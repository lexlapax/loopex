# The trusted M7 fixture wrapper. Run from the clean candidate checkout:
#
#   mix run --no-start scripts/m7-fixture-chat.exs -- --lane m7-operator \
#     --attempts-index /retained/m7/attempts.jsonl --writer W --host H \
#     --markers /retained/m7/markers --run-root /retained/m7/runs \
#     --operator Maintainer [--create] [--continue] [--terminal] \
#     [--external-repository ~/projects/lexlapax/lapaxworks] [--check] \
#     chat --config /retained/m7/config.json
#
# It validates the ordinary explicit configuration first, injects only the
# pinned fixture policy through host composition, records every case in the
# attempts index before dispatch and independently reruns each oracle. The
# command line carries no policy module, command text or credential value.
{:ok, _} = Application.ensure_all_started(:loopex_cli)
:ok = :logger.set_primary_config(:level, :none)
:ok = :io.setopts(:standard_io, encoding: :latin1)

argv =
  case System.argv() do
    ["--" | rest] -> rest
    rest -> rest
  end

System.halt(Mix.Tasks.Loopex.M7Evidence.CaseRunner.main(argv))
