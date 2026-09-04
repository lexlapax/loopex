#!/usr/bin/env bash
# M3 gate runner. Executable acceptance for the kernel-consolidation milestone.
#
# Concept: three cheap, decisive probes decide the opening condition, in an
# order chosen so that the least expensive decisive observation runs first. Each
# probe answers one question the milestone exists to answer, and none of them can
# be satisfied by creating a file.
#
# Technical depth: probe A asks whether the repository runs a closed gate at all.
# Probe B asks whether an accepted gate locks the regressions the post-closure
# override sets produced. Probe C compiles core into an isolated build root and
# asks the shipped admission path for the required-only lower bound ADR 0017
# evaluation step 5 requires. Anything the runner cannot observe is unavailable
# evidence and exits 2; only an observed shortfall emits the declared red.
set -euo pipefail

readonly RED_PREFIX='M3 gate RED: the repository enforces no Closed milestone gate, no accepted gate locks the regressions the post-closure override sets produced, and ADR 0017 evaluation step 5 is absent from the admission path'

die() {
  printf 'M3 gate UNAVAILABLE: %s\n' "$*" >&2
  exit 2
}

# Concept: the declared red is one line, and the bounded observation rides it.
red() {
  printf '%s LOOPEX_M3_PROBE %s\n' "$RED_PREFIX" "$*"
  exit 1
}

# Concept: this gate proves nothing about a provider and therefore refuses to
# hold a credential. The inherited M2 gate owns that lane; a key present here
# would be a key this runner has no reason to hold.
if [ -n "${LOOPEX_PROVIDER_API_KEY:-}" ]; then
  die 'LOOPEX_PROVIDER_API_KEY is present; this gate defines no credential lane of its own'
fi
set +a

role=ordinary
case "${1:-}" in
  '') ;;
  --inspect) role=inspect ;;
  --preflight) role=preflight ;;
  *) die "unknown role $1; the grammar is [--inspect | --preflight]" ;;
esac
[ "$#" -le 1 ] || die 'the role grammar accepts at most one argument'

root=$(git rev-parse --show-toplevel 2>/dev/null) || die 'not inside a Git checkout'
cd "$root" || die "cannot enter $root"

require_digest() {
  local expected=$1 path=$2 actual
  [ -f "$path" ] || die "bound artifact is absent: $path"
  actual=$(shasum -a 256 "$path" | cut -d' ' -f1)
  [ "$actual" = "$expected" ] ||
    die "bound artifact does not match its locked digest: $path"
}

require_digest 'cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0' 'scripts/m1-exunit-runner.exs'
require_digest '0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d' 'apps/loopex/test/m1_exunit_runner_test.exs'
require_digest 'fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999' '.tool-versions'

for path in docs/plans/M3.md docs/plans/M3-technical.md docs/plans/M3-gate.md docs/plans/README.md; do
  [ -f "$path" ] || die "M3 governance artifact is absent: $path"
done

if [ "$role" = inspect ]; then
  printf '%s\n' 'M3 inspection OK'
  exit 0
fi

# ---------------------------------------------------------------------------
# Register reading. The canonical register is the only source for which
# milestones are Closed and which gates are locked, so a probe that hardcoded a
# list would stop being true the next time a milestone closes.
# ---------------------------------------------------------------------------
register_rows() {
  awk '
    /^<!-- loopex:milestone-register:start -->$/ { inside = 1; next }
    /^<!-- loopex:milestone-register:end -->$/   { inside = 0 }
    inside && /^\| `/ {
      name = $0
      sub(/^\| `/, "", name)
      sub(/`.*$/, "", name)
      state = $0
      sub(/^\| `[^`]*` \| /, "", state)
      sub(/ \|.*$/, "", state)
      print name "\t" state
    }
  ' docs/plans/README.md
}

closed_milestones() {
  register_rows | awk -F'\t' '$2 == "Closed" { print $1 }'
}

locked_gate_documents() {
  register_rows | awk -F'\t' '$2 == "Accepted" || $2 == "Closed" { print "docs/plans/" $1 "-gate.md" }'
}

# ---------------------------------------------------------------------------
# Probe A — is a Closed gate run by the repository, or by a person?
#
# Green needs four things at once: the aggregate exists and is executable, its
# enumeration is derived from the register rather than written down, the
# bootstrap aggregate invokes it, and the structural check that refuses a
# milestone gate omitting its mandatory call exists. Creating an empty file
# satisfies none of them, because the enumeration is compared against the
# register this runner read for itself.
# ---------------------------------------------------------------------------
probe_a() {
  local expected actual
  probe_a_state=absent
  probe_a_bootstrap=0
  probe_a_invocation=absent

  if grep -Fq 'check-closed-gates.sh' scripts/check-bootstrap.sh 2>/dev/null; then
    probe_a_bootstrap=1
  fi
  if [ -f apps/loopex/lib/mix/tasks/loopex.gate_invocation.ex ]; then
    probe_a_invocation=present
  fi

  [ -x scripts/check-closed-gates.sh ] || return 1
  probe_a_state=present

  expected=$(closed_milestones | LC_ALL=C sort)
  actual=$(bash scripts/check-closed-gates.sh --list 2>/dev/null | LC_ALL=C sort) || return 1
  [ -n "$actual" ] || return 1
  [ "$expected" = "$actual" ] || { probe_a_state=enumeration_mismatch; return 1; }

  [ "$probe_a_bootstrap" = 1 ] || return 1
  [ "$probe_a_invocation" = present ] || return 1
  return 0
}

# ---------------------------------------------------------------------------
# Probe B — is every inherited regression locked by a gate some authority
# accepted?
#
# The case names come from this gate's own Inherited Regression Lock table, so
# the list has one home. They are looked for in the gate documents of every
# milestone the register records as Accepted or Closed. While M3 is Open its own
# gate is not one of those, which is exactly right: an unaccepted gate locks
# nothing, and this probe turns green when the maintainer accepts the gate that
# names them.
# ---------------------------------------------------------------------------
inherited_case_names() {
  awk '
    /^## Inherited Regression Lock$/ { inside = 1; next }
    inside && /^## / { inside = 0 }
    inside && /^\| `apps\// {
      cases = $0
      n = split(cases, parts, "`")
      for (i = 2; i <= n; i += 2) {
        if (parts[i] !~ /^apps\// && parts[i] !~ /^[0-9]+$/) print parts[i]
      }
    }
  ' docs/plans/M3-gate.md
}

probe_b() {
  local documents name
  probe_b_total=0
  probe_b_locked=0

  documents=$(locked_gate_documents | tr '\n' ' ')
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    probe_b_total=$((probe_b_total + 1))
    if [ -n "$documents" ] && grep -Fq -- "$name" $documents 2>/dev/null; then
      probe_b_locked=$((probe_b_locked + 1))
    fi
  done <<EOF
$(inherited_case_names)
EOF

  [ "$probe_b_total" -gt 0 ] || die 'the Inherited Regression Lock table names no case'
  [ "$probe_b_locked" = "$probe_b_total" ]
}

# ---------------------------------------------------------------------------
# Probe C — does the admission path resolve a required-only lower bound?
#
# Core is stdlib and OTP only, so this compiles without a dependency tree, a Hex
# cache, or a network. The probe asks the shipped module for ADR 0017 evaluation
# step 5 and then checks that its answer is consistent with a refusal: a stub
# returning a smaller number passes the export check and fails the relation. It
# does not prove step 5 is correct — the generated cardinality property this gate
# locks does that — it proves whether step 5 is there at all.
# ---------------------------------------------------------------------------
probe_c() {
  local build ebin
  probe_c_state=absent

  build="$task_root/build"
  mkdir -p "$build" || die 'cannot create the isolated build root'

  (
    cd apps/loopex &&
      HOME="$task_root/home" \
        HEX_HOME="$task_root/home/.hex" \
        MIX_HOME="$task_root/home/.mix" \
        HEX_OFFLINE=1 \
        MIX_ENV=prod \
        MIX_BUILD_ROOT="$build" \
        mix compile >"$task_root/compile.log" 2>&1
  ) || die "core does not compile into an isolated build root; see $task_root/compile.log"

  ebin=$(find "$build" -type d -name ebin | tr '\n' ' ')
  [ -n "$ebin" ] || die 'the isolated build root produced no ebin directory'

  probe_c_state=$(
    # shellcheck disable=SC2086
    elixir $(printf -- '-pa %s ' $ebin) -e '
      module = Loopex.Runtime.ContextAdmission

      answer =
        cond do
          not Code.ensure_loaded?(module) ->
            "module_absent"

          not function_exported?(module, :required_only_lower_bound, 2) ->
            "absent"

          true ->
            observations = %{
              system_class_tokens: 0,
              provider_estimated_tokens: 0,
              context_token_budget: 1_000_000,
              context_record_byte_ceiling: 4_096,
              context_record_depth_limit: 32,
              context_record_cardinality_limit: 4_096
            }

            candidate = %{
              "required" => %{"prompt" => "x"},
              "optional" => %{"project" => String.duplicate("p", 8_192)}
            }

            case module.preflight_required_candidate(candidate, observations) do
              {:refused, refusal} ->
                bound = Map.get(refusal, "required_only_record_byte_cost")
                observed = Map.get(refusal, "observed")

                cond do
                  is_nil(bound) -> "refusal_without_bound"
                  not is_integer(bound) -> "unsound"
                  not is_integer(observed) -> "unsound"
                  bound >= observed -> "unsound"
                  true -> "present"
                end

              _other ->
                "candidate_not_refused"
            end
        end

      IO.write(answer)
    ' 2>/dev/null
  ) || probe_c_state=unavailable

  [ "$probe_c_state" = present ]
}

# ---------------------------------------------------------------------------
# Isolated evidence root. Probe C is the only writable step, and it writes only
# beneath this root, which resolves outside both the checkout and the operator
# product state.
# ---------------------------------------------------------------------------
task_parent=$(cd "${TMPDIR:-/tmp}" && pwd -P) || die 'cannot resolve a temporary directory'
checkout=$(pwd -P)
case "$task_parent" in
  "$checkout"|"$checkout"/*) die 'the temporary directory resolves inside the checkout' ;;
esac

task_root=$(mktemp -d "$task_parent/loopex-m3-gate.XXXXXXXX") || die 'cannot allocate a task root'
task_root=$(cd "$task_root" && pwd -P)
cleanup() { rm -rf "$task_root"; }
trap cleanup EXIT INT TERM
mkdir -p "$task_root/home"

probe_a || a_failed=1
probe_b || b_failed=1
probe_c || c_failed=1

observation="aggregate=$probe_a_state bootstrap_invokes_aggregate=$probe_a_bootstrap invocation_check=$probe_a_invocation locked_regressions=$probe_b_locked/$probe_b_total step5=$probe_c_state"

if [ -n "${a_failed:-}" ] || [ -n "${b_failed:-}" ] || [ -n "${c_failed:-}" ]; then
  red "$observation"
fi

if [ "$role" = preflight ]; then
  printf '%s\n' 'M3 preflight OK'
  exit 0
fi

# ---------------------------------------------------------------------------
# Ordinary mode. Reachable only once every probe above is green, which is the
# point: the commands below protect a product that does not yet behave as this
# milestone promises, so running them before the probes would report on the
# wrong thing.
# ---------------------------------------------------------------------------
run_step() {
  printf 'M3 gate step: %s\n' "$*"
  "$@" || die "required command failed: $*"
}

run_step mix loopex.status
run_step bash scripts/check-bootstrap.sh
run_step bash scripts/check-closed-gates.sh

# Concept: this gate is Open, and an Open gate says what it cannot yet do.
#
# Technical depth: the protected-selector, full-suite, and retained-evidence
# lanes are locked in the gate document but are not yet written into these
# bytes. Reaching this line means every probe went green, which cannot happen at
# the candidate this gate opens on. Before acceptance these bytes must invoke
# every protected role through the authoritative standalone channel and validate
# the complete retained-evidence manifest. Reporting a pass here instead would
# make a missing lane look like a proved one, so it is unavailable evidence.
die 'the protected-selector, suite, and evidence lanes are not yet written into this Open gate'
