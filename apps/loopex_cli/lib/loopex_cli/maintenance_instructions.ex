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

  @block %{
    "version" => "loopex.reference.maintenance.v1",
    "body" =>
      "Summarize the conversation so far so work can continue from the summary alone. " <>
        "Keep every user requirement and decision, exact file paths, commands, identifiers, " <>
        "numbers and quoted values, the results of tool calls later work depends on, and " <>
        "open questions. Do not invent facts or add advice."
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
