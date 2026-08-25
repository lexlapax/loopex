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
{"mechanism_disabled":"committed_history_projection","selector":"apps/loopex/test/agent_loop_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex/lib/loopex/conversation.ex","restored_sha256":""}
```

## Outcome 2: stream delta reconstruction

```json
{"mechanism_disabled":"stream_delta_reconstruction","selector":"apps/loopex_llm_reqllm/test/streaming_conformance_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex/lib/loopex/stream_domain.ex","restored_sha256":""}
```

## Tool registry: tool definition generation binding

```json
{"mechanism_disabled":"tool_definition_generation_binding","selector":"apps/loopex/test/tool_registry_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex_protocol/lib/loopex_protocol/tool_definition.ex","restored_sha256":""}
```

## Outcome 4: workspace path scope containment

```json
{"mechanism_disabled":"workspace_path_scope_containment","selector":"apps/loopex_executor_local/test/coding_tools_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex_executor_local/lib/coding_tools.ex","restored_sha256":""}
```

## Outcome 6: host policy deny pre-start refusal

```json
{"mechanism_disabled":"host_policy_deny_prestart_refusal","selector":"apps/loopex_executor_local/test/host_policy_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex/lib/loopex/policy.ex","restored_sha256":""}
```

## Outcome 7: project resource trust admission

```json
{"mechanism_disabled":"project_resource_trust_admission","selector":"apps/loopex/test/project_resource_trust_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex/lib/loopex/project_resource.ex","restored_sha256":""}
```

## Outcome 8: cancellation cleanup confirmation

```json
{"mechanism_disabled":"cancellation_cleanup_confirmation","selector":"apps/loopex/test/cancellation_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex/lib/loopex/runtime/session_state.ex","restored_sha256":""}
```

## Outcome 10: command surface facade only

```json
{"mechanism_disabled":"command_surface_facade_only","selector":"apps/loopex_cli/test/cli_test.exs","observed_failure":"","candidate":"","artifact":"apps/loopex_cli/lib/loopex_cli.ex","restored_sha256":""}
```

## Why the observed values are empty

Each record's `observed_failure`, `candidate`, and `restored_sha256` describe one
mutation experiment performed at one clean candidate. `restored_sha256` must
equal the running revision's SHA-256 of the artifact it names, so a record
written before the candidate settles goes stale the moment that artifact changes
again — and a stale record is worse than an absent one, because it reads as
evidence.

The eight experiments are run against the closure candidate. The locked
`mechanism_disabled`, `selector`, and `artifact` triples above are fixed now, so
the experiment set is decided rather than chosen afterwards to fit whatever
happened to fail.

## Related

- [Coding demonstration](M2-coding-demonstration.md) — the attended real-provider run.
- [M1 negative demonstrations](M1-negative-demonstrations.md) — the closed milestone's equivalent record.
- [Evidence index](README.md).
