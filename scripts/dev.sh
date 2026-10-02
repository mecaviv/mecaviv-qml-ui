#!/bin/bash

# Script de développement pour un projet
# Build + Serveur + Ouverture navigateur
# Usage: ./dev.sh <project>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Vérifier l'argument
if [ $# -eq 0 ]; then
    echo "Usage: $0 <project>"
    echo "Projects disponibles:"
    echo "  - sirenepupitre    : Port 8000"
    echo "  - pedalier         : Port 8010"
    echo "  - router           : Port 8002"
    echo "SirenConsole : franz build qml-ui -p wasm -t console, puis franz run console-server"
    exit 1
fi

PROJECT=$1

# Fonction pour tuer les serveurs existants
kill_server() {
    local port=$1
    echo "🔍 Vérification du port $port..."
    if lsof -ti:$port >/dev/null 2>&1; then
        echo "🛑 Arrêt du serveur sur le port $port..."
        lsof -ti:$port | xargs kill -9 2>/dev/null || true
        sleep 1
    fi
}

# Fonction pour démarrer un serveur Node.js et ouvrir le navigateur
start_node_server() {
    local project_name=$1
    local webfiles_dir=$2
    local port=$3
    
    echo "🌐 Démarrage du serveur Node.js sur le port $port..."
    cd "$webfiles_dir"
    
    # Démarrer le serveur en arrière-plan
    node server.js $port > /tmp/${project_name}_server.log 2>&1 &
    SERVER_PID=$!
    
    # Attendre que le serveur démarre
    sleep 2
    
    # Ouvrir Chrome
    echo "🌍 Ouverture de Chrome sur http://localhost:$port"
    /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
        --new-window \
        --auto-open-devtools-for-tabs \
        "http://localhost:$port" &
    
    echo ""
    echo "================================================"
    echo "✅ $project_name démarré !"
    echo "================================================"
    echo "  URL: http://localhost:$port"
    echo "  Logs: tail -f /tmp/${project_name}_server.log"
    echo "  Arrêter: kill $SERVER_PID"
    echo "================================================"
}

# Build + Dev selon le projet
case $PROJECT in
    sirenepupitre)
        PORT=8000
        kill_server $PORT
        
        echo "🔨 Build de SirenePupitre..."
        "$SCRIPT_DIR/build-project.sh" sirenepupitre
        
        start_node_server "sirenepupitre" "$ROOT_DIR/SirenePupitre/webfiles" $PORT
        ;;
    
    
    pedalier)
        PORT=8010
        kill_server $PORT
        
        echo "🔨 Build de pedalierSirenium..."
        "$SCRIPT_DIR/build-project.sh" pedalier
        
        start_node_server "pedalier" "$ROOT_DIR/pedalierSirenium/webfiles" $PORT
        ;;
    
    router)
        PORT=8002
        kill_server $PORT
        
        echo "📦 Installation de sirenRouter..."
        "$SCRIPT_DIR/build-project.sh" router
        
        echo "🚀 Démarrage de sirenRouter..."
        cd "$ROOT_DIR/sirenRouter"
        npm start &
        SERVER_PID=$!
        
        sleep 2
        
        echo ""
        echo "================================================"
        echo "✅ sirenRouter démarré !"
        echo "================================================"
        echo "  API REST: http://localhost:8002"
        echo "  WebSocket: ws://localhost:8003"
        echo "  UDP: port 8004"
        echo "  Arrêter: kill $SERVER_PID"
        echo "================================================"
        ;;
    
    *)
        echo "❌ Projet inconnu: $PROJECT"
        echo "Projects disponibles: sirenepupitre, pedalier, router (SirenConsole : franz run console-server)"
        exit 1
        ;;
esac

# Garder le script actif
echo ""
echo "Appuyez sur Ctrl+C pour arrêter..."
wait


