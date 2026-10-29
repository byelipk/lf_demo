defmodule Mix.Tasks.Codex.SmokeTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Mix.Tasks.Codex.Smoke

  test "help works without a live invocation" do
    assert capture_io(fn -> Smoke.run(["--help"]) end) =~ "LF_CODEX_LIVE=1 mix codex.smoke"
  end

  test "rejects invalid arguments before a live invocation" do
    for args <- [["--unknown"], ["extra"], ["--timeout", "abc"], ["--report"]] do
      assert_raise Mix.Error, ~r/Usage:/, fn -> Smoke.run(args) end
    end

    for timeout <- ["0", "-1", "60001"] do
      assert_raise Mix.Error, ~r/--timeout must be between/, fn ->
        Smoke.run(["--timeout", timeout])
      end
    end

    for timeout <- ["0", "-1", "300001"] do
      assert_raise Mix.Error, ~r/--run-timeout must be between/, fn ->
        Smoke.run(["--run-timeout", timeout])
      end
    end

    assert_raise Mix.Error, ~r/Unknown seeded report/, fn ->
      Smoke.run(["--report", "report:missing"])
    end
  end

  test "test build cannot invoke live Codex through the task" do
    output =
      capture_io(fn ->
        for args <- [[], ["--preview"]] do
          assert_raise Mix.Error, ~r/\[test_forbidden\]/, fn -> Smoke.run(args) end
        end
      end)

    refute output =~ "Requesting"
    refute output =~ "PASS"
  end
end
