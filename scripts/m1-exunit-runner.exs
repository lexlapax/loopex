defmodule Loopex.M1Gate.ExUnitReport do
  @moduledoc false

  @selector ~r/\Aapps\/[a-z][a-z0-9_]*\/test\/[A-Za-z0-9_.-]+(?:\/[A-Za-z0-9_.-]+)*_test\.exs\z/u
  @states ~w(passed failed skipped excluded)

  def validate(events, stats, selector, seed, minimum, policy, expectations) do
    expected_excluded = Enum.count(expectations, &(elem(&1, 0) == "excluded"))

    with :ok <- invocation(selector, seed, minimum, policy, expectations),
         :ok <- result(events, stats, selector, seed, minimum, expected_excluded),
         {:ok, tests} <- tests(events, stats, selector),
         :ok <- expectations(tests, expectations) do
      executed = stats.total - stats.skipped - stats.excluded
      {:ok, %{executed: executed, digest: digest(events, stats)}}
    end
  end

  def invocation(selector, seed, minimum, policy, expectations) do
    components = String.split(selector, "/")

    cond do
      not Regex.match?(@selector, selector) or
          Enum.any?(components, &(&1 in ["", ".", ".."])) ->
        {:error, "selector is not a canonical application test path"}

      not is_integer(seed) or seed < 0 or seed > 999_999 ->
        {:error, "selector seed must be an integer from 0 through 999999"}

      not is_integer(minimum) or minimum < 1 ->
        {:error, "selector minimum must be a positive integer"}

      policy not in [:zero, :positive] ->
        {:error, "selector exclusion policy is unknown"}

      expectations == [] ->
        {:error, "selector must bind at least one locked test name"}

      Enum.any?(expectations, fn {state, name} -> state not in @states or name == "" end) ->
        {:error, "selector expectation is malformed"}

      expectations |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() !=
          length(expectations) ->
        {:error, "selector repeats a locked test name"}

      policy == :zero and Enum.any?(expectations, &(elem(&1, 0) == "excluded")) ->
        {:error, "zero-exclusion selector cannot expect an excluded test"}

      policy == :positive and
          not Enum.any?(expectations, &(elem(&1, 0) == "excluded")) ->
        {:error, "positive-exclusion selector must name every expected exclusion"}

      true ->
        :ok
    end
  end

  defp result(events, stats, selector, seed, minimum, expected_excluded) do
    total = stats[:total]
    skipped = stats[:skipped]
    excluded = stats[:excluded]
    failures = stats[:failures]

    executed =
      if is_integer(total) and is_integer(skipped) and is_integer(excluded),
        do: total - skipped - excluded

    cond do
      events.selector != selector or events.seed != seed ->
        {:error, "authoritative events are bound to another selector or seed"}

      events.suite_started != 1 or events.suite_finished != 1 or
          events.owned_formatter != true ->
        {:error, "authoritative formatter did not own exactly one complete suite"}

      events.max_failures != false or events.selector_mismatches != 0 or
        events.duplicate_tests != 0 or events.unknown_events != 0 ->
        {:error, "authoritative formatter observed an incomplete or foreign event stream"}

      not Enum.all?([total, executed, skipped, excluded, failures], &non_negative?/1) ->
        {:error, "authoritative counts are malformed"}

      total != executed + skipped + excluded ->
        {:error, "authoritative counts do not balance"}

      executed < minimum ->
        {:error, "selector executed fewer than its locked minimum"}

      skipped != 0 ->
        {:error, "selector skipped a test"}

      failures != 0 ->
        {:error, "selector failed"}

      excluded != expected_excluded ->
        {:error, "selector exclusions do not equal its exact named exclusions"}

      true ->
        :ok
    end
  end

  defp tests(%{tests: event_tests}, %{total: total}, selector)
       when is_map(event_tests) and map_size(event_tests) == total do
    event_tests
    |> Map.values()
    |> Enum.reduce_while({:ok, []}, fn test, {:ok, acc} ->
      with %{file: ^selector, module: module, name: name, state: state} <- test,
           true <- is_binary(module) and module != "",
           true <- is_binary(name) and name != "",
           true <- state in @states do
        {:cont, {:ok, [test | acc]}}
      else
        _other -> {:halt, {:error, "authoritative events contain a malformed test"}}
      end
    end)
  end

  defp tests(_events, _stats, _selector),
    do: {:error, "authoritative events do not equal the official total"}

  defp expectations(tests, expected) do
    Enum.reduce_while(expected, :ok, fn {state, name}, :ok ->
      case Enum.filter(tests, &(&1.name == name)) do
        [%{state: ^state}] -> {:cont, :ok}
        [] -> {:halt, {:error, "a locked test did not appear"}}
        [_one] -> {:halt, {:error, "a locked test recorded the wrong state"}}
        _many -> {:halt, {:error, "a locked test name appeared more than once"}}
      end
    end)
  end

  defp non_negative?(value), do: is_integer(value) and value >= 0

  defp digest(events, stats) do
    tests =
      events.tests
      |> Map.values()
      |> Enum.map(&{&1.file, &1.module, &1.name, &1.state})
      |> Enum.sort()

    {events.selector, events.seed, events.suite_started, events.suite_finished,
     events.owned_formatter, events.max_failures, events.selector_mismatches,
     events.duplicate_tests, events.unknown_events, stats.total, stats.skipped, stats.excluded,
     stats.failures, tests}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

defmodule Loopex.M1Gate.ExUnitFormatter do
  @moduledoc false
  use GenServer

  @impl GenServer
  def init(opts) do
    with {:ok, config} <- Keyword.fetch(opts, :loopex_m1_gate),
         true <- is_pid(config.collector) and Process.alive?(config.collector),
         true <- is_pid(config.owner) and Process.alive?(config.owner),
         :ok <- Agent.update(config.collector, fn _ -> initial(config, opts) end) do
      {:ok, config}
    else
      _other -> {:stop, "invalid M1 formatter configuration"}
    end
  end

  @impl GenServer
  def handle_cast(event, config) do
    Agent.update(config.collector, &collect(&1, event))

    if match?({:suite_finished, _}, event) do
      send(config.owner, {:loopex_m1_suite_finished, config.collector})
    end

    {:noreply, config}
  end

  defp initial(config, opts) do
    %{
      selector: config.selector,
      seed: config.seed,
      expected_file: Path.expand(config.selector, config.root),
      owned_formatter:
        Keyword.get(opts, :formatters) == [__MODULE__] and
          Keyword.get(opts, :seed) == config.seed and
          Keyword.get(opts, :dry_run) == false and
          Keyword.get(opts, :repeat_until_failure) == 0 and
          Keyword.get(opts, :only_test_ids) == nil and
          Keyword.get(opts, :max_failures) == :infinity and
          Keyword.get(opts, :include) == config.include and
          Keyword.get(opts, :exclude) == config.exclude,
      suite_started: 0,
      suite_finished: 0,
      max_failures: false,
      selector_mismatches: 0,
      duplicate_tests: 0,
      unknown_events: 0,
      tests: %{}
    }
  end

  defp collect(state, {:suite_started, _}), do: Map.update!(state, :suite_started, &(&1 + 1))
  defp collect(state, {:suite_finished, _}), do: Map.update!(state, :suite_finished, &(&1 + 1))
  defp collect(state, :max_failures_reached), do: %{state | max_failures: true}

  defp collect(state, {:test_finished, %ExUnit.Test{} = test}),
    do: put_test(state, test, state_name(test.state))

  defp collect(state, {:module_finished, %ExUnit.TestModule{state: {:failed, _}} = module}) do
    Enum.reduce(module.tests, state, fn test, acc ->
      if is_nil(test.state), do: put_test(acc, test, "failed", replace: true), else: acc
    end)
  end

  defp collect(state, {:module_finished, %ExUnit.TestModule{}}), do: state
  defp collect(state, {:case_started, _}), do: state
  defp collect(state, {:case_finished, _}), do: state
  defp collect(state, {:module_started, _}), do: state
  defp collect(state, {:test_started, _}), do: state
  defp collect(state, {:sigquit, _}), do: %{state | max_failures: true}
  defp collect(state, _), do: Map.update!(state, :unknown_events, &(&1 + 1))

  defp put_test(state, test, status, options \\ []) do
    id = {test.module, test.name}
    file = test.tags[:file] && Path.expand(to_string(test.tags[:file]))
    replace? = Keyword.get(options, :replace, false)

    state =
      if file == state.expected_file,
        do: state,
        else: Map.update!(state, :selector_mismatches, &(&1 + 1))

    entry = %{
      file: state.selector,
      module: inspect(test.module),
      name: test.name |> Atom.to_string() |> String.replace_prefix("test ", ""),
      state: status || "failed"
    }

    cond do
      status == nil ->
        state
        |> Map.update!(:unknown_events, &(&1 + 1))
        |> Map.update!(:tests, &Map.put(&1, id, entry))

      replace? and Map.has_key?(state.tests, id) ->
        Map.update!(state, :tests, &Map.put(&1, id, entry))

      Map.has_key?(state.tests, id) ->
        Map.update!(state, :duplicate_tests, &(&1 + 1))

      true ->
        Map.update!(state, :tests, &Map.put(&1, id, entry))
    end
  end

  defp state_name(nil), do: "passed"
  defp state_name(:passed), do: "passed"
  defp state_name({:failed, _}), do: "failed"
  defp state_name({:invalid, _}), do: "failed"
  defp state_name({:skipped, _}), do: "skipped"
  defp state_name({:excluded, _}), do: "excluded"
  defp state_name(_), do: nil
end

defmodule Loopex.M1Gate.RealPathEvidence do
  @moduledoc false

  @collector Loopex.M1Gate.RealPathCollector

  @doc """
  Reports identity observed by one real-path selector.

  The report is a map whose keys and binary values are validated by the
  standalone runner for the selected real-path profile. The runner, not the
  selector, owns the nonce, recorded time, and authoritative marker.
  """
  def report(report) do
    try do
      GenServer.call(@collector, {:report, report})
    catch
      :exit, _reason -> {:error, :collector_unavailable}
    end
  end
end

defmodule Loopex.M1Gate.RealPathCollector do
  @moduledoc false
  use GenServer

  def start_link(owner) when is_pid(owner),
    do: GenServer.start_link(__MODULE__, owner, name: __MODULE__)

  def reports(collector), do: GenServer.call(collector, :reports)

  @impl GenServer
  def init(owner), do: {:ok, %{owner: owner, reports: []}}

  @impl GenServer
  def handle_call({:report, report}, _from, state),
    do: {:reply, :ok, %{state | reports: [report | state.reports]}}

  def handle_call(:reports, {owner, _tag}, %{owner: owner} = state),
    do: {:reply, Enum.reverse(state.reports), state}

  def handle_call(:reports, _from, state), do: {:reply, {:error, :not_owner}, state}
end

defmodule Loopex.M1Gate.SelectorRunner do
  @moduledoc false

  alias Loopex.M1Gate.ExUnitFormatter
  alias Loopex.M1Gate.ExUnitReport

  @nonce ~r/\A[0-9a-f]{32}\z/u
  @input_header "LOOPEX_M1_SELECTOR_V1"
  @max_provider_bytes 16_384
  @max_input_bytes byte_size(@input_header) + 1 + 32 + 1 + @max_provider_bytes + 1
  @app_name ~r/\A[a-z][a-z0-9_]*\z/u
  @real_path_fields %{
    "model" => ~w(provider model endpoint adapter_build),
    "combined" =>
      ~w(provider model endpoint adapter_build executor_build executor_identity tool_identity)
  }
  @placeholder_values ~w(tbd todo pending unknown -)

  def main(args) do
    input = IO.binread(:stdio, @max_input_bytes + 1)
    System.delete_env("LOOPEX_PROVIDER_API_KEY")

    result =
      try do
        with {:ok, invocation} <- arguments(args),
             {:ok, nonce, provider_key} <- input(input, not is_nil(invocation.real_path)),
             :ok <-
               ExUnitReport.invocation(
                 invocation.selector,
                 invocation.seed,
                 invocation.minimum,
                 invocation.policy,
                 invocation.expectations
               ),
             {:ok, root} <- absolute_directory(invocation.root, "repository root"),
             {:ok, build} <- absolute_directory(invocation.build, "isolated test build"),
             {:ok, selector_path, selector_bytes, directory_owner} <-
               selector(root, invocation.selector),
             :ok <- exact_owner(directory_owner, invocation.owner),
             {:ok, closure} <-
               compiled_closure(
                 build,
                 invocation.owner,
                 invocation.internal,
                 invocation.allowed
               ),
             :ok <- add_code_paths(closure),
             :ok <- start_owner(invocation.owner) do
          run(
            invocation,
            nonce,
            provider_key,
            root,
            selector_path,
            selector_bytes
          )
        end
      rescue
        _ -> {:error, "authoritative selector execution failed"}
      catch
        _, _ -> {:error, "authoritative selector execution failed"}
      end

    case result do
      {:error, reason} ->
        IO.puts(:stderr, "M1 selector runner refused: #{reason}")
        System.halt(1)

      _ ->
        IO.puts(:stderr, "M1 selector runner refused an unexpected result")
        System.halt(1)
    end
  end

  defp arguments(["--only-real-provider", "--real-path", profile | rest])
       when profile in ["model", "combined"],
       do: arguments(rest, profile)

  defp arguments(["--only-real-provider" | _rest]),
    do: {:error, "real-provider selector must name one exact real-path profile"}

  defp arguments(args), do: arguments(args, nil)

  defp arguments(
         [root, build, selector, owner, internal, allowed, seed, minimum, policy | encoded],
         real_path
       )
       when encoded != [] do
    with {seed, ""} <- Integer.parse(seed),
         {minimum, ""} when minimum > 0 <- Integer.parse(minimum),
         {:ok, policy} <- policy(policy),
         {:ok, owner} <- application(owner),
         {:ok, internal} <- applications(internal),
         {:ok, allowed} <- applications(allowed),
         true <- owner in internal and owner in allowed,
         true <- Enum.all?(allowed, &(&1 in internal)),
         {:ok, expectations} <- expectations(encoded) do
      {:ok,
       %{
         root: root,
         build: build,
         selector: selector,
         owner: owner,
         internal: internal,
         allowed: allowed,
         seed: seed,
         minimum: minimum,
         policy: policy,
         expectations: expectations,
         real_path: real_path
       }}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, "invalid selector-runner arguments"}
    end
  end

  defp arguments(_, _), do: {:error, "invalid selector-runner arguments"}

  defp application(name) do
    if Regex.match?(@app_name, name) and byte_size(name) <= 64,
      do: {:ok, String.to_atom(name)},
      else: {:error, "application identity is malformed"}
  end

  defp applications(encoded) do
    names = String.split(encoded, ",", trim: true)

    with true <- encoded != "" and Enum.join(names, ",") == encoded,
         parsed <- Enum.map(names, &application/1),
         true <- Enum.all?(parsed, &match?({:ok, _}, &1)),
         values <- Enum.map(parsed, fn {:ok, value} -> value end),
         true <- values == values |> Enum.uniq() |> Enum.sort() do
      {:ok, values}
    else
      _ -> {:error, "application inventory is malformed"}
    end
  end

  defp policy("zero"), do: {:ok, :zero}
  defp policy("positive"), do: {:ok, :positive}
  defp policy(_), do: {:error, "exclusion policy must be zero or positive"}

  defp expectations(encoded) do
    Enum.reduce_while(encoded, {:ok, []}, fn item, {:ok, acc} ->
      case String.split(item, "=", parts: 2) do
        [state, name] when state in ~w(passed failed skipped excluded) and name != "" ->
          {:cont, {:ok, [{state, name} | acc]}}

        _ ->
          {:halt, {:error, "locked test expectation is malformed"}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp input(input, false) do
    case input do
      <<@input_header, 0, nonce::binary-size(32), 0, 0>> ->
        if Regex.match?(@nonce, nonce), do: {:ok, nonce, nil}, else: {:error, "invalid nonce"}

      _ ->
        {:error, "default selector input is malformed"}
    end
  end

  defp input(input, true) do
    case input do
      <<@input_header, 0, nonce::binary-size(32), 0, key::binary>>
      when byte_size(key) > 1 and byte_size(key) <= @max_provider_bytes + 1 ->
        cond do
          not String.ends_with?(key, <<0>>) ->
            {:error, "provider input is malformed"}

          not Regex.match?(@nonce, nonce) ->
            {:error, "invalid nonce"}

          :binary.match(binary_part(key, 0, byte_size(key) - 1), <<0>>) != :nomatch ->
            {:error, "provider input is malformed"}

          true ->
            {:ok, nonce, binary_part(key, 0, byte_size(key) - 1)}
        end

      _ ->
        {:error, "real-provider selector input is malformed"}
    end
  end

  defp absolute_directory(path, label) do
    expanded = Path.expand(path)

    if Path.type(path) == :absolute and expanded == path and File.dir?(path) and
         File.lstat!(path).type != :symlink do
      {:ok, path}
    else
      {:error, "#{label} is not one absolute ordinary directory"}
    end
  end

  defp selector(root, selector) do
    with :ok <- no_symlink_components(root, selector),
         {:ok, %{type: :regular}} <- File.lstat(Path.join(root, selector)),
         {:ok, entry} <- tracked_entry(root, selector),
         :ok <- ordinary_index_entry(entry, selector),
         {:ok, bytes} <- File.read(Path.join(root, selector)),
         ["apps", directory, "test" | _] <- String.split(selector, "/"),
         true <- Regex.match?(@app_name, directory) do
      {:ok, Path.join(root, selector), bytes, String.to_atom(directory)}
    else
      _ -> {:error, "selector is not one tracked ordinary file owned by an application"}
    end
  end

  defp exact_owner(owner, owner), do: :ok

  defp exact_owner(_directory_owner, _declared_owner),
    do: {:error, "selector owner disagrees with project authority"}

  defp no_symlink_components(root, relative) do
    relative
    |> String.split("/")
    |> Enum.reduce_while(root, fn component, prefix ->
      path = Path.join(prefix, component)

      case File.lstat(path) do
        {:ok, %{type: :symlink}} -> {:halt, :error}
        {:ok, _} -> {:cont, path}
        {:error, _} -> {:halt, :error}
      end
    end)
    |> case do
      :error -> {:error, "selector crosses a symlink or missing component"}
      _ -> :ok
    end
  end

  defp tracked_entry(root, selector) do
    case System.cmd("git", ["ls-files", "--stage", "--", selector],
           cd: root,
           env: [{"GIT_OPTIONAL_LOCKS", "0"}],
           stderr_to_stdout: true
         ) do
      {entry, 0} -> {:ok, entry}
      _ -> {:error, "selector index entry is unavailable"}
    end
  end

  defp ordinary_index_entry(entry, selector) do
    case String.split(String.trim_trailing(entry, "\n"), [" ", "\t"]) do
      ["100644", object, "0", ^selector] ->
        if Regex.match?(~r/\A[0-9a-f]+\z/u, object), do: :ok, else: :error

      _ ->
        :error
    end
  end

  defp compiled_closure(build, owner, internal, allowed) do
    owner_file = Path.join([build, "lib", Atom.to_string(owner), "ebin", "#{owner}.app"])

    if File.regular?(owner_file),
      do:
        walk_closure(
          build,
          [owner],
          MapSet.new(),
          [],
          MapSet.new(internal),
          MapSet.new(allowed)
        ),
      else: {:error, "owning application is absent from the isolated test build"}
  end

  defp walk_closure(_build, [], _seen, paths, _internal, _allowed),
    do: {:ok, Enum.reverse(paths)}

  defp walk_closure(build, [application | rest], seen, paths, internal, allowed) do
    cond do
      not safe_application?(application) ->
        {:error, "compiled application identity is not one safe application name"}

      MapSet.member?(internal, application) and not MapSet.member?(allowed, application) ->
        {:error, "compiled dependency closure reaches an undeclared sibling application"}

      MapSet.member?(seen, application) ->
        walk_closure(build, rest, seen, paths, internal, allowed)

      true ->
        ebin = Path.join([build, "lib", Atom.to_string(application), "ebin"])
        app_file = Path.join(ebin, "#{application}.app")

        if File.regular?(app_file) do
          with :ok <- ordinary_tree_path(build, ebin),
               :ok <- ordinary_ebin(ebin),
               {:ok, dependencies} <- app_spec(app_file, application) do
            walk_closure(
              build,
              dependencies ++ rest,
              MapSet.put(seen, application),
              [ebin | paths],
              internal,
              allowed
            )
          end
        else
          if MapSet.member?(internal, application) do
            {:error, "an allowed internal dependency is absent from the isolated test build"}
          else
            walk_closure(
              build,
              rest,
              MapSet.put(seen, application),
              paths,
              internal,
              allowed
            )
          end
        end
    end
  end

  defp safe_application?(application) when is_atom(application) do
    name = Atom.to_string(application)
    Regex.match?(@app_name, name) and byte_size(name) <= 64
  end

  defp safe_application?(_application), do: false

  defp ordinary_tree_path(root, path) do
    relative = Path.relative_to(path, root)

    if relative == path or String.starts_with?(relative, "../") do
      {:error, "compiled application escaped the isolated build"}
    else
      no_symlink_components(root, relative)
    end
  end

  defp ordinary_ebin(ebin) do
    with {:ok, entries} <- File.ls(ebin),
         true <- entries != [],
         true <-
           Enum.all?(entries, fn entry ->
             match?({:ok, %File.Stat{type: :regular}}, File.lstat(Path.join(ebin, entry)))
           end) do
      :ok
    else
      _ -> {:error, "compiled application ebin contains a link or non-ordinary entry"}
    end
  end

  defp app_spec(path, expected) do
    case :file.consult(String.to_charlist(path)) do
      {:ok, [{:application, ^expected, properties}]} when is_list(properties) ->
        applications = Keyword.get(properties, :applications, [])
        included_applications = Keyword.get(properties, :included_applications, [])

        if is_list(applications) and Enum.all?(applications, &is_atom/1) and
             is_list(included_applications) and Enum.all?(included_applications, &is_atom/1),
           do: {:ok, Enum.uniq(applications ++ included_applications)},
           else: {:error, "compiled application has an invalid dependency closure"}

      _ ->
        {:error, "compiled application identity does not match its owner"}
    end
  end

  defp add_code_paths(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case Code.prepend_path(path) do
        true -> {:cont, :ok}
        _ -> {:halt, {:error, "compiled dependency closure could not be loaded"}}
      end
    end)
  end

  defp start_owner(owner) do
    case Application.ensure_all_started(owner) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, "owning application could not start without provider credentials"}
    end
  end

  defp run(invocation, nonce, provider_key, root, selector_path, selector_bytes) do
    ExUnit.start(autorun: false)
    {:ok, collector} = Agent.start(fn -> nil end)

    config = %{
      collector: collector,
      owner: self(),
      root: root,
      selector: invocation.selector,
      seed: invocation.seed,
      include: if(invocation.real_path, do: [:real_provider], else: []),
      exclude: if(invocation.real_path, do: [:test], else: [:real_provider])
    }

    ExUnit.configure(
      autorun: false,
      formatters: [ExUnitFormatter],
      seed: invocation.seed,
      dry_run: false,
      repeat_until_failure: 0,
      only_test_ids: nil,
      max_failures: :infinity,
      include: config.include,
      exclude: config.exclude,
      failures_manifest_path: nil,
      loopex_m1_gate: config
    )

    {:ok, real_path_collector} = Loopex.M1Gate.RealPathCollector.start_link(self())

    {stats, events, real_path_reports} =
      try do
        if invocation.real_path, do: System.put_env("LOOPEX_PROVIDER_API_KEY", provider_key)
        Code.compile_string(selector_bytes, selector_path)
        runner = ExUnit.async_run()
        stats = ExUnit.await_run(runner)
        await_formatter!(collector)
        reports = Loopex.M1Gate.RealPathCollector.reports(real_path_collector)
        {stats, Agent.get(collector, & &1), reports}
      after
        System.delete_env("LOOPEX_PROVIDER_API_KEY")
      end

    Agent.stop(collector)
    GenServer.stop(real_path_collector)
    finish(stats, events, real_path_reports, nonce, provider_key, invocation)
  end

  defp await_formatter!(collector) do
    receive do
      {:loopex_m1_suite_finished, ^collector} -> :ok
    after
      5_000 -> raise "authoritative formatter did not finish"
    end
  end

  defp finish(stats, events, real_path_reports, nonce, provider_key, invocation) do
    with {:ok, report} <-
           ExUnitReport.validate(
             events,
             stats,
             invocation.selector,
             invocation.seed,
             invocation.minimum,
             invocation.policy,
             invocation.expectations
           ),
         {:ok, identity} <-
           real_path_identity(invocation.real_path, real_path_reports, provider_key) do
      case identity do
        nil ->
          IO.write(
            "\nLOOPEX_EXUNIT_REPORT nonce=#{nonce} selector=#{invocation.selector} " <>
              "seed=#{invocation.seed} executed=#{report.executed} " <>
              "digest=sha256:#{report.digest}\n"
          )

        fields ->
          recorded = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
          digest = real_path_digest(report.digest, invocation.real_path, fields, recorded)
          suffix = Enum.map_join(fields ++ [{"recorded", recorded}], " ", &join_field/1)

          IO.write(
            "\nLOOPEX_EXUNIT_REPORT nonce=#{nonce} selector=#{invocation.selector} " <>
              "seed=#{invocation.seed} executed=#{report.executed} " <>
              "digest=sha256:#{digest} #{suffix}\n"
          )
      end

      System.halt(0)
    else
      {:error, reason} ->
        IO.puts(:stderr, "M1 selector runner refused: #{reason}")
        System.halt(1)
    end
  end

  defp real_path_identity(nil, [], _provider_key), do: {:ok, nil}

  defp real_path_identity(nil, _reports, _provider_key),
    do: {:error, "default selector reported real-path identity"}

  defp real_path_identity(profile, [report], provider_key) when is_map(report) do
    fields = Map.fetch!(@real_path_fields, profile)

    with true <- Map.keys(report) |> Enum.sort() == Enum.sort(fields),
         true <- Enum.all?(fields, &valid_identity_value?(report[&1])),
         true <- report["adapter_build"] == "loopex_llm_reqllm@0.0.0",
         true <-
           profile != "combined" or
             report["executor_build"] == "loopex_executor_local@0.0.0",
         true <- Enum.all?(fields, &credential_absent?(report[&1], provider_key)) do
      {:ok, Enum.map(fields, &{&1, report[&1]})}
    else
      _ -> {:error, "real-path identity report is malformed"}
    end
  end

  defp real_path_identity(_profile, [_report], _provider_key),
    do: {:error, "real-path identity report is malformed"}

  defp real_path_identity(_profile, [], _provider_key),
    do: {:error, "real-path selector did not report identity"}

  defp real_path_identity(_profile, _reports, _provider_key),
    do: {:error, "real-path selector did not report identity exactly once"}

  defp valid_identity_value?(value) when is_binary(value) and byte_size(value) > 0 do
    printable? = value |> :binary.bin_to_list() |> Enum.all?(&(&1 in 0x21..0x7E))
    printable? and String.downcase(value) not in @placeholder_values
  end

  defp valid_identity_value?(_value), do: false

  defp credential_absent?(value, provider_key),
    do: :binary.match(value, provider_key) == :nomatch

  defp real_path_digest(report_digest, profile, fields, recorded) do
    {report_digest, profile, fields, recorded}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp join_field({key, value}), do: "#{key}=#{value}"
end

case System.argv() do
  ["--loopex-m1-selector" | args] -> Loopex.M1Gate.SelectorRunner.main(args)
  _ -> :ok
end
