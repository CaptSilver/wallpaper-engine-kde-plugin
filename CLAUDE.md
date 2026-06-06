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
./build/sub/src/Test/backend_scene_tests      # ~3000 doctest cases (excludes SceneScript)
./build/sub/src/Test/scenescript_tests         # ~750 doctest cases (SceneScript JS APIs)
```

### Local CI / preflight (the comprehensive gate)

This project uses a **local** verification gate, not cloud CI. `tools/scripts/preflight.sh`
is the single source of truth. The default run is the comprehensive gate:

1. **clang-format lint** — parent-repo C/C++ (excludes `build|tests/build|tests/fixtures`).
2. **Submodule build + tests** — `backend_scene_tests` + `scenescript_tests`.
3. **Main project ctest** — the `tests/` binaries.
4. **Scoped `-Werror` gate** — builds the four shippable / dlopen'd targets
   (`WallpaperEngineKde`, `mpvbackend`, `wescene-renderer-qml`, `wpParticle`)
   with `-Werror` (conversion family stays warning-only). FATAL on any
   `-Wall`/`-Wextra` regression in shippable code. Plumbing lives in
   `src/backend_scene/cmake/WekWerrorScoped.cmake`; build dir `build/werror-shippable`.
5. **Sanitizer gate (ASAN+UBSAN, submodule doctest suites)** — builds + runs
   `backend_scene_tests` and `scenescript_tests` under
   `-DWEK_SANITIZE=address,undefined` with `halt_on_error=1`. FATAL on any
   sanitizer finding. Build dir `build/asan-gate`. The wider parent-tests +
   full-suite ASAN run is still advisory via `--sanitize=address,undefined`.
6. **Fuzz smoke** — 9 libFuzzer harnesses, **seeded from `tests/fuzz_corpus/<target>/seed/`** (cold-start fallback when missing). `FUZZ_SECS=N` to tune (default 20s each). After long fuzz sessions, refresh the committed seeds with `tools/scripts/fuzz/minimize.sh <target>`. Size budget: 200 KB per target. Fuzz crash regressions are pinned under `tests/fixtures/fuzz_regressions/<target>/*.bin` and replayed by the parser doctests; pin a new artifact with `tools/scripts/fuzz/pin-regression.sh`.
Coverage + mutation are **opt-in** (the wired-in default-fatal versions were OOMing
30 GB boxes when run alongside parallel builds):
- **Coverage**: `tools/scripts/preflight.sh --coverage` (with `COVERAGE_FATAL=1` to gate, or
  `WEK_COVERAGE_REFRESH=1` to update `tests/.coverage-baseline.json`). Covers parent +
  submodule with 5 baseline keys (`cxx_lines`/`cxx_regions`/`qml`/`sub_lines`/`sub_regions`),
  0.5pp tolerance. Build dirs `build/impl-coverage` + `build/impl-coverage-sub`. ~3 min.
- **Mutation**: `tools/scripts/mutation.sh --diff-only --strict` for the per-PR gate, or bare
  `tools/scripts/mutation.sh` for the full ~10-20 min sweep. Mull-driven, `--workers=$(nproc)`,
  `--no-output` to skip GDB post-mortem (7× speedup), `--timeout 8000` per mutant. Tests
  use `tests/TestSandbox.h`'s `wek::test_sandbox::enableIsolated()` (per-process HOME
  under `$XDG_CACHE_HOME/wek-test-sandbox/proc-XXXXXX`) so parallel workers don't race
  on the shared `~/.qttest/` sandbox. MOC autogen filtered out (`_autogen/|/moc_|\.moc$`).
  Build dirs `build/impl-mutation` + `build/impl-mutation-sub`.

**Install the pre-push hook so the gate isn't silently bypassed:**

```bash
git config core.hooksPath tools/scripts/git-hooks   # enable (runs preflight on every `git push`)
git push --no-verify                           # skip once (avoid for non-trivial pushes)
git config --unset core.hooksPath              # disable
```

The hook is a 5-line wrapper that `exec`s `tools/scripts/preflight.sh`. A full run is ~3-5 min
(fuzz alone ≈ 2.3 min); a silent push is the hook working, not a hang. Opt-in coverage
and mutation legs are NOT in the default flow — invoke separately when wanted.

Preflight runs inside the Fedora distrobox automatically (it wraps commands in `distrobox enter`
when run from the host, or runs them directly when already inside the box). To run it inside a
plain Fedora container (or any CI context) **without** a distrobox-create attempt, export
`WEK_IN_CI=1` (or the standard `CI=true`) — that short-circuits the distrobox detection and runs
the gates directly. The script always resolves to the **superproject** working tree, so it is safe
to invoke from inside the `src/backend_scene` submodule.

**Opt-in legs** (standalone — lint + that one build/run, fresh build dirs, skip the normal flow):

```bash
tools/scripts/preflight.sh --werror     # build full project with -DWEK_WERROR=ON (see Warning flags)
tools/scripts/preflight.sh --coverage   # standalone: llvm-cov vs tests/.coverage-baseline.json
                                  # (NON-FATAL when standalone; the default gate runs this FATAL).
                                  # WEK_COVERAGE_REFRESH=1 to rewrite the baseline.
tools/scripts/preflight.sh --tsan       # WEK_SANITIZE=thread over the SceneScript + thread suites
tools/scripts/preflight.sh --sanitize=address,undefined   # ASAN+UBSAN over parent + submodule suites
```

`--werror` (whole-tree) is **non-fatal** today (renderer libs not yet audited
clean). `--coverage` (standalone) is non-fatal — use it for inspection or
`WEK_COVERAGE_REFRESH=1` baseline updates; the default flow runs the coverage
gate with `COVERAGE_FATAL=1`. `--sanitize=...` is **FATAL** on findings
(audited-clean submodule suites + parent tests). `--tsan` is a gate (FATAL on
a race). The default flow already covers the scoped `-Werror` over the 4
shippable targets + ASAN+UBSAN over the submodule doctest suites + coverage +
mutation `--diff-only` — the opt-in legs are the wider audit runs. See
`tools/scripts/preflight.sh --help`.

`tools/scripts/mutation.sh` runs Mull (auto-fetched via the submodule's `FetchMull.cmake`) over
parent test targets + the submodule's `backend_scene_tests`, diffs surviving mutants
against `tests/.mull-baseline.json`. **MOC autogen filtered out** (`_autogen/|/moc_|\.moc$`)
so Qt's autogen churn doesn't generate false positives. **`tools/scripts/mutation.sh --diff-only --strict`
is wired into the default preflight gate** (typical 0-10 min depending on touched files);
the bare `tools/scripts/mutation.sh` runs the full ~10-20 min suite. `--refresh-baseline` rewrites the
committed survivor set after intentional mutation-changing edits.

### Warning flags & `-Werror`

The renderer libs build with the full `warn_opts`
(`-Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion`, in
`src/backend_scene/src/CMakeLists.txt`). The shippable / dlopen'd targets — the plugin `.so`,
`backend_mpv`, and the `wescene-renderer-qml` bridge — carry the conservative
`wek_warn_opts` (`-Wall -Wextra`), defined in `src/backend_scene/cmake/WekWarnings.cmake` (one
canonical file, included from the root and submodule CMake so the parent and standalone-submodule
builds agree, mirroring `WekSanitize.cmake`). `wpParticle` is built with the renderer-libs
`warn_opts` (it is part of the particle system family that links into the renderer libs); both
warn lists honour the same `-Werror` rules, so the scoped gate treats it identically to the
other three shippable targets.

`-DWEK_WERROR=ON` (OFF by default) appends `-Werror` to the **first-party** warn lists only.
third_party is excluded **by construction** (it never receives these flags — no global
`add_compile_options`), and the signed/unsigned diagnostic family stays **warning-only** under
`-Werror` (`-Wno-error=conversion` / `-Wno-error=sign-conversion` / `-Wno-error=sign-compare`)
since it is noisy across the renderer. Verify with `tools/scripts/preflight.sh --werror`. The
whole-tree leg is **non-fatal** today: the four shippable targets are `-Wall -Wextra` clean
(and gated FATAL by the default flow via `cmake/WekWerrorScoped.cmake`), but the wider renderer
libs (Vulkan/RenderGraph/VulkanRender/Scene/Audio) still trip `-Wall/-Wextra` errors
(`-Wmismatched-tags`, `-Wunused-parameter/-function/-lambda-capture/-private-field`,
`-Wmissing-braces`) and need a separate audit pass before `-Werror` can gate the whole tree.
Set `WERROR_FATAL=1` to flip the whole-tree leg fatal once the renderer libs are clean.

The **scoped `-Werror`** plumbing (`cmake/WekWerrorScoped.cmake`) is what makes step 4 of
the default flow fatal: it applies `-Werror` (with the conversion family no-error-gated) to
just the four shippable targets, and is a no-op when `-DWEK_WERROR=ON` is set explicitly so
the two paths never double-apply.

### Supported distros (Qt6 + CMake floor matrix)

| Distro                | Qt6   | CMake   | Status                          |
|-----------------------|-------|---------|---------------------------------|
| Ubuntu 24.04 LTS      | 6.4   | 3.28    | **Not supported** (Qt too old)  |
| Ubuntu 24.10          | 6.6   | 3.30    | **Not supported** (Qt too old)  |
| Ubuntu 25.04          | 6.7   | 3.30    | Supported (floor of record)     |
| Ubuntu 26.04 LTS      | 6.8+  | 3.32+   | Next LTS (Apr 2026)             |
| Debian Bookworm       | 6.4   | 3.25    | **Not supported**               |
| Debian Trixie         | 6.7   | 3.31    | Supported                       |
| Fedora 41-43          | 6.7-6.8 | 3.30-3.32 | Primary RPM target          |
| Arch (rolling)        | 6.8+  | 4.x     | Supported                       |
| Bazzite (Fedora base) | follows Fedora | | Primary distribution target  |

Bump the CMake / Qt floor when the **lowest-row** column moves up:
- **CMake floor: 3.22** (margin: 3 minor versions below the lowest supported
  distro's 3.25, leaving room for environments that lag).
- **Qt6 floor: 6.7** (Ubuntu 25.04 / Debian Trixie value; bump to 6.8 once
  Ubuntu 25.04 is officially dropped from the supported-distro list).

## Architecture

### Main plugin (this repo)

- **src/** — C++ code for the QML plugin
  - `plugin.cpp` — QML plugin entry point. Registers 18 types under `com.github.captsilver.wallpaperEngineKde`:
    - Creatable: `PluginInfo` (cache path + version), `MouseGrabber`, `SceneViewer`, `Mpv`,
      `TTYSwitchMonitor`, `ScreenSaverMonitor`, `MprisMonitor`, `FileHelper`,
      `WebAudioBridge`, `WebUrlInterceptor`, `SafeWallpaperBridge`, `PlaylistManager`,
      `WekControl`, `WekNotifier`, `WekDiagnostics`.
    - Uncreatable (owned by `PlaylistManager`): `PlaylistsModel`, `PlaylistItemsModel`.
    - Singleton: `MigrationHelper`.
    A `com.github.catsout.…` shim package installs in parallel as a v1.3 migration aid
    (see `WEK_INSTALL_CATSOUT_SHIM` in the root `CMakeLists.txt`). When built with
    `WEKDE_HAS_GLOBALACCEL`, `WekShortcuts` is also instantiated once per process
    (not a QML type — bound to `qApp` for KGlobalAccel).
  - `FileHelper.cpp` — native C++ helper for file ops, wallpaper config CRUD, HTML patching for web wallpapers, thumbnail generation.
  - `MouseGrabber` — mouse event capture and forwarding to target QML items.
  - `TTYSwitchMonitor` — D-Bus listener for `PrepareForSleep` (TTY switch / suspend).
  - `ScreenSaverMonitor` — pauses the renderer when the screen locker or screensaver activates (logind / freedesktop ScreenSaver D-Bus).
  - `MprisMonitor` — MPRIS2 player state + colour extraction for media-aware wallpapers.
  - `PluginInfo` — exposes cache path and version to QML.
  - `WebAudioBridge` — Web-Audio API bridge between QtWebEngine wallpapers and host audio.
  - `WebUrlInterceptor` — QWebEngineUrlRequestInterceptor sandboxing `file://` fetches for web wallpapers.
  - `SafeWallpaperBridge` — QWebChannel-exposed bridge with a read-only property surface for web wallpapers.
  - `MigrationHelper` — runs the v1.2→1.3 catsout-id migration in-process via KConfig.
  - `PlaylistManager` / `PlaylistsModel` / `PlaylistItemsModel` — wallpaper playlist editor + runtime.
  - `WekControl` / `WekNotifier` / `WekDiagnostics` — host-side control surface, KNotification wrapper, and diagnostics collector used by the settings UI.

- **src/backend_mpv/** — MPV backend for video wallpapers
  - Uses libmpv for playback
  - Static library `mpvbackend`

- **plugin/contents/ui/** — QML settings interface
  - `main.qml` — main plugin window
  - `config.qml` — configuration page
  - `WallpaperListModel.qml` — wallpaper list model
  - `backend/Scene.qml` — SceneViewer QML integration
  - `backend/Mpv.qml` — MPV QML integration

- **tests/** — Main project unit tests (Qt6Test + QuickTest + node).
  - C++ binaries (18): `tst_filehelper`, `tst_plugininfo`, `tst_mpriscolors`,
    `tst_mousegrabber`, `tst_mpvbackend`, `tst_thumbnail_grabber`, `tst_webaudio`,
    `tst_migrationhelper`, `tst_playlist_manager`, `tst_ttyswitchmonitor`,
    `tst_screensavermonitor`, `tst_safewallpaperbridge`, `tst_weburlinterceptor`,
    `tst_wekcontrol`, `tst_weknotifier`, `tst_wekdiagnostics`, `tst_wekshortcuts`,
    `tst_activityhelper`.
  - QML tests: ~33 `tst_*.qml` files under `tests/qml/` (driven via qmltestrunner).
  - JS tests: `node --test` over `tests/js/*.test.mjs`.

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
- **src/WPSceneParser.cpp** — main scene JSON parser (~5500 lines), builds Scene from wallpaper files. `ParseImageObj` / `ParseTextObj` are orchestrators over ~30 extracted helpers (2026-05-26 decompose passes); `setupTextScripts` in the `qml_helper` bridge follows the same pattern.
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
  - `test_SceneScript.cpp` — ~750 tests for all JS APIs (Vec3, WEMath, WEColor, layer/sound/scene proxies, dirty tracking, IIFE compilation, timers, device detection).
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
