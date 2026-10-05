cmake_minimum_required(VERSION 3.16)
project(qmlwebsocketserver LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)

find_package(Qt6 REQUIRED COMPONENTS Core Quick WebSockets)

qt_add_executable(qmlwebsocketserver
    main.cpp
    data.qrc
)

qt_add_qml_module(qmlwebsocketserver
    URI qmlwebsocketserver
    VERSION 1.0
    NO_RESOURCE_TARGET_PATH
)

target_link_libraries(qmlwebsocketserver
    PRIVATE
    Qt6::Core
    Qt6::Quick
    Qt6::WebSockets
)

# L'exécutable et le dossier du module QML partagent le nom "qmlwebsocketserver".
# Sur desktop, l'exe natif n'a pas d'extension → collision au link (EISDIR).
# On le sort dans bin/. En WASM les artefacts portent une extension (.js/.wasm/.html),
# pas de collision — et build_run_web.sh les attend à la racine du build, donc on n'y touche pas.
if(NOT EMSCRIPTEN)
    set_target_properties(qmlwebsocketserver PROPERTIES
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin")
endif()

copy_to_webfiles(qmlwebsocketserver ${CMAKE_CURRENT_SOURCE_DIR}/../webfiles)
