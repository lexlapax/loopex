unless System.get_env("LOOPEX_HOME") do
  isolated_home =
    Path.join(System.tmp_dir!(), "loopex-host-policy-#{System.unique_integer([:positive])}")

  File.mkdir_p!(isolated_home)
  System.put_env("LOOPEX_HOME", isolated_home)
  System.at_exit(fn _status -> File.rm_rf(isolated_home) end)
end

Code.require_file("../../loopex/test/support/m1_runtime_helper.exs", __DIR__)
Code.require_file("../../loopex/test/support/agent_loop_helper.exs", __DIR__)

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

  defmodule CountingDenies do
    @moduledoc false
    @behaviour Policy

    @observer_key {__MODULE__, :observer}

    def observe_from(pid), do: :persistent_term.put(@observer_key, pid)
    def stop_observing, do: :persistent_term.erase(@observer_key)

    @impl Policy
    def decide(request) do
      case :persistent_term.get(@observer_key, nil) do
        observer when is_pid(observer) ->
          send(observer, {:host_policy_decided, request.tool_call_id})

        _none ->
          :ok
      end

      {:deny, :policy_denied}
    end
  end

  defmodule Raises do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: raise("host policy is broken")
  end

  defmodule KillsItself do
    @moduledoc false
    @behaviour Policy
    @impl Policy
    def decide(_request), do: Process.exit(self(), :kill)
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

  defmodule DeniesAsAsked do
    @moduledoc false

    # Concept: a host that denies with whichever category the case names.
    #
    # Technical depth: the category travels in the request rather than in five
    # near-identical fixtures, and `decide/1` runs in its own task, so the
    # request is the only channel that reaches it.

    @behaviour Policy
    @impl Policy
    def decide(%{arguments: %{"category" => category}}), do: {:deny, category}
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
    def runtime_command(_reference, _command), do: raise("unreachable")

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

  defp await_run_finished(attachment, acc \\ [], attempts \\ 500)

  defp await_run_finished(_attachment, _acc, 0),
    do: flunk("the denied run never committed a terminal event")

  defp await_run_finished(attachment, acc, attempts) do
    case Loopex.next_event(attachment) do
      {:ok, %{kind: "run.finished"} = event} ->
        Enum.reverse([event | acc])

      {:ok, event} ->
        await_run_finished(attachment, [event | acc], attempts)

      _absent ->
        Process.sleep(10)
        await_run_finished(attachment, acc, attempts - 1)
    end
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
    # Concept: one tool call is refused once, reaches no executor, and becomes a
    # durable result the model and operator can read before the run continues.
    #
    # Technical depth: calling the policy twice and comparing its answers proved
    # only that this fixture was deterministic. It did not exercise the runtime,
    # count runtime decisions, or detect a retry. The observer lives in
    # `persistent_term` because the policy boundary deliberately executes in an
    # isolated process; the message therefore counts the production decision
    # point rather than a test-side rehearsal.
    CountingDenies.observe_from(self())
    on_exit(&CountingDenies.stop_observing/0)

    fixture =
      Loopex.AgentLoopFixture.start(
        script: [
          %{
            text: "try the tool",
            calls: [%{id: "c1", name: "write", arguments: %{"path" => "notes.txt"}}]
          },
          %{text: "the tool was refused", calls: []}
        ],
        policy: CountingDenies
      )

    on_exit(fn -> Loopex.AgentLoopFixture.stop(fixture) end)

    {_session_id, attachment, reply} = Loopex.AgentLoopFixture.run(fixture, "write notes")
    assert {:accepted, "prompt-1"} = reply

    events = await_run_finished(attachment)

    assert_receive {:host_policy_decided, "c1"}, 1_000
    refute_receive {:host_policy_decided, "c1"}, 200
    assert Loopex.AgentLoopTestExecutor.jobs(fixture.executor) == []

    tool = Enum.find(events, &(&1.kind == "tool.finished"))
    assert tool["tool_call_id"] == "c1"
    assert tool["outcome"] == "denied"

    finished = Enum.find(events, &(&1.kind == "run.finished"))
    assert finished["outcome"] == "completed"

    assert [_first, second] = Loopex.AgentLoopTestModel.dispatched(fixture.model)
    result = Enum.find(second.messages, &(&1["role"] == "tool"))
    assert result["outcome"] == "denied"
    assert result["content"] =~ "Do not retry"
  end

  test "a policy that raises times out or returns a malformed value fails closed into denial" do
    # Every one of these has not allowed anything, and the safe reading of "I do
    # not know" is no.
    assert {:deny, :policy_unavailable} = Policy.decide(Raises, request())
    assert {:deny, :policy_unavailable} = Policy.decide(KillsItself, request())
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

  test "a denial category outside the published enumeration is refused rather than carried" do
    # Every published category comes back exactly as the host sent it. That is
    # what the enumeration is for: an operator reading a denial gets a category
    # they can look up.
    for category <- Policy.reason_categories() do
      assert {:deny, ^category} =
               Policy.decide(DeniesAsAsked, request(%{arguments: %{"category" => category}}))
    end

    # A category the host invented is not one of them, and this boundary does not
    # hand it on. It still denies -- the fail-closed direction is unchanged --
    # but as unavailable, because an answer this port cannot read is exactly the
    # "I do not know" that resolves to no.
    refute :invented_by_the_host in Policy.reason_categories()

    assert {:deny, :policy_unavailable} =
             Policy.decide(
               DeniesAsAsked,
               request(%{arguments: %{"category" => :invented_by_the_host}})
             )
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
