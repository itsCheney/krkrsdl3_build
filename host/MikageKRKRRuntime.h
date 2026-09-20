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
    // Last completed GPU submission, excluding queue wait; -1 if unavailable.
    double gpuSubmissionTimeMilliseconds;
    // Last frame's command-capacity + drawable wait; part of main-thread time.
    double presentationWaitTimeMilliseconds;
    // Cumulative counters for the current Layer session (not Emote meshes).
    uint64_t gpuLayerComposition;
    uint64_t gpuLayerOperations;
    uint64_t layerCPUFallbacks;
    uint64_t layerUploadedBytes;
    uint64_t layerReadbackBytes;
    uint64_t layerGPUResidentBytes;
    uint64_t layerCPUCacheBytes;
    uint64_t layerPinnedCPUTextures;
} MikageKRKRStats;

bool MikageKRKRStart(const char *gamePath,
                     const char *renderer,
                     void *uiWindowScene,
                     bool menuGestureEnabled,
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

// On-demand native GPU screenshot. Call on the main thread with a zeroed frame.
// Top-down straight-alpha RGBA8; no CPU copy is retained between captures.
// On success the caller owns pixels and must release it using FreeCapturedFrame.
typedef struct MikageKRKRCapturedFrame {
    uint8_t *pixels;
    int32_t width;
    int32_t height;
    int32_t pitch;
} MikageKRKRCapturedFrame;
bool MikageKRKRCaptureFrame(MikageKRKRCapturedFrame *frame);
void MikageKRKRFreeCapturedFrame(MikageKRKRCapturedFrame *frame);

#ifdef __cplusplus
}
#endif
