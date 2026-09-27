<a id="technical-depth"></a>
## Technical depth

Concept: [M6 minimal runnable Loopex](M6.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M6.md#concept-plan-purpose).

Concept: [Design decisions](M6.md#concept-plan-decisions).

M6 waits on one decision. It is accepted before the implementation that depends
on it, not before unrelated work, and it may not be outstanding at closure. The
repository status check reads the links in this section, so a decision named
only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Before the in-process model adapter, the memory store, the ephemeral composition, named skill directories or the fixed policy revision is written. Outcome 6, the read-only tools and the durable composition's model, bounds, sampling and active-tool options do not wait on it | Outcomes 1 to 5: the two profiles, the memory store's truth statement, one in-process ReqLLM adapter for every provider with credentials read at the model boundary, its guards, one-shot dispatch, call-owned tagged transport and cleanup, the paired vision amendment, the ReqLLM start step, the default model, the skill rule with its two ADR 0025 supersessions, the fixed durable policy revision and its two rollback exceptions, the authority rule, and `ask`'s machine contract |

**The closure prerequisite, satisfied.** M5 closed on 2026-09-26 at the tested
implementation `fe020e24b62504f6f2fbc6c81711f399803b6fa9` (administrative
closure `3f81b04828901a6fb05b29e8b6bed211eed2d376`, tag `v0.2.0`).

**Maintainer decision, 2026-09-26: earlier milestones may be reworked.** The
maintainer authorized M6 to rework code delivered by M1 to M5 where the minimal
profile needs it. Every rework M6 makes is listed in
[Compatibility](#technical-plan-compatibility), and each keeps the M5 suites
and release lanes green. The vision's non-negotiables are not covered by this
decision: dependency direction, one serial owner, durability truth, plain
boundary data, and credential isolation, except as ADR 0039's vision
amendment states.

**Maintainer decisions, 2026-09-26, after the second external review:**
- every model in the ephemeral profile, local or hosted, runs through one
  in-process ReqLLM adapter with guards, and ADR 0039 amends the vision for
  the credential exposure that brings; this replaces the earlier choice to keep
  hosted models on the companion; the durable profile keeps the companion;
- user skill directories are admitted in both profiles, with ADR 0039
  superseding ADR 0025's source and name-order clauses explicitly;
- the durable profile may activate the new read-only tools, and the rollback
  claim is narrowed to name what `0.2` does with them;
- the in-process call and result path are non-streaming and run in one caller,
  while a call-owned tagged pool carries the connection; this is the selected
  M6 implementation boundary and replaces the earlier choices recorded below;
- model calls use HTTP/1, and HTTP/2 is future work gated on Finch.

**The earlier choices, and why they were replaced:** on 2026-09-26 the
maintainer first chose that cleanup walk the call's linked streaming process
tree. Reviews showed that Task startup and teardown leave request-bearing
processes briefly unreachable from any link, so the ReqLLM call became
non-streaming in one caller. A later shared HTTP/1 pool relied on
`Connection: close`; review showed that a request header cannot force peer
closure and that OTP may retain TLS resumption state after a response. The
selected M6 design keeps the one caller but gives every call a unique tagged
HTTP/1 pool, an owner-side one-shot dispatch fence, explicit TLS retention
controls and local pool teardown. The reply still arrives whole, with no
progress deltas. Plan and ADR acceptance remain separate maintainer decisions.

**At acceptance of ADR 0039,** the acceptance change also:
- makes the vision amendment ADR 0039's technical companion states, in all
  seven places together: `docs/vision.md` §12 and §16,
  `docs/vision-technical.md` §6.1, §6.2, §12.7 and §23, and AGENTS.md's
  "Credentials and context" non-negotiable, the last with the maintainer's
  explicit approval;
- updates the ADR index (`docs/adr/README.md`): ADRs 0019's and 0034's rows and
  prose gain "scoped to the durable profile by 0039", and ADR 0025's gain
  "source and name-order clauses superseded by 0039 for named skill
  directories".

All accepted ADR records stay byte-for-byte unchanged.

**Deferrals.** No M6 outcome waits on these, and M6 runs no part of them:

- ADR 0035 stays Proposed and wholly deferred.
- ADRs 0036, 0037 and 0038 stay Proposed as prerequisites of the M7 and M8
  drafts.

<a id="technical-plan-implementation-readiness"></a>
### Implementation Readiness

Concept: [How each outcome is verified](M6.md#concept-plan-verification).

Acceptance is the implementation gate for this plan pair. Before a workstream
starts, an independent adversarial read must find every applicable row below
closed. A remaining choice in one of these rows is a plan defect; an
implementer may choose only private mechanics that preserve the stated
contract.

| Readiness question | Where this pair closes it |
| --- | --- |
| What can a caller supply or observe? | The embedded API and command sections give closed grammars, value domains, return and exit algebras, precedence rules, bounds and profile-specific mappings |
| Which process owns each mutable fact and cleanup obligation? | The API, adapter, composition and failure-boundary sections name the owner, supervision or monitoring relationship, registration point, stop order, retry state and unproved state for every actor |
| Can the locked dependencies perform the design without an unstated route? | The composition bootstrap, adapter and compatibility sections pin OTP application startup plus the ReqLLM, Req, Finch, Mint and NimblePool call paths, options, timers, retry fence, final route and escript/release behavior used by M6 |
| Are trust and credential transitions complete? | ADR 0039 and the adapter contract name every participant, capability, guard boundary, credential read, value check, release proof, poison transition and admitted nonparticipant |
| Can every promised outcome be demonstrated? | The evidence table binds every outcome and boundary to named tests, fixtures, real-provider lanes, retained reviews or demonstrations, including failure injection and exact boundary values |
| Can M6 land without an implicit compatibility decision? | The compatibility, migration, rollback and packaging sections enumerate every M1–M5 rework, retained default, version change, rollback exception and release artifact |

The final planning audit follows the same rows across the Concept and Technical
depth files and the locked dependency source. It fails readiness if two
sections give different answers, a public or decision-bearing rule appears
only in Technical depth, a witness cannot be built with a named seam, or an
implementer would have to select among materially different behaviors. Passing
documentation checks alone is not evidence of implementation readiness.

<a id="technical-plan-ownership"></a>
### Ownership and Rejoin

Concept: [Scope](M6.md#concept-plan-scope).

| Workstream | Owns | Depends on | Rejoin order |
| --- | --- | --- | --- |
| 0. Governance prerequisite | P2's `AGENTS.md` and verification-guide rule for selected unattended release lanes before provider, credential, wire-protocol or daemon merges | Plan acceptance | Before A and before any provider-touching merge |
| A. Model and store | `Loopex.LLM.ReqLLM.InProcess`, its cleanup owner and `OneShotHTTP1` Req adapter, the model-side gate behaviour, the pure mapping it shares with the companion and the shared two-consumer `Deadline` arithmetic, in `apps/loopex_llm_reqllm/lib/loopex/llm/`; ReqLLM's removal from automatic start in `apps/loopex_llm_reqllm/mix.exs`; `Loopex.Store.Memory` in `apps/loopex_store_local/lib/loopex/store/`; the conformance runs for both | ADR 0039 | Foundation; may rejoin before or after B |
| B. Local executor | Every M6 change under `apps/loopex_executor_local`: the executor-side inward gate-client behaviour, ephemeral init-registration and process-proof integration, environment hardening, and `loopex.grep`, `loopex.find` and `loopex.ls`, with their focused tests | ADR 0039 for the private gate contract; otherwise independent of A | Foundation; may rejoin before or after A |
| C. Composition | `LoopexComposition.Ephemeral` (the embedded API, bounded application bootstrap and composition), `LoopexComposition.Application` plus the `mix.exs` `mod:` entry for its one-for-all tree and `prep_stop/1`/`stop/1` handshake, the ReqLLM start step, the composition-side implementation of the model and executor inward gate-client behaviours, the durable `LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` options `:model`, `:bounds`, `:sampling` and `:active_tools` and their fixed policy revision, and `LoopexComposition.ResourcePacks.read_directories/2`, all in `apps/loopex_composition` | A and B for the ephemeral profile; neither for the durable options | After both foundations |
| D. Command | The `ask` subcommand and its `-p` alias, output modes, exit map, correlated ask-mode interrupt API, pre-child signal latch, escript `app: nil` setting and command-aware application bootstrap in `apps/loopex_cli` | C | After C |
| E. Closure tooling and documentation | `mix loopex.closure.confine`, `mix loopex.closure.archive_compare` (in `apps/loopex/lib/mix/tasks/`, beside the existing checks), `scripts/stage-archive-manifest.sh`, `scripts/floor-lane.sh` and `scripts/attended-release.sh` with their fixture tests; P1, P3 and P4; `README.md`, `docs/operator/getting-started.md`, `runtime.md`, `tools-and-policy.md`, `docs/developer/getting-started.md` and its technical companion, `runtime-and-embedding.md`, `compatibility-surfaces.md`; the closure evidence scaffold | Outcome 6 tooling is independent; product documentation follows A through D | Last |

One integrator owns rejoin, conflicts and post-rejoin verification. Parallel
writers use one worktree each with non-overlapping paths. The integrator writes
the acceptance demonstration script (`scripts/m6-demonstration.sh`) first. Each
workstream's rejoin check is the focused witness set in the evidence table for
the boundaries it owns: A and B use their adapter, store, executor and tool
suites; C adds the embedded workflow; D makes the complete four-step
demonstration runnable; and E uses its fixture and documentation checks. The
complete demonstration is expected to remain failing before D and first becomes
eligible for a configured development smoke after D. Its closure evidence is
retained only from the closure candidate on macOS and Linux. The fast check
still runs once for the integrated candidate, not after each rejoin.

<a id="technical-plan-api"></a>
### The Embedded API Contract

Concept: [Scope](M6.md#concept-plan-scope).

**Where it lives.** The module is `LoopexComposition.Ephemeral` in
`apps/loopex_composition`. It is not in core, because composing edges (the
memory store, the model adapter, the executor) is what the dependency direction
forbids core to do. A host depends on `loopex_composition` alone. Core's
runtime library (`apps/loopex/lib` outside `mix/`) is unchanged by M6.

```elixir
@opaque session() :: {:loopex_ephemeral_session, pid(), :atomics.atomics_ref()}
@spec run(String.t(), keyword()) :: {:ok, result()} | {:error, reason()}
@spec start_session(keyword()) :: {:ok, session()} | {:error, reason()}
@spec ask(session(), String.t(), keyword()) :: {:ok, result()} | {:error, reason()}
@spec history(session()) :: {:ok, history()} | {:error, reason()}
@spec answer(session(), String.t(), String.t()) :: {:ok, result()} | {:error, reason()}
@spec last_result(session()) :: {:ok, result()} | {:error, reason()} | :none
@spec stop_session(session()) ::
        :ok | {:error, {:cleanup_unproved, unproved()}} | {:error, :session_unavailable}

@type tool_outcome ::
        "completed"
        | "failed"
        | "denied"
        | "cancelled"
        | "cancelled_workspace_lease_lost"
        | "outcome_unknown"
@type uint64 :: 0..18_446_744_073_709_551_615
@type positive_uint64 :: 1..18_446_744_073_709_551_615
@type observed_quantity :: 0..55_340_232_221_128_654_844
@type tool_projection :: %{tool_id: String.t() | nil, outcome: tool_outcome()}
@type observation(outcome, details) :: %{
        text: String.t(),
        text_truncated: boolean(),
        outcome: outcome,
        profile: :ephemeral,
        session_id: String.t(),
        run_id: String.t(),
        tools: [tool_projection()],
        tools_truncated: boolean(),
        shadowed_skills: [String.t()],
        details: details
      }
@type completed_details :: %{"cleanup_grace_ms" := positive_uint64()}
@type result :: observation(:completed, completed_details())
@type interaction :: %{
        "interaction_id" := String.t(),
        "run_id" := String.t(),
        "turn" := positive_uint64(),
        "tool_call_id" := String.t(),
        "status" := "pending",
        "prompt" := String.t(),
        "choices" := [%{"id" := String.t(), "label" := String.t()}],
        "expires_at" := positive_uint64()
      }
@type history :: %{
        entries: [history_message()],
        truncated: boolean()
      }
@type history_message ::
        %{role: :user | :assistant, text: String.t(), text_truncated: boolean()}
        | %{role: :tool, tool_id: String.t() | nil, outcome: tool_outcome()}
@type startup_cause ::
   {:composition,
         :temporary_root_creation_failed
         | :dependency_start_failed
         | :store_start_failed
         | :workspace_lease_failed
         | :executor_start_failed
         | :trace_capability_start_failed
         | :trace_capability_bind_failed
         | :runtime_start_failed}
        | {:session_create, :failed}
        | {:client_start, :failed}
        | {:attach, :failed}
        | {:resource_admission, :failed}
        | {:skill_activation, :failed}
@type unproved :: %{
        root: String.t(),            # exact kept path, valid UTF-8, at most 65,536 bytes
        root_ownership: :owned | :unknown,
        pending: [
          :run_ending | :effect_cleanup | :process_groups | :session_subtree
          | :gate_release | :root_removal
        ],
        ending:
          {:ok, result()}
          | {:error, run_error() | no_ending_error() | {:interaction_pending, interaction()}}
          | :none,
        cause: startup_cause() | nil
      }
@type failure_details :: %{
        "category" := "deadline_preflight_failed",
        "retryable" := false,
        "dimension" := nil,
        "observed" := nil,
        "limit" := nil
      }
      | %{
        "category" := "context_budget_exceeded",
        "retryable" := false,
        "dimension" :=
          "system_class_tokens"
          | "context_tokens"
          | "context_record_bytes"
          | "context_record_depth"
          | "context_record_cardinality",
        "observed" := observed_quantity(),
        "limit" := positive_uint64()
      }
@type failed_details ::
        %{"reason" := "model_call_failed" | "unreadable_model_answer",
          "failure" := nil, "cleanup_grace_ms" := positive_uint64()}
        | %{"reason" := nil, "failure" := failure_details(),
            "cleanup_grace_ms" := positive_uint64()}
@type bound_details :: %{
        "bound" := "max_turns" | "token_budget" | "deadline",
        "observed" := observed_quantity(),
        "declared_limit" := uint64(),
        "accounting_source" := "reported" | "estimated" | nil,
        "cleanup_grace_ms" := positive_uint64()
      }
@type unknown_details :: %{
        "reconciliation_ref" := String.t(),
        "cleanup_grace_ms" := positive_uint64()
      }
@type cancelled_details :: %{"cleanup_grace_ms" := positive_uint64()}
@type failed_observation :: observation(:failed, failed_details())
@type bound_observation :: observation(:bound_reached, bound_details())
@type unknown_observation :: observation(:outcome_unknown, unknown_details())
@type cancelled_observation :: observation(:cancelled, cancelled_details())
@type run_error ::
        {:run, :failed, failed_observation()}
        | {:run, :bound_reached, bound_observation()}
        | {:run, :outcome_unknown, unknown_observation()}
        | {:run, :cancelled, cancelled_observation()}
@type no_ending_snapshot :: %{
        text: String.t(),
        text_truncated: boolean(),
        profile: :ephemeral,
        session_id: String.t(),
        run_id: String.t() | nil,
        tools: [tool_projection()],
        tools_truncated: boolean(),
        shadowed_skills: [String.t()],
        waited_ms: uint64()
      }
@type no_ending_error ::
        {:timeout, no_ending_snapshot()}
        | {:session_unavailable, no_ending_snapshot()}
@type public_no_ending_error :: {:timeout, no_ending_snapshot()}
@type composition_reason ::
        :composition_application_start_failed
        | :host_policy_required
        | :unknown_provider
        | :hosted_tools_unsupported
        | :ambient_provider_credentials
        | :credential_preflight_failed
        | :credential_tool_gate_unavailable
        | :ephemeral_admission_closed
        | :ephemeral_admission_poisoned
        | :ephemeral_owner_start_failed
        | :ephemeral_owner_registration_failed
        | :credential_call_active
        | :workspace_unusable
        | :temporary_root_unusable
        | :temporary_root_creation_failed
        | :provider_base_url_unsupported
        | :provider_module_replaced
        | :req_default_options_unsupported
        | :ssl_key_log_enabled
        | :req_llm_tidewave_enabled
        | :req_llm_start_failed
        | :req_llm_already_started
        | :req_llm_host_declaration_invalid
        | :req_llm_dotenv_enabled
        | :unclassified_skill_directory
        | :duplicate_skill
        | :skill_directory_unusable
        | :skill_manifest_invalid
        | :dependency_start_failed
        | :store_start_failed
        | :workspace_lease_failed
        | :executor_start_failed
        | :trace_capability_start_failed
        | :trace_capability_bind_failed
        | :runtime_start_failed
        | :session_create_failed
        | :client_start_failed
        | :attach_failed
        | :resource_admission_failed
        | :skill_activation_failed
@type invalid_option_reason ::
        :options
        | :unknown_key
        | :duplicate_key
        | :too_many_skills
        | :policy
        | :model
        | :req_llm
        | :tools
        | :skills
        | :cwd
        | :max_steps
        | :deadline_ms
        | :max_tokens
        | :context_token_budget
        | :timeout
        | :base_url
@type reason ::
        run_error()
        | {:interaction_pending, interaction()}
        | :invalid_interaction_answer
        | {:cleanup_unproved, unproved()}
        | :run_open
        | :session_closed
        | :session_unavailable
        | public_no_ending_error()
        | :interaction_requires_session
        | {:invalid_prompt, :empty | :too_large | :invalid_utf8}
        | {:composition, composition_reason()}
        | {:invalid_option, invalid_option_reason()}
```

`unproved.root_ownership` is `:owned` only after an exact successful exclusive
claim; every ordinary startup or stop failure therefore keeps that value. It is
`:unknown` only for a lost temporary-root claim result, where the named path may
have pre-existed and the error is a diagnostic, never authorization to remove
it. `unproved.pending` is a non-empty, duplicate-free subset emitted in this fixed
order: `:run_ending`, `:effect_cleanup`, `:process_groups`,
`:session_subtree`, `:gate_release`, `:root_removal`. It names every cleanup
obligation the owner reached and could not prove in that attempt; it does not
name a downstream phase that its prerequisites prevented it from entering.
`gate_release` is therefore present only after items 1 through 4 below were
proved and the final gate exchange failed, and `root_removal` is present only
after gate release was proved and removal was not. They never occur together.
Its `ending` describes the current public operation, never an earlier completed
run. It is the exact observed
`{:ok, result}` or `{:error, run_error}` when that run reached a terminal event.
When a prompt or answer may have been admitted but no ending was observed, it
is the exact `{:error, no_ending_error}` snapshot returned to the waiting call.
If the last public value of the current run before stop was a pending
interaction and no later operation was admitted, it is that exact
`{:error, {:interaction_pending, interaction}}`. It is `:none` when there is no
observation for the current operation: the session never had a run, startup
failed before one, the owner registered a validated `ask/3` or `answer/3`
request that then failed before possible prompt or answer admission, or the
current core observation failed the closed projection validation below. The owner
records that internal operation marker when it accepts the validated request,
before calling core, and removes it on an ordinary pre-admission refusal. A
caller-side option, prompt or identifier refusal never reaches the owner, does
not create the marker and leaves its prior `last_result` available to a later
stop. Once the marker exists, a result from an earlier run is never substituted.
`observed_quantity` is wider than `uint64` because the unchanged usage
accounting may add a prior charge of `uint64 - 1` to one reply's two independent
uint64 usage members; `3 * uint64 - 1` is the exact reachable ceiling
(`provider_attempt.ex:557-563`, `session_state.ex:5960-6005`). Declared limits,
waits, turns and cleanup grace remain uint64.

**Options.** `run/2` and `start_session/1` accept a proper keyword list whose
closed key set is the table below, with each key present at most once. An
unknown key returns `{:error, {:invalid_option, :unknown_key}}`, a duplicate
key returns `{:error, {:invalid_option, :duplicate_key}}`, and a
non-keyword list or non-list returns `{:error, {:invalid_option, :options}}`.
Except for the separately named missing-policy and too-many-skills errors, a
value outside its stated type or bound returns
`{:error, {:invalid_option, key}}`. A well-shaped value that fails the later
provider, workspace or skill guard returns that guard's named composition
error. Validation finishes before a temporary root, dependency or session
starts.

| Option | Accepted value and meaning | Default |
| --- | --- | --- |
| `:policy` | Required non-nil module atom that loads and exports `decide/1`, the `Loopex.Policy` callback, and whose `inspect/1` result is valid UTF-8 from 1 through 256 bytes so the derived policy identity is constructible in core's released domain. A non-atom, unloadable module, module without `decide/1` or longer derived identity returns `{:invalid_option, :policy}`. Composition ships no policy of its own, because host policy belongs to the host. The `ask` command maps its policy names to the reference CLI's policy modules | none; omission refuses `{:composition, :host_policy_required}` |
| `:model` | Valid UTF-8 `provider:model` string of 1 to 512 bytes, split at its first colon, with a non-empty provider prefix and non-empty remainder as the model id; later colons belong to the id, so `ollama:name:tag` is valid. The later provider guard admits the four prefixes ADR 0039 names and returns `{:composition, :unknown_provider}` for any other well-shaped prefix | `LOOPEX_MODEL`, else `"ollama:llama3.2"`; the selected default is validated identically |
| `:req_llm` | Exactly `:host_started`, declaring that the host started ReqLLM itself with `.env` loading off; explicit `nil` is invalid | omitted, so Loopex performs the guarded start |
| `:tools` | Exactly `:none`, `:coding` (`read`, `write`, `edit`, `bash`) or `:read_only` (`read`, `grep`, `find`, `ls`). Only presets are accepted because their projections carry the ADR 0017 system-class witness. A credential-bearing hosted model accepts only `:none`; either active preset refuses `{:composition, :hosted_tools_unsupported}`. With credential-free Ollama, an active preset additionally requires all three supported hosted-provider variables unset, or refuses `{:composition, :ambient_provider_credentials}` | `:coding` |
| `:skills` | Proper list of zero to four non-empty valid UTF-8 path strings, each at most 65,536 bytes and containing no NUL, reusing the named-resource path ceiling (`resource_packs.ex:27`, `:957-964`); paths are expanded relative to the validated `:cwd`, then the named-directory rules validate and classify them. Five or more returns `{:invalid_option, :too_many_skills}` | `[]` |
| `:cwd` | Non-empty valid UTF-8 path string of at most 65,536 bytes with no NUL, reusing the same path ceiling and resolving to an existing directory; workspace root for every tool and for skill classification | the result of `File.cwd/0`; inability to read or resolve it refuses `{:composition, :workspace_unusable}` |
| `:max_steps` | Positive unsigned 64-bit integer, mapped to the runtime bound `max_turns`; composition deliberately narrows core's wider integer domain so every public option and retained bound is bounded | 16 |
| `:deadline_ms` | Positive unsigned 64-bit integer, mapped to the runtime bound `deadline_ms` | 600_000 |
| `:max_tokens` | Integer from 1 through 1,000,000, mapped to sampling `"max_tokens"` and matching `Loopex.Model`'s request domain (`model.ex:368-372`) | 4_096 |
| `:context_token_budget` | Positive unsigned 64-bit integer, the runtime's required budget | 8_192 |
| `:timeout` | Positive unsigned 64-bit integer milliseconds for waiting for `run.finished`; the owner measures one monotonic deadline and polls in 10 ms slices, never passing the whole value to a BEAM receive or timer | `:deadline_ms` plus 30_000, saturating at the unsigned 64-bit maximum |
| `:base_url` | Non-empty valid UTF-8 string of at most 65,536 bytes with no NUL, reusing the composition's bounded-text ceiling. The later address guard requires the exact byte grammar and canonicalization under **Provider routes**: lowercase `http` or `https`; canonical IPv4 or bounded ASCII DNS host; optional canonical port 1 through 65,535; no user information, query, fragment, IPv6, Unicode host, escape, backslash, repeated interior slash or dot segment; and only empty or slash-prefixed unreserved path segments. DNS is lowercased, default ports and trailing slashes are removed. A credential-bearing provider additionally requires HTTPS. Any failure returns `{:composition, :provider_base_url_unsupported}`. The normalized value is always passed to ReqLLM explicitly | the built-in provider module's `default_base_url/0`, never ReqLLM's application configuration or catalog; the selected default passes both validations |

The third argument of `ask/3` is a separate closed keyword list: it accepts only
one optional `:timeout` with the same domain, overriding the session's wait for
that ask only. Every model, policy, tool, skill, workspace, bound, sampling and
address choice is fixed by `start_session/1`; trying to pass one again, any
other key, a duplicate `:timeout`, or a malformed options term returns the same
`invalid_option` form without sending a session command.

**Boundary precedence.** `start_session/1` validates the outer option term,
unknown and duplicate keys, then option values in the table's order before any
filesystem or composition guard. `run/2` performs that complete option pass,
then prompt validation, then helper and composition guards. `ask/3` first reads
the handle cell and owner liveness (`session_closed` or `session_unavailable`
wins), then validates its ask-option term/key/value, then the prompt, then asks
the live owner to apply `run_open` and admission. `answer/3` applies the same
lifecycle check, then validates both identifier shapes before it compares the
current interaction and offered choices. `last_result/1`, `history/1` and
`stop_session/1` apply only the lifecycle check before their owner request.
These orders also govern combinations of errors; no branch chooses by map or
keyword enumeration order.

After value validation, `start_session/1` and `run/2` apply composition checks
in this exact order, and the first failure wins: resolve and verify `:cwd`;
invoke the named-directory helper on the complete `:skills` list; split and
admit the model's provider prefix; map it through the fixed prefix-to-expected-
module table; apply the hosted-tools rule and the pre-start Req default-options,
`SSLKEYLOGFILE` and Tidewave guards; run the bounded
`loopex_composition` application bootstrap and obtain its exact live gate;
complete the ReqLLM-start hygiene decision;
verify that the now-initialized registry maps the prefix to that exact module;
select the explicit `:base_url` or call that verified module's
`default_base_url/0`, then normalize it; reserve, start and exchange the still-root-blocked owner
at the scheduling gate; for an active Ollama preset acquire its tools lease and
then run the sensitive ambient-variable preflight; repeat the global, provider
and address guards; obtain the gate-issued root-start token; then create the
root and private subtree. A later phase never runs after an earlier refusal.
Any failure after owner exchange uses the bounded no-root cancellation handshake
until the gate issues that token. Combined-fault tests cover every adjacent
pair—including pre-start guard versus application bootstrap and application
bootstrap versus ReqLLM hygiene—and policy omission together with bad prompt,
skill, provider and hygiene inputs.

A hosted model needs its provider's own credential variable set in the host's
environment, which the calling process reads at each call, and the `:none` tool
preset. For Ollama, either active preset also requires every supported hosted
provider variable unset. Within the ephemeral composition's participants, no
active-tool session overlaps its owned credential caller or pool; the durable,
direct-executor, trusted-host and post-quarantine transport limits are stated
below.

**Semantics:**

- **Prompt boundary.** `run/2` and `ask/3` accept a non-empty valid UTF-8 prompt
  of at most 32,768 bytes. This leaves a fixed half of the Store's 65,536-byte
  item ceiling for the command and event envelope. They refuse
  `{:error, {:invalid_prompt, reason}}` before composition or a session command
  for `:empty`, `:too_large` or `:invalid_utf8`. The check order is zero bytes,
  then byte size above 32,768, then UTF-8 validity, so an oversized invalid byte
  string is `:too_large`.

- **`run/2`** validates its prompt and session options, then is
  `start_session/1`, `ask/3` and `stop_session/1`. A validation or startup
  error returned before a handle exists—including startup rollback whose root
  removal is unproved—returns unchanged; there is no handle on which to invent
  a stop. Once `start_session/1` returns a handle, the stop is always performed.
  A pending interaction cannot survive this one-shot form:
  after stopping it returns `{:error, :interaction_requires_session}` rather
  than an already-stale interaction. A host that may answer a deferral uses
  `start_session/1`, `ask/3` and `answer/3`. It retains both the first call's
  result and any `cleanup_unproved` map while it performs the mandatory stop;
  precedence is closed:
  1. a `cleanup_unproved` returned by that stop is the final return;
  2. if the first call already returned `cleanup_unproved` and a retrying stop
     succeeds, `run/2` returns the exact `ending` retained in the first map
     (a pending interaction maps to `interaction_requires_session`, and
     `:none` maps to the proved-cleanup bare `:session_unavailable` lifecycle
     error);
  3. if the first call returned `cleanup_unproved` and the permanent failed
     owner makes the following stop bare-unavailable, `run/2` preserves the
     first cleanup map, which is the only public value that names the root;
  4. otherwise a bare-unavailable stop overrides the earlier value as the bare
     `:session_unavailable`, except for the proved-cleanup case below; and
  5. after an ordinary successful stop, the first result is returned, with a
     pending interaction mapped to `interaction_requires_session`.

  Thus the caller always learns of a known kept root and never receives a stale
  cleanup failure after a successful retry. A post-admission session loss before
  a terminal event cannot satisfy the run-ending cleanup obligation: `ask/3`
  returns `cleanup_unproved` with the bounded
  `{:session_unavailable, snapshot}` as its `ending`. This missing-terminal
  branch is permanently unproved, so its following stop is bare unavailable
  and rule 3 preserves the earlier map. Rule 2 applies only to a cleanup error
  whose pending obligations are retryable. Any other
  bare-unavailable stop means an intervening unmarked owner exit left no new
  public cleanup proof, so rule 4 returns the bare lifecycle error.
- **`start_session/1`** composes the ephemeral profile and starts one runtime,
  creates one session with `%{"surface" => "embedded"}` and `command_id`
  `"create"`, requires exact `{:ok, session_id}`, and attaches from sequence 0.
  The session value is opaque:
  `@opaque session() :: {:loopex_ephemeral_session, pid(),
  :atomics.atomics_ref()}`. A host holds it and passes
  it back, and inspects nothing inside it; it is an in-VM handle like a runtime
  reference, never boundary data, and no public or durable contract carries it.
  Behind it is a supervised owner process that monitors, but is never linked
  to, the process that called `start_session/1`. The owner holds the runtime
  and the one attachment (`Runtime.attach` binds an attachment to its caller,
  `runtime.ex:346-348`); every call below goes through the owner. Each public
  call monitors the owner for the duration of its request and converts an owner
  `DOWN` or request exit into the lifecycle result proved by the handle cell,
  without changing the caller's trap-exit flag. What a host
  may read about the session comes from a terminal observation, `history/1`
  and `last_result/1`: every terminal observation carries `session_id` and
  `profile`. The opaque
  handle also contains one private `:atomics` cell, initially open. It is
  neither boundary data nor global state and carries no request or credential.
  The application DynamicSupervisor starts each owner with
  `restart: :temporary`, so neither a successful stop nor a crash creates a
  replacement owner for the same handle.
- **Scheduling-subtree lifetime.** Before creating a temporary root, every
  owner records and monitors the exact gate, application supervisor and owner
  DynamicSupervisor PIDs supplied through its start handoff. It retains those
  monitors for its whole lifetime and never rediscovers a replacement by name.
  An `EXIT` or `DOWN` from any of the three, or a gate reply whose incarnation no
  longer matches, closes admission, rejects new API work, performs the same
  bounded session-failure cleanup and exits unmarked; waiting callers receive
  the applicable admission-state result and later handle calls are unavailable.
  A retained root is host-logged when no waiter can receive it. Thus killing the
  shared owner DynamicSupervisor cannot leave a scheduled owner deliberately
  running without its gate capability. A suspended owner may not process the
  monitor before the startup refusal returns; its untrappable kill or monitor-
  driven cleanup completes when it is scheduled, while the poisoned gate and
  required VM restart prevent new ephemeral work.
- **Core client actor.** The owner never makes a potentially unbounded public
  facade call itself. Before it creates any linked helper, the owner sets
  `Process.flag(:trap_exit, true)` and retains that setting for its lifetime.
  After the runtime starts it creates one linked and
  monitored, non-restarting `FacadeClient` actor. That actor calls
  `Loopex.create_session/3`, with `%{"surface" => "embedded"}` and bounded
  `command_id` `"create"`, then `Loopex.attach/3`, `Loopex.command/2`,
  `Loopex.resource_catalog/2`, `Loopex.session_status/2` and
  `Loopex.next_event/1`; it remains alive for the session and is the attachment
  holder and sole `next_event/1` caller. The owner sends one operation at a time
  as `{owner_pid, ref, operation}` with a fresh reference. The actor replies
  `{self(), ref, :ready}` and remains start-blocked. The owner requires that
  reply within an admission-handshake deadline 1,000 ms from the send, or the
  remaining enclosing lifecycle deadline when shorter. Only after the owner has
  serialized any stop or borrower `DOWN` and recorded the operation as possibly
  admitted does it compute an absolute operation deadline and send
  `{owner_pid, ref, :dispatch, operation_deadline}`. The actor accepts that
  grant only from its recorded owner and for its current reference, enters the
  facade, then sends `{self(), ref, result}`. The owner accepts only tuples
  carrying the recorded actor PID and matching reference. Actor-operation and
  public-wait deadlines are distinct. Startup, catalog, status, prompt and
  answer facade operations each get a 5,000 ms absolute operation deadline
  computed when the owner sends the dispatch grant; an event poll gets 1,000 ms
  from its grant.
  Those operation deadlines are never shortened by the borrower's wait timeout.
  Abort and cleanup-time commands use only the remaining cleanup deadline. The
  public wait deadline controls when the borrower receives a timeout and when
  work changes from attended following to the same owner's background state; it
  does not kill or duplicate an already granted actor operation. All waits are
  sliced and the owner remains in its receive loop.

  Before the owner sends the dispatch grant, an expired handshake deadline,
  cancellation or borrower `DOWN` sends `{owner_pid, ref, :cancel}`. Signals
  from the one owner reach the actor in send order, so an actor that has not yet
  handled the operation consumes it first, remains blocked, then consumes the
  cancel. It accepts the cancel only from the recorded owner, clears the
  operation, replies `{self(), ref, :cancelled}` and remains the session client;
  the owner accepts that acknowledgement even if `:ready` is still in its
  mailbox. Only that matching acknowledgement lets the owner classify no
  possible core effect. The cancellation acknowledgement has its own deadline
  1,000 ms from the cancel send, or the remaining cleanup deadline when shorter;
  it never refers to an operation deadline that has not begun. If the actor does
  not acknowledge, the owner sends an untrappable kill and awaits it only to the
  enclosing lifecycle deadline. A missing `DOWN` remains a retained
  `:session_subtree` obligation on the pre-admission session-failure path. Once
  the owner sends the grant for a mutating command,
  admission is conservatively possible even if the actor never enters the
  facade or never returns; killing the actor does not retract a coordinator call
  already sent. Mailbox ordering between the borrower and actor therefore cannot
  create a false pre-admission classification: the owner itself owns the one
  transition.
  An actor-operation timeout or actor `DOWN` makes its result inadmissible and
  sends the actor an untrappable kill. Exact `DOWN` is required before subtree
  stop, but only within the current lifecycle deadline; otherwise the monitor is
  retained as `:session_subtree` for a caller-visible retry. A possibly admitted
  prompt or answer therefore takes the no-ending
  cleanup path; a startup command failure rolls back without ever admitting a
  prompt. Actor loss also ends its attachment, so the owner never reattaches or
  invents unseen events. The actor is an explicit fifth owned session process
  outside the private edge subtree; cleanup proves it `DOWN` before the cleanup
  worker stops the runtime and subtree. Its link and an already-sent kill make it
  end when scheduled after unexpected owner death, while the owner's monitor
  gives the normal proof. A deliberately suspended actor may temporarily
  outlive a bounded failure return or owner exit, but it has no admissible result
  or new-operation grant. The owner correlates both `EXIT` and `DOWN` from this
  actor; an abnormal exit is a session-path failure, while a forced cleanup
  kill cannot kill the trapping owner before it records the actor's `DOWN`.
- **`ask/3`** refuses with `{:error, :run_open}` while an earlier run of the
  session has no `run.finished`, for example after `interaction_pending`.
  It also reserves the session's one public-mutation slot as soon as the owner
  accepts a validated ask, before it sends the `FacadeClient` operation. While
  that slot is reserved, a second ask immediately returns `{:error, :run_open}`
  without entering a queue or starting its public wait deadline. A pre-grant
  cancellation or exact command refusal releases the slot; possible admission
  keeps it reserved until the resulting run reaches its next permitted state.
  Otherwise the owner installs a monitor for that request's caller before it
  admits work, removes it after the reply wins serialization, and:
  1. sends a prompt with the next ephemeral command identifier defined below;
  2. joins that command to its run through the `user.message_appended` event,
     which carries both `command_id` and `run_id` (`session_state.ex:4387-4396`);
  3. follows the attachment the way `LoopexCli.Render.follow` does, polling
     `next_event/1` at a 10 ms interval while it answers `{:error, :empty}`,
     until the `run.finished` with that `run_id`, or the wait timeout.

  Its results:
  - `completed` returns `{:ok, result}`, where `text` is the last
    `assistant.message_appended` content for that `run_id`.
  - Every other outcome returns
    `{:error, {:run, outcome, observation}}`. The observation repeats the
    tagged outcome, carries the same bounded text, tool and skill projection as
    a completed result, and contains the fixed outcome-specific `details` map.
    The tuple tag, `observation.outcome` and `observation.details` variant must
    agree. No other combination is public.
  - When the step limit is reached this is
    `{:error, {:run, :bound_reached,
    %{outcome: :bound_reached, details: %{"bound" => "max_turns", ...}, ...}}}`.
  - An `interaction.requested` event for that run (a policy that defers)
    returns `{:error, {:interaction_pending, interaction}}` and leaves the run
    open. The interaction is exactly `Loopex.Interaction.view/1` for the pending
    record: eight fixed string-keyed members, a 1-to-256-byte valid UTF-8
    `interaction_id` and `run_id`, a positive `turn`, a 1-to-65,536-byte valid
    UTF-8 `tool_call_id`, literal status `"pending"`, a 1-to-2,048-byte valid
    UTF-8 prompt, one to eight choices whose unique ids are 1 to 64 bytes and
    whose labels are 1 to 256 valid UTF-8 bytes, and a positive unsigned 64-bit
    `expires_at`. The ephemeral boundary validates all eight members, the
    complete choices list and the numeric domains after `Interaction.view/1`;
    it does not trust the unchanged core's raw wall clock or replayed integers.
    An invalid `turn`, `expires_at` or other member is never exposed and follows
    the unexpected post-admission session-failure cleanup path below. `ask/3`
    does not answer on its own. The host answers with
    `answer(session, interaction_id, choice_id)`, where `interaction_id` is the
    byte-identical 1-to-256-byte identifier from that interaction and
    `choice_id` is the byte-identical identifier of one of its offered choices,
    at most 64 bytes as `Loopex.Interaction` requires
    (`interaction.ex:15-17`, `:32`). The
    owner sends those two strings plus a fresh bounded command id as the
    complete `%{type: :interaction_answer, command_id:, interaction_id:,
    choice_id:}` command and requires exact `{:accepted, same_id}` before
    clearing the pending observation. A malformed identifier, an unknown or stale
    interaction, or a choice the interaction did not offer returns
    `{:error, :invalid_interaction_answer}` without resolving the question.
    Accepting one validated answer reserves the same public-mutation slot before
    the actor handshake. While it is reserved, every second answer immediately
    returns `{:error, :invalid_interaction_answer}` without entering a queue or
    starting its public wait deadline; an ask returns `{:error, :run_open}`.
    Exact pre-grant cancellation or command refusal restores the still-pending
    interaction and releases the slot. Possible admission retains the slot
    through the next question or terminal ending.
    After admission, `answer/3` follows the same run until its next
    `interaction.requested`, terminal `run.finished`, or the session's wait
    timeout, with the same per-request caller monitor and dead-borrower rule as
    `ask/3`. It therefore returns another `interaction_pending` for each of ADR
    0024's two permitted answer-then-defer transitions, or the same terminal
    result or error algebra as `ask/3`; a fourth question is denied by core.
    On acceptance of a new prompt before its caller timed out, the owner
    atomically clears the prior `last_result` to `:none` before it begins
    following that run. Acceptance after that caller already received timeout
    retains the timeout snapshot until a question or ending replaces it. The
    same rule applies to an interaction answer: timely acceptance clears the
    answered pending interaction to `:none`; late acceptance retains the
    timeout snapshot. `last_result/1` is a
    non-consuming snapshot of the current run: it is `:none` before that run's
    next question or ending, the exact `interaction_pending` while the current
    question remains unanswered, and the run's result or error after terminal
    observation. It never returns an answered question or an observation from
    an earlier run. The next `ask/3` remains `:run_open` until the prior run
    ends even while `last_result/1` is `:none`.
- **Timeout continuation.** The session owner is the sole attachment reader.
  The owner selects public expiry when its receive loop first observes the
  monotonic wait deadline reached; only an actor result already dequeued and
  validated before that observation precedes it. A merely queued or later actor
  result belongs to the continuation. When `ask/3` or `answer/3` reaches that
  wait timeout, it returns
  `{:error, {:timeout, snapshot}}`. The snapshot carries `profile`,
  `session_id`, the joined `run_id` when learned or `nil`, `waited_ms`, and the
  same bounded text, tool and shadowed-skill projection as a terminal
  observation.

  Before the owner has granted the prompt or answer, expiry records no possible
  admission, returns a snapshot with `run_id: nil`, sends the exact actor cancel
  and waits for its acknowledgement in owner state; it does not change
  `last_result`, so an unanswered interaction remains visible, and another ask
  is admitted after cancellation completes when no prior run is open. After the grant but before
  the command returns, expiry conservatively records a possibly open run,
  returns the same `run_id: nil` snapshot and leaves the one actor call running
  to its independent operation deadline; another ask returns `run_open` until
  that call resolves, while `last_result` still holds the pre-command value.
  Exact later acceptance enters background following and then stores the timeout
  snapshot until a question or ending replaces it. Exact later refusal preserves
  the pre-command value and admits a later ask when no prior run is open. A malformed return, actor-operation
  timeout or actor loss takes the no-waiter session-failure path and publishes no
  second result.

  After command acceptance, expiry includes every event the owner dequeued first
  and changes any in-flight event poll into background ownership without killing
  it. The owner keeps one scheduled
  10 ms drain loop over that same attachment, with no concurrent
  `next_event/1` caller, until it observes the run's next interaction or
  terminal ending. Until then `last_result/1` returns the same timeout snapshot;
  afterward it returns the pending interaction or terminal result. A question
  ends the background drain but not the run: a next `ask/3` still returns
  `:run_open` until that question is answered and the run eventually reaches
  `run.finished`. Only a terminal observation permits a new prompt. Stop cancels
  a scheduled poll that has not been submitted. An ungranted actor operation is
  canceled through the acknowledgement handshake. A granted poll, prompt or
  answer is allowed to return under the earlier of its independent operation
  deadline and the cleanup deadline; the owner consumes that result only to
  establish whether a run exists, then reuses the still-live actor for abort.
  Exit of the process that created the session
  takes the stop path. Exit of a different process waiting on this request
  removes that waiter: before the owner sends the actor's dispatch grant the
  request is discarded; after that conservative possible-admission boundary the owner
  lets the one command resolve, with no timeout snapshot invented for the dead
  process. Refusal preserves the pre-command `last_result`; acceptance clears it
  to `:none` and enters the same sole-reader background drain. While the granted
  command is unresolved or the accepted run is open, a next ask is `:run_open`;
  after acceptance, `last_result/1` is `:none` until the next question or ending;
  afterward the creator can read the new observation. If that no-waiter drain
  fails, or if the private subtree fails while no request is waiting, the owner
  takes the no-waiter cleanup path below: it invents no snapshot, leaves no new
  `last_result`, logs any retained root, and exits unmarked. No background
  drainer outlives the session owner.
- **Unexpected command or attachment failure.** The owner exhaustively handles
  the documented `Loopex.command/2` and `next_event/1` results. Expected command
  rejections map only to the public reasons above. An attachment
  `{:disconnected, last_sequence}`, any other attachment error, or an unexpected
  command return cancels the drain loop and enters the same bounded stop and
  cleanup path; M6 does not silently reattach because it cannot prove which
  events a failed attachment delivered. If cleanup proves, a failure before a
  prompt is sent returns the bare `:session_unavailable` form. If that cleanup
  is unproved, `cleanup_unproved` overrides the bare lifecycle error, names the
  retained root and has `ending: :none`. Once a prompt may have been admitted,
  a failure before a terminal event constructs
  `{:error, {:session_unavailable, snapshot}}`, where `snapshot` has the same
  closed partial projection as a timeout and `waited_ms` is the elapsed
  monotonic wait, but that value is only `cleanup_unproved.ending`: without the
  terminal event the run-ending obligation cannot be proved. The waiting call
  therefore receives the closed `cleanup_unproved` value and its retained root;
  it never receives that no-ending error directly. The owner then exits without
  marking the handle stopped, and later calls return the bare atom. No
  error leaves a scheduled poll or permanently open run behind. If the failure
  instead occurs in the owner's background drain after the earlier public call
  already returned a timeout, there is no waiting caller to receive a second
  snapshot. The owner takes the same cleanup path, cancels the poll and exits
  unmarked; the earlier timeout remains the only public observation and later
  calls return the bare atom. An unproved cleanup in that no-waiter path logs
  the retained root and pending obligations to the host logger before exit, as
  the caller-exit path does. The standalone `ask` VM suppresses that logger, so
  this limitation can leave an unnamed retained root there.
- **Observation boundary.** The `text` in a completed result, run-error
  observation or no-ending snapshot is at most 65,536 bytes, cut at a valid UTF-8
  boundary with `text_truncated: true`. Its `tools` contains at most
  the 256 most recent `tool.finished` projections for the run in
  `event_sequence` order and marks omitted older entries with
  `tools_truncated: true`. `shadowed_skills` contains at most four names.
  The text ceiling is defensive: the unchanged kernel admits the entire raw
  model reply and each assistant event through the Store's 65,536-byte item
  envelope, so an integrated valid event is necessarily smaller. A pure
  projection-unit witness exercises 65,536/65,537 and a split multibyte code
  point; the runtime witness proves valid events are projected without claiming
  an impossible 64 KiB assistant payload.
  Before exposing a completed result, run error, interaction or no-ending
  snapshot, the boundary validates every numeric member against the type above:
  positive turns, expiry and cleanup grace; unsigned-64-bit declared limits and
  waits; and non-negative observations no greater than
  `3 * uint64 - 1`. It converts the monotonic elapsed wait to `waited_ms` with
  saturation into the unsigned-64-bit domain. It never clamps or publishes a
  malformed core terminal or interaction value. A mismatch is a session-path
  failure whose selected public value is the bare `:session_unavailable`, never
  a fabricated no-ending snapshot. The owner does not update `last_result`,
  performs the same bounded stop and exits unmarked. Proved cleanup returns the
  bare value to a waiting caller. Unproved cleanup overrides it with
  `cleanup_unproved` and `ending: :none`; a malformed terminal is not a valid
  `run.finished` for cleanup item 1, leaves `:run_ending` rather than
  `:effect_cleanup` pending for items 1 and 2, and prevents item 2 from being
  evaluated. Independently reached later process or subtree failures still
  combine in their fixed order. A malformed
  interaction may still be aborted and cleaned normally. After a prior public timeout there is no waiting caller and
  only the already-returned timeout remains observable.
  Every identifier and detail string in an observation, `history` or no-ending
  snapshot is non-empty valid UTF-8 and at most 1,024 bytes, except an
  explicitly nullable member and the separately bounded interaction fields.
  Each non-null projected `tool_id` is the resolved definition id from
  `tool.finished`, not the provider's `tool_call_id`, and is at most 128 bytes.
  It is `nil` only when core recorded an unresolved tool call with no definition
  id; the raw model-supplied name is not substituted. Runtime and
  session identifiers are already at most 256 bytes (`runtime.ex:35`,
  `:777`), tool ids at most 128 bytes (`tool_definition.ex:79`, `:447-456`),
  defined tool ids at most 128 bytes, skill names at most 64 characters, and reconciliation references are the
  runtime's fixed stable id. The projection validates those source invariants;
  it never truncates an identity. An impossible oversized or invalid identifier
  enters the unexpected-session-failure cleanup path and returns
  `session_unavailable` or `cleanup_unproved` rather than emitting a malformed
  public value.
- **`history/1`** returns at most the 256 most recent committed conversation
  entries projected from the public events, in `event_sequence` order, as
  `%{entries: entries, truncated: boolean}`. `truncated` is true when older
  entries were omitted. User and assistant text is at most 64 KiB per entry,
  cut at a UTF-8 boundary with `text_truncated: true`:
  - `%{role: :user, text:, text_truncated:}` from `user.message_appended`;
  - `%{role: :assistant, text:, text_truncated:}` from
    `assistant.message_appended`;
  - `%{role: :tool, tool_id:, outcome:}` from `tool.finished`.
  The per-text history ceiling is the same defensive projection bound and is
  unit-tested separately from the Store-constrained integrated history.
  It remains callable while an ask, answer or timeout continuation is active:
  the owner serializes the request, projects the committed public events known
  at that instant, and resumes its scheduled drain. It neither calls
  `next_event/1` nor creates a second attachment reader, and it never waits for
  the current run to finish.
- **`stop_session/1`** coalesces concurrent stops at the owner. Acceptance of
  the first stop atomically enters `stopping`. Every later stop joins that one
  cleanup attempt and receives the same selected return. Every non-stop API
  request serialized after the transition is answered immediately with
  `{:error, :session_unavailable}`; it never queues behind cleanup or starts
  work. A request serialized before the transition completes under its ordinary
  rule, including the admission-specific resolution below for an already
  registered ask or answer. After successful
  cleanup and root removal, the owner atomically marks the
  handle stopped immediately before replying `:ok`, then exits; a later stop
  reads that cell and returns `:ok` without a tombstone process. Other API calls
  on it return `:session_closed`. A dead owner whose cell is still open is an
  unexpected crash and returns `:session_unavailable`, never false success.
  Stop first marks every caller-facing result for the current ask or answer as
  closed, but it does not make a granted actor result inadmissible. An ungranted
  operation is canceled and acknowledged. For a granted event poll, prompt or
  answer, stop waits only to the earlier of that operation's existing deadline
  and the cleanup deadline. A returned poll is interpreted normally; a returned
  prompt or answer is validated as accepted or refused solely to update the
  run-admission state. No result is delivered to the superseded borrower. A
  refusal with no prior run proceeds directly to cleanup; acceptance or an
  already-open run proceeds to abort. An operation timeout, malformed return or
  actor `DOWN` sends the actor an untrappable kill and waits only to the cleanup
  deadline. A missing `DOWN` preserves both the corresponding possible-run and
  `:session_subtree` obligations; it does not start a replacement actor or claim
  that abort ran. The creator-`DOWN` path uses this same state machine.
  Thus an ordinary stop never destroys the sole command attachment before it
  has used that attachment for any required abort. The abort/run-ending and
  core-actor phase must finish by `cleanup_started_at + cleanup_grace_ms`; the
  fixed additional 5,000 ms is reserved for the bounded phases below.

  If a run is open, stop sends the complete `%{type: :abort, command_id:}` with a
  fresh bounded id, requires exact `{:accepted, same_id}` to classify it as
  admitted, and waits for that run's `run.finished`, whatever its outcome. A
  refused, malformed, mismatched, lost or actor-failed reply follows the same
  pre-/post-`:dispatching` admission algebra as prompt and answer. The
  terminal event may win the race before the abort is admitted; an admitted
  abort can end `cancelled` or `outcome_unknown`. It waits for at most the
  session's committed `cleanup_grace_ms` plus 5_000 ms. The owner records that
  one saturating monotonic deadline when cleanup begins; abort, process-group
  proof, runtime stop, subtree stop and worker reap all consume the same budget
  in slices no longer than 1,000 ms. It never calls the locked
  `Loopex.stop/1` or `Supervisor.stop/3` synchronously, because both may wait
  without a finite caller timeout. After the last required attachment event or
  an actor timeout, it ends and awaits the core client actor first within that
  same deadline; loss of that actor before `run.finished` leaves `:run_ending`
  unproved, and missing actor `DOWN` prevents every later cleanup phase in that
  attempt. Only after actor `DOWN` does the exit-trapping owner run an explicit
  ordered phase set: `:process_groups` when an executor exists and that phase
  has never been reached, then `:runtime_stop` while the
  runtime is live, then `:subtree_stop` while the private subtree is live. An
  already proved process-group phase is queried from the gate and not run
  again; a previously reached but unproved process-group phase is permanent and
  is also not rerun.

  Each present phase gets its own request-free, credential-free, linked and
  monitored non-trapping worker; no worker calls more than one blocking API. A
  phase occupies at most one 1,000 ms slot under the common deadline. Its
  operation cutoff is 500 ms after that phase starts or the common deadline,
  whichever is earlier; an in-time provisional result must be validated,
  followed by correlated `finish` and exact normal `DOWN` within the remainder
  of the slot. At the operation cutoff, a missing, malformed or late result
  causes an untrappable kill; the owner awaits exact `DOWN` in bounded receives
  until the slot ends and performs one zero-wait receive there. A caught return,
  refusal, raise, throw or exit whose exact worker `DOWN` is proved records that
  phase's failure and still starts the next independent phase. A timed-out
  worker whose exact `DOWN` is proved likewise leaves its phase unproved and
  permits the next phase. Missing worker `DOWN` retains that monitor and
  `:session_subtree`, prevents every later phase in that attempt and forbids
  success or root removal, because the blocking call may still be active.

  The three phase slots, final gate exchange and root removal consume at most
  the fixed additional 5,000 ms; absent phases are skipped rather than slept.
  The owner remains responsive and trusts only the gate's bound process-group
  proof and the child/root monitors recorded during startup, never a worker's
  cleanup claim. Owner death sends the same kills through the workers' links.
  The owner correlates every worker `EXIT` and `DOWN`; an abnormal exit is not
  cleanup proof, and a forced kill cannot terminate the owner before it samples
  the retained monitors and selects the result.

  Every accepted caller retry, and the creator-exit final retry, records a fresh
  saturating monotonic deadline `now + cleanup_grace_ms + 5_000`; it never
  reuses the expired first-attempt deadline. A retry constructs its phase set
  from retained reached/proved state. It never requests a reached process-group
  proof again after failure or after the executor or subtree may have ended. If
  a prior phase worker is still missing `DOWN`, the owner first reissues its
  untrappable kill and awaits that exact retained monitor in bounded slices. If
  the recorded core client actor is still missing `DOWN`, it does the same for
  that actor. No later phase or removal worker starts until every retained actor
  and phase-worker monitor is proved `DOWN`; a missing `DOWN` keeps item 4
  pending as `:session_subtree`. Once those processes are proved down, the owner
  recomputes the ordered set. It first runs `:process_groups` when an executor
  exists, the proof is absent and that phase was never reached because the actor
  or an earlier phase worker blocked it; it then runs the still-pending runtime
  and subtree phases with the same per-phase protocol. If only
  `:root_removal` is pending, no cleanup phase worker starts. The gate keeps an accepted
  proof nonce and its executor-PID, instance and lease binding queryable after
  worker, executor and subtree `DOWN`. It deletes that
  record only as part of the gate's acknowledged, correlated
  final-cleanup-disposition commit; owner `DOWN` before that commit converts the
  registration and its children to orphan obligations rather than deleting
  them.
  This lets the owner validate the nonce after its phase worker ends and lets a
  subtree-only retry preserve the already-proved group fact. The owner attempts recursive
  root removal only after every phase worker and recorded child and
  subtree root are `DOWN`, and returns `:ok` only when all five cleanup
  obligations are proved and removal succeeds:
  1. the open run's structurally valid, matching `run.finished` arrived; this
     requires the fixed event identity and every public terminal member to pass
     the observation-boundary validation above, and is vacuously proved when
     the session never had an open run. An absent or malformed event leaves
     only `:run_ending` pending and prevents item 2 from being evaluated;
  2. the observed ending is `completed`, `failed`, `bound_reached` or
     `cancelled`: each is a clean ending emitted only after the run's applicable
     provider and executor work ended. An admitted abort with unconfirmed
     cleanup ends `outcome_unknown` (`session_coordinator.ex:6000-6006`), which
     leaves this item unproved. This rule uses the observed ending rather than
     whether the abort command won the race. This item is also vacuously proved
     when the session never had a run;
  3. every process group the local executor owned is proved empty through its
     private gate-proof handshake. The executor freezes new dispatch after the
     run-ending wait, drains every still-unproved group with its existing
     process-table check (`executor.ex:6335-6377`), and sends the gate an
     instance- and lease-bound proof before runtime shutdown. The owner never
     learns a group from tool output or synthesizes that proof;
  4. the core client actor and every cleanup phase worker,
     `SessionRoot`, `RuntimeHolder`, the private supervisor and every recorded
     child of that per-session subtree are `DOWN`. The supervised termination
     releases the workspace lease and ends the store, executor and any
     already-stopped runtime before the filesystem can be removed. A startup
     phase whose grant lacks an exact return remains unproved even when every
     known parent is `DOWN`, because an unreported child may exist. A worker
     deadline with any child or root still live is `:session_subtree`; killing
     the worker is never itself proof that the subtree ended. A removal worker
     does not exist until after item 5 and is owned exclusively by the later
     root-removal obligation.
  5. after items 1 through 4, the owner sends the gate one correlated final
     cleanup disposition carrying its owner identity and any accepted process-
     group proof nonce. The gate requires every registered preflight, local or
     hosted call, caller, subtree PID and registry tag gone; atomically removes
     the owner registration, lease, inactive-executor capability and retained
     proof; and replies with the exact release acknowledgement. Only that reply
     proves `:gate_release`. A refused, malformed, late or missing reply commits
     the one-way poison latch before return, leaves `:gate_release` pending and
     is permanent for that VM. It never becomes success from owner or gate
     `DOWN`.

  After item 5 is proved, an `:owned` root lets the owner start one separate
  linked and monitored removal worker carrying only the exact temporary-root
  path. An `:unknown` root claim never starts this worker and remains
  `:root_removal` unproved. The worker
  performs recursive deletion; the owner never calls filesystem removal
  synchronously. It consumes the same remaining cleanup deadline, and the
  trapping owner correlates its `EXIT` and exact `DOWN`. Success requires both a
  successful removal return and a subsequent owner-side absence check. A raised,
  exited, malformed or hung removal, a root still present after success, or
  expiry makes the owner send the worker an untrappable kill and perform one
  zero-wait receive. It retains the root and names `:root_removal`; when exact
  `DOWN` is absent it also retains the worker monitor, and a retry waits for that
  prior worker before starting another. A root-removal-only retry starts a new
  removal worker only after the old one is proved gone and no cleanup phase worker is
  needed. A suspended removal worker may temporarily outlive a bounded return or
  owner exit until its already-sent kill is scheduled; it can only continue the
  attempted removal of the retained exact root.

  When `ask/3` or `answer/3` has a waiting caller, stop leaves that caller
  registered while the owner performs this sequence. If a pending interaction
  was observed before stop serialized, the waiting call was already replied to
  and is no longer registered. Once stop wins serialization, it never publishes
  a question that the ensuing abort would make stale. Before the owner replies
  to stop or enters a failed-stop state, it resolves each still-waiting call by
  that request's admission state. A terminal event for its run returns the exact
  terminal result or run error. Before possible prompt or answer admission,
  proved cleanup returns bare `{:error, :session_unavailable}` and unproved
  cleanup returns the shared `cleanup_unproved` value with `ending: :none`.
  After possible admission but before a terminal event, the run-ending
  obligation is necessarily unproved. The caller receives `cleanup_unproved`,
  whose `ending` is the current bounded
  `{:error, {:session_unavailable, snapshot}}`; that no-ending value is not a
  direct proved-cleanup return. If a terminal event arrives during stop, the
  first rule above returns that terminal value instead.
  These are replies to public API callers, not additional attachment readers.

  Otherwise it keeps the root, returns
  `{:error, {:cleanup_unproved, %{root: path, root_ownership: :owned,
  pending: [...], ending: observed_ending, cause: nil}}}`
  naming every reached item that failed proof (`:run_ending`,
  `:effect_cleanup`, `:process_groups`, `:session_subtree` or `:gate_release`
  for items 1 to 5), plus `:root_removal` when the first five obligations were
  proved but recursive removal failed. An item whose prerequisites failed is
  not reached and is not appended merely because it remains downstream:
  absence of `run.finished` does not also name `:effect_cleanup`; a missing
  actor `DOWN` prevents the cleanup phases and names
  `:session_subtree`, not an unevaluated process group; any failure among items
  1 through 4 prevents and omits `:gate_release`; and a gate failure prevents
  and omits `:root_removal`. The worker still attempts every later phase that
  does not depend on the failed proof, so independently observed failures among
  items 1 through 4 are combined in the fixed public order. `observed_ending`
  is the exact terminal
  result or run error when one was seen, the exact no-ending error returned to
  a waiting call after possible prompt or answer admission, the exact pending
  interaction that was the last public value of the current run when stop began,
  or `:none` when the current operation has no observation because the session
  never had a run, startup failed before one, or the owner registered a
  validated ask or answer that failed before possible admission; it is never a
  prior run's result after that marker exists. A request rejected at the public
  boundary never creates the marker, so a later stop still uses the owner's
  current run observation. The pending list
  uses the public type's fixed order with no duplicates. It writes nothing
  else. A later
  `stop_session/1` on the same session first reaps any still-live recorded actor
  and retained phase worker, then starts one bounded worker for each still-
  pending reached phase, including a never-reached process-group phase before
  the still-live runtime or subtree when item 4 was pending, and
  retries through the removal worker when only `:root_removal` was pending. It
  never retries an unproved gate release or repeats a proved process-group
  drain.
  This retry state exists only when that `stop_session/1` returned the error to
  a caller while the session handle survives. The one-shot `run/2`, creator-exit
  and post-timeout background-drain paths log any retained root and exit
  unmarked after their bounded cleanup attempt; they cannot promise a later
  retry without a surviving caller contract.
  Items 1 to 3 and item 5, once unproved, stay unproved for the life of the VM; the owner
  never relies on a stale process-group identifier after the executor ends, so
  the root then stays for the host to remove. After returning such a permanent
  failure, the owner logs nothing (the caller received the path), exits without
  marking the handle stopped, and every later API call, including another stop,
  returns `:session_unavailable`. When only item 4 or `:root_removal` is pending,
  the owner enters a terminal retry state tied to the process that called
  `start_session/1`: only `stop_session/1` retries the outstanding proof; every
  other API call returns `:session_unavailable`. If that caller process exits,
  the owner performs one final bounded retry, logs a still-kept root and pending
  obligation, and exits unmarked. If a retry proves cleanup and removal, it
  marks the handle stopped and the ordinary idempotent-stop rules apply.
  One-shot `run/2` returns the error, logs the retained path and ends the failed
  owner because it exposes no session handle.
- **One session per `start_session/1`.** Each call composes its own runtime and
  root. Concurrent sessions are separate runtimes, and no session shares a
  root.

**Ephemeral command identifiers.** Startup uses the fixed distinct ids
`"create"`, `"admit-resources"` and `"activate-skill-1"` through
`"activate-skill-4"`. After startup the owner holds a private 32-byte nonce and
an arbitrary-precision monotonic counter. For each prompt, interaction answer
or abort it increments the counter once and constructs a 64-byte lowercase id
as `"e-"` plus the first 62 hexadecimal characters of SHA-256 over the bytes
from `:erlang.term_to_binary([nonce, counter, type], [:deterministic])`, where
type is exactly `:prompt`, `:answer` or `:abort`. Tests inject the nonce.
An operation keeps that one id through dispatch and requires the exact accepted
reply; it never retries with another id. The nonce, counter and ids contain no
credential and never cross the public API except through existing durable
command records.

**Failure of the owning process.** If the process that created the session
exits, the creator monitor fires and the owner performs the same abort, stop
and removal sequence. Any still-live registered borrower waiting in `ask/3` or
`answer/3` receives the same admission-state-specific concurrent-stop result:
the exact terminal value; before possible admission, bare
`session_unavailable` after proved cleanup or `cleanup_unproved` with
`ending: :none`; after possible admission without a terminal event,
`cleanup_unproved` with the bounded no-ending value inside it. The owner sends it
before exiting. A
`cleanup_unproved` result in this creator-exit branch never creates retry state,
even when only the subtree or root remains: creator lifetime ended. When no
registered waiter remains, the owner logs a kept root and exact pending
obligations once before it exits unmarked. The owner is not linked back to the
creator: an owner or gate failure therefore leaves other host processes alive
to receive the monitored request failure or make a later handle call. There is
no recovery, and none is claimed.

<a id="technical-plan-adapter"></a>
### The In-Process Model Adapter Contract

Concept: [Scope](M6.md#concept-plan-scope).

`Loopex.LLM.ReqLLM.InProcess` implements `Loopex.Model.complete/3` inside the
host's VM for every provider the ephemeral profile serves: `ollama`, `openai`,
`anthropic` and `openrouter`. It does not replace the companion adapter
`Loopex.LLM.ReqLLM`, which the durable composition always uses; the durable
composition refuses an `ollama:` model with
`{:composition, :durable_model_unsupported}`, because the companion requires a
credential. A credential-bearing in-process model also refuses unless
`:tools` is `:none`, before any per-session root or tool process exists.

**Shared mapping.** The companion's exact pure request-side, reply and error
closure moves into one module both adapters call,
`Loopex.LLM.ReqLLM.Mapping`; no listed function is copied. The moved closure is:

- `context_of/1`, every `render_message/2` clause and `provider_name/1`
  (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex:1031-1102`);
- `provider_tools/1` and every `provider_tool/1` clause (`:1104-1134`);
- `bounded_calls/1` (`:770-790`), with the fail-closed correction below;
- `reply/6`, `completed/1`, `error_status?/1`, `provider_request_id/2`,
  `bounded_response_id/1`, `header/2` and `present/1` (`:676-726`,
  `:977-1014`);
- `failure_pair/2`, every `returned_class/1` clause and every
  `raised_class/1` clause (`:583-674`).

The new module owns the constants those functions use, including the unchanged
response-id bound and fixed call-failed text. The companion replaces its private
calls with that module and keeps `worker_preflight/2`, `failure_stage/2`,
`assemble/3`, every streaming function (`emit`, `drain`,
`ResponseBuilder`) and `identity/1`. The in-process adapter calls the same moved
functions around its non-streaming ReqLLM return. No companion state or process
is in the moved closure, and no second implementation is admitted.

The one correction is `bounded_calls/1`. It never uses
`ReqLLM.ToolCall.to_map/1`, because locked ReqLLM substitutes `%{}` when a
binary argument decode fails. For every buffered `%ReqLLM.ToolCall{}` visible at
this seam it first requires both `ReqLLM.ToolCall.builtin?(call)` and
`ReqLLM.ToolCall.provider_native?(call)` to be false. It then requires exact
type `"function"`, non-empty binary id and name, neither atom- nor string-keyed
error metadata in `ReqLLM.ToolCall.metadata/1`, and a binary argument payload
for which `ReqLLM.JSON.decode(raw, json_repair: false)` returns a map. It accepts
valid `{}` and rejects invalid text, `null`, arrays and
incomplete-but-repairable JSON. Provider-executed builtins and provider-native
calls are not replayable application calls; they fail the whole reply and can
never be flattened into a local core tool request. Only
`%{id:, name:, arguments:}` crosses out of the sensitive caller. Any failure
rejects the entire ordered call list and, because generation has already begun,
becomes fixed `dispatched_or_unknown`; no partial list reaches tool execution.
Both adapters use this one corrected function. Valid application-call replies
are unchanged, while a malformed binary payload or visible non-application
classification that reaches this seam can no longer masquerade as an ordinary
local call (`tool_call.ex:106-178`, `:208-217`, `:236-270`).

That is the exact seam, not a provider-wire claim. Before `bounded_calls/1`,
locked ReqLLM's buffered builders can call `ToolCall.new/3`, which generates a
nil id and fixes type to `"function"`; normalize nil or unsupported arguments to
literal `"{}"`; omit malformed provider calls; retain a provider-executed
builtin flag; and retain only async or status metadata on normalized buffered
calls (`provider/defaults/response_builder.ex:164-206`,
`tool_call.ex:93-103`, `provider/defaults.ex:1556-1571`,
`providers/openai/responses_api.ex:2322-2337`, `:2415-2427`). A
`%ReqLLM.ToolCall{}` already carrying provider-native metadata may also remain
visible because the buffered normalizer preserves an existing struct. Loopex
cannot reconstruct the removed id, type, argument-shape or error-marker facts.
Dependency vectors pin each normalization. A call omitted by ReqLLM executes
nothing; a visible normalized `"{}"` is accepted as `%{}` and still crosses core
tool resolution, schema validation and host policy. Visible builtin and
provider-native markers remain reconstructible and therefore fail closed. The
plan names only the erased distinctions as a limitation rather than assigning
an impossible raw-response obligation to the shared mapper.

Cross-adapter equivalence is exact for request mapping and every valid bounded
reply. For failures it covers only the public model return class and fixed text:
pre-call refusal is `not_dispatched`, and every post-call failure is
`dispatched_or_unknown`. A companion streaming wrapper and a direct
non-streaming `%ReqLLM.Error.API.Request{}` may have different private
stage/class diagnostics; those terms never enter a public, durable or owner
state plane and are not an equivalence claim.

One additional internal pure module,
`Loopex.LLM.ReqLLM.Deadline`, owns the arithmetic already used by the companion:
`invocation_deadline/2` maps a committed absolute system-millisecond instant to
native monotonic time as
`System.convert_time_unit(deadline, :millisecond, :native) - native_offset`, and
`remaining_timeout/2` compares native instants, returns zero for a non-positive
remainder and rounds any positive fractional millisecond upward. The existing
`ProviderBridge.invocation_deadline/2` and
`ProviderCodec.remaining_timeout/2` become delegating private test seams, so
the companion's bytes and behavior do not change. The companion and in-process
adapter are the two concrete consumers; neither separately samples wall and
monotonic clocks or reimplements the conversion.

**The call, guards and per-call process** are stated once in ADR 0039's
technical companion: the non-streaming `ReqLLM.generate_text/3` with an inline
model, `api_key` read from the provider's variable by the calling process
immediately before the call, an explicit `base_url` (the host's, else the
built-in module's default), `total_timeout: :infinity`,
`receive_timeout: :infinity`, `max_retries: 0` as defense in depth, no
`:cache`; and
`req_http_options` naming `OneShotHTTP1`, `redirect: false`, and the exact
nested Finch list `[name: Req.Finch, pool_tag: tag, pool_timeout: bounded]`,
whose `bounded` value is from 1 through 1,000 ms, plus only the
credential-free private context
`{owner_pid, tag, route_fingerprint}`. The fingerprint is the exact
credential-free provider, surface, POST method, admitted base URL, relative
route and nil-query expectation defined below. A credential-bearing provider requires `https`; only
Ollama may use `http`. Before the caller starts, its owner directly
`spawn_monitor`s a start-blocked lifecycle root, records it with the gate, and
then lets that root start a user-managed pool under an anonymous supervisor,
with `protocols: [:http1]`,
`size: 1`, `count: 1` and no metrics. HTTPS alone adds exactly
`conn_opts: [transport_opts: [reuse_sessions: false, session_tickets: :disabled,
keep_secrets: false]]`; HTTP omits `conn_opts`. Finch passes the outer
`conn_opts` to Mint, and Mint reads the SSL values only from its nested
`transport_opts`. That single monitored, request-free lifecycle root
performs the exact empty-registry check, `Finch.Pool.child_spec/1`, anonymous
supervisor start, `DynamicSupervisor.start_child/2`, inspection and later graceful
teardown while the cleanup owner stays in its receive loop. It owns the
anonymous supervisor, synchronously registers every returned PID with the owner
before proceeding, traps ordinary exits, monitors the cleanup owner and begins
the same unwind on owner `DOWN` or a gate message, and derives the exact HTTP/1 worker PID from the returned
pool-supervisor PID, requiring
`Supervisor.which_children/1` to be exactly
`[{1, owned_pid, :worker, [Finch.HTTP1.Pool]}]`, and requires the full
duplicate-key registry lookup to be exactly
`[{owned_pid, Finch.HTTP1.Pool}]`, while the unique
`Req.Finch.SupervisorRegistry` lookup is exactly one entry for the recorded pool
supervisor and expected pool configuration, before the caller starts and again
at the dispatch grant. The dispatch-time check is a command to this same
registered lifecycle root, not a new helper. If that check does not return, the
owner remains responsive, withholds dispatch and success, and takes the
unproved-cleanup path unless cooperative root teardown completes. Complete
setup must answer before the earlier of 1,000
ms and the call deadline. Stop can request and await cooperative unwind during
every setup phase. The lifecycle root exits only after every registered
descendant is `DOWN`; if a dependency call prevents that proof, no provider
result or successful acknowledgement returns and the gate remains fail-closed.
The owner requires both Loopex-created registry entries gone before replying. It never uses `Finch.find_pool/2`,
whose duplicate-entry path can choose at random, and never permits a later
lookup to select or start a replacement. The three
host-global guards are ReqLLM's built-in provider module, empty `:req` default
options and unset `SSLKEYLOGFILE`; address and final-request guards reject
unsafe origins or routing substitutions.

The cleanup owner enforces `request.deadline`, the committed absolute system-
millisecond instant, outside Finch. It freezes one
`System.time_offset(:native)` and maps that instant through the shared deadline
module; it never derives a budget from separately sampled clocks. Every wait
samples `System.monotonic_time(:native)`, uses the shared upward-rounded
remaining milliseconds and is capped at 1,000 ms. At final dispatch the pool
checkout timeout is that same value capped at 1,000; zero refuses before the
transport grant. The caller returns
`{caller_pid, ref, result, finished_at_native}` before normal exit. A result is
admissible only when its timestamp is no later than the mapped deadline. When
the owner first observes expiry, one zero-wait receive lets an already-queued,
matching, in-time result win; otherwise expiry makes every result inadmissible
and the owner kills the caller. The converted native instant may be an arbitrary-
precision integer; only capped slices reach OTP or Finch, so no unsigned-64-bit
duration or native remainder reaches a relative timer.

`OneShotHTTP1` validates the final route fingerprint and the absence of an
external `into` or compression request, removes its private Req-only context,
and obtains the
owner's only dispatch grant together with the exact recorded worker PID. It
then builds a `%Finch.Request{}` from the final Req method, URL, headers and
already encoded non-streaming body with
`Finch.build(method, url, headers, body, [pool_tag: tag])`, installs an internal
8,388,608-byte response collector and `accept-encoding: identity`, and calls
`Finch.HTTP1.Pool.request/6` directly on that PID, literal name argument
`Req.Finch`, and the exact option list
`[pool_timeout: bounded, receive_timeout: :infinity, request_timeout:
:infinity]`. The final Req validation requires those same timeout values and
refuses `:pool_strategy` or any other Finch request/build option. It never calls
`Req.Finch.run/1` or any Finch request or stream entry point that performs the
auto-starting registry lookup. A dead or restarted worker therefore fails the
call; a replacement never receives the request. The adapter implements the
bounded accumulator and error normalization that the locked Req adapter would
otherwise supply. A chunk that would cross the limit halts the HTTP/1 request;
an overflow or encoded response becomes the private adapter sentinel
`model_response_too_large` or `model_response_encoding_unsupported`; both are
normalized at the model port to the public
`{:dispatched_or_unknown, "model_call_failed"}` form and never enter the run
algebra. It restores the original Req `into` and
private context only to the returned Req request so any attempted retry reaches
the same owner fence, then waits for local tagged-pool teardown before returning
  to ReqLLM.

  The one-shot adapter records only the response header used for provider call
  identity: `request-id` for Anthropic, `x-request-id` for OpenAI, and no header
  for Ollama or OpenRouter. Because `total_timeout: :infinity` keeps Req and the
  adapter in this same sensitive caller, it stores that zero-or-one-element
  header list in the caller's process dictionary under
  `{Loopex.LLM.ReqLLM.InProcess, :response_headers, tag}` before returning the
  `%Req.Response{}` to ReqLLM. The caller deletes that key before generation and
  in an `after` clause on every exit; no other process or state receives it.
  This side channel is required because locked `generate_text/3` returns only
  the decoded `%ReqLLM.Response{}` and discards the outer response headers.

  For an exact `{:ok, %ReqLLM.Response{} = response}` return, the caller builds
  metadata with `usage: response.usage || %{}`, `finish_reason:
  response.finish_reason` and `headers:` equal to that captured list, adding an
  `error:` member only when `response.error` is non-nil. It requires the shared
  `completed/1`, which rejects a non-nil error and finish reasons `:error`,
  `:incomplete` and `:cancelled`; requires `bounded_calls(response)`; obtains
  text as `ReqLLM.Response.text(response) || ""`; and calls the shared
  `reply(request, identity, metadata, text, calls, 0)`. Any other return,
  malformed response, failed completion check or unreconstructible call is the
  fixed `dispatched_or_unknown` model failure. The sensitive caller catches
  every raise, exit and throw, recursively checks every
provider-controlled binary in that mapped reply—including assistant text,
tool-call fields and `provider_response_id`—for an exact occurrence of the
resolved credential, and sends only a mapped reply or fixed error class to the
  sensitive owner. The adapter reports no progress deltas.

The runtime's `model` field stays the `provider:model` string, as
`runtime.ex:1170-1171` requires. The adapter rebuilds the inline model from it
on every call and uses it for both the reply's `identity` (provider, model id,
base URL as endpoint) and dispatch. No catalog lookup or unverified-model
warning occurs, which matters because Ollama models are absent from the pinned
catalog.

| Prefix | Credential variable | Default base URL (ReqLLM 1.24.0) | POST route |
| --- | --- | --- | --- |
| `ollama:` | none | `http://localhost:11434/v1` | `/chat/completions` |
| `openai:` | `OPENAI_API_KEY` | `https://api.openai.com/v1` | `/chat/completions` for `:openai_chat_completions`; `/responses` for `:openai_responses` |
| `anthropic:` | `ANTHROPIC_API_KEY` | `https://api.anthropic.com` | `/v1/messages` |
| `openrouter:` | `OPENROUTER_API_KEY` | `https://openrouter.ai/api/v1` | `/chat/completions` |

The model grammar is `<prefix><id>`. The id is everything after the first colon,
so `ollama:qwen3:14b` names id `qwen3:14b`. Any other prefix refuses as
`{:composition, :unknown_provider}`.

**Exact route binding.** One private byte parser accepts only
`<scheme>://<host>[:<port>][<path>]`; provider and URI-library parsers do not
admit or normalize input. Scheme is literal lowercase `http` or `https`. Host
is either four canonical decimal IPv4 octets from 0 through 255, with no leading
zero except `0`, or an ASCII DNS name of at most 253 bytes made of one or more
dot-separated 1-to-63-byte labels. Each DNS label begins and ends with an ASCII
letter or digit and otherwise contains only those bytes or `-`; it normalizes to
lowercase. Empty labels, a trailing dot, bracketed IPv6, Unicode, percent escapes
and user information refuse. The optional port is canonical decimal with no
leading zero and lies from 1 through 65,535; explicit `:80` for `http` and
`:443` for `https` normalize away, and omission has that same effective port.
The path is empty or `/` followed by non-empty segments made only of RFC 3986
unreserved ASCII bytes. Query, fragment, percent escapes, backslashes, repeated
interior separators and literal `.` or `..` segments refuse. All trailing `/`
bytes are removed, including a lone root slash. A library parse may only verify
that the resulting canonical string has the same scheme, host, effective port
and path.
This admits the built-in empty, `/v1` and `/api/v1` prefixes without leaving
Req's one-boundary-slash rule ambiguous. The expected final path is that
normalized prefix concatenated with the table's route; final query, fragment
and user information are nil.

Before credential resolution, the caller binds one `route_fingerprint` to the
tag and owner: `%{provider: provider, surface: surface, method: :post,
base_url: normalized_base, path: final_path, query: nil}`. For Anthropic and
OpenAI it obtains the surface through credential- and network-free
`ReqLLM.plan(model_spec, :chat, planning_options)`
(`deps/req_llm/lib/req_llm.ex:420-423`). The planning options are exactly, in
this order,
`max_tokens`, `tools`, `total_timeout: :infinity`,
`receive_timeout: :infinity`, `max_retries: 0`, `base_url` and the complete
`req_http_options` stated above; no `api_key`, `operation` or `cache` member is
present. The literal `:chat` matches the `generate_text/3` path.
The generation options are byte-for-byte the same keyword list for Ollama and,
for a hosted provider, that list with only `api_key: resolved_value` prepended
immediately after the final guard and token verification. Thus planning and
generation cannot disagree about sampling, tools, transport, address or retry,
while the planning call never receives the credential. The caller requires
`:anthropic_messages`, `:openai_chat_completions` or
`:openai_responses` and the corresponding fixed route. ReqLLM's planner does
not admit Ollama or OpenRouter, so their surfaces and routes are the fixed
table rows, not a planner claim. The fingerprint is carried in
`finch_private`, removed before `Finch.build/5`, and also retained by the owner.
At the atomic dispatch claim, `OneShotHTTP1` supplies the final Req method and
URI; the owner requires exact fingerprint equality, including effective port,
path and nil query, and for Anthropic/OpenAI requires the request's private
ReqLLM plan metadata to name the same surface. Only then can it grant the
recorded worker PID. A mismatch is the conservative pre-network
`dispatched_or_unknown` refusal. Thus neither same-origin path substitution nor
an OpenAI surface change can pass the final boundary.

**Credentials.**
- The runtime's model options carry the provider's credential variable name
  and the base URL, never a value.
- Composition validates only the fixed provider-to-variable reference and the
  no-tools rule; it never reads the value. The sensitive calling process alone
  resolves and checks the variable immediately before each call, naming the
  variable and never the value, and returns the fixed public
  `{:not_dispatched, "model_call_failed"}` failure when it is absent, empty or
  larger than 65,536 bytes. A private test sentinel may distinguish the guard;
  it never crosses the model port.
- The library never deletes a host variable, because each call reads it.
- A hosted ephemeral session requires `active_tools: []`.
- `LoopexComposition.Ephemeral.CredentialToolGate` is one VM-wide GenServer
  under the composition application's one-for-all supervisor, before the
  DynamicSupervisor that owns ephemeral session owners. It grants any number
  of monitored `:tools` leases or any number of monitored `:credential_call`
  leases, never both modes at once. Acquisition and mode transition are one
  serialized call. The gate is host-edge admission state, not session truth:
  composition passes its explicit capability to the model adapter and executor,
  while no runtime looks it up by name and it stores no policy, request or
  credential. Every gate `init/1` creates a fresh private generation and writes
  exact `{:unclean, generation}` to `:persistent_term`; absence means a first
  healthy VM start, while any prior value makes that incarnation start
  poisoned. A replacement always overwrites the old generation before serving
  a message, so a clean-stop proof from an earlier gate can never erase the
  replacement's marker. Before every ephemeral owner start, including a tool-free
  local session, the API atomically reserves owner admission at the gate. The
  gate monitors the starting process. The new `restart: :temporary` owner must
  synchronously exchange that reservation for its own PID registration before
  it creates a root or acquires a lease; child-start refusal, explicit
  cancellation or the starting process's `DOWN` releases only an unexchanged
  reservation. Owner `DOWN` removes a registration only when it has no lease,
  registered preflight, subtree, executor or local-call obligation. Otherwise
  the gate converts it to an orphan obligation, triggers every registered local
  lifecycle root to unwind, kills registered callers, retains child monitors and
  registry tags, and permanently poisons both modes for that VM. Later proofs
  can close and remove the orphan records, but they cannot clear the one-way
  latch or make admission resume before VM restart. The gate never discards
  child records with their parent registration.

  The two inward edge applications do not import a composition module.
  `loopex_llm_reqllm` owns a private
  `Loopex.LLM.ReqLLM.InProcess.GateClient` behaviour for provider-call
  registration, acquisition, child registration, release and poison.
  `loopex_executor_local` owns a private
  `Loopex.Executor.Local.EphemeralGateClient` behaviour for lease validation,
  probe registration, process-group proof, release and poison. One module in
  `loopex_composition`, which already depends inward on both applications,
  implements both behaviours. Composition passes each edge the corresponding
  `{client_module, opaque_handle}` through its private constructor; the handle
  contains no function and never enters a public, durable or diagnostic plane.
  Each edge invokes only its own behaviour dynamically and has no compile-time
  dependency on composition. The callback implementation is a bounded encoder
  and receiver for the asynchronous gate protocol, not a second owner or state
  store.

  **Gate message discipline.** No participant uses an unbounded
  `GenServer.call/3`. Every gate operation is an asynchronous capability
  message carrying a fresh request reference, requester PID, absolute monotonic
  expiry, operation and bounded payload; the only accepted reply repeats that
  exact reference and carries the operation's closed result. The requester
  monitors the gate, ignores stale or mismatched replies and sends an
  idempotent same-reference cancel on timeout. The gate rejects an expired
  request, records a canceled reference through its expiry and makes repeated
  references return the recorded result without a second transition. Erlang's
  same-sender ordering plus that expiry means a suspended gate cannot later
  turn an abandoned reserve, exchange or acquisition into live state.

  Every reserve, exchange, acquisition, PID registration, caller creation,
  caller-token verification, lease check, proof submission, proof query and
  release round trip ends at the earlier of 1,000 ms and its enclosing startup,
  model-call, tool-call or cleanup deadline. Participants compare one absolute
  deadline and receive in bounded slices; they do not put an admitted uint64
  into an OTP timer. Session and cleanup owners keep the pending reference in
  their normal receive loop so stop and `DOWN` messages remain answerable.
  Other waiters remain start-blocked and have read no credential or started no
  OS effect. A missing, late, malformed or gate-`DOWN` reply never authorizes
  progress. Reservation failure maps by the fixed admission reasons below; a
  live-gate owner-exchange timeout or malformed reply is
  `ephemeral_owner_registration_failed`, while gate `DOWN` is
  `credential_tool_gate_unavailable`. A credential-call failure maps to the
  fixed model failure. A tool-dispatch lease-check failure returns the fixed
  tool refusal before an OS child. A lost registration or cleanup proof takes
  the unproved and poison path. The credential caller applies the same rule to
  its token verification and exits without reading the environment on failure.
  `prep_stop/1` uses its separately fixed 1,000 ms bound. Late replies cannot
  change an owner result already selected.

  Each opaque handle also contains a private one-way `:atomics` poison latch
  created and owned by the gate tree. A session-bound participant that cannot
  prove a registration, release or *gate-scope helper* `DOWN` commits poison
  locally by an atomic zero-to-one transition before it reports the failure.
  Through the owner's prepared acknowledgement, the synchronous entrypoint is
  the sole detector and poison committer for owner-start helper proof: the guard reports its bounded
  evidence to that entrypoint, and a dead, silent or malformed guard is detected
  by the entrypoint's own monitor. Gate-scope helpers are exactly an owner-start
  guard or worker, a pre-root credential
  preflight actor, a ReqLLM-hygiene worker, or a gate-registered provider-call
  cleanup owner, lifecycle root or caller whose missing end could retain a
  lease, registration or dispatch capability. The session's `FacadeClient`,
  phase-selective cleanup workers and root-removal worker are not gate-scope
  helpers: their missing `DOWN` values remain the retryable
  `:session_subtree` or `:root_removal` obligations above and do not poison by
  themselves.

  Poison may originate in the session owner itself—for example after an
  unproved final gate acknowledgement or an owner-held preflight proof. That
  owner first commits the atomic latch and creates one poison reference. It
  atomically enters the applicable startup-rollback or session-cleanup state
  and closes new facade admission. Before the owner can acknowledge its
  post-exchange preparation, it has already recorded the one session cleanup
  grace; no preflight, root or dependency phase is yet authorized. It therefore
  creates the ordinary `now + cleanup_grace_ms + 5_000` deadline or joins an
  existing cleanup deadline without extending it. It computes the selection-notification
  deadline as 1,000 ms after the later of
  the active cleanup deadline and that origin instant, using saturating
  arithmetic, and sends the gate the exact correlated `poison_watch` control.
  It does not wait for the acknowledgement: message ordering from this owner
  puts the watch before either later control, while the live owner remains the
  independent deadline fallback. It then finishes every still-independent
  cleanup phase under that cleanup deadline while the gate can
  grant nothing, atomically stores the complete cleanup result, freezes the
  recipient-results set and sends exact `poison_delivery_started` with one new
  aggregate delivery deadline 1,000 ms ahead. Only that second control starts
  result delivery. A live gate already monitors the owner and records each
  control when it arrives; owner `DOWN` or either applicable deadline makes it
  terminate the shared tree. An unresponsive gate cannot grant after it resumes
  because every transition rechecks the already-set latch, while the live owner
  terminates the tree at the applicable deadline. Owner `DOWN` after the latch
  but before result selection makes the gate kill the tree and leaves only the
  named bare-unavailable owner-loss result. Thus a poison delivery deadline
  never preempts discovery of the complete reached-phase cleanup result.

  Poison otherwise closes authority before it tears down a selected reporting
  path. A session-bound detector other than the session owner records one poison
  reference and sends it only through its owner-bound private capability to the
  registered owner; it sends no preliminary gate message and does not start a
  result-delivery deadline. It waits at most 1,000 ms for exact custody. In the
  owner's serial receive loop, accepting custody atomically commits poison and
  enters the existing `stopping`/session-failure state if cleanup has not begun:
  new facade admission closes, previously serialized operations keep their
  stated admission rules, and later stop calls join that one cleanup attempt.
  It records a fresh `now + cleanup_grace_ms + 5_000` cleanup deadline. If stop
  or creator loss already entered that state, custody joins the existing attempt
  and deadline rather than extending it.

  Before doing cleanup work, the owner computes a distinct selection-
  notification deadline exactly 1,000 ms after the cleanup deadline, using
  saturating arithmetic, and sends the exact correlated `poison_watch` control
  to the gate. Only an exact gate acknowledgement received within the detector's
  1,000 ms custody wait permits the owner to acknowledge custody; that
  acknowledgement names the owner, poison reference and selection deadline.
  The detector then sends its correlated retirement notice and exits normally;
  the owner must observe that exact detector `DOWN`. Cleanup may continue beyond
  that initial custody interval. At its cleanup deadline the owner performs the
  final zero-wait receives, samples proof state and atomically stores the
  complete reached-phase result before leaving that serialized transition.
  Missing gate or owner custody, detector `DOWN` before retirement, owner
  `DOWN`, a mismatched message or failure to send exact
  `poison_delivery_started` by the later selection deadline makes the detector,
  owner or gate terminate the exact shared tree. During the fixed post-cleanup
  margin the owner freezes the already stored recipient values and sends
  `poison_delivery_started` with one new aggregate absolute delivery deadline
  1,000 ms ahead; only that message starts result delivery.

  A reporting session owner freezes one immutable, capability-bound
  `recipient_results` set before that delivery-start message. The set contains
  every still-live waiter and that waiter's already selected bounded value;
  values need not be equal. Thus an ask waiter may retain its terminal value
  while a concurrent stop waiter receives the later `cleanup_unproved` value.
  The owner sends all entries without serial waits and collects exact
  acknowledgements only until the aggregate delivery deadline. Each receiving
  wrapper accepts only its own capability and acknowledges before returning its
  already validated value; if reporter `DOWN` wins, it performs one zero-wait
  receive for an already queued matching handoff. A session owner with no
  waiter, or any unacknowledged retained-root path, writes the retained-root
  diagnostic to the host logger before teardown. The detector has already
  retired; the owner sends exact `poison_handoff_complete` to the gate
  immediately before sending the gate and its exact one-for-all supervisor an
  untrappable termination signal. Missing or mismatched delivery start or completion, or expiry of the
  one aggregate delivery deadline, takes the same gate fallback. Completion is
  only the takeover boundary, not cleanup or delivery proof; there is no per-
  recipient interval.

  While it remains live, the gate is the reporting actor for an admitted
  ReqLLM-hygiene cohort. It
  creates the same one aggregate deadline, freezes a recipient-to-
  `req_llm_start_failed` set, performs the same concurrent handoff and
  acknowledgement collection, then terminates the tree. Every admitted hygiene
  requester also monitors that exact gate. If gate `DOWN` wins, the external
  requester—not a replacement gate—selects fixed `req_llm_start_failed`,
  ignores every later reply and returns by the same 7,000 ms outer deadline;
  no owner, root, credential read or effect exists to clean. The synchronous
  `start_session/1` entrypoint is a separate direct-return case, not a wrapper
  or a process in the shared tree: it keeps the host creator identity, owns its
  fixed owner-start refusal on its call stack, and is the sole detector and
  poison committer for owner-start helper proof through the owner's prepared
  acknowledgement. The guard may
  report a missing worker proof, but it cannot commit poison or transfer result
  custody; a silent, malformed or dead guard is instead detected through the
  entrypoint's existing monitor and deadline. The entrypoint atomically commits
  poison, directs and bounds the existing shared-tree termination/reap branch,
  and only then returns its caller-held refusal. There is therefore no pre-owner
  custody message, private result handoff or `poison_handoff_complete`. Once
  exchange succeeds and the owner acknowledges its prepared state, every
  detector uses the registered-owner protocol above; a detector with no live
  registered owner terminates the tree at once. None of these paths
  creates a second cleanup owner or retry path.

  The gate checks the latch before and after any potentially blocking work and
  immediately before every authority-bearing transition or grant. Once set, it
  refuses reservation, owner exchange, root-token issue, lease acquisition or
  release, PID or tag registration, caller creation or token verification,
  process-group proof submission and final session disposition. Exactly three
  non-authorizing control transitions remain admissible: (1) `poison_watch`
  records the exact owner PID, poison reference and selection deadline and may
  return its correlated acknowledgement; (2) `poison_delivery_started` for that
  tuple records one aggregate delivery deadline without storing any recipient
  value; and (3) `poison_handoff_complete` for the same tuple orders immediate
  tree termination. The gate may create the same internal watch and delivery
  states when it is the hygiene reporter. An identical replay returns the
  already recorded acknowledgement and never extends a deadline or repeats a
  side effect. A stale, mismatching, reordered or conflicting control message
  is refused, cannot change the recorded tuple and cannot postpone the existing
  fallback. At either deadline the gate performs one zero-wait receive for an
  already queued exact message, then terminates the tree if the next required
  transition is absent. These transitions cannot clear poison, release an
  obligation or authorize runtime, credential or effect work. The gate does not autonomously exit before the applicable selection or
  delivery deadline while an
  exact reporting session owner remains live, because that would destroy the
  selected result path. The reporting actor, direct-return entrypoint or the
  no-reporter/deadline fallback above terminates the tree. Thus a
  suspended gate cannot later commit queued admission when it resumes, a
  caller-visible reached `:gate_release` failure can be handed off before its
  owner dies, an admitted hygiene cohort receives its fixed failure before the
  gate dies, and a replacement sees the already-retained unclean marker and
  starts poisoned. Other sessions ended by the ensuing shared-tree failure use
  the separately named bare-unavailable limitation; they do not borrow the
  reporting session's cleanup map. The clean-stop census requires the latch to
  remain zero. Only trusted code holding the private capability can set it;
  resetting it is impossible short of VM restart.

  The composition application callback's `prep_stop/1` is the only erasure
  authorization path, and `stop/1` is the only commit path. Callback state
  retains the application supervisor PID. `prep_stop/1` never calls a
  supervisor child-enumeration API or the gate synchronously. It starts one
  unlinked, monitored, non-trapping resolver worker bound to the application-
  supervisor PID, a fresh reference and one absolute 1,000 ms deadline. The
  worker resolves and verifies the current gate and owner-DynamicSupervisor
  children, asks that exact gate to atomically seal owner, lease and ReqLLM-
  hygiene admission under the same reference and expiry, sends one provisional
  result and waits for `finish`. On a structurally valid, in-time result the
  callback sends exact `{callback_pid, ref, :finish}` and accepts the proof only
  after the worker's exact normal `DOWN` within the same absolute deadline; it otherwise
  sends an untrappable kill, performs one zero-wait receive at the deadline and
  returns no proof. The worker can neither erase a marker nor start an owner,
  and a late request or result is refused by the reference and expiry. A gate
  sealed by a worker whose result is lost stays fail-closed while OTP stops the
  tree, with both markers retained. The gate returns an empty-census proof
  bound to the nonce, application-supervisor PID, owner-DynamicSupervisor PID,
  exact gate PID and exact persistent marker generation
  only when it already has no reservation, registered owner, lease, poisoned
  obligation, admitted hygiene cohort, hygiene worker or outstanding
  controller-mutation obligation; the hygiene marker is not `:starting`; and
  the verified DynamicSupervisor already has no children. Requests queued but
  not admitted are refused after the seal. It never waits for an active session
  or hygiene decision and never erases either marker; a non-empty census returns
  no proof and lets OTP continue stopping the tree with both markers intact.

  `prep_stop/1` places only that proof in the callback state passed to `stop/1`.
  After OTP has ended the application supervisor, `stop/1` verifies that the
  proof names the same supervisor and child incarnations. With the application
  tree and every possible marker writer already gone, it compare-and-erases
  only exact `{:unclean, proof_generation}` as the final clean-stop commit; a
  missing, malformed or different value returns without erasure. It never
  erases the separate ReqLLM hygiene marker.
  A timeout, missing or replaced child, gate death
  before reply, callback failure, non-empty or contradictory census, absent
  proof or failure before commit leaves the scheduling marker and the hygiene
  marker unchanged. Once commit occurs, the
  application tree and all admission paths are already gone. The gate's
  `terminate/2`, ordinary child shutdown and supervisor termination never clear
  it. A gate or supervising-subtree crash
  stops every ephemeral owner under the one-for-all tree but leaves the
  scheduling marker.
  A replacement gate is poisoned and refuses both modes until a VM restart;
  every handle for a session stopped by the failure returns
  `session_unavailable`.
  This is explicit host-edge admission state, not hidden per-runtime truth;
  trusted host code can erase it and is outside the guarantee.
- An Ollama session with an active preset acquires a `:tools` lease before any
  root. The owner has already recorded the one 5,000 ms session-start deadline
  that later covers the root and every private-edge phase. It releases only
  after every registered sensitive preflight, its complete per-session subtree
  and every executor process group are proved down or empty. An active
  credential-call mode refuses composition as
  `credential_call_active`; an unavailable gate refuses
  `credential_tool_gate_unavailable`. After acquisition, the owner starts one
  linked and monitored raw preflight process, registers its PID beneath the
  tools lease before granting it work, marks it sensitive and requires it to set
  its process logger level to `:none`. The grant carries the owner PID and a
  fresh reference. The process checks only whether `OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY` or `OPENROUTER_API_KEY` is set, sends exactly
  `{probe_pid, ref, :clear | {:present, variable_name}}`, then exits. The owner
  accepts a result only from that PID/reference and only after the same process's
  exact normal `DOWN`, which follows its send. The remaining session-start
  deadline bounds both. On expiry, creator/owner loss, malformed result,
  abnormal `DOWN`, result without `DOWN` or `DOWN` without a result, the owner or
  gate sends an untrappable kill. Exact `DOWN` returns
  `credential_preflight_failed` and releases the lease; missing `DOWN` returns
  the same no-root error, retains the registered obligation and poisons both
  modes until VM restart. A present variable, including an empty or oversized
  value, returns `ambient_provider_credentials` only after normal `DOWN` and
  releases the lease. Before starting the executor, the owner registers the
  private subtree root with the gate. From then on, owner death does not release
  the lease. Before root registration, owner death still waits for every
  registered preflight PID; after registration, an unproved process group or a
  missing process-group proof poisons both lease modes for the rest of the VM.
  The value never leaves the short-lived process, though the host environment
  itself keeps it.
- A tool-free owner acquires no mode lease. Before the executor phase grant it
  allocates a fresh instance reference and places that reference, its owner
  registration and the inward gate-client handle in the private
  `Executor.Local` child options. The new executor process knows its own PID:
  its `init/1` performs the bounded gate registration as its first effect,
  before ledger preparation, state construction, definition exposure or
  dispatch. The gate binds an `:inactive_executor` proof capability to that PID,
  instance and owner and returns it in the exact registration reply. That
  capability admits no tool definition or dispatch and participates in neither
  lease mode; it exists only so cleanup can obtain a gate-bound proof that the
  executor's private process-group set stayed empty. Exact refusal makes
  `init/1` stop and the executor phase return its fixed start failure. A missing,
  malformed or gate-loss reply takes the existing poison path before `init/1`
  stops, because registration may have committed. Registration starts a
  process-group proof obligation even though the executor exposes no tools.
  Only an accepted proof nonce followed by the owner's final acknowledged
  disposition removes that capability. Owner or executor `DOWN` before the
  proof is accepted leaves `:process_groups` pending and poisons both modes;
  subtree `DOWN` alone never discharges it.
- Every ephemeral owner also receives an instance-bound local-call capability.
  It grants neither lease mode and cannot authorize a credential read. A
  credential-free Ollama cleanup owner registers itself and then its
  start-blocked lifecycle root, pool children and caller beneath the enclosing
  owner through this capability. The cleanup owner directly `spawn_monitor`s
  the generic caller only after exact pool setup; the caller monitors both that
  owner and the gate and cannot start until the gate records its PID and returns
  a one-use local token. This permits the default Ollama call to run while its
  session holds a `:tools` lease, but keeps every call process in the gate's
  owner census. Normal local-call release requires every registered PID `DOWN`
  and both tagged registry entries absent, with no credential quarantine. An
  unproved local call poisons later ephemeral admission until VM restart.
- For a hosted provider, after core has registered the cleanup owner and before that owner creates a
  lifecycle root, pool or caller, the owner acquires and holds a
  `:credential_call` lease. An active tool lease produces fixed public
  `{:not_dispatched, "model_call_failed"}` without reading the variable or
  starting a pool. After exact pool setup, the owner asks the gate to create a
  generic request-free caller. In one serialized gate turn, the gate spawns it
  start-blocked, records and monitors its PID under the lease, and returns a
  one-use start token. The caller also monitors that gate and exits without a
  credential read if the gate dies before delivering the token. The owner
  monitors the returned PID and only then sends call inputs; the caller verifies
  the token, lease capability and PID-bound registration immediately before it
  reads the selected value. The owner retains the lease through its core stop
  handshake and registers the lifecycle root and each pool-subtree PID as they
  appear. Gate failure during caller creation therefore leaves either no caller
  or a blocked caller that self-terminates, never an unregistered credential
  reader. Normal release requires every registered PID
  `DOWN` and starts a 5,000 ms quarantine at caller `DOWN` before a tool lease
  can be granted. That interval matches the isolated transport-drain witness;
  it does not observe or prove transport `DOWN`, and a slower drain is the named
  residual exposure. Cleanup-owner death never releases directly: the gate
  tells the registered lifecycle root to unwind, kills a still live registered
  caller, waits for every registered PID, and applies the same
  quarantine. The owner created and registered the start-blocked lifecycle root
  before setup, so no partial subtree can exist behind an unknown root PID.
- Before every local tool dispatch in an active ephemeral session, the executor
  runs the same PID/reference, result-before-normal-`DOWN` sensitive probe under
  the earlier of 1,000 ms and the job's existing absolute effective deadline.
  It registers the probe beneath the tools lease before granting the check. Any
  present variable, timeout, malformed result, abnormal or missing `DOWN`
  returns the existing fixed
  `{:refused_before_effect, :effect_start_authority_unavailable}` without
  starting an OS process; the missing-`DOWN` branch also freezes later executor
  dispatch and retains a gate obligation that poisons both modes. Exact normal
  `DOWN` is required before a clear result permits effect admission. Same-VM host code can still
  change the environment after either check or inspect another process; that is
  trusted host interference, not a structural isolation claim. A durable
  composition or directly constructed executor in the same VM is also not a
  gate participant. The gate proves only that the ephemeral composition does
  not schedule its credential-bearing call path beside its own active-tool
  path; a host needing exclusion from every in-VM executor gives this profile a
  dedicated VM.
- The executor's `bash` environment is constructed as `PATH=/usr/bin:/bin` and
  today removes only `LOOPEX_PROVIDER_API_KEY` after its snapshot of the
  environment (`executor.ex:5241-5258`); core's receipt validation rejects only
  that name (`session_state.ex:139`, `:3941`), and core is unchanged, so M6
  has only an executor instance carrying the explicit ephemeral tool-lease
  capability rework `spawn_environment` to remove `OPENAI_API_KEY`,
  `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY` explicitly as well. Durable and
  directly constructed instances without that capability preserve the M5
  environment behavior. The gate and dispatch check are
  the Loopex scheduling proof; scrubbing prevents ordinary inheritance but is
  not same-user isolation.
- **Private process-group proof.** M6 adds no executor-protocol member. Each
  ephemeral `Executor.Local` receives an explicit gate proof capability: the
  tool-lease capability for an active preset or the inactive-executor capability
  for `:tools :none`. It
  keeps a private set of group identities whose emptiness has not yet been
  proved. With serial tool execution it contains at most one: a group is
  discarded only after the existing process-table check proves it empty, and
  an interrupted or failed check remains and refuses later dispatch. After the
  run-ending wait, the process-groups phase worker calls
  `drain_process_groups(executor_pid, instance_ref, proof_capability,
  absolute_deadline)`. The absolute deadline is the owner's one monotonic
  cleanup deadline, not a relative timer. The call atomically refuses new
  dispatch, drains and checks that set, and returns exactly `{:ok, proof_nonce}`
  only after the gate has accepted a proof bound to that executor PID, instance
  reference, proof capability and fresh nonce; its only ordinary failure is
  `{:error, :process_groups_unproved}`. The owner validates the same nonce by a
  read-only capability call to the gate after the worker is `DOWN`. A malformed
  return, raise, exit, missed deadline, executor death, invalid proof or any
  remaining group leaves `:process_groups` pending. Once accepted, the gate
  retains the nonce and its complete binding through worker, executor and
  subtree `DOWN` and lease release; it remains queryable until the monitored
  session owner acknowledges its final cleanup disposition or dies. A later
  subtree-only cleanup retry therefore neither calls the ended executor nor
  replaces that proof. The worker then attempts
  runtime and subtree stop even when this proof failed, so a proof failure does
  not manufacture a live subtree; a deadline may leave both
  `:process_groups` and `:session_subtree` pending. For every ephemeral executor,
  the owner allocates the instance reference before the phase grant and
  `Executor.Local.init/1` registers `self()` under the session owner's admission
  as its first effect. For `:tools :none`, the exact reply issues an
  `:inactive_executor` proof capability rather than a tools lease. For an active
  preset it validates and binds the already-held tools lease. The executor
  accepts no definition or dispatch before that exact reply; an inactive one
  accepts none afterward and proves
  its private group set stayed empty; the gate binds the accepted nonce to the
  owner registration, executor PID and instance. No-executor startup rollback
  is the only proof that needs no executor handshake. Every registered
  executor, including `:tools :none`, must submit and have its nonce validated
  while it is alive; only afterward may subtree shutdown produce its `DOWN`.
  The gate releases a tool lease only after its
  proof and subtree `DOWN`; owner or worker testimony is insufficient. This is
  a private host-edge API, not a public `Loopex.Executor` callback or durable
  record.
- The ephemeral private subtree owns one `Loopex.Trace.Capability`, as the
  durable composition does through its credential plane. It starts before the
  runtime, supplies its handle to the model options, and is bound to the exact
  returned runtime before startup commits, so the caller can exclude itself
  from Loopex trace sessions (`trace.ex:56`).
- The in-process adapter owns exactly one credential-bearing adapter MFA:
  `{Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1}`. Its initial argument is the
  bounded credential-free call specification. After its start token and gate
  capability are verified, that function calls
  `Loopex.Trace.exclude_self(tracing_capability,
  functions: [{Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1}])` and requires
  exact `:ok` before the hosted branch reads the environment. An unavailable
  or malformed exclusion result is fixed `not_dispatched`, reads no credential,
  accepts no connection and takes owned teardown. No other adapter function
  receives or returns the resolved bytes; dependency calls occur from the
  already-excluded process. Ollama uses the same exclusion path without ever
  reading a credential.
- Before sending a mapped result to the owner, the caller recursively checks
  every provider-controlled binary in the mapped reply, including assistant
  text, tool-call fields and `provider_response_id`, for the exact resolved
  value. A match is discarded and becomes the fixed
  `dispatched_or_unknown` failure. The plan makes no claim to recognize an
  encoded or otherwise transformed derivative.

**Host hygiene** follows ADR 0039's technical companion, which states the start
table once:
- `loopex_llm_reqllm` declares `req_llm` with `runtime: false` and its new
  direct exact `req` and `finch` dependencies with `runtime: false`. Mix
  therefore compiles and embeds their code but places none of the three in
  `loopex_llm_reqllm.app`'s automatic application-start list.
  `loopex_composition` depends on
  `loopex_llm_reqllm` (`apps/loopex_composition/mix.exs:35`), which depends on
  `req_llm` (`apps/loopex_llm_reqllm/mix.exs:63`), so without this, starting
  either would start ReqLLM and load `.env`
  (`deps/req_llm/lib/req_llm/application.ex:25-31`) before any Loopex code ran;
- the escript and every build that carries the adapter still carry ReqLLM,
  Req and Finch code. The companion and a host OTP release list all three as
  `:load`; the guarded step starts `:req_llm`, whose application dependencies
  then start Req and Finch. The developer guide states this and fixture releases
  assert that the modules are present while all three applications remain
  stopped until that step;
- the companion worker already starts ReqLLM explicitly after its own settings
  (`provider_worker.ex:43`, `:78-79`) and is unchanged;
- the credential/tool gate serializes the start step in its receive loop; M6
  does not call `:global.trans/3`, whose lock acquisition is unbounded. The gate
  records one absolute decision deadline 5,000 ms ahead before any application-
  controller interaction, sets `trap_exit: true`, starts one linked and
  monitored non-trapping hygiene worker and remains responsive. The gate owns
  table evaluation and every marker write; the worker performs all potentially
  blocking application-state reads, `Application.put_env/4` and
  `Application.ensure_all_started/1`. It first sends the exact running/config
  snapshot and waits start-blocked for a correlated row directive. For row 4 or
  5 the gate writes persistent `:starting` before directing the first mutating
  configuration request. The worker and gate use the one decision deadline
  throughout, regardless of any later timeout internal to an application-
  controller call. The worker sends provisional
  `{worker_pid, ref, result, finished_at}` and remains blocked for a correlated
  `finish`. A matching result stamped no later than the decision deadline may
  win; at that deadline the gate performs one zero-wait receive before choosing
  the result. The gate then sets the reap deadline to the earlier of 1,000 ms
  after that choice and 6,000 ms after the decision began. For an in-time
  provisional result it sends `finish`; for a missing, malformed, late or
  otherwise unproved result it sends an untrappable kill. In either case it
  remains responsive and waits in bounded receives for the worker's exact
  `DOWN`, correlating both `EXIT` and `DOWN`, followed by one zero-wait receive
  at the reap deadline. Only an in-time valid result followed by exact normal
  `DOWN` permits the gate to replace
  `:starting` with exact `:started` for accepted success or restore the row's
  prior marker state for a returned error; the latter is
  `req_llm_start_failed`. Concurrent requests join the
  active decision under the same 7,000 ms outer bound, then re-evaluate the
  table; a returned failure answers the whole current cohort without an
  immediate second start. Two first compositions can therefore start ReqLLM
  only once. Exact gate `DOWN` makes each admitted external requester select the
  fixed failure under its gate monitor as stated above; no dead gate is assigned
  result ownership. A read or configuration timeout, malformed result, abnormal worker
  loss, or failure to observe exact normal worker `DOWN` after an in-
  time snapshot or result makes the decision unproved. After the reap interval,
  the surviving gate atomically poisons both ephemeral modes, fixes
  `req_llm_start_failed` for every requester in the admitted cohort, completes
  the aggregate poison-result handoff by the absolute 7,000 ms outer deadline
  and only then terminates the shared tree. Before a row-4/5 mutation directive
  it preserves the
  exact prior hygiene marker—absent or `:started`—rather than inventing
  `:starting`; after that directive every uncertain or late result retains
  `:starting` because controller mutation may have continued. A missing matching
  `DOWN` is logged without extending the outer bound or rolling the marker back.
  A read failure before mutation and exact normal
  worker `DOWN` returns the same fixed failure without changing the marker or
  poisoning the gate. The scheduling-gate poison makes every later composition
  refuse until VM restart even when the hygiene marker remained absent or
  `:started`; a retained `:starting` also survives an application restart. No
  owner reservation, root, credential read or effect exists at this phase.
  Requester death does not cancel an admitted start: the
  gate completes or bounds the decision and retains its result for later table
  evaluation. The `.env` setting and exact completed marker outlive a clean stop
  and restart of the Loopex application and any later restart of ReqLLM. A later
  composition therefore proceeds after a hygiene success only when the
  scheduling gate's separate unclean marker was erased by the exact
  `prep_stop/1`/`stop/1` handshake; a crash restart remains poisoned until VM
  restart. A host that turns loading back on is refused. The step never writes
  `warn_unverified_models`.

  The request that asks the gate to perform or join this decision uses the
  gate's fresh-reference, requester PID, absolute-expiry, idempotent-cancel and
  replay protocol with the same 7,000 ms outer deadline. The gate acknowledges
  start or join before controller work. Expiry or cancellation before admission
  performs no read, configuration or start, and a late dequeued request records
  fixed `req_llm_start_failed` without beginning work. Once admitted, requester
  death or a joiner's timeout does not cancel the shared cohort, but no stale
  reply can revive the abandoned composition.

**Errors.** The boundary is the call to `ReqLLM.generate_text/3` itself,
matching where the companion places its own call
(`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex:416-453`, citing ADR 0018).
The owner's one-shot grant is the exact internal network-dispatch fence, but
the public classification stays at the earlier `generate_text/3` boundary so a
failure is never made less conservative.
- **Before the call:** a refusal the adapter meets before calling
  `generate_text/3` is returned, never raised, as
  `{:error, {:not_dispatched, "model_call_failed"}}`. A raise is caught by the
  coordinator as `{:error, :provider_call_failed}`
  (`session_coordinator.ex:4149-4152`), which is `dispatched_or_unknown`. That
  covers model build, a missing credential, a failed guard, context, tools and
  options, and a deadline already elapsed. This is the only form the
  coordinator retries (`@attempt_limit 2`).
- **During core lifetime registration or activation:** the registrar is locked,
  process-local core code. If core interrupts that interval, the callback emits
  no adapter result and the coordinator's existing provider-call failure or
  cleanup-unproved path wins. It is not retried even though the adapter granted
  no network dispatch. Exact `:unmanaged` from `ProviderLifetime.starter/0`
  refuses before a candidate exists. Exact `:unmanaged` or
  `{:error, :provider_resource_refused}` from `ProviderLifetime.register/2`,
  with proved candidate `DOWN`, remains the pre-call `not_dispatched` form.
- **From the call on:** every return or raise from `generate_text/3`,
  including `{:error, _}` and a non-2xx status, is
  `{:error, {:dispatched_or_unknown, "model_call_failed"}}`, because the
  request may already have reached the server. A possibly delivered call is
  never retried.

**In-flight cleanup.** Each call uses ADR 0039's explicit
[per-call process](../adr/0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-tree):
an authority-free owner candidate that becomes the cleanup owner only after
exact managed core registration; the registered owner-created, monitored,
start-blocked pool-lifecycle root; the start-blocked sensitive caller, the only
process that can return the result; and an anonymous monitored supervisor
holding only the tagged user-managed pool. For a hosted call the gate creates
and registers that caller under its credential lease. For Ollama the registered
cleanup owner creates it and the gate registers it under the enclosing owner's
local-call capability, without a credential lease or quarantine. Both paths
register the lifecycle root and every pool child before work.

  In the callback process, `complete/3` first calls
  `ProviderLifetime.starter/0` (`provider_lifetime.ex:35-45`). Exact `:unmanaged`
  returns fixed `not_dispatched` without a proxy, child, credential read, pool or
  poison. Only
  `{:managed, starter}` proceeds. The callback retains a fresh one-use activation
  token and passes the opaque starter to one **unlinked**, monitored start proxy
  with a private reference and absolute start deadline equal to the earlier of
  the model-call deadline and 1,000 ms from start. The proxy monitors the
  callback, reports ready and invokes
  `ProviderLifetime.start_child(starter, child)` only
  after the callback's exact grant, the same transferable-starter pattern the
  locked companion uses (`provider_bridge.ex:69-79`, `:216-227`). Its child
  closure captures only callback and proxy PIDs, reference and deadline—never
  the activation token, request, options, credential, result or starter—and
  creates the candidate start-blocked. The candidate marks itself sensitive,
  monitors callback and proxy, checks the deadline,
  reports its PID directly to the callback and remains inert. The proxy reports
  the exact start return provisionally and waits for correlated `finish`.

  The callback reconciles matching proxy and candidate reports in either order,
  installs the candidate monitor and sends `finish`. On success the proxy sends
  exact `proxy_retiring` to the candidate before normal exit. Same-sender ordering
  means the candidate accepts normal proxy `DOWN` only after that notice; every
  earlier, abnormal or mismatching proxy `DOWN` ends it without work. The callback
  also requires exact normal proxy `DOWN`, then sends `registration_pending` with
  the exact private `stop_reference` that later core registration will use. The
  candidate validates and stores it before acknowledging. That acknowledgement
  cancels the short expiry but grants no request, credential, gate, root, pool,
  caller or dispatch authority.

  The callback alone enters the locked process-local
  `ProviderLifetime.register/2` registrar and cannot add a local timeout. Core
  first asks the provider worker to retain the candidate, then asks the provider
  guard to register it (`session_coordinator.ex:4172-4195`). Forced cleanup can
  discover a live callback's pending-resource slot or a registration queued at
  the guard (`session_coordinator.ex:4776-4849`), but normal stop kills the
  callback before inspecting the guard's registered resource
  (`session_coordinator.ex:4917-4919`, `:5859-5862`, `:6046-6049`). The locked
  worker-retained/guard-unregistered interval therefore cannot guarantee
  candidate `DOWN` before model settlement without a core change.

  On callback `DOWN` before `begin`, the candidate permanently disables
  activation, performs one zero-wait receive for an already queued matching core
  stop, acknowledges and exits if present, and otherwise exits without waiting.
  If guard registration committed, locked core observes the missing registered
  stop acknowledgement as `provider_cleanup_unproved`
  (`session_coordinator.ex:4621-4667`). If it did not commit, core may report its
  pre-registration model result with no registered provider-resource obligation
  before the authority-free candidate takes its
  first scheduled protocol step and exits. That result proves no call input or
  provider-call authority was released, not candidate `DOWN`. The candidate
  selects no fixed `not_dispatched` result, and no registration fallback timer
  exists. It remains a child of the session worker supervisor, so the complete
  session-subtree proof still reaps it before public session cleanup can be
  proved.

  Only exact `{:managed, retainer_pid, cleanup_grace_ms}` returned from
  `ProviderLifetime.register/2` converts the candidate into the cleanup owner and
  permits `activation_prepare` with the one-use token and that exact tuple. The
  owner validates it, monitors the retainer, records the token and acknowledges
  preparation while remaining inert. The callback then sends distinct `begin`;
  only the first exact token receipt authorizes gate, root, pool, caller,
  credential or dispatch work, and the owner acknowledges before accepting call
  inputs. Callback `DOWN` before `begin` follows the zero-wait rule above; after
  `begin`, the registered owner enters ordinary cleanup. A missing, late or
  malformed preparation or `begin` acknowledgement emits no adapter result and
  remains under that same core interruption and cleanup path.

  An exact returned start error plus normal proxy `DOWN` and no candidate report
  is clean `not_dispatched`. A missing, late, malformed or mismatching report,
  abnormal or missing proxy `DOWN`, or start expiry is unknown. The callback
  commits the shared poison latch first, withholds activation, kills every known
  proxy or candidate and waits at most 1,000 ms for known `DOWN` values before
  returning fixed `not_dispatched`. A killed proxy cannot retract a queued
  `Task.Supervisor.start_child/3` request. An undisclosed candidate that appears
  later sees dead proxy or callback, or the expired deadline, and exits without
  gate authority or a model request. Callback `DOWN` while the proxy is blocked leaves
  only that request-free, self-fencing path; when next scheduled, the proxy's
  callback monitor makes it retire. Late messages are ignored. A returned
  `:unmanaged` or `{:error, :provider_resource_refused}` from `register/2` plus
  exact candidate `DOWN` is clean `not_dispatched`; missing candidate `DOWN`
  first poisons admission.
  On `{:error, :provider_guard_unavailable}`, a registrar raise or malformed
  return, the callback kills and awaits the known candidate under the same
  1,000 ms proof and poison-on-missing-`DOWN` rule, then exits with fixed private
  reason `:provider_lifetime_registration_failed`. That exit remains outside the
  adapter's returned-error mapping; locked core catches and discards it as
  `{:error, :provider_call_failed}` (`session_coordinator.ex:4149-4152`), which
  keeps the conservative no-retry classification. Any fault after exact managed
  registration uses core's registered-resource stop, acknowledgement and `DOWN` proof and
  never substitutes fixed `not_dispatched` for unproved cleanup.

  After the start proof, the adapter monitors the candidate through registration
  and starts no pool, caller or credential read until the exact managed return
  arrives. Exact `:unmanaged`
  or `{:error, :provider_resource_refused}` sends the candidate's
  untrappable `:kill` and awaits its exact monitor `DOWN` for at most 1,000 ms.
  No cleanup grace exists until registration succeeds, and the start-blocked
  candidate has no resource or gate grant yet, so this is a private reap bound
  rather than a cooperative cleanup deadline. Exact `DOWN` returns fixed
  `not_dispatched`. If it is still absent, `complete/3` returns the same fixed
  result, logs the PID/monitor without its exit reason, poisons both ephemeral
  gate modes until VM restart and admits that the authority-free candidate may
  remain start-blocked until scheduled; no pool, caller, credential read or
  dispatch can occur from it. Guard-unavailable, raised or malformed registration uses
  the fixed private exit above, never a returned adapter `not_dispatched` value.
After the direct HTTP/1 worker call returns, the one-shot adapter waits while
the owner has the lifecycle root stop its anonymous supervisor gracefully. That
is an early cleanup path, not the only one: once the lifecycle root exists,
every later pool-child failure or partial start, terminal reply, refusal, caller-spawn
failure or exit starts or joins the same idempotent teardown. The owner proves
the lifecycle root, anonymous supervisor, pool supervisor and exact recorded
worker `DOWN` and both tagged registry entries absent before releasing the
adapter or any pre-adapter result. On normal completion it then ends and awaits
the blocked caller before sending its mapped reply to the waiting `complete/3`
callback. The registered owner stays alive while that callback returns. It
acknowledges the coordinator's subsequent provider-resource stop only after the
already-proved cleanup, and exits after the acknowledgement; this
reply-before-stop order keeps the registered resource alive for core's exact
handshake.
On a stop or deadline it first makes any reply inadmissible, kills and awaits
the caller, then cooperatively tears down and proves the pool before acknowledging
`{:loopex_provider_resource_stopped, stop, self()}`
(`session_coordinator.ex:4641`). It never kills the lifecycle root or pool
supervisor. A missing proof withholds the reply or acknowledgement, and the coordinator's existing
forced-stop and unproved-cleanup path applies (`:4646-4652`).

The caller performs HTTP/1 socket I/O, so killing it ends the only result path.
NimblePool sends check-in asynchronously
(`deps/nimble_pool/lib/nimble_pool.ex:461-471`) and closes a checked-out worker
only after it processes the caller's cancellation (`:669-675`, `:770-794`;
`deps/finch/lib/finch/http1/pool.ex:287-293`). Root shutdown can race either
message. Cleanup therefore does not claim that the checked-out socket or its OTP
TLS controller has finished when the owned caller and pool are proved gone.
Under isolated release conditions, server-observed EOF and every call-created
TLS controller must drain within 5,000 ms of caller `DOWN`; runtime cleanup does
not wait for or prove that threshold. No guarantee depends on a peer honoring
`Connection: close`; no result route or reusable TLS state remains, and TLS
reuse, tickets and secret retention are disabled.

**Diagnostics.** The host environment, calling process, tagged pool and TLS
state can expose the request and, for a hosted provider, its credential, as ADR
0039's vision amendment names. A log line written in the caller is suppressed
because the caller's level is `:none`; dependency-process logs, crash reports,
crash dumps and a host telemetry handler remain host-owned, and a copied value
can have a host-chosen lifetime. The `ask` command sets the primary logger level to
`:none`, renders its own lines, and sets `ERL_CRASH_DUMP=/dev/null` and
`ERL_CRASH_DUMP_SECONDS=0` for its own VM, matching the companion
(`provider_worker.ex:71-82`); the launcher also exports them when its first
argument is `ask` or `-p`. A library host owns its logger, crash dumps and
telemetry handlers, and the developer guide says what it takes on.

<a id="technical-plan-store"></a>
### The Memory Store Contract

Concept: [Scope](M6.md#concept-plan-scope).

**What the memory store is.** `Loopex.Store.Memory` is a supervised GenServer
over the shipped pure state module `Loopex.Store.Local.State`
(`apps/loopex_store_local/lib/loopex/store/local/state.ex`, 713 lines, no IO).
It is the same logic the local store replays from its log. It is the conformance
test wrapper `LoopexStoreLocalTest.Memory`
(`store_conformance_helper.exs:76-199`) promoted to library code:
- linked with `start_link`;
- it keeps the wrapper's GenServer state shape, so the conformance helper's
  `store_snapshot` (`store_conformance_helper.exs:1625`) reads it unchanged;
- it keeps an optional `:fault_probe` option. The option is active only when
  supplied, and follows the same checkpoint protocol as
  `Loopex.Store.Local.start_link(path:, fault_probe:)` (`local.ex:183`,
  `:242-257`), so the fault-injected cases (`each_store_with_unknown`,
  `:1017-1030`) exercise the shipped module. No composition passes a probe.

The core test fixture `Loopex.M1RuntimeTestStore` is not used: it is unlinked,
fault-instrumented, and grows without bound.

**Conformance.** The conformance helper's `:memory` kind switches from the test
wrapper to `Loopex.Store.Memory` itself (`start_store(:memory)`,
`store_conformance_helper.exs:1034-1038`). Every case, the fault-injected ones
included, then proves the shipped module.

**Truth statement.** Every committed record lives in the GenServer's state for
the life of the runtime and nowhere else. Stopping the runtime, or losing the VM,
loses the session, and no recovery is claimed. Memory grows with the session's
records, bounded by the runtime's existing turn, token and deadline bounds per
run but not across runs. That is a named limitation: an ephemeral session is
meant to be short, and a host that holds one open indefinitely pays for its
history.

**Artifacts.** The ephemeral profile composes no artifact store. Tool output over
a tool's byte bound is truncated with the executor's truncation notice and not
spilled (`executor.ex:4896-4920`), and the transfer family answers
`artifact_transfer_unsupported`. This is the same behaviour the runtime has always
had with `artifact_store: nil`.

<a id="technical-plan-composition"></a>
### The Composition Contract

Concept: [Scope](M6.md#concept-plan-scope).

After closed option and prompt validation, workspace and skill resolution,
provider admission and the pre-start Req, SSL and Tidewave guards, but before
ReqLLM hygiene or owner admission, `start_session/1`, and `run/2` through it,
ensure `:loopex_composition` is started. This placement is the single precedence chain
above: a workspace, skill, provider or pre-start guard refusal wins without an
application side effect, while bootstrap failure wins over every later hygiene
or lifecycle fault. Because `Application.ensure_all_started/1` can block in the
application controller, the entrypoint starts one unlinked, monitored
`ApplicationBootstrapGuard`. The guard monitors the requesting process, traps
exits only from its one linked, monitored, non-trapping bootstrap worker and
owns that worker's lifetime. Neither process receives model, credential,
workspace or root input.

The guard and requester share one absolute 5,000 ms decision deadline and one
further 1,000 ms reap deadline. The worker sends its
PID/reference/timestamp/result tuple to the guard and waits for correlated
`finish`; the guard validates and forwards that provisional tuple to the
requester. A requester `finish` goes through the guard to the worker. Only an
in-time `{:ok, started_apps}`, exact normal worker `DOWN`, the guard's correlated
reap acknowledgement and exact normal guard `DOWN` permit gate lookup. If the
requester dies or either deadline expires, the guard sends the worker an
untrappable kill, waits only to the reap deadline for exact `DOWN` and exits;
the guard's only normal exit follows exact worker `DOWN` and its reap
acknowledgement, and every earlier guard exit is non-normal so the link kills a
still-live non-trapping worker. A live requester
whose guard does not finish by the reap deadline kills the guard and performs
one zero-wait matching receive before returning failure. An exact returned
error, malformed or late result, abnormal exit, timeout, missing proof or either
missing `DOWN` returns `{:composition,
:composition_application_start_failed}`. An already submitted OTP controller
request may still finish after either process is killed; it has no session or
effect authority. A later session-creation entrypoint therefore calls
`ensure_all_started/1` again and accepts the controller's idempotent already-
started result. Concurrent first calls may each have a guard and worker, but OTP
serializes the one application start. The
generated `loopex_composition.app` omits ReqLLM, Req and Finch from its automatic
application set under the `runtime: false` declarations below, so this bootstrap
cannot precede the hygiene decision with a ReqLLM or `.env` start.

`ask/3`, `answer/3`, `last_result/1`, `history/1` and `stop_session/1` consume an
existing opaque handle and never run this bootstrap. Their lifecycle check keeps
the precedence fixed above: application, gate or owner loss makes the handle
closed or unavailable, and a handle call never restarts a new application tree.

The packaged escript sets `escript: [app: nil, ...]`. Its generated wrapper
loads the embedded code and configuration but starts no Loopex application
before `LoopexCli.main/1`. Main first performs only literal command
classification. For literal `ask` or `-p`, it completes the closed CLI grammar,
prompt acquisition and bounds, and profile selection before any Loopex
application start. Every malformed, incomplete or otherwise refused ask input returns
its fixed status and diagnostic with no Loopex application started. A valid
  ephemeral form invokes the public session-creation entrypoint above. A valid
  durable form invokes private `start_durable_ask_application/0` before
  credential discard or durable dispatch. Every argv not beginning with `ask` or
  `-p` invokes `start_legacy_application_or_halt/0` before existing dispatch.

`start_durable_ask_application/0` calls
`Application.ensure_all_started(:loopex_cli)`. Exact `{:ok, _}` continues. Every
returned error or malformed value and every raise, throw or exit is discarded;
the ask boundary renders only fixed `application_start_failed`, writes zero
standard-output bytes and exits status 1. It never calls
`Application.format_error/1` or passes an application term to another renderer.

  The legacy helper reproduces Mix's generated M5 wrapper, not a match assertion. It
calls `Application.ensure_all_started(:loopex_cli)`; `{:ok, _}` continues, while
`{:error, {app, reason}}` writes iodata consisting, in order, of the literal
"ERROR! Could not start application ", `Atom.to_string(app)`, the literal ": ",
`Application.format_error(reason)` and one LF to standard error, then calls
`:erlang.halt(1)`. The same helper runs
  before an unknown or released command, preserving the M6 CLI graph's dependency
order, output and failure semantics; ReqLLM, Req and Finch remain the separately
declared load-only exception. The split is exhaustive, so a stalled composition
application start cannot occur outside the bound for valid ephemeral `ask`, an
invalid ask cannot race application startup, and no released command silently
loses its former application startup.

**The ephemeral profile** (`LoopexComposition.Ephemeral`) starts, in order:
1. It completes the pure/workspace checks above through model prefix admission,
   the fixed expected-module lookup and the hosted-tools rule without a gate.
   It checks Req defaults, `SSLKEYLOGFILE` and Tidewave, runs the bounded
   application bootstrap, and only then obtains the composition application's
   explicit credential/tool-gate capability for the bounded ReqLLM hygiene
   decision. Only after that decision has either started ReqLLM or
   verified the host declaration does it query ReqLLM's initialized registry,
   require the exact expected module, select the explicit base URL or call that
   module's `default_base_url/0`, normalize the address and repeat the global
   guards. An unknown prefix therefore wins every later fault; for a known
   prefix, a replaced module wins an explicit or default-address fault. It
   acquires no mode lease and has no owner or root at this phase.
2. It reserves owner admission, completes the bounded temporary-owner start and
   exchanges that reservation for the still-root-blocked owner exactly as the
   owner-start protocol below states. Before acknowledging its post-exchange
   prepared state, and before any preflight, root token or dependency phase,
   the owner obtains `Loopex.Executor.default_cleanup_grace_ms/0` once and
   records that positive unsigned-64-bit cleanup grace. Only that registered
   owner may acquire a lease or later receive a root-start token.
3. Immediately after exchange the registered owner records one 5,000 ms
   absolute session-start deadline. For an active Ollama preset it atomically
   acquires a `:tools` lease before the sensitive preflight or temporary root;
   an active
   credential-call mode refuses `credential_call_active`, and an unavailable
   gate refuses `credential_tool_gate_unavailable`. A hosted or tool-free owner
   carries the capability but acquires no lease at composition. The active-
   Ollama preflight uses the registered PID/reference/result-before-normal-
   `DOWN` protocol above to prove all supported hosted-provider variables unset
   within that deadline and exits. The ordinary composition process validates fixed variable names but
   never reads a value. It then repeats the host-global, provider and address
   guards. `:loopex`,
   `:loopex_store_local` and `:loopex_executor_local` were already started with
   the composition application, and ReqLLM was handled by step 1. If the host
   already started Req, this cannot undo an
   earlier key-log file open, but it still prevents the call-owned pool from
   opening or appending while the variable is set.
4. After the gate issues the one-use root-start token, the granted
   `SessionRoot` startup actor creates the temporary root. Its first
   `candidate_prepare` grant permits only side-effect-free path preparation,
   not filesystem mutation. Under that grant it obtains one result from
   `System.tmp_dir!()`. The root
   helper has a private constructor-supplied zero-arity seam for that lookup and
   one-arity seam for entropy; production supplies only `&System.tmp_dir!/0` and
   `&:crypto.strong_rand_bytes/1`, and no public option or application setting
   can replace them. Tests use the same helper with injected values. A raise,
   throw, exit, non-binary result or invalid complete path from that lookup maps
  to `{:composition, :temporary_root_unusable}` before creation. The actor then
   obtains exactly 32 bytes from `:crypto.strong_rand_bytes/1` through a private
   injectable entropy seam and proposes `loopex-<nonce>`, where `<nonce>` is all
   64 lowercase hex characters. An entropy raise, throw, exit or result other
   than an exact 32-byte binary maps to
   `{:composition, :temporary_root_creation_failed}`. Before creation, the
   complete path must be valid UTF-8, contain no NUL and be at most 65,536 bytes;
   otherwise composition refuses `{:composition, :temporary_root_unusable}`
   without creating it. `File.mkdir/1` is the exclusive claim; `:eexist`
   consumes a new nonce, at most 16 attempts. Sixteen collisions or any other
   mkdir return, raise, throw or exit maps to
   `{:composition, :temporary_root_creation_failed}`. Immediately after a
   successful claim and before any child or file starts, the actor applies mode
   `0700`, `lstat`s the path and requires an ordinary directory owned by the
   current OS user, exact permission bits `0700` and an empty entry list. A
   chmod, lstat or listing failure, raise, throw, exit or mismatch uses startup
   cause `{:composition, :temporary_root_creation_failed}` and enters rollback.
   Proved removal returns that cause; inability to prove removal returns the
   ordinary `cleanup_unproved` root-removal case carrying it. Before each
   `mkdir`, the actor reports the candidate and waits for the owner to record and
   grant that exact claim. If the candidate-preparation grant has no exact
   candidate return by the startup deadline, the owner sends an untrappable kill
   and waits within that deadline. Exact actor `DOWN` returns
   `{:composition, :temporary_root_creation_failed}` with no root. Missing
   `DOWN` returns the same no-root failure, poisons both gate modes until VM
   restart and logs the retained monitor: the actor never received a mutation
   grant and cannot call `mkdir`; after owner loss it cannot obtain one. A grant
   for a recorded candidate with no exact mkdir return is
   `root_claim_unknown`: the path may have pre-existed, so Loopex does not remove
   it. After the actor is proved down and the final gate disposition is exactly
   acknowledged, it returns `cleanup_unproved` naming that possible path with
   `root_ownership: :unknown`, `pending: [:root_removal]`, `ending: :none` and
   `cause: {:composition, :temporary_root_creation_failed}`. A failed reached
   gate exchange instead returns the same map with only `:gate_release`, under
   the reached-phase rule; an unproved actor or subtree returns the same map with
   only `:session_subtree` and never reaches the exchange. The path is
   diagnostic only; the host is not told to remove or retry it. Before such a
   grant, actor loss cannot have changed the filesystem. The name is never
   accepted from the caller and a symlink or pre-existing path is never
   followed.
5. `Loopex.Store.Memory`.
6. `WorkspaceLease` on `:cwd`.
7. `Executor.Local`, with its ledger root at `<tmp>/receipts`, no artifact
   store and the explicit gate proof capability: the tools lease for an active
   preset, or the gate's owner-bound inactive-executor capability for
   `:tools :none`. An active executor uses it for the lease and presence check
   before every tool dispatch; an inactive executor has no definitions and
   cannot dispatch.
8. `Loopex.Trace.Capability`. `SessionRoot` starts it under the private
   supervisor, registers and monitors the returned PID, obtains and validates
   its exact handle, and passes only that handle into the model options below.
   A returned start, handle or validation failure maps to
   `trace_capability_start_failed` after proved rollback.
9. The `RuntimeHolder` and runtime, with:
   - `runtime_id: "ephemeral-<id>"`, where `<id>` is the first 32 lowercase hex
     characters of SHA-256 of the successful root nonce. It is generated once
     for this runtime, is 42 bytes, changes with a collision retry and is
     supplied explicitly to the unchanged required runtime option. Tests replace
     only the private entropy seam;
   - `store`;
   - `model`:
     `%{module: Loopex.LLM.ReqLLM.InProcess, model: "<provider:model>", options: [base_url: url, credential_variable: name_or_nil, tracing_capability: handle, credential_tool_gate: gate, provider_call_capability: owner_bound_capability]}`;
   - `executor`;
   - for `:tools` `:none`, both `tools: []` and `active_tools: []`;
   - for `:coding` or `:read_only`, `tools: CodingTools.definitions()` and the
     preset's exact active ids. This explicit empty-definition case is required
     because core interprets an empty active list beside non-empty definitions
     as all definitions during option inheritance;
   - `policy` and `policy_identity` (`%{"id" => inspect(policy), "revision" => "0.2.0"}`, the durable composition's default, fixed below);
   - `bounds`, `sampling`, `context_token_budget`, and the explicit committed
     previously recorded `cleanup_grace_ms` returned once by
     `Loopex.Executor.default_cleanup_grace_ms/0` (5,000 ms in the locked
     kernel);
   - `resource_manifest` from `:skills`.

10. After the exact runtime handle is registered, the owner grants one
    `trace_capability_bind` phase under the same startup deadline.
    `SessionRoot` calls `Loopex.Trace.Capability.bind(handle, runtime)` and
    requires exact `:ok`; it never retries a missing reply. A returned error is
    `trace_capability_bind_failed` after proved rollback. A deadline, actor loss
    or missing, malformed or late return after the grant is `start_unknown`,
    collapses the complete private subtree and retains the owned root with
    `:session_subtree` unproved. Only an exact bind return permits the prepared
    tuple and startup commit, so no session, prompt or model call can use an
    unbound capability.

The owner constructor has one private model-port builder dependency. Production
hard-codes the exact `Loopex.LLM.ReqLLM.InProcess` value above; API callers,
application configuration and session options cannot replace it. Composition
tests inject only a scripted implementation of the unchanged `Loopex.LLM` port
through that constructor seam, so API lifecycle and failure witnesses exercise
the real composition without network timing. The adapter's own suites and the
acceptance demonstration exercise the production builder.

**Refusals** name the step: `{:composition, reason}`.

**Owner admission and start.** After option validation and before a temporary
root, the entrypoint asks the gate for an owner reservation bound to the
creating process. A stopping gate returns
`{:composition, :ephemeral_admission_closed}`; a gate carrying the persistent
poison returns `{:composition, :ephemeral_admission_poisoned}`; an absent,
dead, exiting or malformed gate reply returns
`{:composition, :credential_tool_gate_unavailable}`. On a reservation, the
entrypoint starts the `restart: :temporary` owner under the owner
DynamicSupervisor. Owner `init/1` creates only its creator and guard monitors,
then returns `{:ok, start_blocked_state}` immediately; it does not use
`handle_continue/2` or wait inside `init/1`. That return is what lets
`DynamicSupervisor.start_child/2` return the owner PID. In its ordinary receive
loop the owner remains start-blocked: it creates no root, lease, application or
session and accepts no public request. A returned child-start failure or raise synchronously cancels
the reservation and returns `{:composition,
:ephemeral_owner_start_failed}`.

The entrypoint does not call the locked, potentially unbounded
`DynamicSupervisor.start_child/2` itself. It starts and monitors, but does not
link to, one `owner_start_guard`, then starts and monitors one non-trapping
`owner_start_worker`. Before that link can form, the guard sets
`Process.flag(:trap_exit, true)`; it monitors the creator and worker and
correlates both worker `EXIT` and `DOWN`. The worker links to the
guard, reports its PID to both guard and entrypoint and remains start-blocked;
only after both processes and monitors are known does the entrypoint send the
guard a correlated start grant. The guard relays that grant, and the worker
alone calls `start_child/2`. The responsive guard never enters that call. It
receives the exact return, records and monitors any returned owner PID, relays
the result to the entrypoint, and keeps custody until commit or cancellation.
The child specification gives the new owner the creator PID, guard PID,
reservation reference and expiry. The already-returned owner's post-`init/1`
receive loop accepts only the correlated private exchange, commit, cancellation
and monitored-lifetime messages until commit. Guard `DOWN`, creator `DOWN` or
expiry before a committed exchange makes it exit.

Creator `DOWN` for any reason makes the responsive guard send untrappable kills
to the worker and any returned owner, consume the worker's correlated `EXIT`,
await both exact `DOWN` messages, cancel the reservation and exit. The gate's independent creator monitor also releases
an unexchanged reservation. Unexpected guard death kills the linked,
non-trapping worker and makes a returned start-blocked owner exit through its
guard monitor. The entrypoint's monitor-only relationship means its own timeout
kill cannot propagate back into the host caller. A normal entrypoint path cannot
end before it has explicitly committed or canceled the handoff and reaped the
guard, worker and, on refusal, owner.

The guard treats a worker `EXIT` or `DOWN` before it has recorded an exact
`start_child/2` return as `start_result_unknown`; it does not infer that no
request was queued. It reports that correlated state to the entrypoint and
remains alive for cancellation. The worker's result send precedes its normal
exit signal to the same guard, so a recorded result followed by normal `DOWN`
is not reclassified. A guard `DOWN` before its commit acknowledgement is also
unknown to the entrypoint. Either unknown state takes the same shared-supervisor
kill, poison, cancellation and reap branch as expiration below, returning
`ephemeral_owner_start_failed`. This covers loss before the call, while it is
blocked and after an owner may have returned but before the guard relayed it.

After the guard relays the owner PID, the entrypoint monitors it and uses the
correlated gate protocol to exchange the reservation for that exact PID. A
stopping or poisoned gate keeps the corresponding reason above; gate loss keeps
`credential_tool_gate_unavailable`; a live-gate timeout, token/PID mismatch or
malformed exchange returns `ephemeral_owner_registration_failed`. On every
failed exchange the entrypoint tells the guard to cancel. The guard kills and
awaits the still-blocked owner and worker, sends the correlated reservation
cancellation and acknowledges only after both exact `DOWN` messages; the
entrypoint then awaits the guard's `DOWN` before returning. The gate rejects or
expires any late exchange. Gate loss invokes the one-for-all failure path, and
the entrypoint still requires owner, worker and guard `DOWN`; no root existed,
so none of these forms is `cleanup_unproved`.

If the guard does not relay a result, reports `start_result_unknown`, or dies
before commit, the entrypoint cannot know whether a
`start_child/2` request is queued. It kills the owner DynamicSupervisor, which
forces the one-for-all subtree through the already-poisoned application-failure
path, sends the worker and guard untrappable kills, cancels the reservation and
waits a second 1,000 ms reap bound. The unknown-start branch always leaves the
gate poisoned and requires VM restart, even when the owner DynamicSupervisor,
worker and guard monitors all report `DOWN`. In that case it returns
`{:composition, :ephemeral_owner_start_failed}` with no known residual helper.
A child whose PID never reached the guard may remain start-blocked until it is
scheduled and receives the dead-supervisor or expired-token signal; the plan
does not claim its synchronous `DOWN`, but it cannot create a root or effect. If
any known `DOWN` is still absent, the entrypoint returns the same error, leaves the
unclean marker and the gate poisoned for both modes, and records the missing
monitor in the host log. The already-sent untrappable kills may remain pending
until the suspended process is scheduled; neither process holds a live gate
capability, and any child started from the queued request receives an expired
token and exits from its start block without creating a root. This is the sole
startup-refusal case that may temporarily outlive the return, and it admits no
handle, root, credential read or effect. A VM restart is required before another
ephemeral session after every unknown-start branch. The entrypoint does not
exit the host caller. Only after an acknowledged gate exchange does the
entrypoint send a matching start-commit to the guard. The guard relays it to the
  owner. The owner validates it, obtains
  `Loopex.Executor.default_cleanup_grace_ms/0` exactly once, requires a positive
  unsigned-64-bit integer, records it, enters `commit_prepared` and replies
  `start_prepared`; it remains root-blocked and keeps its guard monitor. An
  impossible invalid locked-kernel value takes the same poisoned no-root
  `ephemeral_owner_start_failed` branch instead of authorizing preparation. The guard
relays that acknowledgement. The entrypoint then sends `retire_guard`; the guard
tells the owner it is retiring, the owner marks that exact retirement authorized
and removes its guard monitor while remaining root-blocked, and the guard relays
`guard_retired` before exiting normally. Messages from the guard reach the
entrypoint in send order, so its acknowledgement precedes its `DOWN`.

The entrypoint requires the guard and worker exact `DOWN` messages within the
remaining startup bound. Missing helper proof takes the same supervisor-kill,
poison and no-root refusal branch above. Only after both helpers are proved gone
does the entrypoint request a one-use release token from the exact gate
incarnation that exchanged the owner registration. The gate binds that token to
the reservation, owner PID and creator PID and sends it to the entrypoint; token
issuance is the release boundary. The entrypoint forwards only that token, and
the owner accepts it once only from its still-live monitored creator with the
exact binding. A gate `DOWN` delivered before its token—signals from that one
sender retain order—or creator loss before token issuance makes the owner exit
without a root. Once the gate issued the token, later gate loss is an ordinary
post-release application failure whether or not the creator managed to forward
it; if the owner received it, the bounded rollback below applies, while an owner
killed by the gate's one-for-all failure has the separately named unmarked-owner
root-retention limitation. The entrypoint never synthesizes a token from stored
gate identity or `Process.alive?/1`. Thus no guard, worker or cross-sender
`release_start` race can produce a no-root refusal after root creation.

**Startup completion and rollback.** `start_session/1` starts its supervised
owner and installs the creator monitor before creating the temporary root.
It reuses the one 5,000 ms absolute session-start deadline recorded immediately
after owner exchange, before any active-Ollama preflight, root lookup or private
process start. It starts one linked and
monitored, non-restarting `Ephemeral.SessionRoot` raw actor, which also monitors
the owner, reports a correlated `ready` before any dependency call and waits for
the owner's grant. The owner remains in its receive loop throughout startup.
The actor first executes the temporary-root protocol above through grant-gated
phases. It then becomes the lifetime OTP parent of an initially empty
`:one_for_all`, zero-restart-intensity private supervisor. It starts that
supervisor, reports its exact PID, and waits until the owner has installed its
own monitor and acknowledged it before any child start.

Store, workspace lease, executor, runtime trace capability and
`RuntimeHolder`/runtime then start in that fixed order; the post-runtime trace
bind follows before preparation.
Before each potentially blocking supervisor or runtime-start call, `SessionRoot`
sends `{phase_ready, root_pid, ref, phase}` and waits for a correlated owner
grant. Sending that grant is the phase's possible-start boundary. Every returned
child PID is sent to the owner and must be monitored and acknowledged before the
next phase. Before the executor grant the owner supplies the fresh instance
reference and private gate-client registration options. `Executor.Local.init/1`
registers its own PID with the gate before any other executor initialization;
the supervisor call cannot return a usable child until the exact capability
reply is installed. A lost supervisor return therefore remains the ordinary
granted-phase `start_unknown` case, while the gate and private supervisor retain
the self-registered PID for rollback. Because `Loopex.Runtime.start_link/1` returns a runtime handle only
after its own infinite readiness control call, the supervisor first starts one
side-effect-free, start-blocked `RuntimeHolder` child and registers its PID with
the owner. On a separate grant that holder calls `Loopex.Runtime.start_link/1`,
reports the handle and remains the runtime supervisor's OTP parent for the
session lifetime. No temporary starter becomes the parent of a surviving edge.
All phase messages carry the same root PID/reference and are ignored otherwise.

After every exact PID and runtime handle is registered and the trace capability
is exactly bound, `SessionRoot` sends one prepared tuple and remains blocked.
Only the owner's correlated commit moves it
to its lifetime loop and permits the linked and monitored core `FacadeClient`
actor to start. That client creates the session and attaches after event
sequence zero, remains the attachment holder and executes every later facade
operation under the bounded actor protocol above.
When the manifest has packs, it must then complete the admission and activation
state machine specified under **Skills by path**. An empty manifest submits no
resource command. Only successful attachment plus successful admission and all
activations may return a handle. No prompt, provider call or tool effect can
dispatch before that point.

Any failure from root creation through the last activation makes results
inadmissible and records exactly one `startup_cause`: the fixed composition
step, `{:composition, :dependency_start_failed}` for `SessionRoot` or private-
supervisor bootstrap before a named child phase,
`{:composition, :trace_capability_start_failed}` for a returned capability
start, handle or validation failure,
`{:composition, :trace_capability_bind_failed}` for an exact returned bind
failure,
`{:client_start, :failed}` when the core client actor cannot be created,
`{:session_create, :failed}`, `{:attach, :failed}`, the first refused,
malformed, raised, exited or mismatching admission/catalog step as
`{:resource_admission, :failed}`, or the first such activation as
`{:skill_activation, :failed}`. Admission or earlier accepted activation
commands may already exist in the memory store, but no prompt can observe them;
rollback destroys that store rather than trying to compensate with more
commands.

The 5,000 ms startup deadline is sliced and never passed whole to a BEAM timer.
A returned phase error remains that phase's fixed failure when the owner records
the exact return before the deadline and subsequently proves every applicable
known process `DOWN`. The side-effect-free candidate-preparation phase is the
one exception to the root-bearing rule: loss after its grant but before an exact
candidate report makes the owner kill the actor. Exact actor `DOWN` proves no
root exists, keeps the fixed phase error and permits the ordinary final gate
disposition; missing `DOWN` prevents that exchange and poisons both modes.
Once a candidate is recorded, loss after the
mkdir grant is the ownership-unknown branch. After an exact successful claim,
a deadline, malformed or lost dependency-phase return, creator loss,
or `SessionRoot`, private-supervisor, trace-capability process or
`RuntimeHolder` loss after a phase grant, or loss of the trace-bind reply after
its grant, before the exact phase return is `start_unknown`: even if every known monitor
later reports `DOWN`, an unreported child may exist. The owner makes results
inadmissible, sends untrappable kills to the exact known actor, supervisor and
holder PIDs, and enters rollback, but it never upgrades that branch to proved
cleanup from parent `DOWN`. It retains the owned temporary root and
`:session_subtree` obligation and returns no handle. If executor start might
have occurred, release of an active tool lease additionally requires the
existing process-group proof; inability to obtain it poisons both gate modes.
No prompt, provider call or tool dispatch is possible before the prepared
startup commits.

The preceding rollback branch assumes the owner remains alive. If the owner
itself dies at any time after the successful reservation exchange and before a
handle is returned, the entrypoint cannot act as a second session owner or
construct a cleanup map from state it does not own. Its owner monitor returns
the bare `{:error, :session_unavailable}`. Before the gate issues the root-start
token, no root can exist; the gate turns any registered preflight, lease or
owner obligation into its orphan-cleanup state and poisons both modes if that
release is unproved. After token issue, `SessionRoot`'s owner monitor prevents
later phase grants and collapses the private subtree; the gate retains every
already registered subtree, process-group or local-call obligation and poisons
both modes when their release is unproved. A post-token root can remain unnamed
under the existing unexpected-owner limitation. No process substitutes for the
dead owner, retries a phase or reports cleanup proved.

Rollback uses the same single monotonic `cleanup_grace_ms + 5_000` deadline as
`stop_session/1`. It first kills and awaits the linked, monitored core client
actor when one exists; a blocked create, attach, admission or activation cannot
survive rollback, and failure to observe its `DOWN` is `:session_subtree`. It
then uses the same ordered one-worker-per-phase protocol and 500 ms operation/
1,000 ms total phase slots for process-group proof, runtime stop and subtree
stop. The locked `Loopex.stop/1` or an infinite-shutdown child specification can
block only its own worker while the owner remains responsive. A phase worker
proved `DOWN` after failure permits the next independent phase; missing `DOWN`
prevents it. The owner checks every recorded child/root monitor and verifies any
started executor through the gate-bound process-group proof. After the actor,
every phase worker, every child and subtree root are `DOWN`,
an owner whose reservation was exchanged submits the same correlated final
gate disposition as ordinary stop and requires its exact acknowledgement. Only
after that acknowledgement does it start the exact separate removal worker and
require the owner-side absence check. A live actor, child or root returns
`cleanup_unproved` with `pending: [:session_subtree]`; an unproved executor
group uses `:process_groups`; a refused, malformed, late or missing final gate
acknowledgement uses permanent `:gate_release`, flips the poison latch and keeps
any possible root; a raised, exited, malformed, hung or ineffective removal uses
`:root_removal`.
The pending list uses the reached-phase rule above. Independently observed
process-group and subtree failures combine in that order; either prevents the
final gate exchange, so `:gate_release` is omitted. A failed final gate exchange
is reached only after those proofs and therefore appears alone; it prevents and
omits `:root_removal`. Root removal is reached only after the acknowledgement
and therefore also appears alone. A no-root actor failure that prevents the
final exchange returns its fixed phase error and poisons admission; it does not
misreport an exchange that was never attempted.
An abrupt VM exit is the separately named hard-kill limitation. Global
applications and the ReqLLM settings are not part of that subtree and retain
the VM lifetime stated below.

The private subtree is a `:one_for_all` supervisor with restart intensity zero,
owned for its lifetime by `SessionRoot`; the owner monitors both. No memory
store, lease, executor, trace capability, runtime or
session edge is restarted in place. The first unexpected child exit therefore
collapses the complete subtree; its `DOWN` makes the owner answer any still
waiting call through the session-failure cleanup path, perform the same cleanup
proof, and exit unmarked. With no registered waiter it follows the no-waiter
rule: no observation is invented, any retained root and obligations are logged,
and later calls through the open handle cell return bare `session_unavailable`.
A crash can never substitute an empty memory store or a new edge beneath an
existing session handle.

A proved returning startup failure leaves no per-session process, gate
registration, lease or
root and maps its cause to the corresponding fixed `{:composition, reason}`:
the named root/dependency/store/lease/executor/trace-capability/runtime reason,
or `client_start_failed`, `session_create_failed`, `attach_failed`,
`resource_admission_failed` or `skill_activation_failed` for those five causes.
If process-group, subtree, final gate-release or
recursive-removal proof fails, the API instead returns
`{:error, {:cleanup_unproved, unproved}}` with the applicable ordered pending
members, `ending: :none`, the fixed failing-step `cause`, and the retained root.
When no root or possible root ever existed, an unproved final gate release has
no truthful `cleanup_unproved.root`; it poisons both modes, logs the fixed gate
failure without a path and returns
`{:error, {:composition, :credential_tool_gate_unavailable}}` instead.
There is no session handle to retry. The host owns a root marked `:owned`; an
`:unknown` possible path is named for investigation and must not be removed on
Loopex's authority. If the caller exits
during startup, the owner performs the same rollback and logs the root and
cause only when removal fails. For an active-tool composition, rollback before
root registration can submit the final disposition only after the sensitive
preflight is down. After registration it can submit only after the complete
private subtree root is `DOWN` and the owner proves every executor process group
empty. In both cases only the gate's exact acknowledgement releases the owner
record and lease; failure poisons both modes for the VM. Root removal is never
the lease boundary.

**The durable profile** gains four optional composition options. The existing
`LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` entrypoints
share them because they already share the durable composition validator:
- `:model` (a `provider:model` string the single credential serves, default the
  pinned `anthropic:claude-haiku-4-5`; an `ollama:` model refuses
  `{:composition, :durable_model_unsupported}`, because the companion requires
  a credential);
- `:bounds`;
- `:sampling`;
- `:active_tools`, a list of defined tool ids, which defaults to the four coding
  tools, so a durable composition's active set is unchanged when three new tools
  are defined; naming `loopex.grep`, `loopex.find` or `loopex.ls` is allowed,
  with the rollback exception below.

Named directories are deliberately not a fifth option on these raw runtime
constructors: they return no session bootstrap object and therefore cannot
truthfully promise per-session admission or activation. An embedding host calls
the public `ResourcePacks.read_directories/2`, passes its returned `manifest`
through the already released `:resource_manifest` option, and drives ADR 0025's
admit/activate commands for each session. `ask --state-root` performs that host
workflow itself. This keeps the raw entrypoints constructible without changing
their return contracts or hiding a decision-bearing manifest.

The durable profile keeps the companion adapter and the single
`LOOPEX_PROVIDER_API_KEY` credential. A later decision on configuration (the M7
draft) may add per-provider credentials.

**Durable added-option grammar.** These three entrypoints preserve their
released outer option behavior. A non-list still returns
`{:error, :invalid_composition_options}`. Within the documented `keyword()`
contract, an unknown key remains ignored and a repeated key keeps its first
value through the existing `Keyword.get/3` and `Keyword.fetch/2` semantics.
M6 does not impose the ephemeral API's closed-list rules on these released
entrypoints. Existing recognized values keep their released validation. Each
added option has the closed value grammar below; an invalid first value returns
`{:error, {:invalid_composition_option, key}}` before an edge starts:

Validation order is fixed. After the outer list check, the released chain keeps
its exact precedence: policy, required `:state_root`/`:workspace`/`:runtime_id`,
`:recover_stale_writer`, `:artifact_transfers`, `:provider_launch`, resource
manifest, then workspace manifest. Only after all eight released stages succeed
does M6 validate `:model`, `:bounds`, `:sampling` and `:active_tools`, in that
order. A provider-specific composition refusal from a well-shaped model occurs
at the `:model` stage. Combined invalid existing/new and new/new options return
the first failure in this order; the option witness pins every adjacent pair.

| Added option | Accepted value | Default |
| --- | --- | --- |
| `:model` | A 1-to-512-byte valid UTF-8 `provider:model` string split at the first colon, with non-empty provider and remainder; later colons belong to the model id. `openai:`, `anthropic:` and `openrouter:` are admitted; well-shaped `ollama:` returns `{:composition, :durable_model_unsupported}`; every other prefix returns `{:composition, :unknown_provider}` | pinned `anthropic:claude-haiku-4-5` |
| `:bounds` | A map with no keys outside `:max_turns`, `:token_budget`, `:deadline_ms`; every present value is a positive unsigned-64-bit integer, and omitted members take the unchanged runtime defaults | all unchanged runtime defaults |
| `:sampling` | Exactly `%{"max_tokens" => n}` where `n` is an integer from 1 through 1,000,000 | `%{"max_tokens" => 4_096}` |
| `:active_tools` | A proper list of zero to seven unique strings, each exactly one of `loopex.read`, `loopex.write`, `loopex.edit`, `loopex.bash`, `loopex.grep`, `loopex.find`, `loopex.ls` | the four coding ids |

The durable companion never hands a caller-admitted duration to a ReqLLM or
OTP relative timer. Its streaming call now supplies `total_timeout: :infinity`,
`stream_idle_timeout: :infinity` and `receive_timeout: :infinity`; the unchanged
coordinator remains the sole deadline authority and spends the committed
absolute deadline in its existing one-hour timer slices
(`session_coordinator.ex:3601-3631`). The companion's bridge still refuses an
already elapsed deadline before handoff, and its framed socket waits already
slice the same absolute instant (`provider_codec.ex:160-207`). Thus the added
unsigned-64-bit `deadline_ms` grammar does not reach ReqLLM's unsliced
`Process.send_after/3`, while default and observable durable behavior stay M5.

Composition validates every requested active id before calling core; it never
lets `Runtime.Control` silently drop an unknown id. For an explicit empty
active list it composes the runtime with an empty tool-definition list, because
the unchanged runtime treats an empty selection beside non-empty definitions as
"all" during option inheritance. Every non-empty admitted list composes all
seven definitions and passes the exact selection. This keeps core unchanged and
makes `none`, coding and read-only command presets literal.

**The durable policy revision.** The default `policy_identity`
(`loopex_composition.ex:259-261`, the only place it is derived) changes its
revision from `Loopex.version()` to the fixed `"0.2.0"`. The revision is stored
with each interaction (`session_state.ex:1509`) and recovery compares it for
exact equality (`session_coordinator.ex:6593`), so a version-derived revision
would leave a pending interaction suspended after an upgrade to `0.3.0` or a
rollback to `0.2.0`. A host-supplied `:policy_identity` is unchanged.

**Skills by path.** `LoopexComposition.ResourcePacks.read_directories(paths,
workspace: dir)` builds a resource manifest from named skill directories.
Its public contract is closed:

```elixir
@type read_directories_reason ::
        :invalid_paths
        | :invalid_options
        | :workspace_unusable
        | :skill_directory_unusable
        | :unclassified_skill_directory
        | :duplicate_skill
        | :skill_manifest_invalid
@type shadowed_skill_id :: String.t()
@type read_directories_result :: %{
        manifest: map(),
        shadowed_skills: [shadowed_skill_id()]
      }
@spec read_directories(term(), term()) ::
        {:ok, read_directories_result()} | {:error, read_directories_reason()}
```

`paths` is a proper list of zero to four unique, non-empty, valid-UTF-8 path
strings, each at most 65,536 bytes with no NUL. A relative path is expanded
against the validated `workspace`; an absolute path stays absolute. The second
argument is a proper keyword list containing exactly one `:workspace`, with no
duplicate or unknown key. `workspace` has the same path domain and resolves to
an existing directory. The helper derives the executor-compatible opaque
`workspace_ref` itself with `WorkspaceIdentity.reference/1` after two matching
realpath-and-inode observations; callers cannot supply a conflicting label. A
malformed path list or path value, including a repeated byte-identical path
string, returns `:invalid_paths`; that complete path-shape pass runs before the
options-shape pass, so it also wins when both arguments are malformed. Malformed
options then return `:invalid_options`. Both passes finish before filesystem
access or pack classification. The helper next resolves and verifies the
workspace; `:workspace_unusable` therefore wins every named-directory failure.
It expands each relative input against that workspace, lexically normalizes the
complete absolute spelling without resolving links, sorts those spellings by
unsigned UTF-8 bytes, and inspects directories serially in that order. The first
failure stops the walk; no later directory is read. All filesystem failures
reading or resolving a named directory normalize to
`:skill_directory_unusable`; any pack validation failure normalizes to
`:skill_manifest_invalid`. This fixes multi-fault precedence independently of
caller input order. Boundaries map the
helper result once, with no profile-dependent choice left to an implementer:

| Helper result | Ephemeral API | `ask`, either profile |
| --- | --- | --- |
| `:invalid_paths` or `:invalid_options` | `{:error, {:invalid_option, :skills}}` | status 1, diagnostic code `invalid_skills`, zero stdout |
| `:workspace_unusable`, `:skill_directory_unusable`, `:unclassified_skill_directory`, `:duplicate_skill` or `:skill_manifest_invalid` | `{:error, {:composition, reason}}` | status 1, diagnostic code `skill_directories_unavailable`, zero stdout |

The ephemeral option validator detects five or more `:skills` entries before
the helper and returns `{:error, {:invalid_option, :too_many_skills}}`; `ask`
performs its common flag syntax and count checks first and reports five entries
  as status 1, diagnostic code `invalid_skills`, and zero stdout.

Each `shadowed_skill_id` is exactly `"user:<name>"`, the `source_id` of a user
pack omitted because the project pack with that name won. The result has exactly
`manifest` and `shadowed_skills`. `manifest` is exactly
the normalized plain-data manifest returned by `Loopex.ResourcePack.digest/1`
under ADR 0025's `loopex.resource_manifest/1` schema, with no added member.
Packs retain that validator's unsigned-bytewise `{source_id, name}` ordering;
each `shadowed_skills` member is exactly the omitted user pack's
`"user:<name>"` source id. The list is duplicate-free and sorted by unsigned
UTF-8 bytes. Input path order therefore cannot change either a successful
result or the first error atom.
`workspace` is the absolute workspace root the executor leases (`:cwd`), used
as the base for relative input paths and to classify packs; the derived
`workspace_ref` is the executor's opaque reference (`runtime.ex:921`) recorded
in the manifest. Existing discovery already takes both
(`resource_packs.ex:76-78`). What it does:
- **Validation:** the helper uses one named-pack variant of the existing
  `read_pack/3` traversal. It performs the non-following content walk once,
  carrying the counters through the actual regular-file collection rather than
  checking in a prewalk and then calling the existing unbounded
  `regular_files/5`: depth at most 32,
  at most 256 visited directories, 4,096 directory entries and 1 MiB of
  cumulative named-pack-root-relative path bytes, counting every entry type.
  The named pack root is depth zero and counts as the first visited directory.
  An entry at depth 32 is admitted, but encountering any entry beneath a
  depth-32 directory would be depth 33 and refuses. Each raw directory-list
  member increments the entry count before name, type or pack validation,
  including an invalid name, symlink or special entry. It contributes the byte
  length of its complete raw `/`-separated root-relative path, separators
  included and with no leading slash or terminator; the root contributes zero.
  A value exactly at 256 directories, 4,096 entries or 1,048,576 path bytes is
  admitted, and the first candidate that would make a value larger refuses
  before content from that candidate is retained. The same traversal admits
  exactly 64 regular files and 1,048,576 cumulative content bytes; the 65th file
  or first content byte beyond that ceiling refuses. Non-regular entries affect
  entry and path counts but not file or content counts. The first exceeded cap
  returns `:skill_manifest_invalid`. The same traversal
  requires `SKILL.md` with frontmatter whose name matches its directory, at most
  64 regular files and at most 1 MiB of regular-file content, and supplies the
  exact files from which the digest is computed. The traversal checks the caps
  after each directory enumeration. Existing project discovery keeps its M5
  `read_pack/3` path; only the public named-directory helper takes this bounded
  variant. The locked portable file API
  materializes one directory's complete name list before Loopex can count it;
  a single host-named directory with an enormous fan-out therefore remains a
  named synchronous allocation/input-cost limitation, not a claim of bounded
  memory against a hostile filesystem.
- **Classification,** after resolving the realpaths of the directory and of
  `workspace`:
  - exactly `<workspace>/.agents/skills/<name>`: a project skill, `source_id`
    `"project:<name>"`, the identity discovery already gives
    (`resource_packs.ex:797-803`);
  - not under `<workspace>`: a user skill, `source_id` `"user:<name>"`;
  - anywhere else under `<workspace>`: returned by this function as
    `{:error, :unclassified_skill_directory}` and mapped by composition as
    specified above.

  Both kinds carry `origin`, `commit` and `tree_digest` nil. Core's
  resource-pack validation accepts any bounded label as `source_id` and nil Git
  provenance (`resource_pack.ex:203-216`, `:343-348`), so it needs no change.
  A user skill's identity is bound to the content digest the manifest already
  records for its files; the admission decision binds the whole manifest's
  digest.
- **What is recorded:** the host path is never recorded. Only the identity,
  digests and admitted content enter the manifest.
- **Local wins.** A project skill and a user skill with the same name: the
  project skill is admitted, and the user skill is left out of the manifest and
  reported by its exact `"user:<name>"` source id (`shadowed_skills` in the API result, and in `ask`'s
  JSON). Because the shadowed pack never enters the manifest, core never sees
  an ambiguous name. Two distinct input path strings that resolve to directories
  of the same kind with the same skill name return
  `{:error, :duplicate_skill}`, which composition maps as specified above. The
  earlier lexical-duplicate rule therefore has one fixed precedence even when
  the repeated path would also identify the same pack.
- **No project discovery:** the ephemeral profile and `ask` never walk a
  directory on their own. There is no `AGENTS.md` prompt and no
  `.agents/skills` walk, because a headless caller cannot answer a prompt.
  `ask` always passes its `--skill-dir` list as the selected named-directory
  source, including an explicit empty manifest under `--state-root`, and omits
  both `:project_manifest` and `:project_decision`. Existing `run` and direct
  composition behavior remain unchanged.
- **Decision:** immediately before admission, the ephemeral session owner or
  durable `ask` host constructs exactly `%{"manifest_digest" => digest,
  "workspace_ref" => manifest["workspace_ref"], "trust_scope" =>
  "project_skills", "decision_source" => "host_supplied", "issued_at" =>
  timestamp, "expires_at" => nil, "revocation_state" => "active"}`. `timestamp`
  is the host clock in UTC, truncated to a whole second and encoded by
  `DateTime.to_iso8601/1`; tests inject that clock. Those are all and only the
  ADR 0025 decision members. The scope is the one core admits
  (`resource_pack.ex:125`), read as the named skills admitted for this
  workspace's session and bound to the executor's workspace. ADR 0039 decides
  that naming the path is the host's admission decision and that a user skill's
  `user:` identity is its truthful provenance.
- **Admission then activation.** After create and attach, and before returning
  an ephemeral handle or admitting an `ask` prompt, a non-empty manifest takes
  this exact serial path:
  1. submit one `admit_resources` command with a fresh bounded command id, the
     normalized manifest digest and the complete decision above; require the
     exact `{:accepted, same_id}` reply;
  2. call `resource_catalog/2` and require a success object whose configured and
     admitted digests both equal that digest, whose `decision_disposition` is
     `"active"`, and whose entries match every admitted pack's canonical
     `{source_id, name, pack_digest}` tuple with no missing, duplicate or extra
     tuple;
  3. in the normalized manifest's unsigned-bytewise `{source_id, name}` order,
     submit one `activate_skill` command per pack whose payload has exactly
     `manifest_digest: digest`, that pack's `source_id`, `name` and
     `pack_digest`, and `supporting_labels: []`, with a fresh bounded command id;
     wait for exact `{:accepted, same_id}` before the next command.

  The empty manifest submits no resource command, preserving 0.2 readability.
  A refused or malformed command reply, catalog error or mismatch, call raise,
  caller exit or session loss stops the sequence at its first failure. In the
  ephemeral profile the admission command and every catalog call or validation
  failure map to `{:composition, :resource_admission_failed}`; an activation step maps to
  `{:composition, :skill_activation_failed}`, and startup rollback destroys all
  partially committed memory-store state under the fixed cause above. No prompt,
  provider call or tool effect may precede the final acceptance. So ADR 0025's
  separation holds: only activated skills enter context, and the selection limit
  of four applies. A fifth directory refuses before composition as
  `{:invalid_option, :too_many_skills}`; a shadowed directory still counts
  toward the four.
- **Durable profile:** under `ask --state-root`, the
  admitted snapshot is retained under the state root by digest through the
  composition's released `retain_launch_option/2` seam and the admission is
  journaled as a reference, digest,
  decision and selections, as for any admitted pack. It passes the helper's
  manifest through the released `:resource_manifest` option, including the
  explicit empty manifest, and omits project discovery. A direct embedding host
  can perform the same constructible workflow: call the public helper, pass
  `result.manifest` as `:resource_manifest` to one of the released composition
  brackets so that bracket retains it once, then use that manifest after
  `Loopex.ResourcePack.digest/1` supplies its digest, workspace
  reference and canonical packs in the released ADR 0025 per-session commands.
  The raw durable composition entrypoints themselves
  submit no session command. Durable `ask --state-root` performs the exact
  three-step sequence above. If it fails after create, the durable journal keeps
  its actual possibly committed prefix, no prompt is admitted, the command exits status 1 with
  zero stdout, and the fresh session remains resumable; it is not rolled back or
  deleted.

<a id="technical-plan-command"></a>
### The Command Contract

Concept: [Scope](M6.md#concept-plan-scope).

**Grammar:**

```text
loopex ask [--model SPEC] [--output text|json] [--skill-dir DIR]... [--tools none|coding|read-only]
           --policy allow-all|shell-allowlist|refuse-all
           [--cwd DIR] [--max-steps N] [--deadline-ms N]
           [--state-root DIR] [--] [PROMPT...]
loopex -p ...        # the same as `loopex ask ...`
```

- `ask` extends the released `parse_command` grammar with its tabled flags, and
  `-p` is normalized to `ask` before parsing. Both `--key value` and
  `--key=value` are accepted. Flags may be interspersed with positional words
  until literal `--`; every later argv element is positional even when it begins
  with `--`. An unknown `--key`, a bare flag, a missing or empty value and a
  repeated non-repeatable flag refuse in the existing parser categories and map
  to the fixed `invalid_arguments` diagnostic below; `ask` never echoes the
  unbounded flag spelling.
  A one-dash token other than the leading command alias is a positional word,
  not an option. Only `--skill-dir` is repeatable for this command, in argv
  order, with the separate four-entry ceiling below.
- With one or more positional argv elements, the prompt is those exact elements
  joined by one ASCII space byte; standard input is not read. With zero
  positional elements, stdin supplies the prompt and its exact bytes are
  preserved, including leading or trailing whitespace and a terminal LF. Zero
  bytes is `empty`; whitespace is not normalized. The joined or read value then
  passes the API's UTF-8 and 32,768-byte validation. Standard input is read
  incrementally and retains at most 32,769 bytes; byte 32,769 refuses
  `too_large` immediately, without reading the remainder or starting a root,
  dependency or provider.
- `--skill-dir` is repeatable up to four times; every other flag may appear
  once. Each names a project or user skill directory under the composition's
  skill rule, classified against `--cwd`. It is named apart from `run`'s
  `--skill`, which selects an installed skill by name.
- `--tools read-only` activates exactly `loopex.read`, `loopex.grep`,
  `loopex.find` and `loopex.ls`; `--tools none` activates no tool. The same
  exact lists reach the durable profile under `--state-root`, with the rollback
  exception for the three M6-only ids.
- `--output` defaults to `text`.
- The command resolves `File.cwd/0` once when `--cwd` is omitted, validates the
  result under the same path rule as an explicit value, and always passes it as
  ephemeral `cwd:` or durable `workspace:`. Failure to resolve it refuses
  before either composition starts.

Every shared flag is translated exactly once; the command never forwards an
ephemeral option name to the durable composition:

| Flag | Ephemeral profile | Durable profile selected by `--state-root` |
| --- | --- | --- |
| `--state-root DIR` | absent; its presence selects the other column | `state_root: DIR`; after taking the existing placement lock, the command supplies `runtime_id:` from `Loopex.runtime_placement_id/1`, as `run` does |
| `--cwd DIR`, or the resolved command cwd when omitted | `cwd: DIR` | `workspace: DIR` |
| `--model SPEC` | `model: SPEC` | `model: SPEC` |
| `--tools none` | `tools: :none` | `active_tools: []` |
| `--tools coding` | `tools: :coding` | `active_tools: ["loopex.read", "loopex.write", "loopex.edit", "loopex.bash"]` |
| `--tools read-only` | `tools: :read_only` | `active_tools: ["loopex.read", "loopex.grep", "loopex.find", "loopex.ls"]` |
| each `--skill-dir DIR` | the complete `skills:` list, including `[]` | the helper builds one manifest from the complete list; `ask` passes it as the released `resource_manifest:` option, including the explicit empty manifest; no project discovery occurs |
| `--max-steps N` | `max_steps: N` | partial `bounds: %{max_turns: N}` |
| `--deadline-ms N` | `deadline_ms: N` | partial `bounds: %{deadline_ms: N}`; when both bound flags occur their members share one map |
| `--policy NAME` | the named reference policy module | the same module; the composition supplies its fixed default policy identity unless the host API overrides it |
| `--output MODE` | renderer only | renderer only |

Other omitted flags retain the selected composition's own defaults. In particular,
the durable partial `bounds` map is merged by `Loopex.Runtime` with its unchanged
token-budget and any omitted bound defaults; `ask` does not synthesize a second
set. All shared values use the embedded API's domains: paths have at most
65,536 valid UTF-8 bytes and no NUL, model specifications at most 512 bytes,
`--max-steps` and `--deadline-ms` are canonical positive decimal spellings of
unsigned 64-bit integers. A duplicate or out-of-domain flag refuses before
either composition starts.
- **Models.** Without `--state-root`, every model runs in-process; a hosted one
  needs its provider's own credential variable and `--tools none`. With
  `--state-root`, every
  model runs through the companion the escript embeds
  (`LoopexCli.ProviderLaunch.options/0`) with `LOOPEX_PROVIDER_API_KEY`, and
  `ollama:` refuses with status 1 as `durable_model_unsupported`. In `ask`'s own VM nothing
  starts ReqLLM before composition does, so `ask` always takes the start
  table's first-Loopex-owned-start row unless a deliberately injected malformed
  hygiene marker makes the earlier refusal row win.
- **Credentials at dispatch.** `composes_offline?` (`loopex_cli.ex:108-111`)
  includes both literal first arguments `ask` and `-p`, so
  `CredentialHost.discard/0` does not run before either alias
  chooses its profile. The durable profile then consumes
  `LOOPEX_PROVIDER_API_KEY` as `run` does; the ephemeral profile discards it
  unread and reads only the chosen provider's own variable, at each call.
- `refuse-all` joins the existing policy names. It becomes selectable for `ask`
  only.
- `ask` composes the ephemeral profile unless `--state-root` names a root.
  `LOOPEX_HOME` never switches profiles.
- With `--state-root`, it composes the durable profile and needs everything
  `run` needs: the built companion, `LOOPEX_PROVIDER_API_KEY` and a workspace.
  `--model` must then name a provider that credential serves.
- **Dispatch:** `main/1` treats a first argument of `ask` or `-p` as the `ask`
  subcommand. It is an offline form, and `--daemon` is not accepted.

**Command-boundary precedence.** After normalizing `-p` to `ask`, the parser
walks argv left to right and reports the first structural error (unknown or bare
flag, missing/empty value, or disallowed repetition). If parsing succeeds, it
validates the complete collected values in this fixed order: `--output`,
`--state-root` path shape, `--cwd` path shape, `--model`, `--tools`, the complete
`--skill-dir` count/path/lexical-duplicate set, `--max-steps`, `--deadline-ms`,
then required `--policy`. It next resolves and verifies cwd, validates the
prompt with the API's empty/size/UTF-8 precedence, runs the skill helper, and
only then enters the selected profile. The ephemeral profile continues with the
composition-guard order above. The durable profile checks its supported model,
then takes placement, derives the runtime id, consumes the credential and
composes in the numbered order below. The first failure wins; combined-fault
witnesses exercise every adjacent pair plus invalid output with bad cwd,
missing policy with invalid prompt or skill, and bad model with bad tools.

**Durable fresh-session algorithm.** `ask --state-root` reuses the released M5
primitives but fixes their order for a headless one-shot command. After common
flag, cwd, policy, prompt and named-directory argv/path-shape validation, it
runs exactly; the single helper call in step 1 owns all filesystem,
classification and pack validation:

1. Call `read_directories/2`. This helper call is read-only with respect to the
   state root; no placement or root identity exists yet.
2. Acquire the existing placement lock, derive `runtime_id` with
   `Loopex.runtime_placement_id/1`—which may create the root's identity record—
   obtain exactly one plane through the existing `hosted_plane/0` custody path
   (which consumes `LOOPEX_PROVIDER_API_KEY` once), and compute the follow-window
   duration from the already validated `--deadline-ms` or the released 600,000 ms default.
   Failure at any point releases what this step acquired and never reacquires a
   credential for a retry.
3. Call `LoopexComposition.with_runtime/2` with exactly these unconditional
   options: `runtime_id: placement`, `state_root: root`, `workspace: cwd`, the
   selected `policy:`, the resolved exact `active_tools:` list,
   `resource_manifest: result.manifest`,
   `provider_launch: LoopexCli.ProviderLaunch.options()`,
   `recover_stale_writer: true` and `credential_plane: plane`. Append `model:`
   only when `--model` was supplied and one partial `bounds:` map only when a
   bound flag was supplied. Omit `:project_manifest`, `:project_decision`,
   `:progress_to`, `:sampling` and every other optional composition key. The
   existing composition
   `retain_launch_option/2` retains `result.manifest` by digest exactly once,
   after the placement lock and before Store/session work. The command performs
   no separate retain and does not call the non-facade
   `Loopex.Runtime.configuration/1`. An inner `after` releases that exact plane
   only after `with_runtime/2` returns or raises; the outer placement-release
   `after` runs after plane release.
4. The `with_runtime/2` callback process drives every durable mutation
   synchronously through the public facade, as M5's `run` path does. It creates
   the session and owns the command attachment; no mutation helper, local timer or forced
   helper death adds a second source of mutation uncertainty. A public facade
   call can still return unavailable after core committed and before its reply,
   so any non-success is never retried and the durable prefix may include the
   attempted mutation. The existing interrupt handler remains the
   independently responsive signal path and submits only the ordinary public
   abort.
5. Create one fresh session with M5's exact `%{"surface" => "cli"}` options and
   one existing `unique_id/0` command id. Require exactly
   `{:ok, session_id}`, where `session_id` is non-empty valid UTF-8 of at most
   256 bytes. Before attach or any resource command, require
   `Loopex.track_session(state_root, session_id, placement)` to return exact
   `:ok`. Then require exact `{:ok, %Loopex.Attachment{} = attachment}` from
   attach after event sequence zero; for a non-empty manifest perform the
   exact admit/catalog/ordered-activation sequence above; read session status and
   require `{:ok, status}` where `status` is a map containing at least exact
   `status: :active` and `cleanup_grace_ms:` as a positive unsigned-64-bit
   integer. Additional released status members are accepted and ignored. Invoke
   the existing best-effort interrupt installation using that validated
   cleanup grace. `Interrupt.install/2` remains M5's always-`:ok` interface: an
   internal installation failure creates no new M6 workflow failure boundary
   and the command continues without a signal handler.
6. Submit one prompt with a fresh existing `unique_id/0` command id, retain that
   exact id as `prompt_command_id`, and require its exact accepted reply.
   Immediately after validating that reply and before starting
   the reader, record `follow_started_at` from the monotonic clock and compute
   the one saturating deadline as that instant plus the follow-window duration
   plus 30,000 ms. Startup, tracking and resource-admission time is therefore
   outside the follow window, and every `waited_ms` is measured from
   `follow_started_at`. The callback-owned command attachment is never used for
   `next_event/1`. The callback saves its prior trap-exit flag, sets
   `trap_exit: true`, and starts one linked and monitored `FollowReader` with the
   runtime, session id, a fresh reference and accepted cursor zero. The reader
   creates its own transient attachment with
   `after_event_sequence: accepted_cursor`, is its holder, and calls
   `next_event/1` serially. For each return it sends exactly
   `{reader_pid, ref, result, finished_at}` and waits start-blocked for either
   `{callback_pid, ref, :accept, next_cursor}` or
   `{callback_pid, ref, :finish}`. It accepts either only from the recorded
   callback. For `{:ok, event}`, the callback requires a bounded event with an
   integer `event_sequence` strictly greater than its accepted cursor, accepts
   it only when `finished_at` is no later than the one saturating monotonic
   follow deadline, advances to that exact sequence, and acknowledges it before
   the reader asks again. `{:error, :empty}` is acknowledged with the unchanged
   cursor and the reader waits at most 10 ms before asking again.

   The callback begins with `joined_run_id: nil`. It advances past every valid
   pre-join event without adding it to the render projection until it observes
   the exact `user.message_appended` event whose `"command_id"` equals
   `prompt_command_id`; that event's `"run_id"` must be a non-empty valid-UTF-8
   value of at most 256 bytes, which becomes the immutable
   `joined_run_id` (`session_state.ex:4387-4398`). Another matching command event,
   or one that changes the frozen run id, is malformed. After the join, only
   events whose `"run_id"` carries that exact value can change text, tools or the
   terminal result; valid events for another run still advance the disposable
   reader cursor but never enter the projection. A terminal event before the
   join or for another run is not this command's terminal. Expiry before the
   join returns `no_ending` with `run_id: null`; reader loss or a malformed join
   takes the fixed `session_unavailable` path. This command-to-run association,
   not event timing or adjacency, defines the selected run.

   The callback processes only the recorded reader PID and reference and
   correlates both its `EXIT` and `DOWN`. A terminal event starts one private
   1,000 ms reader-reap deadline, sends `:finish` and awaits exact normal
   `DOWN`. At the follow deadline it performs one zero-wait
   receive. An already-delivered matching return whose `finished_at` is no later
   than the deadline wins over expiry and is interpreted normally: a terminal
   wins; a nonterminal event advances the accepted cursor and partial projection,
   is acknowledged, and then expiry returns timeout with that projection; an
   empty return is acknowledged and then returns timeout; and a read failure
   returns `session_unavailable`. With no such queued return, or with one whose
   timestamp is later, expiry wins without accepting it. The callback then sends
   the reader `:finish` when it is waiting for acknowledgement, otherwise an
   untrappable kill, and starts the same 1,000 ms reap deadline. Exact `DOWN`
   within that interval permits the selected projection to return. If it is
   absent, the callback sends one untrappable kill if it has not already done
   so, consumes only an already-available matching `DOWN`, unlinks and
   demonitors the reader with a flush, discards the selected projection and
   returns fixed diagnostic `follow_reader_cleanup_unconfirmed`; it never waits
   beyond that private interval. Reader `DOWN`, attach refusal, disconnect, malformed
   return or any other read error before a terminal event yields the bounded
   `session_unavailable` result; no replacement reader is started. If the reader
   consumed an event but died before the callback accepted its message, only
   that disposable attachment advanced. The durable event remains replayable
   from the callback's unchanged accepted cursor, so the tracked session is left
   resumable and the command makes no no-loss claim for the transient
   attachment. The whole callback workflow is inside a `try` whose `after`
   block applies the same bounded reap protocol to any remaining reader and
   restores the prior trap-exit flag before the callback can return, raise,
   throw or exit. The link kills a
   reader blocked inside an infinite facade call if the callback itself dies
   untrappably. The callback performs no terminal output. It returns exactly one
   bounded internal render projection or one fixed diagnostic code. A reader
   whose `DOWN` was withheld may briefly survive unlinked until its already-sent
   kill is scheduled; it has no mutation capability, its disposable attachment
   is not durable truth, and `with_runtime/2` cleanup proceeds. The command does
   not claim synchronous death in that branch.

Every durable create, admission, activation and prompt operation uses the
existing CLI id shape, `"cli-"` plus 32 lowercase hex characters from 16 random
bytes. One id is generated before each facade call, retained until its reply,
and never regenerated or retried after dispatch. Every resource and prompt
reply must be exact `{:accepted, same_id}`; any other shape is that step's first
failure. Tests replace only the private entropy seam to assert exact commands
and replies. The separately retained M5 interrupt manager is unchanged: its
best-effort abort id is `"interrupt-"` plus 32 lowercase hex characters, it
accepts the released `{:accepted, binary_id}` shape without same-id correlation,
and it does not retry that abort. M6 does not use that legacy acceptance as
proof of a run ending or cleanup; only the followed terminal event does so.

Within the callback, the first workflow failure return wins. A create non-success
may follow a committed create whose reply was lost; the command has no session id,
does not retry or track it, writes zero stdout and makes no recovery claim. Track failure sends no
resource command or prompt, reports `session_tracking_failed` on stderr, exits 1 and
writes zero stdout. The retained snapshot and Store session are committed, but
the tracking error can occur before publication or after entry publication and
before directory fsync succeeds; the command neither retries nor claims whether
the session is listed or resumable. After tracking returns success, any attach,
admission, catalog, activation, status or prompt call that
does not return that step's exact required success shape exits 1 with zero stdout, leaves the listed
durable session and its actual possibly committed prefix resumable, and reports
that boundary's fixed diagnostic code. That prefix may include the attempted
admission, activation or prompt when core committed before its reply was lost;
the command never retries or claims otherwise. No prompt, provider call or tool
dispatch precedes returned success from every resource activation. After an
exact prompt-acceptance reply, the run or no-ending result wins.

`with_runtime/2` is the one runtime/edge stop acknowledgement. Its released
contract returns the callback result only after confirmed cleanup and replaces a
normally returned callback value with
`{:error, {:composition_cleanup_unconfirmed, details}}` when cleanup is
unconfirmed. The callback has emitted nothing, so replacement can discard its
projection completely. Durable `ask` never inspects or formats `details`: it
maps every such replacement to status 1, zero stdout and the exact stderr line
`loopex: runtime_cleanup_unconfirmed\n`. The inner `after` releases the plane,
then the outer `after` releases the placement lock, on every handled path. Only
after both releases does the command render exactly once from the surviving
bounded projection or fixed diagnostic. Only the separately named hard halt
can skip release or rendering.

**Durable follow window.** The client wait is the resolved committed
`deadline_ms` plus 30,000 ms, saturating at unsigned-64-bit maximum. It is one
monotonic deadline recorded immediately after exact prompt acceptance and
before reader creation, polled in at-most-1,000 ms slices and never passed whole
to an OTP timer. `{:error, :empty}` sleeps at most 10 ms and continues. The
joined run's terminal event ends the wait. `{:disconnected, last_sequence}`, any
other documented reader-attachment error, `FollowReader` `DOWN`, or an unexpected
return after prompt acceptance yields the bounded `session_unavailable`
no-ending projection; expiry yields the bounded `timeout` projection. Both are
status 6 and leave the tracked durable state resumable. A corresponding failure
before prompt acceptance is the status-1 step failure above. `waited_ms` is the
saturated monotonic duration since that same recorded instant. The default resolved deadline is the
runtime's released 600,000 ms; the unsigned-64-bit maximum and addition overflow
use the same sliced saturation rule. A private constructor-supplied monotonic-
clock seam supplies production `System.monotonic_time(:millisecond)` and lets
the workflow witness fix acceptance, return and expiry instants; it is not a
CLI flag, composition option or application setting.

**Text output.**
- On `completed`, standard output carries only the final assistant text followed
  by a newline. Every other outcome leaves standard output empty.
- Standard error carries one `tool <outcome> <id>` line for each returned tool.
  A terminal observation is followed by exactly `ending <outcome><LF>`; a
  no-ending observation is followed by exactly
  `ending no_ending <reason><LF>`, where `<reason>` is literal `timeout` or
  `session_unavailable`. `<id>` is either literal `null` for
  an unresolved tool or the JSON-string encoding
  of the first 1,024 UTF-8 bytes of the identifier, cut at a code-point boundary
  and followed by `...` inside the string when bytes were omitted. These are
  bounded summaries from the public terminal observation or no-ending snapshot. `ask` emits no
  started, progress or artifact lines and does not read the private attachment.

**JSON output.** The compact JSON encoding of one object, followed by exactly
one LF, is written to standard output at the end; there is no other standard-
output byte for any run outcome or public no-ending observation.
JSON mode emits no tool or ending summary on standard error. For a run or no-
ending observation with proved ephemeral cleanup, or for any durable
observation, standard error is empty. An unproved ephemeral cleanup emits only
the retained-root diagnostic below; a status-1 refusal or command failure emits
only its fixed diagnostic. Thus every fact duplicated as a text-mode summary is
carried only in the JSON object in JSON mode.
A status 1 refusal or command/lifecycle failure writes nothing to standard
output. Except for the ordinary worker-reap hard halt named below, it writes
the one bounded diagnostic selected by the diagnostic contract. In particular,
if an unmarked owner or scheduling-gate crash makes
`stop_session/1` return bare `:session_unavailable`, the command cannot
construct a public cleanup proof and discards any earlier run observation
rather than emit a misleading object. One public `cleanup_unproved` map is
enough to override that general rule: it supplies the retained root, cleanup
state and ending under the precedence below, while an earlier such map survives
a later bare-unavailable stop. A post-admission
  `session_unavailable` snapshot before a terminal event exists only inside that
  map and renders with `{"proved": false}`. The ephemeral command otherwise
constructs the object only from the public completed result, run-error
observation, no-ending snapshot or `cleanup_unproved.ending`, plus the
public return from `stop_session/1`. It does not inspect the opaque handle or
read the attachment. The durable command keeps its existing attachment reader
and projects the same schema.

```json
{"schema": "loopex.ask/1", "session_id": "...", "run_id": "...",
 "outcome": "completed", "text": "...", "text_truncated": false,
 "profile": "ephemeral",
 "tools": [{"tool_id": "loopex.read", "outcome": "completed"}], "tools_truncated": false,
 "shadowed_skills": [],
 "cleanup": {"proved": true},
 "details": {"cleanup_grace_ms": "5000"}}
```

**The member set is closed.** The top-level members are exactly those above,
as ADR 0039 lists them. For a terminal outcome, `details` is a projection of the
`run.finished` payload (`session_state.ex:2880-2897`, `:4566-4576`,
`:6061-6075`). For `no_ending`, it comes from the public no-ending error. Each
has exactly the members below, uses `null` only where stated, and drops every
other source member:

| Member | Type and empty or null rule |
| --- | --- |
| `schema` | string, exactly `loopex.ask/1` |
| `session_id` | non-empty string |
| `run_id` | non-empty string, except null for `no_ending` when no run id was learned |
| `profile` | string, exactly `ephemeral` or `durable` |
| `outcome` | string, one value in the outcome table below |
| `text` | string; `""` when the run produced no assistant message |
| `text_truncated` | boolean; false when `text` is empty or was not cut |
| `tools` | array of objects with exactly two members: `tool_id`, either the resolved `tool.finished` definition id as a non-empty valid-UTF-8 string of at most 128 bytes or null only for an unresolved call, and `outcome`, exactly `completed`, `failed`, `denied`, `cancelled`, `cancelled_workspace_lease_lost` or `outcome_unknown`; `[]` when none were observed |
| `tools_truncated` | boolean; false when `tools` was not cut |
| `shadowed_skills` | array of strings; `[]` when none were shadowed |
| `cleanup` | ephemeral cleanup object, or null for the durable profile; never another scalar |
| `details` | object with exactly the outcome-specific members below |

For every outcome and both profiles, `text` is the last
`assistant.message_appended` content for this run, or `""` when the run has no
such event. `tools` is the 256 most recent `tool.finished` projections for this
run in ascending `event_sequence` order. `shadowed_skills` is the composition's
deterministic, unsigned-bytewise-sorted list of omitted `"user:<name>"` source
ids. A failed, bounded, unknown, cancelled or no-ending object never borrows an
event from an earlier run.

| `outcome` | `details` members |
| --- | --- |
| `completed`, `cancelled` | `cleanup_grace_ms` |
| `failed` | `reason`, `failure` (`category`, `retryable`, `dimension`, `observed`, `limit`), `cleanup_grace_ms` |
| `bound_reached` | `bound`, `observed`, `declared_limit`, `accounting_source`, `cleanup_grace_ms` |
| `outcome_unknown` | `reconciliation_ref`, `cleanup_grace_ms` |
| `no_ending` (status 6) | `reason`, `waited_ms`; `run_id` is then the run's id if known, else `null` |

The outcome-specific members have these exact JSON types and null rules:

| Member | Type and null rule |
| --- | --- |
| `cleanup_grace_ms` | canonical positive decimal string; never null |
| `reason` | for `failed`, string exactly `model_call_failed` or `unreadable_model_answer`, or null, with exactly one of `reason` and `failure` non-null; for `no_ending`, string exactly `timeout` or `session_unavailable`, never null |
| `failure` | object or null; when non-null it has exactly `category`, `retryable`, `dimension`, `observed` and `limit` |
| `failure.category` | string exactly `deadline_preflight_failed` or `context_budget_exceeded`; never null when `failure` is non-null |
| `failure.retryable` | boolean, exactly false; never null when `failure` is non-null |
| `failure.dimension` | null for `deadline_preflight_failed`; otherwise one of `system_class_tokens`, `context_tokens`, `context_record_bytes`, `context_record_depth` or `context_record_cardinality` |
| `failure.observed`, `failure.limit` | null for `deadline_preflight_failed`; otherwise canonical decimal strings (`observed` is non-negative and `limit` positive) |
| `bound` | string exactly `max_turns`, `token_budget` or `deadline`; never null for `bound_reached` |
| `observed`, `declared_limit` | canonical non-negative decimal strings; never null for `bound_reached` |
| `accounting_source` | string exactly `reported` or `estimated`, or null when no provider accounting supplied the bound |
| `reconciliation_ref` | non-empty string; never null for `outcome_unknown` |
| `waited_ms` | canonical non-negative decimal string; never null for `no_ending` |

Every canonical decimal string is lowercase ASCII digits, has no leading zero
except the value `"0"` and preserves the exact non-negative Elixir integer.
Declared limits, waits and grace values are unsigned 64-bit; `observed` values
may reach the exact `3 * uint64 - 1` usage-accounting ceiling. Both domains are
at most 20 decimal bytes. Quantities are strings because the independent
Node consumer cannot exactly represent every accepted integer as a JSON number;
this follows the canonical decimal-string wire rule in ADR 0023 rather than
silently rounding above `2^53 - 1`.

**Bounds.** `text` is at most 64 KiB, cut at a UTF-8 boundary with
`text_truncated` true; `tools` at most 256 entries, with `tools_truncated`;
`shadowed_skills` at most four source ids; every other string is at most 1 KiB,
the runtime's own identifiers already being shorter, except `cleanup.root`,
which is untruncated and at most 65,536 bytes by path admission. The pending
interaction's separate `tool_call_id` keeps its 65,536-byte bound.
Canonical decimal quantities are at most 20 bytes.

**Cleanup.** `cleanup` is `{"proved": true}`, or, when the latest public
`cleanup_unproved` map came from the worker or `stop_session/1` in the ephemeral
profile, `{"proved": false, "root": "...", "root_ownership": "owned" | "unknown", "pending": [...]}`. The false form's `root` is a string; `root_ownership` is the exact projection of the public cleanup map and `unknown` never authorizes deletion. `pending` is a
non-empty array containing only `"run_ending"`, `"effect_cleanup"`,
`"process_groups"`, `"session_subtree"`, `"gate_release"` or `"root_removal"`, in that order
with no duplicates.
The true form means both process cleanup and temporary-root removal succeeded.
The exit status still reports the run's outcome, and standard error names the
kept root. A bare unavailable stop has no representable cleanup value and takes
the status 1, no-standard-output rule above unless the worker already supplied
  the proof-bearing cleanup map above. A post-admission snapshotted session loss
  renders status 6 with unproved cleanup and its retained root. For an earlier cleanup map,
a successful retrying stop renders its retained ending with `{"proved": true}`;
a newer
`cleanup_unproved` stop return replaces the earlier cleanup map; and a bare
unavailable stop preserves the earlier map and renders its retained ending.
If the selected cleanup map has `ending: :none`, there is no run observation to
render: the command exits status 1 with no standard-output bytes and names the
map's retained root on standard error. A successful retry before that case has
no retained root left to name and reports only `session_unavailable`.
These are the same precedence rules as `run/2`. A durable run's `cleanup` is `null`: `ask`
performs no ephemeral cleanup proof, its offline BEAM exits, and the durable
state remains resumable.

Usage and model identity are not public events, so the object does not claim
them. Adding a member is a new schema name.

**Interrupts.** After an ephemeral `start_session/1` returns its handle and
before the run starts, the command calls the new internal
`Interrupt.install_ask(main_pid, ref)` and requires exact
`{:ok, signal_manager_pid}` for the exact `:erl_signal_server` manager on which
the `:gen_event` handler was installed. Installation has a private 1,000 ms
bound. That correlated mode uses the existing 10,000 ms backstop. Refusal,
malformed return, duplicate active-handler claim or manager
loss before exact success makes the main process call bounded
`stop_session/1`; normal pre-run cleanup precedence then yields fixed diagnostic
`interrupt_handler_unavailable`, or the real retained-root diagnostic, and
status 1 with zero standard output. No ask worker starts and the command makes
no interrupt-handling claim on that path. The command's main process owns the
handle, monitors the returned signal-manager PID and then starts a monitored worker
whose only job is the blocking `ask/3` call. The main process waits for either
that worker's one result, its exact monitor `DOWN`, signal-manager `DOWN`, or a signal notice.
The worker sends `{worker_pid, ref, result}` before a normal exit; signal ordering
from that worker places the result before its `DOWN`, and on `DOWN` the main
process performs one zero-wait receive so a queued matching result wins. A
matching `DOWN` without a result is a command-path failure: the main process
calls bounded `stop_session/1` before rendering. A stop-supplied terminal or no-
ending value inside `cleanup_unproved.ending` is rendered with that cleanup; an
`:ending` of `:none`, successful stop with no observation, or bare unavailable
stop writes no standard-output byte and exits status 1, while still emitting the
fixed owned/unknown-root diagnostic when the cleanup map provides one. No
worker failure invents an observation or leaves the owned session unstopped.
If signal-manager `DOWN` wins, one zero-wait receive admits an already-queued
matching worker result; otherwise the main takes the same bounded installation-
failure stop and diagnostic path.

A worker result is provisional until its exact `DOWN`, mandatory
`stop_session/1` and one signal-manager decision all finish. Ask mode remains
installed. On the provisional result the main starts one private 1,000 ms reap
deadline and awaits the exact worker `DOWN` in bounded slices. At expiry it
sends that worker an untrappable kill and performs one zero-wait receive for the
same `DOWN`. If it is still absent, the result is inadmissible and the command
immediately hard-halts with status 1, with no output or cleanup promise; it does
not enter stop or finish while an unproved command worker can still use the
handle. That bounded fault is a named limitation. Once exact `DOWN` is proved,
the main calls the bounded stop, and the observation plus stop return use the
same precedence as `run/2`. The main then calls
`Interrupt.finish_ask(signal_manager_pid, ref)` as a synchronous, correlated
`:gen_event.call` to that exact PID with a private 1,000 ms bound. The handler
serializes this call with signal callbacks and atomically returns exactly
`{:ok, :ordinary}` when it was still idle for `ref`, or
`{:ok, :interrupted}` when a first signal had already changed it to
`stopping(ref)`. Either exact reply disarms the matching backstop, removes ask
mode and retires the main monitor. `:ordinary` permits one normal render from the
provisional observation and stop return. `:interrupted` discards normal text
rendering and takes the status-130 interrupt projection below. A missing,
malformed, late or mismatched reply, handler absence or manager loss makes the
result inadmissible: because stop has already run, the command emits only the
real retained-root diagnostic when the stop return supplies one, otherwise
`interrupt_handler_unavailable`, writes zero standard-output bytes and exits 1.
Thus a signal before or during mandatory stop and ordinary completion cannot
both win, and no live handle is left after the handler is disarmed. The exact
finish transition is the linearization point: a signal callback serialized
before it wins `:interrupted`; one serialized afterward is a post-run process
signal outside this completed ask and cannot resurrect or replace its stop.
Entering ask mode records the main PID and a fresh reference in the existing
signal handler. An *ask interrupt notice* is any member of the handler's
existing in-VM set `SIGTERM`, `SIGHUP` or `SIGQUIT`; an operator's terminal
`SIGINT` reaches it as the launcher's existing forwarded `SIGTERM`. The first
handled member atomically changes the handler's state from `idle` to
`stopping(ref)`, arms the one existing interrupt backstop and sends exactly
`{signal_manager_pid, ref, :interrupt}` from the callback's `self()` once to
that main PID. The
main accepts only that recorded PID/reference and ignores forged, stale or
same-reference replayed notices. From the instant the handle exists, it calls bounded `stop_session/1`
whether or not the worker has entered `ask/3`. If the worker is registered, the
session owner serializes the ask and stop, remains the only attachment reader,
and replies to the worker as the stop contract states. After stop selects, the
main performs one zero-wait receive for the matching worker result and `DOWN`.
If `DOWN` is absent it sends that exact worker an untrappable kill and uses one
private 1,000 ms reap deadline, never beyond the already-armed backstop. Exact
`DOWN` triggers one final zero-wait receive in which an already-queued matching
result wins; with no result, rendering uses only the stop return. A result
without exact `DOWN`, or a worker whose `DOWN` is still absent at the reap
deadline, invokes the named status-130 hard halt and promises no output. Thus
the main renders at most once and never leaves the command worker alive. If
stop wins before owner registration, a successful stop followed by the worker's
bare `session_closed`, or a bare `session_unavailable` with no proof-bearing
cleanup map, writes zero standard-output bytes, invents no `no_ending`
snapshot, emits only a retained-root diagnostic that an actual cleanup map
provides, and exits 130. Under
JSON output it emits the observed terminal outcome when one arrived, or
`no_ending` from the worker's bounded no-ending snapshot when none did, with
the exact `timeout` or `session_unavailable` reason and cleanup proof or
kept-root failure. A bare-unavailable stop caused by an unmarked owner/gate
failure cannot construct that object and emits no standard output. Text output emits no answer after an
interrupt; both modes name an unproved root on standard error and exit 130. A
later handled member of that set while the handler remains in `stopping(ref)`, or expiry
of that backstop after the stop bound, calls `System.halt(130)` and is the named
hard-kill case: no output or root cleanup is then promised. Every orderly path,
including the one entered from a signal notice, uses the exact synchronous
`finish_ask/2` transition above after stop and worker reap; the handler also
monitors the main and disarms on its `DOWN`.

Before a session handle exists, no ask-mode handler has a stop target. For
`ask` and `-p`, the launcher therefore latches any `INT`, `TERM`, `HUP` or
`QUIT` received before its child PID is assigned, forwards `TERM` immediately
after assignment, and continues its existing reap loop until the child is gone.
It also forwards later members as it does today. This closes the lost-signal
window but deliberately promises no Loopex exit status or cleanup for the pre-
handle interval; the platform child status is returned. No JSON or text result
is promised there. Durable `ask` retains the existing attachment-abort behavior
and resumable state after its handler is installed.

**Bounded command diagnostics.** Except for the ordinary worker-reap hard halt,
which terminates before rendering and promises no output, `ask` has its own
closed status-1 renderer and never passes a facade return, exception, path,
argv value or other arbitrary term to the existing unbounded
`terminal_message/1`. Except for the retained-root form below, it writes
exactly `loopex: <code><LF>`, where `<code>` is the first applicable fixed
value in this table:

| Boundary | Diagnostic code |
| --- | --- |
| structural argv error | `invalid_arguments` |
| `--output`, `--state-root`, `--cwd`, `--model`, `--tools`, `--skill-dir`, `--max-steps` or `--deadline-ms` value failure | respectively `invalid_output`, `invalid_state_root`, `invalid_cwd`, `invalid_model`, `invalid_tools`, `invalid_skills`, `invalid_max_steps` or `invalid_deadline` |
| missing `--policy`; present but unknown policy | `policy_required`; `invalid_policy` |
| command cwd lookup or realpath failure; prompt failure | `workspace_unusable`; respectively `invalid_prompt_empty`, `invalid_prompt_too_large` or `invalid_prompt_invalid_utf8` |
| named-directory helper failure after argument admission | `skill_directories_unavailable` |
| durable ask application startup failure | `application_start_failed` |
| durable Ollama selection; missing durable provider credential | `durable_model_unsupported`; `provider_credential_required` |
| placement lock or runtime-identity failure; either profile's composition refusal not mapped above | `durable_runtime_unavailable`; `composition_unavailable` |
| create, tracking, attach, resource admission or catalog validation, skill activation, status read or prompt submission | respectively `session_create_failed`, `session_tracking_failed`, `attachment_failed`, `resource_admission_failed`, `skill_activation_failed`, `session_status_failed` or `prompt_submission_failed` |
| durable follow-reader reap exceeded its private bound | `follow_reader_cleanup_unconfirmed` |
| ephemeral ask-mode install or live-handler failure | `interrupt_handler_unavailable` |
| durable `with_runtime/2` cleanup replacement; bare unavailable lifecycle | `runtime_cleanup_unconfirmed`; `session_unavailable` |
| any otherwise unmapped status-1 path | `command_failed` |

The category is selected from the already fixed boundary order; a nested reason
cannot change it. An arbitrary facade term is discarded after choosing the
boundary category, and an exception is caught only at the boundary whose code
it selects. No code contains caller bytes.

When the selected public cleanup map retains a root, the one root diagnostic is
instead exactly
`loopex: cleanup_unproved root=<root-json> ownership=<ownership> pending=<pending><LF>`.
`<ownership>` is literal `owned` or `unknown`; the latter is diagnostic and not
deletion authority. `<root-json>`
is `JSON.encode!/1` of the validated root string, including its quotation marks;
it is at most `6 * 65_536 + 2` bytes. `<pending>` is the non-empty comma-joined
list of the fixed pending atoms in their contract order, without brackets or
spaces. For `ending: :none` this is the sole status-1 line. For a retained run
outcome in text mode it follows the bounded tool and ending lines; in JSON mode
it is the only standard-error line. That outcome keeps its status. No standard-
error path inspects or renders a returned arbitrary term.

**Exit map for `ask`.** It uses values below the daemon's 65–111 and distinct
from 127 and 130:

| Status | Meaning |
| --- | --- |
| 0 | `completed` |
| 1 | Refusal before the run, a cleanup-only failure before prompt admission with no run observation, or a command/lifecycle failure outside the run-outcome algebra for which no public cleanup proof can be constructed; standard output is empty. Except for the named ordinary worker-reap hard halt, which terminates before rendering and promises no output, the fixed code or retained-root diagnostic above is written to standard error. The last case includes an unmarked owner or scheduling-gate crash, even if a run observation had already arrived |
| 2 | `failed` |
| 3 | `bound_reached` |
| 4 | `outcome_unknown` |
| 5 | `cancelled` |
| 6 | No terminal ending was observed after a prompt may have been admitted: the follow window expired, or the ephemeral attachment or command path became unavailable. The command stops the session in the ephemeral profile; for the durable profile it exits and leaves the durable state resumable, not a live in-process owner. `details.reason` distinguishes `timeout` from `session_unavailable`; text-mode standard error says which occurred, while `--output json` writes the `no_ending` object and follows the JSON-mode standard-error rule above |
| 130 | Interrupt after an ephemeral handle exists: the first signal takes the bounded stop route above; a second signal or backstop expiry is the hard-kill case. A pre-handle signal has no Loopex status contract and returns the reaped platform child status |

No `ask` policy defers: `allow-all` allows, and `shell-allowlist` and
`refuse-all` only deny. So `ask` has no deferred-interaction status. A deferring
policy is an API matter, surfaced there as `{:interaction_pending, _}`.

`run` keeps its documented statuses. The existing CLI and daemon maps are not
renumbered.

<a id="technical-plan-tools"></a>
### The Read-Only Tools Contract

Concept: [Scope](M6.md#concept-plan-scope).

Three tools join `CodingTools.definitions()`. Each has effect class `read_only`,
idempotency `safe_retry`, a wall-time budget of 30_000 ms, an output budget of
16_384 bytes, and the protocol-minimum positive artifact budget of 1 byte; the
implementations never emit an artifact. Each argument object has
the released ToolDefinition schema subset only: `type: "object"`, `properties`
and `required`. Core normalization does not retain or enforce JSON Schema's
`additionalProperties`, so no definition claims that keyword. As the final
tool boundary, `Executor.Local` checks the decoded argument map before invoking
the implementation: grep permits exactly `pattern`, `path`, `glob`; find
permits exactly `pattern`, `path`; ls permits exactly `path`, `recursive`.
Unknown keys, atom/string aliases that would collide, non-string keys, missing
required keys and wrong types all return `:invalid_tool_arguments`. Every path
is a non-empty valid-UTF-8 string of at most 4,096 bytes with no NUL, relative
to the workspace or absolute within it. The walker resolves the workspace root once with the same realpath
containment primitive as `CodingTools.resolve/2`, normalizes the requested path
lexically against that root, and then uses `lstat` one segment at a time. It
checks the resolved parent of every segment and refuses an escape, but it does
not dereference the final entry; this preserves a symlink as a link entry and
lets the walker enforce non-descent. Every regex or glob is a non-empty
valid-UTF-8 string of at most 4,096 bytes with no NUL. A maximum-plus-one value,
an extra key, wrong type, failed regex/glob compile or escaping path is
`:invalid_tool_arguments`. Output consists only of the complete records and
notices defined below; it never cuts a record or a UTF-8 sequence.

| Tool | Exact argument object | Result |
| --- | --- | --- |
| `loopex.grep` 1.0.0 | required `pattern` (compiled by `Regex.compile(pattern, "u")` with no other option); optional `path` (default `.`); optional `glob`, whose omission means no path filter and whose presence is matched against each workspace-relative file path | One `M` record per matching line, sorted by raw path bytes then one-based line number, at most 1,000 records. A line contributes once even when the regex matches it more than once. Files over 1 MiB or containing invalid UTF-8 are skipped and counted in the bounded notice |
| `loopex.find` 1.0.0 | required `pattern` (the glob grammar below, matched against each workspace-relative entry path); optional `path` (default `.`) | One `P` record per matching entry in raw-byte lexical order, at most 2,000 |
| `loopex.ls` 1.0.0 | optional `path` (default `.`); optional `recursive` (boolean, default false) | One `P` record per entry in raw-byte lexical order, at most 2,000; directories gain a trailing `/` before field encoding; recursive depth is at most 8 |

After argument admission, inability to inspect the requested root itself is a
tool failure, not a completed empty walk or a descendant skip. A missing root,
an unreadable or unlistable requested directory, or a requested root whose type
or identity changes during its first enumeration returns outcome `failed` with
the exact bounded output `grep failed: requested path unavailable`,
`find failed: requested path unavailable` or
`ls failed: requested path unavailable`. It emits no `M`, `P` or `N` record.
Once that root has been admitted, an inaccessible or changing descendant is a
completed walk with the applicable aggregate `unreadable` or `changed` count.

**Matcher grammar.** Matching is anchored to the complete normalized
workspace-relative path, whose separator is `/` on every platform. A pattern
is a non-empty sequence of non-empty `/`-separated segments; literal `.` and
`..` segments refuse. Outside a bracket class, `*` matches zero or more Unicode
scalar values other than `/`, `?` matches exactly one such value, and `\`
quotes the next scalar as a literal. `**` is special only as an entire segment
and matches zero or more complete non-empty segments; adjacent stars anywhere
else refuse. A bracket class matches one scalar other than `/`: `[abc]`,
`[a-z]` and `[^a-z]` are admitted, ranges are inclusive by scalar value, `^`
negates only in the first class position, `-` is literal first or last, and
backslash quotes the next scalar. An empty, descending, slash-containing or
unterminated class, a trailing backslash and an empty segment refuse. Wildcards
match a leading `.` like any other scalar, so dotfiles need no special spelling.
The implementation is a pure matcher or an equivalent anchored generated
regex over the already enumerated path; filesystem wildcard expansion is not
part of the route.

**Result encoding.** Every field is encoded bytewise after its source string
has passed UTF-8 validation. Printable ASCII bytes `0x20` through `0x7e` other
than `%` remain literal; every other byte, including tab, CR, LF, `%`, controls
and every non-ASCII UTF-8 byte, becomes `%HH` with uppercase hex. This encoding
is injective and makes record boundaries unambiguous.
`<TAB>` and `<LF>` below denote the single bytes `0x09` and `0x0a`; the angle
brackets are notation, not output.

- A grep match is exactly `M<TAB><path><TAB><line><TAB><text><LF>`. The text is
  the complete source line without its terminal LF; a preceding CR remains and
  is encoded. Files are streamed as lines and the regex is applied separately
  to each line.
- A find or ls entry is exactly `P<TAB><path><LF>`.
- When anything was skipped, one aggregate notice follows all result records:
  `N<TAB>skipped<TAB>invalid_name=<n><TAB>too_large=<n><TAB>invalid_utf8=<n><TAB>changed=<n><TAB>unreadable=<n><LF>`.
  Every counter is decimal, saturates at 10,000, and the five keys stay in that
  order; zero-valued keys remain present. `changed` includes a post-open
  identity or type mismatch. Non-regular entries excluded by grep are not
  skips.
- If an entry, cumulative-path-byte, result, cumulative-file-byte or output
  ceiling stops otherwise eligible work, the final record is the literal
  `N<TAB>truncated<LF>`. Before appending any result record, the encoder always
  reserves exactly 107 bytes of the 16,384-byte output budget: 95 bytes for the
  maximum skipped notice with all five counters rendered as `10000`, plus 12
  bytes for the literal truncated notice. The reservation is not reclaimed when
  either notice is absent. A result record must fit in full within the remaining
  16,277 bytes or it is omitted and sets `truncated`; actual notices consume
  only their encoded length inside the reservation and are never truncated.
  Notice order is `skipped`, then `truncated`.

The three tools share one incremental `lstat` walker; they never call
`Path.wildcard/2` to traverse. It reads each directory in bytewise lexical
order, includes dotfiles, never descends through a symlink directory, and
checks containment for each entry before reading or emitting it. These are
pathname checks, not pinned directory-handle operations: Erlang's `:file` API
offers neither `openat` nor `O_NOFOLLOW`. A concurrent same-user process can
swap a parent or target after a check and can swap it back around the post-open
identity comparison. The walker therefore makes no confinement claim against
an adversarially changing filesystem or mount; that is the existing local
executor boundary, not an OS sandbox. An entry name
that is not valid UTF-8 is skipped and increments the aggregate
`invalid_name` counter, so every emitted path stays valid UTF-8. Directory
identity is `{major_device, inode, type}` from `:file.read_link_info/2`; the
walker samples it before and immediately after each `:file.list_dir_all/1` and
requires equality. A mismatch at the requested root takes the fixed failed
result above; a mismatch below it increments `changed`. A symlink may be listed or matched by
its link path but is never descended and `grep` never opens it. FIFOs, devices,
sockets and other non-regular entries may be listed or matched by `find` or
`ls`, but are never opened or descended. `grep` opens only an entry that was a
regular file at `lstat`. Its file identity is exactly
`{major_device, inode, size}`. It records that tuple from
`:file.read_link_info/2`, opens with `[:read, :binary]`, then in order reads
`:file.read_file_info/2` from the open handle and
`:file.read_link_info/2` from the path. Both observations must still be regular
files with the same tuple before any content is used. After the complete bounded
read and before retaining any matches, it repeats handle-then-path observations
and requires the same tuple again. Any open or stat error increments
`unreadable`; a type or tuple mismatch discards that file's matches and
increments `changed` for a descendant. When the file itself is the requested
root, any open/stat error or identity/type mismatch instead returns grep's fixed
`requested path unavailable` failed result with no record or notice. A pre-open size above 1 MiB, or byte 1,048,577 observed
while reading, increments `too_large`. These checks refuse an ordinary
replacement without claiming to detect a same-inode, same-size concurrent
rewrite or a swap that changes and changes back. The glob
grammar above is used only as a pure matcher over a relative path. A file or
other final-entry path input is treated as a one-entry walk: grep considers it
only when it is a regular file, while find and ls may emit it. For a directory
input, grep and find consider descendants but not the requested directory
itself; ls considers direct children, and recursive ls considers descendants,
but neither form emits the requested directory itself. Descendant depth starts
at one. A directory recurses to depth 32 for `grep` and `find`, and only when
requested to depth 8 for `ls`.

The walker does not materialize the whole tree. `:file.list_dir_all/1` does,
however, materialize the complete name list for the one directory currently
being visited; Loopex then sorts that list bytewise and processes it. These caps
bound traversal after each directory enumeration, not the allocation or time
required to enumerate one directory. The requested directory root itself
contributes neither an entry nor path bytes; a requested non-directory final
entry is the walk's first entry. For each sorted raw directory-list member,
before name or type validation, the walker computes the next inspected-entry
count and adds the byte length of the complete raw workspace-relative path, `/`
separators included and no terminator. Invalid names, symlinks and special
entries count toward both ceilings. Exactly 10,000 entries and 8,388,608 path
bytes are admitted; the first candidate that would exceed either is not
inspected and sets `truncated`. For `grep`, `find` and `ls` with
`recursive: true`, a directory entry at the applicable maximum recursion depth
may be emitted or matched, but is not enumerated and sets `truncated` because
its requested descendants were not inspected. Non-recursive `ls` intentionally
ends after the requested directory's direct children; a child directory's
unrequested descendants do not set `truncated`.

A result exactly at the tool's 1,000- or 2,000-record ceiling is admitted. The
walker continues within the other caps; only the next otherwise eligible result
is omitted and sets `truncated`. `grep` additionally streams files and admits
exactly 16,777,216 cumulative file bytes; every byte actually read from an
eligible regular file counts even when that file is later classified invalid
UTF-8, too large or changed, and the first byte beyond the ceiling is not
retained and stops the walk as truncated. Entry, depth, path-byte, file-byte,
result or output ceilings return the bounded
partial result plus the exact truncation notice above; the deadline uses
the executor's existing timed-out tool result. None of the tools runs an OS
process. The presence-only credential check occurs before this walker starts.
- The entry classifier is one small pure function over the `lstat` type. Real
  temporary-workspace integration fixtures cover a FIFO and Unix socket;
  one synthetic `%File.Stat{type: :device}` unit value covers Elixir's single
  device branch, which an unprivileged test cannot create under the required temporary root.
  No production filesystem seam or access to `/dev` is introduced for the
  witness.
- They are active only where a composition's active set names them. The durable
  default stays the four coding tools. The M5 behavior tests stay unchanged;
  `cli_test.exs:3607-3608` is the one inventory assertion reworked from four
  definitions to the exact seven-definition set while also asserting that the
  default active ids remain the original four.

<a id="technical-plan-closure-tooling"></a>
### The Closure Tooling Contract

Concept: [Scope](M6.md#concept-plan-scope).

| Command | Replaces | Contract |
| --- | --- | --- |
| `mix loopex.closure.confine TESTED ADMIN --name NAME --patch PATCH` | the M5 `confinement.py` | Enforces the milestone guide's [confinement](../developer/milestones-technical.md#technical-milestones-confinement) exactly: direct parent; exactly the five paths; ordinary blobs with unchanged modes; byte reconstruction of `docs/plans/README.md` and root `README.md`; the Closure row only; the context map append only; the scaffold `Pending` cells only. `PATCH` has an existing directory parent and must not exist. The task completes every check and buffers the bounded zero-context patch before creating `PATCH` exclusively; a failed check creates nothing, and a write failure removes only the partial file it just created. It prints one `PASS` or `FAIL` line per check and exits zero only after the complete patch is closed |
| `scripts/stage-archive-manifest.sh SHA OUT` | the M5 inline staging | `OUT` and exact sidecar `OUT.source-identity` have an existing directory parent and must not exist. The script stages `git archive SHA` under the [canonical rule](../developer/milestones-technical.md#technical-milestones-archive-extraction): a fresh directory, a subshell with `umask 022`, called from a caller that sets `umask 0777` and records both. It writes the complete `scripts/source-archive-manifest.sh` bytes to `OUT` and the archive's exact `SOURCE_IDENTITY` bytes to `OUT.source-identity`, using exclusive temporary siblings and no-overwrite renames; failure removes only files it created and publishes neither final path |
| `mix loopex.closure.archive_compare TESTED_MANIFEST ADMIN_MANIFEST TESTED ADMIN` | the M5 `archive_compare.py` | Reads the required exact sidecars `TESTED_MANIFEST.source-identity` and `ADMIN_MANIFEST.source-identity`; a missing, non-ordinary or malformed sidecar refuses. It checks NUL framing, no duplicates and sorted records; each projection against its commit's `git ls-tree -r -t --full-tree`; tested and administrative projections identical; tuples identical after removing `docs/**`, `README.md` and `SOURCE_IDENTITY`; and each sidecar's `SOURCE_IDENTITY` names its own commit and committer date. It is read-only, prints one `PASS` or `FAIL` line per check, writes no file and exits zero only when every check passes |
| `scripts/floor-lane.sh SHA --output-dir DIR [--long-bound]` | the M5 `closure-lane.sh` | After all argument, SHA, toolchain, open-file and signal preflights pass, `DIR` must not exist and its parent must be an existing directory; the script creates it at mode `0700`. It makes a fresh clone at `SHA` outside `DIR` on the floor pair. It raises the soft open-file limit to 65_536 (or the hard limit) and refuses below 4_096. It refuses to run when `SIGHUP` is ignored in its own disposition, read portably with `ps -o ignored= -p $$` (supported by both BSD and procps `ps`), and prints the mask. It runs `LOOPEX_CHECK_ALONE=loopex_llm_reqllm bash scripts/check.sh`, retaining the complete stream plus final `EXIT=` and `DURATION_S=` in `DIR/check.log`; with `--long-bound` it then retains the corresponding run in `DIR/long-bound.log`. A preflight failure creates no directory; a run failure keeps the new directory and complete logs as evidence and exits nonzero |
| `scripts/attended-release.sh --output LOG [--answer-attended --disposition ANCHOR --milestone NAME]` | the terminal the M5 `loopex-release-driver.py` provided | `LOG` must not exist and its parent must be an existing directory; after preflight the script creates it exclusively and never overwrites it. It runs `scripts/check-release.sh` under the platform's `script(1)`, so the attended cases have a terminal: BSD `script -q -F /dev/null …` on macOS, and util-linux `script -q -f -e -c "…" /dev/null` on Linux. **A person answers the attended notices by default**, exactly as the release check has always required. The M5 driver-attendance disposition (`agent-context-map.md#disposition-m5-driver-attendance-2026-09-23`) applied to the M5 closure candidates only. The script's automatic mode (`--answer-attended`) requires both following arguments and is refused unless the named recorded maintainer disposition authorizes it for this run. The script checks, and prints each check: the anchor exists in `docs/developer/agent-context-map.md` at `HEAD`; its entry names the passed milestone; its entry names the full 40-character SHA of `HEAD`, which must equal the clean checkout being tested; and its entry states automatic attended answers are authorized. Any failed check refuses before `LOG` creation or `check-release.sh`. In automatic mode it feeds a FIFO and writes `yes` only after the exact notice text is matched in the terminal output, ignoring carriage returns and its own echo. The terminal remains live while the exact transcript is retained to `LOG` with every occurrence of `LOOPEX_PROVIDER_API_KEY` replaced before publication; the final log includes `RELEASE_EXIT=` and `ATTENDED_ANSWERS=`. Check failure keeps that complete redacted log and exits nonzero |

Each command has tests against a fixture repository:
- `apps/loopex/test/closure_tooling_test.exs` for the two Mix tasks;
- `scripts/test/stage-archive-manifest-test.sh`,
  `scripts/test/floor-lane-test.sh` and `scripts/test/attended-release-test.sh`
  for the three scripts, each run by `scripts/check.sh`.
The fixtures cover every mandatory argument, an existing output target, missing
parent, partial-write cleanup, exact sidecar and log names, missing and malformed
compare sidecars, preflight no-create, failing-run retention and successful no-
overwrite output in addition to each semantic failure above.

The fixture reproduces a passing and a failing case for every check. The fast
check runs on both platforms at closure (hosted CI on Linux, and the Darwin floor
run), so the macOS and Linux branches of `script(1)` and `ps` are both executed.
Nothing uses Python or any tool outside the toolchain baseline.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M6.md#concept-plan-outcomes).

Concept: [How each outcome is verified](M6.md#concept-plan-verification).

| # | Witness files | What they prove | Lane |
| --- | --- | --- | --- |
| 1 | `apps/loopex_composition/test/ephemeral_api_test.exs` and `ephemeral_api_fault_test.exs` (new), with a scripted model adapter behind the unchanged port | The closed API grammar and error algebra: every option default, mapping, precedence and malformed form; policy-module identity at 1, 256 and 257 bytes; positive-uint64 minima, maxima and max-plus-one refusals; the saturated timeout default; 32,768/32,769-byte prompts; and complete-path admission at 65,536/65,537 bytes before creation. Multi-turn, every terminal outcome, a failed tool result, an unresolved tool with nullable definition id, `interaction_pending`, every permitted answer-then-defer transition, `interaction_requires_session`, command-to-run joining, timeout continuation, post-admission session loss and every pre-admission lifecycle branch take their fixed forms. Fixed startup ids and injected nonce/counter/type vectors pin prompt, answer and abort ids; mismatched accepted ids, lost replies and every retry opportunity prove one id and no regeneration. Every terminal or no-ending observation carries only its bounded text, tool, shadowed-skill and fixed detail projection. Units exercise minimum, maximum and out-of-domain numeric members; 65,536/65,537-byte answer, history and tool-call-id boundaries; split UTF-8; resolved definition ids at 128 bytes; 256/257 list boundaries; 1 KiB identifier/detail bounds; and the `3 * uint64 - 1` observed-usage ceiling. Integrated cases use the largest Store-admissible events rather than claiming an impossible 64 KiB event payload | fast |
| 1 | `apps/loopex_composition/test/ephemeral_startup_test.exs` and `ephemeral_api_fault_test.exs` (new) | Pre-root validation and a returned, fully rolled-back startup failure leave no owner, reservation, lease, process or root. The gate-issued one-use root token, `SessionRoot` ready/grant protocol, one 5,000 ms startup deadline, private-supervisor registration, every store/lease/executor/trace-capability/runtime phase, the post-runtime trace bind and a `RuntimeHolder` stalled in runtime readiness are suspended at ready, grant, return, registration, acknowledgement and commit. The trace capability's exact PID and handle are registered before runtime start; returned start/handle/validation and bind failures take their distinct fixed causes, an exact successful bind precedes preparation, and lost or malformed post-grant bind results take `start_unknown`. Loss after the side-effect-free candidate-preparation grant but before its exact report makes the owner kill the actor. Exact actor `DOWN` proves no root, preserves the fixed phase error and reaches the ordinary final disposition without poison; if exact `DOWN` remains unavailable, the final exchange is not reached, the fixed phase error survives, both modes are poisoned and no gate-release error is fabricated. A granted exclusive `mkdir` with no exact return yields the fixed temporary-root cause and, after a successful final gate acknowledgement, `root_ownership: :unknown` with `pending: [:root_removal]`; a faulted acknowledgement instead yields only `:gate_release`; neither branch deletes or retries the possible path. Only after exact root claim does a dependency phase granted without an exact return remain `start_unknown` with an owned root plus `:session_subtree` even after all known parents report `DOWN`; the executor-start branch also requires process-group proof. Every returned rollback after reservation exchange submits its final disposition only after the actor, subtree and applicable groups are gone; exact acknowledgement releases the record before root removal or a proved failure. Reached lost, refused, malformed and late acknowledgement with a possible root returns permanent `gate_release`, retains the root and poisons both modes; with no possible root it logs no path and returns `credential_tool_gate_unavailable`. Owner death after reservation exchange and before root-token issue returns bare `session_unavailable` with no root; after token issue it returns the same bare value while an unnamed root may remain. Every ordinary retained root is `:owned` | fast |
| 1 | `apps/loopex_composition/test/ephemeral_stop_contract_test.exs` (new) | `stop_session/1` proves the ordered run-ending, effect-cleanup, process-group, complete-session-subtree and final gate-release obligations before root removal; terminal-before-abort clean endings win while `outcome_unknown` remains unproved. A missing or malformed terminal leaves only `:run_ending` and does not claim unevaluated effect cleanup. The exact final gate disposition removes every session registration and lease and must be acknowledged before deletion or success; lost, refused, malformed and late acknowledgements leave permanent `:gate_release`, flip the poison latch and never become success from process death. The first accepted stop enters `stopping`; concurrent stops receive its same result, while every public non-stop method raced after the transition returns `session_unavailable` immediately, including during a suspended phase worker. Concurrent stop never publishes a stale question and resolves an already waiting ask or answer with the observed terminal value, a pre-admission no-ending cleanup value or the bounded `session_unavailable` no-ending snapshot. Every reachable single and combined reached-failure set has fixed order: missing actor `DOWN` omits every unevaluated worker phase; a phase-worker result failure with exact `DOWN` permits later independent phases; missing phase-worker `DOWN` stops later phases; any item-1-to-4 failure omits gate release; gate failure omits root removal; and gate release and root removal never combine. Only sole subtree or sole owned root-removal failure creates retry state. Every retry and creator-exit final retry records a fresh `cleanup_grace_ms + 5_000` deadline, proves retained actors and phase/removal workers `DOWN`, then includes a never-reached process-group phase before still-pending runtime/subtree phases. Reached unproved run ending, effect cleanup, process-group proof, gate release and unknown root ownership are permanent. A caught post-admission session loss can only preserve its earlier cleanup map across the expected later bare-unavailable stop. One-shot, creator-exit and no-waiter paths log and exit, while successful, repeated and concurrent stops and closed/unavailable handles take the fixed forms | fast |
| 1 | `apps/loopex_composition/test/ephemeral_lifecycle_test.exs` and `ephemeral_cleanup_test.exs` (new) | The owner traps exits before linking helpers and correlates every `EXIT`, `DOWN`, PID and reference. The `FacadeClient` operation, ready, dispatch-with-deadline and cancel messages are suspended independently: missing ready takes the 1,000 ms handshake cancellation path; stop or borrower loss before grant gets a matching cancellation acknowledgement under its separate bound and cannot reach core; after grant a prompt or answer is conservatively possibly admitted regardless of actor scheduling. A second ask before the first grant returns `run_open`; a second answer returns `invalid_interaction_answer`; neither queues or starts a wait deadline, and exact pre-grant refusal or cancellation releases the one mutation slot. Pre-ready, ready-before-grant, granted poll and granted prompt/answer stop cases prove that stop cancels only ungranted work, waits granted work to its operation/cleanup bound, and reuses the live actor for abort. Forged, stale and reordered messages never move the boundary. Timeout-to-question, `last_result`, `run_open`, all four concurrent-stop/creator-exit admission-and-proof branches and terminal-wins races take their fixed forms. Separate process-group, runtime-stop and subtree-stop workers are faulted at result, `finish`, `EXIT` and `DOWN`; each has the 500 ms operation cutoff and 1,000 ms total slot. Refusal, malformed return, raise, throw, exit or timeout with exact worker `DOWN` records that phase and still attempts the next independent phase, while missing `DOWN` prevents a successor and retains `:session_subtree`. Accepted process-group proof is nonce-bound and reused; a retry after an actor-blocked first attempt reaches the previously unevaluated process-group phase, while no reached unproved process-group phase repeats. Every retry receives its fresh deadline. A root-removal-only retry proves any prior removal worker gone and starts no phase worker. Every helper is reaped or the exact reached obligation remains unproved | fast |
| 2 | `apps/loopex_llm_reqllm/test/mapping_test.exs`, `provider_route_test.exs` and `in_process_adapter_test.exs` (new); companion mapping suites plus the dependency-visible correction cases | Cross-adapter vectors pin byte-identical request and valid bounded application-call reply mapping for all four providers. Planning receives the exact ordered credential-free option list; generation receives the same list with only a hosted `api_key` prepended. Response-header capture is provider-exact, deleted on every return/raise/throw/exit and supplies the mapped metadata. A non-nil response error and finish reasons `:error`, `:incomplete` and `:cancelled` fail. Buffered `ToolCall` fixtures cover valid `{}`, invalid text, `null`, arrays, incomplete but repairable JSON, visible atom/string error metadata, provider-executed builtin and provider-native markers, missing or empty visible id/name and multiple-call ordering; any invalid or non-application visible member rejects the whole call list as post-dispatch failure and no local tool executes. Separate provider-builder vectors pin the earlier generated id, normalized missing/nil/empty/unsupported arguments, forced function type, omitted malformed call and stripped error metadata; they prove the mapper makes no impossible refusal claim for an erased field while separately proving visible non-application markers remain rejected. Paired 401, 429, 5xx, transport error, raise, throw and exit cases assert the same public two-class error and fixed text without claiming identical private streaming/direct diagnostics. Route vectors cover provider defaults, omitted ports, explicit default and non-default ports, canonical IPv4, lowercase DNS, uppercase DNS input and normalized paths; they reject uppercase schemes, IPv6, Unicode or percent-encoded hosts, userinfo, empty or malformed authority, non-canonical ports, ports 0 and 65,536, query, fragment, dot segments and every disallowed path before a root or credential read. The effective HTTPS pool options reaching Mint contain the exact nested `conn_opts`/`transport_opts` retention controls, while HTTP omits them | fast |
| 2 | `apps/loopex_llm_reqllm/test/in_process_adapter_test.exs`, `in_process_cleanup_test.exs` and `in_process_guard_test.exs` (new); model streaming conformance; companion suites; `in_process_real_test.exs` (`real_provider`) | All four providers use the inline model, canonical explicit address, `total_timeout: :infinity`, `receive_timeout: :infinity`, no cache and `max_retries: 0`. Anthropic and OpenAI planning passes literal `:chat` plus the exact credential-free generation-option list; generation takes the same chat path and adds only the hosted credential. Deadline vectors map the committed absolute system-millisecond instant with one frozen native offset; cover separated clock samples, positive and negative offsets, uint64 maximum, one positive native tick rounded up to 1 ms, zero/negative remainder, the 1,000 ms cap, in-time and late queued result timestamps and the zero-wait expiry race; and prove no full uint64 or native remainder reaches an OTP or Finch timer. Owner-candidate start proves exact unmanaged starter acquisition creates no proxy or candidate, while the managed path passes the opaque starter only to the unlinked proxy and permutes ready/grant, proxy result, candidate report, `finish`, `proxy_retiring`, proxy `DOWN`, `registration_pending`, activation preparation and `begin`; it faults every missing, late, duplicated, replayed, malformed, mismatching and abnormal form and covers wrong stop reference and retainer tuple. Callback death is injected before disclosure, after disclosure, during registration, after managed return and on both sides of `begin`; core stop is injected before and after managed return. With the locked owner `Task.Supervisor` suspended, expiry kills the proxy and poisons admission; resuming it may materialize an undisclosed request-free candidate, which receives no `begin` and exits on its first scheduled dead-proxy, dead-callback or expired-deadline step without a gate request, root, caller, credential read or dispatch. The worker-retained/guard-unregistered witness lets model settlement precede candidate `DOWN` and proves no registered provider-resource obligation exists. If a matching core stop was already queued, the candidate acknowledges it and exits; if registration committed but callback `DOWN` arrives first, candidate exit without acknowledgement yields locked core `provider_cleanup_unproved`. No branch uses a registration fallback timer or invents adapter `not_dispatched`. Exact `:unmanaged` or `{:error, :provider_resource_refused}` from registration with candidate `DOWN` remains clean `not_dispatched`; a missing candidate `DOWN` returns that fixed result only after the poison latch closes all grants. `{:error, :provider_guard_unavailable}`, raised and malformed registration retain core's conservative result. The selected hosted credential is read only by the sensitive caller; absent, empty, 65,536/65,537-byte, exact-value echo, ambient/global/address/provider/final-route and response-overflow/encoding cases map to their fixed public class without leaking private sentinels. A runtime trace session naming the exact one-MFA inventory plus dependency call sites sees the credential-free pre-exclusion call and a non-excluded control canary, but no raw trace message or entry from the sensitive caller after exact exclusion carries the credential canary; exclusion refusal reads no credential. Forced retry, redirect, 429/529 and upload-close cases receive at most one grant, accepted connection and request-start marker through the recorded HTTP/1 worker; a body over 64 KiB succeeds. Every setup and dispatch phase registers before progress. After exact managed registration, normal, stop, deadline, partial setup and caller/root/owner failure either prove every registered process `DOWN` and both tagged entries absent before success or acknowledgement, or take the unproved path; no missing registered-owner or child `DOWN` becomes fixed `not_dispatched`. TLS 1.2/1.3 non-resumption, distinct concurrent pools and the isolated 5,000 ms socket/controller drain witness hold. Real Ollama and hosted calls pass; valid mapping stays byte-identical, malformed binary arguments visible at the buffered `ToolCall` seam take the named correction, and dependency-normalized cases remain pinned | fast; release |
| 2 | `apps/loopex_composition/test/credential_tool_gate_test.exs`, `credential_tool_gate_fault_test.exs` and `apps/loopex_executor_local/test/provider_environment_test.exs` (new) | Same-mode concurrency and opposite-mode exclusion use capability-bound records. Every ephemeral owner reserves and exchanges admission before root creation. An active Ollama owner holds its tools lease through real Ollama calls; each credential-free call registers its cleanup owner, root, children and directly spawned start-blocked caller under the owner's local-call capability, with no credential lease or quarantine. A hosted call instead registers its cleanup owner, acquires `:credential_call` before root/pool/caller creation, uses the gate-created start-blocked caller and releases only after all registered PIDs and entries are gone plus quarantine. Owner and gate loss are raced before and after each registration. Any unproved tool group or local/hosted call poisons both modes. Tool-enabled and `:tools :none` executors submit and validate their process-group proof nonce while alive; premature owner or executor `DOWN` retains `:process_groups` and poisons admission, while only no-executor rollback is vacuous. The one-way latch is faulted before and after every gate wait and transition for every named gate-scope helper, while the excluded facade, cleanup and removal workers retain only their retryable obligations. Owner-originated poison tests commit the latch, finish independent cleanup and select the reached-phase result before starting delivery. Helper-origin tests inject poison before cleanup, beside concurrent ask/stop/creator loss and at the cleanup deadline race. Custody atomically enters or joins the serialized stopping state, closes new admission and records the cleanup plus distinct 1,000 ms selection-notification deadlines; the detector retires only through its exact notice and `DOWN`. Missing custody, premature detector or owner `DOWN`, or absent delivery start exercises gate takeover. Exact `poison_delivery_started` after the stored reached-phase result then begins one aggregate 1,000 ms interval for a frozen capability-bound recipient-to-value set, including different simultaneous ask and stop values; entries are sent without serial waits, and malformed completion, missing acknowledgement and expiry terminate the tree only after the selected values have had their bounded path. Hygiene tests cover both a live gate reporting to its cohort and external requesters selecting the fixed failure on exact gate `DOWN` within the 7,000 ms outer deadline; owner-start tests prove the synchronous entrypoint keeps the creator identity and caller-held refusal without a wrapper or private handoff. No acknowledgement race can reopen admission, and other sessions ended by shared-tree termination receive only bare unavailable. Final session disposition requires the exact gate acknowledgement after every registration, lease, tag and proof is gone. Gate or supervisor crash ends all active ephemeral sessions and keeps poison across application restart. `prep_stop/1` alone seals admission through its unlinked monitored resolver: suspended child enumeration or gate calls, late/malformed result, missing `finish` or worker `DOWN` produce no proof and preserve both markers; only an in-time result, correlated `finish` and normal `DOWN` yields the generation-bound empty census consumed by `stop/1`. A gate crash after proof but before supervisor termination starts a replacement with a new persistent generation; the old proof cannot compare-and-erase that marker. Ephemeral-capability child environments are scrubbed while durable/direct instances preserve M5 behavior | fast |
| 2 | `apps/loopex_composition/test/credential_tool_gate_fault_test.exs` (new), post-poison protocol cases | The gate refuses every authority-bearing transition after the latch and admits exactly correlated `poison_watch`, `poison_delivery_started` and `poison_handoff_complete`. Identical replay, stale reference, wrong PID or deadline, reordering, conflict and deadline-edge zero-wait cases neither extend time nor grant or release authority. Owner-origin cases install watch before delivery-start without awaiting the gate, preserve sender ordering and use the live owner as fallback; a pre-root ambient-credential preflight with missing exact `DOWN` records the fixed 10,000 ms rollback deadline before watch. Helper-origin cases send no preliminary gate message: exact gate watch acknowledgement precedes owner custody, then detector retirement and exact `DOWN` precede delivery-start; completion targets the gate after the detector has retired. Every cleanup and selection deadline race stores the complete reached-phase result before the aggregate delivery interval begins | fast |
| 1–4 | `apps/loopex_composition/test/application_bootstrap_test.exs` and `req_llm_start_test.exs` (new); generated application, escript, companion-release and fixture-host-release assertions | Direct embedded and built-escript session creation exercises the bounded `loopex_composition` bootstrap: already started, exact success/error, malformed/late result, timeout, a controller start that completes after refusal and concurrent first calls all take their fixed branches, and the application gate tree is live before ephemeral gate lookup. The bootstrap guard is faulted while the worker blocks in the controller call, after provisional result and around `finish`; requester death, guard death, worker death, either missing `DOWN` and both deadline races leave no worker result path or session authority. Existing-handle API calls never bootstrap and return only their lifecycle-first result after application/gate loss. The built escript records `app: nil`; a callback stalled on its first composition start proves that `main/1` was reached and the 5,000 ms decision plus 1,000 ms reap bound wins. Every malformed or unclassifiable `ask`/`-p` form, including a missing `--state-root` value, refuses before any Loopex/project application start. Valid ephemeral forms start no `:loopex_cli` application first. Valid durable forms use the ask-specific helper; an injected arbitrary, large or control-bearing application error proves fixed `application_start_failed`, zero stdout and status 1. Every M1–M5 or unknown command instead invokes the private legacy-start helper before existing main logic; success preserves application order, and its injected dependency-start failure proves the exact former formatted line and status 1 rather than a match exception. Combined-fault cases pin workspace, skill, provider and pre-start guard refusal before bootstrap, and bootstrap refusal before ReqLLM hygiene. `req_llm`, `req` and `finch` code is present but not auto-started under `runtime: false`; neither bounded bootstrap nor escript startup loads `.env` or opens Tidewave. The guarded hygiene decision then exercises every start-table row, first-start overlap and host-declaration case. Companion dependency-start behavior remains unchanged because it starts the set explicitly | fast; release |
| 1, 3, 4 | `apps/loopex_composition/test/application_bootstrap_test.exs` (new), guard-lifecycle cases | Requester death is faulted while the controller call blocks and after its provisional result; guard death is faulted before and after provisional forwarding; worker result, `finish`, worker `DOWN`, guard reap acknowledgement and guard `DOWN` are each withheld, malformed and reordered. Success is impossible until exact normal worker `DOWN`, then the correlated guard acknowledgement, then exact normal guard `DOWN`. Every failure kills or proves the worker and guard under the shared decision/reap deadlines; an already-submitted controller request may finish later but cannot return a session result or bypass a later full precedence pass | fast |
| 1, 4 | Built-escript application inventory assertions in `apps/loopex_cli/test/ask_command_test.exs` (new) | Mix starts its embedded Elixir base before `main/1`; every no-start claim in this plan means no Loopex project application. Invalid `ask` and `-p` forms prove that no Loopex `.app` is started, valid ephemeral forms prove `:loopex_cli` stays stopped until the bounded composition path starts its own graph, and durable/legacy forms prove their distinct helpers start the exact M6 CLI graph with ReqLLM, Req and Finch still load-only | fast; release |
| 2 | `apps/loopex_composition/test/credential_tool_gate_fault_test.exs` and `owner_start_fault_test.exs` (new) | Every gate request proves fresh reference, requester binding, absolute expiry, admission acknowledgement, idempotent cancellation, expired or late-dequeued refusal and stale-reply rejection. Owner-start tests suspend creator/guard/worker/owner messages, links and monitors before the call, while `start_child/2` blocks, after an owner may have returned, through exchange, commit preparation, guard retirement, both helper reaps and gate-issued one-use root-token delivery. A clean refusal proves all known helpers and any returned owner `DOWN`. Any guard or worker loss without the exact correlated start result takes the shared-supervisor kill branch, flips the poison latch, kills the exact gate tree and requires VM restart even when all known PIDs are down; missing known `DOWN` messages are logged but are not the source of uncertainty. Owner death after exchange is faulted both during active preflight before token issue, proving no root and orphan-lease cleanup or poison, and after token issue, proving bare unavailable with the named possible unnamed root. Gate death before token issue creates no root; every token/death/forwarding order after issue follows private-start rollback or the named unmarked-owner limitation. Existing owners monitor the gate and both application supervisors, reject new work and clean up on failure; a suspended process may outlive the bounded refusal only without a result or root-start capability | fast |
| 2 | `apps/loopex_composition/test/req_llm_start_test.exs` (new) | The complete application read/configure/start decision uses one 5,000 ms deadline and one 1,000 ms reap bound in the responsive gate's linked, monitored worker. Tests suspend every snapshot, row directive, application read, configuration write, start return, provisional result, `finish` and exact normal `DOWN`, plus abnormal and missing `DOWN`, malformed/late results, gate loss, joined cohorts and requester death. No mutation is directed before `:starting`. A proved pre-mutation failure preserves the prior marker; uncertainty after the first mutation directive retains `:starting` and poisons both modes. Marker commit or restoration occurs only after an in-time provisional result, `finish` and normal `DOWN`. The worker reap cutoff is no later than 6,000 ms after decision start. The outer request/join path separately proves acknowledgement, the poison-only aggregate handoff and 7,000 ms expiry, cancellation, late dequeue and stale reply. Two first compositions start once, an entire failed cohort receives one result and no owner/root/credential/effect exists during the decision | fast |
| 3 | The store conformance suite with `:memory` bound to `Loopex.Store.Memory`; `apps/loopex_composition/test/ephemeral_profile_test.exs` and `ephemeral_private_startup_test.exs` (new) | The shipped memory store passes every conformance and fault-injection case, and the profile refuses without policy. Private tmp and entropy seams cover lookup raise/throw/exit/malformed results; 65,536/65,537-byte and UTF-8/NUL complete paths; entropy shape; 15 collisions then success and 16 then refusal; every mkdir, chmod, lstat and listing failure or mismatch; and pre-existing paths untouched. Candidate preparation and claim ready/grant/return races prove loss before the side-effecting `mkdir` grant mutates nothing; missing candidate-actor `DOWN` keeps the same no-root refusal and poisons the gate. Exact claim success produces an owned empty ordinary directory at mode `0700`; loss after the `mkdir` grant but before its return yields the fixed cause, ownership-unknown possible path, no deletion and no retry. The winning nonce pins root and runtime-id vectors. After exact claim, `SessionRoot`, private-supervisor, store, lease, executor, trace-capability, `RuntimeHolder`/runtime and trace-bind ready/grant/return/register/ack/commit boundaries are faulted under the one startup deadline; an exact returned failure can roll back cleanly, while an unknown granted dependency phase keeps an owned root and subtree obligation even after all known parent `DOWN` messages. Successful stop and owner exit prove process groups, final gate release and every registered session process down before recursive removal; caller-visible errors preserve path, ownership, cause and ordered obligations, while the post-timeout no-waiter path is host-logger-only and standalone `ask` can suppress it | fast |
| 4 | `apps/loopex_cli/test/ask_command_test.exs`, `ask_exit_test.exs` and `ask_delegation_test.exs` (new) | The complete grammar and fixed boundary precedence; `-p` identity; argv and incrementally bounded stdin prompts; profile selection independent of `LOOPEX_HOME`; credential-discard order; every exit status; text and JSON stdout purity; and separate-process delegation. Status-1 tests feed huge nested facade terms, exceptions, control characters, newlines, long paths and long unknown flags and prove only the closed fixed diagnostic code or bounded JSON-encoded cleanup-root line is emitted. Every text-mode terminal and no-ending standard-error line, including exact `ending no_ending timeout` and `ending no_ending session_unavailable`, is pinned. JSON-mode proved run and no-ending observations have empty standard error; an unproved cleanup has only its retained-root line. Both profiles pass the explicit empty named-directory manifest and perform no discovery | fast |
| 4 | `apps/loopex_composition/test/resource_packs_directories_test.exs` (new) | Direct `LoopexComposition.ResourcePacks.read_directories/2` calls prove the complete public algebra and precedence: malformed paths before malformed options and before filesystem work; workspace failure before named-directory work; canonical unsigned-bytewise expanded-path inspection; and the same first error under every multi-fault input permutation. They also prove exact path/count bounds; relative and absolute resolution; two matching realpath/device/inode observations before the helper derives its non-caller-controlled `workspace_ref`; every named filesystem and pack error; exactly the two result members; exact project/user identities; local-wins shadows; same-kind duplicates; unsigned-bytewise result order; and path-order-independent manifest digest. Exact and max-plus-one fixtures pin depth, visited-directory, raw-entry, complete raw relative-path-byte, regular-file and content-byte caps, including invalid-name and special entries in the applicable counts and the named one-directory materialization limitation | fast |
| 4 | `apps/loopex_composition/test/resource_admission_workflow_test.exs` (new) | Under both ephemeral startup and durable `ask`, the helper result is retained exactly once where durable, the exact host decision is admitted, catalog digests/disposition and the complete canonical tuple set are checked, and skills activate one at a time in unsigned-bytewise order with exact command-id replies. Empty input submits no resource command. Refusal, malformed return, raise, exit, session loss, missing/extra/duplicate catalog tuple, digest mismatch and every Nth activation stop at the first failure before prompt/provider/tool work. Proved ephemeral rollback destroys the partial memory state and root; an unproved rollback returns its exact cause and root; durable failure keeps the actual possibly committed prefix, never retries and leaves a tracked session resumable only after tracking succeeded | fast |
| 4 | `apps/loopex_cli/test/ask_projection_test.exs` and `ask_interrupt_test.exs` (new) | The ephemeral renderer uses only the public completed result, run-error observation, no-ending snapshot or `cleanup_unproved.ending` plus the mandatory stop return, never the handle or attachment. Across both profiles and every outcome, compact JSON is exactly one closed-member object plus one LF, with no other stdout byte; `text`, `tools` and `shadowed_skills` come only from the selected run or composition in their stated order; an unresolved tool has `tool_id: null`; a timeout and a caught post-admission session loss each produce a complete `no_ending` object with the fixed distinct reason, the latter only from `cleanup_unproved.ending` with `cleanup.proved: false` and its retained root. Every false cleanup projects the ordered reached-failure set, including `gate_release` only when reached, and exact root ownership. Worker-origin cleanup maps followed by successful retry, a newer failed retry or a permanent bare stop select the exact stated cleanup/ending; `ending: :none` takes status 1 with zero standard output and names any still-retained root on standard error. Decimal-string witnesses cover `2^53`, unsigned-64-bit maxima and the exact observed-usage maximum without rounding. Text mode emits answer bytes only for completed and bounded terminal summaries on standard error. Forced unmarked owner/gate failure before observation and after a terminal observation, including bare-unavailable stop without an earlier proof-bearing cleanup map, proves status 1 and zero standard-output bytes because no public cleanup proof exists. Real signals suspend the worker before its lifecycle check/owner send, after owner registration but before dispatch grant, after grant and after its provisional result while mandatory stop is running. The first case proves successful stop plus bare `session_closed` or unavailable yields zero stdout, no fabricated `no_ending` and exit 130; every case proves one stop and at most one render. A latched pre-child signal is forwarded and reaped with the platform status but has no Loopex output, cleanup or status promise; second-signal and backstop cases remain hard kills | fast |
| 4 | `apps/loopex_executor_local/test/read_only_tools_test.exs` and `apps/loopex_composition/test/tool_preset_budget_test.exs` (new) | The executor's final argument validator admits only each tool's exact key set and types, with exact/max-plus-one string bounds. Root failures, descendant skips, identity changes, symlink non-descent, special-file non-open behavior, raw-entry/path/file-byte/depth/result ceilings and grep's exact 16 MiB cumulative-read rule take their fixed forms. At-cap and next-item fixtures pin whether the requested root counts, maximum-depth emission, result truncation and every skip counter; default non-recursive `ls` does not mark an emitted directory truncated merely because its unrequested descendants exist, while recursive depth exhaustion does. Output records use the percent encoding exactly; the encoder always reserves 107 bytes, admits only complete records in the remaining 16,277 bytes, and emits the 95-byte maximum skipped notice before the 12-byte truncated notice. No fixture claims an OS sandbox or bounded one-directory enumeration. The three literal presets carry the exact definitions/active ids and remain under ADR 0017's measured system-class limit | fast |
| 4 | `apps/loopex_executor_local/test/read_only_tools_test.exs` (new) | `loopex.grep` with omitted `glob` applies no path filter; explicit empty `glob` is invalid, and each admitted non-empty glob is matched against the complete workspace-relative `/`-separated file path. Omission, `*`, a nonmatching pattern and nested-path patterns have distinct fixtures | fast |
| 4 | `apps/loopex_cli/test/ask_interrupt_test.exs` and launcher fixtures (new) | Exact ask-mode installation precedes worker start, is bounded at 1,000 ms and returns the exact `:erl_signal_server` manager PID. Install refusal, malformed return, duplicate active-handler claim, manager replacement or manager loss stop the new session, emit the fixed install diagnostic or real retained-root line, write zero stdout and exit 1; manager `DOWN` admits only an already-queued matching worker result before taking that path. Forged, stale, old-manager and replayed same-reference notices are ignored. Direct `SIGTERM`, `SIGHUP` and `SIGQUIT`, plus terminal `SIGINT` forwarded by the launcher as `SIGTERM`, each exercise the same ask-notice path. A provisional ordinary worker result starts the exact 1,000 ms reap deadline; in-time `DOWN` proceeds to mandatory stop, an absent `DOWN` gets one kill and zero-wait receive, and a still-absent `DOWN` hard-halts status 1 with no output or cleanup claim. Signals before, during and after mandatory stop race the exact 1,000 ms `finish_ask/2` call; manager serialization returns exactly `:ordinary` or `:interrupted`, and only the winner renders. Missing, malformed, late or mismatched finish reply and manager loss yield status 1, zero stdout and only the applicable fixed or retained-root diagnostic. The exact signal-manager PID/reference notice starts one orderly stop; exact finish and main `DOWN` disarm the backstop. A second handled signal or backstop expiry in `stopping` hard-halts, while one first signal never does. The monitored ask worker is suspended before owner registration, registered before grant and after grant; each branch performs one stop and at most one render, and the pre-registration branch invents no observation. After interrupt stop, queued result-before-`DOWN`, `DOWN` without result and neither queued are faulted; the exact worker is killed and reaped within 1,000 ms, while withheld `DOWN` takes the no-output status-130 hard halt. Launcher fixtures deliver each signal before child assignment and after assignment but before handler install; the latch forwards `TERM`, no signal is lost, the child is reaped and its platform status is preserved without a Loopex-130 assertion | fast |
| 5 | `apps/loopex_composition/test/durable_options_test.exs` (new), exercised through `start/1`, `with_runtime/2` and `start_edges/2`; `apps/loopex_llm_reqllm/test/provider_deadline_test.exs` | All four added options and defaults share one validator: first-colon model parsing including an id with another colon; admitted and refused provider cases; complete and partial bounds at 1, uint64 maximum and maximum plus one; sampling at 1 and 1,000,000 and outside; every active-id combination, duplicate/unknown refusal and the explicit empty-definition workaround. Existing non-list, unknown-key and first-duplicate behavior remains released behavior. Combined faults pin the released validation chain followed by model→bounds→sampling→active-tools, including every adjacent pair, and no invalid added value starts an edge. Named directories are not a raw fifth option. Companion total, stream-idle and receive waits are infinite; the unchanged sliced coordinator deadline remains authoritative at uint64 maximum and for a short stalled call | fast |
| 5 | `apps/loopex_cli/test/durable_ask_workflow_test.exs` (new) | The helper completes before root identity; placement and runtime id precede one credential-plane acquisition; one exact composition-option bundle retains the manifest once; and create→track→attach→admit→catalog→ordered activation→status→interrupt→prompt occurs exactly, with the empty-manifest path skipping resource commands. Create id bounds, the attachment struct, active status plus positive-uint64 cleanup grace, exact command replies, every catalog mismatch, and the catalog-to-`resource_admission_failed` diagnostic are pinned. Every boundary fails independently and in the stated combined-fault precedence. Create-reply loss, tracking failure before publication and after publication-before-fsync, each post-track failure and the legacy `interrupt-` id/uncorrelated accepted reply are exercised without retry or stronger recovery claims. The private monotonic-clock seam fixes prompt acceptance, reader return and expiry instants, including saturation and the zero-wait deadline race. The single `FollowReader` owns a replay attachment from the callback's accepted cursor and requires exact PID/ref/deadline/cursor acknowledgements. Pre-join events, another run's events, a matching `user.message_appended` command id, a duplicate or conflicting join and expiry before join prove that the prompt command id freezes exactly one run id and only that run enters the projection. On terminal, error, deadline and callback raise/throw/exit, exact `DOWN` proves reap; a deliberately withheld `DOWN` instead discards the projection, returns only `follow_reader_cleanup_unconfirmed`, emits no callback output and may briefly leave the killed, unlinked reader with no mutation or output route. An event consumed only by its disposable attachment remains replayable from the unchanged durable cursor in both branches. `with_runtime/2` cleanup replacement discards any callback projection, plane and placement release in order, and only the surviving value renders once afterward | fast |
| 5 | The complete M5 suites and retained release lanes; `mix loopex.deps_budget`; `git diff v0.2.0 -- apps/loopex/lib ':(exclude)apps/loopex/lib/mix'` empty at the tested candidate, with only the two closure tasks added under `apps/loopex/lib/mix/tasks/` | Valid durable behavior, daemon and both protocol generations remain unchanged; a companion malformed binary argument still visible at the buffered `ToolCall` seam now fails closed before tool execution, visible provider-executed and provider-native calls fail rather than becoming local requests, dependency-normalized erased cases remain pinned, and the named timer-safety change leaves the coordinator deadline authoritative. The dependency budget and core runtime library are unchanged. Expected test-data changes are enumerated rather than called unchanged: running-build version assertions become version-derived; the exact definition inventory moves from four to seven while a separate assertion keeps the default active ids at the original four; visible malformed-binary and non-application fixtures change from flattening to fixed post-dispatch failure; dependency-normalization fixtures keep the locked behavior; `release_version` and developer text move to `0.3.0`; and the release manifest adds the two M6 provider rows plus the separate rollback lane. The durable default `policy_identity` remains literal `"0.2.0"`; pure encoder version-vector tests remain unchanged | fast; release |
| 5 | `apps/loopex_cli/test/rollback_test.exs` (new, release lane `rollback`), against a `v0.2.0` build made from a fresh `git archive v0.2.0` and a scripted model | A durable root holding a pending interaction written by the candidate recovers, and the interaction is answered, under `v0.2.0`, and the reverse; a `loopex.grep` call written by the candidate but not yet dispatched, resumed under `v0.2.0`, is committed as a failed `unknown_tool` call and the run continues; one already dispatched is never run under `v0.2.0`, and its work either has a matching receipt admitted or stays pending for reconciliation; a completed `loopex.grep` call in history replays under `v0.2.0`; a root with an admitted user skill, written by the candidate, resumes under `v0.2.0`'s offline `loopex resume` with the retained snapshot reloaded by digest, and under `v0.2.0`'s daemon with the session resumed and all of that session's skill context withheld, project skills included. The default `policy_identity` revision is `"0.2.0"` under both | release |
| 6 | `apps/loopex/test/closure_tooling_test.exs` (new); `scripts/test/stage-archive-manifest-test.sh`, `scripts/test/floor-lane-test.sh`, `scripts/test/attended-release-test.sh` (new); `bash scripts/check.sh --docs` | Every command's exact grammar, mandatory argument, preflight, PASS/FAIL line and exit rule is exercised. Existing outputs never overwrite; missing parents create nothing; partial writes remove only their own temporary files; failed executed lanes retain complete logs. Archive comparison refuses missing, non-ordinary and malformed exact sidecars and proves NUL framing, tuple projections and source identity. Automatic attendance refuses a missing anchor, wrong milestone, wrong exact HEAD SHA and absent authorization, and accepts only the recorded combination. P1's exact charter exception list, P2's selected unattended pre-merge lanes, P3's retained complete output plus SHA and P4's milestone-branch rejoin-main rule are present. A retained semantic review covers `README.md`, `docs/operator/getting-started.md`, `docs/operator/runtime.md`, `docs/operator/tools-and-policy.md`, `docs/developer/getting-started.md`, `docs/developer/getting-started-technical.md`, `docs/developer/runtime-and-embedding.md` and `docs/developer/compatibility-surfaces.md`; the documentation check passes. M6 closure invokes only these repository commands | fast; closure |
| 1–4 | `scripts/m6-demonstration.sh`, the single acceptance demonstration, run from a clean checkout with no `LOOPEX_HOME` on macOS and on Linux | Its four steps in order, each printing its own `PASS` or `FAIL` line and the elapsed time; the complete output of each platform's run retained with its reference and SHA-256 digest in `docs/evidence/M6-closure-runs.md` | closure |
| — | An independent read-only security review of the in-process credential path, naming the tested SHA, retained as `docs/evidence/M6-security-review.md` with the reviewer's retained output reference and SHA-256 digest | The credential is read only at the model boundary and its exact value is gated before replies enter a Loopex plane; every guard and the final one-shot route check occur at the stated boundary; the call-owned pool is unique, its lifecycle root and every registered child end, and both tagged registry entries disappear before a provider result or successful cleanup acknowledgement; TLS reuse, tickets and secret retention are disabled; the caller is the only result path and ends before release. The review covers the ephemeral scheduling gate's participants, proof-bound releases, quarantine, both-mode poison, gate-failure termination and named nonparticipants. Checked-out socket and OTP TLS-controller exposure, including the isolated release witness's 5,000 ms threshold and the fact runtime cleanup does not wait for it, matches all seven amendment texts; host-environment and host-diagnostic retention is named; no arbitrary heap-erasure claim is made. Packaging leaves ReqLLM, Req and Finch loaded but stopped until the guarded start; the only persistent library setting Loopex changes is ReqLLM's `.env` switch, and `:llm_db` configuration remains untouched | closure |

**Evidence rules.**
- **Executed witnesses.** Every derived number has an executed witness before
  closure: the exit statuses, the tool bounds, the defaults, and the release
  manifest's row count.
- **Retained outputs.** Every release lane retains its complete output with a
  stable reference and a SHA-256 digest, recorded in
  `docs/evidence/M6-closure-runs.md`, which the tested candidate creates and
  indexes as a scaffold.
- **Release rows.** The manifest (`check-release.sh:135-157`) grows from nine
  real-provider rows to eleven, and its header comment changes with it. The
  `rollback` lane is a separate `--only rollback` lane beside them, credential
  free, because it drives a scripted model:
  - row 10, `loopex_cli|test/ask_real_test.exs|ephemeral ask answers from a
    local Ollama model through a separate process`. The ephemeral profile runs
    against a local Ollama model, driven through `loopex -p --output json` from
    a separate OS process, which is also the real-provider agent-delegation
    case. It runs under `without_credential`: the manifest loop gains a
    per-row credential mode, since today it runs every row under
    `with_credential` (`check-release.sh:155`);
  - row 11, `loopex_composition|test/ephemeral_real_test.exs|the embedded API
    answers in-process from Anthropic with the release credential`. The
    ephemeral profile's embedded API runs an Anthropic model in-process.
- **Release credentials.** The release credential stays
  `LOOPEX_PROVIDER_API_KEY`, an Anthropic key.
  - `with_credential` passes it to row 11 as `ANTHROPIC_API_KEY` for that row's
    process only.
  - `without_credential` unsets `LOOPEX_PROVIDER_API_KEY`, `OPENAI_API_KEY`,
    `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY`, so no credential-free lane or
    fast check can see one.
  - The wrapper's self-check and its log redaction cover all four names.
- **Release host precondition.** The release check requires
  `LOOPEX_RELEASE_OLLAMA_MODEL`, naming a model already pulled on a reachable
  local Ollama server. If it is missing or unreachable, the check fails as
  evidence unavailable. It never skips the row, and closure cannot proceed
  without it.

<a id="technical-plan-failures"></a>
### Ownership and Failure at Every Boundary

Concept: [Scope](M6.md#concept-plan-scope).

| Boundary | Owner | Failure and its answer |
| --- | --- | --- |
| Host process ↔ ephemeral owner | The supervised `LoopexComposition.Ephemeral` owner monitors the creating caller; caller and owner are not linked. Each public request temporarily monitors the owner and normalizes its `DOWN` or request exit through the handle cell | The creating caller exits: the owner aborts an open run, stops the runtime (the executor terminating its owned process groups) and removes an owned root only when cleanup is proved, otherwise retaining and logging its path, ownership and pending obligations. A lost exclusive-claim return retains an unknown possible path and never removes it. The owner crashes: the caller survives, a waiting request or later handle call returns the proved closed or bare unavailable lifecycle result, and the private subtree collapses without restart; the root may remain, as with a hard VM kill, under the named limitation |
| Entrypoint ↔ owner-start guard, worker and gate | The entrypoint monitors the responsive guard, its linked worker and any returned start-blocked owner; the gate owns reservation exchange and the one-use root-start token | A missing correlated start result, helper reap or retirement acknowledgement kills the known actors and shared owner supervisor, flips the poison latch and refuses with no root-start authority. Owner death after exchange returns bare unavailable: before token issue no root exists and orphan obligations close or poison; after issue a root may remain unnamed. No entrypoint becomes a replacement cleanup owner |
| Ephemeral owner ↔ public callers | The one serial owner holds one public-mutation slot and one lifecycle state | A second ask before or after grant is `run_open`; a second answer while an answer owns the slot is `invalid_interaction_answer`; neither queues. The first stop enters `stopping`; later stops join its result and later non-stop requests return unavailable immediately, while requests serialized earlier take their exact admission-state result |
| Coordinator ↔ either adapter | The session coordinator, as for any model | A raise or exit inside the adapter is `dispatched_or_unknown` by the existing rule, and the run ends `failed`. A pre-dispatch refusal is retried once by the existing attempt limit |
| Owner candidate or cleanup owner ↔ caller and tagged pool | The callback acquires the invocation-local starter before creating a process. The in-process adapter starts an authority-free candidate behind an unlinked, monitored proxy; only reconciled PID reports, authorized proxy retirement, normal proxy `DOWN`, exact managed coordinator registration, activation preparation and one-use `begin` convert and admit it as the cleanup owner. The ephemeral gate owns hosted credential-call registration and Ollama local-call registration | Exact unmanaged starter acquisition creates no proxy or candidate. An unknown queued supervisor start poisons admission and withholds `begin`; a later undisclosed candidate exits on its first scheduled dead-proxy, dead-callback or expired-deadline step without authority. In the locked worker-retained/guard-unregistered interval, model settlement may precede authority-free candidate `DOWN`; no registered provider-resource obligation, call input or authority exists, and complete session-subtree cleanup still reaps it. If registration committed, candidate exit without the exact stop acknowledgement is unproved. An admitted owner creates and monitors a start-blocked pool-lifecycle root and registers it before pool work. A hosted call acquires its credential-call lease and gate-created caller; Ollama uses the enclosing owner's local-call capability, takes no credential lease or quarantine and may run while that session's tools lease remains held. The root synchronously registers every returned child before progress. Once it starts, every later partial start, refusal, reply, spawn failure or exit joins one idempotent teardown. Normal completion proves the root, every registered child and both tagged registry entries absent, then ends the only result caller before release. Stop or deadline first makes replies inadmissible and sends the caller an untrappable kill, then requests cooperative root teardown. Missing caller, root, child or exact registered cleanup-owner `DOWN`, either registry entry or failed graceful teardown withholds provider success or cleanup acknowledgement, preserves the registered obligation and takes core's unproved-cleanup path; a bounded return never claims a missing `DOWN` occurred |
| Adapter ↔ ReqLLM | The in-process adapter | Any non-success return or raise from `generate_text/3` is `dispatched_or_unknown`. A response with a non-nil `error` or finish reason `:error`, `:incomplete` or `:cancelled` is not success. The kernel's deadline ends the call through the cleanup owner, and the run ends `failed` or `outcome_unknown` by the existing rules |
| Composition ↔ guards and credential | The ephemeral composition, owner before pool creation, caller before each call and one-shot adapter at final dispatch | A replaced provider module, non-empty `:req` `:default_options`, set `SSLKEYLOGFILE`, unsafe base URL, plain HTTP or an active tool preset for a credential-bearing provider refuses before any per-session root exists; the pre-start Req and SSL guards run before Loopex starts ReqLLM/Req. Only the sensitive caller reads the key: an absent, empty or greater-than-65,536-byte value found immediately before `generate_text/3` is `not_dispatched`, accepts no connection and takes the owned teardown path. A final route mismatch or second adapter invocation is refused without network activity but remains conservatively `dispatched_or_unknown` because the ReqLLM call has begun |
| Composition ↔ ReqLLM's start | The credential/tool gate owns the marker and one linked, monitored hygiene worker owns every application read, configuration write and start call under one decision deadline | `TIDEWAVE_REPL="true"`, an undeclared host start or a declared start with `.env` loading on refuses before owner admission. A proved pre-mutation failure preserves the prior marker. The gate writes `:starting` before the first mutation directive; any uncertainty after it retains that marker and poisons both modes until VM restart. A result is final only after provisional reply, `finish` and exact normal worker `DOWN`; requester loss cannot cancel admitted shared work |
| Owner ↔ private startup actor and subtree | The owner monitors `SessionRoot`; `SessionRoot` is the lifetime OTP parent of the zero-restart `:one_for_all` supervisor, and a registered `RuntimeHolder` remains the runtime parent | The gate's one-use token is the only root-start authority. One 5,000 ms deadline covers root claim and every grant-gated store, lease, executor, trace-capability, runtime and trace-bind phase. A returned phase failure rolls back its known resources. The trace process and handle exist before runtime start, and exact bind to the returned runtime is required before startup preparation. Loss after the side-effect-free candidate-preparation grant but before its exact report makes the owner kill the actor: exact `DOWN` proves no root and reaches the ordinary no-root disposition without poison, while missing `DOWN` prevents that exchange and poisons both modes. Loss after a granted `mkdir` but before its exact return keeps an ownership-unknown possible path, never deletes or retries it and returns the fixed temporary-root cause. Only after exact root claim does a dependency-phase grant without an exact return become `start_unknown`; known parent `DOWN` cannot prove an unreported child absent, so the call returns `cleanup_unproved`, keeps the owned root and `:session_subtree`, and requires any applicable process-group proof |
| Runtime ↔ private ephemeral subtree | `SessionRoot` owns the `:one_for_all`, zero-restart-intensity subtree containing the memory store, lease, executor, runtime trace capability, `RuntimeHolder` and runtime; the ephemeral owner monitors every registered PID | Any child loss collapses the subtree without restarting an edge. The owner takes the session-failure cleanup path and exits unmarked; the handle reports unavailable, and nothing is recovered or silently replaced beneath it. Cleanup retries reap any retained actor, phase worker or removal worker before starting a successor |
| Ephemeral owner ↔ final gate release | The gate retains the owner registration, lease or inactive capability, accepted proof nonce and every registered call/subtree/tag until the owner submits one correlated final disposition | Exact acknowledgement after an empty session census proves `:gate_release` and alone permits root removal. Refusal, malformed or lost acknowledgement flips the poison latch, keeps `:gate_release` permanently pending and never becomes success from owner or gate `DOWN` |
| Executor ↔ tools and ephemeral gate | The local executor | M5 dispatch/effect behavior stays unchanged; three read-only in-VM tools are added, provider variables are scrubbed, and the private instance/lease-bound process-group proof feeds only the ephemeral scheduling gate |
| Durable callback ↔ `FollowReader` | The callback owns one linked, monitored disposable-attachment reader and its accepted cursor | Exact `DOWN` within the private reap bound permits the selected projection. Missing `DOWN` discards it, returns only `follow_reader_cleanup_unconfirmed` and leaves the already-killed reader with no mutation or output route; the durable cursor remains replayable |
| `ask` main ↔ signal handler and worker | The CLI main owns the handle, installs and monitors exact ask mode, and monitors one blocking API worker | Installation or live-handler loss stops the session and exits 1. An ordinary provisional result must be followed by exact worker `DOWN` through the 1,000 ms reap protocol; a still-missing `DOWN` hard-halts status 1 without output. A first correlated interrupt notice performs bounded stop; afterward the main kills and proves worker `DOWN` within 1,000 ms before rendering. Missing `DOWN` on that interrupt path, a second handled signal or backstop expiry hard-halts 130. Every admitted ordinary outcome has one exit status; JSON is one compact object plus one LF and text mode emits only its defined bytes; no branch invents an observation |

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Surface | M6 change | Label |
| --- | --- | --- |
| Core runtime library (`apps/loopex/lib` outside `mix/`) | None | Unchanged |
| Core Mix tasks (`apps/loopex/lib/mix/tasks/`) | Two closure tasks added beside the existing checks | Development tooling |
| `LoopexComposition.Ephemeral` | New | Experimental |
| `loopex_composition` application tree | Adds `LoopexComposition.Application`, names it through `mix.exs` `mod:`, and owns the one-for-all gate/owner-supervisor tree plus the clean-stop callback handshake | Private host-edge lifecycle required by the ephemeral profile; durable composition behavior is unchanged |
| `LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` (M4/M5 rework) | Optional `:model`, `:bounds`, `:sampling` and `:active_tools`; defaults reproduce M5 exactly; released outer option behavior stays unchanged; named directories use the public helper, released `:resource_manifest` option and ADR 0025 session commands; the default policy revision is fixed at `"0.2.0"` | Experimental, additive; the revision keeps `0.2` recovery exact |
| `LoopexComposition.ResourcePacks.read_directories/2` | New; project and user skill directories, `user:<name>` identity | Experimental |
| The companion adapter (M1/M5 rework) | Pure mapping moved to `Loopex.LLM.ReqLLM.Mapping`; the dependency-visible tool-call mapper now decodes binary arguments without repair, rejects malformed payloads still visible after ReqLLM's buffered normalization rather than substituting `%{}`, and rejects visible provider-executed or provider-native calls instead of flattening them into replayable local calls; ReqLLM total, stream-idle and receive waits become `:infinity` so only the unchanged coordinator's sliced committed deadline governs the call | Private refactor, bounded fail-closed correctness fix and timer-safety fix; valid application-call reply mapping, dependency-normalized erased cases, protocol and deadline meaning unchanged |
| `loopex_llm_reqllm` application (M1 rework) | `req_llm` plus the direct exact `req` and `finch` dependencies are `runtime: false`: their code stays embedded but none enters the adapter application's automatic start list; the companion already starts the dependency set explicitly | Hardening; companion and host releases list all three as `:load` |
| Local executor (M2 rework) | An instance carrying the explicit ephemeral tool-lease capability removes the three per-provider credential variables as well as `LOOPEX_PROVIDER_API_KEY`; instances without it preserve M5 environment behavior. Ephemeral instances retain at most one unproved process group, freeze dispatch and send the private instance/lease-bound empty-group proof to the gate | Scoped hardening; public executor protocol, durable records and durable/direct default behavior unchanged |
| The vision (§12) | The credential exclusion narrowed for the ephemeral profile, by ADR 0039 | Made at ADR 0039's acceptance |
| Command line | `ask` and `-p` added; `refuse-all` selectable for `ask`, mapped to `LoopexCli.Policy.RefuseAll`; the launcher exports `ERL_CRASH_DUMP=/dev/null` for `ask` and `-p` only. The escript uses `app: nil`: invalid ask input starts nothing, valid ephemeral ask reaches the bounded composition bootstrap, valid durable ask starts the CLI graph through its fixed-diagnostic helper, and the exact-Mix-compatible legacy helper reproduces the former startup for every existing or unknown command; every existing subcommand remains behaviorally unchanged | Experimental command plus private startup rework |
| Release check (M5 rework) | Two real-provider rows and the `rollback` lane added; a per-row credential mode; credential clearing and redaction cover the per-provider names; `release_version` moved to `0.3.0`; the Ollama precondition | Development tooling |
| Model strings | New `provider:model` grammar | Experimental |
| Coding tools (M2 rework) | Three read-only tools defined; the durable default active set unchanged | Additive; activating them in a durable root narrows rollback as stated |
| Store (M1 rework) | `Loopex.Store.Memory` promoted from the conformance test wrapper; the local store unchanged | Private; additive |
| Journal, store format, protocol generations 1 and 2, executor protocol, daemon | None | Unchanged |
| Toolchain | Both pairs; the floor pair still passes the fast check | Unchanged |

<a id="technical-plan-migration"></a>
### Migration and Rollback

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Item | M6 answer |
| --- | --- |
| Supported source and target versions | `0.2` roots open unchanged under `0.3`; there is no new root format |
| Forward migration | None |
| Migration between profiles | None; an ephemeral session is never promoted to a durable one |
| Backup and restore or downgrade policy | Unchanged from `0.2`; the `0.2` binary opens and resumes every root `0.3` writes, with the two exceptions below |
| Pending interactions across versions | The default policy revision is `"0.2.0"` in both releases, so a pending interaction recovers and can be answered after an upgrade or a rollback |
| Exception: a call to an M6-only tool | A call not yet dispatched is re-resolved against the active tool set on recovery (`session_coordinator.ex:6602`); `0.2` answers `{:error, {:unknown_tool, name}}` (`:6844`) and commits it as a failed tool call (`:6625-6626`), and the run continues; its effect never ran, and the model sees the failure. A call already dispatched follows core's dispatched-effect recovery unchanged (`session_coordinator.ex:2789-2796`): `0.2` queries the executor, admits a matching receipt, and otherwise leaves the work pending for reconciliation; `0.2`'s executor defines no such tool, so it never runs it again |
| Exception: an admitted user skill | Its admission is journaled as a reference, digest, decision and selections (`session_state.ex:4898`) and its snapshot retained under the state root by digest (`resource_packs.ex:333-380`), as for any pack. `0.2`'s offline `loopex resume` reloads it by digest through core validation, which accepts its `user:<name>` identity (`resource_pack.ex:203-216`, `:343-348`). `0.2`'s daemon composes only discovered project skills (`daemon.ex:239-242`), whose manifest can never match the session's one admitted digest, so the session resumes with all of its skill context withheld, project skills included (`runtime/resource_snapshot.ex:112-121`, `runtime/resource_context.ex:38-47`). `0.2` cannot admit a new one |
| Proof | The `rollback` lane proves both directions and both exceptions |

<a id="technical-plan-packaging"></a>
### Packaging

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

- **No new application or newly resolved package:**
  - the memory store is a module in `loopex_store_local`;
  - the in-process adapter and the shared mapping are in `loopex_llm_reqllm`,
    which changes its existing ReqLLM declaration to
    `{:req_llm, "~> 1.24.0", runtime: false}` and adds direct exact
    `{:req, "== 0.7.4", runtime: false}` and
    `{:finch, "== 0.23.0", runtime: false}` declarations because the one-shot
    adapter calls their request types and transport API directly. The lockfile
    gains no package, and none auto-starts with the edge application;
  - the ephemeral API and start step are in `loopex_composition`; its existing
    application gains `LoopexComposition.Application` and the `mix.exs` `mod:`
    entry that owns the gate tree and clean-stop callback handshake;
  - the command is in `loopex_cli`.
- **Dependency budget:** `mix loopex.deps_budget` changes nowhere. The CLI
  reaches the ephemeral profile only through composition, as the client rules
  require.
- **Escript:** the existing build pair still embeds `loopex_composition`, its
  application callback and the companion used by `ask --state-root`, but its
  Mix escript configuration now sets `app: nil`. The generated wrapper therefore
  reaches `LoopexCli.main/1` without starting a Loopex application. Main performs
  only literal command classification before startup. Literal `ask` and `-p`
  complete their command grammar, prompt bounds and profile choice first;
  invalid input starts nothing. A valid ephemeral form invokes the public
  bounded composition bootstrap. A valid durable form calls the ask-specific
  helper, whose `ensure_all_started(:loopex_cli)` success starts the same graph
  and whose every failure becomes fixed `application_start_failed`. Every other
  argv calls the private legacy-start helper, whose success and formatted
  application-error/status-1 branches exactly match the prior Mix wrapper. The release witness stalls the first composition callback and
  proves the ephemeral bound, requires the exact composition tree live before
  gate lookup, proves the durable ask's bounded startup error, and replays every
  retained M1–M5 command witness through the explicit legacy-start branch,
  including one dependency-start error.
- **Host releases:** a host building its own OTP release with the in-process
  adapter lists `req_llm`, `req` and `finch` as `:load`, because all three edge
  dependencies are `runtime: false` in `loopex_llm_reqllm`; the developer guide
  states it. The guarded start step starts them in dependency order.
- **Version:** `VERSION` moves to `0.3.0`.

**Minimalism budget:**
- The ephemeral API is one public module over the existing facade. Per live
  session it adds one temporary owner and one long-lived `FacadeClient`; it
  creates no alternate session loop or durable truth.
- The model edge is the in-process adapter over the shared mapping, one thin Req
  adapter and one pure deadline module shared by the companion and in-process
  owner; its cleanup owner, caller, anonymous pool supervisor and registered
  request-free pool-lifecycle root are direct functions of that edge.
- The composition edge adds one VM-wide credential/tool gate, its persistent
  fail-closed marker, the single module implementing the model and executor
  edges' two private gate-client behaviours, and one DynamicSupervisor for
  ephemeral session owners.
  Owner admission uses one bounded guard and worker that both end before a
  successful handle is returned. ReqLLM hygiene uses one bounded worker per
  decision. Each session adds one `SessionRoot`, one private supervisor, one
  runtime trace-capability process and one `RuntimeHolder`; these are required
  to keep blocking starts out of the owner, bind sensitive-call exclusion to
  the exact runtime and preserve the OTP parent of every surviving edge.
- The local executor adds one private at-most-one-group proof state and one
  gate-only drain handshake; no core behavior or executor protocol changes.
- The memory store is the promoted 125-line wrapper.
- The command adds one parser branch, one renderer mode, one monitored worker
  and one correlated state in the existing signal handler so the main process
  can own signal handling; the launcher adds only its pre-child signal latch.
- The three tools are three definitions and three effect clauses.
- The closure tooling is two Mix tasks and three shell scripts.
- Nothing is added beyond that: no configuration framework, no second loop, no
  credential store or custodian, no new process type in core. Cleanup and
  durable-follow helpers are bounded, operation-scoped processes rather than
  supervisors or retained services.

<a id="technical-plan-limitations"></a>
### Named Limitations

Concept: [Non-goals](M6.md#concept-plan-non-goals).

| # | Limitation | Why it is accepted |
| --- | --- | --- |
| 1 | In the ephemeral profile the host environment has a hosted credential for the host's lifetime. During the call and owned cleanup until they end, the caller, tagged pool, provider HTTP/TLS state, crash reports, crash dumps and host telemetry may expose it; a host-made copy has host-owned retention. Cleanup proves the caller and tagged pool gone. Beyond the continuing host environment and host-made copies, a checked-out socket and its OTP TLS controller may retain request material while they drain | ADR 0039's vision amendment accepts this scoped exposure; the exact value is gated before a reply enters a Loopex plane; TLS reuse, tickets and secret retention are disabled; `SSLKEYLOGFILE` is refused; the caller is sensitive and excluded from Loopex tracing; no result route remains after cleanup. Under isolated release conditions the socket and controller must be gone within 5,000 ms of caller `DOWN`, but runtime cleanup does not wait for or prove that threshold; no arbitrary heap-erasure claim is made; the durable profile keeps structural isolation |
| 2 | ReqLLM's start settings and, once Loopex starts it, its application plus Req's shared infrastructure stay for the VM's life unless the host stops them; a host that wants ReqLLM started earlier must start it itself with `.env` loading off and declare it | ReqLLM reads the settings only at start; composition refuses rather than inherit an unknown start. Loopex does not stop or reference-count shared dependencies another component may use, but no model call uses their default pools and the lifecycle witness proves the surviving infrastructure retains no per-call request or credential. Loopex also refuses `TIDEWAVE_REPL="true"` before it can start ReqLLM's optional listener; a host-started dependency may already have created one, which is a host-owned side effect Loopex cannot undo |
| 3 | A hard VM kill or an unexpected crash of the ephemeral owner itself can leave the temporary root behind; a surviving opaque handle can report `session_unavailable` but cannot prove cleanup or name a root the crashed owner failed to retain | The root is under the host's temporary directory, mode `0700`, and holds no committed session truth because the store is in memory. It can hold the executor receipt ledger, which is committed effect evidence and is why an unproved root is never deleted. Caller exit, ordinary stop and startup failure remain covered by the cleanup-and-report contract. An `ask` command whose unmarked owner or scheduling gate crashes and therefore cannot obtain a public cleanup proof emits no JSON and exits with status 1, even if it had already observed the run |
| 4 | A durable model must name a provider the single `LOOPEX_PROVIDER_API_KEY` serves, needs the built companion, and cannot be a local Ollama model | Per-provider durable credentials belong to the M7 draft's configuration decision |
| 5 | `ask` offers no deferring policy; a deferred interaction is an API matter | Answering needs a client that holds the question; the app server and an embedding host are those clients |
| 6 | The JSON result carries no usage or model identity | They are not public events; adding them is a protocol decision |
| 7 | An ephemeral session's memory grows with its history, bounded per run but not across runs | Ephemeral sessions are meant to be short; stopping the session releases it |
| 8 | A stop whose cleanup cannot be proved, or whose recursive root removal fails, keeps an owned temporary root for the host to remove after its users end. A lost exclusive-mkdir result instead names a possible path with unknown ownership and authorizes no deletion | Deleting an owned root while an effect or per-session process may still use it would be worse; deleting an unknown path could destroy pre-existing host data. The path, ownership and pending obligation are named in the error. A later stop retries only an owned unproved session-subtree stop or root removal; an unknown claim, unproved run ending, effect cleanup or process-group proof remains conservative for the VM lifetime |
| 9 | Rolling a durable root back to `0.2` fails a not-yet-dispatched call to an M6-only tool as `unknown_tool`, withholds all skill context of a session with a user skill under `0.2`'s daemon, and `0.2` cannot admit a new user skill | Stated and proved by the `rollback` lane; the call's effect never ran |
| 10 | The adapter refuses to run while the host sets any `:req` default options; model calls use HTTP/1 only | Default options reach every request; a host that needs them composes the durable profile. Finch's multiplexed HTTP/2 pool can resend below Req's control, and HTTP/2 negotiated on its HTTP/1 pool fails requests above the initial flow-control window; HTTP/2 waits for a transport that removes both limits |
| 11 | A model's reply arrives whole in the ephemeral profile, with no streamed progress, and each call starts and tears down a new tagged pool while its checked-out transport may drain asynchronously | Progress is transient and never session truth; the per-call pool prevents cross-call connection or TLS-session reuse, at the cost of one handshake per HTTPS call. Shared `Req.Finch` registry infrastructure persists but holds no per-call request, connection or credential after owned cleanup; the socket and OTP TLS controller are outside that infrastructure and are covered by limitation 1; the durable companion keeps streaming |
| 12 | The daemon is unchanged, so a durable session with a user skill resumed through it cannot match the admitted snapshot and has all of its skill context withheld, project skills included | Named skill directories in daemon-owned sessions belong to the M7 draft's saved configuration; the offline `loopex resume` reloads them |
| 13 | The reply gate detects the exact resolved credential value, not an encoded, fragmented or otherwise transformed derivative a provider invents; same-VM host code can deliberately tamper with global registry or configuration after a guard | Exact known-value exclusion is testable without treating arbitrary output as secret by resemblance; a host needing a stronger structural boundary uses the durable profile, and trusted host interference is outside an in-VM library's protection |
| 14 | A host-started Req/Finch may have opened an `SSLKEYLOGFILE` destination before composition | Loopex cannot undo a host side effect. Model calls never use the shared default pool; composition and each call refuse while the variable is set; when Loopex starts Req/Finch itself the guard runs first; and the witness distinguishes fresh-VM non-creation from no new open or append by the call-owned pool |
| 15 | The in-process adapter refuses a provider response body over 8 MiB and any content-encoded response | The internal bounded collector halts HTTP/1 before retaining more body bytes, and identity encoding avoids an unbounded decompression stage. Hosted model replies are expected to be far smaller; a host needing a different transport contract uses the durable companion or a later adapter decision |
| 16 | The scheduling gate covers only sessions and calls created by the ephemeral composition. A durable composition, directly constructed executor or trusted host process in the same VM can overlap a tool with the ephemeral provider path | Same-VM code is not a sandbox boundary. A host needing that exclusion gives the ephemeral profile a dedicated VM; the durable profile keeps provider execution in its isolated companion |
| 17 | An active-tool owner that cannot prove its process groups empty, an unproved credential-call root, or a gate/supervisor crash poisons both lease modes until the VM restarts; the crash also ends every active ephemeral session and leaves its handle unavailable | Reopening either mode could expose a credential beside an orphan tool or admit a tool beside an orphan credential path. The persistent fail-closed marker survives application-process restart but contains no credential, request, policy or session truth |
| 18 | After a credential caller and its pool are gone, the gate waits 5,000 ms before admitting an ephemeral tool, but it cannot observe or prove that a checked-out socket or TLS controller finished draining | The interval is the isolated release witness threshold, not a runtime cleanup proof. A transport that exceeds it can overlap a later tool; a host requiring structural exclusion gives the profile a dedicated VM |
| 19 | `ask` can perform an orderly first-interrupt stop only after it has an ephemeral session handle. The launcher latches and forwards a pre-handle signal but preserves the reaped platform child status and promises no Loopex cleanup or result; a second handled signal or backstop expiry may hard-kill the VM and leave a temporary root without output | Before the opaque handle exists the command has no public stop target; the latch closes the lost-signal window without inventing a cleanup target or portable status. Repeated interrupt remains the operator's immediate escape hatch. The real-signal witness distinguishes the pre-handle, orderly and hard-kill paths |
| 20 | The local executor's pathname checks, including the read-only walker, do not pin directory handles and cannot guarantee workspace confinement against a concurrent same-user filesystem swap or mutable mount | Erlang's `:file` API exposes neither `openat` nor `O_NOFOLLOW`. Lexical checks, parent realpaths, `lstat` and post-open identity checks refuse ordinary escapes and type replacements but do not create an OS sandbox; a host needing that boundary uses an isolated hand or otherwise controls workspace mutation |
| 21 | The read-only walker materializes the complete entry-name list for one directory before sorting it and applying traversal caps | Erlang's `:file.list_dir_all/1` has no streaming iterator. The walker avoids materializing the whole tree and bounds all work after each directory enumeration, but a host must not treat the 10,000-entry or 8 MiB path cap as protection from the allocation or time cost of one exceptionally large directory |
| 22 | After `ask/3` or `answer/3` returns a timeout, a later command or attachment failure in the sole-owner background drain cannot deliver a second no-ending snapshot | No API caller is then waiting and the opaque handle retains only its lifecycle cell. The earlier timeout remains the public observation; the owner cancels the drain, performs cleanup, emits any retained root and pending obligations only to the host logger, exits unmarked, and later handle calls return bare `session_unavailable`. Because standalone `ask` suppresses the logger, that command can leave this retained root unnamed |
| 23 | A helper sent an untrappable kill can temporarily outlive a bounded API or command return when its exact `DOWN` is not available: the composition-bootstrap guard or worker, core client actor, cleanup phase worker, root-removal worker, owner-start helper, provider owner-candidate start proxy or durable `FollowReader`. A queued provider-candidate start may also materialize an undisclosed start-blocked child after the callback returns. Separately, the locked worker-retained/guard-unregistered interval can let a pre-registration model result precede a disclosed authority-free candidate's `DOWN` | BEAM scheduling cannot make process death synchronous, and killing a caller cannot retract a queued `Task.Supervisor` request. Its result is inadmissible; the session retains the exact monitor and cleanup obligation, owner-start or an unknown provider-candidate start poisons the gate, or durable `ask` returns the fixed `follow_reader_cleanup_unconfirmed` diagnostic. An undisclosed or pre-registration candidate captures no request, options, credential, gate, root, pool, caller or dispatch authority, receives no `begin` and exits on its first scheduled dead-proxy, dead-callback or expired-deadline step. The pre-registration result proves no registered provider-resource obligation, not candidate `DOWN`; complete session-subtree cleanup still reaps it. Exact managed registration restores the stronger registered-owner proof. No replacement cleanup phase or removal worker starts until its retained predecessor is proved down. A later creation call may start another bootstrap guard because the predecessor received no session input or authority and can only have submitted OTP's idempotent serialized application start. A detached `FollowReader` has no output route and its disposable cursor cannot consume durable truth from the callback's accepted cursor |
| 24 | Locked ReqLLM's buffered provider builders can generate a replacement for a missing tool-call id, normalize missing, nil, empty or unsupported arguments to `{}`, force the function type, omit a malformed call and remove earlier error metadata before Loopex's shared mapper | The mapper cannot reconstruct erased provider-wire facts. It rejects malformed binary arguments, invalid fields and provider-executed or provider-native classifications that remain visible. An omitted call executes nothing; a normalized `{}` still crosses core tool resolution, schema validation and host policy. Requiring raw-provider validation would add a provider-specific response parser beside ReqLLM and is outside this minimal adapter milestone |
| 25 | After an ordinary ephemeral `ask` worker sends a provisional result, failure to prove that exact worker `DOWN` through the 1,000 ms kill-and-reap protocol hard-halts the command with status 1 and promises neither output nor cleanup | Rendering or entering stop while an unproved worker can still use the handle would admit two owners of command progress. BEAM scheduling cannot make `DOWN` synchronous; the hard halt is a bounded fail-closed terminal path, exercised independently from the interrupt status-130 path |
