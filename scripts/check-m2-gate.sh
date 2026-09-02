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

    if function_exported?(Loopex.Store, :max_item_bytes, 0) do
      # ADR 0018's exact callback boundary reports complete usage as the raw
      # token pair, so the probe can observe several turns without conservative
      # accounting consuming the remaining run allowance after its first call.
      # The `status` member belongs to the reducer's normalized usage, never to
      # the adapter reply, whose every level admits no extra key. The branch is
      # discovered from ADR 0017's public Store ceiling rather than a private
      # reducer name.
      {:ok,
       %{
         "text" => "probe turn #{turn}",
         "identity" => %{
           "provider" => "probe",
           "model" => request.model,
           "endpoint" => "in-process"
         },
         "usage" => %{"input_tokens" => 1, "output_tokens" => 1},
         "tool_calls" =>
           Enum.map(tool_calls, fn call ->
             %{"id" => call.id, "name" => call.name, "arguments" => call.arguments}
           end),
         "delta_count" => if(is_function(progress, 1), do: 1, else: 0),
         "streamed" => is_function(progress, 1),
         "provider_response_id" => nil,
         "canonical_request_bytes" => request.canonical_request_bytes,
         "staged_request_digest" => request.staged_request_digest
       }}
    else
      # The pre-Amendment-4 M2 shape, retained so A and R observe the same
      # existing loop while the new behavioral selectors remain red.
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
end

# The probe's own permissive host policy. It declares no `@behaviour` because
# `Loopex.Policy` does not exist on the tree this probe also has to run against,
# and a missing behaviour is a compile error there. Its `decide/1` returns the
# ADR 0009 allow shape.
defmodule Loopex.M2Probe.Policy do
  def decide(_request), do: {:allow, nil}
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

  # The accepted M2 runtime options are a named active tool set and a host-supplied
  # policy. A runtime that refuses either and accepts only one hand-written
  # definition and the literal allow term is the M1 shape, and that refusal is
  # itself one of the observations.
  #
  # Authority has to fall back exactly as the tool set does. Outcome 6 requires an
  # M2 runtime to refuse to start when no policy is named, so a probe that passed
  # only M1's literal `{:host_policy, :allow}` would be refused by the very tree
  # it exists to observe — and because the probe gates green in every role, the
  # gate could never pass.
  defp start_runtime(base) do
    attempts =
      for runtime_configuration <- [
            [context_token_budget: 8_192, cleanup_grace_ms: 5_000],
            [cleanup_grace_ms: 5_000],
            []
          ],
          {shape, tool_option} <- [
            {"named_set", {:tools, coding_tools()}},
            {"single_hand_written", {:tool, demonstration_tool()}}
          ],
          authority <- [{:policy, Loopex.M2Probe.Policy}, {:grant_decision, {:host_policy, :allow}}] do
        {shape, runtime_configuration ++ [tool_option, authority]}
      end

    started =
      Enum.find_value(attempts, fn {shape, options} ->
        case Loopex.start_link(Keyword.merge(base, options)) do
          {:ok, runtime} -> {shape, runtime}
          _other -> nil
        end
      end)

    started ||
      raise "the probe could not start a runtime in either the M2 or the M1 shape"
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
  #
  # Standard input is closed for the same reason it is cleared: the probe runs
  # before the credential frame is read, and a build tool that inherited the
  # gate's standard input could consume that frame before the gate ever sees it.
  # It is not hypothetical. Under the floor toolchain this compile drained the
  # frame, and the run then reported the credential absent and refused its
  # real-provider roles -- a true refusal about a false absence. On the current
  # toolchain the frame survived by luck rather than by design. Closing it here
  # makes the credential boundary hold by construction.
  if ! output="$(
    env -u MIX_BUILD_PATH MIX_ENV=dev MIX_BUILD_ROOT="$probe_root/build" \
      TMPDIR="$probe_root" mix compile 2>&1 </dev/null
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
      elixir "${code_paths[@]}" "$program" 2>&1 </dev/null
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
  "a reached deadline whose cleanup cannot be confirmed ends outcome unknown rather than bound reached" \
  "a retried tool operation keeps its operation identity and reconciles against its own attempt bound request digest" \
  "a tool call whose run deadline already passed is not dispatched and still commits a terminal fact" \
  "the committed absolute deadline is propagated into the model call rather than an independent per call timeout" \
  "a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only" \
  "every sampling bound is a declared committed value with no implicit default" \
  "a committed run deadline bounds a host policy consultation without inventing a policy verdict" \
  "a queued policy result processed after the committed deadline cannot authorize an effect" \
  "an atom valued executor receipt is normalized before bounded projection" \
  "an effect intent whose store commit crosses the deadline never reaches the executor" \
  "an executor event that names the live call but any wrong binding never reaches the operator" \
  "an operator abort remains responsive while host policy is blocked" \
  "every declared executor receipt field is validated live and during reconciliation" \
  "executor receipts are bounded projected and bind every repeated job identity" \
  "reconciling an unknown effect resolves its steer and promotes its follow up atomically" \
  "several tool calls in one turn are dispatched in the model's own call order" \
  "the runtime commits the assistant reply and never assembles canonical history from streamed deltas"

require_feature \
  "the operator never sees an answer until the run ends; nothing streams and no delta algebra exists" \
  apps/loopex_llm_reqllm/test/streaming_conformance_test.exs \
  "every model adapter satisfies one streaming conformance suite" \
  "each canonical delta kind is bounded plain data carrying no provider or host term" \
  "a text delta is observable while its operation is still incomplete rather than after the reply returns" \
  "replaying an adapter's emitted deltas reproduces the reply it returned byte identically" \
  "the model and executor progress domains carry separate sequences each closed by its own content free item" \
  "a gapless sequence within one stream domain and its closing total make lost progress detectable" \
  "the canonical identity encoding is injective and sampled distinct encodings derive stable distinct labels" \
  "a provider retry opens a second stream domain under one turn and neither domain reports the other as loss" \
  "a retried executor operation attempt opens its own stream domain closed by its own closure item and count" \
  "the committed assistant message is built from the reply and never assembled from deltas" \
  "a cancelled stream commits no assistant message and a late reply never becomes canonical" \
  "an adapter that emits no deltas is conformant and declares that it does not stream" \
  "the model reply contract declares the optional provider response identifier" \
  "the shipped adapter splits oversized provider text before it reaches progress" \
  "the shipped adapter refuses terminal-control provider progress before emission" \
  "the delta payload ceiling counts the provider-controlled call identifier and tool name"

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

# Schema evaluation is the internal authority that stops malformed model
# arguments before policy, grant, or dispatch.
require_feature \
  "model tool arguments are not validated against their staged definition before policy or dispatch" \
  apps/loopex_protocol/test/tool_definition_test.exs \
  "arguments are checked against every declared schema constraint"

# The Control service is the authority that distinguishes a real owner handoff
# from runtime unavailability. These supporting cases stop progress, closure,
# or post-commit admission from converting an unavailable answer into an
# invented supersession.
require_feature \
  "progress closure and post commit cannot distinguish Control unavailability from owner loss" \
  apps/loopex/test/session_lifecycle_test.exs \
  "progress reports runtime unavailability without inventing owner supersession" \
  "progress closure reports runtime unavailability without inventing owner supersession" \
  "post commit reports runtime unavailability without inventing owner supersession"

require_feature \
  "the reference prompt has no locked duration derivation or unknown bound refusal" \
  apps/loopex_reference_client/test/reference_client_test.exs \
  "the reference prompt commits a five minute duration and derives its instant at staging" \
  "the reference prompt refuses an unknown bound key before admitting a command"

require_feature \
  "the operator has no coding tools; read, write, edit, and bash do not exist" \
  apps/loopex_executor_local/test/coding_tools_test.exs \
  "read returns bounded chunked content and reports truncation" \
  "write creates or replaces a file beneath the workspace root and refuses static escapes" \
  "edit applies an exact match change and names what differed on a mismatch" \
  "bash runs an argv command and an explicit raw shell command with distinct semantics" \
  "every filesystem tool refuses a path that escapes the workspace root through traversal or a symlink" \
  "bash emits real progress before completion with exact identity sequence offsets and receipt count" \
  "a tool child process group is owned and terminated with its job and no group member survives" \
  "a long running job carries the run deadline is terminated at expiry and its cleanup is confirmed before the run commits its bound"

require_feature \
  "oversized tool output has nowhere to go; there is no artifact store and a long result is simply lost" \
  apps/loopex_store_local/test/artifact_store_conformance_test.exs \
  "one object supports two exact immutable uses in every artifact adapter" \
  "retaining a large value keeps every byte while its bounded notice names the artifact" \
  "the compact artifact reference carries object and use identity without private provenance" \
  "artifact reference fields are bounded and invalid metadata is refused before success" \
  "artifact use metadata is closed allocation bounded and preserves every opaque identifier" \
  "artifact use allocation guard rejects every oversized scalar before adapter access" \
  "Core put proves input object and exact described use before returning success" \
  "locator only stat and object fetch never reconstruct or accept use provenance" \
  "a referenced use remains required when its object bytes are still available" \
  "a referenced object and use remain exact after the local adapter is reopened" \
  "artifact use publication is immutable and concurrent identical puts converge" \
  "the truncation notice stays bounded and names the complete retained artifact" \
  "the public retrieval facade resolves an opaque locator through validated object identity" \
  "public retrieval refuses dishonest stat identity and dishonest fetched bytes" \
  "stat and fetch refuse same size and different size artifact corruption" \
  "fetch refuses a reference whose claimed exact size differs from the stored bytes" \
  "opening an absent artifact root durably publishes every new directory component" \
  "artifact publication leaves unrelated store files unchanged" \
  "artifact publication syncs file bytes before its durable directory entry" \
  "unsafe opaque locators are refused before an adapter can resolve them" \
  "a locator the store never issued reports unavailable rather than raising" \
  "an artifact round trips byte exactly and a missing artifact reports unavailable" \
  "failed artifact use staging write file sync publication compare or parent sync returns no reference" \
  "existing artifact use comparison admits identical bytes and preserves different partial or unreadable values"

require_feature \
  "artifact use metadata can leak into a durable receipt or public event while the store cases stay green" \
  apps/loopex/test/artifact_runtime_test.exs \
  "one Core-retained use is the exact reference journaled published recovered and privately described" \
  "a malformed or legacy artifact reference fails closed before durable or public success"

require_feature \
  "the shipped executor can bypass Core artifact validation or lose private retention provenance" \
  apps/loopex_executor_local/test/artifact_retention_contract_test.exs \
  "a real local executor spills through core with the complete private artifact use" \
  "a real executor refuses a dishonest retained artifact instead of returning its reference"

require_feature \
  "durable Store items have no shared allocation-safe byte, depth, or cardinality admission" \
  apps/loopex/test/store_item_budget_test.exs \
  "the shared Store item normalizer reports exact byte depth and cardinality boundaries" \
  "event normalization and transaction-only protections remain exact and separate" \
  "generated normalization equals real Store transaction normalization and byte admission" \
  "oversized map and improper list report the first structural witness while admitted invalid keys stay distinct"

require_feature \
  "provider context can be admitted without one committed policy and independent Store-item preflight" \
  apps/loopex/test/context_admission_test.exs \
  "Runtime rejects an omitted or invalid context token budget before Control or Store starts" \
  "live required context commits every exact first failure and dispatches no provider" \
  "a dead preparer makes real Core abandonment unconfirmed without activation or dispatch" \
  "command admission preflights every durable candidate and refuses an unrepresentable future terminal before work" \
  "deadline staging checks clock domain and absolute uint64 addition before dispatch and replays one exact pair" \
  "prompt steer and follow-up refusal commit-unknown re-present one exact command binding" \
  "the named reference fixture binds exact context definition-list retained-component and receipt fixed point" \
  "optional project stages empty or is wholly withheld and recomputed by token or record budget" \
  "structured source goldens receipt arithmetic digest framing and malformed replay form one locked matrix" \
  "self consistent message tool and project substitutions cannot outrun adjacent receipt relations" \
  "a required-context refusal retains only the compact safe projection and calls no provider" \
  "context refusal promotion and recovery preserve the predecessor budget into its successor" \
  "context refusal replay validates every compact dimension relation and rejects every broken pair" \
  "revision two phase and cross version replay fail closed in both directions" \
  "page-size-one replay survives a crash after the refusal row and applies its terminal once" \
  "a prepared resume exposes retained context so omission recovers it and a mismatch can abandon before activation" \
  "project resolution locks zero or one shapes first failure order and bounded inspection"

require_feature \
  "the reference composition can replace an explicit context budget or default a non-omitted value" \
  apps/loopex_composition/test/context_admission_test.exs \
  "the reference composition defaults only omission to 8192 and forwards an explicit context budget unchanged"

require_feature \
  "the reference command can resolve defaults after replay or cross prepared-owner conflict without truthful abandonment" \
  apps/loopex_cli/test/context_budget_commands_test.exs \
  "the reference commands default only omission and reject or forward one top-level context budget" \
  "CLI renders only the exact safe context failure projection" \
  "resume recovers an omitted or equal active context and abandons an unequal owner before dispatch" \
  "cancel recovers an omitted or equal active context and refuses an unequal owner before abort" \
  "resume and cancel report context conflict owner unconfirmed before activation or abort" \
  "a settled prepared owner with no active context accepts omission or an explicit future default"

require_feature \
  "provider dispatch has no durable attempt authority, exact retry proof, or conservative recovery settlement" \
  apps/loopex/test/provider_attempt_protocol_test.exs \
  "the request and first attempt open atomically before one direct one-use Control permit can invoke the provider" \
  "a reply whose stream evidence or digest contradicts itself is refused not repaired" \
  "the durable reply retains every adapter value byte for byte and replay rebuilds none" \
  "a crash after a page-size-one request row recovers its consecutive open without dispatching either page" \
  "a page-size-one settlement row applies no terminal semantics until its consecutive terminal row" \
  "a blocked provider worker ignores wrong stale and duplicate permits and invokes once only for its exact fresh permit" \
  "same-owner worker death before a proved Control refusal retries once without charging the dead attempt" \
  "a third-party Model task DOWN after dispatch is ambiguous terminal evidence and never retries" \
  "the authoritative origin closes its model stream before a terminal outcome can publish" \
  "Control death or a lost reply before and after permit send never redispatches and only post-send cells invoke once" \
  "a live owner handoff immediately before Control send invokes none while handoff immediately after send preserves only the predecessor call" \
  "a deadline proved before permit send settles uncharged with no call while a deadline after send settles that attempt conservatively without retry" \
  "only exact pre-canary not_dispatched proof opens one retry whose accounting and stream domain stay bound to its attempt" \
  "two exact not-dispatched settlements consume the version-one allowance with no third attempt" \
  "succession preserves retry permission but never resets or reopens the two-attempt allowance" \
  "reply preflight admits one below and at each Store byte depth and cardinality limit and compacts one above" \
  "a callback aggregate over the Store byte limit completes when its request and durable reply projections each fit" \
  "a credential-shaped raw provider error becomes one generic terminal and enters no retained runtime plane" \
  "request-open commit-unknown re-presents identical bytes and dispatches only after the retained pair resolves" \
  "retry-open commit-unknown re-presents identical bytes and dispatches attempt two only after the retained open resolves" \
  "continue-settlement commit-unknown re-presents identical accounting and conversation bytes before tool or next-turn dispatch" \
  "terminal-settlement commit-unknown re-presents identical accounting conversation and terminal bytes before closure or publication" \
  "provider settlement atomically preserves accounting and first durable termination precedence without false effect or bound outcomes" \
  "recovery settles an unresolved open without redispatch and never reuses or closes the dead predecessor stream"

require_feature \
  "the shipped provider adapter cannot distinguish pre-canary non-dispatch from ambiguous transport failure" \
  apps/loopex_llm_reqllm/test/provider_attempt_adapter_contract_test.exs \
  "the shipped adapter declares not_dispatched only before its transport canary and ambiguity after it"

require_feature \
  "the configured cancellation period is not one measured durable value across admission, cleanup, receipts, and terminals" \
  apps/loopex/test/cancellation_observation_contract_test.exs \
  "the committed cleanup period propagates through genesis status job receipt and terminal" \
  "the versioned genesis decoder refuses missing extra invalid and legacy cleanup truth" \
  "the cleanup period is a canonical job fact rather than an executor side option" \
  "cancellation bounds follow the exact formula and invalid input never calls the executor" \
  "configured cancellation observes a delayed callback beyond the legacy sixty second bound" \
  "configured cancellation enters a uint64 observation wait without handing it to one VM timer" \
  "the execute-result reserve admits one late receipt but expiry stays outcome unknown" \
  "genesis and effect intent are measured before owner or executor authority" \
  "the complete genesis admits exactly 65536 canonical bytes and refuses one byte more"

require_feature \
  "Local has no durable root-wide effect authority, dual-clock fence, receipt reserve, or unresolved-root quarantine" \
  apps/loopex_executor_local/test/local_authority_contract_test.exs \
  "a prepared Local root binds one exact canonical generation before returning" \
  "same-path directory replacement and an isolated generation copy both refuse" \
  "generation validation rejects extra keys broken relations symlinks and oversized bytes" \
  "placement publication syncs the generation file and its parent before returning" \
  "two Local instances sharing one root issue one effect permit and conflict on changed bytes" \
  "wall truth and the immutable monotonic action deadline fence effects independently" \
  "a later effect transition reuses the handoff deadline after wall time moves backward" \
  "a Local receipt reports the committed cleanup facts and fits the Store item envelope" \
  "missing malformed and contradictory cleanup facts make a retained receipt unavailable" \
  "receipt fitting spills complete bytes and fail-closed artifact answers claim no suffix" \
  "complete root snapshots enforce both entry capacity and the byte ceiling" \
  "observed_at is sampled at effect admission and not resampled after delayed work" \
  "effect admission retains exact marker and open authority and observes file before parent sync" \
  "deadline refusal precedes admission while post-admission cancellation cannot rewrite no-effect truth" \
  "Local owner loss terminates launch-owned authority and quarantines unresolved root truth" \
  "restart refuses a malformed open-index tail without downgrading existing open authority" \
  "stopping only the Local runtime can leave a bypassed OS child alive and rollback requires positive termination"

require_feature \
  "prepared recovery has no one-use activation capability and cannot distinguish omission from conflicting configuration" \
  apps/loopex_cli/test/prepared_recovery_contract_test.exs \
  "an active recovered run stays paused until one-use activation and propagates cleanup" \
  "abandonment of an active prepared owner prevents activation and dispatch" \
  "a preparer that dies before holder transfer cannot leave an activatable owner" \
  "prepared interrupt transfer survives preparer death and an abort wins before dispatch" \
  "the prepared interrupt owner can abandon its capability without activating work" \
  "commit unknown abort admission permanently fences prepared activation without dispatch" \
  "resume omission recovers the committed cleanup period before active work resumes" \
  "resume and cancel cleanup mismatches abandon their prepared owner without manual release" \
  "explicit cancel recovers the committed cleanup bound and aborts while work stays paused" \
  "configured interrupt joins concurrent signals under one abort identity and bound" \
  "a configured signal before any prompt dispatches no work and legacy install remains available" \
  "prepared recovery and separately prepared Local authority stay out of durable and rendered planes" \
  "the operator renderer emits only a generic failure for a credential shaped raw provider error"

require_feature \
  "the shipped reference stack cannot carry a non-default cleanup value through real receipt restart prepared resume and cancel recovery" \
  apps/loopex_reference_client/test/configured_recovery_contract_test.exs \
  "a non-default cleanup value crosses real Local receipt restart prepared resume and cancel recovery" \
  "prepared restart activation reconciles the retained effect once without redispatch"

require_feature \
  "host policy cannot refuse a tool call; there is no policy port and no working deny path" \
  apps/loopex_executor_local/test/host_policy_test.exs \
  "every host policy implementation satisfies one policy port conformance suite" \
  "a host policy deny decision issues no grant and starts no operating system process" \
  "a denied tool call commits a truthful denied outcome the operator can read" \
  "the run continues or terminates truthfully after a denial and never retries the refused call" \
  "a denied read only call reaches neither the executor nor a durable effect path" \
  "model tool context and client input cannot mint or widen a host grant" \
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
  "discovery resolves one canonical resource under declared path and size limits and retains the future shape total" \
  "the operator is shown every resolved path its provenance and the manifest digest" \
  "an explicit trust decision binds workspace revision manifest and digests" \
  "a changed workspace revision manifest or content invalidates the decision" \
  "a headless run without a matching positive decision stages no project block journals a declined receipt and still runs" \
  "an ordinary workspace read stays a policy governed tool effect and is never context staging" \
  "an admitted project block changes no tool set policy decision bound or grant" \
  "project manifest and trust labels are closed bounded safe text before retention"

require_feature \
  "the operator cannot stop a running task; cancellation is recorded but nothing is cancelled" \
  apps/loopex/test/cancellation_test.exs \
  "an interrupt reaches the run through the public facade and through no private path" \
  "an abort admitted during a model call cancels the run and schedules no new work" \
  "an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled" \
  "confirmed executor cleanup cannot replace a missing operation terminal fact when deriving cancelled" \
  "a validated terminal tool fact committed before the abort is preserved and not overwritten" \
  "an effect without sufficient evidence ends outcome unknown and is never blindly retried" \
  "a second interrupt reports what is still being cleaned up rather than abandoning the session" \
  "a cancellation executor without cancel/2 is unconfirmed" \
  "the operator observes what was cancelled and what actually happened"

require_feature \
  "a starting executor job can be pronounced clean when its cancellation never answers" \
  apps/loopex_executor_local/test/executor_test.exs \
  "a starting job whose cancellation does not answer becomes unconfirmed"

require_feature \
  "the operator cannot find yesterday's work; nothing enumerates the sessions in a state root" \
  apps/loopex/test/session_directory_test.exs \
  "a fresh operating system process lists the sessions in a resolved state root" \
  "the state root resolves from LOOPEX_HOME and never from application environment" \
  "a session resumes under the durable runtime placement identity that created it" \
  "a fresh operating system process re-presents the runtime placement identity persisted by its predecessor" \
  "resuming a session through a different runtime identity is refused with an explicit reason" \
  "a repeated resume command identity returns its historical result while a fresh identity acquires ownership" \
  "Store replay of a resume command survives a missing directory cache"

require_feature \
  "there is no loopex command; the only way to run a session is a test selector" \
  apps/loopex_cli/test/cli_test.exs \
  "loopex run submits a prompt and streams the answer with its tool calls and results" \
  "the operator steers a running task and queues a follow-up from the same terminal" \
  "prompt steer follow up and abort have distinct explicit affordances and input naming neither is refused" \
  "each command refuses malformed ambiguous or irrelevant arguments before doing work" \
  "tool progress from a running executor job reaches the operator's terminal before the tool finishes" \
  "loopex sessions lists the operator's sessions and loopex resume continues one" \
  "an interrupt signal delivered to a running loopex process cancels the task through the public facade" \
  "an interrupt whose cleanup cannot be confirmed reports outcome unknown with its reconciliation reference" \
  "loopex cancel reconciles a session left behind by a dead process and is refused against a live owner" \
  "a reused live pid cannot inherit a stale placement lock" \
  "the policy option selects the governing host policy and a refusal is reported in the transcript" \
  "the command ships its own permissive policy that is named explicitly, prints one notice, and is never an implicit fallback" \
  "loopex artifact retrieves spilled bytes by the object locator carried in its compact reference" \
  "project resource trust is decided at the terminal and a non interactive run without a decision proceeds with the block withheld" \
  "the command surface drives only the public facade and owns no loop store cursor or authority" \
  "the command retrieves artifacts through the ArtifactStore facade and never calls a composed adapter directly" \
  "the command exposes exactly run sessions resume cancel and artifact and no wire or line framing surface" \
  "a dropped stream closure leaves the terminal falling back to the durable record without inferring abandonment or starting a timer" \
  "the runtime measures exact staged system and tool bytes while the provider facing base stays under one thousand tokens" \
  "argument parsing and terminal output use only the standard library" \
  "the operator declares how long a stopped run may spend stopping and a bad value is refused"

require_feature \
  "an embedder cannot depend on a shipped composition; the only composition is test support" \
  apps/loopex_composition/test/kernel_composition_test.exs \
  "one page of shipped code starts the application tree a runtime a session a prompt and its events" \
  "an independent embedder fixture composes the kernel without depending on the command application" \
  "the shipped composition requires a host supplied policy and ships no permissive default" \
  "the composition resolves its state root explicitly and never through application environment" \
  "the composition forwards the executor's declared cleanup period and probe" \
  "required host inputs are validated before the first effect" \
  "a later error raise or exit cleans every process acquired before it" \
  "stopping the runtime releases the composition owner and every private process" \
  "abnormal runtime death releases the composition owner and every private process"

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
  "the gate refuses an owned root that resolves inside the checkout or the operator's product state" \
  "the evidence lifecycle admits its direct evidence closure and later descendants" \
  "the evidence lifecycle requires one atomic direct four document evidence child" \
  "closure binds the evidence commit in one transition and changes only derived status bytes" \
  "closed evidence closure and disposition cannot mutate or bypass their reviewed transition" \
  "candidate scoped retained digests answer for the revision each record names"

require_feature \
  "the dependency corpus does not yet describe the M2 eight-application inventory or the composition role" \
  apps/loopex/test/deps_budget_test.exs \
  "the repository satisfies the dependency budget and direction" \
  "the M2 planned inventory admits exactly eight applications with their declared roles" \
  "a composition depends on the edge applications it composes and on no client or external package" \
  "a client depends on at most one composition and never on another client"

require_feature \
  "the live status corpus no longer protects prerequisite and closed gate generation governance" \
  apps/loopex/test/status_check_test.exs \
  "a milestone cannot outrun the ADR dispositions its plan pair declares" \
  "a Closed milestone's gate is amended by an accepted generation, not a rebind" \
  "a gate generation table fails closed on every malformed shape" \
  "a gate generations table is append-only in both admitted directions" \
  "the integrated phase is derived from the register's closed rows"

require_feature \
  "the history walk no longer protects prerequisite and closed gate generation governance" \
  apps/loopex/test/history_anchoring_test.exs \
  "an unavailable walk is unavailable evidence in both history checks" \
  "a declared Bound Artifacts table that binds nothing is refused" \
  "the real history reader carries the register and refuses a laundered prerequisite" \
  "a completed Acceptance row is judged even while the register still says Open" \
  "a Closed milestone cannot conceal an outstanding prerequisite behind an Open successor" \
  "accepting a prerequisite later cannot legalise an earlier acceptance" \
  "a Closed milestone's gate generation is one atomic proposal and one rebind" \
  "recorded gate generations are append-only across reachable history" \
  "a gate generation rebind cannot bind an interposed revision that changes nothing" \
  "a gate generation rebind cannot bind an interposed revision carrying unrelated bytes" \
  "a gate generation rebind cannot bind a merge or a revision behind one"

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

revision_file_digest() {
  local revision="$1" path="$2" output
  git cat-file -e "$revision:$path" 2>/dev/null || return 1

  case "$digest_dialect" in
    shasum) output="$(git show "$revision:$path" 2>/dev/null | shasum -a 256)" ;;
    sha256sum) output="$(git show "$revision:$path" 2>/dev/null | sha256sum)" ;;
  esac

  [ -n "$output" ] || return 1
  printf '%s' "${output%% *}"
}

require_candidate_digest() {
  local candidate="$1" path="$2" recorded="$3" context="$4" actual
  actual="$(revision_file_digest "$candidate" "$path")" \
    || fail "$context cannot read $path at candidate $candidate"
  [ "$recorded" = "$actual" ] \
    || fail "$context records $recorded for $path, not candidate $candidate's $actual"
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
require_bound_artifact \
  809ca8b835182751f493ef1c931d309f36a73ae48cf78208f84b81fcb05e74a4 \
  apps/loopex_composition/test/kernel_composition_test.exs
require_bound_artifact \
  50319510018a4b3e2fab2e5998f3b7979209982b9cabc15e7fa69cfc5782a8cc \
  apps/loopex/test/gate_isolation_test.exs

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
  docs/evidence/M2-recorded-limitations.md
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

run_selector 1 apps/loopex/test/agent_loop_test.exs default 100 zero \
  "passed=a prompt runs until the model stops requesting tools rather than after a fixed number of turns" \
  "passed=every model request carries the committed conversation history including the original prompt" \
  "passed=an assistant tool call and its real tool result are committed and replayed to the model" \
  "passed=each turn dispatches exactly the canonical request bytes and digest committed before it" \
  "passed=a staged request carries complete tool definition bytes and its generation triple and is reconstructible from the journal alone" \
  "passed=every turn after the first is canonical history replay and the reserved continuation field stays empty" \
  "passed=the maximum turn bound ends the run bound reached before another provider call" \
  "passed=the cumulative token budget ends the run bound reached before another provider call" \
  "passed=the wall clock deadline ends the run bound reached before another provider call" \
  "passed=the committed absolute deadline is propagated into the model call rather than an independent per call timeout" \
  "passed=a prompt fixes its deadline at first request staging and not at admission" \
  "passed=every sampling bound is a declared committed value with no implicit default" \
  "passed=the retry allowance a run has already spent is not handed back by a succession" \
  "passed=a tool call whose run deadline already passed is not dispatched and still commits a terminal fact" \
  "passed=a committed request that expired while its owner was down is not redispatched to the provider" \
  "passed=a reached deadline whose cleanup cannot be confirmed ends outcome unknown rather than bound reached" \
  "passed=an unproven effect ends the run rather than letting the model be asked again" \
  "passed=an unproven effect outranks the model stopping on its own and the run never finishes completed" \
  "passed=an unproven effect stops the tool calls still queued behind it in the same batch" \
  "passed=an unproven effect outranks the maximum turn bound" \
  "passed=an unproven effect outranks the cumulative token budget" \
  "passed=a retried tool operation keeps its operation identity and reconciles against its own attempt bound request digest" \
  "passed=a reply committed before an admitted abort completes the turn and an abort admitted first keeps the late reply as attempt evidence only" \
  "passed=a receipt lost after the effect ran ends the run outcome unknown rather than failed" \
  "passed=a refusal that precedes the effect stays a terminal failed and the loop carries on" \
  "passed=an executor error the runtime cannot place before the effect is unproven" \
  "passed=an executor that declares nothing has every error read as unproven" \
  "passed=an answer that reaches for the pre-start tag and misses its shape declares nothing" \
  "passed=a pre-start refusal is read from the answer's shape and not from the error's name" \
  "passed=a complete tool stream closes on its receipt's own progress count" \
  "passed=a receipt the Store refuses cannot complete its tool stream" \
  "passed=a reply the Store refuses cannot complete its model stream" \
  "passed=an abandoned model stream closes on the count this runtime published rather than zero" \
  "passed=a delta carrying a field its kind does not declare is refused rather than projected" \
  "passed=the run's terminal reports the cleanup period this session declared" \
  "passed=no item of a stream domain is emitted after that domain's closure" \
  "passed=a closed stream domain accepts nothing further and its relay is gone" \
  "passed=a succession never gives two owners one stream domain" \
  "passed=a prior ownership verdict cannot suppress notified model cleanup" \
  "passed=a superseded coordinator is not reaped while cleanup is still pending" \
  "passed=an abrupt model owner death never gives its successor the same stream domain" \
  "passed=a model error before its supersession notification cannot close the old domain" \
  "passed=runtime unavailability while closing a model error does not invent owner supersession" \
  "passed=handoff cannot move between progress admission and relay emission" \
  "passed=a stale Store refusal of a model result leaves closure and abandonment to the successor" \
  "passed=a retained model result closes complete after Control handoff" \
  "passed=a model result admitted before handoff still closes complete after ownership moves" \
  "passed=a live executor supersession ends its old stream without claiming the effect abandoned" \
  "passed=an executor progress ownership refusal ends the stale plane without terminating its worker" \
  "passed=runtime unavailability during executor progress does not invent owner loss" \
  "passed=runtime unavailability while closing a refused tool does not invent owner loss" \
  "passed=a durable owner handoff fences executor progress and closure before its notification arrives" \
  "passed=a malformed executor receipt cannot close the old domain across an owner handoff" \
  "passed=a stale non receipt executor answer leaves diagnosis and reconciliation to the successor" \
  "passed=an executor receipt admitted before handoff still closes complete after ownership moves" \
  "passed=a retained executor receipt closes complete after Control handoff" \
  "passed=a stream relay ends with the owner that opened it, ahead of its own backlog" \
  "passed=two attempts of one tool operation never share a stream domain" \
  "passed=an executor that declares no cancellation confirms nothing" \
  "passed=a stream statistic that is not a count is refused rather than published or committed" \
  "passed=a complete model stream closes on its reply's own delta count" \
  "passed=a run that no executor answered still reports the period it would have stopped under" \
  "passed=a model delta emitted after its stream is closed is neither projected nor counted" \
  "passed=an event emitted after its stream is closed is neither projected nor counted" \
  "passed=an abandoned tool stream closes on the count this runtime published rather than a claim" \
  "passed=executor progress proves its whole identity before anything is projected" \
  "passed=a refused executor event is counted privately and never journaled" \
  "passed=a refused current-attempt payload preserves its executor sequence gap" \
  "passed=a validated executor event carries only its bounded named payload across" \
  "passed=the first delta of a model attempt is sequence zero" \
  "passed=each executor stream anchors to the current public event at its own dispatch" \
  "passed=a Store refusal of late model attempt evidence makes clean cancellation unprovable" \
  "passed=a late model error is retained as bounded attempt evidence without becoming history" \
  "passed=an unreadable late model reply is retained as a bounded error instead of crashing cleanup" \
  "passed=a model reply queued behind its deadline is retained with the deadline termination" \
  "passed=cleanup waits for a model result sent after the supervisor answers" \
  "passed=late model evidence binds the provider retry attempt that produced it" \
  "passed=a model tool call preserves a JSON number argument through durable dispatch" \
  "passed=a schema-invalid tool call fails before policy or executor sees it" \
  "passed=an undeclared late provider field becomes bounded error and never reaches the journal" \
  "passed=nested provider fields are projected out of valid late evidence" \
  "passed=a deeply nested late provider term becomes bounded error at the Store boundary" \
  "passed=a malformed streamed flag in a late reply becomes bounded error" \
  "passed=a late reply whose streamed flag contradicts its count becomes bounded error" \
  "passed=an oversized valid late reply is retained as bounded error" \
  "passed=a late model error retains only its generic bounded category" \
  "passed=a committed run deadline bounds a host policy consultation without inventing a policy verdict" \
  "passed=a queued policy result processed after the committed deadline cannot authorize an effect" \
  "passed=an atom valued executor receipt is normalized before bounded projection" \
  "passed=an effect intent whose store commit crosses the deadline never reaches the executor" \
  "passed=an executor event that names the live call but any wrong binding never reaches the operator" \
  "passed=an operator abort remains responsive while host policy is blocked" \
  "passed=every declared executor receipt field is validated live and during reconciliation" \
  "passed=executor receipts are bounded projected and bind every repeated job identity" \
  "passed=reconciling an unknown effect resolves its steer and promotes its follow up atomically" \
  "passed=several tool calls in one turn are dispatched in the model's own call order" \
  "passed=the runtime commits the assistant reply and never assembles canonical history from streamed deltas"

run_selector 2 apps/loopex_llm_reqllm/test/streaming_conformance_test.exs default 19 zero \
  "passed=every model adapter satisfies one streaming conformance suite" \
  "passed=each canonical delta kind is bounded plain data carrying no provider or host term" \
  "passed=a text delta is observable while its operation is still incomplete rather than after the reply returns" \
  "passed=replaying an adapter's emitted deltas reproduces the reply it returned byte identically" \
  "passed=the model and executor progress domains carry separate sequences each closed by its own content free item" \
  "passed=a gapless sequence within one stream domain and its closing total make lost progress detectable" \
  "passed=the canonical identity encoding is injective and sampled distinct encodings derive stable distinct labels" \
  "passed=a provider retry opens a second stream domain under one turn and neither domain reports the other as loss" \
  "passed=a retried executor operation attempt opens its own stream domain closed by its own closure item and count" \
  "passed=the committed assistant message is built from the reply and never assembled from deltas" \
  "passed=a cancelled stream commits no assistant message and a late reply never becomes canonical" \
  "passed=an adapter that emits no deltas is conformant and declares that it does not stream" \
  "passed=a delta missing a field its kind declares is refused rather than projected" \
  "passed=a delta field whose size the ceiling cannot see is refused rather than projected" \
  "passed=an abandoned domain is closed and stated rather than guessed from a stream that stopped" \
  "passed=the model reply contract declares the optional provider response identifier" \
  "passed=the shipped adapter splits oversized provider text before it reaches progress" \
  "passed=the shipped adapter refuses terminal-control provider progress before emission" \
  "passed=the delta payload ceiling counts the provider-controlled call identifier and tool name"

run_selector 3 apps/loopex/test/input_algebra_test.exs default 9 zero \
  "passed=a prompt starts a run only while the session is settled and is otherwise refused" \
  "passed=the runtime never infers whether new input is steering or follow up and a steer must name its active run" \
  "passed=a steer joins the active run after the current tool batch and before the next model request" \
  "passed=a steer is recorded applied only when a committed request carried it" \
  "passed=a follow up starts a new run only after the active run and its steering settle" \
  "passed=a promoted follow up fixes its deadline when its first request stages" \
  "passed=a steer that arrives after its run is terminal commits unapplied with a reason and is never promoted" \
  "passed=at most one unapplied steer and one queued follow up exist and both survive owner succession" \
  "passed=an abort resolves any unapplied steer and queued follow up as cancelled"

run_selector 4 apps/loopex_executor_local/test/coding_tools_test.exs default 39 zero \
  "passed=read returns bounded chunked content and reports truncation" \
  "passed=write creates or replaces a file beneath the workspace root and refuses static escapes" \
  "passed=edit applies an exact match change and names what differed on a mismatch" \
  "passed=bash runs an argv command and an explicit raw shell command with distinct semantics" \
  "passed=bash reports a nonzero exit as failed and names the status the command exited with" \
  "passed=every filesystem tool refuses a path that escapes the workspace root through traversal or a symlink" \
  "passed=bash emits real progress before completion with exact identity sequence offsets and receipt count" \
  "passed=a coding tool command receives a constructed provider credential free environment and its receipt records that declared environment" \
  "passed=a tool child process group is owned and terminated with its job and no group member survives" \
  "passed=a long running job carries the run deadline is terminated at expiry and its cleanup is confirmed before the run commits its bound" \
  "passed=an already expired job is refused before the local executor opens a port" \
  "passed=the wall time budget the session declared bounds the job and not merely the run" \
  "passed=a job whose workspace lease is lost mid flight is ended and reported unproven" \
  "passed=a filesystem tool is bounded while it runs rather than only before it starts" \
  "passed=write refuses a name that is not an ordinary file and replaces the one it names atomically" \
  "passed=edit refuses a name that is not an ordinary file before it opens anything" \
  "passed=a lease lost while a job's output is being retained abandons the retention and reports it unproven" \
  "passed=a command that backgrounds work and exits is not completed until its group is quiescent" \
  "passed=a lease lost while a job's group is brought to quiescence is reported unproven" \
  "passed=a lease lost while a job's receipt is being retained is reported unproven" \
  "passed=a process group is confirmed clean only by a ps that answered" \
  "passed=the first process the launcher starts explicitly excludes the provider credential" \
  "passed=every executor spawn supplies an environment override that excludes the provider credential" \
  "passed=the run deadline bounds retaining a spilled artifact and the abandonment is reported" \
  "passed=a receipt that could not be retained is reported rather than answered as a result" \
  "passed=work this executor cannot bound is abandoned at its bound and a program that never answers confirms nothing" \
  "passed=the run deadline bounds the demonstration launcher as well as the coding tools" \
  "passed=the cleanup budget is one configured period with a declared default and every receipt records it" \
  "passed=a job requiring process cleanup retains its receipt under a separate quarter period bound" \
  "passed=the configured cleanup budget bounds the whole termination sequence rather than each step of it" \
  "passed=cancelling a running job answers only for the cleanup it could confirm" \
  "passed=cancelling an unknown job id leaves another running job untouched" \
  "passed=each of the three quiescence answers reaches a distinct outcome and only one is proved" \
  "passed=an answer this executor gives after an effect ran never wears the pre-start tag" \
  "passed=a job is bounded by the tool's declared budget when that is sooner than the run's" \
  "passed=a deadline stop whose cleanup could not be confirmed is unproven rather than cancelled" \
  "passed=a job is refused when the lease it names is held at another fencing token" \
  "passed=the two containment mechanisms obligation four names by name are the ones the code uses" \
  "passed=a cleanup helper that outlives its bound is terminated rather than left running"

run_selector 5 apps/loopex_store_local/test/artifact_store_conformance_test.exs default 24 zero \
  "passed=one object supports two exact immutable uses in every artifact adapter" \
  "passed=retaining a large value keeps every byte while its bounded notice names the artifact" \
  "passed=the compact artifact reference carries object and use identity without private provenance" \
  "passed=artifact reference fields are bounded and invalid metadata is refused before success" \
  "passed=artifact use metadata is closed allocation bounded and preserves every opaque identifier" \
  "passed=artifact use allocation guard rejects every oversized scalar before adapter access" \
  "passed=Core put proves input object and exact described use before returning success" \
  "passed=locator only stat and object fetch never reconstruct or accept use provenance" \
  "passed=a referenced use remains required when its object bytes are still available" \
  "passed=a referenced object and use remain exact after the local adapter is reopened" \
  "passed=artifact use publication is immutable and concurrent identical puts converge" \
  "passed=the truncation notice stays bounded and names the complete retained artifact" \
  "passed=the public retrieval facade resolves an opaque locator through validated object identity" \
  "passed=public retrieval refuses dishonest stat identity and dishonest fetched bytes" \
  "passed=stat and fetch refuse same size and different size artifact corruption" \
  "passed=fetch refuses a reference whose claimed exact size differs from the stored bytes" \
  "passed=opening an absent artifact root durably publishes every new directory component" \
  "passed=artifact publication leaves unrelated store files unchanged" \
  "passed=artifact publication syncs file bytes before its durable directory entry" \
  "passed=unsafe opaque locators are refused before an adapter can resolve them" \
  "passed=a locator the store never issued reports unavailable rather than raising" \
  "passed=an artifact round trips byte exactly and a missing artifact reports unavailable" \
  "passed=failed artifact use staging write file sync publication compare or parent sync returns no reference" \
  "passed=existing artifact use comparison admits identical bytes and preserves different partial or unreadable values"

run_selector 6a apps/loopex_executor_local/test/host_policy_test.exs default 10 zero \
  "passed=every host policy implementation satisfies one policy port conformance suite" \
  "passed=a host policy deny decision issues no grant and starts no operating system process" \
  "passed=a denied tool call commits a truthful denied outcome the operator can read" \
  "passed=the run continues or terminates truthfully after a denial and never retries the refused call" \
  "passed=a denied read only call reaches neither the executor nor a durable effect path" \
  "passed=model tool context and client input cannot mint or widen a host grant" \
  "passed=a policy that raises times out or returns a malformed value fails closed into denial" \
  "passed=defer is declared and refused in this milestone rather than treated as allow or deny" \
  "passed=every executor backed tool requires a policy decision including a read only tool" \
  "passed=a permissive policy applies only when it is named and omitting the policy option refuses runtime start"

run_selector 6b apps/loopex_reference_client/test/allow_all_policy_test.exs default 2 zero \
  "passed=the shipped allow all policy allows every decision it is asked" \
  "passed=the shipped allow all policy emits exactly one permissive authority notice"

run_selector 7 apps/loopex/test/project_resource_trust_test.exs default 8 zero \
  "passed=discovery resolves one canonical resource under declared path and size limits and retains the future shape total" \
  "passed=the operator is shown every resolved path its provenance and the manifest digest" \
  "passed=an explicit trust decision binds workspace revision manifest and digests" \
  "passed=a changed workspace revision manifest or content invalidates the decision" \
  "passed=a headless run without a matching positive decision stages no project block journals a declined receipt and still runs" \
  "passed=an ordinary workspace read stays a policy governed tool effect and is never context staging" \
  "passed=an admitted project block changes no tool set policy decision bound or grant" \
  "passed=project manifest and trust labels are closed bounded safe text before retention"

run_selector 8a apps/loopex/test/cancellation_test.exs default 25 zero \
  "passed=an interrupt reaches the run through the public facade and through no private path" \
  "passed=an abort admitted during a model call cancels the run and schedules no new work" \
  "passed=an abort admitted during a tool call cancels the executor job and confirms cleanup before committing cancelled" \
  "passed=cleanup commits a valid executor receipt queued behind its own settlement" \
  "passed=confirmed executor cleanup cannot replace a missing operation terminal fact when deriving cancelled" \
  "passed=a validated terminal tool fact committed before the abort is preserved and not overwritten" \
  "passed=an effect without sufficient evidence ends outcome unknown and is never blindly retried" \
  "passed=a second interrupt reports what is still being cleaned up rather than abandoning the session" \
  "passed=a second interrupt during cleanup starts no second executor cancellation" \
  "passed=the operator observes what was cancelled and what actually happened" \
  "passed=an abort reduced while an unprovable receipt settles finishes the run outcome unknown" \
  "passed=the abort is durable before its cleanup runs and its ending is a second commit" \
  "passed=the coordinator answers while a host cancellation is still running" \
  "passed=a host cancellation that never answers is bounded and settles unconfirmed" \
  "passed=a cancellation executor without cancel/2 is unconfirmed" \
  "passed=a run being cleaned up is still active and admits nothing new until its ending commits" \
  "passed=an executor that never answered leaves its call a terminal fact of its own" \
  "passed=a recovering owner ends the abandoned call before it ends the run" \
  "passed=an abort after succession cannot report a clean stop for the predecessor's unproved effect" \
  "passed=a run does not end while the operation it owns has no committed ending" \
  "passed=a recovering owner does not end a run whose operation it could not settle" \
  "passed=a recovering owner ends a run with no dispatched effect outcome unknown" \
  "passed=a cancellation this runtime cannot read is unproven rather than a confirmed clean stop" \
  "passed=an abort during an in flight tool call treats an executor cancellation error as outcome unknown with a reconciliation reference" \
  "passed=an abort admitted after an unprovable effect committed never rewrites the run to cancelled"

run_selector 8b apps/loopex_executor_local/test/executor_test.exs default 7 zero \
  "passed=a starting job whose cancellation does not answer becomes unconfirmed"

run_selector 9 apps/loopex/test/session_directory_test.exs default 7 zero \
  "passed=a fresh operating system process lists the sessions in a resolved state root" \
  "passed=the state root resolves from LOOPEX_HOME and never from application environment" \
  "passed=a session resumes under the durable runtime placement identity that created it" \
  "passed=a fresh operating system process re-presents the runtime placement identity persisted by its predecessor" \
  "passed=resuming a session through a different runtime identity is refused with an explicit reason" \
  "passed=a repeated resume command identity returns its historical result while a fresh identity acquires ownership" \
  "passed=Store replay of a resume command survives a missing directory cache"

run_selector 10 apps/loopex_cli/test/cli_test.exs default 22 zero \
  "passed=loopex run submits a prompt and streams the answer with its tool calls and results" \
  "passed=the operator steers a running task and queues a follow-up from the same terminal" \
  "passed=prompt steer follow up and abort have distinct explicit affordances and input naming neither is refused" \
  "passed=each command refuses malformed ambiguous or irrelevant arguments before doing work" \
  "passed=tool progress from a running executor job reaches the operator's terminal before the tool finishes" \
  "passed=loopex sessions lists the operator's sessions and loopex resume continues one" \
  "passed=an interrupt signal delivered to a running loopex process cancels the task through the public facade" \
  "passed=an interrupt whose cleanup cannot be confirmed reports outcome unknown with its reconciliation reference" \
  "passed=loopex cancel reconciles a session left behind by a dead process and is refused against a live owner" \
  "passed=a reused live pid cannot inherit a stale placement lock" \
  "passed=the policy option selects the governing host policy and a refusal is reported in the transcript" \
  "passed=the command ships its own permissive policy that is named explicitly, prints one notice, and is never an implicit fallback" \
  "passed=loopex artifact retrieves spilled bytes by the object locator carried in its compact reference" \
  "passed=project resource trust is decided at the terminal and a non interactive run without a decision proceeds with the block withheld" \
  "passed=the command surface drives only the public facade and owns no loop store cursor or authority" \
  "passed=the command retrieves artifacts through the ArtifactStore facade and never calls a composed adapter directly" \
  "passed=the command exposes exactly run sessions resume cancel and artifact and no wire or line framing surface" \
  "passed=a dropped stream closure leaves the terminal falling back to the durable record without inferring abandonment or starting a timer" \
  "passed=the runtime measures exact staged system and tool bytes while the provider facing base stays under one thousand tokens" \
  "passed=argument parsing and terminal output use only the standard library" \
  "passed=the operator declares how long a stopped run may spend stopping and a bad value is refused" \
  "passed=the real operator decision path displays resolved path provenance trust and both digests"

run_selector 11 apps/loopex_composition/test/kernel_composition_test.exs default 9 zero \
  "passed=one page of shipped code starts the application tree a runtime a session a prompt and its events" \
  "passed=an independent embedder fixture composes the kernel without depending on the command application" \
  "passed=the shipped composition requires a host supplied policy and ships no permissive default" \
  "passed=the composition resolves its state root explicitly and never through application environment" \
  "passed=the composition forwards the executor's declared cleanup period and probe" \
  "passed=required host inputs are validated before the first effect" \
  "passed=a later error raise or exit cleans every process acquired before it" \
  "passed=stopping the runtime releases the composition owner and every private process" \
  "passed=abnormal runtime death releases the composition owner and every private process"

# The tool registry is the internal mechanism the loop and the tools resolve
# through. It is locked supporting coverage, not an outcome of its own.
run_selector registry apps/loopex/test/tool_registry_test.exs default 5 zero \
  "passed=a runtime-scoped registry resolves a tool id and version and refuses an unknown id" \
  "passed=two runtimes carry independent tool registries with no global registration" \
  "passed=a conflicting tool id and version registration is refused with an explicit reason" \
  "passed=a session binds one active model visible name to one generation and refuses a name conflict at start" \
  "passed=a model request records the exact tool definition generation it used"

# Tool-schema evaluation is the internal mechanism that keeps invalid model
# arguments out of policy, grant, and executor boundaries.
run_selector tool-schema apps/loopex_protocol/test/tool_definition_test.exs default 10 zero \
  "passed=arguments are checked against every declared schema constraint"

# Owner-loss admission is cross-cutting stream machinery rather than an
# operator outcome. These cases protect the distinction between an unavailable
# Control process and an actual owner-loss verdict.
run_selector stream-mechanics apps/loopex/test/session_lifecycle_test.exs default 3 zero \
  "passed=progress reports runtime unavailability without inventing owner supersession" \
  "passed=progress closure reports runtime unavailability without inventing owner supersession" \
  "passed=post commit reports runtime unavailability without inventing owner supersession"

run_selector reference-bounds apps/loopex_reference_client/test/reference_client_test.exs default 4 zero \
  "passed=the reference prompt commits a five minute duration and derives its instant at staging" \
  "passed=the reference prompt refuses an unknown bound key before admitting a command"

# Artifact adapter conformance cannot prove which compact members the runtime
# retains or publishes. This separate role protects the cross-boundary
# projection and the privacy of the immutable use metadata.
run_selector artifact-runtime apps/loopex/test/artifact_runtime_test.exs default 2 zero \
  "passed=one Core-retained use is the exact reference journaled published recovered and privately described" \
  "passed=a malformed or legacy artifact reference fails closed before durable or public success"

run_selector artifact-retention apps/loopex_executor_local/test/artifact_retention_contract_test.exs default 2 zero \
  "passed=a real local executor spills through core with the complete private artifact use" \
  "passed=a real executor refuses a dishonest retained artifact instead of returning its reference"

run_selector store-item-budget apps/loopex/test/store_item_budget_test.exs default 4 zero \
  "passed=the shared Store item normalizer reports exact byte depth and cardinality boundaries" \
  "passed=event normalization and transaction-only protections remain exact and separate" \
  "passed=generated normalization equals real Store transaction normalization and byte admission" \
  "passed=oversized map and improper list report the first structural witness while admitted invalid keys stay distinct"

run_selector context-admission apps/loopex/test/context_admission_test.exs default 17 zero \
  "passed=Runtime rejects an omitted or invalid context token budget before Control or Store starts" \
  "passed=live required context commits every exact first failure and dispatches no provider" \
  "passed=a dead preparer makes real Core abandonment unconfirmed without activation or dispatch" \
  "passed=command admission preflights every durable candidate and refuses an unrepresentable future terminal before work" \
  "passed=deadline staging checks clock domain and absolute uint64 addition before dispatch and replays one exact pair" \
  "passed=prompt steer and follow-up refusal commit-unknown re-present one exact command binding" \
  "passed=the named reference fixture binds exact context definition-list retained-component and receipt fixed point" \
  "passed=optional project stages empty or is wholly withheld and recomputed by token or record budget" \
  "passed=structured source goldens receipt arithmetic digest framing and malformed replay form one locked matrix" \
  "passed=self consistent message tool and project substitutions cannot outrun adjacent receipt relations" \
  "passed=a required-context refusal retains only the compact safe projection and calls no provider" \
  "passed=context refusal promotion and recovery preserve the predecessor budget into its successor" \
  "passed=context refusal replay validates every compact dimension relation and rejects every broken pair" \
  "passed=revision two phase and cross version replay fail closed in both directions" \
  "passed=page-size-one replay survives a crash after the refusal row and applies its terminal once" \
  "passed=a prepared resume exposes retained context so omission recovers it and a mismatch can abandon before activation" \
  "passed=project resolution locks zero or one shapes first failure order and bounded inspection"

run_selector composition-context apps/loopex_composition/test/context_admission_test.exs default 1 zero \
  "passed=the reference composition defaults only omission to 8192 and forwards an explicit context budget unchanged"

run_selector command-context apps/loopex_cli/test/context_budget_commands_test.exs default 6 zero \
  "passed=the reference commands default only omission and reject or forward one top-level context budget" \
  "passed=CLI renders only the exact safe context failure projection" \
  "passed=resume recovers an omitted or equal active context and abandons an unequal owner before dispatch" \
  "passed=cancel recovers an omitted or equal active context and refuses an unequal owner before abort" \
  "passed=resume and cancel report context conflict owner unconfirmed before activation or abort" \
  "passed=a settled prepared owner with no active context accepts omission or an explicit future default"

run_selector provider-attempt apps/loopex/test/provider_attempt_protocol_test.exs default 24 zero \
  "passed=the request and first attempt open atomically before one direct one-use Control permit can invoke the provider" \
  "passed=a reply whose stream evidence or digest contradicts itself is refused not repaired" \
  "passed=the durable reply retains every adapter value byte for byte and replay rebuilds none" \
  "passed=a crash after a page-size-one request row recovers its consecutive open without dispatching either page" \
  "passed=a page-size-one settlement row applies no terminal semantics until its consecutive terminal row" \
  "passed=a blocked provider worker ignores wrong stale and duplicate permits and invokes once only for its exact fresh permit" \
  "passed=same-owner worker death before a proved Control refusal retries once without charging the dead attempt" \
  "passed=a third-party Model task DOWN after dispatch is ambiguous terminal evidence and never retries" \
  "passed=the authoritative origin closes its model stream before a terminal outcome can publish" \
  "passed=Control death or a lost reply before and after permit send never redispatches and only post-send cells invoke once" \
  "passed=a live owner handoff immediately before Control send invokes none while handoff immediately after send preserves only the predecessor call" \
  "passed=a deadline proved before permit send settles uncharged with no call while a deadline after send settles that attempt conservatively without retry" \
  "passed=only exact pre-canary not_dispatched proof opens one retry whose accounting and stream domain stay bound to its attempt" \
  "passed=two exact not-dispatched settlements consume the version-one allowance with no third attempt" \
  "passed=succession preserves retry permission but never resets or reopens the two-attempt allowance" \
  "passed=reply preflight admits one below and at each Store byte depth and cardinality limit and compacts one above" \
  "passed=a callback aggregate over the Store byte limit completes when its request and durable reply projections each fit" \
  "passed=a credential-shaped raw provider error becomes one generic terminal and enters no retained runtime plane" \
  "passed=request-open commit-unknown re-presents identical bytes and dispatches only after the retained pair resolves" \
  "passed=retry-open commit-unknown re-presents identical bytes and dispatches attempt two only after the retained open resolves" \
  "passed=continue-settlement commit-unknown re-presents identical accounting and conversation bytes before tool or next-turn dispatch" \
  "passed=terminal-settlement commit-unknown re-presents identical accounting conversation and terminal bytes before closure or publication" \
  "passed=provider settlement atomically preserves accounting and first durable termination precedence without false effect or bound outcomes" \
  "passed=recovery settles an unresolved open without redispatch and never reuses or closes the dead predecessor stream"

run_selector provider-adapter apps/loopex_llm_reqllm/test/provider_attempt_adapter_contract_test.exs default 1 zero \
  "passed=the shipped adapter declares not_dispatched only before its transport canary and ambiguity after it"

run_selector cancellation-observation apps/loopex/test/cancellation_observation_contract_test.exs default 9 zero \
  "passed=the committed cleanup period propagates through genesis status job receipt and terminal" \
  "passed=the versioned genesis decoder refuses missing extra invalid and legacy cleanup truth" \
  "passed=the cleanup period is a canonical job fact rather than an executor side option" \
  "passed=cancellation bounds follow the exact formula and invalid input never calls the executor" \
  "passed=configured cancellation observes a delayed callback beyond the legacy sixty second bound" \
  "passed=configured cancellation enters a uint64 observation wait without handing it to one VM timer" \
  "passed=the execute-result reserve admits one late receipt but expiry stays outcome unknown" \
  "passed=genesis and effect intent are measured before owner or executor authority" \
  "passed=the complete genesis admits exactly 65536 canonical bytes and refuses one byte more"

run_selector local-authority apps/loopex_executor_local/test/local_authority_contract_test.exs default 17 zero \
  "passed=a prepared Local root binds one exact canonical generation before returning" \
  "passed=same-path directory replacement and an isolated generation copy both refuse" \
  "passed=generation validation rejects extra keys broken relations symlinks and oversized bytes" \
  "passed=placement publication syncs the generation file and its parent before returning" \
  "passed=two Local instances sharing one root issue one effect permit and conflict on changed bytes" \
  "passed=wall truth and the immutable monotonic action deadline fence effects independently" \
  "passed=a later effect transition reuses the handoff deadline after wall time moves backward" \
  "passed=a Local receipt reports the committed cleanup facts and fits the Store item envelope" \
  "passed=missing malformed and contradictory cleanup facts make a retained receipt unavailable" \
  "passed=receipt fitting spills complete bytes and fail-closed artifact answers claim no suffix" \
  "passed=complete root snapshots enforce both entry capacity and the byte ceiling" \
  "passed=observed_at is sampled at effect admission and not resampled after delayed work" \
  "passed=effect admission retains exact marker and open authority and observes file before parent sync" \
  "passed=deadline refusal precedes admission while post-admission cancellation cannot rewrite no-effect truth" \
  "passed=Local owner loss terminates launch-owned authority and quarantines unresolved root truth" \
  "passed=restart refuses a malformed open-index tail without downgrading existing open authority" \
  "passed=stopping only the Local runtime can leave a bypassed OS child alive and rollback requires positive termination"

run_selector prepared-recovery apps/loopex_cli/test/prepared_recovery_contract_test.exs default 13 zero \
  "passed=an active recovered run stays paused until one-use activation and propagates cleanup" \
  "passed=abandonment of an active prepared owner prevents activation and dispatch" \
  "passed=a preparer that dies before holder transfer cannot leave an activatable owner" \
  "passed=prepared interrupt transfer survives preparer death and an abort wins before dispatch" \
  "passed=the prepared interrupt owner can abandon its capability without activating work" \
  "passed=commit unknown abort admission permanently fences prepared activation without dispatch" \
  "passed=resume omission recovers the committed cleanup period before active work resumes" \
  "passed=resume and cancel cleanup mismatches abandon their prepared owner without manual release" \
  "passed=explicit cancel recovers the committed cleanup bound and aborts while work stays paused" \
  "passed=configured interrupt joins concurrent signals under one abort identity and bound" \
  "passed=a configured signal before any prompt dispatches no work and legacy install remains available" \
  "passed=prepared recovery and separately prepared Local authority stay out of durable and rendered planes" \
  "passed=the operator renderer emits only a generic failure for a credential shaped raw provider error"

run_selector reference-cancellation apps/loopex_reference_client/test/configured_recovery_contract_test.exs default 2 zero \
  "passed=a non-default cleanup value crosses real Local receipt restart prepared resume and cancel recovery" \
  "passed=prepared restart activation reconciles the retained effect once without redispatch"

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

run_selector mechanics apps/loopex/test/gate_isolation_test.exs default 7 zero \
  "passed=an ambient MIX_BUILD_PATH cannot redirect gate owned compilation out of the owned build root" \
  "passed=the gate refuses an owned root that resolves inside the checkout or the operator's product state" \
  "passed=the evidence lifecycle admits its direct evidence closure and later descendants" \
  "passed=the evidence lifecycle requires one atomic direct four document evidence child" \
  "passed=closure binds the evidence commit in one transition and changes only derived status bytes" \
  "passed=closed evidence closure and disposition cannot mutate or bypass their reviewed transition" \
  "passed=candidate scoped retained digests answer for the revision each record names"

run_selector mechanics apps/loopex/test/deps_budget_test.exs default 28 zero \
  "passed=the repository satisfies the dependency budget and direction" \
  "passed=the M2 planned inventory admits exactly eight applications with their declared roles" \
  "passed=a composition depends on the edge applications it composes and on no client or external package" \
  "passed=a client depends on at most one composition and never on another client"

run_selector mechanics apps/loopex/test/status_check_test.exs default 43 zero \
  "passed=a milestone cannot outrun the ADR dispositions its plan pair declares" \
  "passed=a Closed milestone's gate is amended by an accepted generation, not a rebind" \
  "passed=a gate generation table fails closed on every malformed shape" \
  "passed=a gate generations table is append-only in both admitted directions" \
  "passed=the integrated phase is derived from the register's closed rows"

run_selector mechanics apps/loopex/test/history_anchoring_test.exs default 25 zero \
  "passed=an unavailable walk is unavailable evidence in both history checks" \
  "passed=a declared Bound Artifacts table that binds nothing is refused" \
  "passed=the real history reader carries the register and refuses a laundered prerequisite" \
  "passed=a completed Acceptance row is judged even while the register still says Open" \
  "passed=a Closed milestone cannot conceal an outstanding prerequisite behind an Open successor" \
  "passed=accepting a prerequisite later cannot legalise an earlier acceptance" \
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

require_safe_tracked_path_at() {
  local revision="$1" path="$2" context="$3" entry
  case "$path" in
    /* | *..* | *//*)
      fail "$context names an unsafe path $path"
      ;;
  esac

  entry="$(git ls-tree "$revision" -- "$path" 2>/dev/null)" \
    || fail "$context cannot inspect $path at candidate $revision"
  [[ "$entry" =~ ^100644\ blob\ [0-9a-f]{40,64}$'\t' ]] \
    || fail "$context names $path, which is not a tracked ordinary file at candidate $revision"
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
    "artifact_use_object_binding|apps/loopex_store_local/test/artifact_store_conformance_test.exs"
    "local_whole_root_replacement_refusal|apps/loopex_executor_local/test/local_authority_contract_test.exs"
    "local_generation_copy_refusal|apps/loopex_executor_local/test/local_authority_contract_test.exs"
    "context_model_projection_accounting|apps/loopex/test/context_admission_test.exs"
    "provider_attempt_one_use_permit|apps/loopex/test/provider_attempt_protocol_test.exs"
  )

  local declared
  declared="$(grep -c '"mechanism_disabled"' "$path")"
  [ "$declared" -eq 13 ] \
    || fail "the negative demonstrations must be exactly thirteen records, not $declared"

  local records=() line
  while IFS= read -r line; do
    records+=("$line")
  done < <(grep -E '^\{"mechanism_disabled":' "$path")

  [ "${#records[@]}" -eq 13 ] \
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

    git merge-base --is-ancestor "$candidate" HEAD 2>/dev/null \
      || fail "the $mechanism demonstration names candidate $candidate, which is not reachable from this revision"
    require_safe_tracked_path_at "$candidate" "$selector" "the $mechanism demonstration"
    require_safe_tracked_path_at "$candidate" "$artifact" "the $mechanism demonstration"
    require_candidate_digest \
      "$candidate" "$artifact" "$restored" "the $mechanism demonstration"

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

m2_evidence_lifecycle_program() {
  cat <<'LOOPEX_M2_EVIDENCE_LIFECYCLE'
defmodule Loopex.M2EvidenceLifecycle do
  @evidence_paths [
    "docs/evidence/M2-coding-demonstration.md",
    "docs/evidence/M2-negative-demonstrations.md",
    "docs/evidence/M2-real-call-attestations.md",
    "docs/evidence/M2-toolchain-matrix.md"
  ]
  @plan "docs/plans/M2.md"
  @plans_index "docs/plans/README.md"
  @root_readme "README.md"
  @dispositions "docs/developer/agent-context-map.md"
  @empty_closure "| Closure | — | — | — |"
  @closure_paths Enum.sort([@plan, @plans_index, @root_readme, @dispositions])

  def main do
    candidate = System.get_env("LOOPEX_M2_SOURCE_CANDIDATE", "")

    case validate(candidate) do
      :ok -> IO.puts("M2 evidence lifecycle OK")
      {:error, reason} ->
        IO.puts(:stderr, "M2 evidence lifecycle refused: #{reason}")
        System.halt(1)
    end
  rescue
    _exception ->
      IO.puts(:stderr, "M2 evidence lifecycle refused: evidence history is unavailable")
      System.halt(1)
  catch
    _kind, _reason ->
      IO.puts(:stderr, "M2 evidence lifecycle refused: evidence history is unavailable")
      System.halt(1)
  end

  def validate(candidate) do
    with :ok <- exact_candidate(candidate),
         :ok <- complete_history(),
         :ok <- commit_exists(candidate),
         true <- ancestor?(candidate, "HEAD") || {:error, "source candidate is not reachable"},
         {:ok, revisions} <- revisions(),
         {:ok, evidence} <- unique_evidence(candidate, revisions),
         :ok <- evidence_blobs_retained(evidence, "HEAD"),
         {:ok, evidence_plan} <- revision_file(evidence, @plan),
         {:ok, @empty_closure} <- closure_row(evidence_plan),
         :ok <- state_is(evidence, "In review"),
         {:ok, head_plan} <- revision_file("HEAD", @plan),
         {:ok, current_closure} <- closure_row(head_plan),
         :ok <- validate_current_state(candidate, evidence, current_closure, revisions) do
      :ok
    else
      false -> {:error, "evidence history is unavailable"}
      {:ok, row} -> {:error, "evidence child already carries Closure: #{row}"}
      {:error, _reason} = error -> error
      _other -> {:error, "evidence history is unavailable"}
    end
  end

  defp exact_candidate(candidate) do
    if Regex.match?(~r/^[0-9a-f]{40}$/, candidate),
      do: :ok,
      else: {:error, "matrix names no exact source candidate"}
  end

  defp complete_history do
    with {:ok, shallow} <- git(["rev-parse", "--is-shallow-repository"]),
         true <- String.trim(shallow) == "false" || {:error, "history is shallow"},
         {:ok, replacements} <- git(["replace", "-l"]),
         true <- String.trim(replacements) == "" || {:error, "history uses replacement objects"},
         {:ok, grafts_path} <- git(["rev-parse", "--git-path", "info/grafts"]),
         :ok <- empty_or_absent(String.trim(grafts_path)) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp empty_or_absent(path) do
    case File.read(path) do
      {:ok, ""} -> :ok
      {:ok, _bytes} -> {:error, "history uses grafts"}
      {:error, :enoent} -> :ok
      {:error, _reason} -> {:error, "history completeness cannot be established"}
    end
  end

  defp commit_exists(revision) do
    case git(["cat-file", "-e", "#{revision}^{commit}"]) do
      {:ok, _output} -> :ok
      {:error, _output} -> {:error, "source candidate is not a commit"}
    end
  end

  defp revisions do
    with {:ok, output} <- git(["rev-list", "--parents", "HEAD"]) do
      parsed =
        output
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [revision | parents] = String.split(line, " ", trim: true)
          {revision, parents}
        end)

      {:ok, parsed}
    end
  end

  defp unique_evidence(candidate, revisions) do
    candidates =
      revisions
      |> Enum.filter(fn {_revision, parents} -> parents == [candidate] end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.filter(&evidence_edge?(candidate, &1))

    case candidates do
      [evidence] -> {:ok, evidence}
      [] -> {:error, "source candidate has no direct evidence-only child"}
      _many -> {:error, "source candidate has more than one direct evidence-only child"}
    end
  end

  defp evidence_edge?(candidate, revision) do
    with {:ok, paths} <- changed_paths(candidate, revision),
         true <- paths == Enum.sort(@evidence_paths),
         true <- Enum.all?(@evidence_paths, &ordinary_blob?(revision, &1)) do
      true
    else
      _other -> false
    end
  end

  defp ordinary_blob?(revision, path) do
    case git(["ls-tree", revision, "--", path]) do
      {:ok, output} -> Regex.match?(~r/^100644 blob [0-9a-f]{40,64}\t/, output)
      {:error, _output} -> false
    end
  end

  defp evidence_blobs_retained(evidence, revision) do
    case Enum.find(@evidence_paths, fn path -> blob_id(evidence, path) != blob_id(revision, path) end) do
      nil -> :ok
      path -> {:error, "retained evidence changed after the evidence commit: #{path}"}
    end
  end

  defp validate_current_state(_candidate, evidence, @empty_closure, _revisions) do
    with {:ok, head} <- git(["rev-parse", "HEAD"]),
         true <- String.trim(head) == evidence || {:error, "an open milestone has commits after its evidence child"},
         :ok <- state_is("HEAD", "In review") do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp validate_current_state(_candidate, evidence, _closure, revisions) do
    with {:ok, descendants} <- descendant_records(evidence, revisions),
         {:ok, transition} <- unique_closure_transition(evidence, descendants),
         :ok <- transition_shape(evidence, transition),
         {:ok, closure} <- closure_record(transition),
         :ok <- closure_binds_evidence(closure, evidence),
         :ok <- closure_matches_acceptance(closure, evidence),
         :ok <- plan_changes_only_closure(evidence, transition),
         :ok <- derived_status_only(evidence, transition),
         {:ok, disposition_record} <- new_disposition(evidence, transition, closure.target),
         :ok <- state_is(transition, "Closed"),
         :ok <- descendants_follow_transition(evidence, transition, descendants),
         :ok <- retain_closure(evidence, descendants, transition, closure.row, disposition_record) do
      :ok
    end
  end

  defp descendant_records(evidence, revisions) do
    records =
      revisions
      |> Enum.filter(fn {revision, _parents} -> ancestor?(evidence, revision) end)
      |> Map.new(fn {revision, parents} ->
        plan = required_revision_file!(revision, @plan)
        {revision, %{parents: parents, closure: required_closure_row!(plan)}}
      end)

    {:ok, records}
  rescue
    _exception -> {:error, "a descendant has no readable M2 Closure record"}
  end

  defp unique_closure_transition(evidence, descendants) do
    first =
      descendants
      |> Enum.filter(fn {revision, %{parents: parents, closure: closure}} ->
        revision != evidence and closure != @empty_closure and
          Enum.all?(Enum.filter(parents, &Map.has_key?(descendants, &1)), fn parent ->
            descendants[parent].closure == @empty_closure
          end)
      end)
      |> Enum.map(&elem(&1, 0))

    case first do
      [transition] -> {:ok, transition}
      [] -> {:error, "no unique first Closure transition is reachable"}
      _many -> {:error, "more than one first Closure transition is reachable"}
    end
  end

  defp transition_shape(evidence, transition) do
    with {:ok, parents} <- parents_of(transition),
         true <- parents == [evidence] || {:error, "Closure transition is not the direct one-parent child of evidence"},
         {:ok, paths} <- changed_paths(evidence, transition),
         true <- paths == @closure_paths || {:error, "Closure transition changes bytes outside the four allowed paths"} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp closure_record(revision) do
    with {:ok, plan} <- revision_file(revision, @plan),
         {:ok, row} <- closure_row(plan),
         [_, authority, target, candidate, concept, technical, gate] <-
           Regex.run(
             ~r/^\| Closure \| ([^|]+?) \| \[disposition\]\(([^)]+)\) \| candidate `([0-9a-f]{40})`; concept `(sha256:[0-9a-f]{64})`; technical `(sha256:[0-9a-f]{64})`; gate `(sha256:[0-9a-f]{64})` \|$/,
             row
           ),
         true <- String.trim(authority) not in ["", "—"] || {:error, "Closure authority is empty"} do
      {:ok,
       %{
         row: row,
         target: target,
         candidate: candidate,
         concept: concept,
         technical: technical,
         gate: gate
       }}
    else
      {:error, _reason} = error -> error
      _other -> {:error, "Closure row is malformed"}
    end
  end

  defp closure_binds_evidence(%{candidate: evidence}, evidence), do: :ok
  defp closure_binds_evidence(_closure, _evidence), do: {:error, "Closure does not bind the evidence commit"}

  defp closure_matches_acceptance(closure, evidence) do
    with {:ok, plan} <- revision_file(evidence, @plan),
         {:ok, acceptance} <- acceptance_record(plan),
         true <-
           {closure.concept, closure.technical, closure.gate} ==
             {acceptance.concept, acceptance.technical, acceptance.gate} ||
             {:error, "Closure does not bind the accepted envelope and gate digests"} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp acceptance_record(plan) do
    with {:ok, row} <- unique_row(plan, "Acceptance"),
         [_, concept, technical, gate] <-
           Regex.run(
             ~r/^\| Acceptance \| [^|]+ \| \[disposition\]\([^)]+\) \| candidate `[0-9a-f]{40}`; concept `(sha256:[0-9a-f]{64})`; technical `(sha256:[0-9a-f]{64})`; gate `(sha256:[0-9a-f]{64})` \|$/,
             row
           ) do
      {:ok, %{concept: concept, technical: technical, gate: gate}}
    else
      _other -> {:error, "Acceptance row at evidence is malformed"}
    end
  end

  defp plan_changes_only_closure(evidence, transition) do
    with {:ok, before} <- revision_file(evidence, @plan),
         {:ok, after_bytes} <- revision_file(transition, @plan),
         {:ok, before_row} <- closure_row(before),
         {:ok, after_row} <- closure_row(after_bytes),
         true <- String.replace(after_bytes, after_row, before_row, global: false) == before ||
                   {:error, "M2 plan changes more than the Closure row"} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp derived_status_only(evidence, transition) do
    with {:ok, plans_before} <- revision_file(evidence, @plans_index),
         {:ok, plans_after} <- revision_file(transition, @plans_index),
         :ok <- only_marker_changes(plans_before, plans_after, [
           {"<!-- loopex:current-status:start -->", "<!-- loopex:current-status:end -->"},
           {"<!-- loopex:milestone-register:start -->", "<!-- loopex:milestone-register:end -->"}
         ]),
         {:ok, root_before} <- revision_file(evidence, @root_readme),
         {:ok, root_after} <- revision_file(transition, @root_readme),
         :ok <- only_marker_changes(root_before, root_after, [
           {"<!-- loopex:readme-status:start -->", "<!-- loopex:readme-status:end -->"}
         ]) do
      :ok
    end
  end

  defp only_marker_changes(before, after_bytes, markers) do
    with {:ok, before_parts} <- marker_parts(before, markers),
         {:ok, after_parts} <- marker_parts(after_bytes, markers),
         true <- Enum.all?(markers, fn marker -> before_parts[marker].body != after_parts[marker].body end) ||
                   {:error, "a required derived status marker did not change"},
         true <- normalize_markers(before, markers) == normalize_markers(after_bytes, markers) ||
                   {:error, "a lifecycle summary changes outside its derived markers"} do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp marker_parts(bytes, markers) do
    Enum.reduce_while(markers, {:ok, %{}}, fn {start_marker, end_marker} = marker, {:ok, found} ->
      pattern = ~r/#{Regex.escape(start_marker)}(.*?)#{Regex.escape(end_marker)}/s

      case Regex.scan(pattern, bytes) do
        [[whole, body]] -> {:cont, {:ok, Map.put(found, marker, %{whole: whole, body: body})}}
        _other -> {:halt, {:error, "a derived status marker is absent or duplicated"}}
      end
    end)
  end

  defp normalize_markers(bytes, markers) do
    Enum.reduce(markers, bytes, fn {start_marker, end_marker}, normalized ->
      Regex.replace(
        ~r/#{Regex.escape(start_marker)}.*?#{Regex.escape(end_marker)}/s,
        normalized,
        start_marker <> "\n<derived-status>\n" <> end_marker
      )
    end)
  end

  defp new_disposition(evidence, transition, target) do
    with [_, anchor] <- Regex.run(~r/^\.\.\/developer\/agent-context-map\.md#([a-z0-9][a-z0-9-]*)$/, target),
         {:ok, before} <- revision_file(evidence, @dispositions),
         {:ok, after_bytes} <- revision_file(transition, @dispositions),
         marker = ~s(<a id="#{anchor}"></a>),
         true <- count(before, marker) == 0 || {:error, "Closure disposition anchor already existed at evidence"},
         true <- count(after_bytes, marker) == 1 || {:error, "Closure disposition anchor is absent or duplicated"},
         true <- String.starts_with?(after_bytes, before) || {:error, "Closure transition rewrites prior disposition bytes"},
         appended = binary_part(after_bytes, byte_size(before), byte_size(after_bytes) - byte_size(before)),
         {:ok, block} <- disposition_block(after_bytes, marker),
         true <- appended == "\n" <> block || {:error, "Closure transition adds bytes outside its new disposition record"},
         true <- count(appended, "<a id=") == 1 || {:error, "Closure transition adds more than one disposition anchor"},
         true <- complete_disposition_block?(block, marker) || {:error, "Closure disposition record is incomplete"} do
      {:ok, %{marker: marker, block: block}}
    else
      {:error, _reason} = error -> error
      _other -> {:error, "Closure disposition target is not the durable context map"}
    end
  end

  defp complete_disposition_block?(block, marker) do
    Regex.match?(
      ~r/^#{Regex.escape(marker)}\n(?:##|###|####|#####|######) [^\n]+\n\n\S/s,
      block
    ) and String.ends_with?(block, "\n")
  end

  defp disposition_block(bytes, marker) do
    case :binary.match(bytes, marker) do
      {start, _length} ->
        tail = binary_part(bytes, start, byte_size(bytes) - start)

        finish =
          case :binary.match(tail, "\n<a id=", scope: {byte_size(marker), byte_size(tail) - byte_size(marker)}) do
            {index, _length} -> index
            :nomatch -> byte_size(tail)
          end

        {:ok, binary_part(tail, 0, finish)}

      :nomatch ->
        {:error, "Closure disposition block is absent"}
    end
  end

  defp descendants_follow_transition(evidence, transition, descendants) do
    case Enum.find(Map.keys(descendants), fn revision ->
           revision != evidence and not ancestor?(transition, revision)
         end) do
      nil -> :ok
      revision -> {:error, "an evidence descendant bypasses the Closure transition: #{revision}"}
    end
  end

  defp retain_closure(evidence, descendants, transition, closure_row, disposition_record) do
    Enum.reduce_while(descendants, :ok, fn {revision, %{closure: row}}, :ok ->
      cond do
        not ancestor?(transition, revision) ->
          {:cont, :ok}

        row != closure_row ->
          {:halt, {:error, "Closure row changed after the transition at #{revision}"}}

        true ->
          case evidence_blobs_retained(evidence, revision) do
            :ok ->
              with {:ok, bytes} <- revision_file(revision, @dispositions),
                   {:ok, block} <- exact_disposition_block(bytes, disposition_record),
                   true <- block == disposition_record.block ||
                             {:error, "Closure disposition changed after the transition at #{revision}"} do
                {:cont, :ok}
              else
                {:error, _reason} = error -> {:halt, error}
              end

            {:error, _reason} = error ->
              {:halt, error}
          end
      end
    end)
  end

  defp exact_disposition_block(bytes, %{marker: marker}) do
    with [_match] <- :binary.matches(bytes, marker),
         {:ok, block} <- disposition_block(bytes, marker) do
      {:ok, block}
    else
      _other -> {:error, "Closure disposition anchor is absent or duplicated"}
    end
  end

  defp state_is(revision, expected) do
    with {:ok, index} <- revision_file(revision, @plans_index),
         [_, state] <- Regex.run(~r/^\| M2 \| ([^|]+?) \|/m, index),
         true <- String.trim(state) == expected || {:error, "M2 is not #{expected} at #{revision}"} do
      :ok
    else
      {:error, _reason} = error -> error
      _other -> {:error, "M2 register row is absent at #{revision}"}
    end
  end

  defp parents_of(revision) do
    with {:ok, line} <- git(["rev-list", "--parents", "-n", "1", revision]),
         [_revision | parents] <- String.split(String.trim(line), " ", trim: true) do
      {:ok, parents}
    else
      _other -> {:error, "revision parents are unavailable"}
    end
  end

  defp changed_paths(left, right) do
    with {:ok, output} <- git(["diff", "--name-only", "--no-renames", left, right]) do
      {:ok, output |> String.split("\n", trim: true) |> Enum.sort()}
    end
  end

  defp blob_id(revision, path) do
    case git(["rev-parse", "#{revision}:#{path}"]) do
      {:ok, output} -> String.trim(output)
      {:error, _output} -> :unavailable
    end
  end

  defp revision_file(revision, path) do
    case git(["show", "#{revision}:#{path}"]) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _output} -> {:error, "#{path} is unavailable at #{revision}"}
    end
  end

  defp required_revision_file!(revision, path) do
    case revision_file(revision, path) do
      {:ok, bytes} -> bytes
      {:error, reason} -> raise reason
    end
  end

  defp closure_row(plan), do: unique_row(plan, "Closure")

  defp required_closure_row!(plan) do
    case closure_row(plan) do
      {:ok, row} -> row
      {:error, reason} -> raise reason
    end
  end

  defp unique_row(plan, name) do
    rows = Regex.scan(~r/^\| #{Regex.escape(name)} \|.*$/m, plan) |> Enum.map(&hd/1)

    case rows do
      [row] -> {:ok, row}
      _other -> {:error, "M2 plan carries no unique #{name} row"}
    end
  end

  defp count(bytes, needle), do: length(:binary.matches(bytes, needle))

  defp ancestor?(left, right) do
    match?({:ok, _output}, git(["merge-base", "--is-ancestor", left, right]))
  end

  defp git(args) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end

Loopex.M2EvidenceLifecycle.main()
LOOPEX_M2_EVIDENCE_LIFECYCLE
}

validate_evidence_lifecycle() {
  local candidate="$1" output status
  output="$(
    LOOPEX_M2_SOURCE_CANDIDATE="$candidate" \
      elixir -e "$(m2_evidence_lifecycle_program)" 2>&1
  )"
  status=$?

  [ "$status" -eq 0 ] || fail "$output"
  [ "$output" = "M2 evidence lifecycle OK" ] \
    || fail "the evidence lifecycle validator returned an unrecognised result"
}

matrix_candidate_digest_artifacts() {
  printf '%s\n' \
    "gate_sha256|$GATE_DOCUMENT" \
    "runner_sha256|scripts/check-m2-gate.sh" \
    "exunit_runner_sha256|scripts/m1-exunit-runner.exs" \
    "exunit_corpus_sha256|apps/loopex/test/m1_exunit_runner_test.exs" \
    "gate_corpus_sha256|apps/loopex/test/gate_isolation_test.exs" \
    "composition_corpus_sha256|apps/loopex_composition/test/kernel_composition_test.exs" \
    "tool_versions_sha256|.tool-versions"
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
  while IFS='|' read -r key file; do
    expect="$(matrix_field "$header" "$key")" \
      || fail "the retained matrix records no $key"
    require_candidate_digest \
      "$candidate" "$file" "$expect" "the retained matrix $key"
  done < <(matrix_candidate_digest_artifacts)

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
  for lane in floor current; do
    count="$(grep -cE "^m0 lane=$lane " "$path")"
    [ "$count" -eq 1 ] \
      || fail "the retained matrix must carry exactly one M0 $lane re-proof, not $count"
    line="$(grep -E "^m0 lane=$lane " "$path" | head -1)"
    [ "$(matrix_field "$line" candidate)" = "$candidate" ] \
      || fail "the M0 $lane re-proof names a different candidate than the matrix row"
    m0_digest="$(matrix_field "$line" gate_sha256)" \
      || fail "the M0 $lane re-proof names no gate digest"
    require_candidate_digest \
      "$candidate" docs/plans/M0-gate.md "$m0_digest" \
      "the M0 $lane re-proof"
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

  count="$(grep -cE '^m1 candidate=' "$path")"
  [ "$count" -eq 1 ] \
    || fail "the retained matrix must carry exactly one M1 re-proof, not $count"
  line="$(grep -E '^m1 candidate=' "$path" | head -1)"
  [ "$(matrix_field "$line" candidate)" = "$candidate" ] \
    || fail "the M1 re-proof names a different candidate than the matrix row"
  [ "$(matrix_field "$line" command)" = "bash-p:scripts/check-m1-gate.sh" ] \
    || fail "the M1 re-proof names a command other than the privileged M1 gate"
  [ "$(matrix_field "$line" elixir)" = "1.20.3" ] \
    || fail "the M1 re-proof was not recorded on Elixir 1.20.3"
  [ "$(matrix_field "$line" otp)" = "29.0.5" ] \
    || fail "the M1 re-proof was not recorded on OTP 29.0.5"
  [[ "$(matrix_field "$line" seed)" =~ ^[0-9]{1,6}$ ]] \
    || fail "the M1 re-proof records no canonical seed"
  [[ "$(matrix_field "$line" executed)" =~ ^[1-9][0-9]*$ ]] \
    || fail "the M1 re-proof executed no protected cases"
  [ "$(matrix_field "$line" verdict)" = "GREEN" ] \
    || fail "the M1 re-proof is not GREEN"
  [ "$(matrix_field "$line" exit)" = "0" ] \
    || fail "the M1 re-proof did not exit zero"
  expect="$(matrix_field "$line" gate_sha256)" \
    || fail "the M1 re-proof names no gate digest"
  require_candidate_digest \
    "$candidate" docs/plans/M1-gate.md "$expect" "the M1 re-proof"

  validate_evidence_lifecycle "$candidate"
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
