defmodule LoopexCli.ChatInput do
  @moduledoc """
  ## Concept

  Read exactly one conversation line and translate its explicit syntax. Reading
  the next line remains the driver's decision, including after a wait barrier.

  ## Technical depth

  ADR 0049 admits LF or CRLF terminated UTF-8 lines up to 65,536 bytes before
  the terminator. The byte-oriented device must already use Latin-1 encoding.
  Single-byte requests deliberately avoid reading the next command while a
  barrier is outstanding. At most one bounded line is retained. EOF with a
  fragment, bare CR, NUL, invalid UTF-8 and IO failure refuse with fixed codes.
  Parsing supplies no command identity, session state, authority or admission.
  The driver applies the existing facade's command limits and state rules.
  """

  alias LoopexCli.ConfigJson
  alias LoopexProtocol.{Session.Answer, Wire}

  @line_bytes 65_536
  @controls %{
    "/wait" => :wait,
    "/status" => :status,
    "/abort" => :abort,
    "/compact" => :compact,
    "/quit" => :quit
  }

  @doc """
  ## Concept

  Read one terminated line without consuming any following command.

  ## Technical depth

  Returns the parsed action, `:empty`, `:eof`, or a fixed refusal. No read is
  retried after an IO error. A caller may perform this blocking operation in its
  owned input worker so cancellation does not depend on input availability.
  """
  @spec read(IO.device()) :: {:ok, term()} | :empty | :eof | {:error, atom()}
  def read(device \\ :stdio), do: read_line(device, "")

  @doc """
  ## Concept

  Parse one line whose terminator has already been removed.

  ## Technical depth

  Plain text is preserved, and `//` removes exactly its first slash. Command
  words are literal; no shell expansion or quoting is performed. Answers decode
  their JSON string once, and identities use the existing protocol encoding.
  Configure objects use the duplicate-preserving bounded configuration decoder;
  their allowed fields are subsequently checked by ordinary owner admission.
  """
  @spec parse(term()) :: {:ok, term()} | :empty | {:error, atom()}
  def parse(line) when is_binary(line) and byte_size(line) <= @line_bytes do
    cond do
      not String.valid?(line) -> {:error, :invalid_input_utf8}
      String.contains?(line, [<<0>>, "\r", "\n"]) -> {:error, :invalid_input_line}
      line == "" -> :empty
      true -> action(line)
    end
  end

  def parse(line) when is_binary(line), do: {:error, :input_line_too_large}
  def parse(_), do: {:error, :invalid_input_line}

  defp read_line(device, line) do
    case byte(device) do
      "\n" -> parse(line)
      "\r" -> finish_crlf(device, line)
      <<0>> -> {:error, :invalid_input_line}
      :eof when line == "" -> :eof
      :eof -> {:error, :unterminated_input_line}
      <<_>> when byte_size(line) == @line_bytes -> {:error, :input_line_too_large}
      <<next>> -> read_line(device, <<line::binary, next>>)
      _ -> {:error, :input_failed}
    end
  end

  defp finish_crlf(device, line) do
    case byte(device) do
      "\n" -> parse(line)
      :failed -> {:error, :input_failed}
      _ -> {:error, :invalid_input_line}
    end
  end

  defp byte(device) do
    case IO.binread(device, 1) do
      value when is_binary(value) or value == :eof -> value
      _ -> :failed
    end
  rescue
    _ -> :failed
  catch
    _, _ -> :failed
  end

  defp action("/" <> "/" <> text), do: {:ok, {:prompt, "/" <> text}}
  defp action("/steer " <> text), do: text_action(:steer, text)
  defp action("/follow-up " <> text), do: text_action(:follow_up, text)
  defp action("/answer " <> rest), do: answer(rest)

  defp action("/decline " <> id) do
    response(id, %{"disposition" => "declined"})
  end

  defp action("/configure " <> json) do
    case ConfigJson.decode(json) do
      {:ok, changes} -> {:ok, {:configure, changes}}
      _ -> {:error, :invalid_configure_json}
    end
  end

  defp action("/" <> _ = control) do
    case Map.fetch(@controls, control) do
      {:ok, action} -> {:ok, action}
      :error -> {:error, :invalid_chat_command}
    end
  end

  defp action(text), do: {:ok, {:prompt, text}}

  defp text_action(_, ""), do: {:error, :invalid_chat_command}
  defp text_action(type, text), do: {:ok, {type, text}}

  defp answer(rest) do
    case String.split(rest, " ", parts: 2) do
      [id, "--text " <> json] -> text_answer(id, json)
      [id, "--choice " <> choice] -> response(id, %{"choice_id" => choice})
      _ -> {:error, :invalid_chat_answer}
    end
  end

  defp text_answer(id, json) do
    case String.trim_leading(json, " ") do
      <<?\", _::binary>> = json ->
        case :json.decode(json) do
          text when is_binary(text) -> response(id, %{"text" => text})
          _ -> {:error, :invalid_chat_answer}
        end

      _ ->
        {:error, :invalid_chat_answer}
    end
  rescue
    _ -> {:error, :invalid_chat_answer}
  end

  defp response(id, answer) do
    with {:ok, id} <- Wire.identity(id),
         {:ok, answer} <- Answer.decode_wire(answer) do
      {:ok, {:answer, id, answer}}
    else
      _ -> {:error, :invalid_chat_answer}
    end
  end
end
