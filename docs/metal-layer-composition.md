# Experimental ordinary Layer composition on Metal

Branch: `codex/metal-layer-composition` in the app, build and core repositories.
Stable renderer remains on app `main` / build and core `mikage`.

Default `metal` binds a process-lifetime hybrid RenderManager before any game
Layer is created. `software-metal` and `opengl` retain the software manager.
Layer shaders compile independently; failure logs a reason and retains native
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
32-bit pixel strides. Both prevent out-of-bounds access in edge fixtures.

## Synchronization and lifetime

GPU mutations invalidate CPU caches. Reads share a cache until content changes;
CPU writes dirty it and upload before the next GPU use. Pinned raw-pointer
textures remain CPU authoritative and preserve pointer addresses; arbitrary
plugin writes are refreshed whenever they become GPU sources. Script Bitmap,
Layer and LayerEx exports use that path. GPU sources and overlapping self-copies
use independent snapshots. Destination-dependent kernels snapshot only the
written rectangle; overwrite kernels never read destination pixels. Unsupported
CPU methods currently read complete operand textures once per content version.
No permanent CPU mirror is created for GPU-only textures.

Layers, character/cache resources and deferred deletions are cleared before
manager unbinding and backend shutdown. Any intentionally retained texture is
detached into CPU authority before its backend is destroyed. GPU resources never
escape into the process-lifetime method cache.

HUD/diagnostics report Layer composition separately from presentation, with
cumulative GPU operations, CPU fallbacks, upload/readback bytes, GPU resident
bytes, CPU cache bytes and pinned CPU texture count.

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
