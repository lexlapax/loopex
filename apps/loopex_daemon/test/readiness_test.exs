defmodule LoopexDaemon.ReadinessTest do
  use ExUnit.Case, async: true

  alias LoopexDaemon.Readiness
  alias LoopexProtocol.Frame

  test "encodes the exact ordered record with one literal newline" do
    root = "/tmp/root \"quoted\"\\tab\tline\nnext"
    socket = root <> "/daemon/socket\\\" name"

    assert {:ok, line} = Readiness.encode(root, socket, "incarnation-1", "0.2.0")

    assert line ==
             "{\"record\":\"daemon_ready\",\"root\":\"/tmp/root \\\"quoted\\\"\\\\tab\\tline\\nnext\"," <>
               "\"socket\":\"/tmp/root \\\"quoted\\\"\\\\tab\\tline\\nnext/daemon/socket\\\\\\\" name\"," <>
               "\"incarnation\":\"incarnation-1\",\"version\":\"0.2.0\"}\n"

    assert :binary.matches(line, "\n") == [{byte_size(line) - 1, 1}]

    payload = binary_part(line, 0, byte_size(line) - 1)

    assert {:ok,
            %{
              "record" => "daemon_ready",
              "root" => ^root,
              "socket" => ^socket,
              "incarnation" => "incarnation-1",
              "version" => "0.2.0"
            }} = Frame.decode(payload, 4_096)
  end

  test "escapes every JSON control form and preserves unicode" do
    root = <<?/, ?r, ?\b, ?\f, ?\r, 0, 31>> <> "-λ"

    assert {:ok, line} = Readiness.encode(root, "/socket", "ι", "0.2.0")
    assert line =~ ~S("root":"/r\b\f\r\u0000\u001f-λ")
    refute line =~ <<0>>
    refute line =~ <<31>>
  end

  test "refuses empty, non-binary and invalid UTF-8 values" do
    valid = ["/root", "/socket", "incarnation", "0.2.0"]

    for invalid <- ["", :not_binary, <<255>>], index <- 0..3 do
      arguments = List.replace_at(valid, index, invalid)
      assert {:error, :invalid_readiness_value} = apply(Readiness, :encode, arguments)
    end
  end
end
