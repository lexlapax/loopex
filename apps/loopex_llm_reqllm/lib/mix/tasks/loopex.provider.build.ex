defmodule Mix.Tasks.Loopex.Provider.Build do
  @moduledoc """
  ## Concept

  Builds the private, same-source provider companion and its non-secret host
  launch configuration. A dirty source tree is not an evidence build.

  ## Technical depth

  Run in the reference adapter project. The generated manifest binds the clean
  source revision, train version, dependency lock, actual archive entry paths
  and bytes, and exact Elixir/OTP pair. A second archive build proves that
  embedding the manifest did not change its inputs. Only the manifest BEAM and
  final executable are excluded, avoiding self-reference. The `.launch` file
  contains all four managed launch options; standalone callers must append
  their own `cleanup_grace_ms`. This task neither starts the provider nor reads
  a provider credential. It accepts `--force` and `--warnings-as-errors`;
  compilation is always forced with warnings treated as errors.
  """

  use Mix.Task
  alias Loopex.LLM.ReqLLM.{ProviderConfiguration, ProviderWorker}

  @shortdoc "Builds the private reference-provider companion"
  @identity_beam "Elixir.Loopex.LLM.ReqLLM.ProviderBuildIdentity.beam"
  @identity_paths [@identity_beam, "loopex_llm_reqllm/ebin/" <> @identity_beam]

  @impl Mix.Task
  def run(args) do
    unless Mix.Project.config()[:app] == :loopex_llm_reqllm,
      do: Mix.raise("run this task in apps/loopex_llm_reqllm")

    unless Enum.all?(args, &(&1 in ["--force", "--warnings-as-errors"])),
      do: Mix.raise("provider build accepts only --force and --warnings-as-errors")

    root = Path.expand("../..", File.cwd!())
    source = clean_source!(root)
    lock_digest = digest(File.read!(Path.join(root, "mix.lock")))
    compile_source!()
    worker = Mix.Project.config()[:escript][:path] |> Path.expand()

    install_identity(nil)
    build_archive!()

    manifest = %{
      "source" => source,
      "version" => Mix.Project.config()[:version],
      "dependency_lock_sha256" => lock_digest,
      "packaged_input_sha256" => packaged_input_digest(worker),
      "elixir" => System.version(),
      "otp" => ProviderWorker.otp_version()
    }

    install_identity(manifest)
    build_archive!()
    verify_packaged_input!(worker, manifest["packaged_input_sha256"])

    unless clean_source!(root) == source and
             digest(File.read!(Path.join(root, "mix.lock"))) == lock_digest,
           do: Mix.raise("provider source changed during build")

    {:ok, worker_digest} = ProviderConfiguration.file_digest(worker)

    configuration = [
      worker_path: worker,
      interpreter_path: Path.join(List.to_string(:code.root_dir()), "bin/escript"),
      worker_sha256: worker_digest,
      build_manifest_sha256: manifest |> :erlang.term_to_binary([:deterministic]) |> digest()
    ]

    {:ok, _validated} = ProviderConfiguration.validate(configuration)
    :ok = ProviderConfiguration.verify_artifact(Map.new(configuration))
    File.write!(worker <> ".launch", :io_lib.format(~c"~tp.~n", [configuration]))
    File.write!(worker <> ".manifest", :io_lib.format(~c"~tp.~n", [manifest]))
    Mix.shell().info("Provider companion and non-secret launch configuration built at #{worker}")
  end

  # Concept: identity describes what the worker will load from its archive.
  # Technical depth: Mix changes archive layout across supported toolchains and
  # substitutes stripped/consolidated BEAMs. Extracting the resulting archive
  # includes those bytes, generated bootstrap code, and embedded configuration.
  # Exact paths preserve distinct entries with a shared basename. The two
  # identity paths are the flat floor and application-prefixed current layouts.
  @doc false
  def packaged_input_digest(worker) do
    entries = archive_entries!(worker)
    paths = Enum.map(entries, &elem(&1, 0))

    unless length(paths) == length(Enum.uniq(paths)) and
             Enum.count(paths, &(&1 in @identity_paths)) == 1,
           do: Mix.raise("provider archive has ambiguous paths or build identity")

    entries
    |> Enum.reject(fn {path, _bytes} -> path in @identity_paths end)
    |> Enum.map(fn {path, bytes} -> {path, digest(bytes)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> digest()
  end

  @doc false
  def verify_packaged_input!(worker, expected) do
    unless packaged_input_digest(worker) == expected,
      do: Mix.raise("provider packaged inputs changed while embedding build identity")

    :ok
  end

  defp archive_entries!(worker) do
    with {:ok, sections} <- :escript.extract(String.to_charlist(worker), []),
         archive when is_binary(archive) <- Keyword.get(sections, :archive),
         {:ok, entries} <- :zip.extract(archive, [:memory]) do
      Enum.map(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)
    else
      _invalid -> Mix.raise("provider executable does not contain a readable archive")
    end
  end

  defp clean_source!(root) do
    {status, 0} =
      System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=all"], cd: root)

    unless status == "", do: Mix.raise("provider build requires a clean source checkout")
    {source, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    String.trim(source)
  end

  defp compile_source! do
    tasks = ["compile", "compile.all", "compile.protocols"]
    compilers = Mix.Project.config()[:compilers] || Mix.compilers()
    tasks = tasks ++ Enum.map(compilers, &"compile.#{&1}")
    Enum.each(tasks, &Mix.Task.reenable/1)
    Mix.Task.run("compile", ["--force", "--warnings-as-errors"])
  end

  defp build_archive! do
    # Concept: two archives establish that the embedded identity is the only
    # self-referential entry. Source compilation has already completed above.
    # Technical depth: Mix regenerates the same private escript entry module
    # on each call. Only these intentional generated-module replacements waive
    # module-conflict warnings; ordinary source compilation remains strict.
    replace_generated_module(fn -> Mix.Tasks.Escript.Build.run([]) end)
  end

  defp install_identity(manifest) do
    quoted =
      quote do
        defmodule Loopex.LLM.ReqLLM.ProviderBuildIdentity do
          @moduledoc false
          @doc false
          def manifest, do: unquote(Macro.escape(manifest))
        end
      end

    replace_generated_module(fn ->
      for {module, beam} <- Code.compile_quoted(quoted) do
        File.write!(
          Path.join(Mix.Project.compile_path(), Atom.to_string(module) <> ".beam"),
          beam
        )
      end
    end)
  end

  defp replace_generated_module(fun) do
    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      fun.()
    after
      Code.compiler_options(previous)
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
