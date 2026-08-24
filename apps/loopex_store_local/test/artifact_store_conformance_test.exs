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
        :ok = Agent.update(pid, &Map.put(&1, digest, bytes))

        {:ok,
         %{
           digest: digest,
           media_type: Map.get(metadata, "media_type", "application/octet-stream"),
           size: byte_size(bytes),
           role: role,
           locator: digest
         }}
      else
        {:error, {:unknown_artifact_role, role}}
      end
    end

    @impl Loopex.ArtifactStore
    def fetch(pid, reference) do
      case Agent.get(pid, &Map.fetch(&1, reference.locator)) do
        {:ok, bytes} ->
          if Canonical.digest_bytes(bytes) == reference.digest,
            do: {:ok, bytes},
            else: {:error, :artifact_integrity_failed}

        :error ->
          {:error, :unknown_artifact}
      end
    end

    @impl Loopex.ArtifactStore
    def stat(pid, reference) do
      case fetch(pid, reference) do
        {:ok, _bytes} -> {:ok, reference}
        {:error, reason} -> {:error, reason}
      end
    end
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
    assert notice =~ reference.digest
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
    [{module, handle} | _rest] = implementations()

    full = String.duplicate("y", 50_000)
    {:ok, reference} = module.put(handle, full, %{})
    kept = binary_part(full, 0, 1_024)
    notice = ArtifactStore.truncation_notice(kept, byte_size(full), reference)

    # The bounded result is the kept portion plus a short notice, so it stays
    # close to the bound rather than reintroducing the size it was avoiding.
    assert byte_size(notice) < 1_024 + 400

    # It names the total and the retrieval reference, so an operator can get the
    # rest and a model knows it is not seeing everything.
    assert notice =~ "50000 bytes"
    assert notice =~ reference.digest
  end

  test "the operator retrieves a spilled artifact by its opaque reference through the public facade" do
    [{module, handle} | _rest] = implementations()

    {:ok, reference} = module.put(handle, "the whole output", %{})

    # The locator is the only thing a caller needs, and core never takes it
    # apart: a reference rebuilt from its retained members fetches the same
    # bytes.
    rebuilt = %{
      digest: reference.digest,
      media_type: reference.media_type,
      size: reference.size,
      role: reference.role,
      locator: reference.locator
    }

    assert {:ok, "the whole output"} = module.fetch(handle, rebuilt)
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
end
