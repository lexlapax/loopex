defmodule LoopexComposition.CredentialHostTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.LLM.ReqLLM.{CredentialCustody, CredentialRegistry}
  alias Loopex.Trace.Capability
  alias LoopexComposition.CredentialHost

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-credential-host-#{System.unique_integer([:positive])}")

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    variable = ReqLLM.credential_variable()

    on_exit(fn ->
      :erlang.trace_pattern({System, :get_env, 1}, false, [:local])
      System.delete_env(variable)
      File.rm_rf!(root)
    end)

    %{root: root, workspace: workspace, variable: variable}
  end

  test "an absent or empty credential refuses and starts nothing", %{variable: variable} do
    System.delete_env(variable)
    assert CredentialHost.open() == {:error, :provider_credential_required}
    System.put_env(variable, "")
    assert CredentialHost.open() == {:error, :provider_credential_required}
    assert System.get_env(variable) == nil
  end

  test "one read serves two sequential compositions, each with its own capability", context do
    credential = "credential-host-canary"
    System.put_env(context.variable, credential)
    assert :erlang.trace_pattern({System, :get_env, 1}, true, [:local]) == 1
    collector = spawn_link(fn -> collect([]) end)
    :erlang.trace(:all, true, [:call, {:tracer, collector}])
    :erlang.trace(collector, false, [:call])

    assert {:ok, host} = CredentialHost.open()

    options = [
      state_root: Path.join(context.root, "state"),
      workspace: context.workspace,
      policy: Policy
    ]

    runtimes =
      for label <- ["inspect", "resume"] do
        {:ok, plane} = CredentialHost.plane(host)

        runtime =
          LoopexComposition.with_runtime(
            Keyword.merge(options, runtime_id: "host-#{label}", credential_plane: plane),
            fn runtime ->
              # The composition bound this plane's capability to its runtime.
              assert Capability.bind(plane.capability, runtime) == :ok

              registry = Keyword.fetch!(plane.model_options, :credential_registry)
              token = Keyword.fetch!(plane.model_options, :credential_token)
              assert {:ok, custody} = CredentialRegistry.route(registry, token)
              assert {:ok, %{credential: ^credential}} = CredentialCustody.resolve(custody)
              runtime
            end
          )

        :ok = CredentialHost.release_plane(plane)
        refute Process.alive?(plane.capability_pid)
        runtime
      end

    :erlang.trace(:all, false, [:call])
    assert length(Enum.uniq(runtimes)) == 2

    send(collector, {:report, self()})
    assert_receive {:traces, traces}, 5_000

    reads =
      traces
      |> Enum.filter(
        &match?(
          {:trace, _pid, :call, {System, :get_env, [variable]}}
          when variable == context.variable,
          &1
        )
      )

    assert length(reads) == 1
    assert System.get_env(context.variable) == nil
  end

  # Concept: a workspace-scoped child a host starts never inherits the
  # credential, even while the variable is still set.
  test "project-resource discovery runs git without the credential", context do
    fake = Path.join(context.root, "fake-bin")
    File.mkdir_p!(fake)
    dump = Path.join(context.root, "git-env")
    script = Path.join(fake, "git")
    File.write!(script, "#!/bin/sh\nenv > \"#{dump}\"\nexit 1\n")
    File.chmod!(script, 0o755)
    File.write!(Path.join(context.workspace, "AGENTS.md"), "Be careful.\n")

    previous_path = System.get_env("PATH")
    System.put_env("PATH", fake <> ":" <> previous_path)
    System.put_env(context.variable, "discovery-canary")

    try do
      assert %{workspace: %{revision: nil}} =
               LoopexComposition.ProjectResources.discover(context.workspace)
    after
      System.put_env("PATH", previous_path)
    end

    environment = File.read!(dump)
    refute environment =~ "discovery-canary"
    refute environment =~ context.variable
  end

  defp collect(messages) do
    receive do
      {:trace, _pid, :call, _mfa} = message ->
        collect([message | messages])

      {:report, caller} ->
        send(caller, {:traces, Enum.reverse(messages)})
    end
  end
end
