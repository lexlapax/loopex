defmodule LoopexCli.CredentialCustodyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Loopex.LLM.ReqLLM
  alias Loopex.Trace.Capability
  alias LoopexComposition.CredentialHost

  @canary "cli-custody-canary-7f3a"

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "lcc-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace}
  end

  # Concept: the reference CLI's host plane refuses composition when any part
  # of it is malformed, before a Store, executor or runtime exists.
  test "a malformed host credential plane refuses composition before any edge", context do
    {holder, plane} = hosted_plane()

    options = [
      runtime_id: "cli-custody",
      state_root: Path.join(context.root, "s"),
      workspace: context.workspace,
      policy: Policy
    ]

    model_options = plane.model_options

    for broken <- [
          %{plane | model_options: Keyword.delete(model_options, :credential_registry)},
          %{plane | model_options: model_options ++ [extra: @canary]},
          %{plane | model_options: Keyword.put(model_options, :credential_token, @canary)},
          %{plane | model_options: Keyword.put(model_options, :credential_registry, :bogus)},
          %{plane | capability: :bogus},
          Map.put(plane, :extra, @canary)
        ] do
      assert LoopexComposition.start(Keyword.put(options, :credential_plane, broken)) ==
               {:error, {:invalid_composition_option, :credential_plane}}

      refute File.exists?(Path.join([context.root, "s", "store.log"]))
    end

    send(holder, :stop)
  end

  test "a plane's capability binds one runtime and refuses a second" do
    {holder, plane} = hosted_plane()
    runtime_a = start_runtime("cli-capability-a")
    runtime_b = start_runtime("cli-capability-b")

    assert Capability.bind(plane.capability, runtime_a) == :ok
    assert Capability.bind(plane.capability, runtime_a) == :ok
    assert Capability.bind(plane.capability, runtime_b) == {:error, :capability_already_bound}
    assert Capability.bind(plane.capability, runtime_a) == :ok
    send(holder, :stop)
  end

  # Concept: a custody or routing process that crashes on a request carrying
  # credential bytes leaves those bytes out of every report and log.
  test "custody and registry refuse canary-bearing requests and a forced crash reports no canary" do
    {holder, plane} = hosted_plane()
    registry = Keyword.fetch!(plane.model_options, :credential_registry)
    token = Keyword.fetch!(plane.model_options, :credential_token)
    {:ok, custody} = ReqLLM.CredentialRegistry.route(registry, token)

    log =
      capture_log(fn ->
        pids = [custody.pid, registry.pid]

        # Unrecognized requests carrying credential bytes are refused, not
        # crashed on, so no exit reason or report can carry state.
        for pid <- pids do
          assert GenServer.call(pid, {:unexpected, @canary}) == {:error, :unavailable}
          GenServer.cast(pid, {:unexpected, @canary})
          send(pid, {:unexpected, @canary})
        end

        assert Enum.all?(pids, &Process.alive?/1)
        monitors = for pid <- pids, do: {pid, Process.monitor(pid)}
        Process.exit(custody.pid, :kill)

        # Custody's death takes its host and the registry with it; neither
        # observed exit carries the credential.
        for {pid, monitor} <- monitors do
          assert_receive {:DOWN, ^monitor, :process, ^pid, reason}, 1_000
          refute inspect(reason) =~ @canary
        end

        Process.sleep(100)
      end)

    refute log =~ @canary
    refute log =~ Base.encode64(@canary)
    send(holder, :stop)
  end

  # The host process owns the plane's links, so a test crash cannot reach
  # the test process itself.
  defp hosted_plane do
    test = self()
    System.put_env(ReqLLM.credential_variable(), @canary)

    holder =
      spawn(fn ->
        {:ok, host} = CredentialHost.open()
        {:ok, plane} = CredentialHost.plane(host)
        send(test, {:plane, plane})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:plane, plane}, 5_000
    assert System.get_env(ReqLLM.credential_variable()) == nil
    on_exit(fn -> Process.exit(holder, :kill) end)
    {holder, plane}
  end

  defp start_runtime(id) do
    {:ok, adapter} =
      Loopex.Store.Local.start_link(
        path: Path.join(System.tmp_dir!(), "#{id}-#{System.unique_integer([:positive])}.log")
      )

    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, adapter)
    {:ok, runtime} = Loopex.start_link(runtime_id: id, store: store, context_token_budget: 8_192)
    on_exit(fn -> if Loopex.Runtime.alive?(runtime), do: Loopex.stop(runtime) end)
    runtime
  end
end
