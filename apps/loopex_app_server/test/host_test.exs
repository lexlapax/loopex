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
  because this host only establishes that a credential is present and never
  reads its value; the adapter reads the variable itself, later, and none of
  these cases reaches a dispatch. The provider launch configuration names a
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

    System.cmd(elixir, arguments,
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
      :loopex_store_local,
      :loopex_executor_local,
      :telemetry
    ]

  defp ebin(application) do
    path = Application.app_dir(application, "ebin")
    assert File.dir?(path)
    path
  end
end
