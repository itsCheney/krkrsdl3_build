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
    // GPU->CPU readback attribution. Each pair reports cumulative bytes and
    // events for one source; the byte buckets sum to layerReadbackBytes.
    uint64_t layerReadbackLockBytes;
    uint64_t layerReadbackLockCount;
    uint64_t layerReadbackFallbackBytes;
    uint64_t layerReadbackFallbackCount;
    uint64_t layerReadbackPersistentBytes;
    uint64_t layerReadbackPersistentCount;
    uint64_t layerReadbackPixelsBytes;
    uint64_t layerReadbackPixelsCount;
    uint64_t layerReadbackDetachBytes;
    uint64_t layerReadbackDetachCount;
    uint64_t layerReadbackPointBytes;
    uint64_t layerReadbackPointCount;
    uint64_t layerPointCacheHits;
    uint64_t layerPointCacheMisses;

    // Software fallback attribution. Role counters only advance when that
    // operand caused a real GPU->CPU readback.
    uint64_t layerFallbackTargetReadbackBytes;
    uint64_t layerFallbackTargetReadbackCount;
    uint64_t layerFallbackSourceReadbackBytes;
    uint64_t layerFallbackSourceReadbackCount;
    uint64_t layerFallbackReferenceReadbackBytes;
    uint64_t layerFallbackReferenceReadbackCount;

    // Why Layer operations rejected the Metal path before using software.
    uint64_t layerGPURejectTargetUnavailable;
    uint64_t layerGPURejectTargetCPUResident;
    uint64_t layerGPURejectMultipleInputs;
    uint64_t layerGPURejectUnsupportedMethod;
    uint64_t layerGPURejectUnsupportedStretch;
    uint64_t layerGPURejectInvalidOpacity;
    uint64_t layerGPURejectSourceUnavailable;
    uint64_t layerGPURejectSourceFormat;
    uint64_t layerGPURejectInvalidGeometry;
    uint64_t layerGPURejectUnsupportedKind;
    uint64_t layerGPURejectAlphaTables;
    uint64_t layerGPURejectBackendFailure;
    uint64_t layerGPURejectTriangles;
    uint64_t layerGPURejectPerspective;

    // Top cumulative reject methods for the current Layer session. Comma-
    // separated "method:count" entries; multiple-input keys include [N].
    char layerMultipleInputMethods[512];
    char layerUnsupportedMethods[512];

    // D3DAdaptor captureCanvas bridge diagnostics.
    uint64_t emoteCaptureCalls;
    uint64_t emoteCaptureCPUFallbacks;
    uint64_t emoteCaptureCPUBytes;
    uint64_t emoteCaptureGPUCopies;
    uint64_t emoteCaptureGPUBytes;

    // M5 cumulative runtime profiling. Times are nanoseconds for lossless
    // interval differencing in the host heartbeat.
    uint64_t emoteProgressCalls;
    uint64_t emoteProgressTimeNS;
    uint64_t emotePrepareCalls;
    uint64_t emotePrepareTimeNS;
    uint64_t emoteDrawCalls;
    uint64_t emoteDrawTimeNS;
    uint64_t emoteCaptureProfileCalls;
    uint64_t emoteCaptureTimeNS;

    // M6.2 Emote prepare breakdown.
    uint64_t emotePrepareTransformTimeNS;
    uint64_t emotePrepareMotionProgressTimeNS;
    uint64_t emotePrepareSnapshotTimeNS;
    uint64_t emoteNodeProgressCalls;
    uint64_t emoteNodeProgressTimeNS;
    uint64_t emoteSubmotionCreates;
    uint64_t emoteSubmotionRebuildTimeNS;
    uint64_t emoteShapeBuildCalls;
    uint64_t emoteShapeBuildTimeNS;
    uint64_t emoteShapeVertices;
    uint64_t emoteMeshBuildCalls;
    uint64_t emoteMeshBuildTimeNS;
    uint64_t emoteMeshVerticesBuilt;
    uint64_t emoteDeformedVerticesBuilt;
    uint64_t emoteGPUDeformDraws;
    uint64_t emoteGPUDeformVertices;
    uint64_t emoteRenderSteps;
    uint64_t emotePlayerDraws;
    uint64_t emoteDistinctPlayerDraws;
    uint64_t emoteRepeatedPlayerDraws;
    uint64_t emoteDistinctTargets;
    uint64_t emoteMaxDrawsPerStep;
    uint64_t emoteMaxPlayersPerStep;
    uint64_t emoteMaxDrawsPerPlayerStep;

    uint64_t meshDrawCalls;
    uint64_t meshVertices;
    uint64_t meshIndices;
    uint64_t meshCPUTimeNS;
    uint64_t meshValidationTimeNS;
    uint64_t meshBufferAllocations;
    uint64_t meshBufferBytes;
    uint64_t meshBufferAllocationTimeNS;
    uint64_t metalSubmits;
    uint64_t metalSyncWaits;
    uint64_t metalSyncWaitTimeNS;
    uint64_t metalQueueWaitTimeNS;
    uint64_t metalRingBytes;
    uint64_t metalRingSuballocs;
    uint64_t metalRingSuballocTimeNS;
    uint64_t metalRingWraps;
    uint64_t metalRingStallTimeNS;
    uint64_t metalRingHighWaterBytes;
    uint64_t metalRingFallbackAllocations;
    uint64_t metalRingFallbackBytes;
    uint64_t stepEventTimeNS;
    uint64_t stepIterateTimeNS;
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
