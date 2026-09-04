# M3 Gate

Executable acceptance for `M3`. These canonical UTF-8/LF bytes and their SHA-256
are mutable while `M3` is Open and become immutable for the milestone when the
plan pair and gate are explicitly accepted. Progress rows and retained evidence
may then change only in conformance with that lock.

The one ordinary gate command is:

```text
bash scripts/check-m3-gate.sh
```

This gate protects a milestone with no new operator surface, so it cannot open
by driving one. It opens instead on the three questions the milestone exists to
answer, in the order that puts the cheapest decisive observation first: does the
repository run a closed gate at all, does any accepted gate lock the regressions
the post-closure override sets produced, and does the admission path resolve the
required-only lower bound ADR 0017 evaluation step 5 requires. None of the three
can be satisfied by creating a file, which is the property that makes them worth
running before any selector is inspected.

Independent review still judges what no probe can. Whether each of the
seventy-nine inherited cases still asserts what its name promises after the
product changed underneath it, whether the Outcome 7 mutation records attack the
assertion rather than a neighbouring one, whether the deferred-read redesign
preserves publication ordering rather than merely moving the read, and whether
the retention bound defines a settled-past attempt soundly, are all review
judgments this runner does not claim to make.

This gate is neither `M1` nor `M2`. It runs plain `bash`, builds no sealed
environment, launches no environment launcher, and defines **no credential lane
of its own**: it refuses `LOOPEX_PROVIDER_API_KEY` outright, because a gate that
proves no provider behaviour has no reason to hold a key. Where `M3` needs a
real-provider result it invokes the inherited `M2` gate, which owns that lane
and its bounded frame unchanged.

<a id="amendment-transaction-v1"></a>

Any amendment to this gate after acceptance follows the generic two-revision
proposal and rebind transaction: proposal `A` advances the generation while
retaining the prior Acceptance row and lifecycle state, and its immediate
one-parent child `R` rebinds Acceptance to exact `A` and adds one new
disposition anchor. Amendment sections appear below in physical document order
with consecutive numbers. This gate binds `.tool-versions`, so Outcome 8 will
use that transaction once, in sequence behind the three additive generations on
the Closed `M0`, `M1`, and `M2` gates.

## Opening Condition

Before allocating any state, the runner refuses `LOOPEX_PROVIDER_API_KEY` when
it is present in the initial environment, disables automatic export, resolves the
repository root through Git, accepts only the bounded role grammar
`[--inspect | --preflight]`, and verifies every bound artifact below. It then
allocates one isolated evidence root outside both the checkout and the operator
product state and runs the three probes.

### Probe A — the repository runs a closed gate, or a person does

`M2` closed with the rule that existing gates stay green met by a maintainer
waiver and one retained run, because no repository entrypoint enforces it. The
probe therefore asks the repository, not the maintainer.

Green requires all four of:

1. `scripts/check-closed-gates.sh` exists and is executable;
2. its `--list` output equals, as a set, the milestones the canonical register
   records as `Closed` — the runner reads that register itself, so an
   enumeration written down rather than derived fails here;
3. `scripts/check-bootstrap.sh` invokes it; and
4. `apps/loopex/lib/mix/tasks/loopex.gate_invocation.ex` exists, being the
   repository-owned check that fails when a milestone gate omits its one
   mandatory call.

What the probe proves when it is red: nothing in the repository executes a
Closed gate, so every claim that inherited gates are green rests on someone
having run them and said so. What it does not prove: that the aggregate is
correct. Its correctness is the locked
`apps/loopex/test/closed_gate_aggregate_test.exs` role, including the case that
mutates the register and requires the set of executed gates to change with it.

### Probe B — an accepted gate locks the inherited regressions

The case names come from the Inherited Regression Lock table in this document,
so the list has exactly one home and the runner cannot drift from it. Each name
is looked for in the gate document of every milestone the register records as
`Accepted` or `Closed`.

While `M3` is Open its own gate is not one of those documents. That is the
point rather than an accident: an unaccepted gate locks nothing, and this probe
turns green at the moment the maintainer accepts the gate that names these
cases. Locking them is the deliverable of Outcome 1.

What the probe proves when it is red: every regression the three post-closure
override sets produced is protected by the full-suite lane alone, and deleting
any one of them leaves every gate green. What it does not prove: that any of
those cases is honest. That is Outcome 7 and independent review.

### Probe C — the admission path resolves a required-only lower bound

Core is stdlib and OTP only, so the runner compiles it into the isolated
evidence root with no dependency tree, Hex cache, or network, and then asks the
shipped `Loopex.Runtime.ContextAdmission` module for ADR 0017 evaluation step 5.

Green requires `required_only_lower_bound/2` to be exported **and** the module to
refuse a project-bearing candidate that exceeds the record byte ceiling with a
refusal carrying `required_only_record_byte_cost` strictly below `observed`. A
stub returning a constant passes the export check and fails the relation, which
is why both halves are required.

What the probe proves when it is red: the admission path judges exactly the
candidate it is handed, so a byte refusal reports a final cost while the ADR
reads it as a bound. What it does not prove: that step 5 is correct at every
cardinality. The generated property to 1,024 in
`apps/loopex/test/context_admission_test.exs` does that, and this gate locks it.

### When a probe cannot run

A compile failure, a missing toolchain, an unreadable register, an inability to
allocate the isolated evidence root, or a temporary directory that resolves
inside the checkout is **unavailable evidence** and exits 2. Only an observed
shortfall emits the declared red. A retry that turns an exit 2 into a pass is a
diagnostic, never a verdict.

### Roles and isolation

The exact role grammar is ordinary, `--inspect`, or `--preflight`.

- `--inspect` verifies bound artifacts and governance paths without allocating a
  task root, compiling, or writing the checkout. It is the read-only review lane
  and prints only `M3 inspection OK`.
- `--preflight` allocates the isolated evidence root, runs all three probes, and
  stops after `M3 preflight OK`. It is a writable evidence lane.
- ordinary runs the complete gate after the probes turn green.

Every role refuses `LOOPEX_PROVIDER_API_KEY` before doing anything else. The
writable lanes physically resolve the temporary parent, refuse one that resolves
inside the checkout, own `HOME`, `HEX_HOME`, `MIX_HOME`, and `MIX_BUILD_ROOT`
beneath the task root, force Hex offline, and remove the task root on exit,
interruption, or termination.

## Bound Artifacts

| SHA-256 | Path |
| --- | --- |
| `36fa5a17b764638ffea72aa87da4903e1e0f28f6fe5338c7c46a756184dbe6df` | `scripts/check-m3-gate.sh` |
| `cc290e60d9f9588c75f1259b25976a58d1c30713e570cd5a88c70cdf3c2159a0` | `scripts/m1-exunit-runner.exs` |
| `0a8406ca080c70624e776b01e37c7ded210b54659064cf63723a847a54debe2d` | `apps/loopex/test/m1_exunit_runner_test.exs` |
| `fad47299b27a767785d2a6a776155038054f5457ee3ce0195a37ae667f7a9999` | `.tool-versions` |

The gate document externally binds its runner, which `mix loopex.status`
verifies; a runner cannot honestly verify its own bytes before executing them.
The runner verifies every other bound artifact before allocating evidence state.

`scripts/m1-exunit-runner.exs` is bound at exactly the bytes `M1` closed with,
and its adversarial corpus `apps/loopex/test/m1_exunit_runner_test.exs` is bound
with it. `M3` reuses that authoritative channel unchanged. A channel bound
without its corpus would be a digest without a meaning, and the corpus case
`fake stdout at_exit and early halt cannot manufacture one authoritative result`
is why every protected result below can be believed.

`.tool-versions` is bound deliberately, and Outcome 8 must change it. That is not
the contradiction it looks like. A gate that validates a toolchain matrix and
does not bind the file naming that matrix protects nothing, so the binding stays
and the change moves through the governed transaction instead: three
`amendment-transaction-v2` generations on the Closed `M0`, `M1`, and `M2` gates
and one `amendment-transaction-v1` amendment here, run in sequence, every holder
rebound before the last completes, and no revision in that window a closure
candidate.

Three artifacts are deliberately **not** bound, each for the same reason `M2`
gave for leaving the dependency-budget artifacts unbound — binding bytes the
milestone must change would lock a digest acceptance already knows is wrong:

- `apps/loopex/test/gate_isolation_test.exs`, which Outcome 7 changes and which
  the `M2` gate binds; its rebinding is an `amendment-transaction-v2` generation
  on Closed `M2`, with its own acceptance.
- `scripts/check-bootstrap.sh`, which Outcome 5 changes to invoke the aggregate.
- `scripts/check-m0-gate.sh`, which Outcome 6 changes to stop reporting every
  outcome-1 failure as a formatter problem.

Each of the three is instead locked behaviourally: the probes and the locked
selectors below fail if the behaviour those files are supposed to have is
missing, which is the protection a digest would only approximate.

## Repository Commands and Owned State

After every probe turns green, ordinary mode runs in this order:

| # | Command | Protection |
| --- | --- | --- |
| 1 | `mix loopex.status` | Governance, links, exact lifecycle capsule, plan envelopes, ADRs, and bound artifacts |
| 2 | `bash scripts/check-bootstrap.sh` | Portable repository aggregate |
| 3 | `bash scripts/check-closed-gates.sh` | Every `Closed` milestone gate the register names, failing closed on a missing, unreadable, or red one |
| 4 | standalone protected `M3` selectors | Exact roles, names, states, minima, seed, ownership, and dependency closure through the authoritative channel |
| 5 | complete credential-free suite at the gate seed | Unselected regression protection |
| 6 | retained evidence validation | Aggregate execution record, deletion demonstration, generated step-5 evidence, latency and memory observations, mutation records, and the toolchain matrix |

Rows 3 through 6 are what this Open gate does not yet execute. Row 3 waits on
Outcome 5 delivering the aggregate; rows 4 through 6 must be written into the
runner bytes before acceptance, invoking every protected role through the
authoritative standalone channel and validating the complete retained-evidence
manifest. Until then the runner reaches that point only if every probe is green,
which cannot happen at the candidate this gate opens on, and it reports
unavailable evidence rather than a pass. **The accepted bytes may not rely on a
missing lane as their declared red.**

## Authoritative ExUnit Channel

Every protected result below is produced by `scripts/m1-exunit-runner.exs` at its
bound bytes, invoked per selector with an exact role name, seed, and minimum, and
compared against the exact case-name and case-state manifest this document
carries. A selector that reports fewer cases than its minimum, reports a case
this document does not name, skips or excludes a named case, or reports through
any other channel is a red, not a warning.

## Inherited Regression Lock

Every case below exists and passes on the product base this gate opens on. The
deliverable is not making them pass — it is that after acceptance, deleting,
renaming, skipping, or excluding any of them turns this gate red. Minimum counts
are whole-file counts at the opening base, so a case removed from a file that
still contains protected cases is caught by the count as well as by the name.

Nine of these selectors are named by no gate at all today. Nine are named by the
`M2` gate at lower minima that predate the override sets; this gate raises the
minimum to the whole file and adds the case names the override sets brought.

The enumeration is derived, not written: it is every case the range
`6345ded..0509d5d3` added to a test file, plus every case in a file that range
created, taken at `main@0509d5d33fc56d7c91c6bb8320e832c2424d04b8`. That base is
named because it moves. The override sets were still landing on `main` while this
gate was drafted, and each landing changes this table. Before acceptance the
table must be re-derived at the exact candidate the gate is accepted on, and the
review must compare the two derivations rather than trust this one.

| Selector | Minimum | Locked case names |
| --- | --- | --- |
| `apps/loopex/test/audit3_repairs_test.exs` | 6 | `a binding read that outlives the committed deadline refuses the permit`; `a binding read that never answers inside its bound refuses without holding Control`; `a binding read that answers in time still dispatches the permit`; `a superseded coordinator is reaped after supersession kills its terminating model worker`; `a model reserve firing after supersession settles nothing and releases the owner`; `an executor reserve firing after supersession kills no effectful worker` |
| `apps/loopex/test/audit_repairs_test.exs` | 4 | `an attachment installed during an unresolved commit is fenced at the acknowledged position`; `an unacknowledged row is withheld from next_event and released after post commit`; `the item preflight, the builders, and transaction validation agree on every item`; `replaying an unknown command refusal token refuses the record instead of raising` |
| `apps/loopex/test/cancellation_test.exs` | 29 | `a receipt lookup admits exactly the stated answers and reports every other as an error` |
| `apps/loopex/test/provider_attempt_protocol_test.exs` | 39 | `a dispatch binding that is not the canonical attempt identity is refused, not spent`; `a first provider permit is refused unless a committed attempt-open row registers its binding`; `an adapter reply above the item cardinality ceiling is refused without projecting it`; `an adapter reply above the item byte or depth ceiling is refused before it is projected`; `raw reply admission refuses container overhead and keys past the identifier limit`; `a reply measuring exactly the item ceiling is admitted and one byte more is not`; `an adapter-supplied :absent usage member is malformed, not missing`; `admit_bounded agrees with the Store item verdict over random plain data`; `exactly the ADR 0018 settlement combinations validate` |
| `apps/loopex/test/session_lifecycle_test.exs` | 13 | `a completed create replayed into a restarted runtime starts no owner generation` |
| `apps/loopex/test/store_item_budget_test.exs` | 6 | `an oversized scalar binary is measured exactly and refused without an encoded copy`; `the measured cost equals the deterministic encoding for every admitted form` |
| `apps/loopex/test/timer_domain_test.exs` | 7 | `session status answers while the execute-result reserve is open`; `an expired execute-result reserve still settles outcome_unknown`; `a run with a near-uint64 deadline dispatches and finishes normally`; `a deadline outside the unsigned 64-bit domain is refused before it is committed`; `the maximum admitted cleanup period cancels a tool call without a timer_value crash`; `the maximum admitted cleanup period terminates a provider attempt`; `an out-of-domain cleanup period is refused at start and at session creation` |
| `apps/loopex_cli/test/cli_test.exs` | 47 | `resume and cancel reach a session whose finished run left its writer marker behind`; `identifiers from two operating-system processes are two commands to one journal`; `a command re-presented under its own generated identifier still replays`; `run sizes its interrupt backstop from the session's committed cleanup period`; `an interrupt names its abort with an identifier no second virtual machine repeats`; `a second interrupt during an admitted stop is answered, and the owned process group still goes`; `the launcher waits through a second interrupt and reports the escript's own status` |
| `apps/loopex_cli/test/live_store_holder_test.exs` | 1 | `a state root held by a live embedder refuses the command instead of evicting it` |
| `apps/loopex_cli/test/placement_probe_test.exs` | 2 | `a probe that cannot inspect the owner is a failed probe, not absence`; `a lock whose owner cannot be probed is refused, not reclaimed` |
| `apps/loopex_cli/test/prepared_recovery_contract_test.exs` | 19 | `a transferred capability activates through the handler after the preparer dies`; `a holder transfer asked for by a process that is not the holder is refused`; `an interrupt and a handler activation race to exactly one winner`; `resume installs its interrupt handler before it spends the activation` |
| `apps/loopex_composition/test/stale_writer_recovery_test.exs` | 3 | `a writer marker with no identity to check is never broken automatically`; `a marker left by a dead holder is broken and the runtime starts`; `a live runtime on the same state root refuses a recovering opener` |
| `apps/loopex_executor_local/test/executor_test.exs` | 8 | `a receipt lookup for a job this executor still holds answers effect_in_flight` |
| `apps/loopex_executor_local/test/post_closure_hotfix_test.exs` | 16 | `a job still open on the shared root is unconfirmed at an instance that does not own it`; `the committed job period rather than the executor default bounds this job's cleanup`; `a cancellation spends the cancelled job's committed period`; `a peer never reads a confirmed receipt for a job whose settlement ends quarantined`; `a settlement that cannot remove its open record never reports confirmed cleanup`; `open-entry removal spends the settlement's remaining allowance and ends inside it`; `a settlement whose receipt cannot be retained leaves this job's open authority`; `a settlement that cannot take the root claim leaves the open entry and reports it`; `a settlement that removes its open entry ends with a final receipt and no entry`; `a root claim that cannot be released after a raising body reaches the caller`; `a claim released after a raising body re-raises exactly what the body raised`; `every retention phase of one settlement draws on one shared allowance`; `an admission interrupted after its first durable publication is visible to the scan`; `every ledger directory level is created and synced into the parent that names it`; `a root claim that cannot be released reaches the caller instead of the body's answer`; `the accepted maximum cleanup period never reaches a raw VM timer` |
| `apps/loopex_reference_client/test/configured_recovery_contract_test.exs` | 5 | `prepared activation without a retained receipt ends outcome_unknown without redispatch`; `prepared activation over a quarantined root ends outcome_unknown and keeps the quarantine`; `prepared activation leaves an unanswerable receipt lookup to the host` |
| `apps/loopex_store_local/test/artifact_publication_hotfix_test.exs` | 3 | `concurrent uses of one object never contend for a single sidecar name`; `a publisher held at atomic publication replaces only byte-identical bytes`; `publishing the first use durably records every directory entry it creates` |
| `apps/loopex_store_local/test/store_conformance_test.exs` | 6 | `an orderly stop gives the writer marker back and never removes a successor's` |
| `apps/loopex_store_local/test/writer_lock_holder_test.exs` | 8 | `a live holder in this VM refuses a recovering opener and keeps its marker`; `a live holder in another operating-system process refuses a recovering opener`; `a holder killed with SIGKILL leaves a marker its successor recovers`; `a Store killed inside this VM leaves a marker this VM recovers`; `a v1 marker carrying no identity is never recovered automatically`; `a marker whose recorded identifier was reused is recovered despite a live process`; `a probe that cannot inspect the holder keeps the marker held`; `a probe that never answers is bounded and leaves the marker held` |

## Protected Outcome Selectors

Each case below must exist, pass, and run through the authoritative standalone
channel at no less than the stated minimum. The roles marked *new* do not exist
at the opening base; naming a case that does not exist yet is what a gate is for,
and no probe can be turned green by creating one.

| Outcome | Selector | Minimum | Status |
| --- | --- | --- | --- |
| 1 | The eighteen selectors of the Inherited Regression Lock above | as tabled | existing |
| 2 | `apps/loopex/test/context_admission_test.exs` | 26 | existing, extended by the step-5 role |
| 3 | `apps/loopex/test/event_dispatcher_availability_test.exs` | 8 | new |
| 4 | `apps/loopex/test/provider_attempt_protocol_test.exs` | 42 | existing, extended by the retention role |
| 5 | `apps/loopex/test/closed_gate_aggregate_test.exs` | 12 | new |
| 6 | `apps/loopex/test/closed_gate_aggregate_test.exs` | 12 | new, sharing Outcome 5 selector |
| 7 | `apps/loopex/test/gate_isolation_test.exs` | 9 | existing, extended by the scratch-root role |
| 8 | `apps/loopex/test/status_check_test.exs` | 47 | existing, extended by the binding-transaction role |

The Outcome 2 role must include the generated cardinality property to 1,024, the
structural maximal-instance walk, and the replay-equivalence cases that state
which already-journaled byte refusals change meaning and which do not.

The Outcome 5 and 6 role must include the register-mutation case that changes
which gates execute, the missing, unreadable, and red gate cases, the case where
a milestone gate omits its mandatory call, and one negative per distinct `M0`
outcome-1 failure mode including the floor-toolchain-over-current-pair-artifacts
case observed on 2026-08-27.

The Outcome 7 role must include concurrent scratch-root allocation from
simultaneous virtual machines with no collision, and each repaired weakness must
carry a mutation record showing the assertion fails on the pre-repair path.

## Locked Supporting Mechanism Selectors

| Selector | Minimum | Protection |
| --- | --- | --- |
| `apps/loopex/test/deps_budget_test.exs` | 28 | Eight applications unchanged, no new role, no external dependency anywhere, and the dependency direction intact |
| `apps/loopex/test/core_only_test.exs` | 4 | Core stays stdlib and OTP only across every product repair |
| `apps/loopex/test/m1_exunit_runner_test.exs` | accepted `M1` minimum | The authoritative result channel cannot be spoofed |
| `apps/loopex/test/docs_check_test.exs` | 6 | Ordered Concept and Technical depth sections survive every module this milestone edits |

## Deliberately Unlocked Selectors

Outcome 1 exists because a test no gate names can be deleted while every gate
stays green. That argument does not stop at the override sets, so the exact set
of test files this gate leaves unlocked is named here rather than left implicit.
A test file that appears in neither this list nor any gate is a red.

| Selector | Cases | Why it is left to the suite lane |
| --- | --- | --- |
| `apps/loopex/test/bounds_test.exs` | 9 | Unit coverage for a reducer whose behaviour is locked through `apps/loopex/test/agent_loop_test.exs` |
| `apps/loopex/test/conversation_test.exs` | 8 | Unit coverage for the history projection locked through the same loop role |
| `apps/loopex/test/docs_check_test.exs` | 6 | Locked above as a supporting mechanism rather than here |
| `apps/loopex/test/journal_ownership_test.exs` | 7 | Unit coverage for ownership behaviour locked through the M1 journal and fencing roles |
| `apps/loopex/test/tool_call_reader_test.exs` | 11 | Unit coverage for a parser whose behaviour is locked through the M2 loop and tool roles |
| `apps/loopex_llm_reqllm/test/adapter_test.exs` | 4 | Adapter unit coverage locked behaviourally through the M2 streaming conformance role |
| `apps/loopex_llm_reqllm/test/credential_plane_test.exs` | 4 | Locked behaviourally through the M2 credential and provider boundary |
| `apps/loopex_protocol/test/loopex_protocol_test.exs` | 2 | Contract-application unit coverage with no behaviour of its own to protect |

## Mandatory Closure Evidence

Closure requires retained records bound to the exact product candidate SHA, gate
digest, command, seed, toolchain, platform, and limits:

1. the closed-gate aggregate executed against every `Closed` gate, with its
   register-derived enumeration printed and compared;
2. a deletion demonstration on at least three of the seventy-nine inherited
   cases, chosen across three applications, each turning this gate red;
3. the generated ADR 0017 step-5 cardinality evidence with its seed and bound;
4. a multi-session control-latency observation under a held Store transaction,
   before and after the dispatcher change;
5. a Control memory observation across a long provider-attempt sequence, before
   and after the retention bound;
6. one mutation record per repaired frozen weakness and per repaired
   partial-evidence item;
7. the complete toolchain matrix on the raised floor pair and the unchanged
   current pair, Darwin for both and Linux for the current pair; and
8. the four `.tool-versions` transactions and the `M2` isolation-corpus
   generation, each with its acceptance, its proposal and rebind revisions, and
   the checks proved at each.

Credentials, tenant identifiers, and secrets never enter those artifacts. A
missing toolchain lane, an unreadable closed gate, or an environment that cannot
allocate an isolated evidence root is unavailable evidence and blocks closure
rather than becoming a skipped pass. No `M3` evidence record may describe an
offline check as proving a network call occurred.

## Documentation Obligations

| Category | Required closure disposition |
| --- | --- |
| Operator-facing documentation | `docs/operator/how-a-run-works-technical.md` |
| Operator README | `docs/operator/README.md` |
| Developer-facing documentation | `docs/developer/architecture.md`, `docs/developer/architecture-technical.md`, `docs/developer/agent-context-map.md` |
| Developer README | `docs/developer/README.md` |
| Documentation README | `docs/README.md` |
| Root README | `README.md` |
| Changelog | `CHANGELOG.md` |

## Failure Rules and Declared Red

A red required check blocks closure. A retry is diagnostic and never a pass: a
same-SHA, same-seed, same-environment failure that disappears is a blocking
flake until it is fixed or explicitly dispositioned. Nothing may be skipped,
filtered, softened, quarantined, rewritten, retried longer, or replaced by a
fake to make this gate pass.

### Declared Red Condition

Until `M3` delivers what it declares, the runner emits exactly one line:

```text
M3 gate RED: the repository enforces no Closed milestone gate, no accepted gate locks the regressions the post-closure override sets produced, and ADR 0017 evaluation step 5 is absent from the admission path
```

The bounded `LOOPEX_M3_PROBE` observation is appended to that same line. At the
candidate this gate opens on, the expected observation is:

```text
LOOPEX_M3_PROBE aggregate=absent bootstrap_invokes_aggregate=0 invocation_check=absent locked_regressions=0/79 step5=absent
```

Each field is a separate fact and each turns green separately: `aggregate` and
`invocation_check` on Outcome 5, `bootstrap_invokes_aggregate` on the same,
`locked_regressions` at acceptance of this gate, and `step5` on Outcome 2. A run
in which any field is still red is a red run, and a run in which every field is
green but a later locked lane fails is equally red.
