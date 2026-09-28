#!/usr/bin/env bash
# Executes the release runner's actual parser, preflight and lane helper.
# No fixture claims to execute a model workflow or substitute for a release.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
source "$root/scripts/lib/release-lane.sh"
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-release-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
tree="$work/tree"
retain="$work/retained"
mkdir -p "$tree/apps/fixture" "$tree/scripts" "$retain"
cp "$root/scripts/suite-summary.sh" "$tree/scripts/"
without_credential() { env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY "$@"; }

fail() { printf 'check-release-test: %s\n' "$*" >&2; exit 1; }
expect_refusal() {
  local status=0
  (release_select "$@") >"$work/parser-output" 2>&1 || status=$?
  [ "$status" -eq 2 ] || fail "selector refusal returned $status"
}
release_select
for row in 1 2 3 4 5 6 7 8 9 10 11; do release_selected "real-provider-$row" || fail "full omitted row $row"; done
release_selected node_client && release_selected long_bound && release_selected cross_uid &&
  release_selected rollback || fail 'full omitted a group'
release_select --only real_provider --only real-provider-5 --only long_bound
count=0
for row in 1 2 3 4 5 6 7 8 9 10 11; do
  if release_selected "real-provider-$row"; then count=$((count + 1)); fi
done
[ "$count" -eq 9 ] || fail 'unattended provider union is not nine rows'
if release_selected node_client || release_selected cross_uid; then fail 'selection expanded into other groups'; fi
release_needs_node || fail 'provider group omitted Node-dependent rows'
release_select --only real-provider-5
release_needs_provider || fail 'provider row omitted credential preflight'
if release_needs_node || release_needs_ollama; then fail 'provider row 5 has unrelated preflights'; fi
release_select --only real-provider-10
if release_needs_provider || release_needs_node; then fail 'local Ollama row has unrelated preflights'; fi
release_needs_ollama || fail 'local Ollama row omitted its model preflight'
release_select --only real-provider-11
release_needs_provider || fail 'hosted ephemeral row omitted credential preflight'
if release_needs_node || release_needs_ollama; then fail 'hosted ephemeral row has unrelated preflights'; fi
release_select --only long_bound
if release_needs_provider || release_needs_node; then fail 'long_bound has unrelated preflights'; fi
release_select --only node_client
release_needs_node || fail 'node_client omitted its Node preflight'
if release_needs_provider; then fail 'node_client spuriously requires a credential'; fi
expect_refusal --only
release_select --only rollback
release_selected rollback || fail 'rollback selector did not select its lane'
if release_needs_provider || release_needs_node; then fail 'rollback has unrelated preflights'; fi
release_select --only long_bound
expect_refusal --only real-provider-1
expect_refusal --only real-provider-2
expect_refusal --only real-provider-12
expect_refusal --only node_client --only node_client
expect_refusal --help

# The actual manifest census rejects a duplicated case even with the right
# number of rows. It checks every definition before any provider lane can run.
manifest="$work/manifest"
for index in 1 2 3; do
  printf 'fixture|test/cases.exs|case %s\n' "$index" >>"$manifest"
done
mkdir "$tree/apps/fixture/test"
for index in 1 2 3; do
  printf '  test "case %s" do\n  end\n' "$index" >>"$tree/apps/fixture/test/cases.exs"
done
release_manifest_valid "$manifest" "$tree" 3 || fail 'valid complete manifest refused'
head -n 2 "$manifest" >"$work/duplicate-manifest"
head -n 1 "$manifest" >>"$work/duplicate-manifest"
if release_manifest_valid "$work/duplicate-manifest" "$tree" 3 >"$work/manifest-output" 2>&1; then
  fail 'duplicate case replaced a required manifest witness'
fi
if release_manifest_valid "$manifest" "$tree" 4 >"$work/manifest-output" 2>&1; then
  fail 'wrong manifest count passed'
fi
printf 'fixture|test/cases.exs|undefined\n' >"$work/missing-manifest"
if release_manifest_valid "$work/missing-manifest" "$tree" 1 >"$work/manifest-output" 2>&1; then
  fail 'undefined manifest case passed'
fi

# Source/build identities use the same guarded helper as the actual runner.
release_retain_identity "$manifest" >"$work/source-identity-output"
grep -qE 'sha256=[0-9a-f]{64}$' "$work/source-identity-output" || fail 'valid source digest unavailable'
(
  release_digest() { return 37; }
  for path in source-archive-manifest source-inventory fresh-source-build.log; do
    status=0
    release_retain_identity "$retain/$path" >"$work/source-digest-failed" 2>&1 || status=$?
    [ "$status" -eq 1 ] || fail 'source/build digest failure passed'
    grep -q 'digest unavailable' "$work/source-digest-failed" || fail 'source digest failure was not explicit'
    if grep -q 'sha256=' "$work/source-digest-failed"; then fail 'failed source digest claimed identity'; fi
  done
)
(
  release_digest() { printf 'not-a-digest\n'; }
  status=0
  release_retain_identity "$manifest" >"$work/source-digest-malformed" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'malformed source digest passed'
)
(
  release_digest() { printf 'not-a-digest\n%064d\n' 0; }
  status=0
  release_retain_identity "$manifest" >"$work/source-digest-multiline" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'mixed-line source digest passed'
  if grep -q 'sha256=' "$work/source-digest-multiline"; then fail 'mixed-line digest claimed identity'; fi
  status=0
  (lane multiline-digest fixture 1 without_credential bash -c 'printf "Result: 1 passed\n"') \
    >"$work/lane-digest-multiline" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'mixed-line lane digest passed'
  if grep -q 'sha256=' "$work/lane-digest-multiline"; then fail 'mixed-line lane digest claimed identity'; fi
)

run_case() {
  local label=$1 expected_status=$2 expected_count=$3 expected=$4
  shift 4
  local status=0 output="$work/$label.output" sha recorded
  (lane "$label" fixture "$expected" without_credential "$@") >"$output" 2>&1 || status=$?
  [ "$status" -eq "$expected_status" ] || fail "$label returned $status"
  grep -q "executed_count=$expected_count duration_seconds=[0-9]" "$retain/$label.log" || fail "$label omitted count/duration"
  sha=$(release_digest "$retain/$label.log")
  recorded=$(sed -n 's/^check-release: retained .* sha256=//p' "$output")
  [ "$sha" = "$recorded" ] || fail "$label digest does not match final bytes"
  if [ "$expected_status" -ne 0 ]; then
    awk '/^check-release: retained / { retained=NR } /^check-release: .* RED|^check-release: .* executed .* expected/ { failed=NR } END {exit !(retained > 0 && failed > retained)}' "$output" ||
      fail "$label judged failure before retaining evidence"
  fi
}
run_case green 0 1 1 bash -c 'printf "Result: 1 passed\n"'
grep -q 'command_status=0 tee_status=0 summary_status=0' "$retain/green.log" || fail 'green statuses missing'
run_case command-failed 1 1 1 bash -c 'printf "Result: 1 passed\n"; exit 23'
grep -q 'command_status=23 tee_status=0 summary_status=0' "$retain/command-failed.log" || fail 'command failure status lost'
run_case parser-failed 1 unavailable 1 bash -c 'printf "fixture emitted no ExUnit summary\n"'
grep -q 'command_status=0 tee_status=0 summary_status=1' "$retain/parser-failed.log" || fail 'parser failure status lost'
run_case command-and-parser-failed 1 unavailable 1 bash -c 'printf "fixture error\n"; exit 31'
grep -q 'command_status=31 tee_status=0 summary_status=1' "$retain/command-and-parser-failed.log" || fail 'combined failure statuses lost'
run_case wrong-count 1 2 1 bash -c 'printf "Result: 2 passed\n"'
run_case nonzero 0 2 nonzero bash -c 'printf "2 tests, 0 failures\n"'
tee() { command tee "$@"; return 24; }
run_case tee-failed 1 1 1 bash -c 'printf "Result: 1 passed\n"'
unset -f tee
grep -q 'command_status=0 tee_status=24 summary_status=0' "$retain/tee-failed.log" || fail 'tee failure status lost'
before=$(release_digest "$retain/green.log")
status=0
(lane green fixture 1 without_credential bash -c 'printf "replacement\n"') >"$work/duplicate-log.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ "$before" = "$(release_digest "$retain/green.log")" ] || fail 'reused lane overwrote immutable evidence'
# All four inherited names must be removed, even when the host has set them.
(
  export LOOPEX_PROVIDER_API_KEY=synthetic OPENAI_API_KEY=synthetic ANTHROPIC_API_KEY=synthetic OPENROUTER_API_KEY=synthetic
  run_case inherited-cleared 0 1 1 bash -c 'test -z "${LOOPEX_PROVIDER_API_KEY+set}${OPENAI_API_KEY+set}${ANTHROPIC_API_KEY+set}${OPENROUTER_API_KEY+set}" && printf "Result: 1 passed\n"'
)
(
  release_digest() { return 37; }
  status=0
  (lane digest-failed fixture 1 without_credential bash -c 'printf "Result: 1 passed\n"') >"$work/digest-failed.output" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail 'unavailable digest did not refuse the lane'
  grep -q 'command_status=0 tee_status=0 summary_status=0 executed_count=1 duration_seconds=' "$retain/digest-failed.log" || fail 'digest failure omitted statuses'
  grep -q 'digest unavailable' "$work/digest-failed.output" || fail 'digest failure was not reported unavailable'
  if grep -q 'sha256=' "$work/digest-failed.output"; then fail 'failed digest claimed retained identity'; fi
)

# Preflight uses a genuine clean fixture repository. PATH commands only record
# whether Node or staging was reached and terminate before any build can run.
fixture="$work/repository"
mkdir -p "$fixture/scripts/fixtures/m4" "$work/bin" "$work/preflight-tmp"
cp "$root/scripts/fixtures/m4/client-toolchain.txt" "$fixture/scripts/fixtures/m4/"
git init -q "$fixture"
git -C "$fixture" add scripts/fixtures/m4/client-toolchain.txt
git -C "$fixture" -c user.name=Fixture -c user.email=fixture@invalid -c commit.gpgsign=false commit -qm 'fixture(M6): seed preflight'
cat >"$work/bin/node" <<'EOF'
#!/usr/bin/env bash
printf 'node\n' >>"$RELEASE_TEST_MARKER"
printf 'v%s\n' "$RELEASE_TEST_NODE"
EOF
cat >"$work/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
printf 'staging\n' >>"$RELEASE_TEST_MARKER"
exit 77
EOF
cat >"$work/bin/uname" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = -s ]; then printf '%s\n' "$RELEASE_TEST_PLATFORM"; else printf 'fixture-arch\n'; fi
EOF
chmod +x "$work/bin/node" "$work/bin/mktemp" "$work/bin/uname"
export RELEASE_TEST_MARKER="$work/preflight-marker"
export RELEASE_TEST_NODE
RELEASE_TEST_NODE=$(awk -F= '$1 == "node" {print $2}' "$fixture/scripts/fixtures/m4/client-toolchain.txt")
export RELEASE_TEST_PLATFORM=Linux
preflight() {
  local expected=$1 status=0
  local credential_env=("PATH=$work/bin:$PATH" "TMPDIR=$work/preflight-tmp")
  shift
  if [ -n "${RELEASE_TEST_CREDENTIAL:-}" ]; then credential_env+=("LOOPEX_PROVIDER_API_KEY=$RELEASE_TEST_CREDENTIAL"); fi
  if [ -n "${RELEASE_TEST_OLLAMA_MODEL:-}" ]; then credential_env+=("LOOPEX_RELEASE_OLLAMA_MODEL=$RELEASE_TEST_OLLAMA_MODEL"); fi
  : >"$RELEASE_TEST_MARKER"
  (cd "$fixture" && env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u OPENROUTER_API_KEY -u LOOPEX_RELEASE_OLLAMA_MODEL \
    "${credential_env[@]}" bash "$root/scripts/check-release.sh" "$@") >"$work/preflight-output" 2>&1 || status=$?
  [ "$status" -eq "$expected" ] || fail "preflight returned $status, expected $expected"
  # Apple's git launcher may create xcrun_db in TMPDIR. Release-owned staging
  # names, not that host cache, are the filesystem boundary being checked.
  for entry in "$work/preflight-tmp"/loopex-*; do
    [ ! -e "$entry" ] || fail 'preflight created release staging'
  done
}
for selector in real-provider-1 real-provider-2 real-provider-12; do
  preflight 2 --only "$selector"
  [ ! -s "$RELEASE_TEST_MARKER" ] || fail 'invalid selector reached Node or staging'
done
preflight 2 --only
preflight 2 --only node_client --only node_client
[ ! -s "$RELEASE_TEST_MARKER" ] || fail 'duplicate selector reached Node or staging'
preflight 2 --only real-provider-5
grep -q 'LOOPEX_PROVIDER_API_KEY is required' "$work/preflight-output" || fail 'provider credential refusal missing'
[ ! -s "$RELEASE_TEST_MARKER" ] || fail 'missing credential reached Node or staging'
preflight 77 --only long_bound
[ "$(cat "$RELEASE_TEST_MARKER")" = staging ] || fail 'long_bound queried Node or refused the absent credential'
preflight 77 --only rollback
[ "$(cat "$RELEASE_TEST_MARKER")" = staging ] || fail 'rollback queried Node or required a real credential'
preflight 2 --only real-provider-10
grep -q 'LOOPEX_RELEASE_OLLAMA_MODEL is required' "$work/preflight-output" || fail 'local Ollama model refusal missing'
[ ! -s "$RELEASE_TEST_MARKER" ] || fail 'missing Ollama model reached Node or staging'
RELEASE_TEST_OLLAMA_MODEL=ollama:
preflight 2 --only real-provider-10
grep -q 'must name an ollama: model' "$work/preflight-output" || fail 'empty Ollama model was admitted'
[ ! -s "$RELEASE_TEST_MARKER" ] || fail 'empty Ollama model reached Node or staging'
RELEASE_TEST_OLLAMA_MODEL=ollama:fixture
preflight 77 --only real-provider-10
[ "$(cat "$RELEASE_TEST_MARKER")" = staging ] || fail 'local Ollama row queried Node or required a credential'
preflight 77 --only node_client
[ "$(cat "$RELEASE_TEST_MARKER")" = "$(printf 'node\nstaging')" ] || fail 'node_client preflight selection is wrong'
RELEASE_TEST_CREDENTIAL=synthetic
preflight 77 --only real-provider-5
[ "$(cat "$RELEASE_TEST_MARKER")" = staging ] || fail 'provider row 5 spuriously queried Node'
preflight 77 --only real-provider-4
[ "$(cat "$RELEASE_TEST_MARKER")" = "$(printf 'node\nstaging')" ] || fail 'provider row 4 omitted Node'
preflight 77 --only real-provider-9
[ "$(cat "$RELEASE_TEST_MARKER")" = "$(printf 'node\nstaging')" ] || fail 'provider row 9 omitted Node'
preflight 77 --only real-provider-11
[ "$(cat "$RELEASE_TEST_MARKER")" = staging ] || fail 'hosted ephemeral row spuriously queried Node'
preflight 77
[ "$(cat "$RELEASE_TEST_MARKER")" = "$(printf 'node\nstaging')" ] || fail 'full preflight changed'
unset RELEASE_TEST_CREDENTIAL
unset RELEASE_TEST_OLLAMA_MODEL
RELEASE_TEST_NODE=wrong
preflight 2 --only node_client
grep -q 'Node v' "$work/preflight-output" || fail 'incorrect Node version did not refuse'
[ "$(cat "$RELEASE_TEST_MARKER")" = node ] || fail 'incorrect Node version reached staging'
RELEASE_TEST_PLATFORM=Darwin
preflight 2 --only cross_uid
grep -q 'cross_uid unavailable' "$work/preflight-output" || fail 'Darwin cross_uid was not unavailable'
[ ! -s "$RELEASE_TEST_MARKER" ] || fail 'unavailable cross_uid reached staging'
printf 'check-release-test: PASS\n'
