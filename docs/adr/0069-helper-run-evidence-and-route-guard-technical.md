<a id="technical-depth"></a>
## Technical depth

Concept: [Helper run evidence and route guard](0069-helper-run-evidence-and-route-guard.md#concept).

<a id="technical-adr-0069-query"></a>
### Run-evidence query

Concept: [Decision](0069-helper-run-evidence-and-route-guard.md#concept-adr-0069-decision).

`run_evidence/3` returns `{:ok, map}`, `{:error, :unknown_run}` or
`{:error, :runtime_unavailable}`. The map has exactly these keys:

| Key | Value |
| --- | --- |
| `admission` | `%{command_id, revision, digest}` of the prompt command that admitted the run |
| `terminal` | `nil` while running; otherwise `%{state, journal_version, record_digest}` |
| `usage` | `%{reported_input, reported_output, estimated, unresolved}` non-negative integers, unresolved a Boolean |
| `through_version` | journal version the answer was computed through |

Core derives `usage` in the same reducer that maintains run accounting during
live work and replay, so restart yields the same answer. Run-owned maintenance
is included; standalone compaction episodes are excluded. Values are bounded by
the existing accounting domains. The helper adapter reads `admission.digest`
immediately after prompt admission for `child_prompted.prompt_digest`, and the
complete map at settlement.

ADR 0056's receipt-fact validation is extracted from `SessionState` as a pure
function so the helper adapter validates receipt bytes without a second copy of
the rules.

<a id="technical-adr-0069-guard"></a>
### Route guard

Concept: [Decision](0069-helper-run-evidence-and-route-guard.md#concept-adr-0069-decision).

The guard reads the host's retained helper classification, which is complete
after ADR 0046's bounded startup classification. Until classification
completes, mutating commands on unclassified sessions wait or refuse as that
startup rule already requires. The guard runs before command admission on each
route; a refused command creates no record and no work. Read-only inspection
and history remain available.

<a id="technical-adr-0069-proof"></a>
### Required proof

Concept: [Compatibility and proof](0069-helper-run-evidence-and-route-guard.md#concept-adr-0069-compatibility).

Both supported toolchains: query results for completed, cancelled, failed and
running runs, with reported, estimated, unresolved and run-owned maintenance
usage, identical after physical Local Store restart; wrong-runtime and
unknown-run refusals; guard refusals for prompt, steer, follow-up, configure,
compact, answer, abort and eager resume on CLI, foreground and daemon routes,
with zero records written.
