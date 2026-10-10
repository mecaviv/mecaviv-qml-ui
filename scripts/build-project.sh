#!/bin/bash

# Script de build pour un projet spécifique
# Usage: ./build-project.sh <project>
# Projects: sirenepupitre, sirenconsole, pedalier, router

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Configuration Qt WebAssembly
QT_CMAKE="$HOME/Qt/6.10.0/wasm_singlethread/bin/qt-cmake"

# Vérifier l'argument
if [ $# -eq 0 ]; then
    echo "Usage: $0 <project>"
    echo "Projects disponibles:"
    echo "  - sirenepupitre    : SirenePupitre (Visualiseur musical)"
    echo "  - sirenconsole     : SirenConsole (Console de contrôle)"
    echo "  - pedalier         : pedalierSirenium (Interface pédalier 3D)"
    echo "  - router           : sirenRouter (Service monitoring Node.js)"
    exit 1
fi

PROJECT=$1

# Fonction de build Qt/QML pour WebAssembly
build_qt_project() {
    local project_name=$1
    local project_dir=$2
    
    echo "🔨 Build de $project_name en WebAssembly..."
    
    cd "$project_dir"
    
    # Créer le dossier build s'il n'existe pas
    mkdir -p build
    cd build
    
    # CMake avec Qt WebAssembly
    echo "⚙️  Configuration CMake..."
    "$QT_CMAKE" ..
    
    # Build
    echo "🔧 Compilation..."
    make -j$(sysctl -n hw.ncpu)
    
    # Copier les fichiers vers webfiles
    echo "📦 Copie vers webfiles..."
    if [ -f "app${project_name}.html" ]; then
        cp app${project_name}.html ../webfiles/
        cp app${project_name}.js ../webfiles/
        cp app${project_name}.wasm ../webfiles/ 2>/dev/null || true
    elif [ -f "${project_name}.html" ]; then
        cp ${project_name}.html ../webfiles/
        cp ${project_name}.js ../webfiles/
        cp ${project_name}.wasm ../webfiles/ 2>/dev/null || true
    fi
    
    echo "✅ Build de $project_name terminé"
}

# Fable: the F# browser side of a page (e.g. SirenePupitre simulateur)
build_fable() {
    local name=$1
    echo "🧪 Fable: $name…"
    cd "$ROOT_DIR"
    dotnet tool restore
    dotnet fable "SirenePupitre/webfiles/$name" -o SirenePupitre/webfiles
    echo "✅ Fable: $name"
}

# Fonction de build pour pedalierSirenium (structure différente)
build_pedalier() {
    local project_dir="$ROOT_DIR/pedalierSirenium/QtFiles"
    
    echo "🔨 Build de pedalierSirenium en WebAssembly..."
    
    cd "$project_dir"
    
    # Créer le dossier build s'il n'existe pas
    mkdir -p build
    cd build
    
    # CMake avec Qt WebAssembly
    echo "⚙️  Configuration CMake..."
    "$QT_CMAKE" ..
    
    # Build
    echo "🔧 Compilation..."
    make -j$(sysctl -n hw.ncpu)
    
    # Copier les fichiers vers webfiles
    echo "📦 Copie vers webfiles..."
    cp qmlwebsocketserver.html "$ROOT_DIR/pedalierSirenium/webfiles/" 2>/dev/null || true
    cp qmlwebsocketserver.js "$ROOT_DIR/pedalierSirenium/webfiles/" 2>/dev/null || true
    cp qmlwebsocketserver.wasm "$ROOT_DIR/pedalierSirenium/webfiles/" 2>/dev/null || true
    
    echo "✅ Build de pedalierSirenium terminé"
}

# Build selon le projet
case $PROJECT in
    sirenepupitre)
        build_qt_project "SirenePupitre" "$ROOT_DIR/SirenePupitre"
        build_fable "simulateur-fable"
        ;;
    
    sirenconsole)
        build_qt_project "SirenConsole" "$ROOT_DIR/SirenConsole"
        ;;
    
    pedalier)
        build_pedalier
        ;;
    
    router)
        echo "📦 Installation des dépendances de sirenRouter..."
        cd "$ROOT_DIR/sirenRouter"
        if [ -f "package.json" ]; then
            npm install
            echo "✅ sirenRouter prêt"
        else
            echo "⚠️  Pas de package.json trouvé, création basique..."
            # Créer un package.json minimal si nécessaire
            echo "{
  \"name\": \"siren-router\",
  \"version\": \"1.0.0\",
  \"description\": \"Service de monitoring pour sirènes\",
  \"main\": \"src/server.js\",
  \"scripts\": {
    \"start\": \"node src/server.js\"
  }
}" > package.json
            npm install express ws
            echo "✅ sirenRouter initialisé"
        fi
        ;;
    
    *)
        echo "❌ Projet inconnu: $PROJECT"
        echo "Projects disponibles: sirenepupitre, sirenconsole, pedalier, router"
        exit 1
        ;;
esac


