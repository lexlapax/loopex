#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/loopex-escript-inventory.XXXXXX")
trap 'rm -rf "$fixture"' EXIT

elixir -e '
  [root] = System.argv()
  entries = ~w(logger/ebin/logger.app logger/ebin/Elixir.Logger.beam
               req_llm/ebin/req_llm.app req/ebin/req.app finch/ebin/finch.app)

  for {label, omitted, empty?} <- [
        {"good", nil, false},
        {"missing", "logger/ebin/logger.app", false},
        {"empty", nil, true}
      ] do
    files =
      for name <- entries, name != omitted do
        contents = if empty? and name == "logger/ebin/logger.app", do: <<>>, else: "fixture"
        {String.to_charlist(name), contents}
      end

    {:ok, {_, zip}} = :zip.create(~c"fixture.zip", files, [:memory])
    File.write!(Path.join(root, label), "#!/usr/bin/env escript\n%% \n" <> zip)
  end

  duplicate = [
    {~c"logger/ebin/logger.app", "first"},
    {~c"logger/ebin/logger.app", "second"}
  ]
  {:ok, {_, zip}} = :zip.create(~c"fixture.zip", duplicate, [:memory])
  File.write!(Path.join(root, "duplicate"), "#!/usr/bin/env escript\n%% \n" <> zip)
' -- "$fixture"

elixir scripts/escript-inventory.exs "$fixture/good" "$fixture/good" \
  >"$fixture/positive.log"
grep -q 'escript-inventory: PASS good' "$fixture/positive.log"
if elixir scripts/escript-inventory.exs "$fixture/good" "$fixture/missing" \
  >"$fixture/negative.log" 2>&1; then
  echo 'escript-inventory-test: missing logger.app was accepted' >&2
  exit 1
fi
grep -q 'missing required applications' "$fixture/negative.log"
for failure in empty duplicate; do
  if elixir scripts/escript-inventory.exs "$fixture/good" "$fixture/$failure" \
    >"$fixture/$failure.log" 2>&1; then
    echo "escript-inventory-test: $failure archive was accepted" >&2
    exit 1
  fi
done
grep -q 'empty required application entry' "$fixture/empty.log"
grep -q 'duplicate archive entries' "$fixture/duplicate.log"
printf 'not an escript\n' >"$fixture/invalid"
if elixir scripts/escript-inventory.exs "$fixture/good" "$fixture/invalid" \
  >"$fixture/invalid.log" 2>&1; then
  echo 'escript-inventory-test: invalid archive was accepted' >&2
  exit 1
fi
grep -q 'invalid escript archive' "$fixture/invalid.log"
printf 'escript-inventory-test: PASS prefixed, missing, empty, duplicate and invalid controls\n'
