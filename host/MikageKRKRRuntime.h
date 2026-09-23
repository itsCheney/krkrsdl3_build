#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum MikageKRKRStepResult {
    MIKAGE_KRKR_STEP_IDLE = 0,
    MIKAGE_KRKR_STEP_RUNNING = 1,
    MIKAGE_KRKR_STEP_FINISHED = 2,
    MIKAGE_KRKR_STEP_FAILED = 3
} MikageKRKRStepResult;

typedef void (*MikageKRKRMenuCallback)(void *context);
typedef void (*MikageKRKRCompletionCallback)(bool success, const char *message, void *context);
typedef void (*MikageKRKRLogCallback)(const char *source, int32_t level, const char *message);

// Strings are borrowed for the duration of the callback; copy before returning.
// May be called on runtime worker threads. NULL disables host log collection.
void MikageKRKRSetLogCallback(MikageKRKRLogCallback callback);

// Movie file names to skip, separated by newlines; NULL or empty clears the
// list. Matching uses the base name only and ignores case, so directories and
// a `?` parameter suffix may be included. A skipped movie reports normal
// end-of-playback immediately, which lets a waiting script continue.
// The string is copied. Call before MikageKRKRStart; it does not affect a
// movie that is already playing.
void MikageKRKRSetSkippedMovies(const char *newlineSeparatedNames);

typedef struct MikageKRKRStats {
    double framesPerSecond;
    double frameTimeMilliseconds;
    int32_t drawableWidth;
    int32_t drawableHeight;
    char renderer[32];
    // frameTimeMilliseconds above remains the average frame interval.
    // Main-thread step wall time (includes script/decode and any GPU waits).
    double cpuFrameTimeMilliseconds;
    double maxCpuFrameTimeMilliseconds;
} MikageKRKRStats;

bool MikageKRKRStart(const char *gamePath,
                     const char *renderer,
                     void *uiWindowScene,
                     bool menuGestureEnabled,
                     bool respectSilentMode,
                     MikageKRKRMenuCallback menuCallback,
                     MikageKRKRCompletionCallback completionCallback,
                     void *context);
MikageKRKRStepResult MikageKRKRStep(void);
// Request KRKR's normal main-window close query; game may confirm or cancel.
// No forced termination and no foreground suspension while it is pending.
bool MikageKRKRRequestExit(void);
// Forced host stop for interrupted startup/host lifecycle cleanup.
void MikageKRKRRequestStop(void);
bool MikageKRKRSetForeground(bool foreground);
bool MikageKRKRGetStats(MikageKRKRStats *stats);
bool MikageKRKRIsRunning(void);
const char *MikageKRKRLastError(void);
void *MikageKRKRNativeWindow(void);

#ifdef __cplusplus
}
#endif
