# krkrsdl3_build（Mikage 分支）

简体中文 · [English](README.en.md)

这是 [krkrsdl3_build](https://github.com/krkrsdl3/krkrsdl3_build) 的分支，负责构建 [Mikage Next](https://github.com/itsCheney/Mikage-Next) 使用的 KiriKiri 运行时。引擎源码位于 `cpp/` 子模块，指向 [itsCheney/krkrsdl3](https://github.com/itsCheney/krkrsdl3) 的同名分支。

在上游原有的 Windows、Linux、Android、WebAssembly、HarmonyOS、macOS 构建之外，这个分支增加了把引擎打包为可嵌入 iOS framework（`KRKRRuntime.framework`）的构建方式，以及宿主 App 调用的 C 接口。

## 分支

| 分支 | 用途 | `cpp/` 指向 |
| --- | --- | --- |
| `mikage` | Mikage `main` 使用的稳定版运行时 | krkrsdl3 `mikage` |
| `mikage-beta` | Mikage `beta` 使用的测试版运行时 | krkrsdl3 `mikage-beta` |
| `main` | 跟踪上游 krkrsdl3_build | 上游 krkrsdl3 |

合并方向固定为 `mikage-beta` → `mikage`，先合并 krkrsdl3，再合并本仓库并更新 `cpp/` 指针，最后在 Mikage Next 对应分支更新子模块。

## 宿主接口

`host/MikageKRKRRuntime.h` 是宿主 App 使用的 C 接口，主要包括：

- `MikageKRKRStart` / `MikageKRKRStep` / `MikageKRKRRequestExit` / `MikageKRKRRequestStop`：启动游戏、在宿主的主循环中逐帧推进、请求退出（经过游戏自己的确认）或强制停止。
- `MikageKRKRSetForeground`：切换前后台；进入后台时保存系统变量。
- `MikageKRKRGetStats` 及各类 profile 函数：帧率、CPU/GPU 时间、图层工作量等性能数据。
- `MikageKRKRCaptureFrame`：截取当前画面。
- `MikageKRKRSetSkippedMovies`、`MikageKRKRSetExperimentalEmote`、`MikageKRKRSetLogCallback`：跳过指定视频、选择 Emote 实现、接收引擎日志。

`KRKR_HOST_LIBRARY=ON` 时构建 `KRKRRuntime.framework`；为 `OFF`（默认）时仍构建原有的独立 iOS 程序。

## 构建

需要 CMake、vcpkg 和完整的 Xcode（iOS SDK）。iOS 预设使用 Xcode 生成器。依赖（SDL3、FFmpeg 等）通过 vcpkg 安装，首次构建较慢。

```sh
git clone --recursive -b mikage https://github.com/itsCheney/krkrsdl3_build.git
cd krkrsdl3_build
export VCPKG_ROOT=/path/to/vcpkg

# 嵌入式 framework（Mikage 使用的方式）
cmake --preset "iOS Device Config" -DKRKR_HOST_LIBRARY=ON -DUSE_RENDER_METAL=ON
cmake --build out/ios-device --config Release --parallel

# 独立的 iOS 程序
bash script/build-ios.sh device Release
```

Mikage Next 用 [`scripts/build-krkr-ios.sh`](https://github.com/itsCheney/Mikage-Next/blob/main/scripts/build-krkr-ios.sh) 分别构建真机和 Apple Silicon 模拟器版本，再合成 `KRKRRuntime.xcframework`。其他平台的构建脚本在 `script/` 下，预设见 `CMakePresets.json`。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `cpp/` | 引擎源码（krkrsdl3 子模块） |
| `host/` | 嵌入式 iOS framework 的宿主接口与实现 |
| `cmake/` | 按模块拆分的 CMake 构建脚本 |
| `script/` | 各平台构建脚本 |
| `vcpkg/` | 自定义 vcpkg port 与 triplet |
| `docs/` | 渲染架构、Metal 图层合成、GPU 回读、Emote 等设计文档 |
| `Res/` | 程序资源 |
| `android/`、`ohos/`、`emscripten/` | 安卓、鸿蒙、WebAssembly 工程 |

## 许可证

沿用 KiriKiri / 吉里吉里Z 的许可证及 krkrsdl3 补充条款，见 [LICENSE](LICENSE)。`cpp/` 中部分代码另有许可证（包括 GPL-3.0-or-later 的 Emote 动画实现），详见 krkrsdl3 仓库的 README。

感谢 KiriKiri、吉里吉里Z 与 krkrsdl3 的所有贡献者。
