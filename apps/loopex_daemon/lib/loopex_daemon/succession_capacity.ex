defmodule LoopexDaemon.SuccessionCapacity do
  @moduledoc """
  ## Concept

  An attached connection always keeps enough of its bounded output allowance
  for one detachment notice and one correlated predecessor reply. This module
  derives that reserve from every legal maximum reply shape instead of choosing
  a hand-maintained byte estimate.

  ## Technical depth

  The maximal request identity uses ADR 0023's 64-byte request alphabet. Input
  mutations use the 65,536-byte raw command-identity limit; resume and resource
  mutations use their tighter 256-byte raw limits. The candidate set contains
  accepted admission and every closed durable refusal for all eight
  lease-authorized mutation methods, plus the four succession error forms. Each
  candidate is encoded by `LoopexProtocol.Frame`; the largest complete frame is
  the serial reply slot and its sum with the maximal detached frame is the
  delivery reserve.
  """

  alias LoopexDaemon.WireRecords
  alias LoopexProtocol.Frame

  @max_u64 18_446_744_073_709_551_615
  @max_request_id String.duplicate("~", 64)
  @max_session_id :binary.copy(<<255>>, 256)
  @input_command_id :binary.copy(<<255>>, 65_536)
  @bounded_command_id :binary.copy(<<255>>, 256)

  @mutation_specs [
    {"session.resume", @bounded_command_id, ["runtime_command_conflict"]},
    {"session.prompt", @input_command_id, ["run_active"]},
    {"session.steer", @input_command_id, ["run_mismatch", "steer_pending", "no_active_run"]},
    {"session.follow_up", @input_command_id, ["follow_up_pending", "no_active_run"]},
    {"session.abort", @input_command_id, ["no_active_run"]},
    {"session.respond_interaction", @input_command_id,
     ["interaction_absent", "interaction_resolved", "invalid_interaction_answer"]},
    {"session.admit_resources", @bounded_command_id,
     [
       "run_active",
       "resource_manifest_missing",
       "resource_binding_changed",
       "resource_not_admitted",
       "resource_not_found",
       "resource_selection_limit",
       "resource_support_not_found"
     ]},
    {"session.activate_skill", @bounded_command_id,
     [
       "run_active",
       "resource_manifest_missing",
       "resource_binding_changed",
       "resource_not_admitted",
       "resource_not_found",
       "resource_selection_limit",
       "resource_support_not_found"
     ]}
  ]

  @error_codes [
    "admission_unknown",
    "session_unavailable",
    "control_not_held",
    "attachment_conflict"
  ]

  @typedoc false
  @type candidate :: %{
          id: binary(),
          bytes: pos_integer(),
          sha256: binary()
        }

  @typedoc false
  @type measurement :: %{
          notice_bytes: pos_integer(),
          notice_sha256: binary(),
          reply_bytes: pos_integer(),
          reply_id: binary(),
          delivery_reserve_bytes: pos_integer(),
          reply_candidates: [candidate()]
        }

  @doc false
  @spec measure() :: measurement()
  def measure do
    notice =
      @max_session_id
      |> WireRecords.detached(@max_u64)
      |> encoded!("notice/detached")

    replies = Enum.map(reply_records(), fn {id, record} -> encoded!(record, id) end)
    largest = Enum.max_by(replies, &{&1.bytes, &1.id})

    %{
      notice_bytes: notice.bytes,
      notice_sha256: notice.sha256,
      reply_bytes: largest.bytes,
      reply_id: largest.id,
      delivery_reserve_bytes: notice.bytes + largest.bytes,
      reply_candidates: replies
    }
  end

  @doc false
  @spec reply_records() :: [{binary(), map()}]
  def reply_records do
    admissions =
      Enum.flat_map(@mutation_specs, fn {method, command_id, reasons} ->
        session_id = if method == "session.resume", do: @max_session_id

        accepted =
          {method <> "/accepted",
           WireRecords.admission(@max_request_id, method, command_id, :accepted, session_id)}

        refused =
          Enum.map(reasons, fn reason ->
            {method <> "/refused/" <> reason,
             WireRecords.admission(
               @max_request_id,
               method,
               command_id,
               {:refused, reason}
             )}
          end)

        [accepted | refused]
      end)

    errors =
      Enum.map(@error_codes, fn code ->
        {"error/" <> code, WireRecords.succession_error(@max_request_id, code)}
      end)

    admissions ++ errors
  end

  defp encoded!(record, id) do
    {:ok, encoded} = Frame.encode(record)
    binary = IO.iodata_to_binary(encoded)

    %{
      id: id,
      bytes: byte_size(binary),
      sha256: :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)
    }
  end
end
