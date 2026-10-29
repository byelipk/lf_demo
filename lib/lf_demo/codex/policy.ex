defmodule LfDemo.Codex.Policy do
  @forbidden_capabilities if(Application.compile_env(:lf_demo, :test_build, false),
                            do: [:live_codex],
                            else: []
                          )
  def check(environment_setting \\ System.get_env("LF_CODEX_LIVE")) do
    cond do
      Enum.member?(@forbidden_capabilities, :live_codex) ->
        {:error,
         LfDemo.Codex.Error.new(
           :test_forbidden,
           "Live invocation is forbidden in the test build."
         )}

      environment_setting != "1" ->
        {:error, LfDemo.Codex.Error.new(:live_codex_disabled, "Live Codex disabled.")}

      true ->
        :ok
    end
  end

  def enabled?, do: check() == :ok
  def client, do: if(enabled?(), do: LfDemo.Codex.LiveClient, else: LfDemo.Codex.DisabledClient)
end
