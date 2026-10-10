<a id="technical-depth"></a>
## Technical depth

Concept: [Pre-1.0 superseded surface retirement](0070-pre-1-superseded-surface-retirement.md#concept).

<a id="technical-adr-0070-surfaces"></a>
### Surfaces and replacements

Concept: [Decision](0070-pre-1-superseded-surface-retirement.md#concept-adr-0070-decision).

| Surface | Amended clause | Replacement |
| --- | --- | --- |
| `Executor.cancel/3` | ADR 0016 technical, `cancel/3` retains ADR 0012's defensive behaviour | `cancel/4` |
| `Interrupt.install/1` | ADR 0016 technical, the interrupt boundary retains `install/1` | `install/2` |
| `Policy.decide/2` facade | ADR 0024 technical, M2's locked one-shot projection | `Policy.evaluate/2`; a defer is returned as a question |
| `ReqLLM.complete/2` | ADR 0019 technical, the old bare-model refusal | `Loopex.Model` `complete/3` |
| Unversioned single-token credential plane | ADR 0048 composition contract, the separate validated legacy branch and legacy single-route defaults | A one-route version-2 plane derived from the host's single credential reference |
| `loopex.demo.*` tools | ADR 0009, retained registered demo generations | The current coding tools |
| `daemon prepare-index`, legacy import | ADR 0031 offline legacy import and ADR 0032 index-upgrade clauses | Offline commands write the daemon session index |

<a id="technical-adr-0070-proof"></a>
### Required proof

Concept: [Compatibility and proof](0070-pre-1-superseded-surface-retirement.md#concept-adr-0070-compatibility).

Each removal deletes its code, tests and documentation together and migrates
callers to the replacement. The whole affected application suites pass on both
supported pairs; credential custody, provider isolation and offline/daemon
session workflows keep their existing proofs, and the real-provider release
lanes run on the closure candidate.
