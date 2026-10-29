defmodule LfDemo.Application do
  use Application
  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: LfDemo.PubSub},
      LfDemo.RuntimeSupervisor,
      LfDemoWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: LfDemo.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed),
    do: LfDemoWeb.Endpoint.config_change(changed, removed)
end
