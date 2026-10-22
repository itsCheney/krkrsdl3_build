#include "MikageKRKRRuntime.h"
#include "MikageSDLHost.h"

#import <Foundation/Foundation.h>
#include <TargetConditionals.h>

#include <SDL3/SDL.h>
#define SDL_MAIN_HANDLED
#include <SDL3/SDL_main.h>

#include <string>
#include <functional>
#include <exception>
#include <cstring>
#include <sys/mman.h>
#include <unistd.h>
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
#include "LayerWorkDiagnostics.h"
#include "LayerManager.h"
#include "tjsCommHead.h"
#include "TVPScript.h"
#include "tvpinputdefs.h"
#include "../cpp/plugins/emoteplayer/emoteperformance.h"

namespace {
std::atomic<MikageKRKRLogCallback> diagnosticCallback{nullptr};
std::mutex logOutputMutex;
std::mutex skippedMoviesMutex;
std::string skippedMovies;
std::atomic<bool> stretchToScreen{false};
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
// Defined in the core with C++ linkage; runs kag.saveSystemVariables.
void TVPDoSaveSystemVariables();
// Defined in the core (TVPSystem.cpp). With TVPHostOwnsProcess set,
// System.exit sets TVPTerminated and unwinds here with eTJSSilent instead of
// calling exit(), so the session returns to the library.
extern bool TVPHostOwnsProcess;
extern bool TVPTerminated;

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

extern "C" void MikageKRKRSetStretchToScreen(bool enabled)
{
    stretchToScreen.store(enabled, std::memory_order_relaxed);
}

#include "TVPApplication.h"
#include "TVPWindow.h"
#include "TVPEvent.h"
#include "tjsNativeLayer.h"
#include "tjsArray.h"
#include "PlatformThread.h"
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
// Nonzero while MikageKRKRStep is on the stack. A modal SDL dialog pumps the
// run loop mid-script, so host callbacks can arrive inside a step.
int stepDepth = 0;
// The KAG tap watch (kKAGTapWatch) of the running game.
bool tapWatchInstalled = false;
int tapWatchWait = 0;
std::string activeRenderer;
Uint64 statsWindowStarted = 0;
Uint64 previousFrameAt = 0;
Uint64 frameIntervalTotal = 0;
Uint64 frameCount = 0;
double currentFPS = 0;
double currentFrameTimeMS = 0;
Uint64 frameWorkTotal = 0, frameWorkMax = 0;
double currentCpuFrameTimeMS = 0, currentMaxCpuFrameTimeMS = 0;
uint64_t drawCallsAtWindowStart = 0;
double currentDrawCallsPerFrame = 0;
constexpr Uint64 nanosecondsPerSecond = 1000000000ULL;
constexpr Uint64 slowFrameThresholdNS = 50000000ULL;
Uint64 slowFrameCount = 0;
Uint64 peakFrameEventTimeNS = 0, peakFrameIterateTimeNS = 0;
Uint64 peakFrameEventCount = 0;

void resetStats()
{
    krkrsdl3::layer_work::ResetFrameHistory();
    statsWindowStarted = SDL_GetTicksNS();
    previousFrameAt = 0;
    frameIntervalTotal = 0;
    frameCount = 0;
    currentFPS = 0;
    currentFrameTimeMS = 0;
    frameWorkTotal = frameWorkMax = 0;
    currentCpuFrameTimeMS = currentMaxCpuFrameTimeMS = 0;
    drawCallsAtWindowStart = krkrsdl3::TVPGetDrawCallCount();
    currentDrawCallsPerFrame = 0;
    slowFrameCount = 0;
    peakFrameEventTimeNS = peakFrameIterateTimeNS = peakFrameEventCount = 0;
}

void recordFrame(Uint64 presentedAt, Uint64 workDuration,
                 Uint64 eventDuration, Uint64 iterateDuration, Uint64 eventCount)
{
    krkrsdl3::layer_work::RecordFrame(presentedAt,workDuration);
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
        const uint64_t drawCalls = krkrsdl3::TVPGetDrawCallCount();
        currentDrawCallsPerFrame =
            static_cast<double>(drawCalls - drawCallsAtWindowStart) / frameCount;
        drawCallsAtWindowStart = drawCalls;
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

// KRKR's side of the shared SDL host session (MikageSDLHost.h).
// iOS asks the app to quit while the game may sit in a modal loop (its own
// quit confirmation, for one). That loop only ends once the application is
// terminating, so mark it as soon as SDL hears about it, from inside the
// loop's own event pump; otherwise the watchdog kills the app after 5 s.
bool SDLCALL watchTermination(void *, SDL_Event *event)
{
    if (event->type == SDL_EVENT_TERMINATING && Application) {
        MikageKRKRLogMessage("bridge", 3, "runtime.terminating");
        Application->Terminate();
    }
    return true;
}

SDL_AppResult hostInit(void **appstate, int argc, char *argv[])
{
    SDL_AddEventWatch(watchTermination, nullptr);
    SDL_AppResult result = SDL_AppInit(appstate, argc, argv);
    const char *actualRenderer = MikageKRKRGetActiveRendererName();
    if (actualRenderer && *actualRenderer)
        activeRenderer = actualRenderer;
    MikageKRKRLogMessage("bridge", 3, activeRenderer.c_str());
    return result;
}

SDL_AppResult hostEvent(void *appstate, SDL_Event *event)
{
    switch (event->type) {
        case SDL_EVENT_WINDOW_EXPOSED:
        case SDL_EVENT_WINDOW_RESIZED:
        case SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED:
        case SDL_EVENT_WINDOW_SHOWN:
        case SDL_EVENT_WINDOW_HIDDEN:
        case SDL_EVENT_WINDOW_RESTORED:
        case SDL_EVENT_DID_ENTER_FOREGROUND:
        case SDL_EVENT_DID_ENTER_BACKGROUND:
            krkrsdl3::TVPInvalidatePresentation("host.lifecycle");break;
        default:break;
    }
    return SDL_AppEvent(appstate, event);
}

SDL_AppResult hostIterate(void *appstate)
{
    krkrsdl3::TVPBeginRuntimeStep();
    SDL_AppResult result = SDL_AppIterate(appstate);
    krkrsdl3::TVPEndRuntimeStep();
    return result;
}

SDL_AppResult hostQuit(void *appstate, SDL_AppResult result)
{
    SDL_RemoveEventWatch(watchTermination, nullptr);
    try {
        SDL_AppQuit(appstate, result);
    } catch (const eTJS &error) {
        MikageSDLHostSetLastError(error.GetMessage().c_str());
        return SDL_APP_FAILURE;
    }
    return result;
}

void hostSessionEnded()
{
    endDiagnosticScriptTraceSession();
    TVPSetGameRunningOrientation(false);
    MikageKRKRSetWindowScene(nullptr);
    activeRenderer.clear();
}

void hostSetActive(bool active)
{
    if (Application)
        Application->NotifyActiveEvent(active ? eTVPActiveEvent::onActive : eTVPActiveEvent::onDeactive);
}

void hostFrameCompleted(const MikageSDLHostFrame *frame)
{
    recordFrame(frame->finishedNS, frame->workNS,
                frame->eventNS, frame->iterateNS, frame->eventCount);
}

const MikageSDLHostEngine krkrEngine = {
    "KRKR",
    hostInit,
    hostEvent,
    hostIterate,
    hostQuit,
    hostSessionEnded,
    TVPSetAudioSuspended,
    hostSetActive,
    hostFrameCompleted,
    resetStats,
    MikageKRKRLogMessage,
};
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
    if (MikageSDLHostIsRunning()) {
        MikageSDLHostSetLastError("A KRKR session is already running.");
        return false;
    }
    if (!gamePath || !*gamePath) {
        MikageSDLHostSetLastError("The KRKR game path is empty.");
        return false;
    }

    @autoreleasepool {
        NSString *path = [NSString stringWithUTF8String:gamePath];
        BOOL isDirectory = NO;
        if (!path || ![[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory]) {
            MikageSDLHostSetLastError("The KRKR game path does not exist.");
            return false;
        }

        std::string normalizedPath(gamePath);
        if (isDirectory && normalizedPath.back() != '/')
            normalizedPath.push_back('/');

        try {
            MikageKRKRSetLogCallback(diagnosticCallback.load(std::memory_order_acquire));
            // Per-session Emote counters start from zero for each game.
            emoteplayer::resetPerformanceStats();
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
            if (stretchToScreen.load(std::memory_order_relaxed))
                arguments.emplace_back("-stretch=1");

            std::vector<char *> argv;
            argv.reserve(arguments.size());
            for (auto &argument : arguments)
                argv.push_back(argument.data());

            activeRenderer = renderer && *renderer ? renderer : "metal";
            // Capture diagnostics are session-scoped, just like Layer stats.
            // Do not let a previous game make GPU-copy/fallback counts ambiguous.
            krkrsdl3::TVPResetEmoteCaptureStats();
            krkrsdl3::TVPResetRuntimeProfileStats();

            traceScope.BeginSession();
            tapWatchInstalled = false;
            tapWatchWait = 0;
            TVPHostOwnsProcess = true;
            const MikageSDLHostConfiguration configuration = {
                static_cast<int>(argv.size()),
                argv.data(),
                uiWindowScene,
                respectSilentMode,
                menu,
                completion,
                context,
            };
            // The host finishes the session itself when SDL_AppInit fails.
            if (!MikageSDLHostStart(&krkrEngine, &configuration))
                return false;
        } catch (const eTJSSilent &) {
            MikageSDLHostAbortStart(TVPTerminated ? "The game exited during startup."
                                                  : "Silent KRKR exception during startup.");
            return false;
        } catch (const eTJS &error) {
            MikageSDLHostAbortStart(std::string(error.GetMessage().c_str()).c_str());
            return false;
        } catch (const std::exception &error) {
            MikageSDLHostAbortStart(error.what() ? error.what() : "C++ exception during KRKR startup.");
            return false;
        } catch (...) {
            MikageSDLHostAbortStart("Unknown C++ exception during KRKR startup.");
            return false;
        }
    }
    return true;
}

namespace {

void watchButtonTaps();

// Stays raised while a modal window waits: its script is mid-call.
struct StepDepth {
    StepDepth() { ++stepDepth; }
    ~StepDepth() { --stepDepth; }
};

// Runs on the step stack. The diagnostics scopes live here, not around the
// switch: VM call scopes link to the step's scope, and a modal window can
// suspend them across frames.
MikageKRKRStepResult runStep()
{
    DiagnosticScriptTraceScope traceScope;
    krkrsdl3::cpu_frame::rawLine = [](const char* line) {MikageKRKRLogMessage("KRKR", 3, line);};
    krkrsdl3::cpu_frame::captureStack = [](char* out, size_t bytes, unsigned frames) {
        return diagnosticScriptOnVMThread() && TJS::TJSGetStackTraceUTF8(out, static_cast<tjs_uint>(bytes), frames);
    };
    krkrsdl3::cpu_frame::StepScope cpuStep;
    StepDepth depth;
    watchButtonTaps();
    try {
        return static_cast<MikageKRKRStepResult>(MikageSDLHostStep());
    } catch (const eTJSSilent &) {
        // System.exit already requested termination: a normal end of game.
        if (TVPTerminated)
            return static_cast<MikageKRKRStepResult>(MikageSDLHostFinish(SDL_APP_SUCCESS, nullptr));
        MikageSDLHostFinish(SDL_APP_FAILURE, "Silent KRKR exception while stepping.");
    } catch (const eTJS &error) {
        std::string message(error.GetMessage().c_str());
        MikageSDLHostFinish(SDL_APP_FAILURE, message.c_str());
    } catch (const std::exception &error) {
        MikageSDLHostFinish(SDL_APP_FAILURE, error.what());
    } catch (...) {
        MikageSDLHostFinish(SDL_APP_FAILURE, "Unknown C++ exception while stepping KRKR.");
    }
    return MIKAGE_KRKR_STEP_FAILED;
}

// True while a modal window's loop has handed the frame back to the host:
// the script that opened it is still mid-call on the step stack.
bool modalSuspended = false;

// Host calls that run game script (a menu command, the quit request) run
// on the step stack as well: that script may open a modal window, and a
// modal loop on the host stack spins UIKit's run loop from inside the
// SwiftUI action that called it.
std::vector<std::function<bool()>> stepJobs;
bool stepJobResult = false;

bool runJob(const std::function<bool()> &job)
{
    DiagnosticScriptTraceScope traceScope;
    StepDepth depth;
    try {
        return job();
    } catch (...) {
        return false;
    }
}

#if defined(__aarch64__) && defined(__APPLE__)
// Steps run on their own stack so a modal window (askYesNo, the quit
// confirmation) can return each frame to the display link and resume on
// the next one. Blocking the display link instead keeps UIKit from
// delivering touches, so the dialog could never be answered.
// arm64 Apple ABI: x19-x28, fp, lr and d8-d15 are what a switch must keep.
extern "C" void mikage_krkr_fiber_switch(void **saveSP, void *loadSP);
extern "C" void mikage_krkr_fiber_trampoline(void);
asm(R"(
.text
.private_extern _mikage_krkr_fiber_switch
.p2align 2
_mikage_krkr_fiber_switch:
    sub sp, sp, #160
    stp x19, x20, [sp, #0]
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp x29, x30, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mov x9, sp
    str x9, [x0]
    mov sp, x1
    ldp x19, x20, [sp, #0]
    ldp x21, x22, [sp, #16]
    ldp x23, x24, [sp, #32]
    ldp x25, x26, [sp, #48]
    ldp x27, x28, [sp, #64]
    ldp x29, x30, [sp, #80]
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    add sp, sp, #160
    ret

.private_extern _mikage_krkr_fiber_trampoline
.p2align 2
_mikage_krkr_fiber_trampoline:
    mov x0, x20
    blr x19
    brk #0xf1
)");

constexpr size_t kStepStackSize = 16u << 20;
void *stepStack = nullptr;
void *stepStackPointer = nullptr;
void *hostStackPointer = nullptr;
bool onStepStack = false;
MikageKRKRStepResult stepResult = MIKAGE_KRKR_STEP_IDLE;

void toHost()
{
    mikage_krkr_fiber_switch(&stepStackPointer, hostStackPointer);
}

[[noreturn]] void stepMain(void *)
{
    for (;;) {
        if (!stepJobs.empty()) {
            std::function<bool()> job = std::move(stepJobs.front());
            stepJobs.erase(stepJobs.begin());
            stepJobResult = runJob(job);
            stepResult = MIKAGE_KRKR_STEP_RUNNING;
        } else {
            stepResult = runStep();
        }
        toHost();
    }
}

bool prepareStepStack()
{
    void *stack = mmap(nullptr, kStepStackSize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (stack == MAP_FAILED)
        return false;
    // The lowest page stays unmapped so an overflow faults instead of
    // corrupting the heap.
    mprotect(stack, getpagesize(), PROT_NONE);
    stepStack = stack;
    // The frame mikage_krkr_fiber_switch restores: x19-x28, fp, lr, d8-d15.
    auto top = reinterpret_cast<uintptr_t>(stack) + kStepStackSize;
    auto *frame = reinterpret_cast<uint64_t *>((top - 160) & ~uintptr_t(15));
    std::memset(frame, 0, 160);
    frame[0] = reinterpret_cast<uint64_t>(&stepMain);                      // x19
    frame[11] = reinterpret_cast<uint64_t>(&mikage_krkr_fiber_trampoline); // lr
    stepStackPointer = frame;
    return true;
}

void modalYield()
{
    if (!onStepStack) {
        TVPSleepFor(16);
        return;
    }
    modalSuspended = true;
    // In the background the dialog waits without drawing.
    do {
        stepResult = MIKAGE_KRKR_STEP_RUNNING;
        toHost();
    } while (!MikageSDLHostIsForeground() && !(Application && Application->IsTarminate()));
    modalSuspended = false;
}

MikageKRKRStepResult resumeStep()
{
    // A nested run loop (an SDL event pump inside the step) can call back in.
    if (onStepStack)
        return MIKAGE_KRKR_STEP_RUNNING;
    if (!stepStack) {
        if (!prepareStepStack())
            return runStep();
        TVPHostModalYield = modalYield;
    }
    onStepStack = true;
    mikage_krkr_fiber_switch(&hostStackPointer, stepStackPointer);
    onStepStack = false;
    return stepResult;
}

// Runs job on the step stack now, or after the game's open dialog closes.
// A job that opens a dialog itself finishes on a later frame; it counts
// as done.
bool runOnStepStack(std::function<bool()> job)
{
    if (onStepStack)
        return runJob(job);
    stepJobs.push_back(std::move(job));
    if (modalSuspended)
        return true;
    stepJobResult = true;
    resumeStep();
    if (!stepStack) {
        // No step stack could be made; resumeStep ran a plain step.
        std::function<bool()> queued = std::move(stepJobs.back());
        stepJobs.pop_back();
        return runJob(queued);
    }
    return stepJobResult;
}
#else
MikageKRKRStepResult resumeStep()
{
    return runStep();
}

bool runOnStepStack(std::function<bool()> job)
{
    return runJob(job);
}
#endif
}

extern "C" MikageKRKRStepResult MikageKRKRStep(void)
{
    if (!MikageSDLHostIsRunning() && !modalSuspended)
        return MIKAGE_KRKR_STEP_IDLE;
    return resumeStep();
}

extern "C" bool MikageKRKRRequestExit(void)
{
    if (!MikageSDLHostIsRunning() || !MikageSDLHostIsForeground() || !TVPMainWindow)
        return false;
    MikageKRKRLogMessage("bridge", 3, "runtime.userClose.requested");
    // The game's close query usually asks with a dialog.
    return runOnStepStack([] {
        if (!TVPMainWindow)
            return false;
        try {
            TVPMainWindow->RequestUserClose();
            return true;
        } catch (const eTJSSilent &) {
            // onCloseQuery called System.exit; the next step finishes the session.
            if (TVPTerminated)
                return true;
            MikageSDLHostSetLastError("Silent KRKR exception requesting close-query.");
        } catch (const eTJS &error) {
            MikageSDLHostSetLastError(error.GetMessage().c_str());
        } catch (const std::exception &error) {
            MikageSDLHostSetLastError(error.what() ? error.what() : "KRKR close-query failed.");
        } catch (...) {
            MikageSDLHostSetLastError("Unknown exception requesting KRKR close-query.");
        }
        MikageKRKRLogMessage("bridge", 5, MikageSDLHostLastError());
        return false;
    });
}

extern "C" bool MikageKRKRSendBack(void)
{
    if (!MikageSDLHostIsForeground())
        return false;
    const bool sent = MikageSDLHostSendBackKey();
    MikageKRKRLogMessage("bridge", sent ? 3 : 4, sent ? "runtime.back.sent" : "runtime.back.unavailable");
    return sent;
}

namespace {

// Evaluates a TJS expression against the game's KAG system and returns its integer
// result, or -1 when it threw (no KAG, or a system without these methods).
tjs_int runKAGScript(const char *script)
{
    if (!MikageSDLHostIsRunning())
        return -1;
    try {
        tTJSVariant result;
        TVPExecuteExpression(ttstr(script), &result);
        return result.Type() == tvtVoid ? 0 : (tjs_int)result.AsInteger();
    } catch (...) {
        return -1;
    }
}

// The KAG3 entry points its own menu uses: auto mode, "skip to the next
// choice or unread text" (which follows the game's read-skip rules), the
// history layer, and bookmarks. Story commands wait for a stable conductor
// (a click wait), as the menu items do.
const char *const kKAGControls =
    "(typeof global.kag == 'undefined' || global.kag === void) ? 0 : ("
    "((typeof kag.enterAutoMode != 'undefined' && typeof kag.cancelAutoMode != 'undefined')"
    "  ? (0x100 | (kag.autoMode ? 1 : 0)) : 0) |"
    "((typeof kag.skipToStop != 'undefined' && typeof kag.cancelSkip != 'undefined')"
    "  ? (0x200 | (kag.skipMode ? 2 : 0)) : 0) |"
    "((typeof kag.inStable == 'undefined' || kag.inStable) ? ("
    "  ((typeof kag.saveBookMark != 'undefined') ? 0x400 : 0) |"
    "  ((typeof kag.loadBookMark != 'undefined' && typeof kag.bookMarkDates != 'undefined'"
    "    && kag.bookMarkDates[999] !== void && kag.bookMarkDates[999] != '') ? 0x800 : 0) |"
    "  ((typeof kag.showHistory != 'undefined'"
    "    && (typeof kag.historyEnabled == 'undefined' || kag.historyEnabled)"
    "    && (typeof kag.historyShowing == 'undefined' || !kag.historyShowing)) ? 0x1000 : 0)"
    ") : 0))";

const char *const kKAGToggleAuto =
    "(kag.autoMode ? kag.cancelAutoMode()"
    " : ((kag.skipMode ? kag.cancelSkip() : 0), kag.enterAutoMode())), 1";

const char *const kKAGToggleSkip =
    "(kag.skipMode ? kag.cancelSkip()"
    " : ((kag.autoMode ? kag.cancelAutoMode() : 0), kag.skipToStop())), 1";

// Bookmark 999: past the game's own slots, so its save menu never shows it.
// Only for games without a quick save of their own.
const char *const kKAGQuickSave = "(kag.saveBookMark(999) === false) ? 0 : 1";
const char *const kKAGQuickLoad = "kag.loadBookMark(999), 1";
const char *const kKAGBacklog = "kag.showHistory(), 1";

// KAGEX games route their system buttons and keys through the global
// SystemAction table; its entries open the game's own screens (save and
// load pages, its backlog) and run its own quick save and load.
struct SystemActionCommand {
    int32_t command;
    uint32_t control;
    std::vector<const char *> names;
};

const std::vector<SystemActionCommand> &systemActionCommands()
{
    static const std::vector<SystemActionCommand> commands = {
        {MikageKRKRCommandQuickSave, MikageKRKRControlCanQuickSave, {"qsave", "quicksave", "quickSave"}},
        {MikageKRKRCommandQuickLoad, MikageKRKRControlCanQuickLoad, {"qload", "quickload", "quickLoad"}},
        {MikageKRKRCommandBacklog, MikageKRKRControlCanBacklog, {"history", "backlog", "log"}},
        {MikageKRKRCommandSave, MikageKRKRControlCanSave, {"save"}},
        {MikageKRKRCommandLoad, MikageKRKRControlCanLoad, {"load"}},
    };
    return commands;
}

// The SystemAction entry for a command, or "" when the game has none.
std::string systemActionName(const SystemActionCommand &command)
{
    for (const char *name : command.names) {
        const std::string probe = std::string("(typeof global.SystemAction != 'undefined' && SystemAction !== void"
                                              " && typeof SystemAction.") + name + " != 'undefined'"
                                              " && SystemAction." + name + " !== void) ? 1 : 0";
        if (runKAGScript(probe.c_str()) == 1)
            return name;
    }
    return {};
}

const SystemActionCommand *systemActionCommand(int32_t command)
{
    for (const SystemActionCommand &entry : systemActionCommands())
        if (entry.command == command)
            return &entry;
    return nullptr;
}

// Once per game: the SystemAction entries, so a log shows what a game
// offers when one of its screens doesn't open.
void logSystemActions()
{
    static std::atomic<bool> logged{false};
    if (logged.exchange(true) || !MikageSDLHostIsRunning())
        return;
    try {
        tTJSVariant result;
        TVPExecuteExpression(ttstr(
            "(typeof global.SystemAction == 'undefined' || SystemAction === void) ? 'none'"
            " : (function { var a = [], k = []; a.assign(SystemAction);"
            " for (var i = 0; i < a.count; i += 2) k.add(a[i]); return k.join(','); } incontextof global)()"),
            &result);
        const std::string message = "systemActions " + std::string(ttstr(result).AsStdString());
        MikageKRKRLogMessage("bridge", 3, message.c_str());
        // The plugins a game added to kag, where systems that draw their
        // own system buttons usually live.
        tTJSVariant plugins;
        TVPExecuteExpression(ttstr(
            "(typeof global.kag == 'undefined' || kag === void || typeof kag.plugins == 'undefined') ? ''"
            " : (function { var k = []; for (var i = 0; i < kag.plugins.count; i++)"
            " k.add(Scripts.getClassNames(kag.plugins[i])[0]); return k.join(','); } incontextof global)()"),
            &plugins);
        const std::string pluginMessage = "kagPlugins " + std::string(ttstr(plugins).AsStdString());
        MikageKRKRLogMessage("bridge", 3, pluginMessage.c_str());
    } catch (...) {
        MikageKRKRLogMessage("bridge", 4, "systemActions unreadable");
    }
}

// Plain KAG3 games put their save and load buttons on a message layer as
// [button] links. Each shown link, as "kind,layer,index,storage target exp";
// kind is save, load, qsave or qload when its jump or expression names one.
const char *const kKAGLinks =
    "(function {"
    " if (typeof global.kag == 'undefined' || kag === void || typeof kag.fore == 'undefined') return '';"
    " var classify = function (t) {"
    "  if (t == '') return '';"
    "  if (/q(uick)?[_ ]?save/i.test(t)) return 'qsave';"
    "  if (/q(uick)?[_ ]?load/i.test(t)) return 'qload';"
    "  var s = /save/i.test(t), l = /load/i.test(t);"
    "  if (s && !l) return 'save';"
    "  if (l && !s) return 'load';"
    "  return '';"
    " };"
    " var out = [], layers = kag.fore.messages;"
    " for (var m = 0; m < layers.count; m++) {"
    "  var ml = layers[m];"
    "  if (ml === void || !ml.visible || typeof ml.links == 'undefined' || typeof ml.numLinks == 'undefined') continue;"
    "  for (var i = 0; i < ml.numLinks; i++) {"
    "   var ln = ml.links[i];"
    "   if (ln === void) continue;"
    "   var t = (string)ln.target, e = (string)ln.exp, st = (string)ln.storage;"
    "   var k = classify(t); if (k == '') k = classify(e); if (k == '') k = classify(st);"
    "   out.add(k + ',' + m + ',' + i + ',' + st + ' ' + t + ' ' + e);"
    "  }"
    " }"
    " return out.join('|');"
    "} incontextof global)()";

// Buttons that are their own layers (ButtonLayer subclasses, as system
// button plugins make) rather than links on a message layer. Each found
// button is kept in global.mikageButtons for the click; returns
// "kind,index,name hint exp target storage" joined by '|'.
const char *const kKAGButtons =
    "(function {"
    " if (typeof global.kag == 'undefined' || kag === void || typeof kag.fore == 'undefined') return '';"
    " var classify = function (t) {"
    "  if (t == '') return '';"
    "  if (/q(uick)?[_ ]?save|クイックセーブ|快速存档|快速保存/i.test(t)) return 'qsave';"
    "  if (/q(uick)?[_ ]?load|クイックロード|快速读档|快速读取/i.test(t)) return 'qload';"
    "  var s = /save|セーブ|存档|保存/i.test(t), l = /load|ロード|读档|读取/i.test(t);"
    "  if (s && !l) return 'save';"
    "  if (l && !s) return 'load';"
    "  if (/auto|オート|自動|自动/i.test(t)) return 'auto';"
    "  if (/skip|スキップ|快进|快速翻页|跳过/i.test(t)) return 'skip';"
    "  return '';"
    " };"
    " var text = function (o, p) { try { var v = o[p]; return v === void ? '' : (string)v; } catch (e) { return ''; } };"
    " global.mikageButtons = [];"
    " if (typeof global.mikageLayers == 'undefined') return '';"
    " var learned = typeof kag.scflags != 'undefined' && kag.scflags !== void ? kag.scflags.mikageButtonKinds : void;"
    " var out = [], layers = global.mikageLayers;"
    " for (var i = 0; i < layers.count && global.mikageButtons.count < 64; i++) {"
    "   var c = layers[i], inMessage = false;"
    "   for (var p = c; p && !p.isPrimary; p = p.parent) if (p instanceof 'MessageLayer') { inMessage = true; break; }"
    "   if (inMessage) continue;"
    "   if (c instanceof 'ButtonLayer' && !(c instanceof 'LinkButtonLayer')) {"
    "    var d = text(c, 'name') + ' ' + text(c, 'hint') + ' ' + text(c, 'exp') + ' ' + text(c, 'target') + ' ' + text(c, 'storage');"
    "    var k = classify(text(c, 'name')); if (k == '') k = classify(text(c, 'hint'));"
    "    if (k == '') k = classify(text(c, 'exp')); if (k == '') k = classify(text(c, 'target'));"
    "    if (k == '') k = classify(text(c, 'storage'));"
    "    if (k == '' && learned !== void) { var lk = learned[c.left + ',' + c.top + ',' + c.width + ',' + c.height]; if (lk !== void) k = lk; }"
    "    out.add(k + ',' + global.mikageButtons.count + ',' + d.replace(/\\|/g, '/'));"
    "    global.mikageButtons.add(c);"
    "   }"
    " }"
    " return out.join('|');"
    "} incontextof global)()";

// Buttons that say nothing about themselves are learned from the player's
// own taps: a tap on a button layer followed by a save or load screen
// (its links, as kKAGLinks reads them), or that turns auto or skip on,
// marks that button, by its place and size, in the game's system
// variables (sf.mikageButtonKinds).
const char *const kKAGTapWatch =
    "(function {"
    " if (typeof global.kag == 'undefined' || kag === void || typeof kag.fore == 'undefined') return 0;"
    " if (typeof global.mikageTap != 'undefined') return 1;"
    // TJS functions don't close over locals: what they call lives in global.
    " if (kag.onMouseDown === void) return 0;"
    " global.mikageTapDown = kag.onMouseDown;"
    " global.mikageTap = %[key: '', at: 0];"
    " global.mikageScreenKind = function {"
    "  var layers = kag.fore.messages;"
    "  for (var m = 0; m < layers.count; m++) {"
    "   var ml = layers[m];"
    "   if (ml === void || !ml.visible || typeof ml.links == 'undefined' || typeof ml.numLinks == 'undefined') continue;"
    "   for (var i = 0; i < ml.numLinks; i++) {"
    "    var ln = ml.links[i];"
    "    if (ln === void) continue;"
    "    var t = (string)ln.target + ' ' + (string)ln.exp + ' ' + (string)ln.storage;"
    "    if (/q(uick)?[_ ]?(save|load)/i.test(t)) continue;"
    "    var s = /save/i.test(t), l = /load/i.test(t);"
    "    if (s && !l) return 'save';"
    "    if (l && !s) return 'load';"
    "   }"
    "  }"
    "  return '';"
    " };"
    " global.mikageRemember = function (key, kind) {"
    "  if (kag.scflags.mikageButtonKinds === void) kag.scflags.mikageButtonKinds = %[];"
    "  if (kag.scflags.mikageButtonKinds[key] != kind) Debug.message('mikage.buttonLearned ' + key + ' ' + kind);"
    "  kag.scflags.mikageButtonKinds[key] = kind;"
    " };"
    // A button whose tap turns auto or skip on, within the same tap.
    " global.mikageLearnMode = function (kind) {"
    "  var tap = mikageTap;"
    "  if (tap.key != '' && System.getTickCount() - tap.at < 1000) mikageRemember(tap.key, kind);"
    "  tap.key = '';"
    " };"
    " if (kag.enterAutoMode !== void) {"
    "  global.mikageAutoEnter = kag.enterAutoMode;"
    "  kag.enterAutoMode = function { try { global.mikageLearnMode('auto'); } catch (e) {} return global.mikageAutoEnter(...); } incontextof kag;"
    " }"
    " if (kag.skipToStop !== void) {"
    "  global.mikageSkipEnter = kag.skipToStop;"
    "  kag.skipToStop = function { try { global.mikageLearnMode('skip'); } catch (e) {} return global.mikageSkipEnter(...); } incontextof kag;"
    " }"
    " global.mikageLearnTap = function (x, y) {"
    "  var tap = mikageTap, shown = mikageScreenKind(), now = System.getTickCount();"
    "  if (shown != '') {"
    "   if (tap.key != '' && now - tap.at < 15000) mikageRemember(tap.key, shown);"
    "   tap.key = '';"
    "   return;"
    "  }"
    "  tap.key = '';"
    // The layer the engine itself hits, and up: reading .children here
    // would make every layer keep an array of its children on each tap.
    "  for (var c = kag.fore.base.getLayerAt(x, y); c && !c.isPrimary; c = c.parent) {"
    "   if (c instanceof 'MessageLayer') break;"
    "   if (c instanceof 'ButtonLayer' && !(c instanceof 'LinkButtonLayer')) {"
    "    tap.key = c.left + ',' + c.top + ',' + c.width + ',' + c.height;"
    "    tap.at = now;"
    "    break;"
    "   }"
    "  }"
    " };"
    " kag.onMouseDown = function (x, y, button, shift) {"
    "  try { if (button == mbLeft) global.mikageLearnTap(x, y); } catch (e) {}"
    "  return global.mikageTapDown(...);"
    " } incontextof kag;"
    " return 1;"
    "} incontextof global)()";

// What the screen is made of, for games whose buttons none of the above
// find: visible layers under the base (M message, B button, L other).
const char *const kKAGLayerTree =
    "(function {"
    " if (typeof global.kag == 'undefined' || kag === void || typeof kag.fore == 'undefined') return '';"
    " var text = function (o, p) { try { var v = o[p]; return v === void ? '' : (string)v; } catch (e) { return ''; } };"
    " if (typeof global.mikageLayers == 'undefined') return '';"
    " var out = [], layers = global.mikageLayers, depths = global.mikageLayerDepths;"
    " for (var i = 0; i < layers.count && out.count < 80; i++) {"
    "   var c = layers[i];"
    "   var t = c instanceof 'MessageLayer' ? 'M' + text(c, 'numLinks') : (c instanceof 'ButtonLayer' ? 'B' : 'L');"
    "   var e = text(c, 'exp') + text(c, 'target') + text(c, 'storage');"
    "   out.add(depths[i] + t + ':' + text(c, 'name') + '@' + c.left + ',' + c.top + ',' + c.width + 'x' + c.height + (e != '' ? ':' + e : ''));"
    " }"
    " return out.join(' ');"
    "} incontextof global)()";

std::string runKAGString(const char *script)
{
    if (!MikageSDLHostIsRunning())
        return {};
    try {
        tTJSVariant result;
        TVPExecuteExpression(ttstr(script), &result);
        return result.Type() == tvtVoid ? std::string() : std::string(ttstr(result).AsStdString());
    } catch (...) {
        return {};
    }
}

// Puts the tap watch on the game's window once KAG is up (checked about
// once a second, until it is).
void watchButtonTaps()
{
    if (tapWatchInstalled || ++tapWatchWait < 60)
        return;
    tapWatchWait = 0;
    tapWatchInstalled = runKAGScript(kKAGTapWatch) == 1;
}

struct KAGLink {
    std::string kind;
    int layer = 0;
    int index = 0;
};

const char *linkKind(int32_t command)
{
    switch (command) {
    case MikageKRKRCommandSave: return "save";
    case MikageKRKRCommandLoad: return "load";
    case MikageKRKRCommandQuickSave: return "qsave";
    case MikageKRKRCommandQuickLoad: return "qload";
    case MikageKRKRCommandAuto: return "auto";
    case MikageKRKRCommandSkip: return "skip";
    default: return nullptr;
    }
}

// The shown links; logs them whenever they change, so a game whose
// buttons aren't recognized shows what it has.
std::vector<KAGLink> kagLinks()
{
    static std::string logged;
    const std::string all = runKAGString(kKAGLinks);
    if (all != logged) {
        logged = all;
        const std::string message = "kagLinks " + all.substr(0, 900);
        MikageKRKRLogMessage("bridge", 3, message.c_str());
    }
    std::vector<KAGLink> links;
    size_t start = 0;
    while (start < all.size()) {
        size_t end = all.find('|', start);
        if (end == std::string::npos)
            end = all.size();
        const std::string entry = all.substr(start, end - start);
        start = end + 1;
        const size_t a = entry.find(',');
        const size_t b = a == std::string::npos ? a : entry.find(',', a + 1);
        const size_t c = b == std::string::npos ? b : entry.find(',', b + 1);
        if (c == std::string::npos || a == 0)
            continue;
        links.push_back({entry.substr(0, a), std::atoi(entry.substr(a + 1, b - a - 1).c_str()),
                         std::atoi(entry.substr(b + 1, c - b - 1).c_str())});
    }
    return links;
}

const KAGLink *findLink(const std::vector<KAGLink> &links, int32_t command)
{
    const char *kind = linkKind(command);
    if (!kind)
        return nullptr;
    for (const KAGLink &link : links)
        if (link.kind == kind)
            return &link;
    return nullptr;
}

void collectVisibleLayers(tTJSNI_BaseLayer *layer, tjs_int depth, iTJSDispatch2 *layers, iTJSDispatch2 *depths,
                          tjs_int &count)
{
    const tjs_int children = (tjs_int)layer->GetCount();
    for (tjs_int i = 0; i < children && count < 512; i++) {
        tTJSNI_BaseLayer *child = layer->GetChildren(i);
        iTJSDispatch2 *owner = child ? child->GetOwnerNoAddRef() : nullptr;
        if (!owner || !child->GetVisible())
            continue;
        tTJSVariant value(owner, owner), level(depth);
        layers->PropSetByNum(TJS_MEMBERENSURE, count, &value, layers);
        depths->PropSetByNum(TJS_MEMBERENSURE, count, &level, depths);
        ++count;
        collectVisibleLayers(child, depth + 1, layers, depths, count);
    }
}

// The visible layers under kag.fore.base in tree order, as
// global.mikageLayers (their depths in global.mikageLayerDepths), walked
// natively: reading Layer.children from script makes each layer keep an
// array holding its children, which dangles once a plugin frees a layer
// of its own (a KRKR crash while skipping through Emote scenes).
void shareVisibleLayers()
{
    iTJSDispatch2 *global = TVPGetScriptDispatch();
    if (!global)
        return;
    iTJSDispatch2 *layers = TJSCreateArrayObject();
    iTJSDispatch2 *depths = TJSCreateArrayObject();
    try {
        tTJSVariant base;
        TVPExecuteExpression(ttstr("(typeof global.kag != 'undefined' && kag !== void && typeof kag.fore != 'undefined')"
                                   " ? kag.fore.base : void"),
                             &base);
        iTJSDispatch2 *object = base.Type() == tvtObject ? base.AsObjectNoAddRef() : nullptr;
        tTJSNI_BaseLayer *root = nullptr;
        if (object && TJS_SUCCEEDED(object->NativeInstanceSupport(TJS_NIS_GETINSTANCE, tTJSNC_Layer::ClassID,
                                                                  (iTJSNativeInstance **)&root)) && root) {
            tjs_int count = 0;
            collectVisibleLayers(root, 0, layers, depths, count);
        }
    } catch (...) {
    }
    tTJSVariant layersValue(layers, layers), depthsValue(depths, depths);
    layers->Release();
    depths->Release();
    global->PropSet(TJS_MEMBERENSURE, "mikageLayers", nullptr, &layersValue, global);
    global->PropSet(TJS_MEMBERENSURE, "mikageLayerDepths", nullptr, &depthsValue, global);
    global->Release();
}

// The game owns its layers' lifetimes: the found buttons and layers are
// let go as soon as a query or press is done with them.
void releaseKAGButtons()
{
    runKAGScript("(typeof global.mikageButtons != 'undefined')"
                 " ? (global.mikageButtons = [], global.mikageLayers = [], global.mikageLayerDepths = [], 1) : 0");
}

// Button layers, as links with layer -1 (index into global.mikageButtons).
// Also logs the layer tree once per screen while no save or load button
// is known, so the next unknown game says what its buttons are.
void addKAGButtons(std::vector<KAGLink> &links)
{
    static std::string loggedButtons, loggedTree;
    if (!MikageSDLHostIsRunning())
        return;
    shareVisibleLayers();
    const std::string all = runKAGString(kKAGButtons);
    if (all != loggedButtons) {
        loggedButtons = all;
        for (size_t at = 0, part = 0; at < all.size() && part < 6; at += 900, ++part) {
            const std::string message = "kagButtons " + all.substr(at, 900);
            MikageKRKRLogMessage("bridge", 3, message.c_str());
        }
    }
    size_t start = 0;
    while (start < all.size()) {
        size_t end = all.find('|', start);
        if (end == std::string::npos)
            end = all.size();
        const std::string entry = all.substr(start, end - start);
        start = end + 1;
        const size_t a = entry.find(',');
        const size_t b = a == std::string::npos ? a : entry.find(',', a + 1);
        if (b == std::string::npos || a == 0)
            continue;
        links.push_back({entry.substr(0, a), -1, std::atoi(entry.substr(a + 1, b - a - 1).c_str())});
    }
    bool known = false;
    for (const KAGLink &link : links)
        known |= link.kind == "save" || link.kind == "load";
    if (known)
        return;
    const std::string tree = runKAGString(kKAGLayerTree);
    if (tree == loggedTree)
        return;
    loggedTree = tree;
    for (size_t at = 0, part = 0; at < tree.size() && part < 6; at += 900, ++part) {
        const std::string message = "kagLayers " + tree.substr(at, 900);
        MikageKRKRLogMessage("bridge", 3, message.c_str());
    }
}

} // namespace

extern "C" uint32_t MikageKRKRGameControls(void)
{
    // The game's own dialog is up; its script is mid-call.
    if (modalSuspended)
        return 0;
    tjs_int controls = runKAGScript(kKAGControls);
    if (controls < 0)
        controls = 0;
    logSystemActions();
    // A game's own entries win over the bookmark quick save and showHistory.
    const bool stable = runKAGScript("(typeof global.kag == 'undefined' || kag === void"
                                     " || typeof kag.inStable == 'undefined' || kag.inStable) ? 1 : 0") == 1;
    std::vector<KAGLink> links = kagLinks();
    addKAGButtons(links);
    releaseKAGButtons();
    for (const SystemActionCommand &entry : systemActionCommands()) {
        if (systemActionName(entry).empty() && !findLink(links, entry.command))
            continue;
        if (stable)
            controls |= entry.control;
        else
            controls &= ~(tjs_int)entry.control;
    }
    return (uint32_t)controls;
}

namespace {

// The press a finger on the game's button would make: down, click, up at
// the button's centre, through the window's input queue.
bool pressButton(int index)
{
    const std::string script =
        "(function { var c = global.mikageButtons[" + std::to_string(index) + "];"
        " var x = c.width \\ 2, y = c.height \\ 2;"
        // The primary layer's parent is null, not void.
        " for (var l = c; !l.isPrimary; l = l.parent) { x += l.left; y += l.top; }"
        " return x < 0 || y < 0 || x > 32767 || y > 32767 ? -1 : x * 65536 + y;"
        "} incontextof global)()";
    const tjs_int at = runKAGScript(script.c_str());
    TVPWindow *window = TVPGetActiveWindow();
    if (!window)
        window = TVPMainWindow;
    if (at < 0 || !window) {
        MikageKRKRLogMessage("bridge", 4, at < 0 ? "pressButton.noPosition" : "pressButton.noWindow");
        return false;
    }
    const tjs_int x = at >> 16, y = at & 0xffff;
    TVPPostInputEvent(new tTVPOnMouseDownInputEvent(window, x, y, mbLeft, ssLeft));
    TVPPostInputEvent(new tTVPOnClickInputEvent(window, x, y));
    TVPPostInputEvent(new tTVPOnMouseUpInputEvent(window, x, y, mbLeft, 0));
    return true;
}

bool runCommand(int32_t command)
{
    const uint32_t controls = MikageKRKRGameControls();
    bool done = false;
    const char *how = "";
    const SystemActionCommand *action = systemActionCommand(command);
    const std::string name = action ? systemActionName(*action) : std::string();
    std::vector<KAGLink> links = kagLinks();
    addKAGButtons(links);
    // Turning auto or skip on the game's own way (its SystemAction entry,
    // else its button) runs what the game adds to it: waiting for voices,
    // its button states. Turning either off below is the same for every game.
    const bool modeOn = (command == MikageKRKRCommandAuto && (controls & MikageKRKRControlCanAuto) &&
                         !(controls & MikageKRKRControlAuto)) ||
                        (command == MikageKRKRCommandSkip && (controls & MikageKRKRControlCanSkip) &&
                         !(controls & MikageKRKRControlSkip));
    const std::string modeAction = modeOn
        ? systemActionName(command == MikageKRKRCommandAuto
                               ? SystemActionCommand{command, MikageKRKRControlCanAuto, {"auto", "autoMode"}}
                               : SystemActionCommand{command, MikageKRKRControlCanSkip, {"skip"}})
        : std::string();
    if (!name.empty() && (controls & action->control)) {
        const std::string script = "SystemAction." + name + "(), 1";
        done = runKAGScript(script.c_str()) == 1;
        how = ".systemAction";
    } else if (!modeAction.empty()) {
        const std::string script = "SystemAction." + modeAction + "(), 1";
        done = runKAGScript(script.c_str()) == 1;
        how = ".systemAction";
    } else if (const KAGLink *own = modeOn ? findLink(links, command) : nullptr) {
        if (own->layer < 0) {
            done = pressButton(own->index);
            how = ".button";
        } else {
            const std::string script = "kag.fore.messages[" + std::to_string(own->layer) + "].processLink(" +
                                       std::to_string(own->index) + "), 1";
            done = runKAGScript(script.c_str()) == 1;
            how = ".link";
        }
    } else if (const KAGLink *link = (controls & (action ? action->control : 0)) ? findLink(links, command) : nullptr) {
        // As a click on the game's own button.
        if (link->layer < 0) {
            done = pressButton(link->index);
            how = ".button";
        } else {
            const std::string script = "kag.fore.messages[" + std::to_string(link->layer) + "].processLink(" +
                                       std::to_string(link->index) + "), 1";
            done = runKAGScript(script.c_str()) == 1;
            how = ".link";
        }
    } else if (command == MikageKRKRCommandAuto && (controls & MikageKRKRControlCanAuto))
        done = runKAGScript(kKAGToggleAuto) == 1;
    else if (command == MikageKRKRCommandSkip && (controls & MikageKRKRControlCanSkip))
        done = runKAGScript(kKAGToggleSkip) == 1;
    else if (command == MikageKRKRCommandQuickSave && (controls & MikageKRKRControlCanQuickSave))
        done = runKAGScript(kKAGQuickSave) == 1;
    else if (command == MikageKRKRCommandQuickLoad && (controls & MikageKRKRControlCanQuickLoad))
        done = runKAGScript(kKAGQuickLoad) == 1;
    else if (command == MikageKRKRCommandBacklog && (controls & MikageKRKRControlCanBacklog))
        done = runKAGScript(kKAGBacklog) == 1;
    releaseKAGButtons();
    char message[96];
    std::snprintf(message, sizeof(message), "runtime.command.%d.%s%s", command, done ? "done" : "unavailable", how);
    MikageKRKRLogMessage("bridge", done ? 3 : 4, message);
    return done;
}

} // namespace

extern "C" bool MikageKRKRRunCommand(int32_t command)
{
    // The game's own dialog is up; its script is mid-call.
    if (modalSuspended)
        return false;
    return runOnStepStack([command] { return runCommand(command); });
}

extern "C" bool MikageKRKRSetControlSkip(bool held)
{
    if (!MikageSDLHostIsRunning())
        return false;
    if (held)
        krkrsdl3::KRKR_Trig_KeyDown(SDL_SCANCODE_LCTRL);
    else
        krkrsdl3::KRKR_Trig_KeyUp(SDL_SCANCODE_LCTRL);
    return true;
}

extern "C" bool MikageKRKRSendPointer(int32_t phase, float x, float y)
{
    if (!MikageSDLHostIsForeground() || phase < 0 || phase > 4)
        return false;
    int count = 0;
    SDL_Window **windows = SDL_GetWindows(&count);
    SDL_Window *window = windows && count > 0 ? windows[0] : nullptr;
    SDL_free(windows);
    int width = 0, height = 0, pixelWidth = 0, pixelHeight = 0;
    if (!window || !SDL_GetWindowSize(window, &width, &height) ||
        !SDL_GetWindowSizeInPixels(window, &pixelWidth, &pixelHeight) || width <= 0 || height <= 0)
        return false;
    // Drawable pixels, as the touch handlers send them.
    const int px = static_cast<int>(x * pixelWidth / width);
    const int py = static_cast<int>(y * pixelHeight / height);
    const tTVPMouseButton button = phase >= 3 ? mbRight : mbLeft;
    switch (phase) {
    case 0:
        krkrsdl3::KRKR_Trig_MouseMove(px, py);
        break;
    case 1:
    case 3:
        krkrsdl3::KRKR_Trig_MouseMove(px, py);
        krkrsdl3::KRKR_Trig_MouseDown(button, px, py);
        break;
    default:
        krkrsdl3::KRKR_Trig_MouseUp(button, px, py);
        break;
    }
    return true;
}

extern "C" void MikageKRKRRequestStop(void)
{
    DiagnosticScriptTraceScope traceScope;
    try {
        if (MikageSDLHostIsRunning()) {
            MikageSDLHostRequestStop();
            if (Application)
                Application->Terminate();
        }
    } catch (...) {
        MikageSDLHostFinish(SDL_APP_FAILURE, "C++ exception while stopping KRKR.");
    }
}

extern "C" bool MikageKRKRSetForeground(bool value)
{
    DiagnosticScriptTraceScope traceScope;
    MikageKRKRLogMessage("audio", 3, value ? "foreground.resume.requested" : "foreground.suspend.requested");
    try {
        if (MikageSDLHostIsForeground() == value)
            return true;
        krkrsdl3::TVPInvalidatePresentation(value ? "host.foreground" : "host.background");
        // The engine's idle compact now saves system variables at most once a
        // minute. iOS may terminate a backgrounded app without onClose, so
        // persist them here unless script is mid-execution.
        if (!value && MikageSDLHostIsRunning() && !stepDepth)
            TVPDoSaveSystemVariables();
        // The host deactivates the game (onDeactive) and its audio, or
        // reactivates them, through krkrEngine.
        return MikageSDLHostSetForeground(value);
    } catch (const eTJSSilent &) {
        // An activation handler called System.exit; the next foreground step
        // finishes the session normally.
        if (TVPTerminated) {
            MikageSDLHostSetForegroundState(value);
            return true;
        }
        MikageSDLHostSetLastError("Silent KRKR exception while changing KRKR foreground state.");
    } catch (const eTJS &error) {
        MikageSDLHostSetLastError(error.GetMessage().c_str());
    } catch (const std::exception &error) {
        MikageSDLHostSetLastError(error.what() ? error.what() : "C++ exception while changing KRKR foreground state.");
    } catch (...) {
        MikageSDLHostSetLastError("Unknown C++ exception while changing KRKR foreground state.");
    }
    TVPSetAudioSuspended(true);
    MikageSDLHostSetForegroundState(false);
    MikageKRKRLogMessage("audio", 5, MikageSDLHostLastError());
    return false;
}

extern "C" bool MikageKRKRGetStats(MikageKRKRStats *stats)
{
    if (!MikageSDLHostIsRunning() || !stats)
        return false;
    std::memset(stats, 0, sizeof(*stats));
    stats->framesPerSecond = currentFPS;
    stats->frameTimeMilliseconds = currentFrameTimeMS;
    stats->cpuFrameTimeMilliseconds = currentCpuFrameTimeMS;
    stats->maxCpuFrameTimeMilliseconds = currentMaxCpuFrameTimeMS;
    stats->drawCallsPerFrame = currentDrawCallsPerFrame;
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
    stats->layerPsTableUploads = layers.psTableUploads;
    stats->layerPsTableUploadedBytes = layers.psTableUploadedBytes;
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
    stats->layerGPURejectPsTables =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::PsTables)];
    stats->layerGPURejectAffineAlias =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::AffineAlias)];
    stats->layerGPURejectPerspectiveAlias =
        layers.gpuRejectCountByReason[rejectIndex(TVPLayerGPURejectReason::PerspectiveAlias)];
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
    stats->emoteUISyncReads = emotePerf.uiSyncReads;
    stats->emoteUISyncWaitNS = emotePerf.uiSyncWaitNS;
    stats->emoteCaptureUpdatePixels = emotePerf.captureUpdatePixels;
    stats->emoteCaptureUpdateFullPixels = emotePerf.captureUpdateFullPixels;
    stats->emoteCaptureRequests = emotePerf.captureRequests;
    stats->emoteCaptureFullCopies = emotePerf.captureFullCopies;

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
    stats->stepEventTimeNS = MikageSDLHostEventTimeNS();
    stats->stepIterateTimeNS = MikageSDLHostIterateTimeNS();
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
    stats->emoteLayerDirectDraws = profile.emoteLayerDirectDraws;

    if (SDL_Window *window = MikageKRKRGetSDLWindow()) {
        int width = 0, height = 0;
        SDL_GetWindowSizeInPixels(window, &width, &height);
        stats->drawableWidth = width;
        stats->drawableHeight = height;
    }
    if (const TVPSprite *sprite = krkrsdl3::KRKR_Get_Current_Sprite()) {
        stats->gameWidth = sprite->width;
        stats->gameHeight = sprite->height;
    }
    std::strncpy(stats->renderer, activeRenderer.c_str(), sizeof(stats->renderer) - 1);
    return true;
}

extern "C" bool MikageKRKRTakeLayerWorkProfile(MikageKRKRLayerWorkProfile *profile)
{
    krkrsdl3::layer_work::lastSuccessfulProfileWindowID=0;
    krkrsdl3::layer_work::lastSuccessfulProfileGeneration=0;
    if(!MikageSDLHostIsRunning() || !profile || !diagnosticCallback.load(std::memory_order_acquire)) return false;
    std::memset(profile,0,sizeof(*profile));
    try {
        const auto sample=krkrsdl3::layer_work::Take();
        profile->intervalNS=sample.intervalNS;
        // Bounds are part of the wire contract. Never emit a silently cut row.
        if(sample.stages.size()>=sizeof(profile->stages) || sample.transfers.size()>=sizeof(profile->transfers) ||
           sample.transferOrigins.size()>=sizeof(profile->transferOrigins) || sample.originOverflow.size()>=sizeof(profile->originOverflow) ||
           sample.transitionProfiles.size()>=sizeof(profile->transitionProfiles) || sample.transitionOverflow.size()>=sizeof(profile->transitionOverflow) ||
           sample.shrinkProfiles.size()>=sizeof(profile->shrinkProfiles) || sample.shrinkOverflow.size()>=sizeof(profile->shrinkOverflow) ||
           sample.shrinkReadWaitSampleCount>krkrsdl3::layer_work::MaxReadWaitSamples ||
           sample.frameSampleCount>krkrsdl3::layer_work::MaxFrameSamples) return false;
        std::memcpy(profile->stages,sample.stages.c_str(),sample.stages.size()+1);
        std::memcpy(profile->transfers,sample.transfers.c_str(),sample.transfers.size()+1);
        profile->amvDecodedFrames=sample.decodedFrames;
        profile->amvDecodedBytes=sample.decodedBytes;
        profile->workProfileVersion=sample.workProfileVersion;
        std::memcpy(profile->transferOrigins,sample.transferOrigins.c_str(),sample.transferOrigins.size()+1);
        std::memcpy(profile->originOverflow,sample.originOverflow.c_str(),sample.originOverflow.size()+1);
        profile->frameSampleCount=sample.frameSampleCount;
        std::copy_n(sample.frameIntervalNS.data(),sample.frameSampleCount,profile->frameIntervalNS);
        std::copy_n(sample.frameCpuWallNS.data(),sample.frameSampleCount,profile->frameCpuWallNS);
        profile->frameSamplesDropped=sample.frameSamplesDropped;
        profile->transitionProfileVersion=sample.transitionProfileVersion;
        std::memcpy(profile->transitionProfiles,sample.transitionProfiles.c_str(),sample.transitionProfiles.size()+1);
        profile->transitionProfilesDropped=sample.transitionProfilesDropped;
        std::memcpy(profile->transitionOverflow,sample.transitionOverflow.c_str(),sample.transitionOverflow.size()+1);
        profile->shrinkProfileVersion=sample.shrinkProfileVersion;
        std::memcpy(profile->shrinkProfiles,sample.shrinkProfiles.c_str(),sample.shrinkProfiles.size()+1);
        profile->shrinkProfilesDropped=sample.shrinkProfilesDropped;
        std::memcpy(profile->shrinkOverflow,sample.shrinkOverflow.c_str(),sample.shrinkOverflow.size()+1);
        profile->shrinkReadWaitSampleCount=sample.shrinkReadWaitSampleCount;
        std::copy_n(sample.shrinkReadWaitSamplesNS.data(),sample.shrinkReadWaitSampleCount,profile->shrinkReadWaitSamplesNS);
        profile->shrinkReadWaitSamplesDropped=sample.shrinkReadWaitSamplesDropped;
        krkrsdl3::layer_work::lastSuccessfulProfileWindowID=sample.spanRouteWindowID;
        krkrsdl3::layer_work::lastSuccessfulProfileGeneration=sample.spanRouteGeneration;
        return true;
    } catch(...) { return false; }
}

extern "C" uint64_t MikageKRKRLastLayerWorkProfileWindowID(void)
{
    if(!krkrsdl3::layer_work::enabled.load(std::memory_order_relaxed) ||
       krkrsdl3::layer_work::lastSuccessfulProfileGeneration!=
           krkrsdl3::layer_work::generation.load(std::memory_order_relaxed)) return 0;
    return krkrsdl3::layer_work::lastSuccessfulProfileWindowID;
}

extern "C" const char *MikageKRKRLayerWorkProfileOrigins(const MikageKRKRLayerWorkProfile *profile)
{
    return profile ? profile->transferOrigins : nullptr;
}

extern "C" const char *MikageKRKRLayerWorkProfileTransitions(const MikageKRKRLayerWorkProfile *profile)
{
    return profile && profile->transitionProfileVersion==1 ? profile->transitionProfiles : nullptr;
}

extern "C" const char *MikageKRKRLayerWorkProfileTransitionOverflow(const MikageKRKRLayerWorkProfile *profile)
{
    return profile && profile->transitionProfileVersion==1 ? profile->transitionOverflow : nullptr;
}

extern "C" const uint64_t *MikageKRKRLayerWorkProfileFrameIntervals(const MikageKRKRLayerWorkProfile *profile)
{
    return profile && profile->frameSampleCount <= krkrsdl3::layer_work::MaxFrameSamples ? profile->frameIntervalNS : nullptr;
}

extern "C" const uint64_t *MikageKRKRLayerWorkProfileFrameCpuWall(const MikageKRKRLayerWorkProfile *profile)
{
    return profile && profile->frameSampleCount <= krkrsdl3::layer_work::MaxFrameSamples ? profile->frameCpuWallNS : nullptr;
}

extern "C" const char *MikageKRKRLayerWorkProfileShrinks(const MikageKRKRLayerWorkProfile *profile)
{
    return profile && profile->shrinkProfileVersion==1 &&
        std::memchr(profile->shrinkProfiles,0,sizeof(profile->shrinkProfiles)) ? profile->shrinkProfiles : nullptr;
}

extern "C" const char *MikageKRKRLayerWorkProfileShrinkOverflow(const MikageKRKRLayerWorkProfile *profile)
{
    return profile && profile->shrinkProfileVersion==1 &&
        std::memchr(profile->shrinkOverflow,0,sizeof(profile->shrinkOverflow)) ? profile->shrinkOverflow : nullptr;
}

extern "C" const uint64_t *MikageKRKRLayerWorkProfileShrinkReadWait(const MikageKRKRLayerWorkProfile *profile)
{
    return profile && profile->shrinkProfileVersion==1 && profile->shrinkReadWaitSampleCount<=krkrsdl3::layer_work::MaxReadWaitSamples
        ? profile->shrinkReadWaitSamplesNS : nullptr;
}

extern "C" bool MikageKRKRTakeLayerTriangleProfile(MikageKRKRLayerTriangleProfile *profile)
{
    if (!MikageSDLHostIsRunning() || !profile || !diagnosticCallback.load(std::memory_order_acquire))
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
    return MikageSDLHostIsRunning();
}

extern "C" const char *MikageKRKRLastError(void)
{
    return MikageSDLHostLastError();
}

extern "C" void *MikageKRKRNativeWindow(void)
{
    SDL_Window *window = MikageKRKRGetSDLWindow();
    if (!window)
        return nullptr;
    return MikageSDLHostUIKitWindow(window);
}

extern "C" void MikageKRKRNotifyMenu(void)
{
    MikageSDLHostNotifyMenu();
}

extern "C" bool MikageKRKRCaptureFrame(MikageKRKRCapturedFrame *frame)
{
    if (!frame || frame->pixels || !MikageSDLHostIsRunning() || !MikageSDLHostIsForeground() ||
        ![NSThread isMainThread])
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
        } catch (...) {
            // Never let an engine exception cross the C boundary into Swift.
            SDL_Log("Native screenshot failed: unknown exception");
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
