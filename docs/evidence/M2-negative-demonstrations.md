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
{"mechanism_disabled":"committed_history_projection","selector":"apps/loopex/test/agent_loop_test.exs","observed_failure":"the projection dropped every assistant turn and its results, so no request carried committed history and seven locked cases failed including the history and replay cases and every turn bound","candidate":"4894dea16a5fdc398106cccd6c7a1b93a161d3c4","artifact":"apps/loopex/lib/loopex/conversation.ex","restored_sha256":"sha256:1b24ee744f7944e91aa489fcdb49027d588d195bc037a55315fe5091beddc5c0"}
```

## Outcome 2: stream delta reconstruction

```json
{"mechanism_disabled":"stream_delta_reconstruction","selector":"apps/loopex_llm_reqllm/test/streaming_conformance_test.exs","observed_failure":"every attempt derived one frozen stream domain id, so two domains under one turn were indistinguishable and five locked cases failed including separate sequences per domain and retry domain separation","candidate":"4894dea16a5fdc398106cccd6c7a1b93a161d3c4","artifact":"apps/loopex/lib/loopex/stream_domain.ex","restored_sha256":"sha256:7a5b964e1ce62c7a561fa7662a19c9930c718864e1f486f40e37ee4adf35a70a"}
```

## Tool registry: tool definition generation binding

```json
{"mechanism_disabled":"tool_definition_generation_binding","selector":"apps/loopex/test/tool_registry_test.exs","observed_failure":"generation returned one frozen triple for every definition, so a changed definition kept its generation and three locked cases failed including the recorded generation and unknown id refusal","candidate":"4894dea16a5fdc398106cccd6c7a1b93a161d3c4","artifact":"apps/loopex_protocol/lib/loopex_protocol/tool_definition.ex","restored_sha256":"sha256:08a9c7b347c4b5f4774e1bc20b7db08eaeb7b29ec7f242a09882ded07696e2e5"}
```

## Outcome 4: workspace path scope containment

```json
{"mechanism_disabled":"workspace_path_scope_containment","selector":"apps/loopex_executor_local/test/coding_tools_test.exs","observed_failure":"resolve expanded the path and compared nothing, so traversal and symlink escapes were admitted and the locked containment case failed","candidate":"4894dea16a5fdc398106cccd6c7a1b93a161d3c4","artifact":"apps/loopex_executor_local/lib/coding_tools.ex","restored_sha256":"sha256:ebbe853fa8a23dffd1eec0d53f3d91dd1922ff85a2051cf86a248a6feb80c832"}
```

## Outcome 6: host policy deny pre-start refusal

```json
{"mechanism_disabled":"host_policy_deny_prestart_refusal","selector":"apps/loopex_executor_local/test/host_policy_test.exs","observed_failure":"the port allowed every decision without consulting the host module, so denial timeout malformed response and defer all fell through to allow and five locked cases failed","candidate":"4894dea16a5fdc398106cccd6c7a1b93a161d3c4","artifact":"apps/loopex/lib/loopex/policy.ex","restored_sha256":"sha256:6f1729d6c000635809c6a9c8a3248450bd6aa4198b9de6b2e7490cdd4a6f911d"}
```

## Outcome 7: project resource trust admission

```json
{"mechanism_disabled":"project_resource_trust_admission","selector":"apps/loopex/test/project_resource_trust_test.exs","observed_failure":"resolve admitted every manifest without consulting the decision, so a headless run staged the project block and four locked cases failed including decision binding and invalidation","candidate":"4894dea16a5fdc398106cccd6c7a1b93a161d3c4","artifact":"apps/loopex/lib/loopex/project_resource.ex","restored_sha256":"sha256:99e658924ad2e6f0916e2ffb4fad9723d12f13ef9b9541defde218c58a0bffc7"}
```

## Outcome 8: cancellation cleanup confirmation

```json
{"mechanism_disabled":"cancellation_cleanup_confirmation","selector":"apps/loopex/test/cancellation_test.exs","observed_failure":"an abort whose cleanup was unconfirmed committed cancelled instead of outcome_unknown and the locked insufficient evidence case failed","candidate":"72c09ec74d43b43e4787b8905c25c57d677cf063","artifact":"apps/loopex/lib/loopex/runtime/session_state.ex","restored_sha256":"sha256:93e198c764e412a923445442b0949b290e12bae49b4eccf221e26d0759026d55"}
```

## Outcome 10: command surface facade only

```json
{"mechanism_disabled":"command_surface_facade_only","selector":"apps/loopex_cli/test/cli_test.exs","observed_failure":"the command named a runtime control module and the locked facade only case failed","candidate":"72c09ec74d43b43e4787b8905c25c57d677cf063","artifact":"apps/loopex_cli/lib/loopex_cli.ex","restored_sha256":"sha256:57476fbf46672ffdd0bea450522fd3c6d59ece557f60413ac9b5114a66820d36"}
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
what makes "restored" a claim about bytes rather than prose. Each digest above
matches this revision, and a record whose artifact changed afterwards is re-run
rather than re-labelled. Two records name a later candidate than the other six, because the session
reducer and the command both changed after their first experiments. The reducer
changed once, to carry a spilled artifact through the receipt. The command
changed three times: the terminal's patience, the unrecognised-flag refusal on
every subcommand, and the project-resource announcement. Each mechanism was
disabled again, at the candidate its record names, and failed its locked selector
again.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended real-provider run.
- [M1 negative demonstrations](M1-negative-demonstrations.md) — the closed milestone's equivalent record.
- [Evidence index](README.md).
