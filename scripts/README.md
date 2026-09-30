# Scripts de Build Centralisés

Scripts pour builder et développer tous les projets du monorepo mecaviv-qml-ui.

> ⚠️ **Note Windows** : Les scripts `.sh` (bash) fonctionnent uniquement sur macOS/Linux.  
> Pour Windows, utilisez les scripts `.ps1` (PowerShell) ou CMake directement.  
> Voir [../docs/BUILD.md](../docs/BUILD.md) pour le guide Windows complet.

## 📋 Scripts Disponibles

### Scripts Unix (macOS/Linux)

Les scripts `.sh` ci-dessous ne fonctionnent que sur macOS et Linux.

#### `build-all.sh` - Build de tous les projets

Build tous les projets Qt/QML en WebAssembly + installation de sirenRouter.

```bash
./scripts/build-all.sh
```

**Durée estimée** : 5-10 minutes selon la machine

**Ce qu'il fait** :
- Build SirenePupitre en WebAssembly
- Build SirenConsole en WebAssembly
- Build pedalierSirenium en WebAssembly
- Installation des dépendances Node.js pour sirenRouter

### `build-project.sh <project>` - Build d'un projet spécifique

Build un seul projet.

```bash
./scripts/build-project.sh sirenepupitre
./scripts/build-project.sh sirenconsole
./scripts/build-project.sh pedalier
./scripts/build-project.sh router
```

**Projets disponibles** :
- `sirenepupitre` : SirenePupitre (Visualiseur musical)
- `sirenconsole` : SirenConsole (Console de contrôle)
- `pedalier` : pedalierSirenium (Interface pédalier 3D)
- `router` : sirenRouter (Service monitoring Node.js)

### `dev.sh <project>` - Mode développement

Build + Serveur + Ouverture du navigateur pour développement rapide.

```bash
./scripts/dev.sh sirenepupitre   # Port 8000
./scripts/dev.sh sirenconsole    # Port 8001
./scripts/dev.sh pedalier        # Port 8010
./scripts/dev.sh router          # Port 8002-8004
```

**Ce qu'il fait** :
1. Tue les serveurs existants sur le port
2. Build le projet
3. Démarre le serveur Node.js
4. Ouvre Chrome avec DevTools

**Ports utilisés** :
- SirenePupitre : `8000`
- SirenConsole : `8001`
- pedalierSirenium : `8010`
- sirenRouter : `8002` (API REST), `8003` (WebSocket), `8004` (UDP)

### `clean-all.sh` - Nettoyage complet

Supprime tous les dossiers de build, node_modules et fichiers temporaires.

```bash
./scripts/clean-all.sh
```

**Ce qu'il fait** :
- Supprime tous les `build/` et `build-*/`
- Supprime tous les `node_modules/`
- Supprime les fichiers `.wasm`
- Supprime les logs temporaires
- Tue tous les serveurs en cours

### `update-all-pupitres.sh` - Mise à jour des pupitres

Met à jour automatiquement tous les pupitres via SSH avec les dernières versions du code.

```bash
# Mise à jour simple (tous les pupitres)
./scripts/update-all-pupitres.sh

# Avec mot de passe personnalisé
./scripts/update-all-pupitres.sh --password MOTDEPASSE

# Avec redémarrage automatique
./scripts/update-all-pupitres.sh --reboot

# Pupitres spécifiques uniquement
./scripts/update-all-pupitres.sh --pupitres "192.168.1.41,192.168.1.42"

# Exclure certains pupitres
./scripts/update-all-pupitres.sh --exclude "192.168.1.47"

# Mode interactif pour sélectionner les pupitres
./scripts/update-all-pupitres.sh --interactive
./scripts/update-all-pupitres.sh -i  # Version courte

# Combinaisons
./scripts/update-all-pupitres.sh --pupitres "192.168.1.41,192.168.1.42" --reboot
./scripts/update-all-pupitres.sh --exclude "192.168.1.47" --reboot --password MOTDEPASSE
./scripts/update-all-pupitres.sh -i --reboot
```

**Options** :
- `--password PASSWORD` : Mot de passe SSH personnalisé (défaut: SIRENS)
- `--reboot` : Redémarre les pupitres après la mise à jour avec `sudo reboot`
- `--pupitres IPS` : Met à jour uniquement les IPs spécifiées (séparées par des virgules)
- `--exclude IPS` : Exclut les IPs spécifiées de la mise à jour
- `--interactive`, `-i` : Mode interactif pour sélectionner les pupitres avec un menu numéroté
- `--help`, `-h` : Affiche l'aide détaillée

**Ce qu'il fait** :
- Charge automatiquement les IPs depuis `SirenConsole/config.js`
- Pour chaque pupitre :
  1. Test de connexion SSH
  2. `git reset --hard` dans `~/dev/src/mecaviv/puredata-abstractions` (écrase modifications locales)
  3. `git reset --hard` dans `~/dev/src/mecaviv-qml-ui` (récupère la dernière version)
  4. `rsync` de `SirenePupitre/webfiles/` vers le pupitre
  5. (Optionnel) `sudo reboot` si `--reboot` est spécifié
- Affiche un rapport détaillé avec réussites/échecs

**Prérequis** :
- **Sur votre machine (macOS)** :
  - `sshpass` installé : `brew install hudochenkov/sshpass/sshpass`
- **Sur chaque pupitre (Raspberry Pi)** :
  - L'utilisateur `sirenateur` doit avoir les droits `sudo` pour le reboot (si `--reboot` est utilisé)
- Les pupitres doivent être accessibles sur le réseau
- Les IPs configurées dans `SirenConsole/config.js`

**Configuration** :
Les IPs sont automatiquement chargées depuis la section `pupitres` de `SirenConsole/config.js`.

**⚠️ Note sur `config.json`** :
Le script **ne modifie PAS** `config.json`. Le fichier est simplement mis à jour via `git reset --hard`. Vous devez configurer manuellement `cb4techID` et `currentSirens` sur chaque pupitre selon ses besoins.

**Note sur le reboot** :
Le redémarrage prend environ 1-2 minutes. Les pupitres seront automatiquement opérationnels au démarrage grâce au script `start-raspberry.sh` configuré dans crontab.

**Configuration sudo sans mot de passe** (si nécessaire) :
Si l'utilisateur `sirenateur` ne peut pas exécuter `sudo reboot` sans mot de passe, configurez sudo sur chaque pupitre :
```bash
# Sur chaque pupitre
sudo visudo
# Ajoutez la ligne suivante :
sirenateur ALL=(ALL) NOPASSWD: /sbin/reboot
```

**Mode interactif** :
Le mode `--interactive` affiche un menu numéroté des pupitres disponibles :
```
📋 Pupitres disponibles :

  [1] 192.168.1.41
  [2] 192.168.1.42
  [3] 192.168.1.43
  ...

Sélectionnez les pupitres (exemples: 1,2,5 ou 1-3 ou 'all' pour tous):
```

Exemples de sélection :
- `1,2,5` : Pupitres 1, 2 et 5
- `1-3` : Pupitres 1 à 3 (plage)
- `1,3-5,7` : Pupitres 1, de 3 à 5, et 7 (combinaison)
- `all` ou `Entrée` : Tous les pupitres

**Gestion des problèmes Git** :
Le script gère automatiquement :
- **Authentification SSH GitHub** : Utilise la clé `~/.ssh/id_ed25519` sans avoir besoin de ssh-agent
- **Branches sans tracking** : Essaie d'abord `git pull`, puis fallback sur `git pull origin <branch_actuelle>`
- Les deux problèmes les plus courants lors de mises à jour distantes sont ainsi résolus

### `restore-pupitres-config.sh` - Restauration du config.json

Restaure `config.json` depuis Git sur les pupitres (utile en cas de corruption).

```bash
# Restaurer tous les pupitres
./scripts/restore-pupitres-config.sh --all

# Restaurer des pupitres spécifiques
./scripts/restore-pupitres-config.sh --pupitres "192.168.1.41,192.168.1.43"

# Avec mot de passe personnalisé
./scripts/restore-pupitres-config.sh --all --password MOTDEPASSE
```

**Options** :
- `--all` : Restaure tous les pupitres (IPs 192.168.1.41 à 192.168.1.47)
- `--pupitres IPS` : Restaure uniquement les IPs spécifiées
- `--password PASSWORD` : Mot de passe SSH personnalisé (défaut: SIRENS)

**Ce qu'il fait** :
- Exécute `git checkout config.json` sur chaque pupitre pour restaurer depuis Git
- Affiche un rapport avec réussites/échecs

**Quand l'utiliser** :
- Après une corruption de `config.json` sur les pupitres
- Pour réinitialiser la configuration à l'état du dépôt Git
- Avant de relancer `update-all-pupitres.sh` après correction d'un bug

### Scripts PowerShell (Windows)

Les scripts `.ps1` ci-dessous fonctionnent sur Windows avec PowerShell 5.1+.

#### `setup-env.ps1` - Configuration des Variables Qt

Script interactif pour configurer `QT_DIR` et `QT_WASM_DIR`.

```powershell
.\scripts\setup-env.ps1
```

**Ce qu'il fait** :
- Détecte Qt dans `C:\Qt\`
- Vous propose de valider ou personnaliser les chemins
- Optionnellement ajoute aux variables système Windows
- Configuration permanente pour tous les terminaux

#### `configure.ps1` - Configuration CMake

Configuration rapide du projet avec CMake.

```powershell
.\scripts\configure.ps1 default   # Desktop Debug
.\scripts\configure.ps1 release   # Desktop Release
.\scripts\configure.ps1 wasm      # WebAssembly
.\scripts\configure.ps1 windows   # Visual Studio
```

**Prérequis** : Définir `QT_DIR` et `QT_WASM_DIR` avec `setup-env.ps1`.

### Équivalence Scripts

| Unix (macOS/Linux) | Windows (PowerShell) | Description |
|-------------------|----------------------|-------------|
| `./scripts/setup-env.sh` | `.\scripts\setup-env.ps1` | Configuration variables Qt |
| `./scripts/configure.sh` | `.\scripts\configure.ps1` | Configuration CMake |
| `./scripts/build-all.sh` | ❌ (utiliser CMake) | Build tous les projets |
| `./scripts/dev.sh` | ❌ (utiliser CMake) | Mode développement |
| `./scripts/update-all-pupitres.sh` | ❌ (SSH Unix uniquement) | Mise à jour des pupitres |

**Recommandation Windows** : Utiliser CMake directement plutôt que les scripts bash.

## 🔧 Configuration Requise

### Qt WebAssembly

Les scripts utilisent Qt 6.10.0 avec le toolchain WebAssembly :

```bash
$HOME/Qt/6.10.0/wasm_singlethread/bin/qt-cmake
```

**Installation Qt pour WebAssembly** :
1. Télécharger Qt 6.10+ depuis [qt.io](https://www.qt.io/download)
2. Installer le module **Qt for WebAssembly**
3. Vérifier que `qt-cmake` est disponible

### Node.js

**Version requise** : Node.js 18+

```bash
node --version  # Vérifier la version
npm --version
```

### .NET SDK

**Version requise** : SDK 10. La configuration CMake exécute `dotnet tool restore` et, si `dotnet paket` répond, `dotnet paket restore`. Les projets sont listés dans le README, section Serveurs .NET.

```bash
dotnet --version
```

### Emscripten (pour Qt WebAssembly)

Qt WebAssembly nécessite Emscripten. Normalement installé avec Qt.

## 🚀 Workflow de Développement

### Première utilisation

```bash
# 1. Build tous les projets
./scripts/build-all.sh

# 2. Tester un projet
./scripts/dev.sh sirenepupitre
```

### Développement quotidien

```bash
# Développer sur un projet spécifique
./scripts/dev.sh sirenconsole

# Modifier le code QML...
# Ctrl+C pour arrêter le serveur

# Rebuild et relancer
./scripts/dev.sh sirenconsole
```

### Nettoyage et rebuild complet

```bash
# Nettoyer tout
./scripts/clean-all.sh

# Rebuild tout
./scripts/build-all.sh
```

## 📦 Structure des Projets

### Projets Qt/QML (SirenePupitre, SirenConsole)

```
ProjectName/
├── CMakeLists.txt
├── main.cpp
├── config.js
├── QML/
├── build/              # Créé par le build
└── webfiles/           # Fichiers pour le serveur
    ├── server.js
    └── [fichiers compilés]
```

### pedalierSirenium (structure différente)

```
pedalierSirenium/
├── QtFiles/
│   ├── CMakeLists.txt
│   ├── main.cpp
│   ├── qml/
│   └── build/          # Créé par le build
├── pd/                 # Patches PureData
└── webfiles/           # Fichiers pour le serveur
```

### sirenRouter (Node.js)

```
sirenRouter/
├── package.json
├── src/
│   ├── server.js
│   └── api/
└── node_modules/       # Créé par npm install
```

## 🐛 Dépannage

### Erreur "qt-cmake not found"

Vérifier le chemin dans `build-project.sh` :

```bash
QT_CMAKE="$HOME/Qt/6.10.0/wasm_singlethread/bin/qt-cmake"
```

Ajuster selon votre installation Qt.

### Port déjà utilisé

Le script `dev.sh` tue automatiquement les processus sur le port, mais si ça ne marche pas :

```bash
# Tuer manuellement
lsof -ti:8000 | xargs kill -9

# Ou utiliser clean-all
./scripts/clean-all.sh
```

### Build échoue

```bash
# Nettoyer et réessayer
./scripts/clean-all.sh
./scripts/build-project.sh <project>
```

### Fichiers wasm très gros

Les fichiers `.wasm` peuvent faire 30-40 MB. C'est normal pour Qt WebAssembly.

## 📝 Logs

Les serveurs créent des logs temporaires :

```bash
# Voir les logs d'un serveur
tail -f /tmp/sirenepupitre_server.log
tail -f /tmp/sirenconsole_server.log
tail -f /tmp/pedalier_server.log
```

## 🔗 Liens Utiles

- [Documentation Qt WebAssembly](https://doc.qt.io/qt-6/wasm.html)
- [Emscripten](https://emscripten.org/)
- [README racine du monorepo](../README.md)
- [Documentation architecture](../docs/ARCHITECTURE.md)
- [Documentation build détaillée](../docs/BUILD.md)

