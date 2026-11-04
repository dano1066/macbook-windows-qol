# Project notes

## Working agreement

- After a new feature is confirmed working by Dan, commit it and push it to the configured remote. Do not claim a feature is confirmed merely because it compiles.
- Preserve Dan's existing macOS settings and explain any system-wide changes or permissions. Avoid changing his system just to test a build.
- This project is a native Swift/AppKit macOS menu-bar app, built with `./scripts/build.sh`; full Xcode is not required. The output is `build/Windows QoL.app` (ignored by Git). Test builds without replacing a running app where possible, and tell Dan to quit and reopen it after updates.

## Accessibility and signing

- Window tracking, focusing and minimizing depend on macOS Accessibility permission. The app checks `AXIsProcessTrusted()` and displays a warning if it is false.
- A recurring failure was an enabled Accessibility switch while the app still reported no access. The app running at the path in `build` was the correct build. TCC logs showed that the system `tccd` service was checking an old cached code hash (`37a979...`) against the newer build. Removing and re-adding the old entry did not solve it.
- Changing the bundle identifier from `local.dan.windows-qol` to `local.dan.windowsqol`, rebuilding, and registering the new app for Accessibility resolved this for Dan. The app migrates pinned apps and the pending Dock backup from the old preferences domain. The bundled Finder extension also has a new identifier.
- The local build is ad-hoc signed with an explicit, stable identifier-based designated requirement; it is not an authenticated developer signature. Do not assume this alone prevents TCC cache issues across rebuilds. If access fails again, check the actual running executable, its code signature, and relevant `com.apple.TCC` logs before recommending another permission reset. Never modify the TCC database directly or weaken macOS security to fix it.
- The first build under a new identity requires the user to grant Accessibility in System Settings. Only the user can grant it. The taskbar can be present even while access is denied.

## Native Dock

- macOS has a single native Dock, and there is no reliable public API here for assigning it to the monitor whose taskbar button was clicked. Do not promise per-monitor native Dock control.
- The rightmost button toggles the global Dock auto-hide setting using System Events; the former implementation restarted Dock on every click and caused visible flicker. macOS may ask for Automation permission.
- To suppress accidental edge reveals, the app temporarily sets the undocumented global `autohide-delay` to 1,000 seconds. On a normal quit, it restores the saved previous delay and makes the native Dock visible, restarting Dock once to apply the change. Preserve the backup and do not overwrite later user changes to the delay. A crash or force quit cannot run normal shutdown cleanup; reopen and quit normally to recover. For immediate recovery, `defaults write com.apple.dock autohide -bool false && killall Dock` makes the Dock visible.
- Dan confirmed the Dock toggle worked and the old process-restart implementation flickered. The newer System Events toggle and shutdown cleanup require interactive verification when changed; do not describe compilation alone as proof.

## Finder and taskbar behavior

- Finder icon view with **Sort By → Name** naturally reflows icons when resized and sorts newly added items. It is distinct from manually positioning icons with Snap to Grid; a custom reflow feature is unnecessary for this use case.
- `Sources/FinderExtension.swift` provides an `Open Terminal Here` Finder Sync extension for the background context menu. Finder extensions may require explicit enablement and may not appear for virtual or cloud-provider folders. Registration/build success is not proof the menu action works interactively.
- Taskbar windows are tracked per display through Accessibility. Minimized windows retain their last known display while the app is running; windows already minimized at startup may not have usable coordinates. An icon with multiple local windows offers a hover list. Clicking an active window's icon minimizes it; restoring returns it to its previous size, not necessarily maximized.
