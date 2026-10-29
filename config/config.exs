import Config

config :lf_demo, LfDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [html: LfDemoWeb.ErrorHTML], layout: false],
  pubsub_server: LfDemo.PubSub,
  live_view: [signing_salt: "local-demo-salt"],
  secret_key_base: String.duplicate("local-synthetic-demo-secret-", 4)

config :phoenix, :json_library, Jason

config :esbuild,
  version: "0.25.12",
  lf_demo: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :lf_demo, :test_build, config_env() == :test
import_config "#{config_env()}.exs"
