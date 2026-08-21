# Remote qBittorrent Web API Client

**Goal:** Build an Omarchy bar widget that securely controls any compatible qBittorrent Web API endpoint.

**Architecture:** Use one endpoint-agnostic API client for status reads and mutations. Configure the base URL, username, and refresh interval through Omarchy widget settings. Keep passwords in Secret Service. Keep only session cookies and qBittorrent sync state in a private runtime directory.

## Invariants

- Never put a qBittorrent password in `shell.json`, a command argument, process environment, repository file, log, or error message.
- Require HTTPS for non-loopback endpoints. Permit plain HTTP only for loopback development endpoints.
- Keep TLS certificate and hostname verification enabled.
- Normalize and validate the base URL once: allow only `http` and `https`; reject user information, query strings, fragments, empty hosts, and control characters; remove trailing slashes while preserving an intentional path prefix.
- Isolate cookies and sync RID caches by normalized endpoint plus username. A setting change must not reuse another connection's state.
- Support status, magnet/URL add, selected `.torrent` upload, start, stop, delete, file priorities, alternative speed mode, rate limits, sequential mode, and share ratio.
- Treat save paths returned by the API as paths on the qBittorrent host. Display them as plain text and never pass them to `xdg-open`.
- Never install, start, stop, configure, or inspect a qBittorrent process on the widget host.
- Keep automated network traffic on fixture servers. Tests must never contact or mutate a user-configured endpoint.

## Target architecture

| File | Responsibility |
|---|---|
| `manifest.json` | Plugin identity and `baseUrl`, `username`, and `refreshIntervalSec` settings |
| `qbt` | URL validation, Secret Service lookup, authentication, cookie retry, Web API calls, and per-connection runtime state |
| `Service.qml` | Pass non-secret settings to `qbt`; expose API readiness and transfer state |
| `Model.js` | Parse the status contract and produce safe user-facing connection errors |
| `Panel.qml` | Connection state and remote-safe torrent controls |
| `tests/fixtures/server.py` | Authenticated qBittorrent fixture with session validation, request recording, and failure modes |
| `tests/api-contract.sh` | Authentication, cookie reuse, state isolation, URL security, API action, and sanitization contracts |
| `tests/model.test.js` | Status, error, formatting, filtering, and torrent model contracts |
| `README.md` | Installation, endpoint configuration, Secret Service provisioning, security model, and limitations |

## Task 1: Define plugin identity and connection settings

**Files:** `manifest.json`, `README.md`

- [ ] Use plugin ID `omaqbt.remote` consistently in the manifest, QML IPC target, Secret Service attributes, documentation, and installation metadata.
- [ ] Preserve repository and maintainer metadata plus upstream MIT attribution in `LICENSE`.
- [ ] Add manifest settings:
  - `baseUrl`: string; defaults to the loopback qBittorrent Web API endpoint.
  - `username`: string; defaults to empty for an unauthenticated loopback endpoint.
  - `refreshIntervalSec`: integer; retain the supported polling range and default.
- [ ] Document an endpoint-neutral widget configuration example:

  ```json
  {
    "baseUrl": "https://torrent.example.net",
    "username": "example-user",
    "refreshIntervalSec": 5
  }
  ```

- [ ] Document HTTPS enforcement and mandatory TLS verification.

**Acceptance:** `omarchy plugin validate .` accepts the manifest, and the plugin installs and enables as `omaqbt.remote`.

## Task 2: Implement a connection-scoped API client

**Files:** `qbt`

- [ ] Add global `--base-url <url>` and `--username <name>` options before the command name.
- [ ] Support `QBT_BASE` and `QBT_USERNAME` as fixture overrides; explicit command-line options win.
- [ ] Normalize and validate the endpoint before any network or credential operation:
  - Accept `https://host[:port][/prefix]`.
  - Accept plain HTTP only for loopback hosts.
  - Reject user information, query strings, fragments, unsupported schemes, empty hosts, and newline/control characters.
  - Remove trailing slashes without removing an intentional path prefix.
- [ ] Derive a connection key as SHA-256 of the normalized URL, a NUL separator, and the username.
- [ ] Store state under `$STATE_DIR/connections/<key>/`:
  - `cookies.txt` for curl's cookie jar.
  - `rid.json` for qBittorrent sync state.
- [ ] Create runtime state under `umask 077`.
- [ ] Reject symlinked state directories/files and state not owned by the current user.
- [ ] Attempt the configured API directly for every status and action command.
- [ ] Depend only on `curl`, `jq`, `python3`, `sha256sum`, standard shell utilities, and optionally `secret-tool` for authenticated endpoints.
- [ ] Keep `qbt` limited to endpoint communication, authentication, and connection-scoped state.

**Acceptance:** `qbt status` reaches the configured endpoint without requiring qBittorrent software or a qBittorrent process on the widget host.

## Task 3: Authenticate without leaking credentials

**Files:** `qbt`, `tests/fixtures/server.py`, `tests/api-contract.sh`

- [ ] Send the connection cookie jar on every API request and update it from every response.
- [ ] Send `Referer: <normalized-base-url>/` on API requests for qBittorrent CSRF validation.
- [ ] On the first protected API `403`, authenticate once and replay the original request once:
  1. Require a configured username.
  2. Read the password with `secret-tool lookup application omaqbt.remote endpoint <normalized-url> username <username>`.
  3. Confirm the Secret Service lookup succeeded before sending a login request.
  4. Pipe the password to curl over standard input with `--data-urlencode 'password@-'`; never interpolate it into curl's arguments.
  5. POST the username and password to `/api/v2/auth/login`.
  6. Accept a successful login only when the response stores a session cookie. Support qBittorrent responses using HTTP 200 with body `Ok.` and HTTP 204 with an empty body.
  7. Recognize standard and endpoint-specific qBittorrent session-cookie names without printing their values.
  8. Replay the original API request with the stored cookie.
- [ ] Never send an empty-password login when the Secret Service entry is absent.
- [ ] Reuse a valid cookie without querying Secret Service again.
- [ ] On a later protected API `403`, refresh the session once and replay once; never loop.
- [ ] Report distinct sanitized failures for missing username, missing secret, rejected credentials, login client ban, TLS/transport failure, access rejection, and other HTTP responses.
- [ ] Redact cookie headers, session identifiers, login fields, and password-like content from errors.
- [ ] Preserve selected `.torrent` input across an authentication replay and accept it only once after authentication.
- [ ] Stub `secret-tool` through a test-only `PATH` prefix. Do not add a production plaintext-password override.

**Acceptance contracts:**

- [ ] The first authenticated API request performs exactly one login and succeeds.
- [ ] A second helper invocation reuses the runtime session without another login or Secret Service lookup.
- [ ] An expired cookie causes exactly one login refresh and one replay.
- [ ] A missing secret causes no login request.
- [ ] Wrong or absent credentials fail without exposing a password or session identifier.
- [ ] Login HTTP 403 reports qBittorrent's client-ban condition.
- [ ] A disallowed plain-HTTP URL fails before `secret-tool` or curl runs.
- [ ] Different endpoint/username pairs never share cookies or RID data.
- [ ] Authenticated magnet adds and selected `.torrent` uploads satisfy their request contracts.

## Task 4: Model readiness as API session state

**Files:** `Service.qml`, `Model.js`, `tests/model.test.js`

- [ ] Add normalized accessors for `settings.baseUrl` and `settings.username`.
- [ ] Centralize helper command construction:

  ```text
  qbt --base-url <baseUrl> --username <username> <command> [arguments...]
  ```

- [ ] Use that builder for status, files, and every mutation.
- [ ] Define `ready` as a successful API session and `warning` as `!api`.
- [ ] Use this helper status schema:

  ```json
  {
    "api": true,
    "error": "",
    "altSpeed": false,
    "dlSpeed": 0,
    "upSpeed": 0,
    "torrents": []
  }
  ```

- [ ] Return the same parseable schema with `api: false`, zero speeds, and an empty torrent list when a status probe fails.
- [ ] Keep action failures as nonzero exits.
- [ ] Clear stale torrents, files, speeds, and alternative-speed state when the endpoint becomes unavailable or connection settings change.
- [ ] Trigger an immediate refresh when `baseUrl` or `username` changes.
- [ ] Ignore results from a process started for an earlier connection key.

**Acceptance:** A settings change cannot send the next action to the previous endpoint, successful status clears prior connection errors, and a failed endpoint cannot leave stale ready-state data visible.

## Task 5: Provide remote-safe panel controls

**Files:** `Panel.qml`, `Model.js`, `tests/model.test.js`

- [ ] Show transfer rates, active count, alternative-speed state, and sort state when ready.
- [ ] Show a sanitized helper error when unavailable, falling back to `Remote Web API is not reachable`.
- [ ] Render endpoint-controlled names, paths, and errors as plain text.
- [ ] Display `savePath` as informational text only.
- [ ] Keep file listing and priority controls.
- [ ] Keep add, start/stop, delete, limits, sequential mode, ratio, filters, notifications, refresh, and right-click start/stop-all behavior.
- [ ] Provide keyboard focus transitions only for visible remote-safe controls.
- [ ] Expose only operations implemented through the configured qBittorrent Web API.

**Acceptance:** The panel becomes ready solely from a successful API session and exposes no action that manages software, services, network interfaces, or paths on the widget host.

## Task 6: Document generic endpoint setup

**Files:** `README.md`

- [ ] Explain the architecture as a qBittorrent Web API client.
- [ ] Use arbitrary example hostnames and usernames in endpoint configuration and Secret Service commands.
- [ ] Keep canonical repository URLs for installation and removal instructions.
- [ ] Document Secret Service provisioning without a password argument or environment variable:

  ```bash
  secret-tool store \
    --label='OmaqBT qBittorrent password' \
    application omaqbt.remote \
    endpoint https://torrent.example.net \
    username example-user
  ```

- [ ] Document credential removal:

  ```bash
  secret-tool clear \
    application omaqbt.remote \
    endpoint https://torrent.example.net \
    username example-user
  ```

- [ ] List `secret-tool`/libsecret only as an authenticated-endpoint requirement.
- [ ] Explain that a selected `.torrent` file is uploaded to the qBittorrent host.
- [ ] Explain that returned save paths belong to the qBittorrent host and cannot be opened from the widget.
- [ ] Document HTTPS requirements, TLS verification, private runtime state, and session isolation.

**Acceptance:** A user can install the plugin, configure any compatible endpoint, provision its secret, and understand the remote-path and security constraints without reading source code.

## Task 7: Verify contracts and an optional configured endpoint

Run automated checks first:

```bash
npm test
./tests/api-contract.sh
omarchy plugin validate .
```

Automated checks must use fixtures only.

For an optional non-mutating manual smoke test:

- [ ] Provision the endpoint's Secret Service entry interactively.
- [ ] Run authenticated status:

  ```bash
  ./qbt \
    --base-url https://torrent.example.net \
    --username example-user \
    status | jq '{api, error, dlSpeed, upSpeed, torrentCount: (.torrents | length)}'
  ```

- [ ] Run status again and confirm the private runtime session is reused without printing the cookie.
- [ ] Enable `omaqbt.remote` with matching widget settings and open the panel.
- [ ] Verify ready state, refresh, torrent listing, and file detail when the endpoint has torrents.
- [ ] Verify an invalid test endpoint produces a sanitized connection error and clears stale data.
- [ ] Do not mutate torrents during the smoke test.

## Completion criteria

- The plugin controls any compatible configured qBittorrent Web API endpoint.
- The widget host does not need qBittorrent installed or running.
- Passwords never enter plugin configuration, arguments, environment, logs, errors, or repository files.
- Session cookies and RID state are private and connection-scoped.
- Missing secrets never cause empty-password login requests.
- Every remote-safe torrent operation is covered by fixture tests.
- The UI contains no host-management or path-opening behavior.
- Unit tests, API contract tests, and plugin validation pass.
