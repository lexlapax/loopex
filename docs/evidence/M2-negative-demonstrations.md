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
{"mechanism_disabled":"committed_history_projection","selector":"apps/loopex/test/agent_loop_test.exs","observed_failure":"the projection kept only the first committed element, so no request after the first carried the assistant tool call or its result; the run stalled after tool.finished, the session coordinator terminated and no run.finished was ever committed, and thirteen cases failed on a drained run that timed out at 5000ms, eight of them locked including history replay, canonical replay after the first turn, every turn bound, and the loop continuing while the model asks for tools","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex/lib/loopex/conversation.ex","restored_sha256":"sha256:1b24ee744f7944e91aa489fcdb49027d588d195bc037a55315fe5091beddc5c0"}
```

## Outcome 2: stream delta reconstruction

```json
{"mechanism_disabled":"stream_delta_reconstruction","selector":"apps/loopex_llm_reqllm/test/streaming_conformance_test.exs","observed_failure":"every attempt derived one frozen stream domain id, so the model and executor domains under one turn were the same label c0f3e65d684f89214bb1cf701488545c and four sampled distinct identities collapsed to one; five locked cases failed including separate sequences per domain, provider retry domain separation, retried executor attempt domains, injective identity encoding, and the cancelled stream case","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex/lib/loopex/stream_domain.ex","restored_sha256":"sha256:7a5b964e1ce62c7a561fa7662a19c9930c718864e1f486f40e37ee4adf35a70a"}
```

## Tool registry: tool definition generation binding

```json
{"mechanism_disabled":"tool_definition_generation_binding","selector":"apps/loopex/test/tool_registry_test.exs","observed_failure":"generation returned one frozen triple for every definition, so a resolve still succeeded but handed back loopex.frozen 0.0.0 and a constant digest beside the real definition bytes, and a changed definition kept its generation; three locked cases failed including the recorded generation, the runtime-scoped resolve and unknown id refusal, and the independent per-runtime registries","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex_protocol/lib/loopex_protocol/tool_definition.ex","restored_sha256":"sha256:08a9c7b347c4b5f4774e1bc20b7db08eaeb7b29ec7f242a09882ded07696e2e5"}
```

## Outcome 4: workspace path scope containment

```json
{"mechanism_disabled":"workspace_path_scope_containment","selector":"apps/loopex_executor_local/test/coding_tools_test.exs","observed_failure":"containment compared nothing, so every resolved path was treated as inside the workspace and a loopex.read of a traversal path completed instead of failing and returned the contents of a file outside the workspace root, and the locked containment case failed","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex_executor_local/lib/coding_tools.ex","restored_sha256":"sha256:b844fcd9ca0a29d0c1603f83b8842c6e5845f799ba5a350d127bcecbda32415c"}
```

## Outcome 6: host policy deny pre-start refusal

```json
{"mechanism_disabled":"host_policy_deny_prestart_refusal","selector":"apps/loopex_executor_local/test/host_policy_test.exs","observed_failure":"a policy that raised, exited or timed out resolved to allow instead of denial, so a raising policy returned an allow with a nil context rather than a policy_unavailable denial; the boundary stopped failing closed and the locked unavailable-policy case failed","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex/lib/loopex/policy.ex","restored_sha256":"sha256:e2c850a06d89151e62fd7f53bf6da9e812926730904ab730bea75ecca98bcfe0"}
```

## Outcome 7: project resource trust admission

```json
{"mechanism_disabled":"project_resource_trust_admission","selector":"apps/loopex/test/project_resource_trust_test.exs","observed_failure":"resolution admitted the manifest whether or not a decision existed and whatever digest one carried, so a decision bound to different content staged the changed block instead of reporting the binding changed and a headless run with no decision staged its project block instead of withholding it, and two locked cases failed including the invalidated binding and the headless declined run","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex/lib/loopex/project_resource.ex","restored_sha256":"sha256:d93e2fdd6cf10467e3d36ebdff62aed988d1493d9300ada3dffee1b2a302c0b9"}
```

## Outcome 8: cancellation cleanup confirmation

```json
{"mechanism_disabled":"cancellation_cleanup_confirmation","selector":"apps/loopex/test/cancellation_test.exs","observed_failure":"the abort no longer read what cleanup achieved or whether the run held an unprovable effect and committed cancelled unconditionally, so an unconfirmed cleanup, an effect without sufficient evidence, and an abort reduced while an unprovable receipt settled all finished the run cancelled where outcome_unknown was owed; three cases failed, two of them locked, the validated terminal case and the outcome unknown case","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex/lib/loopex/runtime/session_state.ex","restored_sha256":"sha256:d50f63954abf5cb58d73a613b0fc35e6753b546985c6f8e9bb1b23df33a6334b"}
```

## Outcome 10: command surface facade only

```json
{"mechanism_disabled":"command_surface_facade_only","selector":"apps/loopex_cli/test/cli_test.exs","observed_failure":"the artifact subcommand read objects through the concrete local artifact store instead of the port, so the command source named Loopex.Store.Local and the locked facade case failed on that name; the concrete call also raised a FunctionClauseError on the port handle the composition returns, failing the locked artifact retrieval case with it","candidate":"2e0e1278031aeb3e2952958a053b1dfd1d84d3d7","artifact":"apps/loopex_cli/lib/loopex_cli.ex","restored_sha256":"sha256:1e7fb5674784b22e7115ff3e410e6dca7d127614b6bf48aa345730684a253a05"}
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

All eight were taken together at one candidate, `2e0e127`, which is the
candidate they name. Running them at one candidate is not a formality: evidence
assembled from several moments cannot be read as one account of one revision.

Each ran in a local clone of that candidate, checked out detached, with the
source tree verified clean before every mutation and again after the artifact was
restored, and confirmed clean after all eight so no mutation leaked into the one
that followed.

They have been re-taken twice during this milestone's repairs, and the reason is
worth stating rather than hiding. An earlier version of this record argued they
did not need re-taking at all, because every artifact was byte-identical to the
candidate the records named and the gate accepts an ancestor. That was true when
written and stopped being true when the repairs changed the artifacts. A stale
digest here is not a cosmetic lag: the gate validates these records before it
reaches the retained matrix and before it will emit a capture at all, so evidence
naming bytes that no longer exist blocks the milestone outright.

Seven of the eight mutations are the ones taken previously, unchanged, against
byte-identical artifacts. One changed, and the change is itself information.
`cancellation_cleanup_confirmation` previously disabled a single clause deciding
an abort's outcome. That decision now routes through one shared reading of ADR
0009's precedence table, used by the deadline and bound paths as well, so
mutating it would disable more than the mechanism this record names. The mutation
instead makes the abort path alone return `cancelled` unconditionally, which is
what "the abort stops confirming cleanup" means in the current code, and leaves
every other terminal path intact.

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
