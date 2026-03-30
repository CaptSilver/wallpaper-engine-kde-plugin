# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Wallpaper Engine KDE Plugin — a plugin for KDE Plasma 6 that integrates Wallpaper Engine (Steam) wallpapers into the Linux desktop. Supports Scene (2D/3D), Web, and Video wallpapers.

## Build

Default compiler: **Clang** (all packaging and CI use `CC=clang CXX=clang++`).

```bash
# Initialize submodules (required)
git submodule update --init --force --recursive

# Build
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Install
sudo cmake --install build

# Restart plasmashell
systemctl --user restart plasma-plasmashell.service
```

### Standalone viewer for debugging

```bash
# In the src/backend_scene/standalone_view/ directory
cmake -B build -S . -DCMAKE_BUILD_TYPE=Debug
cmake --build build

# Run with Vulkan validation layers
./sceneviewer --valid-layer <steamapps>/common/wallpaper_engine/assets <steamapps>/workshop/content/431960/<id>/scene.pkg
```

### Tests

```bash
# Main project tests (FileHelper — requires Qt6 Core+Test)
cmake -B build/tests -S tests -DCMAKE_BUILD_TYPE=Debug
cmake --build build/tests
./build/tests/tst_filehelper

# With mutation testing (requires Clang, auto-downloads Mull)
cmake -B build/tests -S tests -DCMAKE_BUILD_TYPE=Debug -DMUTATION_TESTING=ON
cmake --build build/tests
mull-runner-<ver> build/tests/tst_filehelper

# Submodule tests (backend_scene — requires doctest, Qt6 for SceneScript tests)
cmake -B build/sub -S src/backend_scene -DBUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Debug
cmake --build build/sub
./build/sub/src/Test/backend_scene_tests      # 427 tests
./build/sub/src/Test/scenescript_tests         # 162 tests
```

## Architecture

### Main plugin (this repo)

- **src/** — C++ code for the QML plugin
  - `plugin.cpp` — QML plugin entry point, registers types under `com.github.catsout.wallpaperEngineKde`
  - `FileHelper.cpp` — native C++ helper for file operations, wallpaper config CRUD, HTML patching for web wallpapers
  - `MouseGrabber` — mouse event capture and forwarding to target QML items
  - `TTYSwitchMonitor` — D-Bus listener for `PrepareForSleep` (TTY switch / suspend)
  - `PluginInfo` — exposes cache path and version to QML

- **src/backend_mpv/** — MPV backend for video wallpapers
  - Uses libmpv for playback
  - Static library `mpvbackend`

- **plugin/contents/ui/** — QML settings interface
  - `main.qml` — main plugin window
  - `config.qml` — configuration page
  - `WallpaperListModel.qml` — wallpaper list model
  - `backend/Scene.qml` — SceneViewer QML integration
  - `backend/Mpv.qml` — MPV QML integration

- **tests/** — Main project unit tests (QtTest)
  - `tst_filehelper.cpp` — 37 tests for FileHelper (readFile, getDirSize, getFolderList, config CRUD, patchedHtml, readActiveBindings)

- **rpm/wek.spec** — RPM packaging spec
- **debian/** — Debian packaging

### Scene renderer submodule (`src/backend_scene/`)

Git submodule: [CaptSilver/wallpaper-scene-renderer](https://github.com/CaptSilver/wallpaper-scene-renderer). This is the bulk of the codebase — a custom Vulkan 1.1 renderer for Wallpaper Engine scene files.

#### Key directories

- **src/VulkanRender/** — Vulkan rendering, resource management, render passes
  - `CustomShaderPass.cpp` — per-material shader pass execution, uniform upload
  - `SceneToRenderGraph.cpp` — converts Scene into render graph passes (bloom, reflection, etc.)
  - `FinPass.cpp` / `PrePass.cpp` — final composite and clear passes
- **src/RenderGraph/** — automatic render pass dependency resolution
- **src/Scene/include/Scene/** — scene data structures
  - `Scene.h` — top-level scene: cameras, lights, bloom, clearColor, ambientColor, skylightColor, nodes, scripts
  - `SceneNode.h` — transform hierarchy node (translate, scale, rotation, visibility)
  - `SceneCamera.h` — ortho/perspective camera, lookAt, FOV, path animation
  - `SceneLight.hpp` — point light (color, radius, intensity, premultiplied cache)
  - `SceneMaterial.h` — material with shader, constValues, constValuesDirty flag
- **src/Particle/** — particle system (emitters, initializers, operators, renderers)
- **src/Audio/** — audio via miniaudio, FFT spectrum analysis (KissFFT)
- **src/WPSceneParser.cpp** — main scene JSON parser (~2800 lines), builds Scene from wallpaper files
- **src/WPShaderParser.cpp** — HLSL-to-GLSL shader translation
- **src/WPShaderValueUpdater.cpp** — per-frame shader uniform updates (time, mouse, lights, audio, ambient/skylight)
- **src/SceneWallpaper.cpp** — thread-safe bridge: MainHandler (load/parse), RenderHandler (draw), pending update queues with mutexes
- **src/WPTextRenderer.cpp** — FreeType text rasterization

#### QML bridge

- **qml_helper/SceneBackend.cpp** — Qt/QML wrapper (~2200 lines), owns QJSEngine for SceneScript
  - `setupTextScripts()` — initializes JS engine with Vec3, WEMath, WEColor, thisScene, layer proxies, sound proxies, audio buffers, timers, scene properties
  - `evaluatePropertyScripts()` — 30Hz evaluation loop, dirty layer/sound/scene collection, C++ dispatch
  - `evaluateTextScripts()` / `evaluateColorScripts()` — text and color script evaluation
- **qml_helper/SceneTimerBridge.h** — Q_OBJECT providing setTimeout/setInterval to QJSEngine

#### Tests

- **src/Test/** — doctest-based unit tests
  - `test_SceneScript.cpp` — 162 tests for all JS APIs (Vec3, WEMath, WEColor, layer/sound/scene proxies, dirty tracking, IIFE compilation, timers, device detection)
  - Other test files: WPTexImageParser, SpecTexs, SpriteAnimation, WPShaderTransforms, StringUtils, Algorism, WPUserProperties, WPPuppet, ParticleModify, WPTextLayer

#### Third-party libraries (third_party/)

- Eigen — linear algebra
- glslang — GLSL to SPIR-V compilation
- SPIRV-Reflect — SPIR-V shader reflection
- nlohmann/json — JSON parsing
- miniaudio — cross-platform audio
- KissFFT — FFT for audio spectrum

## Packaging

- **RPM**: `rpm/wek.spec` — Fedora/Bazzite, builds from live git checkout with Clang
- **Deb**: `debian/` — Ubuntu/Debian, native format (`3.0 (native)`), skips `dwz` (Clang DWARF5 incompatibility)

## Debugging

plasmashell logs:
```bash
journalctl /usr/bin/plasmashell -f
# or
plasmashell --replace
```

Install `vulkan-validation-layers` for Vulkan debugging.

## Code Style

- C++20
- Formatting: `.clang-format` (4 spaces, 100 character line width)
- Qt6 / KF6 / Plasma 6
