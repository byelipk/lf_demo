defmodule LfDemo.Codex.Client do
  @callback decide(map(), keyword()) ::
              {:ok, LfDemo.Decision.t()} | {:error, LfDemo.Codex.Error.t()}
end
