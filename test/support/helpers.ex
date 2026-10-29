defmodule LfDemo.TestHelpers do
  alias LfDemo.{Decision, Store, Tools}

  def decision(action, args),
    do: %Decision{
      action: action,
      reason: "Inspect observed evidence before deciding.",
      arguments: args
    }

  def act(store, key, action, args), do: Tools.execute(store, key, decision(action, args))
  def inspect_ref(store, key, ref), do: act(store, key, "inspect", %{"ref_id" => ref})
  def candidate, do: %{"answer_path" => "result.answer", "missing_behavior" => "needs_review"}

  def completion(outcome, overrides \\ %{}) do
    Map.merge(
      %{
        "outcome" => outcome,
        "summary" => "Prepared an evidence-backed next step.",
        "evidence_refs" => ["execution:e201"],
        "learner_note" =>
          "The recorded output is empty. What does the raw response show at the selected field path?",
        "test_report_id" => nil,
        "guide_title" => nil,
        "guide_body" => nil,
        "escalation_owner" => nil,
        "requested_action" => nil
      },
      overrides
    )
  end

  def verified(test) do
    completion("verified_in_sandbox", %{
      "test_report_id" => test.ref_id,
      "evidence_refs" => ["execution:e201", test.ref_id],
      "guide_title" => "Inspect response mapping and missing values",
      "guide_body" =>
        "Use result.answer and needs_review. Compare historical and current configuration, and verify connector reachability before applying."
    })
  end

  def open_case(store, report \\ "report:r104", mode \\ :run) do
    {:ok, run} = Store.start_run(store, report, mode)
    Store.key(run)
  end

  def test_candidate(store, key, c \\ candidate()) do
    act(store, key, "test_configuration", %{"workflow_id" => "workflow:w17", "candidate" => c})
  end

  def runner_options do
    owner = self()
    [before_request: fn pid -> Mox.allow(LfDemo.Codex.ClientMock, owner, pid) end]
  end

  def await_state(store, predicate, timeout \\ 2000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_state(store, predicate, deadline)
  end

  defp wait_for_state(store, predicate, deadline) do
    state = Store.snapshot(store)

    if predicate.(state) do
      state
    else
      receive do
        {:store_updated, ^store} -> wait_for_state(store, predicate, deadline)
      after
        max(0, deadline - System.monotonic_time(:millisecond)) ->
          raise "Timed out waiting for Store transition"
      end
    end
  end
end
