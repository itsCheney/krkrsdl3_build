# krkrsdl3_build (Mikage fork)

[简体中文](README.md) · English

This is a fork of [krkrsdl3_build](https://github.com/krkrsdl3/krkrsdl3_build) that builds the KiriKiri runtime used by [Mikage Next](https://github.com/itsCheney/Mikage-Next). The engine source lives in the `cpp/` submodule, which points at the branch of the same name in [itsCheney/krkrsdl3](https://github.com/itsCheney/krkrsdl3).

On top of upstream’s Windows, Linux, Android, WebAssembly, HarmonyOS and macOS builds, this fork adds a build that packages the engine as an embeddable iOS framework (`KRKRRuntime.framework`), and the C interface a host app calls.

## Branches

| Branch | Purpose | `cpp/` points at |
| --- | --- | --- |
| `mikage` | Stable runtime, used by Mikage `main` | krkrsdl3 `mikage` |
| `mikage-beta` | Test runtime, used by Mikage `beta` | krkrsdl3 `mikage-beta` |
| `main` | Tracks upstream krkrsdl3_build | upstream krkrsdl3 |

Merges always go `mikage-beta` → `mikage`: krkrsdl3 first, then this repository with the `cpp/` pointer updated, then the submodule on the matching Mikage Next branch.

## Host interface

`host/MikageKRKRRuntime.h` is the C interface for the host app. The main calls are:

- `MikageKRKRStart` / `MikageKRKRStep` / `MikageKRKRRequestExit` / `MikageKRKRRequestStop`: start a game, advance it one frame at a time from the host’s run loop, ask it to quit (through the game’s own confirmation), or stop it.
- `MikageKRKRSetForeground`: move between foreground and background; system variables are saved on the way to the background.
- `MikageKRKRGetStats` and the profile functions: frame rate, CPU and GPU time, layer workload and other performance data.
- `MikageKRKRCaptureFrame`: capture the current frame.
- `MikageKRKRSetSkippedMovies`, `MikageKRKRSetExperimentalEmote`, `MikageKRKRSetLogCallback`: skip named movies, choose the Emote implementation, receive engine logs.

With `KRKR_HOST_LIBRARY=ON` the build produces `KRKRRuntime.framework`; with `OFF` (the default) it still builds the original standalone iOS app.

## Building

You need CMake, vcpkg and a full Xcode with the iOS SDK. The iOS presets use the Xcode generator. Dependencies such as SDL3 and FFmpeg are installed through vcpkg, so the first build takes a while.

```sh
git clone --recursive -b mikage https://github.com/itsCheney/krkrsdl3_build.git
cd krkrsdl3_build
export VCPKG_ROOT=/path/to/vcpkg

# Embeddable framework (what Mikage uses)
cmake --preset "iOS Device Config" -DKRKR_HOST_LIBRARY=ON -DUSE_RENDER_METAL=ON
cmake --build out/ios-device --config Release --parallel

# Standalone iOS app
bash script/build-ios.sh device Release
```

Mikage Next’s [`scripts/build-krkr-ios.sh`](https://github.com/itsCheney/Mikage-Next/blob/main/scripts/build-krkr-ios.sh) builds the device and Apple Silicon simulator frameworks and combines them into `KRKRRuntime.xcframework`. Build scripts for the other platforms are in `script/`, and the presets are in `CMakePresets.json`.

## Layout

| Path | Contents |
| --- | --- |
| `cpp/` | Engine source (the krkrsdl3 submodule) |
| `host/` | Host interface and implementation for the embeddable iOS framework |
| `cmake/` | CMake build scripts, split by module |
| `script/` | Per-platform build scripts |
| `vcpkg/` | Custom vcpkg ports and triplets |
| `docs/` | Design notes: rendering architecture, Metal layer composition, GPU readback, Emote and more |
| `Res/` | App resources |
| `android/`, `ohos/`, `emscripten/` | Android, HarmonyOS and WebAssembly projects |

## License

The KiriKiri / Kirikiri Z license and the krkrsdl3 supplementary clause apply; see [LICENSE](LICENSE). Some code in `cpp/` carries its own license, including the GPL-3.0-or-later Emote animation implementation; see the krkrsdl3 README for details.

Thanks to everyone who contributed to KiriKiri, Kirikiri Z and krkrsdl3.
