// CPrivateShim.c
// MousePilot — runtime resolution of the SkyLight symbols we need, plus mach time helpers.

#include "CPrivateShim.h"
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <pthread.h>

typedef void (*MPSLEventSetIOHIDEventFn)(CGEventRef, IOHIDEventRef);

static MPSLEventSetIOHIDEventFn _slEventSetIOHIDEvent = NULL;
static pthread_once_t _slOnce = PTHREAD_ONCE_INIT;

static void _resolveSLEventSetIOHIDEvent(void) {
    void *sym = dlsym(RTLD_DEFAULT, "SLEventSetIOHIDEvent");
    if (sym == NULL) {
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (handle != NULL) {
            sym = dlsym(handle, "SLEventSetIOHIDEvent");
        }
    }
    _slEventSetIOHIDEvent = (MPSLEventSetIOHIDEventFn)sym;
}

bool MPEventSetIOHIDEventIsAvailable(void) {
    pthread_once(&_slOnce, _resolveSLEventSetIOHIDEvent);
    return _slEventSetIOHIDEvent != NULL;
}

bool MPEventSetIOHIDEvent(CGEventRef cgEvent, IOHIDEventRef hidEvent) {
    pthread_once(&_slOnce, _resolveSLEventSetIOHIDEvent);
    if (_slEventSetIOHIDEvent == NULL || cgEvent == NULL || hidEvent == NULL) {
        return false;
    }
    _slEventSetIOHIDEvent(cgEvent, hidEvent);
    return true;
}

// MARK: - SkyLight window hit testing

typedef int MPSLSConnectionID;

typedef MPSLSConnectionID (*MPSLSMainConnectionIDFn)(void);
/// The three literal arguments are undocumented filter flags; (0, 1, 0) is the combination that
/// matches what the window list reports as the frontmost window at a point.
typedef CGError (*MPSLSFindWindowByGeometryFn)(MPSLSConnectionID cid, int zero, int one, int zero2,
                                               const CGPoint *point, CGPoint *outPointInWindow,
                                               uint32_t *outWindowID, MPSLSConnectionID *outWindowCID);
typedef CGError (*MPSLSGetWindowLevelFn)(MPSLSConnectionID cid, uint32_t wid, int32_t *outLevel);
typedef CGError (*MPSLSGetWindowOwnerFn)(MPSLSConnectionID cid, uint32_t wid, MPSLSConnectionID *outOwnerCID);
typedef CGError (*MPSLSConnectionGetPIDFn)(MPSLSConnectionID cid, pid_t *outPid);

static MPSLSFindWindowByGeometryFn _slsFindWindowByGeometry = NULL;
static MPSLSGetWindowLevelFn       _slsGetWindowLevel       = NULL;
static MPSLSGetWindowOwnerFn       _slsGetWindowOwner       = NULL;
static MPSLSConnectionGetPIDFn     _slsConnectionGetPID     = NULL;
static MPSLSConnectionID           _slsMainConnection       = 0;
static bool                        _slsWindowAtPointReady   = false;
static pthread_once_t              _slsWindowOnce           = PTHREAD_ONCE_INIT;

static void *_mpResolveSkyLight(const char *name) {
    void *sym = dlsym(RTLD_DEFAULT, name);
    if (sym == NULL) {
        void *handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
        if (handle != NULL) {
            sym = dlsym(handle, name);
        }
    }
    return sym;
}

static void _resolveWindowAtPoint(void) {
    MPSLSMainConnectionIDFn mainConnection = (MPSLSMainConnectionIDFn)_mpResolveSkyLight("SLSMainConnectionID");
    _slsFindWindowByGeometry = (MPSLSFindWindowByGeometryFn)_mpResolveSkyLight("SLSFindWindowByGeometry");
    _slsGetWindowLevel       = (MPSLSGetWindowLevelFn)_mpResolveSkyLight("SLSGetWindowLevel");
    _slsGetWindowOwner       = (MPSLSGetWindowOwnerFn)_mpResolveSkyLight("SLSGetWindowOwner");
    _slsConnectionGetPID     = (MPSLSConnectionGetPIDFn)_mpResolveSkyLight("SLSConnectionGetPID");

    if (mainConnection == NULL || _slsFindWindowByGeometry == NULL || _slsGetWindowLevel == NULL
        || _slsGetWindowOwner == NULL || _slsConnectionGetPID == NULL) {
        return;
    }
    _slsMainConnection = mainConnection();
    // A zero connection id means the process has no window server session, which every lookup
    // below would fail on anyway.
    _slsWindowAtPointReady = _slsMainConnection != 0;
}

bool MPWindowAtPointIsAvailable(void) {
    pthread_once(&_slsWindowOnce, _resolveWindowAtPoint);
    return _slsWindowAtPointReady;
}

bool MPPidOfWindowAtPoint(CGPoint point, pid_t *outPid) {
    pthread_once(&_slsWindowOnce, _resolveWindowAtPoint);
    if (!_slsWindowAtPointReady || outPid == NULL) return false;

    CGPoint pointInWindow = CGPointZero;
    uint32_t windowID = 0;
    MPSLSConnectionID windowCID = 0;
    if (_slsFindWindowByGeometry(_slsMainConnection, 0, 1, 0, &point, &pointInWindow, &windowID, &windowCID) != kCGErrorSuccess) {
        return false;
    }
    if (windowID == 0) return false;

    // Everything the window-list walk skipped with `layer == 0`: menus, panels, the Dock, wallpaper.
    int32_t level = 0;
    if (_slsGetWindowLevel(_slsMainConnection, windowID, &level) != kCGErrorSuccess) return false;
    if (level != 0) return false;

    MPSLSConnectionID ownerCID = 0;
    if (_slsGetWindowOwner(_slsMainConnection, windowID, &ownerCID) != kCGErrorSuccess) return false;

    pid_t pid = 0;
    if (_slsConnectionGetPID(ownerCID, &pid) != kCGErrorSuccess) return false;
    if (pid <= 0) return false;

    *outPid = pid;
    return true;
}

void MPIOHIDEventRelease(IOHIDEventRef event) {
    if (event != NULL) CFRelease((CFTypeRef)event);
}

static mach_timebase_info_data_t _timebase = {0, 0};
static pthread_once_t _timebaseOnce = PTHREAD_ONCE_INIT;
static void _initTimebase(void) { mach_timebase_info(&_timebase); }

double MPMachTimeToSeconds(uint64_t machTime) {
    pthread_once(&_timebaseOnce, _initTimebase);
    double nanos = (double)machTime * (double)_timebase.numer / (double)_timebase.denom;
    return nanos / 1.0e9;
}

uint64_t MPMachAbsoluteTime(void) {
    return mach_absolute_time();
}
