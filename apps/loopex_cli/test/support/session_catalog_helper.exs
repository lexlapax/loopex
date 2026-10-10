defmodule LoopexCli.Test.SessionCatalog do
  @moduledoc false

  # Concept: a test records a session the way an offline command does.
  # Technical depth: the catalogue is written only by the placement holder.
  # A test that holds no command takes the lock for the one record and gives
  # it back; one already inside a placement-holding command records directly.
  def record(state_root, session_id, placement) do
    case LoopexComposition.Placement.acquire(state_root) do
      {:ok, lock} ->
        try do
          LoopexCli.SessionCatalog.record(state_root, session_id, placement)
        after
          :ok = LoopexComposition.Placement.release(lock)
        end

      {:error, {:placement_active, _owner}} ->
        LoopexCli.SessionCatalog.record(state_root, session_id, placement)
    end
  end
end
