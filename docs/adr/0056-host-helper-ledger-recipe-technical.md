<a id="technical-depth"></a>
## Technical depth

Concept: [Host helper ledger byte recipe](0056-host-helper-ledger-recipe.md#concept).

<a id="technical-adr-0056-purpose"></a>
### Authority and implementation gap

Concept: [Purpose and boundary](0056-host-helper-ledger-recipe.md#concept-adr-0056-purpose).

[ADR 0046's private ledger](0046-child-session-tool-technical.md#technical-adr-0046-decision)
fixes composition ownership, transaction families, object/frame/log caps,
completion credit, original-attempt bindings, adapter-wide commit uncertainty,
stop-only recovery and derived coverage. [ADR 0049](0049-explicit-host-configuration-technical.md#technical-adr-0049-decision)
fixes immutable role/delegation selections. [ADR 0051](0051-current-format-physical-restore-technical.md#technical-adr-0051-placement)
requires semantic validation of every shipped host ledger. This proposal fills
the byte recipe; it does not replace those decisions.

Source inspection at `37bd508536165aa960e6651c7f8612a00b445c7a` establishes the
existing boundaries below; the Core command prerequisite is refreshed at
`e3a64c18f4e9fcebcc33e6fb1be9b03232f160ae`:

- `apps/loopex_composition/lib/loopex_composition/delegation/retained_objects.ex`
  owns UTF-8 object bytes, SHA-256 addressing, 1 MiB admission, physical identity,
  exclusive writer custody and sync/rename/readback. It does not validate JSON.
- `apps/loopex_composition/lib/loopex_composition/delegation/genesis_codec.ex`
  implements the exact three-member current-genesis envelope and calls
  `Loopex.Runtime.SessionGenesis.normalize/1`. Its readers preserve original ETF
  bytes across OTP pairs; they do not require re-encoding equality.
- `Runtime.creation_provenance/2`, `lookup_create_result/4` and `effect_intents/4`
  supply the accepted read-only joins. No helper ledger/router executes yet.
- `SessionState.accounting/2` retains total charge and its last source;
  `ProviderAttempt` validates per-attempt reported/estimated evidence. Neither
  supplies an approved complete retained run-accounting read.
- `SessionState.prepare_command/2` and `propose/3` now use the same
  omission-preserving authored-bound normalization before defaults. Prompt and
  follow-up digests use `loopex_command_v2`; accepted admission retains
  `command_revision` 2 and exact `authored_bounds`. Normalization/digest helpers
  remain private. No helper-facing owning command/digest API/export or complete
  helper integration join is implemented or proved by this recipe.
- `Restore.Audit` checks current stores, Local ledgers, artifacts and resource
  objects. Hash/UTF-8 validation of delegation objects does not yet prove their
  helper grammar or allowance relations.

The T11 task and context pointers retain no earlier complete closed ledger
recipe. Earlier accounting proposals are unaccepted inputs, not authority for
an API or numerical/query bound here.

<a id="technical-adr-0056-recipe"></a>
### Bytes, objects and mutations

Concept: [Proposed persistence and recovery](0056-host-helper-ledger-recipe.md#concept-adr-0056-recipe).

**Canonical data and digest preimages.**

All displayed maps are closed string-key maps. Every listed member is required
unless a union or explicit null says otherwise. Unknown fields, unsupported
versions, duplicate members, wrong types and noncanonical bytes refuse.
The containing ledger JSON admits at most 16 nested containers, 32 members per
object and 16 elements per stored array; these exceed the closed shapes below.
Encoded genesis/options/receipts are scalar base64 strings and retain their
owning decoded structural caps. Complete encoded byte caps apply before parse.
The streaming derived expected-set hash is not a stored array and has no new
entry-count limit; construct its ordered preimage incrementally within the
accepted cache and classification bounds.

`J(value)` is the following canonical UTF-8 JSON byte encoding, without BOM,
whitespace or a trailing newline:

- Object keys are strings, sorted by their unsigned UTF-8 byte sequence.
  Arrays keep their stated order. No Unicode normalization occurs.
- Strings contain valid Unicode scalar values encoded as UTF-8. Escape quote
  and backslash as `\"` and `\\`; encode backspace, form feed, LF, CR and tab
  as `\b`, `\f`, `\n`, `\r`, `\t`. Encode other U+0000..U+001F values as
  six ASCII bytes `\u00xx` with lowercase hex. Emit every other scalar literally,
  including slash and non-ASCII text. Reject lone surrogates and invalid UTF-8.
- Integers use their complete base-10 spelling: `0` or a nonzero digit followed
  by digits, with one leading minus only where a schema expressly permits it.
  This recipe admits no negative ledger quantity, fraction, exponent or `-0`.
  Booleans and null are exactly `true`, `false`, `null`.
- Decode with duplicate-preserving members and exact integer tokens; never
  round through a float or convert a key to an atom. Compare complete input
  with `J(decoded)` after schema validation. Do not use the wire Frame decoder's
  2^53 integer ceiling for private host quantities. The existing OTP JSON
  callback pattern in `LoopexCli.ConfigJson` illustrates exact integer parsing;
  composition must not depend on CLI or copy its configuration schema. The
  existing Protocol.Frame encoder has this key/string/integer recipe; reuse its
  pure encoding where appropriate, removing only its one framing newline and
  applying the smaller owning cap. No change to the public wire codec is implied.

`N` is a nonnegative exact integer; `P` is positive. Their canonical encoded
bytes must fit the owning complete record. This preserves the existing BEAM
integer domain of turn/token bounds; it introduces no new accounting API cap.
`Umax` is 2^64−1; `U` is 0..Umax where an existing field requires it.
`H` is exactly 64 lowercase ASCII hex bytes. `B(x)` is canonical padded
RFC 4648 base64 of original bytes,
verified by decode and encode equality. Opaque IDs use `B`, never a UTF-8 guess;
original ID limits still apply (runtime 1..256 bytes; existing executor identity
fields 1..8192, with their owning validator). Empty IDs refuse. Current
JobRequest origin epochs and fencing_token are N, exactly as its native validator
requires. They remain JSON integers; no binary-epoch fallback is admitted.
Opaque binary values in other owning current schemas retain their declared B
encoding, including inside genesis/receipt envelopes; never guess from a string
or convert a retained epoch/fence between binary and integer.

`D(label,value)` is lowercase SHA-256 of ASCII label, one NUL byte, then
`J(value)`. Labels below are literal and contain no NUL. Retain complete
preimages beside derived digests. A hash indexes bytes; equality checks compare
those bytes, including on an unlikely hash collision. Object addresses are the
existing lowercase SHA-256 of their complete `J(object)` bytes, without a new
domain prefix. Core command, request, configuration, tool and artifact digests
retain their existing owner recipes, not `D`.

```text
binding_identity = [B(runtime_id), B(parent_create_command_id)]
run_identity     = [B(runtime_id), B(parent_session_id), B(parent_run_id)]
operation_identity = {"parent_session_id": B(id),
                      "parent_run_id": B(id), "operation_id": B(id)}
source_intent = {"session_id": B(id), "journal_version": P,
                 "canonical_request_digest": H}
```

Binding and run keys are respectively
`D("loopex:helper-binding:v1", binding_identity)` and
`D("loopex:helper-run:v1", run_identity)`. Logical child create/prompt command
IDs are the ASCII hex bytes of respectively
`D("loopex:helper-create:v1", [B(runtime_id),operation_identity])` and
`D("loopex:helper-prompt:v1", [B(runtime_id),operation_identity])`.
Executor attempt is excluded; changed arguments under the same operation refuse.
These IDs deduplicate live commands and authorize nothing on recovery.

**Physical namespace and framing.**

Under the existing leased `delegation/<SHA256(runtime_id)>/` directory:

```text
<hex64>                                  immutable retained object
bindings/<binding-key>.log                parent binding log
runs/<run-key>.log                        parent/run log
job-index-v1/<SHA256(original-job-id)>     derived job entry
job-index-v1/coverage/<SHA256(session-id)> derived coverage entry
```

The runtime directory hash uses original runtime bytes, matching
`RetainedObjects`; it is distinct from the domain-separated log keys. Existing
object temporary/lock files keep their current physical writer grammar. Ledger
and cache temporaries belong to the exclusive writer and are never admitted as
committed records or authoritative cache entries. The ledger uses the existing
placement and writer-lock mechanisms without treating their marker as a helper
transaction. New ledger/cache directories are 0700 and their regular
records/temporaries 0600. Existing retained-object/lease files keep their owning writer modes. Reject
symlink/special entries and changed ancestor or handle/path identities; existing
placement lock hard links keep their validated ownership role. The accepted
host exclusion is not a malicious-host CAS promise. Missing/inaccessible required files never become empty state.

Every log starts with one header frame, followed by transaction frames. Both
use exactly this binary framing, so file identity is checksummed too:

```text
prefix = <<"LXPHELP1", 1::unsigned-16-big, payload_length::unsigned-32-big>>
frame  = <<prefix::binary, SHA256(prefix)::binary-32,
           payload::binary-payload_length, SHA256(payload)::binary-32>>
```

Magic is eight ASCII bytes. Prefix is 14 bytes, complete header 46, trailer 32;
frame overhead is **78 bytes**. Checksums here are raw 32-byte digests; JSON
SHA fields remain lowercase hex. Payload length is 1..65,536. Read all 46 header
bytes and verify magic/version/header checksum **before** using the length,
allocating a payload buffer or decoding JSON. Unknown version or complete
invalid header refuses even at EOF. A complete header declaring an over-cap
length refuses, not an incomplete tail. Validate raw payload hash, complete
canonical JSON and the appropriate closed schema before reduction.

Header payload is exactly
`{"version":1,"kind":"header","ledger_kind":"binding"|"run",
"identity":binding_identity|run_identity,"identity_sha256":H}`.
Its digest and filename must match the appropriate identity preimage. Header
does not advance ledger version. It is created/synced, with parent-directory
sync, before any mutation append. A missing/torn header proves no usable log;
it is not a recovered empty ledger. Binding log total≤1,048,576; run log
total≤16,777,216, including header, all framing and all complete retained bytes.

Transaction payload is exactly:

```text
{"version":1, "tx_id":H, "expected_version":N,
 "mutation_digest":H, "mutation":mutation}
```

`mutation_digest = D("loopex:helper-mutation:v1",
[header.identity_sha256, expected_version, mutation])`.
For a newly appended frame `expected_version` equals the count of previously
committed transaction frames. Its resulting version is that count plus one;
no gaps, repeated appended tx or replacement frame is valid. Replay first
checks header scope and every complete frame/digest/order/reducer transition.
A duplicate API commit consults the existing tx index before expected-version
admission: exact original expected-version/mutation bytes return the original
committed result, despite a newer head. Changed bytes are a transaction conflict.
It writes no second frame. A different tx with stale version refuses before IO.

Transaction IDs use `D("loopex:helper-tx:v1",
[header.identity_sha256, kind, target])`. Target is `[]` for prepare/bind-parent
and initialize; operation_identity for child-created, child-prompted, stop and
settle; `[operation_identity, B(original_job_id)]` for reserve and bind-receipt;
operation_identity for recover-uncreated. This permits another original attempt
of an existing operation to bind without a second child reservation. A caller
wanting a later stop returns the reducer's original stop, not a differently
reasoned conflicting commit. The ledger commit itself never relaxes tx conflict.
A committed result is derived exactly as
`{"version":1,"tx_id":H,"ledger_version":P,"mutation_digest":H}`.
Lookup returns that result only after full validated replay/known sync; absence
requires a complete exclusively recovered prefix, otherwise it is unknown.

**Retained objects.**

Every helper object is `J`-canonical, nonempty and≤1,048,576 encoded bytes. Install
through `RetainedObjects` and confirm file plus directory durability before an
append references its hash. Referenced object kind, runtime and complete bytes
must match; possession of a hash supplies neither schema validity nor authority.
Unused temporary/unreferenced objects cannot supply missing committed facts.

`G` is exactly the existing GenesisCodec envelope
`{"encoding":"loopex.ledger.plain_etf.v1.base64","bytes":base64,"sha256":H}`.
Its decoded current-v3 genesis is≤65,536 bytes, uncompressed, safe, fully consumed
and validated by SessionGenesis. Preserve retained ETF bytes; do not demand
cross-OTP re-encoding equality. For original normalized options `O`, use the
same literal three-member plain-ETF envelope, with decoded≤65,536. Decode an
options map only, normalize through the existing Store wrapper
`%{"options" => options, kind: "original_options"}` and require its normalized
options equal decoded genesis.options, exactly as current Control does. The
wrapper is validation data, not an extra persisted host record. The genesis-only
codec must not silently be widened into an arbitrary-term decoder. Factor shared byte checks when useful;
use the owning options schema, not a host copy. No process terms or raw opaque
bytes appear as JSON text.

```text
catalog = {"version":1,"kind":"catalog","runtime_id":B(id),
 "providers":existing_closed_durable_provider_bindings,
 "roles":[{"name":role_name,"genesis":G}, ...]}

declaration = {"version":1,"kind":"declaration","enabled":true,
 "roles":[role_name,...],"max_children":1..128,"token_budget":P,
 "child_bounds":{"max_turns":P,"deadline_ms":1..600000,"token_budget":P},
 "max_tokens":P,
 "role_budgets":[{"role":role_name,"context_token_budget":1..Umax,
                  "system_class_tokens":1..Umax}, ...]}

parent_creation = {"version":1,"kind":"parent_creation","runtime_id":B(id),
 "command_id":B(original_id),"original_options":O,"genesis":G,
 "input_digest":H,"canonical_create_digest":H,
 "catalog_sha256":H,"declaration_sha256":H,
 "task_generation":{"tool_id":"loopex.task","tool_version":"1.0.0",
                    "definition_digest":H}}

child_creation = {"version":1,"kind":"child_creation","runtime_id":B(id),
 "operation_identity":operation_identity,"role":role_name,
 "catalog_sha256":H,"declaration_sha256":H,
 "command_id":B(derived_create_id),"original_options":O,"genesis":G,
 "input_digest":H,"canonical_create_digest":H}
```

Catalog roles are unique, bytewise name-sorted, 1..16; role names use ADR 0046's
ASCII pattern. Delegation roles preserve the accepted authored enabled order,
unique 1..16, all present in the catalog; role_budgets follows that same order.
Validate providers through `ProviderBindings.validate/1` and the existing durable
env-reference restriction. Retain references only, never selected credential
values. ADR 0048's explicit same-provider host restart/rebinding remains valid;
it does not alter captured catalog/request bytes or redirect a committed model.
Each role genesis retains admitted exact model/configuration/instruction
bytes, cleanup grace and immutable read/grep/find/ls selection (including existing
derived artifact-read binding), with policy_defer_mode `refuse`, no task/question.
Use SessionGenesis/SessionConfiguration/tool validators and existing provider
route validation. No fresh file/catalog lookup may repair a captured value.
Per-role system≤context; child output/context ceilings must match its actual
model and retained declaration. Header/runtime/catalog/declaration/create IDs
and task generation all join. Disabled sessions without task have no helper
binding; an enabled task selection cannot omit or use a disabled declaration.

`input_digest` is `D("loopex:helper-create-input:v1", creation_without_digests)`:
remove exactly input_digest and canonical_create_digest from the closed creation
object. This binds original options, frozen selections and original command
separately from the resolved Core identity. `canonical_create_digest` is the
existing canonical mutation digest of Store.create_session(runtime_id,command_id,
decoded_genesis); use that pure constructor, never a new host substitute.
For reference, child_created configuration_digest is Core Canonical.digest of
decoded genesis.initial_configuration and tool_selection_sha256 is Core
Canonical.digest of decoded genesis.tool_selection; compare those exact maps.
Child genesis/options must reflect the committed reservation's
threshold, configured turn/reply limits, selected role and original cleanup.
The role snapshot does not allocate a child. The existing standalone
three-member genesis object is also an admitted object kind through GenesisCodec, but it supplies no host binding or missing creation
record. Original child prompt text remains in its captured Core task intent; frames reference source_intent, not raw request
bytes. A digest/refusal is not permission to reissue a command during recovery.

**Closed mutations and reducer.**

The following are the entire mutation maps, including literal `kind` values.
`job` is exactly ADR 0046's router row:

```text
{"job_id":B(id),"route":"helper","operation_id":B(id),"attempt":P,
 "session_id":B(id),"run_id":B(id),"canonical_request_digest":H,
 "origin_session_epoch":N,"origin_executor_epoch":N,
 "executor_identity":B(id),"fencing_token":N,"cleanup_grace_ms":1..Umax}
```

Its native decode must match the original validated JobRequest. Full job bytes,
policy grants, workspace leases and current query IDs are not persisted in this
projection; the immutable source intent supplies exact original semantics.
Each source join requires the same parent/run/operation/request digest and
original attempt. Hashing a row never validates a grant or predecessor joins.

| Mutation | Exact members after `kind` | Admission and reduction |
| --- | --- | --- |
| `prepare_parent` | `creation_sha256:H, command_id:B, input_digest:H, canonical_create_digest:H, catalog_sha256:H, declaration_sha256:H, task_generation:task_generation, closing_credit_bytes:N` | First binding mutation only. All immutable objects already synced and joined; retain exact command/options/genesis. Reserve bind-parent credit before append. |
| `bind_parent` | `parent_session_id:B, creation_sha256:H, input_digest:H, canonical_create_digest:H` | Exactly one result after prepare. Existing read-only exact creation history agrees with original runtime/command/genesis. No recovered create dispatch. |
| `initialize` | `binding_key:H, catalog_sha256:H, declaration_sha256:H, limits:declaration` | First run mutation only. Joined binding names this parent; limits equal retained declaration byte-for-byte. Initial counts, reserved and charged totals are zero, never substituted on resume. |
| `reserve` | `operation_identity, source_intent, job, role:role_name, task_digest:H, child_creation_sha256:H, create_command_id:B, prompt_command_id:B, absolute_cutoff_ms:1..(2^53−1), reserved_tokens:P, closing_credit_bytes:N` | First operation reserves min(child token threshold, aggregate available), increments count once, occupies this parent's cross-run slot before child creation. Before stop, later original attempts of that same operation must match all logical fields and append only their new job/source binding and receipt credit; no new tokens/count/child. |
| `recover_uncreated` | `operation_identity, source_intent, create_command_id:B, prompt_command_id:B, reservation_state:"unknown", reason:"adapter_recovery", child_session_id:null, child_run_id:null, reported_child_usage:0, count_charge:1, closing_credit_bytes:N` | Exact ADR 0046 missing-reservation mutation after complete intent coverage, positively ended old producer/sent calls and conclusive original-create absence. The referenced intent supplies its original job/attempt. Count charged once, tokens zero, already stopped; no reserve/create/prompt later. Excess stays unresolved, not clamped. |
| `child_created` | `operation_identity, child_session_id:B, child_creation_sha256:H, configuration_digest:H, tool_selection_sha256:H, policy_defer_mode:"refuse"` | Live validated owner only, known original create result; compare configuration digest by its existing owner recipe and tool selection digest by Core Canonical. Record before prompt. Recovered missing result uses exact historical lookup, never calls create. After stop no new creation/activation. |
| `child_prompted` | `operation_identity, child_session_id:B, child_run_id:B, prompt_command_id:B, prompt_digest:H` | Original live prompt has a known committed admission. Its digest comes only from ADR 0046's owning Core command revision 2, binding exact prompt text and authored bounds/absolute cutoff. The helper-facing owner join and its proof remain prerequisites below. Recovery never re-presents missing prompt. |
| `stop` | `operation_identity, job, stop_tx_id:H, reason:"cancel"|"cutoff"|"adapter_recovery"` | job is one retained original attempt; stop_tx_id equals containing tx_id. First stop wins. No later create/prompt/activation. Known terminal already won remains its original fact; stop cannot turn it into cancelled. |
| `settle` | `operation_identity, terminal:terminal, accounting:accounting, charge_tokens:N, refund_tokens:N` | Write once only from conclusive terminal and actual cleanup/producer joins, or conclusive recover-uncreated no-child. Validate charges below. Parent unknown outcome stays unknown even after later child settlement. |
| `bind_receipt` | `operation_identity, job, receipt_sha256:H` | One complete exact attempt receipt per retained original job. Receipt object already durable, matches original tuple and settled/conclusive evidence; identical returns original, different refuses. Never synthesizes a current attempt or query route. |

`prompt_digest` is the owning Core digest of the original prompt command under
[ADR 0046's accepted normalized-command revision](0046-child-session-tool-technical.md#technical-adr-0046-decision).
That revision binds the original command ID, exact prompt text and authored
partial bounds, including `deadline_at_ms`, before defaults or clocks are
resolved. Use its owning constructor and retained admission record; do not
hash a host reconstruction or copy Core's private command schema. Current Core
implements this revision: `SessionState.prepare_command/2` and `propose/3` use
the same normalization before defaults, `command_digest` hashes deterministic
ETF `["loopex_command_v2", normalized_command]`, and accepted prompt/follow-up
records retain `command_revision` 2 plus omission-preserving `authored_bounds`.
The normalization/digest functions remain private; this recipe supplies no
helper-facing owning API or digest export. Joining the original owning digest
and retained admission through actual helper prompting remains unimplemented
and unproved. Generic Core revision proof does not prove that integration or
authorize a host substitute. Helper prompting and `child_prompted` admission
remain closed until those owner joins and the other helper prerequisites are
proved; no superseded-v1 fallback is admitted. Recovery validates retained facts
and never reissues the prompt.

Reserve's `task_digest` is Core Canonical.digest of the exact validated task
arguments {role, description, prompt}, validated by the existing fixed Tool
argument validator. It is independent of executor attempt. Each job's own
canonical_request_digest must agree with its own source_intent, not with that
logical task digest: the job digest binds its original attempt/epochs/fence too.
Any later attempt reuses frozen role, child object,
command IDs, reservation and absolute cutoff; it cannot install a different
cutoff or relabel a new task. A repeated already-bound attempt appends nothing.
`closing_credit_bytes` is the post-mutation outstanding credit for that operation,
recomputed from its prospective state and every admitted attempt, never accepted
as caller-selected money. In prepare_parent it is the binding's outstanding credit.

```text
terminal = {"state":"completed"|"failed"|"cancelled"|"bound_reached",
 "child_session_id":B(id),"child_run_id":B(id)|null,"journal_version":P,
 "terminal_record_sha256":H,"cleanup":"confirmed"}
 | {"state":"uncreated","child_session_id":null,"child_run_id":null,
    "journal_version":P,"terminal_record_sha256":H,"cleanup":"confirmed"}

accounting = {"reported_input_tokens":N,"reported_output_tokens":N,
 "estimated_tokens":N,"unresolved_usage":boolean,"charged_tokens":N,
 "through_version":N,"prefix_token":B(token)|null,"evidence_sha256":H}

receipt_object = {"version":1,"kind":"receipt","runtime_id":B(id),
 "operation_identity":operation_identity,"job":job,
 "receipt":{"encoding":"loopex.ledger.plain_etf.v1.base64",
            "bytes":base64,"sha256":H}}
```

Terminal points to the exact retained child run terminal and its owning Core
record digest, namely Core Canonical.digest of its normalized plain payload. A null run is permitted only for state failed when the original
create is known but no prompt was admitted: account for every original sent
prompt/producer, validate the complete captured child prefix and confirmed
cleanup, and bind its last owning record. Missing acknowledgement alone cannot
prove an unprompted child. This variant has zero usage, with the positive
captured child through_version/token; it is distinct from no child creation.
Its labels are the helper outcome projection from that validated fact, not arbitrary reason-text inference. The uncreated variant points to the
source intent whose original-create absence was conclusively joined; its
terminal_record_sha256 is Core Canonical.digest of that validated intent payload; every
accounting quantity and through_version is zero, prefix_token is null, and
unresolved_usage is false. Its evidence preimage below binds the original
source/absence case; conclusive absence is separately checked through Core.
An unknown child lifecycle, unresolved effect or unconfirmed cleanup cannot use either terminal.
Cleanup text records an already established fact; no digest replaces real joins.

Receipt envelope decoded bytes≤65,536, with the existing plain ETF checks and
exact owning executor-receipt schema/identity/output/artifact/cleanup validation.
Use the existing Core fact validator, extracting its pure validator if necessary,
not a private host copy. The host only constructs ADR 0046's bounded helper
result: retained final text≤16 KiB with explicit truncation, Core's model
projection≤2048 encoded bytes and existing artifact references for bulky text.
Measure complete receipt/object/frame, including base64. Preserve native outcome
and original bytes; cancelled requires actual causation and confirmed cleanup,
completed/failed facts that preceded cancellation retain their original outcome.
No raw ETF is newly accepted by a public API.

The reducer additionally joins all referenced object hashes/preimages, validates
logical operation uniqueness and one occupied slot per parent across logs, and
rejects transitions without required predecessor facts. It never derives
coverage from the existing filenames alone. Corrupt child Store/catalog/object
or unsupported accounting evidence fences the affected classification, not an
empty slot. No separate persistent slot or cross-log transaction is introduced.

**Derived cache closure.**

Keep ADR 0046's exact job entry
`{"version":1,"kind":"job","job":job,"source_intent":source_intent,
"run_log":run_key,"frame_offset":null|N}` and coverage entry
`{"version":1,"kind":"coverage","runtime_id":B(id),"session_id":B(id),
"covered_through_version":N,"prefix_token":B(original_token),
"expected_sha256":H}`. Here run_log is the hex basename key, never an arbitrary
path; nonnull frame_offset is the exact zero-based byte offset of a validated
transaction frame containing that original attempt. No lookup follows a caller
supplied path or trusts an offset without full prefix/schema validation.

Job entries≤65,536 canonical JSON bytes. Coverage entries use that same finite
per-entry ceiling. The original prefix token is exactly the owning Core query's
32-byte token; compare as opaque, never reinterpret it as launch authority.
`expected_sha256` remains SHA-256 of the complete canonical JSON array of
`{job,source_intent}` rows ordered by source journal version; tie-break equal
versions by original job bytes and refuse conflicting duplicate jobs. These are
derived cache checks, not host mutation digest domains. Original ordinary/local
router rows keep route `local` and native envelopes unchanged.

Before coverage publication remove every scanned registration with a committed
pre-effect refusal, then install/sync canonical job entries and the coverage
entry atomically under the host lease. Interrupted removal/publication leaves
old, absent or mismatching coverage and forces safe rescan. Page watermark and
terminal joins remain ADR 0046's exact rules. In-memory cache/active registry and
unknown-ID tombstones each keep their accepted separate 4096-entry/8,388,608-byte
bounds; the cache's bound is not a lifetime limit on retained index files.
Use the fixed resumable 60,000 ms startup classification cutoff. Cache loss cannot
hide historical receipts, authorize adoption or make absence conclusive.

<a id="technical-adr-0056-accounting"></a>
### Settlement and completion credit

Concept: [Accounting prerequisite](0056-host-helper-ledger-recipe.md#concept-adr-0056-accounting).

**Exact charge arithmetic and unresolved producer.**

The accounting map is a stored host projection, not a proposed Runtime API.
For a real child through_version is positive and prefix_token is the existing
Core record-prefix identity's original 32 bytes in padded base64. It binds the
captured child history endpoint, not a permission to read or mutate it. The
uncreated variant alone has zero through_version and null prefix_token.
`evidence_sha256` is exactly `D("loopex:helper-accounting-evidence:v1",
[operation_identity, terminal, accounting_without_evidence_sha256])`.
All preimage fields are retained in the settle frame. This is a binding to
validated facts, not a self-authenticating proof. Replay/restore independently
joins the retained child history and its endpoint with the owning Core validators.
There is no opaque accounting object or undecided object grammar under this hash.

**The separate accounting decision still owns the producer.** Helper execution
and settlement remain closed until a typed, source-bound and bounded input can
represent every admitted child's whole-run charge and validate this fixed
projection. A producer can map its approved typed data to these stored fields;
this proposal does not expose them as an API. No generic object fallback,
unvalidated host assertion or hand-copied SessionState reducer is permitted.

The producer must include ordinary provider attempts and automatic maintenance
owned by this run, preserve reported overshoot, estimated remaining-allowance
charges and any unresolved usage. It must exclude standalone session compaction,
not double-count maintenance and bind the original child/run and complete
captured cut. The ledger compares that verified input to through_version and
the terminal/reference joins. unresolved_usage is true whenever any dispatched
attempt has estimated or unresolved usage; a conclusively undispatched attempt
adds no charge or uncertainty. This names what the prerequisite must prove;
it does not choose its API shape, response bound, cursor, lifetime or head/fence
protocol. Last-source `charged` cannot prove certainty. An owning input or complete settlement-size
failure is unavailable evidence, never permission to truncate or call it exact.

For reserved tokens `R`, verified reported `I+O` and verified estimated `T`:

```text
Q = I + O + T
charge = Q                         if unresolved_usage = false
charge = max(R, Q)                 if unresolved_usage = true
refund = max(0, R - charge)
```

Require stored charged_tokens and charge_tokens equal that charge; refund_tokens
equals that refund. Unknown usage therefore cannot reduce the reservation.
Reported overshoot is never clamped to `R` or to the parent allowance. Use exact
nonnegative integer addition/subtraction/comparison; no float, wrap, saturation
or lossy JSON conversion. An estimator is a conservative charge, not measured
provider billing. Recovered-uncreated has `R=Q=charge=refund=0` and retains its
one count charge. Child count never refunds after admission.

The reducer's aggregate charged total is the exact sum of write-once charges.
Unsettled reservations remain fully reserved. Aggregate available is
`max(0, token_budget - charged_total - unsettled_reserved_total)`.
After settlement remove exactly that operation's reservation and add its charge
once. A new reservation receives min(child token threshold, available), positive
only; a count/cap refusal precedes child creation. No settlement/replay resets
allowance on resume. Release slot/unused storage credit only after terminal,
cleanup, settlement and every admitted attempt receipt are conclusive/persisted.
Representability of complete settlement and its owning input remains a required
producer proof; maximum-frame credit alone does not prove an unchosen accounting input
schema fits. No helpers ship before both proofs exist.

**Maximum-frame closing credit.**

Let `F = 65536 + 78 = 65614` bytes. It bounds any one admitted transaction frame,
not an average and not a claim that every kind can attain its last byte.
Let `A` be the exact number of admitted original attempts without a persisted
receipt. For an operation let `C`, `P`, `S`, `T` each be 0 or 1 according as the
originally reserved child-created, child-prompted, stop and settle closing slots remain unspent.
A slot becomes zero only after its frame commits or full conclusive release;
learning that a launch is excluded does not release it early.

```text
operation_credit = F * (C + P + S + T + A)
binding_credit   = F if bind_parent is still required, else 0
```

A first reserve records C=P=S=T=1 and A=1: **328070 bytes**. An additional
original attempt adds one receipt credit F before that attempt is admitted and
must itself have room for its reserve frame. recover_uncreated is already
stopped/no-child: C=P=S=0,T=1 and A equals the validated source attempts not yet
receipted (at least the source original attempt). It receives credit before
its append. All source attempts at that complete captured cut are separately
joined and credited; recover_uncreated still has its exact original source_intent fields.
After stop (including recovered-uncreated), no new reserve or work admission is
allowed. A later solicited attempt may receive a known original result only
through bind_receipt with its complete validated source-intent job join: measure
and admit that sole closing frame atomically before returning its receipt. It
creates no future-work obligation or launch permit; lacking capacity/evidence
remains unresolved. No unbounded uncredited attempt list is kept.
Binding prepare reserves F before its append. initialize has no closing record
of its own. Child records cannot spend another operation's credit.

For file byte count `L`, next exact encoded frame length `n`, total outstanding
credit `K` and prospective outstanding credit `K'`, admit only
`L+n+K' <= file_cap`. Nonclosing frames never debit another obligation. A closing
frame consumes only its own F slot and n≤F; it cannot exhaust the reserved budget.
Hold unused create/prompt/stop slots after a transition excludes them until the
operation's full conclusive release condition. Then release all leftover credit.
Do not speculate that a launch never happened after an attempted append.
No negative/mismatching/stale stored credit is accepted; replay recomputes it.

All arithmetic has finite bounds: file cap is fixed, each obligation costs F,
so total outstanding obligations≤floor(file_cap/F), independent of arbitrarily
large token quantities. Capacity denies a further attempt before its binding or
child effect. For run cap, that quotient is 255; for binding cap it is 15.
This is a byte-credit proof, not a new allowed attempt count or a promise that
128 operations fit. Exact frame/object admission and owning data limits remain
mandatory. Reserved disk bytes do not guarantee host disk availability or sync
success: those failures still fence as unknown.

<a id="technical-adr-0056-options"></a>
### Alternatives and evidence

Concept: [Options and consequences](0056-host-helper-ledger-recipe.md#concept-adr-0056-options).

Maximum full-frame credit needs only the selected frame limit and finite
obligation counts. Tighter kind-specific credit could later save space, but must
bound canonical encoded keys, identity/base64 expansion, every integer/text,
object reference, optional union and all attempts. It cannot take an average,
release on cleanup uncertainty or weaken completion-space protection. A Core
Store union would reverse ownership; a plain ETF log would amend the accepted
JSON framing and require independent replacement codec/corruption evidence.

Required implementation proof, without running any command for this proposal:

- Literal independent canonical JSON, file/header/frame, identity/tx/digest,
  every mutation/union and object vectors; exact JSON/frame/digest writer
  outputs on both pairs, both pairs reading each other's retained genesis/options/receipt payloads.
  Unknown members/versions, duplicate escaped keys, invalid UTF-8/surrogates,
  alternate escapes/numbers/order/whitespace, noncanonical base64 and unsafe,
  compressed, oversized or trailing ETF all refuse before reduction.
- Corrupt each header/length byte and payload/checksum separately. A complete
  invalid last header must refuse. Actual crash-truncated last headers,
  payloads and trailers are repairable only after joined old writer/exclusive
  custody; torn header identity, interior corruption and over-cap length refuse.
- Actual retained-object writer and append/fsync/reopen faults at prepare/bind,
  initialize/reserve/recover, create/prompt, stop, settle, receipt and cache
  boundaries. Lost acknowledgement resolves original tx; changed tx bytes,
  stale version, missing object/source and altered scope/attempt refuse.
- Credit at exact cap edges, arbitrary large exact token values, reported
  overshoot/estimated/unknown charges, extra admitted attempt credit, withheld
  early-release credit and no double settlement/refund. Fsync uncertainty in
  parent A fences parent B's settlement too while bounded best-effort cleanup
  remains possible. Accounting producer proof remains separately required.
- Actual child creation and prompt admission with retained current genesis;
  recovery never invokes either. One occupied parent-session slot across runs,
  independent concurrent parents, no child/provider effect before known reserve,
  stopped launch race, grace/cutoff preservation and actual cleanup joins.
- Complete intent/terminal and creation coverage, refused-registration removal,
  cache eviction/rebuild, missing-log conservative count and excess unresolved
  operations, settled-helper mutation guards and both helper demonstrations.
- ADR 0051 complete physical capture and pure reduction of every shipped helper
  object/log, object/source/child/receipt/index relation, modes and namespace;
  no opaque host-ledger attestation substitutes for grammar validation.

None of these proposed tests is a PASS or a milestone closure claim. Ordinary,
selected long, real-provider and complete closure checks retain their authority.

<a id="technical-adr-0056-compatibility"></a>
### Current-format implementation and restore

Concept: [Compatibility and disposition](0056-host-helper-ledger-recipe.md#concept-adr-0056-compatibility).

Implement this one current recipe only after exact-pair acceptance. No earlier
helper bytes have shipped as a complete ledger; do not add migration/old-root or
older-decoder fallbacks. Existing Core/session/Local bytes and receipt identity
recipes remain unchanged. Factor pure owning validators where needed rather
than teaching composition a second Core schema. This proposal does not itself
register task, enable routing, expose a public read, alter grants or activate
restored authority.

[ADR 0053](0053-current-configure-request-technical.md#technical-adr-0053-decision)
already fixes the closed configure `changes` request grammar. Its coordinated
generation/client activation proofs remain separate; that acceptance supplies
no helper-facing command/digest boundary or whole-child-run accounting read.

Once helper records ship, ADR 0051's offline audit must enumerate their complete
physical namespace under its original IO owner/cutoffs, validate exact framing
and referenced current object grammars, fold every retained run/binding and join
complete Core history. No actor startup, truncated backup repair, selective
log collection or guessed missing accounting is allowed. A current-format
latest quiescent complete backup retains every binding, object, ledger, child
Store and receipt. Checksums do not prove latestness, old-owner termination or
exclusion; existing host attestations and physical restore authority stay distinct.
Unsupported/corrupt helper state prevents unsafe dispatch or restore completion.
Removing the adapter never grants ordinary adoption of a helper session or erases
an unresolved obligation. No cross-version rollback acceptance proof is added.
