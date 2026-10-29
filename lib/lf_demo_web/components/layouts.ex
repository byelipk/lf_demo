defmodule LfDemoWeb.Layouts do
  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>LF Troubleshooting Agent</title>
        <meta name="theme-color" content="#cc0000" />
        <meta
          name="description"
          content="Investigate a learner's course workflow, explain an unexpected result, and prepare an evidence-backed correction, coaching note, handoff, or request for information."
        />
        <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
        <link rel="stylesheet" href="/assets/app.css" />
        <script defer phx-track-static type="text/javascript" src="/assets/app.js">
        </script>
      </head>
      <body>{@inner_content}</body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <main>{@inner_content}</main>
    """
  end
end
