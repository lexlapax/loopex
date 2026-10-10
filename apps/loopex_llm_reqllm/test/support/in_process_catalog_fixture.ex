Code.require_file("in_process_caller_wire_fixture.ex", __DIR__)

defmodule Loopex.LLM.ReqLLM.InProcessCatalogFixture.Adapter do
  @moduledoc false

  @key {__MODULE__, :fixture}
  @repo "/repos/loopex-fixture/catalog/releases"
  @index "/loopex-fixture/catalog/releases/download/catalog-index-fixture/snapshot-index-fixture.json"
  @snapshot "/loopex-fixture/catalog/releases/download/snapshot-fixture/snapshot.json"

  def install(owner, snapshot, token, mode) do
    :persistent_term.put(@key, %{owner: owner, snapshot: snapshot, token: token, mode: mode})
  end

  def clear, do: :persistent_term.erase(@key)

  def run(%Req.Request{} = request) do
    state = :persistent_term.get(@key)
    route = request.url.path

    case route do
      @repo ->
        auth_ok = Req.Request.get_header(request, "authorization") == ["Bearer " <> state.token]
        send(state.owner, {:catalog_route, :releases, auth_ok, self()})

        if state.mode in [:block, :fail_blocked] do
          receive do
            {:catalog_release, owner} when owner == state.owner -> :ok
          after
            10_000 -> raise "catalog fixture release missing"
          end
        end

        if state.mode in [:fail, :fail_blocked] do
          response(request, 500, "private-catalog-loader-sentinel")
        else
          release = %{
            "tag_name" => "catalog-index-fixture",
            "draft" => false,
            "assets" => [
              %{
                "name" => "snapshot-index-fixture.json",
                "browser_download_url" => "https://github.com" <> @index
              },
              %{
                "name" => "latest-fixture.json",
                "browser_download_url" =>
                  "https://github.com/loopex-fixture/catalog/releases/download/catalog-index-fixture/latest-fixture.json"
              }
            ]
          }

          response(request, 200, Jason.encode!([release]))
        end

      @index ->
        no_auth = Req.Request.get_header(request, "authorization") == []
        send(state.owner, {:catalog_route, :index, no_auth, self()})

        entry = %{
          "snapshot_id" => state.snapshot["snapshot_id"],
          "snapshot_url" => "https://github.com" <> @snapshot,
          "generated_at" => state.snapshot["generated_at"]
        }

        response(request, 200, Jason.encode!(%{"snapshots" => [entry]}))

      @snapshot ->
        no_auth = Req.Request.get_header(request, "authorization") == []
        send(state.owner, {:catalog_route, :snapshot, no_auth, self()})
        response(request, 200, LLMDB.Snapshot.encode(state.snapshot))

      _unexpected ->
        send(state.owner, {:unexpected_catalog_route, route})
        response(request, 404, "unexpected route")
    end
  end

  defp response(request, status, body) do
    {request,
     Req.Response.new(
       status: status,
       headers: [{"content-type", "application/json"}],
       body: body
     )}
  end
end

defmodule Loopex.LLM.ReqLLM.InProcessCatalogFixture.Admission do
  @moduledoc false
  @behaviour Loopex.LLM.ReqLLM.InProcess.Admission

  @impl true
  def request(
        {__MODULE__, owner, generation, _cell},
        {:stage_model, call, candidate, proof, _stop, start_proof} = operation,
        deadline
      ) do
    staging = make_ref()
    start = elem(start_proof, 1)
    custody = {:model_cleanup_custody, owner, generation, call, candidate, proof}
    send(candidate, {:model_custody_prepare, start, staging, deadline, __MODULE__, custody})

    receive do
      {:model_custody_prepared, ^candidate, ^staging, ^generation, ^call, ^proof} ->
        grant(generation, operation, staging, deadline)
    after
      1_000 -> {:error, :session_admission_closed}
    end
  end

  def request(
        {:model_cleanup_custody, _owner, generation, call, candidate, proof},
        {:retire_model, call, candidate, proof} = operation,
        deadline
      ),
      do: grant(generation, operation, make_ref(), deadline)

  def request({__MODULE__, _owner, generation, _cell}, operation, deadline),
    do: grant(generation, operation, make_ref(), deadline)

  defp grant(generation, operation, reference, deadline),
    do: {:ok, {:session_grant, generation, elem(operation, 0), self(), reference, deadline}}
end

defmodule Loopex.LLM.ReqLLM.InProcessCatalogFixture do
  @moduledoc """
  ## Concept

  Exercise host-selected cold LLMDB sources through the real Anthropic model
  path without using the network or a provider credential.

  ## Technical depth

  Each probe runs in a fresh VM. File and ReleaseStore sources use one verified
  fixture snapshot with a distinct identity. The source-local Req adapter
  returns real Req request/response pairs and reports only route names and
  token-match Booleans to its owner. The model call uses a separate tagged TLS
  pool and a synthetic selected provider key supplied at the call boundary.
  """

  import ExUnit.Assertions

  alias Loopex.LLM.ReqLLM.InProcess
  alias Loopex.LLM.ReqLLM.InProcessCatalogFixture.Adapter
  alias Loopex.LLM.ReqLLM.InProcessCatalogFixture.Admission
  alias Loopex.LLM.ReqLLM.InProcessCallerWireFixture, as: Wire
  alias Loopex.Model
  alias Loopex.Runtime.ProviderLifetime
  alias Loopex.Runtime.ProviderLifetime.Starter

  @model "anthropic:claude-haiku-4-5-20251001"
  @selected "synthetic-selected-provider-key"
  @github "synthetic-github-catalog-token"

  def run_in_child(mode) do
    root =
      Path.join(System.tmp_dir!(), "loopex-catalog-child-#{System.unique_integer([:positive])}")

    File.mkdir!(root)

    try do
      System.cmd(
        System.find_executable("elixir"),
        [
          "-pa",
          Path.join([Mix.Project.build_path(), "lib", "*", "ebin"]),
          "-r",
          __ENV__.file,
          "-e",
          "Loopex.LLM.ReqLLM.InProcessCatalogFixture.probe(#{inspect(mode)})"
        ],
        cd: root,
        stderr_to_stdout: true,
        env: [
          {"LOOPEX_HOME", root},
          {"GH_TOKEN", nil},
          {"GITHUB_TOKEN", nil},
          {"ANTHROPIC_API_KEY", nil},
          {"SSLKEYLOGFILE", nil},
          {"TIDEWAVE_REPL", nil}
        ]
      )
    after
      File.rm_rf!(root)
    end
  end

  def probe(mode) when mode in [:file, :gh, :github, :failure, :lock, :conformance] do
    {:ok, _} = Application.ensure_all_started(:req_llm)
    assert LLMDB.Catalog.snapshot() == nil
    assert Application.get_env(:req, :default_options, []) == []
    fixture_root = System.fetch_env!("LOOPEX_HOME")
    snapshot = snapshot()
    cert = trusted_ca(fixture_root)

    case mode do
      :file -> file_case(snapshot, cert, fixture_root)
      token when token in [:gh, :github] -> remote_case(snapshot, cert, fixture_root, token)
      :failure -> failure_case(snapshot, fixture_root)
      :lock -> lock_case(snapshot, fixture_root)
      :conformance -> conformance_case(cert)
    end
  end

  defp conformance_case(cert) do
    System.put_env("ANTHROPIC_API_KEY", @selected)
    direct_success(cert)
    IO.puts("IN_PROCESS_STREAMING_CONFORMANCE_PROVED")
  end

  defp snapshot do
    packaged =
      LLMDB.Snapshot.packaged_path()
      |> File.read!()
      |> Jason.decode!()

    provider = packaged["providers"]["anthropic"]
    model = provider["models"]["claude-haiku-4-5-20251001"]
    assert is_map(provider) and is_map(model)

    document =
      packaged
      |> Map.put("providers", %{
        "anthropic" =>
          provider
          |> Map.put("name", "Anthropic cold catalog fixture")
          |> Map.put("models", %{"claude-haiku-4-5-20251001" => model})
      })
      |> Map.put("generated_at", "2026-09-27T00:00:00Z")

    document = Map.put(document, "snapshot_id", LLMDB.Snapshot.snapshot_id(document))
    assert document["snapshot_id"] != packaged["snapshot_id"]
    assert {:ok, _} = LLMDB.Snapshot.prepare(document)
    document
  end

  defp overlay do
    %{
      catalog_witness: [
        name: "Catalog overlay fixture",
        models: %{"overlay-model" => %{capabilities: %{chat: true}}}
      ]
    }
  end

  defp configure(source) do
    Application.put_env(:llm_db, :snapshot_source, source)
    Application.put_env(:llm_db, :custom, overlay())
    Application.put_env(:llm_db, :allow, :all)
    Application.put_env(:llm_db, :deny, %{anthropic: ["not-used-*"]})
    Application.put_env(:llm_db, :prefer, [:anthropic])
    LLMDB.Config.get()
  end

  defp trusted_ca(root) do
    cert = Loopex.LLM.ReqLLM.InProcessTLSFixture.certificate()
    path = Path.join(root, "catalog-ca.pem")
    pem = :public_key.pem_encode(Enum.map(cert[:cacerts], &{:Certificate, &1, :not_encrypted}))
    File.write!(path, pem)
    :ok = :public_key.cacerts_load(String.to_charlist(path))
    cert
  end

  defp call(runtime, cert) do
    fixture = Wire.start(runtime, @model, Wire.wire(:anthropic, "catalog answer"), tls: cert)
    {result, fixture} = fixture |> Wire.begin() |> Wire.result()
    assert {:ok, %{text: "catalog answer", streamed: false}} = result
    assert [written] = fixture.writes
    assert written.line == "POST /v1/messages HTTP/1.1"
    assert written.headers["x-api-key"] == @selected
    refute Enum.any?(written.headers, fn {_name, value} -> String.contains?(value, @github) end)
    refute String.contains?(written.body, @github)
    Wire.stop(fixture)
  end

  defp catalog_state(config, snapshot) do
    assert LLMDB.Config.get() == config
    assert %{snapshot: loaded, epoch: epoch} = state = LLMDB.Catalog.get()
    assert is_integer(epoch) and epoch > 0
    assert loaded.meta.source_snapshot_id == snapshot["snapshot_id"]
    assert {:ok, _} = LLMDB.Catalog.model(:anthropic, "claude-haiku-4-5-20251001")
    assert {:ok, _} = LLMDB.Catalog.model(:catalog_witness, "overlay-model")
    assert loaded.prefer == [:anthropic]
    state
  end

  defp file_case(snapshot, cert, root) do
    path = Path.join(root, "host-selected-catalog.json")
    File.write!(path, LLMDB.Snapshot.encode(snapshot))
    assert {:ok, _} = LLMDB.Snapshot.read(path)
    config = configure({:file, path})
    assert config.snapshot_source == {:file, path}
    assert LLMDB.Catalog.snapshot() == nil
    System.put_env("ANTHROPIC_API_KEY", @selected)
    runtime = Wire.runtime()

    try do
      call(runtime, cert)
      state = catalog_state(config, snapshot)
      call(runtime, cert)
      assert LLMDB.Catalog.get() == state
      assert File.regular?(path)
      IO.puts("CATALOG_FILE_PROVED")
    after
      Wire.close_runtime(runtime)
    end
  end

  defp remote_case(snapshot, cert, root, token_source) do
    cache = Path.join(root, "remote-cache")
    assert :ok = File.mkdir!(cache)
    source = remote_source(cache)
    config = configure(source)
    assert config.snapshot_source == source
    assert LLMDB.Catalog.snapshot() == nil

    if token_source == :gh,
      do: System.put_env("GH_TOKEN", @github),
      else: System.put_env("GITHUB_TOKEN", @github)

    Adapter.install(self(), snapshot, @github, :block)
    runtime = Wire.runtime()
    parent = self()

    {first, first_monitor} =
      spawn_monitor(fn ->
        call(runtime, cert)
        send(parent, {:first_catalog_call_done, self()})
      end)

    try do
      assert_receive {:catalog_route, :releases, true, ^first}, 5_000
      assert System.get_env("ANTHROPIC_API_KEY") == nil
      System.put_env("ANTHROPIC_API_KEY", @selected)
      send(first, {:catalog_release, self()})
      assert_receive {:catalog_route, :index, true, ^first}, 5_000
      assert_receive {:catalog_route, :snapshot, true, ^first}, 5_000
      assert_receive {:first_catalog_call_done, ^first}, 5_000
      assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 1_000
      state = catalog_state(config, snapshot)
      cached = Path.join([cache, "snapshots", snapshot["snapshot_id"] <> ".json"])
      assert File.regular?(cached)
      assert {:ok, _} = LLMDB.Snapshot.read(cached)
      call(runtime, cert)
      assert LLMDB.Catalog.get() == state
      refute_receive {:catalog_route, _, _, _}, 50
      refute_receive {:unexpected_catalog_route, _}, 10

      marker =
        if token_source == :gh,
          do: "CATALOG_REMOTE_GH_PROVED",
          else: "CATALOG_REMOTE_GITHUB_PROVED"

      IO.puts(marker)
    after
      Adapter.clear()
      Wire.close_runtime(runtime)
    end
  end

  defp remote_source(cache) do
    {:github_releases,
     %{
       ref: :latest,
       repo: "loopex-fixture/catalog",
       cache_dir: cache,
       req_opts: [adapter: Adapter, max_retries: 0]
     }}
  end

  defp failure_case(snapshot, root) do
    listener = failure_listener()

    try do
      missing = Path.join(root, "missing-catalog.json")
      refute File.exists?(missing)
      configure({:file, missing})
      assert LLMDB.Catalog.snapshot() == nil
      assert System.get_env("ANTHROPIC_API_KEY") == nil

      traced_selected_key_absence(fn ->
        assert {:error, {:not_dispatched, "model_call_failed"}} =
                 managed_complete(listener.base, 5_000)
      end)

      assert LLMDB.Catalog.snapshot() == nil
      assert_no_model_connection(listener)

      cache = Path.join(root, "failed-release-cache")
      File.mkdir!(cache)
      configure(remote_source(cache))
      System.put_env("GH_TOKEN", @github)
      Adapter.install(self(), snapshot, @github, :fail)

      traced_selected_key_absence(fn ->
        result = managed_complete(listener.base, 5_000)
        assert result == {:error, {:not_dispatched, "model_call_failed"}}
        refute inspect(result) =~ "private-catalog-loader-sentinel"
      end)

      assert_receive {:catalog_route, :releases, true, _caller}, 1_000
      refute_receive {:catalog_route, _, _, _}, 50
      assert LLMDB.Catalog.snapshot() == nil
      assert Path.wildcard(Path.join([cache, "snapshots", "*.json"])) == []
      assert_no_model_connection(listener)

      # A failed cold load is not a cached failure. A separate managed edge
      # invocation reaches ReleaseStore again, then uses the new model key.
      Adapter.install(self(), snapshot, @github, :success)
      System.put_env("ANTHROPIC_API_KEY", @selected)
      cert = trusted_ca(root)
      direct_success(cert)
      assert_receive {:catalog_route, :releases, true, _caller}, 1_000
      assert_receive {:catalog_route, :index, true, _caller}, 1_000
      assert_receive {:catalog_route, :snapshot, true, _caller}, 1_000
      assert LLMDB.Catalog.snapshot() != nil
      IO.puts("CATALOG_FAILURE_PROVED")
    after
      Adapter.clear()
      :ssl.close(listener.socket)
    end
  end

  defp failure_listener do
    cert = Loopex.LLM.ReqLLM.InProcessTLSFixture.certificate()

    {:ok, socket} =
      :ssl.listen(0, [
        :binary,
        active: false,
        reuseaddr: true,
        cert: cert[:cert],
        key: cert[:key]
      ])

    {:ok, {_, port}} = :ssl.sockname(socket)
    %{socket: socket, base: "https://localhost:#{port}"}
  end

  defp direct_success(cert) do
    {:ok, listener} =
      :ssl.listen(0, [:binary, active: false, reuseaddr: true, cert: cert[:cert], key: cert[:key]])

    {:ok, {_, port}} = :ssl.sockname(listener)
    base = "https://localhost:#{port}"
    parent = self()
    progress_ref = make_ref()

    progress = fn delta ->
      send(parent, {:in_process_progress, progress_ref, delta})
      :ok
    end

    # The call's own deadline, shared with the server below: a cold catalog
    # load is charged to it (ADR 0039), so the server waits for the
    # connection exactly as long as the call may still make it.
    deadline = System.system_time(:millisecond) + 10_000
    server = spawn(fn -> serve_direct(listener, parent, deadline) end)
    {:ok, supervisor} = Task.Supervisor.start_link()
    runtime = Wire.runtime()

    try do
      starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
      cell = :atomics.new(2, signed: false)

      options = [
        session_admission: {Admission, self(), make_ref(), cell},
        session_cell: cell,
        base_url: base,
        credential_variable: "ANTHROPIC_API_KEY",
        trace_capability: runtime.capability
      ]

      {:ok, request} =
        Model.request(@model, [%{"role" => "user", "content" => "success"}],
          sampling: %{"max_tokens" => 64},
          deadline: deadline
        )

      result =
        ProviderLifetime.scoped(
          fn candidate, stop_ref ->
            send(parent, {:catalog_registered, candidate, stop_ref})
            {:managed, parent, Loopex.Executor.default_cleanup_grace_ms()}
          end,
          starter,
          fn -> InProcess.complete(request, options, progress) end
        )

      assert {:ok, %{text: "catalog direct answer", streamed: false, delta_count: 0} = reply} =
               result

      assert is_binary(reply.text)
      refute_receive {:in_process_progress, ^progress_ref, _}, 50
      assert_receive {:catalog_registered, candidate, stop_ref}, 1_000
      assert_receive {:catalog_model_wire, ^server, true, "POST /v1/messages HTTP/1.1"}, 1_000
      assert_receive {:catalog_model_closed, ^server}, 5_000
      monitor = Process.monitor(candidate)
      stop = make_ref()
      until = System.monotonic_time(:millisecond) + 5_000

      send(candidate, {:loopex_provider_resource_stop, stop_ref, stop, self(), until, until})
      assert_receive {:loopex_provider_resource_stopped, ^stop, ^candidate}, 2_000
      assert_receive {:DOWN, ^monitor, :process, ^candidate, :normal}, 2_000
      refute_receive {:catalog_model_wire, ^server, _, _}, 50
    after
      :ssl.close(listener)
      if Process.alive?(server), do: Process.exit(server, :kill)
      Supervisor.stop(supervisor)
      Wire.close_runtime(runtime)
    end
  end

  defp serve_direct(listener, parent, deadline) do
    {:ok, socket} = :ssl.transport_accept(listener, remaining(deadline))
    {:ok, socket} = :ssl.handshake(socket, remaining(deadline))
    {head, _body} = read_direct_request(socket, "")
    [line | lines] = String.split(head, "\r\n")

    headers =
      Map.new(lines, fn field ->
        [key, value] = String.split(field, ":", parts: 2)
        {String.downcase(key), String.trim(value)}
      end)

    send(parent, {:catalog_model_wire, self(), headers["x-api-key"] == @selected, line})
    body = Wire.wire(:anthropic, "catalog direct answer")

    response =
      "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nrequest-id: catalog-direct\r\ncontent-length: #{byte_size(body)}\r\n\r\n#{body}"

    :ok = :ssl.send(socket, response)
    assert {:error, :closed} = :ssl.recv(socket, 0, 5_000)
    send(parent, {:catalog_model_closed, self()})
    :ssl.close(socket)
  end

  defp remaining(deadline), do: max(deadline - System.system_time(:millisecond), 0)

  defp read_direct_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        length =
          head
          |> String.split("\r\n")
          |> Enum.find_value(0, fn line ->
            case String.split(line, ":", parts: 2) do
              [key, value] ->
                if String.downcase(key) == "content-length",
                  do: String.to_integer(String.trim(value))

              _ ->
                nil
            end
          end)

        if byte_size(body) >= length do
          {head, binary_part(body, 0, length)}
        else
          {:ok, more} = :ssl.recv(socket, 0, 5_000)
          read_direct_request(socket, bytes <> more)
        end

      _ ->
        {:ok, more} = :ssl.recv(socket, 0, 5_000)
        read_direct_request(socket, bytes <> more)
    end
  end

  defp assert_no_model_connection(listener) do
    assert {:error, :timeout} = :ssl.transport_accept(listener.socket, 50)
  end

  defp managed_complete(base, remaining_ms) do
    {:ok, request} =
      Model.request(@model, [%{"role" => "user", "content" => "hello"}],
        sampling: %{"max_tokens" => 64},
        deadline: System.system_time(:millisecond) + remaining_ms
      )

    owner = self()
    cell = :atomics.new(2, signed: false)

    starter =
      Starter.new(fn _child ->
        send(owner, :unexpected_model_start)
        {:error, :unavailable}
      end)

    options = [
      session_admission: {__MODULE__, owner, make_ref(), cell},
      session_cell: cell,
      base_url: base,
      credential_variable: "ANTHROPIC_API_KEY",
      trace_capability: nil
    ]

    result =
      ProviderLifetime.scoped(
        fn _resource, _stop ->
          send(owner, :unexpected_model_registration)
          :unmanaged
        end,
        starter,
        fn -> InProcess.complete(request, options, Model.discard_progress()) end
      )

    refute_receive :unexpected_model_start, 10
    refute_receive :unexpected_model_registration, 10
    result
  end

  defp traced_selected_key_absence(action) do
    parent = self()
    tracer = spawn(fn -> env_trace_loop(parent) end)
    assert :erlang.trace_pattern({System, :get_env, 1}, true, []) == 1
    :erlang.trace(self(), true, [:call, {:tracer, tracer}])

    try do
      System.get_env("CATALOG_TRACE_CONTROL")
      assert_receive {:catalog_env_read, :control}, 1_000
      action.()
      refute_receive {:catalog_env_read, :selected_provider}, 50
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({System, :get_env, 1}, false, [])
      send(tracer, :stop)
    end
  end

  defp env_trace_loop(parent) do
    receive do
      {:trace, _process, :call, {System, :get_env, ["CATALOG_TRACE_CONTROL"]}} ->
        send(parent, {:catalog_env_read, :control})
        env_trace_loop(parent)

      {:trace, _process, :call, {System, :get_env, ["ANTHROPIC_API_KEY"]}} ->
        send(parent, {:catalog_env_read, :selected_provider})
        env_trace_loop(parent)

      :stop ->
        :ok

      _other ->
        env_trace_loop(parent)
    end
  end

  defp lock_case(snapshot, root) do
    cache = Path.join(root, "locked-release-cache")
    File.mkdir!(cache)
    configure(remote_source(cache))
    System.put_env("GH_TOKEN", @github)
    Adapter.install(self(), snapshot, @github, :block)
    listener = failure_listener()
    parent = self()

    {first, first_monitor} =
      spawn_monitor(fn ->
        {:ok, request} =
          Model.request(@model, [%{"role" => "user", "content" => "first"}],
            sampling: %{"max_tokens" => 64},
            deadline: System.system_time(:millisecond) + 5_000
          )

        send(parent, {:first_preflight, InProcess.preflight(request, listener.base)})
      end)

    try do
      assert_receive {:catalog_route, :releases, true, ^first}, 5_000

      {second, second_monitor} =
        spawn_monitor(fn ->
          send(parent, {:second_ready, self()})

          receive do
            :begin_second ->
              send(parent, {:second_result, managed_complete(listener.base, 50)})
          end
        end)

      assert_receive {:second_ready, ^second}, 1_000
      send(second, :begin_second)
      assert await_catalog_lock(second, 100)
      Process.sleep(100)
      refute_receive {:second_result, _}, 0
      refute_receive {:catalog_route, _, _, ^second}, 0

      send(first, {:catalog_release, self()})
      assert_receive {:catalog_route, :index, true, ^first}, 5_000
      assert_receive {:catalog_route, :snapshot, true, ^first}, 5_000
      assert_receive {:first_preflight, {:ok, %{surface: :anthropic_messages}}}, 5_000
      assert_receive {:DOWN, ^first_monitor, :process, ^first, :normal}, 1_000
      assert_receive {:second_result, {:error, {:not_dispatched, "model_call_failed"}}}, 5_000
      assert_receive {:DOWN, ^second_monitor, :process, ^second, :normal}, 1_000
      assert LLMDB.Catalog.snapshot() != nil
      assert_no_model_connection(listener)
      refute_receive {:catalog_route, _, _, _}, 50
      IO.puts("CATALOG_LOCK_PROVED")
    after
      Adapter.clear()
      :ssl.close(listener.socket)
    end
  end

  defp await_catalog_lock(_pid, 0), do: false

  defp await_catalog_lock(pid, attempts) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} when is_list(stack) ->
        locked? =
          Enum.any?(stack, &match?({:global, :set_lock, _, _}, &1)) and
            Enum.any?(stack, &match?({LLMDB.Catalog, :ensure_loaded!, 0, _}, &1))

        if locked? do
          true
        else
          Process.sleep(10)
          await_catalog_lock(pid, attempts - 1)
        end

      _ ->
        false
    end
  end
end
