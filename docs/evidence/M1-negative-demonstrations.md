# M1 Negative Demonstrations

## Outcome 2: owner post-commit fence

```json
{"mechanism_disabled":"current_owner_post_commit_fence","selector":"apps/loopex/test/session_lifecycle_test.exs","observed_failure":"stale owner consequences were admitted and two locked cases failed","candidate":"115095c955565c782425697a0666d36324742467","artifact":"apps/loopex/lib/owner.ex","restored_sha256":"sha256:26d36cf9a8c0163fd0787a40c9d08439cf45ba31a532809626f09440f01142cc"}
```

## Outcome 3: atomic owner-epoch transaction

```json
{"mechanism_disabled":"store_atomic_admission_compare","selector":"apps/loopex_store_local/test/store_conformance_test.exs","observed_failure":"stale owner epoch returned the wrong refusal and four locked cases failed","candidate":"115095c955565c782425697a0666d36324742467","artifact":"apps/loopex_store_local/lib/loopex/store/local/state.ex","restored_sha256":"sha256:3b0bc91613554ce7e3fa90e458c01888e727d47ac844b19d5c32683e60e84021"}
```

## Outcome 3: commit-unknown domain fence

```json
{"mechanism_disabled":"commit_unknown_dispatch_fence","selector":"apps/loopex_store_local/test/store_conformance_test.exs","observed_failure":"a different transaction crossed an unresolved domain fence and two locked cases failed","candidate":"115095c955565c782425697a0666d36324742467","artifact":"apps/loopex/lib/loopex/store/owner_lane.ex","restored_sha256":"sha256:7404a057c5b15ef8aa9e6955e858dfebe435349355d6ea23b47daed30adc2151"}
```

## Outcome 6: final executor validation

```json
{"mechanism_disabled":"executor_final_prestart_validation","selector":"apps/loopex_executor_local/test/executor_test.exs","observed_failure":"a missing grant binding started the controlled tool and one locked case failed","candidate":"170da5084cf2088c565544eda1ee9c270a67099c","artifact":"apps/loopex_executor_local/lib/executor.ex","restored_sha256":"sha256:80fe9c61a2d7017d010cf3b0f0c0ad6676dd463362e3135b8321a31012ab7037"}
```

## Outcome 8: no-blind-retry transition

```json
{"mechanism_disabled":"no_blind_retry_without_receipt","selector":"apps/loopex_reference_client/test/end_to_end_recovery_test.exs","observed_failure":"outcome_unknown carried a dispatchable job field and one locked case failed","candidate":"115095c955565c782425697a0666d36324742467","artifact":"apps/loopex_reference_client/lib/recovery.ex","restored_sha256":"sha256:7dd38664b00227f923fd7effc8375743d6607037949fbd90d08be0eaafbe336a"}
```
