defmodule LfDemo.StoreTest do
  use ExUnit.Case, async: true
  import LfDemo.TestHelpers
  alias LfDemo.Store

  setup do
    store = start_supervised!({Store, notify: self()})
    %{store: store}
  end

  test "completion atomically commits exactly the tested configuration and guide, preserving history",
       %{store: s} do
    key = open_case(s)
    assert {:ok, _} = inspect_ref(s, key, "execution:e201")
    {:ok, t} = test_candidate(s, key)
    before = Store.snapshot(s)
    assert {:ok, result} = Store.complete_case(s, key, verified(t))
    after_state = Store.snapshot(s)
    assert result.before == before.workflows["workflow:w17"].config
    assert result.after == t.candidate
    assert after_state.workflows["workflow:w17"].config == t.candidate
    assert after_state.workflows["workflow:w17"].revision == 2
    assert after_state.revisions["workflow:w17@1"] == before.workflows["workflow:w17"]
    assert after_state.executions == before.executions
    assert map_size(after_state.notes) == 1
    assert after_state.notes[result.guide_ref].configuration_hash == t.candidate_hash
    assert after_state.active == nil
    assert {:error, :report_completed_reset_required} = Store.start_run(s, "report:r104")
    assert {:error, :already_finished} = Store.stop_run(s)
    assert {:error, :inactive_run} = Store.complete_case(s, key, verified(t))
  end

  test "untested and failing corrections are rejected without any state change", %{store: s} do
    key = open_case(s)
    inspect_ref(s, key, "execution:e201")
    missing = completion("verified_in_sandbox")
    before = Store.snapshot(s)
    assert {:error, :test_required} = Store.complete_case(s, key, missing)
    assert Store.snapshot(s) == before

    {:ok, failing} =
      test_candidate(s, key, %{"answer_path" => "answer", "missing_behavior" => "empty"})

    before = Store.snapshot(s)

    assert {:error, :passing_verifiable_test_required} =
             Store.complete_case(s, key, verified(failing))

    assert Store.snapshot(s) == before
  end

  test "undisclosed evidence and uninspected execution cannot complete", %{store: s} do
    key = open_case(s)
    before = Store.snapshot(s)

    assert {:error, :undisclosed_evidence} =
             Store.complete_case(s, key, completion("coaching_prepared"))

    assert Store.snapshot(s) == before
    inspect_ref(s, key, "document:d01")

    assert {:error, :execution_not_inspected} =
             Store.complete_case(
               s,
               key,
               completion("coaching_prepared", %{"evidence_refs" => ["document:d01"]})
             )
  end

  test "test reports cannot cross runs and tools cannot target another workflow", %{store: s} do
    key = open_case(s)
    {:ok, t} = test_candidate(s, key)

    assert {:error, :wrong_workflow} =
             act(s, key, "test_configuration", %{
               "workflow_id" => "workflow:w31",
               "candidate" => candidate()
             })

    Store.stop_run(s)
    key2 = open_case(s)
    inspect_ref(s, key2, "execution:e201")
    inspect_ref(s, key2, t.ref_id)
    before = Store.snapshot(s)
    assert {:error, :wrong_run_test} = Store.complete_case(s, key2, verified(t))
    assert Store.snapshot(s) == before
  end

  for {name, mutation, expected} <- [
        {"wrong workflow", :workflow, :wrong_workflow_test},
        {"stale revision", :revision, :stale_revision},
        {"stale fixture set", :fixtures, :stale_fixtures}
      ] do
    @mutation mutation
    @expected expected
    test "#{name} completion leaves the Store unchanged", %{store: s} do
      key = open_case(s)
      inspect_ref(s, key, "execution:e201")
      {:ok, t} = test_candidate(s, key)
      # Simulate a server-side revision/fixture update after a check was captured.
      :sys.replace_state(s, fn state ->
        case @mutation do
          :workflow -> put_in(state.tests[t.ref_id].workflow_id, "workflow:w31")
          :revision -> put_in(state.workflows["workflow:w17"].revision, 2)
          :fixtures -> %{state | fixture_version: "answers-v2"}
        end
      end)

      before = Store.snapshot(s)
      assert {:error, @expected} = Store.complete_case(s, key, verified(t))
      assert Store.snapshot(s) == before
    end
  end

  test "required fields, actual change and relevant documents are enforced", %{store: s} do
    key = open_case(s)
    inspect_ref(s, key, "execution:e201")

    assert {:error, :course_document_required} =
             Store.complete_case(s, key, completion("coaching_prepared"))

    assert {:error, :handoff_required} =
             Store.complete_case(s, key, completion("escalation_prepared"))

    assert {:error, :missing_fact_required} =
             Store.complete_case(s, key, completion("needs_information"))

    {:ok, t} = test_candidate(s, key)

    assert {:error, :guide_required} =
             Store.complete_case(s, key, Map.put(verified(t), "guide_body", nil))

    Store.stop_run(s)
    key = open_case(s, "report:r106")
    inspect_ref(s, key, "execution:e203")

    {:ok, t} =
      act(s, key, "test_configuration", %{
        "workflow_id" => "workflow:w23",
        "candidate" => candidate()
      })

    args = verified(t) |> Map.put("evidence_refs", ["execution:e203", t.ref_id])
    assert {:error, :configuration_unchanged} = Store.complete_case(s, key, args)
  end

  test "bare and versioned references differ after commit; paths and URLs are rejected", %{
    store: s
  } do
    key = open_case(s)
    inspect_ref(s, key, "execution:e201")
    {:ok, t} = test_candidate(s, key)
    Store.complete_case(s, key, verified(t))
    key = open_case(s, "report:r105")
    assert {:ok, %{value: %{revision: 2}}} = inspect_ref(s, key, "workflow:w17")
    assert {:ok, %{value: %{revision: 1}}} = inspect_ref(s, key, "workflow:w17@1")

    assert {:ok,
            %{
              value: %{
                current_workflow_ref: "workflow:w17@2",
                recorded_workflow_ref: "workflow:w17@1"
              }
            }} = inspect_ref(s, key, "execution:e202")

    for ref <- ["/etc/passwd", "https://example.com", "file:///tmp/test", "unknown"] do
      assert {:error, %{code: :unknown_reference}} = inspect_ref(s, key, ref)
    end
  end

  test "reset changes generation and old tokens/results cannot affect new runs", %{store: s} do
    old = open_case(s)
    {:ok, t} = test_candidate(s, old)
    assert {:error, :operation_active} = Store.reset(s)
    Store.stop_run(s)
    assert :ok = Store.reset(s)
    new_key = open_case(s)
    refute elem(old, 0) == elem(new_key, 0)
    before = Store.snapshot(s)
    assert {:error, :inactive_run} = Store.save_test_report(s, old, t)
    assert {:error, :inactive_run} = Store.finish(s, old, :failed, "late")
    assert {:error, :inactive_run} = Store.complete_case(s, old, verified(t))

    assert {:error, :inactive_run} =
             Store.append_observation(s, {elem(new_key, 0), elem(new_key, 1), make_ref()}, %{
               late: true
             })

    send(s, {:late_result, old, t})
    assert Store.snapshot(s) == before
  end

  test "concurrent starts allow just one operation including preview", %{store: s} do
    tasks =
      for mode <- [:run, :preview],
          do: Task.async(fn -> Store.start_run(s, "report:r104", mode) end)

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :operation_active})) == 1
  end

  test "a new Store starts from seed and state is only in memory", %{store: s} do
    key = open_case(s)
    Store.append_observation(s, key, %{local: true})
    assert Store.snapshot(s).runs != %{}
    {:ok, fresh} = Store.start_link([])
    on_exit(fn -> if Process.alive?(fresh), do: GenServer.stop(fresh) end)
    assert Store.snapshot(fresh).runs == %{}
    assert Store.snapshot(fresh).cases == %{}
  end

  test "needs information cites a failed selected-execution inspection and records the missing fact",
       %{store: s} do
    key = open_case(s)

    :sys.replace_state(s, fn state ->
      %{state | executions: Map.delete(state.executions, "execution:e201")}
    end)

    {:error, %{failure_ref: failure}} = inspect_ref(s, key, "execution:e201")

    assert {:ok, result} =
             Store.complete_case(
               s,
               key,
               completion("needs_information", %{
                 "evidence_refs" => [failure],
                 "requested_action" => "Provide the missing execution record and HTTP response."
               })
             )

    assert result.outcome == "needs_information"
    assert Store.snapshot(s).workflows["workflow:w17"].revision == 1
  end

  test "a later worker monitor message cannot finalize successful completion twice", %{store: s} do
    key = open_case(s)

    {:ok, worker} =
      Task.Supervisor.start_child(LfDemo.TaskSupervisor, fn ->
        receive do
          :finish -> :ok
        end
      end)

    Store.attach(s, key, worker)
    monitor = Store.snapshot(s).active.monitor
    inspect_ref(s, key, "execution:e201")
    {:ok, t} = test_candidate(s, key)
    {:ok, _} = Store.complete_case(s, key, verified(t))
    completed = Store.snapshot(s)
    send(worker, :finish)
    send(s, {:DOWN, monitor, :process, worker, :normal})
    assert Store.snapshot(s) == completed
  end
end
