defmodule LfDemo.Codex.PortBackend do
  alias LfDemo.Codex.{Policy, Error}

  def open(request) do
    with :ok <- Policy.check() do
      executable = System.find_executable(request.executable)

      if executable do
        port =
          Port.open({:spawn_executable, String.to_charlist(executable)}, [
            :binary,
            :exit_status,
            :use_stdio,
            # Codex reads piped stdin before starting, even with an argv prompt.
            # We only receive stdout; :in gives the child EOF on stdin.
            :in,
            # Keep CLI diagnostics on stderr, outside the JSONL protocol stream.
            :hide,
            args: request.args,
            cd: request.cwd
          ])

        {:ok, port}
      else
        {:error, Error.new(:transport, "Codex executable was not found.")}
      end
    end
  end

  def close(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        # No shell; request child termination even if the calling BEAM task died.
        System.cmd("/bin/kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)
        System.cmd("/bin/kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        if Port.info(port), do: Port.close(port)

      _ ->
        :ok
    end
  end
end
