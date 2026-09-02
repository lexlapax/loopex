# M2 Negative Demonstrations

Thirteen safeguards, disabled one at a time, each with the locked selector
failure it caused and the exact digest of the artifact restored afterwards.

A test that passes proves the behaviour is present. It does not prove the
mechanism the behaviour is credited to is the one carrying it. These records
close that gap: each starts from its own named clean candidate, disables exactly
one mechanism, runs the named selector which must fail for the named reason,
restores the artifact from `git show <candidate>:<path>`, and verifies whole-tree
cleanliness before the next record.

No record stands in for two mechanisms, and a failure observed from a dirty or
previously mutated baseline is no evidence. Whether one clean-baseline mechanism
was disabled, whether it caused the named failure, and whether the whole tree was
clean between records are review obligations; the runner checks the record's
shape, its locked pairs, and that `restored_sha256` equals the SHA-256 of the
artifact at the candidate that record names, which is what makes "restored" a
claim about bytes rather than prose.

The eighth record covers the milestone's headline structural claim. Introducing
a client application is exactly when "session before surface" is most at risk, so
the mechanism that fails a build where a second module reaches past the facade
carries its own mutation record rather than resting on source inspection.

## Outcome 1: committed history projection

```json
{"mechanism_disabled":"committed_history_projection","selector":"apps/loopex/test/agent_loop_test.exs","observed_failure":"project_elements/1 kept only the first committed element, so requests after the first lost committed assistant and tool-result history; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 62/92 passed and 30 failed, commonly stopping after tool.finished with no run.finished within 5000ms","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex/lib/loopex/conversation.ex","restored_sha256":"sha256:1b24ee744f7944e91aa489fcdb49027d588d195bc037a55315fe5091beddc5c0"}
```

## Outcome 2: stream delta reconstruction

```json
{"mechanism_disabled":"stream_delta_reconstruction","selector":"apps/loopex_llm_reqllm/test/streaming_conformance_test.exs","observed_failure":"derive/4 returned one fixed zero stream domain for every identity, so model and executor domains and retry attempts collided; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 18/23 passed and 5 failed across domain separation, injectivity, cancellation, provider retry, and executor retry","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex/lib/loopex/stream_domain.ex","restored_sha256":"sha256:bfbd13b3659a9a2b5c5fcc2ccbed95c08038f16e1abe0bda55a505df719ebef4"}
```

## Tool registry: tool definition generation binding

```json
{"mechanism_disabled":"tool_definition_generation_binding","selector":"apps/loopex/test/tool_registry_test.exs","observed_failure":"generation/1 returned loopex.frozen 0.0.0 and one zero digest for every definition, so resolved and staged definitions lost their real identity and changed bytes retained a generation; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 2/5 passed and 3 failed in runtime-scoped resolution, independent registries, and the staged generation","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex_protocol/lib/loopex_protocol/tool_definition.ex","restored_sha256":"sha256:a219a9d0a95441691fe3c0199c79586016ec066e1b94491438c07a5e77a6d0c1"}
```

## Outcome 4: workspace path scope containment

```json
{"mechanism_disabled":"workspace_path_scope_containment","selector":"apps/loopex_executor_local/test/coding_tools_test.exs","observed_failure":"containment always returned true, so a loopex.read of a traversal path completed instead of refusing and returned the outside file bytes \"not yours\"; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 45/46 passed and 1 failed: every filesystem tool refuses a path that escapes the workspace root through traversal or a symlink","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex_executor_local/lib/coding_tools.ex","restored_sha256":"sha256:d347179f2f9a706cc1e5e4612912080663fd05a1b27492dd56c86e266810c7bf"}
```

## Outcome 6: host policy deny pre-start refusal

```json
{"mechanism_disabled":"host_policy_deny_prestart_refusal","selector":"apps/loopex_executor_local/test/host_policy_test.exs","observed_failure":"the policy boundary converted invalid-module, crash, timeout, malformed-return, rescue, and catch paths to {:allow, nil}; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 7/9 passed and 2 failed because unavailable policies and an unpublished denial category were admitted instead of failing closed","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex/lib/loopex/policy.ex","restored_sha256":"sha256:36f5e3ea4929b530570e23a0780c74cd2b5bd52c7beb3613b3038f03b8407aea"}
```

## Outcome 7: project resource trust admission

```json
{"mechanism_disabled":"project_resource_trust_admission","selector":"apps/loopex/test/project_resource_trust_test.exs","observed_failure":"resolution treated an absent or unrecognised trust decision as admission, so a headless run without a positive decision staged its AGENTS.md project block instead of withholding it; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 8/9 passed and 1 failed: a headless run without a matching positive decision stages no project block journals a declined receipt and still runs","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex/lib/loopex/project_resource.ex","restored_sha256":"sha256:d93e2fdd6cf10467e3d36ebdff62aed988d1493d9300ada3dffee1b2a302c0b9"}
```

## Outcome 8: cancellation cleanup confirmation

```json
{"mechanism_disabled":"cancellation_cleanup_confirmation","selector":"apps/loopex/test/cancellation_test.exs","observed_failure":"forcing only an aborting run terminal to cancelled overwrote ten unproven cleanup and effect outcomes; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 15/25 passed and 10 failed, including the locked case where unconfirmed process-tree cleanup returned cancelled instead of outcome_unknown","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex/lib/loopex/runtime/session_state.ex","restored_sha256":"sha256:06bfc067423124c6b0812b32362956e22c288098418797924d87e566b863f367"}
```

## Outcome 10: command surface facade only

```json
{"mechanism_disabled":"command_surface_facade_only","selector":"apps/loopex_cli/test/cli_test.exs","observed_failure":"the artifact subcommand read through Loopex.Store.Local.Artifacts instead of the public port, so the command source named a concrete implementation; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 23/24 passed and 1 failed: the command surface drives only the public facade and owns no loop store cursor or authority","candidate":"2a8d75232e3293f47992da11be2dacd14c6a8bf4","artifact":"apps/loopex_cli/lib/loopex_cli.ex","restored_sha256":"sha256:224f97532bd02c11c7aff79f4f19e3deb3a875dce33968d85a2a3a72d8083d01"}
```

## Artifact object and use boundary: use object binding

```json
{"mechanism_disabled":"artifact_use_object_binding","selector":"apps/loopex_store_local/test/artifact_store_conformance_test.exs","observed_failure":"validate_described_use/2 stopped comparing the described record against the reference object triple, keeping only the canonicalization version, media type, role and use digest, so a reference whose object locator had been substituted resolved another object's provenance instead of refusing; the diagnostic run reported 23/24 passed and 1 failed: locator only stat and object fetch never reconstruct or accept use provenance, where describe returned an ok use record for the substituted reference and the case requires an error","candidate":"5bef36369f605e6366f363e49c1d60d8d37c1e54","artifact":"apps/loopex/lib/loopex/artifact_store.ex","restored_sha256":"sha256:e890cf96aba0ef8aae8863f029726c913e8c3a3cbc9b506493733fd8ee3d9e48"}
```

The bound selector refused this mutation: `SELECTOR_EXIT=1`,
`M1 selector runner refused: selector failed`, and no authoritative
`LOOPEX_EXUNIT_REPORT` line. The record's `observed_failure` names the
reason, which comes from the diagnostic companion.

## Outcome 4: local whole-root replacement refusal

```json
{"mechanism_disabled":"local_whole_root_replacement_refusal","selector":"apps/loopex_executor_local/test/local_authority_contract_test.exs","observed_failure":"root_binding/1 hashed only the expanded root path and dropped the directory's device and inode, so a root retired and replaced by a fresh directory at the same path still matched its recorded binding; the diagnostic run reported 19/21 passed and 2 failed: a prepared Local root binds one exact canonical generation before returning, where the recorded root_binding no longer equalled the independently recomputed path device and inode digest, and same-path directory replacement and an isolated generation copy both refuse, where the replacement root returned a prepared authority instead of a refusal","candidate":"5bef36369f605e6366f363e49c1d60d8d37c1e54","artifact":"apps/loopex_executor_local/lib/ledger.ex","restored_sha256":"sha256:791e2d4696cd2b7ec03efc64b7b09d8af2ed59502c74ae055ed7f8399e7f6fd9"}
```

The bound selector refused this mutation: `SELECTOR_EXIT=1`,
`M1 selector runner refused: selector failed`, and no authoritative
`LOOPEX_EXUNIT_REPORT` line. The record's `observed_failure` names the
reason, which comes from the diagnostic companion.

## Outcome 4: local generation copy refusal

```json
{"mechanism_disabled":"local_generation_copy_refusal","selector":"apps/loopex_executor_local/test/local_authority_contract_test.exs","observed_failure":"validate_generation/3 stopped comparing the generation record's recorded root_binding with the binding observed for the root being prepared, so a generation file that belongs to another root -- an isolated copy -- was accepted as this root's own authority; the diagnostic run reported 19/21 passed and 2 failed: same-path directory replacement and an isolated generation copy both refuse, and generation validation rejects extra keys broken relations symlinks and oversized bytes at its root_relation case, where a generation naming a foreign root binding prepared successfully instead of refusing","candidate":"5bef36369f605e6366f363e49c1d60d8d37c1e54","artifact":"apps/loopex_executor_local/lib/ledger.ex","restored_sha256":"sha256:791e2d4696cd2b7ec03efc64b7b09d8af2ed59502c74ae055ed7f8399e7f6fd9"}
```

The bound selector refused this mutation: `SELECTOR_EXIT=1`,
`M1 selector runner refused: selector failed`, and no authoritative
`LOOPEX_EXUNIT_REPORT` line. The record's `observed_failure` names the
reason, which comes from the diagnostic companion.

## Context admission: model projection accounting

```json
{"mechanism_disabled":"context_model_projection_accounting","selector":"apps/loopex/test/context_admission_test.exs","observed_failure":"model_facing/1 projected only the tool name, so the one projection that both the receipt producer and its independent validator charge stopped carrying the description and parameter schema and the tool descriptors were charged 432 provider bytes instead of 2393; the diagnostic run reported 17/20 passed and 3 failed: the named reference fixture binds exact context definition-list retained-component and receipt fixed point measured 432 against its locked 2393, a system class refusal beside a staged project retains the required-only estimate saw the fixture model receive a request where the locked case requires none, and context refusal promotion and recovery preserve the predecessor budget into its successor observed no context_admission_refused_v1 record because the under-charged request was admitted","candidate":"5bef36369f605e6366f363e49c1d60d8d37c1e54","artifact":"apps/loopex_protocol/lib/loopex_protocol/tool_definition.ex","restored_sha256":"sha256:a219a9d0a95441691fe3c0199c79586016ec066e1b94491438c07a5e77a6d0c1"}
```

The bound selector refused this mutation: `SELECTOR_EXIT=1`,
`M1 selector runner refused: selector failed`, and no authoritative
`LOOPEX_EXUNIT_REPORT` line. The record's `observed_failure` names the
reason, which comes from the diagnostic companion.

## Provider attempt authority: one-use permit

```json
{"mechanism_disabled":"provider_attempt_one_use_permit","selector":"apps/loopex/test/provider_attempt_protocol_test.exs","observed_failure":"the provider_dispatch permit send no longer recorded the attempt binding in Control's spent_attempts, so the identity it had just permitted stayed unspent and a second permit request for that exact session run turn operation attempt and staged request digest would be granted; the diagnostic run reported 28/29 passed and 1 failed: a spent attempt identity is the exact attempt binding and outlives the owner that spent it, where the retained spent bindings read as the empty list instead of the single binding of the attempt that had already invoked the provider","candidate":"5bef36369f605e6366f363e49c1d60d8d37c1e54","artifact":"apps/loopex/lib/loopex/runtime/control.ex","restored_sha256":"sha256:6fdd591e5f381f384a9283616279023579f052c0eddd2f10b8217a2f62a1fe40"}
```

The bound selector refused this mutation: `SELECTOR_EXIT=1`,
`M1 selector runner refused: selector failed`, and no authoritative
`LOOPEX_EXUNIT_REPORT` line. The record's `observed_failure` names the
reason, which comes from the diagnostic companion.

## How these were produced

Each experiment ran in a local clone of the candidate, checked out detached, with
the source tree verified clean before the mutation and again after the artifact
was restored from `git show <candidate>:<path>`. No experiment ran from a dirty
or previously mutated baseline: a clean-tree check refuses before the mutation is
applied.

The records themselves carry six fields and cleanliness is not among them. The
gate says so — whether one mechanism was disabled, whether it caused the named
failure, and whether the tree was clean between records are review obligations,
not record contents. What is written above is the operator's account of how the
experiments were run, and a reviewer weighs it as that rather than as something
the records demonstrate.

Each selector ran the way the gate runs it — compiled on its own from the
repository root, with the application's test helper absent — so the failure each
record names is the failure the gate would observe.

`restored_sha256` is the SHA-256 of the artifact at the candidate its own record
names, which is what makes "restored" a claim about bytes rather than prose.
Every digest above matches the candidate beside it.

The first eight name one candidate, `2a8d752`, and were taken against its exact
bytes. The five added by Amendment 4 name one later candidate, `5bef363`, and
were taken against its exact bytes. Running each set at one candidate is not a
formality: evidence assembled from several moments cannot be read as one account
of one revision.

The first eight ran one at a time across two disposable detached clones. The
source tree was verified clean before each mutation and after its exact restore,
each restored artifact was recompiled before the next mutation, and both clones
were verified clean at the end. The five added records ran the same way in a
third disposable detached worktree at `5bef363`, one at a time, with
`git status --porcelain` empty before every mutation and again after every
`git checkout --` restore. No mutation could leak into another record.

They have been re-taken whenever milestone repairs changed a bound artifact,
including again at `2a8d752`. An earlier version of this record argued they did
not need re-taking because every artifact was then byte-identical to the
candidate named by the record and the gate accepts an ancestor. That stopped
being true when later repairs changed those artifacts. A stale digest here is
not cosmetic: the gate validates these records before it reaches the retained
matrix and before it will emit a capture, so evidence naming bytes that no
longer exist blocks the milestone.

The `cancellation_cleanup_confirmation` mutation carries one historical change
worth retaining. It originally disabled a single abort-outcome clause. That
decision now routes through one shared reading of ADR 0009's precedence table,
also used by deadline and bound paths, so mutating the shared decision would
disable more than the mechanism this record names. The current mutation makes
only an aborting run return `cancelled` unconditionally, which is what "the abort
stops confirming cleanup" means in the current code, and leaves non-abort
terminal paths intact.

Each selector ran the way the gate runs it, through the bound `M1` runner with
the minimum, policy and locked names lifted from `scripts/check-m2-gate.sh`, so
the failure each record names is the failure the gate would observe. That runner
reports a verdict and not a reason -- it prints `selector failed` and names no
case -- so each mutation was also run against the same isolated compiled tree
under an ordinary formatter to see which cases failed and on what assertion. The
verdict comes from the gate's own path; the prose comes from the diagnostic
companion, and neither stands in for the other.

The five records added by Amendment 4 carry the same two channels, placed
differently. Their `observed_failure` fields hold only the diagnostic reason,
because those bytes were fixed before the runner was driven; the bound
verdict is stated in the companion line beside each record instead. Each of
the five was driven through the same bound `scripts/m1-exunit-runner.exs`
the M2 gate's `run_selector` drives, with the same nonce frame on standard
input, the same owner, internal and allowed application context taken from
`mix loopex.deps_budget --context`, and the exact minimum, exclusion policy
and locked case names its own bound `run_selector` invocation carries, at
seed 0. The runner ran against a compiled closure in an owned task root
outside the checkout, with `LOOPEX_HOME`, `TMPDIR` and `MIX_BUILD_ROOT`
under it, so no locked command wrote into the checkout's own build tree.
Each selector was proved green through that runner at `5bef363` before its
mutation, `MIX_ENV=test mix compile --warnings-as-errors` returned zero for
every mutant, so no refusal came from a build that did not compile, and the
closure was recompiled after every restore. The gate itself draws a random
seed; seed 0 is what these five were driven at, and that is the only
difference between this channel and the one the gate would run.

Every one of the thirteen mutations failed its selector, for the reason its
mechanism predicts. A mutation leaving its selector green would mean the named
mechanism is not what carries the behaviour, which is the finding these records
exist to make possible; none occurred.

`restored_sha256` is the SHA-256 of the artifact at the candidate its own record
names, which is what makes "restored" a claim about bytes rather than prose.
Every digest above matches the candidate beside it.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended real-provider run.
- [M1 negative demonstrations](M1-negative-demonstrations.md) — the closed milestone's equivalent record.
- [Evidence index](README.md).
