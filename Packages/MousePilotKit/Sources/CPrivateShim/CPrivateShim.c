// CPrivateShim.c
// MousePilot — runtime resolution of the one SkyLight symbol we need, plus mach time helpers.

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
