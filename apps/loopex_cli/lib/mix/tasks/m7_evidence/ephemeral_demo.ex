defmodule Mix.Tasks.Loopex.M7Evidence.EphemeralDemo do
  @moduledoc """
  ## Concept

  The attended host for M7's ephemeral question case. It runs the ambiguous
  feature task through one public ephemeral call, shows the model's real
  question to the named operator and passes the operator's typed answer back
  through the ordinary answer path. No canned answer stands in for the
  operator; the interaction ends with that runtime.

  ## Technical depth

  `run/3` takes `--workspace DIR --operator NAME --record FILE [--model ID]
  [--base-url URL]` and optional prompt words (the feature fixture's prompt by
  default). The question responder prints the prompt and numbered choices and
  reads one line: a choice label or number answers with that choice,
  `decline` declines, anything else answers as text. The exclusive record file
  keeps the operator, question, typed answer, selected choice label
  and outcome; credentials never enter
  it. Exit status 0 means the call completed after the operator answered.
  """

  alias LoopexComposition.Ephemeral

  @default_prompt "Add nil_mode to RowEncoder.encode/2, preserving ordinary rows. Both explicit modes must work: empty renders nil as an empty field; literal_null renders nil as null. The default is deliberately undecided. Before editing, call the ask tool with question \"Which default should nil_mode use?\" and choices [\"empty\", \"literal_null\"]. Implement the operator's chosen default and change only lib/row_encoder.ex."

  @doc false
  def run(argv, input, output, extra \\ []) do
    {opts, words, []} =
      OptionParser.parse(argv,
        strict: [
          workspace: :string,
          operator: :string,
          record: :string,
          model: :string,
          base_url: :string
        ]
      )

    prompt = if words == [], do: @default_prompt, else: Enum.join(words, " ")
    parent = self()

    responder = fn question ->
      IO.puts(output, "question: " <> question["prompt"])

      for {choice, index} <- Enum.with_index(question["choices"] || [], 1),
          do: IO.puts(output, "  #{index}. #{choice["label"]}")

      IO.write(output, "answer> ")
      line = input |> IO.read(:line) |> to_string() |> String.trim()
      response = response(question["choices"] || [], line)
      send(parent, {:operator_answer, question, line, response})
      elem(response, 0)
    end

    options =
      [
        policy: LoopexCli.Policy.AllowAll,
        cwd: opts[:workspace],
        tools: :coding,
        questions: true,
        # Concept: the coding tools plus the question tool exceed the default
        # system budget. Technical depth: the host widens only that ceiling.
        system_class_tokens: 4_000,
        # The host composes the instruction envelope; this demonstration's is fixed.
        instructions: %{
          "version" => "m7.ephemeral.v1",
          "base" => "Complete the task using the selected tools and the operator's answers.",
          "environment" => "",
          "appendix" => ""
        },
        question_responder: responder
      ] ++
        Enum.flat_map([model: opts[:model], base_url: opts[:base_url]], fn
          {_key, nil} -> []
          pair -> [pair]
        end)

    result = Ephemeral.run(prompt, Keyword.merge(options, extra))

    answered =
      receive do
        {:operator_answer, question, line, {_response, label}} ->
          %{"prompt" => question["prompt"], "answer" => line, "choice" => label}
      after
        0 -> nil
      end

    outcome =
      case result do
        {:ok, %{outcome: outcome}} -> Atom.to_string(outcome)
        {:error, reason} -> "error:" <> inspect(reason)
      end

    record = %{"operator" => opts[:operator], "question" => answered, "outcome" => outcome}
    {:ok, encoded} = LoopexProtocol.Frame.encode(record)
    :ok = File.write(opts[:record], encoded, [:exclusive])
    IO.puts(output, "outcome: " <> outcome)
    if outcome == "completed" and answered, do: 0, else: 1
  end

  defp response(_choices, "decline"), do: {:decline, nil}

  defp response(choices, line) do
    selected =
      Enum.with_index(choices, 1)
      |> Enum.find(fn {choice, index} -> line in [choice["label"], Integer.to_string(index)] end)

    case selected do
      {choice, _} -> {{:choice, choice["id"]}, choice["label"]}
      nil -> {{:text, line}, nil}
    end
  end
end
