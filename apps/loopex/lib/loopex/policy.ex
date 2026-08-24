defmodule Loopex.Policy do
  @moduledoc """
  ## Concept

  The seam where a host says yes or no to an effect. Loopex owns the mechanics of
  running a tool; whether this tool, with these arguments, in this workspace, is
  allowed to run at all belongs to the host and to nobody else.

  Every executor-backed tool call consults this port. There is no effect class,
  no tool, and no argument shape that skips it — a read-only tool asks exactly as
  a process-spawning one does. That is not caution for its own sake: an exemption
  predicate would itself be a dispatch branch nothing policed, and the first
  question about any such branch is whether its condition is right.

  A denial is a truthful outcome, not a failure. It commits, the operator reads
  it, and the run continues or terminates honestly. It is never retried, because
  the host already answered.

  Fixed by
  [ADR 0009](../../../../docs/adr/0009-tool-executor-and-grant-contracts.md#concept).

  ## Technical depth

  One callback, not one per decision class. `{:defer, request}` is declared here
  and refused in M2: the interactive round trip it implies needs a durable
  interaction record, exact-response matching, expiry, and resume-after-restart
  evidence, none of which this milestone builds. Declaring it now means the shape
  a host returns does not change when that milestone arrives.

  Resolution is exhaustive and fails closed:

  | Observation | Resolution |
  | --- | --- |
  | `{:allow, context}` in the bounded shape or `nil` | grant issued |
  | `{:allow, context}` outside the bounded shape | `{:deny, :policy_unavailable}` |
  | `{:deny, category}` | durable denial, no dispatch |
  | `{:defer, _}` | `{:deny, :interaction_unsupported}` |
  | callback raises, exits, or times out | `{:deny, :policy_unavailable}` |
  | any other return shape | `{:deny, :policy_unavailable}` |

  Every one of those paths ends in a denial. A policy that is broken, slow, or
  wrong denies; it never falls through to allow. That direction is the whole
  point of the port, and it is why `decide/2` here catches rather than lets an
  exception propagate: a crashing policy must produce a decision, not take the
  session down with it.

  The request carries session and run identity, the resolved generation triple,
  validated arguments, effect class, idempotency class, and the workspace lease
  reference. It carries no pid, no credential, and no provider value, so a policy
  cannot be handed authority it was supposed to be granting.
  """

  @decision_timeout_ms 5_000

  @reason_categories [
    :policy_denied,
    :effect_class_not_permitted,
    :workspace_not_permitted,
    :interaction_unsupported,
    :policy_unavailable
  ]

  @max_decision_ref_bytes 256
  @max_attributes 16
  @max_attribute_bytes 1_024

  @typedoc """
  ## Concept

  What a host is asked to decide about.

  ## Technical depth

  Bounded plain data with atom keys. It names the call precisely enough for a
  host to apply its own rules and carries nothing a host could mistake for a
  capability.
  """
  @type request :: %{
          required(:session_id) => binary(),
          required(:run_id) => binary(),
          required(:tool_call_id) => binary(),
          required(:generation) => {binary(), binary(), binary()},
          required(:arguments) => map(),
          required(:effect_class) => binary(),
          required(:idempotency_class) => binary(),
          required(:workspace_lease) => binary()
        }

  @typedoc """
  ## Concept

  What a host may attach to an allow decision.

  ## Technical depth

  `decision_ref` is an opaque bounded binary the host assigns and Loopex never
  parses, joins, or interprets. `attributes` is a small bounded map. `nil` is a
  complete decision context; a host with nothing to add says nothing.
  """
  @type context :: %{optional(:decision_ref) => binary(), optional(:attributes) => map()} | nil

  @typedoc """
  ## Concept

  Why a call was refused.

  ## Technical depth

  A closed enumeration, so an operator reading a denial gets a category they can
  act on rather than free text that varies by host.
  """
  @type reason_category :: atom()

  @callback decide(request()) ::
              {:allow, context()} | {:deny, reason_category()} | {:defer, term()}

  @doc """
  ## Concept

  The refusal categories a denial may carry.

  ## Technical depth

  Exposed so conformance enumerates them from the boundary rather than
  restating them.
  """
  @spec reason_categories() :: [atom()]
  def reason_categories, do: @reason_categories

  @doc """
  ## Concept

  Asks the host, and turns anything that is not a well-formed allow into a
  denial.

  ## Technical depth

  Runs the callback in a supervised task so a policy that blocks cannot block the
  session owner, and so a policy that raises or exits produces a decision instead
  of a crash. The timeout is fixed rather than configurable: a host that wants
  longer to decide is a host that wants an interactive `defer`, which is a
  different decision this milestone declares and refuses.
  """
  @spec decide(module(), request()) :: {:allow, context()} | {:deny, reason_category()}
  def decide(module, request) when is_atom(module) and is_map(request) do
    task = Task.async(fn -> safely(module, request) end)

    case Task.yield(task, @decision_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, decision} -> decision
      _timeout_or_crash -> {:deny, :policy_unavailable}
    end
  end

  def decide(_module, _request), do: {:deny, :policy_unavailable}

  @doc """
  ## Concept

  Whether a term is a decision context this boundary will carry.

  ## Technical depth

  Bounded in every direction: an opaque reference of at most 256 bytes, at most
  sixteen attributes, and at most a kibibyte of canonically encoded attribute
  data. Nothing else is admitted — no pid, port, reference, function, nested
  structure, or unbounded binary — because a context crosses the durable
  boundary and is retained.
  """
  @spec valid_context?(term()) :: boolean()
  def valid_context?(nil), do: true

  def valid_context?(context) when is_map(context) and not is_struct(context) do
    reference = Map.get(context, :decision_ref)
    attributes = Map.get(context, :attributes, %{})

    Map.keys(context) -- [:decision_ref, :attributes] == [] and
      (is_nil(reference) or
         (is_binary(reference) and byte_size(reference) <= @max_decision_ref_bytes)) and
      bounded_attributes?(attributes)
  end

  def valid_context?(_context), do: false

  defp bounded_attributes?(attributes) when is_map(attributes) and not is_struct(attributes) do
    map_size(attributes) <= @max_attributes and
      Enum.all?(attributes, fn {key, value} ->
        is_binary(key) and (is_binary(value) or is_integer(value) or is_boolean(value))
      end) and
      byte_size(LoopexProtocol.Canonical.encode(attributes)) <= @max_attribute_bytes
  end

  defp bounded_attributes?(_attributes), do: false

  # Concept: anything that is not a well-formed allow is a denial.
  #
  # Technical depth: the rescue and catch are the point rather than defensive
  # noise. A policy that raises has not allowed anything, and the safe reading of
  # "I do not know" is no. Letting the exception escape would instead take down
  # the session owner, turning a host's bug into lost work.
  defp safely(module, request) do
    case module.decide(request) do
      {:allow, context} ->
        if valid_context?(context),
          do: {:allow, context},
          else: {:deny, :policy_unavailable}

      {:deny, category} when is_atom(category) ->
        {:deny, category}

      {:defer, _interaction} ->
        {:deny, :interaction_unsupported}

      _other ->
        {:deny, :policy_unavailable}
    end
  rescue
    _error -> {:deny, :policy_unavailable}
  catch
    _kind, _value -> {:deny, :policy_unavailable}
  end
end
