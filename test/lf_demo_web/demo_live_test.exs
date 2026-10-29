defmodule LfDemoWeb.DemoLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Mox
  import LfDemo.TestHelpers
  alias LfDemo.{Store, Decision}
  alias LfDemo.Codex.ClientMock
  @endpoint LfDemoWeb.Endpoint
  setup :verify_on_exit!

  setup do
    Store.stop_run()
    Store.reset()
    %{conn: build_conn()}
  end

  test "normal page is default-off, includes four reports, reconnects without a provider call", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#provider-state", "Live Codex disabled")
    assert has_element?(view, "#preview[disabled]")
    assert has_element?(view, "#run[disabled]")
    assert has_element?(view, "#stop[disabled]")
    assert has_element?(view, "#report-id option[value='report:r107']")
    {:ok, run} = Store.start_run(Store, "report:r104")

    Store.append_observation(Store, Store.key(run), %{
      action: "inspect",
      reason: "Existing evidence",
      arguments: %{"ref_id" => "document:d01"},
      result: {:ok, "preserved"}
    })

    Store.stop_run()
    {:ok, refreshed, _} = live(build_conn(), "/")
    assert has_element?(refreshed, "#run-status", "stopped")
    assert has_element?(refreshed, "#action-history li", "Existing evidence")
    assert map_size(Store.snapshot().runs) == 1
  end

  test "picker uses symptoms and does not start an operation", %{conn: conn} do
    {:ok, view, _} = live(conn, "/")
    view |> form("#report-picker", %{"report_id" => "report:r107"}) |> render_change()
    assert has_element?(view, "#selected-report", "Can I use the fix from the other thread?")
    assert Store.snapshot().active == nil
    assert Store.snapshot().runs == %{}
  end

  test "offline preview uses Mox exactly once, displays raw final response, and executes no action",
       %{conn: conn} do
    store = start_supervised!({Store, notify: self()})
    parent = self()

    expect(ClientMock, :decide, fn _, _ ->
      send(parent, :preview_called)
      d = decision("inspect", %{"ref_id" => "execution:e201"})

      {:ok,
       %Decision{d | metadata: %{final_response: "synthetic/documentation-derived final JSON"}}}
    end)

    {:ok, view, _} =
      live_isolated(conn, LfDemoWeb.TestDemoLive, session: %{"store" => store, "owner" => self()})

    view |> element("#preview") |> render_click()
    assert_receive :preview_called
    await_state(store, &is_nil(&1.active))
    send(view.pid, :store_updated)
    assert has_element?(view, "#preview-or-error", "synthetic/documentation-derived final JSON")
    state = Store.snapshot(store)
    [run] = Map.values(state.runs)
    assert run.status == :previewed
    assert run.disclosed == MapSet.new()
    assert state.tests == %{}
  end

  test "offline UI Stop remains responsive while a Mox request is pending", %{conn: conn} do
    store = start_supervised!({Store, notify: self()})
    parent = self()

    expect(ClientMock, :decide, fn _, _ ->
      send(parent, :pending_request)

      receive do
        :never -> {:error, :unreachable}
      end
    end)

    {:ok, view, _} =
      live_isolated(conn, LfDemoWeb.TestDemoLive, session: %{"store" => store, "owner" => self()})

    view |> element("#run") |> render_click()
    assert_receive :pending_request
    send(view.pid, :store_updated)
    assert has_element?(view, "#reset[disabled]")
    view |> element("#stop") |> render_click()
    assert has_element?(view, "#run-status", "stopped")
    assert Store.snapshot(store).active == nil
    view |> element("#reset") |> render_click()
    assert Store.snapshot(store).runs == %{}
  end

  test "refresh reopens an existing active non-default report without starting another operation",
       %{conn: conn} do
    {:ok, run} = Store.start_run(Store, "report:r107")
    {:ok, view, _} = live(conn, "/")
    assert has_element?(view, "#report-id option[value='report:r107'][selected]")
    assert has_element?(view, "#report-id[disabled]")
    assert has_element?(view, "#selected-report", "Morgan")
    assert has_element?(view, "#run-status", "active")
    assert Store.snapshot().active.key == Store.key(run)
    assert map_size(Store.snapshot().runs) == 1
  end
end
