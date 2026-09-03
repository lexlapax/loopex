defmodule Loopex.LLM.ReqLLM.RealModelLaneTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.Model

  defmodule Deterministic do
    @behaviour Loopex.Model

    @impl Loopex.Model
    def complete(request, _options, _progress \\ nil) do
      with :ok <- Loopex.Model.validate_request(request),
           [%{"content" => content, "role" => "user"} | _rest] <-
             Enum.filter(request.messages, &(Map.get(&1, "role") == "user")) do
        {:ok,
         %{
           text: "deterministic:" <> content,
           identity: %{provider: "deterministic", model: request.model, endpoint: "in-process"},
           usage: %{input_tokens: nil, output_tokens: nil},
           tool_calls: [],
           delta_count: 0,
           streamed: false,
           canonical_request_bytes: request.canonical_request_bytes,
           staged_request_digest: request.staged_request_digest
         }}
      else
        {:error, reason} -> {:error, reason}
        _other -> {:error, :unsupported_model_request}
      end
    end
  end

  test "deterministic and ReqLLM adapters satisfy one model conformance suite" do
    {:ok, request} =
      Model.request(ReqLLM.default_model(), [%{"role" => "user", "content" => "hello"}],
        sampling: %{"max_tokens" => 64},
        deadline: System.system_time(:millisecond) + 60_000
      )

    assert :ok = Model.validate_request(request)
    assert {:ok, deterministic} = Deterministic.complete(request, [], Model.discard_progress())
    assert deterministic.text == "deterministic:hello"
    assert plain_reply?(deterministic)

    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)
    System.delete_env(variable)

    try do
      assert ReqLLM.complete(request, [], Model.discard_progress()) ==
               {:error, {:not_dispatched, "model_call_failed"}}

      for adapter <- [Deterministic, ReqLLM],
          field <- [:canonical_request_bytes, :staged_request_digest] do
        original = Map.fetch!(request, field)
        assert is_binary(original)
        changed = Map.put(request, field, original <> "changed")

        # ADR 0018 bounds the shipped provider adapter's pre-transport refusal to
        # the generic not-dispatched shape; the in-process deterministic adapter
        # has no transport and keeps naming the mismatch.
        expected =
          case adapter do
            ReqLLM -> {:error, {:not_dispatched, "model_call_failed"}}
            Deterministic -> {:error, :canonical_model_request_mismatch}
          end

        assert adapter.complete(changed, [], Model.discard_progress()) == expected
      end
    after
      if previous, do: System.put_env(variable, previous)
    end
  end

  defp plain_reply?(reply) do
    is_binary(reply.text) and is_map(reply.identity) and is_map(reply.usage) and
      is_list(reply.tool_calls) and is_binary(reply.canonical_request_bytes) and
      is_binary(reply.staged_request_digest) and
      Enum.all?([reply.identity, reply.usage], fn map ->
        Enum.all?(map, fn {key, value} -> is_atom(key) and plain?(value) end)
      end)
  end

  defp plain?(value) when is_binary(value) or is_integer(value) or is_nil(value), do: true
  defp plain?(_value), do: false
end
