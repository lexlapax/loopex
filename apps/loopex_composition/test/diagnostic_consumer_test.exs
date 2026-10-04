defmodule LoopexComposition.DiagnosticConsumerTest do
  use ExUnit.Case, async: true

  alias LoopexComposition.DiagnosticConsumer

  test "settings submission preserves caller ownership and abandons late reply aliases" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    rows = [setting("/paths/workspace", "/workspace", "flag")]

    outsider =
      Task.async(fn ->
        assert :ok = DiagnosticConsumer.settings_report(consumer, rows)
        GenServer.call(consumer, {:settings_report, rows})
      end)

    assert Task.await(outsider) == {:error, :not_diagnostic_owner}

    assert DiagnosticConsumer.status(consumer).counts.diagnostic ==
             %{emitted: 0, dropped: 0, unconfirmed: 0}

    refute_receive {:device_write, _, _}, 0

    :ok = :sys.suspend(consumer)
    assert :ok = DiagnosticConsumer.settings_report(consumer, rows)
    assert Process.alive?(consumer)
    refute_receive {:device_write, _, _}, 0
    :ok = :sys.resume(consumer)
    assert DiagnosticConsumer.status(consumer).active
    assert_receive {:device_write, _, bytes}
    assert {:ok, ^rows} = decode_rows(bytes)

    assert GenServer.call(consumer, {:settings_report, rows}) ==
             {:error, :invalid_settings_report}

    receive do
      {ref, _} when is_reference(ref) -> flunk("settings submission left a late request reply")
    after
      0 -> :ok
    end

    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.diagnostic == %{emitted: 0, dropped: 0, unconfirmed: 1}
  end

  test "settings retain exact paths, decimal quantities, indexed order and committed origins" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

      rows = [
        setting("/paths/workspace", "/猫/quote\"/line\n/tab\t", "flag"),
        setting("/session/max_tokens", Integer.to_string(Integer.pow(2, 150)), "committed"),
        setting("/session/skill_dirs/0", "/first", "file#/session/skill_dirs/0"),
        setting("/session/skill_dirs/1", "/second", "env"),
        setting("/trace/enabled", false, "default"),
        setting(
          "/providers/openai",
          %{
            "provider" => "openai",
            "reference_form" => "environment_reference",
            "reference_valid" => true,
            "unavailable_commands" => []
          },
          "file#/providers/openai/credential/env"
        ),
        setting(
          "/providers/anthropic",
          %{
            "provider" => "anthropic",
            "reference_form" => "credential_free",
            "reference_valid" => true,
            "unavailable_commands" => ["chat"]
          },
          "file#/providers/anthropic/credential/none"
        )
      ]

      assert :ok = DiagnosticConsumer.settings_report(consumer, rows)
      await_idle(consumer)
      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts.diagnostic == %{emitted: length(rows), dropped: 0, unconfirmed: 0}
      {"", output} = StringIO.contents(device)
      assert {:ok, ^rows} = decode_rows(output)
      assert length(:binary.matches(output, "\n")) == length(rows)
      assert output =~ "\\n" and output =~ "\\t" and output =~ "\\\""
    end)
  end

  test "harness settings admit only a closed policy identity with matching provenance" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

      policy = %{
        "origin" => "harness",
        "id" => "m7.fixture:m7.repair:captured",
        "revision" => "1",
        "fixture_manifest_digest" => String.duplicate("a", 64)
      }

      admitted = setting("/policy_identity", policy, "harness")

      rejected = [
        setting("/policy_identity", policy, "committed"),
        setting("/policy_identity", %{policy | "origin" => "registry"}, "harness"),
        setting("/policy_identity", %{policy | "origin" => "registry"}, "committed"),
        setting("/policy_identity", %{policy | "fixture_manifest_digest" => nil}, "harness"),
        setting(
          "/policy_identity",
          %{policy | "fixture_manifest_digest" => "bad-canary"},
          "harness"
        ),
        setting("/policy_identity", Map.put(policy, "pins", "private-canary"), "harness"),
        setting("/paths/workspace", "private-canary", "harness")
      ]

      assert :ok = DiagnosticConsumer.settings_report(consumer, rejected ++ [admitted])
      await_idle(consumer)
      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts.diagnostic == %{emitted: 1, dropped: length(rejected), unconfirmed: 0}
      {"", bytes} = StringIO.contents(device)
      assert {:ok, [^admitted]} = decode_rows(bytes)
      refute bytes =~ "canary"
    end)
  end

  test "settings exact JSON line ceiling drops oversized rows whole" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
      empty = setting("/paths/workspace", "", "committed")
      {:ok, framing} = LoopexProtocol.Frame.encode(empty)
      exact = %{empty | "value" => String.duplicate("x", 4_096 - IO.iodata_length(framing))}
      oversized = %{exact | "value" => exact["value"] <> "x"}
      escaped = %{empty | "value" => String.duplicate("\"", 2_048)}
      assert :ok = DiagnosticConsumer.settings_report(consumer, [exact, oversized, escaped])
      await_idle(consumer)
      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts.diagnostic == %{emitted: 1, dropped: 2, unconfirmed: 0}
      {"", bytes} = StringIO.contents(device)
      assert byte_size(bytes) == 4_096
      assert {:ok, [^exact]} = decode_rows(bytes)
    end)
  end

  test "settings reject private captures, credential forms and malformed presentation rows" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

      provider = %{
        "provider" => "openai",
        "reference_form" => "environment_reference",
        "reference_valid" => true,
        "unavailable_commands" => []
      }

      rejected = [
        setting("/session/instructions/base", "instruction-canary", "committed"),
        setting("/roles/reviewer/prompt", "role-prompt-canary", "flag"),
        setting("/session/model_capabilities", "capability-canary", "committed"),
        setting("/session/provider_mapping", "mapping-canary", "committed"),
        setting("/continuation", "continuation-canary", "committed"),
        setting("/providers/openai/credential/env", "ENV_NAME_CANARY", "flag"),
        setting("/providers/openai", Map.put(provider, "env", "ENV_NAME_CANARY"), "flag"),
        setting(
          "/providers/openai",
          %{provider | "reference_form" => "secret-value-canary"},
          "flag"
        ),
        setting(
          "/providers/openai",
          %{provider | "unavailable_commands" => ["secret-value-canary"]},
          "flag"
        ),
        setting("/session/max_tokens", 123, "flag"),
        setting("/session/max_tokens", "00123", "flag"),
        setting("/paths/workspace", <<255>>, "flag"),
        setting("/trace/modules/64", "Loopex.Runtime.Control", "flag"),
        setting("/session/skill_dirs", ["array-canary"], "flag"),
        setting("/paths/workspace", "/safe", "unknown-origin-canary"),
        Map.put(setting("/paths/workspace", "/safe", "flag"), "extra", "extra-canary")
      ]

      admitted = setting("/session/model", "openai:confirmed", "committed")
      assert :ok = DiagnosticConsumer.settings_report(consumer, rejected ++ [admitted])
      await_idle(consumer)
      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts.diagnostic == %{emitted: 1, dropped: length(rejected), unconfirmed: 0}
      {"", bytes} = StringIO.contents(device)
      refute bytes =~ "canary"
      assert {:ok, [^admitted]} = decode_rows(bytes)
      refute inspect(:sys.get_status(device)) =~ "ENV_NAME_CANARY"
    end)
  end

  test "settings share the bounded diagnostic queue and writer cleanup accounting" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    rows = for i <- 1..300, do: setting("/session/max_tokens", Integer.to_string(i), "flag")
    assert :ok = DiagnosticConsumer.settings_report(consumer, rows)
    view = DiagnosticConsumer.status(consumer)
    assert view.active and view.pending == 256
    assert view.counts.diagnostic == %{emitted: 0, dropped: 43, unconfirmed: 0}
    assert_receive {:device_write, writer, bytes}
    assert {:ok, [first]} = decode_rows(bytes)
    assert first == hd(rows)
    [^consumer, supervisor, ^writer] = elem(DiagnosticConsumer.owned_processes(consumer), 1)
    monitors = Map.new([consumer, supervisor, writer], &{&1, Process.monitor(&1)})
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.diagnostic == %{emitted: 0, dropped: 299, unconfirmed: 1}

    for {pid, ref} <- monitors do
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      refute Process.alive?(pid)
    end
  end

  test "broken settings IO is unconfirmed and shares ordinary diagnostic failure sealing" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

    rows = [
      setting("/session/model", "openai:confirmed", "committed"),
      setting("/session/reasoning", "default", "committed")
    ]

    assert :ok = DiagnosticConsumer.settings_report(consumer, rows)
    assert DiagnosticConsumer.status(consumer).pending == 1
    assert_receive {:device_write, _, _}
    send(device, {:release, {:error, :broken}})
    await_failure(consumer)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
    assert DiagnosticConsumer.status(consumer).counts.trace.dropped == 1
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.diagnostic == %{emitted: 0, dropped: 1, unconfirmed: 1}
  end

  defp setting(pointer, value, origin),
    do: %{"setting" => pointer, "value" => value, "origin" => origin}

  defp decode_rows(bytes) do
    rows = String.split(bytes, "\n", trim: true)

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, decoded} ->
      case LoopexProtocol.Frame.decode(row, 4_096) do
        {:ok, value} -> {:cont, {:ok, decoded ++ [value]}}
        error -> {:halt, error}
      end
    end)
  end

  test "supervised startup binds the explicit host and asynchronous closing seals dispatch" do
    device = device()
    consumer = start_supervised!({DiagnosticConsumer, {self(), device, 1_000}})
    assert {:ok, [^consumer, supervisor]} = DiagnosticConsumer.owned_processes(consumer)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
    assert_receive {:device_write, writer, _}
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    ref = make_ref()
    consumer_ref = Process.monitor(consumer)
    supervisor_ref = Process.monitor(supervisor)
    writer_ref = Process.monitor(writer)

    assert {:ok, [^consumer, ^supervisor, ^writer]} =
             DiagnosticConsumer.begin_close(consumer, ref, deadline())

    assert_receive {:diagnostic_consumer_closed, ^consumer, ^ref, {:ok, final}}
    assert final.counts.trace == %{emitted: 0, dropped: 0, unconfirmed: 1}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 1, unconfirmed: 0}
    refute Process.alive?(writer)
    refute Process.alive?(supervisor)
    assert_receive {:DOWN, ^writer_ref, :process, ^writer, _}
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, _}
    assert_receive {:DOWN, ^consumer_ref, :process, ^consumer, :normal}
    refute_receive {:device_write, _, _}, 0
    refute_receive {:diagnostic_consumer_closed, ^consumer, ^ref, _}, 0
  end

  test "private registration and asynchronous shutdown remain owner-only" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

    task =
      Task.async(fn ->
        {DiagnosticConsumer.owned_processes(consumer),
         DiagnosticConsumer.begin_close(consumer, make_ref(), deadline())}
      end)

    assert Task.await(task) == {{:error, :not_diagnostic_owner}, {:error, :not_diagnostic_owner}}
    assert DiagnosticConsumer.status(consumer).failure == nil
    assert {:ok, _} = DiagnosticConsumer.close(consumer, deadline())
  end

  test "observed mailbox growth stays distinct from the proved explicit output bound" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    assert_receive {:device_write, _, _}
    :ok = :sys.suspend(consumer)
    for _ <- 1..6_000, do: send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    assert {:message_queue_len, mailbox} = Process.info(consumer, :message_queue_len)
    assert mailbox >= 6_000
    :ok = :sys.resume(consumer)
    view = DiagnosticConsumer.status(consumer)
    assert view.pending == 256 and view.active
    assert view.counts.diagnostic == %{emitted: 0, dropped: 5_744, unconfirmed: 0}
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.diagnostic == %{emitted: 0, dropped: 6_000, unconfirmed: 1}
  end

  test "a stalled writer holds one entry while the drain consumes and counts excess by kind" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call", "function" => "first"}})
    # Concept: pressure accounting starts with an actually dispatched writer.
    # Technical depth: the same-sender status request follows the diagnostic and
    # confirms rendering/registration before the unchanged device receive wait.
    assert %{active: true, pending: 0, failure: nil} = DiagnosticConsumer.status(consumer)
    assert_receive {:device_write, worker, _}

    for i <- 1..128 do
      send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call", "number" => i}})
      send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "number" => i}})
    end

    for _ <- 1..23, do: send(consumer, {:loopex_diagnostic, %{"kind" => "trace_dropped"}})
    for _ <- 1..17, do: send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})

    view = DiagnosticConsumer.status(consumer)
    assert view.pending == 256
    assert view.active
    assert view.counts.trace == %{emitted: 0, dropped: 23, unconfirmed: 0}
    assert view.counts.diagnostic == %{emitted: 0, dropped: 17, unconfirmed: 0}
    assert is_integer(view.mailbox) and view.mailbox >= 0
    refute_receive {:device_write, _, _}, 0

    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.pending == 0 and final.active == false
    assert final.counts.trace == %{emitted: 0, dropped: 151, unconfirmed: 1}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 145, unconfirmed: 0}
    refute Process.alive?(worker)
    refute Process.alive?(consumer)
  end

  test "each acknowledged write and worker termination precedes the next entry" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call", "function" => "first"}})
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "message" => "second"}})
    assert_receive {:device_write, first, bytes}
    assert bytes =~ "first"
    assert DiagnosticConsumer.status(consumer).pending == 1
    refute_receive {:device_write, _, _}, 0
    send(device, {:release, :ok})
    assert_receive {:device_write, second, bytes}
    assert bytes =~ "second"
    refute Process.alive?(first)
    assert DiagnosticConsumer.status(consumer).counts.trace.emitted == 1
    send(device, {:release, :ok})
    await_idle(consumer)
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.trace == %{emitted: 1, dropped: 0, unconfirmed: 0}
    assert final.counts.diagnostic == %{emitted: 1, dropped: 0, unconfirmed: 0}
    refute Process.alive?(second)
  end

  test "a sustained ordered stream leaves no writer overlap or task-capacity race" do
    StringIO.open("", [encoding: :latin1], fn device ->
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

      for i <- 1..200 do
        send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "number" => i}})
        await_idle(consumer)
      end

      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts.diagnostic == %{emitted: 200, dropped: 0, unconfirmed: 0}
      {"", output} = StringIO.contents(device)
      assert length(:binary.matches(output, "\n")) == 200
    end)
  end

  test "rendering is bounded and redacted before IO or process status inspection" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

    entry = %{
      "kind" => "trace_call",
      "credential_ref" => "credential-canary",
      "arguments" => "arguments-canary",
      "text" => "text-canary",
      "wide" => Enum.to_list(1..1_000),
      "message" => String.duplicate("猫", 4_000)
    }

    send(consumer, {:loopex_diagnostic, entry})
    assert_receive {:device_write, _, bytes}
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary", "message" => "buffer-canary"}})
    assert DiagnosticConsumer.status(consumer).pending == 1
    assert byte_size(bytes) <= 4_096
    assert String.ends_with?(bytes, "\n")

    for canary <- ["credential-canary", "arguments-canary", "text-canary"] do
      refute bytes =~ canary
      refute inspect(:sys.get_status(consumer)) =~ canary
    end

    refute inspect(:sys.get_status(consumer)) =~ "buffer-canary"
    assert {:ok, _} = DiagnosticConsumer.close(consumer, deadline())
  end

  test "private supervisor loss seals delivery and leaves the drain responsive" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
    assert_receive {:device_write, worker, _}
    worker_ref = Process.monitor(worker)
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    supervisor = :sys.get_state(consumer).supervisor
    Process.exit(supervisor, :kill)
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    wait_for(consumer, fn view -> view.failure != nil and view.active == false end)
    assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
    assert final.counts.trace == %{emitted: 0, dropped: 0, unconfirmed: 1}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 1, unconfirmed: 0}
  end

  test "broken IO and writer death are unconfirmed and seal only diagnostic delivery" do
    for disposition <- [:broken, :killed] do
      device = device()
      {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
      send(consumer, {:loopex_diagnostic, %{"kind" => "trace_call"}})
      assert_receive {:device_write, worker, _}
      send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})

      case disposition do
        :broken -> send(device, {:release, {:error, :private_device_error}})
        :killed -> Process.exit(worker, :kill)
      end

      await_failure(consumer)
      send(consumer, {:loopex_diagnostic, %{"kind" => "trace_dropped"}})
      view = DiagnosticConsumer.status(consumer)
      assert view.failure == :diagnostic_output_failed
      assert view.counts.trace == %{emitted: 0, dropped: 1, unconfirmed: 1}
      assert view.counts.diagnostic == %{emitted: 0, dropped: 1, unconfirmed: 0}
      assert view.pending == 0 and view.active == false
      assert {:ok, final} = DiagnosticConsumer.close(consumer, deadline())
      assert final.counts == view.counts
      refute inspect(final) =~ "private_device_error"
      refute_receive {:device_write, _, _}, 0
    end
  end

  test "only the creating host can inspect or close the drain" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)

    task =
      Task.async(fn ->
        {DiagnosticConsumer.status(consumer), DiagnosticConsumer.close(consumer, deadline())}
      end)

    assert Task.await(task) == {{:error, :not_diagnostic_owner}, {:error, :not_diagnostic_owner}}
    assert Process.alive?(consumer)
    assert {:ok, _} = DiagnosticConsumer.close(consumer, deadline())
  end

  test "owner death and abrupt drain loss terminate the private supervisor and blocked writer" do
    for disposition <- [:owner, :drain] do
      device = device()
      parent = self()

      owner =
        spawn(fn ->
          Process.flag(:trap_exit, true)
          {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
          send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
          send(parent, {:consumer, consumer})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:consumer, consumer}
      assert_receive {:device_write, worker, _}
      state = :sys.get_state(consumer)
      supervisor = state.supervisor
      worker_ref = Process.monitor(worker)
      supervisor_ref = Process.monitor(supervisor)
      consumer_ref = Process.monitor(consumer)

      cutoff = System.monotonic_time(:millisecond) + 1_000

      case disposition do
        :owner ->
          send(owner, :stop)

        :drain ->
          Process.exit(consumer, :kill)
          send(owner, :stop)
      end

      for {pid, monitor} <- [
            {worker, worker_ref},
            {supervisor, supervisor_ref},
            {consumer, consumer_ref}
          ] do
        remaining = max(cutoff - System.monotonic_time(:millisecond), 0)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, remaining
      end

      assert System.monotonic_time(:millisecond) <= cutoff
    end
  end

  test "an expired shared deadline refuses to invent joined cleanup" do
    device = device()
    {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
    send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
    assert_receive {:device_write, worker, _}
    worker_ref = Process.monitor(worker)
    started = System.monotonic_time(:millisecond)
    reply = DiagnosticConsumer.close(consumer, started - 1)
    assert System.monotonic_time(:millisecond) - started < 1_000
    assert {:error, :cleanup_unknown, final} = reply
    assert final.counts.diagnostic.unconfirmed == 1
    assert final.counts.diagnostic.emitted == 0
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
  end

  test "closing asks the supervisor to terminate its blocked writer before collecting joins" do
    parent = self()
    device = device()

    owner =
      spawn(fn ->
        Process.flag(:trap_exit, true)
        {:ok, consumer} = DiagnosticConsumer.start_link(device, 1_000)
        send(consumer, {:loopex_diagnostic, %{"kind" => "ordinary"}})
        send(parent, {:consumer, consumer})

        receive do
          :close ->
            send(parent, :closing)
            send(parent, {:closed, DiagnosticConsumer.close(consumer, deadline())})
        end
      end)

    assert_receive {:consumer, consumer}
    assert_receive {:device_write, worker, _}
    supervisor = :sys.get_state(consumer).supervisor
    :sys.get_state(supervisor)
    worker_ref = Process.monitor(worker)
    supervisor_ref = Process.monitor(supervisor)
    true = :erlang.suspend_process(supervisor)

    try do
      send(owner, :close)
      assert_receive :closing
      await_supervisor_shutdown(supervisor, deadline())
      assert Process.alive?(worker)
    after
      :erlang.resume_process(supervisor)
    end

    assert_receive {:closed, {:ok, final}}
    assert final.counts.diagnostic == %{emitted: 0, dropped: 0, unconfirmed: 1}
    assert_receive {:DOWN, ^worker_ref, :process, ^worker, _}
    assert_receive {:DOWN, ^supervisor_ref, :process, ^supervisor, :normal}
  end

  defp await_supervisor_shutdown(supervisor, cutoff) do
    case Process.info(supervisor, :message_queue_len) do
      {:message_queue_len, count} when count > 0 ->
        :ok

      _ ->
        assert System.monotonic_time(:millisecond) < cutoff
        Process.sleep(1)
        await_supervisor_shutdown(supervisor, cutoff)
    end
  end

  defp await_idle(consumer) do
    wait_for(consumer, fn view -> view.pending == 0 and view.active == false end)
  end

  defp await_failure(consumer) do
    wait_for(consumer, fn view -> view.failure != nil end)
  end

  defp wait_for(consumer, predicate, cutoff \\ deadline()) do
    view = DiagnosticConsumer.status(consumer)

    if predicate.(view) do
      view
    else
      assert System.monotonic_time(:millisecond) < cutoff
      Process.sleep(1)
      wait_for(consumer, predicate, cutoff)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 1_000

  defp device do
    parent = self()
    start_supervised!({Task, fn -> device_loop(parent) end}, id: make_ref())
  end

  defp device_loop(parent) do
    receive do
      {:io_request, from, ref, {:put_chars, _encoding, bytes}} ->
        send(parent, {:device_write, from, IO.iodata_to_binary(bytes)})
        receive do: ({:release, result} -> send(from, {:io_reply, ref, result}))
        device_loop(parent)
    end
  end
end
