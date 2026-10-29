defmodule LfDemo.Codex.PortTransport do
  alias LfDemo.Codex.{Policy, ProcessTransport, PortBackend}

  def run(request, timeout) do
    with :ok <- Policy.check(), do: ProcessTransport.run(request, timeout, PortBackend)
  end
end
