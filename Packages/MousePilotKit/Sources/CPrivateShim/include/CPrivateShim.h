// CPrivateShim.h
// MousePilot — declarations for private-but-exported macOS APIs used by the engine.
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

enum {
    kIOHIDGestureFlavorDockPrimary   = 31,
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

#define MPIOHIDEventFieldBase(type) ((type) << 16)

enum {
    kIOHIDEventFieldDockSwipeMask     = MPIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 0,
    kIOHIDEventFieldDockSwipeMotion   = MPIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 1,
    kIOHIDEventFieldDockSwipeProgress = MPIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 2,
    kIOHIDEventFieldDockSwipeFlavor   = MPIOHIDEventFieldBase(kIOHIDEventTypeDockSwipe) | 5,
    kIOHIDEventFieldVelocityX         = MPIOHIDEventFieldBase(kIOHIDEventTypeVelocity) | 0,
    kIOHIDEventFieldVelocityY         = MPIOHIDEventFieldBase(kIOHIDEventTypeVelocity) | 1,
    kIOHIDEventFieldVelocityZ         = MPIOHIDEventFieldBase(kIOHIDEventTypeVelocity) | 2,
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
void MPIOHIDEventRelease(IOHIDEventRef event);

/// SkyLight `SLEventSetIOHIDEvent`, resolved at runtime with dlsym. Returns false if unavailable.
bool MPEventSetIOHIDEvent(CGEventRef cgEvent, IOHIDEventRef hidEvent);
/// True if SLEventSetIOHIDEvent could be resolved.
bool MPEventSetIOHIDEventIsAvailable(void);

// MARK: - CoreGraphics Services (exported by CoreGraphics.tbd)

typedef int CGSConnectionID;
extern CGSConnectionID CGSMainConnectionID(void);
extern CGSConnectionID _CGSDefaultConnection(void);
extern CGError CGSSetConnectionProperty(CGSConnectionID cid, CGSConnectionID targetCID, CFStringRef key, CFTypeRef value);

typedef enum {
    kCGSSpaceIncludesCurrent = 1 << 0,
    kCGSSpaceIncludesOthers  = 1 << 1,
    kCGSSpaceIncludesUser    = 1 << 2,
} MPCGSSpaceMask;
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

// MARK: - Misc helpers

/// Convert a mach absolute time (e.g. CGEventGetTimestamp) to seconds.
double MPMachTimeToSeconds(uint64_t machTime);
/// mach_absolute_time()
uint64_t MPMachAbsoluteTime(void);

#ifdef __cplusplus
}
#endif

#endif /* CPrivateShim_h */
