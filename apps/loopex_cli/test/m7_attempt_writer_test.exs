defmodule LoopexCli.M7AttemptWriterTest do
  use ExUnit.Case, async: true

  # Concept: the attempts writer is proved on real files, real loopback
  # listeners and real independent VMs; no mutex or callback stands in for the
  # lock. Technical depth: every test uses its own temporary directory outside
  # the repository and its own index, so each lock port is chosen afresh.

  alias Mix.Tasks.Loopex.M7Evidence.AttemptEvents, as: Events
  alias Mix.Tasks.Loopex.M7Evidence.AttemptFrames, as: Frames
  alias Mix.Tasks.Loopex.M7Evidence.AttemptWriter, as: Writer

  @campaign "m7-writer"
  @digest String.duplicate("0", 64)
  @first String.duplicate("1", 40)
  @second String.duplicate("2", 40)
  @third String.duplicate("3", 40)

  setup do
    dir = Path.join(System.tmp_dir!(), "m7-writer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir, index: Path.join(dir, "attempts.jsonl")}
  end

  test "creation fixes one lock port and durable genesis and designation", %{
    dir: dir,
    index: index
  } do
    assert {:ok, writer} = Writer.create(index, @campaign, host(dir, 1))
    lock = File.read!(index <> ".lock")
    assert [_, port] = Regex.run(~r/\A\{"port":([0-9]{5}),"version":1\}\n\z/, lock)
    assert String.to_integer(port) in 20_000..32_767

    assert [genesis, designation] = records(index)
    assert genesis["body"]["kind"] == "genesis" and genesis["body"]["campaign_id"] == @campaign
    assert designation["body"]["writer_id"] == "writer-1"
    assert {:ok, File.read!(index)} == Writer.read(writer)

    assert Writer.open(index, host(dir, 1)) == {:error, :attempt_writer_contention}
    assert Writer.create(index, @campaign, host(dir, 1)) == {:error, :attempt_evidence_exists}
    :ok = Writer.close(writer)
    assert {:ok, reopened} = Writer.open(index, host(dir, 1))
    assert File.read!(index <> ".lock") == lock
    :ok = Writer.close(reopened)
  end

  test "a successor campaign records its succession first after designation",
       %{dir: dir, index: index} do
    reference = ref(dir, "disposition")

    succession = %{
      "kind" => "campaign_succession",
      "version" => 1,
      "writer_id" => "writer-1",
      "host_id" => "host-1",
      "ownership_epoch" => 1,
      "predecessor_head" => %{"campaign_id" => "m7-lost", "sequence" => 9, "digest" => @digest},
      "prior_rows" => reference,
      "unavailable_interval" => reference,
      "disposition" => reference
    }

    assert {:ok, writer} = Writer.create(index, @campaign, host(dir, 1), succession: succession)
    assert [_, _, %{"body" => ^succession, "sequence" => 3}] = records(index)
    :ok = Writer.close(writer)

    other = Path.join(dir, "other.jsonl")

    lost =
      Map.put(succession, "predecessor_head", %{
        "campaign_id" => @campaign,
        "sequence" => 9,
        "digest" => @digest
      })

    assert {:error, :invalid_attempt_event} =
             Writer.create(other, @campaign, host(dir, 1), succession: lost)
  end

  test "missing or malformed lock records and a missing index are unavailable evidence",
       %{dir: dir, index: index} do
    created!(dir, index) |> elem(0) |> Writer.close()
    lock = File.read!(index <> ".lock")

    for bytes <- [
          "",
          String.trim_trailing(lock),
          ~s({"port":19999,"version":1}\n),
          ~s({"port":32768,"version":1}\n),
          ~s({"version":1,"port":20000}\n)
        ] do
      File.write!(index <> ".lock", bytes)
      assert Writer.open(index, host(dir, 1)) == {:error, :attempt_lock_unavailable}
    end

    File.rm!(index <> ".lock")
    assert Writer.open(index, host(dir, 1)) == {:error, :attempt_lock_unavailable}
    File.write!(index <> ".lock", lock)
    File.rename!(index, index <> ".moved")
    assert Writer.open(index, host(dir, 1)) == {:error, :attempt_index_unavailable}
  end

  test "independent VMs contend for one lock and exactly one becomes the writer",
       %{dir: dir, index: index} do
    created!(dir, index) |> elem(0) |> Writer.close()
    vms = for _ <- 1..2, do: vm(open_and_hold(index, host(dir, 1)))
    results = Enum.map(vms, &line!/1) |> Enum.sort()
    assert results == ["OPEN error attempt_writer_contention", "OPEN ok"]
    assert Writer.open(index, host(dir, 1)) == {:error, :attempt_writer_contention}
    Enum.each(vms, &stop_vm/1)
    assert {:ok, writer} = Writer.open(index, host(dir, 1))
    :ok = Writer.close(writer)
  end

  test "a crashed writer process releases the lock while its VM keeps running",
       %{dir: dir, index: index} do
    created!(dir, index) |> elem(0) |> Writer.close()
    vm = vm(open_and_hold(index, host(dir, 1)))
    assert line!(vm) == "OPEN ok"
    assert Writer.open(index, host(dir, 1)) == {:error, :attempt_writer_contention}
    Port.command(vm, "crash\n")
    assert line!(vm) == "RELEASED"
    assert {:ok, writer} = Writer.open(index, host(dir, 1))
    Port.command(vm, "alive\n")
    assert line!(vm) == "ALIVE"
    :ok = Writer.close(writer)
    stop_vm(vm)
  end

  test "a killed writer VM releases the lock and its acknowledged start stays consumed",
       %{dir: dir, index: index} do
    created!(dir, index) |> elem(0) |> Writer.close()
    [_, designation] = records(index)
    concept = head_line(designation)
    selection = selection(["a", "b"], @first)
    started = started(dir, "a", @first)

    vm =
      vm("""
      #{prelude()}
      {:ok, w} = Writer.open(#{lit(index)}, #{lit(host(dir, 1))})
      {:ok, _} = Writer.admit(w, #{lit(concept)}, #{lit(selection)}, :new)
      {:ok, record} = Writer.append(w, #{lit(started)})
      IO.puts("ACK " <> Integer.to_string(record["sequence"]))
      IO.puts("PID " <> System.pid())
      IO.read(:stdio, :line)
      """)

    assert line!(vm) == "ACK 3"
    "PID " <> os_pid = line!(vm)
    {_, 0} = System.cmd("kill", ["-KILL", os_pid])
    assert_receive {^vm, {:exit_status, _}}, 30_000

    assert {:ok, writer} = Writer.open(index, host(dir, 1))
    assert [_, _, record] = records(index)
    assert record["body"]["state"] == "started" and record["body"]["case_key"] == "a"

    assert {:blocked, %{reason: :consumed_lane_failure, remaining: []}} =
             Writer.admit(writer, concept, selection, :continue)

    assert Writer.append(writer, started) == {:error, :attempt_case_not_admitted}
  end

  test "an unrelated listener on the lock port refuses as contention until it exits",
       %{dir: dir, index: index} do
    created!(dir, index) |> elem(0) |> Writer.close()
    [_, port] = Regex.run(~r/"port":([0-9]+)/, File.read!(index <> ".lock"))

    listener =
      vm("""
      {:ok, _socket} = :gen_tcp.listen(#{port}, ip: {127, 0, 0, 1})
      IO.puts("LISTENING")
      IO.read(:stdio, :line)
      """)

    assert line!(listener) == "LISTENING"
    assert Writer.open(index, host(dir, 1)) == {:error, :attempt_writer_contention}
    stop_vm(listener)
    assert {:ok, writer} = Writer.open(index, host(dir, 1))
    :ok = Writer.close(writer)
  end

  test "an acknowledged append is already complete in the file and ownership needs handoff",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    assert {:ok, _} = Writer.admit(writer, concept, selection(["a"], @first), :new)
    before = File.read!(index)
    assert {:ok, record} = Writer.append(writer, started(dir, "a", @first))
    {:ok, line, ^record} = Frames.encode(@campaign, 3, record["previous_digest"], record["body"])
    assert File.read!(index) == before <> line

    for kind <-
          ~w(genesis writer_designated writer_relinquished writer_accepted campaign_succession) do
      assert Writer.append(writer, %{"kind" => kind}) ==
               {:error, :attempt_ownership_requires_handoff}
    end

    assert File.read!(index) == before <> line
  end

  test "a torn final append stays unresolved and its bytes are never truncated",
       %{dir: dir, index: index} do
    {writer, _} = created!(dir, index)
    :ok = Writer.close(writer)

    {:ok, line, _} =
      Frames.encode(@campaign, 3, hd(records(index) |> Enum.reverse())["digest"], %{})

    for cut <- [1, div(byte_size(line), 2), byte_size(line) - 1] do
      original = File.read!(index)
      File.write!(index, original <> binary_part(line, 0, cut))
      torn = File.read!(index)

      assert {:error, {:incomplete_attempt_append, %{"sequence" => 2}}} =
               Writer.open(index, host(dir, 1))

      assert File.read!(index) == torn
      File.write!(index, original)
    end
  end

  test "truncated history and forked copies refuse against the committed head",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    {:ok, _} = Writer.admit(writer, concept, selection(["a"], @first), :new)
    {:ok, _} = Writer.append(writer, started(dir, "a", @first))
    {:ok, last} = Writer.append(writer, completed(dir, "a", @first, "pass"))
    committed = head_line(last)
    full = File.read!(index)
    :ok = Writer.close(writer)

    truncated =
      full |> String.split("\n", trim: true) |> Enum.take(3) |> Enum.map_join(&(&1 <> "\n"))

    File.write!(index, truncated)
    {:ok, writer} = Writer.open(index, host(dir, 1))

    assert Writer.admit(writer, committed, selection(["a"], @second), :new) ==
             {:error, :committed_attempt_head_mismatch}

    :ok = Writer.close(writer)
    [_, _, started] = records(index)
    forked = Map.put(completed(dir, "a", @first, "assertion_failed"), "ownership_epoch", 1)
    forked = Map.merge(forked, Map.take(started["body"], ~w(writer_id host_id)))
    {:ok, line, fork} = Events.encode(@campaign, 4, started["digest"], forked)
    File.write!(index, truncated <> line)
    refute fork["digest"] == last["digest"]
    {:ok, writer} = Writer.open(index, host(dir, 1))

    assert Writer.admit(writer, committed, selection(["a"], @second), :new) ==
             {:error, :committed_attempt_head_mismatch}

    assert {:ok, _} = Writer.read(writer)
  end

  test "admission gates each fresh start in pinned order before any dispatch",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)

    assert Writer.append(writer, started(dir, "a", @first)) ==
             {:error, :attempt_case_not_admitted}

    assert {:ok, plan} = Writer.admit(writer, concept, selection(["a", "b"], @first), :new)
    assert Enum.map(plan.remaining, & &1.pin["case_key"]) == ["a", "b"]

    assert Writer.append(writer, started(dir, "b", @first)) ==
             {:error, :attempt_case_not_admitted}

    changed =
      Map.put(started(dir, "a", @first), "specification_digest", String.duplicate("f", 64))

    assert Writer.append(writer, changed) == {:error, :attempt_case_not_admitted}
    assert {:ok, _} = Writer.append(writer, started(dir, "a", @first))

    assert Writer.append(writer, started(dir, "b", @first)) ==
             {:error, :attempt_case_not_admitted}

    assert {:ok, _} = Writer.append(writer, completed(dir, "a", @first, "pass"))
    assert {:ok, _} = Writer.append(writer, started(dir, "b", @first))
    assert {:ok, _} = Writer.append(writer, completed(dir, "b", @first, "pass"))

    assert Writer.append(writer, started(dir, "a", @first)) ==
             {:error, :attempt_case_not_admitted}

    assert Writer.append(writer, pre_dispatch(dir, "a", @first)) ==
             {:error, :attempt_case_not_admitted}

    assert {:blocked, %{reason: :lane_already_ended}} =
             Writer.admit(writer, concept, selection(["a", "b"], @first), :continue)
  end

  test "a non-pass completion ends the admitted lane before its next case",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    {:ok, _} = Writer.admit(writer, concept, selection(["a", "b"], @first), :new)
    {:ok, _} = Writer.append(writer, started(dir, "a", @first))
    {:ok, _} = Writer.append(writer, completed(dir, "a", @first, "assertion_failed"))

    assert Writer.append(writer, started(dir, "b", @first)) ==
             {:error, :attempt_case_not_admitted}

    assert Writer.append(writer, pre_dispatch(dir, "b", @first)) ==
             {:error, :attempt_case_not_admitted}

    assert {:blocked, %{reason: :consumed_lane_failure}} =
             Writer.admit(writer, concept, selection(["a", "b"], @first), :continue)
  end

  test "a pre-dispatch stop resumes on its commit reusing verified passes only",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    {:ok, _} = Writer.admit(writer, concept, selection(["a", "b"], @first), :new)
    {:ok, _} = Writer.append(writer, started(dir, "a", @first))
    {:ok, _} = Writer.append(writer, completed(dir, "a", @first, "pass"))
    {:ok, _} = Writer.append(writer, pre_dispatch(dir, "b", @first))

    assert Writer.append(writer, started(dir, "b", @first)) ==
             {:error, :attempt_case_not_admitted}

    :ok = Writer.close(writer)

    {:ok, writer} = Writer.open(index, host(dir, 1))

    assert {:blocked, %{reason: :post_head_consumed_case}} =
             Writer.admit(writer, concept, selection(["a", "b"], @first), :new)

    [result] = completed(dir, "a", @first, "pass")["evidence"]
    original = File.read!(result["reference"])

    for {bytes, reason} <- [{nil, :missing_reference_bytes}, {original <> "x", :digest_mismatch}] do
      if bytes, do: File.write!(result["reference"], bytes), else: File.rm!(result["reference"])

      assert {:unavailable, %{reason: ^reason, member: "evidence"} = detail} =
               Writer.admit(writer, concept, selection(["a", "b"], @first), :continue)

      refute inspect(detail, limit: :infinity) =~ original

      assert Writer.append(writer, started(dir, "b", @first)) ==
               {:error, :attempt_case_not_admitted}
    end

    File.write!(result["reference"], original)
    assert {:ok, plan} = Writer.admit(writer, concept, selection(["a", "b"], @first), :continue)
    assert [%{pin: %{"case_key" => "a"}}] = plan.reused
    assert [%{pin: %{"case_key" => "b"}}] = plan.remaining

    assert Writer.append(writer, started(dir, "a", @first)) ==
             {:error, :attempt_case_not_admitted}

    assert {:ok, _} = Writer.append(writer, started(dir, "b", @first))
  end

  test "an abandoned suspended lane never continues and the next commit runs every case",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    {:ok, _} = Writer.admit(writer, concept, selection(["a", "b"], @first), :new)
    {:ok, _} = Writer.append(writer, started(dir, "a", @first))
    {:ok, _} = Writer.append(writer, completed(dir, "a", @first, "pass"))
    {:ok, stop} = Writer.append(writer, pre_dispatch(dir, "b", @first))

    assert {:blocked, %{reason: :post_head_consumed_case}} =
             Writer.admit(writer, concept, selection(["a", "b"], @second), :new)

    abandoned = head_line(stop)

    assert {:blocked, %{reason: :lane_abandoned}} =
             Writer.admit(writer, abandoned, selection(["a", "b"], @first), :continue)

    assert {:ok, plan} = Writer.admit(writer, abandoned, selection(["a", "b"], @second), :new)
    assert plan.reused == [] and length(plan.remaining) == 2
    {:ok, _} = Writer.append(writer, started(dir, "a", @second))
    {:ok, _} = Writer.append(writer, completed(dir, "a", @second, "pass"))

    assert {:blocked, %{reason: :lane_abandoned}} =
             Writer.admit(writer, concept, selection(["a", "b"], @first), :continue)
  end

  for {mechanical, verdict} <- [
        {"assertion_failed", "product_failure"},
        {"required_action_absent", "model_nonconformance"},
        {"evidence_incomplete_post_dispatch", "evidence_unavailable"},
        {"provider_environment_failure", "environment_failure"}
      ] do
    test "#{verdict} needs an independent causal authorization naming the next candidate",
         %{dir: dir, index: index} do
      {writer, concept} = created!(dir, index)

      head =
        failed_lane!(writer, dir, concept, unquote(mechanical), unquote(verdict), "reviewer-1")

      assert {:blocked, %{reason: :prior_failure_unauthorized, remaining: []}} =
               Writer.admit(writer, head, selection(["a"], @second), :new)

      reviewed = List.last(records(index))["body"]
      {:ok, authorization} = Writer.append(writer, authorized(dir, reviewed, @second))
      head = head_line(authorization)

      assert {:blocked, %{reason: :prior_failure_unauthorized}} =
               Writer.admit(writer, head, selection(["a"], @third), :new)

      reference = authorization["body"]["authorization_evidence"]["reference"]
      original = File.read!(reference)
      File.rm!(reference)

      assert {:unavailable, %{member: "authorization_evidence", reason: :missing_reference_bytes}} =
               Writer.admit(writer, head, selection(["a"], @second), :new)

      File.write!(reference, original)
      assert {:ok, plan} = Writer.admit(writer, head, selection(["a"], @second), :new)
      assert plan.authorizations == [authorization]
      assert {:ok, _} = Writer.append(writer, started(dir, "a", @second))
    end
  end

  test "an authorized lane's continuation re-verifies its causal references",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    failed_lane!(writer, dir, concept, "assertion_failed", "product_failure", "reviewer-1")
    reviewed = List.last(records(index))["body"]
    {:ok, authorization} = Writer.append(writer, authorized(dir, reviewed, @second))
    head = head_line(authorization)
    {:ok, _} = Writer.admit(writer, head, selection(["a", "b"], @second), :new)
    {:ok, _} = Writer.append(writer, started(dir, "a", @second))
    {:ok, _} = Writer.append(writer, completed(dir, "a", @second, "pass"))
    {:ok, _} = Writer.append(writer, pre_dispatch(dir, "b", @second))
    reference = authorization["body"]["disposition"]["reference"]
    original = File.read!(reference)
    File.write!(reference, original <> "changed")

    assert {:unavailable, %{member: "disposition", reason: :digest_mismatch}} =
             Writer.admit(writer, head, selection(["a", "b"], @second), :continue)

    File.write!(reference, original)
    assert {:ok, plan} = Writer.admit(writer, head, selection(["a", "b"], @second), :continue)
    assert plan.authorizations == [authorization]
    assert [%{pin: %{"case_key" => "b"}}] = plan.remaining
  end

  test "a reviewer who is the case writer cannot authorize a reroll", %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)

    failed_lane!(
      writer,
      dir,
      concept,
      "provider_environment_failure",
      "environment_failure",
      "writer-1"
    )

    reviewed = List.last(records(index))["body"]
    {:ok, authorization} = Writer.append(writer, authorized(dir, reviewed, @second))

    assert {:blocked, %{reason: :prior_failure_unauthorized}} =
             Writer.admit(writer, head_line(authorization), selection(["a"], @second), :new)
  end

  test "a reviewed pass needs no authorization and evidence loss never becomes a pass",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    {:ok, _} = Writer.admit(writer, concept, selection(["a"], @first), :new)
    {:ok, _} = Writer.append(writer, started(dir, "a", @first))
    completed = completed(dir, "a", @first, "pass")
    {:ok, _} = Writer.append(writer, completed)
    {:ok, review} = Writer.append(writer, reviewed(dir, completed, "pass", "reviewer-1"))
    assert {:ok, plan} = Writer.admit(writer, head_line(review), selection(["a"], @second), :new)
    assert plan.authorizations == []

    lost = completed(dir, "a", @first, "evidence_incomplete_post_dispatch")
    assert lost["evidence"] == nil

    lost_pass = Map.merge(reviewed(dir, lost, "pass", "reviewer-1"), tuple())
    assert Events.encode(@campaign, 9, @digest, lost_pass) == {:error, :invalid_attempt_event}
  end

  test "handoff moves the sole writer between hosts and back with retained evidence",
       %{dir: dir, index: index} do
    {writer, _} = created!(dir, index)
    quiescence = Path.join(dir, "quiescence-1")
    before = File.read!(index)

    assert {:ok, %{marker: marker, record: relinquished}} =
             Writer.relinquish(writer, "writer-2", "host-2", "handoff-1", quiescence)

    refute Process.alive?(writer)
    assert File.read!(quiescence) == before
    assert File.read!(marker) == last_line(index)

    {:ok, source} = Writer.open(index, host(dir, 1))

    assert Writer.admit(source, "", selection(["a"], @first), :new) ==
             {:error, :attempt_handoff_pending}

    assert Writer.append(source, started(dir, "a", @first)) == {:error, :attempt_handoff_pending}
    :ok = Writer.close(source)

    destination = transfer!(dir, index, 2)
    revocation = copy!(marker, Path.join(dir, "revocation-1"))
    transfer = copy!(destination, Path.join(dir, "transfer-1"))
    {:ok, receiver} = Writer.open(destination, host(dir, 2))
    assert {:ok, accepted} = Writer.accept(receiver, revocation, transfer)
    assert accepted["body"]["ownership_epoch"] == 2
    assert accepted["body"]["relinquishment_head"]["digest"] == relinquished["digest"]
    concept = head_line(accepted)
    assert {:ok, _} = Writer.admit(receiver, concept, selection(["a"], @first), :new)
    # Both simulated hosts share this machine's loopback port, so each holds
    # the lock in turn; distinct hosts would each hold their own.
    :ok = Writer.close(receiver)

    {:ok, stale} = Writer.open(index, host(dir, 1))

    assert Writer.admit(stale, concept, selection(["a"], @first), :new) ==
             {:error, :attempt_handoff_pending}

    :ok = Writer.close(stale)
    {:ok, receiver} = Writer.open(destination, host(dir, 2))

    assert {:ok, %{marker: back_marker}} =
             Writer.relinquish(
               receiver,
               "writer-1",
               "host-1",
               "handoff-2",
               Path.join(dir, "quiescence-2")
             )

    File.cp!(destination, index)
    {:ok, returned} = Writer.open(index, host(dir, 1))
    back = copy!(back_marker, Path.join(dir, "revocation-2"))
    transfer = copy!(index, Path.join(dir, "transfer-2"))
    assert {:ok, regained} = Writer.accept(returned, back, transfer)
    assert regained["body"]["ownership_epoch"] == 3
    assert {:ok, _} = Writer.admit(returned, head_line(regained), selection(["a"], @first), :new)
    :ok = Writer.close(returned)

    {:ok, gone} = Writer.open(destination, host(dir, 2))

    assert Writer.admit(gone, "", selection(["a"], @first), :new) ==
             {:error, :attempt_handoff_pending}
  end

  # Concept: the closest available stand-in for two machines. Technical depth:
  # each host is its own operating-system VM with its own host identity,
  # marker directory and index copy; only bytes move between them. Both VMs
  # share this machine's loopback port and filesystem namespace, so this does
  # not prove exclusion or evidence paths across real machines.
  test "two OS-process hosts hand off through transferred bytes only", %{dir: dir} do
    a = Path.join(dir, "host-a")
    b = Path.join(dir, "host-b")
    for root <- [a, b], do: File.mkdir_p!(Path.join(root, "markers"))

    host_a = %{
      "writer_id" => "writer-a",
      "host_id" => "host-a",
      "marker_dir" => Path.join(a, "markers")
    }

    host_b = %{
      "writer_id" => "writer-b",
      "host_id" => "host-b",
      "marker_dir" => Path.join(b, "markers")
    }

    index_a = Path.join(a, "attempts.jsonl")
    index_b = Path.join(b, "attempts.jsonl")
    selection = selection(["a"], @first)

    source =
      vm("""
      #{prelude()}
      {:ok, w} = Writer.create(#{lit(index_a)}, #{lit(@campaign)}, #{lit(host_a)})
      {:ok, %{marker: marker}} = Writer.relinquish(w, "writer-b", "host-b", "handoff-ab", #{lit(Path.join(a, "quiescence"))})
      IO.puts("MARKER " <> marker)
      """)

    "MARKER " <> marker = line!(source)
    assert_receive {^source, {:exit_status, 0}}, 30_000

    # The transfer: exact bytes of the index, its lock record and the marker.
    File.write!(index_b, File.read!(index_a))
    File.write!(index_b <> ".lock", File.read!(index_a <> ".lock"))
    File.write!(Path.join(b, "revocation"), File.read!(marker))
    File.write!(Path.join(b, "transfer"), File.read!(index_a))

    destination =
      vm("""
      #{prelude()}
      {:ok, w} = Writer.open(#{lit(index_b)}, #{lit(host_b)})
      {:ok, accepted} = Writer.accept(w, #{lit(Path.join(b, "revocation"))}, #{lit(Path.join(b, "transfer"))})
      IO.puts("EPOCH " <> Integer.to_string(accepted["body"]["ownership_epoch"]))
      IO.puts("ADMIT " <> inspect(Writer.admit(w, "", #{lit(selection)}, :new)))
      """)

    assert line!(destination) == "EPOCH 2"
    assert line!(destination) == "ADMIT {:error, :committed_attempt_head_unavailable}"
    assert_receive {^destination, {:exit_status, 0}}, 30_000

    stale =
      vm("""
      #{prelude()}
      {:ok, w} = Writer.open(#{lit(index_a)}, #{lit(host_a)})
      IO.puts("ADMIT " <> inspect(Writer.admit(w, "", #{lit(selection)}, :new)))
      """)

    assert line!(stale) == "ADMIT {:error, :attempt_handoff_pending}"
    assert_receive {^stale, {:exit_status, 0}}, 30_000
    refute File.read!(index_a) == File.read!(index_b)
  end

  test "an interrupted or unverifiable handoff fences both hosts until it resolves",
       %{dir: dir, index: index} do
    {writer, _} = created!(dir, index)
    stale_copy = copy!(index, Path.join(dir, "pre-handoff"))
    copy!(index <> ".lock", stale_copy <> ".lock")

    {:ok, %{marker: marker}} =
      Writer.relinquish(writer, "writer-2", "host-2", "handoff-1", Path.join(dir, "q"))

    File.rm!(marker)

    destination = transfer!(dir, index, 2)
    transfer = copy!(destination, Path.join(dir, "transfer"))
    {:ok, receiver} = Writer.open(destination, host(dir, 2))

    assert {:unavailable, %{member: "source_revocation"}} =
             Writer.accept(receiver, Path.join(dir, "absent-marker"), transfer)

    assert Writer.admit(receiver, "", selection(["a"], @first), :new) ==
             {:error, :attempt_handoff_pending}

    :ok = Writer.close(receiver)
    {:ok, source} = Writer.open(index, host(dir, 1))

    assert Writer.relinquish(source, "writer-2", "host-2", "handoff-other", Path.join(dir, "q2")) ==
             {:error, :attempt_handoff_pending}

    :ok = Writer.close(source)
    {:ok, source} = Writer.open(index, host(dir, 1))

    assert {:ok, %{marker: ^marker}} =
             Writer.relinquish(source, "writer-2", "host-2", "handoff-1", Path.join(dir, "q"))

    revocation = copy!(marker, Path.join(dir, "revocation"))
    {:ok, receiver} = Writer.open(destination, host(dir, 2))

    File.write!(transfer, File.read!(transfer) <> "x")
    assert {:unavailable, %{member: "transfer"}} = Writer.accept(receiver, revocation, transfer)
    File.write!(transfer, File.read!(destination))
    :ok = Writer.close(receiver)

    {:ok, early} = Writer.open(stale_copy, host(dir, 2))
    assert Writer.accept(early, revocation, transfer) == {:error, :attempt_handoff_unavailable}

    assert Writer.admit(early, "", selection(["a"], @first), :new) ==
             {:error, :not_current_attempt_writer}

    :ok = Writer.close(early)

    {:ok, receiver} = Writer.open(destination, host(dir, 2))
    assert {:ok, _} = Writer.accept(receiver, revocation, transfer)
    :ok = Writer.close(receiver)

    File.cp!(stale_copy, index)
    {:ok, restored} = Writer.open(index, host(dir, 1))
    [_, designation] = records(index)

    assert Writer.admit(restored, head_line(designation), selection(["a"], @first), :new) ==
             {:error, :relinquishment_marker_unmatched}
  end

  test "an active case or admitted lane is not quiescent and cannot be relinquished",
       %{dir: dir, index: index} do
    {writer, concept} = created!(dir, index)
    {:ok, _} = Writer.admit(writer, concept, selection(["a"], @first), :new)
    q = Path.join(dir, "q")

    assert Writer.relinquish(writer, "writer-2", "host-2", "h", q) ==
             {:error, :attempt_case_active}

    {:ok, _} = Writer.append(writer, started(dir, "a", @first))
    :ok = Writer.close(writer)
    {:ok, writer} = Writer.open(index, host(dir, 1))

    assert Writer.relinquish(writer, "writer-2", "host-2", "h", q) ==
             {:error, :attempt_case_active}

    refute File.exists?(q)
  end

  test "records carrying a supplied secret value refuse and leave the index unchanged",
       %{dir: dir, index: index} do
    secret = "sk-m7-redaction-canary"
    created!(dir, index) |> elem(0) |> Writer.close()
    {:ok, writer} = Writer.open(index, host(dir, 1), secrets: [secret, ""])
    [_, designation] = records(index)
    {:ok, _} = Writer.admit(writer, head_line(designation), selection(["a"], @first), :new)
    before = File.read!(index)
    leaking = started(dir, "a", @first) |> Map.put("evidence", [ref(dir, "path-#{secret}")])
    assert Writer.append(writer, leaking) == {:error, :attempt_record_contains_secret}
    assert File.read!(index) == before
    refute File.read!(index) =~ secret
    assert {:ok, _} = Writer.append(writer, started(dir, "a", @first))
  end

  defp failed_lane!(writer, dir, concept, mechanical, verdict, reviewer) do
    {:ok, _} = Writer.admit(writer, concept, selection(["a"], @first), :new)
    {:ok, _} = Writer.append(writer, started(dir, "a", @first))
    completed = completed(dir, "a", @first, mechanical)
    {:ok, _} = Writer.append(writer, completed)
    {:ok, review} = Writer.append(writer, reviewed(dir, completed, verdict, reviewer))
    head_line(review)
  end

  defp created!(dir, index) do
    File.mkdir_p!(Path.join(dir, "markers-1"))
    {:ok, writer} = Writer.create(index, @campaign, host(dir, 1))
    [_, designation] = records(index)
    {writer, head_line(designation)}
  end

  defp transfer!(dir, index, host) do
    root = Path.join(dir, "host-#{host}")
    File.mkdir_p!(Path.join(dir, "markers-#{host}"))
    File.mkdir_p!(root)
    destination = Path.join(root, "attempts.jsonl")
    File.cp!(index, destination)
    File.cp!(index <> ".lock", destination <> ".lock")
    destination
  end

  defp copy!(source, target) do
    File.cp!(source, target)
    target
  end

  defp host(dir, n),
    do: %{
      "writer_id" => "writer-#{n}",
      "host_id" => "host-#{n}",
      "marker_dir" => Path.join(dir, "markers-#{n}")
    }

  defp tuple, do: %{"writer_id" => "writer-1", "host_id" => "host-1", "ownership_epoch" => 1}

  defp selection(keys, candidate) do
    %{
      "candidate_sha" => candidate,
      "lane_id" => "m7-provider",
      "logical_matrix_id" => nil,
      "manifest_digest" => @digest,
      "cases" =>
        Enum.map(
          keys,
          &%{"case_key" => &1, "subcase_key" => nil, "specification_digest" => @digest}
        )
    }
  end

  defp case_body(key, candidate, state, members) do
    Map.merge(
      %{
        "kind" => "case",
        "version" => 1,
        "manifest_digest" => @digest,
        "candidate_sha" => candidate,
        "lane_id" => "m7-provider",
        "logical_matrix_id" => nil,
        "case_key" => key,
        "subcase_key" => nil,
        "specification_digest" => @digest,
        "attempt_id" => nil,
        "state" => state,
        "mechanical_result" => nil,
        "verdict" => nil,
        "evidence" => nil,
        "diagnosis" => nil,
        "disposition" => nil,
        "reviewer_id" => nil,
        "authorized_candidate_sha" => nil,
        "authorization_evidence" => nil
      },
      members
    )
  end

  defp attempt(key, candidate), do: "attempt-#{key}-#{binary_part(candidate, 0, 4)}"

  defp started(dir, key, candidate),
    do:
      case_body(key, candidate, "started", %{
        "attempt_id" => attempt(key, candidate),
        "evidence" => [ref(dir, "path-#{key}-#{candidate}")]
      })

  defp completed(dir, key, candidate, mechanical) do
    evidence =
      if mechanical == "evidence_incomplete_post_dispatch",
        do: nil,
        else: [ref(dir, "result-#{key}-#{candidate}")]

    case_body(key, candidate, "completed", %{
      "attempt_id" => attempt(key, candidate),
      "mechanical_result" => mechanical,
      "evidence" => evidence
    })
  end

  defp pre_dispatch(dir, key, candidate),
    do:
      case_body(key, candidate, "not_dispatched", %{
        "mechanical_result" => "evidence_incomplete_pre_dispatch",
        "evidence" => [ref(dir, "preflight-#{key}-#{candidate}")]
      })

  defp reviewed(dir, completed, verdict, reviewer) do
    Map.merge(completed, %{
      "state" => "reviewed",
      "verdict" => verdict,
      "reviewer_id" => reviewer,
      "diagnosis" => if(verdict == "pass", do: nil, else: ref(dir, "diagnosis-#{verdict}"))
    })
  end

  defp authorized(dir, reviewed, candidate) do
    reviewed
    |> Map.drop(~w(writer_id host_id ownership_epoch))
    |> Map.merge(%{
      "state" => "authorized_next_candidate",
      "authorized_candidate_sha" => candidate,
      "disposition" => ref(dir, "disposition-#{candidate}"),
      "authorization_evidence" => ref(dir, "authorization-#{candidate}")
    })
  end

  defp ref(dir, name) do
    path = Path.join(dir, name)
    content = "content:" <> name
    File.write!(path, content)

    %{
      "reference" => path,
      "sha256" => Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    }
  end

  defp records(index) do
    index
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      {:ok, record} = Events.decode(line)
      record
    end)
  end

  defp last_line(index), do: index |> records() |> List.last() |> encoded()

  defp encoded(record) do
    {:ok, line, ^record} =
      Frames.encode(
        record["campaign_id"],
        record["sequence"],
        record["previous_digest"],
        record["body"]
      )

    line
  end

  defp head_line(record),
    do: "index-head: #{record["campaign_id"]} #{record["sequence"]} #{record["digest"]}"

  defp prelude, do: "alias Mix.Tasks.Loopex.M7Evidence.AttemptWriter, as: Writer"
  defp lit(term), do: inspect(term, limit: :infinity, printable_limit: :infinity)

  defp open_and_hold(index, identity) do
    """
    #{prelude()}
    case Writer.open(#{lit(index)}, #{lit(identity)}) do
      {:ok, w} ->
        IO.puts("OPEN ok")
        ref = Process.monitor(w)

        Stream.repeatedly(fn -> IO.read(:stdio, :line) end)
        |> Enum.reduce_while(nil, fn
          "crash\\n", _ ->
            Process.exit(w, :kill)
            receive do: ({:DOWN, ^ref, _, _, _} -> IO.puts("RELEASED"))
            {:cont, nil}

          "alive\\n", _ ->
            IO.puts("ALIVE")
            {:cont, nil}

          _, _ ->
            {:halt, nil}
        end)

      {:error, reason} ->
        IO.puts("OPEN error " <> Atom.to_string(reason))
        IO.read(:stdio, :line)
    end
    """
  end

  # Concept: each child is a separate operating-system VM loading this build.
  # Technical depth: ERL_LIBS exposes the compiled umbrella applications; the
  # child exits when its standard input closes.
  defp vm(code) do
    libs = :loopex_cli |> :code.lib_dir() |> to_string() |> Path.dirname()

    Port.open({:spawn_executable, System.find_executable("elixir")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 65_536},
      args: ["-e", code],
      env: [{~c"ERL_LIBS", String.to_charlist(libs)}]
    ])
  end

  defp line!(vm) do
    receive do
      {^vm, {:data, {:eol, line}}} -> line
      {^vm, {:exit_status, status}} -> flunk("child VM exited #{status}")
    after
      60_000 -> flunk("child VM produced no line")
    end
  end

  defp stop_vm(vm) do
    Port.command(vm, "quit\n")

    receive do
      {^vm, {:exit_status, _}} -> :ok
    after
      60_000 -> flunk("child VM did not exit")
    end
  end
end
