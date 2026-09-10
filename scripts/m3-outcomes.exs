# Concept: each outcome binds decisive witness identities, not a whole inventory.
# Technical depth: future test bodies are implemented with the feature; reached
# selectors must contain every named passing case, with no skipped/excluded cases.
%{
  outcomes: [
    %{
      id: 1,
      selectors: [
        %{
          path: "apps/loopex_composition/test/skill_acquisition_test.exs",
          names: [
            "pinned Git import retains the exact tree and complete file identities",
            "import uses the authorized executor with closed configuration and bounded cancellation",
            "links escapes unsupported files and exceeded pack limits refuse before publication",
            "interrupted installation preserves the previous pack and executes no downloaded content"
          ]
        }
      ]
    },
    %{
      id: 2,
      selectors: [
        %{
          path: "apps/loopex/test/skill_context_test.exs",
          names: [
            "catalog selected instructions and manifested supporting blocks stage in durable order",
            "only settled operator commands change the next run selection",
            "changed or revoked manifest identity withholds resources without stopping ordinary coding",
            "hostile skill metadata changes neither tool registry policy result nor grants",
            "resource admission measures all dimensions and maximal receipts before dispatch",
            "recovery preserves exact staged resource bytes without refetch or ambiguous redispatch"
          ]
        }
      ]
    },
    %{
      id: 3,
      selectors: [
        %{
          path: "apps/loopex_cli/test/foundation_workflow_test.exs",
          names: [
            "embedding and the source built CLI complete the same skill tool and full artifact workflow",
            "trusted launch and fresh process recovery preserve resource and provider configuration",
            "new readers preserve genuine M2 history and old readers refuse new records before effects"
          ]
        }
      ]
    },
    %{
      id: 4,
      selectors: [
        %{
          path: "apps/loopex/test/context_admission_test.exs",
          names: [
            "required only preflight refuses before any optional inclusive measurement",
            "structured source goldens receipt arithmetic digest framing and malformed replay form one locked matrix",
            "context refusal replay validates every compact dimension relation and rejects every broken pair"
          ]
        },
        %{
          path: "apps/loopex/test/event_dispatcher_availability_test.exs",
          names: [
            "a held Store read does not delay unrelated session acknowledgement",
            "late reads after detach replacement or overflow cannot publish under a stale owner or cursor"
          ]
        },
        %{
          path: "apps/loopex/test/provider_attempt_protocol_test.exs",
          names: [
            "retired permit retention is bounded by active sessions and unresolved work",
            "retired identities remain refused across delayed registration restart and ownership succession",
            "only exact pre-canary not_dispatched proof opens one retry whose accounting and stream domain stay bound to its attempt"
          ]
        }
      ]
    },
    %{
      id: 5,
      selectors: [
        %{
          path: "apps/loopex/test/m3_gate_support_test.exs",
          names: [
            "checkpoint routing selects all outcomes for unknown and shared paths",
            "closed gate prefix excludes the caller and future milestones",
            "closed gate inventory refuses omitted and failed invocation records",
            "actual aggregate runs the predecessor prefix and propagates a failed gate",
            "authoritative reports reject missing duplicate mismatched and malformed evidence",
            "selector accounting prevents an incomplete floor loop from reporting success",
            "inspection is read-only and checkpoint Git routing includes untracked work without stderr contamination"
          ]
        }
      ]
    }
  ],
  real: %{
    path: "apps/loopex_cli/test/foundation_workflow_real_test.exs",
    names: [
      "public pinned Git import and a real provider complete the admitted skill tool and artifact workflow"
    ]
  }
}
