# Termux SSH Bridge

A secure Android ARM64 mobile application built with Flutter that acts as a secure SSH proxy and coding agent bridge to your Termux / PRoot environment over Tailscale.

## Features
1. **Tailscale SSH Configuration**: Input fields for Tailscale IP, Port, Username, and Password/SSH Key with secure persistence (`flutter_secure_storage` & `shared_preferences`).
2. **SSH Connection & Authentication**: Connects via `SSHSocket.connect` and authenticates using `dartssh2`.
3. **Coding Agent & Termux Presets**: Quick action buttons for running diagnostics, PRoot info, disk usage, Tailscale status, git status, and Python agent tests.
4. **Real-Time Terminal Console**: Interactive terminal log viewer displaying stdout, stderr, process exit codes, and custom bash command execution.
5. **Android ARM64 & Android 12+ Optimized**: Built specifically for modern Android devices.
6. **CI/CD Pipeline**: GitHub Actions workflow (`.github/workflows/build_apk.yml`) to automatically compile the release APK.

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

## Building the APK
```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```
The output APK will be available at `build/app/outputs/flutter-apk/app-release.apk`.
