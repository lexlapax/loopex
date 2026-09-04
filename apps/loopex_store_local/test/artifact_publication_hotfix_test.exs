defmodule Loopex.Store.Local.ArtifactPublicationHotfixTest do
  @moduledoc false

  use ExUnit.Case, async: false

  alias Loopex.Store.Local.Artifacts
  alias LoopexProtocol.Canonical

  # Concept: the two questions a reported publication race raises — can one
  # publisher destroy another's value, and is every directory the store creates
  # durable — answered where the filesystem actually decides them.
  #
  # Technical depth: a use sidecar's name is the digest of the exact bytes it
  # holds, so two publishers can contend for one name only by publishing
  # identical bytes. The first case races two different uses of one object and
  # shows they never share a name; the second holds one publisher with its
  # rename outstanding, lets a second publish completely, and then measures what
  # the released rename replaced. The third traces the directory syncs one first
  # publication performs, because "the entry exists" and "the entry survives a
  # crash" are different facts and only the syncs distinguish them.

  defmodule Probe do
    @moduledoc false

    # Concept: hold one publisher at one semantic phase and let it finish on
    # command, so an interleaving is exhibited rather than raced for.
    #
    # Technical depth: the adapter's private `:fault_probe` seam announces each
    # phase and blocks. Phases other than the target continue immediately, so the
    # held publisher completes normally once released.
    def start(owner, target), do: spawn_link(fn -> loop(owner, target) end)

    def release(probe), do: send(probe, :release)

    def stop(probe), do: send(probe, :stop)

    defp loop(owner, target) do
      receive do
        {:loopex_artifact_fault_point, caller, reference, pair} when is_pid(caller) ->
          if pair == target do
            send(owner, {:artifact_fault_reached, self(), pair})

            receive do
              :release ->
                send(caller, {:loopex_artifact_fault_action, reference, :continue})
                loop(owner, target)

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

  test "concurrent uses of one object never contend for a single sidecar name" do
    {root, handle} = open_local("artifact-race-distinct")
    bytes = "one object retained for two different reasons"

    answers =
      1..8
      |> Enum.flat_map(fn index -> ["left-#{index}", "right-#{index}"] end)
      |> Task.async_stream(
        fn session -> {session, put_local(handle, bytes, session)} end,
        max_concurrency: 8,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, answer} -> answer end)

    for {session, answer} <- answers do
      assert {:ok, reference} = answer
      assert reference.locator == Canonical.digest_bytes(bytes)
      assert {:ok, artifact_use} = Artifacts.describe(handle, reference.use_locator)
      assert artifact_use.metadata["session_id"] == session
      assert File.read!(use_path(root, reference)) == use_bytes(bytes, metadata(session))
    end

    locators = for {_session, {:ok, reference}} <- answers, do: reference.use_locator
    assert length(Enum.uniq(locators)) == length(answers)
  end

  test "a publisher held at atomic publication replaces only byte-identical bytes" do
    {root, handle} = open_local("artifact-race-identical")
    bytes = "one object, one reason, two publishers"
    session = "same-reason"
    expected_use_bytes = use_bytes(bytes, metadata(session))

    pair = {:artifact_use_publication, :atomic_publication}
    probe = Probe.start(self(), pair)
    on_exit(fn -> Probe.stop(probe) end)

    # The first publisher observed absence, staged its complete bytes, synced
    # them, and is now held with exactly the reported rename outstanding.
    held = Task.async(fn -> put_local(Map.put(handle, :fault_probe, probe), bytes, session) end)

    assert_receive {:artifact_fault_reached, ^probe, ^pair}, 10_000
    assert Task.yield(held, 0) == nil

    # The second publisher observes the same absence and publishes completely.
    assert {:ok, published} = put_local(handle, bytes, session)
    path = use_path(root, published)
    assert File.read!(path) == expected_use_bytes
    first_inode = File.stat!(path).inode

    # The held rename now lands on the name the second publisher already holds.
    Probe.release(probe)
    assert {:ok, ^published} = Task.await(held, 10_000)

    assert File.stat!(path).inode != first_inode,
           "the reported replacement did not occur, so this case proves nothing"

    assert File.read!(path) == expected_use_bytes,
           "a publication race replaced a competing final value"

    assert {:ok, artifact_use} = Artifacts.describe(handle, published.use_locator)
    assert artifact_use.metadata["session_id"] == session
  end

  test "publishing the first use durably records every directory entry it creates" do
    {root, handle} = open_local("artifact-parent-sync")
    bytes = "first use record under a new root"
    session = "parent-sync"

    {{:ok, reference}, events} = trace(fn -> put_local(handle, bytes, session) end)

    uses = Path.join(root, "uses")
    fan_out = Path.dirname(use_path(root, reference))

    assert File.dir?(uses)
    assert File.dir?(fan_out)

    assert {:sync, root} in events,
           "#{root} was not synced, so its new entry is not durable"

    assert {:sync, uses} in events,
           "#{uses} was not synced, so its entry for #{Path.basename(fan_out)} is not durable"

    assert {:sync, fan_out} in events,
           "#{fan_out} was not synced, so the published use record is not durable"
  end

  defp metadata(session) do
    %{
      media_type: "application/octet-stream",
      role: "tool_output",
      metadata: %{
        "session_id" => session,
        "run_id" => "run-1",
        "operation_id" => "operation-1",
        "attempt" => 1,
        "tool_call_id" => "call-1"
      }
    }
  end

  defp put_local(handle, bytes, session), do: Artifacts.put(handle, bytes, metadata(session))

  defp use_bytes(bytes, use) do
    digest = Canonical.digest_bytes(bytes)

    Canonical.encode([
      "artifact-use-v2",
      %{
        canonicalization_version: Canonical.version(),
        object_digest: digest,
        object_size: byte_size(bytes),
        object_locator: digest,
        media_type: use.media_type,
        role: use.role,
        metadata: use.metadata
      }
    ])
  end

  defp use_path(root, reference) do
    "use:" <> use_digest = reference.use_locator
    Path.join([root, "uses", binary_part(use_digest, 0, 2), use_digest])
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

  # Concept: which directories a publication actually synced.
  #
  # Technical depth: directory durability leaves no trace on the filesystem, so
  # the `:file` calls are traced and the io device each sync names is resolved
  # back to the path it was opened with.
  defp trace(fun) do
    test = self()
    tracer = spawn_link(fn -> forward(test, %{devices: %{}, events: [], opening: []}) end)

    patterns = [{{:file, :open, 2}, [{:_, [], [{:return_trace}]}]}, {{:file, :sync, 1}, true}]

    Enum.each(patterns, fn {pattern, match_spec} ->
      1 = :erlang.trace_pattern(pattern, match_spec, [])
    end)

    1 = :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    result =
      try do
        fun.()
      after
        1 = :erlang.trace(self(), false, [:call])

        Enum.each(patterns, fn {pattern, _spec} ->
          1 = :erlang.trace_pattern(pattern, false, [])
        end)
      end

    delivery = :erlang.trace_delivered(self())

    receive do
      {:trace_delivered, _tracee, ^delivery} -> :ok
    after
      1_000 -> flunk("the publication trace was not delivered")
    end

    send(tracer, {:finish, self()})

    receive do
      {:publication_trace, events} -> {result, events}
    after
      1_000 -> flunk("the publication trace did not finish")
    end
  end

  defp forward(test, state) do
    receive do
      {:trace, ^test, :call, {:file, :open, [path, _modes]}} ->
        forward(test, %{state | opening: [normalize(path) | state.opening]})

      {:trace, ^test, :return_from, {:file, :open, 2}, result} ->
        [path | opening] = state.opening

        devices =
          case result do
            {:ok, device} -> Map.put(state.devices, device, path)
            {:error, _reason} -> state.devices
          end

        forward(test, %{state | devices: devices, opening: opening})

      {:trace, ^test, :call, {:file, :sync, [device]}} ->
        path = Map.get(state.devices, device, {:unknown_device, device})
        forward(test, %{state | events: [{:sync, path} | state.events]})

      {:finish, ^test} ->
        send(test, {:publication_trace, Enum.reverse(state.events)})
    end
  end

  defp normalize(path) when is_binary(path), do: path
  defp normalize(path) when is_list(path), do: List.to_string(path)
end
