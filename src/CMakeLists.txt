# Qt 6.6 floor: the plugin targets Plasma 6 (Qt 6 era); pin a realistic minimum
# so a too-old Qt6 fails at configure with a clear message instead of late and
# cryptically.  6.6 matches the lowest Qt the supported distros ship.
find_package(Qt6 6.6 REQUIRED COMPONENTS Quick Qml Core DBus Network WebEngineCore)

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
)
target_compile_definitions(${PROJECT_NAME} PRIVATE WEKDE_HAS_MPV)
target_compile_definitions(${PROJECT_NAME} PRIVATE
    WEK_VERSION="${PROJECT_VERSION}")
# Warning flags for the shippable plugin .so (dlopen'd into plasmashell — a
# crash here takes down the desktop).  wek_warn_opts comes from
# src/backend_scene/cmake/WekWarnings.cmake (included at the root before
# add_subdirectory(src)); -Wall -Wextra, plus -Werror under WEK_WERROR.
target_compile_options(${PROJECT_NAME} PRIVATE ${wek_warn_opts})
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

