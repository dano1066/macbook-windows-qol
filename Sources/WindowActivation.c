#include "WindowActivation.h"
#include <dlfcn.h>
#include <pthread.h>
#include <string.h>
#include <unistd.h>

// Window-specific focus event sequence adapted from yabai (MIT):
// https://github.com/asmvik/yabai/blob/master/src/window_manager.c
// Copyright (c) 2019 Åsmund Vikane. See docs/licenses/yabai-LICENSE.txt.
// Unlike SetFrontProcessWithOptions, SkyLight accepts the target window ID.
// Resolve private APIs at runtime and never fall back to process-wide activation.
typedef CGError (*SetFrontWindow)(ProcessSerialNumber *, uint32_t, uint32_t);
typedef CGError (*PostFocusEvent)(ProcessSerialNumber *, uint8_t *);
typedef AXError (*GetWindowID)(AXUIElementRef, CGWindowID *);
static SetFrontWindow setFrontWindow;
static PostFocusEvent postFocusEvent;
static GetWindowID getWindowID;

#ifndef WINDOW_ACTIVATION_TESTING
static pthread_once_t loadOnce = PTHREAD_ONCE_INIT;
static void loadFocusAPI(void) {
    // Keep handles open for the lifetime of the resolved function pointers.
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    void *ax = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY | RTLD_LOCAL);
    if (sky) {
        setFrontWindow = (SetFrontWindow)dlsym(sky, "_SLPSSetFrontProcessWithOptions");
        postFocusEvent = (PostFocusEvent)dlsym(sky, "SLPSPostEventRecordTo");
    }
    if (ax) getWindowID = (GetWindowID)dlsym(ax, "_AXUIElementGetWindow");
}
#endif

AXError WindowsQoLGetWindowID(AXUIElementRef window, CGWindowID *windowID) {
#ifndef WINDOW_ACTIVATION_TESTING
    pthread_once(&loadOnce, loadFocusAPI);
#endif
    *windowID = kCGNullWindowID;
    if (!getWindowID) return kAXErrorNotImplemented;
    return getWindowID(window, windowID);
}

static CGError selectKeyWindow(ProcessSerialNumber *process, CGWindowID windowID) {
    uint8_t event[0xf8] = {0};
    event[0x04] = 0xf8;
    event[0x3a] = 0x10;
    memcpy(event + 0x3c, &windowID, sizeof(windowID));
    memset(event + 0x20, 0xff, 0x10);
    event[0x08] = 0x01;
    CGError status = postFocusEvent(process, event);
    if (status != kCGErrorSuccess) return status;
    event[0x08] = 0x02;
    return postFocusEvent(process, event);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
OSStatus WindowsQoLActivateWindowOnly(pid_t pid, AXUIElementRef window, CGWindowID windowID) {
#ifndef WINDOW_ACTIVATION_TESTING
    pthread_once(&loadOnce, loadFocusAPI);
#endif
    if (!setFrontWindow || !postFocusEvent || !getWindowID) return unimpErr;
    if (windowID == kCGNullWindowID) return paramErr;
    CGWindowID actualID = kCGNullWindowID;
    AXError axStatus = getWindowID(window, &actualID);
    if (axStatus != kAXErrorSuccess) return (OSStatus)axStatus;
    if (actualID != windowID) return paramErr;
    pid_t actualPID = 0;
    axStatus = AXUIElementGetPid(window, &actualPID);
    if (axStatus != kAXErrorSuccess) return (OSStatus)axStatus;
    if (actualPID != pid) return paramErr;

    ProcessSerialNumber process = {0, 0}, front = {0, 0};
    OSStatus status = GetProcessForPID(pid, &process);
    if (status != noErr) return status;
    status = GetFrontProcess(&front);
    if (status != noErr) return status;

    // Switching key windows inside the active process needs an explicit handoff.
    if (front.highLongOfPSN == process.highLongOfPSN && front.lowLongOfPSN == process.lowLongOfPSN) {
        AXUIElementRef app = AXUIElementCreateApplication(pid);
        CFTypeRef focused = NULL;
        axStatus = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &focused);
        CFRelease(app);
        CGWindowID previousID = kCGNullWindowID;
        if (axStatus != kAXErrorSuccess || !focused) {
            if (focused) CFRelease(focused);
            return (OSStatus)kAXErrorCannotComplete;
        }
        axStatus = getWindowID((AXUIElementRef)focused, &previousID);
        CFRelease(focused);
        if (axStatus != kAXErrorSuccess) return (OSStatus)axStatus;
        if (previousID == kCGNullWindowID) return (OSStatus)kAXErrorCannotComplete;
        if (previousID == windowID) return noErr;
        uint8_t event[0xf8] = {0};
        event[0x04] = 0xf8;
        event[0x08] = 0x0d;
        event[0x8a] = 0x02;
        memcpy(event + 0x3c, &previousID, sizeof(previousID));
        status = postFocusEvent(&process, event);
        if (status != noErr) return status;
        // Some apps discard the key-window transition if both events are immediate.
        usleep(40000);
        event[0x8a] = 0x01;
        memcpy(event + 0x3c, &windowID, sizeof(windowID));
        status = postFocusEvent(&process, event);
        if (status != noErr) return status;
    }
    status = setFrontWindow(&process, windowID, 0x200 /* kCPSUserGenerated */);
    if (status != noErr) return status;
    return selectKeyWindow(&process, windowID);
}
#pragma clang diagnostic pop
