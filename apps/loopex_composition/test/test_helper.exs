Code.require_file("../../loopex/test/support/configured_genesis_helper.exs", __DIR__)

defmodule LoopexComposition.TestHost do
  @moduledoc false

  alias Loopex.LLM.ReqLLM

  @credential "loopex-composition-test-credential"

  def start(options), do: with_credential(fn -> LoopexComposition.start(options) end)

  def with_runtime(options, callback),
    do: with_credential(fn -> LoopexComposition.with_runtime(options, callback) end)

  defp with_credential(function) do
    variable = ReqLLM.credential_variable()
    System.put_env(variable, @credential)

    try do
      function.()
    after
      System.delete_env(variable)
    end
  end
end

defmodule LoopexComposition.PreparedSessionFixture do
  @moduledoc false

  def capture(configuration) do
    {:ok, genesis} =
      LoopexComposition.Ephemeral.Preflight.genesis(
        configuration,
        configuration.cwd,
        %{"ollama" => %{"credential" => %{"none" => true}}}
      )

    configuration
    |> Map.put(:genesis, genesis)
    |> Map.put(:model, genesis["initial_configuration"]["model"])
    |> Map.put(:context_token_budget, genesis["initial_configuration"]["context_token_budget"])
  end
end

defmodule LoopexComposition.StartupStatusFixture do
  @moduledoc false

  # Concept: fake-runtime phase tests explicitly supply their new startup proof.
  # Technical depth: this seam is used only where a test starts a fake supervisor.
  # Real Memory/Local acquisition tests always read the original Core snapshot.
  def ready(_runtime, _timeout) do
    {:ok,
     %{state: :ready, startup_id: <<0::256>>,
       startup_deadline_ms: System.monotonic_time(:millisecond) + 1_000}}
  end
end

defmodule LoopexComposition.StartupAcquisitionTest.WithoutStartupRead do
  @moduledoc false
  @behaviour Loopex.Store

  for {function, arity} <- [
        transact: 2, transaction_status: 4, runtime_command: 2,
        ownership_head: 3, load_records: 4, load_events: 4
      ] do
    arguments = Macro.generate_arguments(arity - 1, __MODULE__)
    @impl true
    def unquote(function)(reference, unquote_splicing(arguments)),
      do: apply(LoopexComposition.StartupAcquisitionTest.HeldStore,
                unquote(function), [reference, unquote_splicing(arguments)])
  end
end

# Concept: acquisition reads the actual Core barrier over the actual Store.
# Technical depth: the wrapper holds its first startup read before delegating
# unchanged data to Local or Memory. All mutation and custody remain real.
defmodule LoopexComposition.StartupAcquisitionTest.HeldStore do
  @moduledoc false
  @behaviour Loopex.Store

  for {function, arity} <- [
        transact: 2, transaction_status: 4, runtime_command: 2,
        ownership_head: 3, load_records: 4, load_events: 4,
        creation_provenance: 3
      ] do
    arguments = Macro.generate_arguments(arity - 1, __MODULE__)
    @impl true
    def unquote(function)(reference, unquote_splicing(arguments)),
      do: delegate(reference, unquote(function), [unquote_splicing(arguments)])
  end

  @impl true
  def creation_recovery(reference, request) do
    if :atomics.add_get(reference.reads, 1, 1) == 1 do
      send(reference.test, {:startup_read, self(), request})
      receive do: (:release_startup -> :ok)
    end

    delegate(reference, :creation_recovery, [request])
  end

  defp delegate(reference, function, arguments),
    do: apply(reference.store.adapter, function, [reference.store.reference | arguments])
end

# Concept: actual restore deadline proofs run in the release long-bound lane.
# Technical depth: the ordinary suite excludes their tag; the required release
# selection overrides it and retains the unchanged production cutoff assertions.
ExUnit.start(exclude: [:real_provider, :long_bound])
