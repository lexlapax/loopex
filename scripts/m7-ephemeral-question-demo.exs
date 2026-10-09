# A rehearsal of the attended host for M7's ephemeral question case (V5.6);
# lane evidence comes from the fixture wrapper with --terminal. Run from the
# candidate checkout with the operator at the terminal:
#
#   mix run --no-start scripts/m7-ephemeral-question-demo.exs -- \
#     --workspace /retained/m7/ephemeral-workspace --operator Maintainer \
#     --record /retained/m7/ephemeral-question.json --model anthropic:claude-haiku-4-5
#
# It shows the model's real question and sends the operator's typed answer
# through the public ephemeral answer path; nothing is answered for them.
{:ok, _} = Application.ensure_all_started(:loopex_cli)
:ok = :logger.set_primary_config(:level, :none)

argv =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

System.halt(Mix.Tasks.Loopex.M7Evidence.EphemeralDemo.run(argv, :stdio, :stdio))
