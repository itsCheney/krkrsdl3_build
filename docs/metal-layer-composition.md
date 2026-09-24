# Experimental ordinary Layer composition on Metal

Branches: app `beta`; build and SDL core `mikage-beta`.
Stable renderer remains on app `main` / build and core `mikage`.

Default `metal` binds a process-lifetime hybrid RenderManager before any game
Layer is created. `software-metal` and `opengl` retain the software manager.
Initialization probes RGBA and R8 resources before binding and records a fallback
reason if unavailable. Layer shaders compile independently; failure logs a reason and retains native
Metal presentation with software composition.

## Supported paths

- RGBA8 Layer images/targets; R8 glyph coverage. Image decoding and FreeType stay
  on CPU. Province images always use the software factory.
- Copy, color/mask copy, opaque copy; ARGB/color/mask fills, plus opacity color fills and `_d`/`_a` variants.
- AlphaBlend (the software default already holds destination alpha), HDA,
  destination-alpha `_d` and additive-destination `_a`; constant-alpha variants.
- ApplyColorMap, `_d`, `_a` coverage/color/opacity; ordinary antialiased glyphs.
- Integer rectangles: nearest, fast linear, linear. Sampling matches software
  ResizeRGBA, including integer clipping adjustments and edge extrapolation.
  Single-pixel dimensions now safely replicate their only row/column. Negative
  extrapolation uses a defined ARM-compatible unsigned conversion.
- Other samplers, affine/perspective transforms, special text and transition
  methods execute the same canonical software methods through scoped views.
  Scaled reversed source rectangles retain software fallback.

Software methods and parameter IDs remain canonical and process-scoped. GPU
metadata follows opacity/color setters, including the full-opacity special
branch. `_d` uses the production opacity/negative-multiply tables, initialized
lazily after TVPGL initialization. Ordinary Layer formulas do not use Emote UV
or blend formulas.

Software reverse copy now honors half-open horizontal bounds instead of reading
one pixel before the source. Software Gray copy uses byte strides rather than
32-bit pixel strides. Script point/color/mask writes first sever shared texture
ownership, and Province point writes preserve their 8-bit index. Both prevent out-of-bounds access in edge fixtures.

## Synchronization and lifetime

GPU mutations invalidate CPU caches. Reads share a cache until content changes;
CPU writes dirty it and upload before the next GPU use. Pinned raw-pointer
textures remain CPU authoritative and preserve pointer addresses (including loaded-image exports); arbitrary
plugin writes are refreshed whenever they become GPU sources. Script Bitmap,
Layer and LayerEx exports use that path. GPU sources and overlapping self-copies
use independent snapshots. Destination-dependent kernels snapshot only the
written rectangle; on [Tier 2 read/write devices](https://developer.apple.com/documentation/metal/mtlreadwritetexturetier/tier2)
they snapshot their own pixel into registers before writing and reuse a
[serial compute encoder](https://developer.apple.com/documentation/metal/mtldispatchtype/serial).
Transfers, source-alias snapshots, non-Layer passes, readback and submission close
that encoder first, preserving ordered writes. Other devices retain rectangle
snapshots; overwrite kernels never read destination pixels. Unsupported
CPU methods currently read complete operand textures once per content version.
The backend additionally exposes tightly packed local RGBA/R8 readback and
validates region bounds. No permanent CPU mirror is created for GPU-only textures.

Single-pixel queries use a bounded sparse cache. Rectangle writes invalidate only
samples inside the written area; alpha-only hit tests also retain exact alpha
through RGB-only/HDA operations. Alpha-changing operations, unknown GPU writes
and full Emote captures invalidate affected samples. CPU write uploads invalidate
samples taken before an outstanding pointer was modified. An uncached query still
reads the current GPU pixels synchronously; hit testing never substitutes an old
animation frame. ClearTarget retains its render encoder so the following Emote
mesh or mask draws share the clear pass; transfers, compute and target changes
close that encoder in order.

Layers, character/cache resources and deferred deletions are cleared before
manager unbinding and backend shutdown. Any intentionally retained texture is
detached into CPU authority before its backend is destroyed. GPU resources never
escape into the process-lifetime method cache.

HUD/diagnostics report Layer composition separately from presentation, with
cumulative GPU operations, CPU fallbacks, upload/readback bytes, GPU resident
bytes, CPU cache bytes and pinned CPU texture count.

Steps taking at least 50 ms produce a `runtime.slowFrames` summary at most once
per statistics window (one second). Its event/iterate durations and event count
belong to the same worst step, and include blocking waits. Slow Emote load/play
calls emit `emote.slowOperation` at most once per second per operation type;
resource-load reports separate file loading from root TJS object construction,
including cache hits. These timings supplement rather than replace device GPU
profiling.

## Validation

`Tests/MetalLayer` compiles production RenderManager.cpp, tvpgl.cpp and modern
blend functions as the oracle. The fixture replaces platform scheduling and
bitmap allocation only. On macOS it runs native Metal under validation; elsewhere
a synchronous device double exercises texture/cache/session behavior and does
not claim to validate Metal byte formulas.

The matrix covers all supported methods/opacity endpoints, glyph coverage,
subrectangles, clipping during resize, dimensions of one, sampling, flips and
self-copy overlap. It checks exact copy/fill bytes and blend/linear error <= 1,
GPU-to-CPU-to-GPU interleaving, cache reuse, raw pointer writes, independent
textures, unsupported methods/transitions/affine/perspective, three session
unbinds, and deliberately retained textures. A 120-operation ordinary Layer and 320-glyph text
workload reports software CPU wall time and GPU encoding wall time, checks GPU
execution and zero CPU readbacks until explicit final validation. Native tests also verify texture-alias presentation
and screenshots preserving visible RGB even with zero stored alpha.

CI runs native Metal tests plus existing TJS shutdown, scene-cache and frame-time
checks, builds device/simulator frameworks and the app. Device validation still
needs real games: text effects, LayerEx plugins, pixel hit testing, screenshot and
save thumbnails, special transitions, consecutive Metal/software-Metal/OpenGL
sessions, repeated exits and background/foreground recovery. Compare identical
scenes against stable main; transfer/resident counters should settle and
supported paths should avoid recurring readbacks. GPU image decoding and full
special-operator migration are out of scope.

A separate Release performance run disables the validation layer; validation
CPU overhead must not be used as a device performance prediction. Tiny glyph
GPU dispatch overhead is reported independently from large Layer composition.

Offset animation/video updates now clip to canvas bounds while advancing the
source by clipped rows/columns. Empty and offscreen updates are no-ops. AlphaMovie
resizes its backing canvas to script screen dimensions and initializes new
canvas pixels to transparent; software updates use the same rectangle contract.

The overlay Exit button now requests the KRKR main-window user-close query.
The game owns its native confirmation/cancellation; the host continues stepping
and does not suspend foreground audio until the game actually exits. The forced
host stop remains available for interrupted startup/lifecycle cleanup.

Shutdown stops the image loader and runs compact/KAG save callbacks before
system at-exit and plugin unregistration. Save callbacks may execute scripts
inside plugin archives. An unsupported archive now raises a script exception
instead of entering the cache as a null archive pointer.
