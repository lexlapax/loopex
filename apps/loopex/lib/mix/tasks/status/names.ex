defmodule Loopex.Checks.Names do
  @moduledoc """
  ## Concept

  Validates milestone names. A milestone name appears in the register, in three
  filenames, and in every commit that belongs to it, so an ambiguous name splits
  one milestone's records into two sets that both look complete.

  ## Technical depth

  Enforces the naming rule from the development contract: lowercase hyphenated
  ASCII, an `M` followed by digits, or a version-shaped numeric slug; at most 64
  ASCII bytes; unique under case folding; and none of the reserved names,
  including Windows device basenames and the `-gate` and `-technical` suffixes
  that identify a milestone's other two files.
  """

  alias Loopex.Checks.Invalid

  @name ~r/\A(?:M[0-9]+|v?[0-9]+(?:\.[0-9]+)+|[a-z0-9]+(?:-[a-z0-9]+)*)\z/u
  @max_bytes 64
  @reserved MapSet.new(
              ["planning", "seed", "readme", "con", "prn", "aux", "nul"] ++
                for(prefix <- ["com", "lpt"], number <- 1..9, do: "#{prefix}#{number}")
            )

  @doc """
  ## Concept

  Reads a code-formatted milestone name from a register cell or filename and
  returns the bare name, failing when it is malformed or reserved.

  ## Technical depth

  The backtick wrapper is required because the register is a Markdown table: an
  unquoted name would render as prose and a name containing table syntax would
  shift columns. Byte length is measured after the pattern check, so a name that
  is not ASCII fails on the pattern rather than on an encoding error.
  """
  @spec milestone!(String.t(), String.t()) :: String.t()
  def milestone!(raw, path) do
    unless byte_size(raw) >= 3 and String.starts_with?(raw, "`") and String.ends_with?(raw, "`") do
      raise Invalid, "#{path}: milestone names must be code-formatted"
    end

    name = binary_part(raw, 1, byte_size(raw) - 2)
    folded = String.downcase(name)

    if not Regex.match?(@name, name) or byte_size(name) > @max_bytes or
         MapSet.member?(@reserved, folded) or String.ends_with?(folded, "-gate") or
         String.ends_with?(folded, "-technical") do
      raise Invalid, "#{path}: invalid or reserved milestone name #{inspect(name)}"
    end

    name
  end
end
