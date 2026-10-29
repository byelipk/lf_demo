defmodule LfDemo.RunnerTest do
  use ExUnit.Case, async: true
  import Mox
  import LfDemo.TestHelpers
  alias LfDemo.{Store, Runner, Operations}
  alias LfDemo.Codex.{ClientMock, Error}
  setup :verify_on_exit!

  setup do
    %{store: start_supervised!({Store, notify: self()})}
  end

  defp expect_action(action, args) do
    expect(ClientMock, :decide, fn _ctx, _opts -> {:ok, decision(action, args)} end)
  end

  defp latest_test(ctx) do
    ctx.observations
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{action: "test_configuration", result: ["ok", t]} -> t
      %{action: "test_configuration", result: [:ok, t]} -> t
      _ -> nil
    end)
  end

  # Context is JSON-compatible: finite atoms become string values only on encoding;
  # the client behaviour itself receives maps, not an encoded prompt.
  test "shared defect: failed candidate is evidence for the next decision, revised candidate passes",
       %{store: s} do
    key = open_case(s)

    expect(ClientMock, :decide, fn ctx, _ ->
      assert ctx.selected_report == Store.snapshot(s).reports["report:r104"]
      refute Map.has_key?(ctx, :expected_outcome)
      {:ok, decision("inspect", %{"ref_id" => "execution:e201"})}
    end)

    expect_action("inspect", %{"ref_id" => "document:d01"})

    expect_action("test_configuration", %{
      "workflow_id" => "workflow:w17",
      "candidate" => %{"answer_path" => "answer", "missing_behavior" => "needs_review"}
    })

    expect(ClientMock, :decide, fn ctx, _ ->
      t = latest_test(ctx)
      assert t.all_passed == false
      assert Enum.any?(t.checks, &(not &1.passed))

      {:ok,
       decision("test_configuration", %{
         "workflow_id" => "workflow:w17",
         "candidate" => candidate()
       })}
    end)

    expect(ClientMock, :decide, fn ctx, _ ->
      t = latest_test(ctx)
      assert t.all_passed
      {:ok, decision("complete_case", verified(t))}
    end)

    assert :completed = Runner.run(s, key, ClientMock, runner_options())
    state = Store.snapshot(s)
    assert state.cases["report:r104"].outcome == "verified_in_sandbox"
    assert state.workflows["workflow:w17"].revision == 2
    assert map_size(state.notes) == 1
    assert state.runs[elem(key, 1)].request_count == 5
  end

  test "expected missing-data behavior: coaching saves guidance without configuration change", %{
    store: s
  } do
    key = open_case(s, "report:r106")
    before = Store.snapshot(s).workflows
    expect_action("inspect", %{"ref_id" => "execution:e203"})
    expect_action("inspect", %{"ref_id" => "document:d01"})

    expect_action(
      "complete_case",
      completion("coaching_prepared", %{
        "evidence_refs" => ["execution:e203", "document:d01"],
        "learner_note" =>
          "The response has no usable answer, so needs_review matches the assignment. Which field would you inspect to confirm whether an answer exists?"
      })
    )

    assert :completed = Runner.run(s, key, ClientMock, runner_options())
    assert Store.snapshot(s).workflows == before
    assert Store.snapshot(s).cases["report:r106"].outcome == "coaching_prepared"
  end

  test "connector access failure: concrete local escalation without configuration change", %{
    store: s
  } do
    key = open_case(s, "report:r107")
    before = Store.snapshot(s).workflows
    expect_action("inspect", %{"ref_id" => "execution:e204"})
    expect_action("inspect", %{"ref_id" => "document:d03"})

    expect_action("test_configuration", %{
      "workflow_id" => "workflow:w31",
      "candidate" => candidate()
    })

    expect(ClientMock, :decide, fn ctx, _ ->
      assert latest_test(ctx).readiness == "blocked"

      {:ok,
       decision(
         "complete_case",
         completion("escalation_prepared", %{
           "evidence_refs" => ["execution:e204", "document:d03"],
           "escalation_owner" => "Course infrastructure owner",
           "requested_action" =>
             "Review connector permissions for synthetic request req-031 and restore authorized access.",
           "learner_note" =>
             "The connector returned HTTP 403. What access scope does the course connector require?"
         })
       )}
    end)

    assert :completed = Runner.run(s, key, ClientMock, runner_options())
    assert Store.snapshot(s).workflows == before
    assert map_size(Store.snapshot(s).escalations) == 1
  end

  test "second shared report can reuse prior repair with historical/current evidence and no new change",
       %{store: s} do
    key = open_case(s)
    inspect_ref(s, key, "execution:e201")
    {:ok, t} = test_candidate(s, key)
    {:ok, result} = Store.complete_case(s, key, verified(t))
    key = open_case(s, "report:r105")
    before = Store.snapshot(s).workflows
    expect_action("search_context", %{"query" => "mapping"})
    expect_action("inspect", %{"ref_id" => "execution:e202"})
    expect_action("inspect", %{"ref_id" => "workflow:w17"})
    expect_action("inspect", %{"ref_id" => result.guide_ref})
    expect_action("inspect", %{"ref_id" => "document:d01"})

    expect_action(
      "complete_case",
      completion("coaching_prepared", %{
        "evidence_refs" => ["execution:e202", "workflow:w17", result.guide_ref, "document:d01"],
        "learner_note" =>
          "Your recorded run used revision 1; the shared sandbox now uses revision 2. Which revision is selected when you run it again?"
      })
    )

    assert :completed = Runner.run(s, key, ClientMock, runner_options())
    assert Store.snapshot(s).workflows == before
    assert map_size(Store.snapshot(s).notes) == 1
  end

  test "rejected completion is an ordinary observation, never silently replaced", %{store: s} do
    key = open_case(s)
    expect_action("complete_case", completion("coaching_prepared"))

    expect(ClientMock, :decide, fn ctx, _ ->
      assert List.last(ctx.observations).result == [:error, :undisclosed_evidence]
      {:error, Error.new(:transport, "Stop after observing precondition failure.")}
    end)

    Runner.run(s, key, ClientMock, runner_options())
    assert Store.snapshot(s).cases == %{}
  end

  test "preview calls exactly once and does not execute a valid proposed action", %{store: s} do
    key = open_case(s, "report:r104", :preview)

    expect_action("test_configuration", %{
      "workflow_id" => "workflow:w17",
      "candidate" => candidate()
    })

    Runner.run(s, key, ClientMock, runner_options())
    state = Store.snapshot(s)
    assert state.runs[elem(key, 1)].status == :previewed
    assert state.runs[elem(key, 1)].request_count == 1
    assert state.tests == %{}
    assert state.runs[elem(key, 1)].history == []
    assert state.active == nil
  end

  test "preview errors receive no repair opportunity", %{store: s} do
    key = open_case(s, "report:r104", :preview)

    expect(ClientMock, :decide, fn _, _ ->
      {:error, Error.new(:invalid_json, "Synthetic malformed response")}
    end)

    Runner.run(s, key, ClientMock, runner_options())
    assert {:error, %Error{kind: :invalid_json}} = Store.snapshot(s).runs[elem(key, 1)].result
    assert Store.snapshot(s).runs[elem(key, 1)].request_count == 1
  end

  test "invalid JSON has at most one repair and remains a visible failure", %{store: s} do
    key = open_case(s)

    expect(ClientMock, :decide, 2, fn _, _ ->
      {:error, Error.new(:invalid_json, "Synthetic malformed response")}
    end)

    Runner.run(s, key, ClientMock, runner_options())
    run = Store.snapshot(s).runs[elem(key, 1)]
    assert run.status == :failed
    assert run.request_count == 2
    assert length(run.history) == 1
    assert {:error, %Error{kind: :invalid_json}} = run.result
  end

  test "request exhaustion is visible and cannot produce success", %{store: s} do
    key = open_case(s)
    expect_action("inspect", %{"ref_id" => "document:d01"})
    Runner.run(s, key, ClientMock, Keyword.put(runner_options(), :max_calls, 1))
    assert {:error, %Error{kind: :budget_exhausted}} = Store.snapshot(s).runs[elem(key, 1)].result
    assert Store.snapshot(s).cases == %{}
  end

  test "timeout and provider errors remain failures", %{store: s} do
    for kind <- [:timeout, :transport, :unexpected_native_tool] do
      key = open_case(s)

      expect(ClientMock, :decide, fn _, _ ->
        {:error, Error.new(kind, "Synthetic documented failure")}
      end)

      Runner.run(s, key, ClientMock, runner_options())
      assert {:error, %Error{kind: ^kind}} = Store.snapshot(s).runs[elem(key, 1)].result
      assert Store.snapshot(s).runs[elem(key, 1)].status == :failed
    end
  end

  test "request timer cancels a delayed mock", %{store: s} do
    key = open_case(s)
    parent = self()

    expect(ClientMock, :decide, fn _, _ ->
      send(parent, {:waiting, self()})

      receive do
        :never -> {:error, Error.new(:transport, "unexpected")}
      end
    end)

    Runner.run(s, key, ClientMock, Keyword.put(runner_options(), :request_timeout, 20))
    assert_receive {:waiting, query}
    refute Process.alive?(query)
    assert {:error, %Error{kind: :timeout}} = Store.snapshot(s).runs[elem(key, 1)].result
  end

  test "Stop wins while a supervised request is pending; late completion cannot commit", %{
    store: s
  } do
    parent = self()

    expect(ClientMock, :decide, fn _, _ ->
      send(parent, {:pending, self()})

      receive do
        :release -> {:ok, decision("complete_case", completion("coaching_prepared"))}
      end
    end)

    {:ok, run} =
      Operations.start(s, "report:r104", :run, [client: ClientMock] ++ runner_options())

    assert_receive {:pending, query}
    monitor = Process.monitor(query)
    assert :ok = Store.stop_run(s)
    assert_receive {:DOWN, ^monitor, :process, ^query, _}
    send(query, :release)

    assert {:error, :inactive_run} =
             Store.complete_case(s, Store.key(run), completion("coaching_prepared"))

    state = Store.snapshot(s)
    assert state.runs[run.id].status == :stopped
    assert state.cases == %{}
    assert state.workflows["workflow:w17"].revision == 1
  end

  @tag capture_log: true
  test "unexpected worker exit marks failure and releases the active slot", %{store: s} do
    key = open_case(s)

    {:ok, worker} =
      Task.Supervisor.start_child(LfDemo.TaskSupervisor, fn ->
        receive do
          :crash -> exit(:synthetic_failure)
        end
      end)

    assert :ok = Store.attach(s, key, worker)
    send(worker, :crash)
    state = await_state(s, &is_nil(&1.active))
    assert state.runs[elem(key, 1)].status == :failed
    assert {:ok, _} = Store.start_run(s, "report:r104")
  end

  test "an exhausted total deadline prevents any request", %{store: s} do
    key = open_case(s)
    Runner.run(s, key, ClientMock, Keyword.put(runner_options(), :run_timeout, 0))
    run = Store.snapshot(s).runs[elem(key, 1)]
    assert run.request_count == 0
    assert run.status == :failed
    assert {:error, %Error{kind: :timeout}} = run.result
  end
end
