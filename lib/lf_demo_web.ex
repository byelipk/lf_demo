defmodule LfDemoWeb do
  def live_view do
    quote do
      use Phoenix.LiveView, layout: {LfDemoWeb.Layouts, :app}
      import Phoenix.Component
    end
  end

  defmacro __using__(which), do: apply(__MODULE__, which, [])
end
