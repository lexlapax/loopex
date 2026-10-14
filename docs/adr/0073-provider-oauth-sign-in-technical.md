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
- A *disabled* source is one `{route, source}` pair of the compiled list
  `@disabled_sources` in `Loopex.LLM.ReqLLM.SignIn.Profiles`:
  `{"claude", "loopex"}` while the compiled Anthropic profile carries no
  sanctioned client, and, for a provider whose `real-sign-in-*` lane the
  maintainer deferred (D36), its pair until a later candidate's lane passes
  (D43): `{"chatgpt", "loopex"}`, because OpenAI's dynamically registered
  client has no compiled value whose absence could disable it, or
  `{"vertex", "loopex"}` for a deferred Google client, which leaves the
  `adc` source enabled. A deferral is that one source edit in the candidate.
  A binding of a disabled source is refused with `sign_in_unavailable` and
  its pointer when a command or the daemon selects its configuration, before
  the start precheck and before any credential or token is read (D52):
  `loopex daemon` exits 111 `configuration_invalid` with the line `loopex
  daemon refused to start: configuration_invalid sign_in_unavailable
  <pointer>`, `auth` exits 65 and every other command exits 1.
  `auth logout` does not apply this refusal, so a sign-in stored before its
  source was disabled can still be revoked and removed (both by D52's
  accepted note). `config validate` is such a command and exits 1 with
  `sign_in_unavailable` and the pointer; `config show`, which only
  inspects, still shows the binding, by form and source only.
- Errors keep ADR 0048's form: a stable class and an RFC 6901 pointer, never a
  value. The new classes are `invalid_sign_in_reference`, `sign_in_route_only`,
  `invalid_vertex_project`, `invalid_vertex_location` and
  `sign_in_unavailable`.
- At most 16 bindings in total, as now. Sign-in routes add no environment name
  to `excluded_env_names`.

**Route catalog.** `Guards`' provider table gains three entries. Each has a
ReqLLM provider module and a credential kind of `:sign_in`, which has no
environment variable. Each entry names its route, the model prefix,
separately from its ReqLLM provider id, which for `chatgpt` is ReqLLM's
`:openai`: `Guards.model/1` returns both. Every route lookup keys by the
route: `ProviderConfiguration.select_route/2`'s custody token, by
`Atom.to_string(selected.provider)` today (`provider_configuration.ex`
:162-167), `HostBindings.select/2` (`host_bindings.ex` :138-139),
`Preflight`'s default binding (`preflight.ex` :138), the in-process
caller's custody and the guardian's credential kind. `Guards.call/1`'s
provider-module check and `ReqLLM.model/1` (`in_process.ex` :45-53) keep
the ReqLLM id. So a `chatgpt:` call never resolves the `openai`
route's custody. `Guards.binding_catalog/0` reports the `:sign_in` kind,
which `HostBindings` uses to refuse `env` and `none` there, and
`CredentialPlane.single_credential_bindings/0` (`credential_plane.ex`
:157-163) keeps only entries bound to a variable, so it leaves the sign-in
routes out:

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
    configuration under `config/` or any app, and a `vertex` `SignIn.Route`
    asserts at its start that `Application.get_env(:req_llm, :google_vertex)`
    is unset.
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
    composition and at model switch as an unconfigured route is, never as a
    Model callback result.
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
- `state` is `signed_in`, `sign_in_required` or `sign_in_incomplete`. Only
  a lock holder that finds the pair
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
  "<id>"}`, where `N` is a positive integer and `client_id` is the
  `client_id` of the decodable side with the greater generation, the
  metadata's on a tie. Any other member or value is
  `credential_store_unsafe`. A sign-out (`SignIn.Store.sign_out/3`, below)
  writes it, before deleting anything, with `N` the largest generation of
  the decodable sides it finds and of an existing floor, so a floor never
  decreases. A sign-out that finds no decodable side writes no floor, keeps
  any existing one and still deletes: a writer puts the record before the
  metadata and metadata is deleted only after a floor write, so any
  generation a process can hold is named by decodable metadata or already
  covered by a floor. A sign-out that finds no side changes nothing. Only
  the operator deletes a floor. The
  [write protocol](#technical-adr-0073-pairing), `Store.read/2`, `auth
  status`, the start precheck and `auth login openai` read it; an absent
  floor is generation 0. Only `auth login openai` uses its `client_id`.
  When OpenAI no longer accepts that issued client, the login fails; the
  operator recovers by `auth logout openai` and, once it has succeeded,
  deleting `<home>/auth/chatgpt.floor`, and the next login registers anew.
  Deleting the floor while a signed-out pair remains, as after a logout cut
  after its floor write or one that exited 69, makes that pair valid
  again. A running service refuses the new client until restarted, as any
  changed client, so no older generation is ever served.
- `<home>` is ADR 0037's home. That `auth/`, the ADC directory
  `$HOME/.config/gcloud` and every selected state root are disjoint by path
  is ADR 0037's
  [separation invariant](0037-host-configuration-and-path-discovery-technical.md#technical-0037-auth-separation),
  which owns the check and its refusal. The context's
  `protected_directories` names both directories. This record relies on it:
  the store re-applies the path check, on the sign-in context the host passed
  it, before every token write, and ADR 0072's backup, adopt and restore
  check every root, `BACKUP`, `DESTINATION` and available restore source
  they will walk against both directories before their first read or write
  of it, so ADR 0072's complete-copy backups never capture a token from
  them. By the maintainer's D27 that comparison of resolved paths is the
  whole rule: no mount is examined, and a mount of any kind that makes
  credential storage reachable inside a walked tree, or a credential file
  copied into a root, is outside this guarantee, under ADR 0037's
  [operator limit](0037-host-configuration-and-path-discovery-technical.md#technical-0037-operator-limit).
  ADR 0051's complete manifest excludes no file.
- The store creates `auth/` with mode `0700`, and checks its mode and owner,
  before any lock acquisition, so the lock primitive's `File.mkdir_p!`
  (`placement.ex` :72) never creates it under the umask. Every credential-store file in it,
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
  and `read_metadata/2` that both succeed.
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
- `read(context, route)`, which applies the
  [pairing rule](#technical-adr-0073-pairing) and returns its result,
  `credential_store_unavailable` or `credential_store_unsafe`; it reads a
  record only from the backend the metadata names;
- `write(context, route, record, metadata)`, which first calls ADR 0037's
  `LoopexComposition.SignIn.Separation.check(context)` and returns its
  `{:error, {:auth_root_overlap, pointer}}` before any backend is touched;
- `delete(context, route)`, which removes the route's record from each of
  the *host's backends*, the file backend and the keychain on macOS or the
  Secret Service on Linux, and then the metadata. A backend the metadata
  names that answers `credential_store_unavailable` fails the delete with
  that class; any other backend that does is skipped, and a record it holds
  stays at rest, never read, because readers use only the backend the
  metadata names, until a later `delete/2` finds that backend available;
- `sign_out(context, route, revoke)`, the sign-out under the route's lock:
  it reads the *raw sides*, the metadata file and the record in each host
  backend, each decoded or undecodable, without the floor or the pairing
  rule, a backend answering `credential_store_unavailable` yielding no
  record; calls `revoke` on a decodable record (`auth logout` passes the
  in-host revocation, `--local-only` and the `adc` source none); writes the
  [generation floor](#technical-adr-0073-generation-floor) and calls
  `delete/2`, which then fails for an unavailable backend the metadata
  names;
- `sign_in(context, route, record, metadata)`, a login's write under the
  route's lock: unless the raw sides are exactly a pair that `read/2`
  returns as `{:ok, _}` or `roll_forward` in the backend and source the
  login writes, it first signs the route out as `sign_out/3` does without
  revocation, and then calls `write/4`. A failure of that sign-out fails
  the login with its class before the login's own pair is written. A switch
  of backend or source therefore discards the earlier grant unrevoked; `auth
  logout` before the switch revokes it.

`write/4` follows the pairing rule's write protocol. `auth login` and `auth
logout` call `sign_in/4` and `sign_out/3`, and composition tests run those
two functions in child OS processes, so every store sequence is proved
without `loopex_cli`.

*Callers and lifecycle of the context.* `auth login` and `auth logout` build
the context through `LoopexCli.Home` after selection and pass it to each store
call; a refusal there is exit 76. Foreground chat, durable and ephemeral
`ask` and the daemon receive it from their command's row of ADR 0037's table
and pass it to the opener that starts their routes, under
[route owners](#technical-adr-0073-route-owners), which gives it unchanged to
each `SignIn.Route`. No default is computed: an `oauth` binding that reaches
`CredentialHost.open/4` or the daemon without a context, or a composition
other than through a borrowed plane, refuses `provider_sign_in_required`
(D50). The refresher keeps the
context for its life and passes it to every store call. It also keeps the
`excluded_env_names` of the whole bindings map its opener was given, and
`auth` the list its selected configuration's
bindings give (`LOOPEX_PROVIDER_API_KEY` alone without one): the refresh
lock's process probe and every keyring child are spawned with each of those
names unset, as the placement probe is (`placement.ex` :557).

Every keyring child (`security`, `secret-tool` and the two wrappers) is
bounded at 5,000 ms. OTP starts each port program as the leader of its
own process group, whose ID is the port's `os_pid` (observed on macOS
with the current pair's OTP 29; the keyring-bounds test proves it on both
hosts and toolchain pairs), and a
wrapper's shell and pipeline inherit that group. At the bound the backend
runs `/bin/kill -KILL -- -<os_pid>`, ending the child and every process it
started, and answers `credential_store_unavailable`, so a
keyring that waits on an unlock prompt never holds the refresh lock beyond
that bound. A bounded write failure is a store write failure: a refresher
takes the pending-write path of refresher step 4, and `auth` exits 69.
The three executables, `/usr/bin/security`, `/usr/bin/secret-tool` and
`/usr/bin/head`, are compile-time values of the backend modules: those
absolute paths in every build except `Mix.env() == :test`, where each is read
from the `:loopex_composition` application key `:sign_in_test_executables`,
as the keychain argument below is. That is the seam through which the
store tests run recording fake executables; the source check of
`sign_in_keychain_test.exs` covers both keys.
Backends:

1. **macOS Keychain.** The backend runs `/usr/bin/security`, by absolute path
   only, in the user's default keychain.
   - The item is a generic password with service `loopex-oauth` and account
     `<home-digest>:<route>`. `home-digest` is the first 16 hex characters of
     the SHA-256 of the canonical absolute home path, so two homes never
     share an item.
   - Writes send `add-generic-password -U -s ... -a ... -w <record>` as one
     line on standard input to the fixed wrapper
     `/bin/sh -c '/usr/bin/head -c "$1" | exec /usr/bin/security -i' sh <bytes>`.
     `security -i` reads commands until end of input and has no command that
     ends it, and an Erlang port cannot half-close standard input, so `head`
     ends the input after the line's bytes. The wrapper's exit status is
     `security`'s, nonzero when the command fails. The secret never appears
     in argv. The record is base64url-encoded first, so it needs no quoting.
   - Reads use `find-generic-password -s ... -a ... -w` on standard output.
     Deletes use `delete-generic-password`. Exit status 44, no such item, is
     no record; any other failure, such as a locked keychain on a host with
     no unlock prompt, is `credential_store_unavailable`.
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
     and the route's start refuses `credential_store_unavailable`, so the
     daemon exits 121. It never falls back to the file backend.
   - A locked or absent keyring at `auth login`: `--store auto` on Linux
     picks `file` only when the route has no metadata file; when metadata
     names `secret_service`, `auto` keeps that backend and exits
     `credential_store_unavailable` (69). A forced
     `--store secret-service` exits 69 likewise.
   - Attributes are `application loopex-oauth home <digest> route <route>`.
   - `secret-tool store` reads the secret until end of input. An Erlang port
     cannot half-close standard input, so the backend runs the fixed wrapper
     `/bin/sh -c '/usr/bin/head -c "$1" | exec /usr/bin/secret-tool store --label="$2" application loopex-oauth home "$3" route "$4"' sh <bytes> <label> <digest> <route>`.
     The byte count comes from the encoded record and the secret arrives on
     the port. Only non-secret values appear in argv.
3. **File.** The record lives in `<home>/auth/<route>.secret`, mode `0600`.
   - Each write creates `<route>.secret.<16 random hex>.tmp` with
     `[:write, :exclusive, :binary, :raw]` inside the `0700` directory, so no
     file server process receives the record, and sets mode `0600`. It then writes, calls `:file.sync/1`, renames over the target and
     syncs the directory.
   - Because the directory is `0700`, the moment before `chmod` exposes
     nothing to another user.
   - Each read opens `<route>.secret` with `[:read, :binary, :raw]`, so no
     file server process receives the record either.
   - Stale `*.tmp` files older than one hour are removed by the next writer.
   - Metadata uses the same atomic write.

Every store call that reads or writes a record runs in a `:sensitive`
process: the `SignIn.Route` refresher, or the `auth` command's exchange
process. A keyring child is a port owned by that process, which also
enforces the child's 5,000 ms bound, so no other process, such as a
`Task`, receives a record.

Backend selection: `auth login --store auto` is the default. Over existing
metadata naming a token backend, `auto` keeps it. Otherwise, on macOS, `auto`
picks `macos_keychain`. On Linux it picks `secret_service` when available, and
otherwise `file`, printing `loopex: no keyring available; token stored in
<path>` on standard error. `--store keychain|secret-service|file` forces one
backend, and an unavailable forced backend exits `credential_store_unavailable`.
The selected backend is recorded in metadata, and every later reader uses
exactly that backend. There is no silent migration between backends: a login
that selects another backend or source signs the route out first
(`sign_in/4`), so no record is left in a backend the metadata no longer
names. A cut after that sign-out leaves the route signed out, and
rerunning the login completes it.

**Refresh lock.** `<home>/auth/<route>.lock` uses `LoopexComposition.Placement`'s
exact algorithm: an `O_EXCL` lock file, owner process incarnation, stale
reclamation under the directory guard, and an inode-checked owner handle. The
primitive moves into a shared private module that every lock user calls; no
second lock algorithm is written. No Loopex-stored refresh token is exchanged without
the lock, because OpenAI's
[token reference](https://developers.openai.com/siwc/token-sharing-open-source/token-reference)
rotates it on every refresh and a daemon, a foreground chat, an `ask` and
`auth` may share one home.

- *Hold.* The lock is held across read, exchange and write: the exchange's
  invocation deadline, in a durable host the companion's cleanup period
  after it, and the write, whose keyring children are each bounded at
  5,000 ms. A logout that meets such a refresh for longer than its
  10,000 ms wait exits 73 having changed nothing.
- *Acquisition.* A refusal as active is retried every 100 ms; at 10,000 ms
  the caller gives up with `sign_in_lock_busy`. The primitive's call can
  itself outlast that (up to 2,000 guard attempts, each `ps` probe bounded
  at 5,000 ms, `placement.ex` :287, :513), so it runs in a worker the caller
  stops waiting for at the deadline. The worker is spawned unlinked and
  monitored, owns its own release, and is not stopped by the route's
  shutdown, so it is never killed inside the guard and a late success is
  released at once. `placement_unverifiable` and `placement_lock_failed`, a
  permanent malformed guard included (:344-348), are not busy: they are
  `sign_in_lock_failed`, with the same no-write behaviour and the same exit
  73, and the printed line or diagnostic names the primitive's cause so the
  operator can repair it. Either class exits 73 in `auth`; a
  refresher exchanges nothing, writes nothing, leaves custody as it was and
  retries on step 5's schedule, and step 7 at its next poll.
- *Owner.* The primitive's owner is the operating-system process
  (`current_owner/1` records `System.pid()`, :414-421), a lock is stale only
  when that process is gone (:482-489), and an acquirer in the same process
  is refused as active (:160-162). So `SignIn.Route` traps exits, takes and
  releases the lock inside `try ... after`, and runs each exchange in a
  separate linked process. Sent `:shutdown`, it finishes an exchange in
  progress and that exchange's write, starts no other, and exits with
  reason `:shutdown`, which ADR 0071's `:sign_in_routes` step counts as
  stopped; its
  opener waits up to 60,000 ms for that before `:kill`, as
  [route owners](#technical-adr-0073-route-owners) states. That covers one
  exchange and its write under the default 5,000 ms cleanup period
  (`durable_options.ex` :127-129); a longer configured period can make them
  outlast it.
  Residual (D41): an interrupt, a chat or `ask` backstop halt (M6's fixed
  10,000 ms `ask` backstop is unchanged), a daemon fail-stop, startup
  reverse cleanup, the 60,000 ms bound itself, or an embedding host whose
  stop waits less, can kill a route mid-exchange, losing a token the
  provider rotated before the write, and the route then needs `auth login`;
  a `SignIn.Route` killed while holding the lock, or an acquisition worker
  killed inside the guard, in an embedding VM that survives strands the
  lock or its guard until that VM exits.

<a id="technical-adr-0073-fence"></a>
**Fence.** A result obtained without the route's lock (a pending write's
record, an ADC refresh's access token or `sign_in_required`, a
refresh-time or adoption-time model list, step 7's nomination) belongs to the *tuple* it was obtained for: the route,
`client_id`, `subject_digest` and generation `G` of the pair it came from.
It is published by this rule only:

1. Take the lock. `sign_in_lock_busy` or `sign_in_lock_failed` publishes
   nothing and changes nothing; the producer retries as it states.
2. `Store.read/2`, completing a `roll_forward` first and judging the
   completed pair. `Store.read/2` applies the
   [generation floor](#technical-adr-0073-generation-floor) itself, so a
   pair a logout has already floored is `:absent` and is never rolled
   forward.
3. The *same tuple* publishes a pending write's record in any `state`,
   because another process refreshing with the token that write's exchange
   rotated may have written `sign_in_required` at `G` (refresher step 4).
   It publishes any other result only at `state: signed_in`, a step 7
   nomination having none to publish and an `adc` refresh's
   `sign_in_required` publishing that `state` at `G` as refresher step 6
   does; at another `state` it rotates custody
   to `nil` and stops the refresh schedule as refresher step 6 does, writing
   nothing. A consistent
   *newer* pair, at a greater generation with the same subject and client
   and `state: signed_in`, is adopted and the result discarded: custody
   rotates to its token, a stopped refresh schedule restarts from step 4,
   and for `chatgpt` one `model_list` runs under this fence; an `adc` pair
   stores no token, so its adoption takes the newer tuple and refreshes
   again on step 5's schedule. *Anything else* discards the result, stores
   nothing it obtained and rotates custody to `nil`, the only write being
   the [recovery rule](#technical-adr-0073-pairing)'s `state:
   sign_in_incomplete` on an inconsistent pair's existing metadata: `:absent` also stops the refresh
   schedule, `inconsistent` names `sign_in_incomplete`, another subject or
   client `sign_in_account_changed`, and a newer pair not `signed_in`
   stops refreshing as step 6 does.
4. Unlock only after custody and any write are done, so the next lock
   holder sees them.

<a id="technical-adr-0073-exchange"></a>**Exchange executors.** Every token-endpoint exchange posts a fixed form to a
compiled HTTPS endpoint, with a 30,000 ms bound. That covers code exchange,
refresh and revocation, and device polling where a provider offers it. The
reply is at most 196,608 bytes and is validated against the profile. An
exchange runs in one of two executors, chosen by the host's isolation
contract:

- **Companion executor.** Durable hosts use it: foreground chat, durable
  `ask` and the daemon. The exchange is a new invocation kind,
  `token_exchange`, of the existing ADR 0019 provider companion. It has the
  same launcher, guardian, scrubbed environment, nonce and manifest proof, and
  private channel.
  - *No runtime.* A route refreshes before any composition exists and
    outlives each one, so its invocations never use a composition's plane or
    trace capability. They run in ADR 0034's no-runtime Direct mode, which
    `complete_prompt/3` already uses (`req_llm.ex` :227-246) and which D62
    extends to them, as [amended](#technical-adr-0073-amendments): two adapter
    functions beside it, `Loopex.LLM.ReqLLM.token_exchange/2` and
    `model_list/2`, refuse a caller-supplied `:tracing_capability`, add a
    fresh `TraceCapability.Direct` marker and run the guardian under the
    unmanaged lifetime (`provider_bridge.ex` :51-68), which the route's
    exchange process has because no runtime started it
    (`provider_lifetime.ex` :36-41). The Direct sender clears and verifies
    its inherited trace flags before it receives the token, with no runtime
    `Control` (`provider_bridge.ex` :1029-1036, :1048-1064).
  - *Launch options.* The opener gives each route the companion's launch
    options and cleanup period: the daemon its own `:provider_launch` and
    `:cleanup_grace_ms` (`service.ex` :626-627), chat and durable `ask`
    `LoopexCli.ProviderLaunch.options/0` and their composition's period
    (`chat.ex` :65, :160; `durable_ask.ex` :74, :148), with
    `Loopex.Executor.default_cleanup_grace_ms()` when none is set.
  - *Secrets through custody.* As ADR 0034's Direct caller does, the
    exchange process starts, for each invocation, one `CredentialRegistry`
    and one `CredentialCustody` holding the secret, puts that custody under
    a fresh `CredentialToken`, passes only the token and the registry handle
    as `credential_token` and `credential_registry`
    (`provider_configuration.ex` :11-14, :119-126), and stops both with
    `CredentialPlane.stop_bindings/1` (`credential_plane.ex` :180-192) before
    it returns. The sender resolves that token once, as for every
    invocation.
  - *Sensitive processes.* For both kinds the guardian, its frame receiver
    and the credential sender set `:sensitive` as their first action, before
    a secret or a token response can reach them, as `SignIn.Route`, its
    exchange process and every custody do. Today only custody does
    (`credential_custody.ex` :109): the receiver is spawned with only
    `[:link, :monitor]` (`provider_bridge.ex` :917-924) and the guardian only
    traps exits (:655-656). A `:sensitive` process generates no trace
    message, so a refresh token, a token response and an ID token pass only
    through sensitive host processes.
  - The companion performs the one POST with its own TLS settings and returns
    the validated token response on the private channel. An `id_token` of at
    most 16,384 bytes is returned with it, unverified; verification belongs to
    the receiving host process, under
    [ID-token verification](#technical-adr-0073-id-token).
  - In the parent, the frame receiver reads the terminal frame and sends it
    to the guardian, which delivers the result only to its caller, the
    route's exchange process (:1739-1744).
  - No raw provider body, header or error text crosses. Failures are the
    closed classes below.
  - A second new invocation kind, `model_list`, of the same companion serves
    [`chatgpt` model admission](#technical-adr-0073-model-admission): the
    access token crosses as the credential frame, and only the bounded,
    validated model list returns.
  - *Frames.* Both kinds keep ADR 0019's launcher, guard, nonce, bootstrap,
    readiness and cleanup, with these data frames. Neither is a Model call,
    so no Control permit, semantic request, staged digest,
    `dispatch_started` or delta frame exists for them.
    - Credential: the custody's one value, 1 to 65,536 bytes as for a
      model invocation (`provider_bridge.ex` :1384-1388): for
      `token_exchange` the refresh token, or on an `adc` route the file's
      `client_secret`, a NUL byte and its refresh token, which the companion
      splits at the NUL; for `model_list`, the access token.
    - Invocation: the kind, the route, its source and `client_id`, and for
      `token_exchange` whether the profile's key set is fetched; no secret.
    - Terminal: exactly one of the validated token response, with its
      `id_token` of at most 16,384 bytes and, when fetched, the key set of
      at most 65,536 bytes; the validated model list; or one closed failure
      class from the table below.
    - The invocation deadline is the 30,000 ms request bound, plus 10,000 ms
      when the key set is fetched, and the guard's cleanup period is the
      `cleanup_grace_ms` the opener gave, as for a model invocation.
- **In-host executor.** The ephemeral profile and the `auth` command use it.
  Each credential-bearing request, an exchange, a revocation, a
  `model_list` or the `vertex` project check, runs as ADR 0039's in-process
  caller runs a model call: after `InProcess.Guards.host/0` refuses
  non-empty `:req` default options and a set `SSLKEYLOGFILE`
  (`in_process/guards.ex` :59-70), from a `:sensitive` process, through
  `Loopex.LLM.ReqLLM.OneShotHTTP1` on a call-owned tagged pool that
  `InProcess.PoolLifecycle` owns, with the profile's TLS options and
  retention and tickets disabled, and its result returns only after that
  pool's teardown proof. The credential-free key-set fetch below is the one
  request made with `Req` directly. The `auth`
  command starts `Req` and `Finch` before its first exchange and, like
  `ask` (`apps/loopex_cli/lib/loopex_cli.ex` :71-72), turns its logger off
  first. The launcher disables crash dumps for it as for `ask`: the
  `ERL_CRASH_DUMP` settings its `case` sets only for `ask|-p` today
  (`apps/loopex_cli/bin/loopex` :60-67) are also set for `auth` (D37). Under
  D37 the refresh token, ID token, authorization code and
  access token may all live in this VM.

Exchange failure classes are closed:

| Class | Meaning |
| --- | --- |
| `sign_in_required` | Provider `invalid_grant`, `invalid_client`, or a revoked or expired refresh token |
| `provider_unreachable` | Transport failure or timeout, or HTTP 5xx |
| `sign_in_failed` | A malformed or over-bound reply, including an `expires_in` that is absent, not an integer or below 10, an ID token that fails [verification](#technical-adr-0073-id-token), or granted scopes missing a required scope |

Of these classes only `sign_in_required` changes the stored `state`. A verified subject
different from the stored one is not an exchange failure; the host refuses
it as `sign_in_account_changed`.

<a id="technical-adr-0073-route-owners"></a>**Refresher, custody and route owners.** Each `oauth` binding has one
`LoopexComposition.SignIn.Route` and one ordinary `CredentialCustody`, which
the route only rotates. `CredentialPlane.load_bindings/2` starts that
custody *unavailable*, with no value and a deadline already past, and
registers it in the `CredentialRegistry` under a fresh `CredentialToken` in
`provider_routes`, as it does an `env` route's custody (`credential_plane.ex`
:124-142), and `ProviderConfiguration.validate_routes/1`'s provider list
(`provider_configuration.ex` :146-153) gains the three sign-in routes. It
starts no route, and neither does composition:
`LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` refuse an
`oauth` binding given as `:provider_bindings` (`Edges.credential_plane/2`,
`edges.ex` :42-59) with `provider_sign_in_required`, and reach a sign-in
route only through a borrowed plane. The process that opens the bindings
starts each route right after the custodies, linked to a process that traps
exits, and stops it. It gives `SignIn.Route.start_link/1` the sign-in
context, the route's custody reference, the `excluded_env_names` of the
whole bindings map and the route's executor: the companion, with the launch
options and cleanup period [the companion executor](#technical-adr-0073-exchange)
names, or in-host. `start_link/1` returns only after
refresher steps 1 and 2 below, so a route that refuses its start makes the
opener refuse: the opener stops what it started, as its startup cleanup
does, and reports the route's class.

| Opener | Starts and supervises | Unexpected route exit (D38, D42) | Normal stop (D41) |
| --- | --- | --- | --- |
| Daemon | `LoopexDaemon.Service.start_binding_plane/1` (`service.ex` :520-548), after `load_bindings/2`, starts each route with the companion executor, links it to the service, which traps exits (:123), and tracks it as `{:sign_in_route, index}`, which `component_kind/1` (:1645-1646) maps to `:sign_in_route` and the running classes (:104-115) to `:sign_in_route_lost`. A route's start refusal stops the service with that class's status, where a plane failure stops it with `credential_plane_start_failed` today (:546-547) | Fail-stop 123; `fatal_reason/1` (:1425-1428) sends attached clients `daemon.stopping` with `fatal:sign_in_route_lost` | ADR 0071's `:sign_in_routes` teardown step, first: each route sent `:shutdown` and given up to 60,000 ms before `:kill`. Startup reverse cleanup stops it with `stop_component/3`'s 5,000 ms (:1702) |
| Foreground chat, durable `ask`, ephemeral `ask` | `LoopexComposition.CredentialHost.open/4` (new), called in the command process with the bindings, the sign-in context, a `lost` function and the options `executor: :companion` with `provider_launch` and `cleanup_grace_ms`, or `executor: :in_host`. It loads the bindings through `load_bindings/2`, as `open/1` loads its own, the custody linked to the command process (`credential_host.ex` :68-79), all of them with the companion executor and only the `oauth` ones in-host, then spawns one *route keeper*, linked to the command process, that traps exits, so it receives the command process's exit as a message, and links each route to itself | The keeper calls `lost` for any route exit it did not request, and for an exception in its own loop, which runs inside `try`. The CLI's function calls `LoopexCli.Interrupt.halt_owning_nothing/2` (new, public) with the line `loopex: sign_in_route_lost` and status 1; the backstop's private `halt_owning_nothing/0` (`interrupt.ex` :1719-1725) becomes a call of it with its note and 130, so both kill the VM's owned process groups before they print and halt | `CredentialHost.close/1` (new), called after the composition has stopped and before the command returns its status: the keeper sends each route `:shutdown`, gives it up to 60,000 ms before `:kill`, and replies when every route is down. A command process that ends first makes the keeper do the same |

- Foreground chat composes today with `:provider_bindings` (`chat.ex` :211),
  which makes its custody an edge of `RuntimeOwner`'s composition. It
  instead opens `CredentialHost.open/4` with its selected bindings and the
  companion executor immediately before it composes (:124), after placement
  and after its driver, which prints a startup refusal, has started, and
  passes `plane/1`'s plane as `:credential_plane`, as
  `with_hosted_runtime/2` does for the legacy commands (`loopex_cli.ex`
  :1764-1775). `RuntimeOwner` therefore owns no route, and its cleanup,
  which gives each edge 1,000 ms before `:kill` (`runtime_owner.ex`
  :265-283), and its exit handling, which turns any owned edge's exit into
  `:runtime_stopped` (:105-108), stay as delivered. Residual: chat's custody
  and registry are then linked to the command process, as durable `ask`'s
  already are, so their crash ends chat without its orderly cleanup instead
  of reaching `RuntimeOwner` as an edge's exit.
- `ask`, durable and ephemeral, takes from the file ADR 0037 selects
  ([ADR 0037's `ask`](0037-host-configuration-and-path-discovery-technical.md#technical-0037-ask))
  the `providers` it names, and keeps its delivered environment route for
  every other provider (D54, D57); with no file it opens its delivered
  routes alone. In each merge below the file's member replaces the
  delivered member of the same provider.
- Durable `ask` already borrows `CredentialHost`'s plane through
  `LoopexCli.CredentialCache.host/0` (`durable_ask.ex` :71, :96-121),
  which opens `open/0`'s single-credential bindings, every compiled hosted
  provider bound to `LOOPEX_PROVIDER_API_KEY` (`credential_cache.ex` :21-36,
  `credential_plane.ex` :157-163). It instead merges those bindings with
  the file's `providers` and keeps only the bindings of the providers its
  model and maintenance model use (D60), because `load_bindings/2` opens
  all or nothing (:65-76, :124-129, :203-209). A model whose provider has
  no binding in the merge, such as a sign-in route the file does not name,
  refuses `provider_credential_required` before anything is opened, as
  durable `ask` refuses a missing key today (`durable_ask.ex` :224-235).
  It passes `CredentialCache` the kept bindings and its sign-in context;
  `CredentialCache` opens them with `open/4` and the companion executor
  where it calls `open/0` and `open/1` today (:21-56), and `ask` calls
  `close/1` after it releases the plane (`durable_ask.ex` :119). So a file
  that binds the model's route needs no API key, and an unrelated binding
  whose variable is unset does not fail it.
- Ephemeral `ask` passes `Ephemeral.start_session/1` as
  `:provider_bindings` the reference route of each compiled provider whose
  credential kind is not `:sign_in`, the one `Preflight` builds for the
  model's provider when given none (`preflight.ex` :132-139), merged with
  the file's `providers`, less every `oauth` binding of a provider that
  neither its model nor its maintenance model uses (D63), so it opens only
  the sign-in routes they use and a signed-out binding of another route
  does not refuse it; with no
  file it passes none, as today (`ephemeral_ask.ex` :129-135). `Ask` still
  discards `LOOPEX_PROVIDER_API_KEY` before the ephemeral profile starts
  (`ask.ex` :125-132), so a file binding naming that variable finds it unset
  there. With a file, ephemeral `ask` opens `open/4` with that whole map and
  the in-host executor: in-host, `open/4` reads no environment variable and starts
  custody only for the map's `oauth` bindings, so no `env` route enters
  custody, and its routes keep the whole map's `excluded_env_names`. Its
  load deletes only `LOOPEX_PROVIDER_API_KEY`, as `load_bindings/2` does
  for any map that does not name it (`credential_plane.ex` :75-76), which
  `Ask` has already discarded. It
  passes the host's `sign_in_routes`, below, to `Ephemeral.start_session/1`
  as the host option `:sign_in_routes`, and calls `close/1` after
  `Ephemeral.stop_session/1` returns and before `finish_interrupt`
  (`ephemeral_ask.ex` :383-392), so an interrupt during the routes'
  graceful stop is still handled by `ask`'s interrupt handler and its
  backstop (D41's residual). That stop request keeps its 11,000 ms bound
  (`ephemeral.ex` :22, :338-354); the route's 60,000 ms come after it.
- `CredentialHost.open/1`, which the legacy `run`, `resume` and `skill`
  reach through `LoopexCli.CredentialCache` (`credential_cache.ex` :38-56),
  has no context and drops every `oauth` binding before it loads the rest,
  so those commands never serve a sign-in route. They select no
  configuration file; a binding reaches them only as the host option
  `:provider_bindings`. Before `open/1`, in `credential_host/1`
  (`loopex_cli.ex` :1795-1803), after the model's route resolves, those
  commands without `--service` refuse a binding of that route whose
  credential is `oauth` with `sign_in_unavailable`, exit 1, and two lines
  on standard error,
  `loopex: sign_in_unavailable /providers/ROUTE/credential/oauth`, `ROUTE`
  being the binding's route, and `use loopex chat, loopex ask or --service`
  (D58 and its accepted note).
- Residual: no Loopex path kills a keeper with `:kill`. One so killed ends
  its opener through their link only while the opener does not trap exits;
  durable `ask` traps them while it follows its run (`follow_reader.ex`
  :48), so a kill then is not noticed: the run continues, `close/1` finds
  the keeper gone and returns, and the routes, which no keeper then stops,
  end when the VM exits.
- *Test seams*, compiled only under `Mix.env() == :test`, as the
  `LOOPEX_TEST_TRACE` seam is (`owner_activation.ex` :272-281): a
  `SignIn.Route` exits with reason `:test_route_exit` once the file that
  `LOOPEX_TEST_SIGN_IN_ROUTE_EXIT` names exists, checked every 100 ms, which
  a test-built command in a child OS process and a spawned daemon read from
  their environment; and `open/4` and the daemon start the module that the
  `:loopex_composition` application key `:sign_in_test_route_module` names
  in place of `SignIn.Route`.

A halt on route loss leaves a durable run without a terminal, and it
resumes later as any interrupted run does. An ephemeral `ask` cannot
resume: as after ADR 0039's named worker-reap hard halt, the command makes
no cleanup claim and its temporary root stays in place. `sign_in_route_lost`
joins `loopex.ask/1`'s fixed status-1 diagnostics (`ask_result.ex` :19-55)
as that halt's line; `ask` writes nothing on standard output in either
output mode.

`CredentialHost.plane/1` and the daemon's plane, both built by
`CredentialPlane.binding_plane/2` (`credential_plane.ex` :166-177), carry
`sign_in_routes`, a map from each sign-in route to its custody reference
and, for `chatgpt`, its model-list table
([`chatgpt` model admission](#technical-adr-0073-model-admission)), as a
plane member beside `model_options`, never inside it. `model_options`
keeps exactly ADR 0048's three members: composition appends it to the
adapter's options (`loopex_composition.ex` :231-238), whose closed key
check refuses any other key as `:invalid_provider_configuration`
(`provider_configuration.ex` :9-14, :22-36), which would fail every model
call through the plane. `Edges`' closed plane check (`edges.ex` :91-106)
admits the member in its key list (:95-96), and `Model.reference/2` keeps
the whole plane in its host options (`model.ex` :41).

`CredentialCustody.resolve/1` changes in one clause: it checks a finite
deadline before the value (`credential_custody.ex` :133-146 checks the value
first today). So custody with no value and a past deadline answers
`:expired`, a route that has no usable token for a transient reason, which
callers report as `model_call_failed`, while `rotate(reference, nil)` with
the default `:infinity` deadline still answers `:missing`, the route that
needs sign-in. No delivered caller rotates to `nil` with a finite deadline.
The token module is unchanged.

1. At start it reads the pair through `Store.read/2` without the lock. One
   write landing during that read yields `{:ok, _}` or `roll_forward`, but
   two can leave the record two generations ahead, so an `inconsistent`
   result is read again under the lock before it is judged. A
   `roll_forward` result is completed under the lock first. A
   `sign_in_lock_busy` or `sign_in_lock_failed` at either locked read leaves
   custody unavailable, so resolution returns `:expired`, and the route
   retries that read on step 5's schedule, handling its result as a running
   refresher does. An `absent` or `inconsistent` result, a
   client ID that does not match the compiled client (the Google `loopex`
   source) or the issued client in metadata (OpenAI), or `state:
   sign_in_required` refuses the route's start with
   `provider_sign_in_required`; this is the maintainer's 2026-10-13 startup
   rule. A `credential_store_unavailable` or `credential_store_unsafe`
   result refuses it with that class. An `adc` route starts as
   [the ADC source](#technical-adr-0073-adc) specifies. The opener refuses
   with the route's class: the daemon exits 120, 121 or 122, and foreground
   chat and `ask` refuse as
   [foreground refusals](#technical-adr-0073-foreground-refusals) states.
2. If the access token expires within the refresh window, it refreshes under
   the lock. The window is the smaller of 300 s and half the token's
   lifetime. At start, a refresh answered `sign_in_required` for a stored
   `loopex` sign-in also refuses the route's start with
   `provider_sign_in_required`, after step 6's write (D51); its other
   failures do not refuse.
3. It rotates custody to the access token with the `expires_at` the
   [custody deadline](#technical-adr-0073-custody-deadline) below sets, in
   monotonic time, using custody's existing `rotate/3`.
4. It schedules the next refresh at the window's start. Each refresh first
   calls `Separation.check(context)` on its own context; a refusal exchanges
   nothing, writes nothing, leaves custody as it was, names
   `auth_root_overlap` with the pointer and retries on step 5's schedule,
   so a provider never rotates a refresh token the store would refuse to
   keep (at start the same refusal refuses the route's start, which the
   daemon reports as ADR 0071's `configuration_invalid`, 111, with the line
   `loopex daemon refused to start: configuration_invalid auth_root_overlap
   <pointer>`, foreground
   chat as ADR 0037's `auth_root_overlap`, and `ask` as
   [foreground refusals](#technical-adr-0073-foreground-refusals) states). It then
   takes the lock, rereads the pair and judges it as the
   [fence](#technical-adr-0073-fence) does with its held tuple: a newer pair
   is adopted without contacting the provider, and anything else exchanges
   nothing and never writes over another account's secret. For the same
   tuple it exchanges, merges the response under
   [the refresh-response rules](#technical-adr-0073-refresh-merge), writes,
   rotates custody and only then unlocks; the exchange runs inside that one
   lock hold and needs no fence. For `chatgpt` it then runs one
   `model_list` with the access token it wrote, published through the
   fence.

   *Write failure after a successful exchange.* The provider may already
   have rotated the refresh token (OpenAI does on every refresh), so the
   merged record is the only usable grant. When `write/4` fails after a
   successful exchange, with any store class or `auth_root_overlap`, the
   refresher rotates custody to the new access token with the deadline from
   this exchange's `t0`, keeps the merged record only in its own
   `:sensitive` process state, releases the lock, and
   retries only the write on step 5's schedule, never exchanging again and
   running no `model_list` while the write is pending. Each retry is
   published through the fence with the tuple the exchange was judged on;
   publishing writes the pending record under the write protocol and, for
   `chatgpt`, then lists. The retry also counts as the same tuple an
   `inconsistent` pair whose metadata names that tuple and whose record is
   undecodable, which is what its own Secret Service write cut short leaves;
   a record its own write left at `G + 1`, as after a failed keychain
   read-back, is a `roll_forward`, completed and adopted as newer. Each
   attempt writes one bounded host diagnostic line, `loopex: provider
   sign-in store write pending for route <route>: <class>`
   (`sign_in_store_write_pending`).

   If the access token's deadline passes while the write is pending,
   resolution returns `:expired`. If the process stops first, the rotated
   refresh token is lost and the route needs `auth login` again; this is
   the residual of the threat model's refresh-token reuse row. Another
   process that refreshes meanwhile with the stored, already rotated
   refresh token receives `sign_in_required` and may write that state at
   `G`, which the pending write then replaces at the next generation. An
   `auth logout` meanwhile revokes only that stored, already rotated token,
   so it may exit 74 `revocation_unconfirmed`; the pending record is then
   discarded unrevoked, and its grant lapses at the provider.
5. A refresh that fails `provider_unreachable` or `sign_in_failed` writes
   nothing and retries with delays of 5, 15, 30, 60, 120, then every 300 s.
   The custody keeps the old token until its `expires_at`. After that,
   resolution returns `:expired` and the sender refuses before dispatch.
6. On `sign_in_required` it rotates custody to `nil`, so resolution returns
   `:missing`, which a call on the route reports as the public reason
   `provider_sign_in_required`. It writes `state: sign_in_required`, writes one bounded host
   diagnostic line, `loopex: provider sign-in required for route <route>; run
   loopex auth login <provider>`, and stops refreshing.
7. Every 30 s it reads the metadata file and the
   [generation floor](#technical-adr-0073-generation-floor), both
   non-secret, and keeps doing so after step 6 or a logout stopped
   refreshing; an `adc` route does the same. When the floor's generation is
   at or above the generation of the tuple it holds, it rotates custody to
   `nil` at once, without the lock: `auth logout` writes the floor before it
   deletes anything, and a floor never decreases, so a logout cut after its
   floor write still ends custody. When either file differs from its last
   nominated read, it then applies the [fence](#technical-adr-0073-fence)
   with no result of its own; a nomination refused `sign_in_lock_busy` or
   `sign_in_lock_failed` records no read, so the next poll nominates again.
   While a write is pending it nominates nothing, because each retry of that
   write applies the fence itself.
   This is how a fresh `auth login` of the same account and client reaches
   a running service, after a logout too: the generation floor makes the
   new login's generation greater than anything the service held. A logout
   therefore leaves custody `nil` at the first poll after its floor write,
   within 30 s whether or not another process holds the lock; a re-login is
   adopted at the first poll whose nomination takes the lock; and a
   different subject or client stays refused until a restart.

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
- A token read from the store, at start or by an adoption, has no exchange
  time. Its lifetime is
  the remaining wall-clock time, `remaining_ms = access_expires_at - now`, and
  `expires_at = t0 + remaining_ms - min(60_000, div(remaining_ms, 4))` with
  `t0` read at that moment. A non-positive remainder gives a deadline already
  past, so resolution returns `:expired` until a refresh succeeds.
- The refresh is always due before the deadline: for every lifetime `L` the
  window `min(300 s, L/2)` exceeds the skew `min(60 s, L/4)`.

For a 30 s token the window is 15 s and the skew 7,500 ms: the refresh is
scheduled at 15 s and custody returns the token until 22,500 ms after `t0`.

A call already dispatched keeps the token it was sent with. Rotation never
cancels, repeats or reclassifies an attempt; ADR 0018 governs the attempt as
before. The access token resolved for a call is the call's selected
credential. `worker_invoke/4` and the in-process caller pass it to the
existing echo guard unchanged, so a mapped reply containing it is withheld and
failed. The refresh token never reaches a model call, so it cannot be echoed
there. The refresher, its exchange process, every custody and, for both
companion kinds, the guardian, its frame receiver and the credential sender
are `:sensitive`; no new trace selector exists.

<a id="technical-adr-0073-model-admission"></a>
**`chatgpt` model admission.** Concept decision 14.

- *Fetch.* `model_list` is one credential-bearing `GET
  https://api.openai.com/v1/models` to that compiled endpoint, with the
  current access token as `Authorization: Bearer`, a 30,000 ms bound and a
  response body of at most 1,048,576 bytes. It runs in the route's exchange
  executor: the companion's `model_list` invocation in durable hosts, never
  the durable host VM; the in-host executor in the ephemeral profile and in
  the `auth` command, under the host-VM audience D37 accepts. The refresher runs it
  after each successful refresh, a pending write's success included, and
  each adoption; `auth login openai`
  runs it once with the newly exchanged access token after ID-token
  verification and before `sign_in/4`, so the login's first write already
  carries the list.
- *Validation.* The response is one JSON object whose `data` is a list; the
  kept entries are those with `visibility == "list"`. Each kept `id` matches
  `\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z`, at most 128 bytes; at most 256 ids
  are kept, sorted and without duplicates. No listed id, more than 256, an
  invalid id, a body over 1,048,576 bytes or a malformed body is
  `sign_in_failed`. Refusing an empty list is this record's reading of
  D25's required list: an account that lists no model has no usable
  `chatgpt:` route. A transport failure,
  timeout or non-2xx status is `provider_unreachable`. No raw body, header or
  error text crosses the private channel or reaches a diagnostic.
- *Record at login* (D25). The list is part of `auth login openai`. The
  login's `sign_in/4` writes the metadata with the validated list as
  `models`. A login whose `model_list` fails writes no token record, no
  metadata and no floor change, and exits with the failure's class: 68
  `sign_in_failed` for a malformed body, an empty list, an invalid id, more
  than 256 listed ids or a body over 1,048,576 bytes, and 72 `provider_unreachable`
  for a transport failure, the 30,000 ms timeout or a non-2xx status. The
  exchanged grant is discarded with the `:sensitive` exchange process and is
  not revoked: the provider-side grant is left to expire or rotate, which is
  acceptable because no copy of it survives in Loopex. A rerun of the login
  repeats the whole flow. A re-login over an existing sign-in that fails
  this way leaves the earlier pair, list included, exactly as it was.
  The login writes its list with the token it was fetched with, as one pair
  under the lock, so a logout or login that landed during the listing is
  superseded like any earlier pair. A same-account login cut after its
  record write and completed by `roll_forward` keeps the previous sign-in's
  list, because the record carries none, until the next refresh lists.
- *Record at refresh.* A refresh-time or adoption-time listing runs after
  the lock is released, so a success is published through the
  [fence](#technical-adr-0073-fence) with the tuple of the pair whose access
  token it presented. Publishing writes the list into the metadata's
  `models` with the atomic metadata write, keeping every other member, and
  updates the route's list table. A failure, including
  a lock refused at the fence, changes no stored state, custody or
  token, keeps the previous list, never `null`, and names
  `sign_in_model_list_stale` in one bounded host diagnostic line,
  `loopex: model list refresh failed for route chatgpt: <class>; keeping
  the previous list`; the next successful refresh or adoption retries it.
  A refresh's own token write, a pending write and a `roll_forward` carry
  the existing `models` unchanged; only a login and the fence write a list.
  A process killed before the metadata rename leaves the previous list.
- *Admission.* A `chatgpt` `SignIn.Route` keeps the list it last recorded
  or read in a `:protected` ETS table that it owns and alone writes; the
  plane's `sign_in_routes` names that table. The check reads it with
  `:ets.lookup/2` and never calls the route, so a route waiting up to
  10,000 ms for its lock or 5,000 ms for a keyring child never delays a
  composition or a switch under its configuration deadline; a missing
  table refuses as a miss. The check never runs in `ProviderBindings`' pure
  resolution, which configuration inspection, selection and delegation also
  call without a route. Durable and ephemeral composition check the
  configured model and maintenance model against each `chatgpt` route's
  list before the composition is ready, refusing a miss with
  `provider_route_unavailable` as an unbound route refuses at
  `durable_options.ex` :243. A model or reasoning switch is checked in
  `LoopexComposition.Model.prepare_configuration/5`, after
  `resolve_configuration_routes/3`, against the lists that the
  `:credential_plane`'s `sign_in_routes` names, which `Model.reference/2`
  already keeps (`model.ex` :41), or in the ephemeral profile the
  `:sign_in_routes` host option, which that `Keyword.take/2` gains and the
  session owner passes beside `:provider_bindings`
  (`ephemeral/session_owner.ex` :3325-3330); a miss refuses as an
  unbound route already does there (`model.ex` :53-87), before any config
  commit or dispatch, and leaves the
  prior configuration. It is never a Model callback result, so Core sees no
  failed attempt and nothing retries. Resume keeps ADR 0048's rule of
  checking only the committed model's route; a committed model the account
  later stops listing is sent, and the provider's refusal is an ordinary
  dispatched failure.
- *Tests.* `provider_bridge_test.exs` (extended): the `model_list`
  invocation through the real companion boundary, its credential frame, the
  256-id and 128-byte bounds, the 1,048,576-byte body bound, the timeout,
  the closed failure classes and no raw body crossing.
  `sign_in_refresh_test.exs`: the list is refreshed after each refresh and
  after a re-login adoption, and a failed listing keeps the previous list
  byte for byte, never `null`, and emits one `sign_in_model_list_stale`
  line. **Delayed listing**, through the real refresher, store and lock: the
  fake server holds refresher R's `GET /v1/models` for generation `G` of
  account A until the test releases it, and answers it with a list distinct
  from every other list the test serves. Before the release, in another OS
  process, the test runs (a) `sign_out/3`; (b) `sign_out/3` then
  `sign_in/4` writing account B's pair; (c) a refresh of A by a second
  refresher, which writes `G + 1` and its own list, served again to R's
  listing after R adopts `G + 1`. After the release, R's
  list is never written: in (a) `auth/` holds no metadata or record and the
  floor is the one the sign-out wrote, in (b) and (c) the metadata and
  record bytes equal those the other process wrote, and in all three R's list table,
  observed through a switch admission, still refuses a model only the
  delayed list names. A fourth case releases the delayed answer with
  nothing changed and sees it written at `G`. A fifth holds the route's
  lock in another OS process when the answer returns and sees one
  `sign_in_model_list_stale` line naming `sign_in_lock_busy` and no write.
  The fake server's answers carry no token, and the test asserts that no
  retained output and no diagnostic line contains any token the fake
  server issued. `auth_command_test.exs`: a login whose `model_list` fails, once
  malformed, once empty and once over 256 ids (exit 68) and once timing out and once
  answering 503 (exit 72), writes no record, metadata or floor, both over an
  empty `auth/` and over an existing sign-in whose pair and floor stay byte
  for byte. `sign_in_store_test.exs`: a `chatgpt` metadata file without
  `models`, with `models: null`, and a `vertex` file with `models` are each
  `credential_store_unsafe`. `sign_in_model_admission_test.exs`
  (`apps/loopex_composition`): an unlisted model refuses
  `provider_route_unavailable` at durable and ephemeral composition, a switch
  to it is refused and keeps the prior model, and the fake server sees no
  model request; configuration inspection of the same file succeeds.

**Ephemeral profile.** The ephemeral composition starts no route and no
custody. A sign-in route reaches it only through the `:sign_in_routes` host
option, the map its host's `CredentialHost.open/4` opened
([route owners](#technical-adr-0073-route-owners)); `Ephemeral.start_session/1`'s
preflight refuses an `oauth` binding that map does not name with
`provider_sign_in_required`, before owner activation. So a sign-in route's
access token is held in that host's custody while the host's routes run,
rather than resolved by the caller alone; `env` routes keep ADR 0048's
caller-only resolution (amended below) and never enter that custody. The
composition does not use the durable registry or exclusion plane.
`in_process.ex` currently reads `System.get_env(variable)` in the sensitive
caller. For a `:sign_in` route it instead calls `CredentialCustody.resolve/1`
on the route's custody reference from that map. The reference is passed in host-private
model options next to the binding map, never in a request. `:missing`
refuses as `not_dispatched` with `provider_sign_in_required`, and `:expired`
as `not_dispatched` with `model_call_failed`. The cleanup owner admits the
new refusal as it admits a pre-adapter `model_call_failed`: its pre-adapter
match and `valid_result?/1` (`in_process/cleanup_owner.ex` :621-622,
:669-675) admit only `model_call_failed` today and begin cleanup as
`:result_refused` for anything else, which would seal the session. Everything
else in ADR 0039's caller, pool, cleanup and selected-value guard is
unchanged.

**Daemon and service.**

- A route whose start refuses (refresher steps 1 and 2) refuses the service's
  start with new exit statuses. ADR 0071 takes 111 to
  115, retiring 114, ADR 0072 takes 116 to 119 and 124, and ADR 0037 takes
  125 (D31), so these follow at 120:
  - `provider_sign_in_required` (120);
  - `credential_store_unavailable` (121);
  - `credential_store_unsafe` (122).
  `sign_in_route_lost` (123) is a fail-stop when a running `SignIn.Route`
  exits, like `custody_lost`, as the refresh lock's owner rule requires, through
  the running class and `fatal_reason/1` that
  [route owners](#technical-adr-0073-route-owners) names; the
  `fatal:sign_in_route_lost` it broadcasts is the reason
  `loopex.experimental/4`'s closed `daemon.stopping` set gains (D42;
  [protocol](#technical-adr-0073-failure-reason)).
  ADR 0071's other serving-time fail-stops, a helper owner's exit, the
  slice task's abnormal exit and a helper quiesce call that times out, use `runtime_lost`, already admitted,
  and its catalog refusal (111) is a startup failure before the listener, so
  no other M8 class reaches a client. A disabled source has no status of
  its own: it is 111 at configuration selection (D52).
- `LoopexDaemon.ExitStatus`'s moduledoc range and the `fetch/1` and
  `classes/0` specs extend through 125. Today the moduledoc says 65 through
  110 while both specs say `65..111`
  (`apps/loopex_daemon/lib/loopex_daemon/exit_status.ex` :12, :81, :85); this
  edit makes all three state `65..125`. With ADRs 0071, 0072 and 0037 the daemon's status set is exactly 65 to 125
  except 114, which ADR 0071 retired: every other integer in that range maps
  to exactly one class, and no class maps to 114. The assertion in
  `apps/loopex_daemon/test/command_test.exs`, which today checks
  `Enum.to_list(65..110)`, becomes `Enum.to_list(65..125) -- [114]`.
- Under the maintainer's 2026-10-13 decision, a sign-in route that is not
  ready at startup, because `Store.read/2` returns `absent` or
  `inconsistent` or metadata says `sign_in_required`, refuses start with
  `provider_sign_in_required` (120), leaving no socket, as does a startup
  refresh of a stored `loopex` sign-in answered `sign_in_required` (D51). A
  revocation or logout while the service runs never stops it: refresher
  steps 6 and 7 make only that route's calls refuse.
- At startup a refresh failing `provider_unreachable` or `sign_in_failed`,
  or a lock refused `sign_in_lock_busy` or `sign_in_lock_failed`, does not
  refuse start for a stored `loopex` sign-in. The service serves, and the
  route's calls refuse `model_call_failed` once custody answers `:expired`,
  until a refresh succeeds. An `adc` route starts as
  [the ADC source](#technical-adr-0073-adc) states.
- ADR 0037's start-on-demand presence check reads only the metadata file and
  the [generation floor](#technical-adr-0073-generation-floor). It refuses
  `provider_sign_in_required` when the metadata is absent, its `state` is not
  `signed_in`, or its generation is at or below the floor's, before starting
  anything. D22's refusal before anything is spawned therefore covers only
  what those two files show. An inconsistent pair, an unavailable or unsafe
  store (121, 122) and an `adc` file's failures are found only by the
  spawned daemon, and the starter refuses with the class its exit status
  maps to. Those two sentences are the content of D22's acceptance note;
  D51's refused startup refresh is likewise found only by the spawned
  daemon.
- Readiness keeps ADR 0037's four states; sign-in state is reported by
  `auth status` and the diagnostic command, not by readiness.
- The service's environment is not consulted for sign-in routes, and no
  connected client can trigger a login or name a store.

<a id="technical-adr-0073-foreground-refusals"></a>**Foreground refusals.**
Foreground chat and `ask` meet a route's start refusal in
`CredentialHost.open/4`, before any composition, and a disabled source at
configuration selection. Under D50:

- `provider_sign_in_required`, for a route not ready under refresher steps 1
  and 2 or an `oauth` binding without a sign-in context (an ephemeral `ask`
  without a usable `HOME` has none): chat prints its delivered startup
  refusal for the class (`chat.ex` :530-536) and exits 1; `ask` reports the
  new `loopex.ask/1` status-1 code `provider_sign_in_required`. Both add the
  hint line of [client-visible behavior](#technical-adr-0073-failure-reason)
  without `, then continue`, as `ask`'s diagnostic already adds guidance to
  one code (`ask_result.ex` :93-104).
- `sign_in_unavailable`, for a disabled source: chat prints it the same way
  and `ask` reports the new status-1 code `sign_in_unavailable`.
- `credential_store_unavailable` and `credential_store_unsafe`: chat prints
  its startup refusal for the class, and
  `ask` reports the delivered status-1 code `composition_unavailable`, as it
  reports other composition refusals (`ephemeral_ask.ex` :511,
  `durable_ask.ex` :230-234).
- ADR 0037's own refusals: chat prints the class ADR 0037 names. `ask`'s
  status-1 codes are a closed list (`ask_result.ex` :19-55) that this record
  extends only by the three codes above, and `AskResult.diagnostic/1` maps
  any other code to `command_failed` (:93-94). So a refusal while `ask`
  builds its sign-in context, such as `home_unavailable` or
  `auth_root_overlap`, the marked-ancestor rule's included, reports
  `command_failed`, and a route's
  start refused `auth_root_overlap` (refresher step 4) reports
  `composition_unavailable`.

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
    The authorize request uses the metadata's `client_id` when metadata
    exists, otherwise the
    [generation floor](#technical-adr-0073-generation-floor)'s, as after
    `auth logout`, and `dynamic_agent_client` only when neither exists. Should the
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
    project. A failure keeps the sign-in: the login prints `loopex auth:
    vertex project check failed: <class>` on standard error and still
    exits 0.
- `status` reads metadata and floors only: no secret, no network, no lock. It
  prints one line per configured or stored sign-in route: route, state,
  account label, backend, access and refresh expiry. Metadata whose
  generation is at or below the route's floor, as a sign-out cut after its
  floor write leaves, is shown as not signed in, as absent metadata is.
- `logout` is `SignIn.Store.sign_out/3`: under the lock it reads the
  record, revokes the refresh token at the profile's revocation endpoint
  through the in-host executor, writes the
  [generation floor](#technical-adr-0073-generation-floor), and deletes the
  secret and the metadata, in that order. The floor survives. `--local-only`
  skips revocation. A revocation failure still deletes locally and exits
  `revocation_unconfirmed`. A store that the metadata names and that is
  unavailable fails the delete after the floor write: the route is signed
  out, the record stays in that store, and the command exits 69; a rerun
  deletes it once the store is available. For `adc`, logout revokes
  nothing, writes the floor, deletes only Loopex's metadata and never
  touches gcloud's file.

Exit statuses of `loopex auth`, each with `loopex auth: <class>` on standard
error:

| Status | Class |
| --- | --- |
| 0 | Success; for `status`, every listed route is `signed_in` |
| 1 | Command-line refusal, with usage on standard error; ADR 0037's `home_unavailable`; ADR 0049's load and validation classes for the selected configuration |
| 65 | `sign_in_unavailable`: route disabled in this build, or a flow the provider lacks |
| 66 | `sign_in_denied`: the provider returned `access_denied` |
| 67 | `sign_in_timed_out` |
| 68 | `sign_in_failed` |
| 69 | `credential_store_unavailable` |
| 70 | `credential_store_unsafe` |
| 71 | `credential_store_write_failed` |
| 72 | `provider_unreachable` |
| 73 | `sign_in_lock_busy`, or `sign_in_lock_failed` naming the lock primitive's cause |
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

**Pairing rule.** `Store.read(context, route)` reads the metadata, then the
record from the backend the metadata names, then the floor. That order is an
invariant: a writer writes the
record before the metadata, so a write that lands during an unlocked read,
such as a startup read, yields `{:ok, _}` or `roll_forward`, never metadata
ahead of the record. When the greater generation of the two sides is at or
below the floor's, it returns `:absent` before anything else, because `auth
logout` writes the floor before it deletes; a logout cut after its floor
write is therefore never rolled forward or served. Without metadata it reads
no backend and returns `:absent`: a record no metadata names, as an
interrupted first login or store switch leaves, is never read, and the next
`sign_in/4` or `sign_out/3` removes it. A route whose metadata names
`backend: adc` has no record by design, and `read/2` reads no backend for
it: it returns `{:ok, metadata}`, or `:absent` under the floor; its tuple is
the metadata's route, `client_id`, `subject_digest` and generation;
`write/4` for `adc` writes metadata only. Otherwise it returns exactly one
of:

| Result | When |
| --- | --- |
| `{:ok, record}` | Both decode, and they agree exactly on `route`, `client_id`, `subject_digest` and `generation` |
| `{:roll_forward, record}` | Both decode, they agree on `route`, `client_id` and `subject_digest`, and the record's generation is exactly the metadata's plus one |
| `:inconsistent` | Every other combination: metadata without a record, the metadata's generation ahead of the record's, the record ahead by more than one, a different `subject_digest`, `client_id` or `route`, or an undecodable record |

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
- `inconsistent` makes the route unusable: a starting route refuses
  `provider_sign_in_required` (refresher step 1), and a running refresher rotates custody to
  `nil` and logs `sign_in_incomplete`. A lock holder that finds an existing
  metadata file in an inconsistent pair sets only its `state` to
  `sign_in_incomplete`, keeping its generation, subject and client; nothing
  else deletes or overwrites either side. `auth login` repairs it by
  writing a fresh pair; `auth logout` deletes both sides.

**Write protocol.** `Store.write/4` runs only under the route's refresh lock:

1. Call `Separation.check(context)` on the context passed to `write/4`, and
   on no other paths; an overlap refuses before any backend is opened,
   spawned or written.
2. Read both sides, the record from the backend being written, and the
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
still running the old account refuses its next refresh, writing only `state:
sign_in_incomplete` into the existing metadata.
`/usr/bin/security add-generic-password -U` replaces one item, so a killed
tool leaves either the old or the new record; a Secret Service store cut short
leaves an undecodable value; the file backend's rename leaves the old or the
new file. Each is classified by the table above. `delete/2` removes the
route's record from each of the host's backends and then the metadata, and
runs only after a sign-out's floor write, or when no side decodes and so no
metadata exists; a crash between them leaves metadata at or below the floor,
which is `:absent`.

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
`auth` command's `:sensitive` exchange process, or the `SignIn.Route`
refresher when an ADC file was replaced. The companion returns
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

- Retrieval is a credential-free `GET`: HTTPS only, redirects off, 10,000 ms
  bound, a body of at most 65,536 bytes. A failure is
  `provider_unreachable`. The `auth` command and the ephemeral profile make
  it in-host with `Req`. A durable host VM never starts `Req`
  (`apps/loopex_llm_reqllm/mix.exs` :68-70 declares `req_llm`, `req` and
  `finch` `runtime: false`), so there the `token_exchange` that needs
  verification fetches the set in the companion and returns it beside the
  token, and the cache and refetch rules below do not apply: each such
  exchange fetches a current set.
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
  `credential_store_unsafe`, which a refresh after startup handles as
  `sign_in_failed`.
- It is at most 65,536 bytes of UTF-8 JSON: one object, no duplicate keys,
  every value a string.
- Required: `type` exactly `authorized_user`; `client_id` and
  `client_secret`, each 1 to 256 bytes of printable ASCII; `refresh_token`
  under the token grammar, short enough that the client secret, a NUL byte
  and the refresh token fit the companion's 65,536-byte credential value.
- Optional: `quota_project_id`, ignored because billing uses the configured
  `vertex` project; `universe_domain`, which must be `googleapis.com`;
  `account`, ignored.
- Any other member, nested value or failed check is `sign_in_failed` with the
  detail `adc_invalid`. A later gcloud field is therefore refused by name, not
  silently accepted.
- `client_secret` is Google's non-confidential installed-app secret. It still
  travels only in the credential frame with the refresh token and never enters
  metadata or a diagnostic.

**Refresh.** Every refresh rereads the file, opened with `[:read, :binary,
:raw]` in the refresher's `:sensitive` process (in `auth`, its exchange
process), validates it, then posts
`grant_type=refresh_token` with its client ID, secret and refresh token
through the host's exchange executor. Loopex never writes gcloud's file, and
an unchanged Google refresh token stays valid, so concurrent processes may
refresh independently. The exchange therefore runs without the route's lock,
and its access token is published through the
[fence](#technical-adr-0073-fence) with the tuple of the metadata read
before the exchange; publishing rotates custody and handles the cases
below. A `sign_in_lock_busy` or `sign_in_lock_failed` drops the token and
retries on step 5's schedule; nothing is lost, because Loopex never holds the
only copy of an ADC grant.

- **Unchanged grant** (`adc_digest` equals the metadata's): the subject is
  the stored one, and an absent ID token changes nothing.
- **Replaced file** (`adc_digest` differs, as after another
  `gcloud auth application-default login`): the response's ID token is
  required and verified. The new access token enters custody only after that.
  The same subject writes metadata at the next generation with the new
  `adc_digest`. A different subject is `sign_in_account_changed`: custody
  becomes `nil` and metadata is unchanged. An absent or failing ID token is
  `sign_in_failed`, handled as refresher step 5 states.
- **File absent** (as after `gcloud auth application-default revoke`), or
  `invalid_grant`: published through the fence as `state: sign_in_required`
  at the read tuple's generation, custody `nil`.

**Startup.** A `SignIn.Route` for `adc` applies refresher step 1's state and
pairing checks; its client is the file's, bound by `adc_digest` and, for a
replaced file, by ID-token check 5. It then reads the file and refreshes
once, because no access token is stored. `provider_unreachable` or
a lock refused busy or failed serves with custody left unavailable, so the
route's calls refuse `model_call_failed` until refresher step 5's retry
succeeds. Every other outcome without a token refuses the route's start
(D22): an unsafe file `credential_store_unsafe` (the daemon's 122), and an
absent file, `invalid_grant`, `adc_invalid`, any other `sign_in_failed` or a
changed subject `provider_sign_in_required` (120).
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
produces, as does custody whose token is unusable for a passing reason, past
its deadline after a refused roll-forward (refresher step 1) or still
unavailable after the ADC source's startup met an unreachable provider or a
refused lock, stays `{:not_dispatched, "model_call_failed"}`. An `env` route
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

- `Loopex.Runtime.SessionCoordinator`'s `accept_model_result/3` admits
  `{:not_dispatched, "provider_sign_in_required"}` beside the existing
  `{:not_dispatched, "model_call_failed"}` and passes the category on, where
  today it settles every exact refusal as the bare `:not_dispatched`
  (`session_coordinator.ex` :10408-10414). Any other term is still
  ambiguous.
- `Loopex.Runtime.SessionState`'s `attempt_result/4`, which today records
  every non-reply outcome as `model_call_failed` (`session_state.ex`
  :5032-5033), records that category for it.
- `Loopex.Runtime.ProviderAttempt`'s `validate_result/2`, which admits only
  the two delivered error categories (`provider_attempt.ex` :730-745),
  admits `%{"kind" => "error", "category" => "provider_sign_in_required"}`
  with exactly those two keys, before `settlement_cell/4`.
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
  false}`: `maintenance_run_failure/1`, which today maps a failed reason
  only from `model_call_failed` and `unreadable_model_answer` and answers
  `invalid_maintenance_episode_transition` for any other
  (`session_state.ex` :7641-7649), maps the new reason to that failure, and
  `standalone_settlement_failure/3`, which today maps every terminal error
  settlement to `model_call_failed` (:4715-4717), maps the new category to
  it.

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

By D42 `loopex-experimental-4.json`'s closed `daemon.stopping` `reason_enum`
(schema :5686-5701) also gains `fatal:sign_in_route_lost`, its vectors gain
`daemon_stopping_fatal_sign_in_route_lost` beside
`daemon_stopping_fatal_drain_failed` (vectors :463), and the reason list in
`session_v2_schema_test.exs` (:247-270) gains it. `WireRecords.daemon_stopping/1`
(`wire_records.ex` :899-918) already carries any `fatal:<class>`.

The generation names stay `loopex.experimental/3` and `/4`. Before 1.0 only
the current contract is kept. The independent Node client in the release
check decodes the new vectors. Its daemon client keeps `daemon.stopping`
records without enumerating reasons (`clients/node/daemon-client.mjs` :16),
so for D42 it changes only the pinned daemon schema digest
(`clients/node/contract-manifest.mjs` :163), which the failure reason's
schema change already moves.

**Host and client readers.** Each delivered reader that closes the failed
reason or failure-category set admits the new value beside
`model_call_failed`; otherwise the refusal would fail the reader instead of
reaching the operator:

- `LoopexComposition.Ephemeral.SessionOwner`'s `failed_details/2`
  (`ephemeral/session_owner.ex` :2889-2904);
- `LoopexCli.AskResult`'s `details!/2` (`ask_result.ex` :209-217), so
  `loopex.ask/1`'s `failed` details carry the reason, with `ask`'s failed
  status 2;
- `LoopexCli.DurableAsk.FollowReader`'s `terminal_details?/2`
  (`durable_ask/follow_reader.ex` :345-350);
- the Node client's `clients/node/terminal-outcome.mjs` :49 and
  `clients/node/compact-result.mjs` :52;
- the in-process cleanup owner, as
  [the ephemeral profile](#technical-adr-0073-decision) states.

**Client-visible behavior.**

- Every client receives the terminal outcome `failed` with `reason`
  `provider_sign_in_required` and nothing else new.
- The reference chat and `ask` print one line, `loopex: provider sign-in
  required for route ROUTE; run loopex auth login PROVIDER, then continue`,
  where the route comes from the committed model's prefix. A durable
  session stays resumable, and the command's exit status is that of any
  failed run.
- A chat attached to the daemon under ADR 0071 prints the same line.
- Nothing retries automatically. After `auth login`, the running service
  adopts the token at its first 30 s poll that takes the lock (refresher
  step 7), and the next turn or
  resume dispatches normally.

<a id="technical-adr-0073-threats"></a>
### Threat Model

Concept: [Observable consequences](0073-provider-oauth-sign-in.md#concept-adr-0073-consequences).

| Threat | Mitigation | Residual |
| --- | --- | --- |
| Another local user reads tokens | Keychain and Secret Service are per user; the file backend requires a `0700` directory, a `0600` file and the same owner, with no symlinks | `root` and anyone with the user's account |
| A same-user process, including a host-authorized tool job, reads tokens | None structural. Items created through `/usr/bin/security` trust that tool, and any same-user process can run it. Secret Service answers any client on the session bus. The file is readable by the user | Equal to today's ambient API key in the invoking shell. Loopex never injects tokens into jobs, and the local executor environment still excludes credential names. Untrusted workspaces need OS isolation of the hand |
| Disk theft, home-directory copy or dotfile sync | Keyring backends encrypt at rest. ADR 0037's separation invariant keeps the auth directory, the ADC directory and every state root, backup, destination and available restore source disjoint by path, so tokens never enter backups | A mount that makes credential storage reachable inside a state root, backup or destination, or a credential file copied into a root (D27's operator limit). The file backend is plaintext at rest; `auth login` says so. A record in a keyring unavailable at sign-out stays there, unread, until a later sign-out finds it available |
| Authorization-code interception | PKCE S256, a fresh `state` and nonce, a listener bound to `127.0.0.1` before the browser opens, an exact path, and one request only | A same-user process racing the port can at most receive a code it cannot redeem without the verifier |
| Device-code phishing | `verification_uri` shown only for allowlisted provider hosts | — |
| Endpoint substitution | Compiled HTTPS endpoints per profile. No configuration or environment override; a test-only fake server is injected under `Mix.env() == :test` only | — |
| Refresh-token reuse race | Cross-process lock, no exchange of a Loopex-stored refresh token without it, re-read before exchange, generation adoption; a failed record write after a successful exchange keeps the new record in the refresher's `:sensitive` state and retries only the write | A crash after the provider's rotation and before the record write, a route killed mid-exchange (D41's residual), or a stop while that write is still pending, loses the new token, so the route needs sign-in again; a crash after the record write is recovered by `roll_forward` |
| Leak into logs, traces or crash dumps | `:sensitive` custody, refresher and exchange processes, and for both companion kinds the guardian, its frame receiver and the credential sender; `format_status` redaction as in `CredentialCustody`; tracing exclusion; the companion executor in durable hosts; logger off and crash dumps disabled in `auth`; closed failure classes only | The host-VM audience in the ephemeral profile and `auth`, widened by D37 to refresh tokens, ID tokens and the authorization-code exchange |
| Provider echoes a token | The existing exact-match echo guard on the access token | Split or encoded echoes, as today |
| Forged identity token or substituted signing key | `RS256` only, keys only from the issuer's compiled JWKS URI, closed header, bounded rotation refetch | A compromise of the provider's own keys |
| A delayed result applied to a sign-in it no longer belongs to | One [fence](#technical-adr-0073-fence) publishes every result obtained without the lock (a pending write, an ADC exchange, a model listing, step 7's nomination) only for its own tuple, adopting instead a newer signed-in generation of the same subject and client; a refresh exchange runs and publishes under one lock hold, and custody rotates before unlock | A token already in custody stays usable until the first 30 s poll after a logout's floor write, as the concept states |
| A crash between the two halves of a write | The pairing rule refuses both mismatch directions; same-account `roll_forward` under the lock | A different-account cut needs `auth login` again |
| Impersonating another client | Only Loopex's own client identities, except the `adc` source's client read from gcloud's file under the maintainer's exception; source scan for forbidden ReqLLM options | — |
| Runaway spend | The plan's per-app weekly cap; credit overflow only if the user allows it; the Google project's budgets | Operator-owned |

<a id="technical-adr-0073-evidence"></a>
### Evidence

Concept: [Observable consequences](0073-provider-oauth-sign-in.md#concept-adr-0073-consequences).

A test-only fake OAuth and model server,
`apps/loopex_llm_reqllm/test/support/fake_oauth_server.ex`, serves every
flow. The adapter's own tests compile it, and `loopex_composition`,
`loopex_cli` and `loopex_daemon` tests load it with `Code.require_file`, as
`loopex_composition`'s test helper already loads `loopex`'s support. It uses
`:gen_tcp` with fixed-response handlers, like the existing provider fixtures,
and can produce rotation, `invalid_grant`, `slow_down`, delay and malformed
replies. All tests
use temporary homes and never touch a real keyring.

| File | Cases |
| --- | --- |
| `apps/loopex_llm_reqllm/test/sign_in_profiles_test.exs` | Compiled endpoints, issuers and JWKS URIs are HTTPS and per profile; no override path outside tests. A source scan finds no `oauth_file`, `auth_file`, `oauth_http_options`, `with_claude_subscription`, `codex_originator`, `openai_codex` or `refresh_oauth_credentials` in Loopex source, and no Codex CLI or Claude Code client ID; no `:req_llm, :google_vertex` application configuration in any `config/` file or app. Token-response validation (issuer, audience, scopes, bounds). Each `{route, source}` pair of `@disabled_sources`, and no other, is refused `sign_in_unavailable` at configuration selection, at a route's start and by `auth login` (D43, D52); `{"claude", "loopex"}` is listed while the Anthropic profile has no sanctioned client |
| `apps/loopex_llm_reqllm/test/sign_in_routes_test.exs` | The binding grammar's alternatives, pointers and classes. `oauth` on existing routes and `env` on sign-in routes refuse. `vertex` project and location vectors. Per-route sealed headers, including the `vertex` request's exact `x-goog-user-project` on the companion and in-process callers, and a `vertex` call with an empty token, project or region refused before ReqLLM is called. The `chatgpt` mapping never sends rejected members and always streams with `store: false` |
| `apps/loopex_llm_reqllm/test/sign_in_id_token_test.exs` | Against test RSA keys generated with `:public_key`: a valid RS256 token verifies and yields the subject digest; a forged signature, an altered payload, `alg` `none`, `HS256` signed with the public key as an HMAC secret, `ES256`, and `jku`, `jwk`, `x5u`, `x5c` or `crit` headers are refused; wrong issuer (both Google forms accepted), wrong or multi-member audience, and for the `adc` source an audience equal to the compiled Google desktop client or to any client other than the ADC file's `client_id`, while the file's own `client_id` verifies, expiry, `iat` in the future and nonce mismatch are refused; an unknown `kid` refetches once and verifies after rotation, a still-unknown `kid` is refused, and a second unknown `kid` within 60 s does not refetch; an over-bound or non-RSA key set, a redirect from the JWKS URI and a fetch timeout are refused, the last as `provider_unreachable`; a profile's key set never verifies another profile's token |
| `apps/loopex_composition/test/sign_in_store_test.exs` | File backend: modes, owner, symlink refusal on `*.secret`, `*.json`, `*.floor` and `host-id`; stale `.tmp` cleanup; a refresh that creates the lock namespace under the process umask followed by a successful `Store.read/2` and `read_metadata/2`. **Read order:** a write completed between a `read/2`'s metadata and record reads, through a test-only gate under `Mix.env() == :test`, yields `roll_forward`, and two such writes yield `inconsistent`. **Keyring bounds:** recording fake `security`, `secret-tool` and `head` executables, named through `:sign_in_test_executables`, that never exit make each read, write, read-back and delete answer `credential_store_unavailable` within 5,000 ms plus scheduling slack, leave no child running and release the lock, and a refresher's write so bounded takes the pending-write path; every recorded child environment lacks each excluded credential name. **Backend or source change:** `sign_in/4` moving a route from `loopex` to `adc`, and from the keychain (or Secret Service) fake to `file`, leaves no record in the previous backend and writes above the floor; killed after its sign-out, and killed after its record write, it leaves the route `:absent`, each repaired by rerunning it with either store, after which no host backend holds another record. **Backend reads:** `read/2` with `adc` metadata, or with none, spawns no keyring child (the recording fakes record no invocation). With a recording fake keyring answering unavailable: `sign_out/3` of a route whose metadata names `file` deletes the file record and the metadata and skips that keyring; of a route whose metadata names the keyring, it writes the floor and fails `credential_store_unavailable` with the record kept, and a rerun with the keyring available deletes it; `sign_in/4` writing to the file backend on a host whose keyring does not answer, as on a headless macOS host, writes the file pair. **Rerun after a cut sign-out:** `sign_out/3` with and without revocation killed after its floor write, then rerun, deletes the record and the metadata, the revoking rerun revoking the record's refresh token through the fake server; `sign_in/4` run after the same cut signs out first and leaves no record but its own. **Floor:** a sign-out that finds neither side writes no floor; one that finds only an undecodable record, as a first Secret Service login cut short leaves, writes no floor, deletes it, and a rerun of `sign_in/4` then succeeds; the floor's `client_id` is the greater-generation decodable side's. Generation floor: its closed grammar, an invalid floor refused `credential_store_unsafe`, a sign-out writing the maximum generation and never lowering it, and the next write's generation above it. The metadata path never reads a secret, and `read_metadata/2` with metadata at or below the floor reports the route not signed in. The pairing table, every row: metadata ahead of the record; the record ahead by one for the same account (`roll_forward`) and for a different subject or client (`inconsistent`); ahead by two; metadata alone; a record without metadata (`:absent`); an undecodable record, including a truncated Secret Service value. Write cuts after the record and before the metadata, on the file backend and on each keyring backend through its recording fake executable, for a same-account refresh and for a login of a different account over an existing one; a failed keyring read-back exits `credential_store_write_failed` with the metadata unchanged; `roll_forward` acted on only under the lock. **Separation before backend access:** each case builds the real sign-in context map over real temporary directories, the shape `LoopexCli.Home.sign_in_context/1` returns, with no test-only option or hook in the store; `Separation.check/1` passes on it, and the filesystem is then changed so the auth directory lies inside a listed root (a symbolic link replacing an ancestor of the auth directory) or contains one (the root's path created under it). `write/4` then returns `{:error, {:auth_root_overlap, pointer}}` with that root's pointer; the file backend creates no file, temporary or directory, and the keychain and Secret Service backends' recording fake executables record no invocation. A context of the wrong shape refuses the same way |
| `apps/loopex_composition/test/sign_in_adc_test.exs` | A gcloud-shaped `authorized_user` fixture: restart rereads the file, refreshes and keeps the subject; an absent ID token on an unchanged grant keeps the subject; a response without `refresh_token` keeps using the file's; malformed files (missing member, wrong `type`, extra member, nested value, over-bound, symlink, other owner, group-writable, another `universe_domain`) are refused; a replaced file for the same account is adopted at the next generation without restart; a replaced file for another account is `sign_in_account_changed` with custody `nil`; a replaced file whose refresh returns no ID token is refused; a deleted file is `sign_in_required`; the refresh posts the file's own `client_id`, and a replaced file's ID token whose `aud` is not that `client_id` is `sign_in_failed` with custody and metadata unchanged; the refresher, given a sign-in context whose `protected_directories` names a temporary `G` while `HOME` names another directory holding a different ADC file, reads only `<G>/application_default_credentials.json`; `GOOGLE_APPLICATION_CREDENTIALS` and `CLOUDSDK_CONFIG` are ignored; `sign_out/3` leaves gcloud's file untouched. **Startup:** an absent file, `invalid_grant`, an `adc_invalid` file and a replaced file of another subject each refuse the route's start `provider_sign_in_required`, an unsafe file `credential_store_unsafe`, and an unreachable token endpoint, or the route's lock held by another OS process, starts with the route unavailable, a model call on it refusing `not_dispatched` with `model_call_failed` and no provider request. **Fenced `sign_in_required`:** a refresh that finds the file deleted, while another OS process records a newer `auth login gemini --source adc` before the refresher takes the lock, adopts the newer pair and writes no `sign_in_required`. **Delayed exchange:** the fake server holds a refresher's token response until the test releases it while another OS process runs `sign_out/3`, then `sign_in/4` writing another account's `loopex`-source pair, then a replaced file already recorded at a greater generation; after the release the first publishes nothing, recreates no metadata and leaves custody `nil`, the second leaves the other account's metadata byte for byte and custody `nil`, and the third writes nothing, leaves custody as it was and refreshes again on step 5's schedule; the released token never resolves from custody after a logout |
| `apps/loopex_composition/test/sign_in_keychain_test.exs` | Tagged `:macos_keychain`, against a temporary keychain named through the test-only `:sign_in_test_keychain` key: round trip, overwrite, delete, and a maximum-size record (262,144 base64url bytes on one `security -i` line); the secret never appears in any spawned argv, checked through an argv-recording wrapper. A source check finds the `:sign_in_test_keychain` and `:sign_in_test_executables` keys read only under `Mix.env() == :test` |
| `apps/loopex_composition/test/sign_in_secret_service_test.exs` | Tagged `:secret_service`, under `dbus-run-session` with a throwaway keyring: round trip and availability probe with the bus passed only through the context's `secret_service_bus`; a locked collection is unavailable within 5,000 ms. Untagged, a recording fake executable proves the wrapper's argv, standard-input bytes and child `DBUS_SESSION_BUS_ADDRESS` equal to the context value while the test VM's own variable names another address; a `nil` bus is unavailable without spawning; a route start whose metadata names `secret_service` with the backend unavailable refuses `credential_store_unavailable`; the wrapper runs `/usr/bin/head` by absolute path |
| `apps/loopex_composition/test/sign_in_refresh_test.exs` | Refresh at the window, including a short `expires_in`. **Custody deadline**, through the real refresher and `CredentialCustody.resolve/1`: a fresh 30 s token from the fake server resolves `{:ok, _}` as soon as custody starts and is refreshed at 15 s; with the server then unreachable it still resolves until 22,500 ms after `t0` and `:expired` after it; **delayed response**: a 10 s token whose response the fake server delays by more than 7,500 ms after the request reaches it (so verification and the write finish after `t0` + 7,500 ms) enters custody past its deadline, `CredentialCustody.resolve/1` returns `:expired` on the first call, a model call on the route refuses before dispatch with no provider request carrying that token, and the refresher's next refresh is due at once, a repeated delay following step 5's transient schedule; a refresh answered with `expires_in` 9 is `sign_in_failed` with nothing written and custody unchanged. A refresher whose context's auth directory is moved inside a listed root after start exchanges nothing, keeps custody as it was until the token's deadline and then refuses calls `model_call_failed`; rotation persisted; `invalid_grant` → `sign_in_required` and custody `:missing`; transient retry schedule; expiry while unreachable → `:expired` refusal. Two OS processes on one home perform exactly one exchange, the other adopting. **No trace exposure:** a trace session with call and message flags and `set_on_spawn` on all processes, during a file-backend refresh and an `adc` refresh, receives no event carrying a token, the ADC client secret or a refresh token. Stale lock reclaim. Account change refused; same-account re-login adopted within 30 s; logout reaches custody `nil`. **Logout cut after its floor:** a running refresher, for a `loopex` route and for an `adc` route, holds a token outside its refresh window; `sign_out/3` without revocation, in another OS process, is killed immediately after its floor write, leaving the record and metadata byte for byte unchanged; within one 30 s poll `CredentialCustody.resolve/1` returns `:missing` and a model call on the route refuses `provider_sign_in_required` with no provider request, and the same holds while a third OS process holds the lock across the poll. **Failure written by another process:** a step 7 nomination that finds the held tuple at `state: sign_in_required`, written by another OS process, rotates custody to `nil` and stops the refresh schedule; a nomination refused `sign_in_lock_busy` is repeated at the next poll. **Different-account write cut:** a service running account A; `sign_in/4` for B, in another OS process, is killed after its record write; the service's next refresh exchanges nothing, writes only `state: sign_in_incomplete` into A's metadata and rotates custody to `nil`, B's record bytes are unchanged, a newly started route refuses `provider_sign_in_required`, `read_metadata/2` shows `sign_in_incomplete`, and rerunning `sign_in/4` repairs it. **Restart before metadata publication:** a refresh at which the fake server rotates and invalidates the old refresh token is killed after its record write; a restarted route rolls the metadata forward and refreshes with the rotated token; the invalidated token is never presented again. Refresh-response rules: an OpenAI response without `refresh_token` fails with no write; a Google response without `refresh_token` or `id_token` keeps the prior refresh token and subject; a refresh-response ID token is never used for identity. **Write failure after exchange:** with the fake server rotating and invalidating the old refresh token and the store failing its write, custody resolves the new access token, the fake server sees no second exchange while the write is pending, each retry follows step 5's schedule and emits one `sign_in_store_write_pending` line naming the class and no token, the write succeeds once the store recovers at the next generation, and a refresher stopped before that leaves the route needing sign-in with the invalidated token never presented. **Lock busy:** a lock held by another OS process across a delayed 20,000 ms exchange makes the refresher's acquisition fail `sign_in_lock_busy` after 10,000 ms with no exchange, no write and custody unchanged, and its retry adopts the holder's record without contacting the provider. **Logout then login:** a running refresher reaches custody `nil` and stops its schedule after `sign_out/3`; `sign_in/4` for the same account and client then writes a generation above the floor; the refresher adopts it within 30 s, resolves the new token and refreshes again at the next window. `chatgpt` model list refreshed after each refresh and adoption; a failed refresh-time listing keeps the previous list, never `null`, and names `sign_in_model_list_stale`; the **delayed listing** cases of [`chatgpt` model admission](#technical-adr-0073-model-admission). **Fenced publication of other delayed results**, each with the competing operation run in another OS process at the named point, a logout being `sign_out/3` and a login `sign_in/4`: a step 7 nomination followed, before the refresher takes the lock, by a logout, by a logout and a different-account login, and by a newer same-account login, adopting only the last and leaving custody `nil` in the first two; a pending write after a store failure followed by a logout, a logout killed after its floor write, a different-account login and a newer same-account login, the pending record discarded in all four, nothing recreated, custody `nil` in the first three and the newer generation adopted in the fourth; a pending write still published at the next generation over a `sign_in_required` state written at `G` by another process, over a Secret Service write of its own cut short (undecodable record, metadata at `G`), and, adopted after `roll_forward`, over its own keychain record left at `G + 1` by a failed read-back; a logout, revoking through the fake server, started while a refresher holds the lock across an exchange delayed 5,000 ms, after which custody holds the new token, then `nil` within 30 s, and the logout revokes the new refresh token; and the same with a 15,000 ms delay, where the logout returns `sign_in_lock_busy` and deletes nothing. **Stop mid-exchange:** a route sent `:shutdown` while its exchange is delayed 5,000 ms exits only after the write: the store holds the rotated token at the next generation, the lock is free, and a newly started route refreshes with that token. **Startup read under two writes:** a route started while another OS process completes two refreshes between its unlocked metadata and record reads, through the store's test-only gate, serves after its locked re-read instead of refusing. **Lock owner:** an exchange process that raises while `SignIn.Route` holds the lock leaves no lock, and another route of the same name in the same VM then acquires it; an acquisition whose primitive call outlasts 10,000 ms returns `sign_in_lock_busy` and its late success is released. No retained output or diagnostic line contains a token the fake server issued |
| `apps/loopex_cli/test/auth_command_test.exs` (separation) | `auth login` exits 76 before any token write when the auth directory or the ADC directory and a selected state root overlap in either direction, with the context built by `LoopexCli.Home` from a temporary `HOME` and the selected file |
| `apps/loopex_composition/test/credential_plane_test.exs` (extended) | A sign-in route's custody is started and registered by `load_bindings/2` like an `env` route's, starts unavailable and resolves `:expired`; `load_bindings/2` starts no route. **Route owners:** `LoopexComposition.start/1`, `with_runtime/2` and `start_edges/2` given an `oauth` binding in `:provider_bindings`, `CredentialHost.open/4` with a `nil` context, and `Ephemeral.start_session/1` given an `oauth` binding its `:sign_in_routes` does not name, each refuse `provider_sign_in_required` and start nothing; `CredentialHost.open/1` given an `oauth` and an `env` binding starts only the `env` route's custody; `open/4` starts each route linked to its keeper with the executor its options name, and `plane/1`'s `sign_in_routes` names its custody and table, which `Edges`' plane check admits; an `env`-route model call through a plane carrying `sign_in_routes` dispatches; with both an `openai` `env` and a `chatgpt` `oauth` binding, a `chatgpt:` call resolves only the `chatgpt` custody and an `openai:` call only the `openai` one; in-host, `open/4` given an `env` and an `oauth` binding reads no variable, deletes none but `LOOPEX_PROVIDER_API_KEY` and starts custody only for the `oauth` route; a route made to exit through the `LOOPEX_TEST_SIGN_IN_ROUTE_EXIT` seam while running makes the keeper call `lost` exactly once; an exception in the keeper's loop calls `lost` once, and a keeper killed with `:kill` ends an opener that does not trap exits; `close/1` sent while an exchange is delayed 5,000 ms returns only after the write, without calling `lost`; a stub route named through `:sign_in_test_route_module` that ignores `:shutdown` is killed at 60,000 ms; a command process that exits makes the keeper stop each route the same way; `rotate/3` to no value with a past deadline resolves `:expired` and with the default deadline `:missing`, the delivered `:missing` and `:expired` cases unchanged. Two canaries (access and refresh) never appear in journals, public events, progress, diagnostics, traces, executor job environments or resource subprocess environments. An invocation during rotation uses exactly one token |
| `apps/loopex_llm_reqllm/test/provider_bridge_test.exs` (extended) | The `token_exchange` and `model_list` invocations: their closed frames, the `adc` credential frame's one NUL-joined value, bounds, the deadline with and without a key-set fetch, a `token_exchange` returning the fetched key set within its bound, closed failure classes, no raw body crossing, cleanup proof. The guardian's custody-phase producer of `provider_sign_in_required` and its `model_call_failed` counterparts, as [producing the reason](#technical-adr-0073-failure-reason) lists. The access-token echo guard withholds a reply containing the token. **No runtime:** a `token_exchange` and a `model_list` called from a plain process before any runtime or composition exists, with a one-invocation custody and registry, succeed through the real companion, and their custody and registry are gone when the call returns; a caller-supplied `:tracing_capability` is refused before launch. For both kinds, the guardian, its frame receiver and the credential sender are `:sensitive`, and, with the caller `:sensitive` as the route's exchange process is, a call-trace and message-trace session started on it, with `set_on_spawn`, before the invocation receives no event carrying the refresh token or a token the fake server issued (D62's no-runtime witness) |
| `apps/loopex_cli/test/auth_command_test.exs` | Grammar and every exit status. Loopback: state mismatch, wrong path, denial, timeout, port already bound. `--device` refusal text. A login whose ID token fails verification writes nothing. `status` makes no secret read and no network call. `logout` revoke success, failure and `--local-only`, each leaving the floor. A login after logout authorizes under the floor's issued client. A login answered with `expires_in` 9 exits 68 with nothing written. A binding of a disabled source makes `auth login` and `auth status` exit 65 and `config validate` exit 1 naming `sign_in_unavailable`, `config show` still shows it, and `auth logout` of a sign-in stored before the source was disabled revokes and removes it. `--store auto` over metadata naming an unavailable `secret_service`, through the recording fake, exits 69 and writes no file. `logout` of a route whose metadata names an unavailable keyring writes the floor, exits 69, and `status` then shows the route not signed in. A `gemini` login whose project check fails prints `loopex auth: vertex project check failed: <class>` and exits 0 with the sign-in written. `status` shows a route whose metadata is at or below its floor as not signed in and exits 75. `auth` runs with the launcher's crash-dump settings, as `ask` does. A login whose `model_list` fails writes no record, metadata or floor and exits 68 for a malformed, empty or over-bound list and 72 for a transport failure, timeout or non-2xx status (D25). The ADC metadata path |
| `apps/loopex_cli/test/daemon_sign_in_test.exs` | Statuses 120 to 122, each refusing start, writing `loopex daemon refused to start: <class> <pointer>` before exiting and leaving no socket; 123 when the route exits while serving, made to exit in the spawned daemon through the `LOOPEX_TEST_SIGN_IN_ROUTE_EXIT` seam, an attached client receiving `daemon.stopping` with reason `fatal:sign_in_route_lost` before the connection closes; an inconsistent pair and an unavailable store found only after the spawn, each refused by the starter with the class of the daemon's exit status; a sign-in route absent, inconsistent or `sign_in_required` at startup refuses 120, as does a startup refresh of a stored `loopex` sign-in answered `invalid_grant`, which also writes `state: sign_in_required` (D51); a binding of a disabled source exits 111 `configuration_invalid` naming `sign_in_unavailable` and its pointer, and an on-demand start of it refuses `sign_in_unavailable` with status 1 before the precheck, spawning nothing (D52); start-on-demand presence check, including metadata at or below its floor; `loopex service stop` while an exchange is delayed 5,000 ms exits 0 after the rotated token is written, and a restart refreshes with it; revoked mid-service → next call `not_dispatched` with no fallback to another route, other routes still served, and the attached client's terminal outcome is `failed` with `provider_sign_in_required` and the `auth login` hint; re-login adopted and the next turn succeeds without restart; **logout then login** in sequence while the service runs: the next call after logout refuses `provider_sign_in_required`, and after a same-account login the service adopts the new generation within 30 s and the next turn succeeds without restart |
| `apps/loopex_daemon/test/command_test.exs` (extended) | `ExitStatus.classes/0` covers exactly `Enum.to_list(65..125) -- [114]`, each status once; no class maps to 114 |
| `apps/loopex_llm_reqllm/test/chatgpt_reply_ceiling_test.exs` | Through the fake server: a stream longer than the ceiling ends with completion `limit`, text whose `Loopex.Bounds.estimate/1` is at most the ceiling and is a prefix of what the server sent, a cut on a UTF-8 boundary, no tool calls, nil reported usage, and the server observing the connection closed; a stream that completes below the ceiling is unchanged; a ceiling of 1; a cut during a streamed tool call; the request body never contains `max_output_tokens`. Each case runs through both actual callers: the companion worker's `drain/5`, where the halt calls `StreamResponse.close/1` and no `StreamServer` or HTTP task survives the invocation, and the in-process caller through `OneShotHTTP1`, where the halt is followed by the owner's existing tagged-pool teardown proof before the result, and no progress delta is emitted. A source check finds one ceiling implementation, `ReplyCeiling`, called from both. **Raw-byte bound:** a stream longer than the ceiling whose SSE framing reaches 8,388,609 raw bytes while its estimate is still below the ceiling ends the in-process caller with `{:error, {:dispatched_or_unknown, "model_call_failed"}}` after the same teardown proof, while the same stream through the companion caller ends at the ceiling with completion `limit` |
| `apps/loopex_composition/test/chatgpt_summarizer_test.exs` | A maintenance summary on a `chatgpt:` route through the fake server, with a summary longer than ADR 0043's ceiling, settles as a `limit` reply within the ceiling and is handled as any limit-truncated summary, once through a durable composition (companion caller) and once through an ephemeral composition's maintenance model (in-process caller) |
| `apps/loopex/test/sign_in_required_settlement_test.exs` | `{:not_dispatched, "provider_sign_in_required"}` settles attempt one as `not_dispatched`, accounting `none`, next `terminal` with no retry; the run ends `failed` with that reason; the record replays. **Route availability changes between attempts:** attempt one settles `not_dispatched`/`model_call_failed` with `retry`, custody then becomes `:missing`, and attempt two settles terminal with `provider_sign_in_required`; the two-attempt history replays to the same terminal. **Termination precedence:** the category settled with an `abort` termination ends the run `cancelled` and with a `deadline` termination `bound_reached`, never `failed` with the reason, and each replays to the same terminal. The category with `dispatched_or_unknown`, accounting other than `none`, `next` other than `terminal`, or a termination other than abort or deadline is invalid history; a maintenance run reports the category |
| `apps/loopex_protocol/test/session_v2_schema_test.exs` (extended) | The `daemon.stopping` reason list includes `fatal:sign_in_route_lost` with its literal vector (D42) |
| `apps/loopex_protocol/test/sign_in_required_vectors_test.exs` | The new vectors encode and decode on `loopex.experimental/3` and `/4`; the reason with a nonnull `failure`, or as a failure category with `retryable` `true`, is refused; the regenerated manifests and schema proof match |
| `apps/loopex_cli/test/ask_sign_in_test.exs` | Ephemeral `ask` on a sign-in route through the fake server; refresh in host VM; the route's `excluded_env_names` are those of the whole merged map, so a recording fake keyring child sees none of its variables; every route stopped by `close/1` before the command returns. **Lost during the run:** a 10 s token whose refresh, due 5 s after start, the fake server answers `invalid_grant` while it holds the run's first model reply, a tool call, for 6 s; the second model call meets custody `:missing`, and ephemeral `ask` reports `failed` with `provider_sign_in_required` in `loopex.ask/1` and in text with the `auth login` hint, exit 2; the cleanup owner admits the refusal and the session is not sealed. Durable `ask` reports the same through its follow reader. **Foreground refusals (D50):** each `ask` over an absent, inconsistent and `sign_in_required` pair, and an ephemeral `ask` with an `oauth` binding and no usable `HOME`, reports status 1 `provider_sign_in_required` with the hint; a disabled source reports status 1 `sign_in_unavailable`; an unavailable and an unsafe store report status 1 `composition_unavailable`; none writes standard output, and the fake server sees no model request; chat refuses each with its startup line and exit 1. **Selected file (D54, D57):** durable and ephemeral `ask` with no `--config` use the `oauth` binding of the home's `config.json`, and with `--config` that file's, the file's `paths.state_root` left uncreated; with a file that names only `chatgpt`, an `openai:` model still runs through durable `ask`'s `LOOPEX_PROVIDER_API_KEY` binding and ephemeral `ask`'s `OPENAI_API_KEY` reference route, and durable `ask` with `LOOPEX_PROVIDER_API_KEY` unset runs the `chatgpt:` model and refuses the `openai:` model `provider_credential_required`; with no file each uses its delivered environment route; an invalid selected file reports status 1 `command_failed` with no session started. **Durable `ask` opens only what it uses (D60):** after `loopex init --provider openai`, with only `LOOPEX_PROVIDER_API_KEY` set, durable `ask --state-root R --model anthropic:…` runs, and a `chatgpt:` model the file does not name refuses `provider_credential_required` with nothing opened. **Ephemeral `ask` opens only the routes it uses (D63):** with a file whose signed-out `chatgpt` `oauth` binding has no stored sign-in, ephemeral `ask --model openai:…` runs through its `OPENAI_API_KEY` reference route and starts no sign-in route. **Legacy commands (D58):** `run`, `resume` and `skill` without `--service`, through `LoopexCli.dispatch/2` with the host option `:provider_bindings` holding an `oauth` binding of the model's route, as `offline_provider_bindings_test.exs` :50 passes bindings, print the two D58 lines and exit 1 having started nothing, and with an `oauth` binding of another route they run |
| `apps/loopex_cli/test/sign_in_route_lost_test.exs` | Through the test-built command in a child OS process, making the `SignIn.Route` exit through the `LOOPEX_TEST_SIGN_IN_ROUTE_EXIT` seam while a run is in progress in foreground chat, durable `ask` and ephemeral `ask` prints `loopex: sign_in_route_lost` and exits 1, with no process group the command started left running, `ask` writing no standard output in text or JSON mode; each durable run has no terminal and a later resume recovers it; ephemeral `ask`'s temporary root is left. **Normal exit during an exchange (D41):** chat ending at end of input, and each `ask` finishing its run, while the route's exchange is delayed 5,000 ms, exit only after the write, ephemeral `ask`'s stop request having returned within its 11,000 ms, and a newly started route refreshes with the rotated token. **Interrupt during an exchange:** an interrupt while the exchange is delayed past the backstop exits at the backstop, and the rotated token is lost, a later start refusing `provider_sign_in_required` (D51), the documented residual |
| `apps/loopex_composition/test/sign_in_model_admission_test.exs` | The admission cases of [`chatgpt` model admission](#technical-adr-0073-model-admission). A switch made while the route waits for its lock, held by another OS process, and while a recording fake keyring child of the route never exits, is admitted or refused within 100 ms from the route's table |

Release lanes for M8 outcome 8, attended, run in the `serenity` full check,
and with `--only` before a merge that changes their boundary (D18). Each is
a script lane: one wrapped command runs its steps in order, stops at the
first that fails, and after the last prints `<lane>: PASS steps=N`, the
last line of its redacted retained output, which the release runner's
script-lane judge checks. `real-sign-in-openai` and `real-sign-in-gemini`
are gated on their provider's client, and verification items 2 and 5 are
settled by the maintainer's provider actions that gate them. Before its
case starts, each lane checks its host prerequisites: an attended browser
for the `real-sign-in-openai` and `real-sign-in-gemini` logins, the compiled
Google client for `real-sign-in-gemini`, and `gcloud` and a browser for
`real-sign-in-gemini-adc`. A missing one is a pre-start stop, recorded
`not_dispatched` with the evidence unavailable, never a failed case. Each
runs in a temporary `HOME` with `--store file`:

- `real-sign-in-openai`, `steps=5`: (1) an attended `auth login openai`,
  whose model list, fetched before the login's write, must be recorded
  non-empty within its bounds and name the lane's model; (2) one real
  `chatgpt:` conversation through the installed service; (3) a forced
  refresh, made by stopping the service, setting `access_expires_at` to the
  current time in both the record and the metadata with every other byte
  and the `0600` mode kept, and starting the service, whose startup refresh
  (refresher step 2) must succeed; (4) `auth logout openai` with revocation;
  (5) a second login under the generation floor, which must authorize under
  the floor's issued client, write a generation above the floor and record
  the list again. The lane also records verification items 11 to 15.
- `real-sign-in-gemini`, `steps=4`: (1) an attended `auth login gemini`
  through the compiled Google client and the `loopex` source, whose
  `vertex` project check against a maintainer-owned project must pass;
  (2) one real `vertex:` conversation through the installed service;
  (3) a forced refresh as in the OpenAI lane; (4) `auth logout gemini`
  with revocation.
- `real-sign-in-gemini-adc`, `steps=3`, its own pinned case (D43), which
  needs no Google client: (1) `auth login gemini --source adc` from a file
  written by a real `gcloud auth application-default login` under the
  lane's `HOME`, whose login verifies a real Google ID token whose `aud` is
  that file's `client_id`; (2) one real `vertex:` conversation through the
  installed service; (3) `auth logout gemini`. It records verification
  item 7.
- `real-sign-in-anthropic`, `steps=1`: (1) `auth login anthropic` refused
  `sign_in_unavailable` with exit 65 and nothing written, until a sanctioned
  registration exists. That tested refusal is the lane's complete proof for
  the disabled `claude:` route; M8 closure needs positive lanes for OpenAI
  and Google only, and no deferral for Anthropic.

A lane whose provider client is missing is deferred only by the maintainer
before the closure candidate and is then left out of that candidate's pinned
case list (D36), and the build ships that sign-in disabled, refused
`sign_in_unavailable`, until a later candidate's lane passes (D43): a
deferred `real-sign-in-gemini` disables only the `loopex` source of
`vertex:`. `real-sign-in-anthropic` and `real-sign-in-gemini-adc` are always
present.

No `real-sign-in-*` lane uses the login keychain or a user's Secret
Service: they use the file backend in a temporary home, and the keyring
backends are proved by the tagged `sign_in_keychain_test.exs` case against a
temporary keychain and the tagged `sign_in_secret_service_test.exs` case
under `dbus-run-session` with a throwaway keyring. Only the removal steps
of the macOS installed lane (ADR 0038's step 6) and of `m8-operator` read a
keyring, to show that no Loopex item for their home remains: for each of
`chatgpt`, `vertex` and `claude`, `security find-generic-password -s
loopex-oauth -a <home-digest>:<route>` must exit 44, so an item of another
home never fails them. Under the installed lane's temporary `HOME` no item
was ever written, so its query is a smoke of the removal procedure and
cannot fail; the keychain backend's proof is the `macos_keychain` lane. The
Linux installed lane signs in to nothing and makes no keyring query.

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
- **ADR 0048, Concept and Technical, ephemeral references.** "Ephemeral
  composition retains caller-only value resolution … These paths must not
  share a loader that gives either profile the other's credential
  lifetime", "Ephemeral composition stores only references and uses its
  selected caller resolution below, never this durable custody plane", and
  the "Ephemeral references" paragraph's caller resolution of the chosen
  variable for each invocation. Amended: a sign-in route in the ephemeral
  profile resolves from custody its host opened with
  `CredentialHost.open/4`, which holds the route's access token while the
  host's routes run, and its `SignIn.Route` holds the refresh token in that
  host's VM; `env` routes keep caller-only resolution and never enter that
  custody, so no environment-held value gains the durable lifetime.
- **ADR 0048, Technical, the plane's shape.** "The new host-private
  credential plane has closed shape `{version: 2, capability,
  model_options, excluded_env_names}` with optional `capability_pid`"
  gains a second optional member, `sign_in_routes`, the map
  [route owners](#technical-adr-0073-route-owners) defines. "`model_options`
  contains exactly `provider_routes`, `credential_registry`,
  `tracing_capability`" is unchanged, so the adapter never receives the
  new member, and `provider_routes` also admits the three sign-in routes.
- **ADR 0019, Decision and Technical depth, "One invocation, existing
  authority".** The credential sent over the private channel may be a
  host-held access token. "The private protocol has one version and closed
  per-kind fields" gains two invocation kinds, `token_exchange` and
  `model_list`, under the same launch, isolation and cleanup rules, with the
  closed frames, bounds, deadline and cleanup period
  [the companion executor](#technical-adr-0073-exchange) lists; they carry no
  Control permit or Model request. An `adc` credential frame carries the
  client secret and the refresh token as one NUL-separated value within the
  frame's unchanged 65,536-byte bound. Both kinds run in ADR 0034's
  no-runtime Direct mode, and for them the guardian, its frame receiver and
  the credential sender are `:sensitive`.
- **ADR 0034, Technical depth, its failure table.** The row "Custody answers
  `{:error, :missing}` or `{:error, :expired}` | … the guardian maps it to
  ADR 0019's existing generic credential-send failure and tears the child
  down. No ADR 0029 terminal or public diagnostic gains the atom" is amended
  for a `:sign_in` route: the guardian answers `:missing` with
  `{:error, {:not_dispatched, "provider_sign_in_required"}}` after the same
  teardown, and the run terminal carries that reason, never the atom.
  `:expired`, and both answers on any other route, keep the row. Otherwise
  unchanged in mechanism: a `SignIn.Route` is an additional host owner that
  calls the custody's existing `rotate/3`.
- **ADR 0034, Concept and Technical depth, the Direct mode (D62).** "The
  existing direct `complete_prompt/3` helper remains a separate no-runtime
  path" and "The accepted direct `complete_prompt/3` path is a separate
  no-runtime mode. The helper constructs a private
  `%TraceCapability.Direct{}` itself". Amended: the adapter's
  `token_exchange/2` and `model_list/2` also mint that marker and use that
  mode, with the caller creating one-invocation custody and registry as
  `complete_prompt/3`'s caller does, and for them the guardian, its frame
  receiver and the credential sender are `:sensitive`. Runtime model
  options still cannot select the marker. The `provider_bridge_test.exs`
  no-runtime case is their witness. The token, the registry, resolution
  once per invocation and the sender's trace clearing are unchanged.
- **ADR 0034, Technical depth, the closed reason set.** The row "`:expired`
  | A custody process | It has one and considers it no longer valid" is
  amended: custody also answers `:expired` when it holds no value and its
  finite deadline has passed, because it checks the deadline before the
  value; `:missing` keeps "It has no credential for this token" for custody
  with no value and no finite deadline. The set and its producers are
  unchanged.
- **ADR 0039, Decision point 3**, "each hosted provider has its own variable,
  read at the model boundary for each call". Amended: a sign-in route resolves
  from its host's custody at the model boundary for each call. The
  in-process caller streams a `chatgpt` reply through the existing one-shot
  adapter and tagged pool, so the profile's cleanup proof is unchanged.
- **ADR 0039, Concept, "Composition precedence", and Technical depth,
  "Bounded composition startup".** The complete closed options of
  `Ephemeral.start_session/1` admit one more host option,
  `:sign_in_routes`, the map its host's `CredentialHost.open/4` opened, as
  ADR 0048 admitted `:provider_bindings`. Every other option and the
  validation order are unchanged.
- **ADR 0039, Concept, "Public Admission and Packaging Contracts", row
  "Model failure"**, "Proved pre-call refusal is fixed `model_call_failed`
  with `not_dispatched`", and Technical
  depth, "Error classes", which counts a missing credential among the clean
  `{:not_dispatched, "model_call_failed"}` refusals. Amended: on a sign-in
  route, custody `:missing` is the proved pre-call refusal
  `{:not_dispatched, "provider_sign_in_required"}`, which the cleanup owner
  admits as it admits a pre-adapter `model_call_failed`; `:expired` stays
  `model_call_failed`.
- **ADR 0039, `ask`'s status-1 diagnostics and exit status 1.** The fixed
  status-1 diagnostics of `loopex.ask/1` gain `provider_sign_in_required`
  and `sign_in_unavailable` (D50), each with no standard output in either
  output mode, and `sign_in_route_lost` (D38). Status 1's failures outside
  a run outcome without a public cleanup proof, which name the ordinary
  worker-reap hard halt today, gain the halt on route loss, which writes
  only `loopex: sign_in_route_lost`, to standard error.
- **ADR 0032, Technical depth, the `daemon.stopping` record's `reason`
  row.** "The ordinary component reasons remain `fatal:runtime_lost`,
  `fatal:transfers_lost`, `fatal:workspace_lease_lost`,
  `fatal:executor_lost`, `fatal:registry_lost`, `fatal:custody_lost`,
  `fatal:capability_lost`, `fatal:relay_lost`, `fatal:session_index_lost`
  … and `fatal:drain_failed`." Amended: the set also admits
  `fatal:sign_in_route_lost` (D42). Its sentence on the fatal classes'
  bounded writes applies unchanged.
- <a id="technical-adr-0073-vision-text"></a>**ADR 0039, host-VM credential
  audience, and its vision amendment.** By the maintainer's D37 and D40,
  refresh tokens, ID tokens and the authorization-code exchange may also
  live in this profile's host VM and in the `auth` command's VM, beyond the
  selected provider credential the profile's vision amendment covers, and
  the launcher disables crash dumps for `auth` as for `ask`. ADR 0039's
  [vision amendment](0039-ephemeral-embedded-profile-technical.md#technical-adr-0039-vision)
  inserts one common exception, identical in seven places: `docs/vision.md`
  §12 and §16, `docs/vision-technical.md` §6.1, §6.2, §12.7 and §23, and
  `AGENTS.md`'s credential and context non-negotiable. At this record's
  acceptance one new common text replaces it in all seven places, each
  place keeping its placement: ADR 0039's common exception unchanged,
  followed by this paragraph.

  > ADR 0073's provider sign-in widens this audience, as the maintainer
  > accepted explicitly. For a sign-in route the selected credential is the
  > route's current access token, which the host holds and refreshes in
  > custody while the command or service that opened the route runs, rather
  > than resolving it just in time. Its refresh token, a returned ID token
  > and the authorization-code exchange may also live in the ephemeral
  > profile's host VM and in the `loopex auth` command's VM, under the same
  > observers. A durable host VM holds a sign-in route's refresh token and
  > a returned ID token only in sensitive host processes, which generate no
  > trace messages, and its credential-bearing sign-in requests run in the provider
  > companion under ADR 0019 and ADR 0034 as ADR 0073 amends them. The
  > `ask` and `auth` commands disable crash dumps for their VMs. The host's
  > sign-in store, never runtime state, persists sign-in tokens, only in the
  > operating system's keyring or an owner-only file kept apart by path from
  > every state root, and they never enter journals, public events,
  > progress, diagnostics, traces, fixtures, executor jobs or project
  > resources.

  By the maintainer's D56 and D61 the same acceptance qualifies, together,
  the four other passages of `docs/vision-technical.md` this text would
  contradict, three sentences of §12.7 and §6.1's custody cell, its concept
  pair's sentence in `docs/vision.md` and `AGENTS.md`'s sentence beside the
  common text, each by one appended sentence or clause saying that the
  installed host, not the runtime, persists sign-in tokens in its sign-in
  store and holds them in host custody while its routes run:
  - §12.7, after "Loopex persists credential references, never resolved API
    keys, access tokens, private keys, cookies, or vault values.": "The
    installed host, not the runtime, persists ADR 0073's provider sign-in
    tokens, in its sign-in store outside every state root."
  - §12.7, after "Resolution occurs just in time at the approved model or
    executor boundary and uses the narrowest possible lifetime and
    audience.": "A sign-in route's tokens are the exception: the installed host holds them
    in host custody while its sign-in routes run, as ADR 0073's exception in
    this section states."
  - §12.7, after "Runtime state stays reference-only; selected-key
    resolution remains just in time and the mapped-provider-reply check
    precedes publication.": "That resolution is of an `env` route's selected
    key; a sign-in route's token is held in host custody while its routes run
    (ADR 0073)."
  - §6.1's custody cell, after "resolves an environment-held value just in
    time at the approved model boundary": "; holds a sign-in route's tokens
    in its sign-in store and custody while the route runs (ADR 0073)".
  - `docs/vision.md` §12, after "Credentials remain host-owned references,
    and sensitive material is excluded from journals, public events,
    diagnostics, and fixtures unless a narrowly approved ephemeral hand
    requires it.": "The installed host, not the runtime, persists provider
    sign-in tokens in its sign-in store and holds them in host custody while
    its sign-in routes run (ADR 0073)."
  - `AGENTS.md`'s credential and context non-negotiable, after "Host
    credentials remain references and never enter journals,
    public/progress/diagnostic planes, fixtures, or ordinary jobs beyond an
    approved scoped ephemeral hand secret.": "The installed host, not the
    runtime, persists provider sign-in tokens in its sign-in store and holds
    them in host custody while its sign-in routes run (ADR 0073)."

  This record edits none of those files; the replacement and the
  qualifications land together with its acceptance.
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
- **ADR 0018, Technical depth, "Abort, deadline, and recovery".** "exact
  not-dispatched retries once then fails uncharged if the second attempt
  also refuses" stays exact for `model_call_failed`. A `not_dispatched`
  `provider_sign_in_required`, on either attempt, never retries: it fails
  the run uncharged with that reason, unless an abort or deadline has
  already won.
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
- **ADR 0049, Technical depth, "Closed terminal schema".** "Failure retains
  exactly the existing alternatives: `reason` is `model_call_failed` or
  `unreadable_model_answer` with null `failure`" is amended: `reason` may
  also be `provider_sign_in_required`, with null `failure`.
- **ADR 0049, Technical, file contract.** The `providers` row, "durable chat
  requires `{"credential":{"env":"NAME"}}`", is amended: durable chat also
  accepts `{"credential":{"oauth":{"source":...}}}` on a sign-in route. Schema
  version 1 additionally admits the provider names `chatgpt`, `vertex` and
  `claude`, the `oauth` credential form, and the `vertex` route's `project`
  and `location` members, each under the closed grammar above. The schema
  version stays 1; the closed-object rule is unchanged.
- **ADR 0037 (Proposed).** Its concept states that provider sign-in tokens
  follow this record and that file, keychain and command sources for API
  keys remain a separate future decision.

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
lane that settles it, and the design above does not depend on the answer;
*settled by the maintainer's provider action* names the open item whose
outcome gates a lane.

| # | Item | Disposition |
| --- | --- | --- |
| 1 | Whether an OpenAI refresh immediately invalidates the previous refresh token | None needed. The design assumes it does (lock, read-back, `roll_forward`), and `sign_in_refresh_test.exs` proves that worst case; no product path presents a rotated-away token to learn the answer |
| 2 | Whether OpenAI requires a partner client ID rather than dynamic registration | Settled by the maintainer's provider action under [open item 1](0073-provider-oauth-sign-in.md#concept-adr-0073-open), which gates `real-sign-in-openai`; the lane does not record it. A partner client would amend this record |
| 3 | A documented allowed-model list for plan usage | Implementation. Only the per-account listing is documented and is what the route uses, through `model_list`; `sign_in_model_admission_test.exs` refuses an unlisted model with `provider_route_unavailable` |
| 4 | An official OpenAI statement of the launch date | None needed. No rule depends on the date; it is research context only |
| 5 | Whether Google classifies `cloud-platform` as sensitive or restricted | Settled by the maintainer's provider action under [open item 2](0073-provider-oauth-sign-in.md#concept-adr-0073-open), which gates `real-sign-in-gemini`; the lane does not record it. It sets the Google client's verification path, not code; the `adc` source does not depend on it |
| 6 | Google's stated access-token lifetime | Implementation. The refresher reads `expires_in`, assumes no fixed value and scales the custody skew with it; `sign_in_refresh_test.exs` covers a 30 s lifetime and one below the 10 s minimum |
| 7 | The ADC `authorized_user` member names, and that gcloud's default login grants `openid` | Implementation. `sign_in_adc_test.exs` fixes the grammar; the `real-sign-in-gemini-adc` lane reads a file written by real gcloud and must pass the grammar and return a verifiable ID token. A difference amends the grammar, never silently widens it |
| 8 | The regional Vertex host form | Acceptance, checked 2026-10-13: Google's Vertex AI [locations](https://cloud.google.com/vertex-ai/generative-ai/docs/learn/locations) page gives `https://{LOCATION}-aiplatform.googleapis.com` beside the global `https://aiplatform.googleapis.com` |
| 9 | Anthropic's Commercial Terms text and exact policy dates | None needed. The `claude:` route is disabled and proved by its tested refusal; the dates matter only to a future amendment that enables it |
| 10 | Each provider's ID-token issuer, JWKS URI and signing algorithm | Acceptance, checked 2026-10-13 against both discovery documents, as recorded under [ID-token verification](#technical-adr-0073-id-token) |
| 11 | That OpenAI's ID token carries `aud` equal to the issued `oaiapp_...` client, and that the callback returns that issued client ID | Implementation. `real-sign-in-openai` verifies the real ID token under check 5 against the client the callback returned; a different audience fails the lane and amends this record |
| 12 | That OpenAI honors the OIDC `nonce`, and accepts a later authorize under the issued client instead of `dynamic_agent_client` | Implementation. `real-sign-in-openai` verifies check 7 on the real token, then logs out and signs in again under the floor's issued client |
| 13 | That OpenAI accepts `resource=https://api.openai.com/v1` on refresh | Implementation. The lane's forced refresh sends it and must succeed |
| 14 | That `GET /v1/models` answers a plan access token with entries carrying `visibility` | Implementation. The lane's login runs `model_list` before its write and must record a non-empty list within its bounds that names the lane's model; a failure fails the login with nothing written (D25) |
| 15 | That the plan token's model list fits 256 ids of at most 128 bytes | Implementation. The same lane case; an over-bound real list fails `sign_in_failed` and amends the bound |
| 16 | That `security -i` accepts one input line of 262,144 bytes, the base64url form of a 196,608-byte record, through the `head` wrapper | Implementation. The tagged maximum-size round trip in `sign_in_keychain_test.exs`; a refusal lowers the record bound by amendment |

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
- **Composition API.** `LoopexComposition.CredentialHost` gains `open/4`
  and `close/1`, its plane and the daemon's gain the `sign_in_routes`
  member, and `Ephemeral.start_session/1` gains the `:sign_in_routes` host
  option. An `oauth` binding given to composition as `:provider_bindings`
  is refused, and `CredentialHost.open/1` leaves one out; nothing else
  changes for an embedding host. The adapter's `token_exchange/2` and
  `model_list/2` are private to the sign-in host (`@doc false`).
- **Existing commands.** `run`, `resume` and `skill` without `--service`
  refuse an `oauth` binding of their model's route with `sign_in_unavailable` (D58);
  their other routes are unchanged.
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
