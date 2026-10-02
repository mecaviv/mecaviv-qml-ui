cmake_minimum_required(VERSION 3.16)

project(SirenePupitre VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTORCC ON)

# Ajouter tous les modules nécessaires
find_package(Qt6 REQUIRED COMPONENTS 
    Core
    Quick 
    Quick3D
    WebSockets
    QuickDialogs2
)

qt_standard_project_setup(REQUIRES 6.8)

qt_add_executable(appSirenePupitre
    main.cpp
)

qt_add_qml_module(appSirenePupitre
    URI SirenePupitre
    VERSION 1.0
    QML_FILES
    RESOURCES data.qrc
)

# Qt for iOS sets MACOSX_BUNDLE_GUI_IDENTIFIER automatically since Qt 6.1.
# If you are developing for iOS or macOS you should consider setting an
# explicit, fixed bundle identifier manually though.
set_target_properties(appSirenePupitre PROPERTIES
    # MACOSX_BUNDLE_GUI_IDENTIFIER com.example.appSirenePupitre
    MACOSX_BUNDLE_BUNDLE_VERSION ${PROJECT_VERSION}
    MACOSX_BUNDLE_SHORT_VERSION_STRING ${PROJECT_VERSION_MAJOR}.${PROJECT_VERSION_MINOR}
    MACOSX_BUNDLE TRUE
    WIN32_EXECUTABLE TRUE
)

# Lier tous les modules nécessaires
target_link_libraries(appSirenePupitre
    PRIVATE 
    Qt6::Core
    Qt6::Quick
    Qt6::Quick3D
    Qt6::WebSockets
    Qt6::QuickDialogs2
)

include(GNUInstallDirs)
install(TARGETS appSirenePupitre
    BUNDLE DESTINATION .
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
)

copy_to_webfiles(appSirenePupitre ${CMAKE_CURRENT_SOURCE_DIR}/webfiles)
