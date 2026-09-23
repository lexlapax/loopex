defmodule LoopexAppServer.CredentialCustodyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Loopex.LLM.ReqLLM

  @canary "app-server-custody-canary-9b2d"
  @edge :"$loopex_composition_edge_observer"

  defmodule Policy do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}
  end

  # Concept: the server's composition consumes the variable; a second
  # composition in the same VM refuses before starting a runtime.
  test "a second composition in the same VM refuses the consumed credential" do
    root = Path.join(System.tmp_dir!(), "lac2-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)
    variable = ReqLLM.credential_variable()
    System.put_env(variable, @canary)
    on_exit(fn -> System.delete_env(variable) end)

    options = [
      runtime_id: "app-server-twice",
      state_root: Path.join(root, "s"),
      workspace: workspace,
      policy: Policy
    ]

    assert LoopexComposition.with_runtime(options, fn _runtime -> :first end) == :first
    assert System.get_env(variable) == nil

    assert LoopexComposition.with_runtime(options, fn _runtime -> :second end) ==
             {:error, :provider_credential_required}
  end

  # Concept: the foreground server's composition consumes the credential into
  # custody; that custody refuses requests it does not recognize, and its loss
  # reaches no report, log or observed exit with the credential in it.
  test "the server's custody refuses canary-bearing requests and dies without the canary" do
    root = Path.join(System.tmp_dir!(), "lac-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "w")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    variable = ReqLLM.credential_variable()
    System.put_env(variable, @canary)
    on_exit(fn -> System.delete_env(variable) end)
    test = self()

    Process.put(@edge, fn module, function, arguments ->
      result = apply(module, function, arguments)

      if module == ReqLLM.CredentialCustody,
        do: send(test, {:custody_started, result})

      result
    end)

    on_exit(fn -> Process.delete(@edge) end)

    log =
      capture_log(fn ->
        LoopexComposition.with_runtime(
          [
            runtime_id: "app-server-custody",
            state_root: Path.join(root, "s"),
            workspace: workspace,
            policy: Policy
          ],
          fn _runtime ->
            assert System.get_env(variable) == nil
            assert_receive {:custody_started, {:ok, custody}}, 1_000

            assert GenServer.call(custody, {:unexpected, @canary}) == {:error, :unavailable}
            send(custody, {:unexpected, @canary})
            assert Process.alive?(custody)

            monitor = Process.monitor(custody)
            Process.exit(custody, :kill)
            assert_receive {:DOWN, ^monitor, :process, ^custody, :killed}, 1_000
            :done
          end
        )

        Process.sleep(100)
      end)

    refute log =~ @canary
    refute log =~ Base.encode64(@canary)
  end
end
