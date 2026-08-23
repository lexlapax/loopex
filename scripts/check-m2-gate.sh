#!/usr/bin/env bash
# Executable acceptance gate for milestone M2.
#
# CONCEPT
#
# M2 promises an operator a coding agent they can run from their own terminal.
# This runner judges whether that promise is mechanically present: the features
# the plan names have executable definitions, the locked commands pass, the
# protected selectors run without skips or exclusions, M1's proved protection
# still holds, the retained evidence has the required structure and describes
# the bytes it claims, and real user state was contained. It does not judge
# whether a test asserts what it names, whether a mutation or an interrupt was
# honestly injected, or whether an attended demonstration was a genuine task.
# Independent review owns those judgments and the gate does not pretend
# otherwise.
#
# TECHNICAL DEPTH
#
# The behavioural preflight runs first, before the credential frame is read,
# before any child is spawned for product work, and before any directory is
# created. A read-only reviewer therefore reaches the declared red without a
# writable root of any kind. The writable lane owns the product state root and
# the temporary directory, and fingerprints the operator's real ~/.loopex before
# and after.
#
# M2 deliberately reuses M1's proved machinery instead of building a second
# copy. Every protected selector runs through the bound
# scripts/m1-exunit-runner.exs, and the provider credential reaches a selector
# VM only through that script's LOOPEX_M1_SELECTOR_V1 nonce frame. M2 does not
# rebuild M1's sealed-environment apparatus, and makes no claim to defend
# against a hostile already-running shell.
#
# The retained-evidence validation below lives here rather than in a second
# program. Its exact scope is enumerated in the gate document so no reader
# infers enforcement that does not exist.
set -uo pipefail

readonly GATE_DOCUMENT="docs/plans/M2-gate.md"

# The exact declared red. It names the missing operator feature, not a missing
# file, because adding a checker, a document, an evidence record, or a status
# row must not be able to satisfy it.
readonly DECLARED_RED="an operator cannot run a coding task from the command line; the session loop still stops after two turns, sends the model no conversation history, never streams, and offers only two demonstration tools"

provider_key_value=""

fail() {
  local message="M2 gate RED: $1"
  if [ -n "$provider_key_value" ]; then
    case "$message" in
      *"$provider_key_value"*)
        printf '%s\n' \
          "M2 gate RED: a gate diagnostic collided with the provider credential and was suppressed" >&2
        exit 1
        ;;
    esac
  fi
  printf '%s\n' "$message" >&2
  exit 1
}

note() {
  local message="$1"
  if [ -n "$provider_key_value" ]; then
    case "$message" in
      *"$provider_key_value"*) fail "gate-owned output collides with provider credential bytes" ;;
    esac
  fi
  printf '%s\n' "$message"
}

# ---------------------------------------------------------------------------
# Credential refusal, before anything else observes the environment.
# ---------------------------------------------------------------------------

set +a
if [ -n "${LOOPEX_PROVIDER_API_KEY-}" ] || env | grep -q '^LOOPEX_PROVIDER_API_KEY='; then
  fail "LOOPEX_PROVIDER_API_KEY is present in the initial environment; the credential enters only through the bounded LOOPEX_M2_PROVIDER_V1 stdin frame"
fi

repository_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
  || fail "the gate must run inside the repository checkout"
[ -n "$repository_root" ] || fail "the gate must run inside the repository checkout"
cd "$repository_root" || fail "the repository root is not reachable"

role="ordinary"
capture_lane=""
case "${1-}" in
  "") : ;;
  --preflight)
    role="preflight"
    ;;
  --capture)
    role="capture"
    capture_lane="${2-}"
    case "$capture_lane" in
      darwin-floor | darwin-current | linux-current) : ;;
      *) fail "--capture requires one of darwin-floor, darwin-current, linux-current" ;;
    esac
    ;;
  *) fail "the accepted command is exactly: bash scripts/check-m2-gate.sh [--preflight | --capture <lane>]" ;;
esac

# The exact toolchain and platform each capture lane must have been recorded on.
lane_elixir() {
  case "$1" in
    darwin-floor) printf '%s' "1.17.0" ;;
    darwin-current | linux-current) printf '%s' "1.20.3" ;;
  esac
}

lane_otp() {
  case "$1" in
    darwin-floor) printf '%s' "26.0" ;;
    darwin-current | linux-current) printf '%s' "29.0.5" ;;
  esac
}

lane_os() {
  case "$1" in
    darwin-floor | darwin-current) printf '%s' "darwin" ;;
    linux-current) printf '%s' "linux" ;;
  esac
}

# ---------------------------------------------------------------------------
# Read-only behavioural preflight.
#
# Each check names an operator feature. The selector is that feature's
# executable definition, so a missing selector or a missing locked case means
# the feature does not exist yet, and the message says so in those terms.
# ---------------------------------------------------------------------------

require_feature() {
  local message="$1" selector="$2"
  shift 2
  [ -f "$selector" ] \
    || fail "$message"
  [ -r "$selector" ] \
    || fail "$selector cannot be read"
  local name
  for name in "$@"; do
    grep -qF "test \"${name}\"" "$selector" \
      || fail "$message (the locked case \"${name}\" is not in $selector)"
  done
}

require_feature \
  "$DECLARED_RED" \
  apps/loopex/test/agent_loop_test.exs \
  "a prompt runs until the model stops requesting tools rather than after a fixed number of turns" \
  "every model request carries the committed conversation history including the original prompt" \
  "an assistant tool call and its real tool result are committed and replayed to the model" \
  "each turn dispatches exactly the canonical request bytes and digest committed before it" \
  "the maximum turn bound ends the run as budget exhaustion before another provider call" \
  "the cumulative token budget ends the run as budget exhaustion before another provider call" \
  "the wall clock deadline ends the run as budget exhaustion before another provider call" \
  "every sampling bound is a declared committed value with no implicit default" \
  "a provider continuation binding is carried and an incompatible model change invalidates it"

require_feature \
  "the operator never sees an answer until the run ends; nothing streams and no delta algebra exists" \
  apps/loopex_llm_reqllm/test/streaming_conformance_test.exs \
  "every model adapter satisfies one streaming conformance suite" \
  "each canonical delta kind is bounded plain data carrying no provider or host term" \
  "replaying an adapter's emitted deltas reproduces the reply it returned byte identically" \
  "a gapless turn sequence and the reply's delta count make lost progress detectable" \
  "the committed assistant message is built from the reply and never assembled from deltas" \
  "a cancelled stream commits no assistant message and a late reply never becomes canonical" \
  "an adapter that emits no deltas is conformant and declares that it does not stream"

require_feature \
  "the operator cannot redirect a running task or queue the next one; there is no prompt steer follow-up algebra" \
  apps/loopex/test/input_algebra_test.exs \
  "a prompt starts a run only while the session is settled and is otherwise refused" \
  "the runtime never infers whether new input is steering or follow up and a steer must name its active run" \
  "a steer joins the active run after the current tool batch and before the next model request" \
  "a follow up starts a new run only after the active run and its steering settle" \
  "a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted" \
  "at most one unapplied steer and one queued follow up exist and both survive owner succession" \
  "an abort resolves any unapplied steer and queued follow up as cancelled"

require_feature \
  "an operator's session has no named tool set; there is no runtime-scoped tool registry" \
  apps/loopex/test/tool_registry_test.exs \
  "a runtime-scoped registry resolves a tool id and version and refuses an unknown id" \
  "two runtimes carry independent tool registries with no global registration" \
  "a conflicting tool id and version registration is refused with an explicit reason" \
  "a model request records the exact tool definition generation it used"

require_feature \
  "the operator has no coding tools; read, write, edit, and bash do not exist" \
  apps/loopex_executor_local/test/coding_tools_test.exs \
  "read returns bounded chunked content and reports truncation" \
  "write creates or replaces a file only beneath the workspace root" \
  "edit applies an exact match change and names what differed on a mismatch" \
  "bash runs an argv command and an explicit raw shell command with distinct semantics" \
  "every tool refuses a path that escapes the workspace root through traversal or a symlink" \
  "a tool child process tree is owned and terminated with its job"

require_feature \
  "oversized tool output has nowhere to go; there is no artifact store and a long result is simply lost" \
  apps/loopex_store_local/test/artifact_store_conformance_test.exs \
  "every artifact store implementation satisfies one conformance suite" \
  "tool output beyond its declared bound spills to an artifact instead of truncating silently" \
  "the durable artifact event carries digest media type size role and an opaque reference" \
  "the model facing result stays under its bound and names what was truncated" \
  "an artifact round trips byte exactly and a missing artifact reports unavailable"

require_feature \
  "host policy cannot refuse a tool call; there is no policy port and no working deny path" \
  apps/loopex_executor_local/test/host_policy_test.exs \
  "every host policy implementation satisfies one policy port conformance suite" \
  "a host policy deny decision issues no grant and starts no operating system process" \
  "a denied tool call commits a truthful denied outcome the operator can read" \
  "the run continues or terminates truthfully after a denial and never retries the refused call" \
  "a policy that raises times out or returns a malformed value fails closed into denial" \
  "defer is declared and refused in this milestone rather than treated as allow or deny" \
  "the trusted local allow all policy is explicit configuration rather than an implicit fallback"

require_feature \
  "the operator cannot let the model read the project; there is no discovery manifest or trust decision" \
  apps/loopex/test/project_resource_trust_test.exs \
  "discovery resolves a canonical ordered resource set under declared path size and total limits" \
  "the operator is shown every resolved path its provenance and the manifest digest" \
  "an explicit trust decision binds workspace revision manifest and digests" \
  "a changed workspace revision manifest or content invalidates the decision" \
  "a headless run without a matching positive decision fails closed and stages no project block" \
  "an admitted project block changes no tool set policy decision bound or grant"

require_feature \
  "the operator cannot stop a running task; cancellation is recorded but nothing is cancelled" \
  apps/loopex/test/cancellation_test.exs \
  "an interrupt reaches the run through the public facade and through no private path" \
  "an abort admitted during a model call cancels the run and schedules no new work" \
  "an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled" \
  "a validated terminal tool fact committed before the abort is preserved and not overwritten" \
  "an effect without sufficient evidence ends outcome unknown and is never blindly retried" \
  "a second interrupt reports what is still being cleaned up rather than abandoning the session" \
  "the operator observes what was cancelled and what actually happened"

require_feature \
  "the operator cannot find yesterday's work; nothing enumerates the sessions in a state root" \
  apps/loopex/test/session_directory_test.exs \
  "a fresh operating system process lists the sessions in a resolved state root" \
  "the state root resolves from LOOPEX_HOME and never from application environment" \
  "a session resumes under the durable runtime placement identity that created it" \
  "resuming a session through a different runtime identity is refused with an explicit reason" \
  "a repeated resume command identity returns its historical result while a fresh identity acquires ownership"

require_feature \
  "there is no loopex command; the only way to run a session is a test selector" \
  apps/loopex_cli/test/cli_test.exs \
  "loopex run submits a prompt and streams the answer with its tool calls and results" \
  "loopex sessions lists the operator's sessions and loopex resume continues one" \
  "an interrupt signal delivered to a running loopex process cancels the task through the public facade" \
  "loopex cancel reconciles a session left behind by a dead process and is refused against a live owner" \
  "the policy option selects the governing host policy and a refusal is reported in the transcript" \
  "project resource trust is decided at the terminal and a non interactive run without a decision fails closed" \
  "the command surface drives only the public facade and owns no loop store cursor or authority" \
  "the base system prompt and active tool definitions measure under one thousand tokens" \
  "argument parsing and terminal output use only the standard library"

require_feature \
  "an embedder cannot start the kernel in one page; the only composition is test support" \
  apps/loopex_cli/test/kernel_composition_test.exs \
  "one page of shipped code starts the application tree a runtime a session a prompt and its events" \
  "the shipped composition is the same one the loopex command uses" \
  "the composition resolves its state root explicitly and never through application environment"

require_feature \
  "no real provider has driven a genuine multi-tool coding task through the shipped command" \
  apps/loopex_cli/test/coding_task_test.exs \
  "a multi tool task reads edits and verifies a file in a disposable repository" \
  "the task transcript shows every tool call decision and result" \
  "a denied tool call inside a multi tool task is reported and the task continues truthfully" \
  "the demonstration workspace is disposable and never the operator's own repository" \
  "one real provider task streams edits a real repository across several turns and the operator sees the committed result"

# M1 is closed and its outcomes are proved history, but the behaviour it proved
# is still the floor this milestone stands on. Its selectors are re-run here at
# their exact locked identities, including both real-provider roles.
require_feature \
  "M1's proved runtime isolation no longer has its locked definition" \
  apps/loopex/test/runtime_test.exs \
  "two runtimes coexist without a global name" \
  "a runtime reference is required rather than inferred" \
  "a supervised runtime starts and stops with explicit configuration"

require_feature \
  "M1's proved session ownership no longer has its locked definition" \
  apps/loopex/test/session_lifecycle_test.exs \
  "session creation atomically records its runtime command mapping and genesis re-presents identical bytes idempotently and conflicts on changed bytes" \
  "initial and resumed coordinators commit advance_owner before admitting commands" \
  "a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize" \
  "declared injected and observed transition and fault point pairs are equal" \
  "a prompt cannot start a second active run" \
  "only one coordinator owns a session at a time after durable succession"

require_feature \
  "M1's proved store conformance no longer has its locked definition" \
  apps/loopex_store_local/test/store_conformance_test.exs \
  "every implementation atomically refuses a stale owner epoch incarnation and version" \
  "a killed writer loses no acknowledged fact" \
  "replay audits durable truth but grants no write authority" \
  "known transactions return their retained resolution without a second mutation" \
  "the durable local store survives process death with consecutive store-stamped history"

require_feature \
  "M1's proved embedded API delivery no longer has its locked definition" \
  apps/loopex/test/embedded_api_test.exs \
  "progress and diagnostics never carry durable truth" \
  "committed events survive delivery with stable identity" \
  "attachment snapshots at N and streams events after N without a gap" \
  "a full attachment queue disconnects with a durable-history cursor and resumes gap-free after runtime restart without persisted attachment state"

require_feature \
  "M1's proved model conformance no longer has its locked definition" \
  apps/loopex_llm_reqllm/test/real_model_lane_test.exs \
  "deterministic and ReqLLM adapters satisfy one model conformance suite"

require_feature \
  "M1's proved committed-request dispatch no longer has its locked definition" \
  apps/loopex_reference_client/test/real_model_session_test.exs \
  "model dispatch receives only the committed canonical request bytes and digest" \
  "one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session"

require_feature \
  "M1's proved executor authority no longer has its locked definition" \
  apps/loopex_executor_local/test/executor_test.exs \
  "required grant bindings equal the independent contract oracle" \
  "each missing and wrong grant binding is refused before process start" \
  "only an explicit host-policy allow decision can issue or widen a grant" \
  "the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity" \
  "the workspace lease is held for the job lifetime and loss kills owned work with retained evidence" \
  "the executor starts one credential-free OS tool that writes the expected workspace bytes and retains its receipt"

require_feature \
  "M1's proved facade-only client no longer has its locked definition" \
  apps/loopex_reference_client/test/reference_client_test.exs \
  "the client drives the loop through the embedded API only" \
  "the reference client owns no policy durable state or alternate loop"

require_feature \
  "M1's proved recovery trace no longer has its locked definition" \
  apps/loopex_reference_client/test/end_to_end_recovery_test.exs \
  "reconciliation schema covers the independent recovery contract oracle" \
  "exactly one dispatch ever carried each effect across the restart" \
  "an effect without a durable receipt becomes outcome_unknown and is not blindly retried" \
  "every acknowledged fact survives the restart" \
  "each wrong reconciliation and receipt identity is refused" \
  "one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call"

require_feature \
  "the reused selector-runner corpus no longer has its locked definition" \
  apps/loopex/test/m1_exunit_runner_test.exs \
  "the standalone selector grammar admits every planned owner and rejects foreign paths" \
  "the standalone runner requires one tracked ordinary selector owned by its compiled app" \
  "official counts and exact events refuse failures skips exclusions and missing names" \
  "fake stdout at_exit and early halt cannot manufacture one authoritative result" \
  "only the declared internal dependency closure is reachable and startup never receives the provider key"

require_feature \
  "the dependency corpus does not yet describe the M2 seven-application inventory" \
  apps/loopex/test/deps_budget_test.exs \
  "the repository satisfies the dependency budget and direction" \
  "the M2 planned inventory admits exactly seven applications with their declared roles" \
  "a client composes the edge applications it depends on and declares no external package"

# ---------------------------------------------------------------------------
# Bound artifacts, closure documents, and platform, still read-only.
# ---------------------------------------------------------------------------

digest_dialect=""
if command -v shasum >/dev/null 2>&1; then
  digest_dialect="shasum"
elif command -v sha256sum >/dev/null 2>&1; then
  digest_dialect="sha256sum"
else
  fail "no validated SHA-256 dialect is available; evidence is unavailable"
fi

file_digest() {
  local path="$1" output
  case "$digest_dialect" in
    shasum) output="$(shasum -a 256 "$path" 2>/dev/null)" ;;
    sha256sum) output="$(sha256sum "$path" 2>/dev/null)" ;;
  esac
  [ -n "$output" ] || return 1
  printf '%s' "${output%% *}"
}

require_bound_artifact() {
  local expected="$1" path="$2" actual
  [ -f "$path" ] || fail "bound artifact $path is missing"
  actual="$(file_digest "$path")" || fail "bound artifact $path could not be digested"
  [ "$actual" = "$expected" ] \
    || fail "bound artifact $path is ${actual}, not the accepted ${expected}"
}

# scripts/check-m2-gate.sh is bound by the gate document and verified against it
# by mix loopex.status. A runner cannot honestly verify its own bytes before it
# executes them, and this one does not pretend to.
require_bound_artifact \
  cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0 \
  scripts/m1-exunit-runner.exs
require_bound_artifact \
  0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d \
  apps/loopex/test/m1_exunit_runner_test.exs
require_bound_artifact \
  fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999 \
  .tool-versions

closure_documents=(
  CHANGELOG.md
  README.md
  DEVELOPMENT.md
  VERSION
  docs/README.md
  docs/plans/README.md
  docs/plans/M2.md
  docs/plans/M2-technical.md
  docs/plans/M2-gate.md
  docs/evidence/README.md
  docs/evidence/M2-toolchain-matrix.md
  docs/evidence/M2-negative-demonstrations.md
  docs/evidence/M2-coding-demonstration.md
  docs/operator/README.md
  docs/operator/coding-sessions.md
  docs/operator/tools-and-policy.md
  docs/developer/README.md
  docs/developer/agent-loop-and-tools.md
  docs/developer/compatibility-surfaces.md
  docs/developer/runtime-and-embedding.md
  docs/developer/agent-context-map.md
)

for document in "${closure_documents[@]}"; do
  if [ "$role" = "capture" ] && [ "$document" = docs/evidence/M2-toolchain-matrix.md ]; then
    continue
  fi
  [ -f "$document" ] \
    || fail "the closure document $document does not exist; the milestone does not document what it changed"
  git ls-files --error-unmatch "$document" >/dev/null 2>&1 \
    || fail "the closure document $document is not tracked"
done

case "$(uname -s)" in
  Darwin | Linux) : ;;
  *) fail "this gate executes on Darwin or Linux only" ;;
esac

[ -z "$(git status --porcelain)" ] \
  || fail "the source tree is not clean; a gate result must describe committed bytes"

if [ "$role" = "preflight" ]; then
  note "M2 preflight OK"
  exit 0
fi

# ---------------------------------------------------------------------------
# Provider credential intake.
#
# The frame is exactly LOOPEX_M2_PROVIDER_V1\0<key>\0. An interactive stdin or
# an immediate end of file means no key, which fails the real-provider roles
# rather than skipping them. The key is held in one unexported variable and is
# forwarded only through the selector runner's own nonce frame.
# ---------------------------------------------------------------------------

read_provider_frame() {
  local frame header rest
  if [ -t 0 ]; then
    return 0
  fi
  IFS= read -r -d '' header || return 0
  [ "$header" = "LOOPEX_M2_PROVIDER_V1" ] \
    || fail "the provider frame header is malformed"
  IFS= read -r -d '' rest \
    || fail "the provider frame is missing its key terminator"
  [ -n "$rest" ] || fail "the provider frame carries an empty key"
  [ "${#rest}" -le 16384 ] || fail "the provider frame key exceeds its byte bound"
  if IFS= read -r -d '' frame; then
    fail "the provider frame carries a trailing field"
  fi
  provider_key_value="$rest"
}

read_provider_frame
export -n provider_key_value 2>/dev/null || :

# ---------------------------------------------------------------------------
# Owned state.
# ---------------------------------------------------------------------------

user_state_root=""
user_state_before=""
user_state_after=""

fingerprint_user_state() {
  local root="$1"
  [ -d "$root" ] || { printf '%s' "absent"; return 0; }
  (
    cd "$root" 2>/dev/null || exit 0
    find . -mindepth 1 -exec ls -ldn {} + 2>/dev/null | LC_ALL=C sort
  ) | {
    case "$digest_dialect" in
      shasum) shasum -a 256 ;;
      sha256sum) sha256sum ;;
    esac
  } | { read -r value _rest; printf '%s' "$value"; }
}

user_state_root="$HOME/.loopex"
user_state_before="$(fingerprint_user_state "$user_state_root")"

task_root="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m2-gate.XXXXXX")" \
  || fail "an owned task root could not be created"
task_root="$(cd "$task_root" && pwd -P)" \
  || fail "the owned task root could not be physically resolved"

cleanup() {
  local status=$?
  if [ -n "${task_root:-}" ] && [ -d "$task_root" ]; then
    rm -rf "$task_root"
  fi
  exit "$status"
}
trap cleanup EXIT

case "$task_root" in
  "$user_state_root" | "$user_state_root"/*)
    fail "the owned task root resolves inside the operator's product state"
    ;;
esac

mkdir -p "$task_root/home" "$task_root/tmp" "$task_root/build" "$task_root/workspace" \
  || fail "the owned task root could not be populated"

export LOOPEX_HOME="$task_root/home/.loopex"
export TMPDIR="$task_root/tmp"
export MIX_BUILD_ROOT="$task_root/build"
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ERL_CRASH_DUMP=/dev/null
export ERL_CRASH_DUMP_SECONDS=0
export GIT_OPTIONAL_LOCKS=0

test_build_path="$task_root/build/test"

gate_seed="$(( $(od -An -N4 -tu4 /dev/urandom | tr -d ' \n') % 1000000 ))" \
  || fail "the gate seed could not be derived"
[[ "$gate_seed" =~ ^[0-9]{1,6}$ ]] || fail "the gate seed is malformed"

# The exact running pair, derived from the VM rather than from a declaration.
running_toolchain="$(
  elixir -e 'otp = :erlang.system_info(:otp_release) |> List.to_string()
    path = Path.join([:code.root_dir() |> List.to_string(), "releases", otp, "OTP_VERSION"])
    version = case File.read(path) do
      {:ok, text} -> String.trim(text)
      _ -> otp
    end
    IO.puts(System.version() <> " " <> version)' 2>/dev/null
)" || fail "the running Elixir and OTP pair could not be determined"
running_elixir="${running_toolchain%% *}"
running_otp="${running_toolchain##* }"
[ -n "$running_elixir" ] && [ -n "$running_otp" ] \
  || fail "the running Elixir and OTP pair could not be determined"

if [ "$role" = "capture" ]; then
  [ "$running_elixir" = "$(lane_elixir "$capture_lane")" ] \
    || fail "lane $capture_lane requires Elixir $(lane_elixir "$capture_lane"), not $running_elixir"
  [ "$running_otp" = "$(lane_otp "$capture_lane")" ] \
    || fail "lane $capture_lane requires OTP $(lane_otp "$capture_lane"), not $running_otp"
  [ "$(uname -s | tr '[:upper:]' '[:lower:]')" = "$(lane_os "$capture_lane")" ] \
    || fail "lane $capture_lane requires $(lane_os "$capture_lane")"
fi

# ---------------------------------------------------------------------------
# Locked commands.
# ---------------------------------------------------------------------------

run_locked() {
  local description="$1"
  shift
  local output status
  output="$("$@" 2>&1)"
  status=$?
  if [ "$status" -ne 0 ]; then
    if [ -n "$provider_key_value" ]; then
      output="${output//"$provider_key_value"/[redacted credential]}"
    fi
    printf '%s\n' "$output" >&2
    fail "$description"
  fi
}

project_configs=(mix.exs)
while IFS= read -r child; do
  project_configs+=("$child")
done < <(git ls-files 'apps/*/mix.exs' | LC_ALL=C sort)

run_locked "the dependency budget, the M2 seven-application inventory, or the role direction is violated" \
  mix loopex.deps_budget
run_locked "effective formatting does not include every application source" \
  mix loopex.format_scope
run_locked "formatting is not clean" \
  mix format --check-formatted
run_locked "the default build is not warning-free" \
  mix compile --warnings-as-errors
run_locked "the isolated test build is not warning-free" \
  env MIX_ENV=test mix compile --warnings-as-errors
run_locked "the applications do not all carry the single version train" \
  mix loopex.version_train
run_locked "the operator entrypoint does not build" \
  env MIX_ENV=prod mix cmd --app loopex_cli mix escript.build
run_locked "core is no longer standard-library and OTP only" \
  mix loopex.core_only
run_locked "covered public code does not order Concept before Technical depth" \
  mix loopex.docs_check
run_locked "retained hooks lost their required event or matcher registration" \
  mix loopex.hook_registration
run_locked "the closed M0 matrix behaviour is no longer intact" \
  mix loopex.matrix
run_locked "live governance, indexes, links, or lifecycle state do not validate" \
  mix loopex.status
run_locked "the portable bootstrap aggregate is not green" \
  bash scripts/check-bootstrap.sh

version_reported="$(cat VERSION 2>/dev/null | tr -d '\n')"
[ "$version_reported" = "0.0.0" ] \
  || fail "the version train reports ${version_reported:-nothing}, not the accepted 0.0.0"

# ---------------------------------------------------------------------------
# Protected and inherited selectors, through M1's bound authoritative channel.
# ---------------------------------------------------------------------------

protected_executed=0
demonstration_record=""

run_selector() {
  local outcome="$1" selector="$2" role_name="$3" minimum="$4" policy="$5"
  shift 5
  local context owner internal allowed nonce output status executed marker

  context="$(
    elixir -r "$repository_root/apps/loopex/lib/mix/tasks/loopex.deps_budget.ex" \
      -e 'Loopex.Checks.DepsBudget.main(System.argv())' -- \
      --context "$selector" "${project_configs[@]}" 2>/dev/null
  )" || fail "$selector has no authoritative application dependency context"

  if [[ "$context" =~ ^LOOPEX_DEPENDENCY_CONTEXT\ owner=([a-z][a-z0-9_]*)\ internal=([a-z][a-z0-9_,]*)\ allowed=([a-z][a-z0-9_,]*)$ ]]; then
    owner="${BASH_REMATCH[1]}"
    internal="${BASH_REMATCH[2]}"
    allowed="${BASH_REMATCH[3]}"
  else
    fail "$selector produced a malformed application dependency context"
  fi

  nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
  [[ "$nonce" =~ ^[0-9a-f]{32}$ ]] \
    || fail "the authoritative test-result nonce is malformed"

  case "$role_name" in
    default)
      output="$(
        printf 'LOOPEX_M1_SELECTOR_V1\0%s\0\0' "$nonce" \
          | elixir "$repository_root/scripts/m1-exunit-runner.exs" \
              --loopex-m1-selector "$repository_root" "$test_build_path" \
              "$selector" "$owner" "$internal" "$allowed" \
              "$gate_seed" "$minimum" "$policy" "$@" 2>&1
      )"
      status=$?
      ;;
    real-model | real-combined)
      [ -n "$provider_key_value" ] \
        || fail "outcome $outcome requires a real provider credential; absence is evidence unavailable, never a skip"
      local profile="${role_name#real-}"
      output="$(
        printf 'LOOPEX_M1_SELECTOR_V1\0%s\0%s\0' "$nonce" "$provider_key_value" \
          | elixir "$repository_root/scripts/m1-exunit-runner.exs" \
              --loopex-m1-selector --only-real-provider --real-path "$profile" \
              "$repository_root" "$test_build_path" \
              "$selector" "$owner" "$internal" "$allowed" \
              "$gate_seed" "$minimum" "$policy" "$@" 2>&1
      )"
      status=$?
      ;;
    *) fail "unknown selector role $role_name" ;;
  esac

  if [ "$status" -ne 0 ]; then
    if [ -n "$provider_key_value" ]; then
      output="${output//"$provider_key_value"/[redacted credential]}"
    fi
    printf '%s\n' "$output" >&2
    fail "outcome $outcome did not pass through $selector in role $role_name"
  fi

  marker="$(printf '%s' "$output" | grep -F "LOOPEX_EXUNIT_REPORT nonce=$nonce selector=$selector " | tail -1)"
  [ -n "$marker" ] \
    || fail "outcome $outcome produced no authoritative result for $selector"
  if [[ "$marker" =~ executed=([0-9]+) ]]; then
    executed="${BASH_REMATCH[1]}"
  else
    fail "outcome $outcome produced a malformed authoritative result for $selector"
  fi
  [ "$executed" -ge "$minimum" ] \
    || fail "outcome $outcome executed $executed cases, below its locked minimum $minimum"

  case "$outcome" in
    inherited | mechanics) : ;;
    *) protected_executed=$(( protected_executed + executed )) ;;
  esac

  if [ "$outcome" = 13 ] && [ "$role_name" = real-combined ]; then
    demonstration_record="$marker"
  fi
}

run_selector 1 apps/loopex/test/agent_loop_test.exs default 9 zero \
  "passed=a prompt runs until the model stops requesting tools rather than after a fixed number of turns" \
  "passed=every model request carries the committed conversation history including the original prompt" \
  "passed=an assistant tool call and its real tool result are committed and replayed to the model" \
  "passed=each turn dispatches exactly the canonical request bytes and digest committed before it" \
  "passed=the maximum turn bound ends the run as budget exhaustion before another provider call" \
  "passed=the cumulative token budget ends the run as budget exhaustion before another provider call" \
  "passed=the wall clock deadline ends the run as budget exhaustion before another provider call" \
  "passed=every sampling bound is a declared committed value with no implicit default" \
  "passed=a provider continuation binding is carried and an incompatible model change invalidates it"

run_selector 2 apps/loopex_llm_reqllm/test/streaming_conformance_test.exs default 7 zero \
  "passed=every model adapter satisfies one streaming conformance suite" \
  "passed=each canonical delta kind is bounded plain data carrying no provider or host term" \
  "passed=replaying an adapter's emitted deltas reproduces the reply it returned byte identically" \
  "passed=a gapless turn sequence and the reply's delta count make lost progress detectable" \
  "passed=the committed assistant message is built from the reply and never assembled from deltas" \
  "passed=a cancelled stream commits no assistant message and a late reply never becomes canonical" \
  "passed=an adapter that emits no deltas is conformant and declares that it does not stream"

run_selector 3 apps/loopex/test/input_algebra_test.exs default 7 zero \
  "passed=a prompt starts a run only while the session is settled and is otherwise refused" \
  "passed=the runtime never infers whether new input is steering or follow up and a steer must name its active run" \
  "passed=a steer joins the active run after the current tool batch and before the next model request" \
  "passed=a follow up starts a new run only after the active run and its steering settle" \
  "passed=a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted" \
  "passed=at most one unapplied steer and one queued follow up exist and both survive owner succession" \
  "passed=an abort resolves any unapplied steer and queued follow up as cancelled"

run_selector 4 apps/loopex/test/tool_registry_test.exs default 4 zero \
  "passed=a runtime-scoped registry resolves a tool id and version and refuses an unknown id" \
  "passed=two runtimes carry independent tool registries with no global registration" \
  "passed=a conflicting tool id and version registration is refused with an explicit reason" \
  "passed=a model request records the exact tool definition generation it used"

run_selector 5 apps/loopex_executor_local/test/coding_tools_test.exs default 6 zero \
  "passed=read returns bounded chunked content and reports truncation" \
  "passed=write creates or replaces a file only beneath the workspace root" \
  "passed=edit applies an exact match change and names what differed on a mismatch" \
  "passed=bash runs an argv command and an explicit raw shell command with distinct semantics" \
  "passed=every tool refuses a path that escapes the workspace root through traversal or a symlink" \
  "passed=a tool child process tree is owned and terminated with its job"

run_selector 6 apps/loopex_store_local/test/artifact_store_conformance_test.exs default 5 zero \
  "passed=every artifact store implementation satisfies one conformance suite" \
  "passed=tool output beyond its declared bound spills to an artifact instead of truncating silently" \
  "passed=the durable artifact event carries digest media type size role and an opaque reference" \
  "passed=the model facing result stays under its bound and names what was truncated" \
  "passed=an artifact round trips byte exactly and a missing artifact reports unavailable"

run_selector 7 apps/loopex_executor_local/test/host_policy_test.exs default 7 zero \
  "passed=every host policy implementation satisfies one policy port conformance suite" \
  "passed=a host policy deny decision issues no grant and starts no operating system process" \
  "passed=a denied tool call commits a truthful denied outcome the operator can read" \
  "passed=the run continues or terminates truthfully after a denial and never retries the refused call" \
  "passed=a policy that raises times out or returns a malformed value fails closed into denial" \
  "passed=defer is declared and refused in this milestone rather than treated as allow or deny" \
  "passed=the trusted local allow all policy is explicit configuration rather than an implicit fallback"

run_selector 8 apps/loopex/test/project_resource_trust_test.exs default 6 zero \
  "passed=discovery resolves a canonical ordered resource set under declared path size and total limits" \
  "passed=the operator is shown every resolved path its provenance and the manifest digest" \
  "passed=an explicit trust decision binds workspace revision manifest and digests" \
  "passed=a changed workspace revision manifest or content invalidates the decision" \
  "passed=a headless run without a matching positive decision fails closed and stages no project block" \
  "passed=an admitted project block changes no tool set policy decision bound or grant"

run_selector 9 apps/loopex/test/cancellation_test.exs default 7 zero \
  "passed=an interrupt reaches the run through the public facade and through no private path" \
  "passed=an abort admitted during a model call cancels the run and schedules no new work" \
  "passed=an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled" \
  "passed=a validated terminal tool fact committed before the abort is preserved and not overwritten" \
  "passed=an effect without sufficient evidence ends outcome unknown and is never blindly retried" \
  "passed=a second interrupt reports what is still being cleaned up rather than abandoning the session" \
  "passed=the operator observes what was cancelled and what actually happened"

run_selector 10 apps/loopex/test/session_directory_test.exs default 5 zero \
  "passed=a fresh operating system process lists the sessions in a resolved state root" \
  "passed=the state root resolves from LOOPEX_HOME and never from application environment" \
  "passed=a session resumes under the durable runtime placement identity that created it" \
  "passed=resuming a session through a different runtime identity is refused with an explicit reason" \
  "passed=a repeated resume command identity returns its historical result while a fresh identity acquires ownership"

run_selector 11 apps/loopex_cli/test/cli_test.exs default 9 zero \
  "passed=loopex run submits a prompt and streams the answer with its tool calls and results" \
  "passed=loopex sessions lists the operator's sessions and loopex resume continues one" \
  "passed=an interrupt signal delivered to a running loopex process cancels the task through the public facade" \
  "passed=loopex cancel reconciles a session left behind by a dead process and is refused against a live owner" \
  "passed=the policy option selects the governing host policy and a refusal is reported in the transcript" \
  "passed=project resource trust is decided at the terminal and a non interactive run without a decision fails closed" \
  "passed=the command surface drives only the public facade and owns no loop store cursor or authority" \
  "passed=the base system prompt and active tool definitions measure under one thousand tokens" \
  "passed=argument parsing and terminal output use only the standard library"

run_selector 12 apps/loopex_cli/test/kernel_composition_test.exs default 3 zero \
  "passed=one page of shipped code starts the application tree a runtime a session a prompt and its events" \
  "passed=the shipped composition is the same one the loopex command uses" \
  "passed=the composition resolves its state root explicitly and never through application environment"

run_selector 13 apps/loopex_cli/test/coding_task_test.exs default 4 positive \
  "passed=a multi tool task reads edits and verifies a file in a disposable repository" \
  "passed=the task transcript shows every tool call decision and result" \
  "passed=a denied tool call inside a multi tool task is reported and the task continues truthfully" \
  "passed=the demonstration workspace is disposable and never the operator's own repository" \
  "excluded=one real provider task streams edits a real repository across several turns and the operator sees the committed result"

run_selector 13 apps/loopex_cli/test/coding_task_test.exs real-combined 1 positive \
  "passed=one real provider task streams edits a real repository across several turns and the operator sees the committed result" \
  "excluded=a multi tool task reads edits and verifies a file in a disposable repository" \
  "excluded=the task transcript shows every tool call decision and result" \
  "excluded=a denied tool call inside a multi tool task is reported and the task continues truthfully" \
  "excluded=the demonstration workspace is disposable and never the operator's own repository"

[ -n "$demonstration_record" ] \
  || fail "the attended demonstration role retained no non-secret real-path identity"

run_selector inherited apps/loopex/test/runtime_test.exs default 3 zero \
  "passed=two runtimes coexist without a global name" \
  "passed=a runtime reference is required rather than inferred" \
  "passed=a supervised runtime starts and stops with explicit configuration"

run_selector inherited apps/loopex/test/session_lifecycle_test.exs default 6 zero \
  "passed=session creation atomically records its runtime command mapping and genesis re-presents identical bytes idempotently and conflicts on changed bytes" \
  "passed=initial and resumed coordinators commit advance_owner before admitting commands" \
  "passed=a superseded owner cannot newly commit or use a delayed result to update cache publish dispatch or authorize" \
  "passed=declared injected and observed transition and fault point pairs are equal" \
  "passed=a prompt cannot start a second active run" \
  "passed=only one coordinator owns a session at a time after durable succession"

run_selector inherited apps/loopex_store_local/test/store_conformance_test.exs default 5 zero \
  "passed=every implementation atomically refuses a stale owner epoch incarnation and version" \
  "passed=a killed writer loses no acknowledged fact" \
  "passed=replay audits durable truth but grants no write authority" \
  "passed=known transactions return their retained resolution without a second mutation" \
  "passed=the durable local store survives process death with consecutive store-stamped history"

run_selector inherited apps/loopex/test/embedded_api_test.exs default 4 zero \
  "passed=progress and diagnostics never carry durable truth" \
  "passed=committed events survive delivery with stable identity" \
  "passed=attachment snapshots at N and streams events after N without a gap" \
  "passed=a full attachment queue disconnects with a durable-history cursor and resumes gap-free after runtime restart without persisted attachment state"

run_selector inherited apps/loopex_llm_reqllm/test/real_model_lane_test.exs default 1 zero \
  "passed=deterministic and ReqLLM adapters satisfy one model conformance suite"

run_selector inherited apps/loopex_reference_client/test/real_model_session_test.exs default 1 positive \
  "passed=model dispatch receives only the committed canonical request bytes and digest" \
  "excluded=one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session"

run_selector inherited apps/loopex_reference_client/test/real_model_session_test.exs real-model 1 positive \
  "passed=one real non-streaming model call receives the committed canonical request bytes and digest and completes inside a session" \
  "excluded=model dispatch receives only the committed canonical request bytes and digest"

run_selector inherited apps/loopex_executor_local/test/executor_test.exs default 6 zero \
  "passed=required grant bindings equal the independent contract oracle" \
  "passed=each missing and wrong grant binding is refused before process start" \
  "passed=only an explicit host-policy allow decision can issue or widen a grant" \
  "passed=the executor recomputes the canonical JobRequest digest and the receipt retains verified origin identity" \
  "passed=the workspace lease is held for the job lifetime and loss kills owned work with retained evidence" \
  "passed=the executor starts one credential-free OS tool that writes the expected workspace bytes and retains its receipt"

run_selector inherited apps/loopex_reference_client/test/reference_client_test.exs default 2 zero \
  "passed=the client drives the loop through the embedded API only" \
  "passed=the reference client owns no policy durable state or alternate loop"

run_selector inherited apps/loopex_reference_client/test/end_to_end_recovery_test.exs default 5 positive \
  "passed=reconciliation schema covers the independent recovery contract oracle" \
  "passed=exactly one dispatch ever carried each effect across the restart" \
  "passed=an effect without a durable receipt becomes outcome_unknown and is not blindly retried" \
  "passed=every acknowledged fact survives the restart" \
  "passed=each wrong reconciliation and receipt identity is refused" \
  "excluded=one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call"

run_selector inherited apps/loopex_reference_client/test/end_to_end_recovery_test.exs real-combined 1 positive \
  "passed=one real-provider trace forces a credential-free tool survives an untrappable runtime-tree kill after receipt before fact reconciles one effect without redispatch preserves its fact and completes a second real call" \
  "excluded=reconciliation schema covers the independent recovery contract oracle" \
  "excluded=exactly one dispatch ever carried each effect across the restart" \
  "excluded=an effect without a durable receipt becomes outcome_unknown and is not blindly retried" \
  "excluded=every acknowledged fact survives the restart" \
  "excluded=each wrong reconciliation and receipt identity is refused"

run_selector mechanics apps/loopex/test/m1_exunit_runner_test.exs default 5 zero \
  "passed=the standalone selector grammar admits every planned owner and rejects foreign paths" \
  "passed=the standalone runner requires one tracked ordinary selector owned by its compiled app" \
  "passed=official counts and exact events refuse failures skips exclusions and missing names" \
  "passed=fake stdout at_exit and early halt cannot manufacture one authoritative result" \
  "passed=only the declared internal dependency closure is reachable and startup never receives the provider key"

run_selector mechanics apps/loopex/test/deps_budget_test.exs default 27 zero \
  "passed=the repository satisfies the dependency budget and direction" \
  "passed=the M2 planned inventory admits exactly seven applications with their declared roles" \
  "passed=a client composes the edge applications it depends on and declares no external package"

run_locked "the credential-free suite does not pass at the gate seed" \
  env MIX_ENV=test mix test --exclude real_provider --seed "$gate_seed"

# ---------------------------------------------------------------------------
# Retained evidence.
#
# The checks below are exactly what the gate document claims and no more.
# Whether a mutation was honestly injected, and whether a retained field matches
# the process output it names, remain review obligations.
# ---------------------------------------------------------------------------

readonly NEGATIVE_RECORD_PATTERN='^\{"mechanism_disabled":"([a-z][a-z0-9_]*)","selector":"([A-Za-z0-9._/-]+)","observed_failure":"([ -~]+)","candidate":"([0-9a-f]{40})","artifact":"([A-Za-z0-9._/-]+)","restored_sha256":"sha256:([0-9a-f]{64})"\}$'

require_safe_tracked_path() {
  local path="$1" context="$2"
  case "$path" in
    /* | *..* | *//*)
      fail "$context names an unsafe path $path"
      ;;
  esac
  git ls-files --error-unmatch "$path" >/dev/null 2>&1 \
    || fail "$context names $path, which is not a tracked file at this revision"
}

validate_negative_demonstrations() {
  local path=docs/evidence/M2-negative-demonstrations.md
  [ -f "$path" ] || fail "the negative demonstration record does not exist"

  local expected=(
    "committed_history_projection|apps/loopex/test/agent_loop_test.exs"
    "stream_delta_reconstruction|apps/loopex_llm_reqllm/test/streaming_conformance_test.exs"
    "tool_definition_generation_binding|apps/loopex/test/tool_registry_test.exs"
    "workspace_path_scope_containment|apps/loopex_executor_local/test/coding_tools_test.exs"
    "host_policy_deny_prestart_refusal|apps/loopex_executor_local/test/host_policy_test.exs"
    "project_resource_trust_admission|apps/loopex/test/project_resource_trust_test.exs"
    "cancellation_cleanup_confirmation|apps/loopex/test/cancellation_test.exs"
    "command_surface_facade_only|apps/loopex_cli/test/cli_test.exs"
  )

  local declared
  declared="$(grep -c '"mechanism_disabled"' "$path")"
  [ "$declared" -eq 8 ] \
    || fail "the negative demonstrations must be exactly eight records, not $declared"

  local records=() line
  while IFS= read -r line; do
    records+=("$line")
  done < <(grep -E '^\{"mechanism_disabled":' "$path")

  [ "${#records[@]}" -eq 8 ] \
    || fail "only ${#records[@]} negative demonstration records are one-line JSON objects in the canonical key order"

  local index=0 record pair want_mechanism want_selector
  local mechanism selector candidate artifact restored actual
  for record in "${records[@]}"; do
    pair="${expected[$index]}"
    want_mechanism="${pair%%|*}"
    want_selector="${pair##*|}"

    [[ "$record" =~ $NEGATIVE_RECORD_PATTERN ]] \
      || fail "negative demonstration $(( index + 1 )) is not one canonical record in the locked key order"
    mechanism="${BASH_REMATCH[1]}"
    selector="${BASH_REMATCH[2]}"
    candidate="${BASH_REMATCH[4]}"
    artifact="${BASH_REMATCH[5]}"
    restored="${BASH_REMATCH[6]}"

    [ "$mechanism" = "$want_mechanism" ] \
      || fail "negative demonstration $(( index + 1 )) disables $mechanism, not the locked $want_mechanism"
    [ "$selector" = "$want_selector" ] \
      || fail "the $mechanism demonstration names $selector, not its locked $want_selector"

    require_safe_tracked_path "$selector" "the $mechanism demonstration"
    require_safe_tracked_path "$artifact" "the $mechanism demonstration"

    git merge-base --is-ancestor "$candidate" HEAD 2>/dev/null \
      || fail "the $mechanism demonstration names candidate $candidate, which is not reachable from this revision"

    actual="$(file_digest "$artifact")" \
      || fail "the $mechanism demonstration artifact $artifact could not be digested"
    [ "$actual" = "$restored" ] \
      || fail "the $mechanism demonstration restored $artifact to $restored, which is not this revision's ${actual}"

    index=$(( index + 1 ))
  done
}

matrix_field() {
  local line="$1" key="$2" rest
  rest="${line#* $key=}"
  [ "$rest" != "$line" ] || return 1
  printf '%s' "${rest%% *}"
}

validate_matrix() {
  local path=docs/evidence/M2-toolchain-matrix.md
  [ -f "$path" ] || fail "the retained matrix does not exist"
  grep -qF '<!-- loopex:m2-matrix:start -->' "$path" \
    || fail "the retained matrix has no canonical start marker"
  grep -qF '<!-- loopex:m2-matrix:end -->' "$path" \
    || fail "the retained matrix has no canonical end marker"

  local header count
  count="$(grep -cE '^matrix candidate=' "$path")"
  [ "$count" -eq 1 ] \
    || fail "the retained matrix must carry exactly one matrix row, not $count"
  header="$(grep -E '^matrix candidate=' "$path" | head -1)"

  local candidate expect
  candidate="$(matrix_field "$header" candidate)" \
    || fail "the retained matrix names no source candidate"
  [[ "$candidate" =~ ^[0-9a-f]{40}$ ]] \
    || fail "the retained matrix names no exact source candidate"
  git merge-base --is-ancestor "$candidate" HEAD 2>/dev/null \
    || fail "the retained matrix names a candidate that is not reachable from this revision"

  [ "$(matrix_field "$header" command)" = "bash:scripts/check-m2-gate.sh" ] \
    || fail "the retained matrix names a command other than the ordinary gate"

  local key file
  for key in \
    "gate_sha256:$GATE_DOCUMENT" \
    "runner_sha256:scripts/check-m2-gate.sh" \
    "exunit_runner_sha256:scripts/m1-exunit-runner.exs" \
    "tool_versions_sha256:.tool-versions"; do
    file="${key#*:}"
    expect="$(file_digest "$file")" \
      || fail "$file could not be digested for the retained matrix"
    [ "$(matrix_field "$header" "${key%%:*}")" = "$expect" ] \
      || fail "the retained matrix records a ${key%%:*} that is not this revision's $file"
  done

  local lane line reference_identity="" identity field
  for lane in darwin-floor darwin-current linux-current; do
    count="$(grep -cE "^capture lane=$lane " "$path")"
    [ "$count" -eq 1 ] \
      || fail "the retained matrix must carry exactly one $lane capture, not $count"
    line="$(grep -E "^capture lane=$lane " "$path" | head -1)"

    [ "$(matrix_field "$line" candidate)" = "$candidate" ] \
      || fail "the $lane capture names a different candidate than the matrix row"
    [ "$(matrix_field "$line" verdict)" = "CAPTURE" ] \
      || fail "the $lane capture is not a CAPTURE verdict"
    [ "$(matrix_field "$line" exit)" = "0" ] \
      || fail "the $lane capture did not exit zero"
    [ "$(matrix_field "$line" elixir)" = "$(lane_elixir "$lane")" ] \
      || fail "the $lane capture was not recorded on Elixir $(lane_elixir "$lane")"
    [ "$(matrix_field "$line" otp)" = "$(lane_otp "$lane")" ] \
      || fail "the $lane capture was not recorded on OTP $(lane_otp "$lane")"
    [ "$(matrix_field "$line" os)" = "$(lane_os "$lane")" ] \
      || fail "the $lane capture was not recorded on $(lane_os "$lane")"
    [[ "$(matrix_field "$line" seed)" =~ ^[0-9]{1,6}$ ]] \
      || fail "the $lane capture records no canonical seed"
    [[ "$(matrix_field "$line" executed)" =~ ^[1-9][0-9]*$ ]] \
      || fail "the $lane capture executed no protected cases"
    [ "$(matrix_field "$line" adapter_build)" = "loopex_llm_reqllm@0.0.0" ] \
      || fail "the $lane capture records an adapter build the bound selector runner cannot have sealed"
    [ "$(matrix_field "$line" executor_build)" = "loopex_executor_local@0.0.0" ] \
      || fail "the $lane capture records an executor build the bound selector runner cannot have sealed"

    identity=""
    for field in provider model endpoint adapter_build executor_build executor_identity tool_identity; do
      identity="$identity $field=$(matrix_field "$line" "$field")"
    done
    case "$identity " in
      *"= "*) fail "the $lane capture is missing a sealed identity field" ;;
    esac

    if [ -z "$reference_identity" ]; then
      reference_identity="$identity"
    else
      [ "$identity" = "$reference_identity" ] \
        || fail "the $lane capture disagrees with darwin-floor on provider, model, endpoint, adapter build, executor build, executor identity, or tool identity"
    fi
  done

  local m0_digest
  m0_digest="$(file_digest docs/plans/M0-gate.md)" \
    || fail "the closed M0 gate document could not be digested"
  for lane in floor current; do
    count="$(grep -cE "^m0 lane=$lane " "$path")"
    [ "$count" -eq 1 ] \
      || fail "the retained matrix must carry exactly one M0 $lane re-proof, not $count"
    line="$(grep -E "^m0 lane=$lane " "$path" | head -1)"
    [ "$(matrix_field "$line" candidate)" = "$candidate" ] \
      || fail "the M0 $lane re-proof names a different candidate than the matrix row"
    [ "$(matrix_field "$line" gate_sha256)" = "$m0_digest" ] \
      || fail "the M0 $lane re-proof names a gate digest that is not this revision's M0 gate"
    [ "$(matrix_field "$line" command)" = "bash:scripts/check-m0-gate.sh" ] \
      || fail "the M0 $lane re-proof names a command other than the M0 gate"
    [ "$(matrix_field "$line" verdict)" = "GREEN" ] \
      || fail "the M0 $lane re-proof is not GREEN"
    [ "$(matrix_field "$line" exit)" = "0" ] \
      || fail "the M0 $lane re-proof did not exit zero"
  done
  [ "$(matrix_field "$(grep -E '^m0 lane=floor ' "$path" | head -1)" elixir)" = "1.17.0" ] \
    || fail "the M0 floor re-proof was not recorded on Elixir 1.17.0"
  [ "$(matrix_field "$(grep -E '^m0 lane=current ' "$path" | head -1)" elixir)" = "1.20.3" ] \
    || fail "the M0 current re-proof was not recorded on Elixir 1.20.3"

  local changed
  changed="$(git diff --name-only "$candidate" HEAD | LC_ALL=C sort | tr '\n' ' ')"
  case "$changed" in
    "" | "docs/evidence/M2-coding-demonstration.md docs/evidence/M2-negative-demonstrations.md docs/evidence/M2-toolchain-matrix.md ") : ;;
    *) fail "this revision changes product bytes relative to the captured candidate: $changed" ;;
  esac
}

validate_negative_demonstrations

user_state_after="$(fingerprint_user_state "$user_state_root")"
[ "$user_state_before" = "$user_state_after" ] \
  || fail "the operator's product state under $user_state_root changed during the run"

if [ "$role" = "capture" ]; then
  # The retained identity fields are exactly the ones the attended
  # demonstration role sealed into its authoritative result: everything after
  # that result's digest field. They are never re-derived here from candidate
  # prose.
  demonstration_fields="${demonstration_record#*digest=sha256:}"
  demonstration_fields="${demonstration_fields#* }"
  [ "$demonstration_fields" != "$demonstration_record" ] \
    || fail "the attended demonstration result carries no sealed identity fields"
  note "capture lane=$capture_lane candidate=$(git rev-parse HEAD) elixir=$running_elixir otp=$running_otp seed=$gate_seed executed=$protected_executed verdict=CAPTURE exit=0 os=$(uname -s | tr '[:upper:]' '[:lower:]') arch=$(uname -m) $demonstration_fields"
  exit 0
fi

validate_matrix

note "M2 gate GREEN seed=$gate_seed protected_executed=$protected_executed"
