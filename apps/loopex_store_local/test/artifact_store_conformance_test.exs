defmodule Loopex.Store.Local.ArtifactStoreConformanceTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.ArtifactStore
  alias Loopex.Store.Local.Artifacts
  alias LoopexProtocol.Canonical

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
      {:ok, pid} =
        Agent.start_link(fn ->
          %{objects: %{}, uses: %{}, last_stat_locator: nil, last_fetch_object: nil}
        end)

      {:ok, pid}
    end

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
      if role in ArtifactStore.roles() and is_map(metadata) do
        digest = Canonical.digest_bytes(bytes)
        locator = "memory:" <> Canonical.digest_bytes("locator:" <> digest)

        object = %{
          digest: digest,
          size: byte_size(bytes),
          locator: locator
        }

        artifact_use = %{
          canonicalization_version: Canonical.version(),
          object_digest: object.digest,
          object_size: object.size,
          object_locator: object.locator,
          media_type: media_type,
          role: role,
          metadata: metadata
        }

        use_bytes = Canonical.encode(["artifact-use-v2", artifact_use])
        use_digest = Canonical.digest_bytes(use_bytes)
        use_locator = "use:" <> use_digest

        reference =
          Map.merge(object, %{
            media_type: media_type,
            role: role,
            use_canonicalization_version: Canonical.version(),
            use_digest: use_digest,
            use_locator: use_locator
          })

        if byte_size(use_bytes) <= 131_072 do
          Agent.get_and_update(pid, fn state ->
            with :ok <- converges(Map.get(state.objects, locator), {object, bytes}),
                 :ok <- converges(Map.get(state.uses, use_locator), {artifact_use, use_bytes}) do
              next = %{
                state
                | objects: Map.put(state.objects, locator, {object, bytes}),
                  uses: Map.put(state.uses, use_locator, {artifact_use, use_bytes})
              }

              {{:ok, reference}, next}
            else
              {:error, reason} -> {{:error, reason}, state}
            end
          end)
        else
          Agent.get_and_update(pid, fn state ->
            case converges(Map.get(state.objects, locator), {object, bytes}) do
              :ok ->
                {{:error, :artifact_use_too_large},
                 %{state | objects: Map.put(state.objects, locator, {object, bytes})}}

              {:error, reason} ->
                {{:error, reason}, state}
            end
          end)
        end
      else
        {:error, :invalid_artifact_metadata}
      end
    end

    def put(_pid, _bytes, _metadata), do: {:error, :adapter_received_unnormalized_use}

    def fetch(pid, object) when is_map(object) do
      case Agent.get_and_update(pid, fn state ->
             {Map.fetch(state.objects, object.locator), %{state | last_fetch_object: object}}
           end) do
        {:ok, {_stored_object, bytes}} ->
          if Enum.sort(Map.keys(object)) == [:digest, :locator, :size] and
               Canonical.digest_bytes(bytes) == object.digest and byte_size(bytes) == object.size,
             do: {:ok, bytes},
             else: {:error, :artifact_integrity_failed}

        :error ->
          {:error, :unknown_artifact}
      end
    end

    def stat(pid, locator) when is_binary(locator) do
      result =
        Agent.get_and_update(pid, fn state ->
          {Map.fetch(state.objects, locator), %{state | last_stat_locator: locator}}
        end)

      case result do
        {:ok, {stored_object, bytes}} ->
          if Canonical.digest_bytes(bytes) == stored_object.digest and
               byte_size(bytes) == stored_object.size,
             do: {:ok, stored_object},
             else: {:error, :artifact_integrity_failed}

        :error ->
          {:error, :unknown_artifact}
      end
    end

    def stat(_pid, _locator), do: {:error, :unknown_artifact}

    def describe(pid, use_locator) when is_binary(use_locator) do
      case Agent.get(pid, &Map.fetch(&1.uses, use_locator)) do
        {:ok, {artifact_use, bytes}} ->
          expected = Canonical.encode(["artifact-use-v2", artifact_use])

          if bytes == expected,
            do: {:ok, artifact_use},
            else: {:error, :artifact_integrity_failed}

        :error ->
          {:error, :unknown_artifact_use}
      end
    end

    def describe(_pid, _use_locator), do: {:error, :unknown_artifact_use}

    def corrupt(pid, locator, bytes) do
      Agent.update(pid, fn state ->
        update_in(state, [:objects, locator], fn {object, _stored} -> {object, bytes} end)
      end)
    end

    def corrupt_use(pid, use_locator, bytes) do
      Agent.update(pid, fn state ->
        update_in(state, [:uses, use_locator], fn {artifact_use, _stored} ->
          {artifact_use, bytes}
        end)
      end)
    end

    def delete_use(pid, use_locator) do
      Agent.update(pid, fn state -> %{state | uses: Map.delete(state.uses, use_locator)} end)
    end

    def use_bytes(pid, use_locator) do
      Agent.get(pid, fn state ->
        case Map.fetch(state.uses, use_locator) do
          {:ok, {_artifact_use, bytes}} -> {:ok, bytes}
          :error -> {:error, :unknown_artifact_use}
        end
      end)
    end

    def last_stat_locator(pid), do: Agent.get(pid, & &1.last_stat_locator)
    def last_fetch_object(pid), do: Agent.get(pid, & &1.last_fetch_object)

    def counts(pid),
      do: Agent.get(pid, &%{objects: map_size(&1.objects), uses: map_size(&1.uses)})

    defp converges(nil, _candidate), do: :ok
    defp converges(candidate, candidate), do: :ok
    defp converges(_existing, _candidate), do: {:error, :artifact_unavailable}
  end

  defmodule Dishonest do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start(mode), do: Agent.start_link(fn -> %{mode: mode, use: nil, calls: []} end)

    def calls(pid), do: Agent.get(pid, &Enum.reverse(&1.calls))

    def put(pid, bytes, %{media_type: media_type, role: role, metadata: metadata}) do
      mode = Agent.get(pid, & &1.mode)
      real_digest = Canonical.digest_bytes(bytes)

      truthful_object = %{
        digest: real_digest,
        size: byte_size(bytes),
        locator: "dishonest:object"
      }

      object = %{
        digest: if(mode == :object_digest, do: String.duplicate("f", 64), else: real_digest),
        size: if(mode == :object_size, do: byte_size(bytes) + 1, else: byte_size(bytes)),
        locator:
          if(mode == :object_locator,
            do: "dishonest:substituted-object",
            else: "dishonest:object"
          )
      }

      truthful_use = %{
        canonicalization_version: Canonical.version(),
        object_digest: truthful_object.digest,
        object_size: truthful_object.size,
        object_locator: truthful_object.locator,
        media_type: media_type,
        role: role,
        metadata: metadata
      }

      use_digest = Canonical.digest(["artifact-use-v2", truthful_use])

      reported_use_digest =
        if mode == :use_digest, do: String.duplicate("e", 64), else: use_digest

      reference =
        Map.merge(object, %{
          media_type: media_type,
          role: role,
          use_canonicalization_version:
            if(mode == :reference_version,
              do: "loopex.canonical.future",
              else: Canonical.version()
            ),
          use_digest: reported_use_digest,
          use_locator:
            if(
              mode == :use_locator,
              do: "use:" <> metadata["session_id"],
              else: "use:" <> reported_use_digest
            )
        })

      described_use = dishonest_use(truthful_use, mode)

      :ok = Agent.update(pid, &%{&1 | use: described_use, calls: [:put | &1.calls]})
      {:ok, reference}
    end

    def put(_pid, _bytes, _metadata), do: {:error, :adapter_received_unnormalized_use}

    def fetch(_pid, object), do: {:ok, :binary.copy("x", object.size)}

    def stat(_pid, _locator),
      do: {:ok, %{digest: String.duplicate("0", 64), size: 0, locator: "other"}}

    def describe(pid, use_locator) do
      Agent.get_and_update(pid, fn state ->
        answer =
          cond do
            state.mode == :missing_describe -> {:error, :unknown_artifact_use}
            is_nil(state.use) -> {:error, :unknown_artifact_use}
            true -> {:ok, state.use}
          end

        {answer, %{state | calls: [{:describe, use_locator} | state.calls]}}
      end)
    end

    defp dishonest_use(use, :described_version),
      do: %{use | canonicalization_version: "loopex.canonical.future"}

    defp dishonest_use(use, :described_object_digest),
      do: %{use | object_digest: String.duplicate("e", 64)}

    defp dishonest_use(use, :described_object_size), do: %{use | object_size: use.object_size + 1}

    defp dishonest_use(use, :described_object_locator),
      do: %{use | object_locator: "dishonest:other-object"}

    defp dishonest_use(use, :described_media_type),
      do: %{use | media_type: "application/dishonest"}

    defp dishonest_use(use, :described_role), do: %{use | role: "invented"}

    defp dishonest_use(use, {:metadata, key}) do
      replacement = if key == "attempt", do: use.metadata[key] + 1, else: "substituted-#{key}"
      put_in(use, [:metadata, key], replacement)
    end

    defp dishonest_use(use, _mode), do: use
  end

  defmodule AdmissionProbe do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    def put(owner, _bytes, _metadata) do
      send(owner, {:adapter_called, :put})
      {:error, :adapter_called}
    end

    def fetch(owner, _object) do
      send(owner, {:adapter_called, :fetch})
      {:error, :adapter_called}
    end

    def stat(owner, _locator) do
      send(owner, {:adapter_called, :stat})
      {:error, :adapter_called}
    end

    def describe(owner, _use_locator) do
      send(owner, {:adapter_called, :describe})
      {:error, :adapter_called}
    end
  end

  defmodule RetrieveProbe do
    @moduledoc false
    @behaviour Loopex.ArtifactStore

    alias LoopexProtocol.Canonical

    def start(mode, bytes) do
      Agent.start_link(fn -> %{mode: mode, bytes: bytes, calls: []} end)
    end

    def calls(pid), do: Agent.get(pid, &Enum.reverse(&1.calls))

    def put(_pid, _bytes, _metadata), do: {:error, :unsupported}

    def stat(pid, locator) when is_binary(locator) do
      %{mode: mode, bytes: bytes} = Agent.get(pid, & &1)
      record(pid, {:stat, locator})

      {:ok,
       %{
         digest: Canonical.digest_bytes(bytes),
         size: byte_size(bytes),
         locator: if(mode == :substituted_stat_locator, do: "probe:other", else: locator)
       }}
    end

    def stat(pid, other) do
      record(pid, {:stat, other})
      {:error, :adapter_received_non_locator}
    end

    def fetch(pid, object) do
      %{mode: mode, bytes: bytes} = Agent.get(pid, & &1)
      record(pid, {:fetch, object})

      if mode == :corrupt_fetch,
        do: {:ok, bytes <> "-corrupt"},
        else: {:ok, bytes}
    end

    def describe(_pid, _use_locator), do: {:error, :unsupported}

    defp record(pid, call), do: Agent.update(pid, &%{&1 | calls: [call | &1.calls]})
  end

  defmodule ArtifactFaultProbe do
    @moduledoc false

    # Concept: a publication fault is held at the exact edge where success would
    # otherwise become observable.
    #
    # Technical depth: this follows the Store Local fault-probe shape without
    # making a filesystem race part of the evidence. The local artifact handle's
    # future private `:fault_probe` member is the seam: the adapter sends the
    # semantic publication phase and waits for `:continue` or `:return_error`.
    # Holding the target lets the case prove that no reference returned before
    # the staging write, sync, rename, comparison, or parent sync completed.
    def start(owner, target) do
      spawn_link(fn -> loop(owner, target) end)
    end

    def release(probe), do: send(probe, :return_error)
    def stop(probe), do: send(probe, :stop)

    defp loop(owner, target) do
      receive do
        {:loopex_artifact_fault_point, caller, reference, pair} when is_pid(caller) ->
          if pair == target do
            send(owner, {:artifact_fault_reached, self(), pair})

            receive do
              :return_error ->
                send(caller, {:loopex_artifact_fault_action, reference, :return_error})

              :stop ->
                :ok
            end
          else
            send(caller, {:loopex_artifact_fault_action, reference, :continue})
            loop(owner, target)
          end

        :stop ->
          :ok
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

  defp caller_metadata(overrides \\ %{}) do
    Map.merge(
      %{
        "media_type" => "application/octet-stream",
        "role" => "tool_output",
        "session_id" => "session-1",
        "run_id" => "run-1",
        "operation_id" => "operation-1",
        "attempt" => 1,
        "tool_call_id" => "call-1"
      },
      overrides
    )
  end

  defp adapter_metadata(metadata) do
    %{
      media_type: Map.fetch!(metadata, "media_type"),
      role: Map.fetch!(metadata, "role"),
      metadata: Map.drop(metadata, ["media_type", "role"])
    }
  end

  defp expected_local_artifact(bytes, metadata) do
    digest = Canonical.digest_bytes(bytes)
    object = %{digest: digest, size: byte_size(bytes), locator: digest}

    artifact_use = %{
      canonicalization_version: Canonical.version(),
      object_digest: object.digest,
      object_size: object.size,
      object_locator: object.locator,
      media_type: Map.fetch!(metadata, "media_type"),
      role: Map.fetch!(metadata, "role"),
      metadata: Map.drop(metadata, ["media_type", "role"])
    }

    use_bytes = Canonical.encode(["artifact-use-v2", artifact_use])
    use_digest = Canonical.digest_bytes(use_bytes)

    reference =
      Map.merge(object, %{
        media_type: artifact_use.media_type,
        role: artifact_use.role,
        use_canonicalization_version: artifact_use.canonicalization_version,
        use_digest: use_digest,
        use_locator: "use:" <> use_digest
      })

    {reference, artifact_use, use_bytes}
  end

  defp put_local(handle, bytes, metadata) do
    Artifacts.put(handle, bytes, adapter_metadata(metadata))
  end

  defp describe_local(handle, use_locator) do
    if function_exported?(Artifacts, :describe, 2) do
      apply(Artifacts, :describe, [handle, use_locator])
    else
      {:error, :artifact_use_contract_missing}
    end
  end

  defp open_local(label) do
    root =
      Path.join(
        System.fetch_env!("LOOPEX_HOME"),
        "#{label}-#{System.unique_integer([:positive])}"
      )

    {:ok, handle} = Artifacts.open(root)
    {root, handle}
  end

  defp store(module, handle), do: %{module: module, handle: handle}

  defp put_artifact(module, handle, bytes, metadata \\ caller_metadata()) do
    invoke_core(:put, [store(module, handle), bytes, metadata])
  end

  defp fetch_artifact(module, handle, reference) do
    invoke_core(:fetch, [store(module, handle), reference])
  end

  defp stat_artifact(module, handle, locator) do
    invoke_core(:stat, [store(module, handle), locator])
  end

  defp describe_artifact(module, handle, reference) do
    invoke_core(:describe, [store(module, handle), reference])
  end

  defp retrieve_artifact(module, handle, locator) do
    invoke_core(:retrieve, [store(module, handle), locator])
  end

  defp invoke_core(name, arguments) do
    if function_exported?(ArtifactStore, name, length(arguments)) do
      apply(ArtifactStore, name, arguments)
    else
      {:error, {:artifact_object_use_contract_missing, name, length(arguments)}}
    end
  end

  defp object_of(reference), do: Map.take(reference, [:digest, :size, :locator])

  defp expected_use(reference, metadata) do
    %{
      canonicalization_version: Canonical.version(),
      object_digest: reference.digest,
      object_size: reference.size,
      object_locator: reference.locator,
      media_type: Map.fetch!(metadata, "media_type"),
      role: Map.fetch!(metadata, "role"),
      metadata: Map.drop(metadata, ["media_type", "role"])
    }
  end

  defp metadata_for_exact_use_size(reference, target) do
    seed = caller_metadata(%{"session_id" => "s"})
    seed_size = byte_size(Canonical.encode(["artifact-use-v2", expected_use(reference, seed)]))
    identifier_size = target - seed_size + 1
    metadata = caller_metadata(%{"session_id" => :binary.copy("s", identifier_size)})

    computed = byte_size(Canonical.encode(["artifact-use-v2", expected_use(reference, metadata)]))

    if computed != target,
      do: raise("could not construct an exact #{target}-byte artifact use; got #{computed}")

    metadata
  end

  test "one object supports two exact immutable uses in every artifact adapter" do
    for {module, handle} <- implementations() do
      bytes = "conformance bytes for #{inspect(module)}"
      first_use = caller_metadata(%{"media_type" => "text/plain"})
      second_use = caller_metadata(%{"media_type" => "text/plain", "tool_call_id" => "call-2"})

      assert {:ok, reference} = put_artifact(module, handle, bytes, first_use)
      assert ArtifactStore.valid_reference?(reference)
      assert {:ok, ^bytes} = fetch_artifact(module, handle, reference)
      assert {:ok, object} = stat_artifact(module, handle, reference.locator)
      assert object == object_of(reference)
      assert {:ok, use} = describe_artifact(module, handle, reference)
      assert use == expected_use(reference, first_use)
      assert stored_identity_counts(module, handle, bytes, [use]) == %{objects: 1, uses: 1}

      # Idempotent by object and use: the same bytes and provenance yield the
      # same compact reference, while a second provenance keeps the object and
      # receives a distinct immutable use.
      assert {:ok, ^reference} = put_artifact(module, handle, bytes, first_use)
      assert stored_identity_counts(module, handle, bytes, [use]) == %{objects: 1, uses: 1}
      assert {:ok, second_reference} = put_artifact(module, handle, bytes, second_use)
      assert object_of(second_reference) == object_of(reference)
      refute second_reference.use_digest == reference.use_digest
      refute second_reference.use_locator == reference.use_locator
      assert {:ok, second_use_record} = describe_artifact(module, handle, second_reference)
      assert second_use_record == expected_use(second_reference, second_use)
      assert {:ok, ^use} = describe_artifact(module, handle, reference)
      assert {:ok, ^bytes} = fetch_artifact(module, handle, reference)
      assert {:ok, ^bytes} = fetch_artifact(module, handle, second_reference)

      assert stored_identity_counts(module, handle, bytes, [use, second_use_record]) == %{
               objects: 1,
               uses: 2
             }

      assert {:ok, ^second_reference} = put_artifact(module, handle, bytes, second_use)

      assert stored_identity_counts(module, handle, bytes, [use, second_use_record]) == %{
               objects: 1,
               uses: 2
             }

      # An unknown role is refused rather than stored under a name nothing
      # understands.
      assert {:error, {:unknown_artifact_role, "invented"}} =
               put_artifact(module, handle, bytes, caller_metadata(%{"role" => "invented"}))
    end
  end

  test "retaining a large value keeps every byte while its bounded notice names the artifact" do
    [{module, handle} | _rest] = implementations()

    full = String.duplicate("x", 10_000)

    {:ok, reference} =
      put_artifact(module, handle, full, caller_metadata(%{"media_type" => "text/plain"}))

    # The whole of it is kept, not the part that fitted.
    assert reference.size == 10_000
    assert {:ok, ^full} = fetch_artifact(module, handle, reference)

    # And the model-facing result says what happened rather than simply ending.
    kept = binary_part(full, 0, 200)
    notice = ArtifactStore.truncation_notice(kept, byte_size(full), reference)

    assert notice =~ "truncated"
    assert notice =~ "200 of 10000 bytes"
    assert notice =~ reference.locator
    assert String.starts_with?(notice, kept)
  end

  test "the compact artifact reference carries object and use identity without private provenance" do
    [{module, handle} | _rest] = implementations()

    {:ok, reference} =
      put_artifact(
        module,
        handle,
        "payload",
        caller_metadata(%{"media_type" => "application/json"})
      )

    assert %{digest: digest, media_type: "application/json", size: 7, role: "tool_output"} =
             reference

    assert String.match?(digest, ~r/^[0-9a-f]{64}$/)
    assert is_binary(reference.locator) and reference.locator != ""

    # Exactly these eight compact members, and no private use label.
    assert Enum.sort(Map.keys(reference)) == [
             :digest,
             :locator,
             :media_type,
             :role,
             :size,
             :use_canonicalization_version,
             :use_digest,
             :use_locator
           ]

    assert reference.use_canonicalization_version == Canonical.version()
    assert reference.use_locator == "use:" <> reference.use_digest

    for private <- ["session-1", "run-1", "operation-1", "call-1"] do
      refute :erlang.term_to_binary(reference) =~ private
    end

    assert is_binary(LoopexProtocol.Canonical.encode(reference))

    # A malformed reference is refused at the boundary rather than committed and
    # discovered on a later read.
    refute ArtifactStore.valid_reference?(Map.delete(reference, :digest))
    refute ArtifactStore.valid_reference?(%{reference | digest: "not-a-digest"})
    refute ArtifactStore.valid_reference?(%{reference | role: "invented"})
  end

  test "artifact reference fields are bounded and invalid metadata is refused before success" do
    valid = %{
      digest: String.duplicate("a", 64),
      media_type: "text/plain",
      size: 0,
      role: "tool_output",
      locator: "opaque",
      use_canonicalization_version: Canonical.version(),
      use_digest: String.duplicate("b", 64),
      use_locator: "use:" <> String.duplicate("b", 64)
    }

    assert ArtifactStore.valid_reference?(valid)

    assert ArtifactStore.valid_reference?(%{
             valid
             | media_type: String.duplicate("m", 255),
               size: 18_446_744_073_709_551_615,
               locator: String.duplicate("l", 1_024)
           })

    refute ArtifactStore.valid_reference?(%{valid | digest: String.duplicate("a", 65)})
    refute ArtifactStore.valid_reference?(%{valid | digest: :binary.copy(<<255>>, 64)})
    refute ArtifactStore.valid_reference?(%{valid | media_type: String.duplicate("m", 256)})
    refute ArtifactStore.valid_reference?(%{valid | media_type: "text/plain\nunsafe"})
    refute ArtifactStore.valid_reference?(%{valid | media_type: <<255>>})
    refute ArtifactStore.valid_reference?(%{valid | size: -1})
    refute ArtifactStore.valid_reference?(%{valid | size: 18_446_744_073_709_551_616})
    refute ArtifactStore.valid_reference?(%{valid | locator: String.duplicate("l", 1_025)})
    refute ArtifactStore.valid_reference?(%{valid | use_digest: String.duplicate("b", 63)})
    refute ArtifactStore.valid_reference?(%{valid | use_locator: "use:chosen-by-adapter"})

    refute ArtifactStore.valid_reference?(%{
             valid
             | use_canonicalization_version: "loopex.canonical.future"
           })

    invalid_media_types = ["", String.duplicate("m", 256), "text/plain\nunsafe", :text]

    for {module, handle} <- implementations(), media_type <- invalid_media_types do
      assert {:error, :invalid_artifact_metadata} =
               put_artifact(
                 module,
                 handle,
                 "metadata boundary",
                 caller_metadata(%{"media_type" => media_type})
               )
    end
  end

  test "artifact use metadata is closed allocation bounded and preserves every opaque identifier" do
    for {module, handle} <- implementations() do
      metadata =
        caller_metadata(%{
          "session_id" => <<0, 255, 1>>,
          "run_id" => <<2, 254, 3>>,
          "operation_id" => <<4, 253, 5>>,
          "attempt" => 7,
          "tool_call_id" => <<6, 252, 7>>
        })

      assert {:ok, reference} = put_artifact(module, handle, "opaque use", metadata)
      assert {:ok, use} = describe_artifact(module, handle, reference)
      assert use == expected_use(reference, metadata)

      compact_bytes = Canonical.encode(reference)

      for {_name, private} <- Map.drop(metadata, ["media_type", "role", "attempt"]) do
        refute compact_bytes =~ private
      end

      boundary_bytes = "exact boundary for #{inspect(module)}"

      assert {:ok, seed_reference} =
               put_artifact(
                 module,
                 handle,
                 boundary_bytes,
                 caller_metadata(%{"session_id" => "s"})
               )

      exact_metadata = metadata_for_exact_use_size(seed_reference, 131_072)
      assert {:ok, exact_reference} = put_artifact(module, handle, boundary_bytes, exact_metadata)
      assert object_of(exact_reference) == object_of(seed_reference)
      assert {:ok, exact_use} = describe_artifact(module, handle, exact_reference)
      assert byte_size(Canonical.encode(["artifact-use-v2", exact_use])) == 131_072

      over_metadata = metadata_for_exact_use_size(seed_reference, 131_073)

      assert {:error, :artifact_use_too_large} =
               put_artifact(module, handle, boundary_bytes, over_metadata)

      assert {:ok, ^exact_use} = describe_artifact(module, handle, exact_reference)
    end
  end

  test "artifact use allocation guard rejects every oversized scalar before adapter access" do
    required = ["session_id", "run_id", "operation_id", "attempt", "tool_call_id"]
    opaque_identifiers = ["session_id", "run_id", "operation_id", "tool_call_id"]

    missing = Enum.map(required, &Map.delete(caller_metadata(), &1))
    empty = Enum.map(opaque_identifiers, &Map.put(caller_metadata(), &1, ""))

    invalid =
      missing ++
        empty ++
        [
          caller_metadata(%{"attempt" => 0}),
          caller_metadata(%{"attempt" => -1}),
          caller_metadata(%{"tool_call_id" => ["not", "opaque"]}),
          Map.put(caller_metadata(), "note", "configured-provider-credential"),
          Map.put(caller_metadata(), "credential", "configured-provider-credential")
        ]

    for candidate <- invalid do
      assert {:error, _reason} =
               put_artifact(AdmissionProbe, self(), "must not be published", candidate)

      refute_receive {:adapter_called, _callback}, 20
    end

    for identifier <- ["session_id", "run_id", "operation_id", "tool_call_id"] do
      huge_identifier = :binary.copy("h", 131_073)

      assert {:error, :artifact_use_too_large} =
               put_artifact(
                 AdmissionProbe,
                 self(),
                 "must not be published",
                 caller_metadata(%{identifier => huge_identifier})
               )

      refute_receive {:adapter_called, _callback}, 20
    end

    huge_attempt = :binary.decode_unsigned(:binary.copy(<<255>>, 131_073))

    assert {:error, :artifact_use_too_large} =
             put_artifact(
               AdmissionProbe,
               self(),
               "must not be published",
               caller_metadata(%{"attempt" => huge_attempt})
             )

    refute_receive {:adapter_called, _callback}, 20
  end

  test "Core put proves input object and exact described use before returning success" do
    {:ok, truthful} = Dishonest.start(:truthful)

    assert {:ok, truthful_reference} =
             put_artifact(Dishonest, truthful, "truth belongs to core", caller_metadata())

    assert Dishonest.calls(truthful) == [:put, {:describe, truthful_reference.use_locator}]

    described_modes =
      [
        :use_digest,
        :object_locator,
        :missing_describe,
        :described_version,
        :described_object_digest,
        :described_object_size,
        :described_object_locator,
        :described_media_type,
        :described_role
      ] ++ Enum.map(~w(session_id run_id operation_id attempt tool_call_id), &{:metadata, &1})

    modes =
      [:object_digest, :object_size, :reference_version, :use_locator] ++ described_modes

    for mode <- modes do
      {:ok, dishonest} = Dishonest.start(mode)
      answer = put_artifact(Dishonest, dishonest, "truth belongs to core", caller_metadata())

      refute match?(
               {:error, {:artifact_object_use_contract_missing, _name, _arity}},
               answer
             ),
             "the Core artifact facade is absent rather than refusing the adapter"

      assert {:error, _reason} = answer

      case {mode in described_modes, Dishonest.calls(dishonest)} do
        {true, [:put, {:describe, locator}]} ->
          assert is_binary(locator) and locator != ""

        {false, [:put]} ->
          :ok

        {_expects_describe, calls} ->
          flunk("unexpected Core artifact callback order for #{inspect(mode)}: #{inspect(calls)}")
      end
    end

    {:ok, dishonest_stat} = Dishonest.start(:stat_locator)
    stat_answer = stat_artifact(Dishonest, dishonest_stat, "dishonest:requested")

    refute match?(
             {:error, {:artifact_object_use_contract_missing, _name, _arity}},
             stat_answer
           ),
           "the Core stat facade is absent rather than refusing the adapter"

    assert {:error, _reason} = stat_answer
  end

  test "locator only stat and object fetch never reconstruct or accept use provenance" do
    [{_local, _local_handle}, {InMemory, memory}] = implementations()
    metadata = caller_metadata(%{"tool_call_id" => "private-call"})

    assert {:ok, reference} = put_artifact(InMemory, memory, "separate identities", metadata)
    assert {:ok, object} = stat_artifact(InMemory, memory, reference.locator)

    assert object == object_of(reference)
    assert Enum.sort(Map.keys(object)) == [:digest, :locator, :size]
    assert {:ok, "separate identities"} = fetch_artifact(InMemory, memory, object)
    assert InMemory.last_fetch_object(memory) == object
    assert Enum.sort(Map.keys(InMemory.last_fetch_object(memory))) == [:digest, :locator, :size]

    assert {:ok, use} = describe_artifact(InMemory, memory, reference)
    assert use.metadata["tool_call_id"] == "private-call"

    substituted = %{reference | locator: "memory:another-valid-object-locator"}
    assert ArtifactStore.valid_reference?(substituted)
    assert {:error, _reason} = describe_artifact(InMemory, memory, substituted)
  end

  test "a referenced use remains required when its object bytes are still available" do
    for {module, handle} <- implementations() do
      corrupt_bytes = "retained object with corrupt use for #{inspect(module)}"
      assert {:ok, corrupt_reference} = put_artifact(module, handle, corrupt_bytes)
      assert {:ok, corrupt_use} = describe_artifact(module, handle, corrupt_reference)
      assert {:ok, ^corrupt_bytes} = fetch_artifact(module, handle, corrupt_reference)

      corrupt_use(module, handle, corrupt_reference, corrupt_use, "partial-sidecar")
      assert {:error, _reason} = describe_artifact(module, handle, corrupt_reference)
      assert {:ok, ^corrupt_bytes} = fetch_artifact(module, handle, corrupt_reference)

      missing_bytes = "retained object with missing use for #{inspect(module)}"
      assert {:ok, missing_reference} = put_artifact(module, handle, missing_bytes)
      assert {:ok, missing_use} = describe_artifact(module, handle, missing_reference)
      assert {:ok, ^missing_bytes} = fetch_artifact(module, handle, missing_reference)

      delete_use(module, handle, missing_reference, missing_use)
      assert {:error, _reason} = describe_artifact(module, handle, missing_reference)
      assert {:ok, ^missing_bytes} = fetch_artifact(module, handle, missing_reference)
    end
  end

  test "a referenced object and use remain exact after the local adapter is reopened" do
    root =
      Path.join(
        System.fetch_env!("LOOPEX_HOME"),
        "artifact-reopen-#{System.unique_integer([:positive])}"
      )

    bytes = <<0, 255, 10>> <> "durable across reopen\n"

    metadata =
      caller_metadata(%{
        "session_id" => "reopen-session",
        "run_id" => "reopen-run",
        "operation_id" => "reopen-operation",
        "attempt" => 9,
        "tool_call_id" => "reopen-call"
      })

    {reference, use} =
      (fn ->
         {:ok, original_handle} = Artifacts.open(root)
         assert {:ok, reference} = put_artifact(Artifacts, original_handle, bytes, metadata)
         assert {:ok, use} = describe_artifact(Artifacts, original_handle, reference)
         assert use == expected_use(reference, metadata)
         {reference, use}
       end).()

    # The original handle is intentionally out of scope. The reopened adapter
    # must recover both identities from the same durable root; reconstructing a
    # use only in the original handle cannot satisfy these reads.
    {:ok, reopened_handle} = Artifacts.open(root)

    assert {:ok, object} = stat_artifact(Artifacts, reopened_handle, reference.locator)
    assert object == object_of(reference)
    assert {:ok, ^bytes} = fetch_artifact(Artifacts, reopened_handle, object)
    assert {:ok, ^use} = describe_artifact(Artifacts, reopened_handle, reference)
    assert ArtifactStore.valid_reference?(reference)
  end

  test "artifact use publication is immutable and concurrent identical puts converge" do
    for {module, handle} <- implementations() do
      metadata = caller_metadata(%{"session_id" => "concurrent-session"})
      bytes = "convergent bytes for #{inspect(module)}"

      answers =
        1..12
        |> Task.async_stream(
          fn _index -> put_artifact(module, handle, bytes, metadata) end,
          max_concurrency: 6,
          ordered: false,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, answer} -> answer end)

      assert Enum.all?(answers, &match?({:ok, _reference}, &1))
      references = Enum.map(answers, fn {:ok, reference} -> reference end)
      assert references |> Enum.uniq() |> length() == 1
      [reference | _rest] = references
      assert {:ok, use} = describe_artifact(module, handle, reference)
      assert use == expected_use(reference, metadata)
      assert {:ok, ^bytes} = fetch_artifact(module, handle, reference)

      conflicting = "conflicting pre-existing use bytes"
      use_location = corrupt_use(module, handle, reference, use, conflicting)

      assert {:error, _reason} = put_artifact(module, handle, bytes, metadata)
      assert {:ok, ^conflicting} = read_use_bytes(module, handle, use_location)
    end
  end

  test "failed artifact use staging write file sync publication compare or parent sync returns no reference" do
    phases = [
      {:staging_write, :absent},
      {:file_sync, :absent},
      {:atomic_publication, :absent},
      {:existing_value_compare, :complete},
      {:parent_directory_sync, :complete}
    ]

    for {phase, visible_before_fault} <- phases do
      {_root, handle} = open_local("artifact-use-fault-#{phase}")
      bytes = "object orphan remains valid after #{phase}"
      metadata = caller_metadata(%{"session_id" => "fault-#{phase}"})
      {reference, artifact_use, _use_bytes} = expected_local_artifact(bytes, metadata)

      if phase == :existing_value_compare do
        assert {:ok, ^reference} = put_local(handle, bytes, metadata)
        assert {:ok, ^artifact_use} = describe_local(handle, reference.use_locator)
      end

      pair = {:artifact_use_publication, phase}
      probe = ArtifactFaultProbe.start(self(), pair)
      on_exit(fn -> ArtifactFaultProbe.stop(probe) end)
      faulting_handle = Map.put(handle, :fault_probe, probe)

      task = Task.async(fn -> put_local(faulting_handle, bytes, metadata) end)

      assert_receive {:artifact_fault_reached, ^probe, ^pair},
                     1_000,
                     "the local adapter ignored or returned before #{phase}"

      assert Task.yield(task, 0) == nil,
             "the local adapter returned a reference before #{phase} completed"

      case {visible_before_fault, describe_local(handle, reference.use_locator)} do
        {:absent, {:error, _reason}} ->
          :ok

        {:complete, {:ok, ^artifact_use}} ->
          :ok

        {_expected, other} ->
          flunk("#{phase} exposed a partial or unexpected artifact use: #{inspect(other)}")
      end

      ArtifactFaultProbe.release(probe)
      assert {:error, _reason} = Task.await(task, 5_000)

      # Object publication precedes use publication. A failed use may therefore
      # leave its immutable object orphaned, but it cannot return the reference
      # that would make the unproved use durable truth.
      assert {:ok, ^bytes} = Artifacts.fetch(handle, object_of(reference))

      case describe_local(handle, reference.use_locator) do
        {:ok, ^artifact_use} ->
          assert phase in [:existing_value_compare, :parent_directory_sync]

        {:error, _reason} ->
          assert phase in [:staging_write, :file_sync, :atomic_publication]

        other ->
          flunk("#{phase} exposed a partial or unexpected artifact use: #{inspect(other)}")
      end
    end
  end

  test "existing artifact use comparison admits identical bytes and preserves different partial or unreadable values" do
    for existing <- [:identical, :different, :partial, :unreadable] do
      {_root, handle} = open_local("artifact-use-existing-#{existing}")
      bytes = "existing-use-#{existing}"
      metadata = caller_metadata(%{"session_id" => "existing-#{existing}"})
      {reference, artifact_use, use_bytes} = expected_local_artifact(bytes, metadata)

      assert {:ok, ^reference} = put_local(handle, bytes, metadata)
      assert {:ok, ^artifact_use} = describe_local(handle, reference.use_locator)
      use_path = local_use_path(handle, artifact_use)

      existing_bytes =
        case existing do
          :identical ->
            use_bytes

          :different ->
            "different complete artifact use"

          :partial ->
            binary_part(use_bytes, 0, div(byte_size(use_bytes), 2))

          :unreadable ->
            File.rm!(use_path)
            File.mkdir!(use_path)
            :unreadable
        end

      if is_binary(existing_bytes), do: File.write!(use_path, existing_bytes)

      answer = put_local(handle, bytes, metadata)

      case existing do
        :identical ->
          assert {:ok, ^reference} = answer
          assert File.read!(use_path) == use_bytes
          assert {:ok, ^artifact_use} = describe_local(handle, reference.use_locator)

        :unreadable ->
          assert {:error, _reason} = answer
          assert File.dir?(use_path)
          assert {:error, _reason} = describe_local(handle, reference.use_locator)

        _conflict ->
          assert {:error, _reason} = answer
          assert File.read!(use_path) == existing_bytes
          assert {:error, _reason} = describe_local(handle, reference.use_locator)
      end

      assert {:ok, ^bytes} = Artifacts.fetch(handle, object_of(reference))
    end
  end

  test "the truncation notice stays bounded and names the complete retained artifact" do
    for {module, handle} <- implementations() do
      full = String.duplicate("y", 50_000)
      {:ok, reference} = put_artifact(module, handle, full)
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

  test "the public retrieval facade resolves an opaque locator through validated object identity" do
    for {module, handle} <- implementations() do
      {:ok, reference} = put_artifact(module, handle, "the whole output")

      # The locator is the only thing the public facade receives. The in-memory
      # fixture deliberately issues a locator that differs from its digest, so
      # this fails if core reconstructs adapter identity by equating the two.
      if module == InMemory, do: refute(reference.locator == reference.digest)

      assert {:ok, "the whole output"} =
               retrieve_artifact(module, handle, reference.locator)

      if module == InMemory do
        assert InMemory.last_stat_locator(handle) == reference.locator
        assert InMemory.last_fetch_object(handle) == object_of(reference)

        assert Enum.sort(Map.keys(InMemory.last_fetch_object(handle))) == [
                 :digest,
                 :locator,
                 :size
               ]
      end
    end
  end

  test "public retrieval refuses dishonest stat identity and dishonest fetched bytes" do
    locator = "probe:requested"
    bytes = "truthful retrieval bytes"

    {:ok, substituted} = RetrieveProbe.start(:substituted_stat_locator, bytes)

    assert {:error, _reason} =
             retrieve_artifact(RetrieveProbe, substituted, locator)

    assert RetrieveProbe.calls(substituted) == [{:stat, locator}]

    {:ok, corrupt} = RetrieveProbe.start(:corrupt_fetch, bytes)

    assert {:error, :artifact_integrity_failed} =
             retrieve_artifact(RetrieveProbe, corrupt, locator)

    assert [stat: ^locator, fetch: object] = RetrieveProbe.calls(corrupt)
    assert Enum.sort(Map.keys(object)) == [:digest, :locator, :size]
    assert object.locator == locator
    assert object.digest == Canonical.digest_bytes(bytes)
    assert object.size == byte_size(bytes)
  end

  test "stat and fetch refuse same size and different size artifact corruption" do
    for replacement <- ["damage!", "short"] do
      for {module, handle} <- implementations() do
        {:ok, reference} = put_artifact(module, handle, "payload")
        corrupt(module, handle, reference, replacement)

        assert {:error, :artifact_integrity_failed} =
                 stat_artifact(module, handle, reference.locator)

        assert {:error, :artifact_integrity_failed} = fetch_artifact(module, handle, reference)
      end
    end
  end

  test "fetch refuses a reference whose claimed exact size differs from the stored bytes" do
    for {module, handle} <- implementations() do
      {:ok, reference} = put_artifact(module, handle, "payload")

      assert {:error, :artifact_integrity_failed} =
               fetch_artifact(module, handle, %{reference | size: reference.size + 1})
    end
  end

  test "opening an absent artifact root durably publishes every new directory component" do
    state_root =
      Path.join(
        System.fetch_env!("LOOPEX_HOME"),
        "absent-state-root-#{System.unique_integer([:positive])}"
      )

    artifact_root = Path.join(state_root, "artifacts")
    refute File.exists?(state_root)

    {{:ok, _handle}, events} = trace_publication(fn -> Artifacts.open(artifact_root) end)

    # One sync reconfirms the nearest existing boundary and one follows each of
    # the two new directory entries. That first sync makes a retry safe after a
    # prior creator made the directory visible but failed its parent sync.
    assert events == [
             {:sync, Path.dirname(System.fetch_env!("LOOPEX_HOME"))},
             {:sync, System.fetch_env!("LOOPEX_HOME")},
             {:sync, state_root}
           ]

    assert File.dir?(state_root)
    assert File.dir?(artifact_root)
  end

  test "artifact publication leaves unrelated store files unchanged" do
    root =
      Path.join(
        System.fetch_env!("LOOPEX_HOME"),
        "artifact-temp-collision-#{System.unique_integer([:positive])}"
      )

    {:ok, handle} = Artifacts.open(root)
    bytes = "collision-safe payload"
    digest = Canonical.digest_bytes(bytes)
    unrelated = Path.join(root, "unrelated-store-file")

    File.write!(unrelated, "another writer's bytes")

    assert {:ok, reference} = put_artifact(Artifacts, handle, bytes)
    assert reference.digest == digest
    assert {:ok, ^bytes} = fetch_artifact(Artifacts, handle, reference)
    assert File.read!(unrelated) == "another writer's bytes"
  end

  test "artifact publication syncs file bytes before its durable directory entry" do
    [{Artifacts, handle} | _rest] = implementations()

    {{:ok, reference}, events} =
      trace_publication(fn -> put_artifact(Artifacts, handle, "durable payload") end)

    publications = for {:rename, source, destination} <- events, do: {source, destination}
    assert length(publications) >= 2

    for publication <- publications do
      assert_durable_publication(events, publication)
    end

    {{:ok, ^reference}, repeated} =
      trace_publication(fn -> put_artifact(Artifacts, handle, "durable payload") end)

    refute Enum.any?(repeated, &match?({:write, _path}, &1))
    refute Enum.any?(repeated, &match?({:rename, _source, _destination}, &1))

    for {_source, destination} <- publications do
      assert {:sync, destination} in repeated
      assert {:sync, Path.dirname(destination)} in repeated
    end
  end

  test "unsafe opaque locators are refused before an adapter can resolve them" do
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
        locator: locator,
        use_canonicalization_version: Canonical.version(),
        use_digest: String.duplicate("b", 64),
        use_locator: "use:" <> String.duplicate("b", 64)
      }

      refute ArtifactStore.valid_reference?(reference)

      assert {:error, :invalid_artifact_reference} =
               retrieve_artifact(AdmissionProbe, self(), locator)

      refute_receive {:adapter_called, _callback}, 20
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
      {:ok, issued} = put_artifact(module, handle, "known")
      foreign = %{issued | digest: String.duplicate("a", 64), size: 3, locator: "x"}

      assert {:error, :unknown_artifact} = fetch_artifact(module, handle, foreign)
      assert {:error, :unknown_artifact} = stat_artifact(module, handle, foreign.locator)

      # An empty locator was already refused by the port; a long one that is not
      # this store's shape is refused for the same reason.
      assert {:error, :unknown_artifact} =
               fetch_artifact(module, handle, %{foreign | locator: String.duplicate("z", 64)})
    end
  end

  test "an artifact round trips byte exactly and a missing artifact reports unavailable" do
    for {module, handle} <- implementations() do
      # Bytes that a text-oriented path would mangle: nulls, high bytes, and a
      # trailing newline that a naive line reader would drop.
      awkward = <<0, 255, 128, 10>> <> "tail\n"
      {:ok, reference} = put_artifact(module, handle, awkward)
      assert {:ok, ^awkward} = fetch_artifact(module, handle, reference)
      assert byte_size(awkward) == reference.size

      # A reference to something that was never stored says so, rather than
      # returning an empty success a caller would read as an empty artifact.
      absent = %{
        reference
        | digest: String.duplicate("0", 64),
          locator: String.duplicate("0", 64)
      }

      assert {:error, :unknown_artifact} = fetch_artifact(module, handle, absent)
      assert {:error, :unknown_artifact} = stat_artifact(module, handle, absent.locator)

      # An empty artifact is a different fact and round trips as itself.
      {:ok, empty_reference} = put_artifact(module, handle, "")
      assert {:ok, ""} = fetch_artifact(module, handle, empty_reference)
      assert empty_reference.size == 0
    end
  end

  defp stored_identity_counts(InMemory, pid, _bytes, _uses), do: InMemory.counts(pid)

  defp stored_identity_counts(Artifacts, %{root: root}, bytes, uses) do
    retained = Enum.map(regular_files(root), &File.read!/1)
    use_bytes = MapSet.new(Enum.map(uses, &Canonical.encode(["artifact-use-v2", &1])))

    %{
      objects: Enum.count(retained, &(&1 == bytes)),
      uses: Enum.count(retained, &MapSet.member?(use_bytes, &1))
    }
  end

  defp regular_files(root) do
    root
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
  end

  defp corrupt_use(Artifacts, handle, _reference, use, bytes) do
    path = local_use_path(handle, use)
    File.write!(path, bytes)
    path
  end

  defp corrupt_use(InMemory, pid, reference, _use, bytes) do
    InMemory.corrupt_use(pid, reference.use_locator, bytes)
    reference.use_locator
  end

  defp delete_use(Artifacts, handle, _reference, use) do
    handle
    |> local_use_path(use)
    |> File.rm!()
  end

  defp delete_use(InMemory, pid, reference, _use) do
    InMemory.delete_use(pid, reference.use_locator)
  end

  defp read_use_bytes(Artifacts, _handle, path), do: File.read(path)

  defp read_use_bytes(InMemory, pid, use_locator), do: InMemory.use_bytes(pid, use_locator)

  defp local_use_path(%{root: root}, use) do
    canonical = Canonical.encode(["artifact-use-v2", use])

    case Enum.filter(regular_files(root), fn path -> File.read!(path) == canonical end) do
      [path] -> path
      [] -> flunk("the successful use was not durably published as exact canonical bytes")
      paths -> flunk("one artifact use resolved to multiple sidecars: #{inspect(paths)}")
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

    patterns = [
      {{:file, :open, 2}, [{:_, [], [{:return_trace}]}]},
      {{:file, :close, 1}, true},
      {{:file, :write, 2}, true},
      {{:file, :sync, 1}, true},
      {{:file, :rename, 2}, true}
    ]

    Enum.each(patterns, fn {pattern, match_spec} ->
      1 = :erlang.trace_pattern(pattern, match_spec, [])
    end)

    1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    result =
      try do
        result = fun.()
        assert {:ok, _value} = result
        result
      after
        1 = :erlang.trace(self(), false, [:call])

        Enum.each(patterns, fn {pattern, _match_spec} ->
          1 = :erlang.trace_pattern(pattern, false, [])
        end)
      end

    delivery = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _tracee, ^delivery} -> :ok
    after
      1_000 -> flunk("file publication trace was not delivered")
    end

    send(tracer, {:finish, self()})

    receive do
      {:publication_trace, events} -> {result, events}
    after
      1_000 -> flunk("file publication trace did not finish")
    end
  end

  defp trace_forwarder(test) do
    trace_forwarder(test, %{devices: %{}, events: [], pending_open: []})
  end

  defp trace_forwarder(test, state) do
    receive do
      {:trace, ^test, :call, {:file, :open, [path, _modes]}} ->
        trace_forwarder(test, %{state | pending_open: [normalize_path(path) | state.pending_open]})

      {:trace, ^test, :return_from, {:file, :open, 2}, result} ->
        [path | pending] = state.pending_open

        devices =
          case result do
            {:ok, io_device} -> Map.put(state.devices, io_device, path)
            {:error, _reason} -> state.devices
          end

        trace_forwarder(test, %{state | devices: devices, pending_open: pending})

      {:trace, ^test, :call, {:file, :close, [io_device]}} ->
        trace_forwarder(test, %{state | devices: Map.delete(state.devices, io_device)})

      {:trace, ^test, :call, {:file, :sync, [io_device]}} ->
        path = Map.get(state.devices, io_device, {:unknown_io_device, io_device})
        trace_forwarder(test, %{state | events: [{:sync, path} | state.events]})

      {:trace, ^test, :call, {:file, :write, [io_device, _bytes]}} ->
        path = Map.get(state.devices, io_device, {:unknown_io_device, io_device})
        trace_forwarder(test, %{state | events: [{:write, path} | state.events]})

      {:trace, ^test, :call, {:file, :rename, [source, destination]}} ->
        event = {:rename, normalize_path(source), normalize_path(destination)}
        trace_forwarder(test, %{state | events: [event | state.events]})

      {:finish, ^test} ->
        send(test, {:publication_trace, Enum.reverse(state.events)})
    end
  end

  defp assert_durable_publication(events, {source, destination}) do
    write = event_index(events, &(&1 == {:write, source}))
    file_sync = if is_integer(write), do: event_index(events, &(&1 == {:sync, source}), write)

    rename =
      if is_integer(file_sync),
        do: event_index(events, &(&1 == {:rename, source, destination}), file_sync)

    parent_sync =
      if is_integer(rename),
        do: event_index(events, &(&1 == {:sync, Path.dirname(destination)}), rename)

    assert is_integer(write), "no write was traced for staging file #{source}"
    assert is_integer(file_sync), "staging file #{source} was not synced after its write"
    assert is_integer(rename), "staging file #{source} was not renamed to #{destination}"

    assert is_integer(parent_sync),
           "destination directory #{Path.dirname(destination)} was not synced after publication"
  end

  defp event_index(events, predicate, after_index \\ -1) do
    events
    |> Enum.with_index()
    |> Enum.find_value(fn {event, index} ->
      if index > after_index and predicate.(event), do: index
    end)
  end

  defp normalize_path(path) when is_binary(path), do: path
  defp normalize_path(path) when is_list(path), do: List.to_string(path)
end
