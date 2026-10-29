defmodule LfDemo.ProcessTransportTest do
  use ExUnit.Case, async: true
  alias LfDemo.Codex.{ProcessTransport, Error}
  @moduletag :synthetic_documentation_derived
  defmodule SyntheticBackend do
    def open(request) do
      handle = {request.test_owner, make_ref()}
      send(request.test_owner, {:synthetic_opened, self(), handle})
      {:ok, handle}
    end

    def close({test_owner, _} = handle), do: send(test_owner, {:cleanup_requested, handle})
  end

  setup do
    directory =
      Path.join(
        System.tmp_dir!(),
        "lf-demo-synthetic-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir!(directory)
    on_exit(fn -> File.rm_rf(directory) end)

    %{
      request: %{
        cwd: directory,
        result_path: Path.join(directory, "final.json"),
        test_owner: self()
      }
    }
  end

  test "caller death requests external cleanup and removes only query artifacts", %{
    request: request
  } do
    caller = spawn(fn -> ProcessTransport.run(request, 10_000, SyntheticBackend) end)
    assert_receive {:synthetic_opened, owner, handle}
    monitor = Process.monitor(owner)
    Process.exit(caller, :kill)
    assert_receive {:cleanup_requested, ^handle}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    refute File.exists?(request.cwd)
  end

  test "timeout requests cleanup without spawning an OS process", %{request: request} do
    parent = self()
    spawn(fn -> send(parent, {:result, ProcessTransport.run(request, 25, SyntheticBackend)}) end)
    assert_receive {:synthetic_opened, _, handle}
    assert_receive {:cleanup_requested, ^handle}
    assert_receive {:result, {:error, %Error{kind: :timeout}}}
  end

  test "synthetic stream is validated and discarded separately from the final file", %{
    request: request
  } do
    parent = self()

    raw =
      ~s({"action":"inspect","reason":"Read evidence.","arguments":{"ref_id":"execution:e201"}})

    File.write!(request.result_path, raw)

    spawn(fn ->
      send(parent, {:result, ProcessTransport.run(request, 1000, SyntheticBackend)})
    end)

    assert_receive {:synthetic_opened, owner, handle}

    send(
      owner,
      {handle,
       {:data, ~s({"type":"item.completed","item":{"type":"reasoning","text":"private"}}\n)}}
    )

    send(owner, {handle, {:exit_status, 0}})
    assert_receive {:result, {:ok, ^raw, []}}
    assert_receive {:cleanup_requested, ^handle}
  end

  test "native tool events invalidate synthetic response and still clean up", %{request: request} do
    parent = self()
    File.write!(request.result_path, "{}")

    spawn(fn ->
      send(parent, {:result, ProcessTransport.run(request, 1000, SyntheticBackend)})
    end)

    assert_receive {:synthetic_opened, owner, handle}

    send(
      owner,
      {handle,
       {:data,
        ~s({"type":"item.started","item":{"type":"command_execution","command":"redacted"}}\n)}}
    )

    send(owner, {handle, {:exit_status, 0}})
    assert_receive {:result, {:error, %Error{kind: :unexpected_native_tool}}}
    assert_receive {:cleanup_requested, ^handle}
  end
end
