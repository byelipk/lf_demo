defmodule LfDemo.Codex.InvestigationProofTest do
  use ExUnit.Case, async: true
  import LfDemo.TestHelpers
  alias LfDemo.{Store, Tools}
  alias LfDemo.Codex.{Error, InvestigationProof}

  @moduletag :synthetic_documentation_derived

  setup do
    store = start_supervised!(Store)
    before = Store.snapshot(store)
    key = open_case(store)

    for {action, args} <- [
          {"search_context", %{"query" => "answer"}},
          {"inspect", %{"ref_id" => "execution:e201"}},
          {"inspect", %{"ref_id" => "document:d01"}},
          {"test_configuration", %{"workflow_id" => "workflow:w17", "candidate" => candidate()}}
        ] do
      Store.request(store, key, :count_request)
      result = Tools.execute(store, key, decision(action, args))
      Store.append_observation(store, key, %{action: action, arguments: args, result: result})
    end

    test = Store.snapshot(store).tests |> Map.values() |> hd()
    Store.request(store, key, :count_request)
    {:ok, _} = Tools.execute(store, key, decision("complete_case", verified(test)))

    %{before: before, state: Store.snapshot(store), run_id: elem(key, 1), test_ref: test.ref_id}
  end

  test "accepts evidence of all four tools and an atomic verified repair", ctx do
    assert {:ok, proof} = InvestigationProof.verify(ctx.before, ctx.state, ctx.run_id)
    assert proof.historical_executions_preserved
    assert proof.case.guide_ref == proof.guide_ref
  end

  test "rejects incomplete runs, missing tool execution, and altered history", ctx do
    state = ctx.state
    incomplete = put_in(state.runs[ctx.run_id].status, :previewed)

    no_test_tool =
      update_in(state.runs[ctx.run_id].history, fn history ->
        Enum.reject(history, &(&1.action == "test_configuration"))
      end)

    altered_execution = put_in(state.executions["execution:e201"].http_status, 500)

    for state <- [incomplete, no_test_tool, altered_execution] do
      assert {:error, %Error{kind: :protocol}} =
               InvestigationProof.verify(ctx.before, state, ctx.run_id)
    end
  end

  test "rejects mismatched tests, revisions, or missing guides even if status says completed",
       ctx do
    state = ctx.state
    failed_test = put_in(state.tests[ctx.test_ref].all_passed, false)
    wrong_revision = put_in(state.workflows["workflow:w17"].revision, 1)
    missing_guide = %{ctx.state | notes: %{}}
    forged_checks = put_in(state.tests[ctx.test_ref].checks, [])
    unrelated_change = put_in(state.workflows["workflow:w23"].revision, 2)

    for state <- [failed_test, wrong_revision, missing_guide, forged_checks, unrelated_change] do
      assert {:error, %Error{kind: :protocol}} =
               InvestigationProof.verify(ctx.before, state, ctx.run_id)
    end
  end
end
