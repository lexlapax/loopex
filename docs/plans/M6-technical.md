<a id="technical-depth"></a>
## Technical depth

Concept: [M6 minimal runnable Loopex](M6.md#concept).

<a id="technical-plan-prerequisites"></a>
### Prerequisites and Acceptance Points

Concept: [Purpose](M6.md#concept-plan-purpose).

Concept: [Design decisions](M6.md#concept-plan-decisions).

M6 first waited on ADR 0039. Proposed ADR 0040 now governs two corrections
to startup and cleanup. Each must be accepted before the closure candidate
claims its dependent outcome, not before unrelated work, and neither may be
outstanding at closure. The
repository status check reads the links in this section, so a decision named
only in prose declares nothing.

| Decision | Acceptance point | What its acceptance settles |
| --- | --- | --- |
| [ADR 0039](../adr/0039-ephemeral-embedded-profile.md#concept) | Before the in-process model adapter, the memory store, the ephemeral composition, named skill directories or the fixed policy revision is written. Outcome 6, the read-only tools and the durable composition's model, bounds, sampling and active-tool options do not wait on it | Outcomes 1 to 5: the two profiles, the memory store's truth statement, one in-process ReqLLM adapter for every provider with credentials read at the model boundary, its guards, one-shot dispatch, call-owned tagged transport and cleanup, the paired vision amendment including the additional proposed host-selected remote-catalog trust scope, the ReqLLM start step, the default model, the skill rule with its two ADR 0025 supersessions, the fixed durable policy revision and its stated rollback limitations, the authority rule, and `ask`'s machine contract |
| [ADR 0040](../adr/0040-ephemeral-startup-interrupt-and-unnamed-root.md#concept) | Before the tested M6 closure candidate claims outcome 3's pre-claim cleanup exception or outcome 4's pre-startup signal installation | The narrow `root: nil` unproved result, its no-deletion and sealed-session rules, and the `ask` handler installed before session startup |

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
- model calls use HTTP/1, and HTTP/2 is future work gated on Finch.

**Maintainer decisions, 2026-09-27:** the maintainer selected the non-streaming,
sensitive-caller path with one uniquely tagged HTTP/1 Finch pool and one-shot Req
dispatch adapter per call. Hosted ephemeral models may use the same coding or
read-only tool presets as Ollama; supported credential variables may already be
set in the host environment. Missing call-cleanup proof seals only its session;
a proved failed call does not itself seal it. There is no cross-session
exclusion or VM restart requirement. These
are proposed-plan decisions; accepting ADR 0039 and this plan pair remains separate.

The tagged pool and one-shot fence replace the shared-pool and
`Connection: close` approach: a request header cannot force peer closure or
prevent retained TLS session state. One owned pool gives local teardown an exact
target; the request remains in the sensitive caller. HTTP/2 stays future work.

<a id="technical-plan-mint-security-maintenance"></a>
#### Exact Lock Change and Verification

Concept: [Mint security maintenance](M6.md#concept-plan-mint-security-maintenance).

The approved lock amendment changes exactly two records: Mint `1.10.1` to
`1.11.0`, and HPAX `1.0.4` to `1.1.0` because Mint `1.11.0` requires HPAX
`~> 1.1`. Finch remains `0.23.0`, Req remains `0.7.4`, and ReqLLM remains
`1.24.0`. No package is added or removed. The [Mint changelog](https://github.com/elixir-mint/mint/blob/main/CHANGELOG.md)
names the HTTP/1 transfer-coding and HTTP/2 header/frame fixes; the
[HPAX changelog](https://github.com/elixir-mint/hpax/blob/main/CHANGELOG.md)
names the decoder behavior required by Mint. These are source facts, not a new
HTTP/2 route for the M6 model adapter.

`mix loopex.deps_budget` must prove the current non-optional package closure
and core dependency direction. Compare the package keys in `v0.2.0` and
candidate `mix.lock` independently to prove that the package-name set did not
change; the budget task alone does not establish cross-version equality. The
model-route and one-shot HTTP/1 suites,
TLS/pool drain witness, fresh-source materialization, both toolchain fast
checks, normal provider lanes and pristine-`v0.2.0` rollback must run on the
final tested candidate. The dependency's stricter response parsing may turn a
malformed peer response into a bounded model failure; no Loopex schema, journal,
or stored-state migration follows. The accepted ADR 0039 source citations
describe the dependency locked at its acceptance; the M6 candidate's tests
and exact current source, not those historical line numbers, prove the updated
dependency's transport behavior.

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
| Are trust and credential transitions complete? | ADR 0039 and the adapter contract name every participant, capability, guard boundary, credential read, value check, session containment, bounded initialization recovery and trusted host limit |
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
| 0. Governance prerequisite | P2's `AGENTS.md` and verification-guide selected unattended release lanes | Plan acceptance | Before any provider-touching merge |
| A. Model and store | In-process adapter, per-call cleanup owner, one-shot HTTP/1 adapter, shared mapper and two-consumer deadline arithmetic in `loopex_llm_reqllm`; load-only dependencies and their literal parser and exact edge-check/materialization whitelist plus negative vectors; promoted memory store | ADR 0039 | Foundation; either order with B |
| B. Local executor | Three read-only tools, session-cell/admission dispatch check and direct nonce-bound process-group drain proof in `loopex_executor_local` | ADR 0039 for session containment; otherwise independent of A | Foundation; either order with A |
| C. Composition | Embedded API, one-worker application bootstrap, `:one_for_one` application tree with `ReqLLMStarter` and owner DynamicSupervisor siblings, owner activation proxy, private session subtree, durable added options/policy revision, skill helper | A and B for ephemeral profile; neither for durable options | After A and B |
| D. Command | Ask/-p grammar, rendering, interrupts, launcher latch, escript command-aware bootstrap | C | After C |
| E. Closure tooling and documentation | Two Mix tasks, three scripts/fixtures; P1/P3/P4, operator/developer pages, indexed closure scaffold | Tooling independent; product docs follow A–D | Last |



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
        root: String.t() | nil,      # exact known path, or nil only before root claim
        root_ownership: :owned | :unknown,
        pending: [
          :run_ending | :effect_cleanup | :process_groups | :session_subtree
          | :root_removal
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
        | :ephemeral_owner_start_failed
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
`:unknown` for a lost temporary-root claim result, where the named path may
have pre-existed, or for an unproved pre-claim child before any path is known.
In the latter case `root` is `nil`, `pending` is exactly `[:session_subtree]`,
`ending` is `:none`, and the cell is sealed. Neither unknown form authorizes
removal. `unproved.pending` is a non-empty, duplicate-free subset emitted in this fixed
order: `:run_ending`, `:effect_cleanup`, `:process_groups`,
`:session_subtree`, `:root_removal`. It names every cleanup
obligation the owner reached and could not prove in that attempt; it does not
name a downstream phase that its prerequisites prevented it from entering.
Root removal is reached only after the run, effect, process-group and subtree
obligations are proved; a failed prerequisite omits downstream obligations.

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
| `:tools` | Exactly `:none`, `:coding` (`read`, `write`, `edit`, `bash`) or `:read_only` (`read`, `grep`, `find`, `ls`). Only presets are accepted because their projections carry the ADR 0017 system-class witness. Every admitted provider accepts each preset. Supported host credential variables may be set; OS child environments retain released behavior, with no new scrub or same-user isolation promise. | `:coding` |
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

After value validation, creation checks in fixed order: resolve `:cwd`; read
the complete named skill list; split/admit model prefix; map its expected built-in
module; check empty Req defaults, unset SSLKEYLOGFILE and Tidewave guard; bootstrap
the composition application; perform or join the bounded ReqLLM initialization;
verify the initialized provider registry's exact module; select/normalize the
explicit or built-in address; activate a temporary owner. Each first failure wins,
and no credential is read during composition. Combined-fault fixtures pin adjacent
pairs and the same order independent of input keyword enumeration.

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
     `:session_unavailable`; and
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
  handle also contains one private session-local `:atomics` two-slot cell: slot 1 is 0 open, 1
  stopping, 2 proved closed, 3 cleanup unproved; slot 2 is 0 no pending model,
  1 pending model/call cleanup. The owner passes this same cell
  explicitly through private model and executor constructors. It carries no
  credential or durable truth. Grant checks admit only 0; 1, 2 and 3 refuse new
  work. Stop uses compare-exchange 0→1; a containment failure compare-exchanges
  only 0 or 1 to 3, preserving an existing 3 and never overwriting proved-closed 2
  before its result or notification. State 2 is absorbing; late failure notices
  cannot revoke its exact proof. No code changes 1 or 3 back to 0. Only
  proved session cleanup and root removal may set 2, including a successful
  later stop retry. A lost notification cannot undo the shared containment state.
  Public lifecycle mapping reads slot 1: at 2, stop is idempotently successful
  and other calls return `session_closed`; at 1 or 3 a live owner accepts only
  stop for bounded proof completion or retry, while non-stop calls return
  `session_unavailable`. An absent owner at 0, 1 or 3 is unavailable, never proved closed.
  The application DynamicSupervisor starts each owner with
  `restart: :temporary`, so neither a successful stop nor a crash creates a
  replacement owner for the same handle.
- **Session supervision.** Each temporary owner monitors the exact owner
  DynamicSupervisor supplied at activation. Supervisor loss ends that owner's
  available lifecycle; it does not create a replacement owner. The composition
  application's initializer is a `:one_for_one` sibling, not an ancestor of a
  session: its failure never instructs existing owners to stop. A private
  session-subtree failure seals the shared session cell to 3, rejects new API,
  model and executor grants, and performs that session's bounded cleanup. A
  retained root is logged when no waiter can receive it.

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
    observation, subject to the narrow pending-terminal reconciliation below:
    an empty retired pre-begin candidate must be released/reaped before exposure.
    It never returns an answered question or an observation from
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
  afterward it returns the pending interaction or terminal result, except that
  the empty-invocation barrier retains a terminal pending until candidate DOWN;
  the timeout snapshot remains visible meanwhile. A question
  ends the background drain but not the run: a next `ask/3` still returns
  `:run_open` until that question is answered and the run eventually reaches
  `run.finished`. Only a terminal observation with any required empty-candidate
  release/DOWN reconciliation complete permits a new prompt. Stop cancels
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
- **`stop_session/1`** coalesces concurrent stops. The first stop changes the
  shared cell from 0 to 1 (a prior 3 remains sealed), records one saturating
  monotonic deadline `now + cleanup_grace_ms + 5_000`, and closes new API, model
  and executor grants. Every later stop joins the same attempt; non-stop calls
  immediately return `session_unavailable`. Neither stopping nor unproved state
  can become open again. The public stop request uses a disposable monitored
  requester, with an absolute 12,000 ms outer response bound: the owner's
  5,000 ms default cleanup grace, its additional 5,000 ms teardown bound,
  1,000 ms for admission and reply, then at most 1,000 ms to reap an unanswered
  requester. If a live owner cannot answer, the caller kills and reaps that
  requester and returns bare `session_unavailable` without
  claiming cleanup. A later owner reply goes only to the retired requester,
  never into the embedding host's mailbox. Requester death also follows its
  borrower death; the owner may still finish its already-submitted stop.
  An ungranted facade operation receives correlated cancel; its acknowledgement
  proves no admission. An already granted operation is allowed to return only
  until the earlier of its existing deadline and cleanup deadline, solely to
  resolve admission state or observe its ending. It is never delivered as a
  new question after stop. A lost/malformed return is conservatively possibly
  admitted. If a run is open, the owner sends one fresh bounded abort id, requires
  exact `{:accepted, same_id}`, and follows only that run to a validated ending.
  Missing terminal identity or malformed numeric fields leave `:run_ending`
  unproved. A valid `outcome_unknown` ending leaves `:effect_cleanup` unproved
  (`session_coordinator.ex:6000-6006`); any other named terminal ending proves
  that run's applicable effect cleanup. No run makes both obligations vacuous.

  The abort/ending and facade-client reap finish within cleanup grace. The owner
  then runs process-group proof, runtime stop, private subtree stop, and root
  removal serially under the same remaining deadline. It never calls the locked
  potentially infinite `Loopex.stop/1`, supervisor stop or filesystem removal in
  its receive loop. The fixed additional 5,000 ms covers three at-most-1,000 ms
  phase slots and a root-removal slot; absent phases are skipped. Each phase
  uses one linked, monitored non-trapping worker, with a 500 ms operation cutoff
  and exact normal DOWN required within its 1,000 ms slot. Result PID, reference,
  phase and completion timestamp must match. An in-time result is provisional
  until the worker accepts the owner's correlated finish and then exact normal
  DOWN; the owner sends finish only for the matching validated in-time result.
  Failure or expiry sends untrappable kill and makes
  one zero-wait receive at the slot deadline. Only one phase worker exists at a
  time. A single persistent cleanup worker would mix a previous infinite API
  call with the next phase after timeout; separate operation-scoped workers and
  exact DOWN prevent that concrete overlap. This is one reused worker function,
  not a helper module or retained supervisor for every phase.

  The owner receives and retains the exact executor-PID/instance/session/nonce
  certificate directly before runtime shutdown. It accepts a worker's drain
  result only after that certificate and exact worker DOWN. Once proved, group
  cleanup is never repeated, even after executor DOWN. A returned group failure
  may leave `:process_groups` pending while independent runtime/subtree stop
  still runs. No-executor rollback is the only vacuous group proof. A missing
  worker DOWN prevents every later blocking phase in that attempt and retains
  `:session_subtree`; the exact monitor must be reaped before any replacement.
  The same rule applies to the facade client. The owner trusts recorded
  child/root monitors, not a worker's assertion that a subtree ended.

  Cleanup is proved only when:
  1. the current open run has a structurally valid matching ending, or no run
     existed;
  2. that ending proves effect cleanup, or no run existed;
  3. every applicable executor process group has its retained direct certificate;
  4. facade client, phase worker, SessionRoot, RuntimeHolder, private supervisor
     and every recorded per-session child are DOWN; a granted startup phase
     without an exact return remains unknown even if known parents are DOWN;
  5. the outstanding model record is cleared by its exact cancellation or
     provisional-or-managed retirement proof and cleanup-owner DOWN, every recorded call
     process is DOWN and both tagged registry entries are absent; a pending or
     unproved record blocks closure even when its parent has ended;
  6. only then, an owned root has a successful bounded removal and owner-side
     absence check.
  A removal worker carries only the exact root, links to the trapping owner,
  and must have its exact DOWN observed. Unknown ownership never authorizes
  deletion. Missing removal DOWN is retained and a later stop reaps it before
  starting another. Removal failure names `:root_removal`; a prerequisite
  failure never claims that removal ran.

  A reached unproved obligation seals cell 3 before any return or failure
  notification. It returns `cleanup_unproved` with exact root/ownership and a
  duplicate-free pending list in order `run_ending,effect_cleanup,process_groups,
  session_subtree,root_removal`, naming only reached failures. An absent ending
  omits unevaluated effect cleanup. Missing facade-client DOWN omits unreached
  group phases and names subtree; independent reached group/subtree failures
  combine. No result or missing notification can reopen the shared cell.
  The map's ending is the current validated terminal, the current possibly
  admitted request's bounded no-ending snapshot, the last pending interaction
  when no later request was admitted, or none. It never substitutes an earlier
  run. A waiting request before admission receives bare unavailable after proved
  cleanup, or cleanup_unproved with ending none; after possible admission without
  a terminal it receives cleanup_unproved retaining the current no-ending
  snapshot. A terminal arriving during stop wins for that request, while stop
  still returns its own cleanup disposition.

  A surviving caller-visible failed-stop owner with only subtree or owned-root
  removal pending accepts only a later stop retry. An unproved ending, effect
  or executor certificate that cannot be recovered conservatively retains the
  root, exits unavailable and does not expose a false retry-success path.
  Each retry gets a fresh common cleanup deadline, reaps exact retained monitors
  first, reuses accepted certificates and resumes only outstanding safe proof
  phases. It never manufactures a terminal, redrains a proved group or calls an
  ended executor to reconstruct a missing certificate. An irrecoverable missing
  run/effect/certificate remains unproved and the root remains retained. A
  successful retry proving all obligations and removal sets cell 2, replies
  `:ok` and ends the owner. Repeated stops then return `:ok`; other calls on
  cell 2 return `session_closed`. An unexpected owner death with cell 0/1/3 is
  unavailable, never cleanup success.
  One-shot and no-waiter paths expose no retry handle: they log retained roots
  when permitted and end after the bounded attempt. Creator exit performs the
  same cleanup; if an owner stays alive in failed-stop state, creator exit makes
  one final bounded retry and then exits. None of these outcomes blocks a new
  session or terminates a peer.

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
creator: an owner failure therefore leaves other host processes alive
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
credential. Every in-process provider admits `:none`, `:coding` and
`:read_only`. Ambient credential variables do not refuse composition or tools;
the proposed vision amendment names the trusted tool audience.

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
`spawn_monitor`s a start-blocked lifecycle root, records its exact monitor, and
then lets that root start a user-managed pool under an anonymous supervisor,
with `protocols: [:http1]`,
`size: 1`, `count: 1` and no metrics. HTTPS alone adds exactly
`conn_opts: [transport_opts: [reuse_sessions: false, session_tickets: :disabled,
keep_secrets: false]]`; HTTP omits `conn_opts`. Finch passes the outer
`conn_opts` to Mint, and Mint reads the SSL values only from its nested
`transport_opts`. That single monitored, request-free lifecycle root
performs the exact empty-registry check, rechecks SSLKEYLOGFILE itself immediately
before the one `Finch.Pool.child_spec/1` (whose cast opens the file), then anonymous
supervisor start, `DynamicSupervisor.start_child/2`, inspection and later graceful
teardown while the cleanup owner stays in its receive loop. It owns the
anonymous supervisor, synchronously registers every returned PID with the owner
before proceeding, traps ordinary exits, monitors the cleanup owner and begins
the same unwind on owner `DOWN` or an exact stop message, and derives the exact HTTP/1 worker PID from the returned
pool-supervisor PID, requiring
`Supervisor.which_children/1` to be exactly
`[{1, owned_pid, :worker, [Finch.HTTP1.Pool]}]`, and requires the full
duplicate-key registry lookup to be exactly
`[{owned_pid, Finch.HTTP1.Pool}]`, while the unique
`Req.Finch.SupervisorRegistry` lookup is exactly
`[{pool_supervisor_pid, {Finch.HTTP1.Pool, 1, expected_pool_config}}]`, before
the caller starts and again at the dispatch grant. Derive `expected_pool_config`
once from the actual `Finch.Pool.child_spec/1` start tuple, validate its complete
fixed projection as ADR 0039 specifies, then compare the entire stored map.
A subset/containment check is insufficient. Tests separately compare the exact
caller-supplied option list, including the three HTTPS retention options;
Finch's expanded map also includes the nil key-log device and cast defaults
(finch.ex:533-560). The dispatch-time check is a command to this same
registered lifecycle root, not a new helper. If that check does not return, the
owner remains responsive, withholds dispatch and success, and takes the
unproved-cleanup path unless cooperative root teardown completes. Complete
setup must answer before the earlier of 1,000
ms and the call deadline. Stop can request and await cooperative unwind during
every setup phase. The lifecycle root exits only after every registered
descendant is `DOWN`; if a dependency call prevents that proof, no provider
result or successful acknowledgement returns and only this session remains sealed.
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
`{caller_pid, ref, result, finished_at_native}` before blocking until its owner
ends it and proves DOWN. A result is
admissible only when its timestamp is no later than the mapped deadline. When
the owner first observes expiry, one zero-wait receive lets an already-queued,
matching, in-time result win; otherwise expiry makes every result inadmissible
and the owner kills the caller. The converted native instant may be an arbitrary-
precision integer; only capped slices reach OTP or Finch, so no unsigned-64-bit
duration or native remainder reaches a relative timer. Finch casts an omitted
connect timeout to 5,000 ms (finch.ex:16,537); the cleanup owner's committed
call deadline is still authoritative and kills the caller if that earlier
deadline wins during DNS, connect, TLS handshake or I/O.

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
:infinity]`. Final Req validation requires the explicit receive timeout and
nested pool timeout; an absent `:request_timeout` normalizes to `:infinity`,
Req's default. An explicit value must also be `:infinity`. It
refuses `:pool_strategy`, `:inet6`, `:pool_max_idle_time`, `:unix_socket`,
`:finch_request` and any other Finch request/build or connection-routing option. It never calls
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
base URL as endpoint) and dispatch. Inline construction bypasses selected-model
catalog resolution and the string resolver's unverified-model warning, which
matters for uncatalogued Ollama models. It does not bypass Anthropic's metadata
lookup. Both planning (`request_plan/diagnostic.ex:84-109`) and generation
translate options (`provider/options.ex:399-402`) through
`providers/anthropic.ex:853-865,1466,1482,1494-1524` and
`model_helpers.ex:94-123,159-174`. The fallback calls `LLMDB.model/2` to determine
adaptive thinking. With the exact M6 list and no thinking option it changes no
option, but still loads shared catalog metadata if absent.

LLMDB retains a snapshot, epoch and load options in `:llm_db_store`
(`llm_db/catalog.ex:64,91-94`). A preloaded snapshot is used unchanged; cold
loading reads host settings (`catalog.ex:107-123,305-319`). Default `:packaged`
plus existing `compile_embed: true` uses the compiled snapshot without runtime
files or downloads (`config/config.exs:23`, `llm_db/packaged.ex:58-69`). Loopex
neither changes sources, filters, overlays or `:skip_packaged_load`, nor clears
metadata on cleanup. Host-selected `{:file, path}` or `{:github_releases, ...}`
can instead read disk or fetch/cache snapshots through ordinary Req, potentially
using `GH_TOKEN`/`GITHUB_TOKEN` (`llm_db/loader.ex:580-606`,
`llm_db/snapshot/release_store.ex:275-289,675-684,902-953`). Such trusted-host
catalog effects are outside the call-owned model transport guarantee.
Cold initialization and callers waiting for it share LLMDB's VM-wide
`:global.trans` load lock (`catalog.ex:305-306`); that wait and fetch consume
each call's existing deadline. A loaded snapshot bypasses it. Loopex adds no
catalog scheduler or timeout. A failed cold load installs no snapshot or cached failure;
a later independent or already-waiting call can run the host loader again
(`llm_db/catalog.ex:107-122`, `llm_db.ex:152-162,540-549`). That is dependency
loading, not an internal retry of the failed adapter invocation. Separately,
unchanged core may admit another proved not_dispatched attempt within its
two-attempt limit; a failed catalog invocation creates no model dispatch or
blind replay authority. Catalog load failure can raise inside metadata loading
(`catalog.ex:126-130,206-209`). ReqLLM.plan normally rescues translation failures
and returns a sanitized error (`request_plan/diagnostic.ex:40-41,106-115`,
`req_llm.ex:422-423`). The sensitive caller normalizes that error and catches
any escaping raise before generate_text/selected-provider-key resolution, returning fixed
`{:error, {:not_dispatched, "model_call_failed"}}` only after owned teardown;
no model dispatch or raw loader reason escapes. This selected-provider-key-free planning
failure is distinct from an activation-registration failure and a started call.
Reply identity is built from the retained inline model, not the existing durable
`identity/1` string resolver (`req_llm.ex:181-188` in the adapter application).
Under this list, synchronous Ollama, OpenAI and OpenRouter preparation/decoding
do not query the catalog. OpenAI Responses retains the attached model before
its deep-research fallback (`providers/openai.ex:707`, `step/usage.ex:47-52`,
`providers/openai/responses_api.ex:1644-1677`). The named request-body witnesses
pin dependency normalization; no new dependency policy is introduced.

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
OpenAI it first probes the surface through credential-free
`ReqLLM.plan(model_spec, :chat, probe_options)`
(`deps/req_llm/lib/req_llm.ex:420-423`). The probe uses the same ordered
generation options below but omits only `req_http_options`, because those
options contain the fingerprint whose path depends on the selected surface.
After forming the fingerprint, it calls `ReqLLM.plan/3` again with the complete
planning options and requires the second surface and route to equal the probe;
any mismatch refuses before credential resolution or dispatch. Only the second
plan is authoritative. Its planning options are exactly, in this order,
`max_tokens`, `tools`, `total_timeout: :infinity`,
`receive_timeout: :infinity`, `max_retries: 0`, `base_url` and the complete
`req_http_options` stated above; no `api_key`, `operation` or `cache` member is
present. The literal `:chat` matches the `generate_text/3` path.
Both planning passes are network-free with default compiled metadata or a
preloaded non-fetching snapshot. A host-selected cold remote catalog can
perform the separate host-owned effects above before any selected provider key
is read.
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

**Credentials and session containment.**
- Model options contain only the fixed provider variable name (or nil), admitted
  base URL, runtime trace-capability handle, private session-admission handle and
  the same session-local lifecycle cell. They contain no credential value. The sensitive caller reads exactly its
  provider's variable immediately before generation; absent, empty or >65,536-byte
  values refuse without dispatch. Composition never probes environment values.
- Each admitted provider may use none, coding or read-only tools. Tools and model
  calls may coexist in the host VM. This profile is trusted same-VM execution,
  not a secret-isolation boundary; the amended vision names the caller, transport,
  host environment and host-made diagnostics. There is no global exclusion,
  lease, cross-session timing exclusion or admission state.
- **Session-local admission and pending-call census.** Atomic lifecycle state
  alone cannot prove a cleanup owner did not die just before another grant.
  The M6 composition session owner therefore retains at most one pending
  model record, never request data. The model edge owns private
  `InProcess.Admission`; the executor owns `Local.EphemeralAdmission`;
  composition's `SessionAdmission` implements both. A thin asynchronous
  request helper provides
  `request(module, opaque_handle, operation, native_deadline)` returning exact
  `{:ok, token}` or `{:error, :session_admission_closed}`. An exact monitored
  candidate DOWN during staging alone returns the correlated
  `{:error, :model_stage_cancelled}` to that live stage request after the
  owner clears the empty record. Each edge's private
  dispatch wrapper is request/4 (module, handle, operation, native deadline);
  the behaviour callback and composition implementation are request/3 (handle,
  operation, deadline). They dynamically invoke the supplied module's request/3,
  so neither implementation imports the other edge or composition. The handle
  carries exact session owner PID, private generation and shared two-slot cell.
  Token is exactly `{:session_grant, generation, operation_tag, requester_pid,
  operation_ref, expires_at_native}`; completion operations return the same
  correlated token for their fresh request, not an expired activation token or
  an unbounded term. This is two inward
  behaviours with one implementation and no new actor, shared imported edge
  behaviour, global scheduler or core change.
  Operations are `{:begin_model, callback_pid, call_ref}`,
  `{:stage_model, call_ref, candidate_pid, proof_ref, stop_ref,
  pre_activation_proof}`,
  `{:register_model, call_ref, cleanup_owner_pid, proof_ref}`,
  `{:record_model_resources, call_ref, cleanup_owner_pid, revision, entries}`,
  `{:tool_grant, executor_pid, instance_ref, dispatch_ref}`,
  `{:retire_model, call_ref, cleanup_owner_pid, proof_ref}` and
  `{:cancel_model, call_ref, pre_activation_proof}`.
  Every request carries requester PID, fresh message reference, native expiry
  and session generation; the owner monitors the exact requester. Replies echo
  the exact tuple and operation. Duplicate references are idempotent and never
  extend expiry; expired dequeue performs no transition. Tokens bind recorded
  PID/call or dispatch reference/generation/expiry and are one-use. Unknown,
  forged, stale, malformed and replayed tokens refuse.

  **Cleanup custody precedes the core registrar.** After reconciling the exact
  candidate/start return and normal proxy DOWN, callback allocates a fresh
  retirement `proof_ref`, distinct from every admission message reference,
  and sends stage_model. Its proof binds that exact returned candidate and
  proxy/PID/monitor/normal-DOWN pair; unknown starts cannot be staged as known.
  The session owner records these identities and stop_ref, installs the exact
  candidate monitor, and sends directly to that candidate
  `{:model_custody_prepare, start_ref, staging_ref, cleanup_deadline,
  cleanup_module, cleanup_handle}`. The callback supplies its already admitted
  private `LoopexComposition.SessionAdmission` module. The candidate binds that
  module with the route before acknowledging custody and uses only its
  `request/3` for cleanup-only cancellation or retirement after callback loss;
  the module is not an activation token and carries no request or credential.
  cleanup_handle is exactly
  `{:model_cleanup_custody, session_owner_pid, generation, call_ref,
  candidate_pid, proof_ref}`. start_ref is the constructor's private reference
  from the reconciled start proof, not newly asserted identity. Candidate
  requires it, its own PID, a live bounded control expiry and exact tuple shape;
  it binds that session route once and echoes staging_ref/generation/call/proof
  in its direct acknowledgement. This cleanup-only handle has no cell, request,
  token or work authority. Candidate records it and acknowledges directly to
  the session owner with the exact staging reference. Only that acknowledgement
  permits the owner's staging acknowledgement to callback. Both messages bind
  the exact sender/PID/generation/call/reference; a conflicting replay seals.
  Candidate monitors that session owner as well. Missing or late delivery never
  permits registrar entry. Lost callback acknowledgement cannot strand the
  candidate's retirement identity.

  Record phases are `:begun`, `:staging`, `:provisional`, `:managed`,
  `:active`, `:cancelling`, `:retiring`, `:retired_wait_down` and `:unproved`. Staging stores
  cleanup identity; provisional means candidate acknowledged it; managed means
  exact core return and live activation registration were validated; active
  means the first resource-recording request after the candidate accepted begin
  was acknowledged. The candidate owns its local begin transition; no unstated
  begin notification to the session owner is required. All progression is correlated to this single
  pending record. register_model changes provisional to managed, never creates
  custody or a record. Only managed/active records can acquire call resources.
  A known staging or provisional record can retire its empty census without
  register_model. Possession of the exact delivered cleanup handle suffices for
  cleanup-only retirement even if the direct custody acknowledgement was lost
  or expired. It does not promote staging to registrar permission. Accepting
  retirement suppresses every later staging/register acknowledgement and grant.
  Retirement/cancel accepts the cleanup-only handle; work operations require
  the full admission handle and live managed grant. No cleanup operation can
  return an activation token. Completion tokens remain correlated acknowledgements.
  Resource recording appends to the same pending record before each child
  receives authority to progress. Revisions start at 1 and increase by one;
  an identical revision/entry replay acknowledges without changing the record,
  while a conflicting replay seals the session. There are at most five process
  entries `{:process, role, pid}` for `:root`, `:anonymous_supervisor`,
  `:pool_supervisor`, `:http1_worker` and `:caller`, and two registry entries
  `{:registry, kind, pool_identity}` for `:worker` and `:supervisor`.
  `pool_identity` is the admitted credential-free `{scheme, host, port, tag}`;
  all entries bind the recorded call, generation and cleanup owner. PIDs and
  tags never change under a role. The owner installs exact process monitors
  before acknowledging; lost recording acknowledgement authorizes no progress.
  Partial-start obligations remain in this bounded census. Retirement uses the
  recorded retirement `proof_ref` and is accepted only after the recorded
  process monitors are DOWN and both recorded tagged registry lookups are empty.
  The retirement reference is an identity, not an expiring dispatch grant.
  Registry death cleanup is asynchronous. Both the cleanup owner and session
  owner poll their exact tagged lookups in sliced waits within the same
  1,000 ms cleanup-control bound; an initially nonempty lookup after process
  DOWN is not failure. Polling uses one correlated timer at intervals at most
  10 ms, capped by the same absolute bound; stale timer references are ignored.
  The owner retains a pending retirement in its ordinary responsive receive
  loop while those independently delivered DOWN messages are outstanding;
  it does not reject merely because they are queued or in flight. It processes
  the exact signals and empty lookups before acknowledging, within the earlier
  of 1,000 ms and that cleanup-control request's deadline. Expiry seals the
  affected session and withholds proof. Grants and retirement never block that
  loop or prevent stop handling.
  Retirement accepts the exact known staging, provisional or managed record and its reached
  census. It does not await a register_model request that may never have been
  sent, may have expired, or may have lost its acknowledgement. No cross-sender
  ordering is assumed. Unknown identity, conflicting census or missing reached
  resource proof withholds acknowledgement and seals only this session.
  No missing owner message or parent termination substitutes for those facts.
  A private test dispatcher can defer handling selected genuine monitor DOWN
  tuples while still handling retirement and stop, then release those tuples.
  The delayed-DOWN witness uses that seam, never fabricated successful signals.

  Before creating the provider proxy, callback asks begin_model with no
  request/options/credential; owner reserves its record, monitors callback and
  sets slot2=1. Candidate remains authority-free until managed core registration.
  Cleanup-only stage_model precedes registration_pending and core register/2.
  Actual provisional commitment transfers failure custody from callback to the
  candidate, even if its acknowledgement is lost. Callback DOWN thereafter
  disables activation and triggers cleanup; it is not evidence of unproved
  cleanup. After exact managed core return, preparation may supply the cell,
  retainer and one-use activation token. register_model's exact live
  acknowledgement is still required before call inputs, root, pool or caller
  grant. An expired or absent activation record leaves provisional retirement
  available; it cannot falsely seal a routine registered abort.

  During staging, candidate DOWN before any staging acknowledgement was issued
  to callback proves no registrar permission was released. With the reconciled
  start/proxy proof and exact candidate DOWN, owner can cancel that empty record;
  it sends the correlated clean-cancellation result, not a staging grant. A
  missing or expired result remains ambiguous and cannot itself seal a record
  that the owner may already have cleared. After provisional commitment,
  candidate must record retirement before exit on callback loss before
  registration_pending is acknowledged, including its original start-deadline expiry after
  custody delivery. After registration_pending, callback DOWN permanently
  disables begin and triggers immediate bounded empty-census retirement, but
  does not permit candidate exit. It retains the accepted retirement identity
  and waits for exact core stop, the empty-invocation settlement barrier below,
  or session-subtree teardown. A later core stop
  is acknowledged only after that recording, then candidate exits. If guard
  registration never committed, no core stop exists: the settlement barrier
  releases this already-retired inert candidate without stopping the session;
  subtree teardown remains the failure fallback. Genuine DOWN clears outstanding
  with any reason. Never wait for a nonexistent stop before recording retirement.
  Missing staged-candidate proof
  or candidate loss without recorded retirement keeps pending. Owner reconciles
  genuine reordered DOWN and matching retirement/cancellation for at most the
  existing 1,000 ms control bound before sealing3; grants stay withheld throughout.
  Callback DOWN with only a begun record reconciles any already-submitted
  staging/control message within the bounded cleanup-control wait before
  classifying missing proof; it never invents an absent child from parent DOWN.
  Unknown loss cannot clear slot2.
  Pre-registration cancel carries exact recorded
  proxy/candidate monitors and their DOWN results; a known-parent DOWN does not
  prove an undisclosed child absent, whose authority-free constructor still
  self-exits without begin.
  Its closed proof records call reference, exact proxy PID/monitor/normal DOWN,
  and either candidate PID/monitor/DOWN or :not_started paired with that proxy's
  authoritative exact returned start error. Missing result/candidate report is
  never :not_started. A no-proxy refusal cancels only its exact no-grant record;
  wrong-call, stale, mixed-proxy or unknown-start proof cannot clear pending.
  For an exact registrar return `:unmanaged` or
  `{:error, :provider_resource_refused}`, cancel_model first records that
  authoritative no-registration result and sets the provisional record to
  cancelling before callback may kill the known candidate. Owner then awaits
  its own exact candidate DOWN and records the empty-census cancellation before
  replying. This request stays pending in the responsive loop; callback uses
  an exact cancellation-prepared notification before kill, then waits for both
  real DOWN and final clean-cancel acknowledgement within the single control
  bound. Lost final acknowledgement grants no clean adapter result but cannot
  reinterpret an already-recorded cancellation as unexplained owner death.
  Candidate DOWN before a cancellation request is processed is reconciled as
  pending evidence, not immediately sealed, within that same bound; it still
  requires the exact no-registration result. Guard-unavailable, raised or
  malformed return proves no such result and never takes this clean lane.
  Candidate loss after staging acknowledgement but before registrar entry can
  cancel only with the live callback's exact
  `{:registrar_not_entered, stage_ref, candidate_pid, monitor_ref, down_reason}`
  proof, bound to the staged record and its actual DOWN. The callback checks
  candidate liveness before entering register/2. Once registrar entry began,
  this proof is unavailable; a dead candidate is not assumed unregistered.

  **Empty-invocation settlement barrier.** The sole pending model record binds
  to the owner's already-reserved prompt command identity and its eventual run
  identity from `user.message_appended`, not to the model request (which has no
  run identity). Store the reserved prompt id even when begin_model precedes its
  event, then freeze run_id on that exact event. answer/3 preserves the original
  prompt/run association rather than rebinding to its answer command. Session
  startup pins owner_epoch once by a public status operation through FacadeClient
  before returning the handle, never by a new read before each short-timeout ask.
  Ordinary succession invalidates the attachment and Ephemeral never reattaches.
  This is ordinary serialized facade work within the existing session-start and
  5,000 ms actor-operation bounds; no new actor, registrar introspection or kernel change is introduced.
  A cleanup-only release is eligible only after genuine callback DOWN,
  permanently disabled begin, accepted retirement of the exact empty pre-begin
  census, and no call input, pool, caller or resource grant ever issued.
  The owner follows the exact command/run's `run.finished`, then initiates a
  fresh `Loopex.session_status/2` round-trip through that same FacadeClient.
  Require status: :active, unchanged owner_epoch, event_sequence at least
  the terminal's sequence, and this run absent from active_run_id and
  pending_work_ids. Control resolves the route; the real coordinator answers
  the serialized call (`runtime.ex:610-614`, `control.ex:839-850`,
  `session_coordinator.ex:271-272,604-628`). Thus terminal delivery alone cannot
  release a candidate while the terminal-producing handler still performs
  provider cleanup. Result, worker-loss, deadline and cancellation handlers
  complete their provider-tree stop before this barrier can answer
  (`session_coordinator.ex:4000-4011,1199-1201,5859-5871,6046-6057`).
  These observations order invocation settlement; they prove no resource DOWN
  and never upgrade a conservative core outcome to success or not_dispatched.
  On that response the owner sends a fresh bounded cleanup-only
  `{:release_empty_invocation, generation, call_ref, candidate_pid, proof_ref,
  release_ref, deadline}` to the exact recorded candidate. It accepts only in
  its permanently inactive empty-retired state with matching identities; no
  activation token is returned. Candidate acknowledges that release and exits.
  An exact core stop winning first uses the existing stop protocol instead.
  The owner keeps the one record and slot2 until its real candidate DOWN,
  under the existing 1,000 ms cleanup-control bound, then clears both before
  returning the terminal observation or admitting the next ask. In this narrow
  state the owner retains a pending terminal; ask/answer waiters, background
  continuation and last_result use the same completion rule. last_result keeps
  its previous observation and another ask returns run_open until the barrier
  and DOWN complete. The original public wait deadline is never reset; expiry
  while reconciliation is pending returns the normal timeout projection and
  background continuation later publishes the terminal. Stop winning instead
  bypasses this continuing-session release: cancel an ungranted status operation
  or drain/reap an already-granted one within existing operation/cleanup bounds,
  then require recorded retirement and real candidate DOWN in subtree cleanup.
  It adds no 5,000 ms status wait to the stop contract. Attachment disconnection
  or coordinator succession takes existing whole-session cleanup; Ephemeral
  never reattaches to consume a successor terminal. Lost release
  acknowledgement does not invalidate an already-recorded empty retirement
  and genuine DOWN; a missing DOWN does. Wrong run/epoch, missing terminal,
  failed status or any reached resource forbids this lane. If the exact valid
  terminal is already retained but its continuing-session barrier fails, enter
  the existing stop path using that terminal for run-ending/effect proof, not
  a fabricated missing-ending snapshot. Proved cleanup returns that terminal
  to a still-waiting caller and marks the handle closed; unproved cleanup returns
  cleanup_unproved carrying that same terminal in ending. If the public wait
  already timed out, publish no second reply; use existing no-waiter cleanup/
  retained-root reporting. Other session-path failures retain their existing
  bare/no-ending algebra. No guessed stop timer, second retired
  record, background work grant or new durable fact is permitted.

  At core's resource-stop, cleanup owner first proves applicable processes/tags,
  sends retire_model with its exact private proof reference and waits for owner
  recording acknowledgement, then sends core stop acknowledgement and exits.
  Session owner clears record/slot2 only after exact cleanup-owner DOWN, with
  any exit reason, and recorded clean retirement. A core-enforced `:killed`
  after its acknowledged stop is not unproved (`session_coordinator.ex:4656-4677`).
  Staging/resource-recording/cancel/retirement remain admissible
  in lifecycle1/3 solely for cleanup; begin_model/tool_grant require lifecycle0
  with no conflicting record. Later grants query the owner, reconciling queued
  exact DOWNs first. Pending grants remain bounded state in the ordinary owner
  receive loop; no selective wait may block stop or clean-retirement handling.
  The requesting edge waits in sliced receives for at most 1,000 ms while the
  owner reconciles clean-retired owner DOWN rather than falsely failing or
  bypassing pending census while notification is unprocessed. Missing proof
  returns the private closed error; before managed lifetime registration the
  model maps by actual dispatch boundary, but after managed registration any
  activation/admission refusal exits with the fixed private
  `:provider_lifetime_registration_failed` reason and leaves settlement to
  core, never inventing a retryable adapter `not_dispatched` result. The
  executor returns fixed pre-effect admission failure, with no new public
  composition code. Existing serial core prevents concurrent model/tool
  dispatch within a session; separate sessions may overlap. Unproved cleanup
  sets lifecycle3 before result; it never returns to0. Only later proved
  session cleanup and removal may set2.
  Begin/register and every work-activation grant use the live model deadline;
  tool grants use the executor's effect deadline. Resource recording, retirement
  staging and clean cancellation use their cleanup-control deadline, never an expired
  model-call deadline. A returned child PID is recorded even if setup expired
  before its return; recording grants cleanup custody, not work. At core
  stop that is the supplied cooperative monotonic-millisecond deadline converted
  to native units; otherwise the private reap/control bound is 1,000 ms from
  request creation. Every wait still caps at 1,000 ms. Expired activation cannot
  grant work even when a cleanup-control request remains admissible.
  Once retired, queued register/begin/resource messages cannot recreate the
  record or reopen activation. Retain the last retired call identity until the
  next live begin; other old calls do not match the current record. begin rejects
  a dead requester, including a delayed request from the old callback. No
  unbounded completed-call history is retained.
- Ambient keys are allowed with every preset. The executor retains released
  child-environment behavior, including its existing LOOPEX_PROVIDER_API_KEY
  removal. M6 adds no per-provider scrub, presence probe or false promise that a
  trusted same-user tool cannot read a key. A host-authorized tool copy is
  ordinary tool content and may enter records, public events and model context;
  adapter credential-injection exclusions do not apply to that deliberate copy.

- **Private process-group proof.** No executor protocol member changes. Each
  ephemeral executor receives its exact session-owner PID, instance reference
  and lifecycle cell. It keeps at most one serially owned unproved group; only
  the existing process-table check (`executor.ex:6335-6377`) removes it.
  After run-ending wait, the bounded cleanup worker calls
  `drain_process_groups(executor_pid, instance_ref, owner_pid, nonce, deadline)`.
  The executor verifies the recorded owner/instance, closes dispatch, drains and
  checks its groups, then sends `{executor_pid, instance_ref, nonce, :groups_empty}`
  directly to the owner before returning `{:ok, nonce}` to the worker. The owner
  accepts only its previously generated nonce and exact live executor PID/instance.
  Success requires both that direct certificate and the worker's matching result
  plus normal DOWN. Neither worker testimony nor an ended executor fabricates
  proof. The owner retains the accepted certificate before runtime stop, so a
  subtree-only retry never calls the ended executor or repeats a proved drain.
  Refusal, malformed result, missed deadline, executor death, mismatched certificate
  or remaining group leaves `:process_groups` unproved and seals only the session.
  A tools-none executor also proves its group set empty while alive; startup
  without any executor is the sole vacuous case. Independent runtime/subtree stop
  may still run after an observed group failure. This is a private host-edge API.



- The ephemeral private subtree owns one `Loopex.Trace.Capability`, as the
  durable composition does through its credential plane. It starts before the
  runtime, supplies its handle to the model options, and is bound to the exact
  returned runtime before startup commits, so the caller can exclude itself
  from Loopex trace sessions (`trace.ex:56`).
- The in-process adapter owns exactly one credential-bearing adapter MFA:
  `{Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1}`. Its initial argument is the
  bounded credential-free call specification. After its start token and open session
  cell are verified, that function calls
  `Loopex.Trace.exclude_self(tracing_capability,
  functions: [{Loopex.LLM.ReqLLM.InProcess.Caller, :run, 1}])` and requires
  exact `:ok` before the hosted branch reads the environment. An unavailable
  or malformed exclusion result is fixed `not_dispatched`, reads no credential,
  accepts no connection and takes owned teardown. No other adapter function
  receives or returns the resolved bytes; dependency calls occur from the
  already-excluded process. Ollama uses the same exclusion path without ever
  reading a credential.
- Before sending a mapped result to the owner, the caller recursively checks
  binary map keys and values as well as every nested list/member in the mapped
  reply, including decoded tool arguments and assistant
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
  update the stale dependency-direction comment at
  `apps/loopex_llm_reqllm/mix.exs:54` in that implementation change: composition
  already depends on this adapter, and core still does not;
- the escript and every build that carries the adapter still carry ReqLLM,
  Req and Finch code. The adapter's `application/0` explicitly lists
  `extra_applications: [:crypto, :logger]` (`apps/loopex_llm_reqllm/mix.exs:36-39`).
  Both escripts reach that application through their existing dependency trees.
  Mix embeds Elixir applications such as Logger only when reached through the
  application tree, separately from dependency code (floor Mix
  `escript.build.ex:247-287`; current `:252-293`). The direct Logger entry
  prevents runtime-false ReqLLM from removing `logger.app` and Logger BEAMs.
  The companion and a host OTP release list all three as
  `:load`; the guarded step starts `:req_llm`, whose application dependencies
  then start Req and Finch. The developer guide states this and fixture releases
  assert that the modules and Logger application metadata are present while all
  three applications remain stopped until that step. Packaged CLI and companion
  witnesses actually perform guarded startup and the real companion bootstrap
  to `:ready`; module inventory alone cannot prove startup;
- the companion worker already starts ReqLLM explicitly after its own settings
  (`provider_worker.ex:43`, `:78-79`) and is unchanged;
- `ReqLLMStarter` serializes initialization in a responsive receive loop.
  Its fixed application child is `restart: :temporary`, `significant: false`;
  the `:one_for_one` parent uses `auto_shutdown: :never`. A service exit
  removes its child specification without automatic restart or restart-intensity
  accounting. A crash loop therefore cannot exhaust the parent and stop its
  owner-DynamicSupervisor sibling. A later creation recreates that exact child
  through the reused authority-free monitored bootstrap helper, using
  `Supervisor.start_child/2` with the fixed specification. Exact returned PID
  or `{:error, {:already_started, pid}}` is accepted only for that registered
  service; absent, malformed or stale returns fail boundedly. The single ReqLLM
  stage's absolute 5,000 ms bound covers recreation, helper termination and
  service admission, not a new full wait for each step. A late helper can only
  recreate infrastructure, never a session. Existing handle calls do not recreate
  it. OTP temporary-child behavior is pinned on both toolchains; a service
  restart here means on-demand recreation, not an automatic restart policy.
- The service spawns one **unlinked**, monitored validation worker with a fresh
  initialization reference. It starts inert, monitors its creating service and
  expires after 1,000 ms without its correlated validation begin. This worker
  receives no session, prompt, model, path, credential or effect authority.
  Validation alone can read application/configuration/provenance state but
  cannot change settings or start dependencies. Only matching omitted-versus-
  `:host_started` declaration cohorts join; other declarations remain bounded
  queued requests for fresh validation. Each requester carries its PID, fresh
  reference and the stage's absolute expiry and monitors the exact service.
  Expired dequeue starts nothing. Requester expiry, service loss, worker loss or
  missing/malformed result yields fixed `req_llm_start_failed`, with no automatic
  resubmission or another waiter's declaration. Waiter death never cancels an
  admitted application start. Worker loss fails its current cohort and releases
  it only after exact DOWN; a queued later cohort gets fresh validation.
- Already-running validation writes neither persistent key. The initializer key
  `{LoopexComposition.ReqLLMStarter, :initializer}` is absent or exactly
  `{:preparing, initializer_pid, initialization_ref}`, and is written only for
  an actual admitted start. Origin at
  `{LoopexComposition.ReqLLMStarter, :provenance}` is absent or
  `{:started, req_llm_supervisor_pid, initialization_ref}`;
  there is no `:starting` intent that can later masquerade as completion.
  A stopped-state validation that permits startup returns a correlated request
  for start authority. The service retains the initializer identity **before**
  its one-use start grant. Preparation never erases prior positive provenance.
  Before that grant, creator loss ends the harmless worker. After it, the
  unlinked worker survives service loss until the real controller operation
  ends; creator-DOWN is no longer a cancellation instruction.
- The admitted worker rechecks guards and current state, persistently writes
  `load_dotenv: false` before start, then calls
  `Application.ensure_all_started(:req_llm)`. The first admitted start
  deliberately overrides even a stopped host's `load_dotenv: true`; an already
  running application with that setting refuses rather than overwriting it.
  A stopped application with prior positive Loopex provenance also requires
  `load_dotenv: false`; if host code changed it to true, startup refuses.
  Only an exact `{:ok, applications}` containing `:req_llm` permits the worker
  itself to publish that PID-bound tuple before sending its result. It captures
  the registered `ReqLLM.Supervisor` PID (`application.ex:45-46`) and requires
  it live with dotenv still off. An empty started list,
  error, raise, exit, intent or DOWN alone never establishes origin. A declared
  host start does not write Loopex provenance. Both a matching result and normal
  worker DOWN are required for success; service waits remain responsive.
- Running reuse requires the currently registered ReqLLM.Supervisor to equal
  the exact live PID in that positive tuple, or a fresh explicit host declaration.
  Service monitors the recorded live incarnation, and each validation cohort
  rechecks the registered PID before success. Old positive provenance remains
  history for the stopped-instance restart rule, not authority over a new PID.
  A host stop/restart between creations therefore requires declaration unless
  a new admitted Loopex start publishes the new incarnation. Never promote a
  host restart merely from prior Loopex history. A host racing stop/restart
  between ensure_all_started return and PID capture can interfere with
  attribution; the trusted host owns that race, not an exclusion mechanism.
- A recreated service first monitors a retained initializer before admitting
  another operation. A live predecessor receives no second grant and is awaited
  through exact DOWN; the new service does not await a result sent to its dead
  predecessor. After DOWN it clears only that exact initializer identity, then
  validates actual state in a new read-only worker. A crash after controller
  submission but before positive provenance may leave ReqLLM running with no
  Loopex origin. That state requires explicit `:host_started` and current
  dotenv-off, not promotion of stale intent. The host can declare or correct the
  state without VM restart; automatic adoption is not promised. Stopped state
  can retry. Malformed host-tampered records refuse until host correction.
  Persistent-term writes occur only on actual start admission/completion/reap,
  not each already-running session creation. Their VM-wide update cost is not
  added to the ordinary session path.
- A stalled controller may leave initialization unavailable while each creation
  still returns at its bound. Temporary service loss or any startup error never
  deliberately tears down peer sessions. Shared dependency failures may affect
  actual consumers and are reported as infrastructure outages. Loopex never
  stops shared ReqLLM on requester loss, restores dotenv or changes llm_db or
  warn_unverified_models. Host declarations and configuration races are trusted
  host inputs. The complete public start-state table remains in ADR 0039.


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
holding only the tagged user-managed pool. For every provider the registered cleanup owner creates and monitors that caller.
It registers the lifecycle root and every pool child before work, and every start
and dispatch grant checks the same session-local lifecycle cell.

  In the callback process, `complete/3` first calls
  `ProviderLifetime.starter/0` (`provider_lifetime.ex:35-45`). Exact `:unmanaged`
  returns fixed `not_dispatched` without a proxy, child, credential read or pool. Only
  `{:managed, starter}` proceeds. Before proxy creation it obtains the session
  owner's exact begin_model token/pending-call record via its private admission
  port; a closed refusal has no proxy or credential read and maps not_dispatched. The callback retains a fresh one-use activation
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
  the exact private `stop_reference` that later core registration will use. Before
  that message it must complete cleanup-only stage_model as specified above:
  session census commitment, direct candidate custody acknowledgement, then
  exact staging acknowledgement to callback. The
  candidate validates and stores it before acknowledging. That acknowledgement
  cancels the short expiry but grants no request, credential, root, pool,
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

  After acknowledging `registration_pending`, callback `DOWN` before `begin`
  permanently disables activation but does not end the candidate. It remains
  inert and responsive to the exact stored core `stop_reference`, even if stop
  is not yet queued. Core kills the callback before sending resource stop
  (`session_coordinator.ex:4573-4576`, `:4627-4634`), so a zero-wait exit would
  falsely make registered cleanup unproved. With no admitted resources, the
  candidate uses its already-staged cleanup-only handle and proof_ref to retire
  the empty staging/provisional census on callback loss, regardless of whether a managed return,
  preparation, register_model request or begin ever arrived.
  It obtains the session owner's exact retirement acknowledgement for the empty
  census under a fresh bounded cleanup-control deadline. It stays alive with
  activation permanently disabled until exact core stop, the empty-invocation
  settlement barrier specified above, or subtree teardown.
  On exact core stop, accepted retirement is already recorded; otherwise it
  finishes recording under the supplied cooperative deadline before acknowledging
  core and exiting. The session owner requires the earlier known cleanup commitment,
  not a later activation registration; missing reached resource proof remains
  unproved. If guard registration did not commit, core may report its
  pre-registration model result with no registered provider-resource obligation
  before the authority-free candidate takes its
  first scheduled protocol step. That result proves no call input or
  provider-call authority was released, not candidate `DOWN`. The candidate
  selects no fixed `not_dispatched` result, and no registration fallback timer
  exists. Its exact terminal followed by the serialized status barrier releases
  the empty retired candidate and requires its actual DOWN before a next ask.
  Complete session-subtree proof is the fallback when that barrier is unavailable,
  not the normal prerequisite for another turn.
  The locked starter fixes candidate shutdown to `:brutal_kill`
  (`session_coordinator.ex:4126-4131`); the adapter cannot change that child spec.
  Ordinary resource stop uses cooperative teardown while the supervisor lives.
  Supervisor removal can kill the candidate without a handleable parent EXIT or
  an after clause. The inert candidate does not trap exits. After activation
  an observed actual parent EXIT initiates permanent teardown, but cannot replace
  exact child/census proof. Destruction without recorded proof remains unproved;
  it cannot reopen a retired record or fabricate a clean acknowledgement.
  At task entry it records the concrete Task.Supervisor parent from its
  inherited OTP ancestry and verifies the parent link before any input arrives.
  It distinguishes that exact parent's EXIT from its known caller's EXIT;
  arbitrary EXIT-shaped messages cannot select a process to kill.
  Caller creation is `:erlang.spawn_opt(caller_fun, [:link, :monitor])`, returning
  `{caller_pid, caller_monitor}` atomically, while this active
  owner traps exits and the caller never does. Immediately after spawn, the
  remaining owner loop runs inside a lexical try/after capturing that exact
  caller PID. The after clause always issues its kill, including unexpected
  normal return or catchable exit; normal completion/stop must already have
  awaited exact caller DOWN before releasing proof. Untrappable owner kill
  bypasses after but propagates the non-normal link exit to caller. Link signals
  and kill requests are not termination proof; the independent session census
  still requires exact caller DOWN. EXIT reasons are processed by shape only.

  Only exact `{:managed, retainer_pid, cleanup_grace_ms}` returned from
  `ProviderLifetime.register/2` permits cleanup-only `activation_prepare` with
  that tuple, one-use token, the already-staged retirement proof reference and session
  handle/cell. The returned cleanup_grace_ms must equal the session's fixed
  5,000 ms `Loopex.Executor.default_cleanup_grace_ms/0`; no public ephemeral
  option changes it. A privately injected shorter grace is not a clean-success
  promise: missed acknowledgement takes core's existing unproved path.
  The candidate validates and records them, monitors the retainer
  and acknowledges preparation while remaining inert. No request, root, pool,
  caller, credential or dispatch grant is supplied. The callback next sends
  register_model carrying that same proof reference and waits for the exact
  session-owner acknowledgement, changing provisional custody to managed
  activation under the live model deadline. An expired transition grants no
  work but leaves cleanup custody intact. Only then does it send distinct `begin`;
  only the first exact token receipt authorizes root, pool, caller,
  credential or dispatch work, and the owner acknowledges before accepting call
  inputs. Callback `DOWN` before `begin` follows the inert stop-wait rule above; after
  `begin`, the registered owner enters ordinary cleanup. A missing, late or
  malformed preparation or `begin` acknowledgement emits no adapter result and
  remains under that same core interruption and cleanup path.

  An exact returned start error plus normal proxy `DOWN` and no candidate report
  is clean `not_dispatched`. A missing, late, malformed or mismatching report,
  abnormal or missing proxy `DOWN`, or start expiry is unknown. The callback
  seals the session cell to 3 first, withholds activation, kills every known
  proxy or candidate and waits at most 1,000 ms for known `DOWN` values before
  returning fixed conservative `dispatched_or_unknown`. A killed proxy cannot retract a queued
  `Task.Supervisor.start_child/3` request. An undisclosed candidate that appears
  later sees dead proxy or callback, or the expired deadline, and exits without
  session authority or a model request. Callback `DOWN` while the proxy is blocked leaves
  only that request-free, self-fencing path; when next scheduled, the proxy's
  callback monitor makes it retire. Late messages are ignored. A returned
  `:unmanaged` or `{:error, :provider_resource_refused}` from `register/2` plus
  session-owner cancellation preparation, exact candidate `DOWN` and final
  cancel_model acknowledgement is clean
  `not_dispatched`; missing candidate `DOWN`
  first seals that session cell to 3.
  On `{:error, :provider_guard_unavailable}`, a registrar raise or malformed
  return, the callback kills and awaits the known candidate under the same
  1,000 ms proof and session-seal-on-missing-`DOWN` rule, then exits with fixed private
  reason `:provider_lifetime_registration_failed`. That exit remains outside the
  adapter's returned-error mapping; locked core catches and discards it as
  `{:error, :provider_call_failed}` (`session_coordinator.ex:4149-4152`), which
  keeps the conservative no-retry classification. Any fault after exact managed
  registration uses core's registered-resource stop, acknowledgement and `DOWN` proof and
  never substitutes fixed `not_dispatched` for unproved cleanup.

  After the start proof, the adapter monitors the candidate through registration
  and starts no pool, caller or credential read until the exact managed return
  arrives. Exact `:unmanaged`
  or `{:error, :provider_resource_refused}` first submits the exact
  no-registration result to cancel_model and obtains its correlated
  cancellation-prepared notification, then sends the candidate's
  untrappable `:kill` and awaits its exact monitor `DOWN` for at most 1,000 ms.
  No cleanup grace exists until registration succeeds, and the start-blocked
  candidate has only provisional cleanup custody, not a resource or session
  work grant, so this is a private reap bound
  rather than a cooperative cleanup deadline. Exact `DOWN` returns fixed
  `not_dispatched` only after the exact clean-cancel acknowledgement. If `DOWN`
  or that acknowledgement is absent, `complete/3` returns fixed conservative
  `dispatched_or_unknown`, logs only the PID/monitor shape, seals its session to 3
  and admits that the authority-free candidate may
  remain start-blocked until scheduled; no pool, caller, credential read or
  dispatch can occur from it. Guard-unavailable, raised or malformed registration uses
  the fixed private exit above, never a returned adapter `not_dispatched` value.
  If cancellation preparation/final acknowledgement is lost, callback still
  kills the known no-input candidate and awaits its real DOWN within the same
  absolute control bound. Missing final acknowledgement remains conservative;
  no second full wait or forgotten inert candidate is permitted.
After the direct HTTP/1 worker call returns, the one-shot adapter waits while
the owner has the lifecycle root stop its anonymous supervisor gracefully. That
is an early cleanup path, not the only one: once the lifecycle root exists,
every later pool-child failure or partial start, terminal reply, refusal, caller-spawn
failure or exit starts or joins the same idempotent teardown. The owner proves
the lifecycle root, anonymous supervisor, pool supervisor and exact recorded
worker `DOWN` and both tagged registry entries absent before releasing the
adapter or any pre-adapter result. On normal completion it then ends and awaits
the blocked caller before sending its mapped reply to the waiting `complete/3`
callback. The registered owner stays alive while that callback returns.
On the coordinator's subsequent provider-resource stop, it first obtains the exact
session owner's clean-retirement recording acknowledgement for its call/PID/proof
reference, then sends core's stop acknowledgement and exits; this
reply-before-stop order keeps the registered resource alive for core's exact
handshake.
On a stop or deadline it first makes any reply inadmissible, kills and awaits
the caller, then cooperatively tears down and proves the pool, obtains that same exact
session-local retirement-recording acknowledgement, and only then acknowledges
`{:loopex_provider_resource_stopped, stop, self()}`
(`session_coordinator.ex:4641`). It never kills the lifecycle root or pool
supervisor. A missing proof withholds the reply or acknowledgement, and the coordinator's existing
forced-stop and unproved-cleanup path applies (`:4646-4652`).

The caller performs HTTP/1 socket I/O, so killing it ends the only result path.
On normal completion Finch transfers the socket to the NimblePool process before
request/6 returns (finch/http1/pool.ex:314-328; nimble_pool.ex:445,462), so
owned pool teardown closes that returned connection. During a freshly checked-out
request, caller cancellation causes NimblePool to remove the resource and invoke
termination. Finch's cancel handler only updates bookkeeping and returns `:ok`
(`finch/http1/pool.ex:295-302`). NimblePool removes the original resource
(`nimble_pool.ex:785-794,916-917`); during fresh checkout it still holds
mint: nil (`finch/http1/pool.ex:182-185`), whose close is a no-op
(`finch/http1/conn.ex:242`). Caller death closes the checked-out socket;
a returned connection closes with pool teardown.
Neither handler return is itself
proof that transport or a TLS controller has already ended. Asynchronous check-in
and cancellation can race graceful root shutdown. Cleanup therefore does not claim that the checked-out socket or its OTP
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
(`store_conformance_helper.exs:75-196`) promoted to library code:
- linked with `start_link`;
- it keeps the wrapper's GenServer state shape, so the conformance helper's
  `store_snapshot` (`store_conformance_helper.exs:1625`) reads it unchanged;
- it keeps an optional `:fault_probe` option. The option is active only when
  supplied, and follows the same checkpoint protocol as
  `Loopex.Store.Local.start_link(path:, fault_probe:)` (`local.ex:183`,
  `:242-257`), so the fault-injected cases (`each_store_with_unknown`,
  `:1017-1030`) exercise the shipped module. The promoted module implements its
  own private library-side `checkpoint/3` using the existing Local transition
  validation and correlated `loopex_store_fault_point` / `loopex_store_fault_action`
  protocol (local.ex:274-305), with a 5,000 ms probe wait. It calls no test module,
  including LoopexStoreLocalTest.FaultProbe. Every Store-port GenServer.call uses
  the library's 30,000 ms timeout (local.ex:65,112-141), not the wrapper's implicit
  5,000 ms default. No composition passes a probe.

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

After pure/workspace/skill/provider checks and pre-start guards, creation ensures
`:loopex_composition` is started before ReqLLM initialization or owner activation.
The entrypoint uses one unlinked monitored bootstrap worker because
`Application.ensure_all_started/1` may block in the application controller.
The worker receives only its requester PID and reference, no model, credential,
workspace, root or session input. The requester records a 5,000 ms absolute
decision deadline and a further 1,000 ms reap deadline. The worker sends its
PID/reference/result/completion timestamp, then exits. Only a matching in-time
success plus exact normal DOWN permits continuation. At the decision deadline
one zero-wait receive admits an already queued in-time result; otherwise the
requester kills the worker and waits only to the reap deadline, then returns
`composition_application_start_failed`. Returned errors, malformed/late values,
abnormal exit or missing proof select the same fixed failure.
Requester death may leave this authority-free worker or an already queued OTP
start finishing shared initialization. Neither can create a root or session.
Later creation safely re-evaluates OTP's idempotent start. Concurrent bootstrap
workers serialize at OTP; no wrapper guard is needed for work with no session
authority. The composition application has a one-for-one supervisor whose
independent children are temporary ReqLLMStarter and the temporary-owner
DynamicSupervisor. The starter is not automatically restarted; later creations
recreate it under the bounded ReqLLM-stage protocol above. Its failures never
consume the parent's restart intensity.
It has no credential scheduling or persistent failure state. ReqLLM, Req and
Finch remain load-only so bootstrap cannot load dotenv.

`ask/3`, `answer/3`, `last_result/1`, `history/1` and `stop_session/1` consume an
existing opaque handle and never run this bootstrap. Their lifecycle check keeps
the precedence fixed above: application or owner loss makes the handle
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

**The ephemeral profile** starts in this fixed order:
1. Validate options and workspace/skills/provider; run pre-start guards and bounded
   composition bootstrap; join ReqLLMStarter with a 5,000 ms requester bound.
   After success verify the exact provider module, select its explicit or built-in
   base URL, normalize it and repeat host-global guards. There is no credential
   read, session owner or temporary root during these shared-infrastructure steps.
2. Activate one temporary session owner using the authority-free proxy protocol
   below. The owner records cleanup grace once from
   `Loopex.Executor.default_cleanup_grace_ms/0` (5,000 ms in locked core),
   creates its session-local cell and installs its creator monitor.
3. On the exact one-use begin token, the owner records one absolute 5,000 ms
   session-start deadline and starts a linked monitored SessionRoot actor.
   It reports ready and performs no path lookup, root mutation or dependency
   start until the owner's matching phase grant. The same cell is passed to
   model/executor private constructors; no public option supplies a different one.
   The caller's startup request reference is an OTP reply alias. On timeout it
   deactivates that alias, consumes a reply already queued before deactivation
   if present, and otherwise sends correlated cancellation. A late owner send
   to the inactive alias is dropped; cancellation also stops an already-ready
   session. Every unproved startup cleanup is logged independently of whether
   cancellation reached the owner before its abort deadline.
4. Under `candidate_prepare`, SessionRoot obtains System.tmp_dir! through a
   private zero-arity seam and 32 entropy bytes through a private one-arity seam.
   Production supplies only the actual functions. It proposes
   `loopex-` plus all 64 lowercase nonce hex bytes; complete path is UTF-8,
   no NUL, at most 65,536 bytes. Invalid tmp result/lookup maps to
   temporary_root_unusable; malformed entropy maps to temporary_root_creation_failed.
   It reports the candidate before the owner grants exclusive File.mkdir.
   Up to 16 eexist collisions take fresh entropy; other failure or exhausted
   collisions take temporary_root_creation_failed. A successful claim is chmod
   0700, lstat-verified ordinary directory owned by current OS user with exact
   permission bits and empty listing before any file or child starts.
   A lost candidate-prepare result gives no mutation authority: known actor is
   killed/reaped within startup deadline. Missing DOWN returns
   `cleanup_unproved` with `root: nil`, unknown ownership, only
   `session_subtree` pending and no ending; it grants no claim and names or
   deletes no path. An exact collision retires only that attempt's candidate.
   If a current candidate is known before its claim grant, an unproved subtree
   names that path, while proved subtree shutdown returns the bare startup
   failure without trying to remove it. A lost mkdir result names an
   ownership-unknown possible path, never deletes it and returns
   cleanup_unproved with root_removal pending
   after actor proof, or session_subtree while actor proof remains missing.
5. SessionRoot becomes the lifetime parent of a zero-restart-intensity private
   one-for-all supervisor. It reports its exact PID and waits for owner monitor
   acknowledgement before any child. It then starts memory store, workspace
   lease on cwd, executor, runtime trace capability, and RuntimeHolder/runtime
   in that order. Before each potentially blocking call it sends
   `{phase_ready, root_pid, ref, phase}`; only the recorded owner grant permits
   the phase. Every exact returned child/handle is registered and acknowledged
   before the next phase. Lost granted returns remain start_unknown: known
   parent DOWN cannot prove an unreported child absent.
6. Executor receives ledger root `<tmp>/receipts`, no artifact store, exact
   owner PID/fresh instance/cell and the private session admission handle. Tools none has both empty definitions and empty active ids; active
   presets use all definitions with the literal selected ids. Both hosted and
   Ollama models permit every preset. No environment presence preflight runs.
7. Trace capability starts before runtime. RuntimeHolder is itself registered
   start-blocked before a separate grant to
   `Loopex.Runtime.start_link/1`; it stays runtime's OTP parent, so no disposable
   starter becomes a surviving edge's parent. Runtime uses:
   - runtime_id `ephemeral-` plus first 32 lowercase SHA-256 hex bytes of the
     successful root nonce, 42 bytes total; entropy seam pins vectors;
   - memory store, executor, named policy and identity revision `"0.2.0"`;
   - in-process adapter model string plus private base_url, credential variable
     name or nil, trace handle and session cell, never a credential value;
   - requested bounds/sampling/context budget; runtime's unchanged token_budget
     default 1,000,000 when not explicitly supplied;
   - exact committed cleanup_grace_ms and normalized skill resource_manifest.
8. Owner grants trace bind under the same deadline, requiring exact
   `Loopex.Trace.Capability.bind(handle, runtime) == :ok`. Missing granted bind
   reply is start_unknown and seals the session; returned failure maps to
   trace_capability_bind_failed after proved rollback.
9. SessionRoot reports one prepared tuple and remains blocked until owner commit.
   Only then may the linked monitored FacadeClient create with surface embedded,
   exact command id create, attach at sequence zero, admit the manifest and
   activate every ordered selection. Empty manifest submits no resource command.
   Attachment initialization also reads public session status once, requiring
   exact {:ok, map} with status: :active, owner_epoch a non-negative integer,
   active_run_id: nil
   and pending_work_ids: [], and pins that epoch before any prompt or handle
   return. This shares the existing absolute session-start deadline, never adds
   a phase budget. Returned error, malformed/missing fields or loss takes fixed
   attach_failed with startup cause {:attach, :failed}, after ordinary rollback;
   unproved rollback overrides it with the existing cleanup_unproved shape.
   All steps must succeed before returning a handle or admitting any prompt.

Production hard-codes the model-port builder; tests inject only the scripted
unchanged model port via a private constructor, not API/configuration. Adapter
suites and the acceptance demo exercise the production builder.

**Owner activation.** The entrypoint alone retains a fresh begin token and starts
one unlinked monitored authority-free proxy with creator PID, reference,
absolute 1,000 ms start expiry and owner DynamicSupervisor PID. The proxy
monitors the creator, calls DynamicSupervisor.start_child only on its exact
initial grant, reports the exact return provisionally and awaits correlated
`finish`. The child closure captures
only creator/proxy PIDs, reference and expiry—no token, session options, model,
credential, workspace or root. A temporary child reports its PID directly,
monitors creator/proxy and remains blocked. Only matching candidate/proxy PID
reports let the entrypoint install the candidate monitor and send `finish`.
The proxy sends the candidate exact `proxy_retiring` before exiting normally.
Those matching reports plus exact normal proxy DOWN permit the entrypoint's activation
prepare/begin handshake. Until begin, proxy loss is accepted as authorized
retirement only after the exact retiring notice; otherwise the candidate exits
without work. The entrypoint installs its owner monitor before begin and grants
validated composition input only after matching activation acknowledgement.
A lost/malformed return, timeout, abnormal or missing proxy DOWN withholds begin,
kills known helper/candidate and awaits exact known monitors at most 1,000 ms,
then returns ephemeral_owner_start_failed with no root. A queued supervisor
start may later create an undisclosed child; it has no inputs or begin token and
exits on its first expired-deadline/dead-creator/dead-proxy step. This uncertainty
does not stop or disable a peer session. Only the admitted session owner may
create a root, and no entrypoint becomes a replacement cleanup owner.

**Startup rollback.** Every returned named phase failure carries its fixed
startup cause after proved cleanup: named composition child, session_create,
client_start, attach, resource_admission or skill_activation. Missing or
malformed granted dependency/bind return is start_unknown, seals cell 3 and
keeps the owned root with session_subtree unproved even if known parents later
go DOWN. It returns no handle and never upgrades unknown starts to proof from
parent DOWN. Before mkdir grant no root can exist. After a lost mkdir reply,
ownership stays unknown and the path is diagnostic, never deletion authority.
Owner death before begin leaves no root; afterward its SessionRoot monitor
prevents more grants and collapses that session subtree, but the entrypoint may
only return bare session_unavailable and cannot name an unreported root.

Rollback uses ordinary stop's single cleanup-grace-plus-5,000 ms deadline,
facade-client reap, serial phase workers, direct executor certificate,
recorded child/root DOWN and exact root-removal/absence proof. Only reached
failures appear in the ordered pending list. No run makes ending/effect phases
vacuous. If executor may have started, a certificate is required while it is
alive; unknown/unproved group or subtree retains the root. No phase retries
after uncertain dispatch of that phase, and no prompt/provider/tool can run
before startup commit. Shared applications, initialized dotenv setting and
ReqLLMStarter lie outside the private subtree. Their real outages are shared
infrastructure failures, never deliberate peer-session termination.

The private one-for-all supervisor has restart intensity zero and never
restarts a memory store, lease, executor, trace capability or runtime in place.
Its first unexpected child loss collapses the subtree and closes only that
owner's lifecycle. SessionRoot and RuntimeHolder remain lifetime parents;
FacadeClient remains the sole public attachment holder and reader.



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
released outer-list, error-shape and duplicate-key conventions. The four added
keys were ignored in `0.2`; M6 recognizes and validates them, so their invalid
values now refuse. `start/1` and `with_runtime/2` return
`{:error, :invalid_composition_options}` for a non-list. `start_edges/2`
returns `{:error, :invalid_composition_options, %{}}` for a non-list options
or lifecycle argument. Every `start_edges/2` failure is
`{:error, reason, partial_edges}`; validation failures have an empty map,
while an edge-start failure names the edges already started
(`edges.ex:79-91`). Within the documented `keyword()`
contract, other unknown keys remain ignored and a repeated key keeps its first
value through the existing `Keyword.get/3` and `Keyword.fetch/2` semantics.
M6 does not impose the ephemeral API's closed-list rules on these released
entrypoints. Existing recognized values keep their released validation. Each
added option has the closed value grammar below; an invalid first value returns
`{:error, {:invalid_composition_option, key}}` from `start/1` or
`with_runtime/2`, and `{:error, {:invalid_composition_option, key}, %{}}`
from `start_edges/2`, before an edge starts:

Validation order is fixed. After the outer list check, `start_edges/2` first
validates the lifecycle's `:interrupt` option, then requires the host-supplied
`:credential_plane` key (`edges.ex:81-82`, `:158-171`). Those two checks do not
run on the ordinary `start/1` and `with_runtime/2` paths. The shared released
validator then keeps its seven-stage precedence (`loopex_composition.ex:146-152`):
policy, required `:state_root`/`:workspace`/`:runtime_id`,
`:recover_stale_writer`, `:artifact_transfers`, `:provider_launch`, resource
manifest, then workspace manifest. Only after all seven released stages succeed
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
  A counter exactly at 256 directories, 4,096 entries or 1,048,576 path bytes
  passes that cap check, and the first candidate that would make it larger refuses
  before content from that candidate is retained. The same traversal admits
  exactly 64 regular files and 1,048,576 cumulative content bytes; the 65th file
  or first content byte beyond that ceiling refuses. Non-regular entries affect
  entry and path counts but not file or content counts. The first exceeded cap
  returns `:skill_manifest_invalid`. The same traversal
  counter transition is tested at each exact/max-plus-one boundary through a
  test-only wrapper that invokes the actual transition with seeded counters;
  production exports no wrapper and accepts no seeded-counter option. The
  4,096-entry and 1 MiB path-byte positive controls prove that counter check,
  not admission of an impossible whole pack under the tighter file and
  directory limits. End-to-end valid-pack fixtures satisfy every cap together.
  The retained pack validator
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
  failure retain startup cause `{:resource_admission, :failed}`; an activation step
  retains `{:skill_activation, :failed}`, and startup rollback destroys all
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
  needs its provider's own credential variable; every tool preset remains available. With
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
if an unmarked owner crash makes
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
profile, `{"proved": false, "root": "...", "root_ownership": "owned" | "unknown", "pending": [...]}`. Every emitted false-cleanup JSON object has a string root because the only `nil`-root case has no ending and emits no object. `root_ownership` is the exact projection of the public cleanup map and `unknown` never authorizes deletion. `pending` is a
non-empty array containing only `"run_ending"`, `"effect_cleanup"`,
`"process_groups"`, `"session_subtree"` or `"root_removal"`, in that order
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

**Interrupts.** After command admission and before ephemeral `start_session/1`,
the command calls the new internal
`Interrupt.install_ask(main_pid, ref)` and requires exact
`{:ok, signal_manager_pid}` for the exact `:erl_signal_server` manager on which
the `:gen_event` handler was installed. Installation has a private 1,000 ms
bound. That correlated mode uses the existing 10,000 ms backstop. Refusal,
malformed return, duplicate active-handler claim or manager loss before exact
success creates no session, emits fixed diagnostic
`interrupt_handler_unavailable`, and exits 1 with zero standard output. A
startup failure after installation finishes the exact handler before its
fixed or retained-root diagnostic is rendered. A signal handled during startup
is held by that handler; if startup returns a handle, the main process stops it
before starting any ask worker. A signal before a handle exists still has no
Loopex cleanup or result promise. After a handle returns, manager or handler
loss calls bounded `stop_session/1` and yields the fixed diagnostic or real
retained-root line with status 1 and zero standard output. The command's main
process owns the handle, monitors the returned signal-manager PID and then starts a monitored worker
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
kept-root failure. A bare-unavailable stop caused by an unmarked owner
failure cannot construct that object and emits no standard output. Text output emits no answer after an
interrupt; both modes name an unproved root on standard error and exit 130. A
later handled member of that set while the handler remains in `stopping(ref)`,
or expiry of the fixed 10,000 ms backstop, calls `System.halt(130)` and is the
named hard-kill case even if bounded stop or worker reap has not finished: no
output or root cleanup is then promised. Every orderly path,
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

When the selected public cleanup map leaves cleanup unproved, the one cleanup diagnostic is
instead exactly
`loopex: cleanup_unproved root=<root-json> ownership=<ownership> pending=<pending><LF>`.
`<ownership>` is literal `owned` or `unknown`; the latter is diagnostic and not
deletion authority. `<root-json>` is `JSON.encode!/1` of the validated root
string, including its quotation marks, or literal `null` only for the pre-claim
unproved subtree. It is at most `6 * 65_536 + 2` bytes. `<pending>` is the non-empty comma-joined
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
| 1 | Refusal before the run, a cleanup-only failure before prompt admission with no run observation, or a command/lifecycle failure outside the run-outcome algebra for which no public cleanup proof can be constructed; standard output is empty. Except for the named ordinary worker-reap hard halt, which terminates before rendering and promises no output, the fixed code or retained-root diagnostic above is written to standard error. The last case includes an unmarked owner crash, even if a run observation had already arrived |
| 2 | `failed` |
| 3 | `bound_reached` |
| 4 | `outcome_unknown` |
| 5 | `cancelled` |
| 6 | No terminal ending was observed after a prompt may have been admitted: the follow window expired, or the ephemeral attachment or command path became unavailable. The command stops the session in the ephemeral profile; for the durable profile it exits and leaves the durable state resumable, not a live in-process owner. `details.reason` distinguishes `timeout` from `session_unavailable`; text-mode standard error says which occurred, while `--output json` writes the `no_ending` object and follows the JSON-mode standard-error rule above |
| 130 | Interrupt after an ephemeral handle exists: the first signal takes the bounded stop route above; a second signal or backstop expiry is the hard-kill case. A signal before handle creation has no Loopex status contract. The separate launcher pre-child latch returns the reaped platform child status |

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
process. The private session admission check precedes this walker; no
environment-key presence check is performed.
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
| `scripts/stage-archive-manifest.sh SHA OUT` | M5 inline staging | OUT and exact sidecar OUT.source-identity must not exist, with existing directory parents. A fresh git archive extraction uses the guide's scoped subshell umask 022 under caller umask 0777. It executes the extracted manifest script against that tree and writes its exact emitted NUL-delimited output bytes, not script source, to OUT; the archive's exact SOURCE_IDENTITY bytes go to the sidecar. It prints CALLER_UMASK=0777 and EXTRACTION_UMASK=0022 on stderr, retained in the staging transcript separately from the manifest bytes. Exclusive temporary siblings and no-overwrite publication preserve targets; failure removes only newly created files and publishes neither final path |
| `mix loopex.closure.archive_compare TESTED_MANIFEST ADMIN_MANIFEST TESTED ADMIN` | the M5 `archive_compare.py` | Reads the required exact sidecars `TESTED_MANIFEST.source-identity` and `ADMIN_MANIFEST.source-identity`; a missing, non-ordinary or malformed sidecar refuses. It checks NUL framing, no duplicates and sorted records; each complete projection against its commit's independently enumerated Git archive members after `export-ignore` and `git ls-tree -r -t --full-tree` modes; each file digest and link target against that commit's Git blob; tested and administrative projections identical; tuples identical after removing the `docs` directory entry plus `docs/**`, `README.md` and `SOURCE_IDENTITY`; and each sidecar's `SOURCE_IDENTITY` names its own commit and committer date. It is read-only, prints one `PASS` or `FAIL` line per check, writes no file and exits zero only when every check passes |
| `scripts/floor-lane.sh SHA --output-dir DIR [--long-bound]` | M5 closure-lane.sh | Complete argument/SHA/floor-toolchain/open-file/signal preflight precedes creation of new mode-0700 DIR; parent must exist. A fresh clone at SHA and absolute pair-specific build root lie outside DIR. The retained fast command is `env -u MIX_BUILD_PATH MIX_BUILD_ROOT=/absolute/retained-work/M6-otp27-build LOOPEX_CHECK_ALONE=loopex_llm_reqllm mise exec erlang@27.3.4 elixir@1.18.5-otp-27 -- bash scripts/check.sh`; the build root is an absolute sibling of DIR for that run. Raise soft nofile to 65,536 or hard limit and refuse below 4,096; a disposable child tests whether SIGHUP is ignored without signaling the invoking shell. Retain complete stream, EXIT and DURATION_S in DIR/check.log. --long-bound runs the same toolchain/build environment with `mix test --only long_bound` from each of apps/loopex, apps/loopex_executor_local and apps/loopex_daemon in turn and retains DIR/long-bound.log. It also runs the one reqllm transport-drain case from apps/loopex_llm_reqllm with `mix test test/in_process_transport_drain_test.exs --only long_bound`, retaining DIR/long-bound-loopex_llm_reqllm.log and requiring exactly one executed case. Preflight creates nothing; executed failures retain complete outputs and exit nonzero |
| `scripts/attended-release.sh --output LOG [--answer-attended --disposition ANCHOR --milestone NAME --authority-sha AUTH_SHA]` | M5 attended terminal driver | New LOG with existing parent; after preflight create exclusively and run check-release.sh under BSD or util-linux script(1) for a human-attended run, preserving platform exit behavior. A person answers by default. Automatic mode requires all three authorization arguments: AUTH_SHA must be a strict descendant of clean tested HEAD; read the exact context-map entry with git show AUTH_SHA:docs/developer/agent-context-map.md, require ANCHOR, exact NAME, full tested HEAD SHA and explicit automatic-answer authorization. Before execution retain complete extracted disposition bytes in the new exclusive LOG.authority sidecar, and print tested SHA, authorization SHA, ancestry result, sidecar reference and SHA-256 in the transcript. Require LOG and LOG.authority both absent at preflight; later branch deletion cannot erase the retained authorization. The runner checks scope/bytes/ancestry, not authorship: explicit maintainer authorization is a governance precondition and Git author strings do not authenticate it. Authority lives in that separately referenced descendant, which is not inserted into the tested-candidate/direct-child administrative closure chain, never the candidate's own hash. Wrong anchor/milestone/SHA/ancestry/authorization refuses before LOG creation. Automatic mode uses a Python 3 standard-library PTY controller where BSD script(1) refuses FIFO input. It feeds yes only after each exact attended notice, ignoring CR and its own echo; automatic answers remain required in M6. Retain complete transcript with all supported credential values redacted before publication, RELEASE_EXIT and ATTENDED_ANSWERS; executed failure retains evidence and exits nonzero |

Each command has tests against a fixture repository:
- `apps/loopex/test/closure_confine_test.exs` and
  `apps/loopex/test/closure_archive_compare_test.exs` for the two Mix tasks;
- `scripts/test/stage-archive-manifest-test.sh`,
  `scripts/test/floor-lane-test.sh` and `scripts/test/attended-release-test.sh`
  for the three closure commands;
- `scripts/test/source-archive-check-test.sh`,
  `scripts/test/rollback-archive-test.sh` and
  `scripts/test/escript-inventory-test.sh` for the fresh-source and packaging
  guards. All six fixtures run under `scripts/check.sh`.
The fixtures cover every mandatory argument, an existing output target, missing
parent, partial-write cleanup, exact sidecar and log names, missing and malformed
compare sidecars, preflight no-create, failing-run retention and successful no-
overwrite output in addition to each semantic failure above.
The fresh-source release runner retains its pre-build manifest producer outside
the extraction and runs those same bytes after the build, so a build cannot
change both source and the witness program. Before acquisition, it refuses any
top-level `deps` or `_build` path and independently inventories every extracted
path, including empty directories. Its judge binds each ordinary file digest and
symlink target to both the extracted tree and the named commit's Git blob,
except the export-substituted `SOURCE_IDENTITY`, which is bound to that commit's
identity text. Only a regular executable CLI escript is a declared build output.
Attendance fixtures also refuse an existing authority sidecar, retain an
executed sidecar-publication failure without starting the release check, and
verify its reference and digest after deleting the authorization branch.

The fixture reproduces a passing and a failing case for every check. The fast
check runs on both platforms at closure (hosted CI on Linux, and the Darwin floor
run), so the macOS and Linux human `script(1)`, automatic PTY and
disposable-child SIGHUP paths are exercised. Python 3 is required only for
automatic attended answers; it is not a runtime or source-build dependency.


**Inspectable credential witness.** Adapter-injection tests run with non-echoing
scripted tools (or tools none). A private constructor-only test seam scans the
cleanup owner's actual retained state within that owner's code before activation,
after mapped reply receipt and at cleanup. It returns only a Boolean canary-match
result; production installs no observer. The witness checks that result, never
process_info messages/dictionary or tracing of a sensitive process, which OTP
redacts. A deliberately injected bad owner-state field containing the canary must
make the witness fail as a positive control. No mailbox-inspection claim is made.
Exact-value echo fixtures include a literal binary map key and a decoded tool
argument's nested map key, as well as values and nested lists; the recursive
caller-side scan must reject every such provider-originated echo.
Provider configuration and automatic model-adapter injection must keep the
credential out of Loopex planes; a separate explicitly authorized tool-copy
fixture intentionally proves the same bytes may appear as ordinary tool content.
This distinction covers state, journal/public/context/trace assertions and the
security review. Isolated TLS fixtures install their test CA with
`:public_key.cacerts_load(path)`, which Mint reads through
`:public_key.cacerts_get()` (`deps/mint/lib/mint/core/transport/ssl.ex:589-601`).
The certificates include the fixture endpoint's SAN; verification remains on,
with no extra production connection option or global Req default.
The TLS resumption witness separately proves TLS 1.2 resumption
with Mint's defaults and TLS 1.3 resumption with an explicit ticket-enabled
control against the same respective servers. The TLS 1.3 fixture server enables
`session_tickets: :stateful` for both that control and production-client
comparison. Server defaults are also disabled, floor `ssl.erl:4277-4309`, current
`ssl_config.erl:991-1025`. The first TLS 1.3 control uses
`session_tickets: :manual`. Its socket-owning process must receive
`{:ssl, :session_ticket, ticket}` with a map ticket within the fixture deadline.
It uses that exact ticket in exactly one second connection with
`session_tickets: :manual, use_ticket: [ticket]`. Both connections use the same
literal fixture hostname, port and explicit server_name_indication matching the
certificate SAN, not an IP reconnect; OTP 29 checks ticket SNI
(`ssl_config.erl:971-973,1027-1032`). Client or relayed accepted-server
`:ssl.connection_information(socket, [:session_resumption])` must report
`session_resumption: true`. Missing/malformed ticket, timeout or non-resumption
fails or is unavailable evidence; no reconnect retry manufactures a pass.
The fixture never logs the ticket. This pins the actual OTP implementation,
not the stale nested-ticket example in floor ssl.erl documentation:
floor `tls_gen_connection_1_3.erl:361-400`, current `:371-410`; resumption
information floor `ssl_gen_statem.erl:1971-1977`, current `:1934-1940`.
It keeps production client versions unchanged and restricts only each server's
protocol. TLS 1.3 relies on explicitly disabled client tickets. The TLS 1.2
positive control waits for matching asynchronous client and server session-cache
installation through the ADR's isolated test-only delegating callback, then
performs exactly one second handshake; missing readiness or non-resumption
fails or is unavailable evidence, never a retry-to-pass loop. Production's
disabled retention must prevent reuse.

The TLS 1.2 probe is test-only `LoopexLLMReqLLMTest.TLSSessionCacheProbe`,
implementing `:ssl_session_cache_api`: `init/1`, `terminate/1`, `lookup/2`,
`update/3`, `delete/2`, `size/1`, `foldl/3` and `select_session/2`. Configure
it before SSL starts in the isolated control VM, using OTP 27's `:session_cb`
or OTP 29's separate `:client_session_cb`/`:server_session_cb` and both role
init-arg settings. It delegates to the role-specific default cache, preserving
client ETS semantics. For the server, OTP discards custom-module update/delete
return values (floor `ssl_server_session_cache.erl:235-245`, current `:236-246`),
so merely returning a replacement default gb_tree cannot store the session.
Server init creates an unnamed protected ETS table owned by the real server
cache process, stores {:cache, default_initial_tree}, and returns {:server, table}.
Server lookup/size read the current tree and delegate to ssl_server_session_cache_db;
update/delete delegate, replace {:cache, new_tree} in that table and return :ok.
OTP never invokes server terminate/1 (floor `ssl_server_session_cache.erl:202-203`,
current `:203-204`); the holder has no heir and disappears with its real owning
cache process. Client terminate/1 delegates to the client default.
Default immutable operations are
floor `ssl_server_session_cache_db.erl:45-46,52-58,64-72,77-81`, current
`:47-48,54-60,66-74,79-82`. Readiness follows successful replacement and an
internal lookup proving the just-updated entry is present. After the matching
update it emits only `{:tls_cache_saved, nonce, role}`: no session id,
cache key, session record or ticket leaves the callback. Client matching uses
the fixture host/port internally; the server has only that isolated listener.
Wait for both exact readiness messages within the fixture deadline before one
reconnect. Floor SSL `ssl_config.erl:424-437`, `ssl_manager.erl:190-194,509-526`
and current `ssl_config.erl:2099-2112` pin the version-specific seam.
On explicit-role init the wrapper binds that role in the cache-manager process.
OTP can later re-init in that same process with raw roleless args (floor
`ssl_manager.erl:531-533`, current `:543-545`); normalize using the bound role
and delegate to the same default. A roleless init with no established role
refuses, never guesses client. Client update/delete preserve ETS mutation;
server operations persist the replacement immutable tree in their probe-owned
mutable holder because OTP ignores the custom callback's returned tree. foldl/select_session
are client-only optional callbacks (floor `ssl_session_cache_api.erl:120-158`),
not calls to nonexistent server functions. The fixture explicitly exercises
initial role binding and this actual roleless re-initialization in a separate
fresh VM. Arm a one-shot client-only size/1 exception on genuine handshake-triggered
cache registration; clear its fault marker before raising so recovery cannot
rearm it. Keep the bound role plus a credential-free observer/nonce in that
same real manager's process dictionary. OTP catches the exception, terminates
the old cache, invokes roleless init/1 and resets its order (floor
`ssl_manager.erl:510-533`, current `:514-545`). Require that real recovery and
successful delegation to the fresh client cache. The positive-resumption
control VM never arms this fault: a recovery resets the cache and cannot stand
in for resumption readiness.

**Packaged startup and catalog witness.**
`apps/loopex_llm_reqllm/test/in_process_packaging_test.exs` inspects both actual
escripts for `logger.app` and Logger BEAMs. Separately it extracts the CLI
archive's exact `.app`/`.beam` entries into fresh application ebin directories,
supporting both Mix layouts and omitting every priv payload. A plain OTP VM
uses only those extracted Elixir/dependency paths plus OTP's standard apps;
no checkout, `_build`, installed Elixir or host dependency path is available.
It starts the extracted `:elixir` base before the compiled driver and asserts
every `:code.get_path/0` entry lies under the extracted or OTP roots.
A compiled test driver calls the public `Ephemeral.run/2` with fixture origins:
HTTP for Ollama, HTTPS for each hosted provider, synthetic selected keys and
the fixture CA. It replaces no runtime startup, adapter or mapper. Every full
synchronous response and cleanup must succeed. Use a fresh VM for each
catalog-state expectation, with the default compiled source and no host overlays.
Require `:persistent_term.get(:llm_db_store, nil)` absent before guarded startup.
Ollama, both OpenAI routes and OpenRouter must leave it absent through the reply.
Anthropic must leave a nonempty embedded snapshot after the full run and
retain its identical content/epoch through a subsequent call and cleanup.
The focused private-constructor adapter test, not a new public run option,
checks before-plan/after-plan/after-generation state inside the actual caller
and reports only fixed Boolean assertions. Its test-only observer is wired
through the private constructor; it does not replace ReqLLM or use external
tracing of the sensitive process. Packaged public run needs no observer.

Pin fixture models `ollama:loopex-fixture:latest`, `openai:gpt-3.5-turbo`
for Chat, `openai:gpt-4o-mini` for Responses,
`openrouter:anthropic/claude-haiku-4-5`, `anthropic:claude-haiku-4-5` and
`anthropic:loopex-catalog-miss`, with routes from the table above. Every fixture
asserts the complete normalized request body, including absent thinking and
reasoning members, stream:false, omitted empty tools and the token-limit field
under the exact M6 option list. Responses uses max_output_tokens; the other
routes use max_tokens. Anthropic known-model and
catalog-miss vectors both succeed; no unknown-model reconstruction is needed.

The project uses `compile_embed: true` (`config/config.exs:23`), so absent priv
alone is not proof. After each non-Anthropic absent-state case, a positive
`LLMDB.load/0` control must populate that same key with nonempty embedded data
containing a known model. For every default-source load, compare snapshot
identity/content to the exact catalog embedded in the build input, not a
hardcoded future catalog version. An empty fallback does not pass
(`llm_db.ex:157-180`). Negative controls with `:skip_packaged_load` and an
explicit empty catalog show that successful fixture replies alone cannot prove
packaged metadata. A separate preloaded-host snapshot case remains byte-for-byte
unchanged through the call; production never clears or replaces it.
Inline model enrichment
is local (`req_llm.ex:313-329`, `llm_db/engine/enrich.ex:73-77`), explicit address
skips the lazy catalog base-URL default (`provider/options.ex:1147-1153`) and synchronous
generation retains that model (`generation.ex:109-133,464-470`). This witness
proves packaged code, not an unstated CLI base-URL flag. Actual CLI local ask
and the actual companion bootstrap through ready are separate entrypoint
witnesses in the existing real-provider release lanes.

Finch itself has no application callback (`deps/finch/mix.exs:28-31`). Its
named shared infrastructure belongs to Req's callback
(`deps/req/lib/req/application.ex:7-14`) and ReqLLM's callback; packaging does
not depend on a nonexistent `Finch.Application` module.

**Exact registration-race harness.**
The real-core case lives in
`apps/loopex_composition/test/session_containment_test.exs`, which depends inward
on the model edge and can call public Ephemeral.ask/3. The adapter suite owns
isolated protocol tests, not a reverse test dependency on composition.
The composition case parks callback just before register/2 after
registration_pending acknowledgement through an edge-owned test-only hook.
Compile this private hook only under MIX_ENV=test; production compiles that
site to :ok without a lookup or observer. The composition test explicitly
requires the model edge's test/support rendezvous helper, which arms an entry
in a fixture-owned named public ETS table with no heir, keyed by the exact
session atomics-cell reference
already available through the private constructor. The composition fixture
obtains that same cell from its real private handle in test-only code, not a
new public handle or admission-token representation. This named rendezvous exists
only in the test VM; it is not application/runtime truth or public configuration.
The fixture runs async: false and owns/deletes the table; entries bind exact
cells so no other session can consume the arm. The entry carries only the
fixture PID and a fresh nonce. With no table or matching entry the hook is a
no-op. The test-only public access permits the callback to atomically take
only its exact cell entry with :ets.take/2. On a match it consumes the arm,
monitors that fixture PID and reports
{:before_provider_register, nonce, callback_pid, call_ref, candidate_pid} to
that fixture. It waits for the exact {:continue_provider_register, nonce},
matching fixture DOWN or a fixed fixture deadline, then demonitor/flushes.
Only the matching continue releases the park; fixture loss or expiry fails the
test invocation rather than silently proceeding into register/2. The rendezvous entry and handshake
carry no call input or credential. It arms only this invocation; the second
ask is unhooked. The hook adds no model option: its fixture PID, nonce and
handshake messages never enter model options, a staged request, journal or
public result. The existing session cell remains a transient private model
option, not a new test-hook option. The test/support helper is not packaged;
add its exact .exs path to the edge's test_ignore_filters list
(`apps/loopex_llm_reqllm/mix.exs:18-22`) and explicitly require it in its consumer,
without ignoring any *_test.exs selector. No production dependency points from
the adapter back to composition.
Test-only inspection of the real coordinator's in_flight entry obtains exact worker/guard
PIDs from the actual in_flight value
`%{task_ref => {:model, run_id, worker_pid, %{guard: guard_pid,
reference: provider_reference, cleanup_grace_ms: grace}}}`
(`session_coordinator.ex:3777-3787`). This deliberately couples a private test
to the locked kernel's in_flight shape; a kernel refactor must update and
re-prove the harness, never silently skip the race or expose a new public API.
Model options as a container are not journaled: core passes them to complete/3
(`session_coordinator.ex:3713,4150`), while request staging extracts only the
existing semantic max_tokens projection (`:3523-3531,3083-3087`). No test-hook
value is placed in either path. Suspend that worker, release the callback
seam, and observe its exact queued offer
`{:loopex_provider_resource_offered, provider_reference, callback_pid,
candidate_pid, stop_ref, offer_ref}`. Suspend callback before resuming
worker; with worker suspended it cannot yet have acknowledged retention. Resume
worker, observe its real acknowledgement
`{:loopex_provider_resource_retained_by_worker, provider_reference, offer_ref,
worker_pid}` queued to the still-suspended callback. Require the worker's actual
Process.info(worker_pid, :monitors) includes {:process, candidate_pid}; the
callback's earlier monitor is not worker-retention evidence. Require successful
live-process messages/dictionary snapshots, not nil treated as absence. The
callback mailbox must contain that exact worker retention ACK; the guard
mailbox must contain no matching
{:loopex_provider_resource_register, provider_reference, callback_pid,
candidate_pid, stop_ref, _}, and its dictionary must lack
{{Loopex.Runtime.SessionCoordinator, :provider_resource}, provider_reference}
(`session_coordinator.ex:4175-4187,4250-4259`). These assertions pin the actual
worker-retained/guard-unregistered window rather than assuming it. Trigger a real public abort through a fixture-owned command
attachment, or let the committed deadline expire. Follow actual callback DOWN,
empty retirement, terminal, status and release/DOWN, then run the second public
ask in that same session. While the correlated release is withheld in the
existing release-fault variant, require a second public ask to return
{:error, :run_open}, the one record and slot2 still held, and no second model
invocation or work grant; only actual candidate DOWN permits the next
successful ask. A test-only cell-keyed release dispatcher atomically consumes
one fixture-owned ETS arm and hands only that exact release tuple to the
fixture, without blocking the session owner's receive loop or the sole facade
reader. With no matching arm, production and test calls send directly. Deliver
the original release within its unchanged 1,000 ms
bound, then require genuine DOWN, cleared slot2 and the successful later ask.
If withholding exhausts the bound, require conservative session cleanup,
never successful reuse or a deadline extension. No fake registrar, fabricated signal
or production introspection is used. try/after deletes any remaining rendezvous
arm, releases only the exact hook nonce and resumes only fixture processes it
suspended. Catch only the expected badarg from resume_process for an already
dead or no-longer-suspended PID; an alive? check cannot close that race, and
other failures remain test failures. Abort can race the guard's worker-DOWN
handler against coordinator stop: assert the public cancelled or deadline
bound_reached outcome and conservative dispatched_or_unknown settlement,
not which guard branch or exit reason won (`session_coordinator.ex:5859-5871`).
The ordinary FacadeClient remains the sole event reader; the test
command attachment only submits abort. A blocked-status variant proves terminal
alone cannot release. Lost release acknowledgement with genuine DOWN remains
proved; missing DOWN does not. Registered stop winning first uses its exact ACK.

**Host-selected catalog witnesses.**
`apps/loopex_llm_reqllm/test/in_process_catalog_test.exs` runs isolated fresh
VMs with no preloaded catalog. One case sets `:llm_db :snapshot_source` to
`{:file, fixture_path}` containing a schema-valid snapshot with a unique
identity, plus a schema-valid `:custom` overlay with a uniquely named
non-selected model. The actual Anthropic call must load that snapshot and
overlay. Compare the configured source/custom/filter/preference settings
before and after the call, and retain the exact loaded metadata/epoch through
call cleanup and a subsequent call. Forcing packaged metadata, skipping the
overlay or clearing the catalog must fail these assertions.

The cold remote case sets `snapshot_source` to
`{:github_releases, %{ref: :latest, repo: "loopex-fixture/catalog",
cache_dir: fixture_cache, req_opts: [adapter: FixtureCatalogAdapter]}}`, with an
empty temporary cache and no snapshot-index override. The fixture adapter is a test-only module FixtureCatalogAdapter implementing
run/1 and returning the actual Req request/response pair, not a function-valued
option (deprecated with IO.warn in `req/request.ex:1068-1070`), new dependency
or global `:req :default_options`. It services the actual ReleaseStore release-list,
index and snapshot-download steps: one non-draft `catalog-index-fixture`
release with matching `snapshot-index-fixture.json` and `latest-fixture.json`
asset names, an index containing the fixture snapshot id and download URL,
then the canonical snapshot document with that same id. It refuses every
unexpected route. Loader forwards the overrides (`loader.ex:608-628`);
ReleaseStore retains req_opts (`release_store.ex:931-938`) and resolves those
steps (`:128-148,174-202,262-305,850-860`). No external request is made.

Use a synthetic GitHub token distinct from the synthetic provider key. Run
both `GH_TOKEN` and fallback `GITHUB_TOKEN` cases, clearing both inherited
variables before setting only the selected synthetic one. The fixture checks the API
Bearer header internally and reports only a fixed Boolean, never a request
or token. Begin with the selected provider variable absent; block the first
catalog request, then let the fixture parent set that provider variable and
release the catalog response. The real model path must use the newly supplied
key and complete, pinning catalog-before-key-resolution ordering without a
new public observer option. No catalog fixture option enters the owned model
request. Assert the source options stay unchanged, the catalog and cache
survive call cleanup, and the next call does not fetch again. Those host-owned
effects are not per-session files or owned-pool obligations. Additional cold
cases use an invalid file and a failing actual ReleaseStore fixture with a
private sentinel in its loader reason. Selected-provider-key-free planning must return
fixed not_dispatched/model_call_failed after teardown, with no model connection,
selected-provider-key read or sentinel in Loopex results, progress, trace or retained owner/runtime
state. A blocked remote load with a second cold caller pins shared-lock waiting
against their existing deadlines; deadline expiry kills owned callers, invents
no retry, and does not claim cancellation of host-owned cache effects. A failed
cold load installs no catalog snapshot, so a later independent or waiting call can
load again (`llm_db/catalog.ex:107-122`, `llm_db.ex:152-162,540-549`). This is
ordinary dependency loading, not a retry of the failed Loopex model call. In a
separate fail-then-success remote fixture case, drive two direct edge
complete/3 invocations through the existing managed ProviderLifetime fixture
pattern (`apps/loopex_llm_reqllm/test/provider_bridge_test.exs:167-215`), with the required session-local
admission fixture and real teardown, not composition or public ask. Count
loader requests with no snapshot/cache hit, fail the first invocation's load
and supply a valid fixture for the second invocation after proved cleanup.
Require the first invocation to return its fixed failure once, the second to
perform its own load and succeed, and no extra load or model dispatch within
the failed invocation. Real core may separately retry a proved not_dispatched
attempt within its unchanged two-attempt limit
(`session_coordinator.ex:7052-7054`, `session_state.ex:1332-1333`,
`provider_attempt.ex:105,120-121`); this edge-level witness does not falsely
claim the first public ask must fail or that its whole run has only one load.
Do not infer a loader count from
successful-cache reuse or count ordinary catalog traffic as model dispatch. All paths and
values are isolated fixtures; the model transport and release provider lanes
remain unchanged. Mutants forcing :packaged or deleting host metadata/cache
must fail. These cases run in the fast adapter lane, separately from the
no-priv packaging witness.

<a id="technical-plan-evidence"></a>
### Evidence Obligations and Mapping

Concept: [Outcomes](M6.md#concept-plan-outcomes).

Concept: [How each outcome is verified](M6.md#concept-plan-verification).

| # | Witness files | What they prove | Lane |
| --- | --- | --- | --- |
| 1 | `apps/loopex_composition/test/ephemeral_lifecycle_test.exs` | A live but suspended owner cannot hold a public stop caller indefinitely: the disposable requester returns bare `session_unavailable` within the 12,000 ms outer bound, a resumed owner can still finish the queued stop, and no late owner reply enters the host caller's mailbox. Borrower death retires its waiting requester without cancelling the owner's already-submitted stop | fast |
| 1 | `apps/loopex_composition/test/ephemeral_api_test.exs` and `ephemeral_api_fault_test.exs`, with a scripted model adapter behind the unchanged port | The closed API grammar and error algebra: every option default, mapping, precedence and malformed form; policy-module identity at 1, 256 and 257 bytes; positive-uint64 minima, maxima and max-plus-one refusals; the saturated timeout default; 32,768/32,769-byte prompts; and complete-path admission at 65,536/65,537 bytes before creation. Multi-turn, every terminal outcome, a failed tool result, an unresolved tool with nullable definition id, `interaction_pending`, every permitted answer-then-defer transition, `interaction_requires_session`, command-to-run joining, timeout continuation, post-admission session loss and every pre-admission lifecycle branch take their fixed forms. Fixed startup ids and injected nonce/counter/type vectors pin prompt, answer and abort ids; mismatched accepted ids, lost replies and every retry opportunity prove one id and no regeneration. Every terminal or no-ending observation carries only its bounded text, tool, shadowed-skill and fixed detail projection. Units exercise minimum, maximum and out-of-domain numeric members; 65,536/65,537-byte answer, history and tool-call-id boundaries; split UTF-8; resolved definition ids at 128 bytes; 256/257 list boundaries; 1 KiB identifier/detail bounds; and the `3 * uint64 - 1` observed-usage ceiling. Integrated cases use the largest Store-admissible events rather than claiming an impossible 64 KiB event payload | fast |
| 1 | `apps/loopex_composition/test/ephemeral_startup_test.exs` and `ephemeral_api_fault_test.exs`; `apps/loopex_composition/test/ephemeral_unknown_root_test.exs` | Pin no-root validation refusal, owner proxy PID/result/DOWN/begin permutation and late undisclosed candidate self-exit without inputs. Fault ready/grant/return/register/ack/commit at every SessionRoot/private-supervisor/store/lease/executor/trace/runtime phase under one 5,000 ms deadline. Candidate prepare grants no mkdir; a delayed candidate after a sealed `root: nil` result cannot gain the owner grant or invoke mkdir; lost mkdir reply names unknown ownership and never deletes. Exact root claim followed by lost dependency return remains start_unknown even when parents are DOWN. Lost trace bind refuses before create/prompt. All startup causes and reached pending lists are pinned; session cell seals3 before unproved return, peer session continues, no shared restart is required | fast |
| 1 | `apps/loopex_composition/test/ephemeral_stop_contract_test.exs`; `apps/loopex_executor_local/test/executor_test.exs` | Prove run-ending/effect/group/subtree obligations before removal. Missing terminal omits unevaluated effect proof; outcome_unknown keeps effects unproved. Race every public method and grant around cell0→1/3; non-stop calls refuse and lost failure notifications cannot reopen; proved-closed2 remains absorbing under delayed failure/cancel notifications. Pin direct executor-PID/instance/nonce certificate before runtime shutdown, reject worker-forged certificates at the owner by executor-only attestation and reject wrong nonce, wrong caller and replay at the executor, retain accepted proof across subtree-only retry. Exact DOWN controls every serial phase/replacement/removal worker. Pin reached-failure combinations and fresh retry deadline, irrecoverable proof remaining unproved, successful later retry setting2 and idempotent stop. A separate session still asks and uses tools after failure | fast |
| 1 | `apps/loopex_composition/test/ephemeral_lifecycle_test.exs` and `ephemeral_cleanup_test.exs` | The owner traps exits before linking helpers and correlates every `EXIT`, `DOWN`, PID and reference. The `FacadeClient` operation, ready, dispatch-with-deadline and cancel messages are suspended independently: missing ready takes the 1,000 ms handshake cancellation path; stop or borrower loss before grant gets a matching cancellation acknowledgement under its separate bound and cannot reach core; after grant a prompt or answer is conservatively possibly admitted regardless of actor scheduling. A second ask before the first grant returns `run_open`; a second answer returns `invalid_interaction_answer`; neither queues or starts a wait deadline, and exact pre-grant refusal or cancellation releases the one mutation slot. Pre-ready, ready-before-grant, granted poll and granted prompt/answer stop cases prove that stop cancels only ungranted work, waits granted work to its operation/cleanup bound, and reuses the live actor for abort. Forged, stale and reordered messages never move the boundary. Timeout-to-question, `last_result`, `run_open`, all four concurrent-stop/creator-exit admission-and-proof branches and terminal-wins races take their fixed forms. Separate process-group, runtime-stop and subtree-stop workers are faulted at result, `finish`, `EXIT` and `DOWN`; each has the 500 ms operation cutoff and 1,000 ms total slot. Refusal, malformed return, raise, throw, exit or timeout with exact worker `DOWN` records that phase and still attempts the next independent phase, while missing `DOWN` prevents a successor and retains `:session_subtree`. Accepted process-group proof is nonce-bound and reused; a retry after an actor-blocked first attempt reaches the previously unevaluated process-group phase, while no reached unproved process-group phase repeats. Every retry receives its fresh deadline. A root-removal-only retry proves any prior removal worker gone and starts no phase worker. Every helper is reaped or the exact reached obligation remains unproved | fast |
| 2 | `apps/loopex_llm_reqllm/test/mapping_test.exs`, `in_process_route_test.exs`, `in_process_model_test.exs`, `in_process_caller_wire_test.exs` and `one_shot_http1_test.exs`; companion mapping suites and dependency-visible correction cases | Cross-adapter vectors pin byte-identical request and valid bounded application-call reply mapping for all four providers. Planning receives the exact ordered credential-free option list; generation receives the same list with only a hosted `api_key` prepended. Response-header capture is provider-exact, deleted on every return/raise/throw/exit and supplies the mapped metadata. A non-nil response error and finish reasons `:error`, `:incomplete` and `:cancelled` fail. Buffered `ToolCall` fixtures cover valid `{}`, invalid text, `null`, arrays, incomplete but repairable JSON, visible atom/string error metadata, provider-executed builtin and provider-native markers, missing or empty visible id/name and multiple-call ordering; any invalid or non-application visible member rejects the whole call list as post-dispatch failure and no local tool executes. Separate provider-builder vectors pin the earlier generated id, normalized missing/nil/empty/unsupported arguments, forced function type, omitted malformed call and stripped error metadata; they prove the mapper makes no impossible refusal claim for an erased field while separately proving visible non-application markers remain rejected. Paired 401, 429, 5xx, transport error, raise, throw and exit cases assert the same public two-class error and fixed text without claiming identical private streaming/direct diagnostics. Route vectors cover provider defaults, omitted ports, explicit default and non-default ports, canonical IPv4, lowercase DNS, uppercase DNS input and normalized paths; they reject uppercase schemes, IPv6, Unicode or percent-encoded hosts, userinfo, empty or malformed authority, non-canonical ports, ports 0 and 65,536, query, fragment, dot segments and every disallowed path before a root or credential read. The effective HTTPS pool options reaching Mint contain the exact nested `conn_opts`/`transport_opts` retention controls, while HTTP omits them | fast |
| 2 | `apps/loopex_llm_reqllm/test/in_process_model_test.exs`, `in_process_admission_test.exs`, `in_process_cleanup_owner_test.exs`, `in_process_pool_lifecycle_test.exs`, `in_process_guard_test.exs`, `in_process_caller_wire_test.exs` and `one_shot_http1_test.exs`; model streaming conformance, companion suites and `apps/loopex_composition/test/ephemeral_real_test.exs` | All four providers use the inline model, canonical explicit address, `total_timeout: :infinity`, `receive_timeout: :infinity`, no cache and `max_retries: 0`. Anthropic and OpenAI planning passes literal `:chat` plus the exact credential-free generation-option list; Anthropic before-plan/after-plan/after-generation Boolean phase checks prove default compiled-catalog initialization and unchanged no-thinking body; generation takes the same chat path and adds only the hosted credential. Deadline vectors map the committed absolute system-millisecond instant with one frozen native offset; cover separated clock samples, positive and negative offsets, uint64 maximum, one positive native tick rounded up to 1 ms, zero/negative remainder, the 1,000 ms cap, in-time and late queued result timestamps and the zero-wait expiry race; and prove no full uint64 or native remainder reaches an OTP or Finch timer. Owner-candidate start proves exact unmanaged starter acquisition creates no proxy or candidate, while the managed path passes the opaque starter only to the unlinked proxy and permutes ready/grant, proxy result, candidate report, `finish`, `proxy_retiring`, proxy `DOWN`, stage_model commitment, private cleanup-module and custody delivery/acknowledgement, `registration_pending`, activation registration/preparation and `begin`; it faults every missing, late, duplicated, replayed, malformed, mismatching and abnormal form and covers wrong stop reference and retainer tuple. Callback death is injected before disclosure, after disclosure, during registration, after managed return and on both sides of `begin`; core stop is injected before and after managed return. With the locked owner `Task.Supervisor` suspended, expiry kills the proxy and seals only its session; resuming it may materialize an undisclosed request-free candidate, which receives no `begin` and exits on its first scheduled dead-proxy, dead-callback or expired-deadline step without root, caller, credential read or dispatch. The composition-owned session_containment_test.exs worker-retained/guard-unregistered witness (mapped in the next row) lets model settlement precede candidate `DOWN` and proves no registered provider-resource obligation exists. When custody was staged, genuine pre-begin callback DOWN must record empty retirement immediately while the candidate remains alive; the exact terminal plus subsequent serialized status barrier releases the empty candidate, genuine DOWN clears slot 2 without sealing or public stop, and the next ask in this same session completes. Only then public stop removes the root. Negative vectors withhold/reorder status, release and real DOWN, change owner_epoch, replay wrong run/reference and attempt release of activated/nonempty/unknown records. Include timeout-background completion and stop winning during status; stop bypasses the continuing-session barrier and still proves subtree DOWN. Actual supervisor termination through the locked brutal_kill starter may preempt teardown and cannot invent a clean acknowledgement. A dropped direct custody acknowledgement still permits empty retirement without granting registrar or work authority; a late acknowledgement cannot reopen the record. After registration_pending, genuine callback DOWN disables activation but leaves the candidate responsive for the later exact core stop. Stage cleanup-only custody before core register. Fault staging delivery/ack loss, callback death before/after provisional commitment, exact core guard commitment before managed return, missing preparation/register_model, expired queued register_model and acknowledgement loss before begin. Every registered empty abort retires the earlier provisional census, acknowledges core and proves candidate DOWN without false sealing. Fault cancellation-prepared/final ack delivery and genuine candidate DOWN ordering; exact no-registration refusal cancels cleanly, unknown registration never does. Queued begin cannot recreate a retired call. No branch uses a registration fallback timer or invents adapter `not_dispatched`. Exact `:unmanaged` or `{:error, :provider_resource_refused}` from registration with candidate `DOWN` remains clean `not_dispatched`; a missing candidate `DOWN` seals the session to 3 and returns conservative `dispatched_or_unknown`, never clean `not_dispatched`. `{:error, :provider_guard_unavailable}`, raised and malformed registration retain core's conservative result. The selected hosted credential is read only by the sensitive caller; absent, empty, 65,536/65,537-byte, exact-value echo, ambient/global/address/provider/final-route and response-overflow/encoding cases map to their fixed public class without leaking private sentinels. A runtime trace session naming the exact one-MFA inventory plus dependency call sites sees the credential-free pre-exclusion call and a non-excluded control canary, but no raw trace message or entry from the sensitive caller after exact exclusion carries the credential canary; exclusion refusal reads no credential. Set SSLKEYLOGFILE after the owner's earlier check but before the lifecycle root's child_spec call: the root refuses and creates/appends no file. Forced retry, redirect, 429/529 and upload-close cases receive at most one grant, accepted connection and request-start marker through the recorded HTTP/1 worker; a body over 64 KiB succeeds. Every setup and dispatch phase registers before progress. After exact managed registration, normal, stop, deadline, partial setup and caller/root/owner failure either prove every registered process `DOWN` and both tagged entries absent before success or acknowledgement, or take the unproved path; no missing registered-owner or child `DOWN` becomes fixed `not_dispatched`. TLS 1.2/1.3 non-resumption with deterministic cache-readiness and ticket-enabled controls and distinct concurrent pools hold in fast cases. The isolated 5,000 ms socket/controller drain is proved only by the separately named release witness. Real Ollama and hosted calls pass; valid mapping stays byte-identical, malformed binary arguments visible at the buffered `ToolCall` seam take the named correction, and dependency-normalized cases remain pinned | fast; release |
| 1, 2 | `apps/loopex_composition/test/ephemeral_serial_run_test.exs`, `ephemeral_settlement_test.exs`, `session_containment_test.exs`, `ephemeral_model_integration_test.exs`, `model_census_test.exs`, `provider_environment_test.exs` and `ephemeral_ambient_disclosure_test.exs`; `apps/loopex_executor_local/test/ephemeral_admission_test.exs` | The retained-worker/guard-unregistered real-core harness proves terminal→status→empty-release→actual DOWN and a successful second ask in the same live session. Real-core variants cover wrong, early and exact ACK-before-DOWN, withheld release expiry and public-stop bypass. The named settlement and census tests cover the remaining negative status, terminal, timeout/background and notification permutations without claiming synthetic processes as real core workers. Startup status failure/loss/malformed fields maps attach_failed with rollback; a 1 ms public ask needs no extra pre-prompt status read. Failed post-terminal status with proved cleanup returns the retained terminal and closes; unproved cleanup carries that ending; prior timeout receives no second reply. Hosted and Ollama models admit none/coding/read-only with all supported variables present; no composition/tool-dispatch presence refusal. Same lifecycle cell reaches model cleanup owner/caller and executor; suspend notifications and prove cell3 rejects later grants. Missing process/registry proof seals3 before conservative result. Callback-DOWN races before/after registration transfer failure authority exactly once; clean-retirement recording ack precedes core ack, exact retired-owner DOWN clears pending, and missing/lost retirement keeps later edge admission closed even before DOWN is handled. Delay independently delivered resource DOWN past retire_model arrival: pending retirement reconciles in the responsive loop, succeeds within its cleanup-control bound, and never blocks stop; expiry seals only that session. Expired model deadlines still permit resource recording and bounded cleanup, not activation. Delay registry removal after exact process DOWN; bounded 10 ms polls reconcile it before proof, and stale poll references are ignored. After recorded retirement, exact cleanup-owner DOWN with any reason, including killed, clears the record. Final closure refuses every pending model record/slot2 or surviving exact tag even when parents are DOWN. Census-revision replays, mixed roles/tags and lost record acknowledgements cannot grant progress or retire unknown resources. Model→tool clean reconciliation is bounded1,000ms and succeeds; wrong-session/replayed/expired tokens cannot change any record. A separate session still calls providers/tools after failure. A deliberately authorized trusted tool reads a supported ambient key and returns it: ordinary tool content may appear in journal, public events and model context. A following provider reply repeating the selected key takes fixed post-dispatch model_call_failed, and repeated echoes can keep failing while context remains; a nonmatching reply stays valid and proved cleanup does not seal the session. Adapter injection witnesses exclude this deliberate host-authorized copy. OS child environment is released M5 behavior; no new scrubbing, same-user secret isolation or cross-call/tool exclusion is promised | fast |
| 1–4 | `apps/loopex_composition/test/bootstrap_test.exs` and `req_llm_start_test.exs`; escript/companion/host inventory in `apps/loopex_llm_reqllm/test/in_process_packaging_test.exs` | Bootstrap one authority-free worker success/error/malformed/late/DOWN/deadline/controller-late-completion and concurrent-start cases; every requester returns within5,000+1,000ms and existing handles never bootstrap. ReqLLMStarter admits one non-secret worker, concurrent requesters join, expiry removes only waiter, no cancellation/peer teardown, later completed start succeeds without VM restart. Fault temporary service recreation with live/dying/ended admitted initializer; no second start before exact predecessor DOWN. Kill the service more than three times in five seconds and retain identical live application/session supervisor and session PIDs. No automatic service restart consumes parent intensity; later creation recreates it boundedly. Validation-only creation writes no persistent keys; absent-origin or different-supervisor-PID running state requires host declaration, and existing waiters fail fixed on service/worker loss. Stop a positively recorded instance and host-restart it; old provenance cannot authorize the new PID. Pin startup refusal precedence, host declarations/current dotenv settings, fresh .env non-load and Tidewave guard. Built escript app:nil admits no project start for invalid ask; ephemeral stalls take bounded bootstrap; durable helper arbitrary errors produce fixed code; legacy commands preserve former start/error behavior. runtime:false code and explicit logger.app/Logger BEAMs remain embedded in both escripts. Actual packaged guarded dependency startup and companion bootstrap to ready must succeed; fixture OTP release :load leaves req_llm/req/finch stopped until guarded start | fast |
| 2 | `apps/loopex_llm_reqllm/test/in_process_transport_drain_test.exs`, with its isolated `long_bound` case on both toolchain pairs | Warm shared Req/SSL only; stall HTTP/TLS calls, then exercise normal completion, stop and deadline. Require ordinary owned-process/tag proof independently, plus server-observed EOF and every call-created TLS controller gone within 5,000 ms of caller DOWN under isolated release conditions. Record the full interval and process/port census; no fixed count or heap-erasure claim. A withheld or late controller fails this release-only case and is never represented as a runtime cleanup acknowledgement condition | current release long_bound; floor --long-bound |
| 2 | `apps/loopex_llm_reqllm/test/in_process_catalog_test.exs`, with cold host-selected catalog fixtures | Actual Anthropic preparation/generation preserves configured file/remote source, overlay/filter/preference settings and the loaded metadata/epoch. A cold latest-release fixture goes through ReleaseStore's own Req calls with source-local adapter options, synthetic GitHub-token header checks, no global Req defaults and no external network. Setting the selected provider key only after the blocked catalog request proves that newly supplied value reaches the actual model call. Host cache/metadata survive cleanup; the next call does not refetch; source adapter options never reach the model route. Cold invalid-file and actual ReleaseStore failures with a raw private sentinel map fixed pre-dispatch model_call_failed after cleanup, with no model connection/selected-provider-key read or sentinel in Loopex planes/state. A blocked cold loader and second cold caller pin shared-lock waiting to existing deadlines. Forced-packaged, omitted-overlay and deleted-state/cache negative controls fail the respective assertions. This does not replace the actual model transport or real-provider lanes | fast |
| 1–4 | `apps/loopex_llm_reqllm/test/in_process_packaging_test.exs`, with CLI/companion archive inventory and the extracted-code fixture | Both real escripts include logger.app/Logger BEAMs. Packaged code with no priv or host dependency paths executes guarded startup and all four actual synchronous provider paths against HTTP/TLS fixtures with synthetic keys; each returns a valid reply and proved cleanup. Separate fresh VMs cover both OpenAI routes, Ollama, OpenRouter, known/missing Anthropic models and exact request bodies. A valid extracted-code ephemeral `ask` traverses actual composition and a synthetic Ollama endpoint while the durable CLI application stays stopped; invalid forms start no project application; durable `ask` starts the exact CLI graph with ReqLLM, Req and Finch still load-only. Non-Anthropic catalog remains absent until positive load control; Anthropic planning initializes the nonempty embedded snapshot and generation/cleanup retain it. Empty/skipped-loading negative controls and unchanged host-preloaded metadata distinguish execution success from packaged-catalog proof. No nonexistent Finch application callback is required. Actual built-command ask and real companion ready-bootstrap remain separately covered by release manifest row 10 and existing real-provider companion bootstrap witnesses | fast; release |
| 1, 3, 4 | `apps/loopex_composition/test/bootstrap_test.exs`, with one-worker lifecycle cases | Requester death is faulted during controller call and after reported result; matching result/timestamp and exact normal worker DOWN are each withheld, malformed and reordered. Only both prove success. Every requester timeout is bounded by its decision/reap deadlines; an already-submitted controller request or authority-free worker may finish shared initialization later but cannot create a root/session or bypass the next full precedence pass | fast |
| 1, 4 | Built-escript inventory and plain-VM admission cases in `apps/loopex_llm_reqllm/test/in_process_packaging_test.exs`; `apps/loopex_cli/test/ask_runner_test.exs` and `ask_command_test.exs` | Mix starts its embedded Elixir base before `main/1`; every no-start claim in this plan means no Loopex project application. Invalid `ask` and `-p` forms prove that no Loopex `.app` is started, valid ephemeral forms prove `:loopex_cli` stays stopped until the bounded composition path starts its own graph, and durable/legacy forms prove their distinct helpers start the exact M6 CLI graph with ReqLLM, Req and Finch still load-only | fast; release |
| 2 | `apps/loopex_composition/test/owner_start_fault_test.exs` | Withhold proxy result/DOWN, suspend start child, permute child report/retiring notice/normal DOWN and activation. No begin means no inputs/root even when delayed supervisor start materializes a child. Existing session remains live. After begin, owner death yields only bare unavailable and possible unnamed root; no replacement cleanup owner or invented cleanup map | fast |
| 2 | `apps/loopex_composition/test/req_llm_start_test.exs` | Suspend validation-worker creation, actual-start retained initializer identity, one-use start grant, shared snapshot, dotenv write, ensure-start return, positive origin write and worker DOWN. Two first callers initialize once; timeout removes only a waiter; a later cohort joins/re-evaluates after exact DOWN. Fault service loss before/after identity publication and begin; an undisclosed pre-publication worker stays inert. Preserve prior origin across fresh validation; a declared host start never becomes Loopex origin. An exact failed or empty-start-list return cannot publish origin. Crash after submission but before origin leaves an unknown running application requiring host declaration; stale intent never becomes provenance. Repeated already-running creation emits no persistent-term writes. Matching-declaration cohorts join, different declarations validate separately. Fault restart with live/dead worker and lost old-service reply; no second active worker before exact DOWN, then re-evaluate instead of awaiting a lost result. Real stalled infrastructure yields bounded creation failure, never a persistent admission block or peer teardown. Current host declarations/dotenv values, stopped-declaration refusal and host-interference limits are pinned | fast |
| 3 | `apps/loopex_store_local/test/memory_test.exs` and `store_conformance_test.exs`; `apps/loopex_composition/test/ephemeral_options_test.exs`, `ephemeral_preflight_test.exs`, `ephemeral_temp_root_test.exs`, `session_root_start_test.exs` and `ephemeral_startup_test.exs` | Library Memory checkpoint protocol uses no test module and30,000ms port calls; real fault probe cases pass. Temp/entropy seams pin UTF-8/NUL/65,536-byte complete paths,15 collisions then success/16 refusal, all mkdir/chmod/lstat/list failures, mode0700 and pre-existing targets untouched. Lost candidate prepare makes no root; lost mkdir return is unknown ownership and never deleted; lost granted dependency return keeps owned root/subtree even after known-parent DOWN. Successful stop/creator exit proves direct process groups and complete subtree before removal; all reached causes/pending shapes and no-waiter logger limitation are pinned | fast |
| 4 | `apps/loopex_cli/test/ask_options_test.exs`, `ask_prompt_test.exs`, `ask_result_test.exs` and `ask_runner_test.exs`; `ask_ephemeral_test.exs`, `ask_integration_test.exs` and `ask_command_test.exs`; `ask_exit_test.exs` and `ask_delegation_test.exs` | The complete grammar and fixed boundary precedence; `-p` identity; argv and incrementally bounded stdin prompts; profile selection independent of `LOOPEX_HOME`; credential-discard order; every exit status; text and JSON stdout purity; and separate-process delegation. Status-1 tests feed huge nested facade terms, exceptions, control characters, newlines, long paths and long unknown flags and prove only the closed fixed diagnostic code or bounded JSON-encoded cleanup-root line is emitted. Every text-mode terminal and no-ending standard-error line, including exact `ending no_ending timeout` and `ending no_ending session_unavailable`, is pinned. JSON-mode proved run and no-ending observations have empty standard error; an unproved cleanup has only its retained-root line. Both profiles pass the explicit empty named-directory manifest and perform no discovery | fast |
| 4 | Existing `apps/loopex_app_server/test/external_workflow_test.exs`, fixture server and independent Node clients | The separate process drives the unchanged JSON-lines app server and reads protocol results, covering the other delegation surface promised in Concept outcome4. Existing external-workflow cases remain required, with no claim that the ask CLI is itself the app server | node_client release |
| 4 | `apps/loopex_composition/test/resource_packs_directories_test.exs` | Direct `LoopexComposition.ResourcePacks.read_directories/2` calls prove the complete public algebra and precedence: malformed paths before malformed options and before filesystem work; workspace failure before named-directory work; canonical unsigned-bytewise expanded-path inspection; and the same first error under every multi-fault input permutation. They also prove exact path/count bounds; relative and absolute resolution; two matching realpath/device/inode observations before the helper derives its non-caller-controlled `workspace_ref`; every named filesystem and pack error; exactly the two result members; exact project/user identities; local-wins shadows; same-kind duplicates; unsigned-bytewise result order; and path-order-independent manifest digest. Seeded pure-counter unit vectors through the test-only wrapper pin exact/max-plus-one raw-entry and path-byte boundaries without claiming whole-pack admission; valid-pack integration fixtures separately pin depth, visited-directory, regular-file and content-byte caps, including invalid-name and special entries in the applicable counts and the named one-directory materialization limitation | fast |
| 4 | `apps/loopex_cli/test/resource_admission_workflow_test.exs` and `apps/loopex_composition/test/ephemeral_startup_test.exs` | Under both ephemeral startup and durable `ask`, the helper result is retained exactly once where durable, the exact host decision is admitted, catalog digests/disposition and the complete canonical tuple set are checked, and skills activate one at a time in unsigned-bytewise order with exact command-id replies. Empty input submits no resource command. Refusal, malformed return, raise, exit, session loss, missing/extra/duplicate catalog tuple, digest mismatch and every Nth activation stop at the first failure before prompt/provider/tool work. Proved ephemeral rollback destroys the partial memory state and root; an unproved rollback returns its exact cause and root; durable failure keeps the actual possibly committed prefix, never retries and leaves a tracked session resumable only after tracking succeeded | fast |
| 4 | `apps/loopex_cli/test/ask_result_test.exs` and `ask_runner_test.exs`; `ask_interrupt_test.exs` and `ask_launcher_test.exs`; `ask_projection_test.exs` | The ephemeral renderer uses only the public completed result, run-error observation, no-ending snapshot or `cleanup_unproved.ending` plus the mandatory stop return, never the handle or attachment. Across both profiles and every outcome, compact JSON is exactly one closed-member object plus one LF, with no other stdout byte; `text`, `tools` and `shadowed_skills` come only from the selected run or composition in their stated order; an unresolved tool has `tool_id: null`; a timeout and a caught post-admission session loss each produce a complete `no_ending` object with the fixed distinct reason, the latter only from `cleanup_unproved.ending` with `cleanup.proved: false` and its retained root. A pre-claim unproved startup with no known path emits `root=null` with no stdout; other nil-root shapes are malformed. Every false cleanup projects the ordered reached-failure set, with no global release phase, and exact root ownership. Worker-origin cleanup maps followed by successful retry, a newer failed retry or a permanent bare stop select the exact stated cleanup/ending; `ending: :none` takes status 1 with zero standard output and names any still-retained root on standard error. Decimal-string witnesses cover `2^53`, unsigned-64-bit maxima and the exact observed-usage maximum without rounding. Text mode emits answer bytes only for completed and bounded terminal summaries on standard error. Forced unmarked owner failure before observation and after a terminal observation, including bare-unavailable stop without an earlier proof-bearing cleanup map, proves status 1 and zero standard-output bytes because no public cleanup proof exists. Real signals suspend the worker before its lifecycle check/owner send, after owner registration but before dispatch grant, after grant and after its provisional result while mandatory stop is running. The first case proves successful stop plus bare `session_closed` or unavailable yields zero stdout, no fabricated `no_ending` and exit 130; every case proves one stop and at most one render. A latched pre-child signal is forwarded and reaped with the platform status but has no Loopex output, cleanup or status promise; second-signal and backstop cases remain hard kills. The real CLI child also receives all four launcher signals after PID assignment but before handler installation while stdin blocks prompt admission | fast |
| 4 | `apps/loopex_executor_local/test/read_only_tools_test.exs` and `apps/loopex_composition/test/tool_preset_budget_test.exs` | The executor's final argument validator admits only each tool's exact key set and types, with exact/max-plus-one string bounds. Root failures, descendant skips, identity changes, symlink non-descent, special-file non-open behavior, raw-entry/path/file-byte/depth/result ceilings and grep's exact 16 MiB cumulative-read rule take their fixed forms. At-cap and next-item fixtures pin whether the requested root counts, maximum-depth emission, result truncation and every skip counter; default non-recursive `ls` does not mark an emitted directory truncated merely because its unrequested descendants exist, while recursive depth exhaustion does. Output records use the percent encoding exactly; the encoder always reserves 107 bytes, admits only complete records in the remaining 16,277 bytes, and emits the 95-byte maximum skipped notice before the 12-byte truncated notice. No fixture claims an OS sandbox or bounded one-directory enumeration. The three literal presets carry the exact definitions/active ids and remain under ADR 0017's measured system-class limit | fast |
| 4 | `apps/loopex_executor_local/test/read_only_tools_test.exs` | `loopex.grep` with omitted `glob` applies no path filter; explicit empty `glob` is invalid, and each admitted non-empty glob is matched against the complete workspace-relative `/`-separated file path. Omission, `*`, a nonmatching pattern and nested-path patterns have distinct fixtures | fast |
| 4 | `apps/loopex_cli/test/ask_interrupt_test.exs`, `ask_ephemeral_test.exs`, `ask_integration_test.exs`; `ask_launcher_test.exs` and `ask_os_signal_test.exs` | Exact ask-mode installation precedes session startup and worker start, is bounded at 1,000 ms and returns the exact `:erl_signal_server` manager PID. Install refusal, malformed return, duplicate claim or manager loss before startup creates no session and emits the fixed diagnostic with zero stdout; handler loss after a handle exists stops it and emits the fixed or retained-root diagnostic. A signal during startup is retained until a returned handle can be stopped without starting a worker. Manager `DOWN` admits only an already-queued matching worker result before the failure path. Forged, stale, old-manager and replayed same-reference notices are ignored. Direct `SIGTERM`, `SIGHUP` and `SIGQUIT`, plus terminal `SIGINT` forwarded by the launcher as `SIGTERM`, each exercise the same ask-notice path. A provisional ordinary worker result starts the exact 1,000 ms reap deadline; in-time `DOWN` proceeds to mandatory stop, an absent `DOWN` gets one kill and zero-wait receive, and a still-absent `DOWN` hard-halts status 1 with no output or cleanup claim. Signals before, during and after mandatory stop race the exact 1,000 ms `finish_ask/2` call; manager serialization returns exactly `:ordinary` or `:interrupted`, and only the winner renders. Missing, malformed, late or mismatched finish reply and manager loss yield status 1, zero stdout and only the applicable fixed or retained-root diagnostic. The exact signal-manager PID/reference notice starts one orderly stop; exact finish and main `DOWN` disarm the backstop. A second handled signal or backstop expiry in `stopping` hard-halts, while a first signal alone does not immediately hard-halt. The monitored ask worker is suspended before owner registration, registered before grant and after grant; each branch performs one stop and at most one render, and the pre-registration branch invents no observation. After interrupt stop, queued result-before-`DOWN`, `DOWN` without result and neither queued are faulted; the exact worker is killed and reaped within 1,000 ms, while withheld `DOWN` takes the no-output status-130 hard halt. Launcher fixtures deliver each signal before child assignment and after assignment but before handler install; the latch forwards `TERM`, no signal is lost, the child is reaped and its platform status is preserved without a Loopex-130 assertion | fast |
| 5 | `apps/loopex_composition/test/durable_options_test.exs`, exercised through `start/1`, `with_runtime/2` and `start_edges/2`; `apps/loopex_llm_reqllm/test/provider_deadline_test.exs` | All four added options and defaults share one validator: first-colon model parsing including an id with another colon; admitted and refused provider cases; complete and partial bounds at 1, uint64 maximum and maximum plus one; sampling at 1 and 1,000,000 and outside; every active-id combination, duplicate/unknown refusal and the explicit empty-definition workaround. Paired released-0.2 and candidate entrypoint vectors show each of the four keys ignored in 0.2 but validated in M6; valid candidate values apply, while `model: "ollama:x"` and malformed values refuse. Outer-list, other-unknown-key and first-duplicate conventions remain released behavior. Combined faults pin the released validation chain followed by model→bounds→sampling→active-tools, including every adjacent pair, and no invalid added value starts an edge. Named directories are not a raw fifth option. Companion total, stream-idle and receive waits are infinite; the unchanged sliced coordinator deadline remains authoritative at uint64 maximum and for a short stalled call | fast |
| 5 | `apps/loopex_cli/test/durable_ask_workflow_test.exs` | The helper completes before root identity; placement and runtime id precede one credential-plane acquisition; one exact composition-option bundle retains the manifest once; and create→track→attach→admit→catalog→ordered activation→status→interrupt→prompt occurs exactly, with the empty-manifest path skipping resource commands. Create id bounds, the attachment struct, active status plus positive-uint64 cleanup grace, exact command replies, every catalog mismatch, and the catalog-to-`resource_admission_failed` diagnostic are pinned. Every boundary fails independently and in the stated combined-fault precedence. Create-reply loss, tracking failure before publication and after publication-before-fsync, each post-track failure and the legacy `interrupt-` id/uncorrelated accepted reply are exercised without retry or stronger recovery claims. The private monotonic-clock seam fixes prompt acceptance, reader return and expiry instants, including saturation and the zero-wait deadline race. The single `FollowReader` owns a replay attachment from the callback's accepted cursor and requires exact PID/ref/deadline/cursor acknowledgements. Pre-join events, another run's events, a matching `user.message_appended` command id, a duplicate or conflicting join and expiry before join prove that the prompt command id freezes exactly one run id and only that run enters the projection. On terminal, error, deadline and callback raise/throw/exit, exact `DOWN` proves reap; a deliberately withheld `DOWN` instead discards the projection, returns only `follow_reader_cleanup_unconfirmed`, emits no callback output and may briefly leave the killed, unlinked reader with no mutation or output route. An event consumed only by its disposable attachment remains replayable from the unchanged durable cursor in both branches. `with_runtime/2` cleanup replacement discards any callback projection, plane and placement release in order, and only the surviving value renders once afterward | fast |
| 5 | The complete M5 suites and retained release lanes; `mix loopex.deps_budget`; `git diff v0.2.0 -- apps/loopex/lib ':(exclude)apps/loopex/lib/mix'` empty at the tested candidate, with only the two closure tasks added and the existing dependency check's literal parser and exact edge-declaration/materialization oracles updated under `apps/loopex/lib/mix/tasks/` | Valid durable behavior, daemon and both protocol generations remain unchanged; a companion malformed binary argument still visible at the buffered `ToolCall` seam now fails closed before tool execution, visible provider-executed and provider-native calls fail rather than becoming local requests, dependency-normalized erased cases remain pinned, and the named timer-safety change leaves the coordinator deadline authoritative. The core dependency budget, package-name closure and core runtime library are unchanged; a `v0.2.0`-to-candidate `mix.lock` package-key comparison proves the closure claim independently of the current-tree dependency budget check. `apps/loopex/test/deps_budget_test.exs` proves the exact three load-only edge tuples and all refused variants named under Packaging; fresh-source materialization exercises those roots. Expected test-data changes are enumerated rather than called unchanged: running-build version assertions become version-derived; the exact definition inventory moves from four to seven while a separate assertion keeps the default active ids at the original four; visible malformed-binary and non-application fixtures change from flattening to fixed post-dispatch failure; dependency-normalization fixtures keep the locked behavior; `release_version` and developer text move to `0.3.0`; and the release manifest adds the two M6 provider rows plus the separate rollback lane. The durable default `policy_identity` remains literal `"0.2.0"`; pure encoder version-vector tests remain unchanged | fast; release |
| 5 | `apps/loopex_cli/test/rollback_test.exs`, separate real-provider-credential-free rollback release lane with fixture-paired v0.2.0/candidate builds | The outer release runner supplies both exact pristine archives to the isolated build procedure below. One test-owned scripted worker speaks the released bootstrap/manifest/request/reply/cleanup protocol; the same fixture launch configuration is captured in each rebuilt CLI and explicitly passed to daemon --provider-launch. The public embedding subcase uses the shipped deferring Loopex.AppServer.Policy.Ask and default revision0.2.0 in both directions, without an identity override, and proves the recovered question is answered and the run advances. M6-only pending-not-dispatched work commits unknown_tool under0.2; dispatched work is never redispatched: matching receipt is admitted, absent/unresolved/settling commits outcome_unknown, and in-flight or declined evidence stays pending. Completed history replays. Offline user-skill reload by digest and daemon-wide withholding of that session's skill context are observed. Invocations of binaries rebuilt from released0.2 source receive only the public inert LOOPEX_PROVIDER_API_KEY=loopex-rollback-inert-not-a-provider-key; real provider keys remain unset and the worker asserts the exact separate credential frame. Missing-variable invocations are negative startup controls. A fresh fixture-paired0.2 daemon cannot discover/activate an external user tuple and returns resource_not_found, while project activation succeeds. This proves released-source compatibility and discovery, not published-binary packaging or arbitrary embedding-host manifests | release |
| 6 | `apps/loopex/test/closure_archive_compare_test.exs` and `closure_confine_test.exs`; `scripts/test/stage-archive-manifest-test.sh`, `source-archive-check-test.sh`, `rollback-archive-test.sh`, `escript-inventory-test.sh`, `floor-lane-test.sh` and `attended-release-test.sh`; `bash scripts/check.sh --docs` | Every command's exact grammar, mandatory argument, preflight, PASS/FAIL line and exit rule is exercised. Existing outputs never overwrite; missing parents create nothing; partial writes remove only their own temporary files; failed executed lanes retain complete logs. Archive comparison refuses missing, non-ordinary and malformed exact sidecars and proves NUL framing, tuple projections, Git-blob-bound file and link content, source identity, and a regular executable escript output. Automatic attendance refuses a missing anchor, wrong milestone, wrong tested SHA, non-descendant authority SHA and absent authorization, and accepts only the recorded combination. P1's exact charter exception list, P2's selected unattended pre-merge lanes, P3's retained complete output plus SHA and P4's milestone-branch rejoin-main rule are present. A retained semantic review covers `README.md`, `docs/operator/getting-started.md`, `docs/operator/runtime.md`, `docs/operator/tools-and-policy.md`, `docs/developer/getting-started.md`, `docs/developer/getting-started-technical.md`, `docs/developer/runtime-and-embedding.md` and `docs/developer/compatibility-surfaces.md`; the documentation check passes. M6 closure invokes only these repository commands | fast; closure |
| 1–4 | `scripts/m6-demonstration.sh`, the single acceptance demonstration, run from a clean checkout with no `LOOPEX_HOME` on macOS and on Linux | Its four steps in order, each printing its own `PASS` or `FAIL` line and the elapsed time; the complete output of each platform's run retained with its reference and SHA-256 digest in `docs/evidence/M6-closure-runs.md` | closure |
| 2 | Independent read-only in-process credential/security review of tested SHA; immutable complete output retained outside repository | `docs/evidence/M6-closure-runs.md` reserves Pending result, tested SHA, retained-output reference and SHA-256 fields before candidate commit. Administrative child fills only reserved fields; no new review document after testing. Review verifies transport, adapter-injected-value rejection, direct cleanup proofs, hosted tool use, ambient-key acceptance including deliberate trusted-tool disclosure, session-local seals, recoverable startup, all seven amendment texts including the proposed host-selected catalog trust scope, loader failure/lock witnesses and release-only socket/TLS5,000ms bound. No arbitrary heap erasure, global key-free runtime claim or same-user tool isolation. Load-only packaging and persisted dotenv off are checked | closure |

The 2026-09-27 maintainer documentation direction extends row 6's retained
semantic review to the existing `docs/operator/coding-sessions.md`,
`docs/operator/observability.md`, `docs/operator/how-a-run-works.md` and its
technical companion, `docs/developer/architecture.md`,
`docs/developer/agent-loop-and-tools.md`, both directory indexes, and the
root `README.md` and `CHANGELOG.md`. The review checks every affected
getting-started command and embedding example against the tested candidate,
distinguishes ephemeral and durable credential/tool/artifact behavior, and
leaves `run`, daemon and app-server guidance correct for the durable profile.

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
  `rollback` lane is a separate `--only rollback` lane beside them, requiring
  no real provider credential because it drives a scripted model:
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
- **Rollback build and staging.** This lane proves compatibility using pristine
  source rebuilds paired with a fixture provider, not published binaries.
  While still in the clean Git checkout, before entering the fresh-source lanes,
  `check-release.sh` resolves `v0.2.0^{commit}` and requires
  `3f81b04828901a6fb05b29e8b6bed211eed2d376`. It stages exact `git archive`
  bytes for that commit and the tested candidate SHA to separate exclusive
  files outside the candidate extraction. It passes their absolute paths and
  commit identities to the rollback driver. Retain each archive reference and
  SHA-256 plus complete staging output. The driver does not need `.git`, does
  not consult the checkout and does not reuse the candidate's already-built
  fresh-source tree. It extracts each archive under a separate scoped-umask
  root, validates SOURCE_IDENTITY against the supplied commit, independently
  enumerates every extracted path, and verifies every file and link against the
  independent Git-tree blob identities, then resolves
  its own locked dependencies with
  `mix deps.get` from that extraction under `without_credential`. No preexisting
  top-level `deps` or `_build`, inherited build-path override or fixture source
  mutation is allowed. The outer runner supplies the separately verified tree
  projections alongside the archives so validation needs no Git repository.
  Keep acquisition/build outputs in the rollback log.

  From each isolated `apps/loopex_cli` directory, with `launch` bound to its
  absolute test-owned scripted launch file, run this direct Mix task recipe:

  ```sh
  MIX_ENV=prod LOOPEX_BUILD_PROVIDER_CONFIG="$launch" mix run --no-start -e '
  tasks = ["compile", "compile.all", "compile.protocols"] ++
    Enum.map(Mix.Project.config()[:compilers] || Mix.compilers(), &"compile.#{&1}")
  Enum.each(tasks, &Mix.Task.reenable/1)
  Mix.Task.run("compile", ["--force", "--warnings-as-errors"])
  Mix.Tasks.Escript.Build.run([])
  '
  ```

  The credential-clearing wrapper encloses dependency acquisition and this
  command. Forced recompilation captures that launch file; the direct task
  bypasses `build_pair/1`, which would overwrite it with real-companion settings
  (`apps/loopex_cli/mix.exs:25,32-89`, `provider_launch.ex:9-40`). Every version
  invocation is a fresh OS process, after its predecessor/daemon DOWN. Reuse
  only the retained durable root/workspace and explicitly retained identities.
  The pending-interaction subcase is a public embedding case, not a CLI-policy
  case. From each isolated `apps/loopex_app_server`, run a test-owned driver with
  `MIX_ENV=prod mix run --no-start DRIVER.exs ...`. It consults the same fixture
  launch file and passes it as `provider_launch:` to
  `LoopexComposition.with_runtime/2`, with the shipped
  `Loopex.AppServer.Policy.Ask`, the same state_root/workspace/runtime_id and
  no policy_identity override. Acquire dependencies, build both CLI binaries and
  precompile both app-server driver environments before either writer commits
  its question. No build/dependency work occurs between committed question and
  answer. Retain its interaction id and stored expires_at unchanged;
  policy expiry is min(five minutes after committed creation, run deadline)
  (`policy/ask.ex:27-39`, `session_coordinator.ex:6525-6541,6753-6767`). Both
  writers explicitly put bounds: %{deadline_ms: 600_000} on the original
  public prompt command, matching the released default (`runtime.ex:946`) and
  its command-bound merge (`session_coordinator.ex:3540-3543`). Do not rely on
  the :bounds composition option that 0.2 ignores. This does not change the
  five-minute interaction expiry.
  This leaves room for proved writer teardown and fresh reader VM startup;
  neither step starts a new expiry clock. The reader computes the remaining
  budget from that stored expires_at and the same wall-clock basis used by
  Ask. Require at least 120_000 ms remaining before activation/answering and
  retain that measured budget; insufficient headroom is unavailable evidence,
  not a reason to extend, recreate or retry the question. Require the actual
  answer commit before the unchanged expiry even after this admission check.
  Expiry fails or is unavailable evidence, never
  a new question, extension or retry. Both source versions must derive the same
  module id and default revision `"0.2.0"` (`loopex_composition.ex:249-261`);
  Ask really defers (`policy/ask.ex:53-80`). CLI allow-all/shell-allowlist cannot
  produce this proof (`loopex_cli.ex:229-233`).

  Writer calls `Loopex.create_session(runtime, %{}, command_id: "rollback-create")`,
  attaches from sequence0, sends one prompt to read the fixture file, and
  retains the committed `interaction.requested` id without answering. Return
  from with_runtime/2 and require successful bracket cleanup of every owned
  edge plus child-process exit before the next OS process
  (`runtime_owner.ex:120-145`). Runtime.stop preserves durable Store history
  (`runtime.ex:122-139`), leaving the pending interaction recoverable.
  Reader in the other source calls `Loopex.prepare_resume_session/3`, attaches
  before activation, checks `Loopex.Attachment.open_interaction/1` for the
  identical pending id, then `Loopex.activate_resume/1` and a single command
  `%{type: :interaction_answer, command_id: answer_id,
  interaction_id: retained_id, choice_id: "allow"}`. Require committed
  interaction resolution, exactly one completed tool and completed run.
  Public entrypoints are `loopex.ex:87-95,133-152,497-544`, pending view
  `attachment.ex:59-73`. Repeat each direction on a separate durable root.
  The fixture worker is history-sensitive: issue one released loopex.read call
  until its tool result appears in context, then final text. A restarted
  per-process counter cannot drive this recovery witness. The CLI/daemon
  fixture-paired binaries separately prove unknown-tool and skill behavior,
  using allow-all where no pending question is claimed.
- **Transport-drain execution.** Reuse `:long_bound`. Implementation adds its
  exclusion alongside the existing `:real_provider` exclusion in
  `apps/loopex_llm_reqllm/test/test_helper.exs:36`. One case in
  `test/in_process_transport_drain_test.exs` drives all HTTP/TLS normal, stop
  and deadline vectors in an isolated VM, using synthetic fixture keys only.
  Add exactly one dedicated step to each of the current release and floor
  `--long-bound` runners. Do not add this application to either generic
  long-bound application loop. The current fresh-extraction command is
  `lane long-bound-loopex_llm_reqllm loopex_llm_reqllm 1 without_credential mix
  test test/in_process_transport_drain_test.exs --only long_bound`; it is not
  an extra manifest row. The lane helper streams this complete output directly
  to `$retain/long-bound-loopex_llm_reqllm.log`, including failure, before
  judging exit status and requiring exactly one executed case.
  M6 closure must invoke `scripts/floor-lane.sh SHA --output-dir DIR
  --long-bound`. Its reqllm step uses the same exact file and selector,
  removes all four credential variables and `MIX_BUILD_PATH`, and preserves
  the pinned floor pair and absolute pair-specific build root used by its fast
  step. Change the release lane() helper to stream directly into its retained
  `$retain/$label.log`, judge that same file and retain command/tee statuses,
  executed count and measured duration before any failure exit. Disable errexit
  only around the pipeline and capture its complete PIPESTATUS array as the
  immediately following command, before restoring errexit. Guard summary
  extraction with a guarded `if` around the command substitution running
  `bash scripts/suite-summary.sh "$retain/$label.log" --count`, recording its
  status and either a numeric count or the fixed unavailable marker; no failed
  substitution may trigger an early set -e exit. After the stream closes,
  append command, tee and summary statuses, count and measured duration to
  that same lane log. Emit its final retained path and SHA-256 in the release
  transcript, for every lane including failed lanes. Reuse the existing digest
  helper (`check-release.sh:102-103`), not just its two fresh-source-file digest
  calls. Only after those records are retained may the helper enforce
  command/tee/summary statuses and expected case count.
  No log is changed after its digest. Missing log, count or digest is unavailable
  evidence, never PASS. A scripts/test/floor-lane-test.sh fixture plus a
  release-lane-helper fixture in scripts/test/attended-release-test.sh must
  drive a failing executed command and a failed count parser, and require the
  retained status/count-or-unavailable/duration and SHA-256 line before nonzero
  exit. A failing command whose summary parser refuses is not claimed to have
  a numeric count. These fixtures execute the candidate's actual lane helper,
  not a copied implementation of it.
  EXIT cleanup removes only disposable extractions/scratch, not retained logs.
  The current temporary-log helper (`check-release.sh:34,118-122`) cannot satisfy
  this without that explicit change. It retains
  `DIR/long-bound-loopex_llm_reqllm.log` and also requires
  exactly one executed case. Each pair's output records tested SHA, toolchain,
  result, measured duration, retained reference and SHA-256. The other apps keep
  their existing long-bound count rules. The current and floor logs, not a fast
  test or the eleven-case manifest, prove the separate 5,000 ms drain bound.
- **Release credentials.** The release credential stays
  `LOOPEX_PROVIDER_API_KEY`, an Anthropic key.
  - `with_ephemeral_credential` passes it to row 11 as `ANTHROPIC_API_KEY` for
    that row's process only and removes `LOOPEX_PROVIDER_API_KEY` in the child.
  - `without_credential` unsets `LOOPEX_PROVIDER_API_KEY`, `OPENAI_API_KEY`,
    `ANTHROPIC_API_KEY` and `OPENROUTER_API_KEY`, so the driver and fast check
    see no real credential.
  - The rollback driver starts under `without_credential`, asserts all four
    variables absent, then supplies only the fixed public inert
    `LOOPEX_PROVIDER_API_KEY=loopex-rollback-inert-not-a-provider-key` in each
    released binary's child environment. Its fixture-paired scripted companion
    receives that literal in its separate credential frame, not bootstrap
    metadata, and never contacts a real provider. Driver self-checks remain
    unchanged; a separate missing-variable child must refuse startup.
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
| Entrypoint ↔ owner activation proxy | Entrypoint retains begin token and monitors proxy/candidate | No inputs or root before reconciled PID/return/normal proxy DOWN and exact begin. Lost start result withholds token; late child self-exits, and peer sessions remain live. Owner loss after begin returns only bare unavailable with possible unnamed root; no replacement owner |
| Ephemeral owner ↔ public callers | The one serial owner holds one public-mutation slot and one lifecycle state | A second ask before or after grant is `run_open`; a second answer while an answer owns the slot is `invalid_interaction_answer`; neither queues. The first stop enters `stopping`; later stops join its result and later non-stop requests return unavailable immediately, while requests serialized earlier take their exact admission-state result |
| Coordinator ↔ either adapter | The session coordinator, as for any model | A raise or exit inside the adapter is `dispatched_or_unknown` by the existing rule, and the run ends `failed`. A pre-dispatch refusal is retried once by the existing attempt limit |
| Model callback/candidate ↔ caller and tagged pool | Core registers cleanup owner; M6 composition session owner retains pending-call census through clean retirement | Callback opens credential-free pending record before proxy; exact managed registration plus session-recorded owner PID permit begin. Resources are owner-registered before progress; normal/stop/deadline/partial failure prove exact applicable processes and both tags before success/core acknowledgement. Missing proof seals only session3 and leaves record pending. Clean retirement is recorded before core stop acknowledgement and exact owner DOWN clears it; queued/unprocessed owner loss cannot admit another edge |
| Adapter ↔ ReqLLM | The in-process adapter | Any non-success return or raise from `generate_text/3` is `dispatched_or_unknown`. A response with a non-nil `error` or finish reason `:error`, `:incomplete` or `:cancelled` is not success. The kernel's deadline ends the call through the cleanup owner, and the run ends `failed` or `outcome_unknown` by the existing rules |
| Composition ↔ guards and credential | The ephemeral composition, owner before pool creation, caller before each call and one-shot adapter at final dispatch | A replaced provider module, non-empty `:req` `:default_options`, set `SSLKEYLOGFILE`, unsafe base URL, plain HTTP or an unsafe routing refuses before any per-session root exists; the pre-start Req and SSL guards run before Loopex starts ReqLLM/Req. Only the sensitive caller reads the key: an absent, empty or greater-than-65,536-byte value found immediately before `generate_text/3` is `not_dispatched`, accepts no connection and takes the owned teardown path. A final route mismatch or second adapter invocation is refused without network activity but remains conservatively `dispatched_or_unknown` because the ReqLLM call has begun |
| Composition ↔ ReqLLM initialization | One temporary responsive ReqLLMStarter and at most one admitted non-secret initializer | Empty Req defaults/unset key-log/Tidewave guard precede shared start. Validation writes no persistent keys; actual admitted start retains initializer identity before grant, persists dotenv off and records positive origin only from a start result containing req_llm. Unlinked admitted worker survives service loss; bounded waiters fail independently. Exact predecessor DOWN permits validation/recreation; temporary service crashes cannot exhaust session-parent restart intensity |
| Owner ↔ private startup actor/subtree | Owner monitors SessionRoot, its private zero-restart supervisor and every registered edge | Exact begin and ready/grant control root/start authority. One5,000ms deadline covers all phases; lost mkdir result names unknown path without deletion; granted unknown dependency remains unproved despite parent DOWN. Trace binds before create/admission. Return failures roll back safely; containment closes only this session |
| Runtime ↔ private ephemeral subtree | `SessionRoot` owns the `:one_for_all`, zero-restart-intensity subtree containing the memory store, lease, executor, runtime trace capability, `RuntimeHolder` and runtime; the ephemeral owner monitors every registered PID | Any child loss collapses the subtree without restarting an edge. The owner takes the session-failure cleanup path and exits unmarked; the handle reports unavailable, and nothing is recovered or silently replaced beneath it. Cleanup retries reap any retained actor, phase worker or removal worker before starting a successor |
| Executor ↔ tools/session admission | Exact executor owner/instance and shared session lifecycle cell | Tool/model edge grants query the same responsive session owner; no grant bypasses a pending unretired model. Direct executor-PID/instance/nonce group certificate is retained before runtime stop. Released environment/effect protocol stays unchanged; only read-only tools and private containment/proof are added |
| Durable callback ↔ `FollowReader` | The callback owns one linked, monitored disposable-attachment reader and its accepted cursor | Exact `DOWN` within the private reap bound permits the selected projection. Missing `DOWN` discards it, returns only `follow_reader_cleanup_unconfirmed` and leaves the already-killed reader with no mutation or output route; the durable cursor remains replayable |
| `ask` main ↔ signal handler and worker | The CLI main installs exact ask mode before creating its handle, then owns the handle and monitors one blocking API worker | Installation refusal creates no session; live-handler loss after startup stops the session and exits 1. A signal admitted during startup stops a returned handle before worker start. An ordinary provisional result must be followed by exact worker `DOWN` through the 1,000 ms reap protocol; a still-missing `DOWN` hard-halts status 1 without output. A first correlated interrupt notice performs bounded stop; afterward the main kills and proves worker `DOWN` within 1,000 ms before rendering. Missing `DOWN` on that interrupt path, a second handled signal or backstop expiry hard-halts 130. Every admitted ordinary outcome has one exit status; JSON is one compact object plus one LF and text mode emits only its defined bytes; no branch invents an observation |

<a id="technical-plan-compatibility"></a>
### Compatibility

Concept: [Rollout and compatibility](M6.md#concept-plan-rollout).

| Surface | M6 change | Label |
| --- | --- | --- |
| Core runtime library (`apps/loopex/lib` outside `mix/`) | None | Unchanged |
| Core Mix tasks (`apps/loopex/lib/mix/tasks/`) | Two closure tasks added; the existing dependency check's literal parser and edge-declaration and materialization-root oracles recognize the three exact load-only declarations | Development tooling; core runtime budget and package-name closure unchanged |
| `LoopexComposition.Ephemeral` | New | Experimental |
| `loopex_composition` application tree | Application callback owns temporary ReqLLMStarter and temporary-owner DynamicSupervisor siblings; the starter is recreated on demand without automatic restart-intensity accounting | Shared startup failures are recoverable infrastructure failures; no cross-session exclusion, persistent refusal state or explicit peer teardown |
| `LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` (M4/M5 rework) | Optional `:model`, `:bounds`, `:sampling` and `:active_tools`; defaults reproduce M5 exactly; released outer-list/error/duplicate-key conventions stay unchanged; these four previously ignored keys become recognized and validated; named directories use the public helper, released `:resource_manifest` option and ADR 0025 session commands; the default policy revision is fixed at `"0.2.0"` | Experimental additions with four-key validation tightening; the revision keeps `0.2` recovery exact |
| `LoopexComposition.ResourcePacks.read_directories/2` | New; project and user skill directories, `user:<name>` identity | Experimental |
| The companion adapter (M1/M5 rework) | Pure mapping moved to `Loopex.LLM.ReqLLM.Mapping`; the dependency-visible tool-call mapper now decodes binary arguments without repair, rejects malformed payloads still visible after ReqLLM's buffered normalization rather than substituting `%{}`, and rejects visible provider-executed or provider-native calls instead of flattening them into replayable local calls; ReqLLM total, stream-idle and receive waits become `:infinity` so only the unchanged coordinator's sliced committed deadline governs the call | Private refactor, bounded fail-closed correctness fix and timer-safety fix; valid application-call reply mapping, dependency-normalized erased cases, protocol and deadline meaning unchanged |
| `loopex_llm_reqllm` application (M1 rework) | `req_llm` plus the direct exact `req` and `finch` dependencies are `runtime: false`: their code stays embedded but none enters the adapter application's automatic start list; explicit extra_applications [:crypto, :logger] retains Logger in both escripts; the companion already starts the dependency set explicitly | Hardening; companion and host releases list all three as `:load` |
| Local executor (M2 rework) | Adds three read-only tools, explicit private session admission/lifecycle cell and direct at-most-one-group drain proof to its owner | Released environment, executor protocol, durable records and durable/direct default behavior unchanged |
| The vision (§12) | The credential exclusion narrowed for the ephemeral profile, by ADR 0039 | Made at ADR 0039's acceptance |
| Command line | `ask` and `-p` added; `refuse-all` selectable for `ask`, mapped to `LoopexCli.Policy.RefuseAll`; the launcher exports `ERL_CRASH_DUMP=/dev/null` for `ask` and `-p` only. The escript uses `app: nil`: invalid ask input starts nothing, valid ephemeral ask reaches the bounded composition bootstrap, valid durable ask starts the CLI graph through its fixed-diagnostic helper, and the exact-Mix-compatible legacy helper reproduces the former startup for every existing or unknown command; every existing subcommand remains behaviorally unchanged | Experimental command plus private startup rework |
| Release check (M5 rework) | Two real-provider rows and the `rollback` lane added; one dedicated credential-free transport-drain step on each toolchain pair outside the generic long-bound application loops; a per-row credential mode; credential clearing and redaction cover the per-provider names; `release_version` moved to `0.3.0`; the Ollama precondition | Development tooling |
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
| Backup and restore or downgrade policy | Unchanged from `0.2`; the `0.2` binary opens and resumes every root `0.3` writes, subject to the same-policy pending-interaction boundary and three stated rollback limitations below |
| Pending interactions across versions | Host-selected policy module identity must match exactly. Composition's default identity revision remains `"0.2.0"`; the fixture supplies shipped Loopex.AppServer.Policy.Ask in both source builds and omits only the identity override. Identity includes `inspect(policy)` and revision (`loopex_composition.ex:259-261`). This proves the same-policy host, not an arbitrary `0.2` CLI policy |
| Exception: a call to an M6-only tool | A call not yet dispatched is re-resolved against the active tool set on recovery (`session_coordinator.ex:5609-5614`); `0.2` answers `{:error, {:unknown_tool, name}}` (`:6846`) and commits it as a failed tool call (same dispatch_effect error branch), and the run continues; its effect never ran, and the model sees the failure. A call already dispatched follows core's dispatched-effect recovery unchanged (`session_coordinator.ex:2789-2796`): activation queries the executor once and never redispatches (`:7651-7736,7800-7847`): a matching receipt is validated/admitted; `:absent`, `:effect_unresolved` or `:effect_settling` commits `outcome_unknown`; `:effect_in_flight`, malformed/mismatching evidence, another executor error or failed store commit declines and leaves work pending for a fresh host query; `0.2`'s executor defines no such tool, so it never runs it again |
| Exception: an admitted user skill | Its admission is journaled as a reference, digest, decision and selections (`session_state.ex:4898`) and its snapshot retained under the state root by digest (`resource_packs.ex:333-380`), as for any pack. `0.2`'s offline `loopex resume` reloads it by digest through core validation, which accepts its `user:<name>` identity (`resource_pack.ex:203-216`, `:343-348`). `0.2`'s daemon composes only discovered project skills (`daemon.ex:239-242`), whose manifest can never match the session's one admitted digest, so the session resumes with all of its skill context withheld, project skills included (`runtime/resource_snapshot.ex:112-121`, `runtime/resource_context.ex:38-47`). |
| Exception: a new user skill | `0.2`'s released CLI/daemon discover project skills only, so they cannot newly admit or activate an external `user:<name>` skill. No claim is made about arbitrary embedding-host manifests. This is distinct from offline reloading of an already retained user snapshot |
| Proof | The `rollback` lane proves both directions and the stated rollback limitations |

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
    entry that owns the one-for-one startup-service/owner-supervisor siblings;
  - the command is in `loopex_cli`.
- **Dependency budget:** update only the literal external-declaration parser,
  the edge-declaration oracle in
  `external_dependency_reasons/2` and the edge roots in
  `external_materialization_roots/1` of
  `apps/loopex/lib/mix/tasks/loopex.deps_budget.ex`. `dependency/1` currently
  parses only two-element declaration ASTs; add the literal three-element AST
  `{:{}, metadata, [name, requirement, [runtime: false]]}` with an atom name
  and nonempty valid binary requirement, without evaluating expressions.
  Keep contextual authorization in the exact edge oracles. They currently admit only
  `{:req_llm, "~> 1.24.0", []}`. The new permitted edge set is exactly
  `{:req_llm, "~> 1.24.0", [runtime: false]}`,
  `{:req, "== 0.7.4", [runtime: false]}` and
  `{:finch, "== 0.23.0", [runtime: false]}` in `loopex_llm_reqllm`, with
  no duplicate declaration or additional option. Declaration order carries no
  meaning. Preserve every inward-direction, core/telemetry budget, package
  lock/version/source and materialization-closure check; Req and Finch already
  belong to that locked closure. `apps/loopex/test/deps_budget_test.exs` adds
  the exact passing set and failing vectors for a missing or duplicate tuple,
  wrong version, auto-starting dependency, extra option, extra package and
  the same declaration in an unauthorized repository application. Parser-level
  negatives cover computed names/requirements/options, duplicate option keys,
  improper lists and every option shape other than literal `[runtime: false]`;
  preserve all existing two-element external and internal-dependency rules.
  The edge-declaration oracle requires all three tuples exactly once. The
  materialization-root oracle admits only those tuples and derives roots;
  its subset check does not independently prove required tuples are present
  (`loopex.deps_budget.ex:633,1550-1556`). Missing-tuple vectors must fail the
  edge oracle. Duplicate names fail parsing (:1229-1233); extra/duplicate/auto-start
  options and other unsupported AST shapes assert the fixed parse refusal
  `deps must be one unambiguous record of unique literal dependency data`.
  Otherwise-valid wrong versions, packages and application placement assert
  their contextual oracle refusals. Fresh-source evidence exercises the admitted roots. The CLI still reaches the ephemeral profile
  only through composition, as the client rules require.
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
  owner activation, proves the durable ask's fixed returned-startup error, and replays every
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
- The composition edge adds one ReqLLMStarter and an owner DynamicSupervisor
  as one-for-one siblings. Startup's sole worker isolates the shared application
  controller; the entrypoint's sole bootstrap worker isolates its initial app
  start, and one owner-activation proxy isolates DynamicSupervisor.start_child.
  These workers have no session inputs or authority. Every live session adds one
  SessionRoot/private supervisor, trace capability and RuntimeHolder because
  runtime readiness/supervisor starts can block and each surviving OTP edge must
  keep a lifetime parent. The M6 composition session owner also holds the small
  private pending-call census; no additional admission actor or global scheduler
  is added.
- The local executor adds an at-most-one unproved group set and direct drain
  certificate, and queries its M6 composition session owner for private dispatch
  admission; no core behavior, environment behavior or protocol changes.

- The memory store promotes the existing small conformance wrapper, with library-side checkpoint and explicit call bounds.
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
| 1 | In the ephemeral profile the host environment has a hosted credential for the host's lifetime. During the call and owned cleanup until they end, the caller, tagged pool, provider HTTP/TLS state, crash reports, crash dumps and host telemetry may expose it; a host-made copy has host-owned retention. Cleanup proves the caller and tagged pool gone. Beyond the continuing host environment and host-made copies, a checked-out socket and its OTP TLS controller may retain request material while they drain | ADR 0039's vision amendment accepts this scoped exposure; the exact adapter-injected value is checked before a reply enters a Loopex plane; TLS reuse, tickets and secret retention are disabled; `SSLKEYLOGFILE` is refused; the caller is sensitive and excluded from Loopex tracing; no result route remains after cleanup. Under isolated release conditions the socket and controller must be gone within 5,000 ms of caller `DOWN`, but runtime cleanup does not wait for or prove that threshold; no arbitrary heap-erasure claim is made; the durable profile keeps structural isolation |
| 2 | ReqLLM's start settings and, once Loopex starts it, its application plus Req's shared infrastructure stay for the VM's life unless the host stops them; a host that wants ReqLLM started earlier must start it itself with `.env` loading off and declare it | ReqLLM reads the settings only at start; composition refuses rather than inherit an unknown start. Loopex does not stop or reference-count shared dependencies another component may use, but no model call uses their default pools and the lifecycle witness proves the surviving infrastructure retains no per-call request or credential. Loopex also refuses `TIDEWAVE_REPL="true"` before it can start ReqLLM's optional listener; a host-started dependency may already have created one, which is a host-owned side effect Loopex cannot undo |
| 3 | A hard VM kill or an unexpected crash of the ephemeral owner itself can leave the temporary root behind; a surviving opaque handle can report `session_unavailable` but cannot prove cleanup or name a root the crashed owner failed to retain | The root is under the host's temporary directory, mode `0700`, and holds no committed session truth because the store is in memory. It can hold the executor receipt ledger, which is committed effect evidence and is why an unproved root is never deleted. Caller exit, ordinary stop and startup failure remain covered by the cleanup-and-report contract. An `ask` command whose unmarked owner crashes and therefore cannot obtain a public cleanup proof emits no JSON and exits with status 1, even if it had already observed the run |
| 4 | A durable model must name a provider the single `LOOPEX_PROVIDER_API_KEY` serves, needs the built companion, and cannot be a local Ollama model | Per-provider durable credentials belong to the M7 draft's configuration decision |
| 5 | `ask` offers no deferring policy; a deferred interaction is an API matter | Answering needs a client that holds the question; the app server and an embedding host are those clients |
| 6 | The JSON result carries no usage or model identity | They are not public events; adding them is a protocol decision |
| 7 | An ephemeral session's memory grows with its history, bounded per run but not across runs | Ephemeral sessions are meant to be short; stopping the session releases it |
| 8 | A stop whose cleanup cannot be proved, or whose recursive root removal fails, keeps an owned temporary root for the host to remove after its users end. A lost exclusive-mkdir result instead names a possible path with unknown ownership and authorizes no deletion | Deleting an owned root while an effect or per-session process may still use it would be worse; deleting an unknown path could destroy pre-existing host data. Any known path, ownership and pending obligation are named in the error. A later stop retries only an owned unproved session-subtree stop or root removal; an unknown claim, unproved run ending, effect cleanup or process-group proof remains conservative for that session's lifetime |
| 9 | Rolling a durable root back to `0.2` fails a not-yet-dispatched call to an M6-only tool as `unknown_tool`, withholds all skill context of a session with a user skill under `0.2`'s daemon, and `0.2`'s released CLI/daemon cannot discover a new external user skill | Stated and proved by the `rollback` lane; the call's effect never ran |
| 10 | The adapter refuses to run while the host sets any `:req` default options; model calls use HTTP/1 only | Default options reach every request; a host that needs them composes the durable profile. Finch's multiplexed HTTP/2 pool can resend below Req's control, and HTTP/2 negotiated on its HTTP/1 pool fails requests above the initial flow-control window; HTTP/2 waits for a transport that removes both limits |
| 11 | A model's reply arrives whole in the ephemeral profile, with no streamed progress, and each call starts and tears down a new tagged pool while its checked-out transport may drain asynchronously | Progress is transient and never session truth; the per-call pool prevents cross-call connection or TLS-session reuse, at the cost of one handshake per HTTPS call. Shared `Req.Finch` registry infrastructure persists but holds no per-call request, connection or credential after owned cleanup; the socket and OTP TLS controller are outside that infrastructure and are covered by limitation 1; the durable companion keeps streaming |
| 12 | The daemon is unchanged, so a durable session with a user skill resumed through it cannot match the admitted snapshot and has all of its skill context withheld, project skills included | Named skill directories in daemon-owned sessions belong to the M7 draft's saved configuration; the offline `loopex resume` reloads them |
| 13 | The reply value check detects the exact resolved credential value, not an encoded, fragmented or otherwise transformed derivative a provider invents; same-VM host code can deliberately tamper with global registry or configuration after a guard | Exact known-value exclusion is testable without treating arbitrary output as secret by resemblance; a host needing a stronger structural boundary uses the durable profile, and trusted host interference is outside an in-VM library's protection |
| 14 | A host-started Req/Finch may have opened an `SSLKEYLOGFILE` destination before composition | Loopex cannot undo a host side effect. Model calls never use the shared default pool; composition and each call refuse while the variable is set; when Loopex starts Req/Finch itself the guard runs first; and the witness distinguishes fresh-VM non-creation from no new open or append by the call-owned pool |
| 15 | The in-process adapter refuses a provider response body over 8 MiB and any content-encoded response; the body ceiling does not bound response headers | The internal bounded collector halts HTTP/1 before retaining more body bytes, and identity encoding avoids an unbounded decompression stage. Locked Finch/Mint accumulate response headers before the collector (`finch/http1/conn.ex:374-377`); the adapter supplies no response-header allocation bound. The deadline limits elapsed time, not that allocation. Hosted model replies are expected to be far smaller; a host needing a different transport contract uses the durable companion or a later adapter decision |
| 16 | Hosted and local ephemeral tools may run while supported host credentials are set; a deliberately authorized tool can copy a key into ordinary content | Same-VM trusted tools are not a secret-isolation boundary. This scoped exposure is Concept-visible and accepted separately with ADR0039. Provider configuration/injection keeps references; deliberate tool content follows ordinary provenance/policy/context bounds |
| 17 | Unproved cleanup seals only that session's lifecycle; genuinely shared ReqLLM/application infrastructure can still be unavailable | Later stop may retry safe proof and new sessions remain eligible. Bounded shared-initialization waiters fail during a real outage and may succeed once it resolves. No permanent VM lockout, lease mode or deliberate peer termination |
| 19 | `ask` can perform an orderly first-interrupt stop only after it has an ephemeral session handle. The launcher latches and forwards signals received before child PID assignment, then preserves the reaped platform child status without a Loopex cleanup or result promise. Inside the child, ask mode is installed before session startup and holds a first signal while its handler remains alive; if a handle returns before an escape it can be stopped; before that handle exists it still promises no cleanup or result. A second handled signal or the fixed 10,000 ms backstop may hard-kill the VM before the public stop's 12,000 ms outer bound and leave a temporary root without output | Before the opaque handle exists the command has no public stop target. The launcher latch closes its separate lost-signal window without inventing a portable status, while the installed handler closes the post-installation handle gap. Repeated interrupt remains the operator's immediate escape hatch. The real-signal witness distinguishes pre-child, pre-handle, orderly and hard-kill paths |
| 20 | The local executor's pathname checks, including the read-only walker, do not pin directory handles and cannot guarantee workspace confinement against a concurrent same-user filesystem swap or mutable mount | Erlang's `:file` API exposes neither `openat` nor `O_NOFOLLOW`. Lexical checks, parent realpaths, `lstat` and post-open identity checks refuse ordinary escapes and type replacements but do not create an OS sandbox; a host needing that boundary uses an isolated hand or otherwise controls workspace mutation |
| 21 | The read-only walker materializes the complete entry-name list for one directory before sorting it and applying traversal caps | Erlang's `:file.list_dir_all/1` has no streaming iterator. The walker avoids materializing the whole tree and bounds all work after each directory enumeration, but a host must not treat the 10,000-entry or 8 MiB path cap as protection from the allocation or time cost of one exceptionally large directory |
| 22 | After `ask/3` or `answer/3` returns a timeout, a later command or attachment failure in the sole-owner background drain cannot deliver a second no-ending snapshot | No API caller is then waiting and the opaque handle retains only its lifecycle cell. The earlier timeout remains the public observation; the owner cancels the drain, performs cleanup, emits any retained root and pending obligations only to the host logger, exits unmarked, and later handle calls return bare `session_unavailable`. Because standalone `ask` suppresses the logger, that command can leave this retained root unnamed |
| 23 | Killed helpers may outlive bounded returns until scheduled; queued supervisor starts may later materialize undisclosed start-blocked candidates | No begin means no session inputs or root authority. Disclosed missing process proofs seal the affected session and retain monitors; no replacement phase starts before predecessor DOWN. Authority-free bootstrap may finish shared OTP init after refusal; existing handles never create replacement sessions. Core's retained-but-unregistered provider interval can settle before candidate DOWN but grants no input/authority; managed registration restores strict cleanup proof. A detached durable FollowReader has no output route and cannot consume the accepted durable cursor |
| 24 | Locked ReqLLM's buffered provider builders can generate a replacement for a missing tool-call id, normalize missing, nil, empty or unsupported arguments to `{}`, force the function type, omit a malformed call and remove earlier error metadata before Loopex's shared mapper | The mapper cannot reconstruct erased provider-wire facts. It rejects malformed binary arguments, invalid fields and provider-executed or provider-native classifications that remain visible. An omitted call executes nothing; a normalized `{}` still crosses core tool resolution, schema validation and host policy. Requiring raw-provider validation would add a provider-specific response parser beside ReqLLM and is outside this minimal adapter milestone |
| 25 | After an ordinary ephemeral `ask` worker sends a provisional result, failure to prove that exact worker `DOWN` through the 1,000 ms kill-and-reap protocol hard-halts the command with status 1 and promises neither output nor cleanup | Rendering or entering stop while an unproved worker can still use the handle would admit two owners of command progress. BEAM scheduling cannot make `DOWN` synchronous; the hard halt is a bounded fail-closed terminal path, exercised independently from the interrupt status-130 path |
| 26 | An unproved child in pre-claim candidate preparation can leave `cleanup_unproved.root` as `nil` because no path has been reported to the owner | Candidate preparation makes no directory, and the child cannot call `TempRoot.claim/1` without an owner grant. The session seals with only `session_subtree` pending and no ending. Neither the host nor the command may treat `nil` as cleanup proof or delete a guessed path. A later path-preallocation design can remove this exception only with new ownership and fault evidence |
