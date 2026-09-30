# SirenManager

Application QML/WebAssembly pour le contrôle des sirènes Mecaviv, migration complète de SireneControlMac.

## Vue d'ensemble

SirenManager est une application complète pour contrôler les sirènes Mecaviv via une interface moderne en QML. Elle reproduit toutes les fonctionnalités de SireneControlMac avec 10 vues principales :

1. **PLAYER** - Séquenceur MIDI avec contrôle de lecture
2. **MIXAGE** - Mixer avec contrôleurs de volume
3. **SIRENIUM** - Contrôle du sirenium (pédalier)
4. **MAINTENANCE** - Contrôle des moteurs et clapets
5. **CONTROLEURS** - Contrôleurs MIDI
6. **PIANO** - Piano virtuel
7. **VOITURES** - Contrôle des voitures A/B
8. **PAVILLONS** - Contrôle des pavillons 1/2
9. **SYSTÈME** - Maintenance système avec SSH proxy
10. **PLAYLISTS** - Compositeur de playlists

## Architecture

- **Frontend QML** : Interface utilisateur moderne avec 10 vues
- **Backend C++** : Modules pour communication UDP, gestion playlists, configuration
- **Service Node.js** : Proxy SSH pour les opérations de maintenance système
- **WebAssembly** : Compilation pour navigateur web

## Prérequis

- Qt 6.10+ avec support WebAssembly
- CMake 3.19+
- Node.js 18+ (pour le backend SSH)
- Qt for WebAssembly (wasm_singlethread)

## Build

### WebAssembly

```bash
# Configurer les variables d'environnement Qt
export QT_DIR="$HOME/Qt/6.10.0/macos"
export QT_WASM_DIR="$HOME/Qt/6.10.0/wasm_singlethread"

# Build WebAssembly
cd SirenManager
mkdir -p build
cd build
$QT_WASM_DIR/bin/qt-cmake ..
make -j$(sysctl -n hw.ncpu)
```

### Desktop natif

```bash
cd SirenManager
mkdir -p build
cd build
cmake ..
make -j$(sysctl -n hw.ncpu)
```

## Structure du projet

```
SirenManager/
├── src/              # Code C++ backend
├── QML/              # Interfaces QML
├── backend/          # Service Node.js pour proxy SSH
├── resources/        # Ressources (icônes, images)
└── webfiles/         # Fichiers générés pour WebAssembly
```

## Gestion des playlists (PLAYLISTS tab)

Le composer accepte plusieurs playlists `.ListLecture` dans `liste_de_lecture/` :

- **Combo Playlist** — sélectionne la playlist à éditer ; étoile ★ devant la playlist active (pointée par `derniere_liste`).
- **Charger / Sauvegarder** opèrent sur la sélection du combo.
- **Définir comme active** réécrit `derniere_liste` puis envoie `NEWLIST` (UDP 0x02) au firmware pour rechargement à chaud — pas besoin de reboot.
- **Nouvelle…** crée un fichier vide ; **Supprimer** retire (refusé sur la playlist active).
- L'extension `.ListLecture` est masquée dans l'UI et la casse originale du fichier est préservée (le dossier peut contenir `.ListLecture` et `.listlecture` mélangés).
- Au save d'une playlist active, l'app envoie aussi `NEWLIST` pour que le firmware relise le contenu modifié.

Le fichier `ALLLIST` (catalogue lu par le firmware au boot et sur `ASKSYNCHRO`) est régénéré automatiquement à chaque création / suppression.

## Synchronisation vers les sirènes

Bouton **Sync vers sirènes** :

- **Mode additif (défaut)** — `tar c | tar x`, copie les fichiers, ne supprime rien.
- **Mode miroir (case à cocher)** — supprime aussi les `.mid*` et `.ListLecture` présents sur la cible mais absents de Maître. La case **Aperçu uniquement** liste les fichiers concernés sans rien toucher (pour valider avant de commettre).

La source est toujours Linux Maître (modèle "source de vérité unique") ; les autres machines sont des miroirs.

## Backend SSH

Le service backend exécute les commandes SSH depuis le navigateur (via WebAssembly). Depuis la racine `mecaviv-qml-ui` :

```bash
dotnet watch --non-interactive --project SirenManager/backend/fsharpwebserver
dotnet run --project SirenManager/backend/fsharpwebserver
```

Le serveur écoute sur le port 8005 (HTTP) et 8006 (WebSocket).

## SSH key persistence (Artila M508)

Les sirènes Artila (Linux Maître + S1–S7 + voitures + pavillons) ont leur rootfs sur **ramdisk volatile** (`/dev/ram0`). Au reboot, `/.ssh/authorized_keys` disparaît, ce qui obligeait à refaire `ssh-copy-id` à chaque redémarrage.

**Solution déployée (CLI, une fois par machine)** : modification de `/mnt/disk/home/guest/lance_taches` (sur le filesystem persistant `/mnt/disk` jffs2) pour qu'il restaure la clé depuis `/mnt/disk/.ssh-persist/authorized_keys` au boot, **avant** de lancer `m_seq.ko` et les autres modules. Marqueur d'idempotence : `# SirenManager-PersistKey-v1`.

**État** : déployé sur Linux Maître, pavillons 1–2, sirènes S1–S7. Reste : voitures A/B (à faire quand elles sont accessibles).

**Pour ajouter une nouvelle clé après coup** : la persist-key snapshot ce qui est dans `/.ssh/authorized_keys` au moment du snapshot. Si une nouvelle machine de contrôle est ajoutée, après son `ssh-copy-id`, ré-exécuter sur chaque sirène :

```bash
ssh <alias> 'cp /.ssh/authorized_keys /mnt/disk/.ssh-persist/authorized_keys'
```

sinon la nouvelle clé disparait au prochain reboot.

## Cloner l'accès SSH sur une autre machine

L'onglet **SYSTÈME** propose un bouton **"Exporter clés SSH"** qui crée une archive `~/Downloads/sirenmanager-keys-<timestamp>.tar.gz` contenant :

- la clé privée `id_rsa_sirenes` (mode 600)
- la clé publique `id_rsa_sirenes.pub`
- les blocs `Host` des 13 sirènes extraits de `~/.ssh/config` (algos legacy SHA-1 inclus, `IdentityFile` normalisé en `~/.ssh/...`)
- un script `INSTALL.sh` interactif (POSIX sh, macOS 10.15+ / Linux) qui copie la clé dans `~/.ssh/` et append les Host alias dans `~/.ssh/config` avec confirmation par étape
- un `README.txt` rappelant la sécurité

Sur la machine cible : `tar xzf sirenmanager-keys-*.tar.gz && cd sirenmanager-keys-* && ./INSTALL.sh`.

⚠ La clé privée donne un accès root à toutes les sirènes — transférer via canal sûr (USB, scp, AirDrop), pas par email/Slack/git.

## Communication

- **UDP** : Communication avec les sirènes via proxy WebSocket
- **SSH** : Opérations de maintenance via backend Node.js
- **WebSocket** : Communication temps réel

## License

Copyright © Mecaviv. All rights reserved.


