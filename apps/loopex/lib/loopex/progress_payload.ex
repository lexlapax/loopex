defmodule Loopex.ProgressPayload do
  @moduledoc false

  # Concept: progress is displayable data, never a terminal instruction.
  #
  # Technical depth: UTF-8 text may contain tabs, newlines, and carriage returns
  # that ordinary model and command output legitimately use. The remaining C0
  # controls include ESC, BEL, backspace, and string terminators; DEL and C1
  # carry their eight-bit equivalents. Refusing those code points prevents ANSI,
  # OSC/clipboard, title, cursor, and erase sequences from reaching a terminal.
  # Invalid UTF-8 is refused because it cannot be classified by code point and a
  # byte in the C1 range is otherwise indistinguishable from text continuation.
  @terminal_controls ~r/[\x{0000}-\x{0008}\x{000B}\x{000C}\x{000E}-\x{001F}\x{007F}-\x{009F}]/u

  @spec terminal_safe?(term()) :: boolean()
  def terminal_safe?(value) when is_binary(value) do
    String.valid?(value) and not Regex.match?(@terminal_controls, value)
  end

  def terminal_safe?(_value), do: false
end
