cmake_minimum_required(VERSION 3.16)

project(SirenConsole VERSION 0.1 LANGUAGES CXX)

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

# Trouver Qt6
find_package(Qt6 REQUIRED COMPONENTS Core Quick QuickControls2 Quick3D WebSockets)

# Configuration Qt6
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)

# Créer l'exécutable
qt_add_executable(appSirenConsole
    main.cpp
)

# Ajouter le module QML
qt_add_qml_module(appSirenConsole
    URI SirenConsole
    VERSION 1.0
    RESOURCES
        data.qrc
)

# Lier les bibliothèques Qt6
target_link_libraries(appSirenConsole PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::QuickControls2
    Qt6::Quick3D
    Qt6::WebSockets
)

# Configuration pour macOS (si nécessaire)
if(APPLE)
    set_target_properties(appSirenConsole PROPERTIES
        MACOSX_BUNDLE TRUE
        MACOSX_BUNDLE_BUNDLE_NAME "SirenConsole"
        MACOSX_BUNDLE_BUNDLE_VERSION "1.0.0"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "1.0.0"
    )
endif()

# Configuration pour WebAssembly
if(EMSCRIPTEN)
    set_target_properties(appSirenConsole PROPERTIES
        OUTPUT_NAME "appSirenConsole"
        SUFFIX ".js"
    )
endif()

copy_to_webfiles(appSirenConsole ${CMAKE_CURRENT_SOURCE_DIR}/webfiles)
