# Can be built standalone:  cmake -B build/tests -S tests
# Or included from root with: -DBUILD_TESTS=ON
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    cmake_minimum_required(VERSION 3.16)
    project(WallpaperEngineKdeTests C CXX)
    set(CMAKE_CXX_STANDARD 20)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_CXX_EXTENSIONS OFF)
    enable_testing()
    set(WEKDE_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../src")
else()
    set(WEKDE_SRC_DIR "${CMAKE_SOURCE_DIR}/src")
endif()
# tst_webaudio includes kissfft .c sources; ensure the C compiler is enabled
# even when this CMakeLists is consumed from a parent project that defaults
# to CXX-only.
enable_language(C)

# Qt 6.6 floor — matches the primary find_package in src/CMakeLists.txt so a
# standalone tests configure errors clearly on a too-old Qt6 (Plasma 6 baseline).
find_package(Qt6 6.6 REQUIRED COMPONENTS Core Test)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

option(MUTATION_TESTING "Enable Mull mutation testing instrumentation" OFF)
if(MUTATION_TESTING)
    include(${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_scene/cmake/FetchMull.cmake)
endif()

option(COVERAGE "Enable Clang source-based coverage instrumentation" OFF)
if(COVERAGE)
    if(NOT CMAKE_CXX_COMPILER_ID MATCHES "Clang")
        message(FATAL_ERROR "COVERAGE requires Clang (found ${CMAKE_CXX_COMPILER_ID})")
    endif()
    set(_cov_compile_flags -fprofile-instr-generate -fcoverage-mapping -g -O0)
    set(_cov_link_flags -fprofile-instr-generate)
endif()

# Sanitizer plumbing (WEK_SANITIZE + wek_apply_sanitizers).  Same canonical
# helper the root + submodule include; idempotent guard makes a repeat include
# (when built from the parent) a no-op.  Referenced relative to this dir so a
# standalone `cmake -B build/tests -S tests` configure (e.g. the ASAN preflight
# leg) still declares the option.  Mirrors how FetchMull.cmake is referenced.
include(${CMAKE_CURRENT_SOURCE_DIR}/../src/backend_scene/cmake/WekSanitize.cmake)

# ── FileHelper unit tests ──────────────────────────────────────────────────────
# FileHelper::generateThumbnail uses ThumbnailGrabber (libmpv) when WEKDE_HAS_MPV
# is defined; otherwise it stubs to thumbnailReady(ok=false). CI without
# libmpv-devel still builds and exercises every other FileHelper code path.
find_package(PkgConfig REQUIRED)
pkg_check_modules(FHMPV mpv)

if(FHMPV_FOUND)
    add_executable(tst_filehelper
        tst_filehelper.cpp
        ${WEKDE_SRC_DIR}/FileHelper.cpp
        ${WEKDE_SRC_DIR}/backend_mpv/ThumbnailGrabber.cpp
        ${WEKDE_SRC_DIR}/qwebchannel.qrc
    )
    target_include_directories(tst_filehelper PRIVATE
        ${WEKDE_SRC_DIR}
        ${WEKDE_SRC_DIR}/backend_mpv
        ${FHMPV_INCLUDE_DIRS})
    target_link_libraries(tst_filehelper PRIVATE
        Qt6::Core Qt6::Test ${FHMPV_LIBRARIES})
    target_compile_options(tst_filehelper PRIVATE ${FHMPV_CFLAGS_OTHER})
    target_compile_definitions(tst_filehelper PRIVATE WEKDE_HAS_MPV)
else()
    message(STATUS "libmpv not found — building tst_filehelper without thumbnail support")
    add_executable(tst_filehelper
        tst_filehelper.cpp
        ${WEKDE_SRC_DIR}/FileHelper.cpp
        ${WEKDE_SRC_DIR}/qwebchannel.qrc
    )
    target_include_directories(tst_filehelper PRIVATE ${WEKDE_SRC_DIR})
    target_link_libraries(tst_filehelper PRIVATE Qt6::Core Qt6::Test)
endif()

if(MUTATION_TESTING)
    target_compile_options(tst_filehelper PRIVATE
        -fpass-plugin=${MULL_PLUGIN_PATH}
        -g -grecord-command-line
    )
endif()

if(COVERAGE)
    target_compile_options(tst_filehelper PRIVATE ${_cov_compile_flags})
    target_link_options(tst_filehelper PRIVATE ${_cov_link_flags})
endif()

add_test(NAME tst_filehelper COMMAND tst_filehelper -v2)
# A scanVideoFolder symlink-loop regression would hang; cap the suite so it
# fails loudly (TIMEOUT) instead of wedging CI/preflight.
set_tests_properties(tst_filehelper PROPERTIES TIMEOUT 120)

# ── PluginInfo property contract tests ───────────────────────────────────────
# version() is a pure-header inline (QStringLiteral(WEK_VERSION)); only the
# header is compiled in — PluginInfo.cpp is excluded because it includes
# SceneBackend.hpp which pulls in the full Vulkan backend.  Qt6::Core+Test
# suffices; no heavy backend link required.
#
# WEK_PROJECT_VERSION: tests/CMakeLists.txt is standalone-capable and declares
# its own project() with no VERSION clause, so PROJECT_VERSION is empty in
# that mode.  Read it from the superproject's VERSION file directly.
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    file(READ "${CMAKE_CURRENT_SOURCE_DIR}/../VERSION" _wek_version_str)
    string(STRIP "${_wek_version_str}" _wek_version_str)
else()
    set(_wek_version_str "${PROJECT_VERSION}")
endif()
add_executable(tst_plugininfo
    tst_plugininfo.cpp
    ${WEKDE_SRC_DIR}/PluginInfo.hpp
)
target_include_directories(tst_plugininfo PRIVATE ${WEKDE_SRC_DIR})
target_compile_definitions(tst_plugininfo PRIVATE
    WEK_VERSION="${_wek_version_str}")
target_link_libraries(tst_plugininfo PRIVATE Qt6::Core Qt6::Test)
if(COVERAGE)
    target_compile_options(tst_plugininfo PRIVATE ${_cov_compile_flags})
    target_link_options(tst_plugininfo PRIVATE ${_cov_link_flags})
endif()
if(MUTATION_TESTING)
    target_compile_options(tst_plugininfo PRIVATE
        -fpass-plugin=${MULL_PLUGIN_PATH}
        -g -grecord-command-line)
endif()
add_test(NAME tst_plugininfo COMMAND tst_plugininfo -v2)
set_tests_properties(tst_plugininfo PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# ── MprisMonitor color extraction tests ───────────────────────────────────────
find_package(Qt6 COMPONENTS Gui Network DBus Quick QUIET)
if(Qt6Gui_FOUND AND Qt6Quick_FOUND)
    add_executable(tst_mpriscolors
        tst_mpriscolors.cpp
        ${WEKDE_SRC_DIR}/MprisMonitor.cpp
    )
    target_include_directories(tst_mpriscolors PRIVATE ${WEKDE_SRC_DIR})
    target_link_libraries(tst_mpriscolors PRIVATE
        Qt6::Core Qt6::Test Qt6::Gui Qt6::Network Qt6::DBus Qt6::Quick)
    if(COVERAGE)
        target_compile_options(tst_mpriscolors PRIVATE ${_cov_compile_flags})
        target_link_options(tst_mpriscolors PRIVATE ${_cov_link_flags})
    endif()
    if(MUTATION_TESTING)
        target_compile_options(tst_mpriscolors PRIVATE
            -fpass-plugin=${MULL_PLUGIN_PATH}
            -g -grecord-command-line)
    endif()
    # Run under a private session bus when available so the self-registered
    # FakeMprisService round-trip cases (findActivePlayer / pollPosition) execute
    # instead of QSKIPping. dbus-run-session spins up a clean, empty bus for the
    # child; the test brings its own fake service, so no external MPRIS player is
    # needed. When dbus-run-session is absent the bare command is used and the
    # bus-dependent cases skip gracefully (current behaviour) — keeps the test
    # runnable everywhere.
    find_program(DBUS_RUN_SESSION dbus-run-session)
    if(DBUS_RUN_SESSION)
        add_test(NAME tst_mpriscolors
            COMMAND ${DBUS_RUN_SESSION} -- $<TARGET_FILE:tst_mpriscolors> -v2)
    else()
        message(STATUS "dbus-run-session not found — tst_mpriscolors runs without a private bus")
        add_test(NAME tst_mpriscolors COMMAND tst_mpriscolors -v2)
    endif()
    set_tests_properties(tst_mpriscolors PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

    # ── MouseGrabber event forwarding tests ───────────────────────────────────
    add_executable(tst_mousegrabber
        tst_mousegrabber.cpp
        ${WEKDE_SRC_DIR}/MouseGrabber.cpp
    )
    target_include_directories(tst_mousegrabber PRIVATE ${WEKDE_SRC_DIR})
    target_link_libraries(tst_mousegrabber PRIVATE
        Qt6::Core Qt6::Test Qt6::Gui Qt6::Quick)
    if(COVERAGE)
        target_compile_options(tst_mousegrabber PRIVATE ${_cov_compile_flags})
        target_link_options(tst_mousegrabber PRIVATE ${_cov_link_flags})
    endif()
    if(MUTATION_TESTING)
        target_compile_options(tst_mousegrabber PRIVATE
            -fpass-plugin=${MULL_PLUGIN_PATH}
            -g -grecord-command-line)
    endif()
    add_test(NAME tst_mousegrabber COMMAND tst_mousegrabber -v2)

    # ── TTYSwitchMonitor suspend/wake dispatch tests ──────────────────────────
    # The D-Bus connect in the ctor only succeeds against a live system bus
    # (gracefully degrades otherwise), but the slot logic + signal contract
    # is plain Qt code: exercise it directly without standing up a fake bus.
    add_executable(tst_ttyswitchmonitor
        tst_ttyswitchmonitor.cpp
        ${WEKDE_SRC_DIR}/TTYSwitchMonitor.cpp
    )
    target_include_directories(tst_ttyswitchmonitor PRIVATE ${WEKDE_SRC_DIR})
    target_link_libraries(tst_ttyswitchmonitor PRIVATE
        Qt6::Core Qt6::Test Qt6::Gui Qt6::Quick Qt6::DBus)
    if(COVERAGE)
        target_compile_options(tst_ttyswitchmonitor PRIVATE ${_cov_compile_flags})
        target_link_options(tst_ttyswitchmonitor PRIVATE ${_cov_link_flags})
    endif()
    if(MUTATION_TESTING)
        target_compile_options(tst_ttyswitchmonitor PRIVATE
            -fpass-plugin=${MULL_PLUGIN_PATH}
            -g -grecord-command-line)
    endif()
    add_test(NAME tst_ttyswitchmonitor COMMAND tst_ttyswitchmonitor -v2)
    set_tests_properties(tst_ttyswitchmonitor PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
endif()

# ── MpvBackend Q_PROPERTY round-trip tests ────────────────────────────────────
find_package(Qt6 COMPONENTS Gui Quick QUIET)
find_package(PkgConfig QUIET)
if(Qt6Gui_FOUND AND Qt6Quick_FOUND AND PkgConfig_FOUND)
    pkg_check_modules(MPV mpv)
    if(MPV_FOUND)
        add_executable(tst_mpvbackend
            tst_mpvbackend.cpp
            ${WEKDE_SRC_DIR}/backend_mpv/MpvBackend.cpp
        )
        target_include_directories(tst_mpvbackend PRIVATE
            ${WEKDE_SRC_DIR}/backend_mpv
            ${MPV_INCLUDE_DIRS})
        target_link_libraries(tst_mpvbackend PRIVATE
            Qt6::Core Qt6::Test Qt6::Gui Qt6::Quick ${MPV_LIBRARIES})
        target_compile_options(tst_mpvbackend PRIVATE ${MPV_CFLAGS_OTHER})
        if(COVERAGE)
            target_compile_options(tst_mpvbackend PRIVATE ${_cov_compile_flags})
            target_link_options(tst_mpvbackend PRIVATE ${_cov_link_flags})
        endif()
        if(MUTATION_TESTING)
            target_compile_options(tst_mpvbackend PRIVATE
                -fpass-plugin=${MULL_PLUGIN_PATH}
                -g -grecord-command-line)
        endif()
        # Offscreen Qt platform — these tests must not need a display.
        add_test(NAME tst_mpvbackend COMMAND tst_mpvbackend -v2)
        set_tests_properties(tst_mpvbackend PROPERTIES
            ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

        # ── ThumbnailGrabber tests (and async FileHelper::generateThumbnail) ──
        add_executable(tst_thumbnail_grabber
            tst_thumbnail_grabber.cpp
            ${WEKDE_SRC_DIR}/FileHelper.cpp
            ${WEKDE_SRC_DIR}/backend_mpv/ThumbnailGrabber.cpp
        )
        target_include_directories(tst_thumbnail_grabber PRIVATE
            ${WEKDE_SRC_DIR}
            ${WEKDE_SRC_DIR}/backend_mpv
            ${MPV_INCLUDE_DIRS})
        target_link_libraries(tst_thumbnail_grabber PRIVATE
            Qt6::Core Qt6::Test Qt6::Gui ${MPV_LIBRARIES})
        target_compile_options(tst_thumbnail_grabber PRIVATE ${MPV_CFLAGS_OTHER})
        target_compile_definitions(tst_thumbnail_grabber PRIVATE WEKDE_HAS_MPV)
        if(COVERAGE)
            target_compile_options(tst_thumbnail_grabber PRIVATE ${_cov_compile_flags})
            target_link_options(tst_thumbnail_grabber PRIVATE ${_cov_link_flags})
        endif()
        if(MUTATION_TESTING)
            target_compile_options(tst_thumbnail_grabber PRIVATE
                -fpass-plugin=${MULL_PLUGIN_PATH}
                -g -grecord-command-line)
        endif()
        add_test(NAME tst_thumbnail_grabber
                 COMMAND tst_thumbnail_grabber -v2)
        set_tests_properties(tst_thumbnail_grabber PROPERTIES
            ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
            WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
    else()
        message(STATUS "libmpv not found — skipping MpvBackend tests")
    endif()
endif()

# ── WebAudioBridge tests ──────────────────────────────────────────────────────
# Bridge between the scene-side AudioAnalyzer and web wallpapers (forwards
# 64L+64R FFT bands via QWebChannel).  We compile AudioAnalyzer and its
# kissfft sources into the test binary; AudioCapture is stubbed inside
# tst_webaudio.cpp so we don't pull in miniaudio / libpulse just to check
# the encoder + signal contract.
set(WEKDE_AUDIO_DIR    "${WEKDE_SRC_DIR}/backend_scene/src/Audio")
set(WEKDE_UTILS_DIR    "${WEKDE_SRC_DIR}/backend_scene/src/Utils")
set(WEKDE_KISSFFT_DIR  "${WEKDE_SRC_DIR}/backend_scene/third_party/kissfft")
add_executable(tst_webaudio
    tst_webaudio.cpp
    ${WEKDE_SRC_DIR}/WebAudioBridge.cpp
    ${WEKDE_AUDIO_DIR}/AudioAnalyzer.cpp
    ${WEKDE_UTILS_DIR}/Logging.cpp
    ${WEKDE_UTILS_DIR}/SceneProfiler.cpp
    ${WEKDE_UTILS_DIR}/Sha.cpp           # genSha1, used by Logging.cpp
    ${WEKDE_KISSFFT_DIR}/kiss_fft.c
    ${WEKDE_KISSFFT_DIR}/kiss_fftr.c
)
target_include_directories(tst_webaudio PRIVATE
    ${WEKDE_SRC_DIR}
    ${WEKDE_AUDIO_DIR}/include
    ${WEKDE_UTILS_DIR}/include
    ${WEKDE_UTILS_DIR}/include/Utils  # internal #includes drop the Utils/ prefix
    ${WEKDE_KISSFFT_DIR}
    ${WEKDE_SRC_DIR}/backend_scene/third_party  # for vog/sha1.hpp
)
target_link_libraries(tst_webaudio PRIVATE Qt6::Core Qt6::Test)
# Suppress kissfft C-source warnings (matches what wpAudio's CMakeLists does).
set_source_files_properties(
    ${WEKDE_KISSFFT_DIR}/kiss_fft.c
    ${WEKDE_KISSFFT_DIR}/kiss_fftr.c
    PROPERTIES COMPILE_OPTIONS "-w"
)
if(MUTATION_TESTING)
    target_compile_options(tst_webaudio PRIVATE
        -fpass-plugin=${MULL_PLUGIN_PATH}
        -g -grecord-command-line)
endif()
if(COVERAGE)
    target_compile_options(tst_webaudio PRIVATE ${_cov_compile_flags})
    target_link_options(tst_webaudio PRIVATE ${_cov_link_flags})
endif()
add_test(NAME tst_webaudio COMMAND tst_webaudio -v2)
set_tests_properties(tst_webaudio PROPERTIES
    ENVIRONMENT "QT_QPA_PLATFORM=offscreen")

# ── MigrationHelper unit tests ────────────────────────────────────────────────
# MigrationHelper now does the catsout→captsilver merge in-process via KConfig
# (was: spawn migrate-from-catsout.sh that got cgroup-killed when plasmashell
# stopped). The test binary needs KF6::ConfigCore. Find the component
# directly (no umbrella `find_package(KF6 …)` because the standalone test
# build doesn't pull in ECM).
find_package(KF6Config REQUIRED)
add_executable(tst_migrationhelper
    tst_migrationhelper.cpp
    ${WEKDE_SRC_DIR}/MigrationHelper.cpp
)
target_include_directories(tst_migrationhelper PRIVATE ${WEKDE_SRC_DIR})
target_link_libraries(tst_migrationhelper PRIVATE Qt6::Core Qt6::Test KF6::ConfigCore)
if(COVERAGE)
    target_compile_options(tst_migrationhelper PRIVATE ${_cov_compile_flags})
    target_link_options(tst_migrationhelper PRIVATE ${_cov_link_flags})
endif()
if(MUTATION_TESTING)
    target_compile_options(tst_migrationhelper PRIVATE
        -fpass-plugin=${MULL_PLUGIN_PATH}
        -g -grecord-command-line)
endif()
add_test(NAME tst_migrationhelper COMMAND tst_migrationhelper -v2)

# ── PlaylistManager unit tests ────────────────────────────────────────────────
add_executable(tst_playlist_manager
    tst_playlist_manager.cpp
    ${WEKDE_SRC_DIR}/PlaylistManager.cpp
    ${WEKDE_SRC_DIR}/PlaylistsModel.cpp
    ${WEKDE_SRC_DIR}/PlaylistItemsModel.cpp
    ${WEKDE_SRC_DIR}/Playlist.cpp
    ${WEKDE_SRC_DIR}/FileHelper.cpp
    ${WEKDE_SRC_DIR}/qwebchannel.qrc
)
target_include_directories(tst_playlist_manager PRIVATE ${WEKDE_SRC_DIR})
target_link_libraries(tst_playlist_manager PRIVATE Qt6::Core Qt6::Test)
if(COVERAGE)
    target_compile_options(tst_playlist_manager PRIVATE ${_cov_compile_flags})
    target_link_options(tst_playlist_manager PRIVATE ${_cov_link_flags})
endif()
if(MUTATION_TESTING)
    target_compile_options(tst_playlist_manager PRIVATE
        -fpass-plugin=${MULL_PLUGIN_PATH}
        -g -grecord-command-line)
endif()
add_test(NAME tst_playlist_manager COMMAND tst_playlist_manager -v2)

# ── QML tests (qmltestrunner) ─────────────────────────────────────────────────
# Prefer Qt6-specific binary names. The bare `qmltestrunner` on some Debian/
# Ubuntu images is a qtchooser proxy that fails at runtime when no default Qt
# is selected ("could not find a Qt installation of ''") — keep it as a last-
# resort fallback only.
find_program(QMLTESTRUNNER NAMES qmltestrunner-qt6 qmltestrunner6 qmltestrunner)
if(QMLTESTRUNNER)
    add_test(NAME tst_qml
        COMMAND ${QMLTESTRUNNER} -input ${CMAKE_CURRENT_SOURCE_DIR}/qml
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
    set_tests_properties(tst_qml PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen;QML2_IMPORT_PATH=${CMAKE_CURRENT_SOURCE_DIR}/qml/_stubs:${CMAKE_CURRENT_SOURCE_DIR}/qml")

    # ── QML coverage (custom homegrown tracer, target: ≥80%) ──────────────────
    # Re-runs qml tests against an instrumented mirror of plugin/contents/ui,
    # collects per-function hits, and reports per-file/total coverage.
    find_package(Python3 REQUIRED COMPONENTS Interpreter)
    if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
        set(_wekde_repo_root "${CMAKE_CURRENT_SOURCE_DIR}/..")
    else()
        set(_wekde_repo_root "${CMAKE_SOURCE_DIR}")
    endif()
    set(_qmlcov_dir   "${CMAKE_BINARY_DIR}/_qmlcov")
    set(_qmlcov_root  "${_qmlcov_dir}/root")
    set(_qmlcov_inst  "${_qmlcov_root}/plugin/contents/ui")
    set(_qmlcov_tests "${_qmlcov_root}/tests/qml")
    set(_qmlcov_cat   "${_qmlcov_dir}/catalog.json")
    set(_qmlcov_log   "${_qmlcov_dir}/runlog.txt")
    set(_qmlcov_json  "${_qmlcov_dir}/report.json")
    set(_qmlcov_threshold "0.95")

    add_custom_target(qmlcov
        COMMAND ${CMAKE_COMMAND} -E rm -rf "${_qmlcov_dir}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${_qmlcov_root}/tests"
        COMMAND ${Python3_EXECUTABLE}
                "${_wekde_repo_root}/tools/qmlcov/instrument.py"
                --src     "${_wekde_repo_root}/plugin/contents/ui"
                --out     "${_qmlcov_inst}"
                --catalog "${_qmlcov_cat}"
        # Copy (not symlink): Qt canonicalizes symlinks before resolving `..`
        # in QML imports, which would defeat the instrumented mirror.
        COMMAND ${CMAKE_COMMAND} -E copy_directory
                "${CMAKE_CURRENT_SOURCE_DIR}/qml" "${_qmlcov_tests}"
        # Point the QML disk cache to a fresh per-run dir, then run.
        # QML_DISABLE_DISK_CACHE alone isn't enough — qmltestrunner-qt6 still
        # consults its cache dir on read, so we redirect it to a clean dir.
        # QML2_IMPORT_PATH order:
        #   _stubs/    — fake versions of native modules (wek-plugin, plasma5support,
        #                taskmanager, QtWebEngine) so production imports resolve
        #   _helpers/  — Helpers module providing test fakes (BackgroundFake)
        #   tests/qml  — Cov singleton (instrumentation tracer)
        COMMAND ${CMAKE_COMMAND} -E env
                QT_QPA_PLATFORM=offscreen
                "QML2_IMPORT_PATH=${_qmlcov_tests}/_stubs:${_qmlcov_tests}"
                QML_DISABLE_DISK_CACHE=1
                QV4_DISABLE_DISK_CACHE=1
                XDG_CACHE_HOME=${_qmlcov_dir}/cache
                bash -c "${QMLTESTRUNNER} -input ${_qmlcov_tests} > ${_qmlcov_log} 2>&1; cat ${_qmlcov_log}; true"
        COMMAND ${Python3_EXECUTABLE}
                "${_wekde_repo_root}/tools/qmlcov/report.py"
                --catalog   "${_qmlcov_cat}"
                --runlog    "${_qmlcov_log}"
                --threshold "${_qmlcov_threshold}"
                --json-out  "${_qmlcov_json}"
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        COMMENT "Computing QML coverage (target ≥${_qmlcov_threshold})"
        VERBATIM
        USES_TERMINAL
    )
else()
    message(STATUS "qmltestrunner not found — skipping QML tests")
endif()

# ── JavaScript tests (Node.js) ────────────────────────────────────────────────
find_program(NODE_EXECUTABLE NAMES node nodejs)
if(NODE_EXECUTABLE)
    # CONFIGURE_DEPENDS: re-run the glob at build time so a newly-added
    # *.test.mjs is picked up without a manual reconfigure (this glob feeds a
    # test command's argument list, not a compiled target's sources, so it is
    # the right, low-risk use of CONFIGURE_DEPENDS).
    file(GLOB _js_test_files CONFIGURE_DEPENDS
        "${CMAKE_CURRENT_SOURCE_DIR}/js/*.test.mjs")
    add_test(NAME tst_js
        COMMAND ${NODE_EXECUTABLE} --test ${_js_test_files}
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
else()
    message(STATUS "node not found — skipping JavaScript tests")
endif()

# ── C++ end-to-end integration harness (Phase 3) ──────────────────────────────
# Loads the real main.qml with `wallpaper` as a context property backed by a
# code-generated config QObject, so main.qml's reactive Connections fire. A second
# tier alongside the qmltestrunner rig; skips gracefully without Qt6QuickTest.
find_package(Qt6 COMPONENTS QuickTest Qml Quick QUIET)
if(Qt6QuickTest_FOUND AND Qt6Qml_FOUND AND Qt6Quick_FOUND)
    if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
        set(_wekde_repo_root_e2e "${CMAKE_CURRENT_SOURCE_DIR}/..")
    else()
        set(_wekde_repo_root_e2e "${CMAKE_SOURCE_DIR}")
    endif()
    find_package(Python3 REQUIRED COMPONENTS Interpreter)

    set(_e2e_gen_dir "${CMAKE_CURRENT_BINARY_DIR}/qml_integration_gen")
    set(_e2e_gen_hdr "${_e2e_gen_dir}/FakeConfiguration.gen.h")
    add_custom_command(
        OUTPUT  "${_e2e_gen_hdr}"
        COMMAND ${CMAKE_COMMAND} -E make_directory "${_e2e_gen_dir}"
        COMMAND ${Python3_EXECUTABLE}
                "${_wekde_repo_root_e2e}/tools/genconfig/gen_fake_config.py"
                "${_wekde_repo_root_e2e}/plugin/contents/config/main.xml"
                "${_e2e_gen_hdr}"
        DEPENDS "${_wekde_repo_root_e2e}/tools/genconfig/gen_fake_config.py"
                "${_wekde_repo_root_e2e}/plugin/contents/config/main.xml"
        COMMENT "Generating FakeConfiguration.gen.h from main.xml"
        VERBATIM)

    add_executable(tst_main_integration
        qml_integration/main.cpp
        qml_integration/FakeWallpaper.h
        "${_e2e_gen_hdr}")
    set_target_properties(tst_main_integration PROPERTIES AUTOMOC ON)
    target_include_directories(tst_main_integration PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/qml_integration"
        "${_e2e_gen_dir}")
    target_compile_definitions(tst_main_integration PRIVATE
        WEKDE_REPO_DIR="${_wekde_repo_root_e2e}"
        QUICK_TEST_SOURCE_DIR="${CMAKE_CURRENT_SOURCE_DIR}/qml_integration")
    target_link_libraries(tst_main_integration PRIVATE
        Qt6::QuickTest Qt6::Qml Qt6::Quick)
    add_test(NAME tst_main_integration COMMAND tst_main_integration)
    set_tests_properties(tst_main_integration PROPERTIES
        ENVIRONMENT "QT_QPA_PLATFORM=offscreen")
else()
    message(STATUS "Qt6QuickTest not found — skipping tst_main_integration (Phase 3)")
endif()

# ── Apply opt-in sanitizers to every C++ test target ──────────────────────────
# No-op unless -DWEK_SANITIZE=... is set.  Guarded by if(TARGET ...) because
# several targets are conditional on optional Qt components / libmpv.  The
# QML (tst_qml) and JS (tst_js) tests are add_test-only (qmltestrunner / node),
# not C++ executables, so they are not listed.
foreach(_wek_test_target
        tst_filehelper tst_plugininfo tst_mpriscolors tst_mousegrabber tst_mpvbackend
        tst_thumbnail_grabber tst_webaudio tst_migrationhelper
        tst_playlist_manager tst_main_integration tst_ttyswitchmonitor)
    if(TARGET ${_wek_test_target})
        wek_apply_sanitizers(${_wek_test_target})
    endif()
endforeach()

# ── Coverage report target ────────────────────────────────────────────────────
if(COVERAGE)
    find_program(LLVM_PROFDATA llvm-profdata REQUIRED)
    find_program(LLVM_COV      llvm-cov      REQUIRED)

    set(_cov_dir  ${CMAKE_BINARY_DIR}/coverage)
    set(_cov_prof ${_cov_dir}/merged.profdata)
    set(_cov_objs $<TARGET_FILE:tst_filehelper>)
    set(_cov_tests tst_filehelper)
    if(TARGET tst_mpriscolors)
        list(APPEND _cov_objs -object=$<TARGET_FILE:tst_mpriscolors>)
        list(APPEND _cov_tests tst_mpriscolors)
    endif()
    if(TARGET tst_mousegrabber)
        list(APPEND _cov_objs -object=$<TARGET_FILE:tst_mousegrabber>)
        list(APPEND _cov_tests tst_mousegrabber)
    endif()
    if(TARGET tst_mpvbackend)
        list(APPEND _cov_objs -object=$<TARGET_FILE:tst_mpvbackend>)
        list(APPEND _cov_tests tst_mpvbackend)
    endif()
    if(TARGET tst_thumbnail_grabber)
        list(APPEND _cov_objs -object=$<TARGET_FILE:tst_thumbnail_grabber>)
        list(APPEND _cov_tests tst_thumbnail_grabber)
    endif()
    if(TARGET tst_migrationhelper)
        list(APPEND _cov_objs -object=$<TARGET_FILE:tst_migrationhelper>)
        list(APPEND _cov_tests tst_migrationhelper)
    endif()
    if(TARGET tst_playlist_manager)
        list(APPEND _cov_objs -object=$<TARGET_FILE:tst_playlist_manager>)
        list(APPEND _cov_tests tst_playlist_manager)
    endif()

    # Ignore everything outside the user-facing "main project" scope:
    #   - Qt / system headers, tests themselves, MOC-generated code, third_party
    #   - backend_mpv/MpvBackend.cpp + qthelper.hpp: tested in isolation by
    #     tst_mpvbackend but with significant fixed-platform code paths
    #     (renderer init, GL bindings, libmpv embed) that aren't part of the
    #     "main project C++ coverage" target.  ThumbnailGrabber.cpp is kept
    #     because its API is fully exercisable from offscreen tests.
    set(_cov_ignore
        -ignore-filename-regex=\(^/usr/\|/Qt6/\|/tests/tst_\|_autogen/\|/moc_\|third_party\|backend_mpv/MpvBackend\|backend_mpv/qthelper\)
    )

    add_custom_target(coverage
        COMMAND ${CMAKE_COMMAND} -E rm -rf ${_cov_dir}
        COMMAND ${CMAKE_COMMAND} -E make_directory ${_cov_dir}
        COMMAND ${CMAKE_COMMAND} -E env
                LLVM_PROFILE_FILE=${_cov_dir}/%p.profraw
                ${CMAKE_CTEST_COMMAND} --output-on-failure
        COMMAND ${CMAKE_COMMAND} -E env bash -c
                "${LLVM_PROFDATA} merge -sparse ${_cov_dir}/*.profraw -o ${_cov_prof}"
        COMMAND ${LLVM_COV} report ${_cov_objs}
                -instr-profile=${_cov_prof} ${_cov_ignore}
        DEPENDS ${_cov_tests}
        WORKING_DIRECTORY ${CMAKE_BINARY_DIR}
        COMMENT "Running tests with coverage and generating report"
        VERBATIM
        USES_TERMINAL
    )

    add_custom_target(coverage-html
        COMMAND ${LLVM_COV} show ${_cov_objs}
                -instr-profile=${_cov_prof} ${_cov_ignore}
                -format=html -output-dir=${_cov_dir}/html
                -show-line-counts-or-regions
        DEPENDS coverage
        COMMENT "Generating HTML coverage report in ${_cov_dir}/html"
        VERBATIM
    )
endif()
