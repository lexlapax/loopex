#!/usr/bin/env bash
# Shared by the release runner and its executable fixtures. Selection is a
# union; repeated selector names are refused before any release work begins.
release_select() {
  release_mode=full
  release_selectors=""
  while [ "$#" -gt 0 ]; do
    [ "$1" = --only ] && [ "$#" -ge 2 ] ||
      { echo 'check-release: usage: check-release.sh [--only NAME ...]' >&2; return 2; }
    case "$2" in
      real_provider | node_client | long_bound | cross_uid | rollback | real-provider-[3-9] | real-provider-10 | real-provider-11) ;;
      real-provider-1 | real-provider-2)
        echo 'check-release: attended rows cannot be selected; run the full closure matrix' >&2
        return 2 ;;
      *) echo 'check-release: unknown selector' >&2; return 2 ;;
    esac
    case " $release_selectors " in
      *" $2 "*) echo 'check-release: duplicate selector' >&2; return 2 ;;
    esac
    release_selectors="${release_selectors:+$release_selectors }$2"
    release_mode=selection-only
    shift 2
  done
}

release_selected() {
  [ "$release_mode" = full ] && return 0
  case " $release_selectors " in *" $1 "*) return 0 ;; esac
  case "$1" in
    real-provider-[3-9] | real-provider-10 | real-provider-11)
      case " $release_selectors " in *' real_provider '*) return 0 ;; esac ;;
  esac
  return 1
}

release_needs_provider() {
  local row
  for row in 1 2 3 4 5 6 7 8 9 11; do
    release_selected "real-provider-$row" && return 0
  done
  return 1
}

release_needs_ollama() {
  release_selected real-provider-10
}

release_needs_node() {
  release_selected node_client || release_selected real-provider-4 || release_selected real-provider-9
}

release_digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum <"$1" | awk '{print $1}'
  else
    shasum -a 256 <"$1" | awk '{print $1}'
  fi
}

release_retain_identity() {
  local path=$1 sha
  if ! sha=$(release_digest "$path") || [ "${#sha}" -ne 64 ]; then
    printf 'check-release: retained digest unavailable: %s\n' "$path" >&2
    return 1
  fi
  case "$sha" in
    *[!0123456789abcdef]*)
      printf 'check-release: retained digest unavailable: %s\n' "$path" >&2
      return 1 ;;
  esac
  printf 'check-release: retained %s sha256=%s\n' "$path" "$sha"
}

# Preserve the fresh archive's ordinary SOURCE_IDENTITY beside its manifest,
# where the later read-only pre-tag comparison requires it.
release_retain_source_identity() {
  local source=$1 target=$2
  if [ ! -f "$source" ] || [ -L "$source" ] || [ ! -s "$source" ] ||
     [ ! -f "$target" ] || [ -L "$target" ] || [ -s "$target" ]; then
    printf 'check-release: source identity sidecar is unavailable or reused\n' >&2
    return 1
  fi
  if ! cp "$source" "$target" || ! cmp -s "$source" "$target"; then
    printf 'check-release: source identity sidecar could not be retained exactly\n' >&2
    return 1
  fi
  release_retain_identity "$target"
}

# Source text alone cannot distinguish an ExUnit case from a comment, string,
# quoted form, or locally imported no-op macro. Require a direct fully rooted
# ExUnit macro outside describe; the result is module TAB source line.
release_definition_lines() {
  local source=$1 name=$2 script
  script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/release-test-definition.exs"
  elixir "$script" "$source" "$name"
}

# Validate the complete manifest before its first selected case can dispatch.
# A repeated case cannot replace an omitted witness while preserving row count.
release_manifest_valid() {
  local manifest=$1 source_tree=$2 expected=$3 rows=0 app file name definitions
  if ! awk -F'|' -v expected="$expected" '
    NF != 3 || $1 == "" || $2 == "" || $3 == "" { invalid = 1 }
    seen[$0]++ { invalid = 1 }
    END { exit (invalid || NR != expected) }
  ' "$manifest"; then
    echo 'check-release: manifest must contain the exact count of unique well-formed cases' >&2
    return 1
  fi
  while IFS='|' read -r -u 4 app file name; do
    rows=$((rows + 1))
    definitions=$(release_definition_lines "$source_tree/apps/$app/$file" "$name" || true)
    if [ -z "$definitions" ] ||
       [ "$(printf '%s\n' "$definitions" | wc -l | tr -d ' ')" != 1 ]; then
      printf 'check-release: manifest row %s needs exactly one top-level Elixir.ExUnit.Case.test in %s\n' \
        "$rows" "$app/$file" >&2
      return 1
    fi
  done 4<"$manifest"
}

# Bind each real-provider result to the ExUnit event, not just the CLI count.
# The sidecar is private retained evidence; an absent or mismatched event
# refuses the lane even when a different test printed a green summary.
release_case_lane() {
  local label=$1 app=$2 file=$3 name=$4 module=$5 line=$6 wrap=$7
  local sidecar="$retain/$label.identity" expected actual source_file status=0
  if ! (umask 077; set -C; : >"$sidecar") 2>/dev/null; then
    printf 'check-release: %s identity sidecar unavailable or reused\n' "$label" >&2
    return 1
  fi
  export LOOPEX_RELEASE_TEST_IDENTITY_PATH="$sidecar"
  lane "$label" "$app" 1 "$wrap" \
    elixir -r "$tree/scripts/release-test-identity-formatter.exs" -S mix test "$file" \
    --only "test:test $name" \
    --formatter ExUnit.CLIFormatter \
    --formatter LoopexReleaseTestIdentityFormatter || status=$?
  unset LOOPEX_RELEASE_TEST_IDENTITY_PATH
  release_retain_identity "$sidecar" || return 1
  [ "$status" -eq 0 ] || return 1
  source_file="$(cd "$(dirname "$tree/apps/$app/$file")" && pwd -P)/$(basename "$file")"
  expected=$(printf '%s\ttest %s\t%s\t%s\ttrue\ttrue' \
    "$module" "$name" "$source_file" "$line")
  actual=$(cat "$sidecar") || return 1
  if [ "$(wc -l <"$sidecar" | tr -d ' ')" != 1 ] || [ "$actual" != "$expected" ]; then
    printf 'check-release: %s executed test identity does not match its manifest definition\n' "$label" >&2
    return 1
  fi
  printf 'check-release: %s executed the named test at %s:%s\n' "$label" "$app/$file" "$line"
}

# The release shell holds the four supported values without exporting them to
# unrelated helpers. A lane's redactor receives their raw bytes on a private
# descriptor, not in argv or its environment, and publishes only masked bytes.
release_redact() {
  env -u LOOPEX_PROVIDER_API_KEY -u OPENAI_API_KEY -u ANTHROPIC_API_KEY \
    -u OPENROUTER_API_KEY ERL_CRASH_DUMP=/dev/null ERL_CRASH_DUMP_SECONDS=0 \
    elixir "$tree/scripts/attended-redact.exs" \
    3< <(printf '%s\0%s\0%s\0%s\0' \
      "${LOOPEX_PROVIDER_API_KEY:-}" "${OPENAI_API_KEY:-}" \
      "${ANTHROPIC_API_KEY:-}" "${OPENROUTER_API_KEY:-}") \
    4<&0 5>&1 </dev/null >/dev/null
}

# A failed command, redactor or parser still has an immutable evidence log.
# The runner supplies tree and retain; fixtures supply disposable trees with
# real judges.
lane() {
  local label=$1 app=$2 expected=$3 wrap=$4 lane_started=$SECONDS
  local log summary_status executed=unavailable duration append_status=0
  local pipeline_statuses
  shift 4
  log="$retain/$label.log"
  if ! (umask 077; set -C; : >"$log") 2>/dev/null; then
    printf 'check-release: %s evidence log unavailable or already exists\n' "$label" >&2
    return 1
  fi
  printf 'check-release: %s\n' "$label"
  set +e
  (cd "$tree/apps/$app" && "$wrap" "$@") 2>&1 | release_redact | tee "$log"
  pipeline_statuses=("${PIPESTATUS[@]}")
  set -e
  if executed=$(bash "$tree/scripts/suite-summary.sh" "$log" --count); then
    summary_status=0
    case "$executed" in
      '' | *[!0-9]*) executed=unavailable; summary_status=1 ;;
    esac
  else
    summary_status=$?
    executed=unavailable
  fi
  duration=$((SECONDS - lane_started))
  printf 'lane-evidence: command_status=%s tee_status=%s summary_status=%s executed_count=%s duration_seconds=%s redactor_status=%s\n' \
    "${pipeline_statuses[0]}" "${pipeline_statuses[2]}" "$summary_status" "$executed" "$duration" \
    "${pipeline_statuses[1]}" >>"$log" || append_status=$?
  if [ "$append_status" -ne 0 ] || ! release_retain_identity "$log"; then
    printf 'check-release: %s retained digest unavailable\n' "$label" >&2
    return 1
  fi
  if [ "${pipeline_statuses[0]}" -ne 0 ] || [ "${pipeline_statuses[1]}" -ne 0 ] ||
     [ "${pipeline_statuses[2]}" -ne 0 ] || [ "$summary_status" -ne 0 ]; then
    printf 'check-release: %s RED command=%s redactor=%s tee=%s summary=%s count=%s elapsed=%ss\n' \
      "$label" "${pipeline_statuses[0]}" "${pipeline_statuses[1]}" \
      "${pipeline_statuses[2]}" "$summary_status" "$executed" "$duration" >&2
    return 1
  fi
  if [ "$executed" -eq 0 ] || { [ "$expected" != nonzero ] && [ "$executed" != "$expected" ]; }; then
    printf 'check-release: %s executed %s tests, expected %s\n' "$label" "$executed" "$expected" >&2
    return 1
  fi
  printf 'check-release: %s executed=%s elapsed=%ss\n' "$label" "$executed" "$duration"
}
