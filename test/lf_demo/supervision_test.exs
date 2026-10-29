defmodule LfDemo.SupervisionTest do
  use ExUnit.Case, async: true
  import LfDemo.TestHelpers
  alias LfDemo.{Store, Operations, RuntimeSupervisor}
  alias LfDemo.Codex.ClientMock
  import Mox
  setup :verify_on_exit!

  test "Store restart terminates its active worker and query and restores seed state" do
    parent = self()

    runtime =
      start_supervised!(
        {RuntimeSupervisor, name: nil, store_options: [notify: self()], task_options: []}
      )

    children = Supervisor.which_children(runtime)
    {_, store, _, _} = Enum.find(children, &(elem(&1, 0) == Store))
    {_, tasks, _, _} = Enum.find(children, &(elem(&1, 0) == Task.Supervisor))
    old_generation = Store.snapshot(store).generation

    expect(ClientMock, :decide, fn _, _ ->
      send(parent, {:query_started, self()})

      receive do
        :never -> {:error, :unreachable}
      end
    end)

    {:ok, _} =
      Operations.start(
        store,
        "report:r104",
        :run,
        [client: ClientMock, task_supervisor: tasks] ++ runner_options()
      )

    assert_receive {:query_started, query}
    worker = Store.snapshot(store).active.pid
    query_monitor = Process.monitor(query)
    worker_monitor = Process.monitor(worker)
    Process.exit(store, :kill)
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _}
    assert_receive {:DOWN, ^query_monitor, :process, ^query, _}
    fresh = await_fresh_store(store)
    state = Store.snapshot(fresh)
    refute state.generation == old_generation
    assert state.runs == %{}
    assert state.active == nil
    assert Process.alive?(runtime)
  end

  defp await_fresh_store(old) do
    receive do
      {:store_updated, store} when store != old -> store
      {:store_updated, ^old} -> await_fresh_store(old)
    after
      2000 -> flunk("Store did not restart")
    end
  end
end
