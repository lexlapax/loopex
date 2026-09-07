defmodule Mix.Tasks.Loopex.Provider.Build do
  @moduledoc """
  ## Concept

  Builds the private, same-source provider companion and its non-secret host
  launch configuration. A dirty source tree is not an evidence build.

  ## Technical depth

  Run in the reference adapter project. The generated manifest binds the clean
  source revision, train version, dependency lock, actual compiled package
  inputs, and exact Elixir/OTP pair. The manifest BEAM and final executable are
  excluded from the input digest, avoiding self-reference. This task neither
  starts the provider nor reads a provider credential.
  """

  use Mix.Task
  alias Loopex.LLM.ReqLLM.{ProviderConfiguration, ProviderWorker}

  @shortdoc "Builds the private reference-provider companion"

  @impl Mix.Task
  def run(args) do
    unless Mix.Project.config()[:app] == :loopex_llm_reqllm,
      do: Mix.raise("run this task in apps/loopex_llm_reqllm")

    root = Path.expand("../..", File.cwd!())

    {status, 0} =
      System.cmd("git", ["status", "--porcelain=v1", "--untracked-files=normal"], cd: root)

    unless status == "", do: Mix.raise("provider build requires a clean source checkout")
    {source, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: root)
    Mix.Task.run("compile", args)

    manifest = %{
      "source" => String.trim(source),
      "version" => Mix.Project.config()[:version],
      "dependency_lock_sha256" => digest(File.read!(Path.join(root, "mix.lock"))),
      "packaged_input_sha256" => input_digest(),
      "elixir" => System.version(),
      "otp" => ProviderWorker.otp_version()
    }

    install_identity(manifest)
    Mix.Tasks.Escript.Build.run(args)
    worker = Mix.Project.config()[:escript][:path] |> Path.expand()
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

  defp input_digest do
    roots = [Mix.Project.app_path() | Enum.map(Mix.Dep.cached(), & &1.opts[:build])]
    # The embedded Elixir/Logger code is also an input, not merely an assertion
    # in a version field. Paths are reduced to archive names, as escript does.
    roots = roots ++ Enum.map([:elixir, :logger], &(&1 |> :code.lib_dir() |> List.to_string()))
    manifest_beam = "Elixir.Loopex.LLM.ReqLLM.ProviderBuildIdentity.beam"

    roots
    |> Enum.flat_map(fn root ->
      Path.wildcard(Path.join(root, "ebin/*.{beam,app}")) ++
        Enum.filter(Path.wildcard(Path.join(root, "priv/**/*")), &File.regular?/1)
    end)
    |> Enum.reject(&(Path.basename(&1) == manifest_beam))
    |> Enum.map(fn path -> {Path.basename(path), digest(File.read!(path))} end)
    |> Enum.uniq()
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> digest()
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

    previous = Code.compiler_options(ignore_module_conflict: true)

    try do
      for {module, beam} <- Code.compile_quoted(quoted) do
        File.write!(
          Path.join(Mix.Project.compile_path(), Atom.to_string(module) <> ".beam"),
          beam
        )
      end
    after
      Code.compiler_options(previous)
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
