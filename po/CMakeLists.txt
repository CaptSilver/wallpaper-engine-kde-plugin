# Compile every .po in this directory tree into matching .mo files and
# install under ${KDE_INSTALL_LOCALEDIR}/<lang>/LC_MESSAGES/.
# Normally ki18n_install(po) (from the parent CMakeLists) handles this;
# this file is a fallback for build hosts where ki18n_install is
# unavailable or behaves unexpectedly.
file(GLOB _po_files "*/*.po")
foreach(_po_file ${_po_files})
    get_filename_component(_lang ${_po_file} DIRECTORY)
    get_filename_component(_lang ${_lang} NAME)
    set(_mo_file ${CMAKE_CURRENT_BINARY_DIR}/${_lang}.mo)
    add_custom_command(OUTPUT ${_mo_file}
        COMMAND msgfmt ${_po_file} -o ${_mo_file}
        DEPENDS ${_po_file}
        VERBATIM)
    add_custom_target(po_${_lang} ALL DEPENDS ${_mo_file})
    install(FILES ${_mo_file}
        DESTINATION ${KDE_INSTALL_LOCALEDIR}/${_lang}/LC_MESSAGES
        RENAME plasma_wallpaper_com.github.captsilver.wallpaperEngineKde.mo)
endforeach()
