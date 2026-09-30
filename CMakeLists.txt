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
# Outils .NET (configure time)
# ============================================================================
# CMake has no module for local dotnet tools or Paket. This is configure-time
# on purpose: an ALL custom target would re-run on every Qt Creator build.
# The repo root is this listfile's directory. An out-of-tree -B folder is not
# a parent of paket.dependencies, and `dotnet paket` only finds the local tool
# by walking up from the process working directory. --tool-manifest pins
# restore to that same directory. A missing SDK or a failed probe does not
# fail the Qt configure.

get_filename_component(MECAVIV_ROOT "${CMAKE_CURRENT_LIST_DIR}" ABSOLUTE)
set(MECAVIV_TOOL_MANIFEST "${MECAVIV_ROOT}/.config/dotnet-tools.json")

# find_program caches a miss as DOTNET_EXECUTABLE-NOTFOUND and does not look
# again. Qt Creator configures with PATH=/usr/bin:/bin:/usr/sbin:/sbin, so the
# installer copy at /usr/local/share/dotnet/dotnet is invisible and that miss
# sticks. Drop a missing result, then try PATH, then the installer directories.
if(NOT EXISTS "${DOTNET_EXECUTABLE}")
    unset(DOTNET_EXECUTABLE CACHE)
    unset(DOTNET_EXECUTABLE)
endif()
find_program(DOTNET_EXECUTABLE dotnet)
if(NOT EXISTS "${DOTNET_EXECUTABLE}")
    foreach(_dotnet_dir IN ITEMS
        "$ENV{DOTNET_ROOT}"
        "/usr/local/share/dotnet"
        "/usr/share/dotnet"
        "$ENV{HOME}/.dotnet"
        "$ENV{ProgramFiles}/dotnet")
        if(_dotnet_dir AND EXISTS "${_dotnet_dir}/dotnet")
            set(DOTNET_EXECUTABLE "${_dotnet_dir}/dotnet" CACHE FILEPATH "Path to dotnet" FORCE)
            break()
        elseif(_dotnet_dir AND EXISTS "${_dotnet_dir}/dotnet.exe")
            set(DOTNET_EXECUTABLE "${_dotnet_dir}/dotnet.exe" CACHE FILEPATH "Path to dotnet" FORCE)
            break()
        endif()
    endforeach()
endif()

if(EXISTS "${DOTNET_EXECUTABLE}" AND EXISTS "${MECAVIV_TOOL_MANIFEST}")
    message(STATUS "dotnet: ${DOTNET_EXECUTABLE}")
    execute_process(
        COMMAND ${DOTNET_EXECUTABLE} tool restore --tool-manifest "${MECAVIV_TOOL_MANIFEST}"
        WORKING_DIRECTORY "${MECAVIV_ROOT}"
        RESULT_VARIABLE DOTNET_TOOL_RESTORE_RESULT
        OUTPUT_VARIABLE DOTNET_TOOL_RESTORE_OUTPUT
        ERROR_VARIABLE DOTNET_TOOL_RESTORE_ERROR
        OUTPUT_STRIP_TRAILING_WHITESPACE
        ERROR_STRIP_TRAILING_WHITESPACE
    )
    if(NOT DOTNET_TOOL_RESTORE_RESULT EQUAL 0)
        message(STATUS "dotnet tool restore failed (${DOTNET_TOOL_RESTORE_RESULT}) in ${MECAVIV_ROOT}; Paket restore skipped")
        if(DOTNET_TOOL_RESTORE_ERROR)
            message(STATUS "${DOTNET_TOOL_RESTORE_ERROR}")
        endif()
    else()
        message(STATUS "dotnet tool restore done (${MECAVIV_ROOT})")
        # `dotnet paket` resolves the local tool by walking up from the
        # process cwd. Away from this repo it prints "command or file was
        # not found". The dll restored into the NuGet cache still runs.
        set(MECAVIV_PAKET_LAUNCH "${DOTNET_EXECUTABLE}" "paket")
        execute_process(
            COMMAND ${MECAVIV_PAKET_LAUNCH} --version
            WORKING_DIRECTORY "${MECAVIV_ROOT}"
            RESULT_VARIABLE DOTNET_PAKET_PROBE
            OUTPUT_VARIABLE DOTNET_PAKET_VERSION
            ERROR_VARIABLE DOTNET_PAKET_PROBE_ERROR
            OUTPUT_STRIP_TRAILING_WHITESPACE
            ERROR_STRIP_TRAILING_WHITESPACE
        )
        set(_paket_probe_text "${DOTNET_PAKET_VERSION}\n${DOTNET_PAKET_PROBE_ERROR}")
        if(NOT DOTNET_PAKET_PROBE EQUAL 0 OR _paket_probe_text MATCHES "[Nn]ot found")
            file(READ "${MECAVIV_TOOL_MANIFEST}" _mecaviv_tool_manifest)
            string(REGEX MATCH "\"paket\"[^}]*\"version\"[ \t\r\n]*:[ \t\r\n]*\"([^\"]+)\"" _mecaviv_paket_ver "${_mecaviv_tool_manifest}")
            if(DEFINED ENV{NUGET_PACKAGES} AND NOT "$ENV{NUGET_PACKAGES}" STREQUAL "")
                set(_nuget_packages "$ENV{NUGET_PACKAGES}")
            elseif(WIN32 AND DEFINED ENV{USERPROFILE})
                set(_nuget_packages "$ENV{USERPROFILE}/.nuget/packages")
            else()
                set(_nuget_packages "$ENV{HOME}/.nuget/packages")
            endif()
            file(GLOB _paket_dlls "${_nuget_packages}/paket/${CMAKE_MATCH_1}/tools/*/any/paket.dll")
            if(_paket_dlls)
                list(SORT _paket_dlls)
                list(GET _paket_dlls -1 _paket_dll)
                execute_process(
                    COMMAND ${DOTNET_EXECUTABLE} "${_paket_dll}" --version
                    WORKING_DIRECTORY "${MECAVIV_ROOT}"
                    RESULT_VARIABLE DOTNET_PAKET_PROBE
                    OUTPUT_VARIABLE DOTNET_PAKET_VERSION
                    ERROR_VARIABLE DOTNET_PAKET_PROBE_ERROR
                    OUTPUT_STRIP_TRAILING_WHITESPACE
                    ERROR_STRIP_TRAILING_WHITESPACE
                )
                if(DOTNET_PAKET_PROBE EQUAL 0)
                    set(MECAVIV_PAKET_LAUNCH "${DOTNET_EXECUTABLE}" "${_paket_dll}")
                    message(STATUS "dotnet paket command was not found; using ${_paket_dll}")
                endif()
            endif()
        endif()
        if(DOTNET_PAKET_PROBE EQUAL 0)
            message(STATUS "dotnet paket ${DOTNET_PAKET_VERSION}")
            execute_process(
                COMMAND ${MECAVIV_PAKET_LAUNCH} restore
                WORKING_DIRECTORY "${MECAVIV_ROOT}"
                RESULT_VARIABLE DOTNET_PAKET_RESTORE_RESULT
                OUTPUT_VARIABLE DOTNET_PAKET_RESTORE_OUTPUT
                ERROR_VARIABLE DOTNET_PAKET_RESTORE_ERROR
                OUTPUT_STRIP_TRAILING_WHITESPACE
                ERROR_STRIP_TRAILING_WHITESPACE
            )
            if(DOTNET_PAKET_RESTORE_RESULT EQUAL 0)
                message(STATUS "dotnet paket restore done (${MECAVIV_ROOT})")
            else()
                message(STATUS "dotnet paket restore failed (${DOTNET_PAKET_RESTORE_RESULT}); Qt configure continues")
                if(DOTNET_PAKET_RESTORE_ERROR)
                    message(STATUS "${DOTNET_PAKET_RESTORE_ERROR}")
                endif()
                if(DOTNET_PAKET_RESTORE_OUTPUT)
                    message(STATUS "${DOTNET_PAKET_RESTORE_OUTPUT}")
                endif()
            endif()
        else()
            message(STATUS "dotnet paket is not available; Paket restore skipped")
            if(DOTNET_PAKET_PROBE_ERROR)
                message(STATUS "${DOTNET_PAKET_PROBE_ERROR}")
            endif()
        endif()
    endif()
else()
    message(STATUS "dotnet tool restore skipped (dotnet or .config/dotnet-tools.json missing)")
endif()

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

