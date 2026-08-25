defmodule LoopexCompositionTest do
  @moduledoc false

  use ExUnit.Case, async: false

  # Concept: an embedder fixture that composes the kernel and depends on no
  # command application.
  #
  # Technical depth: this module is the independent fixture the outcome requires.
  # It reaches the runtime only through `LoopexComposition` and the public
  # `Loopex` facade, and this application declares no dependency on any client,
  # so the composition being usable without the command is a fact of the
  # dependency graph rather than a claim in prose.

  defmodule Embedder do
    @moduledoc false
    @behaviour Loopex.Policy

    @impl Loopex.Policy
    def decide(_request), do: {:allow, nil}

    def run(state_root, workspace, prompt) do
      with {:ok, runtime} <-
             LoopexComposition.start(
               runtime_id: "embedder",
               state_root: state_root,
               workspace: workspace,
               policy: __MODULE__
             ),
           {:ok, session_id} <-
             Loopex.create_session(runtime, %{"tenant" => "embedder"}, command_id: "create"),
           {:ok, attachment} <- Loopex.attach(runtime, session_id, after_event_sequence: 0),
           {:accepted, _id} <-
             Loopex.command(attachment, %{type: :prompt, command_id: "p1", content: prompt}) do
        {:ok, runtime, session_id, attachment}
      end
    end
  end

  defp roots do
    unique = System.unique_integer([:positive])
    state_root = Path.join(System.tmp_dir!(), "loopex-composition-#{unique}")
    workspace = Path.join(System.tmp_dir!(), "loopex-workspace-#{unique}")
    File.mkdir_p!(state_root)
    File.mkdir_p!(workspace)

    on_exit(fn ->
      File.rm_rf(state_root)
      File.rm_rf(workspace)
    end)

    {state_root, workspace}
  end

  test "one page of shipped code starts the application tree a runtime a session a prompt and its events" do
    {state_root, workspace} = roots()

    assert {:ok, runtime, session_id, attachment} =
             Embedder.run(state_root, workspace, "say hello")

    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end
    end)

    # A runtime, a session, an admitted prompt, and events an embedder can read:
    # the whole loop reached from one call. Whether the provider then answers is
    # a different claim, proved in the real-provider lane; this case is about the
    # composition reaching a working stack, and asserting a network call here
    # would make it fail for a missing credential rather than for wiring.
    assert is_binary(session_id)
    assert {:ok, event} = Loopex.next_event(attachment)
    assert event.kind == "user.message_appended"
    assert event["content"] == "say hello"

    assert {:ok, started} = Loopex.next_event(attachment)
    assert started.kind == "run.started"

    # And the page really is a page. The ceiling is part of the promise: the
    # vision requires that one page of code start a runtime, create a session,
    # submit a prompt, and consume events, and a module that quietly grew past
    # that would have stopped keeping it.
    effective = effective_lines("lib/loopex_composition.ex")

    assert length(effective) <= 80,
           "the composition module is #{length(effective)} effective lines; the ceiling is 80"
  end

  test "an independent embedder fixture composes the kernel without depending on the command application" do
    {state_root, workspace} = roots()

    assert {:ok, runtime, _session_id, _attachment} =
             Embedder.run(state_root, workspace, "independent")

    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end
    end)

    # This application declares no dependency on any client, so nothing here can
    # reach the command even accidentally. That is what makes the composition
    # something an embedder can depend on rather than something only the shipped
    # command can use.
    declared = declared_dependencies()
    refute :loopex_cli in declared
    refute :loopex_reference_client in declared
    assert :loopex in declared

    # And nothing in this application names the command, in source rather than in
    # code-path state: the umbrella suite runs every application in one emulator,
    # so whether a client module happens to be loadable there says nothing about
    # what this application depends on.
    for path <- Path.wildcard(app_path("lib/**/*.ex")) do
      refute File.read!(path) =~ "LoopexCli", "#{path} names the command application"
    end
  end

  test "the shipped composition requires a host supplied policy and ships no permissive default" do
    {state_root, workspace} = roots()

    # Omitting the policy refuses to start. A permissive default shipped here
    # would answer the host's authority question once for every embedder that
    # depends on this application, which is exactly the inheritance the two
    # shipped permissive policies exist in clients to avoid.
    assert {:error, :host_policy_required} =
             LoopexComposition.start(
               runtime_id: "no-policy",
               state_root: state_root,
               workspace: workspace
             )

    assert {:error, :host_policy_required} =
             LoopexComposition.start(
               runtime_id: "nil-policy",
               state_root: state_root,
               workspace: workspace,
               policy: nil
             )

    # No module in this application implements the policy behaviour, so there is
    # nothing here a host could accidentally inherit.
    {:ok, modules} = :application.get_key(:loopex_composition, :modules)

    refute Enum.any?(modules, fn module ->
             Code.ensure_loaded?(module) and
               function_exported?(module, :decide, 1)
           end)
  end

  test "the composition resolves its state root explicitly and never through application environment" do
    {state_root, workspace} = roots()

    # The caller supplies the root; nothing is discovered from application
    # environment, which is VM-global and would make two runtimes in one VM share
    # a state root neither of them named.
    assert {:ok, runtime, _session, _attachment} =
             Embedder.run(state_root, workspace, "explicit root")

    on_exit(fn ->
      try do
        Loopex.stop(runtime)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert File.exists?(Path.join(state_root, "store.log"))

    assert {:ok, %{module: _adapter, handle: %{root: artifact_root}}} =
             LoopexComposition.artifacts(state_root)

    assert String.starts_with?(artifact_root, state_root)

    # The source reads no application environment at all.
    source = File.read!(app_path("lib/loopex_composition.ex"))
    refute source =~ "Application.get_env"
    refute source =~ "Application.fetch_env"

    # And a second root is genuinely separate rather than shared.
    {other_root, other_workspace} = roots()
    assert other_root != state_root

    assert {:ok, other, _s, _a} = Embedder.run(other_root, other_workspace, "second")

    on_exit(fn ->
      try do
        Loopex.stop(other)
      catch
        :exit, _reason -> :ok
      end
    end)

    assert File.exists?(Path.join(other_root, "store.log"))
  end

  # Concept: count code, not the prose that explains it.
  #
  # Technical depth: the ceiling is about how much wiring an embedder has to
  # understand, not how well it is documented, so whole documentation blocks come
  # out rather than only their opening lines. Counting prose against the ceiling
  # would reward deleting the explanation, which is the opposite of what this
  # project asks of its code.
  # Concept: read the source this application is about, from wherever the case
  # was invoked.
  #
  # Technical depth: the gate compiles a protected selector from the repository
  # root, while `mix test` runs it from the application directory, so a relative
  # path names a different file in each. Resolving against the selector's own
  # location answers the same in both.
  defp app_path(relative), do: Path.expand(Path.join([__DIR__, "..", relative]))

  # The application's own declaration, read as source. `Mix.Project.config/0`
  # answers for whichever project is loaded, and under the gate none is.
  defp declared_dependencies do
    ~r/\{:([a-z_]+), in_umbrella: true\}/
    |> Regex.scan(File.read!(app_path("mix.exs")))
    |> Enum.map(fn [_match, name] -> String.to_atom(name) end)
  end

  defp effective_lines(path) do
    path
    |> app_path()
    |> File.read!()
    |> String.replace(~r/@(module)?doc """.*?"""\n/s, "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end
end
