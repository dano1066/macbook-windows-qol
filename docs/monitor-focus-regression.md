# Monitor-entry focus regression

The monitor-entry path passes the exact Quartz window ID verified under the
pointer to a window-specific SkyLight focus request, then posts key-window focus
events for that ID. It verifies that the AX window has the same ID and PID before
sending anything. It does not raise the AX window, set AXFocusedWindow, call the
shared taskbar focus helper, or schedule remote-window restoration.

The previous public `SetFrontProcessWithOptions(kSetFrontProcessFrontWindowOnly)`
implementation was reported ineffective by Dan. Its isolated call-order tests
could not verify actual Firefox stacking behavior. The replacement follows
[yabai's window focus sequence](https://github.com/asmvik/yabai/blob/master/src/window_manager.c)
(MIT; license in `docs/licenses/yabai-LICENSE.txt`). These private APIs are resolved
at runtime; unavailable APIs or mismatched identities stop without app-wide fallback.

Run the isolated activation checks (they do not change real windows):

```sh
clang -Wall -Wextra -Werror tests/WindowActivationTests.c -framework ApplicationServices -o /tmp/windows-qol-window-activation-tests
/tmp/windows-qol-window-activation-tests
```

The checks cover window ID and PID verification, exact focus event contents,
same-app key-window handoff, unavailable APIs, and process/event failures.

`tests/MonitorFocusLive.swift` is a separate test entry point compiled after the
production declarations in place of the final app entry point. It must run from
the normally signed build app to reuse its Accessibility identity. It uses two
existing Firefox windows on different displays and a temporary ordinary window to
cover the remote Firefox window, calls the production monitor-focus helper, then
checks the target's focused AX window, the frontmost PID, remote stacking, window
frames and minimized state after 800 ms. It closes its cover and requests the
previous window's focus afterward. It writes `build/monitor-focus-live.json`.
An optional last command-line argument selects a target Quartz window ID. Always
rebuild and reopen the normal app after this test; the test executable exits.
This check changes focus temporarily and should only run during active debugging.

## Live result, 9 November 2026

The replacement passed the live Firefox check in both display directions on Dan's
Mac: the requested Firefox window became focused, Firefox became the frontmost
app, the cover stayed above the other Firefox window, both Firefox frames stayed
unchanged, and the remote window stayed unminimized. These checks exercised the
production activation helper directly; physical monitor-entry movement and other
apps remain interactive checks. The normal app was rebuilt after the probe. Dan then confirmed that physical
monitor-entry movement worked correctly and authorized pushing the fix.

## Interactive verification

With “Activate windows when moving between monitors” enabled:

1. Put Firefox window A on one display and Firefox window B on the other. Cover
   B with another app and leave A visible. Move the pointer from that app's
   display into A. A should receive keyboard input; B must remain behind the
   covering app, with its size and minimized state unchanged. Wait at least a
   second to check for delayed changes.
2. Repeat in the opposite direction and with the covered Firefox window minimized.
3. Leave both Firefox windows visible. Alternate entering each display and check
   that typing or a harmless shortcut goes to the window on the entered display.
4. Repeat with a different multi-window app, such as Terminal or Finder.
5. Cross displays during a drag, through the taskbar/menu bar, and onto desktop
   space. These actions should not activate an unrelated window. Moving over an
   exposed background window should still wait for the display's frontmost window.
6. Check the existing taskbar click/preview focus and minimize behavior separately.

Native full-screen Spaces and applications that reject Accessibility raise/focus
requests need separate verification; a successful build does not establish those
behaviors.
