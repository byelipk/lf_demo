defmodule LfDemo.SandboxTest do
  use ExUnit.Case, async: true
  alias LfDemo.Sandbox
  import LfDemo.TestHelpers

  test "extracts distinct textual answers using restricted dotted keys" do
    for answer <- ["A useful answer", "Different answer"] do
      assert %{status: "ok", answer: ^answer} =
               Sandbox.execute(200, %{"result" => %{"answer" => answer}}, candidate())
    end

    assert {:error, _} =
             Sandbox.validate_config(%{
               "answer_path" => "result[0].answer",
               "missing_behavior" => "empty"
             })

    assert {:error, _} =
             Sandbox.validate_config(%{
               "answer_path" => "System.cmd()",
               "missing_behavior" => "empty"
             })
  end

  test "missing, whitespace, empty, and non-string answers require review" do
    for payload <- [
          %{},
          %{"result" => %{}},
          %{"result" => %{"answer" => nil}},
          %{"result" => %{"answer" => ""}},
          %{"result" => %{"answer" => "  "}},
          %{"result" => %{"answer" => 17}},
          %{"result" => []}
        ] do
      assert %{status: "needs_review", answer: nil} = Sandbox.execute(200, payload, candidate())
    end
  end

  test "starter behavior reproduces the misleading green empty string" do
    assert %{status: "ok", answer: "", diagnostic: "unusable_answer_emitted_empty"} =
             Sandbox.execute(200, %{}, %{"answer_path" => "answer", "missing_behavior" => "empty"})
  end

  test "HTTP failure blocks before extraction and cannot authorize correction" do
    assert %{status: "blocked", answer: nil} =
             Sandbox.execute(403, %{"result" => %{"answer" => "irrelevant"}}, candidate())

    workflow = LfDemo.Seed.state().workflows["workflow:w31"]

    assert %{readiness: "blocked", verifiable: false, all_passed: false} =
             Sandbox.check(workflow, candidate())
  end

  test "checks compare actual outputs with the assignment contract" do
    w = LfDemo.Seed.state().workflows["workflow:w17"]
    assert %{all_passed: true, checks: checks} = Sandbox.check(w, candidate())
    assert length(checks) == 5
    assert Enum.all?(checks, & &1.passed)

    assert %{all_passed: false} =
             Sandbox.check(w, %{"answer_path" => "answer", "missing_behavior" => "needs_review"})

    assert %{all_passed: false} =
             Sandbox.check(w, %{"answer_path" => "result.answer", "missing_behavior" => "empty"})
  end
end
