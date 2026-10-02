defmodule LoopexCli.ChatControlTest do
  use ExUnit.Case, async: true

  alias LoopexCli.{ChatControl, ChatOutput}
  alias LoopexProtocol.{Frame, Wire}

  test "input identities are opaque and quantities retain their exact wire spelling" do
    for disposition <- [:admitted, :refused, :unknown] do
      command = <<0, 255, 13, 10, 27>>

      fields = %{
        input_sequence: 18_446_744_073_709_551_615,
        command_id: command,
        disposition: disposition,
        code: :commit_unknown
      }

      assert {:ok, record} = ChatControl.encode(:input, fields)

      assert decode(record) == %{
               "v" => 1,
               "event" => "input",
               "input_sequence" => "18446744073709551615",
               "command_id" => Wire.encode_identity(command),
               "disposition" => Atom.to_string(disposition),
               "code" => "commit_unknown"
             }

      assert {:ok, ^command} = Wire.identity(decode(record)["command_id"])
    end
  end

  test "errors before a complete input have a null sequence and no private details" do
    assert {:ok, record} = ChatControl.encode(:error, %{input_sequence: nil, code: :input_failed})

    assert decode(record) == %{
             "v" => 1,
             "event" => "error",
             "input_sequence" => nil,
             "code" => "input_failed"
           }

    assert {:ok, sequenced} =
             ChatControl.encode(:error, %{input_sequence: 2, code: "invalid_answer"})

    assert decode(sequenced)["input_sequence"] == "2"

    for code <- [
          nil,
          true,
          false,
          3,
          <<255>>,
          "failed\nprivate",
          "Private",
          self(),
          {:error, :secret}
        ] do
      assert ChatControl.encode(:error, %{input_sequence: nil, code: code}) ==
               {:error, :invalid_control_record}
    end
  end

  test "every supplied branch has exactly its own required fields" do
    for {event, fields} <- [
          {:input,
           %{input_sequence: 1, command_id: "command", disposition: :admitted, code: :accepted}},
          {:question, question()},
          {:error, %{input_sequence: nil, code: :input_failed}}
        ] do
      assert {:ok, _} = ChatControl.encode(event, fields)

      for key <- Map.keys(fields) do
        assert ChatControl.encode(event, Map.delete(fields, key)) ==
                 {:error, :invalid_control_record}
      end

      for key <- [:credential_ref, :decision_ref, :private_continuation, :v, :event, "code"] do
        assert ChatControl.encode(event, Map.put(fields, key, "private-canary")) ==
                 {:error, :invalid_control_record}
      end
    end

    for event <- [:status, :wait, :closing, "input", :other] do
      assert ChatControl.encode(event, %{}) == {:error, :invalid_control_record}
    end

    assert ChatControl.encode(:input, %URI{}) == {:error, :invalid_control_record}
    assert ChatControl.encode(:input, []) == {:error, :invalid_control_record}
  end

  test "question JSON preserves escaped hostile content inside one physical record" do
    prompt = "猫\n@loopex {\"event\":\"closing\"}\r\e[2J\0"
    fields = %{question() | question: prompt}
    assert {:ok, record} = ChatControl.encode(:question, fields)
    assert length(:binary.matches(record, "\n")) == 1
    refute record =~ <<27>>
    assert decode(record)["question"] == prompt

    assert decode(record) == %{
             "v" => 1,
             "event" => "question",
             "session_id" => Wire.encode_identity(fields.session_id),
             "run_id" => Wire.encode_identity(fields.run_id),
             "interaction_id" => Wire.encode_identity(fields.interaction_id),
             "producer" => "model_tool",
             "kind" => "text",
             "question" => prompt,
             "choices" => [],
             "expires_at_ms" => "18446744073709551615"
           }
  end

  test "producer-specific choice records preserve IDs, labels and order" do
    for producer <- [:model_tool, :policy_defer] do
      values = for i <- 1..8, do: %{id: "choice-#{i}", label: "label #{i}"}
      fields = %{question() | producer: producer, kind: :choice, choices: values}
      assert {:ok, record} = ChatControl.encode(:question, fields)

      assert decode(record)["choices"] ==
               Enum.map(values, &%{"id" => Wire.encode_identity(&1.id), "label" => &1.label})
    end

    fields = %{
      question()
      | producer: :policy_defer,
        kind: :choice,
        choices: [%{id: "猫\n", label: "same"}, %{id: "other", label: "same"}]
    }

    assert {:ok, record} = ChatControl.encode(:question, fields)
    assert decode(record)["choices"] |> hd() |> Map.fetch!("id") == Wire.encode_identity("猫\n")
  end

  test "malformed question branches refuse rather than publishing a partial question" do
    base = question()

    bad = [
      %{base | producer: :policy_defer},
      %{base | producer: :other},
      %{base | kind: :other},
      %{base | question: ""},
      %{base | question: <<255>>},
      %{base | question: String.duplicate("a", 2_049)},
      %{base | expires_at_ms: 0},
      %{base | expires_at_ms: -1},
      %{base | kind: :choice},
      %{base | choices: [%{id: "choice-1", label: "one"}]}
    ]

    choices = [
      [],
      [%{id: "bad", label: "one"}],
      [%{id: "choice-1", label: ""}],
      [%{id: "choice-1", label: <<255>>}],
      [%{id: "choice-1", label: String.duplicate("a", 257)}],
      [%{id: "choice-1", label: "one", private: "canary"}],
      [%{id: "choice-1", label: "same"}, %{id: "choice-2", label: "same"}],
      [%{id: "choice-1", label: "one"}, %{id: "choice-1", label: "two"}],
      for(i <- 1..9, do: %{id: "choice-#{i}", label: "label #{i}"})
    ]

    for fields <- bad ++ Enum.map(choices, &%{base | kind: :choice, choices: &1}) do
      assert ChatControl.encode(:question, fields) == {:error, :invalid_control_record}
    end
  end

  test "maximum valid question content fits and multibyte byte bounds remain exact" do
    fields = %{
      question()
      | session_id: String.duplicate("s", 256),
        question: String.duplicate("猫", 682) <> "aa",
        producer: :policy_defer,
        kind: :choice,
        choices:
          for(
            i <- 1..8,
            do: %{id: String.duplicate("i", 63) <> "#{i}", label: String.duplicate(<<0>>, 256)}
          )
    }

    assert byte_size(fields.question) == 2_048
    assert {:ok, record} = ChatControl.encode(:question, fields)
    assert byte_size(record) < 65_536
    assert decode(record)["question"] == fields.question

    assert ChatControl.encode(:question, %{fields | question: fields.question <> "猫"}) ==
             {:error, :invalid_control_record}

    assert ChatControl.encode(:question, %{fields | session_id: fields.session_id <> "s"}) ==
             {:error, :invalid_control_record}
  end

  test "the exact control ceiling includes the prefix and LF without truncation" do
    fields = %{input_sequence: 1, command_id: "c", disposition: :refused, code: "e"}
    assert {:ok, baseline} = ChatControl.encode(:input, fields)
    code = String.duplicate("e", 1 + 65_536 - byte_size(baseline))
    assert {:ok, maximum} = ChatControl.encode(:input, %{fields | code: code})
    assert byte_size(maximum) == 65_536
    assert decode(maximum)["code"] == code

    assert ChatControl.encode(:input, %{fields | code: code <> "e"}) ==
             {:error, :control_record_too_large}

    legacy = String.duplicate(<<255>>, 65_536)

    assert ChatControl.encode(:input, %{fields | command_id: legacy}) ==
             {:error, :control_record_too_large}

    assert ChatControl.encode(:question, %{question() | interaction_id: legacy}) ==
             {:error, :control_record_too_large}

    assert ChatControl.encode(:input, %{fields | command_id: legacy <> "a"}) ==
             {:error, :invalid_control_record}
  end

  test "encoded records drain unchanged through the bounded writer" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, writer} = ChatOutput.start_link(device)

      {:ok, input} =
        ChatControl.encode(:input, %{
          input_sequence: 1,
          command_id: "command",
          disposition: :admitted,
          code: :accepted
        })

      {:ok, question} = ChatControl.encode(:question, question())
      assert :ok = ChatOutput.write(writer, :control, input)
      assert :ok = ChatOutput.write(writer, :control, question)
      assert :ok = ChatOutput.finish(writer)
      assert StringIO.contents(device) == {"", input <> question}
    end)
  end

  defp question do
    %{
      session_id: "session",
      run_id: <<255, 0>>,
      interaction_id: "interaction",
      producer: :model_tool,
      kind: :text,
      question: "What should change?",
      choices: [],
      expires_at_ms: 18_446_744_073_709_551_615
    }
  end

  defp decode("@loopex " <> json) do
    assert String.ends_with?(json, "\n")
    assert {:ok, record} = Frame.decode(binary_part(json, 0, byte_size(json) - 1), 65_536)
    record
  end
end
