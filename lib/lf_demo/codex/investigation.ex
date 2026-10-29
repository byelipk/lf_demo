defmodule LfDemo.Codex.Investigation do
  @moduledoc "Runs the production investigation in a temporary, isolated runtime without Phoenix."
  alias LfDemo.{Operations, RuntimeSupervisor, Store}
  alias LfDemo.Codex.{Error, InvestigationProof, LiveClient}

  def run(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)

    pubsub =
      if Process.whereis(LfDemo.PubSub),
        do: [],
        else: [{Phoenix.PubSub, name: LfDemo.PubSub}]

    children =
      pubsub ++
        [{RuntimeSupervisor, name: nil, store_options: [notify: self()], task_options: []}]

    {:ok, supervisor} = Supervisor.start_link(children, strategy: :one_for_one)

    try do
      runtime = child(supervisor, RuntimeSupervisor)
      store = child(runtime, Store)
      tasks = child(runtime, Task.Supervisor)
      before = Store.snapshot(store)
      report_id = Keyword.get(opts, :report, "report:r104")
      deadline = System.monotonic_time(:millisecond) + Keyword.get(opts, :run_timeout, 300_000)

      worker_opts =
        opts
        |> Keyword.put_new(:client, LiveClient)
        |> Keyword.put(:task_supervisor, tasks)

      with {:ok, run} <- Operations.start(store, report_id, :run, worker_opts),
           {:ok, state} <- await(store, run.id, deadline, 0, opts) do
        InvestigationProof.verify(before, state, run.id)
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  defp child(supervisor, id) do
    supervisor
    |> Supervisor.which_children()
    |> Enum.find_value(fn
      {^id, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end)
  end

  defp await(store, run_id, deadline, seen, opts) do
    state = Store.snapshot(store)
    run = state.runs[run_id]

    if run do
      if callback = opts[:on_observation] do
        run.history |> Enum.drop(seen) |> Enum.each(callback)
      end

      if run.status == :active do
        receive do
          {:store_updated, ^store} ->
            await(store, run_id, deadline, length(run.history), opts)
        after
          max(0, deadline - System.monotonic_time(:millisecond)) ->
            Store.stop_run(store)
            {:error, Error.new(:timeout, "Full investigation deadline exceeded.")}
        end
      else
        {:ok, state}
      end
    else
      {:error, Error.new(:protocol, "Investigation run disappeared from the isolated Store.")}
    end
  end
end
