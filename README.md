 # Termux SSH Bridge

A secure Android ARM64 Flutter app that bridges a webapp to Termux / PRoot over local SSH or Tailscale.

## Features
1. **Tailscale SSH Configuration**: Input fields for Tailscale IP, Port, Username, and Password/SSH Key with secure persistence (`flutter_secure_storage` & `shared_preferences`).
2. **SSH Connection & Authentication**: Connects via `SSHSocket.connect` and authenticates using `dartssh2`.
3. **Coding Agent & Termux Presets**: Quick action buttons for running diagnostics, PRoot info, disk usage, Tailscale status, git status, and Python agent tests.
4. **Real-Time Terminal Console**: Interactive terminal log viewer displaying stdout, stderr, process exit codes, and custom bash command execution.
5. **Android ARM64 & Android 12+ Optimized**: Built specifically for modern Android devices.
6. **Gateway API**: Bearer-authenticated JSON endpoints for health checks, stored-profile connections, allowlisted command execution, and disconnects. The API shares the app's existing SSH session.
7. **Webapp Cloud Queue**: The phone can pair with the webapp and poll for queued commands over HTTPS, then run allowed commands through a saved SSH profile and report results. This works without exposing the phone API to the internet.
8. **CI/CD Pipeline**: GitHub Actions workflow (`.github/workflows/build_apk.yml`) to automatically compile the release APK.

## Connecting from the Terminal tab

The terminal command box also supports a local SSH connection command:

```text
connect <host> <port> <username>
```

For example:

```text
connect 100.x.x.x 8022 your_user
```

The app prompts for the password securely when it is not included. You may also provide it as a fourth argument, although prompting is safer because inline passwords can remain visible in the input field.

The status badge has three states:

- **OFFLINE**: No SSH session is active.
- **CONNECTING**: The app is opening the SSH socket and authenticating.
- **ONLINE**: SSH authentication succeeded.

Make sure Tailscale is installed and connected on the Android device before connecting.

For Termux running on the same phone, use host `127.0.0.1` and the SSH server's
port (commonly `8022`) in the saved profile; Tailscale is not needed for this
local SSH connection.

## Connecting from the hosted webapp

The **API** tab includes a **Webapp Cloud Connection** section. In the webapp,
open **Devices**, choose **Add device**, and enter the displayed six-character
code in the phone app along with the HTTPS webapp URL and the saved SSH profile
to use. The phone stores the returned device key in encrypted storage, then
checks in to the webapp every few seconds and reports command results.

Keep the phone app open while using the cloud command queue. Commands are
checked against the API tab's allowlist before execution; disallowed commands
are reported as rejected. The phone initiates the HTTPS connection, so the
webapp does not need to connect directly to the phone and browser mixed-content
restrictions do not apply.

The cloud device key is separate from the local Gateway API bearer token. Do
not share either token. Unlink the device from the API tab or the webapp
Devices page to revoke its cloud key.

## Gateway API

Open the **API** tab to configure and start the local HTTP bridge. It listens on
port `8765` and shares the app's existing SSH connection. Copy the generated
bearer token from the API tab, then authenticate every request:

```bash
curl http://127.0.0.1:8765/health \
  -H "Authorization: Bearer YOUR_TOKEN"
```

The available endpoints are `GET /health`, `POST /connect`, `POST /execute`,
and `POST /disconnect`. The server binds to loopback by default. LAN access is
an explicit opt-in for trusted networks, and the bearer token remains required.
Commands are restricted to the editable allowlist in the API tab.

The full request and response format is documented in
[`docs/API_CONTRACT.md`](docs/API_CONTRACT.md).

## Building the APK
```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```
The output APK will be available at `build/app/outputs/flutter-apk/app-release.apk`.
