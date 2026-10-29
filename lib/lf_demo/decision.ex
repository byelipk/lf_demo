defmodule LfDemo.Decision do
  @enforce_keys [:action, :reason, :arguments]
  defstruct [:action, :reason, :arguments, metadata: %{}]

  @type t :: %__MODULE__{
          action: String.t(),
          reason: String.t(),
          arguments: map(),
          metadata: map()
        }
  @actions ["search_context", "inspect", "test_configuration", "complete_case"]
  @fields ~w(outcome summary evidence_refs learner_note test_report_id guide_title guide_body escalation_owner requested_action)
  def actions, do: @actions

  def validate(%{"action" => action, "reason" => reason, "arguments" => args} = value)
      when map_size(value) == 3 and action in @actions and is_binary(reason) and is_map(args) do
    with true <- String.length(reason) in 1..240,
         :ok <- validate_arguments(action, args) do
      {:ok, %__MODULE__{action: action, reason: reason, arguments: args}}
    else
      _ -> {:error, :invalid_decision}
    end
  end

  def validate(_), do: {:error, :invalid_decision}

  def validate_arguments("search_context", %{"query" => q} = a)
      when map_size(a) == 1 and is_binary(q) and byte_size(q) in 1..500, do: :ok

  def validate_arguments("inspect", %{"ref_id" => ref} = a)
      when map_size(a) == 1 and is_binary(ref) and byte_size(ref) in 1..160, do: :ok

  def validate_arguments("test_configuration", %{"workflow_id" => w, "candidate" => c} = a)
      when map_size(a) == 2 and is_binary(w), do: LfDemo.Sandbox.validate_config(c)

  def validate_arguments("complete_case", a) do
    valid =
      Enum.sort(Map.keys(a)) == Enum.sort(@fields) and
        a["outcome"] in ~w(verified_in_sandbox coaching_prepared escalation_prepared needs_information) and
        Enum.all?(~w(summary learner_note), &text?(a[&1])) and
        is_list(a["evidence_refs"]) and length(a["evidence_refs"]) in 1..20 and
        Enum.all?(a["evidence_refs"], &is_binary/1) and
        Enum.all?(
          ~w(test_report_id guide_title guide_body escalation_owner requested_action),
          &(is_nil(a[&1]) or text?(a[&1]))
        )

    if valid, do: :ok, else: {:error, :invalid_completion_arguments}
  end

  def validate_arguments(_, _), do: {:error, :invalid_arguments}
  defp text?(s), do: is_binary(s) and byte_size(s) <= 8000 and String.trim(s) != ""
end
