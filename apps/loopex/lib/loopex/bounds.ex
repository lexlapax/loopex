defmodule Loopex.Bounds do
  @moduledoc """
  ## Concept

  What stops a run that the model itself will not stop. Three bounds are
  declared with every run and committed with it: a maximum number of model
  turns, a cumulative token budget, and a wall-clock deadline.

  Reaching one is not a failure. A run that ends at a declared bound ends
  `bound_reached`, saying which bound and what was observed, because the run did
  exactly what it was configured to do. Recording that as a failure would tell
  an operator something untrue and would invite a retry of a run that is not
  broken.

  The deadline is different from the other two and is deliberately not smoothed
  into them. The other two are checked between turns and stop the run before
  another provider call. The deadline also bounds work already in flight, so
  reaching it can abort a request the provider may already have billed, and it
  can only be committed once every owned operation has reached a validated
  terminal fact and every owned process tree has been confirmed cleaned. Where
  either cannot be proved, the run ends `outcome_unknown` instead. A deadline is
  therefore not a guaranteed clean stop, and nothing here describes it as one.

  Fixed by
  [ADR 0010](../../../../docs/adr/0010-provider-continuation-and-context-staging.md#concept).

  ## Technical depth

  `decide/2` is checked in a fixed order, and the order carries meaning:

      last assistant message has no tool calls  -> :completed
      turn_number + 1 > max_turns               -> {:bound_reached, :max_turns}
      cumulative tokens >= token_budget         -> {:bound_reached, :token_budget}
      now >= deadline                           -> {:bound_reached, :deadline}
      otherwise                                 -> :continue

  The no-tool check is first and unconditional. A run whose model stopped on its
  own is `completed` and stays `completed`; a bound evaluated afterwards has
  nothing left to decide, and letting one win would report a run that finished
  normally as one that was cut off.

  Token accounting prefers what the provider reported and falls back to a
  conservative repository-owned estimate, recording which source was used. A
  turn that produced no complete reply — cancelled, deadline-aborted, or failed
  after dispatch — is charged its request bytes plus that turn's committed
  output allowance *in full*. That deliberately over-charges, because the
  alternative makes aborting every turn the cheapest way to stay inside a
  budget.
  """

  @bounds [:max_turns, :token_budget, :deadline]
  @sources [:reported, :estimated]

  @typedoc """
  ## Concept

  The three declared bounds and their committed values.

  ## Technical depth

  Every member is required. A runtime supplies a configured default for each, and
  a host that explicitly declares a malformed one is refused at start rather than
  quietly given the default: the defaults serve a host that said nothing, never
  one that said something wrong.
  """
  @type declared :: %{
          required(:max_turns) => pos_integer(),
          required(:token_budget) => pos_integer(),
          required(:deadline_ms) => pos_integer()
        }

  @typedoc """
  ## Concept

  What the turn machine should do next.

  ## Technical depth

  `{:bound_reached, bound, observed}` carries only the bound and the observed
  value, matching the vision's closed terminal algebra. The declared limit and
  the accounting source are recorded as sibling fields of the run's terminal
  record, beside the outcome rather than inside it.
  """
  @type decision ::
          :continue
          | :completed
          | {:bound_reached, atom(), non_neg_integer() | integer()}

  @doc """
  ## Concept

  The bound names.

  ## Technical depth

  Exposed so the locked bound-by-bound termination cases enumerate them from
  here rather than restating them.
  """
  @spec bounds() :: [atom()]
  def bounds, do: @bounds

  @doc """
  ## Concept

  The accounting sources a charged turn may record.

  ## Technical depth

  `:reported` is the provider's own usage. `:estimated` is the repository-owned
  conservative measurement, used when usage was absent, partial, or when the
  turn produced no complete reply at all.
  """
  @spec sources() :: [atom()]
  def sources, do: @sources

  @doc """
  ## Concept

  Validates and normalizes the declared bounds for a run.

  ## Technical depth

  Refuses a missing or non-positive bound rather than substituting one.

  The deadline is declared here as a *duration* and becomes an absolute instant
  exactly once, when the run's first turn commits its model-call intent. That
  split is not cosmetic. A command admission record must be a deterministic
  function of the command, because `commit_unknown` fencing re-presents it, and a
  record rebuilt with a fresh clock reading would no longer match the transaction
  the store is holding. Once the instant is fixed it is read back from committed
  history, so a recovering owner re-presents the deadline the run actually had
  rather than recomputing one that hands it back the downtime it slept through.

  `decide/2` therefore reads `:deadline`, the resolved instant, while `declare/1`
  validates `:deadline_ms`, the configured duration.
  """
  @spec declare(term()) :: {:ok, declared()} | {:error, term()}
  def declare(%{max_turns: max_turns, token_budget: token_budget, deadline_ms: deadline_ms})
      when is_integer(max_turns) and max_turns > 0 and
             is_integer(token_budget) and token_budget > 0 and
             is_integer(deadline_ms) and deadline_ms > 0 do
    {:ok, %{max_turns: max_turns, token_budget: token_budget, deadline_ms: deadline_ms}}
  end

  def declare(_bounds), do: {:error, :invalid_declared_bounds}

  @doc """
  ## Concept

  Decides whether the run continues, finished on its own, or reached a bound.

  ## Technical depth

  `:turn_number` is the turn just completed, `:tokens` the cumulative charge so
  far, and `:now` the observation instant supplied by the caller rather than
  read here, so the decision stays a pure function a property test can drive.
  """
  @spec decide(declared(), keyword()) :: decision()
  def decide(declared, observations) do
    tool_calls = Keyword.fetch!(observations, :tool_calls)
    turn_number = Keyword.fetch!(observations, :turn_number)
    tokens = Keyword.fetch!(observations, :tokens)
    now = Keyword.fetch!(observations, :now)

    # Concept: a missing deadline is a defect, not a run without one.
    #
    # Technical depth: Elixir orders numbers below atoms, so `now >= nil` is
    # quietly false and a deadline that never got committed would make that bound
    # silently unreachable — the one failure mode a bound must not have. Comparing
    # against a non-integer therefore raises here rather than returning
    # `:continue`.
    unless is_integer(declared.deadline) do
      raise ArgumentError,
            "the run deadline must be a committed instant, got: #{inspect(declared.deadline)}"
    end

    cond do
      tool_calls == [] -> :completed
      turn_number + 1 > declared.max_turns -> {:bound_reached, :max_turns, turn_number}
      tokens >= declared.token_budget -> {:bound_reached, :token_budget, tokens}
      now >= declared.deadline -> {:bound_reached, :deadline, now}
      true -> :continue
    end
  end

  @doc """
  ## Concept

  What one turn is charged against the token budget, and where the number came
  from.

  ## Technical depth

  Three cases, in the order they are tried:

  | Turn evidence | Charged | Source |
  | --- | --- | --- |
  | Reply carries provider usage | reported prompt plus completion totals | `:reported` |
  | Reply present, usage absent or partial | measured request bytes plus reply bytes | `:estimated` |
  | No complete reply at all | measured request bytes plus the committed `max_tokens` in full | `:estimated` |

  The estimator never returns fewer tokens than a provider would charge for the
  same content, because a bound that can be undercounted can be evaded.
  """
  @spec charge(map() | nil, binary(), pos_integer()) ::
          {non_neg_integer(), :reported | :estimated}
  def charge(reply, request_bytes, max_tokens)

  def charge(%{usage: %{"input_tokens" => input, "output_tokens" => output}}, _bytes, _max)
      when is_integer(input) and input >= 0 and is_integer(output) and output >= 0,
      do: {input + output, :reported}

  def charge(%{text: text}, request_bytes, _max_tokens) when is_binary(text),
    do: {estimate(request_bytes) + estimate(text), :estimated}

  def charge(nil, request_bytes, max_tokens),
    do: {estimate(request_bytes) + max_tokens, :estimated}

  def charge(_reply, request_bytes, max_tokens),
    do: {estimate(request_bytes) + max_tokens, :estimated}

  @doc """
  ## Concept

  The identity and version of the estimator, recorded beside every estimated
  charge.

  ## Technical depth

  Retained so a reviewer can tell which measurement produced a number, and so
  the prompt-budget measurement and the token accounting are visibly the same
  estimator rather than two that happen to agree today.

  ADR 0017 renames the identity to `loopex.context_bytes.v1`. The
  one-token-per-three-canonical-bytes algorithm is unchanged; the new name is
  what stops a retained measurement inheriting the superseded claim that this
  estimate never undercounts every provider tokenizer. It is deterministic
  admission policy, not a guarantee about a selected model.
  """
  @spec estimator() :: binary()
  def estimator, do: "loopex.context_bytes.v1"

  @doc """
  ## Concept

  A conservative token estimate over exact UTF-8 bytes.

  ## Technical depth

  Deliberately dependency-free: one token per three bytes, rounded up. Real
  tokenizers average closer to four bytes per token for prose, so this
  over-counts, which is the safe direction for a bound. A measurement needing a
  tokenizer dependency is out of budget, and an estimator that could undercount
  would make the budget evadable.
  """
  @spec estimate(binary()) :: non_neg_integer()
  def estimate(bytes) when is_binary(bytes), do: div(byte_size(bytes) + 2, 3)
end
