defmodule Loopex.LLM.ReqLLM.CredentialRegistryTest do
  @moduledoc """
  ## Concept

  A host routes an opaque runtime token to one defended credential custodian;
  concurrent runtimes remain isolated and rotation changes only the next
  invocation's resolution.

  ## Technical depth

  These cases exercise the exact closed token, registry-handle and custody-ref
  shapes, the keyed sole credential reply, producer normalization, process-loss
  behavior, rotation and redacted OTP status without launching a provider.
  """

  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.CredentialCustody
  alias Loopex.LLM.ReqLLM.CredentialRegistry
  alias Loopex.LLM.ReqLLM.CredentialToken

  test "two runtime registries route only their own opaque token and resolve independently" do
    first = composition("first-credential")
    second = composition("second-credential")

    assert {:ok, first_ref} = CredentialRegistry.route(first.registry, first.token)
    assert {:ok, %{credential: "first-credential"}} = CredentialCustody.resolve(first_ref)

    assert {:ok, second_ref} = CredentialRegistry.route(second.registry, second.token)
    assert {:ok, %{credential: "second-credential"}} = CredentialCustody.resolve(second_ref)

    assert {:error, :unavailable} = CredentialRegistry.route(first.registry, second.token)
    assert {:error, :unavailable} = CredentialRegistry.route(second.registry, first.token)
  end

  test "rotation is visible to the next resolution and missing or expired custody stays classified" do
    composed = composition("before-rotation")
    assert {:ok, custody} = CredentialRegistry.route(composed.registry, composed.token)
    assert {:ok, %{credential: "before-rotation"}} = CredentialCustody.resolve(custody)

    assert :ok = CredentialCustody.rotate(custody, "after-rotation")
    assert {:ok, %{credential: "after-rotation"}} = CredentialCustody.resolve(custody)

    assert :ok = CredentialCustody.rotate(custody, nil)
    assert {:error, :missing} = CredentialCustody.resolve(custody)

    assert :ok =
             CredentialCustody.rotate(
               custody,
               "expired",
               System.monotonic_time(:millisecond) - 1
             )

    assert {:error, :expired} = CredentialCustody.resolve(custody)
  end

  test "closed shapes reject extra keys and process loss becomes unavailable" do
    composed = composition("private")
    {:ok, custody} = CredentialRegistry.route(composed.registry, composed.token)

    assert {:error, :unavailable} =
             CredentialRegistry.route(
               Map.put(composed.registry, :extra, :forbidden),
               composed.token
             )

    assert {:error, :unavailable} =
             CredentialRegistry.route(
               composed.registry,
               Map.put(composed.token, :extra, :forbidden)
             )

    assert {:error, :unavailable} =
             CredentialRegistry.put(
               composed.registry,
               composed.token,
               Map.put(custody, :extra, :forbidden)
             )

    Process.exit(custody.pid, :kill)
    assert eventually(fn -> not Process.alive?(custody.pid) end)
    assert {:error, :unavailable} = CredentialCustody.resolve(custody)

    Process.exit(composed.registry.pid, :kill)
    assert eventually(fn -> not Process.alive?(composed.registry.pid) end)
    assert {:error, :unavailable} = CredentialRegistry.route(composed.registry, composed.token)
  end

  test "OTP status replaces every credential token route message reason and log" do
    secret = "status-canary-credential"
    composed = composition(secret)

    custody_status = %{
      state: %{credential: secret},
      message: {:credential, secret},
      reason: {:credential, secret},
      log: [secret]
    }

    assert %{
             state: :redacted_credential_custody_state,
             message: :redacted_credential_custody_message,
             reason: :redacted_credential_custody_reason,
             log: []
           } = CredentialCustody.format_status(custody_status)

    registry_status = %{
      state: %{token: composed.token},
      message: {:token, composed.token},
      reason: {:token, composed.token},
      log: [composed.token]
    }

    assert %{
             state: :redacted_credential_registry_state,
             message: :redacted_credential_registry_message,
             reason: :redacted_credential_registry_reason,
             log: []
           } = CredentialRegistry.format_status(registry_status)
  end

  defp composition(credential) do
    {:ok, custody_pid} = CredentialCustody.start_link(credential: credential)
    Process.unlink(custody_pid)
    {:ok, custody} = CredentialCustody.reference(custody_pid)
    {:ok, registry_pid} = CredentialRegistry.start_link()
    Process.unlink(registry_pid)
    {:ok, registry} = CredentialRegistry.handle(registry_pid)
    token = CredentialToken.new()
    :ok = CredentialRegistry.put(registry, token, custody)

    on_exit(fn ->
      if Process.alive?(registry_pid), do: Process.exit(registry_pid, :kill)
      if Process.alive?(custody_pid), do: Process.exit(custody_pid, :kill)
    end)

    %{custody: custody, registry: registry, token: token}
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(5)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
