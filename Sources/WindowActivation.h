#ifndef WINDOWS_QOL_WINDOW_ACTIVATION_H
#define WINDOWS_QOL_WINDOW_ACTIVATION_H

#include <ApplicationServices/ApplicationServices.h>

// Request focus for a verified window ID without raising sibling windows.
OSStatus WindowsQoLActivateWindowOnly(pid_t pid, AXUIElementRef _Nonnull window, CGWindowID windowID);
// Read the AX window's identity, including while it is minimized/off screen.
AXError WindowsQoLGetWindowID(AXUIElementRef _Nonnull window, CGWindowID * _Nonnull windowID);

#endif
