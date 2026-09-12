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
            "protocol records reach only stdout and bounded diagnostics only stderr across a real process boundary",
            "strict UTF-8 LF framing and the exact method inventory refuse unknown mutating methods before admission and answer unknown queries with a bounded error",
            "every connection state row from before initialize through restart behaves as ADR 0023 specifies"
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
            "attach returns a snapshot and cursor before live delivery and admission precedes correlated asynchronous delivery",
            "a second attach refuses with a stable reason unless it names explicit replacement which detaches the first at its last emitted cursor",
            "in flight request identity reuse refuses and reuse after completion is ordinary correlation",
            "pre admission pressure refuses before any durable write and post admission pressure drops progress first then detaches at the last emitted cursor",
            "snapshots durable events transient progress and diagnostics stay separate record families and a fresh settled attachment is the final authority"
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
            "recovery resumes an answered but unresolved interaction without speculating acknowledging or dispatching first",
            "identical response replay returns the historical admission and changed content wrong target resolved expired or absent interactions refuse with stable reasons",
            "invalid answers malformed policy output and failed or timed out re-evaluation dispatch nothing and resolve as denial",
            "policy request interaction request and answer digests and their retained preimages survive commit unknown and restart under the same policy identity and revision",
            "every interaction transaction cut is journaled before publication and before any effect intent",
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
            "the attachment owned open read close API refuses another attachment session or runtime and discloses no path",
            "whole first last empty and overrun windows and every distinct refusal reason behave exactly as ADR 0028 specifies",
            "an open that exceeds its deadline or work budget refuses before any snapshot bytes are retained",
            "per connection and per runtime transfer limits refuse independently",
            "streaming memory stays bounded well above the chunk ceiling and startup scavenging removes only owned regular files without following links",
            "genuine old format artifacts remain readable and removing the transfer capability restores the prior API without rewriting data",
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
            "late progress after detach is dropped and process loss cleans the whole child group",
            "a transfer reference from another connection refuses at the wire and connection loss closes every transfer it opened"
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
    },
    %{
      id: 7,
      selectors: [
        %{
          path: "apps/loopex/test/trace_session_test.exs",
          names: [
            "a runtime owned session traces only allowed modules and owned processes and leaves a second VM tracer unaffected",
            "each trace level reports its documented fields and the arguments level redacts credential references model content tool arguments and artifact bytes",
            "trace limits drop with a counted entry and never block a coordinator",
            "no session command client content model output project resource or wire request starts changes or stops a session and stop releases every flag",
            "a release without trace sessions reports unavailability and never falls back to global tracing"
          ]
        },
        %{
          path: "apps/loopex/test/telemetry_boundary_test.exs",
          names: [
            "every port and transaction boundary emits start stop or exception spans with durations and only documented metadata",
            "a crashing telemetry handler is isolated and emission with no handler stays within the measured overhead"
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
