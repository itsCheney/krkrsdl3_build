#include "MikageKRKRRuntime.h"

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>

#include <SDL3/SDL.h>
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include <string>
#include <exception>
#include <cstring>
#include <vector>
#include <atomic>
#include <mutex>
#include <cstdio>
#include <cstdlib>
#include "TVPCompositor.h"
#include "WindowManager.h"
#include "MetalLayerRenderManager.h"

namespace {
std::atomic<MikageKRKRLogCallback> diagnosticCallback{nullptr};
std::mutex logOutputMutex;
std::mutex skippedMoviesMutex;
std::string skippedMovies;
thread_local bool mirroringKRKRLog = false;
SDL_LogOutputFunction previousLogOutput = nullptr;
void *previousLogContext = nullptr;

void diagnosticSDLOutput(void *, int category, SDL_LogPriority priority, const char *message)
{
    auto callback = diagnosticCallback.load(std::memory_order_acquire);
    if (callback && !mirroringKRKRLog) {
        char source[32];
        std::snprintf(source, sizeof(source), "SDL.%d", category);
        callback(source, static_cast<int32_t>(priority), message ? message : "");
    }
    SDL_LogOutputFunction output;
    void *context;
    {
        std::lock_guard<std::mutex> lock(logOutputMutex);
        output = previousLogOutput;
        context = previousLogContext;
    }
    if (output && output != diagnosticSDLOutput)
        output(context, category, priority, message);
}
}

// Defined in the core with C++ linkage.
void TVPSetSkippedMovies(const char *names);

extern "C" void MikageKRKRLogMessage(const char *source, int32_t level, const char *message)
{
    if (auto callback = diagnosticCallback.load(std::memory_order_acquire))
        callback(source, level, message ? message : "");
}

extern "C" void MikageKRKRSetSkippedMovies(const char *newlineSeparatedNames)
{
    {
        std::lock_guard<std::mutex> lock(skippedMoviesMutex);
        skippedMovies = newlineSeparatedNames ? newlineSeparatedNames : "";
    }
    // Applied immediately when a session is already running, and re-applied by
    // MikageKRKRStart so a configuration set before launch is not lost.
    TVPSetSkippedMovies(newlineSeparatedNames);
}

extern "C" void MikageKRKRSetLogCallback(MikageKRKRLogCallback callback)
{
    diagnosticCallback.store(callback, std::memory_order_release);
    SDL_SetHint("MIKAGE_METAL_DIAGNOSTICS", callback ? "1" : "0");
    SDL_LogOutputFunction current = nullptr;
    void *context = nullptr;
    SDL_GetLogOutputFunction(&current, &context);
    if (callback && current != diagnosticSDLOutput) {
        {
            std::lock_guard<std::mutex> lock(logOutputMutex);
            previousLogOutput = current;
            previousLogContext = context;
        }
        SDL_SetLogOutputFunction(diagnosticSDLOutput, nullptr);
    } else if (!callback && current == diagnosticSDLOutput) {
        SDL_LogOutputFunction previous;
        void *previousContext;
        {
            std::lock_guard<std::mutex> lock(logOutputMutex);
            previous = previousLogOutput;
            previousContext = previousLogContext;
        }
        SDL_SetLogOutputFunction(previous, previousContext);
    }
}

#include "TVPApplication.h"
#include "tjsError.h"

void MikageKRKRForwardLog(const ttstr &line)
{
    if (!diagnosticCallback.load(std::memory_order_acquire))
        return;
    try {
        const auto message = line.AsStdString();
        MikageKRKRLogMessage("KRKR", 3, message.c_str());
    } catch (...) {
        // Diagnostics must never introduce a new runtime exception.
    }
}

void MikageKRKRMirrorConsoleLog(const ttstr &line)
{
    // Preserve the engine's SDL console output without collecting the same
    // message twice (or bypassing the host's VM-dump privacy filter).
    struct Restore {
        bool previous;
        ~Restore() { mirroringKRKRLog = previous; }
    } restore{mirroringKRKRLog};
    mirroringKRKRLog = true;
    SDL_Log("%s", line.c_str());
}

extern void TVPSetAudioSuspended(bool suspended);
@interface MikageKRKRBundleMarker : NSObject
@end
@implementation MikageKRKRBundleMarker
@end

extern "C" NSString *MikageKRKRFrameworkResourcePath(void)
{
    return [[NSBundle bundleForClass:MikageKRKRBundleMarker.class] resourcePath];
}

extern "C" SDL_AppResult SDL_AppInit(void **appstate, int argc, char *argv[]);
extern "C" SDL_AppResult SDL_AppEvent(void *appstate, SDL_Event *event);
extern "C" SDL_AppResult SDL_AppIterate(void *appstate);
extern "C" void SDL_AppQuit(void *appstate, SDL_AppResult result);
extern tTVPApplication *Application;
extern "C" void TVPSetGameRunningOrientation(bool running);
extern "C" void MikageKRKRSetWindowScene(void *scene);
extern "C" void MikageKRKRSetMenuGestureEnabled(bool enabled);
extern "C" SDL_Window *MikageKRKRGetSDLWindow(void);
extern "C" const char *MikageKRKRGetActiveRendererName(void);

namespace {
bool running = false;
bool foreground = true;
bool stopRequested = false;
void *appState = nullptr;
std::string lastError;
MikageKRKRMenuCallback menuCallback = nullptr;
MikageKRKRCompletionCallback completionCallback = nullptr;
void *callbackContext = nullptr;
std::string activeRenderer;
Uint64 statsWindowStarted = 0;
Uint64 previousFrameAt = 0;
Uint64 frameIntervalTotal = 0;
Uint64 frameCount = 0;
double currentFPS = 0;
double currentFrameTimeMS = 0;
Uint64 frameWorkTotal = 0, frameWorkMax = 0;
double currentCpuFrameTimeMS = 0, currentMaxCpuFrameTimeMS = 0;
Uint64 stepEventTimeNS = 0, stepIterateTimeNS = 0;
constexpr Uint64 nanosecondsPerSecond = 1000000000ULL;
constexpr Uint64 slowFrameThresholdNS = 50000000ULL;
Uint64 slowFrameCount = 0;
Uint64 peakFrameEventTimeNS = 0, peakFrameIterateTimeNS = 0;
Uint64 peakFrameEventCount = 0;

void resetStats()
{
    statsWindowStarted = SDL_GetTicksNS();
    previousFrameAt = 0;
    frameIntervalTotal = 0;
    frameCount = 0;
    currentFPS = 0;
    currentFrameTimeMS = 0;
    frameWorkTotal = frameWorkMax = 0;
    currentCpuFrameTimeMS = currentMaxCpuFrameTimeMS = 0;
    stepEventTimeNS = stepIterateTimeNS = 0;
    slowFrameCount = 0;
    peakFrameEventTimeNS = peakFrameIterateTimeNS = peakFrameEventCount = 0;
}

void recordFrame(Uint64 presentedAt, Uint64 workDuration,
                 Uint64 eventDuration, Uint64 iterateDuration, Uint64 eventCount)
{
    if (!statsWindowStarted)
        statsWindowStarted = presentedAt;
    if (previousFrameAt)
        frameIntervalTotal += presentedAt - previousFrameAt;
    previousFrameAt = presentedAt;
    frameCount++;
    frameWorkTotal += workDuration;
    if (workDuration >= slowFrameThresholdNS) ++slowFrameCount;
    if (workDuration > frameWorkMax) {
        frameWorkMax = workDuration;
        peakFrameEventTimeNS = eventDuration;
        peakFrameIterateTimeNS = iterateDuration;
        peakFrameEventCount = eventCount;
    }
    Uint64 elapsed = presentedAt - statsWindowStarted;
    if (elapsed >= nanosecondsPerSecond)
    {
        currentFPS =
            static_cast<double>(frameCount) * nanosecondsPerSecond / elapsed;
        if (frameCount > 1)
            currentFrameTimeMS =
                static_cast<double>(frameIntervalTotal) / (frameCount - 1) / 1000000.0;
        currentCpuFrameTimeMS = static_cast<double>(frameWorkTotal) / frameCount / 1000000.0;
        currentMaxCpuFrameTimeMS = static_cast<double>(frameWorkMax) / 1000000.0;
        if (slowFrameCount) {
            // At most one summary per stats window. These are wall durations,
            // including GPU waits, and all peak fields describe the same step.
            char message[256];
            std::snprintf(message, sizeof(message),
                "runtime.slowFrames count=%llu peakWallMS=%.3f peakEventMS=%.3f "
                "peakIterateMS=%.3f peakEvents=%llu",
                static_cast<unsigned long long>(slowFrameCount), currentMaxCpuFrameTimeMS,
                static_cast<double>(peakFrameEventTimeNS) / 1000000.0,
                static_cast<double>(peakFrameIterateTimeNS) / 1000000.0,
                static_cast<unsigned long long>(peakFrameEventCount));
            MikageKRKRLogMessage("performance", 3, message);
        }
        frameWorkTotal = frameWorkMax = 0;
        slowFrameCount = 0;
        peakFrameEventTimeNS = peakFrameIterateTimeNS = peakFrameEventCount = 0;
        statsWindowStarted = presentedAt;
        previousFrameAt = 0;
        frameIntervalTotal = 0;
        frameCount = 0;
    }
}

void resetAfterStartFailure(const std::string &message)
{
    MikageKRKRLogMessage("bridge", 5, message.c_str());
    TVPSetAudioSuspended(true);
    if (appState) {
        try {
            SDL_AppQuit(appState, SDL_APP_FAILURE);
        } catch (...) {
            // A partially initialized runtime must not throw across the C boundary.
        }
    }
    TVPSetGameRunningOrientation(false);
    MikageKRKRSetWindowScene(nullptr);
    running = false;
    foreground = true;
    stopRequested = false;
    appState = nullptr;
    menuCallback = nullptr;
    completionCallback = nullptr;
    callbackContext = nullptr;
    activeRenderer.clear();
    resetStats();
    lastError = message.empty() ? "KRKR initialization failed." : message;
}

void finish(SDL_AppResult result, const char *message)
{
    MikageKRKRLogMessage("bridge", 3, "runtime.finish.begin");
    if (message && *message)
        MikageKRKRLogMessage("bridge", 5, message);
    if (!running && !appState)
        return;

    try {
        TVPSetAudioSuspended(true);
        SDL_AppQuit(appState, result);
    } catch (const eTJS &error) {
        result = SDL_APP_FAILURE;
        lastError = error.GetMessage().c_str();
    } catch (const std::exception &error) {
        result = SDL_APP_FAILURE;
        lastError = error.what() ? error.what() : "C++ exception during KRKR shutdown.";
    } catch (...) {
        result = SDL_APP_FAILURE;
        lastError = "Unknown C++ exception during KRKR shutdown.";
    }
    TVPSetGameRunningOrientation(false);
    MikageKRKRSetWindowScene(nullptr);
    [[AVAudioSession sharedInstance]
        setActive:NO
        withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
        error:nil];

    const bool success = result == SDL_APP_SUCCESS;
    if (!success && lastError.empty())
        lastError = message && *message ? message : SDL_GetError();

    running = false;
    foreground = true;
    stopRequested = false;
    appState = nullptr;

    auto callback = completionCallback;
    auto context = callbackContext;
    menuCallback = nullptr;
    completionCallback = nullptr;
    callbackContext = nullptr;
    activeRenderer.clear();
    resetStats();
    MikageKRKRLogMessage("bridge", success ? 3 : 5,
                         success ? "runtime.finish.success" : lastError.c_str());
    if (callback)
        callback(success, success ? nullptr : lastError.c_str(), context);
}

MikageKRKRStepResult finishForResult(SDL_AppResult result)
{
    if (result == SDL_APP_CONTINUE)
        return MIKAGE_KRKR_STEP_RUNNING;
    const char *message = result == SDL_APP_FAILURE ? SDL_GetError() : nullptr;
    finish(result, message);
    return result == SDL_APP_SUCCESS ? MIKAGE_KRKR_STEP_FINISHED : MIKAGE_KRKR_STEP_FAILED;
}
}

extern "C" bool MikageKRKRStart(const char *gamePath,
                                  const char *renderer,
                                  void *uiWindowScene,
                                  bool menuGestureEnabled,
                                  bool respectSilentMode,
                                  MikageKRKRMenuCallback menu,
                                  MikageKRKRCompletionCallback completion,
                                  void *context)
{
    if (running) {
        lastError = "A KRKR session is already running.";
        return false;
    }
    if (!gamePath || !*gamePath) {
        lastError = "The KRKR game path is empty.";
        return false;
    }

    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:gamePath];
        BOOL isDirectory = NO;
        if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) {
            lastError = "The KRKR game path does not exist.";
            return false;
        }

        std::string normalizedPath(gamePath);
        if (isDirectory && normalizedPath.back() != '/')
            normalizedPath.push_back('/');

        try {
            MikageKRKRSetLogCallback(diagnosticCallback.load(std::memory_order_acquire));
            // SDL defaults to playback on iOS, which ignores the Ring/Silent
            // switch. The host preference chooses normal game-style ambient
            // behavior or SDL's playback behavior before any audio device opens.
            SDL_SetHintWithPriority(
                SDL_HINT_AUDIO_CATEGORY,
                respectSilentMode ? "ambient" : "playback",
                SDL_HINT_OVERRIDE
            );
            MikageKRKRLogMessage(
                "audio",
                3,
                respectSilentMode ? "category.ambient" : "category.playback"
            );
            SDL_SetMainReady();
            MikageKRKRSetWindowScene(uiWindowScene);
            MikageKRKRSetMenuGestureEnabled(menuGestureEnabled);
            TVPSetGameRunningOrientation(true);
            // Re-applied per session: core state is reset between games.
            {
                std::lock_guard<std::mutex> lock(skippedMoviesMutex);
                TVPSetSkippedMovies(skippedMovies.empty() ? nullptr : skippedMovies.c_str());
            }

            std::vector<std::string> arguments;
            arguments.emplace_back("MikageNext");
            arguments.emplace_back(normalizedPath);
            if (diagnosticCallback.load(std::memory_order_acquire))
                arguments.emplace_back("-forcelog=yes");
            if (renderer && *renderer)
                arguments.emplace_back(std::string("-render=") + renderer);

            std::vector<char *> argv;
            argv.reserve(arguments.size());
            for (auto &argument : arguments)
                argv.push_back(argument.data());

            menuCallback = menu;
            completionCallback = completion;
            callbackContext = context;
            lastError.clear();
            activeRenderer = renderer && *renderer ? renderer : "metal";
            stopRequested = false;
            resetStats();
            // Capture diagnostics are session-scoped, just like Layer stats.
            // Do not let a previous game make GPU-copy/fallback counts ambiguous.
            krkrsdl3::TVPResetEmoteCaptureStats();
            krkrsdl3::TVPResetRuntimeProfileStats();
            appState = nullptr;

            SDL_AppResult result = SDL_AppInit(
                &appState,
                static_cast<int>(argv.size()),
                argv.data()
            );
            const char *actualRenderer = MikageKRKRGetActiveRendererName();
            if (actualRenderer && *actualRenderer)
                activeRenderer = actualRenderer;
            MikageKRKRLogMessage("bridge", 3, activeRenderer.c_str());
            if (result != SDL_APP_CONTINUE) {
                running = true;
                finish(result, SDL_GetError());
                return false;
            }
            NSError *audioError = nil;
            [[AVAudioSession sharedInstance] setActive:YES error:&audioError];
            if (audioError) {
                lastError = audioError.localizedDescription.UTF8String;
                TVPSetAudioSuspended(true);
            } else {
                TVPSetAudioSuspended(false);
            }
        } catch (const eTJS &error) {
            resetAfterStartFailure(std::string(error.GetMessage().c_str()));
            return false;
        } catch (const std::exception &error) {
            resetAfterStartFailure(error.what() ? error.what() : "C++ exception during KRKR startup.");
            return false;
        } catch (...) {
            resetAfterStartFailure("Unknown C++ exception during KRKR startup.");
            return false;
        }
    }

    running = true;
    foreground = true;
    resetStats(); // Exclude startup/shader compilation from the first gameplay window.
    return true;
}

extern "C" MikageKRKRStepResult MikageKRKRStep(void)
{
    if (!running)
        return MIKAGE_KRKR_STEP_IDLE;

    try {
        const Uint64 frameStarted = SDL_GetTicksNS();
        const Uint64 eventsStarted = frameStarted;
        Uint64 eventCount = 0;
        SDL_Event event;
        while (SDL_PollEvent(&event)) {
            ++eventCount;
            SDL_AppResult result = SDL_AppEvent(appState, &event);
            if (result != SDL_APP_CONTINUE)
                return finishForResult(result);
        }
        const Uint64 eventDuration = SDL_GetTicksNS() - eventsStarted;
        stepEventTimeNS += eventDuration;

        if (stopRequested)
            return finishForResult(SDL_APP_SUCCESS);

        if (!foreground)
            return MIKAGE_KRKR_STEP_RUNNING;

        const Uint64 iterateStarted = SDL_GetTicksNS();
        krkrsdl3::TVPBeginRuntimeStep();
        SDL_AppResult result = SDL_AppIterate(appState);
        krkrsdl3::TVPEndRuntimeStep();
        const Uint64 frameFinished = SDL_GetTicksNS();
        const Uint64 iterateDuration = frameFinished - iterateStarted;
        stepIterateTimeNS += iterateDuration;
        if (result == SDL_APP_CONTINUE) {
            recordFrame(frameFinished, frameFinished - frameStarted,
                        eventDuration, iterateDuration, eventCount);
        }
        return finishForResult(result);
    } catch (const eTJS &error) {
        std::string message(error.GetMessage().c_str());
        finish(SDL_APP_FAILURE, message.c_str());
    } catch (const std::exception &error) {
        finish(SDL_APP_FAILURE, error.what());
    } catch (...) {
        finish(SDL_APP_FAILURE, "Unknown C++ exception while stepping KRKR.");
    }
    return MIKAGE_KRKR_STEP_FAILED;
}

extern "C" bool MikageKRKRRequestExit(void)
{
    if (!running || !foreground || !TVPMainWindow)
        return false;
    try {
        MikageKRKRLogMessage("bridge", 3, "runtime.userClose.requested");
        TVPMainWindow->RequestUserClose();
        return true;
    } catch (const eTJS &error) {
        lastError = error.GetMessage().c_str();
    } catch (const std::exception &error) {
        lastError = error.what() ? error.what() : "KRKR close-query failed.";
    } catch (...) {
        lastError = "Unknown exception requesting KRKR close-query.";
    }
    MikageKRKRLogMessage("bridge", 5, lastError.c_str());
    return false;
}

extern "C" void MikageKRKRRequestStop(void)
{
    try {
        if (running) {
            stopRequested = true;
            if (Application)
                Application->Terminate();
        }
    } catch (...) {
        finish(SDL_APP_FAILURE, "C++ exception while stopping KRKR.");
    }
}

extern "C" bool MikageKRKRSetForeground(bool value)
{
    MikageKRKRLogMessage("audio", 3, value ? "foreground.resume.requested" : "foreground.suspend.requested");
    try {
        if (foreground == value)
            return true;
        if (!value) {
            foreground = false;
            if (Application)
                Application->NotifyActiveEvent(eTVPActiveEvent::onDeactive);
            TVPSetAudioSuspended(true);
            NSError *error = nil;
            [[AVAudioSession sharedInstance]
                setActive:NO
                withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                error:&error];
            if (error)
                lastError = error.localizedDescription.UTF8String;
            else
                lastError.clear();
            MikageKRKRLogMessage("audio", error ? 5 : 3,
                                 error ? lastError.c_str() : "foreground.suspended");
            return error == nil;
        }

        NSError *error = nil;
        [[AVAudioSession sharedInstance] setActive:YES error:&error];
        if (error) {
            lastError = error.localizedDescription.UTF8String;
            MikageKRKRLogMessage("audio", 5, lastError.c_str());
            return false;
        }
        TVPSetAudioSuspended(false);
        if (Application)
            Application->NotifyActiveEvent(eTVPActiveEvent::onActive);
        foreground = value;
        resetStats(); // Background time is not a gameplay frame interval.
        lastError.clear();
        MikageKRKRLogMessage("audio", 3, "foreground.resumed");
        return true;
    } catch (const eTJS &error) {
        lastError = error.GetMessage().c_str();
    } catch (const std::exception &error) {
        lastError = error.what() ? error.what() : "C++ exception while changing KRKR foreground state.";
    } catch (...) {
        lastError = "Unknown C++ exception while changing KRKR foreground state.";
    }
    TVPSetAudioSuspended(true);
    foreground = false;
    MikageKRKRLogMessage("audio", 5, lastError.c_str());
    return false;
}

extern "C" bool MikageKRKRGetStats(MikageKRKRStats *stats)
{
    if (!running || !stats)
        return false;
    std::memset(stats, 0, sizeof(*stats));
    stats->framesPerSecond = currentFPS;
    stats->frameTimeMilliseconds = currentFrameTimeMS;
    stats->cpuFrameTimeMilliseconds = currentCpuFrameTimeMS;
    stats->maxCpuFrameTimeMilliseconds = currentMaxCpuFrameTimeMS;
    auto* backend = krkrsdl3::TVPGetRenderBackend();
    stats->gpuSubmissionTimeMilliseconds = backend ? backend->GetGpuSubmissionTimeMilliseconds() : -1.0;
    stats->presentationWaitTimeMilliseconds = backend ? backend->GetPresentationWaitTimeMilliseconds() : -1.0;
    auto layers = TVPGetMetalLayerRenderStats();
    stats->gpuLayerComposition = TVPMetalLayerCompositionActive() ? 1 : 0;
    stats->gpuLayerOperations = layers.gpuOperations;
    stats->layerCPUFallbacks = layers.cpuFallbacks;
    stats->layerUploadedBytes = layers.uploadedBytes;
    stats->layerReadbackBytes = layers.readbackBytes;
    stats->layerGPUResidentBytes = layers.gpuResidentBytes;
    stats->layerCPUCacheBytes = layers.cpuCacheBytes;
    stats->layerPinnedCPUTextures = layers.pinnedCPUTextures;
    const auto readbackIndex = [](TVPLayerReadbackSource source) {
        return static_cast<int>(source);
    };
    stats->layerReadbackLockBytes =
        layers.readbackBytesBySource[readbackIndex(TVPLayerReadbackSource::Lock)];
    stats->layerReadbackLockCount =
        layers.readbackCountBySource[readbackIndex(TVPLayerReadbackSource::Lock)];
    stats->layerReadbackFallbackBytes =
        layers.readbackBytesBySource[readbackIndex(TVPLayerReadbackSource::Fallback)];
    stats->layerReadbackFallbackCount =
        layers.readbackCountBySource[readbackIndex(TVPLayerReadbackSource::Fallback)];
    stats->layerReadbackPersistentBytes =
        layers.readbackBytesBySource[readbackIndex(TVPLayerReadbackSource::Persistent)];
    stats->layerReadbackPersistentCount =
        layers.readbackCountBySource[readbackIndex(TVPLayerReadbackSource::Persistent)];
    stats->layerReadbackPixelsBytes =
        layers.readbackBytesBySource[readbackIndex(TVPLayerReadbackSource::Pixels)];
    stats->layerReadbackPixelsCount =
        layers.readbackCountBySource[readbackIndex(TVPLayerReadbackSource::Pixels)];
    stats->layerReadbackDetachBytes =
        layers.readbackBytesBySource[readbackIndex(TVPLayerReadbackSource::Detach)];
    stats->layerReadbackDetachCount =
        layers.readbackCountBySource[readbackIndex(TVPLayerReadbackSource::Detach)];
    stats->layerReadbackPointBytes =
        layers.readbackBytesBySource[readbackIndex(TVPLayerReadbackSource::Point)];
    stats->layerReadbackPointCount =
        layers.readbackCountBySource[readbackIndex(TVPLayerReadbackSource::Point)];
    stats->layerPointCacheHits = layers.pointCacheHits;
    stats->layerPointCacheMisses = layers.pointCacheMisses;

    const auto fallbackRoleIndex = [](TVPLayerFallbackReadbackRole role) {
        return static_cast<int>(role);
    };
    stats->layerFallbackTargetReadbackBytes =
        layers.fallbackReadbackBytesByRole[fallbackRoleIndex(TVPLayerFallbackReadbackRole::Target)];
    stats->layerFallbackTargetReadbackCount =
        layers.fallbackReadbackCountByRole[fallbackRoleIndex(TVPLayerFallbackReadbackRole::Target)];
    stats->layerFallbackSourceReadbackBytes =
        layers.fallbackReadbackBytesByRole[fallbackRoleIndex(TVPLayerFallbackReadbackRole::Source)];
    stats->layerFallbackSourceReadbackCount =
        layers.fallbackReadbackCountByRole[fallbackRoleIndex(TVPLayerFallbackReadbackRole::Source)];
    stats->layerFallbackReferenceReadbackBytes =
        layers.fallbackReadbackBytesByRole[fallbackRoleIndex(TVPLayerFallbackReadbackRole::Reference)];
    stats->layerFallbackReferenceReadbackCount =
        layers.fallbackReadbackCountByRole[fallbackRoleIndex(TVPLayerFallbackReadbackRole::Reference)];

    const auto rejectIndex = [](TVPLayerGPURejectReason reason) {
        return static_cast<int>(reason);
    };
    stats->layerGPURejectTargetUnavailable =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::TargetUnavailable)];
    stats->layerGPURejectTargetCPUResident =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::TargetCPUResident)];
    stats->layerGPURejectMultipleInputs =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::MultipleInputs)];
    stats->layerGPURejectUnsupportedMethod =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::UnsupportedMethod)];
    stats->layerGPURejectUnsupportedStretch =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::UnsupportedStretch)];
    stats->layerGPURejectInvalidOpacity =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::InvalidOpacity)];
    stats->layerGPURejectSourceUnavailable =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::SourceUnavailable)];
    stats->layerGPURejectSourceFormat =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::SourceFormat)];
    stats->layerGPURejectInvalidGeometry =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::InvalidGeometry)];
    stats->layerGPURejectUnsupportedKind =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::UnsupportedKind)];
    stats->layerGPURejectAlphaTables =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::AlphaTables)];
    stats->layerGPURejectBackendFailure =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::BackendFailure)];
    stats->layerGPURejectTriangles =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::Triangles)];
    stats->layerGPURejectPerspective =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::Perspective)];

    const auto multipleInputMethods = TVPGetMetalLayerMultipleInputMethodSummary();
    const auto unsupportedMethods = TVPGetMetalLayerUnsupportedMethodSummary();
    std::strncpy(stats->layerMultipleInputMethods, multipleInputMethods.c_str(),
                 sizeof(stats->layerMultipleInputMethods) - 1);
    std::strncpy(stats->layerUnsupportedMethods, unsupportedMethods.c_str(),
                 sizeof(stats->layerUnsupportedMethods) - 1);

    const auto emoteCapture = krkrsdl3::TVPGetEmoteCaptureStats();
    stats->emoteCaptureCalls = emoteCapture.calls;
    stats->emoteCaptureCPUFallbacks = emoteCapture.cpuFallbacks;
    stats->emoteCaptureCPUBytes = emoteCapture.cpuBytes;
    stats->emoteCaptureGPUCopies = emoteCapture.gpuCopies;
    stats->emoteCaptureGPUBytes = emoteCapture.gpuBytes;

    const auto profile = krkrsdl3::TVPGetRuntimeProfileStats();
    stats->emoteProgressCalls = profile.emoteProgressCalls;
    stats->emoteProgressTimeNS = profile.emoteProgressTimeNS;
    stats->emotePrepareCalls = profile.emotePrepareCalls;
    stats->emotePrepareTimeNS = profile.emotePrepareTimeNS;
    stats->emoteDrawCalls = profile.emoteDrawCalls;
    stats->emoteDrawTimeNS = profile.emoteDrawTimeNS;
    stats->emoteCaptureProfileCalls = profile.emoteCaptureProfileCalls;
    stats->emoteCaptureTimeNS = profile.emoteCaptureTimeNS;
    stats->emotePrepareTransformTimeNS = profile.emotePrepareTransformTimeNS;
    stats->emotePrepareMotionProgressTimeNS = profile.emotePrepareMotionProgressTimeNS;
    stats->emotePrepareSnapshotTimeNS = profile.emotePrepareSnapshotTimeNS;
    stats->emoteNodeProgressCalls = profile.emoteNodeProgressCalls;
    stats->emoteNodeProgressTimeNS = profile.emoteNodeProgressTimeNS;
    stats->emoteSubmotionCreates = profile.emoteSubmotionCreates;
    stats->emoteSubmotionRebuildTimeNS = profile.emoteSubmotionRebuildTimeNS;
    stats->emoteShapeBuildCalls = profile.emoteShapeBuildCalls;
    stats->emoteShapeBuildTimeNS = profile.emoteShapeBuildTimeNS;
    stats->emoteShapeVertices = profile.emoteShapeVertices;
    stats->emoteMeshBuildCalls = profile.emoteMeshBuildCalls;
    stats->emoteMeshBuildTimeNS = profile.emoteMeshBuildTimeNS;
    stats->emoteMeshVerticesBuilt = profile.emoteMeshVerticesBuilt;
    stats->emoteDeformedVerticesBuilt = profile.emoteDeformedVerticesBuilt;
    stats->emoteGPUDeformDraws = profile.emoteGPUDeformDraws;
    stats->emoteGPUDeformVertices = profile.emoteGPUDeformVertices;
    stats->emoteRenderSteps = profile.emoteRenderSteps;
    stats->emotePlayerDraws = profile.emotePlayerDraws;
    stats->emoteDistinctPlayerDraws = profile.emoteDistinctPlayerDraws;
    stats->emoteRepeatedPlayerDraws = profile.emoteRepeatedPlayerDraws;
    stats->emoteDistinctTargets = profile.emoteDistinctTargets;
    stats->emoteMaxDrawsPerStep = profile.emoteMaxDrawsPerStep;
    stats->emoteMaxPlayersPerStep = profile.emoteMaxPlayersPerStep;
    stats->emoteMaxDrawsPerPlayerStep = profile.emoteMaxDrawsPerPlayerStep;
    stats->meshDrawCalls = profile.meshDrawCalls;
    stats->meshVertices = profile.meshVertices;
    stats->meshIndices = profile.meshIndices;
    stats->meshCPUTimeNS = profile.meshCPUTimeNS;
    stats->meshValidationTimeNS = profile.meshValidationTimeNS;
    stats->meshBufferAllocations = profile.meshBufferAllocations;
    stats->meshBufferBytes = profile.meshBufferBytes;
    stats->meshBufferAllocationTimeNS = profile.meshBufferAllocationTimeNS;
    stats->metalSubmits = profile.metalSubmits;
    stats->metalSyncWaits = profile.metalSyncWaits;
    stats->metalSyncWaitTimeNS = profile.metalSyncWaitTimeNS;
    stats->metalQueueWaitTimeNS = profile.metalQueueWaitTimeNS;
    stats->metalRingBytes = profile.metalRingBytes;
    stats->metalRingSuballocs = profile.metalRingSuballocs;
    stats->metalRingSuballocTimeNS = profile.metalRingSuballocTimeNS;
    stats->metalRingWraps = profile.metalRingWraps;
    stats->metalRingStallTimeNS = profile.metalRingStallTimeNS;
    stats->metalRingHighWaterBytes = profile.metalRingHighWaterBytes;
    stats->metalRingFallbackAllocations = profile.metalRingFallbackAllocations;
    stats->metalRingFallbackBytes = profile.metalRingFallbackBytes;
    stats->stepEventTimeNS = stepEventTimeNS;
    stats->stepIterateTimeNS = stepIterateTimeNS;
    stats->metalRenderEncoders = profile.metalRenderEncoders;
    stats->metalComputeEncoders = profile.metalComputeEncoders;
    stats->metalBlitEncoders = profile.metalBlitEncoders;
    stats->metalLayerRectSnapshots = profile.metalLayerRectSnapshots;
    stats->metalLayerRectSnapshotBytes = profile.metalLayerRectSnapshotBytes;
    stats->metalSurfaceUploadBytes = profile.metalSurfaceUploadBytes;
    stats->emoteMaskClears = profile.emoteMaskClears;
    stats->emoteMaskDraws = profile.emoteMaskDraws;
    stats->emoteUniqueMaskGroups = profile.emoteUniqueMaskGroups;
    stats->emoteLayerGPUCopies = profile.emoteLayerGPUCopies;
    stats->emoteLayerGPUCopyBytes = profile.emoteLayerGPUCopyBytes;
    stats->emoteLayerCPUReadbacks = profile.emoteLayerCPUReadbacks;
    stats->emoteLayerCPUReadbackBytes = profile.emoteLayerCPUReadbackBytes;
    stats->emoteLayerCPUReadbackTimeNS = profile.emoteLayerCPUReadbackTimeNS;

    if (SDL_Window *window = MikageKRKRGetSDLWindow()) {
        int width = 0, height = 0;
        SDL_GetWindowSizeInPixels(window, &width, &height);
        stats->drawableWidth = width;
        stats->drawableHeight = height;
    }
    std::strncpy(stats->renderer, activeRenderer.c_str(), sizeof(stats->renderer) - 1);
    return true;
}

extern "C" bool MikageKRKRIsRunning(void)
{
    return running;
}

extern "C" const char *MikageKRKRLastError(void)
{
    return lastError.c_str();
}

extern "C" void *MikageKRKRNativeWindow(void)
{
    SDL_Window *window = MikageKRKRGetSDLWindow();
    if (!window)
        return nullptr;
    return SDL_GetPointerProperty(SDL_GetWindowProperties(window),
                                  SDL_PROP_WINDOW_UIKIT_WINDOW_POINTER,
                                  nullptr);
}

extern "C" void MikageKRKRNotifyMenu(void)
{
    if (menuCallback)
        menuCallback(callbackContext);
}

extern "C" bool MikageKRKRCaptureFrame(MikageKRKRCapturedFrame *frame)
{
    if (!frame || frame->pixels || !running || !foreground || ![NSThread isMainThread])
        return false;
    *frame = {};
    @autoreleasepool {
        try {
            auto *backend = krkrsdl3::TVPGetRenderBackend();
            std::vector<uint8_t> pixels;
            int width = 0, height = 0, pitch = 0;
            if (!backend || !backend->CaptureFrame(pixels, width, height, pitch))
                return false;
            auto *copy = static_cast<uint8_t *>(std::malloc(pixels.size()));
            if (!copy) return false;
            std::memcpy(copy, pixels.data(), pixels.size());
            frame->pixels = copy;
            frame->width = width;
            frame->height = height;
            frame->pitch = pitch;
            return true;
        } catch (const std::exception &error) {
            SDL_Log("Native screenshot failed: %s", error.what());
            return false;
        }
    }
}

extern "C" void MikageKRKRFreeCapturedFrame(MikageKRKRCapturedFrame *frame)
{
    if (!frame) return;
    std::free(frame->pixels);
    *frame = {};
}
