#!/usr/bin/env bash
# Build RPM (Fedora), DEB (Ubuntu), and/or Arch package inside their
# respective distroboxes. Idempotent dependency installation: queries the
# package db and only installs what's missing so re-runs don't redownload
# anything (notably rpmfusion-free, which costs metadata on every fresh
# install).
#
# Usage:
#   tools/scripts/build-packages.sh                  # build all: rpm + deb + arch
#   tools/scripts/build-packages.sh rpm              # build rpm only
#   tools/scripts/build-packages.sh deb              # build deb only
#   tools/scripts/build-packages.sh arch             # build arch only
#   tools/scripts/build-packages.sh --check          # provision deps for selected
#                                              # targets; no build
#   tools/scripts/build-packages.sh arch --check     # provision arch deps only
#
# Containers (auto-created if missing):
#   fedora -> registry.fedoraproject.org/fedora-toolbox:latest
#   ubuntu -> quay.io/toolbx/ubuntu-toolbox:25.04
#   arch   -> quay.io/toolbx-images/archlinux-toolbox:latest
#
# Outputs (copied to $HOME for easy upload):
#   ~/wallpaper-engine-kde-plugin-qt6-<ver>.fc<n>.x86_64.rpm
#   ~/wallpaper-engine-kde-plugin_<ver>_amd64.deb
#   ~/wallpaper-engine-kde-plugin-dbgsym_<ver>_amd64.ddeb (if produced)
#   ~/wallpaper-engine-kde-plugin-<ver>-<rel>-x86_64.pkg.tar.zst

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
REPO_ROOT="$PWD"

# ── Args ──────────────────────────────────────────────────────────────────────
WANT_RPM=1
WANT_DEB=1
WANT_ARCH=1
CHECK_ONLY=0
TARGET_GIVEN=0
for arg in "$@"; do
    case "$arg" in
        rpm)  if [[ $TARGET_GIVEN == 0 ]]; then WANT_RPM=1; WANT_DEB=0; WANT_ARCH=0; TARGET_GIVEN=1; fi ;;
        deb)  if [[ $TARGET_GIVEN == 0 ]]; then WANT_RPM=0; WANT_DEB=1; WANT_ARCH=0; TARGET_GIVEN=1; fi ;;
        arch) if [[ $TARGET_GIVEN == 0 ]]; then WANT_RPM=0; WANT_DEB=0; WANT_ARCH=1; TARGET_GIVEN=1; fi ;;
        all)  WANT_RPM=1; WANT_DEB=1; WANT_ARCH=1; TARGET_GIVEN=1 ;;
        both) WANT_RPM=1; WANT_DEB=1; WANT_ARCH=0; TARGET_GIVEN=1 ;;
        --check|--check-only) CHECK_ONLY=1 ;;
        -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

# ── Output helpers ────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    GREEN=$'\033[1;32m'; BLUE=$'\033[1;34m'; YELLOW=$'\033[1;33m'; RED=$'\033[1;31m'; RESET=$'\033[0m'
else
    GREEN=""; BLUE=""; YELLOW=""; RED=""; RESET=""
fi
step() { printf '\n%s==>%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '%s  ok%s  %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s  warn%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail() { printf '\n%sFAIL:%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

# ── Distrobox containers ──────────────────────────────────────────────────────
FEDORA_BOX="fedora"
FEDORA_IMAGE="registry.fedoraproject.org/fedora-toolbox:latest"
UBUNTU_BOX="ubuntu"
# 25.04 (plucky) — the KF6 dev packages (libkf6package-dev, libkf6config-dev,
# libplasma-dev) are NOT in 24.04 (noble); the project's CI workflow targets
# 25.04 for the same reason.
UBUNTU_IMAGE="quay.io/toolbx/ubuntu-toolbox:25.04"
ARCH_BOX="arch"
# Official upstream Arch image on Docker Hub.  The quay.io/toolbx-images/
# archlinux-toolbox tag is currently gated (401 on anonymous pulls); the
# library/archlinux image works fine — distrobox layers on the toolbox
# niceties (passwd entries, sudoers) at first enter, so no functional gap.
ARCH_IMAGE="docker.io/library/archlinux:latest"

# ── Dependency manifests ──────────────────────────────────────────────────────
# Fedora: rpmbuild + spec BuildRequires. Mirrors rpm/wek.spec; rpm-build/
# rpmdevtools provide rpmbuild itself which fedora-toolbox doesn't ship.
# qtdeclarative/qtwebsockets are not in the spec but the CI Fedora job lists
# them; include explicitly so we don't rely on transitive resolution.
DEPS_FEDORA_BASE=(
    rpm-build rpmdevtools
    cmake extra-cmake-modules clang
    # llvm: provides llvm-ar / llvm-ranlib. CMake auto-picks these as the
    # archiver when the C compiler is Clang and they exist, then bakes the
    # absolute path into each target's link.txt. The Fedora `clang` package
    # does NOT pull `llvm`, so a container with only clang installed will
    # produce link.txt files referencing /usr/bin/llvm-ar — which then fail
    # with "no such file or directory" on first link of any static library.
    llvm
    vulkan-headers vulkan-loader-devel vulkan-validation-layers vulkan-tools
    plasma-workspace-devel libplasma-devel
    kf6-plasma-devel kf6-kcoreaddons-devel kf6-kpackage-devel kf6-kconfig-devel
    # KF6 integration: WekNotifier (KNotifications), WekShortcuts (KGlobalAccel
    # + KXmlGui's KActionCollection), plugin.cpp's KCrash registration, and
    # i18n() wrapping across QML+C++ (Wave 4 / 5).  Missing any of these
    # breaks `cmake --build` on a fresh distrobox.
    kf6-knotifications-devel kf6-kglobalaccel-devel kf6-kxmlgui-devel
    kf6-kcrash-devel kf6-ki18n-devel
    lz4-devel
    qt6-qtbase-private-devel qt6-qtwebchannel-devel
    qt6-qtdeclarative-devel qt6-qtwebsockets-devel
    # QtWebEngine: backend/QtWebView.qml uses WebEngineView + WebEngineProfile
    # + WebEngineUrlRequestInterceptor (sandbox path from SEC-WEB1/2).
    qt6-qtwebengine-devel
    freetype-devel
    # Sanitizer runtimes — libasan.so.8 is only available inside distrobox per
    # CLAUDE.md; required for ASAN builds of the standalone sceneviewer.
    libasan libubsan
)
# Lives in rpmfusion-free. mpv-libs-devel pulls full ffmpeg; the CI workflow
# installs the free mpv-devel (ffmpeg-free) which is fine for compile-test but
# produces an RPM that won't load codec-heavy video wallpapers — use the
# rpmfusion variant for distributable artifacts.
DEPS_FEDORA_RPMFUSION=(
    mpv-libs-devel
)
RPMFUSION_FREE_PKG="rpmfusion-free-release"

# Arch: makepkg + arch/PKGBUILD makedepends/depends.  Mirrors the GitHub CI
# Arch job + the PKGBUILD entries.  Arch ships unversioned KF6 framework
# package names (knotifications, kcrash, …) rather than Fedora-style
# kf6-knotifications-devel / Ubuntu libkf6notifications-dev.
DEPS_ARCH=(
    base-devel
    clang
    llvm
    cmake
    ninja
    extra-cmake-modules
    vulkan-headers
    vulkan-icd-loader
    libplasma
    plasma-workspace
    kconfig
    kcoreaddons
    kpackage
    knotifications
    kcrash
    kglobalaccel
    ki18n
    kxmlgui
    qt6-base
    qt6-declarative
    qt6-webchannel
    qt6-webengine
    mpv
    lz4
    freetype2
    libpulse
    # git + sudo are usually in the toolbox image; list them explicitly so a
    # minimal arch base also works (distrobox enter + makepkg need them).
    git
    sudo
    pkgconf
)

# Ubuntu: dpkg-buildpackage + debian/control Build-Depends.
DEPS_UBUNTU=(
    build-essential devscripts dpkg-dev debhelper fakeroot
    clang cmake extra-cmake-modules ninja-build pkg-config
    # llvm: same reason as the Fedora list — CMake bakes llvm-ar / llvm-ranlib
    # paths into link.txt when present, and on Ubuntu the `clang` package does
    # not pull the unversioned llvm tools, causing static-library link failures.
    llvm
    libvulkan-dev vulkan-validationlayers vulkan-tools
    libkf6package-dev libkf6config-dev libplasma-dev plasma-workspace-dev
    # KF6 integrations referenced by src/CMakeLists.txt (KNotification taxonomy,
    # DrKonqi KCrash, KI18n catalogs, KGlobalAccel shortcuts, KXmlGui for
    # KActionCollection).
    libkf6notifications-dev libkf6crash-dev libkf6i18n-dev
    libkf6globalaccel-dev libkf6xmlgui-dev
    qt6-base-dev qt6-base-private-dev qt6-declarative-dev
    qt6-websockets-dev qt6-webchannel-dev qt6-webengine-dev
    libmpv-dev liblz4-dev libfreetype-dev
    # Sanitizer runtimes — clang ships its own ASAN at /usr/lib/clang/<v>/lib,
    # but libasan8/libubsan1 are needed when invoking sanitizer-instrumented
    # binaries that link against the gcc runtime.
    libasan8 libubsan1
)

# ── Distrobox helpers ─────────────────────────────────────────────────────────
if ! command -v distrobox >/dev/null; then
    fail "distrobox not found on host"
fi

container_exists() {
    distrobox list 2>/dev/null \
        | awk -F'|' 'NR>1 { gsub(/^ +| +$/, "", $2); print $2 }' \
        | grep -qx "$1"
}

ensure_container() {
    local name="$1" image="$2"
    if container_exists "$name"; then
        ok "distrobox '$name' present"
    else
        warn "distrobox '$name' missing — creating from $image"
        distrobox create --yes -i "$image" -n "$name" \
            || fail "failed to create distrobox '$name'"
        ok "distrobox '$name' created"
    fi
}

# ── Fedora ────────────────────────────────────────────────────────────────────
fedora_missing() {
    # Print space-separated list of pkgs from $@ not installed in the box.
    local list="$*"
    distrobox enter "$FEDORA_BOX" -- bash -lc "
        missing=()
        for p in $list; do
            rpm -q \"\$p\" >/dev/null 2>&1 || missing+=(\"\$p\")
        done
        echo \"\${missing[*]}\"
    "
}

bootstrap_fedora() {
    step "Provision fedora distrobox"
    ensure_container "$FEDORA_BOX" "$FEDORA_IMAGE"

    if distrobox enter "$FEDORA_BOX" -- bash -lc "rpm -q $RPMFUSION_FREE_PKG" >/dev/null 2>&1; then
        ok "rpmfusion-free already installed"
    else
        warn "rpmfusion-free missing — installing"
        distrobox enter "$FEDORA_BOX" -- bash -lc "
            sudo dnf install -y \
                https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-\$(rpm -E %fedora).noarch.rpm
        " || fail "rpmfusion-free install failed"
        ok "rpmfusion-free installed"
    fi

    local missing
    missing="$(fedora_missing "${DEPS_FEDORA_BASE[@]}" "${DEPS_FEDORA_RPMFUSION[@]}")"
    if [[ -z "${missing// /}" ]]; then
        ok "all fedora deps already present"
    else
        warn "installing: $missing"
        # tsflags=noscripts: udisks2 (transitively pulled by plasma-workspace-devel)
        # has a %post that calls udevadm trigger, which fails inside an
        # unprivileged distrobox and rolls back the entire transaction.
        # Runtime scriptlets (tmpfiles, systemd unit symlinks, font caches)
        # don't matter for a build-only container; we re-run ldconfig
        # explicitly afterward so library lookups stay correct.
        distrobox enter "$FEDORA_BOX" -- bash -lc "
            sudo dnf install -y --setopt=tsflags=noscripts $missing && sudo ldconfig
        " || fail "dnf install failed"
        ok "fedora deps installed"
    fi

    # qmltestrunner ships in /usr/lib64/qt6/bin (qt6-qtdeclarative-devel) which is
    # NOT on PATH; CMake's find_program() looks for qmltestrunner-qt6/qmltestrunner6/
    # qmltestrunner. Without a discoverable binary the QML test suite (tst_qml,
    # qmlcov) is silently skipped. Worse, any host linuxbrew Qt 6.11 qmltestrunner
    # leaking into PATH is ABI-incompatible with the system Qt 6.10 plasma.core
    # plugin, so main.qml fails to load and the tests no-op. Link the system runner
    # under CMake's first-choice name so the matching-Qt runner always wins.
    distrobox enter "$FEDORA_BOX" -- bash -lc "
        sudo ln -sf /usr/lib64/qt6/bin/qmltestrunner /usr/local/bin/qmltestrunner-qt6
    " || fail "qmltestrunner-qt6 symlink failed"
    ok "qmltestrunner-qt6 linked (system Qt6 runner for QML tests)"
}

build_fedora() {
    step "Build RPM in fedora distrobox (_topdir=/tmp/rpmbuild — tmpfs)"
    [[ -f src/backend_scene/CMakeLists.txt ]] \
        || fail "src/backend_scene missing — run 'git submodule update --init --recursive' first"

    local commit
    commit="$(git rev-parse HEAD)"

    distrobox enter "$FEDORA_BOX" -- bash -lc "
        set -euo pipefail
        TOP=/tmp/rpmbuild
        mkdir -p \$TOP/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
        rm -f \$TOP/RPMS/x86_64/wallpaper-engine-kde-plugin-qt6-*.rpm
        rpmbuild \\
            --define='_topdir '\$TOP \\
            --define='commit $commit' \\
            --define='reporoot $REPO_ROOT' \\
            --undefine=_disable_source_fetch \\
            -ba '$REPO_ROOT/rpm/wek.spec'
    " || fail "rpmbuild failed"

    step "Copy RPM to \$HOME"
    distrobox enter "$FEDORA_BOX" -- bash -lc "
        set -euo pipefail
        rm -f \$HOME/wallpaper-engine-kde-plugin-qt6-*.rpm
        cp -v /tmp/rpmbuild/RPMS/x86_64/wallpaper-engine-kde-plugin-qt6-*.rpm \$HOME/
    " || fail "RPM copy failed"

    # Free the tmpfs space — _topdir's BUILD/BUILDROOT can be 1-2 GB.
    rm -rf /tmp/rpmbuild
    ok "RPMs in \$HOME, /tmp/rpmbuild cleared"
}

# ── Arch ──────────────────────────────────────────────────────────────────────
arch_missing() {
    local list="$*"
    distrobox enter "$ARCH_BOX" -- bash -lc "
        missing=()
        for p in $list; do
            pacman -Q \"\$p\" >/dev/null 2>&1 || missing+=(\"\$p\")
        done
        echo \"\${missing[*]}\"
    "
}

bootstrap_arch() {
    step "Provision arch distrobox"
    ensure_container "$ARCH_BOX" "$ARCH_IMAGE"

    # The Arch toolbox image ships with the keyring + mirror list pre-baked,
    # but on a long-lived box `pacman -Sy` can desync against the upstream
    # mirror snapshot.  Run -Syu unconditionally so the package db is fresh
    # before we query for missing pieces (makepkg's deps are versioned and an
    # out-of-date db produces 404s on the install pass).
    distrobox enter "$ARCH_BOX" -- bash -lc "
        sudo pacman -Syu --noconfirm
    " || fail "pacman -Syu failed"

    local missing
    missing="$(arch_missing "${DEPS_ARCH[@]}")"
    if [[ -z "${missing// /}" ]]; then
        ok "all arch deps already present"
    else
        warn "installing: $missing"
        # --needed: belt-and-braces; we already filtered via arch_missing,
        # but this is the canonical idempotent install flag.
        distrobox enter "$ARCH_BOX" -- bash -lc "
            sudo pacman -S --noconfirm --needed $missing
        " || fail "pacman -S failed"
        ok "arch deps installed"
    fi
}

build_arch() {
    step "Build pkg.tar.zst in arch distrobox"
    [[ -f src/backend_scene/CMakeLists.txt ]] \
        || fail "src/backend_scene missing — run 'git submodule update --init --recursive' first"
    [[ -f arch/PKGBUILD ]] \
        || fail "arch/PKGBUILD missing"

    # makepkg refuses to run as root; the distrobox user is unprivileged so
    # we're already in the right shape.  --noconfirm = unattended; -f =
    # overwrite existing artifacts in the cwd; --skipchecksums because the
    # PKGBUILD's source=() is empty (live-tree build, nothing to verify).
    # Default dep handling is "check, don't install" — bootstrap_arch already
    # ran `pacman -S` against DEPS_ARCH, so the check passes without -s.
    #
    # WEK_REPO_ROOT is the live working tree.  The PKGBUILD reads it via
    # `: \"\${WEK_REPO_ROOT:=\${startdir}/..}\"` so a standalone makepkg
    # invocation (Arch user running it themselves) still works without
    # WEK_REPO_ROOT in env.
    distrobox enter "$ARCH_BOX" -- bash -lc "
        set -euo pipefail
        cd '$REPO_ROOT/arch'
        rm -f wallpaper-engine-kde-plugin-*-x86_64.pkg.tar.zst
        WEK_REPO_ROOT='$REPO_ROOT' \\
            makepkg -f --noconfirm --skipchecksums
    " || fail "makepkg failed"

    step "Copy pkg.tar.zst to \$HOME"
    distrobox enter "$ARCH_BOX" -- bash -lc "
        set -euo pipefail
        rm -f \$HOME/wallpaper-engine-kde-plugin-*-x86_64.pkg.tar.zst
        cp -v '$REPO_ROOT/arch'/wallpaper-engine-kde-plugin-*-x86_64.pkg.tar.zst \$HOME/
        # Drop the PKGBUILD-side artifacts so the next run starts clean.
        rm -f '$REPO_ROOT/arch'/wallpaper-engine-kde-plugin-*-x86_64.pkg.tar.zst
        rm -rf '$REPO_ROOT/arch/src' '$REPO_ROOT/arch/pkg'
    " || fail "pkg.tar.zst copy failed"
    ok "pkg.tar.zst in \$HOME, arch/ work tree cleaned"
}

# ── Ubuntu ────────────────────────────────────────────────────────────────────
ubuntu_missing() {
    local list="$*"
    distrobox enter "$UBUNTU_BOX" -- bash -lc "
        missing=()
        for p in $list; do
            dpkg-query -W -f='\${Status}' \"\$p\" 2>/dev/null \
                | grep -q 'install ok installed' || missing+=(\"\$p\")
        done
        echo \"\${missing[*]}\"
    "
}

bootstrap_ubuntu() {
    step "Provision ubuntu distrobox"
    ensure_container "$UBUNTU_BOX" "$UBUNTU_IMAGE"

    local missing
    missing="$(ubuntu_missing "${DEPS_UBUNTU[@]}")"
    if [[ -z "${missing// /}" ]]; then
        ok "all ubuntu deps already present"
    else
        warn "installing: $missing"
        # apt-get update only when we actually need to install something —
        # avoids redownloading lists on every clean run.
        distrobox enter "$UBUNTU_BOX" -- bash -lc "
            sudo apt-get update && sudo apt-get install -y --no-install-recommends $missing
        " || fail "apt-get install failed"
        ok "ubuntu deps installed"
    fi
}

build_ubuntu() {
    step "Build DEB in ubuntu distrobox"
    [[ -f src/backend_scene/CMakeLists.txt ]] \
        || fail "src/backend_scene missing — run 'git submodule update --init --recursive' first"

    bash "$REPO_ROOT/tools/scripts/gen-debian-changelog.sh"

    distrobox enter "$UBUNTU_BOX" -- bash -lc "
        set -euo pipefail
        cd '$REPO_ROOT'
        # Clear stale artifacts in the parent dir so the cp glob below picks
        # up only this run's outputs.
        rm -f ../wallpaper-engine-kde-plugin*_*.deb \
              ../wallpaper-engine-kde-plugin*_*.ddeb \
              ../wallpaper-engine-kde-plugin*_*.buildinfo \
              ../wallpaper-engine-kde-plugin*_*.changes
        # -tc: run `debian/rules clean` after a successful build (removes
        # obj-x86_64-linux-gnu/ and other intermediates from the source tree).
        dpkg-buildpackage -uc -us -b -tc
    " || fail "dpkg-buildpackage failed"

    step "Copy DEB to \$HOME"
    local parent_dir
    parent_dir="$(dirname "$REPO_ROOT")"
    distrobox enter "$UBUNTU_BOX" -- bash -lc "
        set -euo pipefail
        rm -f \$HOME/wallpaper-engine-kde-plugin_*.deb \
              \$HOME/wallpaper-engine-kde-plugin-dbgsym_*.ddeb
        cp -v '$parent_dir'/wallpaper-engine-kde-plugin_*.deb \$HOME/
        cp -v '$parent_dir'/wallpaper-engine-kde-plugin-dbgsym_*.ddeb \$HOME/ 2>/dev/null || true
        # Drop the parent-dir artifacts dpkg-buildpackage scattered there.
        rm -f '$parent_dir'/wallpaper-engine-kde-plugin*_*.deb \
              '$parent_dir'/wallpaper-engine-kde-plugin*_*.ddeb \
              '$parent_dir'/wallpaper-engine-kde-plugin*_*.buildinfo \
              '$parent_dir'/wallpaper-engine-kde-plugin*_*.changes
    " || fail "DEB copy failed"
    ok "DEBs in \$HOME, source tree + parent dir cleaned"
}

# ── Drive ─────────────────────────────────────────────────────────────────────
# Per-target bootstrap+build so a deb provisioning failure can't block an
# otherwise-working rpm build (and vice-versa).
if [[ $CHECK_ONLY == 1 ]]; then
    [[ $WANT_RPM  == 1 ]] && bootstrap_fedora
    [[ $WANT_DEB  == 1 ]] && bootstrap_ubuntu
    [[ $WANT_ARCH == 1 ]] && bootstrap_arch
    printf '\n%sBootstrap complete — re-run without --check to build.%s\n' "$GREEN" "$RESET"
    exit 0
fi

if [[ $WANT_RPM == 1 ]]; then
    bootstrap_fedora
    build_fedora
fi
if [[ $WANT_DEB == 1 ]]; then
    bootstrap_ubuntu
    build_ubuntu
fi
if [[ $WANT_ARCH == 1 ]]; then
    bootstrap_arch
    build_arch
fi

step "Done"
[[ $WANT_RPM  == 1 ]] && ok "RPM:  $HOME/wallpaper-engine-kde-plugin-qt6-*.rpm"
[[ $WANT_DEB  == 1 ]] && ok "DEB:  $HOME/wallpaper-engine-kde-plugin_*.deb"
[[ $WANT_ARCH == 1 ]] && ok "ARCH: $HOME/wallpaper-engine-kde-plugin-*-x86_64.pkg.tar.zst"
