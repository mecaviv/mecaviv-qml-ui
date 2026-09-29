cmake_minimum_required(VERSION 3.16)

project(MecavivQmlUI 
    VERSION 1.0.0
    DESCRIPTION "Système de contrôle et visualisation pour sirènes musicales"
    LANGUAGES CXX
)

# ============================================================================
# Options de Build
# ============================================================================
option(BUILD_SIRENEPUPITRE "Build SirenePupitre (Visualiseur musical)" ON)
option(BUILD_SIRENCONSOLE "Build SirenConsole (Console de contrôle)" ON)
option(BUILD_PEDALIER "Build pedalierSirenium (Interface pédalier 3D)" ON)
option(BUILD_SIRENMANAGER "Build SirenManager (Contrôle des sirènes)" ON)
option(BUILD_FOR_WASM "Build for WebAssembly" OFF)
# Off by default. sirenRouter is a Node service, not a Qt application, and it
# has no package.json. Leaving this on used to attach an ALL custom target that
# ran `npm install` on every Qt Creator build and failed the QML applications.
option(INSTALL_NODE_DEPS "Install Node.js dependencies for sirenRouter (opt-in, not part of the application build)" OFF)
option(COPY_TO_WEBFILES "Copy built files to webfiles/ directories" ON)

# ============================================================================
# Configuration Globale
# ============================================================================
set(CMAKE_AUTOMOC ON)
set(CMAKE_AUTORCC ON)
set(CMAKE_AUTOUIC ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Messages de configuration
message(STATUS "============================================")
message(STATUS "Mecaviv QML UI Build Configuration")
message(STATUS "============================================")
message(STATUS "Build type: ${CMAKE_BUILD_TYPE}")
message(STATUS "WebAssembly: ${BUILD_FOR_WASM}")
message(STATUS "SirenePupitre: ${BUILD_SIRENEPUPITRE}")
message(STATUS "SirenConsole: ${BUILD_SIRENCONSOLE}")
message(STATUS "pedalierSirenium: ${BUILD_PEDALIER}")
message(STATUS "SirenManager: ${BUILD_SIRENMANAGER}")
message(STATUS "sirenRouter (Node.js): ${INSTALL_NODE_DEPS}")
message(STATUS "============================================")

# ============================================================================
# Dépendances Qt
# ============================================================================
find_package(Qt6 REQUIRED COMPONENTS 
    Core 
    Quick 
    Quick3D 
    WebSockets
)

# ============================================================================
# Sous-projets Qt/QML
# ============================================================================

if(BUILD_SIRENEPUPITRE)
    message(STATUS "Configuring SirenePupitre...")
    add_subdirectory(SirenePupitre)
endif()

if(BUILD_SIRENCONSOLE)
    message(STATUS "Configuring SirenConsole...")
    add_subdirectory(SirenConsole)
endif()

if(BUILD_PEDALIER)
    message(STATUS "Configuring pedalierSirenium...")
    add_subdirectory(pedalierSirenium/QtFiles)
endif()

if(BUILD_SIRENMANAGER)
    message(STATUS "Configuring SirenManager...")
    add_subdirectory(SirenManager)
endif()

# ============================================================================
# sirenRouter (Node.js) — never part of the default "all" target
# ============================================================================
# Qt Creator builds "all". An ALL custom target with no output is always out of
# date, so every application build used to run `npm install` here and stop when
# sirenRouter/package.json was missing. The QML apps do not depend on it.

if(INSTALL_NODE_DEPS)
    find_program(NPM_EXECUTABLE npm)
    if(NPM_EXECUTABLE AND EXISTS "${CMAKE_SOURCE_DIR}/sirenRouter/package.json")
        add_custom_target(sirenRouter
            COMMAND ${NPM_EXECUTABLE} install
            WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}/sirenRouter
            COMMENT "Installing Node.js dependencies for sirenRouter..."
        )
        message(STATUS "sirenRouter: optional target only (cmake --build <dir> --target sirenRouter)")
    else()
        message(STATUS "sirenRouter: not configured (npm or sirenRouter/package.json missing)")
    endif()
else()
    message(STATUS "sirenRouter: skipped (INSTALL_NODE_DEPS=OFF)")
endif()

# ============================================================================
# Targets Personnalisés
# ============================================================================

# Target pour nettoyer tout
add_custom_target(clean_all
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_BINARY_DIR}
#   COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_SOURCE_DIR}/SirenePupitre/build
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_SOURCE_DIR}/SirenConsole/build
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_SOURCE_DIR}/pedalierSirenium/QtFiles/build
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_SOURCE_DIR}/SirenManager/build
    COMMAND ${CMAKE_COMMAND} -E remove_directory ${CMAKE_SOURCE_DIR}/sirenRouter/node_modules
    COMMENT "Cleaning all build directories..."
)

# Target pour lancer les serveurs de développement (Linux/macOS uniquement)
if(UNIX)
    add_custom_target(run_servers
        COMMAND ${CMAKE_SOURCE_DIR}/scripts/dev.sh sirenepupitre &
        COMMENT "Starting development servers..."
    )
endif()

# ============================================================================
# Résumé de Configuration
# ============================================================================

message(STATUS "")
message(STATUS "Configuration complète !")
message(STATUS "")
message(STATUS "Pour builder :")
message(STATUS "  cmake --build ${CMAKE_BINARY_DIR}")
message(STATUS "")
message(STATUS "Pour builder un projet spécifique :")
if(BUILD_SIRENEPUPITRE)
    message(STATUS "  cmake --build ${CMAKE_BINARY_DIR} --target appSirenePupitre")
endif()
if(BUILD_SIRENCONSOLE)
    message(STATUS "  cmake --build ${CMAKE_BINARY_DIR} --target appSirenConsole")
endif()
if(BUILD_PEDALIER)
    message(STATUS "  cmake --build ${CMAKE_BINARY_DIR} --target qmlwebsocketserver")
endif()
message(STATUS "")

