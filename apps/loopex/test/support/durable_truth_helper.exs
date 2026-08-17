defmodule LoopexTest.DurableTruth do
  @moduledoc """
  ## Concept

  Shared scaffolding for the durable-truth tests: isolated journal paths, a
  deterministic generator, a collector that counts what crossed the dispatch and
  publication boundaries, and an induced restart.

  It is scaffolding only. It asserts nothing and decides nothing; the tests own
  every claim.

  ## Technical depth

  Loaded with `Code.require_file/2` from each test file rather than compiled
  through `:elixirc_paths`, so proving these two outcomes needs no change to
  `apps/loopex/mix.exs`. Requiring the same path twice is a no-op, so both test
  files may load it, and either protected selector runs on its own.

  The `_helper.exs` suffix matters: from Elixir 1.19 the test loader warns about
  any file under a test path that it neither loads nor ignores, and it ignores
  that suffix by default. Naming it so keeps the run warning-free without
  configuring an ignore filter.

  The generator is a seeded linear congruential sequence rather than a property
  library, because core carries no dependency. A fixed seed list makes a failure
  reproducible: the same seed produces the same history on every run and on both
  locked toolchains.
  """

  alias Loopex.Coordinator
  alias Loopex.Effect
  alias Loopex.Session

  # Technical depth: a minimal Lehmer generator. The modulus is prime and the
  # multiplier is a primitive root of it, so a nonzero seed never reaches zero and
  # the sequence does not collapse. Sufficient for choosing between a handful of
  # legal next steps; it makes no randomness claim beyond reproducibility.
  @modulus 2_147_483_647
  @multiplier 48_271

  @doc """
  ## Concept

  A journal path inside the test run's isolated state directory.

  ## Technical depth

  Rooted at `LOOPEX_HOME`, which `test_helper.exs` relocates into a temporary
  directory and removes at exit. Fetched rather than defaulted, so a test cannot
  quietly write a journal into real user state if the isolation ever stops
  being established.
  """
  def journal_path(name) do
    Path.join([
      System.fetch_env!("LOOPEX_HOME"),
      "journals",
      "#{name}-#{System.unique_integer([:positive])}.journal"
    ])
  end

  @doc """
  ## Concept

  The executor the tests expect effects to be dispatched to.

  ## Technical depth

  Plain data, fixed, so a mismatch in a test is a deliberate mutation rather
  than an accident of setup.
  """
  def executor, do: %{identity: "executor-a", epoch: 3, fencing_token: 11}

  @doc """
  ## Concept

  An effect request.

  ## Technical depth

  Carries exactly the five fields the digest covers, so a test that changes a
  request changes its digest and therefore its transaction id.
  """
  def request(operation_id, domain, payload, attempt \\ 1, domain_version \\ 1) do
    %{
      operation_id: operation_id,
      attempt: attempt,
      domain: domain,
      domain_version: domain_version,
      payload: payload
    }
  end

  @doc """
  ## Concept

  Starts a coordinator on a journal, recovering it if it already exists.

  ## Technical depth

  Linked, so a test process that traps exits observes a kill as an `{:EXIT, …}`
  message. Every test here traps exits for that reason.
  """
  def start(journal, session_id, collector) do
    Coordinator.start_link(
      journal: journal,
      session_id: session_id,
      dispatch_to: collector,
      executor: executor()
    )
  end

  @doc """
  ## Concept

  A live result that matches a journaled intent, and would therefore be
  admitted.

  ## Technical depth

  Built from the intent on disk rather than from the request, so a test that
  wants a rejection mutates one field of an otherwise admissible answer. A
  result assembled independently could be rejected for a field the test did not
  mean to change, which would prove nothing about the field it did.
  """
  def live_result(coordinator, tx_id, resolution, fact) do
    state = Coordinator.durable_state(coordinator)
    {:ok, intent} = Session.intent(state, tx_id)

    intent
    |> Map.take(admitted_fields())
    |> Map.merge(%{session_epoch: state.epoch, resolution: resolution, fact: fact})
  end

  @doc """
  ## Concept

  A reconciliation receipt that answers a specific query and would therefore be
  admitted.

  ## Technical depth

  Carries the current epoch as `:session_epoch` and the epoch the effect was
  dispatched under as `:session_epoch_at_dispatch`. Both are checked, and they
  differ whenever the effect outlived a restart, which is the ordinary case for
  a fenced effect.
  """
  def receipt(coordinator, tx_id, query_id, resolution, fact) do
    state = Coordinator.durable_state(coordinator)
    {:ok, intent} = Session.intent(state, tx_id)

    intent
    |> Map.take(admitted_fields())
    |> Map.merge(%{
      reconciliation_query_id: query_id,
      session_epoch: state.epoch,
      session_epoch_at_dispatch: Map.fetch!(intent, :epoch),
      resolution: resolution,
      fact: fact
    })
  end

  @doc """
  ## Concept

  The fields an outcome must match the journaled intent on.

  ## Technical depth

  Named here so the field-mutation properties iterate the same set the admission
  rules compare, and a field added to the rules without being added here shows
  up as an untested field rather than passing silently.
  """
  def admitted_fields do
    [
      :tx_id,
      :operation_id,
      :attempt,
      :canonical_request_digest,
      :executor_identity,
      :executor_epoch,
      :fencing_token
    ]
  end

  @doc """
  ## Concept

  Kills a coordinator and waits until it is gone.

  ## Technical depth

  `:kill` rather than a stop, because a clean shutdown is explicitly not
  evidence for either outcome. Drains the link exit so a later `assert_receive`
  in the same test is not answered by this kill.

  The caller must trap exits; otherwise the linked kill takes the test process
  with it.
  """
  def kill(coordinator) do
    reference = Process.monitor(coordinator)
    Process.exit(coordinator, :kill)

    receive do
      {:DOWN, ^reference, :process, ^coordinator, _reason} -> :ok
    after
      2_000 -> raise "coordinator #{inspect(coordinator)} survived a kill"
    end

    receive do
      {:EXIT, ^coordinator, _reason} -> :ok
    after
      200 -> :ok
    end
  end

  @doc """
  ## Concept

  Starts a process that records every dispatch and every publication it
  receives, in order.

  ## Technical depth

  A separate long-lived process rather than the test's own mailbox, so the count
  spans coordinator incarnations: a dispatch emitted by a coordinator that was
  later killed is still counted. That is what makes "never dispatched a second
  time" an assertion over the whole run rather than over one process's lifetime.
  """
  def start_collector do
    spawn_link(fn -> collect([], []) end)
  end

  defp collect(dispatches, publications) do
    receive do
      {:loopex_dispatch, payload} ->
        collect([payload | dispatches], publications)

      {:loopex_published, fact} ->
        collect(dispatches, [fact | publications])

      {:report, from, reference} ->
        send(from, {reference, report_of(dispatches, publications)})
        collect(dispatches, publications)
    end
  end

  defp report_of(dispatches, publications) do
    %{dispatches: Enum.reverse(dispatches), publications: Enum.reverse(publications)}
  end

  @doc """
  ## Concept

  What the collector has seen so far.

  ## Technical depth

  A synchronous round-trip, so the answer includes every message a returned
  coordinator call had already sent: a local `send/2` has placed the message in
  the target's mailbox before it returns, and this request is sent afterwards.
  """
  def report(collector) do
    reference = make_ref()
    send(collector, {:report, self(), reference})

    receive do
      {^reference, report} -> report
    after
      2_000 -> raise "collector #{inspect(collector)} did not report"
    end
  end

  @doc """
  ## Concept

  A reproducible generator state for a given integer seed.

  ## Technical depth

  Maps zero and multiples of the modulus away from the generator's fixed point,
  so every seed a test names produces a full sequence.
  """
  def seed(integer) when is_integer(integer) do
    case rem(abs(integer), @modulus) do
      0 -> 1
      other -> other
    end
  end

  @doc """
  ## Concept

  The next value and generator state.

  ## Technical depth

  Returns the state as the value too, which is all the callers need.
  """
  def next(state) do
    advanced = rem(state * @multiplier, @modulus)
    {advanced, advanced}
  end

  @doc """
  ## Concept

  Chooses one element of a non-empty list.

  ## Technical depth

  Uses the remainder rather than a scaled float, so the choice is identical on
  both locked toolchains and independent of floating-point behaviour.
  """
  def pick(state, choices) when choices != [] do
    {value, state} = next(state)
    {Enum.at(choices, rem(value, length(choices))), state}
  end

  @doc """
  ## Concept

  Generates a legal journal history of `count` records together with an
  independently tracked model of what that history means.

  Only records the reducer would accept are emitted, which is what makes the
  model an oracle: if replay disagrees with the model, one of them is wrong, and
  neither was derived from the other.

  ## Technical depth

  At each step the generator picks among the record kinds that are legal in the
  model's current state — a resolution is only offered when something is open,
  and an unknown outcome only when something is pending — so a run exercises
  every transition without ever producing a history no session could have had.

  The model computes the observable *values* a session should hold, not the sizes
  of the reducer's collections. Counting alone was not enough and a review proved
  it: storing `:committed` for every resolution while leaving fact handling
  correct turns failed effects into committed durable truth, and every count still
  agreed. Facts are therefore compared in order and by content, each transaction's
  resolution is compared individually, and the operation-to-transaction mapping is
  compared as a whole. The model still derives these from the emitted history
  rather than by calling the reducer, so it remains an independent calculation.
  """
  def history(seed_integer, count, session_id) do
    Enum.reduce(1..count, {seed(seed_integer), new_model(session_id), []}, fn _step,
                                                                              {rng, model, acc} ->
      {kind, rng} = pick(rng, legal_kinds(model))
      {record, model, rng} = emit(kind, model, rng)
      {rng, model, [record | acc]}
    end)
    |> then(fn {_rng, model, reversed} -> {Enum.reverse(reversed), model} end)
  end

  defp new_model(session_id) do
    %{
      session_id: session_id,
      seq: 0,
      epoch: 0,
      pending: [],
      unknown: [],
      resolved: %{},
      facts: [],
      operations: %{},
      intents: %{},
      operation_count: 0
    }
  end

  defp legal_kinds(model) do
    always = [:session_opened, :fact_committed, :effect_intent]
    open = model.pending ++ model.unknown

    always ++
      if(model.pending == [], do: [], else: [:effect_unknown]) ++
      if(open == [], do: [], else: [:effect_resolved])
  end

  defp emit(:session_opened, model, rng) do
    seq = model.seq + 1

    record = %{
      kind: :session_opened,
      seq: seq,
      session_id: model.session_id,
      epoch: model.epoch + 1
    }

    {record, %{model | seq: seq, epoch: model.epoch + 1}, rng}
  end

  defp emit(:fact_committed, model, rng) do
    seq = model.seq + 1
    fact = "fact-#{seq}"
    record = %{kind: :fact_committed, seq: seq, fact: fact}
    {record, %{model | seq: seq, facts: model.facts ++ [fact]}, rng}
  end

  defp emit(:effect_intent, model, rng) do
    {domain, rng} = pick(rng, [:workspace, :network])
    operations = model.operation_count + 1
    seq = model.seq + 1

    intent =
      request("op-#{operations}", domain, %{step: operations})
      |> Effect.intent(model.epoch, executor())
      |> Map.put(:seq, seq)

    tx_id = Map.fetch!(intent, :tx_id)

    model = %{
      model
      | seq: seq,
        operation_count: operations,
        operations: Map.put(model.operations, {"op-#{operations}", 1}, tx_id),
        intents: Map.put(model.intents, tx_id, intent),
        pending: model.pending ++ [tx_id]
    }

    {intent, model, rng}
  end

  defp emit(:effect_unknown, model, rng) do
    {tx_id, rng} = pick(rng, model.pending)
    seq = model.seq + 1
    record = %{kind: :effect_unknown, seq: seq, tx_id: tx_id}

    model = %{
      model
      | seq: seq,
        pending: List.delete(model.pending, tx_id),
        unknown: model.unknown ++ [tx_id]
    }

    {record, model, rng}
  end

  defp emit(:effect_resolved, model, rng) do
    {tx_id, rng} = pick(rng, model.pending ++ model.unknown)
    {resolution, rng} = pick(rng, [:committed, :failed])
    seq = model.seq + 1
    fact = "effect-#{seq}"
    record = %{kind: :effect_resolved, seq: seq, tx_id: tx_id, resolution: resolution, fact: fact}

    facts = if resolution == :committed, do: model.facts ++ [fact], else: model.facts

    model = %{
      model
      | seq: seq,
        pending: List.delete(model.pending, tx_id),
        unknown: List.delete(model.unknown, tx_id),
        resolved: Map.put(model.resolved, tx_id, resolution),
        facts: facts
    }

    {record, model, rng}
  end
end
