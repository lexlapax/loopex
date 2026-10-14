<a id="technical-depth"></a>
## Technical depth

Concept: [Provider OAuth sign-in](0073-provider-oauth-sign-in.md#concept).

<a id="technical-adr-0073-decision"></a>
### Contract

Concept: [Context and decision](0073-provider-oauth-sign-in.md#concept-adr-0073-decision).

**Where the code lives.** Core gains no callback, module or dependency. Its
only change is admitting the one closed failure category
`provider_sign_in_required` described under
[the public failure reason](#technical-adr-0073-failure-reason); Core learns a
category string, not any sign-in mechanism. Provider-specific sign-in
profiles live in `loopex_llm_reqllm` under `Loopex.LLM.ReqLLM.SignIn.*`, beside
`HostBindings` and the adapter's provider catalog. These are endpoints,
scopes, request shapes and token-response validation. The token store,
the refresh lock, the refresher and the per-route custody wiring are host
custody and live in `loopex_composition` under `LoopexComposition.SignIn.*`.
The command grammar lives in `loopex_cli`. No new Hex dependency is added.
The keyring backends call operating-system tools as subprocesses; no NIF or
native library enters the archive's linkage set under ADR 0038.

**Binding grammar.** ADR 0048's closed `credential` member gains a third
exclusive alternative, and the `vertex` route gains two required members:

```json
{
  "providers": {
    "openai":  {"credential": {"env": "OPENAI_API_KEY"}},
    "chatgpt": {"credential": {"oauth": {"source": "loopex"}}},
    "vertex":  {"credential": {"oauth": {"source": "adc"}},
                "project": "my-billing-project", "location": "global"}
  }
}
```

- `oauth` is a closed one-member object. `source` is `loopex`, meaning tokens
  from `loopex auth login`, for every sign-in route. `adc` is admitted for
  `vertex` only, meaning Google's Application Default Credentials file.
- `oauth` is admitted only on routes whose catalog profile is `sign_in`:
  `chatgpt`, `vertex` and `claude`. `env` and `none` are refused on those
  routes, and `oauth` is refused on every existing route. So one route has one
  billing meaning.
- `vertex` requires `project`, matching
  `\A[a-z][a-z0-9-]{4,28}[a-z0-9]\z`, and `location`, either `global` or
  matching `\A[a-z]+-[a-z]+[0-9]{1,2}\z`. The location selects one of two
  compiled endpoint templates and never an arbitrary URL. These members are
  host values; no session or remote client can set them.
- `claude` validates its grammar but refuses at composition and in
  `auth login` with `sign_in_unavailable` while the build's compiled Anthropic
  profile carries no sanctioned client. Configuration inspection reports the
  route as configured and unavailable in this build.
- Errors keep ADR 0048's form: a stable class and an RFC 6901 pointer, never a
  value. The new classes are `invalid_sign_in_reference`, `sign_in_route_only`,
  `invalid_vertex_project`, `invalid_vertex_location` and
  `sign_in_unavailable`.
- At most 16 bindings in total, as now. Sign-in routes add no environment name
  to `excluded_env_names`.

**Route catalog.** `Guards`' provider table gains three entries. Each has a
ReqLLM provider module and a credential kind of `:sign_in`, which has no
environment variable:

| Route | ReqLLM provider (pinned 1.24.0) | Endpoint | Authorization header | Billed to |
| --- | --- | --- | --- | --- |
| `chatgpt` | `ReqLLM.Providers.OpenAI`, `auth_mode: :oauth`, `access_token:` only | `https://api.openai.com/v1/responses` | `Authorization: Bearer <access token>` | The signed-in ChatGPT plan, within the user's per-app cap |
| `vertex` | `ReqLLM.Providers.GoogleVertex`, `access_token:`, `project_id:`, `region:` | `https://aiplatform.googleapis.com/v1/projects/{project}/locations/global/publishers/google/models/{model}:generateContent`, or the `https://{location}-aiplatform.googleapis.com` host for a regional location; streaming uses `:streamGenerateContent?alt=sse` | `Authorization: Bearer <access token>`, plus `x-goog-user-project: {project}` | The named Google Cloud project |
| `claude` | `ReqLLM.Providers.Anthropic`, `auth_mode: :oauth`, `access_token:` only | Fixed by the sanctioned registration | `Authorization: Bearer <access token>`; other headers fixed by the registration | Fixed by the registration |

- Loopex passes only `access_token` to ReqLLM, never `oauth_file`,
  `auth_file`, `oauth_http_options`, `with_claude_subscription` or
  `codex_originator`. It never calls a provider module's
  `refresh_oauth_credentials/2`. ReqLLM 1.24.0's OAuth refresh modules embed
  the Codex CLI client ID (`openai/oauth.ex`) and the Claude Code client ID
  (`anthropic/oauth.ex`). Its Claude subscription mode sends a Claude Code
  user agent and `x-app: claude-code`. The `openai_codex` provider targets
  `chatgpt.com/backend-api`, which OpenAI's Sign in with ChatGPT
  documentation tells third-party apps not to use. None of these is admitted.
  A source scan in `sign_in_profiles_test.exs` enforces this.
- `NativeRequest`'s sealed header check is per route. The admitted header set
  and the exact `Authorization` value are derived from the route's profile, so
  `x-goog-user-project` is admitted only for `vertex`. Every other rule of the
  seal is unchanged.
- **`vertex` header and explicit values.** ReqLLM 1.24.0's `GoogleVertex`
  adds only `authorization` (`deps/req_llm/lib/req_llm/providers/google_vertex.ex`
  :425 on the Req path, :1007 on the Finch streaming path), so Loopex adds
  `x-goog-user-project` itself and seals it:
  - In the companion, the `vertex` invocation passes a final per-request
    `on_finch_request` function, which ReqLLM's streaming client applies
    after the provider built the Finch request
    (`deps/req_llm/lib/req_llm/streaming/finch_client.ex` :262). The function
    appends exactly one `x-goog-user-project: <project>` header, then applies
    the per-route seal to the complete request: method `POST`, the compiled
    endpoint host for the configured location, a path naming the configured
    project, location and model, `authorization` exactly `Bearer` and the
    custody token, `x-goog-user-project` exactly the configured project, and
    no other header outside the route's admitted set. A mismatch answers the
    seal's one literal refusal before any byte is sent.
  - In the ephemeral in-process caller, the header is installed and sealed by
    `OneShotHTTP1`'s private native-request step under the same rule, as
    `NativeRequest.install_buffered/4` does for Anthropic today.
  - ReqLLM otherwise falls back to its own Application Default Credentials
    lookup when no `access_token` is given (`auth_source/2`, :798-806), to
    `GOOGLE_CLOUD_PROJECT` and `GOOGLE_CLOUD_REGION` (:755-756), and to
    `Application.get_env(:req_llm, :google_vertex)` (:765). So a `vertex`
    call reaches ReqLLM only with a non-empty `access_token` from custody and
    the configured `project_id` and `region` passed explicitly as options; a
    missing or empty value refuses before ReqLLM is called, as custody
    resolution does. `sign_in_routes_test.exs` proves the refusal and, through
    the fake server, the exact sealed header set on both callers; a source
    scan in `sign_in_profiles_test.exs` finds no `:req_llm, :google_vertex`
    configuration under `config/` or any app, and the composition asserts
    `Application.get_env(:req_llm, :google_vertex)` is unset when it starts
    a `vertex` route.
- **`chatgpt` request shape.** OpenAI's
  [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
  page fixes these: Responses API only; `store: false` and `stream: true` on
  every request; success only on `response.completed`. The one exception is a reply Loopex
ends itself at the ceiling, below. It also rejects
  `previous_response_id`, system-role items, `temperature`, `top_p`,
  `max_output_tokens`, `metadata`, `user`, `truncation`, hosted tools and
  audio. Function tools are supported.
  - The `chatgpt` mapping renders host instructions through the Responses
    `instructions` member, not a system item.
  - It never relies on provider-side continuation.
  - It is streaming-only.
  - It never sends `max_output_tokens`. The request's committed ceiling
    (`Loopex.Model.max_tokens/1`) is enforced by Loopex in the stream drain,
    as [the reply ceiling](#technical-adr-0073-reply-ceiling) specifies, so
    the route is admitted in every role, including the maintenance summarizer
    whose ceiling ADR 0043 fixes.
  - The admitted models are the account's `GET /v1/models` entries with
    `visibility == "list"`, fetched and recorded as
    [`chatgpt` model admission](#technical-adr-0073-model-admission)
    specifies. Capability capture uses the route's registered mappings, as
    other routes do. A model the recorded list does not name is refused at
    composition and at model switch with the existing
    `provider_route_unavailable`, never as a Model callback result.
  - The provider's `subscription_sharing_usage_limit_exceeded` (HTTP 429) and
    `subscription_sharing_usage_unavailable` replies classify under ADR 0029
    as provider failures after dispatch. They are never retried blindly.

**Token record.** One record per route, per home. It binds the tokens to the
account subject, the client and the write generation; its schema, the pairing
rule against the metadata and recovery after a partial write are specified
under [token record, pairing rule and recovery](#technical-adr-0073-pairing).
An `id_token` is verified as
[ID-token verification](#technical-adr-0073-id-token) specifies, and is never
stored.

**Metadata file.** A non-secret metadata file
`<home>/auth/<route>.json` always accompanies the record:

```json
{"version": 1, "route": "chatgpt", "backend": "macos_keychain",
 "client_id": "oaiapp_...", "host_id": "urn:uuid:...",
 "subject_digest": "sha256:...", "account_label": "a***@example.com",
 "scopes": ["openid", "profile", "email", "offline_access", "resource.invoke",
            "chatgpt.tokens.use.direct"],
 "access_expires_at": "2026-10-13T18:00:00Z", "refresh_expires_at": "2026-11-12T17:00:00Z",
 "models": ["gpt-5.1", "..."],
 "generation": 7, "state": "signed_in"}
```

- `backend` is `macos_keychain`, `secret_service`, `file` or `adc`. The first
  three hold a Loopex token record; `adc` holds none and follows
  [the ADC source](#technical-adr-0073-adc).
- `subject_digest` is the SHA-256 of the issuer, a NUL and the subject.
- `account_label` is the provider's e-mail with the local part masked after
  its first character. It appears only in `auth status`.
- `state` is `signed_in`, `sign_in_required`, `sign_in_incomplete` or
  `revocation_unconfirmed`. Only a lock holder that finds the pair
  inconsistent under the [pairing rule](#technical-adr-0073-pairing) writes
  `sign_in_incomplete`.
- `models` is required on the `chatgpt` route and absent on every other
  route. It is the bounded list
  [`chatgpt` model admission](#technical-adr-0073-model-admission) records,
  never `null`: a `chatgpt` login writes no metadata without it (D25). It is
  metadata only and is not part of the pairing comparison. A `chatgpt`
  metadata file without `models`, or another route's file with it, is
  `credential_store_unsafe` under the closed grammar.
- <a id="technical-adr-0073-generation-floor"></a>**Generation floor.** `<home>/auth/<route>.floor` is a non-secret file
  beside `host-id`, written under the route's lock with the atomic write
  below. Its closed grammar is the canonical JSON object
  `{"version": 1, "route": "<route>", "generation_floor": N, "client_id":
  "<id>"}`, where `N` is a positive integer and `client_id` is the client
  the generations were written under: OpenAI's issued `oaiapp_...` client,
  the compiled Google client, or for `adc` the ADC file's client. Any other
  member or value is `credential_store_unsafe`. `auth logout` writes it,
  before deleting anything, with `N` the largest of the record's, the
  metadata's and an existing floor's generation, so a floor never
  decreases. Nothing but the operator removing `auth/` deletes it. The
  [write protocol](#technical-adr-0073-pairing) and `auth login` read it.
- `<home>` is ADR 0037's home. That `auth/`, the ADC directory
  `$HOME/.config/gcloud` and every selected state root are physically
  disjoint is ADR 0037's
  [separation invariant](0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation),
  which owns the check and its refusal. The context's
  `protected_directories` names both directories. This record relies on it:
  the store re-applies the path check, on the sign-in context the host passed
  it, before every token write, and ADR 0072's backup, adopt and restore
  apply ADR 0037's
  [physical walk check](0037-host-configuration-and-path-discovery-technical.md#technical-0037-physical-walk)
  to every directory they walk, so ADR 0072's complete-copy backups never
  capture a token: a walk refuses a walked root located over a protected
  directory, a directory with a protected identity and any mount inside the
  walked tree, a bind-mounted token file included, and, under ADR 0037's
  [mounts-above rule](0037-host-configuration-and-path-discovery-technical.md#technical-0037-mounts-above)
  (D21), a FUSE filesystem or an overlay over a protected directory at or
  above the walked root. A network or virtual filesystem that exports the
  host's own credential directories back to it is outside this guarantee,
  as ADR 0037 states. A restore that meets one
  before its commit is never committed, and one met after its commit leaves
  the commit standing with cleanup pending. ADR 0051's complete manifest
  excludes no file.
- `auth/` is created with mode `0700`. Every credential-store file in it,
  `*.secret`, `*.json`, `*.floor`, `host-id` and their `*.tmp` siblings, is
  `0600`, owned by the effective user. A reader of one of those files refuses
  a symlink anywhere on its path, a different owner, or a wider mode, with
  `credential_store_unsafe`. The refresh lock's namespace is excluded from
  that mode check: `<route>.lock`, its `.owner-*` handles, its `.guard`
  directory and `.claim-*` contenders are created by `Placement`'s primitive
  under the process umask (`apps/loopex_composition/lib/loopex_composition/placement.ex`
  :209, :215, :311-312) and hold only owner incarnations, never a secret; the
  `0700` directory already keeps other users out of them. `sign_in_store_test.exs`
  runs a refresh, which creates the lock namespace, and then a `Store.read/2`
  and `auth status` that both succeed.
- The `adc` source has no Loopex record. Its metadata members are specified
  under [the ADC source](#technical-adr-0073-adc).

**Token store interface.** Every function of `LoopexComposition.SignIn.Store`
takes as its first argument the *sign-in context*, ADR 0037's
[host-to-store contract](0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation):
the plain map `%{home: abs, auth_directory: abs, protected_directories:
[abs, abs], state_roots: [{pointer, abs}], secret_service_bus: binary | nil}`
that `LoopexCli.Home.sign_in_context/1` built and checked for this
command. `secret_service_bus` is the D-Bus session bus address that
`LoopexCli.Home` captured from `DBUS_SESSION_BUS_ADDRESS`, or `nil`, as ADR
0037's sign-in context defines it. The store takes `home` only for the
keyring item's home digest, every file path from `auth_directory`, and the
Secret Service bus only from `secret_service_bus`; it never reads `HOME`,
configuration or the environment, and never selects or resolves a root. It
exposes:

- `read_metadata(context, route)`, which never reads a secret;
- `read(context, route)`, which returns the record or `:absent`,
  `credential_store_unavailable` or `credential_store_unsafe`;
- `write(context, route, record, metadata)`, which first calls ADR 0037's
  `LoopexComposition.SignIn.Separation.check(context)` and returns its
  `{:error, {:auth_root_overlap, pointer}}` before any backend is touched;
- `delete(context, route)`.

`read/2` applies the [pairing rule](#technical-adr-0073-pairing); `write/4`
follows its write protocol.

*Callers and lifecycle of the context.* `auth login` and `auth logout` build
the context through `LoopexCli.Home` after selection and pass it to each store
call; a refusal there is exit 76. Foreground chat, durable `ask`, the daemon
and the ephemeral composition receive it from their command's row of ADR
0037's table and pass it as a host option to composition, which gives it
unchanged to each `SignIn.Route` it starts. A composition with an `oauth`
binding and no context refuses to start with `provider_sign_in_required`; no
default is computed. The refresher keeps the context for its life and passes
it to every store call. Backends:

1. **macOS Keychain.** The backend runs `/usr/bin/security`, by absolute path
   only, in the user's default keychain.
   - The item is a generic password with service `loopex-oauth` and account
     `<home-digest>:<route>`. `home-digest` is the first 16 hex characters of
     the SHA-256 of the canonical absolute home path, so two homes never
     share an item.
   - Writes run `security -i` and send
     `add-generic-password -U -s ... -a ... -w <record>` on standard input.
     The secret never appears in argv. The record is base64url-encoded first,
     so it needs no quoting.
   - Reads use `find-generic-password -s ... -a ... -w` on standard output.
     Deletes use `delete-generic-password`.
   - The record is at most 196,608 bytes, so its base64url form is at most
     262,144 bytes on one `security -i` input line. That the tool accepts a
     line of that size is [verification item 16](#technical-adr-0073-verification),
     settled by a maximum-size round trip in `sign_in_keychain_test.exs`; a
     refusal there lowers the record bound by amendment, never silently.
   - **Test seam.** The keychain argument is a compile-time value of the
     backend module: `nil`, meaning the user's default keychain, in every
     build except `Mix.env() == :test`, where it is read from the
     `:loopex_composition` application key `:sign_in_test_keychain`, as the
     fake OAuth server's endpoints are injected only under test. Neither the
     sign-in context, configuration, the environment nor any caller can
     name a keychain in a shipped build. `sign_in_keychain_test.exs` creates
     a temporary keychain with `security create-keychain`, sets that key,
     and passes the keychain to `add-generic-password`,
     `find-generic-password` and `delete-generic-password` as their keychain
     argument. No test touches the login keychain, and the release lanes use
     `--store file`.
2. **Linux Secret Service.** The backend runs `/usr/bin/secret-tool` from the
   `libsecret-tools` package, by absolute path only.
   - Every `secret-tool` child, and the wrapper below, is spawned with the
     port option `{:env, [{~c"DBUS_SESSION_BUS_ADDRESS", bus}]}`, where `bus`
     is the context's `secret_service_bus`, so the child never uses an
     inherited or autolaunched bus. The store never reads the variable
     itself.
   - The backend is available when that file is executable,
     `secret_service_bus` is non-`nil`, and a probe
     `secret-tool lookup application loopex-oauth-probe` exits 0 or 1 within
     5,000 ms. Exit 1 means no match, which is fine. Any other status, a
     D-Bus error, or no answer within the bound means unavailable; a locked
     collection whose unlock prompt is not answered in time is therefore
     unavailable.
   - A locked or absent keyring at daemon start: the route's metadata names
     `secret_service`, `Store.read/2` returns `credential_store_unavailable`,
     and composition refuses start with `credential_store_unavailable`
     (exit 121). It never falls back to the file backend.
   - A locked or absent keyring at `auth login`: `--store auto` on Linux
     picks `file` only when the route has no metadata file; when metadata
     names `secret_service`, `auto` keeps that backend and exits
     `credential_store_unavailable` (69). A forced
     `--store secret-service` exits 69 likewise.
   - Attributes are `application loopex-oauth home <digest> route <route>`.
   - `secret-tool store` reads the secret until end of input. An Erlang port
     cannot half-close standard input, so the backend runs the fixed wrapper
     `/bin/sh -c 'head -c "$1" | exec /usr/bin/secret-tool store --label="$2" application loopex-oauth home "$3" route "$4"' sh <bytes> <label> <digest> <route>`.
     The byte count comes from the encoded record and the secret arrives on
     the port. Only non-secret values appear in argv.
3. **File.** The record lives in `<home>/auth/<route>.secret`, mode `0600`.
   - Each write creates `<route>.secret.<16 random hex>.tmp` with
     `[:write, :exclusive, :binary]` inside the `0700` directory and sets mode
     `0600`. It then writes, calls `:file.sync/1`, renames over the target and
     syncs the directory.
   - Because the directory is `0700`, the moment before `chmod` exposes
     nothing to another user.
   - Stale `*.tmp` files older than one hour are removed by the next writer.
   - Metadata uses the same atomic write.

Backend selection: `auth login --store auto` is the default. On macOS, `auto`
picks `macos_keychain`. On Linux it picks `secret_service` when available, and
otherwise `file`, printing `loopex: no keyring available; token stored in
<path>` on standard error. `--store keychain|secret-service|file` forces one
backend, and an unavailable forced backend exits `credential_store_unavailable`.
The selected backend is recorded in metadata, and every later reader uses
exactly that backend. There is no silent migration between backends.

**Refresh lock.** `<home>/auth/<route>.lock` uses `LoopexComposition.Placement`'s
exact algorithm: an `O_EXCL` lock file, owner process incarnation, stale
reclamation under the directory guard, and an inode-checked owner handle. The
primitive moves into a shared private module both callers use; no second lock
algorithm is written. The lock is held only across read, exchange, write, so
a holder can keep it for one 30,000 ms exchange plus the write, longer than a
waiter's bound. Acquisition waits at most 10,000 ms, polling every 100 ms,
then fails with `sign_in_lock_busy`. No refresh token is ever exchanged
without the lock. A `sign_in_lock_busy` at `auth login` or `auth logout`
exits 73. A `sign_in_lock_busy` in a refresher exchanges nothing, writes
nothing, leaves custody as it was and retries on the transient schedule of
refresher step 5; on the next attempt it rereads the pair under the lock and
usually adopts what the other holder wrote. In step 7 it retries at the next
30 s poll. The lock is always needed:

- OpenAI's [token reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference)
  rotates the refresh token on every refresh and tells clients to serialize
  refreshes.
- A daemon, a foreground chat, an `ask` and `auth` may share one home.

**Exchange executors.** Every token-endpoint exchange posts a fixed form to a
compiled HTTPS endpoint, with a 30,000 ms bound. That covers code exchange,
refresh and revocation, and device polling where a provider offers it. The
reply is at most 196,608 bytes and is validated against the profile. An
exchange runs in one of two executors, chosen by the host's isolation
contract:

- **Companion executor.** Durable hosts use it: foreground chat, durable
  `ask`, the daemon and the app server. The exchange is a new invocation kind,
  `token_exchange`, of the existing ADR 0019 provider companion. It has the
  same launcher, guardian, scrubbed environment, nonce and manifest proof, and
  private channel.
  - The refresh token crosses as the credential frame.
  - The companion performs the one POST with its own TLS settings and returns
    the validated token response on the private channel. An `id_token` of at
    most 16,384 bytes is returned with it, unverified; verification belongs to
    the receiving host process, under
    [ID-token verification](#technical-adr-0073-id-token).
  - Only the requesting refresher process in the parent receives it. That
    process is `:sensitive` and excluded from tracing.
  - No raw provider body, header or error text crosses. Failures are the
    closed classes below.
  - A second new invocation kind, `model_list`, of the same companion serves
    [`chatgpt` model admission](#technical-adr-0073-model-admission): the
    access token crosses as the credential frame, and only the bounded,
    validated model list returns.
- **In-host executor.** The ephemeral profile and the `auth` command use it. A
  `:sensitive` process makes the POST with `Req` and the profile's TLS
  options; retention and tickets are disabled as in ADR 0039. The `auth`
  command, like `ask`, turns its logger off and disables crash dumps before
  any exchange. ADR 0039's host-VM audience statement applies to the refresh
  token and the access token alike.

Exchange failure classes are closed:

| Class | Meaning |
| --- | --- |
| `sign_in_required` | Provider `invalid_grant`, `invalid_client`, or a revoked or expired refresh token |
| `provider_unreachable` | Transport failure or timeout, or HTTP 5xx |
| `sign_in_failed` | A malformed or over-bound reply, including an `expires_in` that is absent, not an integer or below 10, an ID token that fails [verification](#technical-adr-0073-id-token), granted scopes missing a required scope, or a subject different from the stored one |

Only `sign_in_required` changes the stored `state`.

**Refresher and custody.** For each `oauth` binding, composition starts one
owned edge, `LoopexComposition.SignIn.Route`. It is linked like the existing
registry and custody edges and joins their reverse cleanup.

1. At start it reads the pair through `Store.read/2`. A `roll_forward` result
   is completed under the lock first; a `sign_in_lock_busy` there starts the
   route with custody already past its deadline, so resolution returns
   `:expired`, and retries the roll-forward on step 5's schedule. An
   `absent` or `inconsistent` result, a
   client ID that does not match the compiled client (Google) or the issued
   client in metadata (OpenAI), or `state: sign_in_required` refuses
   composition with `provider_sign_in_required`; this is the maintainer's
   2026-10-13 startup rule, and the daemon exits 120. A
   `credential_store_unavailable` or `credential_store_unsafe` result refuses
   composition with that class (121, 122). An `adc` route starts as
   [the ADC source](#technical-adr-0073-adc) specifies.
2. If the access token expires within the refresh window, it refreshes under
   the lock. The window is the smaller of 300 s and half the token's lifetime.
3. It starts an ordinary `CredentialCustody` with the access token and
   `expires_at` set by the [custody deadline](#technical-adr-0073-custody-deadline)
   below, in monotonic time.
   Durable composition registers that custody in the `CredentialRegistry`
   under a fresh `CredentialToken` in `provider_routes`, exactly like an `env`
   route. The custody and token modules are unchanged; their existing
   `rotate/3` and `:expired` result are what this record uses.
4. It schedules the next refresh at the window's start. On each refresh it
   takes the lock and rereads the pair. If another process already advanced
   the generation with a later expiry, the same subject and the same client,
   it adopts that record without contacting the provider. If the pair is
   `inconsistent`, or names another subject or client, it exchanges nothing,
   writes nothing, rotates custody to `nil` and names `sign_in_incomplete` or
   `sign_in_account_changed` in its diagnostic; it never writes over another
   account's secret. Otherwise it exchanges, merges the response under
   [the refresh-response rules](#technical-adr-0073-refresh-merge), writes,
   unlocks and rotates custody. For `chatgpt` it then runs one `model_list`
   under [`chatgpt` model admission](#technical-adr-0073-model-admission).

   *Write failure after a successful exchange.* The provider may already
   have rotated the refresh token (OpenAI does on every refresh), so the
   merged record is the only usable grant. When `write/4` fails after a
   successful exchange (`credential_store_write_failed`,
   `credential_store_unavailable`, `credential_store_unsafe` or
   `auth_root_overlap`), the refresher:
   - rotates custody to the new access token, with the deadline from this
     exchange's `t0`;
   - keeps the merged record, refresh token included, only in its own
     `:sensitive`, trace-excluded process state, never in a message,
     diagnostic or other process;
   - releases the lock and retries only the write on step 5's schedule,
     never exchanging again while a write is pending. Each retry takes the
     lock and rereads the pair; when the stored generation is still the one
     it exchanged from, it writes the pending record at the next generation
     under the write protocol, otherwise another process has written a newer
     record and the refresher discards the pending one and adopts or refuses
     under this step's rules;
   - names `sign_in_store_write_pending` with the failing class in one
     bounded host diagnostic line per attempt, `loopex: provider sign-in
     store write pending for route <route>: <class>`, and nothing else.

   A pending record's next scheduled refresh waits for the write: if the
   access token's deadline passes first, resolution returns `:expired`. If
   the process stops before a write succeeds, the rotated refresh token is
   lost with it, and the route needs `auth login` again once the provider
   refuses the stored one; this is the residual of the threat model's
   refresh-token reuse row. Another process that refreshes meanwhile with
   the stored, already rotated refresh token receives `sign_in_required` and
   may write that state; a later successful pending write at the next
   generation restores `signed_in`.
   Before every exchange the refresher calls `Separation.check(context)` on
   its own context. A refusal exchanges nothing, writes nothing, rotates
   custody to `nil` and names `auth_root_overlap` with the pointer in its
   diagnostic, so a provider never rotates a refresh token that the store
   would then refuse to keep. At start the same refusal fails composition,
   which the daemon reports as ADR 0037's `111` with class
   `auth_root_overlap`.
5. A transient failure (`provider_unreachable`) retries with delays of 5, 15,
   30, 60, 120, then every 300 s. The custody keeps the old token until its
   `expires_at`. After that, resolution returns `:expired` and the sender
   refuses before dispatch.
6. On `sign_in_required` it rotates custody to `nil`, so resolution returns
   `:missing`, which a call on the route reports as the public reason
   `provider_sign_in_required`. It writes `state: sign_in_required`, writes one bounded host
   diagnostic line, `loopex: provider sign-in required for route <route>; run
   loopex auth login <provider>`, and stops refreshing.
7. Every 30 s it reads only the metadata file, and it keeps doing so after
   step 6 or a logout has stopped refreshing. It adopts a consistent pair
   whose generation is greater than the one it holds, whose
   `subject_digest` equals the one it holds, and whose `client_id` equals
   the one it holds and, when a floor file exists, the floor's `client_id`:
   one `Store.read/2` under the lock must return `{:ok, record}`, custody
   rotates to the new token, the refresh schedule restarts from step 4 if it
   had stopped, and for `chatgpt` one `model_list` runs. This
   is how a fresh `auth login` reaches a running service, after a logout
   too: the [generation floor](#technical-adr-0073-generation-floor) makes the new
   login's generation greater than anything the service held. A different
   subject or client is refused: custody stays `nil` and the diagnostic names
   `sign_in_account_changed`. A deleted metadata file, which is what `auth
   logout` leaves, rotates custody to `nil` within that 30 s and stops the
   refresh schedule.

<a id="technical-adr-0073-custody-deadline"></a>
**Custody deadline.** The custody's deadline keeps a safety margin, the
*skew*, that scales with the token's lifetime, so even a short-lived token
leaves a usable window after the exchange. The deadline is measured from
before the exchange, so a slow exchange, verification or cleanup spends that
window. When they consume it, the token enters custody already past its
deadline and resolution returns `:expired` immediately: no expired token is
ever dispatched, and the refresher follows the existing retry and refusal
path of steps 4 and 5. All values are integer milliseconds:

```text
lifetime_ms = expires_in * 1_000
skew_ms     = min(60_000, div(lifetime_ms, 4))
expires_at  = t0 + lifetime_ms - skew_ms
```

- `t0` is the refresher's `System.monotonic_time(:millisecond)` taken
  immediately before the exchange request is handed to its executor, so time
  spent in transit is charged to the token.
- `expires_in` must be an integer of at least 10. A token response whose
  `expires_in` is absent, not an integer, or below 10 is `sign_in_failed`, as
  a malformed reply: a login writes nothing and exits 68; a refresh writes
  nothing, leaves custody as it was, and retries on the transient schedule of
  step 5.
- A token read from the store at start has no exchange time. Its lifetime is
  the remaining wall-clock time, `remaining_ms = access_expires_at - now`, and
  `expires_at = t0 + remaining_ms - min(60_000, div(remaining_ms, 4))` with
  `t0` read at that moment. A non-positive remainder gives a deadline already
  past, so resolution returns `:expired` until a refresh succeeds.
- The refresh is always due before the deadline: for every lifetime `L` the
  window `min(300 s, L/2)` exceeds the skew `min(60 s, L/4)`.

For a 30 s token the window is 15 s and the skew 7,500 ms: the refresh is
scheduled at 15 s and custody returns the token until 22,500 ms after `t0`.
`CredentialCustody` itself is unchanged; only the `expires_at` its owner
passes changes.

A call already dispatched keeps the token it was sent with. Rotation never
cancels, repeats or reclassifies an attempt; ADR 0018 governs the attempt as
before. The access token resolved for a call is the call's selected
credential. `worker_invoke/4` and the in-process caller pass it to the
existing echo guard unchanged, so a mapped reply containing it is withheld and
failed. The refresh token never reaches a model call, so it cannot be echoed
there. Trace exclusion covers the refresher, the custody, the exchange
process and the companion; no new trace selector exists.

<a id="technical-adr-0073-model-admission"></a>
**`chatgpt` model admission.** Concept decision 14.

- *Fetch.* `model_list` is one credential-bearing `GET
  https://api.openai.com/v1/models` to that compiled endpoint, with the
  current access token as `Authorization: Bearer`, a 30,000 ms bound and a
  response body of at most 1,048,576 bytes. It runs in the route's exchange
  executor: the companion's `model_list` invocation in durable hosts, never
  the durable host VM; the in-host executor in the ephemeral profile and in
  the `auth` command, under ADR 0039's stated audience. The refresher runs it
  after each successful refresh and each step 7 adoption; `auth login openai`
  runs it once with the newly exchanged access token after ID-token
  verification and before `Store.write/4`, so the login's first write
  already carries the list.
- *Validation.* The response is one JSON object whose `data` is a list; the
  kept entries are those with `visibility == "list"`. Each kept `id` matches
  `\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z`, at most 128 bytes; at most 256 ids
  are kept, sorted and without duplicates. More than 256 listed ids, an
  invalid id, a body over 1,048,576 bytes or a malformed body is
  `sign_in_failed`; a transport failure,
  timeout or non-2xx status is `provider_unreachable`. No raw body, header or
  error text crosses the private channel or reaches a diagnostic.
- *Record at login* (D25). The list is part of `auth login openai`. The
  login's `Store.write/4` writes the metadata with the validated list as
  `models`. A login whose `model_list` fails writes no token record, no
  metadata and no floor change, and exits with the failure's class: 68
  `sign_in_failed` for a malformed body, an invalid id, more than 256
  listed ids or a body over 1,048,576 bytes, and 72 `provider_unreachable`
  for a transport failure, the 30,000 ms timeout or a non-2xx status. The
  exchanged grant is discarded with the `:sensitive` exchange process and is
  not revoked: the provider-side grant is left to expire or rotate, which is
  acceptable because no copy of it survives in Loopex. A rerun of the login
  repeats the whole flow. A re-login over an existing sign-in that fails
  this way leaves the earlier pair, list included, exactly as it was.
- *Record at refresh.* A success writes the list into the metadata's
  `models` member under the route's lock with the atomic metadata write,
  keeping the metadata's generation, subject and client, so the pairing is
  unaffected. A failure changes no stored state, no custody and no token,
  keeps the previous list, which is never replaced by `null` or removed, and
  names `sign_in_model_list_stale` in one bounded host diagnostic line,
  `loopex: model list refresh failed for route chatgpt: <class>; keeping
  the previous list`, where `<class>` is `sign_in_failed` or
  `provider_unreachable`. The next successful refresh or adoption retries
  it.
- *Admission.* `SignIn.Route` holds the list it last recorded or read. The
  configured model and maintenance model are checked when composition
  resolves routes (`LoopexComposition.DurableOptions`, where an unbound
  route already refuses at `durable_options.ex` :243, and the ephemeral
  equivalent), and a model or reasoning switch is checked in ADR 0048's
  switch admission (`ProviderBindings`'s private `resolve_selection_routes/4`
  behind `resolve_configuration/3` and `resolve_maintenance_routes/2`, which
  already refuses at `provider_bindings.ex` :169), before any config commit
  or dispatch. A `chatgpt:<id>` whose `<id>` is absent from the list refuses
  with the existing
  `provider_route_unavailable` and leaves the prior configuration; at
  service start that refuses composition as an unbound route does today.
  It is never a Model callback result, so Core sees no failed attempt and
  nothing retries. Resume keeps ADR 0048's rule of checking only the
  committed model's route; a committed model the account later stops
  listing is sent, and the provider's refusal is an ordinary dispatched
  failure.
- *Tests.* `provider_bridge_test.exs` (extended): the `model_list`
  invocation through the real companion boundary, its credential frame, the
  256-id and 128-byte bounds, the 1,048,576-byte body bound, the timeout,
  the closed failure classes and no raw body crossing.
  `sign_in_refresh_test.exs`: the list is refreshed after each refresh and
  after a re-login adoption, and a failed listing keeps the previous list
  byte for byte, never `null`, and emits one `sign_in_model_list_stale`
  line. `auth_command_test.exs`: a login whose `model_list` fails, once
  malformed and once over 256 ids (exit 68) and once timing out and once
  answering 503 (exit 72), writes no record, metadata or floor, both over an
  empty `auth/` and over an existing sign-in whose pair and floor stay byte
  for byte. `sign_in_store_test.exs`: a `chatgpt` metadata file without
  `models`, with `models: null`, and a `vertex` file with `models` are each
  `credential_store_unsafe`. `sign_in_routes_test.exs`: an unlisted model refuses
  `provider_route_unavailable` at composition and at switch, a refused
  switch keeps the prior model, and the fake server sees no model request.

**Ephemeral profile.** The ephemeral composition starts the same
`SignIn.Route` edge and custody, owned by the ephemeral composition and
stopped with it. It does not use the durable registry or exclusion plane.
`in_process.ex` currently reads `System.get_env(variable)` in the sensitive
caller. For a `:sign_in` route it instead calls `CredentialCustody.resolve/1`
on the route's custody reference. The reference is passed in host-private
model options next to the binding map, never in a request. `:missing`
refuses as `not_dispatched` with `provider_sign_in_required`, and `:expired`
as `not_dispatched` with `model_call_failed`. Everything else in ADR 0039's caller,
pool, cleanup and selected-value guard is unchanged.

**Daemon and service.**

- Composition refuses start with new exit statuses. ADR 0071 takes 111 to
  115, retiring 114, and ADR 0072 takes 116 to 119, so these follow at 120:
  - `provider_sign_in_required` (120);
  - `credential_store_unavailable` (121);
  - `credential_store_unsafe` (122).
  `sign_in_route_lost` (123) is a fail-stop when a running `SignIn.Route` edge
  exits, like `custody_lost`.
- `LoopexDaemon.ExitStatus`'s moduledoc range and the `fetch/1` and
  `classes/0` specs extend through 124. Today the moduledoc says 65 through
  110 while both specs say `65..111`
  (`apps/loopex_daemon/lib/loopex_daemon/exit_status.ex` :12, :81, :85); this
  edit makes all three state `65..124`. With ADRs 0071 and 0072 the daemon's status set is exactly 65 to 124
  except 114, which ADR 0071 retired: every other integer in that range maps
  to exactly one class, and `fetch/1` refuses 114. The assertion in
  `apps/loopex_daemon/test/command_test.exs`, which today checks
  `Enum.to_list(65..110)`, becomes `Enum.to_list(65..124) -- [114]`.
- Under the maintainer's 2026-10-13 decision, a sign-in route that is not
  ready at startup, because `Store.read/2` returns `absent` or
  `inconsistent` or metadata says `sign_in_required`, refuses start with
  `provider_sign_in_required` (120), leaving no socket. A revocation or
  logout while the service runs never stops it: refresher steps 6 and 7 make
  only that route's calls refuse.
- A transient refresh failure or `sign_in_lock_busy` at startup does not
  refuse start. The service serves and the route stays unavailable until a
  refresh succeeds.
- ADR 0037's start-on-demand presence check reads only the metadata file. It
  refuses `provider_sign_in_required` when the file is absent or
  `state != signed_in`, before starting anything.
- Readiness keeps ADR 0037's four states; sign-in state is reported by
  `auth status` and the diagnostic command, not by readiness.
- The service's environment is not consulted for sign-in routes, and no
  connected client can trigger a login or name a store.

**Command grammar.**

```text
loopex auth login  <provider> [--store auto|keychain|secret-service|file]
                              [--source loopex|adc] [--no-browser] [--device]
                              [--config FILE]
loopex auth status [<provider>] [--config FILE]
loopex auth logout <provider> [--local-only] [--config FILE]
```

- `<provider>` is `openai`, `gemini` or `anthropic`, mapping to the routes
  `chatgpt`, `vertex` and `claude`.
- The home comes from ADR 0037's resolution; `--config` selects the file
  whose `vertex` project the login checks. `auth` reads no session, starts no
  runtime and holds no placement lock.
- `--source adc` is `gemini` only. It signs in nothing. It validates gcloud's
  file under [the ADC grammar](#technical-adr-0073-adc), performs one refresh
  whose verified ID token supplies the subject, and writes only the metadata
  file.
- **Browser flow** (default). The command binds `127.0.0.1` on the profile's
  port or an ephemeral port, before opening the browser.
  - The OpenAI redirect is `http://127.0.0.1:<port>/auth/callback`; only the
    port may vary, and `localhost` is never substituted.
  - The Google redirect is `http://127.0.0.1:<port>`.
  - Each attempt uses a fresh 32-byte `state`, a nonce where OIDC applies,
    and a PKCE S256 verifier of 64 bytes.
  - The listener accepts exactly one request whose path and `state` match.
    It answers with a fixed page, closes and exits.
  - Any other request gets 404 and the listener keeps waiting. The wait is
    bounded at 300 s.
  - The browser is opened with `/usr/bin/open` on macOS and `xdg-open` on
    Linux. `--no-browser`, or a failed open, prints the URL instead.
- **Headless hosts.** The concept asks for the device flow where a provider
  supports it.
  - OpenAI's discovery document lists no device authorization endpoint.
  - Google's device flow does not admit `cloud-platform`.
  - So `--device` exits `sign_in_unavailable` for all three today, naming the
    alternative:
    - Run `--no-browser` and forward the printed loopback port with
      `ssh -L <port>:127.0.0.1:<port>`. This keeps the headless host's own
      `ext_agent_host_id`, as OpenAI's
      [self-hosted VM](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms)
      page expects.
    - For Gemini, alternatively run
      `gcloud auth application-default login --no-browser` with `--source adc`.
  - A provider profile that later lists a device endpoint gains the flow
    behind the same flag. The flow polls at the provider's `interval`, adds
    5 s on `slow_down`, and stops on `access_denied` or `expired_token`. It
    shows a `verification_uri` only when its host is in the profile's
    compiled allowlist.
- **OpenAI client registration.** OpenAI's
  [sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)
  page uses dynamic registration.
  - The first authorize request uses `client_id=dynamic_agent_client`,
    `agent_name_hint=<approved Loopex name>` and
    `ext_agent_host_id=urn:uuid:<v4>`. The host ID is generated once per home
    and stored in `<home>/auth/host-id`, mode `0600`.
  - The callback returns the issued `oaiapp_...` client ID. It is stored in
    metadata and reused for every later authorize, refresh and revocation.
    When the route's [generation floor](#technical-adr-0073-generation-floor)
    names an issued client, as after `auth logout`, the authorize request
    uses that `client_id` instead of `dynamic_agent_client`. Should the
    callback still return a different client, the login writes under it at
    a generation above the floor, and a running service refuses that pair
    as a changed client, named `sign_in_account_changed`, until restarted.
    That the callback returns the issued client, and that an authorize under
    an issued client is accepted, are verification items 11 and 12.
  - Scopes: `openid profile email offline_access resource.invoke
    chatgpt.tokens.use.direct`.
  - `resource=https://api.openai.com/v1` goes on authorize, exchange and
    refresh.
  - A response whose granted scopes lack `chatgpt.tokens.use.direct` fails
    `sign_in_failed` with the message that the account has no plan usage.
- **Google client.** The compiled desktop client ID, together with Google's
  non-confidential installed-app client secret where the console issues one,
  identifies Loopex.
  - Scopes: `openid email https://www.googleapis.com/auth/cloud-platform`.
  - Authorize and token requests carry `access_type=offline` and
    `prompt=consent`.
  - After sign-in, one bounded request reads the configured `vertex` project
    with the new access token: a `GET` of the compiled endpoint
    `https://cloudresourcemanager.googleapis.com/v3/projects/{project}` with
    `Authorization: Bearer` and `x-goog-user-project: {project}`, made by the
    `auth` command's in-host executor under its 30,000 ms and 65,536-byte
    bounds. It checks that the project accepts the token as its quota
    project; a failure is reported by class but keeps the sign-in.
- `status` reads metadata only: no secret, no network, no lock. It prints one
  line per configured or stored sign-in route: route, state, account label,
  backend, access and refresh expiry.
- `logout` takes the lock, reads the record, and revokes the refresh token at
  the profile's revocation endpoint through the in-host executor. It then
  writes the [generation floor](#technical-adr-0073-generation-floor) and
  deletes the secret and the metadata, in that order. The floor survives. `--local-only` skips
  revocation. A revocation failure still deletes locally and exits
  `revocation_unconfirmed`. For `adc`, logout writes the floor, deletes only
  Loopex's metadata and never touches gcloud's file.

Exit statuses of `loopex auth`, each with `loopex auth: <class>` on standard
error:

| Status | Class |
| --- | --- |
| 0 | Success; for `status`, every listed route is `signed_in` |
| 1 | Command-line refusal, with usage on standard error |
| 65 | `sign_in_unavailable`: route disabled in this build, or a flow the provider lacks |
| 66 | `sign_in_denied`: the provider returned `access_denied` |
| 67 | `sign_in_timed_out` |
| 68 | `sign_in_failed` |
| 69 | `credential_store_unavailable` |
| 70 | `credential_store_unsafe` |
| 71 | `credential_store_write_failed` |
| 72 | `provider_unreachable` |
| 73 | `sign_in_lock_busy` |
| 74 | `revocation_unconfirmed` |
| 75 | `sign_in_required`: `status` found a listed route not signed in, including one shown `sign_in_incomplete` |
| 76 | ADR 0037's auth-separation refusal: a protected credential directory (the auth directory or the ADC directory) and a selected state root overlap; the printed class is the one ADR 0037 defines |

**Inspection.** `config show` and the chat startup report show a sign-in
binding's form and source, for example `oauth (loopex)`. They also show the
`vertex` project and location. They never show availability, backend, label
or expiry, keeping ADR 0048's inspection rule.

<a id="technical-adr-0073-pairing"></a>
### Token Record, Pairing Rule and Recovery

Concept: [Account binding and recovery](0073-provider-oauth-sign-in.md#concept-adr-0073-account-binding).

**Record.** The secret record for a `loopex`-source route:

```json
{"version": 1, "route": "chatgpt", "home_digest": "0f3a...",
 "client_id": "oaiapp_...", "subject_digest": "sha256:...", "generation": 8,
 "access_token": "...", "refresh_token": "...", "token_type": "Bearer",
 "access_expires_at": "2026-10-13T18:00:00Z", "refresh_expires_at": "2026-11-12T17:00:00Z",
 "scopes": ["openid", "..."]}
```

- Each token is 1 to 65,536 bytes of `[A-Za-z0-9._~+/=-]`. The canonical JSON
  record is at most 196,608 bytes. The grammar is closed; a record that does
  not decode under it, including a value a killed keyring tool truncated, is
  undecodable.
- `subject_digest` is the SHA-256 of the issuer, a NUL and the subject taken
  from a verified ID token at the authorization-code exchange
  ([ID-token verification](#technical-adr-0073-id-token)). A refresh never
  changes it.
- `client_id` is the client that obtained the grant: OpenAI's issued
  `oaiapp_...` client or the compiled Google desktop client.
- `generation` is a positive integer; each write uses the next value.
- The record carries every metadata member except `backend`, `host_id`,
  `account_label`, `models` and `state`, so the metadata of the same account
  can be rebuilt from it. A rebuild happens only by `roll_forward`, where the
  metadata exists, so a rebuilt `chatgpt` metadata keeps its existing
  `models`.

**Pairing rule.** `Store.read(context, route)` reads the metadata and the
record and returns exactly one of:

| Result | When |
| --- | --- |
| `{:ok, record}` | Both decode, and they agree exactly on `route`, `client_id`, `subject_digest` and `generation` |
| `:absent` | Neither exists |
| `{:roll_forward, record}` | Both decode, they agree on `route`, `client_id` and `subject_digest`, and the record's generation is exactly the metadata's plus one |
| `:inconsistent` | Every other combination: metadata without a record, a record without metadata, the metadata's generation ahead of the record's, the record ahead by more than one, a different `subject_digest`, `client_id` or `route`, or either side undecodable |

Both mismatch directions are therefore refused: an old token never pairs with
a newer label, and a new account's token never pairs with an old account's
label. `read/2` never writes. Because `auth status` never reads a secret, it
shows the classification the last lock holder recorded in metadata.

**Recovery.**

- `roll_forward` is acted on only by a caller holding the route's refresh
  lock. It writes metadata at the record's generation from the record's
  members, keeping the existing `backend`, `host_id`, `account_label` and
  `models`, with
  `state: signed_in`, then uses the record. This recovers a refresh that
  crashed after the provider rotated the refresh token and after the secret
  write, so the rotated token is not lost.
- `inconsistent` makes the route unusable: composition refuses
  `provider_sign_in_required`, and a running refresher rotates custody to
  `nil` and logs `sign_in_incomplete`. A lock holder that finds an existing
  metadata file in an inconsistent pair sets only its `state` to
  `sign_in_incomplete`, keeping its generation, subject and client; nothing
  else deletes or overwrites either side. `auth login` repairs it by writing a fresh pair; `auth logout` deletes
  both sides.

**Write protocol.** `Store.write/4` runs only under the route's refresh lock:

1. Call `Separation.check(context)` on the context passed to `write/4`, and
   on no other paths; an overlap refuses before any backend is opened,
   spawned or written.
2. Read both sides and the
   [generation floor](#technical-adr-0073-generation-floor). The next
   generation is one more than the largest of the record's, the metadata's
   and the floor's generation present, or 1 when none is.
3. Write the record at that generation. A keyring backend then reads the item
   back and compares bytes; a failed or different read-back exits
   `credential_store_write_failed` with the metadata untouched.
4. Write the metadata at the same generation with the file backend's atomic
   rename.

A crash after step 3 and before step 4 leaves the record one generation
ahead. For the same account and client that is `roll_forward`. For a login
of a different account over an existing one, it is `inconsistent`: the old
account's label is never paired with the new account's token, and a service
still running the old account refuses its next refresh without writing.
`/usr/bin/security add-generic-password -U` replaces one item, so a killed
tool leaves either the old or the new record; a Secret Service store cut short
leaves an undecodable value; the file backend's rename leaves the old or the
new file. Each is classified by the table above. `delete/2` removes the record
and then the metadata; a crash between them leaves metadata without a record,
which is `inconsistent` until `auth logout` is run again.

<a id="technical-adr-0073-id-token"></a>
### ID-Token Verification

Concept: [Context and decision](0073-provider-oauth-sign-in.md#concept-adr-0073-decision).

**Owner.** `Loopex.LLM.ReqLLM.SignIn.IdToken.verify/4` is the single
verifier: a pure function over the compact token, the route's profile, a key
set and the expected values (client ID, nonce, current time). It uses OTP's
`:public_key` and `:crypto` and the `Jason` decoder the adapter already
depends on. No JWT or JOSE library is added; `mix loopex.deps_budget` stays
unchanged. `:public_key` joins `:crypto` in the owning app's
`extra_applications`.

**Where it runs.** In the host process that receives the token response: the
`auth` command's `:sensitive` exchange process, or the durable or ephemeral
`SignIn.Route` refresher when an ADC file was replaced. The companion returns
the ID token unverified on its private channel; it does not verify.

**When it is required.**

- At every authorization-code exchange. A login whose ID token fails
  verification writes nothing and exits `sign_in_failed`.
- At the first refresh of a replaced ADC file
  ([the ADC source](#technical-adr-0073-adc)).
- Never on a refresh of a stored grant. A refresh grant cannot change
  account, so a refresh-response ID token is discarded unverified and is never
  used for identity.

**Checks.** All must hold, else `sign_in_failed`:

1. The compact form has three base64url segments, at most 16,384 bytes in
   total, decoded without padding.
2. The header is a closed object: `alg` is exactly `RS256`; `kid` is a string
   of 1 to 256 bytes; `typ`, if present, is `JWT`. Any `jku`, `jwk`, `x5u`,
   `x5c` or `crit` member is refused, as is every other algorithm, `none` and
   the HMAC family included.
3. The key is the one entry with that `kid` in the key set for the profile's
   issuer. The RSA signature over the first two segments verifies with
   `:public_key.verify/4` using SHA-256.
4. `iss` equals the profile's issuer: `https://auth.openai.com` for OpenAI;
   `https://accounts.google.com` or `accounts.google.com` for Google, which
   documents both.
5. `aud` is the expected client ID, as a string or a one-element list. For
   an authorization-code exchange that is the Loopex client that obtained
   the grant: OpenAI's issued `oaiapp_...` client or the compiled Google
   desktop client. For the `adc` source it is the `client_id` of the ADC
   file that was read for that refresh, the client the refresh posted under
   the [ADC exception](#technical-adr-0073-adc); a token whose audience is
   any other client, the compiled Google desktop client included, is
   refused.
6. `exp` is later than now minus 60 s; `iat` is no later than now plus 60 s.
7. `nonce` equals the attempt's nonce on the authorization-code path.
8. `sub` is a string of 1 to 255 bytes. Its digest is the
   `subject_digest` the [pairing rule](#technical-adr-0073-pairing) binds.

**Keys.** Each profile compiles its issuer together with exactly one JWKS
URI, read from the provider's discovery document on 2026-10-13: OpenAI
`https://auth.openai.com/.well-known/jwks.json`; Google
`https://www.googleapis.com/oauth2/v3/certs`. Both documents list only
`RS256` as the ID-token signing algorithm. A key set from one profile never
verifies another profile's tokens.

- Retrieval is a credential-free `GET` made in-host with `Req`: HTTPS only,
  redirects off, 10,000 ms bound, a body of at most 65,536 bytes. A failure is
  `provider_unreachable`.
- The set admits at most 16 keys. Only `kty: RSA` keys with `use` absent or
  `sig`, `alg` absent or `RS256`, a 2,048- to 4,096-bit modulus and a public
  exponent of 65,537 are kept; other entries are ignored.
- The verifying process caches the set in memory for the response's
  `Cache-Control: max-age`, capped at 86,400 s, or 3,600 s when absent.
- An unknown `kid` causes at most one refetch, no more often than once per
  60 s per profile, which is how a provider's key rotation is followed. A
  `kid` still unknown after it is `sign_in_failed`.

<a id="technical-adr-0073-refresh-merge"></a>
### Refresh-Response Rules

Concept: [Context and decision](0073-provider-oauth-sign-in.md#concept-adr-0073-decision).

A refresh response is merged into the record as follows:

| Member | OpenAI | Google (`loopex` and `adc`) |
| --- | --- | --- |
| `access_token`, `expires_in` | Required | Required |
| `refresh_token` | Required: OpenAI rotates it on every refresh and the prior one may already be invalid. An absent one is `sign_in_failed` with no write | Optional. Absent keeps the prior one. For `adc` a returned one is ignored, because Loopex never writes gcloud's file |
| `id_token` | Discarded unverified | Discarded unverified for an unchanged grant; required and verified for a replaced ADC file |
| `scope` | When present, must still include `chatgpt.tokens.use.direct` | When present, must still include `cloud-platform` |

`subject_digest` and `client_id` never change on refresh. `access_expires_at`
is computed from `expires_in`; no fixed lifetime is assumed. An `expires_in`
below 10 is `sign_in_failed` with no write, and custody follows the
[custody deadline](#technical-adr-0073-custody-deadline) rule.

<a id="technical-adr-0073-adc"></a>
### The ADC Source

Concept: [Context and decision](0073-provider-oauth-sign-in.md#concept-adr-0073-decision).

**Backend.** `adc` is its own member of the metadata `backend` enumeration.
Loopex stores no token for it. Its metadata is:

```json
{"version": 1, "route": "vertex", "backend": "adc",
 "client_id": "...apps.googleusercontent.com", "subject_digest": "sha256:...",
 "adc_digest": "sha256:...", "account_label": "a***@example.com",
 "access_expires_at": null, "refresh_expires_at": null,
 "generation": 3, "state": "signed_in"}
```

`adc_digest` is the SHA-256 of the file's `client_id`, a NUL and its
`refresh_token`. It identifies the grant without storing it; the refresh token
is high-entropy, so the digest discloses nothing usable. The access token
lives only in custody memory.

**Client identity.** The maintainer decided on 2026-10-13 that the `adc`
source is the one exception to decision 3: it presents the `client_id` and
`client_secret` that gcloud wrote into the ADC file, because Application
Default Credentials are Google's documented mechanism for any application
to use the credentials the user granted gcloud. The exception is bound to
this source: no other source or route reads a client from a file, the
`loopex` source of `vertex:` uses the compiled Loopex client, and
`chatgpt:` and `claude:` never present a client Loopex was not issued. The
metadata's `client_id` is the file's, and ID-token check 5 expects it.

**File grammar.** The file is `<G>/application_default_credentials.json`,
where `<G>` is the second member of the sign-in context's
`protected_directories`, ADR 0037's ADC directory `$HOME/.config/gcloud`
for the effective user as `LoopexCli.Home` computed it. `auth login` and
the `SignIn.Route` refresher derive the path from the context they were
given, never from `HOME` or the environment: ADR 0037 lets only
`LoopexCli.Home` read `HOME`, and composition never does.
`GOOGLE_APPLICATION_CREDENTIALS` and `CLOUDSDK_CONFIG` are never consulted,
so the service's environment cannot redirect it.

- The final path component is a regular file, not a symlink, owned by the
  effective user, with no group or other write bit; otherwise
  `credential_store_unsafe`.
- It is at most 65,536 bytes of UTF-8 JSON: one object, no duplicate keys,
  every value a string.
- Required: `type` exactly `authorized_user`; `client_id` and
  `client_secret`, each 1 to 256 bytes of printable ASCII; `refresh_token`
  under the token grammar.
- Optional: `quota_project_id`, ignored because billing uses the configured
  `vertex` project; `universe_domain`, which must be `googleapis.com`;
  `account`, ignored.
- Any other member, nested value or failed check is `sign_in_failed` with the
  detail `adc_invalid`. A later gcloud field is therefore refused by name, not
  silently accepted.
- `client_secret` is Google's non-confidential installed-app secret. It still
  travels only in the credential frame with the refresh token and never enters
  metadata or a diagnostic.

**Refresh.** Every refresh rereads and validates the file, then posts
`grant_type=refresh_token` with its client ID, secret and refresh token
through the host's exchange executor. Loopex never writes gcloud's file, and
an unchanged Google refresh token stays valid, so concurrent processes may
refresh independently. The route's lock is taken only to write metadata.

- **Unchanged grant** (`adc_digest` equals the metadata's): the subject is
  the stored one, and an absent ID token changes nothing.
- **Replaced file** (`adc_digest` differs, as after another
  `gcloud auth application-default login`): the response's ID token is
  required and verified. The new access token enters custody only after that.
  The same subject writes metadata at the next generation with the new
  `adc_digest`. A different subject is `sign_in_account_changed`: custody
  stays `nil` and metadata is unchanged. An absent ID token is
  `sign_in_failed`, with custody `nil`.
- **File absent** (as after `gcloud auth application-default revoke`), or
  `invalid_grant`: `state: sign_in_required`, custody `nil`.

**Startup.** A `SignIn.Route` for `adc` reads the metadata and the file and
refreshes once, because no access token is stored. A transient failure serves
with the route unavailable, like any other transient refresh failure.
`auth login gemini --source adc` performs the same validation and one
refresh, requires a verified ID token, and writes metadata. That gcloud's
default application-default login grants `openid`, so that Google returns an
ID token, is [verification item 7](#technical-adr-0073-verification); a file
whose refresh returns none is refused with `sign_in_failed`.

<a id="technical-adr-0073-reply-ceiling"></a>
### Ceiling Enforcement in the Stream Drain

Concept: [The `chatgpt:` reply ceiling](0073-provider-oauth-sign-in.md#concept-adr-0073-reply-ceiling).

**Where.** The rule is one module, `Loopex.LLM.ReqLLM.ReplyCeiling`: a pure
reducer that takes the ceiling and each streamed text or tool-call fragment
and answers either admit, or halt with the admitted prefix. It is a separate
module because exactly two transports call it and neither can call the
other's drain; it holds no transport, process or progress logic.

- **Companion caller.** In the durable hosts the companion worker's transport
  path reaches `Loopex.LLM.ReqLLM`'s private `drain/5` from `handoff/6`
  through `ReqLLM.stream_text/3`
  (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm.ex`). For `chatgpt`,
  `drain/5` folds each chunk through `ReplyCeiling` before `emit/2`. On halt it
  calls `ReqLLM.StreamResponse.close/1`, which runs the response's `cancel`
  function, stopping the `StreamServer` and its HTTP task, and stops the
  metadata handle. The worker then builds the reply as the rule below says.
  The companion process exits after the invocation as today, so no stream
  process outlives it. `reply_from_stream/4` shares `drain/5` and so the rule.
- **In-process caller.** The ephemeral profile's sensitive caller today
  completes every route with the buffered `ReqLLM.generate_text/3`
  (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/in_process.ex`), through
  `Loopex.LLM.ReqLLM.OneShotHTTP1` on the tagged pool. That cannot serve
  `chatgpt`, which requires `stream: true`. Nor can `ReqLLM.stream_text/3`:
  ReqLLM's streaming path starts a linked `StreamServer` and calls
  `Finch.stream/5` on its own `ReqLLM.Finch` pool, outside the one-shot
  adapter and tagged pool whose teardown ADR 0039's cleanup proof depends on.
  So `chatgpt` in-process follows the existing Anthropic native pattern:
  - the caller renders the Responses request itself, with `stream: true`, and
    places it in the caller-private native-request slot that the private
    native-request step of `OneShotHTTP1` already reads for Anthropic;
  - `OneShotHTTP1`'s response collector, for a `chatgpt` fingerprint, parses
    the SSE body incrementally and folds each `response.output_text.delta`
    and function-call argument delta through `ReplyCeiling`. The collector
    keeps its existing bound of 8,388,608 raw response bytes
    (`@max_body`), which counts every SSE event and its JSON framing, not
    only reply text. When the raw bytes would pass that bound before
    `ReplyCeiling` halts and before `response.completed`, the collector
    halts as it does today with `Req.TransportError` reason
    `:loopex_response_too_large`, and the caller answers
    `{:error, {:dispatched_or_unknown, "model_call_failed"}}`, not a `limit`
    reply;
  - on halt the collector stops receiving and returns the admitted text. The
    owner's existing teardown closes the worker connection and proves the
    tagged pool subtree gone before the caller sends its result, exactly as
    for every other in-process failure or completion. Cancellation and join
    are therefore the profile's existing ones; no new process is started.
  - The in-process caller emits no progress. `InProcess.complete/3` passes
    no progress function to its callback today, and a `chatgpt` reply, like
    every in-process reply, reports zero deltas.
- The native Anthropic transport's own drain serves its routes and is
  unchanged.

The selected-credential echo guard runs over the built reply in both callers,
as it does today. The two callers share the ceiling rule; only the
in-process caller has a raw-byte bound. The companion's `drain/5` streams
through ReqLLM with no raw-byte bound of its own, so there the ceiling or
`response.completed` always ends the reply. In the in-process caller a
ceiling large enough that the stream's raw bytes reach 8,388,608 first ends
the attempt as the dispatched model-call failure above.

**Rule.** For a request whose route is `chatgpt`, and only then:

1. The ceiling is `Loopex.Model.max_tokens(request)`, the committed value.
   Nothing is sent to the provider for it.
2. The drain keeps a running estimate with `Loopex.Bounds.estimate/1`, one
   token per three bytes rounded up (`apps/loopex/lib/loopex/bounds.ex`
   :313), over the streamed text bytes plus the streamed tool-call name and
   argument bytes. It is the estimator Core already uses for bounds. For
   English text and code it usually counts more tokens than the provider's
   tokenizer; for multi-byte scripts it can count fewer. The ceiling bounds
   the estimate, not the provider's count.
3. Before admitting a text fragment, the drain checks whether admitting it
   would make the estimate exceed the ceiling. If so, it admits the longest
   prefix of the fragment, cut on a UTF-8 character boundary, that keeps the
   estimate at or below the ceiling. The companion caller emits that prefix
   as progress; the in-process caller emits none. Then the caller halts. A tool-call fragment that would exceed it halts without admitting
   the fragment.
4. On halting, the caller cancels the response stream as described above for
   its transport, which closes the connection, and does not wait for
   `response.completed`. It skips the
   completion check that requires that event and builds the reply with
   `Mapping.reply/6`, with these values:
   - `completion` `"limit"`;
   - `text`, the admitted text;
   - `tool_calls` `[]`, because a call streamed before the cut was never
     confirmed by the provider and its arguments may be incomplete;
   - `usage` with nil input and output tokens, because the provider reported
     none, so Core accounts the attempt as estimated, as it does any reply
     without reported usage.
5. A stream that reaches `response.completed` below the ceiling is classified
   as before. A provider-reported output-limit stop is still `limit`.

**Consequences.** The attempt settles as a `dispatched_or_unknown` reply with
completion `limit`. Core, compaction and the summarizer already handle that
completion. The plan is still charged for whatever the provider generated
before the connection closed. Reasoning tokens are not streamed as text and
are not counted; the ceiling bounds the visible reply. The plan's weekly cap
bounds spend. The echo guard and every other drain rule apply unchanged to
the admitted text. A maintenance summary on `chatgpt:` reaches the same rule
through whichever caller its profile uses: the companion in durable hosts,
the in-process caller in the ephemeral profile.

<a id="technical-adr-0073-failure-reason"></a>
### Reason, Schemas, Vectors and Core Handling

Concept: [The public failure reason](0073-provider-oauth-sign-in.md#concept-adr-0073-failure-reason).

**Producing the reason.** For a route whose catalog credential kind is
`:sign_in`, a custody resolution of `:missing` is answered before dispatch
with `{:error, {:not_dispatched, "provider_sign_in_required"}}`. Custody is
`:missing` after `sign_in_required`, an account change or a logout.
`:expired`, which a token that lapsed while the provider was unreachable
produces, stays `{:not_dispatched, "model_call_failed"}`. An `env` route
never produces the new reason. Two producers exist:

- *Durable hosts: the parent guardian.* Custody is resolved in the parent,
  never in the companion. The guardian in
  `apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/provider_bridge.ex` first
  launches the companion (`ProviderLauncher.start/5`, :723-735), and its
  credential sender then resolves custody and reports
  `{:credential_phase_result, ..., :custody, {:error, reason}}` for
  `:missing` or `:expired` (:1285-1292). Today the guardian's catch-all
  `credential_phase_result/3` clause (:1530) calls `fail/1`, which collapses
  every refusal to `@not_dispatched`, `model_call_failed` (:1611), because
  `possible_delivery` is still `false`; it becomes `true` only when the
  invocation frame is sent (:1558). The change adds one guardian clause for
  the custody phase: `{:error, :missing}` on a route whose credential kind,
  carried in the guardian state from the selected route's configuration, is
  `:sign_in` sets the result to `{:error, {:not_dispatched,
  "provider_sign_in_required"}}` and enters the same cleanup `fail/1` uses,
  so the launched companion's cleanup proof completes before the result is
  sent. The clause asserts `possible_delivery` is `false`; every other
  custody refusal still reaches `fail/1` unchanged. `worker_invoke/4`
  (`req_llm.ex` :302) runs inside the companion, receives only a resolved
  credential and never produces the reason.
- *Ephemeral profile: the in-process caller* in `in_process.ex`, as
  [the ephemeral profile](#technical-adr-0073-decision) specifies.

`provider_bridge_test.exs` (extended) proves, through the real guardian and
companion: custody `:missing` on a `:sign_in` route returns
`{:not_dispatched, "provider_sign_in_required"}` after the cleanup proof with
no invocation frame sent; `:expired` on the same route and `:missing` on an
`env` route return `{:not_dispatched, "model_call_failed"}`.

**Precedence.** A termination that has already won takes precedence over
the reason, as over every model-call failure. The settlement cell admits the
category with an `abort` or `deadline` termination
(`apps/loopex/lib/loopex/runtime/provider_attempt.ex` :857-868 is the
existing `model_call_failed` cell it mirrors), and the run's terminal outcome
then follows the termination: `cancelled` for `abort` and `bound_reached` for
`deadline` (`apps/loopex/lib/loopex/runtime/control.ex` :1548-1551). Only
with no termination does the run end `failed` with reason
`provider_sign_in_required`; the attempt record names the category in every
case.

**Core.** These changes are in `apps/loopex` and only admit one more closed
string:

- `Loopex.Runtime.SessionCoordinator`'s model-result acceptance admits
  `{:not_dispatched, "provider_sign_in_required"}` beside the existing
  `{:not_dispatched, "model_call_failed"}`. Any other term is still
  ambiguous.
- `Loopex.Runtime.ProviderAttempt`'s `settlement_cell/4` gains one cell: the
  result `{"kind" => "error", "category" => "provider_sign_in_required"}`
  with transport `not_dispatched`, on any legal attempt (1 or 2 under the
  delivered `@attempt_limit` of 2), with no termination or an abort or
  deadline termination. Its conversation is `none`, its accounting source
  `none` and its next step always `terminal`: there is no retry, because a
  retry would meet the same refusal. Every other combination is invalid
  history. The retry machine is unchanged: an attempt-one
  `not_dispatched`/`model_call_failed` with no termination still selects
  `retry`, and that retry may legitimately observe the route's custody
  `:missing`, because the refresher received `invalid_grant` or a logout
  between the two attempts. Attempt two then settles terminal with
  `provider_sign_in_required`.
- `Loopex.Runtime.SessionState` ends the run `failed` with `reason`
  `provider_sign_in_required` and `failure` nil. A maintenance or compaction
  run's failure is `{"category": "provider_sign_in_required", "retryable":
  false}`.

**Protocol.** `LoopexProtocol.Session.Outcome` admits the reason in the
`failed` reason set it enforces today, which holds `model_call_failed` and
`unreadable_model_answer`. `LoopexProtocol.Session.CompactResult` admits the
category. Under `apps/loopex_protocol/priv/schema`:

- `loopex-experimental-3.json` and `loopex-experimental-4.json`: each
  `failure.simple.categories` list gains `provider_sign_in_required`, three
  occurrences in each file. The embedded `chat_terminal_outcome` definition
  gains a `failed_reasons` list of `model_call_failed`,
  `unreadable_model_answer` and `provider_sign_in_required`, so that the
  schema states the set the decoder enforces.
- `chat-terminal-outcome.v1.json` gains the same `failed_reasons` list.
- `session-snapshot.v3.json`, `standalone-compact-result.v1.json` and
  `standalone-compact-completion.v1.json`: each `failure.simple.categories`
  list gains the category.

Under `apps/loopex_protocol/priv/vectors`:

- `chat-terminal-outcome.v1.json` gains a `provider_sign_in_required` case
  and a refused case with a nonnull `failure`.
- `standalone-compact-result.v1.json` and
  `standalone-compact-completion.v1.json` gain a failure case with the
  category.
- `loopex-experimental-3.json` and `loopex-experimental-4.json` gain a run
  terminal event carrying the reason.
- `current-contract-manifests.v1.json` and `canonical-schema-proof.v1.json`
  are regenerated for the changed schema bytes in the same change.

The generation names stay `loopex.experimental/3` and `/4`. Before 1.0 only
the current contract is kept. The independent Node client in the release
check decodes the new vectors.

**Client-visible behavior.**

- Every client receives the terminal outcome `failed` with `reason`
  `provider_sign_in_required` and nothing else new.
- The reference chat and `ask` print one line, `loopex: provider sign-in
  required for route ROUTE; run loopex auth login PROVIDER, then continue`,
  where the route comes from the committed model's prefix. The session stays
  resumable, and the command's exit status is that of any failed run.
- A chat attached to the daemon under ADR 0071 prints the same line.
- Nothing retries automatically. After `auth login`, the running service
  adopts the token within 30 s (refresher step 7), and the next turn or
  resume dispatches normally.


<a id="technical-adr-0073-threats"></a>
### Threat Model

Concept: [Observable consequences](0073-provider-oauth-sign-in.md#concept-adr-0073-consequences).

| Threat | Mitigation | Residual |
| --- | --- | --- |
| Another local user reads tokens | Keychain and Secret Service are per user; the file backend requires a `0700` directory, a `0600` file and the same owner, with no symlinks | `root` and anyone with the user's account |
| A same-user process, including a host-authorized tool job, reads tokens | None structural. Items created through `/usr/bin/security` trust that tool, and any same-user process can run it. Secret Service answers any client on the session bus. The file is readable by the user | Equal to today's ambient API key in the invoking shell. Loopex never injects tokens into jobs, and the local executor environment still excludes credential names. Untrusted workspaces need OS isolation of the hand |
| Disk theft, home-directory copy or dotfile sync | Keyring backends encrypt at rest. ADR 0037's separation invariant and its physical walk check keep the auth directory, the ADC directory and every state root disjoint, so tokens never enter backups | The file backend is plaintext at rest; `auth login` says so |
| Authorization-code interception | PKCE S256, a fresh `state` and nonce, a listener bound to `127.0.0.1` before the browser opens, an exact path, and one request only | A same-user process racing the port can at most receive a code it cannot redeem without the verifier |
| Device-code phishing | `verification_uri` shown only for allowlisted provider hosts | — |
| Endpoint substitution | Compiled HTTPS endpoints per profile. No configuration or environment override; a test-only fake server is injected under `Mix.env() == :test` only | — |
| Refresh-token reuse race | Cross-process lock, no exchange without it, re-read before exchange, generation adoption; a failed record write after a successful exchange keeps the new record in the refresher's `:sensitive` state and retries only the write | A crash after the provider's rotation and before the record write, or a stop while that write is still pending, loses the new token, so the route needs sign-in again; a crash after the record write is recovered by `roll_forward` |
| Leak into logs, traces or crash dumps | `:sensitive` custody, refresher and exchange processes; `format_status` redaction as in `CredentialCustody`; tracing exclusion; the companion executor in durable hosts; logger off and crash dumps disabled in `auth`; closed failure classes only | ADR 0039's host-VM audience in the ephemeral profile and `auth` |
| Provider echoes a token | The existing exact-match echo guard on the access token | Split or encoded echoes, as today |
| Forged identity token or substituted signing key | `RS256` only, keys only from the issuer's compiled JWKS URI, closed header, bounded rotation refetch | A compromise of the provider's own keys |
| A crash between the two halves of a write | The pairing rule refuses both mismatch directions; same-account `roll_forward` under the lock | A different-account cut needs `auth login` again |
| Impersonating another client | Only Loopex's own client identities, except the `adc` source's client read from gcloud's file under the maintainer's exception; source scan for forbidden ReqLLM options | — |
| Runaway spend | The plan's per-app weekly cap; credit overflow only if the user allows it; the Google project's budgets | Operator-owned |

<a id="technical-adr-0073-evidence"></a>
### Evidence

Concept: [Observable consequences](0073-provider-oauth-sign-in.md#concept-adr-0073-consequences).

A test-only fake OAuth and model server, `test/support/fake_oauth_server.ex`
in `loopex_composition`, serves every flow. It uses `:gen_tcp` with
fixed-response handlers, like the existing provider fixtures, and can produce
rotation, `invalid_grant`, `slow_down`, delay and malformed replies. All tests
use temporary homes and never touch a real keyring.

| File | Cases |
| --- | --- |
| `apps/loopex_llm_reqllm/test/sign_in_profiles_test.exs` | Compiled endpoints, issuers and JWKS URIs are HTTPS and per profile; no override path outside tests. A source scan finds no `oauth_file`, `auth_file`, `oauth_http_options`, `with_claude_subscription`, `codex_originator`, `openai_codex` or `refresh_oauth_credentials` in Loopex source, and no Codex CLI or Claude Code client ID; no `:req_llm, :google_vertex` application configuration in any `config/` file or app. Token-response validation (issuer, audience, scopes, bounds). `claude` is disabled without a sanctioned profile |
| `apps/loopex_llm_reqllm/test/sign_in_routes_test.exs` | The binding grammar's alternatives, pointers and classes. `oauth` on existing routes and `env` on sign-in routes refuse. `vertex` project and location vectors. Per-route sealed headers, including the `vertex` request's exact `x-goog-user-project` on the companion and in-process callers, and a `vertex` call with an empty token, project or region refused before ReqLLM is called. `chatgpt` model admission at composition and switch. The `chatgpt` mapping never sends rejected members and always streams with `store: false` |
| `apps/loopex_llm_reqllm/test/sign_in_id_token_test.exs` | Against test RSA keys generated with `:public_key`: a valid RS256 token verifies and yields the subject digest; a forged signature, an altered payload, `alg` `none`, `HS256` signed with the public key as an HMAC secret, `ES256`, and `jku`, `jwk`, `x5u`, `x5c` or `crit` headers are refused; wrong issuer (both Google forms accepted), wrong or multi-member audience, and for the `adc` source an audience equal to the compiled Google desktop client or to any client other than the ADC file's `client_id`, while the file's own `client_id` verifies, expiry, `iat` in the future and nonce mismatch are refused; an unknown `kid` refetches once and verifies after rotation, a still-unknown `kid` is refused, and a second unknown `kid` within 60 s does not refetch; an over-bound or non-RSA key set, a redirect from the JWKS URI and a fetch timeout are refused, the last as `provider_unreachable`; a profile's key set never verifies another profile's token |
| `apps/loopex_composition/test/sign_in_store_test.exs` | File backend: modes, owner, symlink refusal on `*.secret`, `*.json`, `*.floor` and `host-id`; stale `.tmp` cleanup; a refresh that creates the lock namespace under the process umask followed by a successful `Store.read/2` and `auth status`. Generation floor: its closed grammar, an invalid floor refused `credential_store_unsafe`, logout writing the maximum generation and never lowering it, and the next write's generation above it. The metadata path never reads a secret. The pairing table, every row: metadata ahead of the record; the record ahead by one for the same account (`roll_forward`) and for a different subject or client (`inconsistent`); ahead by two; each side alone; an undecodable record, including a truncated Secret Service value. Write cuts after the record and before the metadata, on the file backend and on each keyring backend through its recording fake executable, for a same-account refresh and for a login of a different account over an existing one; a failed keyring read-back exits `credential_store_write_failed` with the metadata unchanged; `roll_forward` acted on only under the lock. **Separation before backend access:** each case builds the real sign-in context map over real temporary directories, the shape `LoopexCli.Home.sign_in_context/1` returns, with no test-only option or hook in the store; `Separation.check/1` passes on it, and the filesystem is then changed so the auth directory lies inside a listed root (a symbolic link replacing an ancestor of the auth directory) or contains one (the root's path created under it). `write/4` then returns `{:error, {:auth_root_overlap, pointer}}` with that root's pointer; the file backend creates no file, temporary or directory, and the keychain and Secret Service backends' recording fake executables record no invocation. A context of the wrong shape refuses the same way |
| `apps/loopex_composition/test/sign_in_adc_test.exs` | A gcloud-shaped `authorized_user` fixture: restart rereads the file, refreshes and keeps the subject; an absent ID token on an unchanged grant keeps the subject; a response without `refresh_token` keeps using the file's; malformed files (missing member, wrong `type`, extra member, nested value, over-bound, symlink, other owner, group-writable, another `universe_domain`) are refused; a replaced file for the same account is adopted at the next generation without restart; a replaced file for another account is `sign_in_account_changed` with custody `nil`; a replaced file whose refresh returns no ID token is refused; a deleted file is `sign_in_required`; the refresh posts the file's own `client_id`, and a replaced file's ID token whose `aud` is not that `client_id` is `sign_in_failed` with custody `nil` and metadata unchanged; the refresher, given a sign-in context whose `protected_directories` names a temporary `G` while `HOME` names another directory holding a different ADC file, reads only `<G>/application_default_credentials.json`; `GOOGLE_APPLICATION_CREDENTIALS` and `CLOUDSDK_CONFIG` are ignored; logout leaves gcloud's file untouched |
| `apps/loopex_composition/test/sign_in_keychain_test.exs` | Tagged `:macos_keychain`, against a temporary keychain named through the test-only `:sign_in_test_keychain` key: round trip, overwrite, delete, and a maximum-size record (262,144 base64url bytes on one `security -i` line); the secret never appears in any spawned argv, checked through an argv-recording wrapper. A source check finds the keychain key read only under `Mix.env() == :test` |
| `apps/loopex_composition/test/sign_in_secret_service_test.exs` | Tagged `:secret_service`, under `dbus-run-session` with a throwaway keyring: round trip and availability probe with the bus passed only through the context's `secret_service_bus`; a locked collection is unavailable within 5,000 ms. Untagged, a recording fake executable proves the wrapper's argv, standard-input bytes and child `DBUS_SESSION_BUS_ADDRESS` equal to the context value while the test VM's own variable names another address; a `nil` bus is unavailable without spawning; a composition whose metadata names `secret_service` with the backend unavailable refuses `credential_store_unavailable`; `auth login --store auto` over such metadata exits 69 and writes no file |
| `apps/loopex_composition/test/sign_in_refresh_test.exs` | Refresh at the window, including a short `expires_in`. **Custody deadline**, through the real refresher and `CredentialCustody.resolve/1`: a fresh 30 s token from the fake server resolves `{:ok, _}` as soon as custody starts and is refreshed at 15 s; with the server then unreachable it still resolves until 22,500 ms after `t0` and `:expired` after it; **delayed response**: a 10 s token whose response the fake server delays by more than 7,500 ms after the request reaches it (so verification and the write finish after `t0` + 7,500 ms) enters custody past its deadline, `CredentialCustody.resolve/1` returns `:expired` on the first call, a model call on the route refuses before dispatch with no provider request carrying that token, and the refresher's next refresh is due at once, a repeated delay following step 5's transient schedule; a token with `expires_in` 9 is `sign_in_failed`, at login with nothing written and at refresh with nothing written and custody unchanged. A refresher whose context's auth directory is moved inside a listed root after start exchanges nothing and rotates custody to `nil`; rotation persisted; `invalid_grant` → `sign_in_required` and custody `:missing`; transient retry schedule; expiry while unreachable → `:expired` refusal. Two OS processes on one home perform exactly one exchange, the other adopting. Stale lock reclaim. Account change refused; same-account re-login adopted within 30 s; logout reaches custody `nil`. **Different-account write cut:** a service running account A; `auth login` for B is killed after its record write; the service's next refresh exchanges nothing, writes nothing and rotates custody to `nil`, B's record bytes are unchanged, a new composition refuses `provider_sign_in_required`, `auth status` shows `sign_in_incomplete`, and rerunning the login repairs it. **Restart before metadata publication:** a refresh at which the fake server rotates and invalidates the old refresh token is killed after its record write; a restarted composition rolls the metadata forward and refreshes with the rotated token; the invalidated token is never presented again. Refresh-response rules: an OpenAI response without `refresh_token` fails with no write; a Google response without `refresh_token` or `id_token` keeps the prior refresh token and subject; a refresh-response ID token is never used for identity. **Write failure after exchange:** with the fake server rotating and invalidating the old refresh token and the store failing its write, custody resolves the new access token, the fake server sees no second exchange while the write is pending, each retry follows step 5's schedule and emits one `sign_in_store_write_pending` line naming the class and no token, the write succeeds once the store recovers at the next generation, and a refresher stopped before that leaves the route needing sign-in with the invalidated token never presented. **Lock busy:** a lock held by another OS process across a delayed 30,000 ms exchange makes the refresher's acquisition fail `sign_in_lock_busy` after 10,000 ms with no exchange, no write and custody unchanged, and its retry adopts the holder's record without contacting the provider. **Logout then login:** a running refresher reaches custody `nil` and stops its schedule after `auth logout`; `auth login` for the same account then writes a generation above the floor under the floor's client; the refresher adopts it within 30 s, resolves the new token and refreshes again at the next window. `chatgpt` model list refreshed after each refresh and adoption; a failed refresh-time listing keeps the previous list, never `null`, and names `sign_in_model_list_stale` |
| `apps/loopex_cli/test/auth_command_test.exs` (separation) | `auth login` exits 76 before any token write when the auth directory or the ADC directory and a selected state root overlap in either direction, with the context built by `LoopexCli.Home` from a temporary `HOME` and the selected file; a durable composition with an `oauth` binding and no context refuses `provider_sign_in_required` |
| `apps/loopex_composition/test/credential_plane_test.exs` (extended) | A sign-in route's custody is registered like an `env` route. Two canaries (access and refresh) never appear in journals, public events, progress, diagnostics, traces, executor job environments or resource subprocess environments. An invocation during rotation uses exactly one token |
| `apps/loopex_llm_reqllm/test/provider_bridge_test.exs` (extended) | The `token_exchange` and `model_list` invocations: credential frame, bounds, closed failure classes, no raw body crossing, cleanup proof. The guardian's custody-phase producer of `provider_sign_in_required` and its `model_call_failed` counterparts, as [producing the reason](#technical-adr-0073-failure-reason) lists. The access-token echo guard withholds a reply containing the token |
| `apps/loopex_cli/test/auth_command_test.exs` | Grammar and every exit status. Loopback: state mismatch, wrong path, denial, timeout, port already bound. `--device` refusal text. A login whose ID token fails verification writes nothing. `status` makes no secret read and no network call. `logout` revoke success, failure and `--local-only`, each leaving the floor. A login after logout authorizes under the floor's issued client. A login whose `model_list` fails writes no record, metadata or floor and exits 68 for a malformed or over-bound list and 72 for a transport failure, timeout or non-2xx status (D25). The ADC metadata path |
| `apps/loopex_cli/test/daemon_sign_in_test.exs` | Statuses 120 to 123, each refused start leaving no socket; a sign-in route absent, inconsistent or `sign_in_required` at startup refuses 120; start-on-demand presence check; revoked mid-service → next call `not_dispatched` with no fallback to another route, other routes still served, and the attached client's terminal outcome is `failed` with `provider_sign_in_required` and the `auth login` hint; re-login adopted and the next turn succeeds without restart; **logout then login** in sequence while the service runs: the next call after logout refuses `provider_sign_in_required`, and after a same-account login the service adopts the new generation within 30 s and the next turn succeeds without restart |
| `apps/loopex_daemon/test/command_test.exs` (extended) | `ExitStatus.classes/0` covers exactly `Enum.to_list(65..124) -- [114]`, each status once; `fetch/1` refuses 114 |
| `apps/loopex_llm_reqllm/test/chatgpt_reply_ceiling_test.exs` | Through the fake server: a stream longer than the ceiling ends with completion `limit`, text whose `Loopex.Bounds.estimate/1` is at most the ceiling and is a prefix of what the server sent, a cut on a UTF-8 boundary, no tool calls, nil reported usage, and the server observing the connection closed; a stream that completes below the ceiling is unchanged; a ceiling of 1; a cut during a streamed tool call; the request body never contains `max_output_tokens`. Each case runs through both actual callers: the companion worker's `drain/5`, where the halt calls `StreamResponse.close/1` and no `StreamServer` or HTTP task survives the invocation, and the in-process caller through `OneShotHTTP1`, where the halt is followed by the owner's existing tagged-pool teardown proof before the result, and no progress delta is emitted. A source check finds one ceiling implementation, `ReplyCeiling`, called from both. **Raw-byte bound:** a stream longer than the ceiling whose SSE framing reaches 8,388,609 raw bytes while its estimate is still below the ceiling ends the in-process caller with `{:error, {:dispatched_or_unknown, "model_call_failed"}}` after the same teardown proof, while the same stream through the companion caller ends at the ceiling with completion `limit` |
| `apps/loopex_composition/test/chatgpt_summarizer_test.exs` | A maintenance summary on a `chatgpt:` route through the fake server, with a summary longer than ADR 0043's ceiling, settles as a `limit` reply within the ceiling and is handled as any limit-truncated summary, once through a durable composition (companion caller) and once through an ephemeral composition's maintenance model (in-process caller) |
| `apps/loopex/test/sign_in_required_settlement_test.exs` | `{:not_dispatched, "provider_sign_in_required"}` settles attempt one as `not_dispatched`, accounting `none`, next `terminal` with no retry; the run ends `failed` with that reason; the record replays. **Route availability changes between attempts:** attempt one settles `not_dispatched`/`model_call_failed` with `retry`, custody then becomes `:missing`, and attempt two settles terminal with `provider_sign_in_required`; the two-attempt history replays to the same terminal. **Termination precedence:** the category settled with an `abort` termination ends the run `cancelled` and with a `deadline` termination `bound_reached`, never `failed` with the reason, and each replays to the same terminal. The category with `dispatched_or_unknown`, accounting other than `none`, `next` other than `terminal`, or a termination other than abort or deadline is invalid history; a maintenance run reports the category |
| `apps/loopex_protocol/test/sign_in_required_vectors_test.exs` | The new vectors encode and decode on `loopex.experimental/3` and `/4`; the reason with a nonnull `failure`, or as a failure category with `retryable` `true`, is refused; the regenerated manifests and schema proof match |
| `apps/loopex_cli/test/ask_sign_in_test.exs` | Ephemeral `ask` on a sign-in route through the fake server; refresh in host VM; custody stopped at composition stop |

Release lanes for M8 outcome 8, attended, gated on each provider's client
being available, run with `--only`:

- `real-sign-in-openai`: an attended `auth login openai --store file` into
  a temporary home, whose model list, fetched before the login's write,
  must be recorded non-empty within its bounds and name the lane's model;
  one real `chatgpt:` conversation through the installed service; a forced
  refresh; logout with revocation; then a second login under the generation
  floor, which must authorize under the floor's issued client, write a
  generation above the floor and record the list again. The lane also
  records verification items 1 and 11 to 15.
- `real-sign-in-gemini`: the same for `vertex:`, `--store file` in a
  temporary home, through both the `loopex`
  and `adc` sources, against a maintainer-owned project. The `adc` part reads
  a file written by a real `gcloud auth application-default login`, and its
  login verifies a real Google ID token whose `aud` is that file's
  `client_id`.
- `real-sign-in-anthropic`: defined, and refused as `sign_in_unavailable`
  until a sanctioned registration exists. That tested refusal is the lane's
  complete proof for the disabled `claude:` route; M8 closure needs positive
  lanes for OpenAI and Google only, and no deferral for Anthropic.

No lane names the login keychain or the user's Secret Service: the real
provider lanes use the file backend in a temporary home, and the keyring
backends are proved by the tagged `sign_in_keychain_test.exs` case against a
temporary keychain and the tagged `sign_in_secret_service_test.exs` case
under `dbus-run-session` with a throwaway keyring.

Complete outputs are retained outside the repository, with tokens redacted by
the existing lane redactor, extended in two ways. It redacts every exact
value the lane has observed: the lane reads the file store's record after
login and after each refresh, so every generation's access and refresh token,
rotated-away ones included, stays covered, and for `adc` the file's refresh
token and client secret. It also redacts every compact JWS-shaped string
(three base64url segments separated by dots, the first beginning `eyJ`), so
an ID token, which is never stored, and any JWT-form access token are covered
without being known in advance.

<a id="technical-adr-0073-amendments"></a>
### Amendment Text

Concept: [Amendments to accepted decisions](0073-provider-oauth-sign-in.md#concept-adr-0073-amendments).

- **ADR 0048, Concept.** "Credentialed routes store only named environment
  references … No raw keys, files, keychain lookups, commands, custom
  endpoints or multiple accounts for one provider enter M7." Amended: a
  sign-in route stores an `oauth` reference. Its tokens are held by the host
  in a keyring or owner-only file outside the state root. `vertex` adds a
  project and one of two compiled endpoint templates. Raw keys, commands,
  arbitrary endpoints and multiple accounts per route stay excluded.
- **ADR 0048, Technical.** The sentence "A binding is either
  `credential: {env: NAME}` … or `credential: {none: true}`" gains the
  `oauth` alternative and the `vertex` members. "Rotation takes an explicit
  host restart/rebinding in M7; no live refresh watcher is added" is amended
  for sign-in routes only: same-subject refresh and re-login rotate custody
  live, and a different subject still needs restart. The compatibility
  section's deferral of "file credentials and live rotation" is narrowed
  accordingly.
- **ADR 0019, Decision.** The credential sent over the private channel may be
  a host-held access token. The companion admits two more invocation kinds,
  `token_exchange` and `model_list`, under the same launch, isolation, bound
  and cleanup rules. The 65,536-byte bound applies to each token.
- **ADR 0034, Decision.** Unchanged in mechanism. A `SignIn.Route` edge is an
  additional host owner that calls the custody's existing `rotate/3`. The
  token-per-route, resolve-once-per-invocation and sender rules are
  unchanged.
- **ADR 0039, Decision point 3**, "each hosted provider has its own variable,
  read at the model boundary for each call". Amended: a sign-in route resolves
  from composition-owned custody at the model boundary for each call. Its
  refresh runs in the host VM under the profile's stated audience. The
  in-process caller streams a `chatgpt` reply through the existing one-shot
  adapter and tagged pool, so the profile's cleanup proof is unchanged.
- **ADR 0029, Concept, "Purpose and Decision".** "The public Model result
  remains `dispatched_or_unknown` with `"model_call_failed"`." And Technical
  depth, "Core still receives exactly
  `{:error, {:dispatched_or_unknown, "model_call_failed"}}`". Amended: these
  stay exact for every failure the companion or provider classifies. In
  addition, a host refusal before dispatch because a sign-in route has no
  usable sign-in returns `{:error, {:not_dispatched,
  "provider_sign_in_required"}}`, and that reason is public in the run
  terminal outcome and in maintenance and compaction failures, with schemas
  and vectors on `loopex.experimental/3` and `/4`. The private stage and
  category pair, its sealing and its exclusion from every public plane are
  unchanged; the new reason is never derived from it.
- **ADR 0018, Technical depth, "Model result boundary".** The union
  "`{:ok, reply()} | {:error, {:not_dispatched, "model_call_failed"}} |
  {:error, {:dispatched_or_unknown, "model_call_failed"}} | {:error,
  term()}`" gains `{:error, {:not_dispatched,
  "provider_sign_in_required"}}`, returned only by a host refusal before
  dispatch on a sign-in route. Every other term keeps its meaning.
- **ADR 0018, Technical depth, `result_projection`.** "`"category" =>
  "model_call_failed" | "unreadable_model_answer"`" gains
  `"provider_sign_in_required"`.
- **ADR 0018, Technical depth, the closed valid-combination table.** Row 4,
  "Exact `not_dispatched` has no conversation and no accounting. Attempt one
  selects retry only when no termination has won", stays exact for
  `model_call_failed`. One row is added: a `not_dispatched` result with
  category `provider_sign_in_required`, on attempt one or two, with no
  termination or an abort or deadline termination, has conversation `none`,
  accounting source `none` and next `terminal`, never `retry`. Every other
  combination with the category is invalid history.
- **ADR 0021, Technical depth, "Exact schema".** "Normal reply and
  model-failure results remain exactly: … `%{"kind" => "error",
  "category" => "model_call_failed"}`". Amended: the model-failure result is
  exactly that map or `%{"kind" => "error", "category" =>
  "provider_sign_in_required"}`. The twelve root keys, the kind value and
  the unreadable result are unchanged.
- **ADR 0043, Technical depth, the episode terminal's failure union.**
  "`{category: "model_call_failed", retryable: false}`" is joined by
  `{category: "provider_sign_in_required", retryable: false}`, for
  run-owned and standalone episodes alike. The other members are unchanged.
- **ADR 0049, Technical, file contract.** The `providers` row, "durable chat
  requires `{"credential":{"env":"NAME"}}`", is amended: durable chat also
  accepts `{"credential":{"oauth":{"source":...}}}` on a sign-in route. Schema
  version 1 additionally admits the provider names `chatgpt`, `vertex` and
  `claude`, the `oauth` credential form, and the `vertex` route's `project`
  and `location` members, each under the closed grammar above. The schema
  version stays 1; the closed-object rule is unchanged.
- **ADR 0037 (Proposed).** "File/keychain/command credentials require a
  separate future decision" becomes: sign-in tokens follow ADR 0073; file and
  command API-key sources still need a separate decision.

<a id="technical-adr-0073-verification"></a>
### Research Record and Verification Items

Concept: [Open for the maintainer](0073-provider-oauth-sign-in.md#concept-adr-0073-open).

Sources were read on 2026-10-13. Primary means the provider's own
documentation.

| Fact used above | Source | Kind |
| --- | --- | --- |
| Sign in with ChatGPT endpoints: `https://auth.openai.com/api/accounts/authorize`, `.../oauth/token`, `.../oauth/revoke`; S256; no device endpoint; issuer `https://auth.openai.com`, JWKS URI and `RS256` only | [auth.openai.com/.well-known/openid-configuration](https://auth.openai.com/.well-known/openid-configuration) | Primary |
| Dynamic registration, scopes, `resource`, loopback rules, headless VMs | [developers.openai.com/siwc/token-sharing-open-source/sign-in](https://developers.openai.com/siwc/token-sharing-open-source/sign-in), [developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms](https://developers.openai.com/siwc/token-sharing-open-source/self-hosted-vms), [developers.openai.com/siwc/quickstart](https://developers.openai.com/siwc/quickstart) | Primary |
| Access token 3,600 s; refresh token 30 days, rotated on each refresh; serialize refreshes; revocation form | [developers.openai.com/siwc/token-sharing-open-source/token-reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference) | Primary |
| Responses API only, `store:false`, `stream:true`, rejected members, model listing | [developers.openai.com/siwc/token-sharing-open-source/models-and-inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference), [developers.openai.com/siwc/token-sharing-open-source/preview-limitations](https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations) | Primary |
| Usage-limit error codes | [developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery](https://developers.openai.com/siwc/token-sharing-open-source/errors-and-recovery) | Primary |
| Plus/Pro, per-app weekly cap, optional credit overflow | [help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites](https://help.openai.com/en/articles/20001542-using-your-chatgpt-plan-in-other-apps-and-sites) | Primary |
| Partner client route for paid or hosted apps | [developers.openai.com/siwc/request-client-id](https://developers.openai.com/siwc/request-client-id), [openai.com/form/sign-in-with-chatgpt-interest/](https://openai.com/form/sign-in-with-chatgpt-interest/) | Primary |
| Launch at DevDay 2026-09-29 | [smartscope.blog/en/blog/sign-in-with-chatgpt-partner-apps-2026/](https://smartscope.blog/en/blog/sign-in-with-chatgpt-partner-apps-2026/), [flaviocopes.com/sign-in-with-chatgpt/](https://flaviocopes.com/sign-in-with-chatgpt/) | Secondary |
| Google installed-app endpoints, loopback, PKCE | [developers.google.com/identity/protocols/oauth2/native-app](https://developers.google.com/identity/protocols/oauth2/native-app) | Primary |
| Device flow scope list excludes `cloud-platform` | [developers.google.com/identity/protocols/oauth2/limited-input-device](https://developers.google.com/identity/protocols/oauth2/limited-input-device) | Primary |
| Refresh-token expiry in Testing status, unused or over-limit tokens | [developers.google.com/identity/protocols/oauth2](https://developers.google.com/identity/protocols/oauth2) | Primary |
| Unverified-app screen and 100-user cap | [developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification) | Primary |
| ADC lookup order and file location | [docs.cloud.google.com/docs/authentication/application-default-credentials](https://docs.cloud.google.com/docs/authentication/application-default-credentials) | Primary |
| `x-goog-user-project` quota project | [docs.cloud.google.com/docs/quotas/set-quota-project](https://docs.cloud.google.com/docs/quotas/set-quota-project) | Primary |
| Vertex `generateContent` path, global endpoint, bearer token | [docs.cloud.google.com/vertex-ai/generative-ai/docs/start/quickstart](https://docs.cloud.google.com/vertex-ai/generative-ai/docs/start/quickstart) | Primary |
| Gemini CLI/Code Assist OAuth from third-party software violates terms (page updated 2026-04-10) | [geminicli.com/docs/resources/tos-privacy](https://geminicli.com/docs/resources/tos-privacy) | Primary (project documentation) |
| Anthropic: OAuth only for its own apps; third parties may not offer Claude.ai login or route through Free/Pro/Max credentials | [code.claude.com/docs/en/legal-and-compliance](https://code.claude.com/docs/en/legal-and-compliance) (undated) | Primary |
| Anthropic Consumer Terms on automated access, effective 2025-10-08 | [www.anthropic.com/legal/consumer-terms](https://www.anthropic.com/legal/consumer-terms) | Primary |
| Anthropic enforcement dates (blocking from 2026-01-09, documentation clarified 2026-02-19; another report says 2026-04-04) | [winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/](https://winbuzzer.com/2026/02/19/anthropic-bans-claude-subscription-oauth-in-third-party-apps-xcxwbn/), [decodethefuture.org/en/anthropic-blocks-third-party-tools/](https://decodethefuture.org/en/anthropic-blocks-third-party-tools/) | Secondary, conflicting |
| Google OIDC issuer, JWKS URI and `RS256` | [accounts.google.com/.well-known/openid-configuration](https://accounts.google.com/.well-known/openid-configuration) | Primary |
| Google refresh responses may omit a new refresh token | [developers.google.com/identity/protocols/oauth2/native-app](https://developers.google.com/identity/protocols/oauth2/native-app) | Primary |
| ReqLLM streaming starts a linked `StreamServer` and uses `Finch.stream/5` on its own pool; `StreamResponse.close/1` cancels | `deps/req_llm` 1.24.0 `streaming.ex`, `stream_server.ex`, `stream_response.ex` | Primary (dependency source) |
| ReqLLM `access_token` options for OpenAI, Vertex and Anthropic; embedded foreign client IDs | `deps/req_llm` 1.24.0 source as locked in `mix.lock` | Primary (dependency source) |

**What would unblock Anthropic.** Anthropic publishes a third-party OAuth
client program, or grants Loopex a written sanction. That sanction must name
the client ID, endpoints, scopes, the billing a Pro or Max user's token
draws on, and the required request headers. The `claude` profile is then
filled from that document under an amendment to this record, and the
`real-sign-in-anthropic` lane becomes a positive proof. No primary source
found on 2026-10-13 offers such a program.

**Verification items.** Each has one disposition. *Acceptance* means it is
settled before this record is accepted; *implementation* names the test or
lane that settles it, and the design above does not depend on the answer.

| # | Item | Disposition |
| --- | --- | --- |
| 1 | Whether an OpenAI refresh immediately invalidates the previous refresh token | Implementation. The design assumes it does (lock, read-back, `roll_forward`). The `real-sign-in-openai` lane's forced refresh records whether the prior token is then refused; `sign_in_refresh_test.exs` already proves the worst case |
| 2 | Whether OpenAI requires a partner client ID rather than dynamic registration | Acceptance: the maintainer's confirmation under [open item 1](0073-provider-oauth-sign-in.md#concept-adr-0073-open). A partner client would amend this record |
| 3 | A documented allowed-model list for plan usage | Implementation. Only the per-account listing is documented and is what the route uses, through `model_list`; `sign_in_routes_test.exs` refuses an unlisted model with `provider_route_unavailable` |
| 4 | An official OpenAI statement of the launch date | None needed. No rule depends on the date; it is research context only |
| 5 | Whether Google classifies `cloud-platform` as sensitive or restricted | Acceptance: decided with [open item 2](0073-provider-oauth-sign-in.md#concept-adr-0073-open). It sets the Google client's verification path, not code; the `adc` source does not depend on it |
| 6 | Google's stated access-token lifetime | Implementation. The refresher reads `expires_in`, assumes no fixed value and scales the custody skew with it; `sign_in_refresh_test.exs` covers a 30 s lifetime and one below the 10 s minimum |
| 7 | The ADC `authorized_user` member names, and that gcloud's default login grants `openid` | Implementation. `sign_in_adc_test.exs` fixes the grammar; the `real-sign-in-gemini` lane reads a file written by real gcloud and must pass the grammar and return a verifiable ID token. A difference amends the grammar, never silently widens it |
| 8 | The regional Vertex host form | Acceptance, checked 2026-10-13: Google's Vertex AI [locations](https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations) page gives `https://{LOCATION}-aiplatform.googleapis.com` beside the global `https://aiplatform.googleapis.com` |
| 9 | Anthropic's Commercial Terms text and exact policy dates | None needed. The `claude:` route is disabled and proved by its tested refusal; the dates matter only to a future amendment that enables it |
| 10 | Each provider's ID-token issuer, JWKS URI and signing algorithm | Acceptance, checked 2026-10-13 against both discovery documents, as recorded under [ID-token verification](#technical-adr-0073-id-token) |
| 11 | That OpenAI's ID token carries `aud` equal to the issued `oaiapp_...` client, and that the callback returns that issued client ID | Implementation. `real-sign-in-openai` verifies the real ID token under check 5 against the client the callback returned; a different audience fails the lane and amends this record |
| 12 | That OpenAI honors the OIDC `nonce`, and accepts a later authorize under the issued client instead of `dynamic_agent_client` | Implementation. `real-sign-in-openai` verifies check 7 on the real token, then logs out and signs in again under the floor's issued client |
| 13 | That OpenAI accepts `resource=https://api.openai.com/v1` on refresh | Implementation. The lane's forced refresh sends it and must succeed |
| 14 | That `GET /v1/models` answers a plan access token with entries carrying `visibility` | Implementation. The lane's login runs `model_list` before its write and must record a non-empty list within its bounds that names the lane's model; a failure fails the login with nothing written (D25) |
| 15 | That the plan token's model list fits 256 ids of at most 128 bytes | Implementation. The same lane case; an over-bound real list fails `sign_in_failed` and amends the bound |
| 16 | That `security -i` accepts one input line of 262,144 bytes, the base64url form of a 196,608-byte record | Implementation. The tagged maximum-size round trip in `sign_in_keychain_test.exs`; a refusal lowers the record bound by amendment |

<a id="technical-adr-0073-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0073-provider-oauth-sign-in.md#concept-adr-0073-compatibility).

- **Schema.** ADR 0049's schema stays at version 1. Before this decision, the
  new members fail the closed-object check with existing classes: a new
  provider name with `{:unsupported_provider, "/providers"}`
  (`apps/loopex_llm_reqllm/lib/loopex/llm/req_llm/host_bindings.ex` :97),
  and an `oauth` credential or the `vertex` members on an existing route with
  `invalid_credential_binding` at the binding's pointer (:117-122). Under the
  pre-1.0 rule nothing older needs to read them.
- **Durable data.** Committed models such as `chatgpt:<id>` are ordinary model
  strings; resuming needs the route admitted. The settled-attempt record and
  the run terminal admit the `provider_sign_in_required` category, and replay
  validates it as above. Before 1.0 no older reader is supported.
- **Removal.** Delete `auth`, the three routes, `SignIn.*`, the companion's
  `token_exchange` and `model_list` kinds and the failure reason with its schema and vector
  entries together. Run `auth logout` for each route first;
  otherwise revoke in the provider's account settings. Then remove `<home>/auth/`.

**Alternatives considered.**

- **Reuse Codex CLI's or Claude Code's client, as ReqLLM's built-in modes do.**
  Rejected. It impersonates another product. OpenAI's documentation steers
  apps away from `backend-api`, and Anthropic's terms forbid it.
- **Put sign-in on the existing `openai` and `anthropic` routes, chosen by
  credential form.** Rejected. The committed model would no longer say what
  was billed or which request rules apply, and one route would carry two
  capability sets.
- **Refresh inside the host VM for durable hosts too.** Rejected. ADR 0019
  moved credential-bearing HTTP out of the host VM because dependency
  diagnostics can carry request bodies. The companion already provides that
  isolation.
- **Have the service spawn `loopex auth refresh` processes.** Rejected. It
  needs the service to locate its own executable, and it duplicates the
  companion's isolation with weaker cleanup proof.
- **An encrypted file with a Loopex-held key.** Rejected. The key would sit
  beside the file under the same user, adding code without adding a
  boundary.
- **A native keyring library.** Rejected. It adds a NIF to the archive's
  linkage proof. The two operating-system tools already exist on the
  supported hosts or degrade to the file backend.
- **Device flow as the headless default.** Not available. Neither OpenAI's
  discovery document nor Google's `cloud-platform` scope admits it today.
  Loopback forwarding and ADC cover headless hosts.
