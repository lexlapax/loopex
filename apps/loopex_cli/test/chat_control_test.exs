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
          {:error, %{input_sequence: nil, code: :input_failed}},
          {:wait, wait()},
          {:closing, %{exit_code: 0, cleanup: :confirmed, last_outcome: nil}}
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
      {:ok, barrier} = ChatControl.encode(:wait, wait())

      {:ok, closing} =
        ChatControl.encode(:closing, %{
          exit_code: 0,
          cleanup: :confirmed,
          last_outcome: completed()
        })

      assert :ok = ChatOutput.write(writer, :control, input)
      assert :ok = ChatOutput.write(writer, :control, question)
      assert :ok = ChatOutput.write(writer, :control, barrier)
      assert :ok = ChatOutput.write(writer, :control, closing)
      assert :ok = ChatOutput.finish(writer)
      assert StringIO.contents(device) == {"", input <> question <> barrier <> closing}
    end)
  end

  test "wait records retain run-only outcomes and the distinct question and uncertainty branches" do
    base = wait()

    unknown = %{
      outcome: :outcome_unknown,
      details: %{"cleanup_grace_ms" => 1, "reconciliation_ref" => <<255, 0>>}
    }

    for fields <- [
          base,
          %{base | run_id: <<255, 0>>, outcome: completed()},
          %{base | state: :question, run_id: "run", interaction_id: <<0, 255>>},
          %{base | state: :uncertain, run_id: "run", outcome: unknown},
          %{base | state: :uncertain, command_id: <<0, 255>>, outcome: :commit_unknown},
          %{
            base
            | state: :uncertain,
              run_id: <<255, 0>>,
              command_id: <<0, 255>>,
              outcome: :commit_unknown
          },
          %{base | state: :uncertain, outcome: :cleanup_unknown},
          %{base | state: :uncertain, run_id: "run", outcome: :cleanup_unknown}
        ] do
      assert {:ok, bytes} = ChatControl.encode(:wait, fields)
      record = decode(bytes)
      assert record["state"] == Atom.to_string(fields.state)
      assert record["input_sequence"] == "1"
      assert record["session_id"] == Wire.encode_identity(fields.session_id)

      for key <- [:run_id, :interaction_id, :command_id] do
        native = Map.fetch!(fields, key)

        assert record[Atom.to_string(key)] ==
                 if(is_nil(native), do: nil, else: Wire.encode_identity(native))
      end

      case fields.outcome do
        nil ->
          assert record["outcome"] == nil

        literal when is_atom(literal) ->
          assert record["outcome"] == Atom.to_string(literal)

        terminal ->
          assert LoopexProtocol.Session.Outcome.decode_wire(record["outcome"]) == {:ok, terminal}
      end
    end
  end

  test "wait refuses inconsistent identities, missing terminal evidence and misplaced host codes" do
    base = wait()

    for invalid <- [
          %{base | state: :active},
          %{base | run_id: "run"},
          %{base | outcome: completed()},
          %{base | interaction_id: "interaction"},
          %{base | command_id: "command"},
          %{base | state: :question, run_id: "run"},
          %{base | state: :question, interaction_id: "interaction"},
          %{
            base
            | state: :question,
              run_id: "run",
              interaction_id: "interaction",
              outcome: completed()
          },
          %{base | state: :uncertain, outcome: :commit_unknown},
          %{
            base
            | state: :uncertain,
              interaction_id: "interaction",
              command_id: "command",
              outcome: :commit_unknown
          },
          %{base | state: :uncertain, command_id: "command", outcome: :cleanup_unknown},
          %{base | state: :uncertain, run_id: "run", outcome: completed()},
          %{
            base
            | state: :uncertain,
              run_id: "run",
              outcome: %{outcome: :outcome_unknown, details: %{}}
          },
          %{base | state: :uncertain, outcome: "cleanup_unknown"},
          %{base | state: :uncertain, interaction_id: "interaction", outcome: :cleanup_unknown},
          %{base | state: :uncertain, run_id: "", outcome: :cleanup_unknown},
          %{base | input_sequence: 0}
        ] do
      assert ChatControl.encode(:wait, invalid) == {:error, :invalid_control_record}
    end
  end

  test "wait and closing preserve configured preparation failure without changing cleanup" do
    failure = %{
      "version" => 2,
      "category" => "context_preparation_failed",
      "retryable" => false,
      "measurement_scope" => nil,
      "cause" => "maintenance_summary_invalid"
    }

    terminal = %{
      outcome: :failed,
      details: %{
        "reason" => nil,
        "failure" => failure,
        "cleanup_grace_ms" => 5_000
      }
    }

    assert {:ok, barrier} =
             ChatControl.encode(:wait, %{wait() | run_id: "run", outcome: terminal})

    assert decode(barrier)["outcome"]["details"]["failure"] == failure

    assert {:ok, closing} =
             ChatControl.encode(:closing, %{
               exit_code: 1,
               cleanup: :confirmed,
               last_outcome: terminal
             })

    assert decode(closing)["last_outcome"]["details"]["failure"] == failure
    assert decode(closing)["cleanup"] == "confirmed"
  end

  test "closing reports prior failure even when the last run succeeded and refuses false success" do
    base = %{exit_code: 1, cleanup: :confirmed, last_outcome: completed()}
    assert {:ok, line} = ChatControl.encode(:closing, base)
    assert decode(line)["exit_code"] == 1
    assert decode(line)["last_outcome"]["outcome"] == "completed"
    assert {:ok, _} = ChatControl.encode(:closing, %{base | cleanup: :unknown})
    assert {:ok, _} = ChatControl.encode(:closing, %{base | last_outcome: nil})

    for invalid <- [
          %{base | exit_code: -1},
          %{base | exit_code: 256},
          %{base | exit_code: "1"},
          %{base | cleanup: :other},
          %{base | exit_code: 0, cleanup: :unknown},
          %{base | last_outcome: :cleanup_unknown},
          %{
            base
            | exit_code: 0,
              last_outcome: %{outcome: :cancelled, details: %{"cleanup_grace_ms" => 1}}
          }
        ] do
      assert ChatControl.encode(:closing, invalid) == {:error, :invalid_control_record}
    end
  end

  test "terminal presentation cap preserves arbitrary counts and refuses oversized opaque references" do
    native = %{
      outcome: :bound_reached,
      details: %{
        "bound" => "token_budget",
        "observed" => 9,
        "declared_limit" => 1,
        "accounting_source" => "estimated",
        "cleanup_grace_ms" => 1
      }
    }

    fields = %{exit_code: 1, cleanup: :confirmed, last_outcome: native}
    assert {:ok, baseline} = ChatControl.encode(:closing, fields)
    digits = String.duplicate("9", 1 + 65_536 - byte_size(baseline))
    maximum = put_in(fields, [:last_outcome, :details, "observed"], String.to_integer(digits))
    assert {:ok, line} = ChatControl.encode(:closing, maximum)
    assert byte_size(line) == 65_536
    assert decode(line)["last_outcome"]["details"]["observed"] == digits

    overflow =
      put_in(fields, [:last_outcome, :details, "observed"], String.to_integer(digits <> "9"))

    assert ChatControl.encode(:closing, overflow) == {:error, :control_record_too_large}

    unknown = %{
      outcome: :outcome_unknown,
      details: %{
        "cleanup_grace_ms" => 1,
        "reconciliation_ref" => :binary.copy(<<255>>, 65_536)
      }
    }

    assert {:ok, _} = LoopexProtocol.Session.Outcome.encode_wire(unknown)

    assert ChatControl.encode(:closing, %{fields | last_outcome: unknown}) ==
             {:error, :control_record_too_large}

    assert ChatControl.encode(:wait, %{
             wait()
             | state: :uncertain,
               run_id: "run",
               outcome: unknown
           }) ==
             {:error, :control_record_too_large}
  end

  defp wait do
    %{
      input_sequence: 1,
      state: :settled,
      session_id: "session",
      run_id: nil,
      interaction_id: nil,
      command_id: nil,
      outcome: nil
    }
  end

  defp completed, do: %{outcome: :completed, details: %{"cleanup_grace_ms" => 5000}}

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
