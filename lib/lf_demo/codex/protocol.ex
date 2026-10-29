defmodule LfDemo.Codex.Protocol do
  alias LfDemo.Decision
  alias LfDemo.Codex.Error
  @external_resource "priv/decision.schema.json"
  @external_resource "priv/decision_prompt.txt"
  @schema "priv/decision.schema.json" |> File.read!() |> Jason.decode!()
  @instructions File.read!("priv/decision_prompt.txt")
  def schema, do: @schema

  def context(%{report: report, run: run}, budget) do
    %{
      goal:
        "Investigate the selected fictional learner report and prepare an evidence-backed outcome.",
      selected_report: report,
      allowed_actions: @schema,
      remaining_budget: budget,
      observations: json_value(run.history)
    }
  end

  def prompt(context),
    do: @instructions <> "\nDecision context:\n" <> Jason.encode!(json_value(context))

  def request(context, dir, opts \\ []) do
    schema = Path.join(dir, "schema.json")
    result = Path.join(dir, "final.json")
    # Process-scoped capability restrictions only. User rules and managed policy remain loaded.
    restrictions = [
      "features.shell_tool=false",
      "features.multi_agent=false",
      "features.apps=false",
      "features.hooks=false",
      "features.remote_plugin=false",
      "features.goals=false",
      "features.memories=false",
      "web_search=\"disabled\"",
      "tools.view_image=false",
      "mcp_servers={}"
    ]

    args =
      [
        "exec",
        "--sandbox",
        "read-only",
        "--ephemeral",
        "--json",
        "--skip-git-repo-check",
        "--output-schema",
        schema,
        "--output-last-message",
        result
      ] ++ Enum.flat_map(restrictions, &["-c", &1])

    model = Keyword.get(opts, :model)
    args = if is_binary(model) and model != "", do: args ++ ["--model", model], else: args

    %{
      executable: Keyword.get(opts, :executable, "codex"),
      args: args ++ [prompt(context)],
      cwd: dir,
      schema_path: schema,
      result_path: result
    }
  end

  def parse_final(raw) when is_binary(raw) do
    details = %{final_response: bounded(raw)}

    cond do
      byte_size(raw) > 65_536 ->
        {:error, Error.new(:invalid_json, "Final response exceeds 64 KiB.", details)}

      true ->
        with {:ok, value} <- Jason.decode(raw), {:ok, decision} <- Decision.validate(value) do
          {:ok, %{decision | metadata: details}}
        else
          {:error, %Jason.DecodeError{}} ->
            {:error, Error.new(:invalid_json, "Final response is not valid JSON.", details)}

          _ ->
            {:error,
             Error.new(
               :invalid_decision,
               "Final JSON does not match the decision contract.",
               details
             )}
        end
    end
  end

  def event(line) do
    # Never retain event text: it may contain hidden reasoning or native output.
    case Jason.decode(line) do
      # The CLI emits nonfatal diagnostics (for example MCP startup warnings)
      # as completed error items. Exit status and the final decision still
      # determine success; these items do not represent native tool execution.
      {:ok, %{"type" => "item.completed", "item" => %{"type" => "error"}}} ->
        :ok

      {:ok, %{"type" => type, "item" => %{"type" => item}}}
      when type in ["item.started", "item.updated", "item.completed"] ->
        if item in ["agent_message", "reasoning"],
          do: :ok,
          else:
            {:error,
             Error.new(:unexpected_native_tool, "Unexpected native capability used.", %{
               event_type: type,
               item_type: String.slice(item, 0, 100)
             })}

      {:ok, %{"type" => type}}
      when type in ["thread.started", "turn.started", "turn.completed"] ->
        :ok

      {:ok, %{"type" => type}} when type in ["turn.failed", "error"] ->
        {:error, Error.new(:transport, "Provider reported a failure.", %{event_type: type})}

      _ ->
        {:error, Error.new(:protocol, "Unrecognized JSONL transport event.")}
    end
  end

  def normalize(raw, lines) do
    case Enum.find_value(lines, fn line ->
           case event(line) do
             {:error, e} -> e
             :ok -> nil
           end
         end) do
      nil -> parse_final(raw)
      error -> {:error, %{error | details: Map.put(error.details, :final_response, bounded(raw))}}
    end
  end

  def bounded(raw) do
    raw
    |> binary_part(0, min(byte_size(raw), 65_536))
    |> String.replace(~r/[^\x{0}-\x{10FFFF}]/u, "")
  rescue
    _ -> "Final response contained invalid UTF-8."
  end

  def json_value(%MapSet{} = set), do: set |> MapSet.to_list() |> json_value()
  def json_value(%_{} = struct), do: struct |> Map.from_struct() |> json_value()
  def json_value(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, json_value(v)} end)
  def json_value(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> json_value()
  def json_value(list) when is_list(list), do: Enum.map(list, &json_value/1)
  def json_value(value) when is_reference(value) or is_pid(value), do: inspect(value)
  def json_value(value), do: value
end
