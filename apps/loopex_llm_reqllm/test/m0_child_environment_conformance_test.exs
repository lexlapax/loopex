Code.require_file("support/provider_build_fixture.exs", __DIR__)

defmodule Loopex.LLM.ReqLLM.M0ChildEnvironmentConformanceTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.{ProviderBuildFixture, ProviderConfiguration, ProviderLauncher}

  @sentinel "LOOPEX_M0_CHILDENV_PARENT_ONLY"
  @sentinel_value "nonsecret-parent-only-conformance"

  setup do
    root =
      Path.join(System.tmp_dir!(), "loopex-m0-childenv-#{System.unique_integer([:positive])}")

    File.mkdir!(root)
    previous = Map.new(["PATH", @sentinel], &{&1, System.get_env(&1)})
    trapped = Process.flag(:trap_exit, true)

    on_exit(fn ->
      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      Process.flag(:trap_exit, trapped)
      File.rm_rf!(root)
    end)

    %{root: root, original_path: previous["PATH"]}
  end

  test "the actual provider worker receives the fixed PATH without the caller sentinel", %{
    root: root,
    original_path: original_path
  } do
    controlled_path = Path.join(root, "parent-bin") <> ":" <> original_path
    System.put_env("PATH", controlled_path)
    System.put_env(@sentinel, @sentinel_value)
    report = Path.join(root, "worker-environment")
    worker = Path.join(root, "worker.sh")

    File.write!(worker, """
    trap - TERM
    printf '%s\\nsentinel:%s\\n%s\\n' "$PATH" "${#{@sentinel}+present}" "$$" > #{shell_quote(report)}
    while :; do /bin/sleep 1; done
    """)

    assert {:ok, namespace} = ProviderLauncher.prepare()
    nonce = String.duplicate("a", 64)

    configuration = %{
      interpreter_path: "/bin/sh",
      worker_path: worker,
      build_manifest_sha256: String.duplicate("d", 64)
    }

    assert {:ok, owned} =
             ProviderLauncher.start(namespace, configuration, nonce, 2_000, 9_999_999_999_999)

    port = owned.port

    try do
      assert_receive {^port, {:data, {:eol, ready}}}, 2_000
      assert String.starts_with?(ready, "ready:#{nonce}:#{owned.carrier}:")
      assert Port.command(port, "run:#{nonce}\n")

      assert eventually(fn ->
               case File.read(report) do
                 {:ok, bytes} -> length(String.split(bytes, "\n", trim: true)) == 3
                 {:error, :enoent} -> false
               end
             end)

      assert ["/usr/bin:/bin", "sentinel:", pid] =
               String.split(File.read!(report), "\n", trim: true)

      assert String.to_integer(pid) in live_group(owned.carrier)
      assert System.get_env("PATH") == controlled_path
      assert System.get_env(@sentinel) == @sentinel_value

      :gen_tcp.close(namespace.listener)
      stop = String.duplicate("b", 32)
      assert Port.command(port, "stop:#{nonce}:#{stop}:2000\n")
      acknowledgement = "cleanup_complete:#{nonce}:#{stop}"
      assert_receive {^port, {:data, {:eol, ^acknowledgement}}}, 2_000
      assert_receive {^port, {:exit_status, 0}}, 500
      assert eventually(fn -> live_group(owned.carrier) == [] end)
      refute File.exists?(namespace.namespace)
      assert System.get_env("PATH") == controlled_path
      assert System.get_env(@sentinel) == @sentinel_value
    after
      :gen_tcp.close(namespace.listener)
      dispose_owned_group(owned)
    end
  end

  test "actual fixture Git children are scrubbed and the offline build bypasses parent PATH shims",
       %{
         root: root,
         original_path: original_path
       } do
    shims = Path.join(root, "parent-bin")
    File.mkdir!(shims)
    git_log = Path.join(root, "git-children")
    erl_log = Path.join(root, "erl-children")
    real_git = System.find_executable("git") || flunk("Git is unavailable")
    otp_bin = Path.join(List.to_string(:code.root_dir()), "bin")
    elixir_root = :code.lib_dir(:elixir) |> List.to_string() |> then(&Path.expand("../..", &1))
    elixir = Path.join(elixir_root, "bin/elixir")
    controlled_path = shims <> ":" <> original_path

    for {name, program, observation} <- [
          {"git", real_git, git_log},
          {"erl", Path.join(otp_bin, "erl"), erl_log}
        ] do
      shim = Path.join(shims, name)

      File.write!(shim, """
      #!/bin/sh
      printf '%s|%s|sentinel:%s\\n' "$1" "$PATH" "${#{@sentinel}+present}" >> #{shell_quote(observation)}
      exec #{shell_quote(program)} "$@"
      """)

      File.chmod!(shim, 0o700)
    end

    System.put_env("PATH", controlled_path)
    System.put_env(@sentinel, @sentinel_value)

    # Concept: both observers must report an actual unsanitized child first.
    # Technical depth: Git is resolved in the caller by System.cmd, before env
    # is applied; its transparent shim records the child environment, not an
    # executable-resolution guarantee. Elixir resolves erl inside its shell,
    # so the separate erl shim detects loss of the build child's fixed PATH.
    assert {git_version, 0} = System.cmd("git", ["--version"])
    assert String.starts_with?(git_version, "git version ")
    assert File.read!(git_log) == "--version|#{controlled_path}|sentinel:present\n"
    assert {"", 0} = System.cmd(elixir, ["-e", ":ok"], stderr_to_stdout: true)
    assert File.read!(erl_log) =~ "|#{controlled_path}|sentinel:present\n"
    File.rename!(git_log, git_log <> "-positive-control")
    File.rename!(erl_log, erl_log <> "-positive-control")

    # This invokes the real fixture on this clean test-only checkout. Its own
    # verification checks source, toolchain, archive bytes and loaded boundaries;
    # requiring the helper or inspecting its environment constructor is not proof.
    options = ProviderBuildFixture.options!(Path.join(root, "fixture"))
    assert {:ok, configuration} = ProviderConfiguration.validate(options)
    assert :ok = ProviderConfiguration.verify_artifact(configuration)
    assert File.regular?(configuration.worker_path)
    assert File.regular?(Path.join(Path.dirname(configuration.worker_path), "build.log"))

    assert File.read!(git_log) ==
             Enum.map_join(["status", "rev-parse", "status", "rev-parse"], fn command ->
               "#{command}|/usr/bin:/bin|sentinel:\n"
             end)

    refute File.exists?(erl_log), "the real build used the caller-only erl shim"
    assert System.get_env("PATH") == controlled_path
    assert System.get_env(@sentinel) == @sentinel_value

    {:ok, [manifest]} =
      :file.consult(String.to_charlist(configuration.worker_path <> ".manifest"))

    IO.inspect(%{
      fixture_source: manifest["source"],
      companion_sha256: configuration.worker_sha256,
      observed_clean_git_children: 4,
      parent_erl_calls_during_build: 0
    })
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp live_group(group) do
    {table, 0} = System.cmd("/bin/ps", ["-ax", "-o", "pid=", "-o", "pgid=", "-o", "stat="])

    for line <- String.split(table, "\n", trim: true),
        [pid, pgid, state] = String.split(line),
        String.to_integer(pgid) == group,
        not String.starts_with?(state, "Z"),
        do: String.to_integer(pid)
  end

  # Fixture recovery is not cleanup evidence. The still-open Port identifies
  # this launch before any fallback signal; successful assertions use its ACK.
  defp dispose_owned_group(owned) do
    if Port.info(owned.port, :os_pid) == {:os_pid, owned.carrier} do
      _ = System.cmd("/bin/kill", ["-KILL", "--", "-#{owned.carrier}"])
      assert eventually(fn -> live_group(owned.carrier) == [] end)
    end

    if Port.info(owned.port) != nil, do: Port.close(owned.port)
  end

  defp eventually(fun) do
    await(fun, System.monotonic_time(:millisecond) + 1_000)
  end

  defp await(fun, until) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= until ->
        false

      true ->
        Process.sleep(10)
        await(fun, until)
    end
  end
end
