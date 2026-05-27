# CMake floor at 3.22 matches Debian Trixie (3.31), Ubuntu 24.10+ (3.30+),
# Fedora 41+ (3.30+), and Arch (rolling).  3.22 (Jan 2022) gives a comfortable
# margin from the lowest supported distro.  See CLAUDE.md "Build" section for
# the canonical supported-distro matrix.
cmake_minimum_required(VERSION 3.22)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

set(KF_MIN_VERSION  "5.68.0")   # KF5 series floor (legacy fallback path)
set(KF6_MIN_VERSION "6.0.0")    # KF6 series floor — matches Plasma 6.0 launch

file(READ "${CMAKE_CURRENT_SOURCE_DIR}/VERSION" WEK_PROJECT_VERSION)
string(STRIP "${WEK_PROJECT_VERSION}" WEK_PROJECT_VERSION)

project("WallpaperEngineKde" VERSION ${WEK_PROJECT_VERSION})

configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/plugin/metadata.json.in"
  "${CMAKE_CURRENT_BINARY_DIR}/metadata.json"
  @ONLY)
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/plugin/metadata.desktop.in"
  "${CMAKE_CURRENT_BINARY_DIR}/metadata.desktop"
  @ONLY)


set(CMAKE_SKIP_INSTALL_ALL_DEPENDENCY true)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
if(NOT OpenGL_GL_PREFERENCE)
  set(OpenGL_GL_PREFERENCE "GLVND")
endif()


option(USE_PLASMAPKG "Use plasmapkg2 to install plugin to user'home"
       ${USE_PLASMAPKG})

set(DEFAULT_BUILD_TYPE "RelWithDebInfo")
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  message(
    STATUS
      "Setting build type to '${DEFAULT_BUILD_TYPE}' as none was specified.")
  set(CMAKE_BUILD_TYPE
      "${DEFAULT_BUILD_TYPE}"
      CACHE STRING "Choose the type of build." FORCE)
endif()

if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX
      /usr
      CACHE PATH "set prefix to /usr" FORCE)
endif(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)


find_package(ECM REQUIRED NO_MODULE)
set(CMAKE_MODULE_PATH ${ECM_MODULE_PATH} ${CMAKE_MODULE_PATH})

if(ECM_VERSION_MAJOR EQUAL 6)
  find_package(Plasma REQUIRED)
  find_package(KF6 ${KF6_MIN_VERSION} REQUIRED COMPONENTS Package Config)
  include(KDEInstallDirs6)
else()
  find_package(KF5 ${KF_MIN_VERSION} REQUIRED COMPONENTS Package Plasma)
  include(KDEInstallDirs)
endif()

if(NOT DEFINED QT_MAJOR_VERSION)
message(FATAL_ERROR "Qt not found")
endif()

if(NOT USE_PLASMAPKG)
  plasma_install_package(plugin com.github.captsilver.wallpaperEngineKde wallpapers
                         wallpaper)

  set(_captsilver_pkg_dest
      "${KDE_INSTALL_DATADIR}/plasma/wallpapers/com.github.captsilver.wallpaperEngineKde")
  install(FILES "${CMAKE_CURRENT_BINARY_DIR}/metadata.json"
          DESTINATION "${_captsilver_pkg_dest}")
  install(FILES "${CMAKE_CURRENT_BINARY_DIR}/metadata.desktop"
          DESTINATION "${_captsilver_pkg_dest}")

  # Transitional shim: install a second package directory at the old catsout URI
  # so existing user installs with `wallpaperplugin=com.github.catsout.…` lines
  # in their plasma-org.kde.plasma.desktop-appletsrc keep resolving.
  # The shim is removed by scripts/migrate-from-catsout.sh on first plugin load
  # and from CMake entirely in the next release.
  option(WEK_INSTALL_CATSOUT_SHIM
         "Install transitional catsout-id shim KPackage (this release only)" ON)

  if(WEK_INSTALL_CATSOUT_SHIM)
    set(_shim_subdir
        plasma/wallpapers/com.github.catsout.wallpaperEngineKde)
    configure_file(
      "${CMAKE_CURRENT_SOURCE_DIR}/plugin/catsout-shim-metadata.json.in"
      "${CMAKE_CURRENT_BINARY_DIR}/catsout-shim-metadata.json"
      @ONLY)
    install(FILES "${CMAKE_CURRENT_BINARY_DIR}/catsout-shim-metadata.json"
            DESTINATION "${KDE_INSTALL_DATADIR}/${_shim_subdir}"
            RENAME metadata.json)
    # Relative symlink so the shim's contents/ resolves to the real package's
    # contents/ regardless of install prefix. Both packages always sit in the
    # same parent directory under share/plasma/wallpapers/.
    install(CODE "
      set(_shim_contents
          \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${KDE_INSTALL_DATADIR}/${_shim_subdir}/contents\")
      file(REMOVE \"\${_shim_contents}\")
      execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
        \"../com.github.captsilver.wallpaperEngineKde/contents\"
        \"\${_shim_contents}\")
    ")
  endif()
else()
  find_program(KPACKAGETOOL NAMES kpackagetool6 kpackagetool)
  if(${KPACKAGETOOL} STREQUAL "KPACKAGETOOL-NOTFOUND")
    message(FATAL_ERROR "kpackagetool not found")
  endif()

  add_custom_target(
    install_pkg
    COMMAND /bin/sh -c
            "${KPACKAGETOOL} -t Plasma/Wallpaper -i ./plugin 2>/dev/null || ${KPACKAGETOOL} -t Plasma/Wallpaper -u ./plugin"
    WORKING_DIRECTORY ${PROJECT_SOURCE_DIR}
    VERBATIM)
endif()

# ── Migration script ─────────────────────────────────────────────────────────
install(PROGRAMS scripts/migrate-from-catsout.sh
        DESTINATION ${KDE_INSTALL_DATADIR}/wek/scripts
        RENAME migrate-from-catsout.sh)
install(CODE "
  set(_link \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${KDE_INSTALL_BINDIR}/wek-migrate-from-catsout\")
  file(REMOVE \"\${_link}\")
  file(MAKE_DIRECTORY \"\$ENV{DESTDIR}\${CMAKE_INSTALL_PREFIX}/${KDE_INSTALL_BINDIR}\")
  execute_process(COMMAND \${CMAKE_COMMAND} -E create_symlink
    \"\${CMAKE_INSTALL_PREFIX}/${KDE_INSTALL_DATADIR}/wek/scripts/migrate-from-catsout.sh\"
    \"\${_link}\")
")

set(QMLPLUGIN_URI "com.github.captsilver.wallpaperEngineKde")
string(REPLACE "." "/" QMLPLUGIN_INSTALL_URI ${QMLPLUGIN_URI})

# Sanitizer plumbing (WEK_SANITIZE option + wek_apply_sanitizers helper).
# Canonical helper lives in the submodule's cmake/ so the SAME file is consumed
# whether the build is configured from here (-S .) or the submodule standalone
# (-S src/backend_scene).  Declared before add_subdirectory(src) so the option
# is visible to every target.
include(${CMAKE_CURRENT_SOURCE_DIR}/src/backend_scene/cmake/WekSanitize.cmake)

# Warning-flag plumbing (WEK_WERROR option + wek_warn_opts list).  Same
# canonical-file pattern as WekSanitize above so the parent and the submodule-
# standalone build share one definition.  Declared before add_subdirectory(src)
# so wek_warn_opts is in scope for the plugin .so and backend_mpv targets.
include(${CMAKE_CURRENT_SOURCE_DIR}/src/backend_scene/cmake/WekWarnings.cmake)

# Release-time hardening plumbing (WEK_HARDEN + WEK_LTO + WEK_USE_LLD).  Same
# canonical-file pattern; off by default so the developer flow is unchanged.
# Packagers / source-built users opt in via -DWEK_HARDEN=ON (and optionally
# -DWEK_LTO=ON for ThinLTO).  Declared before add_subdirectory(src) so
# wek_harden_opts is in scope for the plugin .so / backend_mpv targets.
include(${CMAKE_CURRENT_SOURCE_DIR}/src/backend_scene/cmake/WekHardening.cmake)

add_subdirectory(src)

option(BUILD_TESTS "Build unit tests (requires only Qt6 Core+Test)" OFF)
if(BUILD_TESTS)
    enable_testing()
    add_subdirectory(tests)
endif()
