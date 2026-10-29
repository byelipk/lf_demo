defmodule LfDemo.Codex.DisabledClient do
  @behaviour LfDemo.Codex.Client
  @impl true
  def decide(_, _),
    do:
      {:error,
       LfDemo.Codex.Error.new(
         :live_codex_disabled,
         "Live Codex disabled. Enable it only in your later manual session."
       )}
end
