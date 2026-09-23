defmodule LoopexDaemon.ExitStatus do
  @moduledoc """
  ## Concept

  A daemon process exit is an operator-facing result. Each failure class has
  one stable nonzero status so a service manager can distinguish startup,
  running, cleanup, and offline-import failures without parsing prose.

  ## Technical depth

  Parser refusal is the ordinary command status `1`. The daemon's typed classes
  occupy every integer from 65 through 110 exactly once. Status `0` is reserved
  for successful import or an operator-requested stop whose cleanup completes.
  """

  @parser_refusal 1
  @success 0

  @statuses %{
    state_root_required: 65,
    state_root_unusable: 66,
    workspace_required: 67,
    workspace_unusable: 68,
    provider_launch_required: 69,
    provider_launch_invalid: 70,
    policy_required: 71,
    policy_unknown: 72,
    provider_credential_required: 73,
    project_skills_unusable: 74,
    cleanup_grace_invalid: 75,
    placement_active: 76,
    placement_unverifiable: 77,
    placement_lock_failed: 78,
    store_writer_active: 79,
    store_writer_unverifiable: 80,
    store_writer_acquisition_failed: 81,
    store_log_too_large: 82,
    session_index_too_large: 83,
    session_index_corrupt: 84,
    session_index_upgrade_required: 85,
    session_index_write_failed: 86,
    socket_path_too_long: 87,
    socket_permission_unverified: 88,
    invalid_socket_path: 89,
    signal_install_failed: 90,
    credential_plane_start_failed: 91,
    composition_start_failed: 92,
    daemon_services_start_failed: 93,
    listener_start_failed: 94,
    readiness_write_failed: 95,
    store_capacity_exceeded: 96,
    store_lost: 97,
    transfers_lost: 98,
    workspace_lease_lost: 99,
    executor_lost: 100,
    registry_lost: 101,
    custody_lost: 102,
    capability_lost: 103,
    runtime_lost: 104,
    relay_lost: 105,
    connections_lost: 106,
    listener_lost: 107,
    drain_failed: 108,
    owner_lost: 109,
    prepare_index_interrupted: 110
  }

  @typedoc false
  @type failure_class ::
          unquote(@statuses |> Map.keys() |> Enum.sort() |> Enum.reduce(&{:|, [], [&1, &2]}))

  @doc false
  @spec success() :: 0
  def success, do: @success

  @doc false
  @spec parser_refusal() :: 1
  def parser_refusal, do: @parser_refusal

  @doc false
  @spec fetch(failure_class()) :: {:ok, 65..110} | :error
  def fetch(class), do: Map.fetch(@statuses, class)

  @doc false
  @spec classes() :: %{required(failure_class()) => 65..110}
  def classes, do: @statuses

  @own_classes [:store_writer_active, :store_writer_unverifiable, :store_log_too_large]
  @acquisition_failures [
    :store_writer_lock_failed,
    :store_writer_lock_close_failed,
    :store_writer_recovery_failed,
    :store_writer_identity_unavailable
  ]

  @doc """
  ## Concept

  Names the exit class of a Store refusal met while opening the root's log, so
  every way the root's writer marker or log can refuse reaches the operator
  as its own status.

  ## Technical depth

  The local Store refuses as a bare class or a tuple whose first element is the
  class, carrying a path and a reason of varying arity. A live writer, an
  unverifiable marker and an oversized log keep their own classes; the lock's
  other failures are `store_writer_acquisition_failed`. Any other value is
  `nil`, left to the caller's own class.
  """
  @spec store_open_class(term()) ::
          :store_writer_active
          | :store_writer_unverifiable
          | :store_log_too_large
          | :store_writer_acquisition_failed
          | nil
  def store_open_class(reason) when is_tuple(reason) and tuple_size(reason) >= 1,
    do: store_open_class(elem(reason, 0))

  def store_open_class(class) when class in @own_classes, do: class

  def store_open_class(class) when class in @acquisition_failures,
    do: :store_writer_acquisition_failed

  def store_open_class(_reason), do: nil
end
