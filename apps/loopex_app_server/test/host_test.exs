defmodule Loopex.AppServer.HostTest do
  @moduledoc """
  ## Concept

  The shipped host's launch contract, exercised the way an operator meets it: a
  real process, started with the entry point the operator guide prints, reading
  the inputs the guide names from its own environment.

  Every input has a refusal, and each one says which variable is missing and
  what it is for before anything is composed. The workspace reference an
  operator needs for a trust decision is answered by the same module, from the
  same input.

  ## Technical depth

  No credential is spent here. `LOOPEX_PROVIDER_API_KEY` carries a placeholder,
  which the composition owner consumes into private custody and deletes before
  it publishes a runtime; none of these cases reaches a dispatch. The provider
  launch configuration names a
  companion that is not on disk for the same reason: the host consults the file,
  and nothing here starts a provider.

  Each case runs the process to completion and asserts its exit status rather
  than driving the protocol, because a refusal has no protocol — it is a line on
  standard error and a status an operator's shell can branch on. The cases that
  do serve a connection live in `external_workflow_test.exs`.
  """

  use ExUnit.Case, async: false

  alias LoopexComposition.WorkspaceIdentity

  @moduletag timeout: 120_000

  @serve "Loopex.AppServer.Host.serve()"
  @reference "IO.write(Loopex.AppServer.Host.workspace_reference!())"

  # Concept: the placeholder that stands where an operator's credential would be.
  #
  # Technical depth: it is deliberately not shaped like a provider key. Nothing
  # in these cases sends it anywhere, and a value that looked real would invite
  # a reader to wonder whether it had been.
  @placeholder "not-a-real-credential"

  describe "refusing a launch" do
    test "an absent state root is named, and nothing is composed without one" do
      {output, status} = serve(%{"LOOPEX_HOME" => nil})

      assert status == 3
      assert output =~ "LOOPEX_HOME is required"
      assert output =~ "state root"
    end

    test "an absent workspace is named" do
      {output, status} = serve(%{"LOOPEX_WORKSPACE" => nil})

      assert status == 3
      assert output =~ "LOOPEX_WORKSPACE is required"
    end

    test "a workspace that is not a directory is refused with the path it was given" do
      file = Path.join(root(), "not-a-directory")
      File.write!(file, "")
      {output, status} = serve(%{"LOOPEX_WORKSPACE" => file})

      assert status == 3
      assert output =~ "LOOPEX_WORKSPACE does not name a directory"
      assert output =~ file
    end

    test "an absent provider launch configuration is named" do
      {output, status} = serve(%{"LOOPEX_PROVIDER_LAUNCH" => nil})

      assert status == 3
      assert output =~ "LOOPEX_PROVIDER_LAUNCH is required"
    end

    test "a launch configuration that cannot be read as one is refused, not guessed at" do
      unreadable = Path.join(root(), "unreadable.launch")
      File.write!(unreadable, "this is not a launch configuration\n")
      {output, status} = serve(%{"LOOPEX_PROVIDER_LAUNCH" => unreadable})

      assert status == 3
      assert output =~ "LOOPEX_PROVIDER_LAUNCH does not name a readable launch configuration"
      assert output =~ unreadable
    end

    test "an absent policy is refused and the choices are named, because authority has no default" do
      {output, status} = serve(%{"LOOPEX_POLICY" => nil})

      assert status == 3
      assert output =~ "LOOPEX_POLICY is required"
      assert output =~ "allow-all"
      assert output =~ "ask"
    end

    test "a policy this host does not ship is refused rather than falling back" do
      {output, status} = serve(%{"LOOPEX_POLICY" => "allow-everything"})

      assert status == 3
      assert output =~ "LOOPEX_POLICY must be one of"
      assert output =~ "allow-everything"
    end

    test "an absent credential refuses at launch rather than at the first dispatch" do
      {output, status} = serve(%{"LOOPEX_PROVIDER_API_KEY" => nil})

      assert status == 3
      assert output =~ "LOOPEX_PROVIDER_API_KEY is required"
      assert output =~ "never passed on a command line"
    end

    # Concept: a refusal is one line about one input.
    #
    # Technical depth: a launch missing everything still names the first thing
    # to fix rather than printing a wall, and it never reaches the composition,
    # so no store is opened and no marker is claimed on the way to failing.
    test "a launch missing everything names one input and leaves the state root untouched" do
      home = Path.join(root(), "untouched")

      {output, status} =
        serve(%{
          "LOOPEX_HOME" => home,
          "LOOPEX_WORKSPACE" => nil,
          "LOOPEX_PROVIDER_LAUNCH" => nil,
          "LOOPEX_POLICY" => nil,
          "LOOPEX_PROVIDER_API_KEY" => nil
        })

      assert status == 3
      assert output =~ "LOOPEX_WORKSPACE is required"
      refute output =~ "LOOPEX_POLICY"
      refute File.exists?(Path.join(home, "store.log"))
    end
  end

  describe "explicit programmatic provider configuration" do
    test "whole-map and selected-route refusals precede state creation" do
      home = Path.join(root(), "uncreated-bindings")

      for options <- [
            [provider_bindings: %{"openai" => %{"credential" => %{"env" => "HOME"}}}],
            [provider_bindings: %{}],
            [provider_bindings: bindings(), model: "openrouter:unbound"],
            [provider_bindings: bindings(), maintenance_model: "openrouter:unbound"],
            [provider_bindings: bindings(), unexpected: true],
            [:malformed]
          ] do
        {output, status} =
          run("Loopex.AppServer.Host.serve(#{inspect(options)})", %{"LOOPEX_HOME" => home})

        assert status == 3
        assert output =~ "the programmatic provider configuration is invalid"
        refute output =~ "M7_SERVER"
        refute File.exists?(home)
      end
    end

    test "a missing named credential reports a fixed refusal without the reference" do
      {output, status} =
        run(
          "Loopex.AppServer.Host.serve(provider_bindings: #{inspect(bindings())}, model: \"openai:test\")",
          %{"M7_SERVER_A" => "server-first-canary", "M7_SERVER_B" => nil}
        )

      assert status == 3
      assert output =~ "a configured provider credential is unavailable"
      refute output =~ "M7_SERVER"
      refute output =~ "server-first-canary"
    end

    test "two routes and maintenance reach real composition and stop when input ends" do
      entry = """
      parent = self()
      names = ~w(LOOPEX_PROVIDER_API_KEY M7_SERVER_A M7_SERVER_B)
      Process.put(:"$loopex_composition_edge_observer", fn module, function, [options] = arguments ->
        if module == Loopex do
          unless Enum.all?(names, &(System.get_env(&1) == nil)), do: raise("credential not consumed")
          model = Keyword.fetch!(options, :model)
          unless model.model == "openai:test", do: raise("model not forwarded")
          unless model.module == LoopexComposition.Model, do: raise("model wrapper not forwarded")
          unless Keyword.fetch!(model.options, :adapter) == Loopex.LLM.ReqLLM, do: raise("model adapter not forwarded")
          adapter_options = Keyword.fetch!(model.options, :adapter_options)
          unless adapter_options[:excluded_env_names] == names, do: raise("exclusions not forwarded")
          unless map_size(adapter_options[:provider_routes]) == 2, do: raise("routes not forwarded")
          unless options[:maintenance_model]["reasoning"] == "none", do: raise("maintenance not forwarded")
          unless options[:active_tools] == [], do: raise("tool selection not forwarded")
        end
        result = apply(module, function, arguments)
        case result do
          {:ok, pid} when is_pid(pid) -> send(parent, {:owned, pid})
          {:ok, %Loopex.Runtime{supervisor: pid}} -> send(parent, {:owned, pid})
          _ -> :ok
        end
        result
      end)
      :ok = Loopex.AppServer.Host.serve(
        provider_bindings: #{inspect(bindings())},
        model: "openai:test",
        maintenance_model: "anthropic:claude-haiku-4-5",
        active_tools: [])
      pids = Stream.repeatedly(fn -> receive do {:owned, pid} -> pid after 0 -> nil end end)
        |> Enum.take_while(&is_pid/1)
      unless length(pids) == 9 and Enum.all?(pids, &(not Process.alive?(&1))),
        do: raise("owned cleanup incomplete")
      IO.puts("explicit routes closed")
      """

      {output, status} =
        run(
          entry,
          %{
            "M7_SERVER_A" => "server-first-canary",
            "M7_SERVER_B" => "server-second-canary"
          },
          stdin_eof: true
        )

      assert status == 0, output
      assert output =~ "explicit routes closed"
      refute output =~ "server-first-canary"
      refute output =~ "server-second-canary"
    end
  end

  describe "configuring across real routes" do
    # Concept: a foreground client configures across real host routes without
    # learning them. Technical depth: accepted ADR 0050 over /3 with two bound
    # provider routes in the shipped host. An authored alias resolves to the
    # bound provider's canonical model, an unbound provider refuses, and no
    # record on stdout carries a route, binding, credential or host option.
    test "stdio configure resolves real bound routes without disclosing host-only data" do
      entry = """
      :ok = Loopex.AppServer.Host.serve(
        provider_bindings: #{inspect(bindings())},
        model: "openai:test",
        active_tools: [])
      """

      port =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          :binary,
          :exit_status,
          {:line, 4_194_304},
          {:args, Enum.flat_map(applications(), &["-pa", ebin(&1)]) ++ ["-e", entry]},
          {:env,
           for(
             {name, value} <-
               environment(%{
                 "M7_SERVER_A" => "server-first-canary",
                 "M7_SERVER_B" => "server-second-canary"
               }),
             do: {String.to_charlist(name), String.to_charlist(value)}
           )}
        ])

      ask = fn request ->
        true = Port.command(port, JSON.encode!(request) <> "\n")
        await_reply(port, request["request_id"], [])
      end

      init = %{
        "method" => "initialize",
        "request_id" => "init",
        "generations" => ["loopex.experimental/3"],
        "capabilities" => []
      }

      replies = ask.(init)

      created =
        ask.(%{
          "method" => "session.create",
          "request_id" => "create",
          "command_id" => "Y3JlYXRl",
          "session_options" => %{"version" => 1}
        })

      session = reply_to(created, "create")["session_id"]

      attached =
        ask.(%{"method" => "session.attach", "request_id" => "attach", "session_id" => session})

      assert reply_to(attached, "attach")["type"] == "snapshot"

      unbound =
        ask.(%{
          "method" => "session.configure",
          "request_id" => "unbound",
          "command_id" => "dW5ib3VuZA",
          "changes" => %{"model" => "google:gemini-unbound"}
        })

      assert reply_to(unbound, "unbound")["status"] == "refused"

      bound =
        ask.(%{
          "method" => "session.configure",
          "request_id" => "bound",
          "command_id" => "Ym91bmQ",
          "changes" => %{"model" => "anthropic:claude-haiku-4-5"}
        })

      assert reply_to(bound, "bound")["status"] == "accepted"

      inspected =
        ask.(%{"method" => "session.inspect", "request_id" => "inspect", "session_id" => session})

      assert reply_to(inspected, "inspect")["type"] == "result"
      Port.close(port)

      records = replies ++ created ++ attached ++ unbound ++ bound ++ inspected

      [change | _] =
        for %{"event" => %{"kind" => "session.configured", "data" => data}} <- records, do: data

      assert change["configuration"]["model"] == "anthropic:claude-haiku-4-5-20251001"
      public = inspect(records, limit: :infinity)

      for private <-
            ~w(M7_SERVER canary credential provider_mapping model_capabilities provider_bindings) do
        refute public =~ private, private
      end
    end
  end

  defp reply_to(records, id), do: Enum.find(records, &(&1["request_id"] == id))

  defp await_reply(port, id, records) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        assert {:ok, record} = LoopexProtocol.Frame.decode(line, 4_194_304)
        records = records ++ [record]

        if record["request_id"] == id and record["type"] != "progress",
          do: drain_events(port, records),
          else: await_reply(port, id, records)

      {^port, {:exit_status, status}} ->
        flunk("the host exited #{status} before #{id}: #{inspect(records)}")
    after
      15_000 -> flunk("no reply to #{id}: #{inspect(records)}")
    end
  end

  # Events committed by a request may follow its reply; collect what arrives
  # within a short quiet window so the privacy scan sees them too.
  defp drain_events(port, records) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        assert {:ok, record} = LoopexProtocol.Frame.decode(line, 4_194_304)
        drain_events(port, records ++ [record])
    after
      300 -> records
    end
  end

  defp bindings,
    do: %{
      "openai" => %{"credential" => %{"env" => "M7_SERVER_A"}},
      "anthropic" => %{"credential" => %{"env" => "M7_SERVER_B"}}
    }

  describe "answering the workspace reference" do
    test "the host answers the reference a trust decision must carry" do
      workspace = workspace()

      {output, status} =
        run(@reference, %{"LOOPEX_WORKSPACE" => workspace}, stderr_to_stdout: false)

      assert status == 0
      assert String.match?(output, ~r/\Aworkspace:[0-9a-f]{64}\z/)

      # The same value the composition derives, which is the one the runtime
      # binds a decision against. A client cannot compute it, which is why the
      # host answers it.
      assert {:ok, ^output} = WorkspaceIdentity.reference(workspace)
    end

    test "a shell substituting the reference gets a refusal rather than an empty string" do
      {output, status} = run(@reference, %{"LOOPEX_WORKSPACE" => nil})

      assert status == 3
      assert output =~ "LOOPEX_WORKSPACE is required"
    end
  end

  defp serve(overrides), do: run(@serve, overrides)

  defp run(entry, overrides, options \\ []) do
    elixir = System.find_executable("elixir") || flunk("Elixir executable unavailable")

    arguments =
      Enum.flat_map(applications(), &["-pa", ebin(&1)]) ++ ["-e", entry]

    {executable, arguments} =
      if Keyword.get(options, :stdin_eof, false) do
        {"/bin/sh", ["-c", ~S(exec "$@" </dev/null), "loopex-host-test", elixir | arguments]}
      else
        {elixir, arguments}
      end

    System.cmd(executable, arguments,
      env: environment(overrides),
      stderr_to_stdout: Keyword.get(options, :stderr_to_stdout, true)
    )
  end

  # Concept: a complete launch, with exactly one thing changed per case.
  #
  # Technical depth: an override of `nil` removes the variable from the child's
  # environment whatever this test process inherited, which is what makes
  # "absent" mean absent on a developer machine that exports one of these.
  defp environment(overrides) do
    root = root()

    defaults = %{
      "LOOPEX_HOME" => Path.join(root, "home"),
      "LOOPEX_WORKSPACE" => workspace(),
      "LOOPEX_PROVIDER_LAUNCH" => launch_configuration(),
      "LOOPEX_POLICY" => "ask",
      "LOOPEX_PROVIDER_API_KEY" => @placeholder,
      "ELIXIR_ERL_OPTIONS" => "-noinput"
    }

    defaults |> Map.merge(overrides) |> Map.to_list()
  end

  # Concept: a launch configuration this host can read and no provider can be
  # started from.
  #
  # Technical depth: it carries the four managed options in the term form the
  # companion build emits, so consulting it succeeds, and it names a worker that
  # does not exist, so a case that accidentally reached a dispatch would fail
  # loudly rather than quietly contacting something.
  defp launch_configuration do
    path = Path.join(root(), "absent-companion.launch")

    File.write!(path, """
    [{worker_path,"#{Path.join(root(), "no-such-companion")}"},
     {interpreter_path,"#{Path.join(root(), "no-such-escript")}"},
     {worker_sha256,"#{String.duplicate("0", 64)}"},
     {build_manifest_sha256,"#{String.duplicate("0", 64)}"}].
    """)

    path
  end

  defp workspace do
    path = Path.join(root(), "workspace")
    File.mkdir_p!(path)
    path
  end

  # Concept: one owned root per case, removed afterwards.
  defp root do
    case Process.get(:host_test_root) do
      nil ->
        path =
          Path.join(System.tmp_dir!(), "loopex-host-#{System.unique_integer([:positive])}")

        File.mkdir_p!(path)
        Process.put(:host_test_root, path)
        on_exit(fn -> File.rm_rf(path) end)
        path

      path ->
        path
    end
  end

  defp applications,
    do: [
      :loopex_protocol,
      :loopex,
      :loopex_app_server,
      :loopex_composition,
      :loopex_llm_reqllm,
      :loopex_store_local,
      :loopex_executor_local,
      :telemetry,
      :llm_db,
      :jason
    ]

  defp ebin(application) do
    path = Application.app_dir(application, "ebin")
    assert File.dir?(path)
    path
  end
end
