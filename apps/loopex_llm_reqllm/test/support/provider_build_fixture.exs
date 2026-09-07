defmodule Loopex.LLM.ReqLLM.ProviderBuildFixture do
  @moduledoc """
  ## Concept

  Builds the actual same-source companion for explicitly selected real-provider
  tests. Requiring this file neither builds nor invokes a provider.

  ## Technical depth

  Both the adapter lane and the reference-client recovery trace use this setup.
  The caller owns `root`, including cleanup after a killed trace VM. Everything
  created here stays beneath it; the completed build is verified again when a
  later trace phase reuses it. No Mix project stack or ambient launch file is
  needed. Build failure is unavailable evidence, never a provider-test skip.
  """

  alias Loopex.LLM.ReqLLM.{ProviderConfiguration, ProviderLauncher, ProviderWorker}

  @source_root Path.expand("../../../..", __DIR__)
  @launch_keys [:worker_path, :interpreter_path, :worker_sha256, :build_manifest_sha256]
  @wire_modules [
    Loopex.LLM.ReqLLM,
    Loopex.LLM.ReqLLM.ProviderCodec,
    Loopex.Runtime.ProviderAttempt
  ]

  @doc """
  ## Concept

  Returns the four explicit managed launch options for this clean source.

  ## Technical depth

  A standalone caller must append its own `cleanup_grace_ms`; managed runtime
  calls obtain that period from Core. `root` must be an absolute, test-owned
  directory outside the checkout. This setup adds no request or test timeout.
  """
  def options!(root) when is_binary(root) do
    unless Path.type(root) == :absolute,
           do: raise("provider build requires an owned root outside the checkout")

    root = Path.expand(root)

    unless root != "/" and outside?(root, @source_root),
      do: raise("provider build requires an owned root outside the checkout")

    source = clean_source!()
    build = Path.join(root, "provider-build")
    worker = Path.join(build, "loopex_provider")

    case File.lstat(build) do
      {:error, :enoent} ->
        File.mkdir_p!(root)
        File.mkdir!(build)
        build!(build)

      {:ok, %File.Stat{type: :directory}} ->
        :ok

      _other ->
        raise "provider build namespace is not an ordinary owned directory"
    end

    verify!(worker, source)
  end

  defp build!(build) do
    # Concept: the selected runner's compiled closure is only an offline seed.
    # Technical depth: the repository build still forces current source and
    # rebinds its archive manifest. Copies prevent mutation of the runner's
    # build, dependency sources, Mix archives, or per-Elixir Rebar installation.
    seed = compiled_root!()
    copy!(Path.join(seed, "lib"), Path.join(build, "lib"))

    deps = System.get_env("MIX_DEPS_PATH") || Path.join(@source_root, "deps")
    copy!(Path.expand(deps, @source_root), Path.join(build, "deps"))

    mix_home = System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")
    archives = System.get_env("MIX_ARCHIVES") || Path.join(mix_home, "archives")
    copy!(archives, Path.join(build, "mix-home/archives"))

    rebar = Path.join(mix_home, "elixir")
    if File.dir?(rebar), do: copy!(rebar, Path.join(build, "mix-home/elixir"))

    for directory <- ["home", "tmp", "hex"], do: File.mkdir_p!(Path.join(build, directory))

    elixir_root = :code.lib_dir(:elixir) |> List.to_string() |> then(&Path.expand("../..", &1))
    elixir = Path.join(elixir_root, "bin/elixir")
    mix = Path.join(elixir_root, "bin/mix")
    otp_bin = Path.join(List.to_string(:code.root_dir()), "bin")

    # Concept: even the first build image receives no ambient credential.
    # Technical depth: removal precedes shell startup, not only a later exec.
    # The shell closes stdin before Elixir/Mix can consume the gate's private
    # credential frame. Only non-secret, owned build/toolchain inputs return.
    environment =
      empty_environment()
      |> Map.merge(%{
        "PATH" => Enum.join([Path.join(elixir_root, "bin"), otp_bin, "/usr/bin", "/bin"], ":"),
        "HOME" => Path.join(build, "home"),
        "TMPDIR" => Path.join(build, "tmp"),
        "MIX_ENV" => "test",
        "MIX_BUILD_PATH" => build,
        "MIX_DEPS_PATH" => Path.join(build, "deps"),
        "MIX_HOME" => Path.join(build, "mix-home"),
        "MIX_ARCHIVES" => Path.join(build, "mix-home/archives"),
        "HEX_HOME" => Path.join(build, "hex"),
        "HEX_OFFLINE" => "1",
        "LANG" => "C.UTF-8",
        "LC_ALL" => "C.UTF-8",
        "ERL_CRASH_DUMP" => "/dev/null",
        "ERL_CRASH_DUMP_SECONDS" => "0",
        "GIT_OPTIONAL_LOCKS" => "0"
      })

    {output, status} =
      System.cmd(
        "/bin/sh",
        ["-c", "exec \"$1\" \"$2\" loopex.provider.build </dev/null", "provider-build", elixir, mix],
        cd: Path.join(@source_root, "apps/loopex_llm_reqllm"),
        env: Map.to_list(environment),
        stderr_to_stdout: true
      )

    File.write!(Path.join(build, "build.log"), output)
    unless status == 0, do: raise("provider cold build failed (#{status}):\n#{output}")
  end

  defp verify!(worker, source) do
    {:ok, [configuration]} = :file.consult(String.to_charlist(worker <> ".launch"))
    {:ok, [manifest]} = :file.consult(String.to_charlist(worker <> ".manifest"))
    {:ok, validated} = ProviderConfiguration.validate(configuration)

    expected = %{
      "source" => source,
      "version" => File.read!(Path.join(@source_root, "VERSION")) |> String.trim(),
      "dependency_lock_sha256" => digest(File.read!(Path.join(@source_root, "mix.lock"))),
      "packaged_input_sha256" => Mix.Tasks.Loopex.Provider.Build.packaged_input_digest(worker),
      "elixir" => System.version(),
      "otp" => ProviderWorker.otp_version()
    }

    unless Enum.sort(Keyword.keys(configuration)) == Enum.sort(@launch_keys) and
             validated.worker_path == worker and
             validated.interpreter_path ==
               Path.join(List.to_string(:code.root_dir()), "bin/escript") and
             manifest == expected and
             validated.build_manifest_sha256 ==
               digest(:erlang.term_to_binary(manifest, [:deterministic])),
           do: raise("provider build does not match this source and running toolchain")

    :ok = ProviderConfiguration.verify_artifact(validated)
    verify_wire_modules!(worker)
    unless clean_source!() == source, do: raise("provider source changed during fixture setup")
    configuration
  end

  defp verify_wire_modules!(worker) do
    {:ok, sections} = :escript.extract(String.to_charlist(worker), [])
    {:ok, entries} = :zip.extract(Keyword.fetch!(sections, :archive), [:memory])

    for module <- @wire_modules do
      name = Atom.to_string(module) <> ".beam"
      [{_path, packaged}] = Enum.filter(entries, &(Path.basename(List.to_string(elem(&1, 0))) == name))
      {^module, loaded, _path} = :code.get_object_code(module)

      unless :beam_lib.md5(packaged) == :beam_lib.md5(loaded),
        do: raise("provider companion differs from the loaded #{inspect(module)} boundary")
    end
  end

  defp compiled_root! do
    path = :code.which(ProviderWorker)
    unless is_list(path), do: raise("provider fixture requires the runner's compiled adapter")
    path |> List.to_string() |> Path.dirname() |> then(&Path.expand("../../..", &1))
  end

  defp copy!(source, destination) do
    unless File.dir?(source), do: raise("offline provider build input unavailable: #{source}")
    File.mkdir_p!(Path.dirname(destination))
    File.cp_r!(source, destination, dereference_symlinks: true)
  end

  defp clean_source! do
    environment =
      empty_environment()
      |> Map.merge(%{"PATH" => "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS" => "0"})
      |> Map.to_list()

    {status, 0} =
      System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"],
        cd: @source_root,
        env: environment
      )

    unless status == "", do: raise("provider fixture requires a clean source checkout")
    {source, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: @source_root, env: environment)
    String.trim(source)
  end

  defp empty_environment do
    Map.new(ProviderLauncher.spawn_environment(), fn {name, false} ->
      {List.to_string(name), nil}
    end)
  end

  defp outside?(path, root) do
    relative = Path.relative_to(path, root)
    relative == path or relative == ".." or String.starts_with?(relative, "../")
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
