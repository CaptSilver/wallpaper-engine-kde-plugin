Name:    wallpaper-engine-kde-plugin-qt6
Version: 1.4
Release: 1%{?dist}
Summary: A KDE wallpaper plugin integrating Wallpaper Engine (Plasma 6)

License: GPL-2.0-only
URL:     https://github.com/captsilver/wallpaper-engine-kde-plugin

# Built from a source tarball.  tools/scripts/make-srpm.sh produces it and
# stamps the real Version above -- the value in-tree is only the base, so that
# this spec stays parseable on its own (`rpmspec -q`, `dnf builddep`).
#
# The tarball must carry the recursed submodules: src/backend_scene has seven
# of its own, and the %%files licence rules below read third_party/*/LICENSE
# straight out of the tree.
Source0: %{name}-%{version}.tar.gz

# Optional %%check section (display-free + bus-free unit tests).  Opt in with
# `rpmbuild --with check`; the fast-path build is unchanged.
%bcond_with check

# Dependencies are declared as cmake()/pkgconfig() capabilities rather than
# package names.  The three distros this builds for share almost no names for
# the same libraries -- lz4-devel on Fedora is liblz4-devel on openSUSE and
# lib64lz4-devel on Mageia -- but they all generate the same capabilities from
# the .cmake and .pc files they ship.  Capabilities are what let one spec serve
# every chroot without a thicket of %%if branches.
BuildRequires: cmake
BuildRequires: extra-cmake-modules
BuildRequires: clang
BuildRequires: cmake(VulkanHeaders)
BuildRequires: cmake(VulkanLoader)
BuildRequires: cmake(Plasma)
BuildRequires: cmake(PlasmaActivities)
BuildRequires: cmake(KF6CoreAddons)
BuildRequires: cmake(KF6Package)
BuildRequires: cmake(KF6Config)
BuildRequires: cmake(KF6Notifications)
BuildRequires: cmake(KF6Crash)
BuildRequires: cmake(KF6GlobalAccel)
BuildRequires: cmake(KF6XmlGui)
BuildRequires: cmake(KF6I18n)
BuildRequires: cmake(Qt6Core)
BuildRequires: cmake(Qt6DBus)
BuildRequires: cmake(Qt6Network)
BuildRequires: cmake(Qt6Gui)
BuildRequires: cmake(Qt6Quick)
BuildRequires: cmake(Qt6Qml)
BuildRequires: cmake(Qt6WebChannel)
# src/CMakeLists.txt asks for both WebEngine components, and openSUSE splits
# WebEngine into per-module packages, so request each capability separately.
BuildRequires: cmake(Qt6WebEngineCore)
BuildRequires: cmake(Qt6WebEngineQuick)
BuildRequires: pkgconfig(liblz4)
BuildRequires: pkgconfig(mpv)
BuildRequires: pkgconfig(freetype2)
BuildRequires: pkgconfig(fontconfig)
BuildRequires: pkgconfig(libpulse)
# EGL/GL/GBM drive the hardware video-texture decoder.  pkg_check_modules treats
# them as optional, so leaving them undeclared yields a quietly degraded package
# at a zero exit status instead of a build failure.  On openSUSE they arrive
# transitively through mpv.pc, which is not something to depend on.
BuildRequires: pkgconfig(gl)
BuildRequires: pkgconfig(egl)
BuildRequires: pkgconfig(gbm)

%if 0%{?fedora}
# src/backend_mpv/CMakeLists.txt reads Qt6Gui_PRIVATE_INCLUDE_DIRS.  Only Fedora
# splits the private headers into their own package; openSUSE and Mageia ship
# them inside the ordinary Qt6 devel packages.
BuildRequires: qt6-qtbase-private-devel
%endif

%if %{with check}
BuildRequires: cmake(Qt6Test)
BuildRequires: cmake(Qt6QuickTest)
BuildRequires: nodejs
%endif

# rpm derives the library dependencies from the plugin's DT_NEEDED entries, so
# what it cannot see is what gets named here: the Plasma shell that hosts the
# wallpaper, and the QML import modules loaded by name at runtime.
%if 0%{?suse_version}
Requires: plasma6-workspace
Requires: qt6-webchannel-imports
Recommends: gstreamer-plugins-libav
Recommends: qt6-webengine-imports
%else
%if 0%{?mageia}
Requires: plasma-workspace
Recommends: gstreamer1.0-libav
Recommends: lib64qt6webenginequick6
%else
Requires: plasma-workspace
Requires: mpv-libs
Requires: lz4
Requires: qt6-qtwebchannel
# Not a linkage dependency and not source-visible: dropping it breaks
# rpm-ostree install on Bazzite. Install-time validated, so leave it be.
# No equivalent failure has been seen on openSUSE or Mageia, so it stays
# Fedora-only rather than being copied across on faith.
Requires: glew
Requires: kf6-knotifications
Requires: kf6-kcrash
Requires: kf6-kglobalaccel
Requires: kf6-ki18n
Recommends: gstreamer1-libav
Recommends: qt6-qtwebengine
%endif
%endif
Suggests: pipewire-pulseaudio
Suggests: vulkan-tools

%global _enable_debug_package 0
%global debug_package %{nil}

%description
A wallpaper plugin integrating Wallpaper Engine into KDE Plasma 6 wallpaper
settings. This is the RainyPixel fork with native C++ file operations
(no Python dependency), fixed KDE 6.5+ theme reactivity, and Plasma 6 / Qt6
support.

%prep
%autosetup -n %{name}-%{version}

%build
export CC=clang
export CXX=clang++
cmake -B _build \
      -S . \
      -DCMAKE_BUILD_TYPE=Release \
      %{?with_check:-DBUILD_TESTS=ON}
cmake --build _build -- %{?_smp_mflags}

%install
DESTDIR=%{buildroot} cmake --install _build \
      --prefix %{_prefix}

%check
%if %{with check}
# Run only the bus-free, display-free C++ tests in the RPM build chroot.
# Display-dependent suites (qmltestrunner) are labelled DISPLAY_NEEDED in
# tests/CMakeLists.txt; D-Bus-needing suites are labelled DBUS_NEEDED.  Both
# excluded here; the full-environment suite is covered by the local preflight
# gate on the developer side.
ctest --test-dir _build/tests \
      --output-on-failure \
      --label-exclude 'DISPLAY_NEEDED|DBUS_NEEDED'
%endif

%files
# The project's LICENSE + every vendored third-party license is installed by
# cmake under ${_datadir}/wek/licenses/.  Listing the directory once via
# %%license captures the project LICENSE (at wek/licenses/LICENSE) AND each
# per-library subdir AND THIRD_PARTY_LICENSES.md.  A previous standalone
# `%%license LICENSE` line tried to also stage the project license at the
# distro-standard /usr/share/licenses/<pkg>/LICENSE path, but cmake doesn't
# install there — rpmbuild then failed to find the file.  The wek/licenses
# tree is the single source of truth.
%license %{_datadir}/wek/licenses
# QML plugin (single payload directory under /usr/lib64).
%dir %{_libdir}/qt6
%dir %{_libdir}/qt6/qml
%dir %{_libdir}/qt6/qml/com
%dir %{_libdir}/qt6/qml/com/github
%dir %{_libdir}/qt6/qml/com/github/captsilver
%{_libdir}/qt6/qml/com/github/captsilver/wallpaperEngineKde/
# Plasma wallpaper packages (captsilver primary + catsout shim).
%dir %{_datadir}/plasma
%dir %{_datadir}/plasma/wallpapers
%{_datadir}/plasma/wallpapers/com.github.captsilver.wallpaperEngineKde/
%{_datadir}/plasma/wallpapers/com.github.catsout.wallpaperEngineKde/
# Migration script + /usr/bin symlink.
%dir %{_datadir}/wek
%{_datadir}/wek/scripts/
%{_bindir}/wek-migrate-from-catsout
# D-Bus introspection XML for the WallpaperEngine control surface.
%{_datadir}/dbus-1/interfaces/com.github.captsilver.WallpaperEngine.xml
# KNotification event taxonomy (System Settings -> Notifications -> Wallpaper Engine).
%{_datadir}/knotifications6/wek.notifyrc

%changelog
* Sat Jul 11 2026 packager - 1.4-1
- Wallpaper playlists: editor with ordered and shuffle playback, per-monitor scope
- Many scene-rendering fixes: puppet rigs/attachments, scripted clocks and text,
  animation-layer blending, scene-lighting flicker, long-runtime pixelation
- Volumetric fog lighting for scene wallpapers
- Web wallpapers: sandbox file:// access, gate feature permissions, cap HTTP cache
- Pause the renderer on screen lock / screensaver activation
- Stability: plasmashell crash + data-race fixes (texture-cache UAF, shader-compile
  and audio-capture races, malformed-model guards)
- Lower CPU/memory and faster wallpaper load across the renderer
- Packaging: Arch PKGBUILD + complete Debian build; translatable UI + accessibility

* Fri May 01 2026 packager - 1.3-1
- Plugin URI renamed: com.github.catsout.wallpaperEngineKde
  -> com.github.captsilver.wallpaperEngineKde
- Transitional shim package preserves existing user selectors during upgrade
- Auto-fallback: in-plugin first-load detection silently runs migration script
- New: tools/scripts/migrate-from-catsout.sh + /usr/bin/wek-migrate-from-catsout
- Existing per-desktop wallpaper settings migrated transparently (one-time)

* Wed Apr 22 2026 packager - 1.2-1
- Version bump to 1.2

* Sun Mar 29 2026 packager - 1.1-1
- Planar reflection, MSAA, HDR, geometry shaders, blur effects
- SceneScript: scene property control, timers, device detection, cursor events
- System audio capture, audio decoder fix
- Default compiler switched to Clang, 589 unit tests
- MDL/PKG v0023 support, text layer fixes

* Sat Mar 07 2026 packager - 1.0.1-1
- Update to version 1.0.1

* Sat Feb 28 2026 packager - 0-1
- Add kf6-kcoreaddons-devel and kf6-kpackage-devel to BuildRequires
- Port to RainyPixel fork: drop python3-websockets and Qt5 dep,
  update URL, modernise cmake, remove tarball/setup dependency
