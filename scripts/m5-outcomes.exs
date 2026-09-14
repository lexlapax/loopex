# Concept: each outcome binds decisive witness identities, not a whole inventory.
# Technical depth: future test bodies are implemented with the feature; reached
# selectors must contain every named passing case, with no skipped/excluded cases.
%{
  outcomes: [
    %{
      id: 1,
      selectors: [
        %{
          path: "apps/loopex_daemon/test/session_lifetime_test.exs",
          names: [
            "a daemon started for a state root owns every session in it and a session keeps running after its last client disconnects",
            "an orderly daemon stop settles nothing new records nothing false and releases the store writer marker",
            "an abrupt daemon death leaves only what the journal proves and a restarted daemon recovers every session under the same placement identity",
            "a second daemon for the same state root is refused by the held writer marker and never opens a second store on one log",
            "the daemon exposes session list open and stop through the socket without a client owning session lifetime"
          ]
        }
      ]
    },
    %{
      id: 2,
      selectors: [
        %{
          path: "apps/loopex_daemon/test/socket_transport_test.exs",
          names: [
            "an independent client process initializes over the Unix domain socket with the same generation schema digest and limits the foreground server negotiates",
            "the same command corpus produces identical durable identities through facade foreground server and daemon socket",
            "socket permissions restrict connection to the owning operating system user and a foreign uid is refused before initialize",
            "frame size fragmented input malformed input and a socket path beyond the platform bound are refused with distinct stable reasons",
            "a client disconnect is transport loss that records no cancellation and changes no interaction state"
          ]
        }
      ]
    },
    %{
      id: 3,
      selectors: [
        %{
          path: "apps/loopex_daemon/test/collaboration_test.exs",
          names: [
            "exactly one controller holds the lease for a session while any number of observers attach read only",
            "a command carrying a stale writer epoch is refused before core admission and the current controller is unaffected",
            "an observer takes over only after the controller lease expires or is released and the takeover advances the writer epoch durably",
            "a controller killed mid run is fenced and its late commands are refused after takeover",
            "a session abort issued by the controller cancels work dispatched under an earlier client process with a truthful cleanup outcome",
            "a read only attachment never acquires command authority and no client content lease or metadata grants it"
          ]
        }
      ]
    },
    %{
      id: 4,
      selectors: [
        %{
          path: "apps/loopex_daemon/test/replay_residency_test.exs",
          names: [
            "attach returns a snapshot anchored at the committed sequence and then the buffered and live stream contiguously with no gap",
            "a cursor older than retained history returns cursor expired with a fresh snapshot and cursor instead of silent truncation",
            "per attachment queues are bounded and a slow observer is detached at its last completely emitted cursor while the controller and other attachments continue",
            "idle attachments are evicted at the residency limit and reconnect at their retained cursor with no duplicate or missing durable event",
            "attachment memory per daemon stays within the documented ceiling under the maximum attachment count",
            "transient progress is coalesced or dropped under pressure and never delays a journal transaction"
          ]
        }
      ]
    },
    %{
      id: 5,
      selectors: [
        %{
          path: "apps/loopex_store_daemon/test/store_conformance_test.exs",
          names: [
            "the daemon grade store passes the shared store conformance suite unchanged",
            "torn writes crashes between framing and sync and corrupt frames are detected repaired or refused explicitly",
            "commit ambiguity resolves to exactly one outcome after a crash during transact",
            "writer ownership and owner epochs fence a stale writer after takeover",
            "bounded replay from a snapshot reconstructs the same state as full replay"
          ]
        },
        %{
          path: "apps/loopex_store_daemon/test/migration_test.exs",
          names: [
            "a genuine M4 local log migrates forward and every session replays identically afterwards",
            "an interrupted migration is detected on reopen and completed or rolled back without loss",
            "the previous binary refuses a migrated store explicitly and the documented rollback restores the old root",
            "backup and restore of a daemon store preserve every session identity and event sequence"
          ]
        }
      ]
    },
    %{
      id: 6,
      selectors: [
        %{
          path: "apps/loopex_daemon/test/multi_client_workflow_test.exs",
          names: [
            "two real client processes drive one daemon owned session with the controller prompting and the observer following and then take over after the controller is killed",
            "a fresh extraction of the exact source candidate follows the operator guide to build start and use the daemon with operator supplied inputs",
            "the reference CLI attaches to a daemon owned session lists sessions and aborts cross process work with a truthful outcome",
            "every daemon boundary emits the ADR 0030 telemetry spans and a trace session scoped to the daemon runtime captures identities only"
          ]
        }
      ]
    }
  ],
  real: %{
    path: "apps/loopex_daemon/test/multi_client_workflow_real_test.exs",
    names: [
      "an attended real provider task completes the two client controller observer kill and takeover workflow over one daemon",
      "the attended workflow runs the daemon reference CLI and TypeScript consumer from the extracted source archive by following the operator guide with supplied inputs"
    ]
  }
}
