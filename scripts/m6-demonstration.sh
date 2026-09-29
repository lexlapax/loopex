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

prepare_workspace() {
  # A prior step's edited file would make the next surface skip or repeat tools.
  export M6_DEMO_WORKSPACE="$M6_DEMO_ROOT/$1"
  mkdir "$M6_DEMO_WORKSPACE"
  printf 'M6_DEMONSTRATION_READ_OK\n' >"$M6_DEMO_WORKSPACE/evidence.txt"
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
    File.write!(Path.join(skill, "SKILL.md"),
      "---\nname: m6-demo\ndescription: Perform the demonstration coding task.\n---\n" <>
      "Make exactly four tool calls, in the order below. Do not explore the " <>
      "workspace or reread a file: the named files are relative to your " <>
      "working directory. Wait for each tool result before the next call. " <>
      "Step 1: use read on evidence.txt and remember its exact contents. " <>
      "Step 2: use write to create generated.txt containing exactly " <>
      "M6_BEFORE_EDIT with no newline. " <>
      "Step 3: use edit on generated.txt to replace exactly M6_BEFORE_EDIT " <>
      "with M6_AFTER_EDIT. " <>
      "Step 4: use bash with argv [\"cat\", \"generated.txt\"] " <>
      "to verify the final file. After the successful bash result, do not " <>
      "call another tool. Answer in plain text with the exact final content " <>
      "of generated.txt.\n")
    options = [policy: M6Demonstration.Policy, cwd: workspace,
               model: System.fetch_env!("M6_DEMO_LOCAL_MODEL"),
               tools: :coding, skills: [skill], max_steps: 8, deadline_ms: 120_000]
    result = LoopexComposition.Ephemeral.run(System.fetch_env!("M6_DEMO_PROMPT"), options)
    # Retain the bounded public answer even when a marker assertion fails. This
    # local-only fixture clears provider-key variables; its parent is private.
    File.write!(Path.join(workspace, "embedded-result.txt"),
      inspect(result, limit: :infinity, printable_limit: :infinity) <> "\n", [:exclusive])
    case result do
      {:ok, %{outcome: :completed, text: text, tools: tools}} ->
        completed = for tool <- tools, tool.outcome == "completed", do: tool.tool_id
        required = ~w(loopex.read loopex.write loopex.edit loopex.bash)
        remaining = Enum.reduce(completed, required, fn id, pending ->
          case pending do
            [^id | rest] -> rest
            _ -> pending
          end
        end)
        answer_ok = is_binary(text) and String.contains?(text, "M6_AFTER_EDIT")
        file_ok = File.read(Path.join(workspace, "generated.txt")) == {:ok, "M6_AFTER_EDIT"}
        unless answer_ok and remaining == [] and file_ok,
          do: raise("embedded demonstration coding task mismatch: " <>
                    inspect(%{answer_ok: answer_ok, completed_tools: completed,
                              ordered_tools_ok: remaining == [], file_ok: file_ok}))
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
        # OTP json decodes JSON null to the atom :null.
        unless value["cleanup"] == :null, do: raise("durable cleanup must be null")
    end
    if coding_required == "yes" do
      completed = for tool <- value["tools"], tool["outcome"] == "completed",
                    do: tool["tool_id"]
      required = ~w(loopex.read loopex.write loopex.edit loopex.bash)
      remaining = Enum.reduce(completed, required, fn id, pending ->
        case pending do
          [^id | rest] -> rest
          _ -> pending
        end
      end)
      answer_ok = String.contains?(value["text"], "M6_AFTER_EDIT")
      file_ok = File.read(Path.join(System.fetch_env!("M6_DEMO_WORKSPACE"),
        "generated.txt")) == {:ok, "M6_AFTER_EDIT"}
      unless answer_ok and remaining == [] and file_ok,
        do: raise("command demonstration coding task mismatch: " <>
                  inspect(%{answer_ok: answer_ok, completed_tools: completed,
                            ordered_tools_ok: remaining == [], file_ok: file_ok}))
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
  # Loopex handle. The helper retains child streams only in memory.
  local_run python3 scripts/m6-delegation.py \
    2>"$M6_DEMO_WORKSPACE/delegated.stderr" || return
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
    --state-root "$M6_DEMO_STATE_ROOT" --deadline-ms 120000 --max-steps 8 \
    --output json >"$M6_DEMO_WORKSPACE/durable.json" \
    2>"$M6_DEMO_WORKSPACE/durable.stderr" || return
  assert_quiet_stderr "$M6_DEMO_WORKSPACE/durable.stderr" || return
  assert_json "$M6_DEMO_WORKSPACE/durable.json" completed durable yes || return
  local session
  session=$(elixir -e 'IO.puts(:json.decode(File.read!(hd(System.argv())))["session_id"])' \
    -- "$M6_DEMO_WORKSPACE/durable.json") || return
  durable_run "$M6_DEMO_COMMAND" resume "$session" --policy allow-all \
    --workspace "$M6_DEMO_WORKSPACE" --state-root "$M6_DEMO_STATE_ROOT" \
    >"$M6_DEMO_WORKSPACE/resumed.txt" || return
  grep -q 'M6_AFTER_EDIT' "$M6_DEMO_WORKSPACE/resumed.txt"
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
M6_DEMO_STATE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/loopex-m6-state.XXXXXX")
export M6_DEMO_STATE_ROOT
export M6_DEMO_SKILL="$M6_DEMO_ROOT/skills/m6-demo"
export M6_DEMO_COMMAND="$PWD/apps/loopex_cli/bin/loopex"
export M6_DEMO_PROMPT='Perform the coding task defined by the supplied m6-demo skill.'
printf 'm6-demonstration: candidate %s on %s; workspace root %s\n' \
  "$candidate" "$(uname -s)" "$M6_DEMO_ROOT"
printf 'm6-demonstration: durable state root %s\n' "$M6_DEMO_STATE_ROOT"
# Keep these exclusively created workspaces for inspection and durable evidence.
# They contain no real user state. Never delete an unproved ephemeral session root.
prepare_workspace embedded
step embedded embedded
prepare_workspace command
step command command
prepare_workspace delegation
step delegation delegation
prepare_workspace durable
step durable durable
