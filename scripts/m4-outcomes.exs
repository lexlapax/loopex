# Concept: each outcome binds decisive witness identities, not a whole inventory.
# Technical depth: future test bodies are implemented with the feature; reached
# selectors must contain every named passing case, with no skipped/excluded cases.
%{
  outcomes: [
    %{
      id: 1,
      selectors: [
        %{
          path: "apps/loopex_app_server/test/initialization_test.exs",
          names: [
            "a raw byte client negotiates the exact experimental generation schema digest and limits before any mutation",
            "mutation before initialization and repeated initialization refuse without durable work",
            "protocol records reach only stdout and bounded diagnostics only stderr across a real process boundary"
          ]
        }
      ]
    },
    %{
      id: 2,
      selectors: [
        %{
          path: "apps/loopex_app_server/test/session_mapping_test.exs",
          names: [
            "the same command corpus produces identical durable identities through facade and wire",
            "request identity varies independently of command identity and replay returns the historical admission",
            "attach returns a snapshot and cursor before live delivery and admission precedes correlated asynchronous delivery"
          ]
        }
      ]
    },
    %{
      id: 3,
      selectors: [
        %{
          path: "apps/loopex/test/interaction_lifecycle_test.exs",
          names: [
            "policy defer commits one pending interaction before publication and suspends the run without executor intent",
            "a committed answer re-enters host policy and only an allow result mints a grant before dispatch",
            "expiry abort deadline and restart races resolve by journal order and recovery resumes only retained pending state",
            "successive answer and defer rounds stop at the exact bound with a stable refusal",
            "old readers refuse interaction records before effects beside an old format positive control"
          ]
        },
        %{
          path: "apps/loopex_app_server/test/foundation_mapping_test.exs",
          names: [
            "wire clients select only admitted catalog resources and cannot name roots modules profiles or grants",
            "no request parameter model output resource or answer replaces an immutable launch input",
            "missing or stale trust withholds staged content while ordinary coding continues",
            "interaction answer admission is observed separately from policy re-evaluation grant intent and tool receipt"
          ]
        }
      ]
    },
    %{
      id: 4,
      selectors: [
        %{
          path: "apps/loopex_store_local/test/artifact_transfer_test.exs",
          names: [
            "a chunk is returned only after the complete immutable object verifies once per transfer and object and chunk digests stay distinct",
            "an unsupported ArtifactStore reports unsupported rather than falling back to a whole object fetch",
            "wrong session use object and use swaps and corruption outside the requested window refuse at open before any bytes",
            "a same inode same size rewrite of the original after open never reaches a chunk and every chunk matches the reported object digest",
            "concurrent transfer and connection work exhaustion refuse and close cancellation loss and expiry release every descriptor",
            "unlinked owner private snapshots leave no bytes in the scratch root across repeated abrupt kill and restart",
            "open deadline chunk byte and read deadline budgets bound allocation and a transfer reads at most one verification plus one emit"
          ]
        },
        %{
          path: "apps/loopex_app_server/test/delivery_bounds_test.exs",
          names: [
            "malformed UTF-8 duplicate keys excess nesting and oversized frames refuse before semantic decoding",
            "a blocked reader detaches at a stated cursor while the coordinator stays unblocked and memory stays bounded",
            "late progress after detach is dropped and process loss cleans the whole child group"
          ]
        }
      ]
    },
    %{
      id: 5,
      selectors: [
        %{
          path: "apps/loopex_app_server/test/external_workflow_test.exs",
          names: [
            "the TypeScript consumer completes skill answer reevaluation grant tool artifact and abrupt restart from operator input against the shipped server",
            "stdin EOF performs orderly shutdown without cancellation and the pending interaction survives restart",
            "session abort is the only deliberate cancellation and an aborted interaction is never pending after restart"
          ]
        }
      ]
    },
    %{
      id: 6,
      selectors: [
        %{
          path: "apps/loopex_protocol/test/public_schema_conformance_test.exs",
          names: [
            "Elixir Python and TypeScript clients execute the same positive and negative vectors without the server codec",
            "exact source schema client versions and toolchain platform identities are recorded with every result"
          ]
        },
        %{
          path: "apps/loopex/test/m4_gate_support_test.exs",
          names: [
            "authoritative reports reject missing duplicate reordered wrong kind and stale version fields",
            "the final report grammar rejects missing duplicated reordered and malformed fields"
          ]
        }
      ]
    }
  ],
  real: %{
    path: "apps/loopex_app_server/test/external_workflow_real_test.exs",
    names: [
      "an attended real provider task completes the TypeScript skill answer reevaluation grant tool artifact and restart workflow"
    ]
  }
}
