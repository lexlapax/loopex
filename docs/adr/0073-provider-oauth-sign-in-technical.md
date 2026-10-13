<a id="technical-depth"></a>
## Technical depth

Concept: [Provider OAuth sign-in](0073-provider-oauth-sign-in.md#concept).

<a id="technical-adr-0073-decision"></a>
### Contract

Concept: [Context and decision](0073-provider-oauth-sign-in.md#concept-adr-0073-decision).

**Where the code lives.** Core gains nothing. Provider-specific sign-in
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
- **`chatgpt` request shape.** OpenAI's
  [models and inference](https://developers.openai.com/siwc/token-sharing-open-source/models-and-inference)
  page fixes these: Responses API only; `store: false` and `stream: true` on
  every request; success only on `response.completed`. It also rejects
  `previous_response_id`, system-role items, `temperature`, `top_p`,
  `max_output_tokens`, `metadata`, `user`, `truncation`, hosted tools and
  audio. Function tools are supported.
  - The `chatgpt` mapping renders host instructions through the Responses
    `instructions` member, not a system item.
  - It never relies on provider-side continuation.
  - It is streaming-only.
  - Its reply ceiling is open item 4. Until the maintainer decides it, the
    mapping refuses the route for the maintenance summarizer, whose ceiling
    ADR 0043 fixes.
  - The admitted models are the account's `GET /v1/models` entries with
    `visibility == "list"`. Capability capture uses the route's registered
    mappings, as other routes do. A model the account does not list is refused
    before dispatch as `model_unavailable_for_sign_in`.
  - The provider's `subscription_sharing_usage_limit_exceeded` (HTTP 429) and
    `subscription_sharing_usage_unavailable` replies classify under ADR 0029
    as provider failures after dispatch. They are never retried blindly.

**Token record.** One record per route, per home:

```json
{"version": 1, "route": "chatgpt", "access_token": "...", "refresh_token": "...",
 "token_type": "Bearer", "generation": 7}
```

- Each token is 1 to 65,536 bytes of `[A-Za-z0-9._~+/=-]`. The canonical JSON
  record is at most 196,608 bytes.
- `id_token` is validated, then discarded and never stored. The check is
  issuer, audience equal to the client ID, expiry, and the nonce on the
  authorization-code path.
- `generation` increases by one on every write.

**Metadata file.** A non-secret metadata file
`<home>/auth/<route>.json` always accompanies the record:

```json
{"version": 1, "route": "chatgpt", "backend": "macos_keychain",
 "client_id": "oaiapp_...", "host_id": "urn:uuid:...",
 "subject_digest": "sha256:...", "account_label": "a***@example.com",
 "scopes": ["openid", "profile", "email", "offline_access", "resource.invoke",
            "chatgpt.tokens.use.direct"],
 "access_expires_at": "2026-10-13T18:00:00Z", "refresh_expires_at": "2026-11-12T17:00:00Z",
 "generation": 7, "state": "signed_in"}
```

- `backend` is `macos_keychain`, `secret_service` or `file`.
- `subject_digest` is the SHA-256 of the issuer, a NUL and the subject.
- `account_label` is the provider's e-mail with the local part masked after
  its first character. It appears only in `auth status`.
- `state` is `signed_in`, `sign_in_required` or `revocation_unconfirmed`.
- `<home>` is ADR 0037's home. `auth/` sits beside, never inside, the state
  root, so ADR 0072's backups never capture tokens and restore never
  overwrites them.
- `auth/` is created with mode `0700`. Every file in it is `0600`, owned by
  the effective user. A reader refuses a symlink anywhere on the path, a
  different owner, or a wider mode, with `credential_store_unsafe`.
- The `adc` source has no Loopex record. Its metadata file records
  `backend: "adc"` and the subject digest seen at sign-in, so the service can
  detect an account change.

**Token store interface.** `LoopexComposition.SignIn.Store` exposes:

- `read_metadata(home, route)`, which never reads a secret;
- `read(home, route)`, which returns the record or `:absent`,
  `credential_store_unavailable` or `credential_store_unsafe`;
- `write(home, route, record, metadata)`;
- `delete(home, route)`.

The secret is always written before the metadata. A reader that finds the
metadata's generation newer than the secret treats the route as absent. A
partial write therefore never pairs a new label with an old token. Backends:

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
   - Tests pass a temporary keychain path, created with `security
     create-keychain` and supplied with `-k`/the keychain argument. They never
     touch the login keychain.
2. **Linux Secret Service.** The backend runs `/usr/bin/secret-tool` from the
   `libsecret-tools` package, by absolute path only.
   - The backend is available when that file is executable,
     `DBUS_SESSION_BUS_ADDRESS` is set, and a probe
     `secret-tool lookup application loopex-oauth-probe` exits 0 or 1 within
     5,000 ms. Exit 1 means no match, which is fine. Any other status, or a
     D-Bus autolaunch error, means unavailable.
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
algorithm is written. The lock is held only across read, exchange, write.
Acquisition waits at most 10,000 ms, polling every 100 ms, then fails with
`sign_in_lock_busy`. The lock is always needed:

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
    the validated token response on the private channel.
  - Only the requesting refresher process in the parent receives it. That
    process is `:sensitive` and excluded from tracing.
  - No raw provider body, header or error text crosses. Failures are the
    closed classes below.
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
| `sign_in_failed` | A malformed or over-bound reply, wrong issuer or audience, granted scopes missing a required scope, or a subject different from the stored one |

Only `sign_in_required` changes the stored `state`.

**Refresher and custody.** For each `oauth` binding, composition starts one
owned edge, `LoopexComposition.SignIn.Route`. It is linked like the existing
registry and custody edges and joins their reverse cleanup.

1. At start it reads the metadata and record. A missing record, a client ID
   that does not match the compiled or registered client, or
   `state: sign_in_required` refuses composition with
   `provider_sign_in_required`.
2. If the access token expires within the refresh window, it refreshes under
   the lock. The window is the smaller of 300 s and half the token's lifetime.
3. It starts an ordinary `CredentialCustody` with the access token and
   `expires_at` set to the token's expiry minus 60 s, in monotonic time.
   Durable composition registers that custody in the `CredentialRegistry`
   under a fresh `CredentialToken` in `provider_routes`, exactly like an `env`
   route. The custody and token modules are unchanged; their existing
   `rotate/3` and `:expired` result are what this record uses.
4. It schedules the next refresh at the window's start. On each refresh it
   takes the lock and rereads the store. If another process already advanced
   the generation with a later expiry and the same subject, it adopts that
   record without contacting the provider. Otherwise it exchanges, writes,
   unlocks and rotates custody.
5. A transient failure (`provider_unreachable`) retries with delays of 5, 15,
   30, 60, 120, then every 300 s. The custody keeps the old token until its
   `expires_at`. After that, resolution returns `:expired` and the sender
   refuses before dispatch.
6. On `sign_in_required` it rotates custody to `nil`, so resolution returns
   `:missing`. It writes `state: sign_in_required`, writes one bounded host
   diagnostic line, `loopex: provider sign-in required for route <route>; run
   loopex auth login <provider>`, and stops refreshing.
7. Every 30 s it reads only the metadata file. A higher generation with the
   same `subject_digest` is adopted, and custody rotates to the new token. This
   is how a fresh `auth login` reaches a running service. A different subject
   is refused: custody stays `nil` and the diagnostic names
   `sign_in_account_changed`. A deleted metadata file, which is what `auth
   logout` leaves, rotates custody to `nil` within that 30 s.

A call already dispatched keeps the token it was sent with. Rotation never
cancels, repeats or reclassifies an attempt; ADR 0018 governs the attempt as
before. The access token resolved for a call is the call's selected
credential. `worker_invoke/4` and the in-process caller pass it to the
existing echo guard unchanged, so a mapped reply containing it is withheld and
failed. The refresh token never reaches a model call, so it cannot be echoed
there. Trace exclusion covers the refresher, the custody, the exchange
process and the companion; no new trace selector exists.

**Ephemeral profile.** The ephemeral composition starts the same
`SignIn.Route` edge and custody, owned by the ephemeral composition and
stopped with it. It does not use the durable registry or exclusion plane.
`in_process.ex` currently reads `System.get_env(variable)` in the sensitive
caller. For a `:sign_in` route it instead calls `CredentialCustody.resolve/1`
on the route's custody reference. The reference is passed in host-private
model options next to the binding map, never in a request. `:missing` and
`:expired` refuse as `not_dispatched`. Everything else in ADR 0039's caller,
pool, cleanup and selected-value guard is unchanged.

**Daemon and service.**

- Composition refuses start with new exit statuses, appended after 110 in
  the daemon's table:
  - `provider_sign_in_required` (111);
  - `credential_store_unavailable` (112);
  - `credential_store_unsafe` (113).
  `sign_in_route_lost` (114) is a fail-stop when a running `SignIn.Route` edge
  exits, like `custody_lost`.
- A transient refresh failure at startup does not refuse start. The service
  serves and the route stays unavailable until a refresh succeeds.
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
- `--source adc` is `gemini` only. It signs in nothing. It validates that
  `$HOME/.config/gcloud/application_default_credentials.json` is
  `type: authorized_user`, performs one refresh to learn the subject, and
  writes only the metadata file.
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
  - After sign-in, one credential-free request lists the project. It checks
    that the configured `vertex` project accepts the token with
    `x-goog-user-project`; a failure is reported but keeps the sign-in.
- `status` reads metadata only: no secret, no network, no lock. It prints one
  line per configured or stored sign-in route: route, state, account label,
  backend, access and refresh expiry.
- `logout` takes the lock, reads the record, and revokes the refresh token at
  the profile's revocation endpoint through the in-host executor. It then
  deletes the secret and the metadata in that order. `--local-only` skips
  revocation. A revocation failure still deletes locally and exits
  `revocation_unconfirmed`. For `adc`, logout deletes only Loopex's metadata
  and never touches gcloud's file.

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
| 75 | `sign_in_required`: `status` found a listed route not signed in |

**Inspection.** `config show` and the chat startup report show a sign-in
binding's form and source, for example `oauth (loopex)`. They also show the
`vertex` project and location. They never show availability, backend, label
or expiry, keeping ADR 0048's inspection rule.

<a id="technical-adr-0073-threats"></a>
### Threat Model

Concept: [Observable consequences](0073-provider-oauth-sign-in.md#concept-adr-0073-consequences).

| Threat | Mitigation | Residual |
| --- | --- | --- |
| Another local user reads tokens | Keychain and Secret Service are per user; the file backend requires a `0700` directory, a `0600` file and the same owner, with no symlinks | `root` and anyone with the user's account |
| A same-user process, including a host-authorized tool job, reads tokens | None structural. Items created through `/usr/bin/security` trust that tool, and any same-user process can run it. Secret Service answers any client on the session bus. The file is readable by the user | Equal to today's ambient API key in the invoking shell. Loopex never injects tokens into jobs, and the local executor environment still excludes credential names. Untrusted workspaces need OS isolation of the hand |
| Disk theft, home-directory copy or dotfile sync | Keyring backends encrypt at rest. Tokens sit outside the state root and never enter backups | The file backend is plaintext at rest; `auth login` says so |
| Authorization-code interception | PKCE S256, a fresh `state` and nonce, a listener bound to `127.0.0.1` before the browser opens, an exact path, and one request only | A same-user process racing the port can at most receive a code it cannot redeem without the verifier |
| Device-code phishing | `verification_uri` shown only for allowlisted provider hosts | — |
| Endpoint substitution | Compiled HTTPS endpoints per profile. No configuration or environment override; a test-only fake server is injected under `Mix.env() == :test` only | — |
| Refresh-token reuse race | Cross-process lock, re-read before exchange, generation adoption | A crash between the provider's rotation and the local write loses the new token, so the route needs sign-in again |
| Leak into logs, traces or crash dumps | `:sensitive` custody, refresher and exchange processes; `format_status` redaction as in `CredentialCustody`; tracing exclusion; the companion executor in durable hosts; logger off and crash dumps disabled in `auth`; closed failure classes only | ADR 0039's host-VM audience in the ephemeral profile and `auth` |
| Provider echoes a token | The existing exact-match echo guard on the access token | Split or encoded echoes, as today |
| Impersonating another client | Only Loopex's own client identities; source scan for forbidden ReqLLM options | — |
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
| `apps/loopex_llm_reqllm/test/sign_in_profiles_test.exs` | Compiled endpoints are HTTPS and per profile; no override path outside tests. A source scan finds no `oauth_file`, `auth_file`, `oauth_http_options`, `with_claude_subscription`, `codex_originator`, `openai_codex` or `refresh_oauth_credentials` in Loopex source, and no Codex CLI or Claude Code client ID. Token-response validation (issuer, audience, scopes, bounds). `claude` is disabled without a sanctioned profile |
| `apps/loopex_llm_reqllm/test/sign_in_routes_test.exs` | The binding grammar's alternatives, pointers and classes. `oauth` on existing routes and `env` on sign-in routes refuse. `vertex` project and location vectors. Per-route sealed headers. The `chatgpt` mapping never sends rejected members and always streams with `store: false` |
| `apps/loopex_composition/test/sign_in_store_test.exs` | File backend: modes, owner, symlink refusal; write fault cuts at each step leave the prior record or a consistent absent state; generation ordering; stale `.tmp` cleanup. The metadata path never reads a secret |
| `apps/loopex_composition/test/sign_in_keychain_test.exs` | Tagged `:macos_keychain`, against a temporary keychain: round trip, overwrite, delete; the secret never appears in any spawned argv, checked through an argv-recording wrapper |
| `apps/loopex_composition/test/sign_in_secret_service_test.exs` | Tagged `:secret_service`, under `dbus-run-session` with a throwaway keyring: round trip and availability probe. Untagged, a recording fake executable proves the wrapper's argv and standard-input bytes |
| `apps/loopex_composition/test/sign_in_refresh_test.exs` | Refresh at the window; rotation persisted; `invalid_grant` → `sign_in_required` and custody `:missing`; transient retry schedule; expiry while unreachable → `:expired` refusal. Two OS processes on one home perform exactly one exchange, the other adopting. Stale lock reclaim. Account change refused; same-account re-login adopted within 30 s; logout reaches custody `nil` |
| `apps/loopex_composition/test/credential_plane_test.exs` (extended) | A sign-in route's custody is registered like an `env` route. Two canaries (access and refresh) never appear in journals, public events, progress, diagnostics, traces, executor job environments or resource subprocess environments. An invocation during rotation uses exactly one token |
| `apps/loopex_llm_reqllm/test/provider_bridge_test.exs` (extended) | The `token_exchange` invocation: credential frame, closed failure classes, no raw body crossing, cleanup proof. The access-token echo guard withholds a reply containing the token |
| `apps/loopex_cli/test/auth_command_test.exs` | Grammar and every exit status. Loopback: state mismatch, wrong path, denial, timeout, port already bound. `--device` refusal text. `status` makes no secret read and no network call. `logout` revoke success, failure and `--local-only`. The ADC metadata path |
| `apps/loopex_cli/test/daemon_sign_in_test.exs` | Statuses 111 to 114; start-on-demand presence check; revoked mid-service → next call `not_dispatched` with no fallback to another route; re-login adopted |
| `apps/loopex_cli/test/ask_sign_in_test.exs` | Ephemeral `ask` on a sign-in route through the fake server; refresh in host VM; custody stopped at composition stop |

Release lanes, attended, gated on each provider's client being available, run
with `--only`:

- `real-sign-in-openai`: an attended `auth login openai` into a temporary
  home, one real `chatgpt:` conversation through the installed service, a
  forced refresh, and logout with revocation.
- `real-sign-in-gemini`: the same for `vertex:`, through both the `loopex`
  and `adc` sources, against a maintainer-owned project.
- `real-sign-in-anthropic`: defined, and refused as `sign_in_unavailable`
  until a sanctioned registration exists. That refusal is the lane's
  expected result until then.

Complete outputs are retained outside the repository, with tokens redacted by
the existing lane redactor extended to the stored record's values.

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
  a host-held access token. The companion admits a second invocation kind,
  `token_exchange`, under the same launch, isolation, bound and cleanup rules.
  The 65,536-byte bound applies to each token.
- **ADR 0034, Decision.** Unchanged in mechanism. A `SignIn.Route` edge is an
  additional host owner that calls the custody's existing `rotate/3`. The
  token-per-route, resolve-once-per-invocation and sender rules are
  unchanged.
- **ADR 0039, Decision point 3**, "each hosted provider has its own variable,
  read at the model boundary for each call". Amended: a sign-in route resolves
  from composition-owned custody at the model boundary for each call. Its
  refresh runs in the host VM under the profile's stated audience.
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
| Sign in with ChatGPT endpoints: `https://auth.openai.com/api/accounts/authorize`, `.../oauth/token`, `.../oauth/revoke`; S256; no device endpoint | [auth.openai.com/.well-known/openid-configuration](https://auth.openai.com/.well-known/openid-configuration) | Primary |
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
| ReqLLM `access_token` options for OpenAI, Vertex and Anthropic; embedded foreign client IDs | `deps/req_llm` 1.24.0 source as locked in `mix.lock` | Primary (dependency source) |

**What would unblock Anthropic.** Anthropic publishes a third-party OAuth
client program, or grants Loopex a written sanction. That sanction must name
the client ID, endpoints, scopes, the billing a Pro or Max user's token
draws on, and the required request headers. The `claude` profile is then
filled from that document under an amendment to this record, and the
`real-sign-in-anthropic` lane becomes a positive proof. No primary source
found on 2026-10-13 offers such a program.

**Verification items before acceptance**:

1. Whether an OpenAI refresh immediately invalidates the previous refresh
   token. The lock design assumes it might.
2. Whether OpenAI requires a partner client ID for Loopex, rather than dynamic
   registration.
3. The documented allowed-model list for plan usage; only the per-account
   listing is documented.
4. An official OpenAI statement of the launch date.
5. Whether Google classifies `cloud-platform` as sensitive or restricted, which
   decides the verification path.
6. Google's stated access-token lifetime. The refresher reads `expires_in`
   and assumes no fixed value.
7. The ADC `authorized_user` field names, including `quota_project_id`, on a
   primary page.
8. The regional Vertex host form on a primary page.
9. Anthropic's Commercial Terms text and the exact policy dates.

Each item becomes an implementation-time check, not a silent default.

<a id="technical-adr-0073-compatibility"></a>
### Compatibility Mechanics and Alternatives

Concept: [Compatibility and rollback](0073-provider-oauth-sign-in.md#concept-adr-0073-compatibility).

- **Schema.** ADR 0049's schema stays at version 1. Before this decision, the
  new members fail the closed-object check with the existing
  `invalid_credential_binding` or unsupported-provider class. Under the pre-1.0
  rule nothing older needs to read them.
- **Durable data.** Committed models such as `chatgpt:<id>` are ordinary model
  strings. Session replay needs no change; resuming needs the route admitted.
- **Removal.** Delete `auth`, the three routes, `SignIn.*` and the companion's
  `token_exchange` kind together. Run `auth logout` for each route first;
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
