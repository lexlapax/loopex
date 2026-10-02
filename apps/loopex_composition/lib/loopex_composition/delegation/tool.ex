defmodule LoopexComposition.Delegation.Tool do
  @moduledoc """
  ## Concept

  The fixed opt-in read-only helper tool declaration. Its model-visible role
  string selects a retained host role; the declaration grants no authority.

  ## Technical depth

  ADR 0046 fixes the effect identity, arguments and ceilings. Inspection and
  subsequent router registration share these exact bytes, so instruction cost
  includes the same generation that dispatch will admit. The ordinary schema
  checks types; this host boundary additionally checks the closed UTF-8 byte
  bounds. Catalog membership, grants, allowance reservation and execution
  belong to the owning adapter and are not performed here.
  """

  @definition %{
    "tool_id" => "loopex.task",
    "tool_version" => "1.0.0",
    "name" => "task",
    "description" => "Ask one saved read-only helper role to perform a bounded task.",
    "parameter_schema" => %{
      "type" => "object",
      "properties" => %{
        "role" => %{
          "type" => "string",
          "description" => "Enabled role matching [a-z][a-z0-9_-]{0,63}."
        },
        "description" => %{
          "type" => "string",
          "description" => "Nonempty UTF-8 task description, at most 256 bytes."
        },
        "prompt" => %{
          "type" => "string",
          "description" => "Nonempty UTF-8 task prompt, at most 16,384 bytes."
        }
      },
      "required" => ~w(role description prompt)
    },
    "result_shape" => %{
      "content_type" => "json",
      "description" => "The helper's identity, outcome, answer and usage."
    },
    "effect_class" => "external_effect",
    "idempotency_class" => "reconcile_then_retry",
    "budgets" => %{
      "wall_time_ms" => 600_000,
      "output_bytes" => 32_768,
      "artifact_bytes" => 8_388_608
    }
  }

  @doc """
  ## Concept

  Return the one helper generation without enabling or registering it.

  ## Technical depth

  Absence of class retains the existing effect format and its generation recipe.
  No role enumeration or configured catalog is inserted into these bytes.
  """
  @spec definition() :: LoopexProtocol.ToolDefinition.t()
  def definition, do: @definition

  @doc """
  ## Concept

  Refuse malformed model-supplied helper arguments before reservation or effects.

  ## Technical depth

  Exactly role, description and prompt are required. Strings preserve original
  bytes; no trimming, defaults or input atoms are introduced. Valid syntax says
  nothing about membership in the retained catalog or policy permission.
  """
  @spec validate_arguments(term()) :: :ok | {:error, :invalid_tool_arguments}
  def validate_arguments(arguments) when is_map(arguments) and not is_struct(arguments) do
    if Enum.sort(Map.keys(arguments)) == ~w(description prompt role) and
         text?(arguments["role"], 64) and
         Regex.match?(~r/\A[a-z][a-z0-9_-]{0,63}\z/, arguments["role"]) and
         text?(arguments["description"], 256) and text?(arguments["prompt"], 16_384),
       do: :ok,
       else: {:error, :invalid_tool_arguments}
  end

  def validate_arguments(_), do: {:error, :invalid_tool_arguments}

  defp text?(value, ceiling),
    do: is_binary(value) and byte_size(value) in 1..ceiling and String.valid?(value)
end
