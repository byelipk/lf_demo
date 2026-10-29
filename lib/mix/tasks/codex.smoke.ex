defmodule Mix.Tasks.Codex.Smoke do
  use Mix.Task

  alias LfDemo.Codex.{Error, Investigation, LiveClient, Policy, Protocol}
  alias LfDemo.{Decision, Seed}

  @shortdoc "Proves live Codex can investigate, execute tools, and complete a case"
  @moduledoc """
  Runs the production Operations/Runner loop with the real LiveClient in an
  isolated, temporary Store. Executes application tools and verifies the saved
  case, evidence, and expected outcome. The default report requires all four
  tools, passing sandbox tests, a committed revision, and a saved guide.

      LF_CODEX_LIVE=1 mix codex.smoke
      LF_CODEX_LIVE=1 mix codex.smoke --report report:r107 --timeout 30000
      LF_CODEX_LIVE=1 mix codex.smoke --preview

  Options:

    * `--report` - seeded report ID (default: `report:r104`)
    * `--timeout` - per-request timeout in milliseconds, 1..60000 (default: 60000)
    * `--run-timeout` - total timeout in milliseconds, 1..300000 (default: 300000)
    * `--preview` - request one decision without executing tools
    * `--help` - show usage without invoking Codex

  `LF_CODEX_BIN` and `LF_CODEX_MODEL` use the same overrides as the web app.
  No web endpoint is started. Full runs execute tools and commit only to their
  isolated in-memory Store, which is stopped on exit. At most 12 model requests
  and one schema repair are allowed. Errors and incomplete proofs exit nonzero.
  Live invocation remains forbidden in MIX_ENV=test; there is no mock fallback.
  """

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        strict: [
          report: :string,
          timeout: :integer,
          run_timeout: :integer,
          preview: :boolean,
          help: :boolean
        ]
      )

    if rest != [] or invalid != [],
      do:
        Mix.raise(
          "Usage: mix codex.smoke [--report ID] [--timeout MS] [--run-timeout MS] [--preview] [--help]"
        )

    if opts[:help] do
      Mix.shell().info(@moduledoc)
    else
      smoke(opts)
    end
  end

  defp smoke(opts) do
    timeout = Keyword.get(opts, :timeout, 60_000)

    if timeout not in 1..60_000,
      do: Mix.raise("--timeout must be between 1 and 60000 milliseconds.")

    run_timeout = Keyword.get(opts, :run_timeout, 300_000)

    if run_timeout not in 1..300_000,
      do: Mix.raise("--run-timeout must be between 1 and 300000 milliseconds.")

    Mix.Task.run("app.config")
    report_id = Keyword.get(opts, :report, "report:r104")

    report =
      Map.get(Seed.state().reports, report_id) ||
        Mix.raise("Unknown seeded report: #{report_id}")

    case Policy.check() do
      :ok -> :ok
      {:error, error} -> fail(error)
    end

    {:ok, _} = Application.ensure_all_started(:crypto)

    if opts[:preview],
      do: preview(report, timeout),
      else: investigate(report_id, timeout, run_timeout)
  end

  defp investigate(report_id, timeout, run_timeout) do
    Mix.shell().info(
      "Running full live Codex investigation for #{report_id} (up to 12 requests, #{run_timeout} ms)..."
    )

    started = System.monotonic_time(:millisecond)

    result =
      Investigation.run(
        report: report_id,
        request_timeout: timeout,
        run_timeout: run_timeout,
        before_request: fn _ -> Mix.shell().info("Requesting next live decision...") end,
        on_observation: &print_observation/1
      )

    case result do
      {:ok, proof} ->
        Mix.shell().info(Jason.encode!(proof, pretty: true))
        elapsed = System.monotonic_time(:millisecond) - started

        Mix.shell().info(
          "PASS: full live investigation completed and verified in #{elapsed} ms (#{proof.request_count} requests)."
        )

      {:error, %Error{} = error} ->
        fail(error)

      {:error, reason} ->
        Mix.raise("Live investigation failed: #{inspect(reason)}")
    end
  end

  defp print_observation(%{action: action, arguments: args, result: result}) do
    status =
      case result do
        {:ok, _} -> "ok"
        _ -> "rejected"
      end

    displayed_args =
      if action == "complete_case", do: Map.take(args, ["outcome", "test_report_id"]), else: args

    Mix.shell().info("Tool #{action}: #{status} #{Jason.encode!(displayed_args)}")
  end

  defp print_observation(%{error: error}),
    do: Mix.shell().info("Decision repair: #{error.kind}")

  defp preview(report, timeout) do
    context =
      Protocol.context(%{report: report, run: %{history: []}}, %{
        calls_remaining: 1,
        milliseconds_remaining: timeout
      })

    Mix.shell().info(
      "Requesting one live Codex decision for #{report.report_id} (timeout #{timeout} ms)..."
    )

    started = System.monotonic_time(:millisecond)

    case LiveClient.decide(context, timeout: timeout) do
      {:ok, %Decision{} = decision} ->
        elapsed = System.monotonic_time(:millisecond) - started

        Mix.shell().info(
          Jason.encode!(Map.take(decision, [:action, :reason, :arguments]), pretty: true)
        )

        Mix.shell().info(
          "PASS: live Codex returned a valid application decision in #{elapsed} ms. No action executed."
        )

      {:error, %Error{} = error} ->
        fail(error)
    end
  end

  defp fail(%Error{} = error) do
    diagnostics = Map.take(error.details, [:exit_status, :event_type, :item_type, :exception])

    if map_size(diagnostics) > 0,
      do: Mix.shell().error("Transport details: #{inspect(diagnostics)}")

    hint =
      if error.kind == :live_codex_disabled,
        do: " Run with LF_CODEX_LIVE=1 to opt in.",
        else: ""

    Mix.raise("Live Codex smoke failed [#{error.kind}]: #{error.message}#{hint}")
  end
end
