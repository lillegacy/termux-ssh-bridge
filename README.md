# Termux SSH Bridge

A secure Android ARM64 mobile application built with Flutter that acts as a secure SSH proxy and coding agent bridge to your Termux / PRoot environment over Tailscale.

## Features
1. **Tailscale SSH Configuration**: Input fields for Tailscale IP, Port, Username, and Password/SSH Key with secure persistence (`flutter_secure_storage` & `shared_preferences`).
2. **SSH Connection & Authentication**: Connects via `SSHSocket.connect` and authenticates using `dartssh2`.
3. **Coding Agent & Termux Presets**: Quick action buttons for running diagnostics, PRoot info, disk usage, Tailscale status, git status, and Python agent tests.
4. **Real-Time Terminal Console**: Interactive terminal log viewer displaying stdout, stderr, process exit codes, and custom bash command execution.
5. **Android ARM64 & Android 12+ Optimized**: Built specifically for modern Android devices.
6. **CI/CD Pipeline**: GitHub Actions workflow (`.github/workflows/build_apk.yml`) to automatically compile the release APK.

## Building the APK
```bash
flutter pub get
flutter build apk --release --target-platform android-arm64
```
The output APK will be available at `build/app/outputs/flutter-apk/app-release.apk`.
