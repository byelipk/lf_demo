defmodule LfDemo.Codex.InvestigationTest do
  use ExUnit.Case, async: true
  import Mox
  import LfDemo.TestHelpers
  alias LfDemo.Codex.{ClientMock, Error, Investigation}
  alias LfDemo.Store

  @moduletag :synthetic_documentation_derived
  setup :verify_on_exit!

  test "supervised loop executes tools, verifies the committed repair, and cleans up without touching the app Store" do
    owner = self()
    app_state = Store.snapshot()

    for {action, args} <- [
          {"search_context", %{"query" => "answer"}},
          {"inspect", %{"ref_id" => "execution:e201"}},
          {"inspect", %{"ref_id" => "document:d01"}},
          {"test_configuration", %{"workflow_id" => "workflow:w17", "candidate" => candidate()}}
        ] do
      expect(ClientMock, :decide, fn _, _ -> {:ok, decision(action, args)} end)
    end

    expect(ClientMock, :decide, fn context, _ ->
      %{result: [:ok, test]} = List.last(context.observations)
      assert test.all_passed
      {:ok, decision("complete_case", verified(test))}
    end)

    assert {:ok, proof} =
             Investigation.run(
               runner_options() ++
                 [
                   client: ClientMock,
                   before_worker: fn pid -> send(owner, {:worker, pid}) end,
                   on_observation: fn observation ->
                     send(owner, {:observed, observation.action})
                   end
                 ]
             )

    assert proof.case.outcome == "verified_in_sandbox"
    assert proof.request_count == 5
    assert proof.checks_passed == 5
    assert proof.revision_before == 1
    assert proof.revision_after == 2

    assert proof.successful_tools == %{
             "search_context" => 1,
             "inspect" => 2,
             "test_configuration" => 1,
             "complete_case" => 1
           }

    assert_receive {:worker, worker}
    refute Process.alive?(worker)
    assert_receive {:observed, "search_context"}
    assert_receive {:observed, "complete_case"}
    assert Store.snapshot() == app_state
  end

  test "live-client errors and budget exhaustion cannot produce a passing proof" do
    expect(ClientMock, :decide, fn _, _ ->
      {:error, Error.new(:transport, "Synthetic provider failure.")}
    end)

    assert {:error, %Error{kind: :transport}} =
             Investigation.run(runner_options() ++ [client: ClientMock])

    expect(ClientMock, :decide, fn _, _ ->
      {:ok, decision("inspect", %{"ref_id" => "execution:e201"})}
    end)

    assert {:error, %Error{kind: :budget_exhausted}} =
             Investigation.run(runner_options() ++ [client: ClientMock, max_calls: 1])
  end

  test "a completed coaching case cannot substitute for the expected sandbox repair" do
    for ref <- ["execution:e201", "document:d01"] do
      expect(ClientMock, :decide, fn _, _ ->
        {:ok, decision("inspect", %{"ref_id" => ref})}
      end)
    end

    expect(ClientMock, :decide, fn _, _ ->
      {:ok,
       decision(
         "complete_case",
         completion("coaching_prepared", %{
           "evidence_refs" => ["execution:e201", "document:d01"]
         })
       )}
    end)

    assert {:error, %Error{kind: :protocol, message: message}} =
             Investigation.run(runner_options() ++ [client: ClientMock])

    assert message =~ "Unexpected case outcome"
  end

  for {report, execution, outcome} <- [
        {"report:r106", "execution:e203", "coaching_prepared"},
        {"report:r107", "execution:e204", "escalation_prepared"}
      ] do
    test "verifies #{outcome} without a configuration commit" do
      for ref <- [unquote(execution), "document:d01"] do
        expect(ClientMock, :decide, fn _, _ ->
          {:ok, decision("inspect", %{"ref_id" => ref})}
        end)
      end

      expect(ClientMock, :decide, fn _, _ ->
        args =
          completion(unquote(outcome), %{
            "evidence_refs" => [unquote(execution), "document:d01"],
            "escalation_owner" => "Course infrastructure owner",
            "requested_action" => "Review connector permissions for the recorded request."
          })

        {:ok, decision("complete_case", args)}
      end)

      assert {:ok, proof} =
               Investigation.run(
                 runner_options() ++ [client: ClientMock, report: unquote(report)]
               )

      assert proof.case.outcome == unquote(outcome)
      assert proof.case.before == proof.case.after
    end
  end
end
