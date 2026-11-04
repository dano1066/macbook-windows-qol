# Windows QoL for macOS

A native Mac utility for bringing familiar Windows-style desktop features to macOS. Its first feature is a taskbar on each connected display.

## First version

- The primary display has pinned apps (Finder and Safari to start) plus apps with windows on that display.
- Other displays show apps with windows on that display. Moving a window updates the bars, usually within a second.
- Hover over an icon with multiple windows on that display to see their titles and click a specific window. Clicking the icon minimizes its focused window; clicking a single-window icon again restores or focuses the window. For multiple windows, clicking an inactive app opens the window list. Click a pinned app without a local window to open or activate it. Restoring a window returns it to its previous size rather than maximizing it to fill the screen.
- To pin an app, bring it to the front, then choose **Pin frontmost app to primary bar** from the ▣ menu in the Mac menu bar. Resetting pins restores the defaults.
- Terminal, System Settings and Trash have dedicated icons on the right side of every taskbar. Trash opens in Finder; Terminal and System Settings also show their local windows like other app icons.
- The button at the far right of each taskbar toggles the Apple Dock's **automatically hide and show** setting without restarting the Dock. macOS may ask for permission to control System Events the first time you use it. This is a system-wide setting, not a separate Dock for each monitor. When auto-hide is on, moving the pointer to the Dock's edge can still reveal it; clicking the button again makes it always visible. The setting remains in effect after quitting this app.

On startup, the app hides the Dock and sets its edge reveal delay to 1,000 seconds, so accidental edge reveals are unlikely. On a normal quit, it restores the previous delay and shows the Dock; the Dock briefly restarts. If the app crashes or is force-quit, that cleanup cannot run; relaunch and quit normally to restore it. If needed, `defaults write com.apple.dock autohide -bool false && killall Dock` makes the Dock visible immediately. **Reload Windows QoL** in the ▣ menu quits and reopens the app, so the Dock briefly reappears before it is hidden again.

The bundled Finder extension adds **Open Terminal Here** to the context menu when right-clicking empty space in a folder or a single folder itself. After opening the app, enable the Finder extension under System Settings → General → Login Items & Extensions → Finder if needed. It may not appear in every location, such as virtual or cloud-provider folders. Finder may need to be restarted after updating the extension.

## Build and run

Requires macOS and Apple's Command Line Tools (`xcode-select --install`); full Xcode is not required.

```sh
./scripts/build.sh
open 'build/Windows QoL.app'
```

Choose **Enable Accessibility access…** from the ▣ menu, then enable Windows QoL in System Settings → Privacy & Security → Accessibility. macOS may require quitting and reopening the app after granting access. Without permission the primary bar can launch pinned apps, but window tracking and focusing will not work. The app does not request screen recording access.

Quit from the ▣ menu. The app does not start automatically. If the hidden Apple Dock reappears over the bar, you can also move the Dock to the left or right in System Settings → Desktop & Dock.

## Current limitations

This is an early prototype. Window detection uses Accessibility and depends on what each application exposes. The app assigns windows to the display containing the largest portion and remembers the last display for a window minimized while the app is running. Windows already minimized at startup depend on their reported position, which may not be available or reliable. Hidden apps are omitted. Windows in other Spaces and full-screen apps may behave differently; the taskbar can overlap content and does not reserve desktop space. Some app windows, unusual dialogs, and apps without bundle identifiers may not appear. A crowded bar clips icons rather than scrolling. No per-app unpin UI or launch-at-login yet; **Reset pinned apps** clears additions. This app uses an ad-hoc local signature with a stable identifier-based requirement, not a developer identity; macOS may still require Accessibility permission to be re-added after rebuilds.
