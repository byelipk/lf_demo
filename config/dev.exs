import Config

config :lf_demo, LfDemoWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4000")],
  server: true,
  code_reloader: false,
  check_origin: ["//localhost", "//127.0.0.1"],
  watchers: [esbuild: {Esbuild, :install_and_run, [:lf_demo, ~w(--watch)]}]
