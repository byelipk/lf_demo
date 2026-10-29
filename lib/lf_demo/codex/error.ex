defmodule LfDemo.Codex.Error do
  @enforce_keys [:kind, :message]
  defstruct [:kind, :message, details: %{}]
  @type t :: %__MODULE__{kind: atom(), message: String.t(), details: map()}
  @kinds [
    :live_codex_disabled,
    :test_forbidden,
    :invalid_json,
    :invalid_decision,
    :timeout,
    :cancelled,
    :transport,
    :unexpected_native_tool,
    :protocol,
    :budget_exhausted
  ]
  def new(kind, message, details \\ %{}) when kind in @kinds,
    do: %__MODULE__{kind: kind, message: message, details: details}
end
