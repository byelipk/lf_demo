defmodule LfDemo.Codex.InvestigationProof do
  @moduledoc "Independent acceptance checks over an investigation's actual before/after snapshots."
  alias LfDemo.Codex.Error
  alias LfDemo.Sandbox

  # Evaluator expectations stay outside the model's context and decision loop.
  @outcomes %{
    "report:r104" => "verified_in_sandbox",
    "report:r105" => "verified_in_sandbox",
    "report:r106" => "coaching_prepared",
    "report:r107" => "escalation_prepared"
  }

  def verify(before, state, run_id) do
    run = state.runs[run_id]
    case_result = run && state.cases[run.report_id]

    cond do
      is_nil(run) ->
        rejected("No investigation run was recorded.")

      run.status == :failed ->
        failed(run.result)

      run.status != :completed or is_nil(case_result) or state.active != nil ->
        rejected("The investigation did not commit a completed case.")

      run.mode != :run or run.result != case_result or run.request_count not in 2..12 ->
        rejected("The completed case does not match a bounded full investigation.")

      case_result.outcome != @outcomes[run.report_id] ->
        rejected("Unexpected case outcome: #{case_result.outcome}.")

      true ->
        verify_evidence(before, state, run, case_result)
    end
  end

  defp verify_evidence(before, state, run, case_result) do
    successful = for %{result: {:ok, _}} = observation <- run.history, do: observation
    actions = Enum.frequencies_by(successful, & &1.action)
    report = before.reports[run.report_id]

    inspected =
      for %{action: "inspect", arguments: %{"ref_id" => ref}} <- successful, do: ref

    required =
      if case_result.outcome == "verified_in_sandbox",
        do: ~w(search_context inspect test_configuration complete_case),
        else: ~w(inspect complete_case)

    cond do
      not Enum.all?(required, &Map.has_key?(actions, &1)) ->
        rejected(
          "Missing successful application tools: #{Enum.join(required -- Map.keys(actions), ", ")}."
        )

      report.execution_ref not in inspected or
          not Enum.any?(inspected, &Map.has_key?(before.documents, &1)) ->
        rejected("Execution and course-document inspection were not both demonstrated.")

      report.execution_ref not in case_result.evidence_refs or
          not Enum.all?(case_result.evidence_refs, &MapSet.member?(run.disclosed, &1)) ->
        rejected("The committed case lacks disclosed execution evidence.")

      before.executions != state.executions or
          Map.take(state.revisions, Map.keys(before.revisions)) != before.revisions ->
        rejected("Historical executions or workflow revisions changed.")

      true ->
        verify_outcome(before, state, run, case_result, actions)
    end
  end

  defp verify_outcome(before, state, run, %{outcome: "verified_in_sandbox"} = result, actions) do
    workflow_id = before.reports[run.report_id].workflow_id
    original = before.workflows[workflow_id]
    current = state.workflows[workflow_id]
    guide = state.notes[result.guide_ref]

    test =
      Enum.find_value(result.evidence_refs, fn ref ->
        case state.tests[ref] do
          %{run_id: id, all_passed: true, verifiable: true} = test when id == run.id -> test
          _ -> nil
        end
      end)

    recomputed = test && Sandbox.check(original, test.candidate)

    if test && guide && test.token == run.token && test.generation == run.generation &&
         test.base_revision == original.revision && test.workflow_id == workflow_id &&
         test.candidate == current.config && result.after == current.config &&
         result.before == original.config && current.config != original.config &&
         current.revision == original.revision + 1 &&
         Map.delete(before.workflows, workflow_id) == Map.delete(state.workflows, workflow_id) &&
         state.revisions["#{workflow_id}@#{current.revision}"] == current &&
         test.fixture_version == state.fixture_version && recomputed.all_passed &&
         test.checks == recomputed.checks && test.candidate_hash == recomputed.candidate_hash &&
         guide.workflow_id == workflow_id && guide.configuration_hash == test.candidate_hash &&
         is_binary(guide.body) && String.trim(guide.body) != "" &&
         is_binary(guide.title) && String.trim(guide.title) != "" do
      {:ok,
       summary(run, result, actions)
       |> Map.merge(%{
         test_ref: test.ref_id,
         checks_passed: length(test.checks),
         workflow_id: workflow_id,
         revision_before: original.revision,
         revision_after: current.revision,
         configuration: current.config,
         guide_ref: guide.ref_id,
         guide: guide,
         test_report:
           Map.take(test, [
             :ref_id,
             :all_passed,
             :verifiable,
             :checks,
             :candidate_hash,
             :fixture_version
           ]),
         historical_executions_preserved: true
       })}
    else
      rejected(
        "The passing test, committed configuration, revision, and saved guide do not agree."
      )
    end
  end

  defp verify_outcome(before, state, run, result, actions) do
    handoff_valid? =
      result.outcome != "escalation_prepared" or state.escalations[result.ref_id] == result

    if before.workflows == state.workflows and handoff_valid?,
      do: {:ok, summary(run, result, actions)},
      else: rejected("Coaching/escalation changed a workflow or failed to save its handoff.")
  end

  defp summary(run, result, actions) do
    %{
      report_id: run.report_id,
      run_id: run.id,
      request_count: run.request_count,
      successful_tools: actions,
      case: result
    }
  end

  defp failed({:error, %Error{} = error}), do: {:error, error}
  defp failed(_), do: rejected("The investigation worker failed.")
  defp rejected(message), do: {:error, Error.new(:protocol, message)}
end
