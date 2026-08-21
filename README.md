# OmaqBT

OmaqBT is an [Omarchy](https://omarchy.org) Quattro bar widget for controlling qBittorrent through its Web API. The bar shows live download/upload rates; the panel lists transfers, adds magnets, URLs, and `.torrent` files, controls torrent state, and edits file priorities and transfer limits.

This fork is maintained by [Manuel Seeger](https://github.com/manuelseeger) at [manuelseeger/omaqbt](https://github.com/manuelseeger/omaqbt). Upstream MIT attribution remains in [LICENSE](LICENSE).

![OmaqBT on the Omarchy bar](preview.png)

![OmaqBT torrent detail, remove, and file list](preview-detail.png)

## Install

```sh
omarchy plugin add https://github.com/manuelseeger/omaqbt.git --enable
omarchy bar move omaqbt.remote --section right
```

The plugin uses ID `omaqbt.remote`, so it does not collide with an upstream checkout.

OmaqBT does not install or run qBittorrent. The qBittorrent Web API must already be reachable from this workstation.

## Configure the endpoint

The widget accepts these settings:

- `baseUrl`: qBittorrent Web API base URL. Default: `http://127.0.0.1:8080`.
- `username`: qBittorrent Web UI username. Default: empty, suitable for an unauthenticated localhost API.
- `refreshIntervalSec`: fallback polling interval from 5 to 3600 seconds. Default: `5`.

Set them on the widget entry in `~/.config/omarchy/shell.json`:

```json
{
  "baseUrl": "https://torrent.example.net",
  "username": "admin",
  "refreshIntervalSec": 5
}
```

Restart or reload the Omarchy shell after editing its configuration. Changing `baseUrl` or `username` while the shell is running clears the previous transfer state and triggers an immediate connection probe.

### URL security

Remote endpoints must use HTTPS. Plain HTTP is accepted only for `127.0.0.1`, `localhost`, and `[::1]`. URLs containing user information, a query string, a fragment, an unsupported scheme, an empty host, or control characters are rejected before any credential lookup or network request.

TLS certificate and hostname verification are always enabled. There is no insecure-TLS setting or fallback.

## Provision authentication

When `username` is non-empty and qBittorrent requests authentication, OmaqBT reads the password from Secret Service through `secret-tool`. Store the password for the exact normalized endpoint and username:

```bash
secret-tool store \
  --label='OmaqBT qBittorrent password' \
  application omaqbt.remote \
  endpoint https://torrent.example.net \
  username admin
```

`secret-tool` prompts for the password. Do not add a password argument, shell variable, environment variable, or `shell.json` field.

Remove that credential with:

```bash
secret-tool clear \
  application omaqbt.remote \
  endpoint https://torrent.example.net \
  username admin
```

`secret-tool` is provided by libsecret. It is required only when the configured endpoint requires authentication. An unauthenticated loopback API does not need it.

qBittorrent defines HTTP 403 from `/api/v2/auth/login` as a temporary client-IP ban after too many failed login attempts. Wait for qBittorrent's configured ban duration or have an administrator restart the service or clear the banned IP. OmaqBT does not submit a login request when the matching Secret Service entry is absent.

## Usage

- Left click: open or close the panel.
- Right click: start or stop all torrents.
- Middle click: refresh.
- Esc: close the panel.

While a torrent is downloading or seeding, compact download/upload rates appear beside the bar mark on horizontal bars. Hover for exact rates. When a download reaches 100% between polls, OmaqBT sends a desktop notification through `notify-send`. Already-finished torrents are not re-notified after a shell restart.

Clicking a `magnet:` link in a browser opens the panel after the browser's external-handler prompt. OmaqBT queues the link locally, adds it to the configured remote qBittorrent instance until metadata is available, then stops it. The confirmation row shows the resolved name and size when available; Enter starts the torrent, while Esc cancels it and deletes its files. Paste, `y`, and drag-and-drop behavior is unchanged.

List keys:

- `j` / `k`: move.
- Enter: open torrent detail.
- Space: start or stop the selected torrent.
- `x`: remove the selected torrent while keeping its files; in file detail, skip the selected file.
- `X`: remove the torrent and delete its files after confirmation.
- `t`: start or stop all torrents.
- `s`: cycle sort order.
- `z`: toggle alternative speed limits (turtle mode).
- `a` / `p` / `c` / `*`: active, paused, completed, or all filters.
- `/`: focus the add field.
- `y`: add a magnet or `.torrent` target from the clipboard.
- `r`: refresh.
- Backspace or `h`: leave torrent detail.

File view keys: `j` / `k` move, Enter cycles priority, `x` skips a file, Space starts or stops the torrent, and `X` deletes the torrent and its files.

The add field accepts:

- A magnet link.
- An HTTP(S) URL ending in `.torrent`.
- A local `.torrent` path (`/…`, `~/…`, or `file://…`).

Selecting a local `.torrent` uploads that file to the remote qBittorrent daemon. The optional **Save to…** value is also interpreted by the remote daemon. Enter adds and starts; **Add stopped** adds without starting. Dropping a `.torrent` file or magnet link onto the open panel also adds it.

Torrent detail shows size, ratio, seeds/peers, added time, and `savePath`. The path describes the remote daemon's filesystem. OmaqBT displays it as plain text and intentionally provides no **Open folder** action or shortcut because that remote path generally does not exist on this workstation.

Remote-safe controls remain available: add, start/stop, remove, delete files, per-file priorities, alternative speed mode, per-torrent download/upload limits, sequential download, and share-ratio limits.

## Network access

Expose a qBittorrent Web API only through an intentional reverse-proxy and network-access policy. Restrict clients to the required private networks and do not expose the Web API publicly.

## Architecture and security model

- `Panel.qml` renders remote transfer state and invokes `Service.qml` operations.
- `Service.qml` passes `baseUrl` and `username` to every helper invocation. Settings changes clear stale data before probing the new connection.
- `qbt` validates and normalizes the base URL, authenticates when a protected request returns HTTP 403, and calls qBittorrent API v2.
- The password remains in Secret Service. `qbt` confirms that lookup succeeded, then pipes the password from `secret-tool` to curl over standard input; it is never placed in plugin configuration, command arguments, process environment, repository files, logs, or error messages. A missing secret never causes an empty-password login attempt.
- Every request sends the normalized endpoint as its `Referer`, plus a private curl cookie jar. A protected API 403 triggers at most one login and one replay.
- Session cookies and qBittorrent sync RID data live under `$XDG_RUNTIME_DIR/omaqbt/connections/<key>/`, where `<key>` is SHA-256 of the normalized endpoint, a NUL separator, and the username. The fallback is `/tmp/omaqbt-<uid>` when `XDG_RUNTIME_DIR` is unavailable.
- Runtime directories are private and ownership-checked. Symlinked state directories/files are rejected. Cookie and RID files are not shared across endpoints or usernames.
- Pending browser magnets live under `${XDG_STATE_HOME:-$HOME/.local/state}/omaqbt/`, separate from connection cookies and sync state.
- Helper and UI errors redact cookie, SID, login, and password-like content before display. Endpoint-controlled text is rendered as plain text.

## Requirements

- Omarchy 4 (Quattro) / `omarchy-shell`.
- A reachable qBittorrent Web API v2 endpoint.
- On `PATH` for the helper: `curl`, `jq`, `python3`, and `sha256sum`.
- `secret-tool` / libsecret only for authenticated endpoints.
- `notify-send` / libnotify for completion notifications; missing notification support is ignored.
- `xdg-mime` for browser `magnet:` handler registration.
- `wl-paste` for clipboard add support.

No local `qbittorrent`, `qbittorrent-nox`, systemd user service, VPN interface, or local qBittorrent profile is required or managed.

## Remove

Restore the previous `magnet:` handler before removing the plugin:

```sh
./qbt magnet-uninstall-handler
```

Run that command from the plugin checkout. It removes `~/.local/share/applications/omaqbt-magnet.desktop` and restores `org.qbittorrent.qBittorrent.desktop` when the Qt qBittorrent application is installed.

```sh
omarchy plugin remove omaqbt.remote
```

Removing the plugin disables the widget and deletes its checkout. It does not change the remote qBittorrent daemon or remove the Secret Service entry; use `secret-tool clear` above when credential removal is intended.

## Development

```sh
npm test
./tests/api-contract.sh
./tests/magnet-handler.sh
omarchy plugin validate .
```

The API contract suite starts only loopback fixture servers. It never contacts a real qBittorrent instance, adds a real torrent, or mutates remote data.
