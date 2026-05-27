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
# Warning + hardening flags for the video backend (linked into the plugin .so).
# wek_warn_opts is -Wall -Wextra (+/-Werror under WEK_WERROR); wek_harden_opts
# (empty unless -DWEK_HARDEN=ON) adds stack-protector + _FORTIFY_SOURCE +
# cf-protection at compile time.  Both defined in src/backend_scene/cmake/.
# This is a STATIC library, so the link-side hardening (RELRO/now/noexec) is
# applied where the plugin .so is produced, not here.
target_compile_options(${PROJECT_NAME} PRIVATE ${wek_warn_opts} ${wek_harden_opts})
