#!/usr/bin/env bash
# Drives the actual attended runner in a disposable Git repository. Its fake
# release check exercises terminal answers and retention, not provider work.
set -euo pipefail
unset LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY

source_root=$(cd "$(dirname "$0")/../.." && pwd -P)
work=$(mktemp -d "${TMPDIR:-/tmp}/loopex-attended-test.XXXXXX")
work=$(cd "$work" && pwd -P)
trap 'rm -rf "$work"' EXIT
fail() { printf 'attended-release-test: %s\n' "$1" >&2; exit 1; }

repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/docs/developer" "$work/retained"
cp "$source_root/scripts/attended-release.sh" "$repo/scripts/attended-release.sh"
cp "$source_root/scripts/attended-pty.py" "$repo/scripts/attended-pty.py"
printf '# Fixture context map\n' >"$repo/docs/developer/agent-context-map.md"
printf 'fixture\n' >"$repo/README.md"
git -C "$repo" init -q
git -C "$repo" add .
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): seed attendance'
ancestor=$(git -C "$repo" rev-parse HEAD)

cat >"$repo/scripts/check-release.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${ATTENDED_TEST_MODE:-}" in
  human_success) printf 'fixture human path complete %s\n' "${OPENAI_API_KEY:-}"; exit 0 ;;
  human_failure) printf 'fixture human path failed\n'; exit 17 ;;
  malformed)
    printf 'Authorize pinned public skill import: wrong source. Type yes and press Enter.\n'
    sleep 30
    exit 90 ;;
  out_of_order)
    printf 'Admit exact public skill manifest: source=https://github.com/openai/skills.git digest=%064d. Type yes and press Enter.\n' 0
    sleep 30
    exit 91 ;;
  hang)
    printf '%s\n' "$$" >"$ATTENDED_TEST_CHILD_MARKER"
    sleep 30
    exit 92 ;;
esac
printf 'Authorize pinned public skill import: source=https://github.com/openai/skills.git rev=49f948faa9258a0c61caceaf225e179651397431 path=skills/.curated/security-threat-model. Type yes and press Enter.\n'
IFS= read -r first
[ "$first" = yes ] || exit 61
if [ "${ATTENDED_TEST_MODE:-}" = duplicate_first ]; then
  printf 'Authorize pinned public skill import: source=https://github.com/openai/skills.git rev=49f948faa9258a0c61caceaf225e179651397431 path=skills/.curated/security-threat-model. Type yes and press Enter.\n'
  sleep 30
  exit 93
fi
if [ "${ATTENDED_TEST_MODE:-}" = missing_second ]; then exit 0; fi
if [ "${ATTENDED_TEST_MODE:-}" = malformed_second ]; then
  printf 'Admit exact public skill manifest: source=https://github.com/openai/skills.git digest=%063d. Type yes and press Enter.\n' 0
  sleep 30
  exit 95
fi
printf 'Admit exact public skill manifest: source=https://github.com/openai/skills.git digest=%064d. Type yes and press Enter.\n' 0
IFS= read -r second
[ "$second" = yes ] || exit 62
if [ "${ATTENDED_TEST_MODE:-}" = duplicate_second ]; then
  printf 'Admit exact public skill manifest: source=https://github.com/openai/skills.git digest=%064d. Type yes and press Enter.\n' 0
  sleep 30
  exit 94
fi
printf 'provider echo: %s and %s\n' "${LOOPEX_PROVIDER_API_KEY:-}" "${OPENAI_API_KEY:-}"
value=${OPENROUTER_API_KEY:-}
printf 'split credential: %s' "${value:0:10}"
sleep 0.05
printf '%s\n' "${value:10}"
printf 'fixture release complete\n'
exit "${ATTENDED_TEST_RELEASE_EXIT:-0}"
EOF
git -C "$repo" add scripts/check-release.sh
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): candidate release check'
tested=$(git -C "$repo" rev-parse HEAD)
runner="$repo/scripts/attended-release.sh"
anchor=disposition-m6-attended-test

git -C "$repo" switch -qc authority
cat >>"$repo/docs/developer/agent-context-map.md" <<EOF

<a id="$anchor"></a>
### M6 attended release authorization

Milestone: M6
Tested SHA: $tested
Automatic attended answers: authorized
EOF
git -C "$repo" add docs/developer/agent-context-map.md
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): authorize exact attended candidate'
authority=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q --detach "$tested"

auto_args=(--answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$authority")
expect_preflight_failure() {
  local label=$1 reason=$2
  shift 2
  local output="$work/retained/$label.log" status=0
  (cd "$repo" && bash "$runner" --output "$output" "$@") \
    >"$work/$label.output" 2>&1 || status=$?
  [ "$status" -ne 0 ] || fail "$label passed"
  grep -q "attended-release: $reason" "$work/$label.output" || fail "$label reason changed"
  [ ! -e "$output" ] && [ ! -e "$output.authority" ] || fail "$label created output"
}

expect_preflight_failure missing_anchor disposition_not_unique \
  --answer-attended --disposition absent --milestone M6 --authority-sha "$authority"
expect_preflight_failure wrong_milestone disposition_mismatch \
  --answer-attended --disposition "$anchor" --milestone M7 --authority-sha "$authority"
expect_preflight_failure wrong_sha authority_not_descendant \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$tested"
expect_preflight_failure non_descendant authority_not_descendant \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$ancestor"
expect_preflight_failure invalid_sha invalid_authority_sha \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha not-a-sha
status=0
(cd "$repo" && bash "$runner" --output "$work/missing-parent/log" "${auto_args[@]}") \
  >"$work/missing-parent.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ ! -e "$work/missing-parent" ] &&
  grep -q 'attended-release: output_parent_missing' "$work/missing-parent.output" ||
  fail 'missing parent did not refuse without creating output'

# A wrong tested SHA or missing explicit permission in a descendant entry is
# not enough to authorize an answer, even when the anchor and milestone match.
git -C "$repo" switch -qc wrong-record "$tested"
cat >>"$repo/docs/developer/agent-context-map.md" <<EOF

<a id="$anchor"></a>
### Wrong candidate

Milestone: M6
Tested SHA: 0000000000000000000000000000000000000000
Automatic attended answers: authorized
EOF
git -C "$repo" add docs/developer/agent-context-map.md
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): wrong attended candidate'
wrong_record=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q --detach "$tested"
expect_preflight_failure wrong_record disposition_mismatch \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$wrong_record"

git -C "$repo" switch -qc missing-permission "$tested"
cat >>"$repo/docs/developer/agent-context-map.md" <<EOF

<a id="$anchor"></a>
### No automatic permission

Milestone: M6
Tested SHA: $tested
Automatic attended answers: discussed
EOF
git -C "$repo" add docs/developer/agent-context-map.md
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): omit automatic permission'
missing_permission=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q --detach "$tested"
expect_preflight_failure missing_permission disposition_mismatch \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$missing_permission"

status=0
(cd "$repo" && bash "$runner" --output "$work/retained/invalid.log" --answer-attended) \
  >"$work/invalid.output" 2>&1 || status=$?
[ "$status" -eq 2 ] && [ ! -e "$work/retained/invalid.log" ] ||
  fail 'incomplete automatic arguments did not refuse before output'

printf 'existing log\n' >"$work/retained/existing.log"
status=0
(cd "$repo" && bash "$runner" --output "$work/retained/existing.log" "${auto_args[@]}") \
  >"$work/existing.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ "$(cat "$work/retained/existing.log")" = 'existing log' ] ||
  fail 'existing log was replaced'

printf 'existing sidecar\n' >"$work/retained/sidecar.log.authority"
status=0
(cd "$repo" && bash "$runner" --output "$work/retained/sidecar.log" "${auto_args[@]}") \
  >"$work/sidecar.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ ! -e "$work/retained/sidecar.log" ] &&
  [ "$(cat "$work/retained/sidecar.log.authority")" = 'existing sidecar' ] ||
  fail 'existing sidecar was replaced or created a log'

printf 'protected target\n' >"$work/protected"
ln -s "$work/protected" "$work/retained/link.log"
status=0
(cd "$repo" && bash "$runner" --output "$work/retained/link.log" "${auto_args[@]}") \
  >"$work/link.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ "$(cat "$work/protected")" = 'protected target' ] ||
  fail 'existing symlink target was modified'

mkdir "$work/fault-bin"
cat >"$work/fault-bin/cat" <<'EOF'
#!/usr/bin/env bash
printf 'partial authority\n'
exit 37
EOF
chmod +x "$work/fault-bin/cat"
status=0
(cd "$repo" && PATH="$work/fault-bin:$PATH" bash "$runner" \
  --output "$work/retained/publication-failed.log" "${auto_args[@]}") \
  >"$work/publication-failed.output" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail 'sidecar publication failure passed'
grep -qx 'RELEASE_EXIT=not_started' "$work/retained/publication-failed.log" ||
  fail 'sidecar publication failure did not retain no-start evidence'
[ ! -e "$work/retained/publication-failed.log.authority" ] ||
  fail 'partial authority sidecar survived'
if grep -q 'fixture release complete' "$work/publication-failed.output"; then
  fail 'release check started after sidecar publication failure'
fi

export LOOPEX_PROVIDER_API_KEY='synthetic-release-key-123'
export OPENAI_API_KEY='synthetic-openai-key-[42]'
export ANTHROPIC_API_KEY='synthetic-anthropic-key'
export OPENROUTER_API_KEY='synthetic-openrouter-key'
status=0
credential_path="$work/retained/$OPENROUTER_API_KEY.log"
(cd "$repo" && bash "$runner" --output "$credential_path" "${auto_args[@]}") \
  >"$work/credential-path.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ ! -e "$credential_path" ] &&
  grep -q 'attended-release: output_contains_credential' "$work/credential-path.output" ||
  fail 'credential in output path was published'
status=0
(cd "$repo" && OPENAI_API_KEY=$'multiline\nsynthetic' bash "$runner" \
  --output "$work/retained/multiline.log" "${auto_args[@]}") \
  >"$work/multiline.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ ! -e "$work/retained/multiline.log" ] &&
  grep -q 'attended-release: credential_value_unredactable' "$work/multiline.output" ||
  fail 'multiline credential reached transcript creation'
good="$work/retained/good.log"
(cd "$repo" && bash "$runner" --output "$good" "${auto_args[@]}") \
  >"$work/good.output" 2>&1 || {
    sed -n '1,120p' "$work/good.output" >&2
    fail 'authorized automatic run failed'
  }
grep -qx 'RELEASE_EXIT=0' "$good" || fail 'release exit was not retained'
grep -qx 'ATTENDED_ANSWERS=2' "$good" || fail 'exact two attended answers were not recorded'
grep -q 'fixture release complete' "$good" || fail 'complete transcript missing'
grep -q 'provider echo: \[REDACTED\] and \[REDACTED\]' "$good" ||
  fail 'provider values were not redacted'
grep -q 'split credential: \[REDACTED\]' "$good" ||
  fail 'a credential split between PTY reads was not redacted'
for secret in "$LOOPEX_PROVIDER_API_KEY" "$OPENAI_API_KEY" "$ANTHROPIC_API_KEY" "$OPENROUTER_API_KEY"; do
  if grep -Fq "$secret" "$good" "$work/good.output"; then fail 'credential appeared in published output'; fi
done
expected=$(git -C "$repo" show "$authority:docs/developer/agent-context-map.md" |
  awk -v anchor="$anchor" '
    $0 == "<a id=\"" anchor "\"></a>" { in_section = 1 }
    in_section && $0 ~ /^<a id="/ && $0 != "<a id=\"" anchor "\"></a>" { exit }
    in_section { print }
  ')
[ "$(cat "$good.authority")" = "$expected" ] || fail 'retained disposition changed'
printf '<a id="%s"></a>\n### M6 attended release authorization\n\nMilestone: M6\nTested SHA: %s\nAutomatic attended answers: authorized\n' \
  "$anchor" "$tested" >"$work/expected-authority"
cmp -s "$work/expected-authority" "$good.authority" ||
  fail 'retained disposition bytes changed'
digest=$(shasum -a 256 "$good.authority" | awk '{ print $1 }')
grep -q "sidecar=$good.authority sha256=$digest" "$good" ||
  { sed -n '1,30p' "$good" >&2; fail 'sidecar reference or digest missing'; }
grep -q "tested_sha=$tested authority_sha=$authority ancestry=strict-descendant" "$good" ||
  fail 'ancestry and candidate identity missing'
git -C "$repo" branch -D authority >/dev/null
[ "$digest" = "$(shasum -a 256 "$good.authority" | awk '{ print $1 }')" ] ||
  fail 'authority sidecar changed after branch deletion'

status=0
(cd "$repo" && ATTENDED_TEST_RELEASE_EXIT=17 bash "$runner" \
  --output "$work/retained/release-failed.log" "${auto_args[@]}") \
  >"$work/release-failed.output" 2>&1 || status=$?
[ "$status" -eq 1 ] || fail 'failed release check passed'
grep -qx 'RELEASE_EXIT=17' "$work/retained/release-failed.log" ||
  fail 'failed release exit was not retained'
grep -qx 'ATTENDED_ANSWERS=2' "$work/retained/release-failed.log" ||
  fail 'failed release answers were not retained'
grep -q 'fixture release complete' "$work/retained/release-failed.log" ||
  fail 'failed release transcript was lost'

expect_attended_failure() {
  local label=$1 reason=$2 answers=$3 status=0
  (cd "$repo" && ATTENDED_TEST_MODE="$label" bash "$runner" \
    --output "$work/retained/$label.log" "${auto_args[@]}") \
    >"$work/$label.output" 2>&1 || status=$?
  [ "$status" -eq 1 ] || fail "$label was not refused"
  grep -qx "ATTENDED_FAILURE=$reason" "$work/retained/$label.log" ||
    { tail -10 "$work/retained/$label.log" >&2; fail "$label failure reason changed"; }
  grep -qx "ATTENDED_ANSWERS=$answers" "$work/retained/$label.log" ||
    fail "$label answer count changed"
  [ -s "$work/retained/$label.log.authority" ] ||
    fail "$label lost retained authority"
}
expect_attended_failure malformed unexpected_or_malformed_notice 0
expect_attended_failure out_of_order unexpected_or_malformed_notice 0
expect_attended_failure duplicate_first unexpected_or_malformed_notice 1
expect_attended_failure missing_second missing_attended_notice 1
expect_attended_failure malformed_second unexpected_or_malformed_notice 1
expect_attended_failure duplicate_second unexpected_or_malformed_notice 2

(cd "$repo" && ATTENDED_TEST_MODE=human_success bash "$runner" \
  --output "$work/retained/human.log") >"$work/human.output" 2>&1 ||
  fail 'human terminal path failed'
grep -qx 'RELEASE_EXIT=0' "$work/retained/human.log" ||
  fail 'human terminal exit was not retained'
grep -qx 'ATTENDED_ANSWERS=0' "$work/retained/human.log" ||
  fail 'human terminal path claimed automatic answers'
grep -q 'fixture human path complete \[REDACTED\]' "$work/retained/human.log" &&
  ! grep -Fq "$OPENAI_API_KEY" "$work/retained/human.log" ||
  fail 'human terminal path published a credential'
status=0
(cd "$repo" && ATTENDED_TEST_MODE=human_failure bash "$runner" \
  --output "$work/retained/human-failed.log") >"$work/human-failed.output" 2>&1 ||
  status=$?
[ "$status" -eq 1 ] &&
  grep -qx 'RELEASE_EXIT=17' "$work/retained/human-failed.log" ||
  fail 'human terminal path lost the release failure'

# A signal to the wrapper must reach the PTY child's process group. The
# controller waits for the direct child and leaves a failure transcript.
signal_log="$work/retained/signal.log"
signal_marker="$work/signal-child.pid"
(
  cd "$repo"
  exec env ATTENDED_TEST_MODE=hang ATTENDED_TEST_CHILD_MARKER="$signal_marker" \
    bash "$runner" --output "$signal_log" "${auto_args[@]}"
) >"$work/signal.output" 2>&1 &
runner_pid=$!
for _ in $(seq 1 100); do
  [ -s "$signal_marker" ] && break
  sleep 0.05
done
[ -s "$signal_marker" ] || { kill -TERM "$runner_pid" 2>/dev/null || true; fail 'signal child did not start'; }
child_pid=$(cat "$signal_marker")
kill -TERM "$runner_pid"
status=0
wait "$runner_pid" || status=$?
[ "$status" -ne 0 ] || fail 'interrupted runner passed'
grep -qx 'ATTENDED_FAILURE=interrupted' "$signal_log" ||
  fail 'signal did not retain interruption outcome'
if kill -0 "$child_pid" 2>/dev/null; then fail 'PTY child survived interruption'; fi

before=$(shasum -a 256 "$good" | awk '{print $1}')
status=0
(cd "$repo" && bash "$runner" --output "$good" "${auto_args[@]}") \
  >"$work/reuse.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ "$before" = "$(shasum -a 256 "$good" | awk '{print $1}')" ] ||
  fail 'successful transcript was overwritten'

python3 - "$source_root/scripts/attended-pty.py" <<'PY'
import runpy
import sys

Redactor = runpy.run_path(sys.argv[1])["Redactor"]
redactor = Redactor([b"abcde", b"bcd"])
published = b"".join(
    (redactor.feed(b"a"), redactor.feed(b"bc"),
     redactor.feed(b"de and b"), redactor.feed(b"cd", final=True))
)
assert published == b"[REDACTED] and [REDACTED]"
PY

printf '<a id="edge"></a>\nMilestone: M6\nTested SHA: %s\nAutomatic attended answers: authorized' \
  "$tested" >"$work/context-without-final-newline"
python3 "$source_root/scripts/attended-pty.py" --extract-context \
  "$work/context-without-final-newline" edge >"$work/exact-extraction"
cmp -s "$work/context-without-final-newline" "$work/exact-extraction" ||
  fail 'authority extraction added or removed bytes'

printf 'attended-release-test: PASS\n'
