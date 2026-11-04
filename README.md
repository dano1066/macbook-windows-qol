# Windows QoL for macOS

A native Mac utility for bringing familiar Windows-style desktop features to macOS. Its first feature is a taskbar on each connected display.

## First version

- The primary display has pinned apps (Finder and Safari to start) plus apps with windows on that display.
- Other displays show their own pinned apps and apps with windows on that display. Moving a window updates the bars, usually within a second.
- Windows that fill almost the full height of a display are resized above its taskbar after a drag or maximize. This uses Accessibility and is a best-effort adjustment: full-screen Spaces, apps that do not allow resizing, and windows that do not match the full-height layout may still overlap the bar.
- Double-click a window title bar to fill the usable display above the taskbar; double-click again to restore its previous frame. If a window was already maximized before the app saw it, the first restore uses a centered smaller size. This includes Finder and requires Accessibility access; apps with custom title bars may not expose a compatible target.
- Apps with multiple windows on a display show a stacked icon. Hover or click it to open a horizontal window chooser, then click the preview of the window to focus or restore. Previews use Screen Recording permission when available; minimized or unavailable windows use the app icon. A single-window icon minimizes its focused window or restores and focuses it. A blue line means the app has windows on this display: a bold line means at least one is visible, a dim, thin line means all are minimized, and a brighter line marks the focused app. Restoring a window returns it to its previous size rather than maximizing it to fill the screen.
- Pinned apps remain on their taskbar even without local windows (and then have no blue line). Right-click an app icon to pin or unpin it: secondary taskbars offer both the primary and current taskbar, while the primary taskbar offers only the primary option. Drag pinned icons to reorder them on that taskbar. Secondary pins are stored by display identifier and are separate from the primary taskbar's pins. Clicking Finder with no local window creates a Finder window and attempts to place it on that display. For other pinned apps with windows only on other displays, the chooser lets you explicitly select a remote window rather than switching displays immediately; behavior can vary by app.
- To pin an app, right-click its taskbar icon or bring it to the front and use **Settings… → Taskbar → Pin last used app**. Resetting pins restores the defaults.
- Terminal, System Settings and Trash have simple quick-launch icons on the right side of every taskbar. Trash opens in Finder; open Terminal and System Settings windows appear with other running apps on the left.
- **Settings… → Shortcuts** controls the Windows-style Fn shortcuts: Fn-C/V/X copy, paste and cut; Fn-A selects all; Fn-Z/Y undo and redo; Fn-F finds; Fn-E opens a new Finder window; Fn-S copies the display under the pointer to the clipboard; and Fn-Shift-S starts an area screenshot copied to the clipboard. These use Accessibility; screenshots and opening Finder may also require Screen Recording and Automation permissions. Fn-C and Fn-A replace macOS's Control Centre and Dock shortcuts while enabled. macOS, secure input fields, applications or particular keyboards may intercept shortcuts before the app receives them.
- The button at the far right of each taskbar toggles the Apple Dock's **automatically hide and show** setting without restarting the Dock. macOS may ask for permission to control System Events the first time you use it. This is a system-wide setting, not a separate Dock for each monitor. When auto-hide is on, moving the pointer to the Dock's edge can still reveal it; clicking the button again makes it always visible. The setting remains in effect after quitting this app.

On startup, the app hides the Dock and sets its edge reveal delay to 1,000 seconds, so accidental edge reveals are unlikely. On a normal quit, it restores the previous delay and shows the Dock; the Dock briefly restarts. If the app crashes or is force-quit, that cleanup cannot run; relaunch and quit normally to restore it. If needed, `defaults write com.apple.dock autohide -bool false && killall Dock` makes the Dock visible immediately. **Reload Windows QoL** in the Windows QoL menu-bar menu quits and reopens the app, so the Dock briefly reappears before it is hidden again.

The bundled Finder extension adds **Open Terminal Here** to the context menu when right-clicking empty space in a folder or a single folder itself. After opening the app, enable the Finder extension under System Settings → General → Login Items & Extensions → Finder if needed. It may not appear in every location, such as virtual or cloud-provider folders. Finder may need to be restarted after updating the extension.

## Build and run

Requires macOS and Apple's Command Line Tools (`xcode-select --install`); full Xcode is not required.

```sh
./scripts/build.sh
open 'build/Windows QoL.app'
```

Choose **Settings…** from the Windows QoL menu-bar menu to check Accessibility and screen-capture access and request them when needed. macOS may require quitting and reopening the app after granting access. Without Accessibility, the primary bar can launch pinned apps, but window tracking, focusing and Fn shortcuts will not work. Fn-S requests screen-capture access to copy the current display. macOS controls the permission lists; if an app entry does not appear, use the + button in the relevant System Settings pane to add the app manually.

In **Settings… → General**, choose **Enable** to open Windows QoL when you log in, or **Disable** to stop opening it automatically. This control requires macOS 13 or later and macOS may ask you to approve the item in Login Items & Extensions. If you previously added a separate login item manually, remove that item in System Settings to avoid a duplicate.

Quit from the Windows QoL menu-bar menu. If the hidden Apple Dock reappears over the bar, you can also move the Dock to the left or right in System Settings → Desktop & Dock.

## Current limitations

This is an early prototype. Window detection uses Accessibility and depends on what each application exposes. The app assigns windows to the display containing the largest portion and remembers the last display for a window minimized while the app is running. Windows already minimized at startup depend on their reported position, which may not be available or reliable. Hidden apps are omitted. Windows in other Spaces and full-screen apps may behave differently; the taskbar can overlap content and does not reserve desktop space. Some app windows, unusual dialogs, and apps without bundle identifiers may not appear. A crowded bar clips icons rather than scrolling. **Reset pinned apps** restores the default pinned apps. This app uses an ad-hoc local signature with a stable identifier-based requirement, not a developer identity; macOS may still require Accessibility permission to be re-added after rebuilds.
