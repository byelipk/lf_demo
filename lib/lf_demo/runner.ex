defmodule LfDemo.Runner do
  @moduledoc "Bounded decision/action loop. No diagnostic routing exists here."
  alias LfDemo.{Store, Tools, Decision}
  alias LfDemo.Codex.{Error, Protocol}

  def run(store, key, client, opts \\ []) do
    limits = %{
      calls: min(Keyword.get(opts, :max_calls, 12), 12),
      request_ms: min(Keyword.get(opts, :request_timeout, 60_000), 60_000),
      deadline: now() + min(Keyword.get(opts, :run_timeout, 300_000), 300_000)
    }

    loop(store, key, client, opts, limits, false)
  end

  defp loop(store, key, client, opts, limits, repaired?) do
    with {:ok, context} <- Store.request(store, key, :context),
         :ok <- budget(context, limits),
         :ok <- Store.request(store, key, :count_request) do
      timeout = max(1, min(limits.request_ms, limits.deadline - now()))

      request =
        Protocol.context(context, %{
          calls_remaining: limits.calls - context.run.request_count,
          milliseconds_remaining: limits.deadline - now()
        })

      result = query(client, request, timeout, opts)
      accept(store, key, client, opts, limits, repaired?, result)
    else
      {:error, :inactive_run} -> :stopped
      {:error, error} -> fail(store, key, error)
    end
  end

  defp accept(store, key, client, opts, limits, repaired?, result) do
    with {:ok, context} <- Store.request(store, key, :context),
         true <- now() < limits.deadline do
      if context.run.mode == :preview do
        Store.finish(store, key, :previewed, result)
      else
        advance(store, key, client, opts, limits, repaired?, result)
      end
    else
      {:error, :inactive_run} -> :stopped
      false -> fail(store, key, Error.new(:timeout, "Investigation deadline exceeded."))
    end
  end

  defp advance(store, key, client, opts, limits, repaired?, {:ok, %Decision{} = decision}) do
    # Even clients injected by trusted configuration must satisfy the application contract.
    value = %{
      "action" => decision.action,
      "reason" => decision.reason,
      "arguments" => decision.arguments
    }

    case Decision.validate(value) do
      {:ok, _} ->
        result = Tools.execute(store, key, decision)

        observation = %{
          action: decision.action,
          reason: decision.reason,
          arguments: decision.arguments,
          result: result
        }

        case {decision.action, result} do
          {"complete_case", {:ok, _}} ->
            :completed

          _ ->
            Store.append_observation(store, key, observation)
            loop(store, key, client, opts, limits, repaired?)
        end

      {:error, _} ->
        advance(
          store,
          key,
          client,
          opts,
          limits,
          repaired?,
          {:error, Error.new(:invalid_decision, "Decision contract rejected.")}
        )
    end
  end

  defp advance(store, key, client, opts, limits, false, {:error, %Error{kind: kind} = error})
       when kind in [:invalid_json, :invalid_decision] do
    Store.append_observation(store, key, %{
      error: error,
      repair: "One repair allowed. Return one valid decision matching the supplied schema."
    })

    loop(store, key, client, opts, limits, true)
  end

  defp advance(store, key, _, _, _, _, {:error, error}), do: fail(store, key, error)

  defp advance(store, key, _, _, _, _, _),
    do: fail(store, key, Error.new(:protocol, "Client returned an unsupported result."))

  defp budget(context, limits) do
    cond do
      context.run.request_count >= limits.calls ->
        {:error, Error.new(:budget_exhausted, "Model request budget exhausted.")}

      now() >= limits.deadline ->
        {:error, Error.new(:timeout, "Investigation deadline exceeded.")}

      true ->
        :ok
    end
  end

  defp query(client, request, timeout, opts) do
    task =
      Task.async(fn ->
        receive do
          :decide -> client.decide(request, Keyword.put(opts, :timeout, timeout))
        end
      end)

    if callback = opts[:before_request], do: callback.(task.pid)
    send(task.pid, :decide)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, Error.new(:timeout, "Decision request timed out.")}
      {:exit, _} -> {:error, Error.new(:transport, "Decision process exited.")}
    end
  end

  defp fail(store, key, error), do: Store.finish(store, key, :failed, {:error, error})
  defp now, do: System.monotonic_time(:millisecond)
end
