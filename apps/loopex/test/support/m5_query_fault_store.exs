defmodule Loopex.M5QueryFaultStore do
  @moduledoc false

  alias Loopex.Store

  @behaviour Store

  @impl Store
  def transact(_reference, _transaction), do: {:not_committed, :store_unavailable}

  @impl Store
  def transaction_status(_reference, _session_id, _domain, _tx_id), do: :unavailable

  @impl Store
  def runtime_command(:unavailable, _command), do: :unavailable
  def runtime_command(:malformed, _command), do: {:completed, %{result: 42}}
  def runtime_command(:kill_control, _command), do: Process.exit(self(), :kill)
  def runtime_command(_reference, _command), do: :absent

  @impl Store
  def ownership_head(:unavailable, _session_id, _domain), do: :unavailable
  def ownership_head(:malformed, _session_id, _domain), do: {:present, :maybe}
  def ownership_head(:kill_control, _session_id, _domain), do: Process.exit(self(), :kill)
  def ownership_head(_reference, _session_id, _domain), do: :absent

  @impl Store
  def load_records(_reference, _session_id, _after_version, _limit), do: :unavailable

  @impl Store
  def load_events(_reference, _session_id, _after_sequence, _limit), do: :unavailable
end
