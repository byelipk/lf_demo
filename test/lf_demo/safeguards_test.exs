defmodule LfDemo.SafeguardsTest do
  use ExUnit.Case, async: true
  alias LfDemo.Codex.{DisabledClient, LiveClient, Policy, PortBackend, PortTransport, Error}

  defmodule ForbiddenTransport do
    def run(_, _), do: raise("No real transport is permitted in this test")
  end

  test "disabled development client never calls a transport or falls back" do
    assert {:error, %Error{kind: :live_codex_disabled}} =
             DisabledClient.decide(%{}, transport: ForbiddenTransport)

    assert Policy.client() == DisabledClient
  end

  test "test-build guard refuses every real boundary, including a simulated inherited opt-in" do
    # Pass the inherited setting as data; never set LF_CODEX_LIVE during the build.
    assert {:error, %Error{kind: :test_forbidden}} = Policy.check("1")

    assert {:error, %Error{kind: :test_forbidden}} =
             LiveClient.decide(%{}, transport: ForbiddenTransport)

    assert {:error, %Error{kind: :test_forbidden}} = PortTransport.run(%{}, 100)
    assert {:error, %Error{kind: :test_forbidden}} = PortBackend.open(%{})
  end
end
