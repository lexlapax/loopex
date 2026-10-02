defmodule LoopexComposition.Ephemeral.QuestionResponderTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.Ephemeral.QuestionResponder

  defp question(kind \\ "text") do
    {:ok, request} =
      Loopex.Interaction.model_request(
        if(kind == "text",
          do: %{"question" => "How should nil encode?"},
          else: %{"question" => "Choose an encoding", "choices" => ["null", "empty"]}
        )
      )

    %{
      "producer" => "model_tool",
      "status" => "pending",
      "interaction_id" => "question-1",
      "prompt" => request.prompt,
      "kind" => kind,
      "choices" => Enum.map(request.choices, &%{"id" => &1.id, "label" => &1.label}),
      "expires_at" => System.system_time(:millisecond) + 10_000,
      "run_id" => "private-run",
      "turn" => 1,
      "tool_call_id" => "original-call",
      "credential_reference" => "host-only-reference"
    }
  end

  defp start_worker(dto, callback) do
    supervisor =
      start_supervised!(%{
        id: make_ref(),
        start: {Supervisor, :start_link, [[], [strategy: :one_for_one]]},
        type: :supervisor
      })

    generation = make_ref()
    reference = make_ref()

    assert {:ok, worker} =
             Supervisor.start_child(supervisor, %{
               id: reference,
               start:
                 {QuestionResponder, :start_link, [self(), generation, reference, callback, dto]},
               restart: :temporary,
               shutdown: 1_000
             })

    monitor = Process.monitor(worker)
    {worker, monitor, generation, reference}
  end

  test "DTO drops all runtime and host-private data and validates exact offered choices" do
    for kind <- ["text", "choice"] do
      raw = question(kind)
      assert {:ok, dto} = QuestionResponder.question(raw)
      assert Enum.sort(Map.keys(dto)) == ~w(choices expires_at interaction_id kind prompt)
      assert dto == Map.take(raw, ~w(interaction_id prompt kind choices expires_at))
      refute inspect(dto) =~ "private-run"
      refute inspect(dto) =~ "host-only-reference"
    end

    raw = question("choice")

    for invalid <- [
          Map.put(raw, "producer", "policy_defer"),
          Map.delete(raw, "producer"),
          Map.put(raw, "status", "answered"),
          Map.put(raw, "interaction_id", ""),
          Map.put(raw, "interaction_id", String.duplicate("a", 257)),
          Map.put(raw, "interaction_id", <<255>>),
          Map.put(raw, "expires_at", -1),
          Map.put(raw, "expires_at", 18_446_744_073_709_551_616),
          Map.put(raw, "expires_at", 1.0),
          Map.put(raw, "kind", "text"),
          put_in(raw, ["choices", Access.at(0), "id"], "borrowed"),
          put_in(raw, ["choices", Access.at(0), "extra"], "private")
        ] do
      assert QuestionResponder.question(invalid) == {:error, :responder_failed}
    end
  end

  test "exact owner generation and grant precede invocation and normal DOWN follows bounded result" do
    assert {:ok, dto} = QuestionResponder.question(question())
    parent = self()

    {worker, monitor, generation, reference} =
      start_worker(dto, fn input ->
        send(parent, {:callback_invoked, self(), input})
        {:text, "encode nil as null"}
      end)

    send(worker, {self(), make_ref(), reference, :execute})
    send(worker, {self(), generation, make_ref(), :execute})
    refute_received {:callback_invoked, _, _}
    send(worker, {self(), generation, reference, :execute})
    assert_receive {:callback_invoked, ^worker, ^dto}

    assert_receive {^worker, ^generation, ^reference, :question_response,
                    {:ok, {:text, "encode nil as null"}}}

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    refute Process.alive?(worker)
  end

  test "choice and decline use exact question validation while invalid shapes and failures stay bounded" do
    assert {:ok, choice} = QuestionResponder.question(question("choice"))
    id = hd(choice["choices"])["id"]

    for {callback, expected} <- [
          {fn _ -> {:choice, id} end, {:ok, {:choice, id}}},
          {fn _ -> :decline end, {:ok, :decline}},
          {fn _ -> {:choice, "unoffered"} end, {:error, :responder_failed}},
          {fn _ -> {:text, "wrong kind"} end, {:error, :responder_failed}},
          {fn _ -> id end, {:error, :responder_failed}},
          {fn _ -> self() end, {:error, :responder_failed}},
          {fn _ -> raise "host-private exception" end, {:error, :responder_failed}},
          {fn _ -> throw({:private, choice}) end, {:error, :responder_failed}},
          {fn _ -> exit({:private, choice}) end, {:error, :responder_failed}}
        ] do
      {worker, monitor, generation, reference} = start_worker(choice, callback)
      send(worker, {self(), generation, reference, :execute})
      assert_receive {^worker, ^generation, ^reference, :question_response, ^expected}
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  test "blocked host work is confined to the exact supervised worker and can be joined without a result" do
    assert {:ok, dto} = QuestionResponder.question(question())
    parent = self()

    {worker, monitor, generation, reference} =
      start_worker(dto, fn _ ->
        send(parent, {:callback_blocked, self()})
        receive do: (:release -> {:text, "late answer"})
      end)

    send(worker, {self(), generation, reference, :execute})
    assert_receive {:callback_blocked, ^worker}
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}
    refute Process.alive?(worker)
    refute_received {^worker, ^generation, ^reference, :question_response, _}
  end

  test "callback text respects exact byte and UTF-8 boundaries before reaching an answer command" do
    assert {:ok, dto} = QuestionResponder.question(question())

    for {text, valid} <- [
          {String.duplicate("a", 8_192), true},
          {String.duplicate("é", 4_096), true},
          {String.duplicate("a", 8_193), false},
          {String.duplicate("é", 4_097), false},
          {"", false},
          {<<255>>, false},
          {self(), false}
        ] do
      {worker, monitor, generation, reference} = start_worker(dto, fn _ -> {:text, text} end)
      expected = if valid, do: {:ok, {:text, text}}, else: {:error, :responder_failed}
      send(worker, {self(), generation, reference, :execute})
      assert_receive {^worker, ^generation, ^reference, :question_response, ^expected}
      assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}
    end
  end

  test "an invalid DTO cannot reach host code through direct worker creation" do
    assert {:ok, dto} = QuestionResponder.question(question())

    for invalid <- [nil, Map.put(dto, "credential", "private"), Map.put(dto, "expires_at", -1)] do
      assert {:error, :responder_failed} =
               QuestionResponder.start_link(
                 self(),
                 make_ref(),
                 make_ref(),
                 fn _ -> flunk("host callback must not start") end,
                 invalid
               )
    end
  end
end
