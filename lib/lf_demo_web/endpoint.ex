defmodule LfDemoWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :lf_demo

  @session_options [
    store: :cookie,
    key: "_lf_demo_key",
    signing_salt: "fictional-demo",
    same_site: "Lax"
  ]
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: false

  plug Plug.Static, at: "/", from: :lf_demo, gzip: false, only: ~w(assets favicon.ico favicon.svg)
  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug LfDemoWeb.Router
end
