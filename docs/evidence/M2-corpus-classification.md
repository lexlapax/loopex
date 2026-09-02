# M2 post-merge corpus classification

Retained report of the independent classification that produced the tenth
recorded override in [M2 recorded limitations](M2-recorded-limitations.md#corpus-adr-0018-supersession).
Back to [docs/evidence/README.md](README.md).

Run serially from a fresh clone at `7f89ba9` on 2026-09-02, after the ADR
0015, 0016, 0017, and 0018 implementations and the prepared-recovery work
were integrated on the milestone branch. Thirty-three non-adjudicated red
cases were classified against the accepted ADR text, with the pre-rename
assertion recovered from history for every renamed case.

| Verdict | Count |
| --- | --- |
| Production regression | 3 (one latent, no covering case) |
| Superseded assertion | 19 |
| Defective test support | 9 |
| Undecided, instrumented afterwards | 2 |

## Production regressions

- The model stream domain was derived from a private coordinator operation id
  that differed from the committed `model_operation_id` journaled in the
  attempt records, so a consumer could not bind a delta to its settlement.
  Repaired by deriving from the committed identity.
- `canonical_reply/2` accepted any key under `usage` while identity and tool
  calls closed their key sets. Repaired by closing the usage key set; values
  remain classified so unreported usage stays a canonical reply.
- Latent: the settlement preflight measured a candidate with the shortest
  termination and conversation members while the committed record could be
  up to twelve bytes longer, so a record admitted at the exact ceiling could
  be refused by the Store. Repaired by preflighting the members actually
  committed; a boundary case now proves it in both arms.

After instrumentation, one undecided case exposed a fourth defect: a
coordinator that learned it was superseded on the stream-close path never
re-evaluated the owner-loss stop predicate and stayed alive. Repaired by
routing that path through the same predicate every other superseded site
uses. The other undecided case was correct product behaviour: the provider
worker is deliberately left to answer after an abort so its usage is not
discarded, and only the cancellation reserve stops it; the case's bound now
derives from that reserve.

## Superseded assertions

- Five refutations of `model_result_committed`,
  `model_attempt_evidence_retained`, or `model_attempt_abandoned` became
  refutations of the single `model_attempt_settled_v1` after the mechanical
  rename, which is unsatisfiable because exactly one settlement always
  exists; they now discriminate on `termination` or `conversation`.
- Six cases expected a second dispatch after a dispatched attempt returned no
  readable answer or after owner loss; ADR 0018 makes both terminal.
- Two cases expected a projected reply from a term carrying extra keys, or an
  oversized reply sized with `canonical_request_bytes` included; the reply
  key set is closed and that member is excluded from reply measurement.
- Two renames were incomplete outside the two files the rename touched, one
  kind list was half-applied in a merge, one fixture double reported no usage
  and so was charged the whole allowance, and the succession case's purpose
  required a `not_dispatched` first attempt to remain provable.
- A settlement Store refusal makes the session unavailable and fabricates no
  settlement or terminal; the case that expected an `outcome_unknown` terminal
  was rewritten to that observable.

## Defective test support

The Control-boundary proxy forwarded the provider-dispatch call raw in only
one of its three modes, so the proxy became the caller and Control refused
the permit in four cases. A byte helper measured `kind` as a string where the
Store retains an atom. A `map_reduce` binding was transposed. A hook on the
`owner_advanced` row could not fire because an advance-owner transaction
carries no records; the case is now sequenced at Control and additionally
asserts the exact fence and ownership calls that precede a permit request.
An abort was issued through a superseded attachment. An atom was compared
with a string match. The depth boundary values sat one level off the
projection's real depth. A refute named a kind no prompt writes any more.
An `on_exit` resumed a coordinator racing its own shutdown.

## Blocking flake

"Control received no queued call" reproduced in roughly one in five to one in
ten whole-file runs of the provider-attempt suite, never in isolation, and
not deterministically per seed. The first diagnosis attributed it to a lost
freeze on Control; a helper change that tracks the freeze state directly was
shipped as hygiene and measured to leave the rate unchanged over twenty runs
per arm. Instrumenting the flunk site then proved the mechanism: at the
failing instant Control is suspended by the test process, the coordinator is
blocked inside the publication-fence call to Control, and Control's mailbox
reads empty by both `:messages` and `:message_queue_len` while thawing it
unblocks the coordinator at once. A message sent to a suspended process sits
in its outer signal queue until the process is scheduled, so mailbox
introspection under-reports it; whether a given send has merged depends on
whether the target ran between the send and the suspend, which is why the
failure is load-dependent and whole-file-only. Every mailbox-scanning helper
in that suite is unsound while its target is frozen. The repair, observing
delivery by receive trace instead of by mailbox, is dispositioned separately.

## Per-file counts

Serial runs at seed 0. "Before" is the integrated tree at `7f89ba9`; "after"
is the tree with the production repairs and the first corpus commit.

| File | Before | After |
| --- | --- | --- |
| `apps/loopex/test/agent_loop_test.exs` | 80/100 | 95/100 (six addendum items pending) |
| `apps/loopex/test/provider_attempt_protocol_test.exs` | 19/24 | 24/24 |
| `apps/loopex/test/cancellation_test.exs` | 26/28 | 28/28 |
| `apps/loopex/test/input_algebra_test.exs` | 10/11 | 11/11 |
| `apps/loopex/test/session_lifecycle_test.exs` | 11/12 | 12/12 |
| `apps/loopex/test/embedded_api_test.exs` | 3/4 | 4/4 |
| `apps/loopex_reference_client/test/reference_client_test.exs` | 3/4 | 4/4 |
| `apps/loopex_cli/test/cli_test.exs` | 37/38 | 38/38 |
