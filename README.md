# Wallpaper Engine for KDE (Plasma 6)

A wallpaper plugin integrating [Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine) into KDE Plasma wallpaper settings.

> **This is a maintained fork** of the original [catsout/wallpaper-engine-kde-plugin](https://github.com/catsout/wallpaper-engine-kde-plugin) with improvements for Plasma 6.

## Install

### Ubuntu / Debian (.deb)

> **Note:** Requires Ubuntu 24.10+ or Debian Trixie+ (KDE Plasma 6 / KF6 / Qt6). Ubuntu 24.04 LTS only ships Plasma 5 and does not have the required KF6 packages.

Download the latest `.deb` from [Releases](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/releases):

```sh
sudo apt install ./wallpaper-engine-kde-plugin_*.deb
```

### Fedora / rpm-ostree / Bazzite (RPM)

Download the latest RPM from [Releases](https://github.com/CaptSilver/wallpaper-engine-kde-plugin/releases):

```sh
curl -LO https://github.com/CaptSilver/wallpaper-engine-kde-plugin/releases/download/v1.1/wallpaper-engine-kde-plugin-qt6-1.1-1.fc43.x86_64.rpm
```

Install:
```sh
# Standard Fedora
sudo dnf install ./wallpaper-engine-kde-plugin-qt6-1.1-1.fc43.x86_64.rpm

# rpm-ostree / Bazzite
rpm-ostree install ./wallpaper-engine-kde-plugin-qt6-1.1-1.fc43.x86_64.rpm
```

### Build from source

#### Dependencies

Ubuntu / Debian:
```sh
sudo apt install clang cmake ninja-build extra-cmake-modules pkg-config \
    libvulkan-dev libkf6package-dev libplasma-dev \
    plasma-workspace-dev qt6-base-dev qt6-base-private-dev \
    qt6-declarative-dev qt6-websockets-dev qt6-webchannel-dev \
    libmpv-dev liblz4-dev libfreetype-dev
```

Arch:
```sh
sudo pacman -S extra-cmake-modules plasma-framework gst-libav ninja \
base-devel mpv qt6-declarative qt6-websockets qt6-webchannel vulkan-headers cmake lz4
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

sudo dnf install vulkan-headers plasma-workspace-devel kf6-plasma-devel \
    kf6-kcoreaddons-devel kf6-kpackage-devel gstreamer1-libav \
    lz4-devel mpv-libs-devel qt6-qtbase-private-devel libplasma-devel \
    qt6-qtwebchannel-devel qt6-qtwebsockets-devel cmake extra-cmake-modules
```

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
    qt6-declarative-dev qt6-websockets-dev qt6-webchannel-dev \
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
2. `kpackagetool6 -t Plasma/Wallpaper -r com.github.catsout.wallpaperEngineKde`

## Usage
1. *Wallpaper Engine* installed on Steam
2. Subscribe to some wallpapers on the Workshop
3. Select the *steamlibrary* folder on the Wallpapers tab of this plugin
   - The *steamlibrary* which contains the *steamapps* folder
   - This is usually `~/.local/share/Steam` by default
   - *Wallpaper Engine* needs to be installed in this *steamlibrary*

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

## Acknowledgments
- RainyPixel fork: [RainyPixel/wallpaper-engine-kde-plugin](https://github.com/rainypixel/wallpaper-engine-kde-plugin)
- Original project: [catsout/wallpaper-engine-kde-plugin](https://github.com/catsout/wallpaper-engine-kde-plugin)
- [RePKG](https://github.com/notscuffed/repkg)
- All open-source libraries used in this project
