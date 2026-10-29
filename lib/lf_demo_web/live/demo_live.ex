defmodule LfDemoWeb.DemoLive do
  use LfDemoWeb, :live_view
  alias LfDemo.{Store, Operations}
  alias LfDemo.Codex.{Policy, Protocol}
  @impl true
  def mount(_, _, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(LfDemo.PubSub, Store.topic())
      :timer.send_interval(1000, self(), :tick)
    end

    socket =
      socket
      |> assign_new(:store, fn -> Store end)
      |> assign_new(:client, fn -> Policy.client() end)
      |> assign_new(:operation_options, fn -> [] end)

    state = Store.snapshot(socket.assigns.store)
    latest = state.runs |> Map.values() |> Enum.max_by(& &1.started_at, fn -> nil end)

    selected =
      case state.active do
        %{key: {_, id, _}} -> state.runs[id].report_id
        nil -> if latest, do: latest.report_id, else: "report:r104"
      end

    {:ok, socket |> assign(:selected, selected) |> assign(:notice, nil) |> refresh()}
  end

  @impl true
  def handle_event("select", %{"report_id" => id}, socket) do
    if Map.has_key?(socket.assigns.state.reports, id),
      do: {:noreply, socket |> assign(:selected, id) |> refresh()},
      else: {:noreply, socket}
  end

  def handle_event(event, _, socket) when event in ["preview", "run"] do
    mode = if event == "preview", do: :preview, else: :run

    result =
      Operations.start(
        socket.assigns.store,
        socket.assigns.selected,
        mode,
        Keyword.put(socket.assigns.operation_options, :client, socket.assigns.client)
      )

    {:noreply, socket |> assign(:notice, notice(result)) |> refresh()}
  end

  def handle_event("stop", _, socket),
    do:
      {:noreply,
       socket |> assign(:notice, notice(Store.stop_run(socket.assigns.store))) |> refresh()}

  def handle_event("reset", _, socket),
    do:
      {:noreply,
       socket |> assign(:notice, notice(Store.reset(socket.assigns.store))) |> refresh()}

  @impl true
  def handle_info(message, socket) when message in [:store_updated, :tick],
    do: {:noreply, refresh(socket)}

  defp notice(:ok), do: nil
  defp notice({:ok, _}), do: nil
  defp notice({:error, reason}), do: "Action unavailable: #{inspect(reason)}"

  defp refresh(socket) do
    state = Store.snapshot(socket.assigns.store)
    selected = socket.assigns.selected

    run =
      state.runs
      |> Map.values()
      |> Enum.filter(&(&1.report_id == selected))
      |> Enum.max_by(& &1.started_at, fn -> nil end)

    elapsed =
      if run,
        do:
          max(
            0,
            div((run.finished_at || System.monotonic_time(:millisecond)) - run.started_at, 1000)
          ),
        else: 0

    history =
      if run,
        do:
          Enum.with_index(run.history)
          |> Enum.map(fn {item, i} ->
            %{id: "action-#{run.id}-#{i}", item: item, number: i + 1}
          end),
        else: []

    socket
    |> assign(
      state: state,
      run: run,
      elapsed: elapsed,
      enabled: socket.assigns.client != LfDemo.Codex.DisabledClient,
      form: to_form(%{"report_id" => selected}),
      completed: Map.has_key?(state.cases, selected)
    )
    |> stream(:history, history, reset: true)
  end

  defp pretty(value), do: value |> Protocol.json_value() |> Jason.encode!(pretty: true)
  defp outcome_label("verified_in_sandbox"), do: "Verified in sandbox"
  defp outcome_label("coaching_prepared"), do: "Coaching prepared"
  defp outcome_label("escalation_prepared"), do: "Escalation prepared"
  defp outcome_label("needs_information"), do: "More information needed"
  defp outcome_label(other), do: other
  defp action_label("search_context"), do: "Search context"
  defp action_label("inspect"), do: "Inspect evidence"
  defp action_label("test_configuration"), do: "Test a configuration"
  defp action_label("complete_case"), do: "Prepare the outcome"
  defp action_label(_), do: "Request update"

  attr :name, :string, required: true
  attr :class, :string, default: nil

  defp icon(assigns) do
    paths = %{
      "arrow" => "M5 12h14m-6-6 6 6-6 6",
      "preview" =>
        "M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12Zm10-3a3 3 0 1 0 0 6 3 3 0 0 0 0-6Z",
      "lock" => "M7 10V7a5 5 0 0 1 10 0v3M6 10h12a1 1 0 0 1 1 1v9H5v-9a1 1 0 0 1 1-1Zm6 4v3",
      "reset" => "M3 10a9 9 0 1 1 2 8M3 4v6h6",
      "stop" => "M6 6h12v12H6Z",
      "search" => "M15.5 15.5 21 21M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14Z",
      "check" => "m5 12 4 4L19 6",
      "document" => "M14 3H5v18h14V8l-5-5Zm0 0v5h5M8 12h8m-8 4h5",
      "book" =>
        "M12 5v16M3 3h4a5 5 0 0 1 5 2 5 5 0 0 1 5-2h4v16h-4a5 5 0 0 0-5 2 5 5 0 0 0-5-2H3Z",
      "shield" => "m12 3 8 3v6c0 5-8 9-8 9s-8-4-8-9V6l8-3Zm-4 9 3 3 5-6",
      "flask" => "M9 3h6m-5 0v6L4 19a1.3 1.3 0 0 0 1 2h14a1.3 1.3 0 0 0 1-2L14 9V3M7 14h10",
      "clock" => "M12 8v5l3 2m-3-12a9 9 0 1 0 0 18 9 9 0 0 0 0-18Z"
    }

    assigns = assign(assigns, :path, Map.fetch!(paths, assigns.name))

    ~H"""
    <svg
      class={[@class, "icon"]}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.7"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
      focusable="false"
    ><path d={@path} /></svg>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="shell">
      <header class="header">
        <a href="#" class="brand" aria-label="LF Troubleshooting Agent home">
          <span class="mark" aria-hidden="true">LF<span class="mark-dot"></span></span>
          <div class="brand-copy">
            <p class="university-name">Boston University <span>/ Learning facilitation</span></p><h1>
              Troubleshooting Agent
            </h1>
          </div>
        </a>
        <nav class="header-nav" aria-label="Page sections">
          <a href="#investigation" class="nav-active">Workspace</a><a href="#session-memory">Session memory</a>
        </nav>
        <span id="provider-state" class={["provider", @enabled && "live"]}><span
          class="dot"
          aria-hidden="true"
        ></span>{if @enabled, do: "Live Codex available · manual opt-in", else: "Live Codex disabled"}</span>
      </header>

      <section class="intro" aria-labelledby="intro-title">
        <div>
          <p class="eyebrow"><span class="eyebrow-rule"></span>THE LEARNER SUPPORT LAB</p><h2 id="intro-title">
            Investigate a learner's <span>workflow problem.</span>
          </h2><p class="intro-description">
            Help a learner understand an unexpected result in their course workflow.
            Compare their report with execution evidence and course requirements,
            then save an explanation and a concrete next step.
          </p>
        </div>
        <div class="demo-label"><.icon name="flask" /><span>Synthetic course demo</span></div>
      </section>

      <section
        id="investigation-purpose"
        class="orientation"
        aria-label="Course context and investigation outcomes"
      >
        <div class="course-context">
          <h3>What are learners building?</h3>
          <p>
            A course workflow that calls an API, extracts a text answer, and passes it to the next step.
          </p>
          <div class="course-flow" aria-label="Course workflow">
            <span>API response</span><.icon name="arrow" /><span>Extract answer</span><.icon name="arrow" /><span>Next step</span>
          </div>
          <p class="course-expectation">
            A usable answer should pass through. Missing or unusable answers should be flagged for review.
          </p>
        </div>
        <div class="outcome-context">
          <h3>What should an investigation produce?</h3>
          <p>An explanation backed by evidence, a learner note, and one supported outcome:</p>
          <dl class="possible-outcomes">
            <div>
              <dt>Verified correction</dt><dd>Test and save a local workflow change.</dd>
            </div>
            <div>
              <dt>Coaching</dt><dd>Explain the behavior and the learner's next step.</dd>
            </div>
            <div>
              <dt>Handoff</dt><dd>Identify an owner and a concrete action.</dd>
            </div>
            <div>
              <dt>More evidence needed</dt><dd>Ask for the specific missing information.</dd>
            </div>
          </dl>
        </div>
      </section>

      <p :if={@notice} role="alert" id="notice" class="notice">{@notice}</p>
      <div id="investigation" class="workspace">
        <aside class="panel case-panel" aria-labelledby="case-title">
          <div class="section-heading">
            <span class="step">01</span><h3 id="case-title">Choose a report</h3><span class="count-badge">{map_size(
              @state.reports
            )} reports</span>
          </div>
          <.form for={@form} id="report-picker" phx-change="select">
            <label for="report-id">Learner's reported symptoms</label>
            <div class="select-wrap">
              <select id="report-id" name="report_id" disabled={@state.active != nil}>
                <option
                  :for={{id, report} <- Enum.sort(@state.reports)}
                  value={id}
                  selected={id == @selected}
                >
                  {report.learner_alias} — {report.text}
                </option>
              </select>
            </div>
          </.form>
          <div id="selected-report" class="learner-report">
            <div class="report-author">
              <span class="avatar" aria-hidden="true">{String.first(
                @state.reports[@selected].learner_alias
              )}</span><div>
                <strong>{@state.reports[@selected].learner_alias}</strong><span>Learner report</span>
              </div><span class="report-id">{@selected}</span>
            </div>
            <blockquote>“{@state.reports[@selected].text}”</blockquote>
            <div class="report-references">
              <span><.icon name="document" />{@state.reports[@selected].execution_ref}</span><span>{@state.reports[
                @selected
              ].workflow_id}</span>
            </div>
          </div>
          <div id="case-goal" class="case-goal">
            <strong>Goal for this report</strong>
            <p>
              Explain why {@state.reports[@selected].learner_alias}'s workflow behaved this way and determine what to do next.
            </p>
          </div>
          <div class="controls">
            <button
              id="preview"
              phx-click="preview"
              disabled={not @enabled or @state.active != nil or @completed}
              class="button secondary"
              aria-describedby="control-help"
            ><span><.icon name="preview" />Preview one decision</span><span
              class="button-key"
              aria-hidden="true"
            >01</span></button>
            <button
              id="run"
              phx-click="run"
              disabled={not @enabled or @state.active != nil or @completed}
              class="button primary"
              aria-describedby="control-help"
            ><span>Run investigation</span><.icon name="arrow" /></button>
            <p id="control-help" class="control-help">
              Preview shows one proposed decision. Run follows the evidence, executes tools, and saves the case outcome.
            </p>
            <div class="minor-controls">
              <button id="stop" phx-click="stop" disabled={@state.active == nil}><.icon name="stop" />Stop</button><button
                id="reset"
                phx-click="reset"
                disabled={@state.active != nil}
              ><.icon name="reset" />Reset demo</button>
            </div>
          </div>
          <div :if={not @enabled} class="access-note">
            <.icon name="lock" /><p>
              <strong>Live access is off</strong><span>Enable it in your local session to begin.</span>
            </p>
          </div>
          <p :if={@completed} id="completed-lock" class="hint completed-hint">
            This report is complete. Reset to investigate it again, or choose another report.
          </p>
          <div class="memory-note">
            <.icon name="clock" /><p>
              Saved for this session. Refresh keeps your work;<br />restarting the app restores the demo.
            </p>
          </div>
        </aside>

        <section class="panel investigation-panel" aria-labelledby="investigation-title">
          <div class="section-heading">
            <span class="step">02</span><h3 id="investigation-title">Investigation</h3><span
              id="run-status"
              class={["status", @run && @run.status == :active && "status-active"]}
            ><span class="dot" aria-hidden="true"></span>{if @run,
              do: @run.status,
              else: "Ready when you are"}</span>
          </div>
          <div class="metrics">
            <div>
              <span>Elapsed time</span><strong id="elapsed">{@elapsed}<small>s</small></strong>
            </div><div>
              <span>Model requests</span><strong id="request-count">{if @run,
                do: @run.request_count,
                else: 0}<small> / {if @run && @run.mode == :preview, do: 1, else: 12}</small></strong>
            </div><div>
              <span>Investigation scope</span><strong class="scope-value">One learner report</strong>
            </div>
          </div>
          <div :if={is_nil(@run)} id="empty-investigation" class="empty">
            <div class="evidence-illustration" aria-hidden="true">
              <svg viewBox="0 0 168 132" fill="none"><rect
                x="27"
                y="11"
                width="92"
                height="104"
                rx="13"
                transform="rotate(-8 27 11)"
                fill="#f0efef"
                stroke="#e7e5e5"
              /><rect x="39" y="12" width="92" height="104" rx="13" fill="white" stroke="#e4e1e1" /><path
                d="M56 35h36M56 47h57M56 59h42"
                stroke="#d9d5d5"
                stroke-width="4"
                stroke-linecap="round"
              /><rect x="54" y="77" width="25" height="19" rx="5" fill="#fbe8e8" /><path
                d="m61 86 4 4 7-8"
                stroke="#c00"
                stroke-width="1.8"
                stroke-linecap="round"
                stroke-linejoin="round"
              /><circle cx="117" cy="84" r="23" fill="#fff" stroke="#c00" stroke-width="2.5" /><path
                d="m134 101 15 15"
                stroke="#c00"
                stroke-width="5"
                stroke-linecap="round"
              /><path d="M108 84h18m-9-9v18" stroke="#c00" stroke-width="1.5" stroke-linecap="round" /></svg>
            </div>
            <h4>Find the cause.<br />Prepare a supported next step.</h4>
            <p>
              Choose a report, then select <strong>Run investigation</strong>.<br class="desktop-break" />
              The agent inspects the recorded execution and checks the course requirements.
            </p>
            <div class="workflow-map" aria-label="Investigation process">
              <div>
                <span><.icon name="search" /></span><strong>Inspect</strong><small>Read the evidence</small>
              </div><span class="workflow-connector" aria-hidden="true"></span><div>
                <span><.icon name="check" /></span><strong>Check</strong><small>Test changes if needed</small>
              </div><span class="workflow-connector" aria-hidden="true"></span><div>
                <span><.icon name="book" /></span><strong>Complete</strong><small>Save the case outcome</small>
              </div>
            </div>
          </div>
          <ol id="action-history" phx-update="stream" class="timeline">
            <li :for={{dom_id, entry} <- @streams.history} id={dom_id}>
              <span class="timeline-number">{entry.number}</span><div>
                <div class="action-heading">
                  <h4>{action_label(Map.get(entry.item, :action))}</h4><span>{Map.get(
                    entry.item,
                    :action,
                    "request"
                  )}</span>
                </div><p>
                  {Map.get(entry.item, :reason, "The provider response could not be accepted.")}
                </p><details>
                  <summary>Arguments and observed result</summary><pre>{pretty(entry.item)}</pre>
                </details>
              </div>
            </li>
          </ol>
          <div :if={@run && @run.result} id="run-result" class="outcome">
            <p class="eyebrow">
              {if @run.mode == :preview, do: "ONE DECISION · NO ACTION EXECUTED", else: "THE OUTCOME"}
            </p>
            <%= if @run.status == :completed do %>
              <h3>{outcome_label(@run.result.outcome)}</h3><p>{@run.result.summary}</p>
              <div class="learner-note">
                <span class="note-label"><.icon name="book" />Learner note</span><p>
                  {@run.result.learner_note}
                </p>
              </div>
              <div class="evidence-list">
                <span class="field-label">Evidence</span><span
                  :for={ref <- @run.result.evidence_refs}
                  class="evidence-ref"
                >{ref}</span>
              </div>
              <div :if={@run.result.requested_action} class="handoff">
                <span class="field-label">{if @run.result.escalation_owner,
                  do: @run.result.escalation_owner,
                  else: "Information requested"}</span><p>{@run.result.requested_action}</p>
              </div>
              <div :if={@run.result.before != @run.result.after} class="configuration-comparison">
                <div>
                  <span class="field-label">Before</span><pre>{pretty(@run.result.before)}</pre>
                </div><div>
                  <span class="field-label">Verified configuration</span><pre>{pretty(@run.result.after)}</pre>
                </div>
              </div>
              <p :if={@run.result.before == @run.result.after} class="unchanged">
                <.icon name="shield" />Workflow configuration unchanged
              </p>
              <details>
                <summary>Configuration, guidance, and handoff details</summary><pre>{pretty(@run.result)}</pre>
              </details>
            <% else %>
              <pre id="preview-or-error">{pretty(@run.result)}</pre>
            <% end %>
          </div>
          <div class="investigation-footnote">
            <span><.icon name="shield" />One report at a time</span><span>Up to 12 model requests · 5-minute limit</span>
          </div>
        </section>
      </div>

      <section id="session-memory" class="panel memory-panel" aria-labelledby="memory-title">
        <div class="section-heading">
          <span class="step">03</span><div>
            <h3 id="memory-title">Completed cases and internal guides</h3><p class="section-description">
              Review the explanation, learner note, evidence, and any correction or handoff saved in this session.
            </p>
          </div><span class="count-badge">{map_size(@state.cases)} cases
          <span class="count-divider">/</span> {map_size(@state.notes)} guides</span>
        </div>
        <div :if={@state.cases == %{}} class="memory-empty">
          <span class="memory-empty-icon"><.icon name="book" /></span><p>
            No completed cases yet.<span>Run an investigation to save a case outcome here.</span>
          </p>
        </div>
        <details
          :for={{id, result} <- Enum.sort(@state.cases)}
          id={"memory-" <> id}
          class="memory-entry"
        >
          <summary><span>{result.report_id}</span>{outcome_label(result.outcome)}</summary><pre>{pretty(result)}</pre>
        </details>
        <details :for={{id, note} <- Enum.sort(@state.notes)} class="memory-entry">
          <summary><span>Guide</span>{note.title}</summary><pre>{pretty(Map.put(note, :ref_id, id))}</pre>
        </details>
      </section>
      <footer>
        <span><span class="footer-mark">LF</span>Evidence-backed learner support.</span><span>Fictional teaching resources
        <span class="footer-dot">·</span>
        Local session only</span>
      </footer>
    </div>
    """
  end
end
