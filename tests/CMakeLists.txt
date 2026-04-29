# Can be built standalone:  cmake -B build/tests -S tests
# Or included from root with: -DBUILD_TESTS=ON
if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    cmake_minimum_required(VERSION 3.16)
    project(WallpaperEngineKdeTests CXX)
    set(CMAKE_CXX_STANDARD 20)
    set(CMAKE_CXX_STANDARD_REQUIRED ON)
    set(CMAKE_CXX_EXTENSIONS OFF)
    enable_testing()
    set(WEKDE_SRC_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../src")
else()
    set(WEKDE_SRC_DIR "${CMAKE_SOURCE_DIR}/src")
endif()

find_package(Qt6 REQUIRED COMPONENTS Core Test)
set(CMAKE_AUTOMOC ON)

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
    add_test(NAME tst_mpriscolors COMMAND tst_mpriscolors -v2)

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
    add_test(NAME tst_mousegrabber COMMAND tst_mousegrabber -v2)
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
        add_test(NAME tst_thumbnail_grabber
                 COMMAND tst_thumbnail_grabber -v2)
        set_tests_properties(tst_thumbnail_grabber PROPERTIES
            ENVIRONMENT "QT_QPA_PLATFORM=offscreen"
            WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
    else()
        message(STATUS "libmpv not found — skipping MpvBackend tests")
    endif()
endif()

# ── QML tests (qmltestrunner) ─────────────────────────────────────────────────
find_program(QMLTESTRUNNER NAMES qmltestrunner-qt6 qmltestrunner)
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
    file(GLOB _js_test_files
        "${CMAKE_CURRENT_SOURCE_DIR}/js/*.test.mjs")
    add_test(NAME tst_js
        COMMAND ${NODE_EXECUTABLE} --test ${_js_test_files}
        WORKING_DIRECTORY ${CMAKE_CURRENT_SOURCE_DIR})
else()
    message(STATUS "node not found — skipping JavaScript tests")
endif()

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

    # Ignore everything outside src/ (Qt headers, system libs, tests themselves,
    # MOC-generated code under _autogen/, and third_party).
    set(_cov_ignore
        -ignore-filename-regex=\(^/usr/\|/Qt6/\|/tests/tst_\|_autogen/\|/moc_\|third_party\)
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
