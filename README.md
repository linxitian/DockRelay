# DockRelay

DockRelay clears stale Dock hover after a macOS Space switch. It also checks for a Dock that stays visible when it should hide and for a stale highlight when the pointer remains in Dock. It runs as a menu bar app and can start automatically at login.

[简体中文](README.zh-CN.md)

## Try it

1. Build on macOS with Xcode Command Line Tools or Xcode.

   ```sh
   ./build.sh
   open build/DockRelay.app
   ```

2. Enable **DockRelay** in the Accessibility permissions page under **System Settings → Privacy & Security**. On macOS 27.2 the page may be labeled **Device Control and Data Access**. Open its menu bar menu to refresh the status. If the menu asks for Input Monitoring, follow the system prompt and reopen DockRelay.
3. Reproduce the issue by clicking a Dock icon for an app in another Space and quickly moving the pointer away during the transition. Check **Recoveries** in the menu. The counter advances when the Dock clears after a replay.
4. For daily use, put the app in a stable Applications folder before granting access and select **Launch at Login** in its menu.

The build targets macOS 13 or later and contains Apple silicon and Intel slices. A local ad-hoc build may need a fresh Accessibility grant after rebuilding. If the existing entry appears enabled but the app says otherwise, remove the old entry and add the current app. To uninstall, turn off **Launch at Login**, quit, remove the app, and remove its privacy entries.

## How it works

- A listen-only Quartz tap sees only enter and exit tracking events sent to the current Dock PID. The latest exit is kept in memory. A new enter or Dock PID invalidates it.
- A real exit can open a brief inspection window before any Space notification. DockRelay replays early when the exit was inside Dock, the cursor is now outside, and Accessibility still reports a hovered item. It takes two observations if the exit was close to the inner edge. Ordinary exits at or beyond the boundary do not qualify.
- A Space change also opens a short inspection window. DockRelay checks for a recent exit, checks the Dock through Accessibility on a separate queue. A fresh exit recorded over Dock and an item that is still hovered can trigger a replay after one observation. If the Dock only stays visible, or the exit did not originate over Dock, it waits for corroboration. Geometry uses Quartz display coordinates and the configured Dock edge. Immediately before posting, the current cursor must be clear of the Dock and any magnified item it reports.
- DockRelay copies the exit and sends it back to the same PID with a fresh timestamp and pointer location. Checks start when the Space notification arrives and spread out as the animation settles. A pending retry gets a fresh check when it becomes eligible. The app can send up to four times per exit at increasing intervals. It gives the first replay time to clear the hover. When the first send followed the Space notification and two further samples show the hovered item has not moved or shrunk, it can retry sooner. New Space changes supersede pending checks.

- If the pointer stays inside Dock during a Space switch, DockRelay checks the app icon under it. During the transition it can post a mouse-move event to Dock after the pointer crosses from the icon where the original exit happened to a different app. This covers both an old highlight and a briefly empty selection after the original hover was observed. After the Space notification it requires two samples that agree on the new target. It skips ambiguous targets and pressed mouse buttons.

There is no idle timer, network connection, or third-party runtime. The app does not record keys, click, take screenshots, move the pointer, or restart Dock. The local unified log records attach, replay, and recovery, including elapsed time from the captured exit and the Space notification. A recovery timestamp records when the app observed the result, which includes the time until its next check.

```sh
log stream --style compact --predicate 'subsystem == "io.github.linxitian.dockrelay"'
```

## Validation and limits

`./test.sh` checks the geometry for all three Dock positions, offset displays, a hidden Dock parked over an adjacent display, and the decisions for hover, unexpected visibility, and user interaction. The menu bar app was run on Apple silicon with macOS 27.2 (26B123). The tester reproduced their usual cross-Space issue, saw the Dock recover, and confirmed a nonzero recovery count. Older macOS releases, Intel, physical multi-monitor configurations, and the full-screen-only variant still need live coverage.

On the same Mac, 0.8.0 observed the correct icon selected 13–33 ms after each of 13 early hover replays. This measures the Accessibility selection, and the tester could still see an occasional pause in the magnification animation.

This is a user-session workaround. The Quartz and Accessibility calls are public APIs, but the tracking event types delivered to Dock and its Accessibility structure are implementation details. If macOS changes them, the app may no longer find or replay a usable event. A permanent fix to the Dock itself requires an Apple update.

For distribution, `SIGN_IDENTITY` selects a Developer ID Application signing identity. Sign and notarize the build before offering a public download. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Credit

The captured enter and exit sequences and the replay idea come from [LLP2333/dockUnstick](https://github.com/LLP2333/dockUnstick/tree/3e323de2116deca69a3bb8b7280c182f670b317a). DockRelay implements its own watcher, geometry, and interface. [MIT License](LICENSE).
