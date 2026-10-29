defmodule LfDemo.Codex.ProcessTransport do
  @moduledoc "Owns the OS child independently of the caller; requests termination on caller death. Actual CLI termination requires manual verification."
  alias LfDemo.Codex.{Protocol, Error}

  def run(request, timeout, backend) do
    owner = self()
    tag = make_ref()
    {pid, monitor} = spawn_monitor(fn -> own(owner, tag, request, timeout, backend) end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, Error.new(:transport, "External-process owner exited.")}
    after
      timeout + 2000 ->
        send(pid, :cancel)
        {:error, Error.new(:timeout, "Transport cleanup requested after timeout.")}
    end
  end

  defp own(owner, tag, request, timeout, backend) do
    Process.flag(:trap_exit, true)
    monitor = Process.monitor(owner)

    try do
      case backend.open(request) do
        {:ok, handle} ->
          try do
            result =
              collect(
                handle,
                monitor,
                System.monotonic_time(:millisecond) + timeout,
                "",
                [],
                nil,
                request.result_path
              )

            send(owner, {tag, result})
          after
            backend.close(handle)
          end

        error ->
          send(owner, {tag, error})
      end
    rescue
      e ->
        send(
          owner,
          {tag,
           {:error,
            Error.new(:transport, "External-process transport failed.", %{
              exception: inspect(e.__struct__)
            })}}
        )
    after
      File.rm_rf(request.cwd)
    end
  end

  defp collect(port, monitor, deadline, buffer, events, invalid, result_path) do
    receive do
      {^port, {:data, chunk}} ->
        if byte_size(buffer) + byte_size(chunk) > 131_072 do
          {:error, Error.new(:protocol, "Transport event exceeds the bounded buffer.")}
        else
          parts = String.split(buffer <> chunk, "\n")
          {complete, [tail]} = Enum.split(parts, -1)

          {events, invalid} =
            Enum.reduce(complete, {events, invalid}, fn line, {acc, error} ->
              case Protocol.event(line) do
                :ok -> {acc, error}
                {:error, e} -> {acc, error || e}
              end
            end)

          collect(port, monitor, deadline, tail, events, invalid, result_path)
        end

      {^port, {:exit_status, status}} ->
        invalid =
          if buffer != "" do
            case Protocol.event(buffer) do
              :ok -> invalid
              {:error, e} -> invalid || e
            end
          else
            invalid
          end

        raw =
          case File.open(result_path, [:read, :binary]) do
            {:ok, file} ->
              data = IO.binread(file, 65_537)
              File.close(file)
              if is_binary(data), do: data, else: ""

            _ ->
              ""
          end

        cond do
          invalid ->
            {:error,
             %{
               invalid
               | details: Map.put(invalid.details, :final_response, Protocol.bounded(raw))
             }}

          status != 0 ->
            {:error,
             Error.new(:transport, "Codex exited unsuccessfully.", %{
               exit_status: status,
               final_response: Protocol.bounded(raw)
             })}

          raw == "" ->
            {:error, Error.new(:protocol, "No final response file was produced.")}

          true ->
            {:ok, raw, events}
        end

      {:DOWN, ^monitor, :process, _, _} ->
        {:error, Error.new(:cancelled, "Request owner exited; OS cleanup requested.")}

      {:EXIT, ^port, reason} when reason != :normal ->
        {:error, Error.new(:transport, "External port exited unexpectedly.")}

      {:EXIT, ^port, :normal} ->
        collect(port, monitor, deadline, buffer, events, invalid, result_path)

      :cancel ->
        {:error, Error.new(:cancelled, "OS cleanup requested.")}
    after
      max(0, deadline - System.monotonic_time(:millisecond)) ->
        {:error, Error.new(:timeout, "Codex request timed out; OS cleanup requested.")}
    end
  end
end
