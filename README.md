# DockRelay

DockRelay clears stale Dock hover after a macOS Space switch. It also checks for a Dock that stays visible when it should hide. It runs as a menu bar app and can start automatically at login.

[简体中文](README.zh-CN.md)

## Try it

1. Build on macOS with Xcode Command Line Tools or Xcode.

   ```sh
   ./build.sh
   open build/DockRelay.app
   ```

2. Enable **DockRelay** in **System Settings → Privacy & Security → Accessibility**. Open its menu bar menu to refresh the status. If the menu asks for Input Monitoring, follow the system prompt and reopen DockRelay.
3. Reproduce the issue by clicking a Dock icon for an app in another Space and quickly moving the pointer away during the transition. Check **Recoveries** in the menu. The counter advances when the Dock clears after a replay.
4. For daily use, put the app in a stable Applications folder before granting access and select **Launch at Login** in its menu.

The build targets macOS 13 or later and contains Apple silicon and Intel slices. A local ad-hoc build may need a fresh Accessibility grant after rebuilding. If the existing entry appears enabled but the app says otherwise, remove the old entry and add the current app. To uninstall, turn off **Launch at Login**, quit, remove the app, and remove its privacy entries.

## How it works

- A listen-only Quartz tap sees only enter and exit tracking events sent to the current Dock PID. The latest exit is kept in memory. A new enter or Dock PID invalidates it.
- A Space change opens a short inspection window. DockRelay checks for a recent exit, checks the Dock through Accessibility on a separate queue, and waits for two suspicious observations. Geometry uses Quartz display coordinates and the configured Dock edge. The cursor must be clear of the Dock and any magnified item it reports.
- DockRelay copies the exit and sends it back to the same PID with a fresh timestamp and pointer location. It allows up to two sends in the inspection window and looks for recovery in a later sample. New Space changes supersede pending checks.

There is no idle timer, network connection, or third-party runtime. The app does not record keys, click, take screenshots, move the pointer, or restart Dock. It logs attach, replay, and recovery status to the local unified log without app titles or cursor positions.

```sh
log stream --style compact --predicate 'subsystem == "io.github.linxitian.dockrelay"'
```

## Validation and limits

`./test.sh` checks the geometry for all three Dock positions, offset displays, a hidden Dock parked over an adjacent display, and the decisions for hover, unexpected visibility, and user interaction. The menu bar app was run on Apple silicon with macOS 27.2 (26B123). The tester reproduced their usual cross-Space issue, saw the Dock recover, and confirmed a nonzero recovery count. Older macOS releases, Intel, physical multi-monitor configurations, and the full-screen-only variant still need live coverage.

This is a user-session workaround. The Quartz and Accessibility calls are public APIs, but the tracking event types delivered to Dock and its Accessibility structure are implementation details. If macOS changes them, the app may no longer find or replay a usable event. A permanent fix to the Dock itself requires an Apple update.

For distribution, `SIGN_IDENTITY` selects a Developer ID Application signing identity. Sign and notarize the build before offering a public download. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Credit

The captured enter and exit sequences and the replay idea come from [LLP2333/dockUnstick](https://github.com/LLP2333/dockUnstick/tree/3e323de2116deca69a3bb8b7280c182f670b317a). DockRelay implements its own watcher, geometry, and interface. [MIT License](LICENSE).
