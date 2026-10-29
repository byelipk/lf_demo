defmodule LfDemoWeb.TestDemoLive do
  @moduledoc false
  use LfDemoWeb, :live_view
  alias LfDemoWeb.DemoLive

  def mount(params, %{"store" => store, "owner" => owner} = session, socket) do
    # Server-side test harness; no production route or user-selected client module.
    if self() != owner, do: Mox.allow(LfDemo.Codex.ClientMock, owner, self())

    options = [
      before_worker: fn pid -> Mox.allow(LfDemo.Codex.ClientMock, owner, pid) end,
      before_request: fn pid -> Mox.allow(LfDemo.Codex.ClientMock, owner, pid) end
    ]

    socket =
      Phoenix.Component.assign(socket,
        store: store,
        client: LfDemo.Codex.ClientMock,
        operation_options: options
      )

    DemoLive.mount(params, session, socket)
  end

  defdelegate handle_event(event, params, socket), to: DemoLive
  defdelegate handle_info(message, socket), to: DemoLive
  defdelegate render(assigns), to: DemoLive
end
