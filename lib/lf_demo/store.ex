defmodule LfDemo.Store do
  use GenServer
  alias LfDemo.{Seed, Sandbox, Decision}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  def snapshot(store \\ __MODULE__), do: GenServer.call(store, :snapshot)
  def start_run(store, report, mode \\ :run), do: GenServer.call(store, {:start, report, mode})
  def attach(store, key, pid), do: GenServer.call(store, {:attach, key, pid})
  def stop_run(store \\ __MODULE__), do: GenServer.call(store, :stop)
  def reset(store \\ __MODULE__), do: GenServer.call(store, :reset)
  def request(store, key, operation), do: GenServer.call(store, {:request, key, operation})

  def complete_case(store, key, args, reason \\ "Completion validated atomically"),
    do: request(store, key, {:complete, args, reason})

  def append_observation(store, key, observation),
    do: request(store, key, {:observation, observation})

  def save_test_report(store, key, report), do: request(store, key, {:save_test, report})
  def finish(store, key, status, result), do: request(store, key, {:finish, status, result})
  def key(run), do: {run.generation, run.id, run.token}
  def topic, do: "lf_demo:state"

  @impl true
  def init(opts) do
    state = Map.put(Seed.state(), :notify, Keyword.get(opts, :notify))
    changed(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:snapshot, _, s), do: {:reply, Map.drop(s, [:notify]), s}

  def handle_call({:start, report, mode}, _, s) do
    cond do
      s.active != nil ->
        {:reply, {:error, :operation_active}, s}

      not Map.has_key?(s.reports, report) ->
        {:reply, {:error, :unknown_report}, s}

      Map.has_key?(s.cases, report) ->
        {:reply, {:error, :report_completed_reset_required}, s}

      mode not in [:run, :preview] ->
        {:reply, {:error, :invalid_mode}, s}

      true ->
        id = "run:" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

        run = %{
          id: id,
          generation: s.generation,
          token: make_ref(),
          report_id: report,
          mode: mode,
          status: :active,
          started_at: System.monotonic_time(:millisecond),
          finished_at: nil,
          request_count: 0,
          history: [],
          disclosed: MapSet.new(),
          failed_inspections: MapSet.new(),
          result: nil
        }

        s = %{
          s
          | runs: Map.put(s.runs, id, run),
            active: %{key: key(run), pid: nil, monitor: nil}
        }

        changed(s)
        {:reply, {:ok, run}, s}
    end
  end

  def handle_call({:attach, key, pid}, _, s) do
    if active?(s, key) and is_nil(s.active.pid) do
      s = put_in(s.active, %{key: key, pid: pid, monitor: Process.monitor(pid)})
      {:reply, :ok, s}
    else
      Process.exit(pid, :kill)
      {:reply, {:error, :inactive_run}, s}
    end
  end

  def handle_call(:stop, _, %{active: nil} = s), do: {:reply, {:error, :already_finished}, s}

  def handle_call(:stop, _, s) do
    {_, id, _} = s.active.key
    if s.active.pid, do: Process.exit(s.active.pid, :kill)
    s = finalize(s, id, :stopped, %{message: "Stopped; late results cannot commit."})
    changed(s)
    {:reply, :ok, s}
  end

  def handle_call(:reset, _, %{active: nil} = s) do
    s = Map.put(Seed.state(), :notify, s.notify)
    changed(s)
    {:reply, :ok, s}
  end

  def handle_call(:reset, _, s), do: {:reply, {:error, :operation_active}, s}

  def handle_call({:request, key, operation}, _, s) do
    if active?(s, key) do
      {_, id, _} = key
      {reply, next} = apply_operation(operation, id, s)
      if next != s, do: changed(next)
      {:reply, reply, next}
    else
      {:reply, {:error, :inactive_run}, s}
    end
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{active: %{monitor: ref, key: {_, id, _}}} = s
      ) do
    s =
      finalize(s, id, :failed, %{
        message: "Investigation worker exited",
        reason: inspect(reason, limit: 10)
      })

    changed(s)
    {:noreply, s}
  end

  def handle_info(_, s), do: {:noreply, s}

  defp active?(%{active: %{key: key}}, key), do: true
  defp active?(_, _), do: false

  defp apply_operation(:context, id, s) do
    run = s.runs[id]
    {{:ok, %{run: run, report: s.reports[run.report_id]}}, s}
  end

  defp apply_operation(:count_request, id, s),
    do: {:ok, update_in(s.runs[id].request_count, &(&1 + 1))}

  defp apply_operation({:observation, observation}, id, s),
    do: {:ok, update_in(s.runs[id].history, &(&1 ++ [observation]))}

  defp apply_operation({:finish, status, result}, id, s) when status in [:failed, :previewed],
    do: {:ok, finalize(s, id, status, result)}

  defp apply_operation({:inspect, ref}, id, s) do
    case lookup(s, ref) do
      nil ->
        failure_ref =
          "inspection:" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

        failure = %{
          ref_id: failure_ref,
          attempted_ref: ref,
          run_id: id,
          error: "unknown_reference"
        }

        s = %{s | inspection_failures: Map.put(s.inspection_failures, failure_ref, failure)}
        s = update_in(s.runs[id].failed_inspections, &MapSet.put(&1, ref))
        s = update_in(s.runs[id].disclosed, &MapSet.put(&1, failure_ref))
        {{:error, %{code: :unknown_reference, ref_id: ref, failure_ref: failure_ref}}, s}

      value ->
        s = update_in(s.runs[id].disclosed, &MapSet.put(&1, ref))
        {{:ok, %{ref_id: ref, value: value}}, s}
    end
  end

  defp apply_operation({:search, query}, id, s) do
    terms = query |> String.downcase() |> String.split(~r/\W+/, trim: true)

    sources =
      Enum.flat_map(
        [s.documents, s.reports, s.notes, Map.new(s.cases, fn {_k, v} -> {v.ref_id, v} end)],
        &Enum.to_list/1
      )

    matches =
      sources
      |> Enum.filter(fn {_, v} ->
        text = String.downcase(inspect(v))
        Enum.any?(terms, &String.contains?(text, &1))
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.take(5)

    snippets =
      Enum.map(matches, fn {ref, value} ->
        %{ref_id: ref, snippet: String.slice(inspect(value), 0, 900)}
      end)

    s =
      update_in(s.runs[id].disclosed, fn refs ->
        Enum.reduce(matches, refs, fn {ref, _}, acc -> MapSet.put(acc, ref) end)
      end)

    {{:ok, snippets}, s}
  end

  defp apply_operation({:test_base, workflow}, id, s) do
    if s.reports[s.runs[id].report_id].workflow_id == workflow,
      do: {{:ok, s.workflows[workflow]}, s},
      else: {{:error, :wrong_workflow}, s}
  end

  defp apply_operation({:save_test, report}, id, s) do
    workflow = s.reports[s.runs[id].report_id].workflow_id

    if report.workflow_id == workflow and report.fixture_version == s.fixture_version and
         report.base_revision == s.workflows[workflow].revision do
      ref = "test:" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

      report =
        Map.merge(report, %{
          ref_id: ref,
          run_id: id,
          generation: s.generation,
          token: s.runs[id].token
        })

      s =
        %{s | tests: Map.put(s.tests, ref, report)}
        |> update_in([:runs, id, :disclosed], &MapSet.put(&1, ref))

      {{:ok, report}, s}
    else
      {{:error, :stale_or_wrong_test}, s}
    end
  end

  defp apply_operation({:complete, args, reason}, id, s) do
    with :ok <- Decision.validate_arguments("complete_case", args),
         :ok <- completion_preconditions(s, id, args) do
      {result, next} = commit(s, id, args)

      next =
        update_in(
          next.runs[id].history,
          &(&1 ++
              [%{action: "complete_case", arguments: args, reason: reason, result: {:ok, result}}])
        )

      {{:ok, result}, finalize(next, id, :completed, result)}
    else
      {:error, reason} -> {{:error, reason}, s}
    end
  end

  defp completion_preconditions(s, id, a) do
    run = s.runs[id]
    report = s.reports[run.report_id]
    refs = a["evidence_refs"]
    inspected = MapSet.member?(run.disclosed, report.execution_ref)

    failed =
      Enum.any?(refs, fn ref ->
        case s.inspection_failures[ref] do
          %{run_id: ^id, attempted_ref: execution} -> execution == report.execution_ref
          _ -> false
        end
      end)

    evidence_valid =
      Enum.all?(refs, &(MapSet.member?(run.disclosed, &1) and lookup(s, &1) != nil))

    cond do
      run.mode != :run ->
        {:error, :preview_cannot_complete}

      not evidence_valid ->
        {:error, :undisclosed_evidence}

      not inspected and not (a["outcome"] == "needs_information" and failed) ->
        {:error, :execution_not_inspected}

      a["outcome"] != "needs_information" and report.execution_ref not in refs ->
        {:error, :execution_evidence_required}

      true ->
        outcome_preconditions(s, run, report, a)
    end
  end

  defp outcome_preconditions(s, run, report, %{"outcome" => "verified_in_sandbox"} = a) do
    t = s.tests[a["test_report_id"]]
    w = s.workflows[report.workflow_id]

    cond do
      is_nil(t) ->
        {:error, :test_required}

      t.run_id != run.id or t.token != run.token or t.generation != s.generation ->
        {:error, :wrong_run_test}

      t.workflow_id != report.workflow_id or w.owner != "instructor" ->
        {:error, :wrong_workflow_test}

      not t.all_passed or not t.verifiable ->
        {:error, :passing_verifiable_test_required}

      t.base_revision != w.revision ->
        {:error, :stale_revision}

      t.fixture_version != s.fixture_version ->
        {:error, :stale_fixtures}

      t.candidate == w.config ->
        {:error, :configuration_unchanged}

      not present?(a["guide_title"]) or not present?(a["guide_body"]) ->
        {:error, :guide_required}

      a["test_report_id"] not in a["evidence_refs"] ->
        {:error, :test_evidence_required}

      true ->
        :ok
    end
  end

  defp outcome_preconditions(s, _run, _report, %{"outcome" => "coaching_prepared"} = a) do
    if Enum.any?(a["evidence_refs"], &Map.has_key?(s.documents, &1)),
      do: :ok,
      else: {:error, :course_document_required}
  end

  defp outcome_preconditions(_, _, _, %{"outcome" => "escalation_prepared"} = a) do
    if present?(a["escalation_owner"]) and present?(a["requested_action"]),
      do: :ok,
      else: {:error, :handoff_required}
  end

  defp outcome_preconditions(_, _, _, %{"outcome" => "needs_information"} = a) do
    if present?(a["requested_action"]), do: :ok, else: {:error, :missing_fact_required}
  end

  defp present?(s), do: is_binary(s) and String.trim(s) != ""

  defp commit(s, id, a) do
    report = s.reports[s.runs[id].report_id]
    w = s.workflows[report.workflow_id]

    result = %{
      ref_id: "case:" <> id,
      report_id: report.report_id,
      outcome: a["outcome"],
      summary: a["summary"],
      evidence_refs: a["evidence_refs"],
      learner_note: a["learner_note"],
      before: w.config,
      after: w.config,
      guide_ref: nil,
      escalation_owner: a["escalation_owner"],
      requested_action: a["requested_action"]
    }

    {result, s} =
      if a["outcome"] == "verified_in_sandbox" do
        t = s.tests[a["test_report_id"]]
        w = %{w | config: t.candidate, revision: w.revision + 1}
        guide_ref = "note:" <> w.workflow_id <> ":" <> Sandbox.hash(t.candidate)

        guide = %{
          ref_id: guide_ref,
          workflow_id: w.workflow_id,
          configuration_hash: t.candidate_hash,
          title: a["guide_title"],
          body: a["guide_body"],
          evidence_refs: a["evidence_refs"]
        }

        {%{result | after: w.config, guide_ref: guide_ref},
         %{
           s
           | workflows: Map.put(s.workflows, w.workflow_id, w),
             revisions: Map.put(s.revisions, "#{w.workflow_id}@#{w.revision}", w),
             notes: Map.put_new(s.notes, guide_ref, guide)
         }}
      else
        {result, s}
      end

    s =
      if a["outcome"] == "escalation_prepared",
        do: %{s | escalations: Map.put(s.escalations, result.ref_id, result)},
        else: s

    {result, %{s | cases: Map.put(s.cases, report.report_id, result)}}
  end

  defp lookup(s, ref) do
    value =
      Enum.find_value(
        [
          s.documents,
          s.reports,
          s.executions,
          s.workflows,
          s.revisions,
          s.tests,
          s.notes,
          s.inspection_failures
        ],
        &Map.get(&1, ref)
      ) || Enum.find_value(s.cases, fn {_, v} -> if v.ref_id == ref, do: v end)

    if Map.has_key?(s.executions, ref),
      do:
        Map.put(
          value,
          :current_workflow_ref,
          "#{value.workflow_id}@#{s.workflows[value.workflow_id].revision}"
        ),
      else: value
  end

  defp finalize(s, id, status, result) do
    if s.active && s.active.monitor, do: Process.demonitor(s.active.monitor, [:flush])

    s =
      update_in(
        s.runs[id],
        &%{&1 | status: status, result: result, finished_at: System.monotonic_time(:millisecond)}
      )

    %{s | active: nil}
  end

  defp changed(s) do
    Phoenix.PubSub.broadcast(LfDemo.PubSub, topic(), :store_updated)
    if s.notify, do: send(s.notify, {:store_updated, self()})
    :ok
  end
end
