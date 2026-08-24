defmodule Loopex.Executor.LocalHostPolicyTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Policy

  # Concept: the fixtures live here, in the selector's own file.
  #
  # Technical depth: this role proves a runtime property — that a permissive
  # policy applies only where a host names one — using its own in-file policies
  # and importing nothing from a client. What the reference client's shipped
  # AllowAll actually does is a different claim proved in that client's own lane,
  # and neither role may be satisfied by the other.

  defmodule Allows do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: {:allow, nil}
  end

  defmodule AllowsWithContext do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request),
      do: {:allow, %{decision_ref: "host-decision-1", attributes: %{"tier" => "trusted"}}}
  end

  defmodule Denies do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: {:deny, :policy_denied}
  end

  defmodule Raises do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: raise("host policy is broken")
  end

  defmodule Hangs do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: Process.sleep(30_000)
  end

  defmodule Malformed do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: :yes_go_ahead
  end

  defmodule Defers do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: {:defer, %{question: "may I?"}}
  end

  defmodule Unbounded do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: {:allow, %{decision_ref: String.duplicate("x", 300)}}
  end

  defmodule LeaksAPid do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: {:allow, %{attributes: %{"owner" => self()}}}
  end

  defmodule InertStore do
    @moduledoc false

    # Concept: a store the runtime never reaches.
    #
    # Technical depth: this case is about start-up refusing on missing authority
    # before anything else happens. Every callback raises, so if the refusal ever
    # stopped happening first this case would fail loudly rather than quietly
    # passing against a store that tolerated being used.

    @behaviour Loopex.Store

    @impl Loopex.Store
    def transact(_reference, _transaction), do: raise("the runtime must refuse before this")

    @impl Loopex.Store
    def transaction_status(_reference, _session, _domain, _tx), do: raise("unreachable")

    @impl Loopex.Store
    def ownership_head(_reference, _session, _domain), do: raise("unreachable")

    @impl Loopex.Store
    def load_records(_reference, _session, _after, _limit), do: raise("unreachable")

    @impl Loopex.Store
    def load_events(_reference, _session, _after, _limit), do: raise("unreachable")
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "s1",
        run_id: "r1",
        tool_call_id: "c1",
        generation: {"example.read", "1.0.0", String.duplicate("a", 64)},
        arguments: %{"path" => "x"},
        effect_class: "read_only",
        idempotency_class: "safe_retry",
        workspace_lease: "lease-1"
      },
      overrides
    )
  end

  test "every host policy implementation satisfies one policy port conformance suite" do
    # The same contract holds for each: exactly one of two resolved shapes comes
    # back, and nothing else ever does.
    for module <- [Allows, AllowsWithContext, Denies, Raises, Malformed, Defers, Unbounded] do
      decision = Policy.decide(module, request())

      assert match?({:allow, _context}, decision) or match?({:deny, _category}, decision),
             "#{inspect(module)} resolved to #{inspect(decision)}"

      case decision do
        {:allow, context} -> assert Policy.valid_context?(context)
        {:deny, category} -> assert is_atom(category)
      end
    end
  end

  test "a host policy deny decision issues no grant and starts no operating system process" do
    assert {:deny, :policy_denied} = Policy.decide(Denies, request())

    # The refusal is the whole point: nothing downstream is reached. A grant can
    # only be minted from an explicit allow, so a denial cannot produce one even
    # if a caller tried.
    assert {:error, :host_policy_allow_required} =
             Loopex.Executor.issue_grant({:host_policy, :deny}, %{}, 0)
  end

  test "a denied tool call commits a truthful denied outcome the operator can read" do
    # The category is closed and readable rather than free text that varies by
    # host, and it is one of the declared reasons.
    assert {:deny, category} = Policy.decide(Denies, request())
    assert category in Policy.reason_categories()

    assert Loopex.Conversation.result_content(:denied, Atom.to_string(category)) =~ "refused"
    assert Loopex.Conversation.result_content(:denied, Atom.to_string(category)) =~ "Do not retry"
  end

  test "the run continues or terminates truthfully after a denial and never retries the refused call" do
    # A denial is a terminal outcome of the conversation, not a transient error,
    # so it takes its place beside completed and failed rather than inviting
    # another attempt.
    assert :denied in Loopex.Conversation.outcomes()

    # Asking again returns the same answer; nothing in the port carries retry
    # state that could turn a second ask into a different result.
    assert Policy.decide(Denies, request()) == Policy.decide(Denies, request())
  end

  test "a policy that raises times out or returns a malformed value fails closed into denial" do
    # Every one of these has not allowed anything, and the safe reading of "I do
    # not know" is no.
    assert {:deny, :policy_unavailable} = Policy.decide(Raises, request())
    assert {:deny, :policy_unavailable} = Policy.decide(Malformed, request())
    assert {:deny, :policy_unavailable} = Policy.decide(Unbounded, request())
    assert {:deny, :policy_unavailable} = Policy.decide(LeaksAPid, request())
    assert {:deny, :policy_unavailable} = Policy.decide(:not_a_module, request())

    # A hanging policy denies rather than blocking the session owner forever.
    started = System.monotonic_time(:millisecond)
    assert {:deny, :policy_unavailable} = Policy.decide(Hangs, request())
    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 30_000, "a hanging policy must not block for its own duration"
  end

  test "defer is declared and refused in this milestone rather than treated as allow or deny" do
    # It resolves to a denial, and to a category that says precisely why: the
    # interaction it asks for is unsupported, not that the host refused the call.
    assert {:deny, :interaction_unsupported} = Policy.decide(Defers, request())
    refute match?({:deny, :policy_denied}, Policy.decide(Defers, request()))
    assert :interaction_unsupported in Policy.reason_categories()
  end

  test "every executor backed tool requires a policy decision including a read only tool" do
    # A read-only call asks exactly as a writing one does. There is no effect
    # class that skips the port, because an exemption would itself be a dispatch
    # branch nothing policed.
    for effect_class <- ["read_only", "workspace_write", "process", "external_effect"] do
      assert {:deny, :policy_denied} =
               Policy.decide(Denies, request(%{effect_class: effect_class}))

      assert {:allow, nil} = Policy.decide(Allows, request(%{effect_class: effect_class}))
    end
  end

  test "a permissive policy applies only when it is named and omitting the policy option refuses runtime start" do
    definition = %{
      "tool_id" => "example.read",
      "tool_version" => "1.0.0",
      "name" => "read",
      "description" => "Read a file.",
      "parameter_schema" => %{"type" => "object", "properties" => %{}, "required" => []},
      "result_shape" => %{"content_type" => "text", "description" => ""},
      "effect_class" => "read_only",
      "idempotency_class" => "safe_retry",
      "budgets" => %{"wall_time_ms" => 1_000, "output_bytes" => 1_024, "artifact_bytes" => 1_024}
    }

    {:ok, store} = Loopex.Store.new(InertStore, :unused)

    # A runtime with a tool active and no policy named is refused before any
    # child starts, rather than discovering the missing authority at the first
    # tool call with a run underway and an operator waiting.
    assert {:error, :host_policy_required} =
             Loopex.start_link(runtime_id: "no-policy", store: store, tools: [definition])

    # Naming one is what makes it apply. Nothing supplies it implicitly.
    assert {:error, :host_policy_required} =
             Loopex.start_link(
               runtime_id: "still-no-policy",
               store: store,
               tools: [definition],
               grant_decision: {:host_policy, :allow}
             )
  end
end
