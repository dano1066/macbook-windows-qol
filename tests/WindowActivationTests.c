#include <ApplicationServices/ApplicationServices.h>
#include <assert.h>
#include <stdio.h>
#include <string.h>

static int activationCalls, eventCalls;
static OSStatus lookupResult, activationResult, eventResult;
static AXError windowResult;
static CGWindowID actualID = 99;
static pid_t actualPID = 42;
static bool sameProcess, differentKeyWindow;
static AXUIElementRef expectedWindow, previousWindow;
static uint8_t events[4][0xf8];
static OSStatus lookup(pid_t pid, ProcessSerialNumber *process) {
    assert(pid == 42);
    process->lowLongOfPSN = 123;
    return lookupResult;
}
static OSStatus frontProcess(ProcessSerialNumber *process) {
    process->lowLongOfPSN = sameProcess ? 123 : 456;
    return noErr;
}
static AXError windowNumber(AXUIElementRef window, CGWindowID *number) {
    assert(window == expectedWindow || window == previousWindow);
    *number = window == previousWindow ? 77 : actualID;
    return windowResult;
}
static AXError windowPID(AXUIElementRef window, pid_t *pid) {
    assert(window == expectedWindow);
    *pid = actualPID;
    return kAXErrorSuccess;
}
static AXError focusedWindow(AXUIElementRef app, CFStringRef name, CFTypeRef *value) {
    (void)app;
    assert(CFEqual(name, kAXFocusedWindowAttribute));
    *value = CFRetain(differentKeyWindow ? previousWindow : expectedWindow);
    return kAXErrorSuccess;
}
static CGError activate(ProcessSerialNumber *process, uint32_t windowID, uint32_t options) {
    assert(process->lowLongOfPSN == 123);
    assert(windowID == 99);
    assert(options == 0x200);
    assert(eventCalls == (differentKeyWindow ? 2 : 0));
    activationCalls++;
    return activationResult;
}
static CGError postEvent(ProcessSerialNumber *process, uint8_t *event) {
    assert(process->lowLongOfPSN == 123);
    assert(activationCalls == ((differentKeyWindow && eventCalls < 2) ? 0 : 1));
    assert(eventCalls < 4);
    memcpy(events[eventCalls++], event, 0xf8);
    return eventResult;
}
#define WINDOW_ACTIVATION_TESTING
#define GetProcessForPID lookup
#define GetFrontProcess frontProcess
#define AXUIElementGetPid windowPID
#define AXUIElementCopyAttributeValue focusedWindow
#include "../Sources/WindowActivation.c"

static void reset(void) {
    activationCalls = eventCalls = 0;
    lookupResult = activationResult = eventResult = noErr;
    windowResult = kAXErrorSuccess;
    actualID = 99; actualPID = 42; sameProcess = differentKeyWindow = false;
    setFrontWindow = activate; postFocusEvent = postEvent; getWindowID = windowNumber;
}
static void noChanges(void) { assert(activationCalls == 0 && eventCalls == 0); }
int main(void) {
    expectedWindow = AXUIElementCreateApplication(42);
    previousWindow = AXUIElementCreateApplication(44);
    reset();
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == noErr);
    assert(activationCalls == 1 && eventCalls == 2);
    for (int i = 0; i < 2; i++) {
        CGWindowID number = 0;
        memcpy(&number, events[i] + 0x3c, sizeof(number));
        assert(number == 99 && events[i][0x04] == 0xf8);
        assert(events[i][0x08] == i + 1 && events[i][0x3a] == 0x10);
        for (int j = 0x20; j < 0x30; j++) assert(events[i][j] == 0xff);
    }
    reset(); setFrontWindow = NULL;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == unimpErr); noChanges();
    reset();
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 0) == paramErr); noChanges();
    reset(); actualID = 100;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == paramErr); noChanges();
    reset(); actualPID = 43;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == paramErr); noChanges();
    reset(); windowResult = kAXErrorCannotComplete;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == kAXErrorCannotComplete); noChanges();
    reset(); lookupResult = procNotFound;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == procNotFound); noChanges();
    reset(); activationResult = kCGErrorFailure;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == kCGErrorFailure);
    assert(activationCalls == 1 && eventCalls == 0);
    reset(); eventResult = kCGErrorFailure;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == kCGErrorFailure);
    assert(activationCalls == 1 && eventCalls == 1);
    reset(); sameProcess = true;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == noErr); noChanges();
    reset(); sameProcess = differentKeyWindow = true;
    assert(WindowsQoLActivateWindowOnly(42, expectedWindow, 99) == noErr);
    assert(activationCalls == 1 && eventCalls == 4);
    assert(events[0][0x08] == 0x0d && events[0][0x8a] == 0x02);
    assert(events[1][0x08] == 0x0d && events[1][0x8a] == 0x01);
    for (int i = 0; i < 4; i++) {
        CGWindowID number = 0;
        memcpy(&number, events[i] + 0x3c, sizeof(number));
        assert(number == (i == 0 ? 77 : 99));
    }
    CFRelease(expectedWindow);
    CFRelease(previousWindow);
    puts("Window activation tests passed (11 cases).");
}
