defmodule LoopexCli.ChatControl do
  @moduledoc """
  ## Concept

  Encode the chat driver's acknowledgements, questions, barriers and endings as closed host
  records. Model text remains quoted transcript text, separate from these records.

  ## Technical depth

  ADR 0049 fixes the `@loopex ` prefix, version 1 and 65,536-byte presentation
  ceiling, including LF. Constructors accept exact atom-keyed host fields and
  retain no runtime state. Identities use the protocol's unpadded base64url;
  sequence and expiry quantities use its canonical decimal strings. JSON encoding
  reuses `LoopexProtocol.Frame`, so embedded LF and controls cannot introduce a
  second record. Oversized legacy identities refuse without truncation. Terminal
  objects use the shared protocol codec. Status joins this encoder with its
  public projection; this module does not infer settlement or cleanup.
  """

  alias LoopexProtocol.{Frame, Wire}
  alias LoopexProtocol.Session.Outcome

  @record_bytes 65_536
  @u64_max 18_446_744_073_709_551_615
  @fields %{
    input: [:input_sequence, :command_id, :disposition, :code],
    question: [
      :session_id,
      :run_id,
      :interaction_id,
      :producer,
      :kind,
      :question,
      :choices,
      :expires_at_ms
    ],
    error: [:input_sequence, :code],
    wait: [:input_sequence, :state, :session_id, :run_id, :interaction_id, :command_id, :outcome],
    closing: [:exit_code, :cleanup, :last_outcome]
  }

  @doc """
  ## Concept

  Produce one complete control line without writing it.

  ## Technical depth

  Missing and extra fields, invalid question branches and non-plain values refuse
  with `invalid_control_record`. Valid public data whose encoded presentation
  exceeds the ceiling refuses with `control_record_too_large`. The caller must
  perform transport-failure cleanup for that refusal. This function neither
  acknowledges a command nor establishes the truth of the supplied fields.
  """
  @spec encode(:input | :question | :error | :wait | :closing, term()) ::
          {:ok, binary()}
          | {:error, :invalid_control_record | :control_record_too_large}
  def encode(event, fields) when is_map(fields) and not is_struct(fields) do
    with required when is_list(required) <- Map.get(@fields, event),
         true <- Enum.sort(Map.keys(fields)) == Enum.sort(required),
         {:ok, branch} <- project(event, fields) do
      branch
      |> Map.merge(%{"v" => 1, "event" => Atom.to_string(event)})
      |> render()
    else
      _ -> {:error, :invalid_control_record}
    end
  end

  def encode(_, _), do: {:error, :invalid_control_record}

  defp project(:input, fields) do
    with {:ok, sequence} <- quantity(fields.input_sequence, false),
         {:ok, command} <- identity(fields.command_id),
         true <- fields.disposition in [:admitted, :refused, :unknown],
         {:ok, code} <- code(fields.code) do
      {:ok,
       %{
         "input_sequence" => sequence,
         "command_id" => command,
         "disposition" => Atom.to_string(fields.disposition),
         "code" => code
       }}
    end
  end

  defp project(:error, fields) do
    with {:ok, sequence} <- quantity(fields.input_sequence, true),
         {:ok, code} <- code(fields.code) do
      {:ok, %{"input_sequence" => sequence, "code" => code}}
    end
  end

  defp project(:question, fields) do
    with {:ok, session} <- identity(fields.session_id, 256),
         {:ok, run} <- identity(fields.run_id),
         {:ok, interaction} <- identity(fields.interaction_id),
         true <- fields.producer in [:policy_defer, :model_tool],
         true <- text?(fields.question, 2_048),
         {:ok, choices} <- choices(fields.producer, fields.kind, fields.choices),
         {:ok, expires} <- quantity(fields.expires_at_ms, false) do
      {:ok,
       %{
         "session_id" => session,
         "run_id" => run,
         "interaction_id" => interaction,
         "producer" => Atom.to_string(fields.producer),
         "kind" => Atom.to_string(fields.kind),
         "question" => fields.question,
         "choices" => choices,
         "expires_at_ms" => expires
       }}
    end
  end

  defp project(:wait, fields) do
    with {:ok, sequence} <- quantity(fields.input_sequence, false),
         {:ok, session} <- identity(fields.session_id, 256),
         {:ok, run} <- nullable_identity(fields.run_id),
         {:ok, interaction} <- nullable_identity(fields.interaction_id),
         {:ok, command} <- nullable_identity(fields.command_id),
         {:ok, outcome} <- wait_outcome(fields) do
      {:ok,
       %{
         "input_sequence" => sequence,
         "state" => Atom.to_string(fields.state),
         "session_id" => session,
         "run_id" => run,
         "interaction_id" => interaction,
         "command_id" => command,
         "outcome" => outcome
       }}
    end
  end

  defp project(:closing, fields) do
    with true <- is_integer(fields.exit_code) and fields.exit_code in 0..255,
         true <- fields.cleanup in [:confirmed, :unknown],
         {:ok, outcome} <- nullable_outcome(fields.last_outcome),
         true <-
           fields.exit_code != 0 or
             (fields.cleanup == :confirmed and
                (is_nil(outcome) or outcome["outcome"] == "completed")) do
      {:ok,
       %{
         "exit_code" => fields.exit_code,
         "cleanup" => Atom.to_string(fields.cleanup),
         "last_outcome" => outcome
       }}
    else
      _ -> :error
    end
  end

  defp wait_outcome(%{
         state: :settled,
         interaction_id: nil,
         command_id: nil,
         run_id: nil,
         outcome: nil
       }),
       do: {:ok, nil}

  defp wait_outcome(%{
         state: :settled,
         interaction_id: nil,
         command_id: nil,
         run_id: run,
         outcome: %{outcome: outcome} = value
       })
       when is_binary(run) and outcome in [:completed, :cancelled, :failed, :bound_reached],
       do: Outcome.encode_wire(value)

  defp wait_outcome(%{
         state: :question,
         interaction_id: interaction,
         command_id: nil,
         run_id: run,
         outcome: nil
       })
       when is_binary(run) and is_binary(interaction), do: {:ok, nil}

  defp wait_outcome(%{
         state: :uncertain,
         interaction_id: nil,
         command_id: nil,
         run_id: run,
         outcome: %{outcome: :outcome_unknown} = value
       })
       when is_binary(run), do: Outcome.encode_wire(value)

  defp wait_outcome(%{
         state: :uncertain,
         interaction_id: nil,
         command_id: command,
         run_id: nil,
         outcome: :commit_unknown
       })
       when is_binary(command), do: {:ok, "commit_unknown"}

  defp wait_outcome(%{
         state: :uncertain,
         interaction_id: nil,
         command_id: nil,
         outcome: :cleanup_unknown
       }),
       do: {:ok, "cleanup_unknown"}

  defp wait_outcome(_), do: :error

  defp nullable_identity(nil), do: {:ok, nil}
  defp nullable_identity(value), do: identity(value)
  defp nullable_outcome(nil), do: {:ok, nil}
  defp nullable_outcome(value), do: Outcome.encode_wire(value)

  defp choices(:model_tool, :text, []), do: {:ok, []}

  defp choices(producer, :choice, values)
       when producer in [:model_tool, :policy_defer] and is_list(values) and
              length(values) in 1..8 do
    if Enum.all?(values, &choice?/1) and
         Enum.uniq_by(values, & &1.id) == values and
         model_choices?(producer, values) do
      {:ok, Enum.map(values, &%{"id" => Wire.encode_identity(&1.id), "label" => &1.label})}
    else
      :error
    end
  end

  defp choices(_, _, _), do: :error

  defp choice?(%{id: id, label: label} = choice) when map_size(choice) == 2,
    do: not is_struct(choice) and text?(id, 64) and text?(label, 256)

  defp choice?(_), do: false

  defp model_choices?(:policy_defer, _), do: true

  defp model_choices?(:model_tool, choices) do
    Enum.with_index(choices, 1) |> Enum.all?(fn {choice, i} -> choice.id == "choice-#{i}" end) and
      Enum.uniq_by(choices, & &1.label) == choices
  end

  defp text?(value, max),
    do: is_binary(value) and byte_size(value) in 1..max and String.valid?(value)

  defp identity(value, max \\ 65_536)

  defp identity(value, max)
       when is_binary(value) and byte_size(value) > 0 and byte_size(value) <= max,
       do: {:ok, Wire.encode_identity(value)}

  defp identity(_, _), do: :error

  defp quantity(nil, true), do: {:ok, nil}

  defp quantity(value, _) when is_integer(value) and value > 0 and value <= @u64_max,
    do: {:ok, Wire.encode_u64(value)}

  defp quantity(_, _), do: :error

  defp code(value) when is_atom(value) and value not in [nil, true, false],
    do: code(Atom.to_string(value))

  defp code(value) when is_binary(value) do
    if byte_size(value) in 1..@record_bytes and Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, value),
      do: {:ok, value},
      else: :error
  end

  defp code(_), do: :error

  defp render(record) do
    with {:ok, json} <- Frame.encode(record),
         true <- 8 + IO.iodata_length(json) <= @record_bytes do
      {:ok, IO.iodata_to_binary(["@loopex ", json])}
    else
      _ -> {:error, :control_record_too_large}
    end
  end
end
