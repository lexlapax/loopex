#!/usr/bin/env bash
# Concept: capture one attended release check without turning the M5 driver
# exception into standing permission to answer a person's prompts.
# Technical depth: automatic answers require an exact descendant disposition;
# the PTY controller owns automatic terminal answers; published output is redacted.
set -euo pipefail
# Stop inherited tracing before any key expansion and keep caller startup
# hooks from running again in this runner's Bash children.
set +x
unset BASH_ENV ENV
# The runner needs shell-held values for exact-byte redaction. Git, staging,
# digests and other unrelated children must not inherit caller-exported keys.
export -n LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY

with_redaction_keys() {
  export LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY
  exec "$@"
}

safe_line() {
  local channel=$1 message=$2 name value candidate
  candidate=$'\n'"$message"$'\n'
  for name in LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
    value=${!name:-}
    if [ -n "$value" ]; then
      case "$candidate" in *"$value"*) return 0 ;; esac
    fi
  done
  if [ "$channel" -eq 2 ]; then
    printf '\n%s\n' "$message" >&2
  else
    printf '\n%s\n' "$message"
  fi
}
usage() {
  safe_line 2 'usage: attended-release.sh --output LOG [--answer-attended --disposition ANCHOR --milestone NAME --authority-sha AUTH_SHA] [M7 release-check options]'
  exit 2
}

fail() { safe_line 2 "attended-release: $1"; exit 1; }

output=''
automatic=0
anchor=''
milestone=''
authority_sha=''
# The M7 closure matrix options pass through unchanged to check-release.sh,
# each at most once; that script validates their values.
check_args=()
check_seen=' '
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      [ "$#" -ge 2 ] && [ -z "$output" ] || usage
      output=$2
      shift 2 ;;
    --answer-attended)
      [ "$automatic" -eq 0 ] || usage
      automatic=1
      shift ;;
    --disposition)
      [ "$#" -ge 2 ] && [ -z "$anchor" ] || usage
      anchor=$2
      shift 2 ;;
    --milestone)
      [ "$#" -ge 2 ] && [ -z "$milestone" ] || usage
      milestone=$2
      shift 2 ;;
    --authority-sha)
      [ "$#" -ge 2 ] && [ -z "$authority_sha" ] || usage
      authority_sha=$2
      shift 2 ;;
    --attempts-index|--writer|--host|--markers|--m7-config|--operator|--pins|--resume-matrix)
      [ "$#" -ge 2 ] || usage
      case "$check_seen" in *" $1 "*) usage ;; esac
      case "$2" in ''|*$'\n'*|*$'\r'*) usage ;; esac
      check_seen="$check_seen$1 "
      check_args+=("$1" "$2")
      shift 2 ;;
    *) usage ;;
  esac
done

[ -n "$output" ] || usage
case "$output" in *$'\n'*|*$'\r'*) fail invalid_output_path ;; esac
if [ "$automatic" -eq 1 ]; then
  [ -n "$anchor" ] && [ -n "$milestone" ] && [ -n "$authority_sha" ] || usage
else
  [ -z "$anchor" ] && [ -z "$milestone" ] && [ -z "$authority_sha" ] || usage
fi

case "$output" in
  /*|./*|../*) ;;
  *) output="./$output" ;;
esac
[ -d "$(dirname "$output")" ] || fail output_parent_missing
output_parent=$(cd "$(dirname "$output")" && pwd -P)
output="$output_parent/$(basename "$output")"
case "$output" in *$'\n'*|*$'\r'*) fail invalid_output_path ;; esac
sidecar="$output.authority"
[ ! -e "$output" ] && [ ! -L "$output" ] &&
  [ ! -e "$sidecar" ] && [ ! -L "$sidecar" ] || fail output_exists

script_dir=$(cd "$(dirname "$0")" && pwd -P)
redact_human() {
  env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    -u OPENROUTER_API_KEY ERL_CRASH_DUMP=/dev/null ERL_CRASH_DUMP_SECONDS=0 \
    elixir "$script_dir/attended-redact.exs" \
    3< <(printf '%s\0%s\0%s\0%s\0' \
      "${LOOPEX_PROVIDER_API_KEY:-}" "${OPENAI_API_KEY:-}" \
      "${ANTHROPIC_API_KEY:-}" "${OPENROUTER_API_KEY:-}") \
    4<&0 5>&1 </dev/null >/dev/null
}
redact_record() {
  if [ "$automatic" -eq 1 ]; then
    (with_redaction_keys python3 "$script_dir/attended-pty.py" --redact-stdin)
  else
    redact_human
  fi
}
checkout=$(git rev-parse --show-toplevel 2>/dev/null) || fail not_a_repository
checkout=$(cd "$checkout" && pwd -P)
cd "$checkout"
case "$output/" in "$checkout/"*) fail output_inside_checkout ;; esac
[ -z "$(git status --porcelain)" ] || fail dirty_candidate
tested_sha=$(git rev-parse HEAD)
[[ "$tested_sha" =~ ^[0-9a-f]{40}$ ]] || fail invalid_tested_sha
platform=$(uname -s)
case "$platform" in Darwin|Linux) ;; *) fail unsupported_platform ;; esac
if [ "$automatic" -eq 1 ]; then
  command -v python3 >/dev/null 2>&1 || fail python3_unavailable
else
  command -v script >/dev/null 2>&1 || fail script_unavailable
  command -v elixir >/dev/null 2>&1 || fail elixir_unavailable
fi

# The four release-provider names are the supported credential set. Refusing
# multiline values lets the record-oriented redactor cover every exact value.
for name in LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
  value=${!name:-}
  case "$value" in *$'\n'*|*$'\r'*) fail credential_value_unredactable ;; esac
  if [ -n "$value" ]; then
    case "$output" in *"$value"*) fail output_contains_credential ;; esac
    for argument in ${check_args[@]+"${check_args[@]}"}; do
      case "$argument" in *"$value"*) fail argument_contains_credential ;; esac
    done
  fi
done
unset value argument

scratch=$(mktemp -d "${TMPDIR:-/tmp}/loopex-attended.XXXXXX") || fail scratch_unavailable
chmod 700 "$scratch"
cleanup() { rm -rf "$scratch"; }
trap cleanup EXIT
# Both launch paths run this private wrapper, so the forwarded options reach
# check-release.sh exactly; it holds no credential value.
release_check="$scratch/release-check"
printf 'exec bash %q' "$script_dir/check-release.sh" >"$release_check"
for argument in ${check_args[@]+"${check_args[@]}"}; do printf ' %q' "$argument" >>"$release_check"; done
printf '\n' >>"$release_check"

if [ "$automatic" -eq 1 ]; then
  [[ "$anchor" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || fail invalid_anchor
  [[ "$milestone" =~ ^M[0-9]+$ ]] || fail invalid_milestone
  [[ "$authority_sha" =~ ^[0-9a-f]{40}$ ]] || fail invalid_authority_sha
  [ "$authority_sha" != "$tested_sha" ] || fail authority_not_descendant
  [ "$(git --no-replace-objects cat-file -t "$authority_sha" 2>/dev/null || true)" = commit ] ||
    fail invalid_authority_sha
  git --no-replace-objects merge-base --is-ancestor "$tested_sha" "$authority_sha" || fail authority_not_descendant

  git --no-replace-objects show "$authority_sha:docs/developer/agent-context-map.md" >"$scratch/context" 2>/dev/null ||
    fail authority_context_unavailable
  awk -v anchor="$anchor" '
    $0 == "<a id=\"" anchor "\"></a>" { count++ }
    END { exit count != 1 }
  ' "$scratch/context" || fail disposition_not_unique
  python3 "$script_dir/attended-pty.py" --extract-context "$scratch/context" "$anchor" \
    >"$scratch/authority" || fail disposition_not_unique
  awk -v milestone="$milestone" -v tested="$tested_sha" '
    /^Milestone: / { milestones++; if ($0 != "Milestone: " milestone) bad = 1 }
    /^Tested SHA: / { shas++; if ($0 != "Tested SHA: " tested) bad = 1 }
    /^Automatic attended answers: / {
      permissions++
      if ($0 != "Automatic attended answers: authorized") bad = 1
    }
    END { exit bad || milestones != 1 || shas != 1 || permissions != 1 }
  ' "$scratch/authority" || fail disposition_mismatch
  # The sidecar must remain exact source bytes. A disposition that happens to
  # contain a live provider credential cannot be published as that sidecar.
  (with_redaction_keys python3 "$script_dir/attended-pty.py" --check-no-keys "$scratch/authority") ||
    fail disposition_contains_credential
fi

umask 077
if ! (set -C; : >"$output") 2>/dev/null; then fail output_unavailable; fi
if [ "$automatic" -eq 1 ]; then
  if ! (set -C; : >"$sidecar") 2>/dev/null; then
    printf 'ATTENDED_AUTHORITY=unavailable\nRELEASE_EXIT=not_started\nATTENDED_ANSWERS=0\n' |
      redact_record >>"$output" || true
    fail authority_publication_failed
  fi
  if ! cat "$scratch/authority" >"$sidecar"; then
    # A failed sidecar publication is an executed failure, but it must not
    # start the release check or leave a partial authority claim.
    rm -f "$sidecar"
    printf 'ATTENDED_AUTHORITY=unavailable\nRELEASE_EXIT=not_started\nATTENDED_ANSWERS=0\n' |
      redact_record >>"$output" || true
    fail authority_publication_failed
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum <"$sidecar" | awk '{print $1}')
  else
    digest=$(shasum -a 256 <"$sidecar" | awk '{print $1}')
  fi
  [[ "$digest" =~ ^[0-9a-f]{64}$ ]] || fail authority_digest_unavailable
  printf 'ATTENDED_AUTHORITY tested_sha=%s authority_sha=%s ancestry=strict-descendant sidecar=%s sha256=%s\n' \
    "$tested_sha" "$authority_sha" "$sidecar" "$digest" |
    with_redaction_keys python3 "$script_dir/attended-pty.py" --redact-stdin | tee -a "$output" ||
    fail authority_record_failed
fi

script_command() (
  # The terminal launcher carries only the selected keys into check-release:
  # provider A's release key and M7's provider B key. The two other provider
  # names stay absent from that process tree; the redactors cover all four.
  unset ANTHROPIC_API_KEY OPENROUTER_API_KEY
  export LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY
  if [ "$platform" = Darwin ]; then
    script -q -e -F /dev/null bash "$release_check"
  else
    SHELL=/bin/sh LOOPEX_ATTENDED_RELEASE_CHECK="$release_check" \
      script -q -e -f -c 'exec bash "$LOOPEX_ATTENDED_RELEASE_CHECK"' /dev/null
  fi
)

started=$SECONDS
set +e
if [ "$automatic" -eq 1 ]; then
  # The check's attended test opens /dev/tty. On Darwin, script(1) with FIFO
  # stdin fails before that terminal exists; pty.fork supplies it directly.
  controller=''
  forward_signal() {
    if [ -n "$controller" ]; then kill -TERM "$controller" 2>/dev/null || true; fi
  }
  trap forward_signal HUP INT TERM
  with_redaction_keys python3 "$script_dir/attended-pty.py" --output "$output" \
    --check "$release_check" &
  controller=$!
  while true; do
    wait "$controller"
    controller_status=$?
    if ! kill -0 "$controller" 2>/dev/null; then break; fi
  done
  trap - HUP INT TERM
  [ "$controller_status" -eq 0 ] || fail release_check_failed
else
  script_command 2>&1 | redact_human | tee -a "$output"
  statuses=("${PIPESTATUS[@]}")
fi
set -e

if [ "$automatic" -eq 0 ]; then
  printf '\nRELEASE_EXIT=%s\nATTENDED_ANSWERS=0\nDURATION_S=%s\n' \
    "${statuses[0]}" "$((SECONDS - started))" |
    redact_human | tee -a "$output" ||
    fail summary_record_failed
  [ "${statuses[0]}" -eq 0 ] && [ "${statuses[1]}" -eq 0 ] &&
    [ "${statuses[2]}" -eq 0 ] || fail release_check_failed
fi
safe_line 1 'attended-release: PASS'
