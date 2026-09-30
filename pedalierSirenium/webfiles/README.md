# 📁 WebFiles - Déploiement WebAssembly

## 🚀 Démarrage rapide

### 1. **Build automatique** (recommandé)
```bash
# Depuis la racine du projet
./scripts/build_run_web.sh
```
Cette commande :
- ✅ Compile l'application en WebAssembly
- ✅ Génère `qmlwebsocketserver.wasm` (~36MB)
- ✅ Copie tous les fichiers dans `webfiles/`
- ✅ Lance le serveur Node.js sur `http://localhost:8010`

### 2. **Fichier WASM manquant ?**

Le fichier `qmlwebsocketserver.wasm` (**~36MB**) n'est pas versionné sur GitHub car trop volumineux.

**📥 Téléchargement automatique (recommandé) :**
```bash
# Script automatique avec vérifications
./scripts/download_wasm.sh
```

**📥 Téléchargement manuel depuis Google Drive :**

**Option 1 - Commande wget (gros fichiers Google Drive) :**
```bash
# Depuis la racine du projet
# Étape 1: Récupérer le token de confirmation
wget --quiet --save-cookies /tmp/cookies.txt --keep-session-cookies --no-check-certificate 'https://drive.google.com/uc?export=download&id=1itBpRCFBakVglWZNU7g1_b-6RQi0IA62' -O- | grep -o 'confirm=[^&]*' | cut -d= -f2 > /tmp/confirm.txt

# Étape 2: Télécharger avec le token
wget --load-cookies /tmp/cookies.txt 'https://drive.google.com/uc?export=download&confirm='$(cat /tmp/confirm.txt)'&id=1itBpRCFBakVglWZNU7g1_b-6RQi0IA62' -O webfiles/qmlwebsocketserver.wasm

# Nettoyage
rm -f /tmp/cookies.txt /tmp/confirm.txt
```

**Option 2 - Avec gdown (plus fiable) :**
```bash
# Installation de gdown (si pas déjà installé)
pip install gdown

# Téléchargement
gdown https://drive.google.com/uc?id=1itBpRCFBakVglWZNU7g1_b-6RQi0IA62 -O webfiles/qmlwebsocketserver.wasm
```

**Option 3 - Lien manuel :**
- **Lien Google Drive** : [https://drive.google.com/file/d/1itBpRCFBakVglWZNU7g1_b-6RQi0IA62/view?usp=sharing](https://drive.google.com/file/d/1itBpRCFBakVglWZNU7g1_b-6RQi0IA62/view?usp=sharing)
- **Nom du fichier** : `qmlwebsocketserver.wasm`
- **Destination** : Placer dans le dossier `webfiles/`

### 3. **Lancement manuel du serveur**
```bash
# Si vous avez déjà le fichier WASM
node webfiles/server.js
```

## 📁 Structure des fichiers

```
webfiles/
├── qmlwebsocketserver.wasm     # ⚠️ ~36MB - Non versionné (Google Drive)
├── qmlwebsocketserver.js       # Code JavaScript principal 
├── qmlwebsocketserver.html     # Page d'accueil
├── qtloader.js                 # Chargeur Qt WebAssembly
├── config.js                   # Configuration client
├── server.js                   # Serveur Node.js (port 8010)
└── qml/                        # Ressources QML copiées
```

## 🔧 Prérequis

- **Qt 6.10+** avec support WebAssembly
- **Emscripten SDK** configuré
- **Node.js** pour le serveur local
- **CMake 3.16+**

## 🎭 Interface Scènes

**Accès :** Bouton "🎪 Scènes" en bas à gauche (masque les sirènes 3D)

**Interactions tactiles :**
- **Clic simple** : Charger une scène existante
- **Clic long** : Sauvegarder la scène courante (ouvre dialogue + clavier AZERTY + bouton ✕)
- **Navigation** : Boutons ◄ ► pour changer de page (1-8)
- **États visuels** : Vide (gris), Occupé (orange), Actif (vert)

## ⚠️ Notes importantes

- **Port serveur** : 8010 (configuré dans `server.js`)
- **CORS activé** : Permet connexions cross-origin
- **WebSocket** : `ws://localhost:8080` pour communication
- **Navigateurs supportés** : Firefox, Chrome, Safari, Edge modernes 
