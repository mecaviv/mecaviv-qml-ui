# Contrat partagé : ce qui circule entre les applications

Première étape de la migration vers Fable : recenser, **depuis le code** et pas depuis la doc,
tout ce qui circule entre SirenePupitre, SirenConsole, pedalierSirenium, SirenManager,
sirenRouter, leurs serveurs et PureData. C'est la base du futur projet F# `Shared`, compilé
en .NET pour les serveurs et en JavaScript (Fable) pour les clients : un message y sera décrit
une seule fois.

Relevé sur `main` (`f62aaa4`). Les documents existants (`docs/COMMUNICATION.md`,
`docs/MIDI_WEBSOCKET_API.md`, `SirenePupitre/STRUCTURE_BINAIRE_0x02.md`…) ont servi de carte,
mais chaque entrée ci-dessous a été retrouvée dans le code. Côté PureData, les patchs sont dans
`puredata-abstractions` (`main`).

> **État : inventaire.** Les directions (qui envoie, qui reçoit) ont été relevées en lisant le
> contexte de chaque occurrence ; quelques-unes restent à confirmer (marquées ⚠). Les champs de
> chaque message sont l'étape suivante.

## 1. Les canaux

| Application | Port | Canal | Implémenté dans | Pair |
|---|---|---|---|---|
| SirenePupitre | 8000 | HTTP (fichiers WASM, `/api/midi/notes`, `/api/midi/conductor-cues`) | `SirenePupitre/webfiles/server.js`, `api-midi*.js` | navigateur |
| SirenePupitre | 10002 (par pupitre, `websocketPort`) | WebSocket JSON + binaire | `QML/controllers/WebSocketController.qml` | PureData (`M645.pd`), SirenConsole |
| SirenConsole | 8001 | HTTP (presets, MIDI, `/api/puredata/events`, `/api/pupitres/…`) + WebSocket `/ws` | `SirenConsole/webfiles/server.js`, `api-presets.js`, `api-midi.js` | navigateur, QML |
| SirenConsole | — | WebSocket client vers chaque pupitre | `SirenConsole/webfiles/puredata-proxy.js` | PureData des pupitres |
| pedalierSirenium | 8010 | HTTP (`/api/*`, `/log`, `/logs`, `/logs/stream`) | `pedalierSirenium/webfiles/server.js` | navigateur kiosque |
| pedalierSirenium | 10000 | WebSocket JSON + binaire | `QtFiles/qml/qmlwebsocketserver/controllers/WebSocketController.qml` | PureData (`pedalier.pd`) |
| SirenManager | 8005 / 8006 | HTTP + WebSocket (SSH, UDP pour le build navigateur) | `SirenManager/backend/fsharpwebserver` (F#, déjà porté) | navigateur |
| SirenManager | 8081 / 8082 | HTTP statique + WebSocket ping | `SirenManager/webfiles/server.js` | navigateur |
| SirenManager | UDP | protocole V1 du parc | `SirenManager/src/UdpController.cpp` (+ `mecaviv-v1`, C ABI) | cartes du parc |
| sirenRouter | 8002 (8003 WS, 8004 UDP non liés) | HTTP `/request`, `/release`, `/status`, `/force-release` | `sirenRouter/src/api/control.js` (le `server.js` manque) | consoles |

## 2. Messages JSON (champ `type`)

Émetteurs et récepteurs trouvés. « PureData » renvoie au patch de `puredata-abstractions`
qui contient le nom.

### Console ↔ Pupitre ↔ PureData

| `type` | Envoyé par | Reçu par |
|---|---|---|
| `CONFIG_FULL` | SirenConsole (`server.js`, `puredata-proxy.js`) | SirenePupitre, pedalierSirenium, `puredata-proxy.js` |
| `REQUEST_CONFIG` | SirenePupitre, `puredata-proxy.js` | PureData (`M645.pd`), `puredata-proxy.js` |
| `PARAM_UPDATE` | SirenConsole (`server.js`), SirenePupitre | SirenePupitre, `puredata-proxy.js`, PureData (`M645.pd`) |
| `PARAM_CHANGED` | SirenePupitre (`ConfigController`, `AdvancedSizes`, `ColorPicker`), `puredata-proxy.js` | `puredata-proxy.js`, PureData (`M645.pd`) |
| `CONSOLE_CONNECT` | SirenConsole (`server.js`) | SirenePupitre |
| `CONSOLE_DISCONNECT` | ⚠ introuvable | SirenePupitre |
| `GAME_MODE` | SirenConsole, SirenePupitre (`NavigationManager`) | SirenConsole, SirenePupitre, PureData (`M645.pd`) |
| `UI_CONTROLS` | SirenConsole (`CommandManager`, `server.js`, `puredata-proxy.js`), SirenePupitre | SirenConsole (`server.js`) |
| `GEAR` | SirenePupitre | SirenePupitre, PureData (`M645.pd`) |
| `SIRENS_SELECTED` | SirenePupitre (`ConfigController`) | PureData (`M645.pd`) |
| `COMPOSESIREN_CC_CHANGED` | SirenePupitre (`ConfigController`) | PureData (`M645.pd`) |
| `ACCOMPANIMENT_ENABLED` | SirenePupitre (`GameOptionsDialog`) | PureData (`M645.pd`) |
| `AUTONOMY_MODE` | SirenConsole (`CommandManager`), SirenePupitre (`GameOptionsDialog`) | SirenConsole (`server.js`) |
| `PAD_CONNECTED` | ⚠ introuvable (firmware du pad ?) | SirenePupitre |
| `PAD_CALIBRATION_VALUE` | PureData (`M645.pd`) | SirenePupitre |
| `JOYSTICK_FILTERED` | PureData (`M645.pd`) | SirenePupitre |
| `JOYSTICK_CALIBRATION_STATE` | PureData (`M645.pd`) | SirenePupitre |
| `MUSIC_VISUALIZER` | ⚠ introuvable | SirenePupitre |
| `CONDUCTOR_CUE` | ⚠ introuvable (Reaper ? voir `docs/CONDUCTOR_CUES_PROTOCOL.md`) | SirenePupitre (`ConductorCueDriver`) |
| `BINARY_END` | PureData (`M645.pd`) | SirenePupitre |
| `PAD_CALIBRATION`, `JOYSTICK_CALIBRATION`, `SPEAKER_TEST` | **seulement** `ControllersPanel.qml` (code mort, voir § 5) | PureData (`M645.pd`) |

### Console ↔ serveur de la console

| `type` | Envoyé par | Reçu par |
|---|---|---|
| `SIRENCONSOLE_IDENTIFICATION` | SirenConsole (`WebSocketManager`) | `server.js` |
| `PUPITRE_IDENTIFICATION` | ⚠ introuvable | `server.js` |
| `INITIAL_STATUS`, `PUPITRE_STATUS_UPDATE`, `SYNC_STATUS_CHANGED` | `server.js` | SirenConsole (`WebSocketManager`) |
| `PUPITRE_CONNECTED` | `server.js`, `puredata-proxy.js` | SirenConsole |
| `PUPITRE_DISCONNECTED` | `puredata-proxy.js` | SirenConsole |
| `PUPITRE_STATUS` | ⚠ introuvable | `puredata-proxy.js`, `server.js` |
| `VOLANT_DATA` | `server.js`, `puredata-proxy.js` (depuis la trame binaire `SS`) | SirenConsole |
| `PING` / `PONG` | SirenConsole / `server.js` | `server.js` / SirenConsole |
| `PRESET_UPDATED_FROM_PUPITRE` | `server.js` | ⚠ aucun récepteur trouvé |

### Lecture MIDI

| `type` | Envoyé par | Reçu par |
|---|---|---|
| `MIDI_TRANSPORT` | SirenConsole (`MidiPlayer`, `CommandManager`), SirenePupitre (`NavigationManager`, `SequencerController`) | SirenConsole (`server.js`) |
| `MIDI_FILE_LOAD` | SirenConsole (`CommandManager`), SirenePupitre (`GameAutonomyPanel`) | SirenConsole (`server.js`) |
| `MIDI_SEEK`, `TEMPO_CHANGE` | SirenConsole (`MidiPlayer`, `CommandManager`) | SirenConsole (`server.js`) |
| `MIDI_PLAYBACK_STATE` | `puredata-proxy.js` | `puredata-proxy.js` |
| `MIDI_FILES_LIST` | SirenePupitre (`api-midi.js`) | SirenePupitre (`WebSocketController`, `GameAutonomyPanel`) |
| `MIDI_NOTES` | SirenePupitre (`api-midi-notes.js`) | ⚠ aucun récepteur trouvé |
| `MIDI_NOTE` | SirenConsole (`midi-sequencer.js`) | ⚠ aucun récepteur trouvé |

### Pédalier ↔ PureData

| `type` | Envoyé par | Reçu par |
|---|---|---|
| `VOICE_SELECT` | pedalierSirenium (`ConfigView2D`, `LiveState`) | PureData (`voice-state.pd`, `pedalier.pd`) |
| `LOOPER_SCENES` | PureData (`composition-io.pd`) | pedalierSirenium |
| `SIREN_LOOPER` | PureData (`harmonizer.pd`) | pedalierSirenium |
| `SEQUENCES` | PureData (`sequences-io.pd`) | pedalierSirenium (`LiveState`, `sequences.js`) |
| `CONFIG_FULL` | voir plus haut | pedalierSirenium |

## 3. Trames binaires

Le premier octet est un code, mais **son sens dépend du canal** : un même code n'a pas la même
signification d'un canal à l'autre, et SirenePupitre les distingue aussi par la longueur. Dans
`Shared`, chaque canal aura son propre type, jamais un code global.

### PureData → SirenePupitre (WebSocket 10002) — `WebSocketController.qml`

| Code | Longueur | Contenu | Doc |
|---|---|---|---|
| `0x01` | 4, 6 ou 9 octets | position de lecture ; la variante 9 octets porte un temps en `float32` LE | `STRUCTURE_BINAIRE_*` |
| `0x02` | 18 octets | état complet (`STRUCTURE_BINAIRE_0x02.md`) | ✓ |
| `0x03` | 5 octets | | |
| `0x04` | 5 octets | | |
| `0x05` | 3 octets | | |
| `0x06` | 2 octets | valeur de l'encodeur (navigation) | `STRUCTURE_BINAIRE_0x06.md` |
| `0x07` | 2 octets | appui de l'encodeur | |

### PureData → SirenConsole (`puredata-proxy.js`)

| Code | Longueur | Contenu |
|---|---|---|
| `0x00 0x00` | 2 octets | trame vide, ignorée |
| `"SS"` + `0x01` | | `VOLANT_STATE`, retransmis en JSON `VOLANT_DATA` |
| `0x01` | 10 octets | POSITION, toutes les 50 ms |
| `0x02` | 10 octets / plus de 100 | FILE_INFO au chargement, ou `CONFIG_FULL` (JSON après l'octet de tête) |
| `0x03` | 3 octets | TEMPO, quand il change |
| `0x04` | 3 octets | signature rythmique, quand elle change |
| `0x06` | 6 ou 8 octets | position en ticks |
| `0x7B` (`{`) | | JSON brut |

### Pédalier ↔ PureData (WebSocket 10000)

MIDI brut : Note On `0x90`, Note Off `0x80`, Pitch Bend `0xE0` (`MidiMonitorController.qml`),
plus les trames décodées dans `WebSocketController.qml` (à détailler).

### SirenManager ↔ cartes du parc (UDP, protocole V1)

Codes `0x21`, `0x22`, `0x26`, `0x34`… dans `UdpController.cpp`. **Ce protocole a déjà une
implémentation de référence en Rust** : la crate `mecaviv-v1` de `mecaviv-rs`, que SirenManager
appelle par une C ABI. `Shared` ne doit pas le redécrire : il faudra soit le lier (comme
aujourd'hui), soit le générer depuis la même source.

## 4. Routes HTTP

| Serveur | Routes |
|---|---|
| SirenePupitre (8000) | `/api/midi/notes`, `/api/midi/conductor-cues` |
| SirenConsole (8001) | `/api/presets` (GET, POST), `/api/presets/:id` (GET, PUT, DELETE), `/api/presets/current` et `…/assigned-sirenes`, `…/sirene-config`, `…/outputs`, `…/controller-mapping`, `…/game-mode`, `…/upload`, `…/download` ; `/api/pupitres/…` ; `/api/puredata/events` |
| pedalierSirenium (8010) | `/api/config`, `/api/bluetooth`, `/api/bluetooth/connect`, `/api/sirens`, `/api/rtp`, `/api/temperature`, `/api/system-info`, `/log` (POST), `/logs`, `/logs/stream` |
| sirenRouter (8002) | `/request`, `/release`, `/status`, `/force-release` |
| SirenManager | déjà décrit dans `SirenManager/backend/NODE_CODEBASE.md` et porté en F# |

## 5. Constats

- **Code mort.** `PAD_CALIBRATION`, `JOYSTICK_CALIBRATION` et `SPEAKER_TEST` ne sont émis que par
  `ControllersPanel.qml`, qui n'est plus affiché (seule la page de test `Test2D.qml` l'utilise).
  Les contrôleurs ayant été retirés de SirenePupitre, ces messages sortent du contrat — sauf si
  PureData (`M645.pd`) doit encore les recevoir d'ailleurs.
- **Émetteurs introuvables** (⚠) : `CONSOLE_DISCONNECT`, `PAD_CONNECTED`, `MUSIC_VISUALIZER`,
  `CONDUCTOR_CUE`, `PUPITRE_IDENTIFICATION`, `PUPITRE_STATUS`. Ni dans ce dépôt ni dans
  `puredata-abstractions` : envoyés par un autre programme (Reaper, firmware du pad
  `SirenePupitre/firmware`), construits dynamiquement, ou morts.
- **Récepteurs introuvables** : `PRESET_UPDATED_FROM_PUPITRE`, `MIDI_NOTES`, `MIDI_NOTE`.
- **Codes binaires réutilisés** d'un canal à l'autre avec des sens différents (§ 3).
- **`CONFIG_FULL`** existe deux fois : en JSON, et en binaire (`0x02` suivi de JSON) depuis
  PureData vers la console.
- **Les `config.js`** (`SirenePupitre/config.js`, `SirenConsole/config.js`, `config-loader.js`) sont
  lus à la fois par QML et par Node : leur forme fait partie du contrat (étape suivante).

## 6. Vers le projet `Shared`

Découpage proposé, un module par canal plutôt qu'un catalogue global :

- `Shared.Messages` — les messages JSON du § 2, en unions F# (`type` → cas), avec encodeur et
  décodeur JSON identiques côté .NET et côté Fable ;
- `Shared.Frames.Pupitre`, `Shared.Frames.PureDataConsole`, `Shared.Frames.Pedalier` — les trames
  binaires du § 3, une union par canal ;
- `Shared.Http` — les routes et les corps du § 4 ;
- `Shared.Config` — la forme des `config.js`, destinée à devenir du JSON ;
- le protocole V1 reste à `mecaviv-v1`.

Étapes suivantes, une par commit :
1. les champs de chaque message JSON et de chaque trame (depuis le code émetteur et récepteur) ;
2. la forme des `config.js` et des presets ;
3. lever les ⚠ (un `print` côté PureData ou une capture WebSocket tranche) ;
4. le projet `Shared` lui-même, avec des tests octet par octet contre des captures réelles.
