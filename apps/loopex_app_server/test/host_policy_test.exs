defmodule Loopex.AppServer.HostPolicyTest do
  @moduledoc """
  ## Concept

  The two host policies this server ships, decided in process: the one that asks
  before it allows, and the one that allows and says so.

  ## Technical depth

  These are the decisions an operator selects by name at launch, so what they
  return is product behaviour and is asserted literally rather than through a
  client. The asking policy's question is also handed to the kernel's own
  validator here, because a deferral the runtime would refuse is not a question
  at all, and a case that only matched the map's shape would not notice.

  Nothing here spends a credential, starts a runtime, or leaves the virtual
  machine.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Loopex.AppServer.Policy.{AllowAll, Ask}
  alias Loopex.Interaction

  @request %{
    session_id: "session",
    run_id: "run",
    tool_call_id: "call",
    generation: {"a", "b", "c"},
    arguments: %{"path" => "notes.txt"},
    effect_class: "workspace_write",
    idempotency_class: "not_idempotent",
    workspace_lease: "workspace"
  }

  describe "the asking policy" do
    test "the first sight of a call is a question the runtime admits, not a decision" do
      assert {:defer, question} = Ask.decide(@request)

      assert question.kind == :choice
      assert question.prompt == "Allow this tool call?"
      assert Enum.map(question.choices, & &1.id) == ["allow", "deny"]
      assert Enum.map(question.choices, & &1.label) == ["Allow", "Deny"]

      # Five minutes is a request; the runtime fixes the instant once from the
      # committed creation and caps it at the run's deadline.
      assert question.expires_in_ms == 300_000
      assert question.expires_in_ms <= Interaction.bounds().expires_in_ms

      # The kernel's own validator, so this is a question a session would
      # actually open rather than a map that merely looks like one.
      assert {:ok, validated} = Interaction.validate_request(question)
      assert Interaction.offered?(validated, "allow")
      assert Interaction.offered?(validated, "deny")
      refute Interaction.offered?(validated, "allow once")
    end

    test "an answer is an input to the decision, and the allow is minted here" do
      allowed = Map.put(@request, :interaction_response, %{answer: %{choice_id: "allow"}})

      assert {:allow, nil} = Ask.decide(allowed)
    end

    test "the refusing identity denies under the category an operator can act on" do
      denied = Map.put(@request, :interaction_response, %{answer: %{choice_id: "deny"}})

      assert {:deny, :policy_denied} = Ask.decide(denied)
      assert :policy_denied in Loopex.Policy.reason_categories()
    end

    # Concept: only the allow identity allows. Everything else is a refusal.
    #
    # Technical depth: an answer arrives as data, and data that is malformed,
    # truncated, or simply not one of the offered identities must not read as
    # permission. Each of these is a distinct way an answer could fail to say
    # yes, and none of them may.
    test "anything that is not the allow identity is refused" do
      for response <- [
            %{answer: %{choice_id: "maybe"}},
            %{answer: %{choice_id: "Allow"}},
            %{answer: %{choice_id: ""}},
            %{answer: %{}},
            %{answer: nil},
            %{}
          ] do
        assert {:deny, :policy_denied} =
                 Ask.decide(Map.put(@request, :interaction_response, response)),
               "#{inspect(response)} was not refused"
      end
    end
  end

  describe "the permissive policy" do
    setup do
      AllowAll.reset_notice_for_test()
      on_exit(&AllowAll.reset_notice_for_test/0)
    end

    test "every call is allowed, with nothing added to the decision" do
      assert {:allow, nil} = capture_notice(fn -> AllowAll.decide(@request) end)
    end

    test "the notice says what it is and is printed once, not once per call" do
      notice = AllowAll.notice()

      assert notice =~ "permissive local authority"
      assert notice =~ "not a permission model"

      printed = capture_io(:stderr, fn -> for _ <- 1..4, do: AllowAll.decide(@request) end)

      assert printed |> String.split(notice) |> length() |> Kernel.-(1) == 1,
             "the notice was not printed exactly once for four decisions"
    end
  end

  defp capture_notice(function) do
    result = :erlang.make_ref()
    owner = self()
    capture_io(:stderr, fn -> send(owner, {result, function.()}) end)

    receive do
      {^result, value} -> value
    after
      5_000 -> flunk("the decision never returned")
    end
  end
end
