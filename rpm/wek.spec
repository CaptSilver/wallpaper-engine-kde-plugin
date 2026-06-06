Name:    wallpaper-engine-kde-plugin-qt6
Version: %(cat %{reporoot}/VERSION 2>/dev/null | tr -d '[:space:]')
Release: 1%{?dist}
Summary: A KDE wallpaper plugin integrating Wallpaper Engine (Plasma 6)

License: GPL-2.0-only
URL:     https://github.com/captsilver/wallpaper-engine-kde-plugin

# Built from a live git checkout.

# Optional %check section (display-free + bus-free unit tests).  Opt in with
# `rpmbuild --with check`; the fast-path build is unchanged.
%bcond_with check

BuildRequires: cmake extra-cmake-modules clang
BuildRequires: vulkan-headers
BuildRequires: plasma-workspace-devel libplasma-devel
BuildRequires: kf6-plasma-devel
BuildRequires: kf6-kcoreaddons-devel
BuildRequires: kf6-kpackage-devel
BuildRequires: kf6-kconfig-devel
BuildRequires: kf6-knotifications-devel
BuildRequires: kf6-kcrash-devel
BuildRequires: kf6-kglobalaccel-devel
BuildRequires: kf6-ki18n-devel
BuildRequires: lz4-devel
BuildRequires: mpv-libs-devel
BuildRequires: qt6-qtbase-private-devel
BuildRequires: qt6-qtwebchannel-devel
BuildRequires: freetype-devel
BuildRequires: pulseaudio-libs-devel

%if %{with check}
BuildRequires: qt6-qtbase-devel
BuildRequires: qt6-qtdeclarative-devel
BuildRequires: nodejs
%endif

Requires: plasma-workspace
Requires: mpv-libs
Requires: lz4
Requires: qt6-qtwebchannel
Requires: glew
Requires: kf6-knotifications
Requires: kf6-kcrash
Requires: kf6-kglobalaccel
Requires: kf6-ki18n
Recommends: gstreamer1-libav
Recommends: qt6-qtwebengine
Suggests: pipewire-pulse
Suggests: vulkan-tools

%global _enable_debug_package 0
%global debug_package %{nil}

%{?commit:%global shortcommit %(c=%{commit}; echo ${c:0:7})}
%{!?commit:%global shortcommit unknown}

%description
A wallpaper plugin integrating Wallpaper Engine into KDE Plasma 6 wallpaper
settings. This is the RainyPixel fork with native C++ file operations
(no Python dependency), fixed KDE 6.5+ theme reactivity, and Plasma 6 / Qt6
support.

%prep
# No-op: building directly from the git checkout at %{reporoot}
# Ensure submodules are initialised before calling wallpaper.sh:
#   git submodule update --init --force --recursive

%build
export CC=clang
export CXX=clang++
cmake -B %{_builddir}/wek-build \
      -S %{reporoot} \
      -DCMAKE_BUILD_TYPE=Release \
      %{?with_check:-DBUILD_TESTS=ON}
cmake --build %{_builddir}/wek-build -- %{?_smp_mflags}

%install
DESTDIR=%{buildroot} cmake --install %{_builddir}/wek-build \
      --prefix %{_prefix}

%check
%if %{with check}
# Run only the bus-free, display-free C++ tests in the RPM build chroot.
# Display-dependent suites (qmltestrunner) are labelled DISPLAY_NEEDED in
# tests/CMakeLists.txt; D-Bus-needing suites are labelled DBUS_NEEDED.  Both
# excluded here; the full-environment suite is covered by the local preflight
# gate on the developer side.
ctest --test-dir %{_builddir}/wek-build/tests \
      --output-on-failure \
      --label-exclude 'DISPLAY_NEEDED|DBUS_NEEDED'
%endif

%files
# The project's LICENSE + every vendored third-party license is installed by
# cmake under ${_datadir}/wek/licenses/.  Listing the directory once via
# %license captures the project LICENSE (at wek/licenses/LICENSE) AND each
# per-library subdir AND THIRD_PARTY_LICENSES.md.  A previous standalone
# `%license LICENSE` line tried to also stage the project license at the
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
* %(date +'%a %b %d %Y') packager - %{version}-%{release}.git%{shortcommit}
- Snapshot build from commit %{shortcommit} on %(date +'%Y-%m-%d %H:%M %Z')

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
