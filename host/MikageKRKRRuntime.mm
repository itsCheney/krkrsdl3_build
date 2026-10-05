#include "MikageKRKRRuntime.h"

#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#include <TargetConditionals.h>

#include <SDL3/SDL.h>
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include <string>
#include <exception>
#include <cstring>
#include <vector>
#include <atomic>
#include <algorithm>
#include <array>
#include <mutex>
#include <cstdio>
#include <cstdlib>
#include <stdexcept>
#include "TVPCompositor.h"
#include "WindowManager.h"
#include "MetalLayerRenderManager.h"
#include "PointReadTrace.h"
#include "LayerManager.h"
#include "../cpp/plugins/emoteplayer/emoteperformance.h"

namespace {
std::atomic<MikageKRKRLogCallback> diagnosticCallback{nullptr};
std::mutex logOutputMutex;
std::mutex skippedMoviesMutex;
std::string skippedMovies;
std::atomic<bool> experimentalEmote{false};
std::atomic<uint32_t> emotePerformanceOptions{0};
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
    krkrsdl3::point_trace::SetEnabled(callback != nullptr);
    TVPSetMetalLayerTriangleDiagnostics(callback != nullptr);
    krkrsdl3::layer_work::SetEnabled(callback != nullptr);
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

extern "C" void MikageKRKRSetExperimentalEmote(bool enabled)
{
    experimentalEmote.store(enabled, std::memory_order_relaxed);
}
extern "C" void MikageKRKRSetEmotePerformanceOptions(uint32_t flags)
{
    emotePerformanceOptions.store(flags & 127u, std::memory_order_relaxed);
}

static bool applyEmoteAnimationModeForStart()
{
    const bool enabled = experimentalEmote.load(std::memory_order_relaxed);
    if (!SDL_SetHintWithPriority("MIKAGE_EMOTE_ANIMATION_MODE",
        enabled ? "integrated" : "legacy", SDL_HINT_OVERRIDE)) return false;
    MikageKRKRLogMessage("emote", 3, enabled ? "animation.integrated" : "animation.legacy");
    const char* hints[] = {"MIKAGE_EMOTE_NODE_CACHE", "MIKAGE_EMOTE_CAPTURE_CACHE",
        "MIKAGE_EMOTE_LOCAL_UPDATE", "MIKAGE_EMOTE_REGION_COPY", "MIKAGE_EMOTE_ASYNC_ALPHA",
        "MIKAGE_EMOTE_EXPERIMENTAL_BOUNDS", "MIKAGE_EMOTE_LOCAL_POSE_CACHE"};
    uint32_t flags = emotePerformanceOptions.load(std::memory_order_relaxed);
#if TARGET_OS_SIMULATOR
    // No drawable-presented acknowledgement exists in the simulator SDK.
    // Keep ordinary input rather than publish an unconfirmed alpha frame.
    flags &= ~(1u << 4);
#endif
    for (unsigned i = 0; i < 7; ++i)
        if (!SDL_SetHintWithPriority(hints[i], flags & (1u << i) ? "1" : "0", SDL_HINT_OVERRIDE))
            return false;
    emoteplayer::resetPerformanceStats();
    char optionsLog[64];
    std::snprintf(optionsLog, sizeof(optionsLog), "performance.options flags=%u", flags);
    MikageKRKRLogMessage("emote", 3, optionsLog);
    return true;
}

// Leave pointer events in SDL's queue when the alpha-input queue is full.
// Lifecycle/keyboard/device events remain serviceable, so a blocked GPU cannot
// prevent quitting, resizing or stopping the session. Pointer FIFO is retained.
static bool pollKRKREvent(SDL_Event* event)
{
    if (!TVPHasPendingLayerPointerBackpressure()) return SDL_PollEvent(event);
    SDL_PumpEvents();
    static const std::array<Uint32, 7> pointerTypes = [] {
        std::array<Uint32, 7> types{{SDL_EVENT_MOUSE_MOTION, SDL_EVENT_MOUSE_BUTTON_DOWN,
            SDL_EVENT_MOUSE_BUTTON_UP, SDL_EVENT_MOUSE_WHEEL, SDL_EVENT_FINGER_DOWN,
            SDL_EVENT_FINGER_UP, SDL_EVENT_FINGER_MOTION}};
        std::sort(types.begin(), types.end());
        return types;
    }();
    Uint32 first = SDL_EVENT_FIRST;
    for (Uint32 type : pointerTypes) {
        if (first < type && SDL_PeepEvents(event, 1, SDL_GETEVENT, first, type - 1) > 0) return true;
        first = type + 1;
    }
    return SDL_PeepEvents(event, 1, SDL_GETEVENT, first, SDL_EVENT_LAST) > 0;
}

#include "TVPApplication.h"
#include "tjsError.h"
#include "tjsDebug.h"

namespace {
bool diagnosticScriptOnVMThread() { return [NSThread isMainThread]; }

// The TJS tracer checks its global pointer separately on function entry/exit.
// Switching it inside a script/native callback can therefore unbalance its
// stack. Own a separate reference without enabling TJS debug/object tracing,
// acquire only at an outer host boundary, and retain it until session teardown.
struct DiagnosticScriptTraceState
{
    unsigned hostDepth = 0;
    bool sessionActive = false;
    bool ownsReference = false;

    void Enter(bool requested) noexcept
    {
        if (hostDepth++ == 0 && requested && !ownsReference) {
            try {
                TJS::TJSAddRefStackTracer();
                ownsReference = true;
            } catch (...) {
                // Stack attribution is optional; allocation failure must not
                // prevent the game from starting or processing an event.
            }
        }
    }
    void ReleaseIfIdle() noexcept
    {
        if (hostDepth == 0 && !sessionActive && ownsReference) {
            ownsReference = false;
            TJS::TJSReleaseStackTracer();
        }
    }
    void Leave() noexcept
    {
        --hostDepth;
        ReleaseIfIdle();
    }
    void BeginSession() noexcept { sessionActive = true; }
    void EndSession() noexcept
    {
        sessionActive = false;
        ReleaseIfIdle();
    }
};
DiagnosticScriptTraceState diagnosticScriptTrace;

struct DiagnosticScriptTraceScope
{
    bool entered = diagnosticScriptOnVMThread();
    DiagnosticScriptTraceScope() noexcept
    {
        if (entered)
            diagnosticScriptTrace.Enter(diagnosticCallback.load(std::memory_order_acquire) != nullptr);
    }
    ~DiagnosticScriptTraceScope()
    {
        if (entered) diagnosticScriptTrace.Leave();
    }
    void BeginSession() noexcept
    {
        if (entered) diagnosticScriptTrace.BeginSession();
    }
};

void endDiagnosticScriptTraceSession() noexcept
{
    if (diagnosticScriptOnVMThread()) diagnosticScriptTrace.EndSession();
}
}

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
    endDiagnosticScriptTraceSession();
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
    endDiagnosticScriptTraceSession();
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
    DiagnosticScriptTraceScope traceScope;
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
            if (!applyEmoteAnimationModeForStart())
                throw std::runtime_error("Failed to select Emote animation mode.");
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

            traceScope.BeginSession();
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
    DiagnosticScriptTraceScope traceScope;
    if (!running)
        return MIKAGE_KRKR_STEP_IDLE;

    try {
        const Uint64 frameStarted = SDL_GetTicksNS();
        const Uint64 eventsStarted = frameStarted;
        Uint64 eventCount = 0;
        SDL_Event event;
        while (pollKRKREvent(&event)) {
            ++eventCount;
            SDL_AppResult result = SDL_AppEvent(appState, &event);
            if (result != SDL_APP_CONTINUE)
                return finishForResult(result);
        }
        Uint64 eventDuration = SDL_GetTicksNS() - eventsStarted;
        stepEventTimeNS += eventDuration;

        if (stopRequested)
            return finishForResult(SDL_APP_SUCCESS);

        if (!foreground)
            return MIKAGE_KRKR_STEP_RUNNING;

        // Completion callbacks publish only data. Input and TJS callbacks stay
        // on this engine thread, while render/timeline progress remains live.
        const Uint64 pendingInputStarted = SDL_GetTicksNS();
        TVPProcessPendingLayerPointerEvents();
        const Uint64 pendingInputDuration = SDL_GetTicksNS() - pendingInputStarted;
        eventDuration += pendingInputDuration;
        stepEventTimeNS += pendingInputDuration;

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
    DiagnosticScriptTraceScope traceScope;
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
    DiagnosticScriptTraceScope traceScope;
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
    DiagnosticScriptTraceScope traceScope;
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
    stats->layerGammaLUTUploads = layers.gammaLUTUploads;
    stats->layerGammaLUTUploadedBytes = layers.gammaLUTUploadedBytes;
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
    stats->emoteCaptureSkipped = emoteCapture.skipped;
    stats->emoteCaptureRegionPixels = emoteCapture.regionPixels;
    stats->emoteCaptureFullPixels = emoteCapture.fullPixels;
    const auto emotePerf = emoteplayer::performanceStats();
    stats->emoteNodeCacheHits = emotePerf.nodeCacheHits;
    stats->emoteNodeCacheMisses = emotePerf.nodeCacheMisses;
    stats->emoteShapeCacheHits = emotePerf.shapeCacheHits;
    stats->emoteMeshCacheHits = emotePerf.meshCacheHits;
    stats->emoteDrawListRebuilds = emotePerf.drawListRebuilds;
    stats->emoteCaptureKnownBounds = emotePerf.captureKnownBounds;
    stats->emoteCaptureUnknownBounds = emotePerf.captureUnknownBounds;
    stats->emoteCaptureCOWFallbacks = emotePerf.captureCOWFallbacks;
    stats->emoteAlphaRequests = emotePerf.alphaRequests;
    stats->emoteAlphaCacheHits = emotePerf.alphaCacheHits;
    stats->emoteAlphaPendingEvents = emotePerf.alphaPendingEvents;
    stats->emoteAlphaReadBytes = emotePerf.alphaReadBytes;
    stats->emoteAlphaFailures = emotePerf.alphaFailures;
    stats->emoteUISyncReads = emotePerf.uiSyncReads;
    stats->emoteUISyncWaitNS = emotePerf.uiSyncWaitNS;
    stats->emoteCaptureExperimentalBoundsKnown = emotePerf.captureExperimentalBoundsKnown;
    stats->emoteCaptureExperimentalBoundsUnknown = emotePerf.captureExperimentalBoundsUnknown;
    stats->emoteCaptureExperimentalBoundsPixels = emotePerf.captureExperimentalBoundsPixels;
    stats->emoteCaptureExperimentalBoundsNS = emotePerf.captureExperimentalBoundsNS;
    stats->emoteCaptureUpdatePixels = emotePerf.captureUpdatePixels;
    stats->emoteCaptureUpdateFullPixels = emotePerf.captureUpdateFullPixels;
    stats->emoteLocalPoseCacheHits = emotePerf.localPoseCacheHits;
    stats->emoteLocalPoseCacheMisses = emotePerf.localPoseCacheMisses;
    stats->emoteCaptureRequests = emotePerf.captureRequests;
    stats->emoteCaptureFullCopies = emotePerf.captureFullCopies;
    stats->emoteCaptureRegionCopies = emotePerf.captureRegionCopies;
    stats->emoteCaptureRegionFallbacks = emotePerf.captureRegionFallbacks;
    stats->emoteCaptureBoundsNS = emotePerf.captureBoundsNS;

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

extern "C" bool MikageKRKRTakeLayerWorkProfile(MikageKRKRLayerWorkProfile *profile)
{
    if(!running || !profile || !diagnosticCallback.load(std::memory_order_acquire)) return false;
    std::memset(profile,0,sizeof(*profile));
    try {
        const auto sample=krkrsdl3::layer_work::Take();
        profile->intervalNS=sample.intervalNS;
        std::snprintf(profile->stages,sizeof(profile->stages),"%s",sample.stages.c_str());
        std::snprintf(profile->transfers,sizeof(profile->transfers),"%s",sample.transfers.c_str());
        profile->amvDecodedFrames=sample.decodedFrames;
        profile->amvDecodedBytes=sample.decodedBytes;
        return true;
    } catch(...) { return false; }
}

extern "C" bool MikageKRKRTakeLayerTriangleProfile(MikageKRKRLayerTriangleProfile *profile)
{
    if (!running || !profile || !diagnosticCallback.load(std::memory_order_acquire))
        return false;
    std::memset(profile, 0, sizeof(*profile));
    try {
        const auto sample = TVPTakeMetalLayerTriangleProfile();
        const auto& s = sample.stats;
        profile->intervalNS = s.intervalNS;
        profile->calls = s.calls;
        profile->triangleCount = s.triangleCount;
        profile->gpuCalls = s.gpuCalls;
        profile->gpuPixels = s.gpuPixels;
        profile->clipPixels = s.clipPixels;
        profile->maxClipPixels = s.maxClipPixels;
        profile->maxTargetPixels = s.maxTargetPixels;
        profile->fullSurfaceCalls = s.fullSurfaceCalls;
        profile->target1920x1080Calls = s.target1920x1080Calls;
        profile->targetReadbackBytes = s.targetReadbackBytes;
        profile->sourceReadbackBytes = s.sourceReadbackBytes;
        profile->referenceReadbackBytes = s.referenceReadbackBytes;
        profile->cpuTimeNS = s.cpuTimeNS;
        profile->maxCpuTimeNS = s.maxCpuTimeNS;
        profile->softwareTimeNS = s.softwareTimeNS;
        profile->maxSoftwareTimeNS = s.maxSoftwareTimeNS;
        profile->count2Calls = s.count2Calls;
        profile->singleInputCalls = s.singleInputCalls;
        profile->referenceCalls = s.referenceCalls;
        profile->sourceTargetAliasCalls = s.sourceTargetAliasCalls;
        std::strncpy(profile->methods, sample.methods.c_str(), sizeof(profile->methods) - 1);
        std::strncpy(profile->targetSizes, sample.targetSizes.c_str(), sizeof(profile->targetSizes) - 1);
        std::strncpy(profile->sources, sample.sources.c_str(), sizeof(profile->sources) - 1);
        std::strncpy(profile->stretchModes, sample.stretchModes.c_str(), sizeof(profile->stretchModes) - 1);
        return true;
    } catch (...) {
        return false;
    }
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
