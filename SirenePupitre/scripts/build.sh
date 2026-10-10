#!/bin/bash

# Script de build pour SirenePupitre
# Usage: ./scripts/build.sh [desktop|web|clean|all]

set -e  # Arrêter en cas d'erreur

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonction pour afficher les messages
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Fonction d'aide
show_help() {
    echo "Script de build pour SirenePupitre"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  web         Build pour WebAssembly"
    echo "  clean       Nettoyer les dossiers de build"
    echo "  help        Afficher cette aide"
    echo ""
    echo "Exemples:"
    echo "  $0 web"
    echo "  $0 clean"
}

# Fonction pour vérifier les dépendances
check_dependencies() {
    print_info "Vérification des dépendances..."
    
    # Vérifier CMake
    if ! command -v cmake &> /dev/null; then
        print_error "CMake n'est pas installé"
        exit 1
    fi
    
    # Vérifier Qt6 (WebAssembly)
    QT6_WASM_PATH="$HOME/Qt/6.10.0/wasm_singlethread"
    if [ -d "$QT6_WASM_PATH" ]; then
        print_success "Qt6 WebAssembly trouvé: $QT6_WASM_PATH"
    else
        print_error "Qt6 WebAssembly non trouvé dans $QT6_WASM_PATH"
        print_info "Installez Qt6 pour WebAssembly depuis Qt Installer"
        exit 1
    fi
    
    print_success "Dépendances vérifiées"
}

# Fonction pour nettoyer
clean_build() {
    print_info "Nettoyage des dossiers de build..."
    
    if [ -d "build" ]; then
        rm -rf build
        print_success "Dossier build supprimé"
    fi
    
    if [ -d "webfiles/build" ]; then
        rm -rf webfiles/build
        print_success "Dossier webfiles/build supprimé"
    fi
    
    print_success "Nettoyage terminé"
}



# Fonction pour build WebAssembly
build_web() {
    print_info "Build pour WebAssembly..."
    
    # Vérifier Qt6 pour WebAssembly
    QT6_WASM_PATH="$HOME/Qt/6.10.0/wasm_singlethread"
    if [ ! -d "$QT6_WASM_PATH" ]; then
        print_error "Qt6 pour WebAssembly non trouvé dans $QT6_WASM_PATH"
        print_info "Installez Qt6 pour WebAssembly depuis Qt Installer"
        exit 1
    fi
    
    # Vérifier qt-cmake
    QMAKE="$QT6_WASM_PATH/bin/qt-cmake"
    if [ ! -f "$QMAKE" ]; then
        print_error "qt-cmake non trouvé dans $QMAKE"
        print_info "Vérifiez que Qt6 pour WebAssembly est correctement installé"
        exit 1
    fi
    
    print_success "Qt6 WebAssembly trouvé: $QT6_WASM_PATH"
    print_success "qt-cmake trouvé: $QMAKE"
    
    # Créer le dossier build pour web
    mkdir -p build
    cd build
    
    # Configuration CMake avec qt-cmake
    print_info "Configuration CMake pour WebAssembly..."
    "$QMAKE" ..
    
    # Compilation
    print_info "Compilation WebAssembly..."
    make -j$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
    
    cd ..
    
    # Copier les fichiers dans webfiles
    print_info "Copie des fichiers WebAssembly..."
    cp build/appSirenePupitre.* webfiles/

    # Fable: simulateur.html (simulateur-fable/App.js)
    print_info "Fable: simulateur-fable…"
    (cd ../.. && dotnet tool restore && dotnet fable SirenePupitre/webfiles/simulateur-fable -o SirenePupitre/webfiles)
    
    # FIX : Corriger l'ordre des scripts dans le HTML
    # Qt génère le HTML avec appSirenePupitre.js avant qtloader.js, ce qui cause "qtLoad is not defined"
    # On inverse l'ordre pour que qtloader.js soit chargé en premier
    print_info "Correction de l'ordre des scripts dans le HTML..."
    if [ -f "webfiles/appSirenePupitre.html" ]; then
        # Supprimer la ligne appSirenePupitre.js
        sed -i.bak -e '/<script src="appSirenePupitre.js"><\/script>/d' webfiles/appSirenePupitre.html
        # Réinsérer appSirenePupitre.js APRÈS qtloader.js
        sed -i.bak -e 's|<script type="text/javascript" src="qtloader.js"></script>|<script type="text/javascript" src="qtloader.js"></script>\n    <script src="appSirenePupitre.js"></script>|' webfiles/appSirenePupitre.html
        # Nettoyer les fichiers backup
        rm -f webfiles/appSirenePupitre.html.bak
        print_success "Ordre des scripts corrigé (qtloader.js → appSirenePupitre.js)"
    else
        print_warning "Fichier HTML non trouvé, impossible de corriger l'ordre des scripts"
    fi
    
    # Copier les polices nécessaires pour le rendu 2D (Clef2D)
    mkdir -p webfiles/fonts || true
    if compgen -G "QML/fonts/*.*tf" > /dev/null; then
        cp QML/fonts/*.*tf webfiles/fonts/ || true
        print_success "Polices copiées dans webfiles/fonts/"
    else
        print_warning "Aucune police trouvée dans QML/fonts/"
    fi
    
    # Copier les fichiers .mesh pour les modèles 3D
    mkdir -p webfiles/QML/utils/meshes || true
    if compgen -G "QML/utils/meshes/*.mesh" > /dev/null; then
        cp QML/utils/meshes/*.mesh webfiles/QML/utils/meshes/ || true
        print_success "Fichiers .mesh copiés dans webfiles/QML/utils/meshes/"
    else
        print_warning "Aucun fichier .mesh trouvé dans QML/utils/meshes/"
    fi
    
    # Copier le sous-dossier meshes/ si il existe (pour fichiers .qml générés par balsam)
    if [ -d "QML/utils/meshes/meshes" ]; then
        cp -r QML/utils/meshes/meshes webfiles/QML/utils/meshes/ || true
        print_success "Sous-dossier meshes/ copié"
    fi
    
    print_success "Build WebAssembly terminé"
    print_info "Fichiers dans: webfiles/"
}



# Fonction pour tester le build
test_build() {
    print_info "Test du build..."
    
    if [ -f "webfiles/appSirenePupitre.js" ]; then
        print_success "Fichiers WebAssembly trouvés"
    else
        print_warning "Fichiers WebAssembly non trouvés"
    fi
}

# Script principal
main() {
    print_info "=== Build SirenePupitre ==="
    
    # Vérifier les arguments
    if [ $# -eq 0 ]; then
        print_error "Aucune option spécifiée"
        show_help
        exit 1
    fi
    
    case "$1" in
        "web")
            check_dependencies
            build_web
            test_build
            ;;
        "clean")
            clean_build
            ;;
        "help"|"-h"|"--help")
            show_help
            ;;
        *)
            print_error "Option inconnue: $1"
            show_help
            exit 1
            ;;
    esac
    
    print_success "Build terminé avec succès!"
}

# Exécuter le script principal
main "$@"
