defmodule Loopex.LLM.ReqLLM.CredentialPlaneTest do
  @moduledoc """
  ## Concept

  What the shipped adapter is allowed to let escape while it is holding the
  host's credential.

  ## Technical depth

  ADR 0018 requires credential-shaped raw errors to be absent from every
  prohibited plane, and the logger's crash report is one of them: an uncaught
  error inside the provider worker is reported by the VM with a stacktrace whose
  frames can carry the argument list the call was made with, and that argument
  list is `call_options`, which carries `api_key`. These cases hold the adapter
  to the two halves of that: nothing the worker does while the credential is
  live may terminate it uncaught, and every reason the drain does return is
  bounded and has that credential substituted out of it.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Loopex.LLM.ReqLLM, as: Adapter
  alias Loopex.Model

  @sentinel "sk-loopex-credential-plane-sentinel-2f9c41"

  setup do
    variable = Adapter.credential_variable()
    previous = System.get_env(variable)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(variable)
        value -> System.put_env(variable, value)
      end
    end)

    %{variable: variable}
  end

  describe "a stream that ends by throwing or exiting" do
    test "a progress function that throws ends the drain as a bounded interruption" do
      response = stream_response()

      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(response, request(), identity(), throwing_progress())

      assert is_binary(reason)
      assert byte_size(reason) <= 4_096
    end

    test "a progress function that exits ends the drain as a bounded interruption" do
      response = stream_response()

      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(response, request(), identity(), exiting_progress())

      assert is_binary(reason)
      assert byte_size(reason) <= 4_096
    end
  end

  describe "the credential in a returned reason" do
    test "a provider error echoing the key is substituted before it is returned",
         %{variable: variable} do
      System.put_env(variable, @sentinel)

      response = stream_response(echoing_stream())

      assert {:error, {:stream_interrupted, reason}} =
               Adapter.reply_from_stream(
                 response,
                 request(),
                 identity(),
                 Model.discard_progress()
               )

      refute reason =~ @sentinel
      assert reason =~ "[redacted credential]"
    end
  end

  describe "the provider worker while the credential is live" do
    test "no canary ending reports the credential or terminates the worker uncaught",
         %{variable: variable} do
      previous_adapter = Application.get_env(:req_llm, :finch_request_adapter)
      System.put_env(variable, @sentinel)

      Application.put_env(
        :req_llm,
        :finch_request_adapter,
        Loopex.LLM.ReqLLM.CredentialPlaneTest.RaisingTransport
      )

      on_exit(fn ->
        case previous_adapter do
          nil -> Application.delete_env(:req_llm, :finch_request_adapter)
          value -> Application.put_env(:req_llm, :finch_request_adapter, value)
        end
      end)

      {:ok, live} =
        Model.request(
          Adapter.default_model(),
          [%{"role" => "user", "content" => "credential plane"}],
          sampling: %{"max_tokens" => 1},
          deadline: System.system_time(:millisecond) + 2_000
        )

      log =
        capture_log(fn ->
          assert Adapter.complete(live, [], Model.discard_progress()) ==
                   {:error, {:dispatched_or_unknown, "model_call_failed"}}

          Process.sleep(200)
        end)

      refute log =~ @sentinel
      refute log =~ "Error in process"
    end
  end

  defmodule RaisingTransport do
    @moduledoc false

    @behaviour ReqLLM.FinchRequestAdapter

    @impl ReqLLM.FinchRequestAdapter
    def call(%Finch.Request{}), do: raise("provider library raised after the handoff")
  end

  defp throwing_progress, do: fn _delta -> throw(:progress_refused) end
  defp exiting_progress, do: fn _delta -> exit(:progress_gone) end

  defp request do
    {:ok, request} =
      Model.request(Adapter.default_model(), [%{"role" => "user", "content" => "hi"}],
        sampling: %{"max_tokens" => 8},
        deadline: System.system_time(:millisecond) + 60_000
      )

    request
  end

  defp identity do
    {:ok, identity} = Adapter.identity(Adapter.default_model())
    identity
  end

  # Concept: the same lazy stream the library hands the adapter, with the ending
  # this case is about.
  defp stream_response(stream \\ nil) do
    {:ok, handle} =
      ReqLLM.StreamResponse.MetadataHandle.start_link(fn ->
        %{finish_reason: :stop, status: 200, headers: [], usage: %{}}
      end)

    {:ok, model} = ReqLLM.model(Adapter.default_model())

    %ReqLLM.StreamResponse{
      stream: stream || Stream.map(["Hel", "lo"], &ReqLLM.StreamChunk.text/1),
      metadata_handle: handle,
      cancel: fn -> :ok end,
      model: model,
      context: ReqLLM.Context.new([ReqLLM.Context.user("hi")])
    }
  end

  # Concept: exactly the shape a provider that rejected the key produces -- the
  # key echoed back inside the error body the library raises out of the stream.
  defp echoing_stream do
    Stream.map([:reject], fn _rejected ->
      raise %ReqLLM.Error.API.Stream{
        reason: "Stream failed: authentication_error for x-api-key #{@sentinel}",
        cause: :closed
      }
    end)
  end
end
