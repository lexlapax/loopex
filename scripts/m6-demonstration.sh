#!/usr/bin/env bash
# The four-step M6 demonstration. Build the command/provider pair from the
# exact clean candidate before attributing any result to it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [ -n "${LOOPEX_HOME+x}" ]; then
  echo 'm6-demonstration: unset LOOPEX_HOME before running' >&2
  exit 2
fi
export M6_DEMO_LOCAL_MODEL="${M6_DEMO_LOCAL_MODEL:-ollama:llama3.2}"
export M6_DEMO_DURABLE_MODEL="${M6_DEMO_DURABLE_MODEL:-anthropic:claude-haiku-4-5}"
case "$M6_DEMO_LOCAL_MODEL" in
  ollama:*) ;;
  *) echo 'm6-demonstration: a local Ollama model is required' >&2; exit 2 ;;
esac

local_run() {
  env -u LOOPEX_PROVIDER_API_KEY -u ANTHROPIC_API_KEY -u OPENAI_API_KEY \
    -u OPENROUTER_API_KEY -u OPEN_ROUTER_API_KEY "$@"
}
durable_run() {
  env -u ANTHROPIC_API_KEY -u OPENAI_API_KEY -u OPENROUTER_API_KEY \
    -u OPEN_ROUTER_API_KEY "$@"
}
step() {
  local name=$1 began=$SECONDS status=0
  shift
  "$@" || status=$?
  if [ "$status" -eq 0 ]; then
    printf 'm6-demonstration: PASS %s elapsed=%ss\n' "$name" "$((SECONDS - began))"
  else
    printf 'm6-demonstration: FAIL %s elapsed=%ss status=%s\n' \
      "$name" "$((SECONDS - began))" "$status" >&2
    return "$status"
  fi
}

embedded() {
  local_run mix run --no-start -e '
    unless Code.ensure_loaded?(LoopexComposition.Ephemeral) and
             function_exported?(LoopexComposition.Ephemeral, :run, 2) do
      IO.puts(:stderr, "m6-demonstration: embedded API is not implemented")
      System.halt(1)
    end
    defmodule M6Demonstration.Policy do
      @behaviour Loopex.Policy
      def decide(_request), do: {:allow, nil}
    end
    workspace = System.fetch_env!("M6_DEMO_WORKSPACE")
    skill = System.fetch_env!("M6_DEMO_SKILL")
    File.mkdir_p!(skill)
    File.write!(Path.join(workspace, "evidence.txt"), "M6_DEMONSTRATION_READ_OK\n")
    File.write!(Path.join(skill, "SKILL.md"),
      "---\nname: m6-demo\ndescription: Perform the demonstration coding task.\n---\n" <>
      "Use each of the four coding tools for this task. Read evidence.txt with read. " <>
      "Write generated.txt with content M6_BEFORE_EDIT using write. " <>
      "Use edit to replace M6_BEFORE_EDIT with M6_AFTER_EDIT. " <>
      "Use bash with argv [\"cat\", \"generated.txt\"] to verify the edit. " <>
      "Answer with the evidence.txt contents, M6_AFTER_EDIT and M6_SKILL_LOADED_OK.\n")
    options = [policy: M6Demonstration.Policy, cwd: workspace,
               model: System.fetch_env!("M6_DEMO_LOCAL_MODEL"),
               tools: :coding, skills: [skill], max_steps: 8, deadline_ms: 120_000]
    case LoopexComposition.Ephemeral.run(System.fetch_env!("M6_DEMO_PROMPT"), options) do
      {:ok, %{outcome: :completed, text: text, tools: tools}} ->
        unless Enum.all?(["M6_DEMONSTRATION_READ_OK", "M6_AFTER_EDIT", "M6_SKILL_LOADED_OK"],
                 &String.contains?(text, &1)) and
               Enum.all?(~w(loopex.read loopex.write loopex.edit loopex.bash), fn id ->
                 Enum.any?(tools, &(&1.tool_id == id and &1.outcome == "completed"))
               end) and File.read!(Path.join(workspace, "generated.txt")) == "M6_AFTER_EDIT",
          do: raise("embedded demonstration did not execute the skill coding task")
      _ -> raise "embedded demonstration did not complete with proved cleanup"
    end
  '
}

assert_json() {
  elixir -e '
    [path, outcome, profile, coding_required] = System.argv()
    raw = File.read!(path)
    unless String.ends_with?(raw, "\n") and length(String.split(raw, "\n")) == 2,
      do: raise("command must emit exactly one JSON line")
    value = :json.decode(raw)
    expected = ~w(schema session_id run_id profile outcome text text_truncated
                  tools tools_truncated shadowed_skills cleanup details)
    unless Enum.sort(Map.keys(value)) == Enum.sort(expected) and
             value["schema"] == "loopex.ask/1" and value["outcome"] == outcome and
             value["profile"] == profile,
      do: raise("command result does not match the closed ask schema")
    case profile do
      "ephemeral" ->
        unless value["cleanup"]["proved"] == true,
          do: raise("ephemeral command did not prove cleanup")
      "durable" ->
        unless value["cleanup"] == nil, do: raise("durable cleanup must be null")
    end
    if coding_required == "yes" do
      unless Enum.all?(["M6_DEMONSTRATION_READ_OK", "M6_AFTER_EDIT", "M6_SKILL_LOADED_OK"],
                 &String.contains?(value["text"], &1)) and
               Enum.all?(~w(loopex.read loopex.write loopex.edit loopex.bash), fn id ->
                 Enum.any?(value["tools"],
                   &(&1["tool_id"] == id and &1["outcome"] == "completed"))
               end) and File.read!(Path.join(System.fetch_env!("M6_DEMO_WORKSPACE"),
                 "generated.txt")) == "M6_AFTER_EDIT",
        do: raise("command demonstration did not execute the skill coding task")
    end
  ' -- "$@"
}

assert_quiet_stderr() {
  [ ! -s "$1" ] || {
    echo "m6-demonstration: proved JSON ask wrote to stderr ($1)" >&2
    return 1
  }
}

command() {
  [ -x "$M6_DEMO_COMMAND" ] || {
    echo 'm6-demonstration: build the loopex escript and companion first' >&2
    return 1
  }
  local_run "$M6_DEMO_COMMAND" -p "$M6_DEMO_PROMPT" --policy allow-all \
    --model "$M6_DEMO_LOCAL_MODEL" --tools coding --cwd "$M6_DEMO_WORKSPACE" \
    --skill-dir "$M6_DEMO_SKILL" \
    --deadline-ms 120000 --max-steps 8 --output json \
    >"$M6_DEMO_WORKSPACE/ask.json" 2>"$M6_DEMO_WORKSPACE/ask.stderr" || return
  assert_quiet_stderr "$M6_DEMO_WORKSPACE/ask.stderr" || return
  assert_json "$M6_DEMO_WORKSPACE/ask.json" completed ephemeral yes || return
  local status=0
  # An absent local model reaches the provider, producing a failed run rather
  # than an option refusal or a shortened deadline.
  local_run "$M6_DEMO_COMMAND" -p 'Say hello.' --policy allow-all \
    --model "ollama:loopex-m6-absent-$$-$RANDOM" --tools none \
    --cwd "$M6_DEMO_WORKSPACE" --output json \
    >"$M6_DEMO_WORKSPACE/failed.json" 2>"$M6_DEMO_WORKSPACE/failed.stderr" || status=$?
  [ "$status" -eq 2 ] || {
    echo 'm6-demonstration: failed run must exit 2' >&2
    return 1
  }
  assert_quiet_stderr "$M6_DEMO_WORKSPACE/failed.stderr" || return
  assert_json "$M6_DEMO_WORKSPACE/failed.json" failed ephemeral no
}

delegation() {
  # A distinct process delegates through the command, never through a shared
  # Loopex handle. It waits for the real command exit and retains its stdout.
  local_run elixir -e '
    {output, status} = System.cmd(System.fetch_env!("M6_DEMO_COMMAND"),
      ["-p", System.fetch_env!("M6_DEMO_PROMPT"), "--policy", "allow-all",
       "--model", System.fetch_env!("M6_DEMO_LOCAL_MODEL"), "--tools", "coding",
       "--cwd", System.fetch_env!("M6_DEMO_WORKSPACE"), "--skill-dir",
       System.fetch_env!("M6_DEMO_SKILL"),
       "--deadline-ms", "120000", "--max-steps", "8", "--output", "json"])
    unless status == 0, do: raise("delegated command did not complete")
    File.write!(Path.join(System.fetch_env!("M6_DEMO_WORKSPACE"), "delegated.json"), output)
  ' 2>"$M6_DEMO_WORKSPACE/delegated.stderr" || return
  assert_quiet_stderr "$M6_DEMO_WORKSPACE/delegated.stderr" || return
  assert_json "$M6_DEMO_WORKSPACE/delegated.json" completed ephemeral yes
}

durable() {
  [ -n "${LOOPEX_PROVIDER_API_KEY:-}" ] || {
    echo 'm6-demonstration: durable step requires LOOPEX_PROVIDER_API_KEY' >&2
    return 2
  }
  durable_run "$M6_DEMO_COMMAND" -p "$M6_DEMO_PROMPT" --policy allow-all \
    --model "$M6_DEMO_DURABLE_MODEL" --tools coding --cwd "$M6_DEMO_WORKSPACE" \
    --skill-dir "$M6_DEMO_SKILL" \
    --state-root "$M6_DEMO_WORKSPACE/state" --deadline-ms 120000 --max-steps 8 \
    --output json >"$M6_DEMO_WORKSPACE/durable.json" \
    2>"$M6_DEMO_WORKSPACE/durable.stderr" || return
  assert_quiet_stderr "$M6_DEMO_WORKSPACE/durable.stderr" || return
  assert_json "$M6_DEMO_WORKSPACE/durable.json" completed durable yes || return
  local session
  session=$(elixir -e 'IO.puts(:json.decode(File.read!(hd(System.argv())))["session_id"])' \
    -- "$M6_DEMO_WORKSPACE/durable.json") || return
  durable_run "$M6_DEMO_COMMAND" resume "$session" --policy allow-all \
    --workspace "$M6_DEMO_WORKSPACE" --state-root "$M6_DEMO_WORKSPACE/state" \
    >"$M6_DEMO_WORKSPACE/resumed.txt" || return
  grep -q 'M6_DEMONSTRATION_READ_OK' "$M6_DEMO_WORKSPACE/resumed.txt"
}

candidate=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
  echo 'm6-demonstration: the source checkout must be clean' >&2
  exit 2
fi
# The pair build checks the source identity before and after compiling, forces
# both archives from that source, and embeds the companion launch digest in the
# command. A pre-existing escript is never accepted as demonstration evidence.
(
  unset MIX_BUILD_PATH MIX_BUILD_ROOT
  local_run env MIX_ENV=prod mix cmd --app loopex_cli mix escript.build
)
if [ "$(git rev-parse HEAD)" != "$candidate" ] ||
   [ -n "$(git status --porcelain=v1 --untracked-files=all)" ]; then
  echo 'm6-demonstration: source changed after the command build' >&2
  exit 1
fi

M6_DEMO_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/loopex-m6-demo.XXXXXX")
export M6_DEMO_WORKSPACE="$M6_DEMO_ROOT/workspace"
export M6_DEMO_SKILL="$M6_DEMO_ROOT/skills/m6-demo"
mkdir "$M6_DEMO_WORKSPACE"
export M6_DEMO_COMMAND="$PWD/apps/loopex_cli/bin/loopex"
export M6_DEMO_PROMPT='Perform the coding task defined by the supplied m6-demo skill.'
printf 'm6-demonstration: candidate %s on %s; workspace %s\n' \
  "$candidate" "$(uname -s)" "$M6_DEMO_WORKSPACE"
# Keep this exclusively created workspace for inspection and durable evidence.
# It contains no real user state. Never delete an unproved ephemeral session root.
step embedded embedded
step command command
step delegation delegation
step durable durable
