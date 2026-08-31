defmodule LoopexProtocol.ToolDefinition do
  @moduledoc """
  ## Concept

  What a tool *is*, as bounded plain data: an identity, the bytes a model sees,
  and the declared class of effect and cost running it may incur. A definition
  carries no function, module, pid, or host concept, so the whole record
  round-trips through the store and across the executor protocol unchanged, and
  a request that used one stays reconstructible from the journal long after the
  registry that held it was edited.

  Its identity is the *generation triple* — `tool_id`, `tool_version`, and the
  digest of its canonical bytes. Any change to any field, including the
  model-visible name, produces a different digest and therefore a different
  generation. A definition is never edited in place; a changed tool is a new
  version.

  Fixed by
  [ADR 0009](../../../../docs/adr/0009-tool-executor-and-grant-contracts.md#concept).

  ## Technical depth

  The record's nine fields, all required:

  | Field | Shape |
  | --- | --- |
  | `tool_id` | dot-segmented lowercase ASCII, at most 128 bytes; the `loopex.` prefix is reserved |
  | `tool_version` | exact `major.minor.patch` version string |
  | `name` | model-visible name matching `^[a-z][a-z0-9_]{0,63}$` |
  | `description` | bounded model-visible text, at most 4096 bytes |
  | `parameter_schema` | the declared JSON-Schema-compatible subset below |
  | `result_shape` | model-facing normalized result descriptor |
  | `effect_class` | `read_only`, `workspace_write`, `process`, or `external_effect` |
  | `idempotency_class` | `safe_retry`, `reconcile_then_retry`, or `never_blind_retry` |
  | `budgets` | declared `wall_time_ms`, `output_bytes`, and `artifact_bytes` ceilings |

  The parameter schema subset is deliberately small: an object root with named
  properties, a required-name list, and property types drawn from `string`,
  `integer`, `number`, `boolean`, and `array` of those, each with an optional
  description and an optional string enumeration. Nested objects, unions,
  references, and conditional keywords are refused at registration rather than
  ignored at dispatch, because a schema core cannot evaluate is a schema that
  silently stops validating arguments. Schemas are ordinary Elixir data; wire
  encoding belongs to the provider adapter, never here, and the ADR 0002 floor
  forecloses `:json` and `JSON` regardless.

  ADR 0009 names three of these shapes without fixing them, and this module
  chooses the smallest form that carries what the ADR says each is for. They are
  reversible internal choices, recorded here rather than in a decision record:
  `tool_id`'s grammar is dot-segmented lowercase ASCII bounded at 128 bytes;
  `budgets` carries exactly the three declared ceilings the ADR names, as
  positive integers; and `result_shape` carries a `content_type` of `text` or
  `json` with an optional description, which is what a model-facing normalized
  result descriptor needs to be and no more. Widening any of the three is
  additive and does not disturb a retained generation, because a definition that
  did not use the wider form encodes exactly as it did before.

  `validate/1` is total and returns every reason it found rather than the first,
  so a caller fixing a definition sees the whole list in one pass.
  """

  alias LoopexProtocol.Canonical

  @definition_version "loopex.tool_definition.v1"

  @fields ~w(tool_id tool_version name description parameter_schema result_shape
             effect_class idempotency_class budgets)
  @effect_classes ~w(read_only workspace_write process external_effect)
  @idempotency_classes ~w(safe_retry reconcile_then_retry never_blind_retry)
  @budget_fields ~w(wall_time_ms output_bytes artifact_bytes)
  @property_types ~w(string integer number boolean array)
  @scalar_item_types ~w(string integer number boolean)
  @schema_keys ~w(type properties required)
  @property_keys ~w(type description enum items)
  @result_shape_keys ~w(content_type description)
  @result_content_types ~w(text json)
  @reserved_prefix "loopex."

  @max_tool_id_bytes 128
  @max_description_bytes 4096
  @name_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @tool_id_pattern ~r/^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$/
  @version_pattern ~r/^\d+\.\d+\.\d+$/

  @typedoc """
  ## Concept

  A tool definition as bounded plain data with binary keys.

  ## Technical depth

  The map type cannot express the nine required fields or their shapes, so
  `validate/1` is the authority on what is a definition and this type states
  only that it is a binary-keyed map.
  """
  @type t :: %{optional(binary()) => term()}

  @typedoc """
  ## Concept

  The identity of one definition: `{tool_id, tool_version, definition_digest}`.

  ## Technical depth

  All three members are binaries, the third being lowercase hexadecimal
  SHA-256. The triple is the value a staged request records and a grant binds,
  so it is compared as a whole; no member identifies a definition on its own.
  """
  @type generation :: {binary(), binary(), binary()}

  @doc """
  ## Concept

  The field names every definition carries, in a stable order.

  ## Technical depth

  Exposed so a conformance suite can assert the record's shape against this
  list rather than against a transcription that can drift from it.
  """
  @spec fields() :: [binary()]
  def fields, do: @fields

  @doc """
  ## Concept

  The permitted `effect_class` values.

  ## Technical depth

  Exposed for the same reason as `fields/0`: an executor validating a grant's
  effect class compares against this list rather than repeating it.
  """
  @spec effect_classes() :: [binary()]
  def effect_classes, do: @effect_classes

  @doc """
  ## Concept

  The permitted `idempotency_class` values.

  ## Technical depth

  Reconciliation policy reads this list rather than restating it, so a class
  added here cannot be silently unhandled at a retry decision.
  """
  @spec idempotency_classes() :: [binary()]
  def idempotency_classes, do: @idempotency_classes

  @doc """
  ## Concept

  Completes a host's tool declaration into the canonical record.

  ## Technical depth

  A host declares what a model needs to see — a name, a description, an
  identity, an effect class, and a parameter schema. The remaining fields of the
  canonical record have defaults, so a host is not made to restate what it has
  no opinion about. The generation digest is computed over the *completed*
  record, so what was staged stays exactly checkable; normalization happens once,
  on the way in, and never again.

  Two narrowings are deliberate and are not silent:

  `input_schema` is accepted as a name for `parameter_schema`. They are the same
  thing under two names, and refusing the older one would break every host that
  already uses it for no gain.

  The schema is then narrowed to the subset this kernel can actually evaluate:
  an object root, its named properties, and the required list. A key outside that
  subset — `additionalProperties`, `const`, a union, a `$ref` — is dropped rather
  than carried, because the kernel validates arguments against this record and a
  key it cannot evaluate would claim a constraint that is never enforced. The
  model is shown exactly what the kernel checks. A property whose *type* falls
  outside the subset is refused outright by `validate/1` rather than dropped,
  because dropping it would silently widen what the tool accepts.

  Returns the completed record, which `validate/1` then judges as usual; an
  input that cannot be completed is returned unchanged so its reasons are
  reported against what the host actually wrote.
  """
  @spec normalize(term()) :: term()
  def normalize(declaration) when is_map(declaration) and not is_struct(declaration) do
    schema =
      Map.get(declaration, "parameter_schema") || Map.get(declaration, "input_schema")

    declaration
    |> Map.drop(["input_schema"])
    |> Map.put("parameter_schema", narrow_schema(schema))
    |> Map.put_new("result_shape", %{"content_type" => "text", "description" => ""})
    |> Map.put_new("idempotency_class", "never_blind_retry")
    |> Map.put_new("budgets", %{
      "wall_time_ms" => 120_000,
      "output_bytes" => 65_536,
      "artifact_bytes" => 8_388_608
    })
  end

  def normalize(declaration), do: declaration

  @doc """
  ## Concept

  The schema keywords `normalize/1` would drop from this declaration.

  ## Technical depth

  Reported so a narrowing is never silent. A host that wrote
  `additionalProperties: false` or a `const` believes a constraint is enforced;
  it is not, and being told so at registration is the difference between a
  documented limitation and a surprise at dispatch. Each entry names where the
  keyword sat, so a schema with several properties says which one lost what.

  Returns an empty list when nothing is dropped, which is the ordinary case for
  a declaration already written in the subset.
  """
  @spec narrowing(term()) :: [binary()]
  def narrowing(declaration) when is_map(declaration) and not is_struct(declaration) do
    schema = Map.get(declaration, "parameter_schema") || Map.get(declaration, "input_schema")

    case schema do
      %{} = schema ->
        root = Enum.map(Map.keys(schema) -- @schema_keys, &"parameter_schema.#{&1}")

        properties =
          case Map.get(schema, "properties") do
            %{} = properties ->
              Enum.flat_map(properties, fn
                {name, %{} = property} when is_binary(name) ->
                  Enum.map(
                    Map.keys(property) -- @property_keys,
                    &"parameter_schema.properties.#{name}.#{&1}"
                  )

                _other ->
                  []
              end)

            _other ->
              []
          end

        Enum.sort(root ++ properties)

      _other ->
        []
    end
  end

  def narrowing(_declaration), do: []

  defp narrow_schema(schema) when is_map(schema) and not is_struct(schema) do
    properties =
      schema
      |> Map.get("properties", %{})
      |> case do
        map when is_map(map) and not is_struct(map) ->
          Map.new(map, fn {name, property} -> {name, narrow_property(property)} end)

        other ->
          other
      end

    %{
      "type" => Map.get(schema, "type", "object"),
      "properties" => properties,
      "required" => Map.get(schema, "required", [])
    }
  end

  defp narrow_schema(schema), do: schema

  defp narrow_property(property) when is_map(property) and not is_struct(property),
    do: Map.take(property, @property_keys)

  defp narrow_property(property), do: property

  @doc """
  ## Concept

  Every reason this term is not a valid tool definition; an empty list means it
  is one.

  ## Technical depth

  Checks are independent and all run, so the result is the complete reason set
  rather than the first failure. Each reason is a bounded binary naming the
  field and what was wrong with it. A term that is not a map with exactly the
  nine binary-keyed fields fails on shape before any field is inspected, which
  is why the field checks may assume presence.
  """
  @spec validate(term()) :: [binary()]
  def validate(definition) when is_map(definition) and not is_struct(definition) do
    case shape_reasons(definition) do
      [] -> Enum.flat_map(@fields, &field_reasons(&1, Map.fetch!(definition, &1)))
      reasons -> reasons
    end
  end

  def validate(_definition), do: ["a tool definition must be a map with binary keys"]

  @doc """
  ## Concept

  Whether this term is a valid tool definition.

  ## Technical depth

  A convenience over `validate/1` for call sites that only branch on validity.
  """
  @spec valid?(term()) :: boolean()
  def valid?(definition), do: validate(definition) == []

  @doc """
  ## Concept

  Checks one model-supplied argument object against this generation's declared
  parameter schema before policy sees it or an effect intent is committed.

  ## Technical depth

  Evaluates exactly the registered subset: required members, declared scalar
  types, scalar array items, and string enumerations. Undeclared members remain
  ordinary JSON-Schema additions because this subset has no
  `additionalProperties` keyword; they must still be bounded JSON-like plain
  data. A registered definition is expected, but an invalid definition fails
  closed rather than turning a malformed registry entry into an unchecked call.
  """
  @spec validate_arguments(t(), term()) :: :ok | {:error, :invalid_arguments}
  def validate_arguments(definition, arguments)
      when is_map(definition) and not is_struct(definition) and is_map(arguments) and
             not is_struct(arguments) do
    schema = Map.get(definition, "parameter_schema")

    valid =
      valid?(definition) and json_plain?(arguments) and
        arguments_match_schema?(arguments, schema)

    if valid, do: :ok, else: {:error, :invalid_arguments}
  end

  def validate_arguments(_definition, _arguments), do: {:error, :invalid_arguments}

  @doc """
  ## Concept

  The exact bytes this definition's digest covers.

  ## Technical depth

  Covers the definition-version tag, the canonical-encoding version, and all
  nine fields. Both version tags sit inside the covered bytes, so a retained
  digest always states which shape and which encoding produced it. Raises when
  the definition is invalid, because canonical bytes for a record that could
  never be registered have no meaning and returning them invites a caller to
  retain one.
  """
  @spec canonical_bytes(t()) :: binary()
  def canonical_bytes(definition) do
    case validate(definition) do
      [] ->
        Canonical.encode(%{
          "definition_version" => @definition_version,
          "canonicalization_version" => Canonical.version(),
          "definition" => Map.take(definition, @fields)
        })

      reasons ->
        raise ArgumentError,
              "cannot canonicalize an invalid tool definition: #{Enum.join(reasons, "; ")}"
    end
  end

  @doc """
  ## Concept

  This definition's content digest.

  ## Technical depth

  The third member of the generation triple. Callers retain the canonical bytes
  beside it; the registry compares bytes rather than trusting digest equality.
  """
  @spec definition_digest(t()) :: binary()
  def definition_digest(definition),
    do: definition |> canonical_bytes() |> Canonical.digest_bytes()

  @doc """
  ## Concept

  This definition's generation triple.

  ## Technical depth

  `{tool_id, tool_version, definition_digest}`. This is the value a staged
  request records, a tool-operation intent journals, and a grant binds, so a
  dispatched call names the exact bytes the model was shown.
  """
  @spec generation(t()) :: generation()
  def generation(definition) do
    {Map.fetch!(definition, "tool_id"), Map.fetch!(definition, "tool_version"),
     definition_digest(definition)}
  end

  @doc """
  ## Concept

  Whether a `tool_id` sits in the reserved `loopex.` namespace.

  ## Technical depth

  The registry refuses a reserved identifier offered from outside the reference
  distribution. The prefix check lives here, beside the identifier's grammar, so
  both rules are read together.
  """
  @spec reserved?(binary()) :: boolean()
  def reserved?(tool_id) when is_binary(tool_id),
    do: String.starts_with?(tool_id, @reserved_prefix)

  @doc """
  ## Concept

  The three model-facing fields a provider request renders.

  ## Technical depth

  A staged request carries every field of the record so its `definition_digest`
  stays checkable from the journal alone; this projection is what an adapter
  renders into a provider's own tool format at the edge. Core never stages the
  projection in place of the record.
  """
  @spec model_facing(t()) :: %{binary() => term()}
  def model_facing(definition), do: Map.take(definition, ~w(name description parameter_schema))

  defp shape_reasons(definition) do
    keys = definition |> Map.keys() |> Enum.filter(&is_binary/1)

    if map_size(definition) != length(keys) do
      ["a tool definition must use only binary keys"]
    else
      Enum.map(@fields -- keys, &"#{&1}: required field is missing") ++
        Enum.map(keys -- @fields, &"#{&1}: is not a tool definition field")
    end
  end

  defp field_reasons("tool_id", value) do
    cond do
      not is_binary(value) ->
        ["tool_id: must be a binary"]

      byte_size(value) > @max_tool_id_bytes ->
        ["tool_id: exceeds #{@max_tool_id_bytes} bytes"]

      not Regex.match?(@tool_id_pattern, value) ->
        ["tool_id: must be dot-segmented lowercase ASCII"]

      true ->
        []
    end
  end

  defp field_reasons("tool_version", value) do
    if is_binary(value) and Regex.match?(@version_pattern, value),
      do: [],
      else: ["tool_version: must be an exact major.minor.patch version"]
  end

  defp field_reasons("name", value) do
    if is_binary(value) and Regex.match?(@name_pattern, value),
      do: [],
      else: ["name: must match ^[a-z][a-z0-9_]{0,63}$"]
  end

  defp field_reasons("description", value) do
    cond do
      not is_binary(value) ->
        ["description: must be a binary"]

      value == "" ->
        ["description: must not be empty"]

      byte_size(value) > @max_description_bytes ->
        ["description: exceeds #{@max_description_bytes} bytes"]

      true ->
        []
    end
  end

  defp field_reasons("effect_class", value),
    do: enumerated("effect_class", value, @effect_classes)

  defp field_reasons("idempotency_class", value),
    do: enumerated("idempotency_class", value, @idempotency_classes)

  defp field_reasons("result_shape", value) when is_map(value) and not is_struct(value) do
    cond do
      Map.keys(value) -- @result_shape_keys != [] ->
        ["result_shape: admits only #{Enum.join(@result_shape_keys, " and ")}"]

      Map.get(value, "content_type") not in @result_content_types ->
        ["result_shape: content_type must be #{Enum.join(@result_content_types, " or ")}"]

      not is_binary(Map.get(value, "description", "")) ->
        ["result_shape: description must be a binary"]

      true ->
        []
    end
  end

  defp field_reasons("result_shape", _value), do: ["result_shape: must be a map"]

  defp field_reasons("budgets", value) when is_map(value) and not is_struct(value) do
    missing = Enum.map(@budget_fields -- Map.keys(value), &"budgets: #{&1} is missing")
    extra = Enum.map(Map.keys(value) -- @budget_fields, &"budgets: #{&1} is not a budget")

    # Concept: a missing ceiling is reported once, by `missing` above.
    #
    # Technical depth: this pass therefore ignores `nil` rather than reporting a
    # second reason for the same field, which would make the reason list read as
    # two independent defects.
    positive =
      Enum.flat_map(@budget_fields, fn field ->
        case Map.get(value, field) do
          amount when is_integer(amount) and amount > 0 -> []
          nil -> []
          _other -> ["budgets: #{field} must be a positive integer"]
        end
      end)

    missing ++ extra ++ positive
  end

  defp field_reasons("budgets", _value), do: ["budgets: must be a map"]

  defp field_reasons("parameter_schema", value), do: schema_reasons(value)

  defp enumerated(field, value, permitted) do
    if value in permitted,
      do: [],
      else: ["#{field}: must be one of #{Enum.join(permitted, ", ")}"]
  end

  # Concept: the schema subset core can actually evaluate.
  #
  # Technical depth: refusal is at registration, not dispatch. A construct this
  # walk does not understand — a nested object, a union, a `$ref`, a conditional
  # keyword — is rejected by name rather than skipped, because a skipped keyword
  # reads as "validated" to every later caller while validating nothing.
  defp schema_reasons(schema) when is_map(schema) and not is_struct(schema) do
    properties = Map.get(schema, "properties")
    required = Map.get(schema, "required", [])

    cond do
      Map.keys(schema) -- @schema_keys != [] ->
        ["parameter_schema: admits only #{Enum.join(@schema_keys, ", ")}"]

      Map.get(schema, "type") != "object" ->
        ["parameter_schema: root type must be object"]

      not (is_map(properties) and not is_struct(properties)) ->
        ["parameter_schema: properties must be a map"]

      not (is_list(required) and Enum.all?(required, &is_binary/1)) ->
        ["parameter_schema: required must be a list of names"]

      required -- Map.keys(properties) != [] ->
        ["parameter_schema: required names a property that is not declared"]

      true ->
        Enum.flat_map(properties, fn {name, property} -> property_reasons(name, property) end)
    end
  end

  defp schema_reasons(_schema), do: ["parameter_schema: must be a map"]

  defp property_reasons(name, _property) when not is_binary(name),
    do: ["parameter_schema: property names must be binaries"]

  defp property_reasons(name, property) when is_map(property) and not is_struct(property) do
    type = Map.get(property, "type")

    cond do
      Map.keys(property) -- @property_keys != [] ->
        ["parameter_schema: #{name} admits only #{Enum.join(@property_keys, ", ")}"]

      type not in @property_types ->
        ["parameter_schema: #{name} type must be one of #{Enum.join(@property_types, ", ")}"]

      not is_binary(Map.get(property, "description", "")) ->
        ["parameter_schema: #{name} description must be a binary"]

      true ->
        enum_reasons(name, Map.get(property, "enum")) ++
          items_reasons(name, type, Map.get(property, "items"))
    end
  end

  defp property_reasons(name, _property), do: ["parameter_schema: #{name} must be a map"]

  defp enum_reasons(_name, nil), do: []

  defp enum_reasons(name, enum) do
    if is_list(enum) and enum != [] and Enum.all?(enum, &is_binary/1),
      do: [],
      else: ["parameter_schema: #{name} enum must be a non-empty list of strings"]
  end

  defp items_reasons(name, "array", items) when is_map(items) and not is_struct(items) do
    cond do
      Map.keys(items) -- ["type"] != [] ->
        ["parameter_schema: #{name} items admits only type"]

      Map.get(items, "type") not in @scalar_item_types ->
        ["parameter_schema: #{name} items type must be a scalar type"]

      true ->
        []
    end
  end

  defp items_reasons(name, "array", _items),
    do: ["parameter_schema: #{name} is an array and must declare scalar items"]

  defp items_reasons(_name, _type, nil), do: []

  defp items_reasons(name, _type, _items),
    do: ["parameter_schema: #{name} declares items but is not an array"]

  defp arguments_match_schema?(arguments, %{
         "type" => "object",
         "properties" => properties,
         "required" => required
       })
       when is_map(properties) and is_list(required) do
    Enum.all?(required, &Map.has_key?(arguments, &1)) and
      Enum.all?(properties, fn {name, property} ->
        not Map.has_key?(arguments, name) or
          property_matches?(Map.fetch!(arguments, name), property)
      end)
  end

  defp arguments_match_schema?(_arguments, _schema), do: false

  defp property_matches?(value, %{"type" => type} = property) do
    type_matches?(value, type, Map.get(property, "items")) and
      enum_matches?(value, Map.get(property, "enum"))
  end

  defp property_matches?(_value, _property), do: false

  defp type_matches?(value, "string", _items), do: is_binary(value)
  defp type_matches?(value, "integer", _items), do: is_integer(value)
  defp type_matches?(value, "number", _items), do: is_integer(value) or is_float(value)
  defp type_matches?(value, "boolean", _items), do: is_boolean(value)

  defp type_matches?(value, "array", %{"type" => item_type}) when is_list(value),
    do: Enum.all?(value, &type_matches?(&1, item_type, nil))

  defp type_matches?(_value, _type, _items), do: false

  defp enum_matches?(_value, nil), do: true
  defp enum_matches?(value, enum) when is_list(enum), do: value in enum
  defp enum_matches?(_value, _enum), do: false

  defp json_plain?(value)
       when is_binary(value) or is_integer(value) or is_float(value) or is_boolean(value) or
              is_nil(value),
       do: true

  defp json_plain?(value) when is_list(value), do: Enum.all?(value, &json_plain?/1)

  defp json_plain?(value) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_plain?(nested) end)
  end

  defp json_plain?(_value), do: false
end
