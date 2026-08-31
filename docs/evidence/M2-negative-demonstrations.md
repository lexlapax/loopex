# M2 Negative Demonstrations

Eight safeguards, disabled one at a time, each with the locked selector failure
it caused and the exact digest of the artifact restored afterwards.

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
shape, its locked pairs, and that `restored_sha256` equals this revision's
SHA-256 of the artifact, which is what makes "restored" a claim about bytes
rather than prose.

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

`restored_sha256` is the running revision's SHA-256 of the artifact, which is
what makes "restored" a claim about bytes rather than prose. Every digest above
matches this revision.

All eight name one candidate, `2a8d752`, and were taken against its exact bytes.
Running them at one candidate is not a formality: evidence assembled from
several moments cannot be read as one account of one revision.

The records ran one at a time across two disposable detached clones. The source
tree was verified clean before each mutation and after its exact restore, each
restored artifact was recompiled before the next mutation, and both clones were
verified clean at the end. No mutation could leak into another record.

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

Every one of the eight mutations failed its selector, for the reason its
mechanism predicts. A mutation leaving its selector green would mean the named
mechanism is not what carries the behaviour, which is the finding these records
exist to make possible; none occurred.

`restored_sha256` is the running revision's SHA-256 of the artifact, which is
what makes "restored" a claim about bytes rather than prose. Every digest above
matches this revision.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended real-provider run.
- [M1 negative demonstrations](M1-negative-demonstrations.md) — the closed milestone's equivalent record.
- [Evidence index](README.md).
