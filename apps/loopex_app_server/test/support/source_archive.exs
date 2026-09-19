defmodule Loopex.AppServer.SourceArchive do
  @moduledoc """
  ## Concept

  An archive of the exact committed source, extracted outside the checkout and
  built there the way the operator guide says to build it.

  Two cases need this and they need it identically: one proves the documented
  commands work with a real provider behind them, the other proves the same
  source builds and serves without a credential at all. A second copy of these
  steps would be a second thing to keep true.

  ## Technical depth

  The archive is staged from `HEAD` rather than from the working tree, and a
  dirty tree refuses, because extracting a tree with uncommitted bytes in it
  would prove something about nothing anyone can name. What comes out carries no
  build, no dependencies and no Git directory, and each of those is asserted
  rather than assumed.

  Dependencies are supplied rather than fetched. The guide says `mix deps.get`;
  a build here that reached the network would be proving something about the
  network, so the tree the calling suite's own build resolved is copied in and
  the compile is offline.
  """

  import ExUnit.Assertions

  @applications ~w(loopex_protocol loopex loopex_app_server loopex_composition
                   loopex_store_local loopex_executor_local loopex_llm_reqllm)

  @doc """
  ## Concept

  Stages and extracts the exact committed revision beneath `root`, and answers
  where it landed.

  ## Technical depth

  Refuses a dirty tree before doing any work, so a case that would have proved
  nothing fails in a second rather than after a build. The revision is written
  to standard error, because evidence that does not name the bytes it came from
  is not evidence.
  """
  @spec extract!(binary()) :: binary()
  def extract!(root) when is_binary(root) do
    repository = repository_root()
    {committed, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: repository)
    committed = String.trim(committed)
    {dirty, 0} = System.cmd("git", ["status", "--porcelain"], cd: repository)

    assert dirty == "",
           "the tree is not the committed candidate; extracting it would prove nothing: #{dirty}"

    archive = Path.join(root, "source.tar")

    {_output, 0} =
      System.cmd("git", ["archive", "--format=tar", "-o", archive, committed], cd: repository)

    extracted = Path.join(root, "source")
    File.mkdir_p!(extracted)
    {_output, 0} = System.cmd("tar", ["-xf", archive, "-C", extracted])

    refute File.exists?(Path.join(extracted, "_build"))
    refute File.exists?(Path.join(extracted, "deps"))
    refute File.exists?(Path.join(extracted, ".git"))
    assert File.exists?(Path.join(extracted, "mix.exs"))
    assert File.exists?(Path.join([extracted, "clients", "node", "workflow.mjs"]))
    assert File.exists?(Path.join([extracted, "clients", "node", "interaction-workflow.mjs"]))

    IO.puts(:stderr, "extracted candidate: #{committed}")
    extracted
  end

  @doc """
  ## Concept

  Runs the build the operator guide names, inside the extraction.

  ## Technical depth

  The build is named into the extraction itself: a runner that exports
  `MIX_BUILD_ROOT` to isolate its own lanes would otherwise send these beams to
  that root and leave the extraction with nothing for a consumer to load, and
  `MIX_BUILD_PATH` is cleared because it outranks `MIX_BUILD_ROOT` and a runner
  that sets it would have this build overwrite that runner's own beams.

  The provider credential is removed from the build's environment. Nothing here
  needs one, the companion build in this repository scrubs it deliberately, and
  a compile that carried one would be the one place a credential could reach a
  subprocess that has no business with it.
  """
  @spec build!(binary(), binary()) :: :ok
  def build!(extracted, mix) when is_binary(extracted) and is_binary(mix) do
    repository = repository_root()

    deps =
      Path.expand(System.get_env("MIX_DEPS_PATH") || Path.join(repository, "deps"), repository)

    File.cp_r!(deps, Path.join(extracted, "deps"))

    {output, status} =
      System.cmd(mix, ["compile"],
        cd: extracted,
        stderr_to_stdout: true,
        env: [
          {"MIX_ENV", "prod"},
          {"MIX_BUILD_PATH", nil},
          {"MIX_BUILD_ROOT", Path.join(extracted, "_build")},
          {"MIX_DEPS_PATH", Path.join(extracted, "deps")},
          {"LOOPEX_PROVIDER_API_KEY", nil}
        ]
      )

    assert status == 0, "the extracted source did not build: #{output}"

    for application <- @applications do
      assert File.dir?(Path.join([extracted, "_build", "prod", "lib", application, "ebin"])),
             "#{application} is missing from the extracted build"
    end

    :ok
  end

  @doc """
  ## Concept

  An owned temporary root outside the checkout, resolved to its physical path.

  ## Technical depth

  On this platform the temporary directory is reached through a symlink, and Mix
  computes a dependency's `priv` link between two spellings of the same place,
  which breaks a build beneath an unresolved root. Resolving once here keeps
  every path below it physical.
  """
  @spec owned_root(binary()) :: binary()
  def owned_root(label) when is_binary(label) do
    {physical, 0} = System.cmd("pwd", ["-P"], cd: System.tmp_dir!())
    nonce = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(String.trim(physical), "loopex-m4-#{label}-#{nonce}")
    File.mkdir!(root)
    root
  end

  @doc """
  ## Concept

  A launch configuration a host can read and no provider can be started from.

  ## Technical depth

  It carries the four managed options in the term form the companion build
  emits, so consulting it succeeds, and it names a worker that does not exist,
  so a case that reached a dispatch fails loudly rather than quietly contacting
  something. It exists so a credential-free case can still launch the shipped
  host, which requires a readable configuration like any other input.
  """
  @spec absent_companion_launch!(binary()) :: binary()
  def absent_companion_launch!(root) when is_binary(root) do
    path = Path.join(root, "absent-companion.launch")

    File.write!(path, """
    [{worker_path,"#{Path.join(root, "no-such-companion")}"},
     {interpreter_path,"#{Path.join(root, "no-such-escript")}"},
     {worker_sha256,"#{String.duplicate("0", 64)}"},
     {build_manifest_sha256,"#{String.duplicate("0", 64)}"}].
    """)

    path
  end

  @doc false
  @spec repository_root() :: binary()
  def repository_root, do: Path.expand(Path.join([__DIR__, "..", "..", "..", ".."]))
end
