defmodule LoopexComposition.Ephemeral.OptionsTest do
  @moduledoc false
  use ExUnit.Case, async: false
  alias LoopexComposition.Ephemeral.Options
  @max 18_446_744_073_709_551_615

  defmodule Policy do
    @moduledoc false
    def decide(_), do: {:allow, nil}
  end

  defmodule WrongArity do
    @moduledoc false
    def decide(_, _), do: {:allow, nil}
  end

  @identity_boundary String.to_atom("Elixir." <> String.duplicate("É", 123))
  @identity_too_long String.to_atom("Elixir." <> String.duplicate("É", 123) <> "P")
  for name <- [@identity_boundary, @identity_too_long] do
    defmodule name do
      @moduledoc false
      def decide(_), do: {:allow, nil}
    end
  end

  setup do
    original = System.get_env("LOOPEX_MODEL")
    System.delete_env("LOOPEX_MODEL")

    on_exit(fn ->
      if original,
        do: System.put_env("LOOPEX_MODEL", original),
        else: System.delete_env("LOOPEX_MODEL")
    end)

    :ok
  end

  test "defaults defer workspace and address resolution" do
    assert Options.parse(policy: Policy) ==
             {:ok,
              %{
                policy: Policy,
                model: "ollama:llama3.2",
                req_llm: nil,
                tools: :coding,
                questions: false,
                skills: [],
                cwd: nil,
                max_steps: 16,
                deadline_ms: 600_000,
                max_tokens: 4096,
                context_token_budget: nil,
                reasoning: "default",
                instructions: nil,
                system_class_tokens: nil,
                timeout: 630_000,
                base_url: nil,
                maintenance_instructions: nil,
                provider_bindings: nil,
                maintenance_model: nil,
                trace: nil
              }}
  end

  test "a contextual policy reference needs decide/2 and keeps its context private" do
    contextual = %{module: WrongArity, context: %{"capture" => "private"}}
    assert {:ok, %{policy: ^contextual}} = Options.parse(policy: contextual)

    for invalid <- [
          %{module: Policy, context: nil},
          %{module: WrongArity},
          %{module: WrongArity, context: nil, extra: 1},
          %{module: nil, context: nil}
        ] do
      assert Options.parse(policy: invalid) == {:error, {:invalid_option, :policy}}
    end
  end

  test "questions require a Boolean startup opt-in and a nonempty tool profile" do
    for tools <- [:coding, :read_only], enabled <- [false, true] do
      assert {:ok, %{questions: ^enabled}} =
               Options.parse(policy: Policy, tools: tools, questions: enabled)
    end

    assert {:ok, %{questions: false}} = Options.parse(policy: Policy, tools: :none)

    assert Options.parse(policy: Policy, tools: :none, questions: true) ==
             {:error, {:invalid_option, :questions}}

    for invalid <- [nil, 0, 1, "true", %{}] do
      assert Options.parse(policy: Policy, questions: invalid) ==
               {:error, {:invalid_option, :questions}}
    end

    assert Options.parse(policy: Policy, question_responder: fn _ -> :decline end) ==
             {:error, {:invalid_option, :unknown_key}}

    assert Options.ask_options([questions: true], 42) ==
             {:error, {:invalid_option, :unknown_key}}
  end

  test "instructions reasoning and system ceiling are closed startup selections" do
    block = %{
      "version" => "host.v1",
      "base" => "Exact bytes 猫\n",
      "environment" => "captured environment",
      "appendix" => "trusted appendix"
    }

    for reasoning <- ~w(default none low medium high) do
      assert {:ok, selected} =
               Options.parse(
                 policy: Policy,
                 instructions: block,
                 reasoning: reasoning,
                 system_class_tokens: @max
               )

      assert selected.reasoning == reasoning
      assert selected.system_class_tokens == @max
      assert Map.delete(selected.instructions, "digest") == block
      assert :ok = Loopex.Runtime.Instructions.validate(selected.instructions)
    end

    for invalid <- [nil, %{}, Map.put(block, "extra", true), Map.put(block, "digest", "forged")] do
      assert {:error, {:invalid_option, :instructions}} =
               Options.parse(policy: Policy, instructions: invalid)
    end

    for invalid <- [nil, :default, "adaptive", "DEFAULT"] do
      assert {:error, {:invalid_option, :reasoning}} =
               Options.parse(policy: Policy, reasoning: invalid)
    end

    for invalid <- [nil, 0, -1, @max + 1, "1000"] do
      assert {:error, {:invalid_option, :system_class_tokens}} =
               Options.parse(policy: Policy, system_class_tokens: invalid)
    end

    for {key, value} <- [instructions: block, reasoning: "none", system_class_tokens: 1000] do
      assert {:error, {:invalid_option, :unknown_key}} = Options.ask_options([{key, value}], 42)
    end
  end

  test "run consumes only an enabled unary callback and leaves startup grammar closed" do
    callback = fn _ -> :decline end
    options = [policy: Policy, questions: true, question_responder: callback]
    assert {:ok, [policy: Policy, questions: true], ^callback} = Options.run_options(options)
    assert {:ok, [policy: Policy], nil} = Options.run_options(policy: Policy)

    for bad <- [nil, false, self(), fn -> :decline end, fn _, _ -> :decline end] do
      assert Options.run_options(policy: Policy, questions: true, question_responder: bad) ==
               {:error, {:invalid_option, :question_responder}}
    end

    assert Options.run_options(policy: Policy, question_responder: callback) ==
             {:error, {:invalid_option, :question_responder}}

    assert Options.run_options(policy: Policy, questions: false, question_responder: callback) ==
             {:error, {:invalid_option, :question_responder}}

    assert Options.run_options(options ++ [question_responder: callback]) ==
             {:error, {:invalid_option, :duplicate_key}}

    assert Options.run_options(options ++ [unknown: nil]) ==
             {:error, {:invalid_option, :unknown_key}}

    assert Options.ask_options([question_responder: callback], 42) ==
             {:error, {:invalid_option, :unknown_key}}
  end

  test "trace is a closed startup map, validated even when disabled" do
    assert {:ok, selected} = Options.parse(policy: Policy, trace: %{"enabled" => true})
    assert selected.trace.enabled
    assert selected.trace.configuration.sink == :diagnostics

    assert {:ok, selected} = Options.parse(policy: Policy, trace: %{})
    refute selected.trace.enabled

    for invalid <- [
          nil,
          true,
          self(),
          %{enabled: true},
          %{"sink" => self()},
          %{"enabled" => false, "max_entry_bytes" => 4097},
          %{"modules" => ["NotCompiled.Module"]}
        ] do
      assert Options.parse(policy: Policy, trace: invalid) == {:error, {:invalid_option, :trace}}
    end

    assert Options.ask_options([trace: %{}], 1_000) == {:error, {:invalid_option, :unknown_key}}
  end

  test "values validate in fixed order independent of keyword order" do
    faults = [
      policy: nil,
      model: "bad",
      req_llm: nil,
      tools: :bad,
      skills: nil,
      cwd: nil,
      max_steps: 0,
      deadline_ms: 0,
      max_tokens: 0,
      context_token_budget: 0,
      timeout: 0,
      base_url: nil
    ]

    for [{first, bad_first}, {second, bad_second}] <- Enum.chunk_every(faults, 2, 1, :discard) do
      pair = [{first, bad_first}, {second, bad_second}]

      for ordered <- [pair, Enum.reverse(pair)] do
        opts = if first == :policy, do: ordered, else: [{:policy, Policy} | ordered]
        assert Options.parse(opts) == {:error, {:invalid_option, first}}
      end
    end
  end

  test "numeric domains and saturating wait default" do
    for key <- [:max_steps, :deadline_ms, :context_token_budget, :timeout] do
      for value <- [1, @max] do
        assert {:ok, normalized} = Options.parse([{:policy, Policy}, {key, value}])
        assert normalized[key] == value
      end

      for value <- [0, -1, @max + 1, 1.0, nil, :infinity] do
        assert Options.parse([{:policy, Policy}, {key, value}]) ==
                 {:error, {:invalid_option, key}}
      end
    end

    for deadline <- [@max - 30_001, @max - 30_000, @max - 29_999, @max] do
      assert {:ok, normalized} = Options.parse(policy: Policy, deadline_ms: deadline)
      assert normalized.timeout == min(deadline + 30_000, @max)
    end

    for value <- [1, 1_000_000] do
      assert {:ok, _} = Options.parse(policy: Policy, max_tokens: value)
    end

    assert Options.parse(policy: Policy, max_tokens: 1_000_001) ==
             {:error, {:invalid_option, :max_tokens}}
  end

  test "maintenance instructions are explicit startup data with no per-call override" do
    block = %{"version" => "host.v1", "body" => "Exact bytes 猫\n"}

    for value <- [nil, block] do
      assert {:ok, selected} = Options.parse(policy: Policy, maintenance_instructions: value)
      assert selected.maintenance_instructions == value

      assert {:error, {:invalid_option, :unknown_key}} =
               Options.ask_options([maintenance_instructions: value], 42)
    end

    for invalid <- [
          %{},
          Map.put(block, "extra", true),
          %{block | "body" => ""},
          %{block | "body" => String.duplicate("x", 2049)}
        ] do
      assert {:error, :maintenance_instructions_invalid} =
               Options.parse(policy: Policy, maintenance_instructions: invalid)
    end
  end

  test "outer grammar wins over missing policy and invalid values" do
    for options <- [
          nil,
          %{},
          :options,
          [:policy],
          [{"policy", Policy}],
          [{:policy, Policy}, {:model, "bad"} | :bad]
        ] do
      assert Options.parse(options) == {:error, {:invalid_option, :options}}
    end

    assert Options.parse([{:policy, nil} | :bad]) == {:error, {:invalid_option, :options}}

    assert Options.parse(policy: nil, tokenBudget: 1, policy: nil) ==
             {:error, {:invalid_option, :unknown_key}}

    assert Options.parse(policy: nil, policy: nil) == {:error, {:invalid_option, :duplicate_key}}

    assert Options.parse(policy: nil, policy: nil, unknown: nil) ==
             {:error, {:invalid_option, :unknown_key}}

    assert Options.parse(unknown: nil) == {:error, {:invalid_option, :unknown_key}}
    assert Options.parse(model: "bad") == {:error, {:composition, :host_policy_required}}
    assert Options.parse([]) == {:error, {:composition, :host_policy_required}}
  end

  test "ask options only override the positive uint64 timeout" do
    assert Options.ask_options([], 42) == {:ok, 42}

    for value <- [1, @max] do
      assert Options.ask_options([timeout: value], 42) == {:ok, value}
    end

    for value <- [nil, 0, -1, @max + 1, 1.0, :infinity] do
      assert Options.ask_options([timeout: value], 42) == {:error, {:invalid_option, :timeout}}
    end

    for key <- [
          :policy,
          :model,
          :req_llm,
          :tools,
          :skills,
          :cwd,
          :max_steps,
          :deadline_ms,
          :max_tokens,
          :context_token_budget,
          :base_url,
          :tokenBudget
        ] do
      assert Options.ask_options([{key, nil}, {:timeout, 0}, {:timeout, 0}], 42) ==
               {:error, {:invalid_option, :unknown_key}}
    end

    assert Options.ask_options([timeout: 0, timeout: 0], 42) ==
             {:error, {:invalid_option, :duplicate_key}}

    for options <- [nil, %{}, [:timeout], [{:timeout, 1} | :bad]] do
      assert Options.ask_options(options, 42) == {:error, {:invalid_option, :options}}
    end
  end

  test "prompt checks empty then byte ceiling then UTF8" do
    assert Options.prompt("") == {:error, {:invalid_prompt, :empty}}
    assert Options.prompt("a") == :ok
    assert Options.prompt(String.duplicate("é", 16_384)) == :ok

    assert Options.prompt(String.duplicate("a", 32_769)) ==
             {:error, {:invalid_prompt, :too_large}}

    assert Options.prompt(<<255>> <> String.duplicate("a", 32_768)) ==
             {:error, {:invalid_prompt, :too_large}}

    for prompt <- [<<255>>, <<195>>, nil, [], 1, %{}] do
      assert Options.prompt(prompt) == {:error, {:invalid_prompt, :invalid_utf8}}
    end
  end

  test "policy must load export decide/1 and have a bounded identity" do
    assert byte_size(inspect(@identity_boundary)) == 256
    assert {:ok, _} = Options.parse(policy: @identity_boundary)

    for policy <- [
          nil,
          "Policy",
          fn _ -> :allow end,
          WrongArity,
          String,
          LoopexComposition.OptionsMissingPolicy,
          @identity_too_long
        ] do
      assert Options.parse(policy: policy) == {:error, {:invalid_option, :policy}}
    end
  end

  test "model grammar admits unknown providers and retains the first-colon remainder" do
    for model <- ["x:y", "unknown:name", "ollama:name:tag", "x:" <> String.duplicate("é", 255)] do
      assert {:ok, normalized} = Options.parse(policy: Policy, model: model)
      assert normalized.model == model
    end

    for model <- [
          nil,
          [],
          "",
          "missing-colon",
          ":model",
          "provider:",
          <<255>>,
          "x:" <> String.duplicate("a", 511)
        ] do
      assert Options.parse(policy: Policy, model: model) == {:error, {:invalid_option, :model}}
    end

    for model <- ["", "invalid", "x:" <> String.duplicate("a", 511)] do
      System.put_env("LOOPEX_MODEL", model)
      assert Options.parse(policy: Policy) == {:error, {:invalid_option, :model}}
      assert {:ok, _} = Options.parse(policy: Policy, model: "ollama:override")
    end

    System.put_env("LOOPEX_MODEL", "unknown:environment:tag")
    assert {:ok, %{model: "unknown:environment:tag"}} = Options.parse(policy: Policy)
  end

  test "closed declarations admit each preset and only host-started ReqLLM" do
    for tools <- [:none, :coding, :read_only] do
      assert {:ok, %{tools: ^tools, req_llm: :host_started}} =
               Options.parse(policy: Policy, tools: tools, req_llm: :host_started)
    end

    for value <- [nil, true, "host_started", :started] do
      assert Options.parse(policy: Policy, req_llm: value) ==
               {:error, {:invalid_option, :req_llm}}
    end

    for value <- [nil, [], "coding", :all] do
      assert Options.parse(policy: Policy, tools: value) == {:error, {:invalid_option, :tools}}
    end
  end

  test "bounded paths require valid nonempty UTF8 without NUL but no filesystem resolution" do
    for key <- [:cwd, :base_url] do
      for value <- ["not-an-existing-path-or-URL", String.duplicate("é", 32_768)] do
        assert {:ok, normalized} = Options.parse([{:policy, Policy}, {key, value}])
        assert normalized[key] == value
      end

      for value <- [nil, [], "", <<255>>, "a" <> <<0>>, String.duplicate("a", 65_537)] do
        assert Options.parse([{:policy, Policy}, {key, value}]) ==
                 {:error, {:invalid_option, key}}
      end
    end
  end

  test "skills count proper entries before validating paths and leave duplicates to the helper" do
    for paths <- [[], ["same", "same"], List.duplicate(String.duplicate("é", 32_768), 4)] do
      assert {:ok, %{skills: ^paths}} = Options.parse(policy: Policy, skills: paths)
    end

    for paths <- [
          nil,
          "path",
          ["x" | :bad],
          [""],
          [nil],
          [<<255>>],
          ["x" <> <<0>>],
          [String.duplicate("a", 65_537)]
        ] do
      assert Options.parse(policy: Policy, skills: paths) == {:error, {:invalid_option, :skills}}
    end

    for paths <- [List.duplicate("x", 5), List.duplicate(nil, 5), List.duplicate("x", 6)] do
      assert Options.parse(policy: Policy, skills: paths) ==
               {:error, {:invalid_option, :too_many_skills}}
    end

    assert Options.parse(policy: Policy, skills: [1, 2, 3, 4, 5 | :bad]) ==
             {:error, {:invalid_option, :skills}}
  end
end
