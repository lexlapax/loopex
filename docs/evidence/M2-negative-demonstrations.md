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
{"mechanism_disabled":"committed_history_projection","selector":"apps/loopex/test/agent_loop_test.exs","observed_failure":"project_elements/1 kept only the first committed element, so requests after the first lost the committed assistant/tool-result history; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 49/73 passed, 24 failed, with affected runs commonly stopping after tool.finished and no run.finished within 5000ms","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex/lib/loopex/conversation.ex","restored_sha256":"sha256:1b24ee744f7944e91aa489fcdb49027d588d195bc037a55315fe5091beddc5c0"}
```

## Outcome 2: stream delta reconstruction

```json
{"mechanism_disabled":"stream_delta_reconstruction","selector":"apps/loopex_llm_reqllm/test/streaming_conformance_test.exs","observed_failure":"derive/4 returned the same frozen stream domain c0f3e65d684f89214bb1cf701488545c for every identity, so model/executor domains and retry attempts collided; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 17/22 passed, 5 failed","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex/lib/loopex/stream_domain.ex","restored_sha256":"sha256:bfbd13b3659a9a2b5c5fcc2ccbed95c08038f16e1abe0bda55a505df719ebef4"}
```

## Tool registry: tool definition generation binding

```json
{"mechanism_disabled":"tool_definition_generation_binding","selector":"apps/loopex/test/tool_registry_test.exs","observed_failure":"generation/1 returned loopex.frozen 0.0.0 and one constant digest for every definition, so resolved and staged definitions lost their real identity and changed bytes retained a generation; the bound selector refused (SELECTOR_EXIT=1), and the diagnostic run reported 2/5 passed, 3 failed","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex_protocol/lib/loopex_protocol/tool_definition.ex","restored_sha256":"sha256:08a9c7b347c4b5f4774e1bc20b7db08eaeb7b29ec7f242a09882ded07696e2e5"}
```

## Outcome 4: workspace path scope containment

```json
{"mechanism_disabled":"workspace_path_scope_containment","selector":"apps/loopex_executor_local/test/coding_tools_test.exs","observed_failure":"containment always returned true, so a loopex.read of a traversal path completed instead of refusing and returned the outside file bytes \"not yours\"; the gate-bound selector refused, and the diagnostic run failed exactly 1 of 42 cases: every filesystem tool refuses a path that escapes the workspace root through traversal or a symlink","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex_executor_local/lib/coding_tools.ex","restored_sha256":"sha256:d347179f2f9a706cc1e5e4612912080663fd05a1b27492dd56c86e266810c7bf"}
```

## Outcome 6: host policy deny pre-start refusal

```json
{"mechanism_disabled":"host_policy_deny_prestart_refusal","selector":"apps/loopex_executor_local/test/host_policy_test.exs","observed_failure":"the policy boundary converted timeout or crash rescue and catch paths to {:allow, nil}; a raising policy therefore returned {:allow, nil} instead of {:deny, :policy_unavailable}; the gate-bound selector refused, and the diagnostic run failed exactly 1 of 9 cases: a policy that raises times out or returns a malformed value fails closed into denial","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex/lib/loopex/policy.ex","restored_sha256":"sha256:e2c850a06d89151e62fd7f53bf6da9e812926730904ab730bea75ecca98bcfe0"}
```

## Outcome 7: project resource trust admission

```json
{"mechanism_disabled":"project_resource_trust_admission","selector":"apps/loopex/test/project_resource_trust_test.exs","observed_failure":"resolution admitted the manifest for any map and substituted an empty map when no decision existed, so changed content returned :staged instead of :binding_changed and a headless run without a positive decision staged its project block instead of withholding it; the gate-bound selector refused, and the diagnostic run failed exactly 2 of 9 cases: a changed workspace revision manifest or content invalidates the decision, and a headless run without a matching positive decision stages no project block journals a declined receipt and still runs","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex/lib/loopex/project_resource.ex","restored_sha256":"sha256:d93e2fdd6cf10467e3d36ebdff62aed988d1493d9300ada3dffee1b2a302c0b9"}
```

## Outcome 8: cancellation cleanup confirmation

```json
{"mechanism_disabled":"cancellation_cleanup_confirmation","selector":"apps/loopex/test/cancellation_test.exs","observed_failure":"forcing every aborting run terminal to cancelled overwrote ten unproven-effect outcomes: recovery without a dispatched effect, unconfirmed process-tree cleanup, executor cancellation error, unreadable cancellation, nonreturning host cancellation, an executor that never answered, an unprovable receipt settling during abort, recovery after an abandoned call, succession with a predecessor unproved effect, and the basic insufficient-evidence path all reported cancelled instead of outcome_unknown","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex/lib/loopex/runtime/session_state.ex","restored_sha256":"sha256:cc8120f907afd78bb3eb15f43376cf11d26e54c06cf90f1d2260b2b3561e80ef"}
```

## Outcome 10: command surface facade only

```json
{"mechanism_disabled":"command_surface_facade_only","selector":"apps/loopex_cli/test/cli_test.exs","observed_failure":"the artifact subcommand read through Loopex.Store.Local.Artifacts instead of the port: the locked facade case found the concrete adapter name, and the locked retrieval case raised FunctionClauseError because the composition returned a port wrapper rather than the concrete handle the bypass expected","candidate":"2c6b3a1367d699f71bf127abfc2668033c60392d","artifact":"apps/loopex_cli/lib/loopex_cli.ex","restored_sha256":"sha256:beaf3a354bf94cbf4f21b6077233864ca6d48e6866dbce6148a27e65b3981564"}
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

All eight name one candidate, `2c6b3a1`, and were taken against its exact bytes.
Running them at one candidate is not a formality: evidence assembled from
several moments cannot be read as one account of one revision.

Every record ran in its own disposable detached clone. The source tree was
verified clean before its mutation and after its exact restore, and each clone
was verified clean before deletion. No mutation could leak into another record.

They have been re-taken whenever milestone repairs changed a bound artifact,
including again at `2c6b3a1`. An earlier version of this record argued they did
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
