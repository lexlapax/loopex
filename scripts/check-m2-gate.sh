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
# The opening condition runs first, before the credential frame is read and
# before the product state root exists. It has two parts, in this order.
#
# The primary part is a behavioural probe. It composes a runtime from shipped
# modules through the public Loopex facade inside an isolated evidence root
# outside the checkout, submits one prompt, and observes what the loop actually
# did: how many turns it staged, what each staged request carried, how many
# messages reached the probe process — a coarse mailbox floor, not proof a
# delta reached the progress plane — which tool set the runtime accepted, and
# which tool identities it staged.
# The declared red is emitted from those observations rather than from the
# presence or absence of a file, because a file check is satisfied by writing a
# file.
#
# The additional part is the locked selector and case-identity condition. It
# catches a renamed, deleted, or emptied executable definition once the
# behaviour exists. It is not the primary condition and cannot substitute for
# the probe: a run in which the probe could not execute is evidence unavailable
# and can never be green.
#
# The probe writes only inside its own evidence root, compiles into a build root
# inside it rather than the checkout's, and removes it on the way out. A
# reviewer under a no-file-writes profile, or with no usable temporary
# directory, cannot allocate that root; the probe then reports itself
# unavailable, the additional condition reaches the same declared red, and green
# stays impossible.
#
# The probe's model adapter is a harness, not evidence. Nothing it observes is a
# real-path claim and no outcome is satisfied by it.
#
# The writable lane owns the product state root and the temporary directory, and
# fingerprints the operator's real ~/.loopex before and after.
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
# Primary opening condition: the behavioural probe.
#
# The probe is one Elixir program written into an isolated evidence root. It
# composes a runtime from shipped modules only — the durable local store, the
# trusted-local executor, and its own observing model adapter — starts it
# through Loopex.start_link/1, creates a session, submits one prompt through the
# public facade, waits for the session to settle, and reports what the loop did.
#
# It emits one observation line carrying six fields: five behavioural
# observations and one disclosed shape check.
#
#   turns             how many model requests the loop staged
#   history           whether the last staged request carried the committed
#                     conversation, or one synthesized user message
#   progress_messages how many items reached the probe process during the run;
#                     a mailbox count, not a filtered progress-plane count, and
#                     therefore only a floor
#   tool_set          whether the runtime accepted a named tool set, or only one
#                     hand-written demonstration definition
#   staged            the sorted tool identities the first staged request
#                     actually carried
#
# The sixth field, ports, is the disclosed shape check that accompanies those
# observations rather than one of them: whether the model and executor ports
# expose the arity that carries a progress function at all.
#
# The probe asks for the M2 shape first and falls back to the M1 shape, so the
# same program observes either tree. M2 is present only when all seven
# conjuncts hold: turns is at least three, history is committed_conversation,
# progress_messages is greater than zero, ports is progress_capable, tool_set
# is named_set, staged is non-empty, and no element of staged is a
# demonstration tool under either its dot-segmented identity or its model-visible
# name — any staged demonstration tool is refused, not only a set
# composed wholly of them.
# ---------------------------------------------------------------------------

probe_verdict="unavailable"
probe_report=""
probe_unavailable_reason=""

write_probe_program() {
  cat >"$1" <<'LOOPEX_M2_PROBE_PROGRAM'
defmodule Loopex.M2Probe.Model do
  @moduledoc false
  @behaviour Loopex.Model

  # Both arities are implemented so the same harness observes a loop that calls
  # the M1 non-streaming callback and a loop that supplies a progress function.
  def complete(request, options), do: answer(request, options, nil)

  def complete(request, options, progress) when is_function(progress, 1),
    do: answer(request, options, progress)

  defp answer(request, options, progress) do
    send(Keyword.fetch!(options, :observer), {:probe_model_request, request})
    turn = Agent.get_and_update(Loopex.M2Probe.Turns, &{&1 + 1, &1 + 1})

    if is_function(progress, 1) do
      progress.(%{kind: :text_delta, sequence: 0, content: "probe delta #{turn}"})
      Process.sleep(20)
    end

    tool_calls =
      case {request.tools, turn} do
        {[%{"name" => name} | _], t} when t <= 2 ->
          [
            %{
              id: "probe-tool-call-#{t}",
              name: name,
              arguments: %{"relative_path" => "probe.txt", "content" => "loopex-effect"}
            }
          ]

        _other ->
          []
      end

    # Technical depth: M2 renames the model request's digest field to
    # staged_request_digest so it stops sharing an identifier with the
    # executor's attempt-bound canonical_request_digest. The probe asks for the
    # M2 name first and falls back to the M1 name, exactly as it does for the
    # streaming callback arity, because it must keep observing the M1 tree it
    # runs against today. It echoes back only the field names the request
    # actually carried, so it adds no key to either shape.
    digest_fields = Map.take(request, [:staged_request_digest, :canonical_request_digest])

    {:ok,
     Map.merge(
       %{
         text: "probe turn #{turn}",
         identity: %{provider: "probe", model: request.model, endpoint: "in-process"},
         usage: %{input_tokens: nil, output_tokens: nil},
         tool_calls: tool_calls,
         canonical_request_bytes: request.canonical_request_bytes
       },
       digest_fields
     )}
  end
end

defmodule Loopex.M2Probe do
  @moduledoc false

  def run(root) do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    {:ok, _turns} = Agent.start_link(fn -> 0 end, name: Loopex.M2Probe.Turns)

    {:ok, store_pid} = Loopex.Store.Local.start_link(path: Path.join(root, "store.log"))
    {:ok, store} = Loopex.Store.new(Loopex.Store.Local, store_pid)

    {:ok, lease} =
      Loopex.Executor.Local.WorkspaceLease.start_link(
        id: "probe-lease",
        path: workspace,
        fencing_token: 7
      )

    {:ok, executor} =
      Loopex.Executor.Local.start_link(
        identity: "executor-local",
        epoch: 3,
        fencing_token: 7,
        workspace_leases: %{"probe-lease" => lease},
        ledger_root: Path.join(root, "ledger")
      )

    base = [
      runtime_id: "probe-runtime",
      store: store,
      model: %{
        module: Loopex.M2Probe.Model,
        model: "probe:opening",
        options: [observer: self()]
      },
      executor: %{
        module: Loopex.Executor.Local,
        reference: executor,
        identity: "executor-local",
        epoch: 3,
        fencing_token: 7,
        workspace_ref: "probe-workspace",
        workspace_lease: "probe-lease"
      },
      grant_decision: {:host_policy, :allow},
      progress_to: self()
    ]

    {tool_set, runtime} = start_runtime(base)

    {:ok, session_id} =
      Loopex.create_session(runtime, %{"probe" => "opening"}, command_id: "probe-create")

    {:ok, attachment} = Loopex.attach(runtime, session_id, after_event_sequence: 0)

    {:accepted, _accepted} =
      Loopex.command(attachment, %{
        type: :prompt,
        command_id: "probe-prompt",
        content: "probe the shipped loop"
      })

    settle(runtime, session_id, 600)
    {requests, progress_messages} = drain([], 0)
    Loopex.stop(runtime)

    %{
      turns: length(requests),
      history: history_shape(List.last(requests)),
      progress_messages: progress_messages,
      ports: port_shape(),
      tool_set: tool_set,
      staged: staged_tools(List.first(requests))
    }
  end

  # The accepted M2 runtime option is a named active tool set. A runtime that
  # refuses it and accepts only one hand-written definition is the M1 shape, and
  # that refusal is itself one of the observations.
  defp start_runtime(base) do
    case Loopex.start_link(Keyword.put(base, :tools, coding_tools())) do
      {:ok, runtime} ->
        {"named_set", runtime}

      {:error, _reason} ->
        {:ok, runtime} = Loopex.start_link(Keyword.put(base, :tool, demonstration_tool()))
        {"single_hand_written", runtime}
    end
  end

  defp coding_tools do
    for {id, name} <- [
          {"loopex.read", "read"},
          {"loopex.write", "write"},
          {"loopex.edit", "edit"},
          {"loopex.bash", "bash"}
        ] do
      %{
        "name" => name,
        "description" => "probe #{name}",
        "tool_id" => id,
        "tool_version" => "1.0.0",
        "effect_class" => "workspace_write",
        "input_schema" => %{
          "type" => "object",
          "properties" => %{},
          "additionalProperties" => true
        }
      }
    end
  end

  defp demonstration_tool do
    %{
      "name" => "loopex_demo_write",
      "description" => "Write the fixed demonstration bytes beneath the leased workspace.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "relative_path" => %{"type" => "string", "const" => "probe.txt"},
          "content" => %{"type" => "string", "const" => "loopex-effect"}
        },
        "required" => ["relative_path", "content"],
        "additionalProperties" => false
      },
      "tool_id" => "loopex.demo.write",
      "tool_version" => "1.0.0",
      "effect_class" => "workspace_write"
    }
  end

  defp settle(_runtime, _session_id, 0), do: throw(:probe_session_never_settled)

  defp settle(runtime, session_id, attempts) do
    case Loopex.session_status(runtime, session_id) do
      {:ok, %{active_run_id: nil, pending_work_ids: []}} ->
        :ok

      _other ->
        Process.sleep(10)
        settle(runtime, session_id, attempts - 1)
    end
  end

  defp drain(requests, progress_messages) do
    receive do
      {:probe_model_request, request} -> drain([request | requests], progress_messages)
      _other -> drain(requests, progress_messages + 1)
    after
      0 -> {Enum.reverse(requests), progress_messages}
    end
  end

  defp history_shape(nil), do: "none"

  defp history_shape(request) do
    roles = request.messages |> Enum.map(&Map.get(&1, "role")) |> MapSet.new()

    if MapSet.member?(roles, "assistant") and MapSet.member?(roles, "tool"),
      do: "committed_conversation",
      else: "single_user_message"
  end

  defp port_shape do
    model = Loopex.Model.behaviour_info(:callbacks) |> Keyword.get_values(:complete)
    executor = Loopex.Executor.behaviour_info(:callbacks) |> Keyword.get_values(:execute)

    if 3 in model and 5 in executor, do: "progress_capable", else: "no_progress_channel"
  end

  defp staged_tools(nil), do: []

  defp staged_tools(request) do
    request.tools
    |> Enum.map(&Map.get(&1, "tool_id", Map.get(&1, "name", "unnamed")))
    |> Enum.sort()
  end
end

root = System.fetch_env!("LOOPEX_M2_PROBE_ROOT")

case Loopex.M2Probe.run(root) do
  %{} = observed ->
    IO.puts(
      "LOOPEX_M2_PROBE turns=#{observed.turns} history=#{observed.history} " <>
        "progress_messages=#{observed.progress_messages} ports=#{observed.ports} " <>
        "tool_set=#{observed.tool_set} staged=#{Enum.join(observed.staged, "+")}"
    )
end
LOOPEX_M2_PROBE_PROGRAM
}

run_opening_probe() {
  local probe_root="" program output field
  local turns history progress_messages ports tool_set staged

  probe_root="$(mktemp -d "${TMPDIR:-/tmp}/loopex-m2-probe.XXXXXX" 2>/dev/null)" || probe_root=""
  if [ -z "$probe_root" ] || [ ! -d "$probe_root" ] || [ ! -w "$probe_root" ]; then
    probe_unavailable_reason="no writable evidence root could be allocated under ${TMPDIR:-/tmp}"
    return 0
  fi

  probe_root="$(cd "$probe_root" && pwd -P)" || probe_root=""
  case "${probe_root:-/}" in
    "$repository_root" | "$repository_root"/*)
      rm -rf "$probe_root"
      probe_unavailable_reason="the evidence root resolved inside the checkout, which is not isolation"
      return 0
      ;;
  esac
  if [ -z "$probe_root" ]; then
    probe_unavailable_reason="the evidence root could not be physically resolved"
    return 0
  fi

  program="$probe_root/probe.exs"
  if ! write_probe_program "$program" 2>/dev/null; then
    rm -rf "$probe_root"
    probe_unavailable_reason="the probe program could not be written to its evidence root"
    return 0
  fi

  # Compilation goes to a build root inside the evidence root, never the
  # checkout's, so a stale or absent _build cannot change what the probe sees.
  # MIX_BUILD_PATH is cleared rather than merely overridden: it takes precedence
  # over MIX_BUILD_ROOT, so an ambient value would silently defeat the isolation
  # this comment claims. Clearing it is what makes the claim true.
  if ! output="$(
    env -u MIX_BUILD_PATH MIX_ENV=dev MIX_BUILD_ROOT="$probe_root/build" \
      TMPDIR="$probe_root" mix compile 2>&1
  )"; then
    printf '%s\n' "$output" >&2
    rm -rf "$probe_root"
    probe_unavailable_reason="the probe could not compile the tree into its own build root"
    return 0
  fi

  local code_paths=()
  for field in "$probe_root"/build/dev/lib/*/ebin; do
    [ -d "$field" ] && code_paths+=(-pa "$field")
  done
  if [ "${#code_paths[@]}" -eq 0 ]; then
    rm -rf "$probe_root"
    probe_unavailable_reason="the probe build root contains no compiled application"
    return 0
  fi

  output="$(
    env -u MIX_BUILD_PATH LOOPEX_M2_PROBE_ROOT="$probe_root/state" \
      LOOPEX_HOME="$probe_root/state/.loopex" \
      TMPDIR="$probe_root" ERL_CRASH_DUMP=/dev/null ERL_CRASH_DUMP_SECONDS=0 \
      elixir "${code_paths[@]}" "$program" 2>&1
  )"
  if [ $? -ne 0 ]; then
    printf '%s\n' "$output" >&2
    rm -rf "$probe_root"
    probe_unavailable_reason="the probe could not drive the shipped loop through the public facade"
    return 0
  fi

  rm -rf "$probe_root"

  probe_report="$(printf '%s\n' "$output" | grep -E '^LOOPEX_M2_PROBE ' | tail -1)"
  if [ -z "$probe_report" ]; then
    probe_unavailable_reason="the probe produced no observation line"
    return 0
  fi

  turns="$(probe_field "$probe_report" turns)"
  history="$(probe_field "$probe_report" history)"
  progress_messages="$(probe_field "$probe_report" progress_messages)"
  ports="$(probe_field "$probe_report" ports)"
  tool_set="$(probe_field "$probe_report" tool_set)"
  staged="$(probe_field "$probe_report" staged)"

  if [[ ! "$turns" =~ ^[0-9]+$ ]] || [[ ! "$progress_messages" =~ ^[0-9]+$ ]]; then
    probe_unavailable_reason="the probe observation line is malformed"
    probe_report=""
    return 0
  fi

  if [ "$turns" -ge 3 ] \
    && [ "$history" = "committed_conversation" ] \
    && [ "$progress_messages" -gt 0 ] \
    && [ "$ports" = "progress_capable" ] \
    && [ "$tool_set" = "named_set" ] \
    && [ -n "$staged" ] \
    && ! printf '%s' "$staged" | grep -qE '(^|\+)loopex[._]demo[._][^+]*(\+|$)'; then
    probe_verdict="m2_present"
  else
    probe_verdict="m1_shape"
  fi
}

probe_field() {
  local line="$1" key="$2" rest
  rest="${line#* $key=}"
  [ "$rest" != "$line" ] || return 1
  printf '%s' "${rest%% *}"
}

run_opening_probe

if [ "$probe_verdict" = "m1_shape" ]; then
  fail "$DECLARED_RED (observed through the public facade: $probe_report)"
fi

if [ -n "$probe_unavailable_reason" ]; then
  note "M2 opening probe unavailable: $probe_unavailable_reason; the declared red is reached from the locked definitions below and this run can never be green"
fi

# ---------------------------------------------------------------------------
# Additional opening condition: locked selectors and case identities.
#
# This runs after the probe and never in place of it. Each check names an
# operator feature; the selector is that feature's executable definition, so a
# missing selector or a missing locked case means the feature does not exist
# yet, and the message says so in those terms.
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
  "a staged request carries complete tool definition bytes and its generation triple and is reconstructible from the journal alone" \
  "every turn after the first is canonical history replay and the reserved continuation field stays empty" \
  "the maximum turn bound ends the run bound reached before another provider call" \
  "the cumulative token budget ends the run bound reached before another provider call" \
  "the wall clock deadline ends the run bound reached before another provider call" \
  "a retried tool operation keeps its operation identity and reconciles against its own attempt bound request digest" \
  "a tool call whose run deadline already passed is not dispatched and still commits a terminal fact" \
  "the committed absolute deadline is propagated into the model call rather than an independent per call timeout" \
  "a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only" \
  "a cancelled turn is charged its request bytes and its committed max tokens in full and marked estimated" \
  "every sampling bound is a declared committed value with no implicit default"

require_feature \
  "the operator never sees an answer until the run ends; nothing streams and no delta algebra exists" \
  apps/loopex_llm_reqllm/test/streaming_conformance_test.exs \
  "every model adapter satisfies one streaming conformance suite" \
  "each canonical delta kind is bounded plain data carrying no provider or host term" \
  "a text delta is observable while its operation is still incomplete rather than after the reply returns" \
  "replaying an adapter's emitted deltas reproduces the reply it returned byte identically" \
  "the model and executor progress domains carry separate sequences each closed by its own content free item" \
  "a gapless sequence within one stream domain and its closing total make lost progress detectable" \
  "a provider retry opens a second stream domain under one turn and neither domain reports the other as loss" \
  "a retried executor operation attempt opens its own stream domain closed by its own closure item and count" \
  "the committed assistant message is built from the reply and never assembled from deltas" \
  "a cancelled stream commits no assistant message and a late reply never becomes canonical" \
  "an adapter that emits no deltas is conformant and declares that it does not stream"

require_feature \
  "the operator cannot redirect a running task or queue the next one; there is no prompt steer follow-up algebra" \
  apps/loopex/test/input_algebra_test.exs \
  "a prompt starts a run only while the session is settled and is otherwise refused" \
  "the runtime never infers whether new input is steering or follow up and a steer must name its active run" \
  "a steer joins the active run after the current tool batch and before the next model request" \
  "a steer is recorded applied only when a committed request carried it" \
  "a follow up starts a new run only after the active run and its steering settle" \
  "a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted" \
  "at most one unapplied steer and one queued follow up exist and both survive owner succession" \
  "an abort resolves any unapplied steer and queued follow up as cancelled"

# The registry is the internal mechanism the loop and the tools both resolve
# through. It is not an operator feature and is not an outcome; it is locked
# supporting coverage under the outcomes it serves.
require_feature \
  "the loop and the tools have no runtime-scoped registry to resolve a named versioned tool through" \
  apps/loopex/test/tool_registry_test.exs \
  "a runtime-scoped registry resolves a tool id and version and refuses an unknown id" \
  "two runtimes carry independent tool registries with no global registration" \
  "a conflicting tool id and version registration is refused with an explicit reason" \
  "a session binds one active model visible name to one generation and refuses a name conflict at start" \
  "a model request records the exact tool definition generation it used"

require_feature \
  "the operator has no coding tools; read, write, edit, and bash do not exist" \
  apps/loopex_executor_local/test/coding_tools_test.exs \
  "read returns bounded chunked content and reports truncation" \
  "write creates or replaces a file only beneath the workspace root" \
  "edit applies an exact match change and names what differed on a mismatch" \
  "bash runs an argv command and an explicit raw shell command with distinct semantics" \
  "every tool refuses a path that escapes the workspace root through traversal or a symlink" \
  "executor progress carries the full identity epoch digest and fence tuple and a refused event is dropped and counted" \
  "a tool child process tree is owned and terminated with its job" \
  "a long running job carries the run deadline is terminated at expiry and its cleanup is confirmed before the run commits its bound"

require_feature \
  "oversized tool output has nowhere to go; there is no artifact store and a long result is simply lost" \
  apps/loopex_store_local/test/artifact_store_conformance_test.exs \
  "every artifact store implementation satisfies one conformance suite" \
  "tool output beyond its declared bound spills to an artifact instead of truncating silently" \
  "the durable artifact event carries digest media type size role and an opaque reference" \
  "the model facing result stays under its bound and names what was truncated" \
  "the operator retrieves a spilled artifact by its opaque reference through the public facade" \
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
  "every executor backed tool requires a policy decision including a read only tool" \
  "a permissive policy applies only when it is named and omitting the policy option refuses runtime start"

require_feature \
  "no shipped permissive policy exists for a reference host to name" \
  apps/loopex_reference_client/test/allow_all_policy_test.exs \
  "the shipped allow all policy allows every decision it is asked" \
  "the shipped allow all policy emits exactly one permissive authority notice"

require_feature \
  "the operator cannot stage project resources into the model's context; there is no discovery manifest or trust decision" \
  apps/loopex/test/project_resource_trust_test.exs \
  "discovery resolves a canonical ordered resource set under declared path size and total limits" \
  "the operator is shown every resolved path its provenance and the manifest digest" \
  "an explicit trust decision binds workspace revision manifest and digests" \
  "a changed workspace revision manifest or content invalidates the decision" \
  "a headless run without a matching positive decision fails closed and stages no project block" \
  "an ordinary workspace read stays a policy governed tool effect and is never context staging" \
  "an admitted project block changes no tool set policy decision bound or grant"

require_feature \
  "the operator cannot stop a running task; cancellation is recorded but nothing is cancelled" \
  apps/loopex/test/cancellation_test.exs \
  "an interrupt reaches the run through the public facade and through no private path" \
  "an abort admitted during a model call cancels the run and schedules no new work" \
  "an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled" \
  "a run finishes cancelled only when every owned operation is validated terminal and every owned process tree is confirmed cleaned" \
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
  "the operator steers a running task and queues a follow-up from the same terminal" \
  "prompt steer follow up and abort have distinct explicit affordances and input naming neither is refused" \
  "tool progress from a running executor job reaches the operator's terminal before the tool finishes" \
  "loopex sessions lists the operator's sessions and loopex resume continues one" \
  "an interrupt signal delivered to a running loopex process cancels the task through the public facade" \
  "an interrupt whose cleanup cannot be confirmed reports outcome unknown with its reconciliation reference" \
  "loopex cancel reconciles a session left behind by a dead process and is refused against a live owner" \
  "the policy option selects the governing host policy and a refusal is reported in the transcript" \
  "the command ships its own permissive policy that is named explicitly, prints one notice, and is never an implicit fallback" \
  "loopex artifact retrieves a spilled artifact by its opaque reference" \
  "project resource trust is decided at the terminal and a non interactive run without a decision fails closed" \
  "the command surface drives only the public facade and owns no loop store cursor or authority" \
  "the base system prompt and active tool definitions measure under one thousand tokens" \
  "argument parsing and terminal output use only the standard library"

require_feature \
  "an embedder cannot depend on a shipped composition; the only composition is test support" \
  apps/loopex_composition/test/kernel_composition_test.exs \
  "one page of shipped code starts the application tree a runtime a session a prompt and its events" \
  "an independent embedder fixture composes the kernel without depending on the command application" \
  "the shipped composition requires a host supplied policy and ships no permissive default" \
  "the composition resolves its state root explicitly and never through application environment"

# The attended real-provider demonstration is mandatory closure evidence rather
# than an outcome. It is locked here exactly as an outcome selector is.
require_feature \
  "no real provider has driven a genuine multi-tool coding task through the shipped command" \
  apps/loopex_cli/test/coding_task_test.exs \
  "a multi tool task reads edits and verifies a file in a disposable repository" \
  "the task transcript shows every tool call decision and result" \
  "a denied tool call inside a multi tool task is reported and the task continues truthfully" \
  "the demonstration workspace is disposable and never the operator's own repository" \
  "a real provider evidence claim fails when the reply carries no provider supplied response identifier" \
  "one real provider task streams edits a real repository across several turns and the operator sees the committed result" \
  "one real provider call surfaces the provider's own response identifier and reported usage that the deterministic adapter cannot produce"

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
  "the runner's own build and root isolation has no locked definition, so an ambient environment variable can defeat it unnoticed" \
  apps/loopex/test/gate_isolation_test.exs \
  "an ambient MIX_BUILD_PATH cannot redirect gate owned compilation out of the owned build root" \
  "the gate refuses an owned root that resolves inside the checkout or the operator's product state"

require_feature \
  "the dependency corpus does not yet describe the M2 eight-application inventory or the composition role" \
  apps/loopex/test/deps_budget_test.exs \
  "the repository satisfies the dependency budget and direction" \
  "the M2 planned inventory admits exactly eight applications with their declared roles" \
  "a composition depends on the edge applications it composes and on no client or external package" \
  "a client depends on at most one composition and never on another client"

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
  docs/evidence/M2-real-call-attestations.md
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

# The locked definitions can all be present while the behaviour is not, so the
# probe is required rather than advisory. A run that could not observe the loop
# has unavailable evidence, which is never a pass.
[ "$probe_verdict" = "m2_present" ] \
  || fail "the opening behavioural probe did not observe the working loop through the public facade (${probe_unavailable_reason:-no observation}); evidence is unavailable and never PASS"

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

fingerprint_tree() {
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
user_state_before="$(fingerprint_tree "$user_state_root")"

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
  "$repository_root" | "$repository_root"/*)
    fail "the owned task root resolves inside the checkout, which is not isolation"
    ;;
esac

mkdir -p "$task_root/home" "$task_root/tmp" "$task_root/build" "$task_root/workspace" \
  || fail "the owned task root could not be populated"

export LOOPEX_HOME="$task_root/home/.loopex"
export TMPDIR="$task_root/tmp"
export MIX_BUILD_ROOT="$task_root/build"
# MIX_BUILD_PATH takes precedence over MIX_BUILD_ROOT. Exporting the root while
# leaving an ambient path in place would let one inherited environment variable
# redirect every locked command back into the checkout, so it is cleared here
# and its effect is verified below rather than assumed.
unset MIX_BUILD_PATH
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
export ERL_CRASH_DUMP=/dev/null
export ERL_CRASH_DUMP_SECONDS=0
export GIT_OPTIONAL_LOCKS=0

test_build_path="$task_root/build/test"

# The checkout's own _build must be inert for the whole run. This is the
# executable form of the isolation claim: clearing MIX_BUILD_PATH states the
# intent, and this fingerprint pair proves no locked command wrote into the
# checkout's build tree anyway.
checkout_build_root="$repository_root/_build"
checkout_build_before="$(fingerprint_tree "$checkout_build_root")"

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

run_locked "the dependency budget, the M2 eight-application inventory, or the role direction is violated" \
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

# M1 pinned provider, model, endpoint, and adapter build across its two
# real-provider roles so one green real path could not stand in for another run
# against a different provider or build. M2 has three real roles and keeps the
# same agreement: the first real role observed sets the reference identity and
# every later one must match it.
real_reference_identity=""
real_reference_role=""

marker_field() {
  local line="$1" key="$2" rest
  rest="${line#* $key=}"
  [ "$rest" != "$line" ] || return 1
  printf '%s' "${rest%% *}"
}

require_real_identity_agreement() {
  local marker="$1" label="$2" identity="" field value
  for field in provider model endpoint adapter_build; do
    value="$(marker_field "$marker" "$field")" \
      || fail "$label sealed no $field into its authoritative result"
    [ -n "$value" ] || fail "$label sealed an empty $field"
    identity="$identity $field=$value"
  done

  if [ -z "$real_reference_identity" ]; then
    real_reference_identity="$identity"
    real_reference_role="$label"
  else
    [ "$identity" = "$real_reference_identity" ] \
      || fail "$label reported a different provider, model, endpoint, or adapter build than $real_reference_role"
  fi
}

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

  case "$role_name" in
    real-model | real-combined)
      require_real_identity_agreement "$marker" "the $outcome $role_name role"
      ;;
  esac

  if [ "$outcome" = demonstration ] && [ "$role_name" = real-combined ]; then
    demonstration_record="$marker"
  fi
}

run_selector 1 apps/loopex/test/agent_loop_test.exs default 15 zero \
  "passed=a prompt runs until the model stops requesting tools rather than after a fixed number of turns" \
  "passed=every model request carries the committed conversation history including the original prompt" \
  "passed=an assistant tool call and its real tool result are committed and replayed to the model" \
  "passed=each turn dispatches exactly the canonical request bytes and digest committed before it" \
  "passed=a staged request carries complete tool definition bytes and its generation triple and is reconstructible from the journal alone" \
  "passed=every turn after the first is canonical history replay and the reserved continuation field stays empty" \
  "passed=the maximum turn bound ends the run bound reached before another provider call" \
  "passed=the cumulative token budget ends the run bound reached before another provider call" \
  "passed=the wall clock deadline ends the run bound reached before another provider call" \
  "passed=a retried tool operation keeps its operation identity and reconciles against its own attempt bound request digest" \
  "passed=a tool call whose run deadline already passed is not dispatched and still commits a terminal fact" \
  "passed=the committed absolute deadline is propagated into the model call rather than an independent per call timeout" \
  "passed=a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only" \
  "passed=a cancelled turn is charged its request bytes and its committed max tokens in full and marked estimated" \
  "passed=every sampling bound is a declared committed value with no implicit default"

run_selector 2 apps/loopex_llm_reqllm/test/streaming_conformance_test.exs default 11 zero \
  "passed=every model adapter satisfies one streaming conformance suite" \
  "passed=each canonical delta kind is bounded plain data carrying no provider or host term" \
  "passed=a text delta is observable while its operation is still incomplete rather than after the reply returns" \
  "passed=replaying an adapter's emitted deltas reproduces the reply it returned byte identically" \
  "passed=the model and executor progress domains carry separate sequences each closed by its own content free item" \
  "passed=a gapless sequence within one stream domain and its closing total make lost progress detectable" \
  "passed=a provider retry opens a second stream domain under one turn and neither domain reports the other as loss" \
  "passed=a retried executor operation attempt opens its own stream domain closed by its own closure item and count" \
  "passed=the committed assistant message is built from the reply and never assembled from deltas" \
  "passed=a cancelled stream commits no assistant message and a late reply never becomes canonical" \
  "passed=an adapter that emits no deltas is conformant and declares that it does not stream"

run_selector 3 apps/loopex/test/input_algebra_test.exs default 8 zero \
  "passed=a prompt starts a run only while the session is settled and is otherwise refused" \
  "passed=the runtime never infers whether new input is steering or follow up and a steer must name its active run" \
  "passed=a steer joins the active run after the current tool batch and before the next model request" \
  "passed=a steer is recorded applied only when a committed request carried it" \
  "passed=a follow up starts a new run only after the active run and its steering settle" \
  "passed=a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted" \
  "passed=at most one unapplied steer and one queued follow up exist and both survive owner succession" \
  "passed=an abort resolves any unapplied steer and queued follow up as cancelled"

run_selector 4 apps/loopex_executor_local/test/coding_tools_test.exs default 8 zero \
  "passed=read returns bounded chunked content and reports truncation" \
  "passed=write creates or replaces a file only beneath the workspace root" \
  "passed=edit applies an exact match change and names what differed on a mismatch" \
  "passed=bash runs an argv command and an explicit raw shell command with distinct semantics" \
  "passed=every tool refuses a path that escapes the workspace root through traversal or a symlink" \
  "passed=executor progress carries the full identity epoch digest and fence tuple and a refused event is dropped and counted" \
  "passed=a tool child process tree is owned and terminated with its job" \
  "passed=a long running job carries the run deadline is terminated at expiry and its cleanup is confirmed before the run commits its bound"

run_selector 5 apps/loopex_store_local/test/artifact_store_conformance_test.exs default 6 zero \
  "passed=every artifact store implementation satisfies one conformance suite" \
  "passed=tool output beyond its declared bound spills to an artifact instead of truncating silently" \
  "passed=the durable artifact event carries digest media type size role and an opaque reference" \
  "passed=the model facing result stays under its bound and names what was truncated" \
  "passed=the operator retrieves a spilled artifact by its opaque reference through the public facade" \
  "passed=an artifact round trips byte exactly and a missing artifact reports unavailable"

run_selector 6a apps/loopex_executor_local/test/host_policy_test.exs default 8 zero \
  "passed=every host policy implementation satisfies one policy port conformance suite" \
  "passed=a host policy deny decision issues no grant and starts no operating system process" \
  "passed=a denied tool call commits a truthful denied outcome the operator can read" \
  "passed=the run continues or terminates truthfully after a denial and never retries the refused call" \
  "passed=a policy that raises times out or returns a malformed value fails closed into denial" \
  "passed=defer is declared and refused in this milestone rather than treated as allow or deny" \
  "passed=every executor backed tool requires a policy decision including a read only tool" \
  "passed=a permissive policy applies only when it is named and omitting the policy option refuses runtime start"

run_selector 6b apps/loopex_reference_client/test/allow_all_policy_test.exs default 2 zero \
  "passed=the shipped allow all policy allows every decision it is asked" \
  "passed=the shipped allow all policy emits exactly one permissive authority notice"

run_selector 7 apps/loopex/test/project_resource_trust_test.exs default 7 zero \
  "passed=discovery resolves a canonical ordered resource set under declared path size and total limits" \
  "passed=the operator is shown every resolved path its provenance and the manifest digest" \
  "passed=an explicit trust decision binds workspace revision manifest and digests" \
  "passed=a changed workspace revision manifest or content invalidates the decision" \
  "passed=a headless run without a matching positive decision fails closed and stages no project block" \
  "passed=an ordinary workspace read stays a policy governed tool effect and is never context staging" \
  "passed=an admitted project block changes no tool set policy decision bound or grant"

run_selector 8 apps/loopex/test/cancellation_test.exs default 8 zero \
  "passed=an interrupt reaches the run through the public facade and through no private path" \
  "passed=an abort admitted during a model call cancels the run and schedules no new work" \
  "passed=an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled" \
  "passed=a run finishes cancelled only when every owned operation is validated terminal and every owned process tree is confirmed cleaned" \
  "passed=a validated terminal tool fact committed before the abort is preserved and not overwritten" \
  "passed=an effect without sufficient evidence ends outcome unknown and is never blindly retried" \
  "passed=a second interrupt reports what is still being cleaned up rather than abandoning the session" \
  "passed=the operator observes what was cancelled and what actually happened"

run_selector 9 apps/loopex/test/session_directory_test.exs default 5 zero \
  "passed=a fresh operating system process lists the sessions in a resolved state root" \
  "passed=the state root resolves from LOOPEX_HOME and never from application environment" \
  "passed=a session resumes under the durable runtime placement identity that created it" \
  "passed=resuming a session through a different runtime identity is refused with an explicit reason" \
  "passed=a repeated resume command identity returns its historical result while a fresh identity acquires ownership"

run_selector 10 apps/loopex_cli/test/cli_test.exs default 15 zero \
  "passed=loopex run submits a prompt and streams the answer with its tool calls and results" \
  "passed=the operator steers a running task and queues a follow-up from the same terminal" \
  "passed=prompt steer follow up and abort have distinct explicit affordances and input naming neither is refused" \
  "passed=tool progress from a running executor job reaches the operator's terminal before the tool finishes" \
  "passed=loopex sessions lists the operator's sessions and loopex resume continues one" \
  "passed=an interrupt signal delivered to a running loopex process cancels the task through the public facade" \
  "passed=an interrupt whose cleanup cannot be confirmed reports outcome unknown with its reconciliation reference" \
  "passed=loopex cancel reconciles a session left behind by a dead process and is refused against a live owner" \
  "passed=the policy option selects the governing host policy and a refusal is reported in the transcript" \
  "passed=the command ships its own permissive policy that is named explicitly, prints one notice, and is never an implicit fallback" \
  "passed=loopex artifact retrieves a spilled artifact by its opaque reference" \
  "passed=project resource trust is decided at the terminal and a non interactive run without a decision fails closed" \
  "passed=the command surface drives only the public facade and owns no loop store cursor or authority" \
  "passed=the base system prompt and active tool definitions measure under one thousand tokens" \
  "passed=argument parsing and terminal output use only the standard library"

run_selector 11 apps/loopex_composition/test/kernel_composition_test.exs default 4 zero \
  "passed=one page of shipped code starts the application tree a runtime a session a prompt and its events" \
  "passed=an independent embedder fixture composes the kernel without depending on the command application" \
  "passed=the shipped composition requires a host supplied policy and ships no permissive default" \
  "passed=the composition resolves its state root explicitly and never through application environment"

# The tool registry is the internal mechanism the loop and the tools resolve
# through. It is locked supporting coverage, not an outcome of its own.
run_selector registry apps/loopex/test/tool_registry_test.exs default 5 zero \
  "passed=a runtime-scoped registry resolves a tool id and version and refuses an unknown id" \
  "passed=two runtimes carry independent tool registries with no global registration" \
  "passed=a conflicting tool id and version registration is refused with an explicit reason" \
  "passed=a session binds one active model visible name to one generation and refuses a name conflict at start" \
  "passed=a model request records the exact tool definition generation it used"

# Mandatory closure evidence: the attended real-provider demonstration.
run_selector demonstration apps/loopex_cli/test/coding_task_test.exs default 5 positive \
  "passed=a multi tool task reads edits and verifies a file in a disposable repository" \
  "passed=the task transcript shows every tool call decision and result" \
  "passed=a denied tool call inside a multi tool task is reported and the task continues truthfully" \
  "passed=the demonstration workspace is disposable and never the operator's own repository" \
  "passed=a real provider evidence claim fails when the reply carries no provider supplied response identifier" \
  "excluded=one real provider task streams edits a real repository across several turns and the operator sees the committed result" \
  "excluded=one real provider call surfaces the provider's own response identifier and reported usage that the deterministic adapter cannot produce"

run_selector demonstration apps/loopex_cli/test/coding_task_test.exs real-combined 2 positive \
  "passed=one real provider task streams edits a real repository across several turns and the operator sees the committed result" \
  "passed=one real provider call surfaces the provider's own response identifier and reported usage that the deterministic adapter cannot produce" \
  "excluded=a multi tool task reads edits and verifies a file in a disposable repository" \
  "excluded=the task transcript shows every tool call decision and result" \
  "excluded=a denied tool call inside a multi tool task is reported and the task continues truthfully" \
  "excluded=the demonstration workspace is disposable and never the operator's own repository" \
  "excluded=a real provider evidence claim fails when the reply carries no provider supplied response identifier"

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

run_selector mechanics apps/loopex/test/gate_isolation_test.exs default 2 zero \
  "passed=an ambient MIX_BUILD_PATH cannot redirect gate owned compilation out of the owned build root" \
  "passed=the gate refuses an owned root that resolves inside the checkout or the operator's product state"

run_selector mechanics apps/loopex/test/deps_budget_test.exs default 28 zero \
  "passed=the repository satisfies the dependency budget and direction" \
  "passed=the M2 planned inventory admits exactly eight applications with their declared roles" \
  "passed=a composition depends on the edge applications it composes and on no client or external package" \
  "passed=a client depends on at most one composition and never on another client"

run_selector mechanics apps/loopex/test/status_check_test.exs default 42 zero \
  "passed=a Closed milestone's gate is amended by an accepted generation, not a rebind" \
  "passed=a gate generation table fails closed on every malformed shape" \
  "passed=a gate generations table is append-only in both admitted directions" \
  "passed=the integrated phase is derived from the register's closed rows"

run_selector mechanics apps/loopex/test/history_anchoring_test.exs default 19 zero \
  "passed=a Closed milestone's gate generation is one atomic proposal and one rebind" \
  "passed=recorded gate generations are append-only across reachable history" \
  "passed=a gate generation rebind cannot bind an interposed revision that changes nothing" \
  "passed=a gate generation rebind cannot bind an interposed revision carrying unrelated bytes" \
  "passed=a gate generation rebind cannot bind a merge or a revision behind one"

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

# ---------------------------------------------------------------------------
# Real-call attestations.
#
# M1's selector runner seals a fixed real-path field set and refuses a report
# whose key set differs. It is a bound artifact at M1's exact closing bytes, so
# no attestation field can enter that channel. The attestation therefore lives
# beside it, in an M2-owned record this runner validates.
#
# What this proves is bounded and the gate document says so in the same terms:
# the record is well formed, its identifiers carry the documented form of the
# provider the bound runner sealed in this same run, no identifier is reused,
# and the record's non-secret identity is byte-identical to that sealed
# identity. It does not and cannot prove that a socket was opened. Whether each
# identifier exists in the provider account, and whether the reported usage
# matches the billed call, is closure review's step and the only one that
# reaches the provider.
# ---------------------------------------------------------------------------

readonly ATTESTATION_RECORD_PATTERN='^\{"role":"(demonstration_db|inherited_5c|inherited_8b)","selector":"([A-Za-z0-9._/-]+)","provider":"([a-z][a-z0-9_-]*)","model":"([!-~]+)","endpoint":"([!-~]+)","adapter_build":"([!-~]+)","calls":([1-9][0-9]*),"response_id_form":"([A-Za-z0-9_-]{1,16}):([1-9][0-9]{0,2})-([1-9][0-9]{0,2})","provider_response_ids":"([A-Za-z0-9_+-]+)","input_tokens":([1-9][0-9]*),"output_tokens":([1-9][0-9]*),"candidate":"([0-9a-f]{40})","recorded":"([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)"\}$'

# This runner carries no provider allowlist. Each record declares the identifier
# form its named provider documents, written <prefix>:<min>-<max>, and the
# recorded identifiers are validated against that declaration. Enumerating
# providers here would make adding a model adapter a governance event, which a
# replaceable model boundary does not deserve.
#
# Validating a declared form is weaker than validating a known one, and the gate
# document says so rather than implying otherwise: a fabricator declares their
# own form. What survives is internal consistency — every identifier has the
# shape its own record claims, no identifier is reused, and the counts and
# totals agree — plus the protection that was always the load-bearing one, which
# is the auditor's lookup of each identifier against the provider account.

validate_real_call_attestations() {
  local path=docs/evidence/M2-real-call-attestations.md
  [ -f "$path" ] || fail "the real-call attestation record does not exist"

  [ -n "$real_reference_identity" ] \
    || fail "no real-provider role sealed an identity for the attestation record to agree with"

  local expected=(
    "demonstration_db|apps/loopex_cli/test/coding_task_test.exs|4"
    "inherited_5c|apps/loopex_reference_client/test/real_model_session_test.exs|1"
    "inherited_8b|apps/loopex_reference_client/test/end_to_end_recovery_test.exs|2"
  )

  local declared
  declared="$(grep -c '"provider_response_ids"' "$path")"
  [ "$declared" -eq 3 ] \
    || fail "the real-call attestations must be exactly three records, not $declared"

  local records=() line
  while IFS= read -r line; do
    records+=("$line")
  done < <(grep -E '^\{"role":' "$path")

  [ "${#records[@]}" -eq 3 ] \
    || fail "only ${#records[@]} real-call attestation records are one-line JSON objects in the canonical key order"

  local index=0 record pair want_role want_selector want_calls
  local role_name selector provider model endpoint adapter_build calls ids
  local form_prefix form_min form_max declared_form="" record_form
  local remainder remainder_length
  local input_tokens output_tokens candidate identity id id_count seen_ids=" "
  for record in "${records[@]}"; do
    pair="${expected[$index]}"
    want_role="${pair%%|*}"
    want_selector="$(printf '%s' "$pair" | cut -d'|' -f2)"
    want_calls="${pair##*|}"

    if [ -n "$provider_key_value" ]; then
      case "$record" in
        *"$provider_key_value"*)
          fail "real-call attestation $(( index + 1 )) carries provider credential bytes"
          ;;
      esac
    fi

    [[ "$record" =~ $ATTESTATION_RECORD_PATTERN ]] \
      || fail "real-call attestation $(( index + 1 )) is not one canonical record in the locked key order"
    role_name="${BASH_REMATCH[1]}"
    selector="${BASH_REMATCH[2]}"
    provider="${BASH_REMATCH[3]}"
    model="${BASH_REMATCH[4]}"
    endpoint="${BASH_REMATCH[5]}"
    adapter_build="${BASH_REMATCH[6]}"
    calls="${BASH_REMATCH[7]}"
    form_prefix="${BASH_REMATCH[8]}"
    form_min="${BASH_REMATCH[9]}"
    form_max="${BASH_REMATCH[10]}"
    ids="${BASH_REMATCH[11]}"
    input_tokens="${BASH_REMATCH[12]}"
    output_tokens="${BASH_REMATCH[13]}"
    candidate="${BASH_REMATCH[14]}"

    [ "$role_name" = "$want_role" ] \
      || fail "real-call attestation $(( index + 1 )) attests $role_name, not the locked $want_role"
    [ "$selector" = "$want_selector" ] \
      || fail "the $role_name attestation names $selector, not its locked $want_selector"
    require_safe_tracked_path "$selector" "the $role_name attestation"

    identity=" provider=$provider model=$model endpoint=$endpoint adapter_build=$adapter_build"
    [ "$identity" = "$real_reference_identity" ] \
      || fail "the $role_name attestation records a provider, model, endpoint, or adapter build that the bound selector runner did not seal in this run"

    record_form="$form_prefix:$form_min-$form_max"
    [ "$form_min" -le "$form_max" ] \
      || fail "the $role_name attestation declares response identifier form $record_form, whose minimum length exceeds its maximum"
    [ "$form_max" -le 128 ] \
      || fail "the $role_name attestation declares response identifier form $record_form, whose maximum length exceeds the admitted 128"
    if [ -z "$declared_form" ]; then
      declared_form="$record_form"
    else
      [ "$record_form" = "$declared_form" ] \
        || fail "the $role_name attestation declares response identifier form $record_form while an earlier record declared $declared_form; all three roles ran against one sealed provider identity"
    fi

    id_count=0
    local remaining="$ids"
    while [ -n "$remaining" ]; do
      id="${remaining%%+*}"
      if [ "$id" = "$remaining" ]; then
        remaining=""
      else
        remaining="${remaining#*+}"
      fi
      [ -n "$id" ] \
        || fail "the $role_name attestation carries an empty provider response identifier"
      case "$id" in
        "$form_prefix"*) : ;;
        *)
          fail "the $role_name attestation carries a response identifier that does not begin with the $form_prefix prefix its record declares for $provider"
          ;;
      esac
      remainder="${id#"$form_prefix"}"
      [[ "$remainder" =~ ^[A-Za-z0-9_-]+$ ]] \
        || fail "the $role_name attestation carries a response identifier whose remainder leaves the admitted character set"
      remainder_length="${#remainder}"
      { [ "$remainder_length" -ge "$form_min" ] && [ "$remainder_length" -le "$form_max" ]; } \
        || fail "the $role_name attestation carries a response identifier of remainder length $remainder_length, outside the $form_min-$form_max range its record declares for $provider"
      case "$seen_ids" in
        *" $id "*)
          fail "the $role_name attestation reuses provider response identifier $id, which another role already claimed"
          ;;
      esac
      seen_ids="$seen_ids$id "
      id_count=$(( id_count + 1 ))
    done

    [ "$calls" -eq "$id_count" ] \
      || fail "the $role_name attestation claims $calls real calls but names $id_count response identifiers"
    [ "$calls" -ge "$want_calls" ] \
      || fail "the $role_name attestation claims $calls real calls, below the $want_calls its locked role must have made"
    [ "$input_tokens" -ge "$calls" ] && [ "$output_tokens" -ge "$calls" ] \
      || fail "the $role_name attestation reports fewer tokens than it reports calls"

    git merge-base --is-ancestor "$candidate" HEAD 2>/dev/null \
      || fail "the $role_name attestation names candidate $candidate, which is not reachable from this revision"

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
    "" | "docs/evidence/M2-coding-demonstration.md docs/evidence/M2-negative-demonstrations.md docs/evidence/M2-real-call-attestations.md docs/evidence/M2-toolchain-matrix.md ") : ;;
    *) fail "this revision changes product bytes relative to the captured candidate: $changed" ;;
  esac
}

validate_negative_demonstrations
validate_real_call_attestations

user_state_after="$(fingerprint_tree "$user_state_root")"
[ "$user_state_before" = "$user_state_after" ] \
  || fail "the operator's product state under $user_state_root changed during the run"

checkout_build_after="$(fingerprint_tree "$checkout_build_root")"
[ "$checkout_build_before" = "$checkout_build_after" ] \
  || fail "the checkout's own _build changed during the run; the owned build root did not contain compilation"

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
