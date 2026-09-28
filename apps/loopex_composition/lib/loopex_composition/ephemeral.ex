defmodule LoopexComposition.Ephemeral do
  @moduledoc """
  ## Concept

  Starts one ephemeral Loopex session without a caller-supplied state root. The
  returned in-VM handle belongs to the process that created it and is usable
  only after the session, attachment and selected resources are ready.

  ## Technical depth

  Shared preflight finishes before a temporary owner receives configuration.
  The owner is a temporary supervised child monitored by the creator, never
  linked to it. The handle carries only that owner and its session-local
  lifecycle cell. Startup failure returns the owner's fixed public error after
  its bounded cleanup attempt; no partial handle is exposed.
  """

  alias LoopexComposition.Ephemeral.{OwnerActivation, Preflight, SessionOwner}

  @opaque session() :: {:loopex_ephemeral_session, pid(), :atomics.atomics_ref()}
  @type reason() :: term()

  @doc """
  ## Concept

  Creates an ephemeral session from one host-selected policy and optional model,
  tool, skill, workspace and bound choices.

  ## Technical depth

  Grammar and shared dependency checks run before owner activation. One private
  begin token gives a single owner permission to start its temporary subtree.
  Its result is withheld until the facade attachment, selected resources and
  active status have all been confirmed under the same startup deadline.
  """
  @spec start_session(keyword()) :: {:ok, session()} | {:error, reason()}
  def start_session(options) do
    with {:ok, configuration} <- Preflight.prepare(options),
         {:ok, supervisor} <- owner_supervisor(),
         {:ok, activation} <- OwnerActivation.start(supervisor),
         {:ok, cell} <- OwnerActivation.begin(activation),
         owner = OwnerActivation.owner(activation),
         {:ok, :session_ready} <- SessionOwner.start_session(owner, configuration, 16_000) do
      {:ok, {:loopex_ephemeral_session, owner, cell}}
    end
  end

  defp owner_supervisor do
    case Process.whereis(LoopexComposition.Ephemeral.OwnerSupervisor) do
      supervisor when is_pid(supervisor) -> {:ok, supervisor}
      _ -> {:error, {:composition, :composition_application_start_failed}}
    end
  end
end
