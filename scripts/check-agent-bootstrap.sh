#!/usr/bin/env bash
# Portable check for project instructions, skills, and client adapters.
#
# The structural half -- adapter pointers, role profiles, key sets, hook
# registration, and the hosted wrapper -- runs on the accepted Elixir/OTP
# toolchain through `mix loopex.agent_bootstrap`. What stays here is what is
# genuinely about the shell and the filesystem: which commands exist, which files
# are executable, whether every script parses, and whether each guard still
# rejects its fixture when run as the client would run it.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

fail() {
  echo "agent bootstrap check failed: $*" >&2
  exit 1
}

for required_command in bash git awk cat grep readlink sed tr mix; do
  command -v "$required_command" >/dev/null 2>&1 || fail "missing $required_command"
done

mix loopex.agent_bootstrap

[ "$(tr -d '\r\n' < CLAUDE.md)" = "@AGENTS.md" ] ||
  fail "CLAUDE.md must contain only @AGENTS.md"

[ -s DEVELOPMENT.md ] || fail "missing DEVELOPMENT.md"
grep -Fq '[DEVELOPMENT.md](DEVELOPMENT.md)' README.md ||
  fail "README.md must link DEVELOPMENT.md"
grep -Fq 'bash scripts/check-bootstrap.sh' DEVELOPMENT.md ||
  fail "DEVELOPMENT.md must name the provider-neutral bootstrap command"

[ -L .claude/skills ] || fail ".claude/skills must be a symlink"
[ "$(readlink .claude/skills)" = "../.agents/skills" ] ||
  fail ".claude/skills must point to ../.agents/skills"

for skill in adr gate close-milestone; do
  [ -s ".agents/skills/$skill/SKILL.md" ] || fail "missing $skill skill"
  [ -s ".agents/skills/$skill/agents/openai.yaml" ] ||
    fail "missing $skill OpenAI metadata"
  [ -s ".claude/skills/$skill/SKILL.md" ] ||
    fail "Claude cannot resolve $skill"
done

bash -n .claude/hooks/*.sh scripts/*.sh

for hook in .claude/hooks/*.sh; do
  [ -x "$hook" ] || fail "$hook is not executable"
done

for repository_check in scripts/check*.sh; do
  [ -x "$repository_check" ] || fail "$repository_check is not executable"
done

# The guards read one field of the tool call through this command. A hook that
# cannot run it fails open, so an unexecutable reader would silently remove every
# guard rather than reporting anything.
[ -x scripts/json-field.sh ] || fail "scripts/json-field.sh is not executable"

if grep -nE 'Bash\(git (add|commit|worktree)' .claude/settings.json >/dev/null; then
  fail "Claude settings auto-allow mutating Git commands"
fi

# These scans use `git grep`, which reads TRACKED files only. A recursive
# working-directory grep also reads untracked content, and a nested checkout is
# ordinary: a Git worktree created under `.claude/worktrees/` puts a whole second
# copy of the repository inside a scanned directory, so the scan matched archive
# material and even its own pattern text and failed on a clean commit. Scanning
# what the repository actually contains removes the class, rather than excluding
# one directory name that the next tool will not use.
if git grep -nE 'gpt-5\.6-(luna|terra|sol)|(^|[^[:alnum:]_])(Luna|Terra|Sol)([^[:alnum:]_]|$)' \
  -- .codex >/dev/null 2>&1; then
  fail "Codex config contains an account-specific model alias"
fi

if git grep -nE 'findings inform, gates decide|Append a closure note|Status.*Proposed/Accepted' \
  -- .agents/skills >/dev/null 2>&1; then
  fail "shared skill contains superseded authority language"
fi

if git grep -nE "CI owns enforcement|full gates are CI's job|Move to CI gates|get their own workflow" \
  -- AGENTS.md .claude .github docs/developer >/dev/null 2>&1; then
  fail "hosted CI is described as owning repository enforcement"
fi

for duplicate in \
  docs/archive/loopex-AGENT-CONTEXT.md \
  docs/archive/loopex-AGENTS.md \
  docs/archive/loopex-README.md \
  docs/archive/loopex-dotcodex-config.toml \
  docs/archive/loopex-vision.md; do
  [ ! -e "$duplicate" ] || fail "redundant archive snapshot remains: $duplicate"
done

# A tool-call document is built with printf rather than by an external
# processor. Only a backslash and a double quote need escaping for the values
# below, and both are handled before the value reaches the format string.
json_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '%s' "$value"
}

guard() {
  printf '{"tool_input":{"command":"%s"}}' "$(json_escape "$1")" |
    .claude/hooks/guard-bash.sh >/dev/null 2>&1
}

file_guard() {
  printf '{"tool_input":{"%s":"%s"}}' "$1" "$(json_escape "$2")" |
    .claude/hooks/guard-filesystem.sh >/dev/null 2>&1
}

deny_commands=(
  'ls ~/.loopex'
  'ls $HOME/.loopex'
  'ls ${HOME}/.loopex'
  'ls "$HOME"/".loopex"'
  "ls ${HOME%/}/.loopex"
)
for command_text in "${deny_commands[@]}"; do
  set +e
  guard "$command_text"
  guard_result=$?
  set -e
  [ "$guard_result" -eq 2 ] ||
    fail "real-home guard returned $guard_result, expected deny 2: $command_text"
done

allow_commands=(
  'git status'
  'ls /tmp/loopex-smoke'
  'LOOPEX_HOME="$(mktemp -d)" mix test'
)
for command_text in "${allow_commands[@]}"; do
  set +e
  guard "$command_text"
  guard_result=$?
  set -e
  [ "$guard_result" -eq 0 ] ||
    fail "real-home guard returned $guard_result, expected allow 0: $command_text"
done

deny_paths=(
  '~/.loopex/journal'
  '$HOME/.loopex/journal'
  '${HOME}/.loopex/journal'
  '${HOME%/}/.loopex/journal'
  "${HOME%/}/.loopex/journal"
)
for field in file_path notebook_path path; do
  for path_text in "${deny_paths[@]}"; do
    set +e
    file_guard "$field" "$path_text"
    guard_result=$?
    set -e
    [ "$guard_result" -eq 2 ] ||
      fail "file guard returned $guard_result, expected deny 2: $field=$path_text"
  done
done

for path_text in AGENTS.md /tmp/loopex-smoke; do
  set +e
  file_guard file_path "$path_text"
  guard_result=$?
  set -e
  [ "$guard_result" -eq 0 ] ||
    fail "file guard returned $guard_result, expected allow 0: $path_text"
done

echo "agent bootstrap check passed"
