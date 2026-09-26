defmodule Loopex.Runtime.DaemonRoute do
  @moduledoc false

  @opaque t :: %__MODULE__{
            control: pid(),
            runtime_token: reference(),
            session_id: binary(),
            attachment_id: binary(),
            attachment_incarnation: binary(),
            coordinator: pid(),
            owner_generation: binary()
          }

  defstruct [
    :control,
    :runtime_token,
    :session_id,
    :attachment_id,
    :attachment_incarnation,
    :coordinator,
    :owner_generation
  ]

  @doc false
  @spec new(pid(), reference(), binary(), binary(), binary(), pid(), binary()) :: t()
  def new(
        control,
        runtime_token,
        session_id,
        attachment_id,
        attachment_incarnation,
        coordinator,
        owner_generation
      )
      when is_pid(control) and is_reference(runtime_token) and is_binary(session_id) and
             is_binary(attachment_id) and is_binary(attachment_incarnation) and
             is_pid(coordinator) and is_binary(owner_generation) do
    %__MODULE__{
      control: control,
      runtime_token: runtime_token,
      session_id: session_id,
      attachment_id: attachment_id,
      attachment_incarnation: attachment_incarnation,
      coordinator: coordinator,
      owner_generation: owner_generation
    }
  end

  @doc false
  @spec routing(t()) ::
          {:ok, pid(), reference(), binary(), binary(), binary(), pid(), binary()}
          | {:error, :invalid_daemon_route}
  def routing(%__MODULE__{
        control: control,
        runtime_token: runtime_token,
        session_id: session_id,
        attachment_id: attachment_id,
        attachment_incarnation: attachment_incarnation,
        coordinator: coordinator,
        owner_generation: owner_generation
      })
      when is_pid(control) and is_reference(runtime_token) and is_binary(session_id) and
             is_binary(attachment_id) and is_binary(attachment_incarnation) and
             is_pid(coordinator) and is_binary(owner_generation) do
    {:ok, control, runtime_token, session_id, attachment_id, attachment_incarnation, coordinator,
     owner_generation}
  end

  def routing(_route), do: {:error, :invalid_daemon_route}
end
