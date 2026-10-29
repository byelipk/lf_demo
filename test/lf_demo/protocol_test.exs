defmodule LfDemo.ProtocolTest do
  use ExUnit.Case, async: true
  alias LfDemo.Codex.{Protocol, Error}
  alias LfDemo.{Decision, Seed}
  @moduletag :synthetic_documentation_derived
  @final ~s({"action":"inspect","reason":"Check the recorded response.","arguments":{"ref_id":"execution:e201"}})
  test "pure request uses argv, absolute artifacts, restrictions, selected report and no guessed model" do
    report = Seed.state().reports["report:r104"]

    request =
      Protocol.request(
        %{selected_report: report, observations: []},
        "/private/tmp/synthetic-query"
      )

    assert request.executable == "codex"
    assert Path.type(request.schema_path) == :absolute
    assert Path.type(request.result_path) == :absolute

    assert Enum.take(request.args, 6) == [
             "exec",
             "--sandbox",
             "read-only",
             "--ephemeral",
             "--json",
             "--skip-git-repo-check"
           ]

    for restriction <- [
          "features.shell_tool=false",
          "features.multi_agent=false",
          "features.apps=false",
          "features.hooks=false",
          "web_search=\"disabled\"",
          "mcp_servers={}"
        ] do
      assert restriction in request.args
    end

    refute "--model" in request.args
    refute "--ignore-rules" in request.args
    refute "--ignore-user-config" in request.args
    assert List.last(request.args) =~ Jason.encode!(report)
    assert Protocol.schema()["additionalProperties"] == false

    custom =
      Protocol.request(%{}, "/private/tmp/synthetic-query",
        model: "user-selected-model",
        executable: "/custom/path/codex"
      )

    assert custom.executable == "/custom/path/codex"
    assert "user-selected-model" in custom.args
    refute File.exists?(request.result_path)
  end

  test "normalizes application-owned decision and retains original final response" do
    assert {:ok, %Decision{action: "inspect", metadata: %{final_response: @final}}} =
             Protocol.parse_final(@final)
  end

  test "invalid JSON and invalid contract are bounded errors without atom creation" do
    assert {:error, %Error{kind: :invalid_json, details: %{final_response: "{bad"}}} =
             Protocol.parse_final("{bad")

    for value <- [
          %{"action" => "arbitrary", "reason" => "Check", "arguments" => %{}},
          %{
            "action" => "inspect",
            "reason" => String.duplicate("x", 241),
            "arguments" => %{"ref_id" => "execution:e201"}
          },
          %{
            "action" => "inspect",
            "reason" => "Check",
            "arguments" => %{"ref_id" => "execution:e201", "extra" => true}
          }
        ] do
      assert {:error, %Error{kind: :invalid_decision}} =
               Protocol.parse_final(Jason.encode!(value))
    end

    {:ok, value} = Jason.decode(@final)
    assert {:error, _} = Decision.validate(Map.put(value, "extra", true))

    assert {:error, %Error{details: %{final_response: raw}}} =
             Protocol.parse_final(String.duplicate("x", 70_000))

    assert byte_size(raw) <= 65_536
  end

  test "JSONL events are separate from final decision and hidden reasoning is discarded" do
    events = [
      ~s({"type":"thread.started","thread_id":"synthetic-thread"}),
      ~s({"type":"turn.started"}),
      ~s({"type":"item.completed","item":{"type":"error","message":"DO_NOT_STORE_DIAGNOSTIC_TEXT"}}),
      ~s({"type":"item.completed","item":{"type":"reasoning","text":"DO_NOT_STORE_HIDDEN_TEXT"}}),
      ~s({"type":"item.completed","item":{"type":"agent_message","text":"final follows"}}),
      ~s({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}})
    ]

    assert {:ok, decision} = Protocol.normalize(@final, events)
    refute inspect(decision) =~ "DO_NOT_STORE_HIDDEN_TEXT"
    refute inspect(decision) =~ "DO_NOT_STORE_DIAGNOSTIC_TEXT"
    refute inspect(decision) =~ "input_tokens"
  end

  test "unexpected native tools invalidate the final decision" do
    for type <-
          ~w(command_execution file_change mcp_tool_call web_search plan unknown_native_tool) do
      event =
        Jason.encode!(%{
          "type" => "item.started",
          "item" => %{"type" => type, "text" => "hidden output"}
        })

      assert {:error, %Error{kind: :unexpected_native_tool, details: details}} =
               Protocol.normalize(@final, [event])

      assert details.final_response == @final
      refute inspect(details) =~ "hidden output"
    end

    assert {:error, %Error{kind: :protocol}} = Protocol.event("not JSON")

    assert {:error, %Error{kind: :transport}} =
             Protocol.event(~s({"type":"turn.failed","error":{"message":"private"}}))
  end

  test "nonfatal diagnostic items cannot hide a failed turn or invalid final response" do
    diagnostic = ~s({"type":"item.completed","item":{"type":"error","message":"warning"}})
    failed = ~s({"type":"turn.failed","error":{"message":"failure"}})

    assert {:error, %Error{kind: :transport}} = Protocol.normalize(@final, [diagnostic, failed])
    assert {:error, %Error{kind: :invalid_json}} = Protocol.normalize("", [diagnostic])
  end
end
