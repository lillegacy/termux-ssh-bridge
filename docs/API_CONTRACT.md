# Gateway API Contract

The Termux SSH Bridge exposes a small JSON API over HTTP on port `8765`.
The API and the mobile terminal share one SSH connection.

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

## Endpoints

### `GET /health`

Returns the shared SSH connection state.

```json
{
  "ok": true,
  "status": "ok",
  "sshConnected": true,
  "sshConnecting": false,
  "activeProfile": "default"
}
```

### `POST /connect`

Connects to a profile already stored in the app. The request body identifies
the profile by its ID or display name. The API never needs or returns the SSH
password.

```json
{
  "profile": "Default Tailscale Termux"
}
```

Success:

```json
{
  "ok": true,
  "connected": true,
  "profile": "Default Tailscale Termux"
}
```

If authentication fails, the endpoint returns `ok: false`, `connected: false`,
and a `message` describing the failure.

### `POST /execute`

Executes a command over the active SSH connection and waits for it to finish.

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
  "exitCode": 0
}
```

`ok` reflects whether the exit code was zero. A non-zero command exit remains
an HTTP `200` response so the caller can inspect `stderr` and `exitCode`.

The command must satisfy the configured allowlist. Every segment separated by
`&&`, `||`, `;`, or `|` must begin with an allowed prefix. Command substitution
and input/output redirection are disabled. A rejected command returns HTTP
`403` with error code `command_not_allowed`.

### `POST /disconnect`

Closes the shared SSH connection.

```json
{
  "ok": true,
  "connected": false
}
```

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

Common status codes are `400` (bad request), `401` (bad token), `403`
(command denied), `404` (unknown route or profile), `409` (gateway state
conflict), `413` (body too large), and `500` (execution/server failure).

## Network security

The server binds to `127.0.0.1` by default. In the app's **API** tab, enabling
**Allow trusted LAN access** changes the bind address to `0.0.0.0` and restarts
the server. This is intended only for a trusted local network. The bearer token
remains mandatory, but plain HTTP does not encrypt traffic; use an SSH tunnel
or HTTPS reverse proxy when confidentiality is required.

The request body limit is 1 MiB.
