defmodule LfDemo.Tools do
  alias LfDemo.{Store, Decision, Sandbox}

  def execute(store, key, %Decision{action: action, arguments: args, reason: reason}) do
    with :ok <- Decision.validate_arguments(action, args) do
      if action == "complete_case",
        do: Store.complete_case(store, key, args, reason),
        else: dispatch(action, args, store, key)
    end
  end

  defp dispatch("search_context", %{"query" => query}, s, k),
    do: Store.request(s, k, {:search, query})

  defp dispatch("inspect", %{"ref_id" => ref}, s, k), do: Store.request(s, k, {:inspect, ref})

  defp dispatch("test_configuration", %{"workflow_id" => id, "candidate" => candidate}, s, k) do
    with {:ok, workflow} <- Store.request(s, k, {:test_base, id}) do
      report = Sandbox.check(workflow, candidate)
      Store.save_test_report(s, k, report)
    end
  end
end
