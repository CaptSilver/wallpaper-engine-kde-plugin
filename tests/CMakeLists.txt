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

# ── FileHelper unit tests ──────────────────────────────────────────────────────
add_executable(tst_filehelper
    tst_filehelper.cpp
    ${WEKDE_SRC_DIR}/FileHelper.cpp
)
target_include_directories(tst_filehelper PRIVATE ${WEKDE_SRC_DIR})
target_link_libraries(tst_filehelper PRIVATE Qt6::Core Qt6::Test)

if(MUTATION_TESTING)
    target_compile_options(tst_filehelper PRIVATE
        -fpass-plugin=${MULL_PLUGIN_PATH}
        -g -grecord-command-line
    )
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
    add_test(NAME tst_mpriscolors COMMAND tst_mpriscolors -v2)
endif()
