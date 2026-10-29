# LF Troubleshooting Agent

A small local Phoenix LiveView prototype for investigating **one fictional learner report**. It uses a bounded decision/tool loop, executable sandbox checks, evidence disclosure, and an atomic correction commit. All state lives in a GenServer map. No database, persistence, deployment, or release setup.

Live Codex is disabled by default. Use the explicit smoke task below to verify the installed CLI and authentication.

## Start locally

The repository pins Elixir **1.20.4-otp-29** and Erlang/OTP **29.1.2** in `.tool-versions`. Use that OTP-specific Elixir build with asdf or a compatible version manager.

```sh
mix deps.get
mix setup
mix phx.server
# Or: iex -S mix phx.server
```

Open <http://127.0.0.1:4000>. If that port is occupied, use `PORT=4017 mix phx.server` and open the corresponding local URL. The page initially says **Live Codex disabled**; Preview and Run are disabled. Startup, rendering, reconnecting, setup, and health checks never request a model decision. A working Codex login is unnecessary for ordinary development.

`mix setup` only fetches dependencies and builds the usual Phoenix assets with esbuild. There is no separate frontend app or Node service.

Refresh/reconnect keeps current memory. Restarting the Store/application loses generated runs, reports, fixes, cases, handoffs, and guides and restores seeds. Reset does the same only when no operation is active. Completed reports require Reset to run again; stopped/failed attempts may restart. The other report about the shared workflow remains available after a correction.

## Offline verification

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

Builder verification on the pinned pair: `mix deps.get`, `mix setup`, `mix test` (50 passed), `mix format --check-formatted`, and `mix compile --warnings-as-errors`. The default-off page was also booted and inspected locally on port 4017 because port 4000 was occupied.

The ExUnit/Mox suite covers sandbox execution, all three outcomes, rejected and revised candidates, completion preconditions and atomicity, historical revision preservation, prior-remedy reuse, single-operation locking, Stop/late-result races, worker failure, Store restart, preview, UI reconnect, and transport cancellation requests. Client expectations are explicitly granted to the actual query process before its start handshake. Concurrent tests use isolated Stores and never replace global application configuration.

Protocol/event examples and fake process handles are **synthetic/documentation-derived**. Mocked decisions demonstrate application mechanics; they establish no independent model judgment, authentication, actual usage, or live CLI compatibility. Tests cannot invoke the live adapter even if an opt-in variable is inherited. The inherited setting is simulated as guard input in tests; no test sets the live-enable environment variable.

## Architecture and contracts

- `LfDemo.Store` owns maps, generation/run tokens, disclosure sets, ordered observations, immutable test reports and executions, and atomic completion. A failed completion leaves its state unchanged. All mutations pass through the Store.
- `LfDemo.RuntimeSupervisor` uses `rest_for_one`: Store precedes `Task.Supervisor`. A Store crash terminates the investigation and linked query task. Each investigation is a temporary supervised task; failure is recorded without restarting a request.
- `LfDemo.Runner` supplies the complete selected report, goal, contracts, remaining budget and actual observations. It validates decisions and executes four actions through `LfDemo.Tools`. There is no report-text or fixture-label routing.
- `LfDemo.Sandbox` is pure map traversal and assignment-contract verification. HTTP failures block before extraction. Five checks exercise two distinct answers, missing, empty and non-string data. Test results never automatically change configuration.
- `LfDemo.Decision` and `LfDemo.Codex.Error` define the application boundary with explicit validation and a finite error vocabulary. `priv/decision.schema.json` and `priv/decision_prompt.txt` own the response schema and instructions. No dynamic atom creation or evaluation of model text.
- `LfDemo.Codex.Protocol` builds requests and normalizes final JSON separately from JSONL events. Final-response data is capped at 64 KiB; hidden reasoning/event text is discarded. Unexpected native tools invalidate a result before any domain action runs.
- `LfDemo.Codex.DisabledClient` is the default. `LiveClient`, `PortTransport`, and `PortBackend` independently check policy before external execution. No fallback to a provider exists.
- `LfDemo.Codex.ProcessTransport` owns the external handle independently and monitors its caller. Stop, timeout, caller failure, and Store restart request cleanup. The Port backend uses executable/argv directly, requests TERM/KILL of a still-active child, and closes the Port. Actual installed CLI termination behavior remains for manual verification. Terminating only a BEAM task is not treated as proof of OS-child termination.
- The CLI port supplies EOF on stdin so `codex exec` can start with its argv prompt. CLI stderr stays separate from JSONL stdout. Completed diagnostic `error` items are discarded; fatal `error` / `turn.failed` events, nonzero exit, missing/invalid final output, and native-tool items still fail the request.
- `LfDemoWeb.DemoLive` subscribes to PubSub and reads snapshots. It never requests a decision from mount, render, reconnect or PubSub handlers. Only deliberate Preview/Run events start work.

One active operation includes previews. Full runs allow at most 12 model requests (repairs included), 60 seconds per request, 300 seconds total, and one JSON/schema repair. Preview permits exactly one call, no repair, and executes no returned action.

The four actions are `search_context`, `inspect`, `test_configuration`, and `complete_case`. Search returns at most five source snippets. Inspection accepts known local references only. A bare workflow reference is current; `@revision` retrieves history. Tests are bound to the selected workflow. A verified commit uses exactly its stored passing candidate, checks current base revision/fixture set, creates a guide keyed by workflow plus configuration hash, increments the revision, and preserves historical executions. Coaching saves guidance; escalation creates a local handoff and sends nothing; needs-information records a missing fact.

## Fictional scenarios (human/evaluator context only)

| Reports | Underlying condition | Demonstrated local outcome |
| --- | --- | --- |
| River `report:r104`, Alex `report:r105` | Shared instructor starter reads `answer` while the payload contains `result.answer`; missing values emit an empty string. | Verify a candidate that also handles missing/empty/non-string answers, commit it with a guide; the second report can compare historical and current revisions and receive coaching. |
| Sam `report:r106` | No usable answer with a correctly configured workflow. | Explain the assignment's expected `needs_review` / null output without a configuration change. |
| Morgan `report:r107` | HTTP 403 with synthetic insufficient permissions. | Prepare a concrete local handoff to the course infrastructure owner; extraction changes cannot restore access. |

These diagnoses and the build specification are not included in runtime context or searchable sources. The three source documents are fictional teaching resources, not BU policy. “Verified in sandbox” describes only the demonstrated synthetic effect, not repair of a real learner environment.

## Live integration smoke check

With an authenticated Codex CLI installed, run:

```sh
LF_CODEX_LIVE=1 mix codex.smoke
# Optional: choose another seeded report or a shorter per-request timeout
LF_CODEX_LIVE=1 mix codex.smoke --report report:r107 --timeout 30000
# Keep the earlier single-decision check available
LF_CODEX_LIVE=1 mix codex.smoke --preview
mix help codex.smoke
```

The default runs the full production `Operations` → `Runner` → `LiveClient` → `Tools` → `Store` path against a fresh, isolated in-memory Store. Every decision comes from a real CLI request, using the same schema, validation, authentication, and optional `LF_CODEX_BIN` / `LF_CODEX_MODEL` settings as the web app. The task prints tool executions as they happen and a JSON proof only after checking the committed case. No web endpoint starts; the temporary runtime is stopped on success or failure, and the application's existing Store is untouched.

For the default `report:r104` (also `report:r105`), `PASS` requires successful execution of all four tools: `search_context`, `inspect`, `test_configuration`, and `complete_case`. Verification checks execution and course-document inspection, disclosed evidence, a passing test from this run, the committed candidate and incremented workflow revision, a saved guide, and unchanged historical executions/revisions. It independently reruns the pure sandbox checks against the committed candidate. A coaching case cannot substitute for the expected repair. The JSON proof includes the case, tool counts, test checks, configuration, revisions, and guide. Reports `r106` and `r107` instead require completed coaching and a saved escalation respectively, with no workflow changes.

Runs allow at most 12 real model requests, 60 seconds per request, 300 seconds overall, and one schema repair. `--timeout` and `--run-timeout` can shorten these limits. Policy/provider errors, exhaustion, incomplete cases, and failed proof checks exit nonzero. Live access remains forbidden in `MIX_ENV=test`; synthetic tests verify mechanics and rejection cases only. `--preview` preserves the earlier one-decision check and executes no tool. Manual Stop/OS-process-cleanup verification remains separate.

The earlier single-decision mode was verified on October 28, 2026 with `codex-cli 0.160.0`: it returned `inspect` with `ref_id: execution:e201` in 14,839 ms. The installed CLI emitted local log-database and MCP startup warnings on stderr; these did not invalidate its successful decision.

Full-loop verification on October 28, 2026 with the same CLI: `LF_CODEX_LIVE=1 mix codex.smoke` exited successfully in **133,536 ms using 8 real requests**. It executed `inspect` five times and each of `search_context`, `test_configuration`, and `complete_case` once. Case `case:run:1` completed as `verified_in_sandbox`; test `test:2` passed all five checks, workflow `workflow:w17` advanced from revision 1 to 2 with `result.answer` / `needs_review`, and a guide was saved. The independent proof confirmed historical executions were preserved and recomputed the sandbox checks. The summary and guide described the local commit accurately. All effects were confined to the temporary Store. Offline verification: formatting, warnings-as-errors compilation, and **62 passing tests**.

## Interactive live verification

To exercise the full UI flow:

1. Start normally and confirm the page says **Live Codex disabled**.
2. Stop the app, then personally opt in:

   ```sh
   LF_CODEX_LIVE=1 iex -S mix phx.server
   ```

   This only makes controls available; it does not start a request. `LF_CODEX_BIN` can specify an executable path; `LF_CODEX_MODEL` can select an accessible model. Otherwise the adapter uses the user's configured model and existing CLI authentication. It performs no version/help/login probes.
3. Select a report and click **Preview one decision**. Inspect the original final response, normalized decision/error, and installed CLI flag compatibility. Preview executes no proposed action.
4. Only after that check, run the shared-starter, connector-access, and missing-data investigations and inspect the model's actual choices and evidence.
5. Manually verify actual timeout/Stop OS-process cleanup and compatibility with the installed CLI and managed policy. Keep this separate from offline acceptance.

Each eventual query uses a fresh temporary non-repository directory, output schema file, and designated final-response file:

```text
codex exec --sandbox read-only --ephemeral --json --skip-git-repo-check
  --output-schema ABS_SCHEMA --output-last-message ABS_RESULT
  [process-scoped capability restrictions] [--model USER_MODEL] PROMPT
```

Arguments are passed separately, never interpolated into a shell. Process-scoped settings restrict shell, subagents, apps, hooks, remote plugins, goals, memories, web search, and image tools. An empty MCP table override is supplied, but the installed CLI merges existing server entries: it does not reliably disable configured servers, and startup warnings can appear. User rules, approval policy, and managed policy remain loaded. Supported settings depend on the installed CLI; a read-only sandbox and separate working directory are not a complete filesystem-isolation guarantee. Any observed native-tool event still fails closed. Only freshly generated query transport artifacts are cleaned up; no disk state or recovery is implemented.

## References

- [Elixir documentation](https://elixir-lang.org/docs/) and [OTP 29.1.2](https://www.erlang.org/patches/OTP-29.1.2)
- [Phoenix app generation](https://hexdocs.pm/phoenix/Mix.Tasks.Phx.New.html), [Task.Supervisor](https://hexdocs.pm/elixir/Task.Supervisor.html), [Mox](https://hexdocs.pm/mox/Mox.html)
- [Codex non-interactive mode](https://learn.chatgpt.com/docs/non-interactive-mode), [developer commands](https://learn.chatgpt.com/docs/developer-commands), [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Role context supplied with the specification](https://jobs.silkroad.com/BU/External/jobs/317456)
