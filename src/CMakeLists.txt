# Qt 6.7 floor.  Supported distro matrix (canonical in CLAUDE.md):
#   * Ubuntu 25.04        - Qt 6.7
#   * Debian Trixie       - Qt 6.7
#   * Fedora 41+          - Qt 6.7+
#   * Arch (rolling)      - Qt 6.8+
# Pinning to the lowest meets-policy ensures a too-old Qt6 fails fast at
# configure with a clear error instead of late and cryptically.  Bump again
# once the floor distro moves to Qt 6.8 (Ubuntu 26.04 LTS expected April 2026).
find_package(Qt6 6.7 REQUIRED COMPONENTS Quick Qml Core DBus Network WebEngineCore)

add_subdirectory(backend_mpv)

SET(BUILD_QML ON CACHE BOOL "")
add_subdirectory(backend_scene)

set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

add_library(${PROJECT_NAME}
	SHARED
	plugin.cpp
	MouseGrabber.cpp
	TTYSwitchMonitor.cpp
	ScreenSaverMonitor.cpp
	MprisMonitor.cpp
	PluginInfo.cpp
	FileHelper.cpp
	SafeWallpaperBridge.cpp
	WebAudioBridge.cpp
	WebUrlInterceptor.cpp
	MigrationHelper.cpp
	Playlist.cpp
	PlaylistManager.cpp
	PlaylistsModel.cpp
	PlaylistItemsModel.cpp
	WekControl.cpp
	WekNotifier.cpp
	WekDiagnostics.cpp
	qmldir
	qwebchannel.qrc
)

target_link_libraries(${PROJECT_NAME}
	PRIVATE
	Qt::Quick
	Qt::Qml
	mpvbackend
	wescene-renderer-qml
	wpAudio
	Qt::Core
	Qt::DBus
	Qt::Network
	Qt::WebEngineCore
	KF6::ConfigCore
	KF6::Notifications
	KF6::Crash
	KF6::I18n
)

# KGlobalAccel wires global keyboard shortcuts through KActionCollection +
# the kglobalaccel daemon.  Optional: when the dev/build sysroot lacks
# kf6-kglobalaccel-devel / libkf6globalaccel-dev the WekShortcuts class is
# excluded from the plugin .so.  System Settings -> Shortcuts will then not
# show "Wallpaper Engine"; the D-Bus surface (WekControl) still works
# unchanged, so users can drive the plugin from KRunner / kdotool / qdbus.
find_package(KF6XmlGui QUIET)   # KActionCollection (used by WekShortcuts)
if(TARGET KF6::GlobalAccel AND TARGET KF6::CoreAddons AND TARGET KF6::XmlGui)
    target_sources(${PROJECT_NAME} PRIVATE WekShortcuts.cpp)
    target_link_libraries(${PROJECT_NAME} PRIVATE
        KF6::GlobalAccel
        KF6::CoreAddons
        KF6::XmlGui)
    target_compile_definitions(${PROJECT_NAME} PRIVATE WEKDE_HAS_GLOBALACCEL)
endif()
target_compile_definitions(${PROJECT_NAME} PRIVATE WEKDE_HAS_MPV)
target_compile_definitions(${PROJECT_NAME} PRIVATE
    WEK_VERSION="${PROJECT_VERSION}")
# Warning flags for the shippable plugin .so (dlopen'd into plasmashell — a
# crash here takes down the desktop).  wek_warn_opts comes from
# src/backend_scene/cmake/WekWarnings.cmake (included at the root before
# add_subdirectory(src)); -Wall -Wextra, plus -Werror under WEK_WERROR.
# wek_harden_opts is empty unless -DWEK_HARDEN=ON; on, it adds
# stack-protector-strong + _FORTIFY_SOURCE=2 + cf-protection=full at compile
# time, and RELRO+now+noexecstack at link.
target_compile_options(${PROJECT_NAME} PRIVATE ${wek_warn_opts} ${wek_harden_opts})
target_link_options(${PROJECT_NAME} PRIVATE ${wek_harden_link_opts})
set_target_properties(${PROJECT_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
set_target_properties(${PROJECT_NAME}
                       PROPERTIES LINK_FLAGS "-Wl,--exclude-libs,ALL")

# During plugin searching Qt will be looking for 'qmldir' file
# So we should place it next to our plugin lib.
add_custom_command(
    TARGET ${PROJECT_NAME}
    POST_BUILD
    COMMAND
        ${CMAKE_COMMAND} -E copy
        ${CMAKE_CURRENT_LIST_DIR}/qmldir
		$<TARGET_FILE_DIR:${PROJECT_NAME}>/qmldir
)

install(
	TARGETS ${PROJECT_NAME}
    DESTINATION ${KDE_INSTALL_QMLDIR}/${QMLPLUGIN_INSTALL_URI}
)

install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/qmldir
    DESTINATION ${KDE_INSTALL_QMLDIR}/${QMLPLUGIN_INSTALL_URI}
)

