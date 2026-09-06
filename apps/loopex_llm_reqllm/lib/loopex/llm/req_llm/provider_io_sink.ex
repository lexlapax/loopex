defmodule Loopex.LLM.ReqLLM.ProviderIOSink do
  @moduledoc false

  @doc false
  def child_spec(_options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      restart: :permanent,
      shutdown: 5_000,
      type: :worker
    }
  end

  @doc false
  def start_link(_options) do
    :proc_lib.start_link(__MODULE__, :init, [self()])
  end

  @doc false
  def init(parent) when is_pid(parent) do
    case register() do
      :ok ->
        :proc_lib.init_ack(parent, {:ok, self()})
        loop()

      {:error, reason} ->
        :proc_lib.init_ack(parent, {:error, reason})
        exit(reason)
    end
  end

  defp register do
    Process.register(self(), __MODULE__)
    :ok
  rescue
    ArgumentError -> {:error, :provider_io_sink_unavailable}
  end

  defp loop do
    receive do
      {:io_request, from, reply_as, _request} when is_pid(from) ->
        send(from, {:io_reply, reply_as, {:error, :enotsup}})
        loop()

      _unknown ->
        loop()
    end
  end
end
