defmodule LfDemo.Codex.LiveClient do
  @behaviour LfDemo.Codex.Client
  alias LfDemo.Codex.{Policy, Protocol, Error}
  @impl true
  def decide(context, opts) do
    with :ok <- Policy.check() do
      dir =
        Path.join(
          System.tmp_dir!(),
          "lf-demo-query-" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
        )

      case File.mkdir(dir) do
        :ok ->
          invoke(context, dir, opts)

        {:error, reason} ->
          {:error,
           Error.new(:transport, "Could not create query directory.", %{reason: inspect(reason)})}
      end
    end
  end

  defp invoke(context, dir, opts) do
    try do
      request =
        Protocol.request(context, dir,
          executable: System.get_env("LF_CODEX_BIN") || "codex",
          model: System.get_env("LF_CODEX_MODEL")
        )

      File.write!(request.schema_path, Jason.encode!(Protocol.schema()))
      transport = Keyword.get(opts, :transport, LfDemo.Codex.PortTransport)
      # Recheck immediately before the external boundary; no mock/error fallback exists.
      with :ok <- Policy.check(),
           {:ok, raw, events} <-
             transport.run(request, min(Keyword.get(opts, :timeout, 60_000), 60_000)) do
        Protocol.normalize(raw, events)
      end
    rescue
      e ->
        {:error,
         Error.new(:transport, "Codex transport failed.", %{exception: e.__struct__ |> inspect()})}
    after
      # This path is freshly generated above; no caller-controlled cleanup path.
      File.rm_rf(dir)
    end
  end
end
