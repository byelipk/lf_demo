defmodule LfDemo.Sandbox do
  @moduledoc "Pure execution and assignment-contract checks for the fictional lab."
  @fixture_version "answers-v1"
  def fixture_version, do: @fixture_version

  def validate_config(%{"answer_path" => path, "missing_behavior" => behavior} = c)
      when map_size(c) == 2 and is_binary(path) and behavior in ["empty", "needs_review"] do
    if byte_size(path) <= 160 and
         Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$/, path),
       do: :ok,
       else: {:error, :invalid_answer_path}
  end

  def validate_config(_), do: {:error, :invalid_configuration}

  def execute(http, _payload, _config) when http < 200 or http >= 300,
    do: %{status: "blocked", answer: nil, diagnostic: "connector_http_failure"}

  def execute(_http, payload, config) do
    answer =
      Enum.reduce(String.split(config["answer_path"], "."), payload, fn key, value ->
        if is_map(value), do: Map.get(value, key), else: nil
      end)

    cond do
      is_binary(answer) and String.trim(answer) != "" ->
        %{status: "ok", answer: answer, diagnostic: "answer_extracted"}

      config["missing_behavior"] == "empty" ->
        %{status: "ok", answer: "", diagnostic: "unusable_answer_emitted_empty"}

      true ->
        %{status: "needs_review", answer: nil, diagnostic: "unusable_answer"}
    end
  end

  def hash(candidate),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(Enum.sort(candidate)))
      |> Base.encode16(case: :lower)

  def check(workflow, candidate) do
    fixtures = [
      {"first_text", %{"result" => %{"answer" => "Route to support."}},
       %{status: "ok", answer: "Route to support."}},
      {"other_text", %{"result" => %{"answer" => "Ask for the request ID."}},
       %{status: "ok", answer: "Ask for the request ID."}},
      {"missing", %{"result" => %{}}, %{status: "needs_review", answer: nil}},
      {"empty", %{"result" => %{"answer" => ""}}, %{status: "needs_review", answer: nil}},
      {"non_string", %{"result" => %{"answer" => 42}}, %{status: "needs_review", answer: nil}}
    ]

    reachable = workflow.http_status in 200..299

    checks =
      for {id, payload, expected} <- fixtures do
        observed = execute(workflow.http_status, payload, candidate)

        %{
          id: id,
          expected: expected,
          observed: observed,
          passed: Map.take(observed, [:status, :answer]) == expected
        }
      end

    %{
      workflow_id: workflow.workflow_id,
      base_revision: workflow.revision,
      candidate: candidate,
      candidate_hash: hash(candidate),
      fixture_version: @fixture_version,
      readiness: if(reachable, do: "ready", else: "blocked"),
      verifiable: reachable,
      checks: checks,
      all_passed: reachable and Enum.all?(checks, & &1.passed)
    }
  end
end
