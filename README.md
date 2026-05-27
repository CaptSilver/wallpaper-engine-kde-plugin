# Wallpaper Engine for KDE (Plasma 6)

A wallpaper plugin integrating [Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine) into KDE Plasma wallpaper settings.

> **This is a maintained fork** by [CaptSilver](https://github.com/CaptSilver) of the original [catsout/wallpaper-engine-kde-plugin](https://github.com/catsout/wallpaper-engine-kde-plugin) (no longer maintained), with Plasma 6 support and substantial new features.

## Install

### Ubuntu / Debian (.deb)

> **Note:** Requires Ubuntu 24.10+ or Debian Trixie+ (KDE Plasma 6 / KF6 / Qt6). Ubuntu 24.04 LTS only ships Plasma 5 and does not have the required KF6 packages.

Download the latest `.deb` from [Releases](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/releases):

```sh
sudo apt install ./wallpaper-engine-kde-plugin_*.deb
```

### Fedora / rpm-ostree / Bazzite (RPM)

Download the latest RPM from [Releases](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/releases):

Install:
```sh
# Standard Fedora
sudo dnf install ./wallpaper-engine-kde-plugin-qt6-*.fc43.x86_64.rpm

# rpm-ostree / Bazzite
rpm-ostree install ./wallpaper-engine-kde-plugin-qt6-*.fc43.x86_64.rpm
```

### Build from source

#### Dependencies

Ubuntu / Debian:
```sh
sudo apt install clang cmake ninja-build extra-cmake-modules pkg-config \
    libvulkan-dev libkf6package-dev libplasma-dev \
    plasma-workspace-dev qt6-base-dev qt6-base-private-dev \
    qt6-declarative-dev qt6-webchannel-dev \
    libmpv-dev liblz4-dev libfreetype-dev
```

Arch:
```sh
sudo pacman -S extra-cmake-modules plasma-framework gst-libav ninja \
base-devel mpv qt6-declarative qt6-webchannel vulkan-headers cmake lz4
```

Fedora:
```sh
# Add RPM Fusion repos (required for ffmpeg/mpv)
sudo dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Replace ffmpeg-free with full ffmpeg
sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
sudo dnf install -y ffmpeg-devel --allowerasing

sudo dnf install -y clang cmake extra-cmake-modules vulkan-headers \
    plasma-workspace-devel libplasma-devel kf6-plasma-devel \
    kf6-kcoreaddons-devel kf6-kpackage-devel \
    lz4-devel mpv-libs-devel freetype-devel \
    qt6-qtbase-private-devel qt6-qtwebchannel-devel
```

##### Optional: standalone Vulkan viewer

The `sceneviewer` binary under `src/backend_scene/standalone_view/` is a
debug-only viewer that renders a single scene package in its own window
(handy for triaging wallpaper bugs without restarting plasmashell). It
needs an extra dep on top of the baseline list above:

- Fedora:        `sudo dnf install -y glfw-devel`
- Ubuntu/Debian: `sudo apt install libglfw3-dev`
- Arch:          `sudo pacman -S glfw-x11` (or `glfw-wayland` / `glfw`)

Then build it separately from the main plugin:

~~~sh
cmake -B build/sceneviewer -S src/backend_scene/standalone_view -DCMAKE_BUILD_TYPE=Debug
cmake --build build/sceneviewer
~~~

See [CLAUDE.md "Standalone viewer for debugging"](CLAUDE.md) for the
Vulkan validation-layer flag and runtime usage.

#### Build and Install
```sh
# Download source
git clone https://github.com/captsilver/wallpaper-engine-kde-plugin.git
cd wallpaper-engine-kde-plugin

# Download submodules
git submodule update --init --force --recursive

# Configure and build
cmake -B build -S . -DCMAKE_BUILD_TYPE=Release
cmake --build build

# Install (system-wide)
sudo cmake --install build

# Restart plasmashell
systemctl --user restart plasma-plasmashell.service
```

#### Build RPM package (Fedora)

Useful for rpm-ostree/Bazzite systems where layered packages survive updates.

```sh
git clone https://github.com/captsilver/wallpaper-engine-kde-plugin.git
cd wallpaper-engine-kde-plugin

# Install build dependencies from spec (includes clang, cmake, Qt6, Vulkan, etc.)
sudo dnf builddep ./rpm/wek.spec

# RPM Fusion is required for mpv-libs-devel
sudo dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
sudo dnf install -y ffmpeg-devel --allowerasing

# Initialise submodules
git submodule update --init --force --recursive

# Optional: use tmpfs for faster builds
sudo mount -t tmpfs tmpfs ~/rpmbuild/BUILD

# Build the RPM (builds from the live checkout)
rpmbuild --define="commit $(git rev-parse HEAD)" \
    --define="reporoot $(pwd)" \
    -ba ./rpm/wek.spec

sudo umount ~/rpmbuild/BUILD

# Install
sudo dnf install ~/rpmbuild/RPMS/x86_64/wallpaper-engine-kde-plugin-qt6-*.rpm

# rpm-ostree / Bazzite
rpm-ostree install ~/rpmbuild/RPMS/x86_64/wallpaper-engine-kde-plugin-qt6-*.rpm
```

#### Build .deb from source

```sh
git clone https://github.com/captsilver/wallpaper-engine-kde-plugin.git
cd wallpaper-engine-kde-plugin

# Install build dependencies
sudo apt install \
    clang cmake ninja-build extra-cmake-modules pkg-config debhelper fakeroot \
    libvulkan-dev libkf6package-dev libplasma-dev \
    plasma-workspace-dev qt6-base-dev qt6-base-private-dev \
    qt6-declarative-dev qt6-webchannel-dev \
    libmpv-dev liblz4-dev libfreetype-dev

# Initialise submodules
git submodule update --init --force --recursive

# Build the .deb package
dpkg-buildpackage -us -uc -b

# Install
sudo apt install ../wallpaper-engine-kde-plugin_*.deb
```

## Activate in Plasma

After installing via any method:

1. Right-click the desktop → **Configure Desktop and Wallpaper...**
2. Open the **Wallpaper Type** dropdown and select **Wallpaper Engine for KDE**
3. Under **Steam Library**, point to the folder containing your `steamapps` directory
   - Usually `~/.local/share/Steam`
   - *Wallpaper Engine* must be installed in this library
4. Your subscribed Workshop wallpapers will appear in the list — select one and click **Apply**

> **Note:** After an rpm-ostree/Bazzite install you may need to reboot before the plugin starts working. For cmake installs, restarting plasmashell is enough: `systemctl --user restart plasma-plasmashell.service`

### Uninstall
1. Remove files listed in `build/install_manifest.txt`
2. `kpackagetool6 -t Plasma/Wallpaper -r com.github.captsilver.wallpaperEngineKde`

## Usage
1. *Wallpaper Engine* installed on Steam
2. Subscribe to some wallpapers on the Workshop
3. Select the *steamlibrary* folder on the Wallpapers tab of this plugin
   - The *steamlibrary* which contains the *steamapps* folder
   - This is usually `~/.local/share/Steam` by default
   - *Wallpaper Engine* needs to be installed in this *steamlibrary*

### Multi-monitor

Each screen has its own desktop (a Plasma "containment") and its own
Wallpaper Engine settings. To set a different wallpaper per screen:

1. Right-click the desktop you want to change → **Configure Desktop and Wallpaper…**
2. Pick a wallpaper from the **Wallpapers** or **Videos** tab; click **Apply**.
3. Repeat on each screen.

> **Tip:** if both screens always change together, your screens are sharing
> one desktop. Open **System Settings → Workspace → Workspace Behavior →
> Virtual Desktops** (or right-click the panel → **Manage Panels and
> Desktops**) and ensure each screen has its own desktop.

Per-screen scope also applies to the **Background Color**, **Display
Mode**, **Mute Audio**, **Volume**, and per-wallpaper user properties —
every option in the right pane is stored under the containment that owns
the screen.

Playlists with **Active Playlist** set are intentionally **synchronized**
across screens — every screen cycles to the same wallpaper on the same
tick. To run different playlists per screen, activate one playlist on
each containment independently.

## Requirements
- KDE Plasma 6
- Qt 6
- Vulkan 1.1+
- C++20 compiler (Clang recommended, GCC 10+ also works)
- [Vulkan driver](https://wiki.archlinux.org/title/Vulkan#Installation) installed (AMD users: use RADV)

## Known Issues
- Some scene wallpapers may **crash** KDE
  - Remove `WallpaperSource` line in `~/.config/plasma-org.kde.plasma.desktop-appletsrc` and restart KDE to fix
- Mouse long press (to enter panel edit mode) is broken on desktop
- Screen Locking is not supported

## Diagnostics

The plugin honors several `WEKDE_*` environment variables for verbose
diagnostics. Set them before launching `plasmashell` (or, for the
standalone `sceneviewer`, before running the binary):

| Variable | Purpose |
|---|---|
| `WEKDE_PIPELINE_DIAG=1` | Dump the per-pass Vulkan render-graph layout on each reload (large output). |
| `WEKDE_TIME_DIAG=1` | Per-frame CPU timing of major render stages — useful for hunting wallpaper-specific perf cliffs. |
| `WEKDE_SCRIPT_DIAG=1` | Verbose SceneScript JS engine logging (`scenescript-dispatch-debug.md` in memory). |
| `WEKDE_DEBUG_PARTICLE=1` | Particle-system per-emitter trace. |
| `WEKDE_TEXT_DUMP_DIR=<dir>` | Dump each rasterized text glyph atlas to `<dir>`. |
| `WEKDE_PASS_DUMP_MEM_MB=<n>` | Cap memory used by `--dump-passes-dir` to `<n>` MB (prevents OOM on long sessions). |
| `WEKDE_SKIP_PARTICLE_CHILD_SUBSTR=<s>` | Skip particle objects whose name contains `<s>` — isolation tool. |
| `WEKDE_DISABLE_OVERBRIGHT_HDR=1` | Disable the overbright clamp in HDR post-processing pipeline. |

The standalone `sceneviewer` also accepts `--list-env-vars` to print the
same list at runtime, and `H` / `?` in the viewer prints keyboard
shortcuts.

## Support Status

### Scene Wallpapers
Supported via a custom Vulkan 1.1 renderer. Requires *Wallpaper Engine* installed for assets. Both 2D (orthographic) and 3D (perspective) scenes are supported.

**Rendering:**
- Layer compositing with blend modes (normal, translucent, additive)
- Particle systems (emitters, modifiers, trails, sprite sheets)
- Bloom, blur, and multi-pass post-processing effects
- Planar reflection
- HDR content pipeline (RGBA16F render targets, tonemapping)
- Geometry shaders (HLSL-to-GLSL translation)
- Puppet/skeletal animation
- Camera shake and parallax
- MSAA

**SceneScript (JavaScript):**
- Property scripts driving layer transforms, visibility, alpha, and colors at 30Hz
- Scene property control (bloom strength/threshold, clear color, camera, ambient/skylight lighting, point lights)
- Sound layer control (play/stop/pause/volume, audio spectrum via FFT)
- Timer API (setTimeout/setInterval), device detection, shared inter-script state
- Text layer dynamic content (clock/date scripts)
- Cursor events (click, enter, leave, down, up, move)
- User property overrides persisted per-wallpaper

**Text Layers:**
- FreeType rasterization with runtime font size control
- Script-driven dynamic text updates

### Web
Supported via QtWebEngine. HTML patching, Plasma 6 mouse input, and user property updates through QWebChannel.

### Video
- **MPV** (default) — libmpv playback
- **QtMultimedia** — GStreamer fallback

## Upgrading from versions ≤ 1.2 (catsout-id)

Version 1.3 renames the plugin's KDE id from
`com.github.catsout.wallpaperEngineKde` to `com.github.captsilver.wallpaperEngineKde`.
The upgrade is **fully automatic** — no user action required.

**What happens on upgrade:**

1. The new package installs both the renamed plugin and a transitional shim
   package at the old id, so existing wallpaper selections in your Plasma
   config keep resolving.
2. On the next plasmashell start (or session login), the plugin's first-load
   migration helper fires. It silently runs `wek-migrate-from-catsout`, which:
   - backs up your `~/.config/plasma-org.kde.plasma.desktop-appletsrc` to
     `~/.config/wek-migration-backup/<timestamp>/`,
   - rewrites every per-desktop wallpaper selection from the old id to the
     new id (including all containment-specific settings like Backend,
     WallpaperPath, MuteAudio),
   - removes the old plugin install and the transitional shim,
   - writes a marker at `~/.config/wekde/migrated-from-catsout` so the
     migration won't run twice,
   - restarts plasmashell.
3. After the restart, your wallpapers are back exactly as they were.

**Manual run** (e.g., to verify before upgrade, or to recover from a
non-standard session): `wek-migrate-from-catsout --dry-run` previews the
changes; `wek-migrate-from-catsout --auto` runs silently as the plugin
itself does.

**Recovery**: every run creates a timestamped backup. To revert, copy
`~/.config/wek-migration-backup/<timestamp>/plasma-org.kde.plasma.desktop-appletsrc`
back over `~/.config/plasma-org.kde.plasma.desktop-appletsrc` and remove the
marker file at `~/.config/wekde/migrated-from-catsout`.

**Version 1.4 will remove the transitional shim.** If you skip 1.3 and
upgrade directly from 1.2 to 1.4+, the auto-migration cannot fire because
the shim won't be present — in that case run `wek-migrate-from-catsout`
manually after upgrade.

## Acknowledgments
- RainyPixel fork: [RainyPixel/wallpaper-engine-kde-plugin](https://github.com/rainypixel/wallpaper-engine-kde-plugin)
- Original project: [catsout/wallpaper-engine-kde-plugin](https://github.com/catsout/wallpaper-engine-kde-plugin) (no longer maintained — this fork picks up where it left off)
- [RePKG](https://github.com/notscuffed/repkg)
- All open-source libraries used in this project
