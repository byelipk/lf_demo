defmodule LfDemo.Operations do
  alias LfDemo.{Store, Runner}

  def start(store, report_id, mode, opts \\ []) do
    client = Keyword.get(opts, :client, LfDemo.Codex.Policy.client())

    with true <- client != LfDemo.Codex.DisabledClient,
         {:ok, run} <- Store.start_run(store, report_id, mode) do
      key = Store.key(run)

      case Task.Supervisor.start_child(
             Keyword.get(opts, :task_supervisor, LfDemo.TaskSupervisor),
             fn ->
               receive do
                 :start -> Runner.run(store, key, client, opts)
               end
             end,
             restart: :temporary
           ) do
        {:ok, pid} ->
          if callback = opts[:before_worker], do: callback.(pid)

          case Store.attach(store, key, pid) do
            :ok ->
              send(pid, :start)
              {:ok, run}

            error ->
              error
          end

        {:error, reason} ->
          Store.finish(store, key, :failed, %{
            message: "Worker could not start",
            reason: inspect(reason)
          })

          {:error, :worker_start_failed}
      end
    else
      false -> {:error, :live_codex_disabled}
      error -> error
    end
  end
end
