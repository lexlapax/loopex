<a id="technical-depth"></a>
## Technical depth

Concept: [Private attempts IO prerequisite](0065-private-attempts-io-prerequisite.md#concept).

<a id="technical-adr-0065-purpose"></a>
### Available lock mechanisms

Concept: [Purpose and evidence](0065-private-attempts-io-prerequisite.md#concept-adr-0065-purpose).

OTP 27.3.4 and 29.0.5 `file` and `prim_file` export IO and sync operations but
no advisory lock. `file:open`'s exclusive option is create-if-absent; a
surviving pathname proves no live writer. VM-local names cannot exclude another
VM. A Unix-domain socket path also survives its owner.

A listening TCP socket is kernel state owned by its process. Binding
`127.0.0.1:Port` without `SO_REUSEPORT` fails with `eaddrinuse` while another
socket listens there, on Darwin and Linux, and the kernel closes it when the
owning OS process exits.

<a id="technical-adr-0065-decision"></a>
### Scope and physical ownership

Concept: [Decision](0065-private-attempts-io-prerequisite.md#concept-adr-0065-decision).

The index's lock record is written once with the index, by exclusive create,
and holds one port in 20000..32767, below both platforms' default ephemeral
ranges. The writer opens it with:

```elixir
:gen_tcp.listen(port, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: false])
```

`eaddrinuse` is contention and refuses admission; any other error is
unavailable evidence. The writer never accepts connections on the listener.

The process that owns the listener opens the index with `[:raw, :binary]` and
performs every read, append and `:file.sync/1` while holding it. Raw
descriptors and the listener are both owned by that process, so its death
releases the lock and stops IO together. The VM's death releases both through
the kernel. A writer exiting proves neither fsync success nor that no case was
consumed.

Elixir owns ADR 0057's closed body and frame validation, full-chain replay,
greatest committed head, campaign designation and dispatch admission. Capture
each invocation's work and cleanup cutoffs once within its committed finite
budget; lock acquisition, reads, appends and syncs do not renew them. Retain
the 65,536-byte record limit and refuse uncertain or incomplete appends until
the original index is exclusively resolved. Never truncate a tail or start a
replacement campaign merely because an acknowledgement was lost. Success
requires the complete append and fsync before acknowledgement or dispatch.

<a id="technical-adr-0065-options"></a>
### Alternatives and qualification

Concept: [Options and consequences](0065-private-attempts-io-prerequisite.md#concept-adr-0065-options).

Python's `fcntl.lockf`, Darwin `lockf`, Linux `flock` and a native helper are
not selected and are not fallbacks.

Qualify with real independent VMs on both supported toolchains: contention,
writer-process crash and VM kill followed by reacquisition, port held by an
unrelated listener, complete history and original head, append/sync before
acknowledgement or dispatch, and honest uncertain cleanup. Do not replace the
physical lock tests with a VM mutex or fake callback.

The writer unit stays separate from two-host handoff, retained source
revocation, manifest execution authority and paid runner activation.

<a id="technical-adr-0065-current"></a>
### Current format and rollback

Concept: [Current contract and rollback](0065-private-attempts-io-prerequisite.md#concept-adr-0065-current).

Keep ADR 0057's exact event union and envelope/digest recipe; the lock record
is the only addition. Before rollback, stop the live writer. Removing the
source path does not erase a consumed attempt. Retained records are unchanged;
no unlocked append, history rewrite or cross-version migration is authorized.
