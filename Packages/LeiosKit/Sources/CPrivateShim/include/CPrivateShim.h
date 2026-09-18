// CPrivateShim.h
// Leios — declarations for private-but-exported macOS APIs used by the engine.
//
// Everything here is either exported by a public framework (IOKit, CoreGraphics)
// but undocumented, or resolved at runtime with dlsym (SkyLight).
// Derived from Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix), MMF License.

#ifndef CPrivateShim_h
#define CPrivateShim_h

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// MARK: - IOHIDEvent (IOKit, exported but undocumented)

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef uint32_t IOHIDEventType;
typedef uint32_t IOHIDEventField;
typedef double   IOHIDFloat;
typedef uint32_t IOHIDEventOptionBits;
typedef uint16_t IOHIDEventPhaseBits;

// Values copied from Apple's open-source IOHIDEventTypes.h (via mac-mouse-fix Shared/IOKit/External).
enum {
    kIOHIDEventTypeNULL              = 0,
    kIOHIDEventTypeRotation          = 5,
    kIOHIDEventTypeScroll            = 6,
    kIOHIDEventTypeZoom              = 8,
    kIOHIDEventTypeVelocity          = 9,
    kIOHIDEventTypeNavigationSwipe   = 16,
    kIOHIDEventTypeZoomToggle        = 22,
    kIOHIDEventTypeDockSwipe         = 23,
};

// Positional values from Apple's IOHIDEventTypes.h, where this is an implicit enum starting at
// kIOHIDGestureFlavorNone = 0. Dock swipes carry DockPrimary; a real trackpad gesture sends 3, and
// the Dock silently ignores a DockSwipe event that carries any other flavor.
enum {
    kIOHIDGestureFlavorNone                        = 0,
    kIOHIDGestureFlavorNotificationCenterPrimary   = 1,
    kIOHIDGestureFlavorNotificationCenterSecondary = 2,
    kIOHIDGestureFlavorDockPrimary                 = 3,
    kIOHIDGestureFlavorDockSecondary               = 4,
};

enum {
    kIOHIDEventPhaseUndefined        = 0,
    kIOHIDEventPhaseBegan            = 1 << 0,
    kIOHIDEventPhaseChanged          = 1 << 1,
    kIOHIDEventPhaseEnded            = 1 << 2,
    kIOHIDEventPhaseCancelled        = 1 << 3,
    kIOHIDEventPhaseMayBegin         = 1 << 7,
    kIOHIDEventEventPhaseMask        = 0xFF,
    kIOHIDEventEventOptionPhaseShift = 24,
};

enum {
    kIOHIDSwipeNone   = 0,
    kIOHIDSwipeUp     = 1 << 0,
    kIOHIDSwipeDown   = 1 << 1,
    kIOHIDSwipeLeft   = 1 << 2,
    kIOHIDSwipeRight  = 1 << 3,
};

enum {
    kIOHIDGestureMotionHorizontalX = 1,
    kIOHIDGestureMotionVerticalY   = 2,
    kIOHIDGestureMotionScale       = 3,
};

#define LeiosIOHIDEventFieldBase(type) ((type) << 16)

enum {
    kIOHIDEventFieldDockSwipeMask     = LeiosIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 0,
    kIOHIDEventFieldDockSwipeMotion   = LeiosIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 1,
    kIOHIDEventFieldDockSwipeProgress = LeiosIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 2,
    kIOHIDEventFieldDockSwipeFlavor   = LeiosIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 5,
    kIOHIDEventFieldVelocityX         = LeiosIOHIDEventFieldBase(kIOHIDEventTypeVelocity) | 0,
    kIOHIDEventFieldVelocityY         = LeiosIOHIDEventFieldBase(kIOHIDEventTypeVelocity) | 1,
    kIOHIDEventFieldVelocityZ         = LeiosIOHIDEventFieldBase(kIOHIDEventTypeVelocity) | 2,
};

extern IOHIDEventRef IOHIDEventCreate(CFAllocatorRef allocator, IOHIDEventType type, uint64_t timeStamp, IOOptionBits options);
extern void IOHIDEventSetIntegerValue(IOHIDEventRef event, IOHIDEventField field, CFIndex value);
extern void IOHIDEventSetFloatValue(IOHIDEventRef event, IOHIDEventField field, IOHIDFloat value);
extern void IOHIDEventAppendEvent(IOHIDEventRef event, IOHIDEventRef childEvent, IOOptionBits options);
extern void IOHIDEventSetSenderID(IOHIDEventRef event, uint64_t senderID);
extern uint64_t IOHIDEventGetSenderID(IOHIDEventRef event);
extern void IOHIDEventSetPhase(IOHIDEventRef event, IOHIDEventPhaseBits phase);
extern void IOHIDEventSetEventFlags(IOHIDEventRef event, IOOptionBits flags);
extern IOOptionBits IOHIDEventGetEventFlags(IOHIDEventRef event);
extern CFStringRef IOHIDEventCopyDescription(IOHIDEventRef event);

/// CoreGraphics: extract the IOHIDEvent wrapped by a CGEvent (returns +1 retained, or NULL).
extern IOHIDEventRef CGEventCopyIOHIDEvent(CGEventRef event);

/// CFRelease for IOHIDEventRef (which Swift imports as an opaque pointer).
void LeiosIOHIDEventRelease(IOHIDEventRef event);

/// SkyLight `SLEventSetIOHIDEvent`, resolved at runtime with dlsym. Returns false if unavailable.
bool LeiosEventSetIOHIDEvent(CGEventRef cgEvent, IOHIDEventRef hidEvent);
/// True if SLEventSetIOHIDEvent could be resolved.
bool LeiosEventSetIOHIDEventIsAvailable(void);

// MARK: - CoreGraphics Services (exported by CoreGraphics.tbd)

typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CGSConnectionID _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(CGSConnectionID cid, CGSConnectionID targetCID, CFStringRef key, CFTypeRef value);

typedef enum {
    kCGSSpaceIncludesCurrent = 1 << 0,
    kCGSSpaceIncludesOthers  = 1 << 1,
    kCGSSpaceIncludesUser    = 1 << 2,
} LeiosCGSSpaceMask;
extern CFArrayRef CGSCopySpaces(CGSConnectionID cid, int mask);

typedef int CGSSymbolicHotKey;
typedef unsigned int CGSModifierFlags;
enum {
    kCGSNumericPadKeyMask = 1 << 21,
    kCGSFunctionKeyMask   = 1 << 23,
};
extern bool    CGSIsSymbolicHotKeyEnabled(CGSSymbolicHotKey hotKey);
extern CGError CGSSetSymbolicHotKeyEnabled(CGSSymbolicHotKey hotKey, bool isEnabled);
extern CGError CGSGetSymbolicHotKeyValue(CGSSymbolicHotKey hotKey, uint16_t *outKeyEquivalent, uint16_t *outVirtualKeyCode, CGSModifierFlags *outModifiers);
extern CGError CGSSetSymbolicHotKeyValue(CGSSymbolicHotKey hotKey, uint16_t keyEquivalent, uint16_t virtualKeyCode, CGSModifierFlags modifiers);

// MARK: - SkyLight window hit testing

/// pid of the app owning the frontmost window at `point`, when that window is at level 0 (a normal
/// app window, as opposed to a menu, panel, Dock tile or wallpaper).
///
/// `point` is in the CG global display coordinate space — top-left origin, the same space
/// `CGEventGetLocation` returns, *not* AppKit's bottom-left `NSEvent.mouseLocation`.
///
/// Answers the same question as walking `CGWindowListCopyWindowInfo`, but without copying the whole
/// window list: one hit test in the WindowServer instead of every window's metadata.
///
/// Returns false when SkyLight is unavailable, when no window covers the point, or when the topmost
/// window there is not at level 0. A false return means "no answer", not "no app" — callers fall
/// back to the window list rather than treating it as nil.
bool LeiosPidOfWindowAtPoint(CGPoint point, pid_t *outPid);

/// True if every SkyLight symbol `LeiosPidOfWindowAtPoint` needs could be resolved.
bool LeiosWindowAtPointIsAvailable(void);

// MARK: - Misc helpers

/// Convert a mach absolute time (e.g. CGEventGetTimestamp) to seconds.
double LeiosMachTimeToSeconds(uint64_t machTime);
/// mach_absolute_time()
uint64_t LeiosMachAbsoluteTime(void);

#ifdef __cplusplus
}
#endif

#endif /* CPrivateShim_h */
