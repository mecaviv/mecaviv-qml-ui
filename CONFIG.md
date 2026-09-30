# Configuration - Mecaviv QML UI

Guide de configuration pour adapter le projet à votre environnement.

## 🚀 Configuration Rapide (Recommandé)

**Scripts interactifs** pour configurer automatiquement vos chemins Qt :

### macOS / Linux

```bash
# Lancer le script de configuration (bash)
./scripts/setup-env.sh

# Le script va:
# 1. Détecter votre système (macOS/Linux)
# 2. Chercher Qt dans les emplacements standards
# 3. Vous proposer de valider ou personnaliser les chemins
# 4. Optionnellement ajouter les variables à votre ~/.zshrc ou ~/.bashrc
```

### Windows

```powershell
# Lancer le script de configuration (PowerShell)
.\scripts\setup-env.ps1

# Le script va:
# 1. Chercher Qt dans C:\Qt\
# 2. Vous proposer de valider ou personnaliser les chemins
# 3. Optionnellement ajouter les variables aux variables système Windows
```

**Ou configuration manuelle** (voir ci-dessous) :

## 📋 Prérequis

Avant de configurer, assurez-vous d'avoir installé :
- Qt 6.10+ (Desktop + WebAssembly)
- CMake 3.19+
- Node.js 18+
- .NET SDK 10 (`dotnet watch`, `dotnet run`)
- Ninja

## 🔧 Configuration des Chemins Qt

Le projet utilise des variables d'environnement pour les chemins Qt. Vous devez les configurer selon votre installation.

### Variables Requises

| Variable | Description | Exemple |
|----------|-------------|---------|
| `QT_DIR` | Chemin Qt Desktop | `/Users/USERNAME/Qt/6.10.0/macos` |
| `QT_WASM_DIR` | Chemin Qt WebAssembly | `/Users/USERNAME/Qt/6.10.0/wasm_singlethread` |

### Configuration par Système

#### macOS / Linux

Ajouter à votre `~/.zshrc` ou `~/.bashrc` :

```bash
# Qt Paths pour mecaviv-qml-ui
export QT_DIR="$HOME/Qt/6.10.0/macos"           # macOS
# export QT_DIR="$HOME/Qt/6.10.0/gcc_64"        # Linux

export QT_WASM_DIR="$HOME/Qt/6.10.0/wasm_singlethread"
```

Puis recharger :
```bash
source ~/.zshrc  # ou ~/.bashrc
```

#### Windows (PowerShell)

Ajouter à votre profil PowerShell (`$PROFILE`) :

```powershell
# Qt Paths pour mecaviv-qml-ui
$env:QT_DIR = "C:\Qt\6.10.0\msvc2019_64"
$env:QT_WASM_DIR = "C:\Qt\6.10.0\wasm_singlethread"
```

Ou via les variables d'environnement système :
1. Panneau de configuration → Système → Paramètres système avancés
2. Variables d'environnement
3. Nouvelle variable utilisateur :
   - Nom : `QT_DIR`
   - Valeur : `C:\Qt\6.10.0\msvc2019_64`
4. Nouvelle variable utilisateur :
   - Nom : `QT_WASM_DIR`
   - Valeur : `C:\Qt\6.10.0\wasm_singlethread`

### Vérification

```bash
# Vérifier que les variables sont définies
echo $QT_DIR
echo $QT_WASM_DIR

# macOS/Linux
ls $QT_DIR/bin/qmake
ls $QT_WASM_DIR/bin/qmake

# Windows
dir %QT_DIR%\bin\qmake.exe
dir %QT_WASM_DIR%\bin\qmake.exe
```

## 🚀 Configuration Temporaire (Test Rapide)

Si vous voulez tester sans modifier vos fichiers de configuration :

### macOS / Linux

```bash
# Définir les variables pour la session actuelle
export QT_DIR="$HOME/Qt/6.10.0/macos"
export QT_WASM_DIR="$HOME/Qt/6.10.0/wasm_singlethread"

# Puis builder
cmake --preset=default
cmake --build build
```

### Windows (PowerShell)

```powershell
# Définir les variables pour la session actuelle
$env:QT_DIR = "C:\Qt\6.10.0\msvc2019_64"
$env:QT_WASM_DIR = "C:\Qt\6.10.0\wasm_singlethread"

# Puis builder
cmake --preset=default
cmake --build build
```

## 🔍 Trouver votre Installation Qt

Si vous ne connaissez pas le chemin de votre installation Qt :

### macOS / Linux

```bash
# Recherche Qt dans les emplacements courants
ls -d ~/Qt/*/
ls -d /opt/Qt/*/
```

### Windows

```powershell
# Recherche Qt sur le disque C:
dir C:\Qt /s
```

### Chemins Typiques

| OS | Chemin Desktop | Chemin WASM |
|---|---|---|
| **macOS** | `~/Qt/6.10.0/macos` | `~/Qt/6.10.0/wasm_singlethread` |
| **Linux** | `~/Qt/6.10.0/gcc_64` | `~/Qt/6.10.0/wasm_singlethread` |
| **Windows** | `C:\Qt\6.10.0\msvc2019_64` | `C:\Qt\6.10.0\wasm_singlethread` |

## ⚙️ Configuration Avancée

### Utiliser une Version Qt Différente

Si vous avez Qt 6.8 au lieu de 6.10 :

```bash
export QT_DIR="$HOME/Qt/6.8.0/macos"
export QT_WASM_DIR="$HOME/Qt/6.8.0/wasm_singlethread"
```

### Plusieurs Installations Qt

Utilisez des alias pour basculer facilement :

```bash
# Dans ~/.zshrc ou ~/.bashrc

# Qt 6.10
alias qt610='export QT_DIR="$HOME/Qt/6.10.0/macos" && export QT_WASM_DIR="$HOME/Qt/6.10.0/wasm_singlethread"'

# Qt 6.8
alias qt68='export QT_DIR="$HOME/Qt/6.8.0/macos" && export QT_WASM_DIR="$HOME/Qt/6.8.0/wasm_singlethread"'

# Usage:
# qt610  # Activer Qt 6.10
# qt68   # Activer Qt 6.8
```

## 🐛 Troubleshooting

### Erreur "QT_DIR not set"

```
CMake Error: QT_DIR environment variable is not set
```

**Solution** : Définir la variable `QT_DIR` comme indiqué ci-dessus.

### Erreur "Qt6 not found"

```
CMake Error: Could not find a package configuration file provided by "Qt6"
```

**Solutions** :
1. Vérifier que `QT_DIR` pointe vers le bon dossier :
   ```bash
   ls $QT_DIR/lib/cmake/Qt6
   ```
2. Si le dossier n'existe pas, vérifier l'installation Qt
3. Essayer de spécifier le chemin directement :
   ```bash
   cmake --preset=default -DQt6_DIR="$QT_DIR/lib/cmake/Qt6"
   ```

### Les Variables ne Persistent Pas

**macOS/Linux** : Vérifier que vous avez bien ajouté les `export` dans `~/.zshrc` (macOS) ou `~/.bashrc` (Linux), puis :
```bash
source ~/.zshrc  # ou ~/.bashrc
```

**Windows** : Utiliser les variables d'environnement système (via le Panneau de configuration) plutôt que PowerShell pour une configuration permanente.

## 📚 Voir Aussi

- [Guide de Build Complet](docs/BUILD.md)
- [README Principal](README.md)
- [Documentation CMake](https://cmake.org/cmake/help/latest/manual/cmake-presets.7.html)

