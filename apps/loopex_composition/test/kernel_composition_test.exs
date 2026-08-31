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

  test "the composition forwards the executor's declared cleanup period and probe" do
    # Concept: ADR 0009 asks for the cleanup grace to be a declared *session*
    # configuration value. A period only a host that hand-builds an executor can
    # set is not that, and the shipped composition neither accepted nor forwarded
    # it, so a reference embedder and the command-line operator both got the
    # default and could not choose another.
    #
    # Technical depth: the caller-local observer runs the exact public `start/1`
    # path and delegates both edge calls to their real constructors. It observes
    # the options at the decision boundary without adding a runtime accessor or
    # making a provider call.
    {state_root, workspace} = roots()
    process_probe = Path.join(workspace, "process-probe")
    File.write!(process_probe, "#!/bin/sh\nexit 0\n")
    File.chmod!(process_probe, 0o700)

    captured =
      capture_edges(
        runtime_id: "forwarded",
        state_root: state_root,
        workspace: workspace,
        policy: Embedder,
        cleanup_grace_ms: 137,
        process_probe: process_probe
      )

    runtime_options = Map.fetch!(captured, Loopex)
    executor_options = Map.fetch!(captured, Loopex.Executor.Local)

    assert Keyword.fetch!(runtime_options, :cleanup_grace_ms) == 137
    assert Keyword.fetch!(executor_options, :cleanup_grace_ms) == 137
    assert Keyword.fetch!(executor_options, :process_probe) == process_probe

    runtime_executor = Keyword.fetch!(runtime_options, :executor)
    assert runtime_executor.workspace_ref =~ ~r/^workspace:[0-9a-f]{64}$/
    refute runtime_executor.workspace_ref == workspace
    assert Keyword.fetch!(executor_options, :workspace_leases)["workspace"]
    refute contains_exact?(runtime_options, workspace)
    refute contains_exact?(executor_options, workspace)

    # Concept: the cleanup period reaches the session as well as the hand.
    #
    # Forwarded rather than defaulted: keys the host did not supply stay absent,
    # so the one default each owning port declares applies.
    {default_root, default_workspace} = roots()

    defaults =
      capture_edges(
        runtime_id: "defaults",
        state_root: default_root,
        workspace: default_workspace,
        policy: Embedder
      )

    refute Keyword.has_key?(Map.fetch!(defaults, Loopex), :cleanup_grace_ms)
    refute Keyword.has_key?(Map.fetch!(defaults, Loopex.Executor.Local), :cleanup_grace_ms)
    refute Keyword.has_key?(Map.fetch!(defaults, Loopex.Executor.Local), :process_probe)
  end

  test "required host inputs are validated before the first effect" do
    edge_observer = :"$loopex_composition_edge_observer"
    effect_observer = :"$loopex_composition_effect_observer"

    refuse_effect = fn module, function, _arguments ->
      flunk("#{module}.#{function} caused an effect")
    end

    Process.put(edge_observer, refuse_effect)
    Process.put(effect_observer, refuse_effect)

    try do
      assert {:error, :host_policy_required} =
               LoopexComposition.start(
                 runtime_id: "prevalidated",
                 state_root: "/unused",
                 workspace: "/unused"
               )

      assert {:error, {:invalid_composition_option, :state_root}} =
               LoopexComposition.start(
                 runtime_id: "prevalidated",
                 workspace: "/unused",
                 policy: Embedder
               )

      assert {:error, {:invalid_composition_option, :workspace}} =
               LoopexComposition.start(
                 runtime_id: "prevalidated",
                 state_root: "/unused",
                 policy: Embedder
               )

      assert {:error, {:invalid_composition_option, :runtime_id}} =
               LoopexComposition.start(
                 state_root: "/unused",
                 workspace: "/unused",
                 policy: Embedder
               )
    after
      Process.delete(edge_observer)
      Process.delete(effect_observer)
    end
  end

  test "a later error raise or exit cleans every process acquired before it" do
    cases = [
      {Loopex.Executor.Local.WorkspaceLease, :error},
      {Loopex.Executor.Local, :raise},
      {Loopex, :exit}
    ]

    for {failed_module, failure} <- cases do
      {state_root, workspace} = roots()

      {captured, stopped} =
        capture_start_failure(state_root, workspace, failed_module, failure)

      expected =
        Enum.take(
          [Loopex.Store.Local, Loopex.Executor.Local.WorkspaceLease, Loopex.Executor.Local],
          length(captured)
        )

      assert Enum.map(captured, &elem(&1, 0)) == expected
      assert stopped == Enum.reverse(expected)
      for {_module, pid} <- captured, do: refute(Process.alive?(pid))
    end
  end

  test "stopping the runtime releases the composition owner and every private process" do
    {state_root, workspace} = roots()
    test = self()
    marker = make_ref()
    observer = :"$loopex_composition_edge_observer"

    Process.put(observer, fn module, function, arguments ->
      result = apply(module, function, arguments)
      send(test, {marker, self(), module, result})
      result
    end)

    try do
      assert {:ok, runtime} =
               LoopexComposition.start(
                 runtime_id: "owned-stack",
                 state_root: state_root,
                 workspace: workspace,
                 policy: Embedder
               )

      acquired =
        for _ <- 1..4 do
          assert_receive {^marker, owner, module, result}
          {owner, module, result}
        end

      [owner] = acquired |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      owner_monitor = Process.monitor(owner)

      assert :ok = Loopex.stop(runtime)
      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 2_000
      refute Loopex.Runtime.alive?(runtime)

      for {_owner, module, {:ok, pid}} <- acquired, module != Loopex do
        refute Process.alive?(pid)
      end
    after
      Process.delete(observer)
    end
  end

  test "abnormal runtime death releases the composition owner and every private process" do
    {state_root, workspace} = roots()
    test = self()
    marker = make_ref()
    observer = :"$loopex_composition_edge_observer"

    Process.put(observer, fn module, function, arguments ->
      result = apply(module, function, arguments)
      send(test, {marker, self(), module, result})
      result
    end)

    try do
      assert {:ok, runtime} =
               LoopexComposition.start(
                 runtime_id: "abnormal-owned-stack",
                 state_root: state_root,
                 workspace: workspace,
                 policy: Embedder
               )

      acquired =
        for _ <- 1..4 do
          assert_receive {^marker, owner, module, result}
          {owner, module, result}
        end

      [owner] = acquired |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      owner_monitor = Process.monitor(owner)

      Process.exit(runtime.supervisor, :kill)

      assert_receive {:DOWN, ^owner_monitor, :process, ^owner, :normal}, 2_000
      refute Loopex.Runtime.alive?(runtime)

      for {_owner, module, {:ok, pid}} <- acquired, module != Loopex do
        refute Process.alive?(pid)
      end
    after
      Process.delete(observer)
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

  defp capture_edges(options) do
    marker = make_ref()
    test = self()

    Process.put(:"$loopex_composition_edge_observer", fn module,
                                                         function,
                                                         [edge_options] = args ->
      if module in [Loopex, Loopex.Executor.Local],
        do: send(test, {marker, module, edge_options})

      apply(module, function, args)
    end)

    try do
      assert {:ok, runtime} = LoopexComposition.start(options)

      try do
        for _ <- 1..2, into: %{} do
          assert_receive {^marker, module, edge_options}
          {module, edge_options}
        end
      after
        Loopex.stop(runtime)
      end
    after
      Process.delete(:"$loopex_composition_edge_observer")
    end
  end

  defp capture_start_failure(state_root, workspace, failed_module, failure) do
    test = self()
    marker = make_ref()
    observer = :"$loopex_composition_edge_observer"
    effect_observer = :"$loopex_composition_effect_observer"

    Process.put(observer, fn module, function, arguments ->
      if module == failed_module do
        case failure do
          :error -> {:error, :injected_failure}
          :raise -> raise "injected failure"
          :exit -> exit(:injected_failure)
        end
      else
        {:ok, pid} = result = apply(module, function, arguments)
        send(test, {marker, module, pid})
        result
      end
    end)

    Process.put(effect_observer, fn module, function, arguments ->
      result = apply(module, function, arguments)

      if module == Process and function == :exit do
        [pid, :shutdown] = arguments
        send(test, {marker, :stopped, pid})
      end

      result
    end)

    try do
      assert {:error, _reason} =
               LoopexComposition.start(
                 runtime_id: "failure-#{failure}",
                 state_root: state_root,
                 workspace: workspace,
                 policy: Embedder
               )

      count =
        Enum.find_index(
          [
            Loopex.Store.Local,
            Loopex.Executor.Local.WorkspaceLease,
            Loopex.Executor.Local,
            Loopex
          ],
          &(&1 == failed_module)
        )

      acquired =
        for _ <- 1..count do
          assert_receive {^marker, module, pid}
          {module, pid}
        end

      stopped =
        for _ <- 1..count do
          assert_receive {^marker, :stopped, pid}
          {module, ^pid} = Enum.find(acquired, &(elem(&1, 1) == pid))
          module
        end

      {acquired, stopped}
    after
      Process.delete(observer)
      Process.delete(effect_observer)
    end
  end

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

  defp contains_exact?(term, target) when term == target, do: true

  defp contains_exact?(term, target) when is_map(term),
    do:
      term
      |> Map.to_list()
      |> Enum.any?(fn {key, value} ->
        contains_exact?(key, target) or contains_exact?(value, target)
      end)

  defp contains_exact?(term, target) when is_list(term),
    do: Enum.any?(term, &contains_exact?(&1, target))

  defp contains_exact?(term, target) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains_exact?(target)

  defp contains_exact?(_term, _target), do: false
end
