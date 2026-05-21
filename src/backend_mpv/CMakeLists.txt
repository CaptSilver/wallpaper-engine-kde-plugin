project(mpvbackend)

find_package(Qt${QT_MAJOR_VERSION} COMPONENTS Gui Quick REQUIRED)
include_directories(${Qt${QT_MAJOR_VERSION}Gui_PRIVATE_INCLUDE_DIRS})

find_package(PkgConfig REQUIRED)
pkg_check_modules(MPV REQUIRED mpv)

set(CMAKE_AUTOMOC ON) 
set(CMAKE_AUTORCC ON) 
set(CMAKE_AUTOUIC ON) 

add_library(${PROJECT_NAME}
	STATIC
	MpvBackend.cpp
	ThumbnailGrabber.cpp
	qthelper.hpp
)
target_link_libraries(${PROJECT_NAME} 
	PRIVATE 
    Qt::Quick
	Qt::Gui
	# Qt::X11Extras
	${MPV_LIBRARIES}
)
target_include_directories(${PROJECT_NAME} PUBLIC .) #${INCLUDE_DIRECTORIES})
# Warning flags for the video backend (linked into the plugin .so).  Previously
# carried none; wek_warn_opts is -Wall -Wextra (+/-Werror under WEK_WERROR),
# defined in src/backend_scene/cmake/WekWarnings.cmake.
target_compile_options(${PROJECT_NAME} PRIVATE ${wek_warn_opts})
