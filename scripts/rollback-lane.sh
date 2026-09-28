#!/usr/bin/env bash
# Concept: a credential-free release lane rebuilds the pristine v0.2.0 and
# candidate archives independently before crossing their durable roots.
# Technical depth: the outer runner supplies exact archived bytes, complete
# Git-tree projections and source identities; this driver never consults Git
# or the checkout. Every child build has private deps and _build paths.
set -euo pipefail

if [ "$#" -ne 9 ]; then
  echo 'usage: rollback-lane.sh RETAIN OLD_SHA OLD_ARCHIVE OLD_TREE OLD_ID NEW_SHA NEW_ARCHIVE NEW_TREE NEW_ID' >&2
  exit 2
fi
retain=$1 old_sha=$2 old_archive=$3 old_projection=$4 old_identity=$5
new_sha=$6 new_archive=$7 new_projection=$8 new_identity=$9
case "$old_sha" in
  3f81b04828901a6fb05b29e8b6bed211eed2d376) ;;
  *) echo 'rollback: released v0.2.0 identity differs from closure' >&2; exit 2 ;;
esac
case "$new_sha" in
  *[!0123456789abcdef]*|'') echo 'rollback: invalid candidate SHA' >&2; exit 2 ;;
esac
[ "${#new_sha}" -eq 40 ] || { echo 'rollback: invalid candidate SHA' >&2; exit 2; }
for variable in LOOPEX_PROVIDER_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY OPENROUTER_API_KEY; do
  [ -z "${!variable+x}" ] || { printf 'rollback: ambient %s must be absent\n' "$variable" >&2; exit 2; }
done
unset MIX_BUILD_PATH MIX_BUILD_ROOT

source_dir=$(cd "$(dirname "$0")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/loopex-rollback.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
elixir_bin=$(command -v elixir)
erl_dir=$(dirname "$(command -v erl)")

check_archive() {
  local label=$1 sha=$2 archive=$3 projection=$4 identity=$5 tree="$scratch/$1"
  (umask 022; mkdir "$tree"; tar -xf "$archive" -C "$tree")
  bash "$source_dir/scripts/source-archive-manifest.sh" "$tree" >"$scratch/$label.manifest"
  elixir "$source_dir/scripts/rollback-archive-check.exs" \
    "$scratch/$label.manifest" "$projection" "$identity" "$sha" "$tree"
  printf 'rollback: %s source %s archive_sha256=%s\n' "$label" "$sha" "$(digest "$archive")"
}

digest() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

make_launch() {
  local label=$1 tree="$scratch/$1" wrapper="$scratch/$1-worker.sh" launch="$scratch/$1.launch"
  printf '#!/bin/sh\nPATH="%s:/usr/bin:/bin" ERL_LIBS="%s/_build/prod/lib" exec "%s" "%s/scripts/rollback-worker.exs" "$@"\n' \
    "$erl_dir" "$tree" "$elixir_bin" "$source_dir" >"$wrapper"
  chmod 700 "$wrapper"
  ROLLBACK_WORKER="$wrapper" ROLLBACK_DIGEST="$(digest "$wrapper")" \
    ROLLBACK_MANIFEST="$(digest "$archive")" ROLLBACK_CONFIG="$launch" \
    elixir -e '
      options = [
        worker_path: System.fetch_env!("ROLLBACK_WORKER"),
        interpreter_path: "/bin/sh",
        worker_sha256: System.fetch_env!("ROLLBACK_DIGEST"),
        build_manifest_sha256: System.fetch_env!("ROLLBACK_MANIFEST"),
        cleanup_grace_ms: 2_000
      ]
      File.write!(System.fetch_env!("ROLLBACK_CONFIG"), :io_lib.format("~p.~n", [options]))
    '
}

build_pair() {
  local label=$1 tree="$scratch/$1" launch="$scratch/$1.launch"
  printf 'rollback: %s acquire locked dependencies\n' "$label"
  (cd "$tree" && MIX_ENV=prod mix deps.get)
  printf 'rollback: %s compile app-server driver environment\n' "$label"
  (cd "$tree/apps/loopex_app_server" && MIX_ENV=prod mix compile --warnings-as-errors)
  printf 'rollback: %s build fixture-paired CLI\n' "$label"
  (cd "$tree/apps/loopex_cli" && MIX_ENV=prod LOOPEX_BUILD_PROVIDER_CONFIG="$launch" \
    mix run --no-start -e '
      tasks = ["compile", "compile.all", "compile.protocols"] ++
        Enum.map(Mix.Project.config()[:compilers] || Mix.compilers(), &"compile.#{&1}")
      Enum.each(tasks, &Mix.Task.reenable/1)
      Mix.Task.run("compile", ["--force", "--warnings-as-errors"])
      Mix.Tasks.Escript.Build.run([])
    ')
  [ -f "$tree/apps/loopex_cli/loopex" ] || { echo 'rollback: CLI build absent' >&2; exit 1; }
}

archive=$old_archive
check_archive old "$old_sha" "$old_archive" "$old_projection" "$old_identity"
make_launch old
archive=$new_archive
check_archive new "$new_sha" "$new_archive" "$new_projection" "$new_identity"
make_launch new
build_pair old
build_pair new

# The public facade witness is deliberately a separate driver process for
# each direction. A binary is not invoked until both isolated builds finish.
for direction in old-to-new new-to-old; do
  printf 'rollback: pending interaction %s\n' "$direction"
  bash "$source_dir/scripts/rollback-case.sh" "$scratch" "$direction" read
done
bash "$source_dir/scripts/rollback-binary-case.sh" "$scratch"
bash "$source_dir/scripts/rollback-skill-case.sh" "$scratch"
printf 'rollback: M6-only pending tool under released v0.2 reader\n'
bash "$source_dir/scripts/rollback-case.sh" "$scratch" new-to-old unknown-tool

printf 'rollback: PASS paired builds, interactions, unknown tool, CLI and skill/daemon cases\n'
