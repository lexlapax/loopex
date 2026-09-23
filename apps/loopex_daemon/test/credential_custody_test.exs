defmodule LoopexDaemon.CredentialCustodyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LoopexDaemon.{ExitStatus, Sentinel}

  @canary "daemon-custody-canary-4c1e"

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  setup do
    root = Path.join(System.tmp_dir!(), "ldc-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, workspace: workspace, state_root: Path.join(root, "s")}
  end

  # Concept: the daemon's own composition refuses a malformed credential plane
  # before any Store, executor or runtime edge starts.
  test "a malformed host plane refuses the daemon's composition before any edge", context do
    options = [
      runtime_id: "daemon-custody",
      state_root: context.state_root,
      workspace: context.workspace,
      policy: Policy
    ]

    for broken <- [
          %{capability: :bogus, model_options: []},
          %{capability: :bogus, model_options: [credential_token: @canary]},
          %{model_options: []},
          :bogus
        ] do
      assert {:error, {:invalid_composition_option, :credential_plane}, %{}} =
               LoopexComposition.start_edges(Keyword.put(options, :credential_plane, broken))
    end

    refute File.exists?(Path.join(context.state_root, "store.log"))
  end

  # Concept: the daemon's custody refuses requests it does not recognize, and
  # when it dies the daemon fail-stops with custody's class; no report, log or
  # observed exit carries the credential.
  @tag timeout: 120_000
  test "custody refuses a canary-bearing request and its loss fail-stops without the canary",
       context do
    options = [
      state_root: context.state_root,
      socket_path: Path.join([context.state_root, "daemon", "d.sock"]),
      workspace: context.workspace,
      policy: Policy,
      credential: @canary,
      admission_wait_ms: 200
    ]

    log =
      capture_log(fn ->
        {:ok, output} = StringIO.open("")
        test = self()

        task =
          Task.async(fn ->
            Sentinel.run(options, output: output, install_signals: false, notify: test)
          end)

        assert_receive {:loopex_daemon_sentinel, _sentinel, _owner_ref, owner}, 5_000
        await_ready(output, 1_000)

        custody = :sys.get_state(owner).pids.custody
        assert GenServer.call(custody, {:unexpected, @canary}) == {:error, :unavailable}
        send(custody, {:unexpected, @canary})
        assert Process.alive?(custody)

        monitor = Process.monitor(custody)
        Process.exit(custody, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^custody, :killed}, 1_000

        {:ok, custody_lost} = ExitStatus.fetch(:custody_lost)
        assert Task.await(task, 60_000) == custody_lost
      end)

    refute log =~ @canary
    refute log =~ Base.encode64(@canary)
  end

  defp await_ready(output, attempts) when attempts > 0 do
    case StringIO.contents(output) do
      {"", line} when byte_size(line) > 0 ->
        :ok

      _empty ->
        Process.sleep(10)
        await_ready(output, attempts - 1)
    end
  end

  defp await_ready(_output, 0), do: flunk("daemon never announced readiness")
end
