defmodule LoopexCli.MaintenanceInstructions do
  @moduledoc """
  ## Concept

  The reference host's shared, versioned maintenance instructions: what a
  compaction summary must keep so the conversation can continue from it.

  ## Technical depth

  ADR 0043 has reference hosts supply this block explicitly through
  composition; composition and Core invent none. It is the closed
  `{version, body}` map, rendered by Core as `version + ": " + body` and
  captured once per episode. Changing the body requires a new version.
  """

  # ADR 0043 admits only the closed summary/carry-forward JSON object and has the
  # reference instruction ask for a compact envelope below 3,072 encoded bytes.
  @block %{
    "version" => "loopex.reference.maintenance.v2",
    "body" =>
      "Summarize the conversation so far so work can continue from the summary alone. " <>
        "Keep every user requirement and decision, exact file paths, commands, identifiers, " <>
        "numbers and quoted values, the results of tool calls later work depends on, and " <>
        "open questions. When the conversation starts from an earlier summary, carry forward " <>
        "every fact it states, copying exact names, values and paths verbatim. Do not invent " <>
        "facts or add advice. Your entire reply is one compact " <>
        "JSON object under 3,000 bytes. Its first character is { and its last is }. Never wrap " <>
        "it in ``` backticks or add any other text. Use exactly this shape: " <>
        ~s({"summary": "<the summary>", "carry_forward": {"files_read": ["<path>"], ) <>
        ~s("files_changed": ["<path>"]}}. List each workspace path at most once.)
  }

  @doc """
  ## Concept

  The block every reference conversation composes.

  ## Technical depth

  Returned as data; validation and capture belong to the runtime.
  """
  @spec reference() :: map()
  def reference, do: @block
end
