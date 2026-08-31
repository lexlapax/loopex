defmodule Loopex.Store.Local.ArtifactStoreConformanceTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.ArtifactStore
  alias Loopex.Store.Local.Artifacts

  # Concept: one suite every artifact store satisfies.
  #
  # Technical depth: the suite is written against the behaviour, so a second
  # implementation joins by being added to `implementations/0` rather than by
  # someone writing a second suite that can drift from this one. M2 ships exactly
  # one adapter; the in-memory implementation below is test support and is
  # deliberately not product surface, not composable by a host, and not
  # documented as an adapter.

  defmodule InMemory do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def open do
      {:ok, pid} = Agent.start_link(fn -> %{} end)
      {:ok, pid}
    end

    @impl Loopex.ArtifactStore
    def put(pid, bytes, metadata) do
      role = Map.get(metadata, "role", "tool_output")

      if role in ArtifactStore.roles() do
        digest = Canonical.digest_bytes(bytes)
        locator = "memory:" <> Canonical.digest_bytes("locator:" <> digest)

        reference = %{
          digest: digest,
          media_type: Map.get(metadata, "media_type", "application/octet-stream"),
          size: byte_size(bytes),
          role: role,
          locator: locator
        }

        :ok = Agent.update(pid, &Map.put(&1, locator, {reference, bytes}))

        {:ok, reference}
      else
        {:error, {:unknown_artifact_role, role}}
      end
    end

    @impl Loopex.ArtifactStore
    def fetch(pid, reference) do
      case Agent.get(pid, &Map.fetch(&1, reference.locator)) do
        {:ok, {_stored_reference, bytes}} ->
          if Canonical.digest_bytes(bytes) == reference.digest and
               byte_size(bytes) == reference.size,
             do: {:ok, bytes},
             else: {:error, :artifact_integrity_failed}

        :error ->
          {:error, :unknown_artifact}
      end
    end

    @impl Loopex.ArtifactStore
    def stat(pid, reference) do
      result =
        Agent.get_and_update(pid, fn state ->
          {Map.fetch(state, reference.locator), Map.put(state, :last_stat_probe, reference)}
        end)

      case result do
        {:ok, {stored_reference, bytes}} ->
          if Canonical.digest_bytes(bytes) == stored_reference.digest and
               byte_size(bytes) == stored_reference.size,
             do: {:ok, stored_reference},
             else: {:error, :artifact_integrity_failed}

        :error ->
          {:error, :unknown_artifact}
      end
    end

    def corrupt(pid, locator, bytes) do
      Agent.update(pid, fn state ->
        Map.update!(state, locator, fn {reference, _stored} -> {reference, bytes} end)
      end)
    end

    def last_stat_probe(pid), do: Agent.get(pid, &Map.fetch!(&1, :last_stat_probe))
  end

  defp implementations do
    root =
      Path.join(
        System.fetch_env!("LOOPEX_HOME"),
        "artifacts-#{System.unique_integer([:positive])}"
      )

    {:ok, local} = Artifacts.open(root)
    {:ok, memory} = InMemory.open()

    [{Artifacts, local}, {InMemory, memory}]
  end

  test "every artifact store implementation satisfies one conformance suite" do
    for {module, handle} <- implementations() do
      bytes = "conformance bytes for #{inspect(module)}"

      assert {:ok, reference} = module.put(handle, bytes, %{"media_type" => "text/plain"})
      assert ArtifactStore.valid_reference?(reference)
      assert {:ok, ^bytes} = module.fetch(handle, reference)
      assert {:ok, ^reference} = module.stat(handle, reference)

      # Idempotent by content: the same bytes yield the same reference.
      assert {:ok, ^reference} = module.put(handle, bytes, %{"media_type" => "text/plain"})

      # An unknown role is refused rather than stored under a name nothing
      # understands.
      assert {:error, {:unknown_artifact_role, "invented"}} =
               module.put(handle, bytes, %{"role" => "invented"})
    end
  end

  test "tool output beyond its declared bound spills to an artifact instead of truncating silently" do
    [{module, handle} | _rest] = implementations()

    full = String.duplicate("x", 10_000)
    {:ok, reference} = module.put(handle, full, %{"media_type" => "text/plain"})

    # The whole of it is kept, not the part that fitted.
    assert reference.size == 10_000
    assert {:ok, ^full} = module.fetch(handle, reference)

    # And the model-facing result says what happened rather than simply ending.
    kept = binary_part(full, 0, 200)
    notice = ArtifactStore.truncation_notice(kept, byte_size(full), reference)

    assert notice =~ "truncated"
    assert notice =~ "200 of 10000 bytes"
    assert notice =~ reference.locator
    assert String.starts_with?(notice, kept)
  end

  test "the durable artifact event carries digest media type size role and an opaque reference" do
    [{module, handle} | _rest] = implementations()

    {:ok, reference} = module.put(handle, "payload", %{"media_type" => "application/json"})

    assert %{digest: digest, media_type: "application/json", size: 7, role: "tool_output"} =
             reference

    assert String.match?(digest, ~r/^[0-9a-f]{64}$/)
    assert is_binary(reference.locator) and reference.locator != ""

    # Exactly these five members, and nothing that could carry a path or a pid
    # across a durable boundary.
    assert Enum.sort(Map.keys(reference)) == [:digest, :locator, :media_type, :role, :size]
    assert is_binary(LoopexProtocol.Canonical.encode(reference))

    # A malformed reference is refused at the boundary rather than committed and
    # discovered on a later read.
    refute ArtifactStore.valid_reference?(Map.delete(reference, :digest))
    refute ArtifactStore.valid_reference?(%{reference | digest: "not-a-digest"})
    refute ArtifactStore.valid_reference?(%{reference | role: "invented"})
  end

  test "the model facing result stays under its bound and names what was truncated" do
    for {module, handle} <- implementations() do
      full = String.duplicate("y", 50_000)
      {:ok, reference} = module.put(handle, full, %{})
      kept = binary_part(full, 0, 1_024)
      notice = ArtifactStore.truncation_notice(kept, byte_size(full), reference)

      # The bounded result is the kept portion plus a short notice, so it stays
      # close to the bound rather than reintroducing the size it was avoiding.
      assert byte_size(notice) < 1_024 + 400

      # It names the total and the retrieval locator, so an operator can get the
      # rest and a model knows it is not seeing everything. The second adapter's
      # locator contains no digest, proving this is the opaque retrieval value.
      assert notice =~ "50000 bytes"
      assert notice =~ reference.locator
      if module == InMemory, do: refute(notice =~ reference.digest)
    end
  end

  test "the operator retrieves a spilled artifact by its opaque reference through the public facade" do
    for {module, handle} <- implementations() do
      {:ok, reference} = module.put(handle, "the whole output", %{})

      # The locator is the only thing the public facade receives. The in-memory
      # fixture deliberately issues a locator that differs from its digest, so
      # this fails if core reconstructs adapter identity by equating the two.
      if module == InMemory, do: refute(reference.locator == reference.digest)

      assert {:ok, "the whole output"} =
               ArtifactStore.retrieve(%{module: module, handle: handle}, reference.locator)

      if module == InMemory do
        probe = InMemory.last_stat_probe(handle)
        assert probe.locator == reference.locator
        refute probe.digest == probe.locator
      end
    end
  end

  test "stat and fetch refuse same size and different size artifact corruption" do
    for replacement <- ["damage!", "short"] do
      for {module, handle} <- implementations() do
        {:ok, reference} = module.put(handle, "payload", %{})
        corrupt(module, handle, reference, replacement)

        assert {:error, :artifact_integrity_failed} = module.stat(handle, reference)
        assert {:error, :artifact_integrity_failed} = module.fetch(handle, reference)
      end
    end
  end

  test "artifact publication syncs file bytes before its durable directory entry" do
    [{Artifacts, handle} | _rest] = implementations()

    events = trace_publication(fn -> Artifacts.put(handle, "durable payload", %{}) end)

    first_sync = Enum.find_index(events, &(&1 == :sync))
    rename = Enum.find_index(events, &(&1 == :rename))

    last_sync =
      events
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn
        {:sync, index} -> index
        {_event, _index} -> nil
      end)

    assert is_integer(first_sync)
    assert is_integer(rename)
    assert is_integer(last_sync)
    assert Enum.count(events, &(&1 == :sync)) == 3
    assert first_sync < rename
    assert rename < last_sync

    assert events
           |> Enum.chunk_every(4, 1, :discard)
           |> Enum.member?([:write, :sync, :rename, :sync])

    repeated = trace_publication(fn -> Artifacts.put(handle, "durable payload", %{}) end)

    assert Enum.count(repeated, &(&1 == :sync)) == 3
    refute :write in repeated
    refute :rename in repeated
  end

  test "unsafe opaque locators are refused before an adapter can resolve them" do
    [{_local_module, _local_handle}, {InMemory, memory}] = implementations()

    unsafe = [
      "",
      "line\nbreak",
      "terminal\e[31m",
      "right-to-left\u202Etxt",
      <<255>>,
      String.duplicate("x", 1_025)
    ]

    for locator <- unsafe do
      reference = %{
        digest: String.duplicate("a", 64),
        media_type: "text/plain",
        size: 3,
        role: "tool_output",
        locator: locator
      }

      refute ArtifactStore.valid_reference?(reference)

      assert {:error, :invalid_artifact_reference} =
               ArtifactStore.retrieve(%{module: InMemory, handle: memory}, locator)
    end
  end

  test "a locator the store never issued reports unavailable rather than raising" do
    # Concept: a locator is opaque to the port, so a store must answer for one it
    # does not recognise rather than assume its own shape.
    #
    # Technical depth: the port admits any non-empty locator, and this store
    # derives a path by slicing the first two characters of it. A durable
    # reference carrying a valid digest and a one-character locator therefore
    # passed validation and then raised out of `binary_part/3` during retrieval
    # -- a crash in recovery where a typed answer was owed.
    for {module, handle} <- implementations() do
      foreign = %{
        digest: String.duplicate("a", 64),
        media_type: "text/plain",
        size: 3,
        role: "tool_output",
        locator: "x"
      }

      assert {:error, :unknown_artifact} = module.fetch(handle, foreign)
      assert {:error, :unknown_artifact} = module.stat(handle, foreign)

      # An empty locator was already refused by the port; a long one that is not
      # this store's shape is refused for the same reason.
      assert {:error, :unknown_artifact} =
               module.fetch(handle, %{foreign | locator: String.duplicate("z", 64)})
    end
  end

  test "an artifact round trips byte exactly and a missing artifact reports unavailable" do
    for {module, handle} <- implementations() do
      # Bytes that a text-oriented path would mangle: nulls, high bytes, and a
      # trailing newline that a naive line reader would drop.
      awkward = <<0, 255, 128, 10>> <> "tail\n"
      {:ok, reference} = module.put(handle, awkward, %{})
      assert {:ok, ^awkward} = module.fetch(handle, reference)
      assert byte_size(awkward) == reference.size

      # A reference to something that was never stored says so, rather than
      # returning an empty success a caller would read as an empty artifact.
      absent = %{
        reference
        | digest: String.duplicate("0", 64),
          locator: String.duplicate("0", 64)
      }

      assert {:error, :unknown_artifact} = module.fetch(handle, absent)
      assert {:error, :unknown_artifact} = module.stat(handle, absent)

      # An empty artifact is a different fact and round trips as itself.
      {:ok, empty_reference} = module.put(handle, "", %{})
      assert {:ok, ""} = module.fetch(handle, empty_reference)
      assert empty_reference.size == 0
    end
  end

  defp corrupt(Artifacts, %{root: root}, reference, bytes) do
    path = Path.join([root, binary_part(reference.locator, 0, 2), reference.locator])
    File.write!(path, bytes)
  end

  defp corrupt(InMemory, pid, reference, bytes) do
    InMemory.corrupt(pid, reference.locator, bytes)
  end

  defp trace_publication(fun) do
    test = self()

    tracer =
      spawn_link(fn ->
        trace_forwarder(test)
      end)

    patterns = [{:file, :write, 2}, {:file, :sync, 1}, {:file, :rename, 2}]

    Enum.each(patterns, fn pattern ->
      1 = :erlang.trace_pattern(pattern, true, [])
    end)

    1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      assert {:ok, _reference} = fun.()
    after
      1 = :erlang.trace(self(), false, [:call])
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, []))
    end

    delivery = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _tracee, ^delivery} -> :ok
    after
      1_000 -> flunk("file publication trace was not delivered")
    end

    send(tracer, {:finish, self()})

    receive do
      {:publication_trace, events} -> events
    after
      1_000 -> flunk("file publication trace did not finish")
    end
  end

  defp trace_forwarder(test), do: trace_forwarder(test, [])

  defp trace_forwarder(test, events) do
    receive do
      {:trace, ^test, :call, {:file, :sync, [_io_device]}} ->
        trace_forwarder(test, [:sync | events])

      {:trace, ^test, :call, {:file, :write, [_io_device, _bytes]}} ->
        trace_forwarder(test, [:write | events])

      {:trace, ^test, :call, {:file, :rename, [_source, _destination]}} ->
        trace_forwarder(test, [:rename | events])

      {:finish, ^test} ->
        send(test, {:publication_trace, Enum.reverse(events)})
    end
  end
end
