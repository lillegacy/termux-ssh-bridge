# Gateway API Contract

The Termux SSH Bridge exposes a small JSON API over HTTP on port `8765`.
The API and the mobile terminal share one SSH connection.

Phase 1 adds an **on-demand bridge**: instead of queueing commands for a poll,
a client can open a session with `POST /bridge/connect`, run commands with
`POST /bridge/execute`, and close it with `POST /bridge/disconnect`. The
`/connect`, `/execute` and `/disconnect` endpoints remain as aliases.

## Authentication

Every JSON endpoint, including `/health`, requires a bearer token:

```http
Authorization: Bearer YOUR_TOKEN
```

The token is generated on the device and shown in the app's **API** tab.
Copy it with the token field's copy button. The token is stored in Android
encrypted secure storage and is never sent to the SSH server.

Requests without a valid token receive HTTP `401` and this response:

```json
{
  "ok": false,
  "error": {
    "code": "unauthorized",
    "message": "A valid bearer token is required."
  }
}
```

The server allows browser cross-origin requests and includes CORS headers.
Use HTTPS or an SSH tunnel when the browser page is served over HTTPS.

## Bridge PIN

The **API** tab can store an optional numeric PIN. When it is set,
`POST /bridge/connect` and `POST /connect` require it:

```json
{ "profile": "Default Tailscale Termux", "pin": "1234" }
```

Five failed attempts lock PIN entry for one minute (`429 pin_locked`).
An empty PIN disables the check. The bearer token is still mandatory.

## Session lifecycle

| Phase | Rule |
| --- | --- |
| Active | A command resets the idle timer. Heartbeat: **5 s**. |
| Idle | No command for **30 s**. Heartbeat eases to **30 s**. |
| Closed | No command for **30 min**. The SSH connection is closed automatically. |

The app also closes the session if the phone's own **Disconnect** button is
used, and reports the new state on the next request.

## Endpoints

### `GET /health`

Returns the shared SSH connection state plus the current bridge session.

```json
{
  "ok": true,
  "status": "ok",
  "sshConnected": true,
  "sshConnecting": false,
  "activeProfile": "default",
  "bridge": {
    "sessionId": "6f1c...",
    "profile": "Default Tailscale Termux",
    "connectedForSeconds": 42,
    "idleSeconds": 3,
    "idle": false,
    "commandCount": 2,
    "heartbeatSeconds": 5
  }
}
```

`bridge` is `null` when no session is open.

### `POST /bridge/connect` (alias: `POST /connect`)

Connects to a profile already stored in the app. The request body identifies
the profile by its ID or display name. The API never needs or returns the SSH
password.

```json
{
  "profile": "Default Tailscale Termux",
  "pin": "1234"
}
```

Success:

```json
{
  "ok": true,
  "connected": true,
  "profile": "Default Tailscale Termux",
  "pinRequired": true,
  "session": {
    "sessionId": "6f1c...",
    "connectedForSeconds": 0,
    "idleSeconds": 0,
    "idle": false,
    "commandCount": 0,
    "heartbeatSeconds": 5
  }
}
```

If authentication fails, the endpoint returns `ok: false`, `connected: false`,
and a `message` describing the failure.

### `POST /bridge/execute` (alias: `POST /execute`)

Executes a command over the active SSH connection and waits for it to finish.
The command never waits for an external poll: it runs as soon as the request
arrives.

```json
{
  "command": "uname -a"
}
```

Success:

```json
{
  "ok": true,
  "stdout": "Linux termux 6.1.0-aarch64\n",
  "stderr": "",
  "exitCode": 0,
  "session": { "idle": false, "heartbeatSeconds": 5 }
}
```

`ok` reflects whether the exit code was zero. A non-zero command exit remains
an HTTP `200` response so the caller can inspect `stderr` and `exitCode`.

### Command policy (ban list)

Phase 1 replaced the allow list with a **ban list**, editable in the app's
**API** tab (one blocked command or pattern per line, `#` starts a comment).

* A command is rejected when its first token — or the basename of an absolute
  path — equals a banned name, or when the line contains a banned multi-word
  pattern.
* Banned names also cover dotted variants: `mkfs` blocks `mkfs.ext4`.
* Shell indirection (`sh`, `bash`, `eval`, `exec`, `command`, `builtin`) is
  banned by default so a caller cannot route around the list.
* Command substitution, redirection, newlines and control characters are
  rejected outright. `;`, `&`, and `|` split the command into segments and
  every segment is checked.

A rejected command returns HTTP `403`:

```json
{
  "ok": false,
  "error": {
    "code": "command_not_allowed",
    "message": "\"rm\" is on the command ban list."
  }
}
```

The default list targets destructive and power operations only (`rm`, `dd`,
`mkfs`, `sudo`, `shutdown`, …). Because a ban list permits everything else,
the bearer token and the phone's SSH credentials are the primary controls —
treat the token as a secret.

### `POST /bridge/disconnect` (alias: `POST /disconnect`)

Closes the shared SSH connection and ends the session.

```json
{
  "ok": true,
  "connected": false,
  "session": null
}
```

### `POST /bridge/ping` (alias: `POST /ping`)

Wake-up call for the webapp. It nudges the app isolate, polls the cloud queue
immediately instead of waiting for the next background tick, counts as bridge
activity and answers in a few milliseconds. The webapp uses it as a liveness
and version probe.

```json
{
  "ok": true,
  "pong": true,
  "version": "1.5.1+11",
  "sshConnected": true,
  "sshConnecting": false,
  "activeTerminals": 0,
  "serverTime": "2026-11-17T02:40:00.000Z"
}
```

`GET /health`, `POST /bridge/ping` and `GET /bridge/status` all report
`version`, so a stale install is visible from the browser without guessing.

### `GET /bridge/status` and `POST /bridge/heartbeat`

Return the current session without running a command. A heartbeat does not
count as command activity and does not reset the idle timer.

```json
{
  "ok": true,
  "version": "1.5.1+11",
  "connected": true,
  "session": { "sessionId": "6f1c...", "idle": true, "heartbeatSeconds": 30 }
}
```

### `GET /bridge/terminal/status`

Reports whether interactive terminals are available and how many are open.
Requires the bearer token.

```json
{
  "ok": true,
  "activeTerminals": 0,
  "maxTerminals": 4,
  "available": true
}
```

### `POST /bridge/terminal/ticket`

Exchange the bearer token for a single-use WebSocket ticket. Tickets expire
after 60 seconds and are consumed by the first successful upgrade. Browsers
cannot set an `Authorization` header on a WebSocket handshake, so the ticket
travels in the query string instead.

```json
{
  "ok": true,
  "ticket": "hR2...",
  "expiresInSeconds": 60,
  "maxTerminals": 4,
  "activeTerminals": 0
}
```

### `GET /bridge/terminal` (WebSocket)

Open a full PTY over the existing SSH connection:

```
ws://HOST:8765/bridge/terminal?ticket=TICKET&cols=120&rows=32
```

The upgrade is rejected unless the ticket is valid. At most four terminals can
be open at once (`429 too_many_terminals`). `cols` and `rows` are clamped to
20–400 and 5–200.

Frames are asymmetric so raw terminal output is never re-encoded:

- **Server → client binary frames** carry raw PTY output bytes.
- **Server → client text frames** carry JSON control messages.
- **Client → server text frames** carry JSON control messages.

Control messages:

```json
{ "type": "ready", "columns": 120, "rows": 32, "terminal": "xterm-256color" }
{ "type": "exit", "code": 0 }
{ "type": "error", "code": "stream_failed", "message": "..." }
{ "type": "pong" }
```

Client messages:

```json
{ "type": "input", "data": "ls -la\r" }
{ "type": "resize", "cols": 100, "rows": 40 }
{ "type": "ping" }
```

`input.data` is UTF-8 encoded before it is written to the SSH channel.
`resize` updates the remote window size immediately. An open terminal keeps the
bridge session alive: the idle timer is reset while any terminal is connected,
so a long-running `tmux` or `vim` session is not disconnected after 30 minutes.

## Errors

Error responses use one envelope:

```json
{
  "ok": false,
  "error": {
    "code": "invalid_request",
    "message": "A human-readable explanation."
  }
}
```

Common status codes are `400` (bad request), `401` (bad token or PIN), `403`
(command denied), `404` (unknown route or profile), `409` (gateway state
conflict), `413` (body too large), `429` (PIN locked) and `500`
(execution/server failure).

## Network security

The server binds to `127.0.0.1` by default. In the app's **API** tab, enabling
**Allow trusted LAN access** changes the bind address to `0.0.0.0` and restarts
the server. This is intended only for a trusted local network. The bearer token
remains mandatory, but plain HTTP does not encrypt traffic; use an SSH tunnel
or HTTPS reverse proxy when confidentiality is required.

The request body limit is 1 MiB.

## Webapp cloud command queue

The local Gateway API is not the connection used by the hosted webapp. To
avoid requiring the browser to reach the phone over plain HTTP, pair the phone
with the webapp from the app's **API** tab:

1. In the webapp, open **Devices** and create a one-time pairing code.
2. In the phone app, enter the HTTPS webapp URL, pairing code, and saved SSH
   profile to use for cloud commands.
3. Keep the phone app open. It polls `/api/public/device/poll` every five
   seconds over HTTPS, executes commands through the selected SSH profile, and
   reports output to `/api/public/device/result`.

The device key returned by `/api/public/device/pair` is kept in encrypted
device storage. The phone enforces the same ban list for cloud commands and
reports rejected commands as `rejected`. The webapp API bearing the device key
is separate from the local Gateway API bearer token. Unlink from the app or the
webapp's Devices page to revoke the cloud key.

The cloud queue remains the fallback when the browser cannot reach the phone
directly. When it can, the bridge endpoints above remove the polling delay.
