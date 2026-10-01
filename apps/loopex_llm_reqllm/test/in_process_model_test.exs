defmodule Loopex.LLM.ReqLLM.InProcessModelTest do
  use ExUnit.Case, async: false

  alias Loopex.LLM.ReqLLM.InProcess
  alias Loopex.LLM.ReqLLM.InProcess.Caller
  alias Loopex.LLM.ReqLLM.Deadline
  alias Loopex.Model
  alias Loopex.Runtime.ProviderLifetime
  alias Loopex.Runtime.ProviderLifetime.Starter

  defmodule AdmissionProbe do
    @behaviour Loopex.LLM.ReqLLM.InProcess.Admission

    @impl true
    def request(
          {__MODULE__, owner, generation, _cell},
          {:stage_model, call, candidate, proof, _stop, start_proof} = operation,
          deadline
        ) do
      staging_ref = make_ref()
      start_ref = elem(start_proof, 1)
      custody = {:model_cleanup_custody, owner, generation, call, candidate, proof}

      send(
        candidate,
        {:model_custody_prepare, start_ref, staging_ref, deadline, __MODULE__, custody}
      )

      receive do
        {:model_custody_prepared, ^candidate, ^staging_ref, ^generation, ^call, ^proof} ->
          grant(generation, operation, staging_ref, deadline)
      after
        1_000 -> {:error, :session_admission_closed}
      end
    end

    def request(
          {__MODULE__, _owner, generation, _cell},
          {:cancel_model, _call,
           {:registration_refused, _registration, candidate, candidate_monitor}} = operation,
          deadline
        ) do
      Process.exit(candidate, :kill)

      receive do
        {:DOWN, ^candidate_monitor, :process, ^candidate, :killed} ->
          grant(generation, operation, make_ref(), deadline)
      after
        1_000 -> {:error, :session_admission_closed}
      end
    end

    def request(
          {__MODULE__, owner, generation, _cell},
          {:cancel_model, _call,
           {:model_start_proof, _, _, _, :normal, :not_started, {:error, :unavailable}}} =
            operation,
          deadline
        ) do
      send(owner, {:no_child_cancel_deadline, self(), deadline})
      send(owner, {:admission_seen, :cancel_model, self(), operation})
      grant(generation, operation, make_ref(), deadline)
    end

    def request({__MODULE__, owner, generation, _cell}, operation, deadline) do
      send(owner, {:admission_seen, elem(operation, 0), self(), operation})
      grant(generation, operation, make_ref(), deadline)
    end

    def request(
          {:model_cleanup_custody, owner, generation, call, candidate, proof},
          {:retire_model, call, candidate, proof} = operation,
          deadline
        ) do
      send(owner, {:admission_seen, :retire_model, self(), operation})
      grant(generation, operation, make_ref(), deadline)
    end

    defp grant(generation, operation, reference, deadline),
      do: {:ok, {:session_grant, generation, elem(operation, 0), self(), reference, deadline}}
  end

  defmodule StageRaceProbe do
    @behaviour Loopex.LLM.ReqLLM.InProcess.Admission

    @impl true
    def request(
          {__MODULE__, _observer, generation, _cell},
          {:begin_model, _callback, _call} = operation,
          deadline
        ) do
      grant(generation, operation, deadline)
    end

    def request(
          {__MODULE__, observer, generation, _cell},
          {:stage_model, call, candidate, proof, _stop, start_proof} = operation,
          deadline
        ) do
      start_ref = elem(start_proof, 1)
      staging_ref = make_ref()
      send(observer, {:stage_requested, self(), candidate, call, proof, start_ref})

      receive do
        {:stage_result, ^candidate, :clean_cancel} ->
          {:error, :model_stage_cancelled}

        {:stage_result, ^candidate, :deliver_custody} ->
          custody = {:model_cleanup_custody, observer, generation, call, candidate, proof}

          send(
            candidate,
            {:model_custody_prepare, start_ref, staging_ref, deadline, __MODULE__, custody}
          )

          receive do
            {:stage_result, ^candidate, :lost_ack} ->
              {:error, :session_admission_closed}

            {:stage_result, ^candidate, :grant} ->
              grant(generation, operation, deadline)
          after
            1_000 -> {:error, :session_admission_closed}
          end
      after
        1_000 -> {:error, :session_admission_closed}
      end
    end

    def request(
          {:model_cleanup_custody, observer, generation, call, candidate, proof},
          {:retire_model, call, candidate, proof} = operation,
          deadline
        ) do
      send(observer, {:retirement_requested, candidate, call, proof})
      grant(generation, operation, deadline)
    end

    def request(
          {__MODULE__, observer, generation, _cell},
          {:cancel_model, _call, {:registrar_not_entered, _, candidate, _, :killed}} = operation,
          deadline
        ) do
      send(observer, {:admission_seen, :cancel_model, self(), operation})

      if Process.alive?(candidate),
        do: {:error, :session_admission_closed},
        else: grant(generation, operation, deadline)
    end

    def request(_handle, _operation, _deadline), do: {:error, :session_admission_closed}

    defp grant(generation, operation, deadline),
      do: {:ok, {:session_grant, generation, elem(operation, 0), self(), make_ref(), deadline}}
  end

  setup_all do
    previously_started? =
      Enum.any?(Application.started_applications(), fn {application, _, _} ->
        application == :req_llm
      end)

    previous_dotenv = Application.get_env(:req_llm, :load_dotenv, :not_set)
    Application.put_env(:req_llm, :load_dotenv, false)
    {:ok, _started} = Application.ensure_all_started(:req_llm)

    on_exit(fn ->
      unless previously_started?, do: Application.stop(:req_llm)

      if previous_dotenv == :not_set,
        do: Application.delete_env(:req_llm, :load_dotenv),
        else: Application.put_env(:req_llm, :load_dotenv, previous_dotenv)
    end)

    :ok
  end

  defp request(model, timeout_ms \\ 10_000) do
    {:ok, request} =
      Model.request(model, [%{"role" => "user", "content" => "hello"}],
        sampling: %{"max_tokens" => 16},
        deadline: System.system_time(:millisecond) + timeout_ms
      )

    request
  end

  test "preflight selects each provider without resolving its selected key" do
    for {model, provider, variable, surfaces} <- [
          {"ollama:qwen3:14b", :ollama, nil, [:ollama_chat_completions]},
          {"openai:gpt-4o-mini", :openai, "OPENAI_API_KEY",
           [:openai_chat_completions, :openai_responses]},
          {"anthropic:claude-sonnet-4-5", :anthropic, "ANTHROPIC_API_KEY", [:anthropic_messages]},
          {"openrouter:openai/gpt-4o-mini", :openrouter, "OPENROUTER_API_KEY",
           [:openrouter_chat_completions]}
        ] do
      assert {:ok, prepared} = InProcess.preflight(request(model), nil)
      assert prepared.provider == provider
      assert prepared.credential_variable == variable
      assert prepared.surface in surfaces
      assert String.starts_with?(prepared.base_url, "http")
      refute Map.has_key?(prepared, :api_key)
      refute Map.has_key?(prepared, :credential)
      assert is_map(prepared.identity)
      assert prepared.identity.endpoint == prepared.base_url
    end
  end

  test "preflight refuses changed committed bytes, unsupported providers and unsafe addresses" do
    original = request("ollama:small")

    assert {:error, {:not_dispatched, "model_call_failed"}} =
             InProcess.preflight(%{original | staged_request_digest: <<0::256>>}, nil)

    assert {:error, {:not_dispatched, "model_call_failed"}} =
             InProcess.preflight(request("other:model"), nil)

    assert {:error, {:not_dispatched, "model_call_failed"}} =
             InProcess.preflight(request("openai:gpt-4o-mini"), "http://api.openai.com/v1")
  end

  test "explicit bindings choose only the committed provider and reject every invalid reference" do
    routes = %{
      "openai" => %{"credential" => %{"env" => "M7_FIRST_REFERENCE"}},
      "anthropic" => %{"credential" => %{"env" => "M7_SECOND_REFERENCE"}},
      "ollama" => %{"credential" => %{"none" => true}}
    }

    for {model, variable} <- [
          {"openai:gpt-4o-mini", "M7_FIRST_REFERENCE"},
          {"anthropic:claude-sonnet-4-5", "M7_SECOND_REFERENCE"},
          {"ollama:small", nil},
          {"openai:gpt-4o-mini", "M7_FIRST_REFERENCE"}
        ] do
      assert {:ok, prepared} = InProcess.preflight(request(model), nil, routes)
      assert prepared.credential_variable == variable
      refute Map.has_key?(prepared, :provider_bindings)
    end

    for bad <- [
          Map.delete(routes, "openai"),
          %{},
          put_in(routes, ["anthropic", "credential", "env"], "HOME")
        ] do
      assert {:error, {:not_dispatched, "model_call_failed"}} =
               InProcess.preflight(request("openai:gpt-4o-mini"), nil, bad)
    end
  end

  test "preflight normalizes the explicit address and refuses host Req defaults" do
    assert {:ok, prepared} =
             InProcess.preflight(request("ollama:small"), "http://LOCALHOST:11434/v1///")

    assert prepared.base_url == "http://localhost:11434/v1"

    previous = Application.get_env(:req, :default_options, :not_set)

    try do
      Application.put_env(:req, :default_options, finch: :alternate)

      assert {:error, {:not_dispatched, "model_call_failed"}} =
               InProcess.preflight(request("ollama:small"), nil)
    after
      if previous == :not_set,
        do: Application.delete_env(:req, :default_options),
        else: Application.put_env(:req, :default_options, previous)
    end
  end

  test "sensitive caller waits for both exact messages and refuses a missing trace grant" do
    {:ok, prepared} = InProcess.preflight(request("ollama:small"), nil)
    cell = :atomics.new(2, signed: false)
    call_ref = make_ref()
    input_ref = make_ref()
    tag = make_ref()

    arguments = %{
      owner: self(),
      callback: self(),
      ref: call_ref,
      input_ref: input_ref,
      tag: tag,
      cell: cell,
      trace_capability: :invalid,
      pool_timeout: 1
    }

    {caller, monitor} = spawn_monitor(fn -> Caller.run(arguments) end)
    assert_receive {:in_process_caller_ready, ^caller, ^call_ref}, 1_000

    send(caller, {:in_process_caller_begin, self(), call_ref, make_ref()})
    send(caller, {:in_process_caller_input, self(), call_ref, input_ref, prepared})
    refute_receive {^caller, ^call_ref, _result, _instant}, 50

    send(caller, {:in_process_caller_begin, self(), call_ref, input_ref})

    assert_receive {^caller, ^call_ref, {:error, {:not_dispatched, "model_call_failed"}},
                    finished_at},
                   1_000

    assert is_integer(finished_at)
    assert Process.alive?(caller)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000
  end

  test "begin before input does not dispatch and callback loss ends the caller" do
    owner = self()
    callback = spawn(fn -> receive do: (:stop -> :ok) end)
    cell = :atomics.new(2, signed: false)
    call_ref = make_ref()
    input_ref = make_ref()

    {caller, monitor} =
      spawn_monitor(fn ->
        Caller.run(%{
          owner: owner,
          callback: callback,
          ref: call_ref,
          input_ref: input_ref,
          tag: make_ref(),
          cell: cell,
          trace_capability: :invalid,
          pool_timeout: 1
        })
      end)

    assert_receive {:in_process_caller_ready, ^caller, ^call_ref}, 1_000
    send(caller, {:in_process_caller_begin, owner, call_ref, input_ref})
    refute_receive {^caller, ^call_ref, _result, _instant}, 50
    send(callback, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 1_000
    refute_receive {^caller, ^call_ref, _result, _instant}, 50
  end

  test "unmanaged callback refuses before beginning or starting a child" do
    options = callback_options()

    assert {:error, {:not_dispatched, "model_call_failed"}} =
             InProcess.complete(request("ollama:small"), options, fn _ -> :ok end)

    refute_receive {:admission_seen, _, _, _}, 30
  end

  test "a rejected admission route never invokes the managed starter" do
    test = self()

    starter =
      Starter.new(fn _child ->
        send(test, :starter_invoked)
        {:error, :unavailable}
      end)

    options = callback_options()
    {_module, owner, generation, cell} = options[:session_admission]
    options = Keyword.put(options, :session_admission, {:wrong_route, owner, generation, cell})

    result =
      ProviderLifetime.scoped(fn _, _ -> :unmanaged end, starter, fn ->
        InProcess.complete(request("ollama:small"), options, fn _ -> :ok end)
      end)

    assert {:error, {:not_dispatched, "model_call_failed"}} = result
    refute_receive :starter_invoked, 30

    for options <- [
          Keyword.put(callback_options(), :provider_bindings, %{
            "ollama" => %{"credential" => %{"none" => true}}
          }),
          callback_options()
          |> Keyword.delete(:credential_variable)
          |> Keyword.put(:provider_bindings, %{
            "openai" => %{"credential" => %{"env" => "M7_UNUSED"}}
          })
        ] do
      assert {:error, {:not_dispatched, "model_call_failed"}} =
               ProviderLifetime.scoped(fn _, _ -> flunk("registrar entered") end, starter, fn ->
                 InProcess.complete(request("ollama:small"), options, fn _ -> :ok end)
               end)

      refute_receive {:admission_seen, _, _, _}, 30
      refute_receive :starter_invoked, 30
    end
  end

  test "a proved no-child start cancels the pending call without registration" do
    starter = Starter.new(fn _child -> {:error, :unavailable} end)

    result =
      ProviderLifetime.scoped(fn _, _ -> flunk("registrar entered") end, starter, fn ->
        InProcess.complete(request("ollama:small"), callback_options(), fn _ -> :ok end)
      end)

    assert {:error, {:not_dispatched, "model_call_failed"}} = result
    assert_receive {:admission_seen, :begin_model, _, _}, 1_000
    assert_receive {:admission_seen, :cancel_model, _, _}, 1_000
    refute_receive {:admission_seen, :stage_model, _, _}, 30
  end

  test "proved no-child cancellation gets a fresh cleanup deadline" do
    starter = Starter.new(fn _child -> {:error, :unavailable} end)
    model_request = request("ollama:small", 400)

    model_deadline =
      Deadline.invocation_deadline(model_request.deadline, System.time_offset(:native))

    result =
      ProviderLifetime.scoped(fn _, _ -> flunk("registrar entered") end, starter, fn ->
        InProcess.complete(model_request, callback_options(), fn _ -> :ok end)
      end)

    assert {:error, {:not_dispatched, "model_call_failed"}} = result
    assert_receive {:no_child_cancel_deadline, callback, cleanup_deadline}, 1_000
    assert callback == self()
    assert cleanup_deadline > model_deadline
    refute_receive {:admission_seen, :stage_model, _, _}, 20
  end

  test "a managed callback stages the candidate, registers it, and waits for owner proof" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> stop_fixture_supervisor(supervisor) end)
    starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
    test = self()

    result =
      ProviderLifetime.scoped(
        fn candidate, stop_ref ->
          send(test, {:registered_candidate, candidate, stop_ref})
          {:managed, test, Loopex.Executor.default_cleanup_grace_ms()}
        end,
        starter,
        fn ->
          InProcess.complete(request("ollama:small"), callback_options(), fn _ -> :ok end)
        end
      )

    assert {:error, {:not_dispatched, "model_call_failed"}} = result
    assert_receive {:registered_candidate, candidate, stop_ref}, 1_000
    assert_receive {:admission_seen, :begin_model, _, _}, 1_000
    assert_receive {:admission_seen, :register_model, _, _}, 1_000
    assert_receive {:admission_seen, :record_model_resources, _, _}, 1_000
    monitor = Process.monitor(candidate)
    nonce = make_ref()
    stop_at = System.monotonic_time(:millisecond) + 5_000
    send(candidate, {:loopex_provider_resource_stop, stop_ref, nonce, self(), stop_at, stop_at})
    assert_receive {:loopex_provider_resource_stopped, ^nonce, ^candidate}, 2_000
    assert_receive {:DOWN, ^monitor, :process, ^candidate, :normal}, 2_000
    assert_receive {:admission_seen, :retire_model, _, _}, 1_000
  end

  test "a refused registrar reaps the staged candidate without a work grant" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> stop_fixture_supervisor(supervisor) end)
    starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
    test = self()

    result =
      ProviderLifetime.scoped(
        fn candidate, _stop_ref ->
          send(test, {:refused_candidate, candidate})
          :unmanaged
        end,
        starter,
        fn ->
          InProcess.complete(request("ollama:small"), callback_options(), fn _ -> :ok end)
        end
      )

    assert {:error, {:not_dispatched, "model_call_failed"}} = result
    assert_receive {:refused_candidate, candidate}, 1_000
    refute Process.alive?(candidate)
    refute_receive {:admission_seen, :register_model, _, _}, 30
    refute_receive {:admission_seen, :record_model_resources, _, _}, 30
  end

  test "candidate DOWN before custody acknowledgement accepts only the owner's clean cancel" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> stop_fixture_supervisor(supervisor) end)
    starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
    test = self()
    {options, cell} = stage_race_options()

    {callback, callback_monitor} =
      spawn_monitor(fn ->
        result =
          ProviderLifetime.scoped(
            fn _, _ -> send(test, :registrar_entered) end,
            starter,
            fn -> InProcess.complete(request("ollama:small"), options, fn _ -> :ok end) end
          )

        send(test, {:callback_result, result})
      end)

    assert_receive {:stage_requested, ^callback, candidate, _call, _proof, _start_ref}, 1_000
    candidate_monitor = Process.monitor(candidate)
    Process.exit(candidate, :kill)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :killed}, 1_000
    send(callback, {:stage_result, candidate, :clean_cancel})

    assert_receive {:callback_result, {:error, {:not_dispatched, "model_call_failed"}}}, 1_000
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 1_000
    assert :atomics.get(cell, 1) == 0
    refute_receive :registrar_entered, 20
  end

  test "candidate expiry during staging accepts the owner's clean cancellation" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> stop_fixture_supervisor(supervisor) end)
    starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
    {options, cell} = stage_race_options()
    model_request = request("ollama:small", 650)
    {callback, callback_monitor} = stage_race_callback(model_request, options, starter)

    assert_receive {:stage_requested, ^callback, candidate, _call, _proof, _start_ref}, 1_000
    candidate_monitor = Process.monitor(candidate)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 1_000
    assert System.system_time(:millisecond) >= model_request.deadline
    send(callback, {:stage_result, candidate, :clean_cancel})

    assert_receive {:callback_outcome,
                    {:return, {:error, {:not_dispatched, "model_call_failed"}}}},
                   1_000

    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 1_000
    assert :atomics.get(cell, 1) == 0
    refute_receive :registrar_entered, 20
  end

  test "model expiry after staging custody cancels the inert candidate before returning" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> stop_fixture_supervisor(supervisor) end)
    starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
    {options, cell} = stage_race_options()
    model_request = request("ollama:small", 650)
    {callback, callback_monitor} = stage_race_callback(model_request, options, starter)

    assert_receive {:stage_requested, ^callback, candidate, call, proof, _start_ref}, 1_000
    candidate_monitor = Process.monitor(candidate)
    send(callback, {:stage_result, candidate, :deliver_custody})
    assert_receive {:model_custody_prepared, ^candidate, _, _, ^call, ^proof}, 1_000

    Process.sleep(max(model_request.deadline - System.system_time(:millisecond) + 10, 0))
    assert System.system_time(:millisecond) > model_request.deadline
    send(callback, {:stage_result, candidate, :grant})

    assert_receive {:admission_seen, :cancel_model, ^callback,
                    {:cancel_model, ^call,
                     {:registrar_not_entered, _, ^candidate, cancel_monitor, :killed}}},
                   1_000

    assert is_reference(cancel_monitor)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :killed}, 1_000

    assert_receive {:callback_outcome,
                    {:return, {:error, {:not_dispatched, "model_call_failed"}}}},
                   1_000

    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 1_000
    assert :atomics.get(cell, 1) == 0
    refute_receive :registrar_entered, 20
  end

  test "model expiry while pending acknowledgement is delayed cancels before registrar" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> stop_fixture_supervisor(supervisor) end)
    starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
    {options, cell} = stage_race_options()
    model_request = request("ollama:small", 650)
    {callback, callback_monitor} = stage_race_callback(model_request, options, starter)

    assert_receive {:stage_requested, ^callback, candidate, call, proof, _start_ref}, 1_000
    candidate_monitor = Process.monitor(candidate)
    send(callback, {:stage_result, candidate, :deliver_custody})
    assert_receive {:model_custody_prepared, ^candidate, _, _, ^call, ^proof}, 1_000

    assert :erlang.suspend_process(candidate)
    assert :erlang.trace(callback, true, [:send]) == 1

    try do
      assert System.system_time(:millisecond) < model_request.deadline
      send(callback, {:stage_result, candidate, :grant})

      assert_receive {:trace, ^callback, :send, {:registration_pending, ^callback, _stop_ref},
                      ^candidate},
                     500

      Process.sleep(max(model_request.deadline - System.system_time(:millisecond) + 10, 0))
      assert System.system_time(:millisecond) > model_request.deadline
    after
      :erlang.trace(callback, false, [:send])
      if Process.alive?(candidate), do: :erlang.resume_process(candidate)
    end

    assert_receive {:admission_seen, :cancel_model, ^callback,
                    {:cancel_model, ^call,
                     {:registrar_not_entered, _, ^candidate, cancel_monitor, :killed}}},
                   1_000

    assert is_reference(cancel_monitor)
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :killed}, 1_000

    assert_receive {:callback_outcome,
                    {:return, {:error, {:not_dispatched, "model_call_failed"}}}},
                   1_000

    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 1_000
    assert :atomics.get(cell, 1) == 0
    refute_receive :registrar_entered, 20
  end

  test "lost stage acknowledgement leaves provisionally owned candidate to retire" do
    {:ok, supervisor} = Task.Supervisor.start_link()
    on_exit(fn -> stop_fixture_supervisor(supervisor) end)
    starter = Starter.new(fn child -> Task.Supervisor.start_child(supervisor, child) end)
    {options, cell} = stage_race_options()
    {callback, callback_monitor} = stage_race_callback(request("ollama:small"), options, starter)

    assert_receive {:stage_requested, ^callback, candidate, call, proof, _start_ref}, 1_000
    candidate_monitor = Process.monitor(candidate)
    send(callback, {:stage_result, candidate, :deliver_custody})
    assert_receive {:model_custody_prepared, ^candidate, _, _, ^call, ^proof}, 1_000
    send(callback, {:stage_result, candidate, :lost_ack})

    assert_receive {:callback_outcome, {:exit, :in_process_stage_unproved}}, 1_000
    assert_receive {:DOWN, ^callback_monitor, :process, ^callback, :normal}, 1_000
    assert_receive {:retirement_requested, ^candidate, ^call, ^proof}, 1_000
    assert_receive {:DOWN, ^candidate_monitor, :process, ^candidate, :normal}, 1_000
    assert :atomics.get(cell, 1) == 0
    refute_receive :registrar_entered, 20
  end

  defp callback_options do
    cell = :atomics.new(2, signed: false)

    [
      session_admission: {AdmissionProbe, self(), make_ref(), cell},
      session_cell: cell,
      base_url: nil,
      credential_variable: nil,
      trace_capability: :invalid
    ]
  end

  defp stage_race_options do
    cell = :atomics.new(2, signed: false)

    options = [
      session_admission: {StageRaceProbe, self(), make_ref(), cell},
      session_cell: cell,
      base_url: nil,
      credential_variable: nil,
      trace_capability: :invalid
    ]

    {options, cell}
  end

  defp stage_race_callback(model_request, options, starter) do
    observer = self()

    spawn_monitor(fn ->
      outcome =
        try do
          {:return,
           ProviderLifetime.scoped(
             fn _, _ -> send(observer, :registrar_entered) end,
             starter,
             fn -> InProcess.complete(model_request, options, fn _ -> :ok end) end
           )}
        catch
          :exit, reason -> {:exit, reason}
        end

      send(observer, {:callback_outcome, outcome})
    end)
  end

  defp stop_fixture_supervisor(supervisor) do
    Supervisor.stop(supervisor)
  catch
    :exit, _ -> :ok
  end
end
