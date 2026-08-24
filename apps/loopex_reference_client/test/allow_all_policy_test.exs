defmodule Loopex.ReferenceClient.AllowAllPolicyTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Loopex.ReferenceClient.Policy.AllowAll

  # Concept: this lane proves what the shipped module does.
  #
  # Technical depth: the executor edge's policy role proves a runtime property —
  # that a permissive policy applies only where a host names one — using its own
  # in-file fixtures. This role proves the behaviour of the reference client's
  # own shipped AllowAll. Neither may be satisfied by the other, which is why the
  # two live in different applications and assert different things.

  defp request(overrides \\ %{}) do
    Map.merge(
      %{
        session_id: "s1",
        run_id: "r1",
        tool_call_id: "c1",
        generation: {"loopex.demo.write", "1.0.0", String.duplicate("a", 64)},
        arguments: %{"relative_path" => "trace.txt", "content" => "x"},
        effect_class: "workspace_write",
        idempotency_class: "reconcile_then_retry",
        workspace_lease: "lease-1"
      },
      overrides
    )
  end

  setup do
    :persistent_term.erase({AllowAll, :announced})
    :ok
  end

  test "the shipped allow all policy allows every decision it is asked" do
    capture_io(:stderr, fn ->
      # Every effect class, including the ones a cautious host would refuse.
      for effect_class <- ["read_only", "workspace_write", "process", "external_effect"] do
        assert {:allow, nil} = AllowAll.decide(request(%{effect_class: effect_class}))
      end

      # And regardless of what the call actually asks for. This policy has no
      # opinion to express, which is exactly what makes it permissive rather
      # than a permission model.
      assert {:allow, nil} =
               AllowAll.decide(request(%{arguments: %{"path" => "/etc/passwd"}}))

      assert {:allow, nil} =
               AllowAll.decide(request(%{idempotency_class: "never_blind_retry"}))
    end)

    # It resolves through the port to an allow with a valid context, so a runtime
    # that names it gets a decision the boundary will carry.
    capture_io(:stderr, fn ->
      assert {:allow, nil} = Loopex.Policy.decide(AllowAll, request())
      assert Loopex.Policy.valid_context?(nil)
    end)
  end

  test "the shipped allow all policy emits exactly one permissive authority notice" do
    output =
      capture_io(:stderr, fn ->
        for _ <- 1..5, do: AllowAll.decide(request())
      end)

    # One notice, not one per call. A line per tool call would train an operator
    # to ignore it, which is the opposite of what a notice is for.
    occurrences = output |> String.split(AllowAll.notice()) |> length() |> Kernel.-(1)
    assert occurrences == 1

    # It says what it is out loud: permissive local authority, and not a
    # permission model.
    assert AllowAll.notice() =~ "permissive local authority"
    assert AllowAll.notice() =~ "not a permission model"

    # A second batch after the first adds nothing, because the operator already
    # read it.
    quiet = capture_io(:stderr, fn -> AllowAll.decide(request()) end)
    refute quiet =~ AllowAll.notice()
  end
end
