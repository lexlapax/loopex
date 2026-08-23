defmodule Loopex.LLM.ReqLLM.RealModelLaneTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM
  alias Loopex.Model

  defmodule Deterministic do
    @behaviour Loopex.Model

    @impl Loopex.Model
    def complete(request, _options) do
      with :ok <- Loopex.Model.validate_request(request),
           [%{"content" => content, "role" => "user"}] <- request.messages do
        {:ok,
         %{
           text: "deterministic:" <> content,
           identity: %{provider: "deterministic", model: request.model, endpoint: "in-process"},
           usage: %{input_tokens: nil, output_tokens: nil},
           tool_calls: [],
           canonical_request_bytes: request.canonical_request_bytes,
           canonical_request_digest: request.canonical_request_digest
         }}
      else
        {:error, reason} -> {:error, reason}
        _other -> {:error, :unsupported_model_request}
      end
    end
  end

  test "deterministic and ReqLLM adapters satisfy one model conformance suite" do
    {:ok, request} =
      Model.request(ReqLLM.default_model(), [%{"role" => "user", "content" => "hello"}])

    assert :ok = Model.validate_request(request)
    assert {:ok, deterministic} = Deterministic.complete(request, [])
    assert deterministic.text == "deterministic:hello"
    assert plain_reply?(deterministic)

    variable = ReqLLM.credential_variable()
    previous = System.get_env(variable)
    System.delete_env(variable)

    try do
      assert ReqLLM.complete(request, []) == {:error, {:credential_unset, variable}}

      for adapter <- [Deterministic, ReqLLM],
          field <- [:canonical_request_bytes, :canonical_request_digest] do
        original = Map.fetch!(request, field)
        assert is_binary(original)
        changed = Map.put(request, field, original <> "changed")

        assert adapter.complete(changed, []) ==
                 {:error, :canonical_model_request_mismatch}
      end
    after
      if previous, do: System.put_env(variable, previous)
    end
  end

  defp plain_reply?(reply) do
    is_binary(reply.text) and is_map(reply.identity) and is_map(reply.usage) and
      is_list(reply.tool_calls) and is_binary(reply.canonical_request_bytes) and
      is_binary(reply.canonical_request_digest) and
      Enum.all?([reply.identity, reply.usage], fn map ->
        Enum.all?(map, fn {key, value} -> is_atom(key) and plain?(value) end)
      end)
  end

  defp plain?(value) when is_binary(value) or is_integer(value) or is_nil(value), do: true
  defp plain?(_value), do: false
end
