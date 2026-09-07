defmodule Loopex.LLM.ReqLLM.ProviderCodecTest do
  use ExUnit.Case, async: true

  alias Loopex.LLM.ReqLLM.ProviderCodec
  alias Loopex.Store

  @nonce String.duplicate("a", 64)
  @digest String.duplicate("b", 64)

  test "every closed kind round-trips its exact envelope" do
    handshake = %{"nonce" => @nonce, "version" => 1, "build_manifest_sha256" => @digest}

    frames = [
      {:bootstrap, handshake},
      {:ready, handshake},
      {:credential, %{"nonce" => @nonce, "credential" => <<0, 255, 128>>}},
      {:invocation, invocation(%{model: "fixture", continuation: nil}, <<131, 0, 255>>)},
      {:dispatch_started, identity_fields()},
      {:delta,
       Map.put(identity_fields(), "payload", %{kind: :text_delta, content_index: 0, text: "ok"})},
      {:terminal, terminal(%{text: "ok", usage: %{input_tokens: 1, output_tokens: 2}})}
    ]

    for {kind, payload} <- frames do
      assert {:ok, frame} = ProviderCodec.encode(kind, payload)
      assert {:ok, ^kind, ^payload} = ProviderCodec.decode(frame)
      assert byte_size(frame) <= ProviderCodec.cap(kind) + 8
    end

    for status <- ["not_dispatched", "dispatched_or_unknown", "unreadable"] do
      payload = Map.put(identity_fields(), "status", status)
      assert {:ok, frame} = ProviderCodec.encode(:terminal, payload)
      assert {:ok, :terminal, ^payload} = ProviderCodec.decode(frame)
    end
  end

  test "Store-admitted raw scalar values and atom-key spellings survive exactly" do
    negative_zero = -0.0

    body = %{
      text: <<0, 255, 192, 128>>,
      identity: %{provider: "fixture", model: "fixture", endpoint: "local"},
      usage: %{input_tokens: -1, output_tokens: Integer.pow(2, 800)},
      tool_calls: [%{"arguments" => %{"fraction" => 0.25, <<255>> => false}}],
      provider_response_id: nil,
      streamed: true,
      delta_count: 12,
      private_codec_fixture_key: [negative_zero, [], %{}, true, false, nil]
    }

    assert {:ok, _cost} = Store.admit_bounded(body)
    candidate = terminal(body)
    assert {:ok, frame} = ProviderCodec.encode(:terminal, candidate)
    assert {:ok, :terminal, ^candidate} = ProviderCodec.decode(frame)
    assert {:ok, :terminal, decoded} = ProviderCodec.decode(frame)
    [decoded_zero | _] = decoded["reply"][:private_codec_fixture_key]
    assert <<decoded_zero::float-big-64>> == <<negative_zero::float-big-64>>
  end

  test "a maximum admitted raw body plus both independently bounded echoes fits" do
    overhead = :erlang.external_size(%{"text" => ""}, [:deterministic])
    body = %{"text" => :binary.copy(<<255>>, 65_536 - overhead)}
    assert {:ok, 65_536} = Store.admit_bounded(body)

    reply =
      body
      |> Map.put(:canonical_request_bytes, :binary.copy(<<0>>, 65_536))
      |> Map.put("canonical_request_bytes", :binary.copy(<<255>>, 65_536))

    candidate = terminal(reply)
    assert {:ok, frame} = ProviderCodec.encode(:terminal, candidate)
    assert byte_size(frame) > 3 * 65_536
    assert {:ok, :terminal, ^candidate} = ProviderCodec.decode(frame)

    # Concept: complete settlement can exceed admission without losing the reply.
    # Technical depth: adding even one retained field crosses this body's exact
    # Store limit. The codec transports the admitted body without settling it.
    assert {:error, {:item_too_large, _, 65_536}} =
             Store.admit_bounded(Map.put(body, "accounting_source", "reported"))
  end

  test "a maximum body cardinality may carry two additional echoes" do
    body = Map.new(1..1_024, &{"member-#{&1}", nil})
    assert {:ok, _cost} = Store.admit_bounded(body)
    reply = Map.merge(body, %{:canonical_request_bytes => "a", "canonical_request_bytes" => "b"})
    candidate = terminal(reply)
    assert {:ok, frame} = ProviderCodec.encode(:terminal, candidate)
    assert {:ok, :terminal, ^candidate} = ProviderCodec.decode(frame)
  end

  test "wire expansion accommodates external-term byte-list compression" do
    body = %{"lists" => List.duplicate(List.duplicate(255, 1_024), 60)}
    assert {:ok, measured} = Store.admit_bounded(body)
    candidate = terminal(body)
    assert {:ok, frame} = ProviderCodec.encode(:terminal, candidate)
    assert byte_size(frame) > measured * 6
    assert {:ok, :terminal, ^candidate} = ProviderCodec.decode(frame)
  end

  test "request semantic bytes, canonical bytes and progress have independent ceilings" do
    overhead = :erlang.external_size(%{"content" => ""}, [:deterministic])
    semantic = %{"content" => :binary.copy(<<0>>, 65_536 - overhead)}
    assert {:ok, 65_536} = Store.admit_bounded(semantic)
    request = invocation(semantic, :binary.copy(<<255>>, 65_536))
    assert {:ok, frame} = ProviderCodec.encode(:invocation, request)
    assert {:ok, :invocation, ^request} = ProviderCodec.decode(frame)

    delta =
      Map.put(identity_fields(), "payload", %{kind: :text_delta, text: :binary.copy("x", 65_536)})

    assert {:ok, frame} = ProviderCodec.encode(:delta, delta)
    assert {:ok, :delta, ^delta} = ProviderCodec.decode(frame)
  end

  test "credentials admit the exact bound and refuse empty or oversized values" do
    for size <- [0, 65_537] do
      assert {:error, :invalid_frame} =
               ProviderCodec.encode(:credential, %{
                 "nonce" => @nonce,
                 "credential" => :binary.copy("c", size)
               })
    end

    payload = %{"nonce" => @nonce, "credential" => :binary.copy("c", 65_536)}
    assert {:ok, frame} = ProviderCodec.encode(:credential, payload)
    assert {:ok, :credential, ^payload} = ProviderCodec.decode(frame)
  end

  test "closed fields, identities, result variants and plain-value rules fail closed" do
    for value <- [
          self(),
          make_ref(),
          fn -> :ok end,
          {:a, 1},
          [1 | :tail],
          %{__struct__: URI},
          :reported
        ] do
      assert {:error, :invalid_frame} =
               ProviderCodec.encode(:terminal, terminal(%{"value" => value}))
    end

    for payload <- [
          Map.put(identity_fields(), "status", "unknown"),
          identity_fields() |> Map.put("status", "unreadable") |> Map.put("reply", %{}),
          terminal(%{}) |> Map.put("extra", nil),
          terminal(%{}) |> Map.put("nonce", String.duplicate("A", 64)),
          terminal(%{}) |> Map.put("staged_request_digest", "wrong"),
          terminal(%{canonical_request_bytes: :not_bytes}),
          terminal(%{"canonical_request_bytes" => :binary.copy("x", 65_537)})
        ] do
      assert {:error, :invalid_frame} = ProviderCodec.encode(:terminal, payload)
    end

    assert {:error, :invalid_frame} = ProviderCodec.encode(:unknown_kind, identity_fields())
    assert {:error, :invalid_frame} = ProviderCodec.encode(:terminal, %{nonce: @nonce})
  end

  test "depth and collection bounds include exactly the codec envelope level" do
    legal = Enum.reduce(1..11, nil, fn _, child -> [child] end)
    assert {:ok, _cost} = Store.admit_bounded(%{"nested" => legal})
    assert {:ok, frame} = ProviderCodec.encode(:terminal, terminal(%{"nested" => legal}))
    assert {:ok, :terminal, _payload} = ProviderCodec.decode(frame)

    for body <- [
          %{"nested" => [legal]},
          %{"nested" => List.duplicate(nil, 1_025)},
          %{"nested" => Map.new(1..1_025, &{"key-#{&1}", nil})},
          %{String.duplicate("k", 257) => nil}
        ] do
      assert {:error, :invalid_frame} = ProviderCodec.encode(:terminal, terminal(body))
    end
  end

  test "decoder refuses unknown atoms without creating them or erasing binary-key collisions" do
    name = "codec_missing_atom_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(name, :utf8) end
    assert {:ok, frame} = ProviderCodec.encode(:terminal, terminal(%{name => 1}))

    changed =
      :binary.replace(
        frame,
        <<0, byte_size(name)::16, name::binary>>,
        <<1, byte_size(name)::16, name::binary>>
      )

    assert {:error, :invalid_frame} = ProviderCodec.decode(changed)
    assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(name, :utf8) end

    candidate = terminal(%{:text => "atom", "text" => "binary"})
    assert {:ok, frame} = ProviderCodec.encode(:terminal, candidate)
    assert {:ok, :terminal, ^candidate} = ProviderCodec.decode(frame)
  end

  test "decoder refuses duplicate keys, invalid value tags, lengths, versions and trailing bytes" do
    assert {:ok, frame} = ProviderCodec.encode(:terminal, terminal(%{"x" => nil, "y" => true}))
    duplicate = :binary.replace(frame, <<0, 1::16, "y">>, <<0, 1::16, "x">>)
    assert {:error, :invalid_frame} = ProviderCodec.decode(duplicate)

    for malformed <- [
          <<"LP", 2, 7, 1::32, 0>>,
          <<"LP", 1, 255, 1::32, 0>>,
          <<"LP", 1, 7, 1::32, 255>>,
          <<"LP", 1, 7, 0::32>>,
          <<"LP", 1, 7, 4_294_967_295::32>>,
          <<"LP", 1, 7, 5::32, 3, 65_537::32>>,
          <<"LP", 1, 7, 3::32, 6, 1_025::16>>,
          :erlang.term_to_binary(terminal(%{})),
          binary_part(frame, 0, byte_size(frame) - 1),
          frame <> <<0>>
        ] do
      assert {:error, :invalid_frame} = ProviderCodec.decode(malformed)
    end
  end

  test "AF_UNIX fragmented reads return one complete frame and leave the next untouched" do
    {sender, receiver} = socket_pair()
    first = terminal(%{"text" => :binary.copy("x", 20_000)})
    second = Map.put(identity_fields(), "status", "unreadable")
    assert {:ok, encoded_first} = ProviderCodec.encode(:terminal, first)
    assert {:ok, encoded_second} = ProviderCodec.encode(:terminal, second)

    producer =
      spawn_link(fn ->
        for <<byte <- encoded_first>>, do: :ok = :gen_tcp.send(sender, <<byte>>)
        :ok = :gen_tcp.send(sender, encoded_second)
      end)

    assert {:ok, :terminal, ^first} = ProviderCodec.recv(receiver, 5_000)
    assert {:ok, :terminal, ^second} = ProviderCodec.recv(receiver, 5_000)
    ref = Process.monitor(producer)
    assert_receive {:DOWN, ^ref, :process, ^producer, _reason}, 1_000
  end

  test "oversized declarations refuse before payload and partial EOF never becomes a result" do
    {sender, receiver} = socket_pair()
    :ok = :gen_tcp.send(sender, <<"LP", 1, 7, ProviderCodec.cap(:terminal) + 1::32>>)
    assert {:error, :invalid_frame} = ProviderCodec.recv(receiver, 1_000)

    {sender, receiver} = socket_pair()
    assert {:ok, frame} = ProviderCodec.encode(:terminal, terminal(%{"text" => "complete"}))
    :ok = :gen_tcp.send(sender, binary_part(frame, 0, byte_size(frame) - 1))
    :ok = :gen_tcp.close(sender)
    assert {:error, reason} = ProviderCodec.recv(receiver, 1_000)
    assert reason in [:closed, :invalid_frame]
  end

  test "fragment arrival spends one deadline across header and all payload reads" do
    {sender, receiver} = socket_pair()

    assert {:ok, frame} =
             ProviderCodec.encode(:terminal, terminal(%{"text" => :binary.copy("x", 12_000)}))

    <<header::binary-size(8), first::binary-size(4_096), tail::binary>> = frame
    :ok = :gen_tcp.send(sender, header)

    producer =
      spawn_link(fn ->
        Process.sleep(80)
        :ok = :gen_tcp.send(sender, first)
        Process.sleep(80)
        :ok = :gen_tcp.send(sender, tail)
      end)

    started = System.monotonic_time(:millisecond)
    assert {:error, :timeout} = ProviderCodec.recv(receiver, 120)
    assert System.monotonic_time(:millisecond) - started < 220
    monitor = Process.monitor(producer)
    assert_receive {:DOWN, ^monitor, :process, ^producer, _reason}, 1_000
  end

  test "a timeout beyond the VM timer domain receives a complete frame" do
    {sender, receiver} = socket_pair()
    payload = terminal(%{"text" => "complete"})

    producer =
      spawn_link(fn ->
        Process.sleep(20)
        :ok = ProviderCodec.send(sender, :terminal, payload)
      end)

    assert {:ok, :terminal, ^payload} = ProviderCodec.recv(receiver, Integer.pow(2, 80))
    monitor = Process.monitor(producer)
    assert_receive {:DOWN, ^monitor, :process, ^producer, _reason}, 1_000
  end

  test "received terminal nesting is bounded independently of encoder rejection" do
    legal = Enum.reduce(1..11, nil, fn _, child -> [child] end)
    assert {:ok, _cost} = Store.admit_bounded(%{"nested" => legal})
    assert {:error, _reason} = Store.admit_bounded(%{"nested" => [legal]})

    candidate = %{
      "nonce" => String.duplicate("a", 64),
      "staged_request_digest" => String.duplicate("b", 64),
      "status" => "reply",
      "reply" => %{"nested" => legal}
    }

    assert {:ok, frame} = ProviderCodec.encode(:terminal, candidate)
    <<prefix::binary-size(4), _length::32, body::binary>> = frame
    key = <<0, 6::16, "nested">>
    assert length(:binary.matches(body, key)) == 1
    deeper = :binary.replace(body, key, key <> <<6, 1::16>>)
    over_depth = <<prefix::binary, byte_size(deeper)::32, deeper::binary>>

    {sender, receiver} = socket_pair()

    # Bypass only encoding of the invalid candidate. The parent receives a
    # correctly framed, otherwise valid reply over its actual AF_UNIX codec.
    assert :ok = :gen_tcp.send(sender, frame <> over_depth)
    assert {:ok, :terminal, ^candidate} = ProviderCodec.recv(receiver, 1_000)
    assert {:error, :invalid_frame} = ProviderCodec.recv(receiver, 1_000)
    assert {:error, :invalid_frame} = ProviderCodec.decode(over_depth)
  end

  defp identity_fields, do: %{"nonce" => @nonce, "staged_request_digest" => @digest}
  defp terminal(reply), do: Map.merge(identity_fields(), %{"status" => "reply", "reply" => reply})

  defp invocation(request, bytes) do
    Map.merge(identity_fields(), %{"request" => request, "canonical_request_bytes" => bytes})
  end

  defp socket_pair do
    root = Path.join(System.tmp_dir!(), "lpc-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    path = Path.join(root, "s")
    options = [:binary, active: false, packet: :raw, send_timeout: 1_000]
    {:ok, listener} = :gen_tcp.listen(0, [{:ifaddr, {:local, path}} | options])
    File.chmod!(path, 0o600)
    {:ok, sender} = :gen_tcp.connect({:local, path}, 0, options, 1_000)
    {:ok, receiver} = :gen_tcp.accept(listener, 1_000)
    :gen_tcp.close(listener)

    on_exit(fn ->
      :gen_tcp.close(sender)
      :gen_tcp.close(receiver)
      File.rm_rf!(root)
    end)

    {sender, receiver}
  end
end
