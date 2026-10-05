cmake_minimum_required(VERSION 3.16)

project(SirenManager VERSION 0.1 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)

# Configuration pour WebAssembly
if(EMSCRIPTEN)
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s TOTAL_MEMORY=256MB -s ALLOW_MEMORY_GROWTH=1")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s WASM=1 -s EXPORTED_RUNTIME_METHODS=[\"ccall\",\"cwrap\"]")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s EXPORTED_FUNCTIONS=[\"_main\"]")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s USE_PTHREADS=0")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s DISABLE_EXCEPTION_CATCHING=0")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s ASSERTIONS=1")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s SAFE_HEAP=0")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -s STACK_SIZE=5MB")
endif()

# Éviter de charger les plugins QML optionnels (ex: Qt Graphs/Quick3D absents en WASM)
set(QT_SKIP_QML_PLUGINS TRUE)
set(CMAKE_DISABLE_FIND_PACKAGE_Qt6Quick3DTools ON)
set(CMAKE_DISABLE_FIND_PACKAGE_Qt6Quick3D ON)
set(CMAKE_DISABLE_FIND_PACKAGE_Qt6Graphs ON)
set(CMAKE_DISABLE_FIND_PACKAGE_Qt6VirtualKeyboard ON)

# Trouver Qt6 (Quick3D retiré : non utilisé, évite la dépendance à instancer en WASM)
find_package(Qt6 REQUIRED COMPONENTS Core Quick QuickControls2 WebSockets Network)

# Configuration Qt6
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Sources C++
set(SOURCES
    main.cpp
    src/UdpController.cpp
    src/SshController.cpp
    src/PlaylistManager.cpp
    src/MachineManager.cpp
    src/Config/SirenConfig.cpp
    src/Models/PlaylistModel.cpp
)

set(HEADERS
    src/UdpController.h
    src/SshController.h
    src/PlaylistManager.h
    src/MachineManager.h
    src/Config/SirenConfig.h
    src/Config/MachineType.h
    src/Models/PlaylistModel.h
)

# Créer l'exécutable
qt_add_executable(appSirenManager
    ${SOURCES}
    ${HEADERS}
)

# Ajouter le module QML
qt_add_qml_module(appSirenManager
    URI SirenManager
    VERSION 1.0
    RESOURCES
        data.qrc
)

# Lier les bibliothèques Qt6
target_link_libraries(appSirenManager PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::WebSockets
    Qt6::Network
)

# Configuration pour macOS (si nécessaire)
if(APPLE)
    set_target_properties(appSirenManager PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_BUNDLE_NAME "SirenManager"
        MACOSX_BUNDLE_BUNDLE_VERSION "1.0.0"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
    )
endif()

# Configuration pour WebAssembly
if(EMSCRIPTEN)
    set_target_properties(appSirenManager PROPERTIES
        OUTPUT_NAME "appSirenManager"
        SUFFIX ".js"
    )
endif()

copy_to_webfiles(appSirenManager ${CMAKE_CURRENT_SOURCE_DIR}/webfiles)
