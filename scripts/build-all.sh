#!/bin/bash

# Script de build pour tous les projets du monorepo mecaviv-qml-ui
# Build SirenePupitre, SirenConsole, pedalierSirenium et sirenRouter

set -e  # Arrêter en cas d'erreur

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

echo "================================================"
echo "🚀 Build de tous les projets mecaviv-qml-ui"
echo "================================================"
echo ""

# Fonction pour afficher les résultats
show_result() {
    if [ $1 -eq 0 ]; then
        echo "✅ $2 - Build réussi"
    else
        echo "❌ $2 - Build échoué"
    fi
}

# 1. Build SirenePupitre
echo "📦 Build de SirenePupitre..."
if "$SCRIPT_DIR/build-project.sh" sirenepupitre; then
    show_result 0 "SirenePupitre"
else
    show_result 1 "SirenePupitre"
    exit 1
fi
echo ""

# 2. Build SirenConsole
echo "📦 Build de SirenConsole..."
if "$SCRIPT_DIR/build-project.sh" sirenconsole; then
    show_result 0 "SirenConsole"
else
    show_result 1 "SirenConsole"
    exit 1
fi
echo ""

# 3. Build pedalierSirenium
echo "📦 Build de pedalierSirenium..."
if "$SCRIPT_DIR/build-project.sh" pedalier; then
    show_result 0 "pedalierSirenium"
else
    show_result 1 "pedalierSirenium"
    exit 1
fi
echo ""

# 4. Install sirenRouter (Node.js)
echo "📦 Installation de sirenRouter..."
if "$SCRIPT_DIR/build-project.sh" router; then
    show_result 0 "sirenRouter"
else
    show_result 1 "sirenRouter"
    exit 1
fi
echo ""

echo "================================================"
echo "✅ Tous les projets ont été buildés avec succès !"
echo "================================================"
echo ""
echo "Pour lancer un projet en mode développement :"
echo "  ./scripts/dev.sh sirenepupitre"
echo "  franz run console-server        (SirenConsole)"
echo "  ./scripts/dev.sh pedalier"
echo "  ./scripts/dev.sh router"


