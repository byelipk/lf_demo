defmodule LfDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :lf_demo,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application,
    do: [mod: {LfDemo.Application, []}, extra_applications: [:logger, :runtime_tools, :crypto]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:phoenix, "~> 1.8.16"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.3"},
      {:bandit, "~> 1.8"},
      {:jason, "~> 1.4"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:mox, "~> 1.2", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp aliases,
    do: [
      setup: ["deps.get", "assets.setup", "assets.build"],
      "assets.setup": ["esbuild.install --if-missing"],
      "assets.build": ["esbuild lf_demo"]
    ]
end
