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
digest_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

repo="$work/repo"
mkdir -p "$repo/scripts" "$repo/docs/developer" "$work/retained"
cp "$source_root/scripts/attended-release.sh" "$repo/scripts/attended-release.sh"
cp "$source_root/scripts/attended-pty.py" "$repo/scripts/attended-pty.py"
cp "$source_root/scripts/attended-redact.exs" "$repo/scripts/attended-redact.exs"
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
if [ -n "${ANTHROPIC_API_KEY+set}${OPENROUTER_API_KEY+set}" ]; then
  printf 'ambient provider credential reached the release check\n'
  exit 63
fi
case "${ATTENDED_TEST_MODE:-}" in
  human_success)
    printf 'fixture human path complete %s %s %s %s\n' \
      "${LOOPEX_PROVIDER_API_KEY:-}" 'synthetic-openai-key-[42]' \
      'synthetic-anthropic-key' 'synthetic-openrouter-key'
    if [ -n "${ATTENDED_TEST_ECHO_FILE:-}" ]; then cat "$ATTENDED_TEST_ECHO_FILE"; fi
    exit 0 ;;
  human_failure) printf 'fixture human path failed\n'; exit 17 ;;
  m7_args)
    printf 'forwarded:'
    for argument in "$@"; do printf ' [%s]' "$argument"; done
    printf '\nprovider a: %s\nprovider b: %s\n' \
      "${LOOPEX_PROVIDER_API_KEY:-}" "${OPENAI_API_KEY:-}"
    exit 0 ;;
  human_no_newline) printf 'tail'; exit 0 ;;
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
printf 'provider echo: %s and %s\n' "${LOOPEX_PROVIDER_API_KEY:-}" 'synthetic-openai-key-[42]'
value=synthetic-openrouter-key
printf 'split credential: %s' "${value:0:10}"
sleep 0.05
printf '%s\n' "${value:10}"
printf 'forwarded:'
for argument in "$@"; do printf ' [%s]' "$argument"; done
printf '\nfixture release complete\n'
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
git -C "$repo" replace "$wrong_record" "$authority"
expect_preflight_failure replaced_wrong_record disposition_mismatch \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$wrong_record"
git -C "$repo" replace -d "$wrong_record" >/dev/null

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
bad_output="$work/retained/"$'bad\nRELEASE_EXIT=0'".log"
status=0
(cd "$repo" && bash "$runner" --output "$bad_output") \
  >"$work/bad-path.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ ! -e "$bad_output" ] &&
  grep -q 'attended-release: invalid_output_path' "$work/bad-path.output" ||
  fail 'line-oriented evidence path was accepted'
physical_parent="$work/retained/"$'physical\nRELEASE_EXIT=0'
mkdir "$physical_parent"
ln -s "$physical_parent" "$work/retained/alias"
status=0
(cd "$repo" && bash "$runner" --output "$work/retained/alias/injected.log") \
  >"$work/symlink-path.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ ! -e "$physical_parent/injected.log" ] &&
  grep -q 'attended-release: invalid_output_path' "$work/symlink-path.output" ||
  fail 'canonicalized line-oriented evidence path was accepted'

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
mkdir "$work/env-bin"
cat >"$work/env-bin/git" <<'EOF'
#!/usr/bin/env bash
if [ -n "${LOOPEX_PROVIDER_API_KEY+set}${OPENAI_API_KEY+set}${ANTHROPIC_API_KEY+set}${OPENROUTER_API_KEY+set}" ]; then
  printf 'present\n' >>"$ATTENDED_TEST_ENV_MARKER"
else
  printf 'absent\n' >>"$ATTENDED_TEST_ENV_MARKER"
fi
exec "$ATTENDED_TEST_REAL_GIT" "$@"
EOF
chmod +x "$work/env-bin/git"
export ATTENDED_TEST_REAL_GIT
ATTENDED_TEST_REAL_GIT=$(command -v git)
status=0
(cd "$repo" && PATH="$work/env-bin:$PATH" ATTENDED_TEST_ENV_MARKER="$work/git-env-marker" \
  bash "$runner" --output "$work/retained/credential-preflight.log" \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$tested") \
  >"$work/credential-preflight.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ -s "$work/git-env-marker" ] ||
  fail 'credential preflight did not exercise Git'
! grep -qx present "$work/git-env-marker" ||
  fail 'unrelated attended preflight inherited a provider credential'
git -C "$repo" switch -qc nul-secret "$tested"
{
  printf '\n<a id="%s"></a>\n' "$anchor"
  printf 'Milestone: M6\nTested SHA: %s\nAutomatic attended answers: authorized\n' "$tested"
  printf 'note\0%s\n' "$OPENAI_API_KEY"
} >>"$repo/docs/developer/agent-context-map.md"
git -C "$repo" add docs/developer/agent-context-map.md
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): authority with hidden credential bytes'
nul_secret=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q --detach "$tested"
expect_preflight_failure nul_secret disposition_not_unique \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$nul_secret"
git -C "$repo" switch -qc plain-secret "$tested"
{
  printf '\n<a id="%s"></a>\n' "$anchor"
  printf 'Milestone: M6\nTested SHA: %s\nAutomatic attended answers: authorized\n' "$tested"
  printf 'note %s\n' "$OPENAI_API_KEY"
} >>"$repo/docs/developer/agent-context-map.md"
git -C "$repo" add docs/developer/agent-context-map.md
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): authority with visible credential bytes'
plain_secret=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q --detach "$tested"
expect_preflight_failure plain_secret disposition_contains_credential \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$plain_secret"
git -C "$repo" switch -qc nul-permission "$tested"
{
  printf '\n<a id="%s"></a>\n' "$anchor"
  printf 'Milestone: M6\nTested SHA: %s\n' "$tested"
  printf 'Automatic attended answers: authorized\0denied\n'
} >>"$repo/docs/developer/agent-context-map.md"
git -C "$repo" add docs/developer/agent-context-map.md
git -C "$repo" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture(M6): NUL-suffixed authorization'
nul_permission=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch -q --detach "$tested"
expect_preflight_failure nul_permission disposition_not_unique \
  --answer-attended --disposition "$anchor" --milestone M6 --authority-sha "$nul_permission"
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
grep -q 'provider echo: <REDACTED> and <REDACTED>' "$good" ||
  fail 'provider values were not redacted'
grep -q 'split credential: <REDACTED>' "$good" ||
  fail 'a credential split between PTY reads was not redacted'
for secret in "$LOOPEX_PROVIDER_API_KEY" "$OPENAI_API_KEY" "$ANTHROPIC_API_KEY" "$OPENROUTER_API_KEY"; do
  if grep -Fq "$secret" "$good" "$work/good.output"; then fail 'credential appeared in published output'; fi
done
cat >"$work/reinject.bash" <<'EOF'
export LOOPEX_PROVIDER_API_KEY=synthetic-release-key-123
export OPENAI_API_KEY='synthetic-openai-key-[42]'
export ANTHROPIC_API_KEY=synthetic-anthropic-key
export OPENROUTER_API_KEY=synthetic-openrouter-key
EOF
BASH_ENV="$work/reinject.bash" bash -c '
  test "$OPENAI_API_KEY" = "synthetic-openai-key-[42]"' ||
  fail 'attended Bash startup-hook positive control did not run'
(cd "$repo" && BASH_ENV="$work/reinject.bash" bash "$runner" \
  --output "$work/retained/startup-hook.log" "${auto_args[@]}") \
  >"$work/startup-hook.output" 2>&1 ||
  fail 'attended launch passed ambient keys from a Bash startup hook'
grep -qx 'ATTENDED_ANSWERS=2' "$work/retained/startup-hook.log" ||
  fail 'startup-hook run did not complete both authorized notices'
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
digest=$(digest_file "$good.authority")
grep -q "sidecar=$good.authority sha256=$digest" "$good" ||
  { sed -n '1,30p' "$good" >&2; fail 'sidecar reference or digest missing'; }
grep -q "tested_sha=$tested authority_sha=$authority ancestry=strict-descendant" "$good" ||
  fail 'ancestry and candidate identity missing'
git -C "$repo" branch -D authority >/dev/null
[ "$digest" = "$(digest_file "$good.authority")" ] ||
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
grep -q 'fixture human path complete <REDACTED> <REDACTED> <REDACTED> <REDACTED>' \
  "$work/retained/human.log" ||
  fail 'human terminal path published a credential'
for secret in "$LOOPEX_PROVIDER_API_KEY" "$OPENAI_API_KEY" "$ANTHROPIC_API_KEY" "$OPENROUTER_API_KEY"; do
  ! grep -Fq "$secret" "$work/retained/human.log" "$work/human.output" ||
    fail 'human terminal path published a credential'
done
status=0
(cd "$repo" && ATTENDED_TEST_MODE=human_failure bash "$runner" \
  --output "$work/retained/human-failed.log") >"$work/human-failed.output" 2>&1 ||
  status=$?
[ "$status" -eq 1 ] &&
  grep -qx 'RELEASE_EXIT=17' "$work/retained/human-failed.log" ||
  fail 'human terminal path lost the release failure'

# The M7 closure matrix options reach check-release.sh unchanged and in order
# on both launch paths, with provider A and B values present and redacted.
m7_args=(--attempts-index "$work/retained/m7 attempts.jsonl" --writer workstation
  --host host-1 --markers "$work/retained/markers" --m7-config "$work/m7 config.json"
  --operator 'A Person' --pins "$work/pins.json" --resume-matrix matrix-1)
m7_line="forwarded: [--attempts-index] [$work/retained/m7 attempts.jsonl] [--writer] [workstation] [--host] [host-1] [--markers] [$work/retained/markers] [--m7-config] [$work/m7 config.json] [--operator] [A Person] [--pins] [$work/pins.json] [--resume-matrix] [matrix-1]"
(cd "$repo" && ATTENDED_TEST_MODE=m7_args bash "$runner" \
  --output "$work/retained/human-m7.log" "${m7_args[@]}") >"$work/human-m7.output" 2>&1 ||
  fail 'human terminal path with M7 options failed'
tr -d '\r' <"$work/retained/human-m7.log" >"$work/human-m7.lines"
grep -qxF "$m7_line" "$work/human-m7.lines" ||
  fail 'human terminal path did not forward the M7 options exactly'
grep -qx 'provider a: <REDACTED>' "$work/human-m7.lines" &&
  grep -qx 'provider b: <REDACTED>' "$work/human-m7.lines" ||
  fail 'provider A and B values did not reach the check redacted'
(cd "$repo" && bash "$runner" --output "$work/retained/auto-m7.log" "${auto_args[@]}" \
  "${m7_args[@]}") >"$work/auto-m7.output" 2>&1 ||
  fail 'automatic path with M7 options failed'
tr -d '\r' <"$work/retained/auto-m7.log" | grep -qxF "$m7_line" ||
  fail 'automatic path did not forward the M7 options exactly'
for secret in "$LOOPEX_PROVIDER_API_KEY" "$OPENAI_API_KEY"; do
  ! grep -Fq "$secret" "$work/retained/human-m7.log" "$work/retained/auto-m7.log" \
    "$work/human-m7.output" "$work/auto-m7.output" ||
    fail 'M7 options run published a credential'
done
for refused in "--writer a --writer b" "--operator" "--host x --unknown y"; do
  status=0
  # shellcheck disable=SC2086
  (cd "$repo" && bash "$runner" --output "$work/retained/refused-m7.log" $refused) \
    >"$work/refused-m7.output" 2>&1 || status=$?
  [ "$status" -eq 2 ] && [ ! -e "$work/retained/refused-m7.log" ] &&
    grep -q 'usage: attended-release.sh' "$work/refused-m7.output" ||
    fail "malformed M7 options were accepted: $refused"
done
expect_preflight_failure m7_credential_argument argument_contains_credential \
  --operator "operator-$OPENAI_API_KEY"

# A human-attended run uses the baseline toolchain, not Python. Hide Python's
# availability check and make any later invocation fail, including one buried
# in a redaction pipeline.
human_without_python() (
  command() {
    if [ "$1" = -v ] && [ "$2" = python3 ]; then return 1; fi
    builtin command "$@"
  }
  python3() {
    : >"$work/python-invoked"
    return 97
  }
  export -f command python3
  cd "$repo"
  ATTENDED_TEST_MODE=$1 bash "$runner" --output "$2"
)
human_without_python human_success "$work/retained/human-no-python.log" \
  >"$work/human-no-python.output" 2>&1 ||
  fail 'human terminal path required Python'
[ ! -e "$work/python-invoked" ] || fail 'human terminal path invoked Python'
grep -qx 'RELEASE_EXIT=0' "$work/retained/human-no-python.log" ||
  fail 'human no-Python release exit was not retained'
grep -q 'fixture human path complete <REDACTED> <REDACTED> <REDACTED> <REDACTED>' \
  "$work/retained/human-no-python.log" ||
  fail 'human no-Python transcript exposed the credential'
for secret in "$LOOPEX_PROVIDER_API_KEY" "$OPENAI_API_KEY" "$ANTHROPIC_API_KEY" "$OPENROUTER_API_KEY"; do
  ! grep -Fq "$secret" "$work/retained/human-no-python.log" \
    "$work/human-no-python.output" ||
    fail 'human no-Python output exposed a credential'
done
status=0
human_without_python human_failure "$work/retained/human-failed-no-python.log" \
  >"$work/human-failed-no-python.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ ! -e "$work/python-invoked" ] &&
  grep -qx 'RELEASE_EXIT=17' "$work/retained/human-failed-no-python.log" ||
  fail 'human no-Python failure was not retained'

invalid_key=$'\377'
printf '%s\n' "$invalid_key" >"$work/invalid-key-echo"
(cd "$repo" && OPENAI_API_KEY="$invalid_key" ATTENDED_TEST_MODE=human_success \
  ATTENDED_TEST_ECHO_FILE="$work/invalid-key-echo" \
  bash "$runner" --output "$work/retained/human-invalid-byte.log") \
  >"$work/human-invalid-byte.output" 2>&1 ||
  fail 'human terminal path refused a raw credential byte'
grep -qx 'RELEASE_EXIT=0' "$work/retained/human-invalid-byte.log" ||
  fail 'human raw-byte release exit was not retained'
if LC_ALL=C grep -aFq "$invalid_key" "$work/retained/human-invalid-byte.log" \
  "$work/human-invalid-byte.output"; then
  fail 'human terminal path exposed a raw credential byte'
fi
joined_key='tailRELEASE_EXIT=0'
(cd "$repo" && OPENAI_API_KEY="$joined_key" ATTENDED_TEST_MODE=human_no_newline \
  bash "$runner" --output "$work/retained/human-unterminated.log") \
  >"$work/human-unterminated.output" 2>&1 ||
  fail 'human terminal path refused an unterminated transcript'
grep -qx 'RELEASE_EXIT=0' "$work/retained/human-unterminated.log" ||
  fail 'human unterminated release exit was not retained'
! grep -Fq "$joined_key" "$work/retained/human-unterminated.log" \
  "$work/human-unterminated.output" ||
  fail 'human summary synthesized a credential after the PTY transcript'
pass_key='attended-release: PASS'
(cd "$repo" && OPENAI_API_KEY="$pass_key" ATTENDED_TEST_MODE=human_success \
  bash "$runner" --output "$work/retained/human-pass-key.log") \
  >"$work/human-pass-key.output" 2>&1 ||
  fail 'human terminal path refused a diagnostic-shaped credential'
! grep -Fq "$pass_key" "$work/retained/human-pass-key.log" \
  "$work/human-pass-key.output" ||
  fail 'success diagnostic exposed a supported credential'

# A regular-file read supplies an exact 65,536-byte first chunk. The key begins
# two bytes before that boundary and the input has no final newline.
elixir_redact() {
  env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    -u OPENROUTER_API_KEY ERL_CRASH_DUMP=/dev/null ERL_CRASH_DUMP_SECONDS=0 \
    elixir "$repo/scripts/attended-redact.exs" \
    3< <(printf '%s\0%s\0%s\0%s\0' "$1" "$2" "$3" "$4") \
    4<&0 5>&1 </dev/null >/dev/null
}

# Keep the pipe open after a short prompt. It must reach the reader before a
# longer credential is completed or the producer closes its end of the pipe.
stream_gate="$work/redact-stream-release"
(
  printf 'yes?\na-very-long-'
  while [ ! -e "$stream_gate" ]; do sleep 0.05; done
  printf 'credential-value\n'
) | elixir_redact '' 'a-very-long-credential-value' '' '' \
  >"$work/redact-stream-actual" &
stream_pid=$!
prompt_seen=0
for _ in $(seq 1 200); do
  if grep -qx 'yes?' "$work/redact-stream-actual"; then prompt_seen=1; break; fi
  kill -0 "$stream_pid" 2>/dev/null || break
  sleep 0.05
done
if [ "$prompt_seen" -ne 1 ]; then
  touch "$stream_gate"
  wait "$stream_pid" || true
  fail 'redactor withheld a short prompt until pipe EOF'
fi
partial_seen=0
if grep -Fq 'a-very-long-' "$work/redact-stream-actual"; then partial_seen=1; fi
touch "$stream_gate"
stream_status=0
wait "$stream_pid" || stream_status=$?
[ "$partial_seen" -eq 0 ] || fail 'redactor published a partial credential'
[ "$stream_status" -eq 0 ] || fail 'redactor failed after a streaming prompt'
printf 'yes?\n[REDACTED]\n' >"$work/redact-stream-expected"
cmp -s "$work/redact-stream-expected" "$work/redact-stream-actual" ||
  fail 'redactor changed the streamed prompt or split credential'

# Descriptor/setup errors must stop before any unredacted transcript is sent.
status=0
env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
  -u OPENROUTER_API_KEY ERL_CRASH_DUMP=/dev/null ERL_CRASH_DUMP_SECONDS=0 \
  elixir "$repo/scripts/attended-redact.exs" \
  3< <(printf 'secret\0\0\0\0') 4<&- 5>&1 </dev/null \
  >"$work/redact-failed-actual" 2>"$work/redact-failed-error" || status=$?
[ "$status" -ne 0 ] && [ ! -s "$work/redact-failed-actual" ] &&
  grep -qx 'attended-redact: redaction_failed' "$work/redact-failed-error" ||
  fail 'redactor accepted a missing input descriptor'

awk 'BEGIN { for (i = 0; i < 65534; i++) printf "x" }' >"$work/redact-input"
printf '%s!%s' "$OPENROUTER_API_KEY" "$OPENAI_API_KEY" >>"$work/redact-input"
awk 'BEGIN { for (i = 0; i < 65534; i++) printf "x" }' >"$work/redact-expected"
printf '<REDACTED>!<REDACTED>' >>"$work/redact-expected"
elixir_redact "$LOOPEX_PROVIDER_API_KEY" "$OPENAI_API_KEY" \
  "$ANTHROPIC_API_KEY" "$OPENROUTER_API_KEY" \
  <"$work/redact-input" >"$work/redact-actual" ||
  fail 'human redactor refused a bounded split credential'
cmp -s "$work/redact-expected" "$work/redact-actual" ||
  fail 'human redactor changed bytes or missed a split credential'

printf 'abcdef' >"$work/overlap-input"
elixir_redact '' abc abcdef '' \
  <"$work/overlap-input" >"$work/overlap-actual" ||
  fail 'human redactor refused overlapping keys'
[ "$(cat "$work/overlap-actual")" = '[REDACTED]' ] ||
  fail 'human redactor did not choose the longest key at one position'

printf 'REDRED' | elixir_redact '' RED '' '' >"$work/marker-actual" ||
  fail 'human redactor refused a marker-contained key'
[ "$(cat "$work/marker-actual")" = '!!' ] ||
  fail 'human redactor repeated a key inside its marker'
printf 'aa[R' | elixir_redact '' 'a[R' '' '' >"$work/join-actual" ||
  fail 'human redactor refused a replacement-boundary key'
[ "$(cat "$work/join-actual")" = 'a<REDACTED>' ] ||
  fail 'human redactor synthesized a key across its marker boundary'
printf 'x%sx' "$invalid_key" | elixir_redact '' "$invalid_key" '' '' \
  >"$work/invalid-byte-actual" || fail 'human redactor refused a raw credential byte'
[ "$(cat "$work/invalid-byte-actual")" = 'x[REDACTED]x' ] ||
  fail 'human redactor decoded or missed a raw credential byte'
printf 'xcaféx' | elixir_redact '' 'café' '' '' >"$work/utf8-actual" ||
  fail 'human redactor refused a UTF-8 credential'
[ "$(cat "$work/utf8-actual")" = 'x[REDACTED]x' ] ||
  fail 'human redactor changed a UTF-8 credential byte sequence'

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
if ! grep -qx 'ATTENDED_FAILURE=interrupted' "$signal_log"; then
  tail -n 16 "$signal_log" >&2
  tail -n 16 "$work/signal.output" >&2
  fail 'signal did not retain interruption outcome'
fi
if kill -0 "$child_pid" 2>/dev/null; then fail 'PTY child survived interruption'; fi

before=$(digest_file "$good")
status=0
(cd "$repo" && bash "$runner" --output "$good" "${auto_args[@]}") \
  >"$work/reuse.output" 2>&1 || status=$?
[ "$status" -eq 1 ] && [ "$before" = "$(digest_file "$good")" ] ||
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
for key, input_bytes in ((b"RED", b"REDRED"), (b"a[R", b"aa[R")):
    redactor = Redactor([key])
    published = redactor.feed(input_bytes, final=True)
    assert key not in published
    if key == b"RED":
        assert published == b"!!"
    else:
        assert published == b"a<REDACTED>"
PY

printf '<a id="edge"></a>\nMilestone: M6\nTested SHA: %s\nAutomatic attended answers: authorized' \
  "$tested" >"$work/context-without-final-newline"
python3 "$source_root/scripts/attended-pty.py" --extract-context \
  "$work/context-without-final-newline" edge >"$work/exact-extraction"
cmp -s "$work/context-without-final-newline" "$work/exact-extraction" ||
  fail 'authority extraction added or removed bytes'

printf 'attended-release-test: PASS\n'
