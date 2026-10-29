defmodule LfDemo.Seed do
  alias LfDemo.Sandbox

  def state do
    correct = %{"answer_path" => "result.answer", "missing_behavior" => "needs_review"}

    workflows =
      for {id, config, http, payload} <- [
            {"workflow:w17", %{"answer_path" => "answer", "missing_behavior" => "empty"}, 200,
             %{
               "result" => %{"answer" => "Route this request to the support queue."},
               "request_id" => "req-017"
             }},
            {"workflow:w23", correct, 200, %{"result" => %{}, "request_id" => "req-023"}},
            {"workflow:w31", correct, 403,
             %{"error" => "insufficient_permission", "request_id" => "req-031"}}
          ],
          into: %{} do
        {id,
         %{
           workflow_id: id,
           revision: 1,
           owner: "instructor",
           config: config,
           http_status: http,
           payload: payload
         }}
      end

    reports =
      for {id, learner, text, execution, workflow} <- [
            {"report:r104", "River",
             "My run is green, but the final answer is empty. Is my prompt wrong?",
             "execution:e201", "workflow:w17"},
            {"report:r105", "Alex",
             "The last step gets an empty answer even though the API succeeded.",
             "execution:e202", "workflow:w17"},
            {"report:r106", "Sam",
             "The answer is blank and the run says needs_review. I thought every successful run should give me an answer.",
             "execution:e203", "workflow:w23"},
            {"report:r107", "Morgan",
             "I also get an empty answer. Can I use the fix from the other thread?",
             "execution:e204", "workflow:w31"}
          ],
          into: %{} do
        {id,
         %{
           report_id: id,
           learner_alias: learner,
           text: text,
           execution_ref: execution,
           workflow_id: workflow
         }}
      end

    executions =
      for {_, r} <- reports, into: %{} do
        w = workflows[r.workflow_id]

        {r.execution_ref,
         %{
           ref_id: r.execution_ref,
           http_status: w.http_status,
           raw_payload: w.payload,
           configuration: w.config,
           output: Sandbox.execute(w.http_status, w.payload, w.config),
           recorded_workflow_ref: "#{w.workflow_id}@1",
           workflow_id: w.workflow_id
         }}
      end

    documents = %{
      "document:d01" => %{
        title: "Assignment brief",
        body:
          "Extract a nonempty textual answer from the API response and pass it to the next workflow step. If no usable answer exists, return status needs_review and answer null."
      },
      "document:d02" => %{
        title: "Troubleshooting reference",
        body:
          "Compare raw response, selected field path, output, and connector status. Test candidate changes with valid, missing, empty, and non-string answers."
      },
      "document:d03" => %{
        title: "Support guidance",
        body:
          "Help learners observe and diagnose. Route access issues to the course infrastructure owner. These are fictional teaching resources, not BU policy."
      }
    }

    %{
      generation: make_ref(),
      reports: reports,
      workflows: workflows,
      revisions: Map.new(workflows, fn {id, w} -> {"#{id}@1", w} end),
      executions: executions,
      documents: documents,
      runs: %{},
      tests: %{},
      inspection_failures: %{},
      cases: %{},
      notes: %{},
      escalations: %{},
      active: nil,
      fixture_version: Sandbox.fixture_version()
    }
  end
end
