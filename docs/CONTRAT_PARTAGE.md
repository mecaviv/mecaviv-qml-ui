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

> **État : inventaire (étape 1) et champs (étape 2).** Les directions (qui envoie, qui reçoit)
> ont été relevées en lisant le contexte de chaque occurrence ; quelques-unes restent à confirmer
> (marquées ⚠).
>
> **Hors contrat pour l'instant : les pads et le joystick** de SirenePupitre. Leur technologie a
> changé et leur calibrage sera repensé (fin octobre 2026). Les messages qui les concernent
> (`PAD_*`, `JOYSTICK_*`, et les octets pads/joystick de la trame `0x02`) sont listés pour mémoire
> mais ne seront pas portés tels quels.

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

## 2. Messages JSON

**Deux discriminants coexistent** : la plupart des messages ont un champ `type`, mais le pédalier
(`LOOPER_SCENES`, `SIREN_LOOPER`, `SEQUENCES`, `SIRENIUM`, `VOICE_SELECT`) et `MUSIC_VISUALIZER`
côté pupitre utilisent le champ **`device`**. Le pédalier envoie en plus son JSON **dans des trames
binaires** (`sendBinaryMessage`, marqué « @CRITICAL: ne pas changer »).

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
| `PAD_CONNECTED` 🔧 | ⚠ introuvable (firmware du pad ?) | SirenePupitre |
| `PAD_CALIBRATION_VALUE` 🔧 | PureData (`M645.pd`) | SirenePupitre |
| `JOYSTICK_FILTERED` 🔧 | PureData (`M645.pd`) | SirenePupitre |
| `JOYSTICK_CALIBRATION_STATE` 🔧 | PureData (`M645.pd`) | SirenePupitre |
| `device: MUSIC_VISUALIZER` | ⚠ introuvable | SirenePupitre |
| `CONDUCTOR_CUE` | ⚠ introuvable (Reaper ? voir `docs/CONDUCTOR_CUES_PROTOCOL.md`) | SirenePupitre (`ConductorCueDriver`) |
| `BINARY_END` | PureData (`M645.pd`) | SirenePupitre |
| `PAD_CALIBRATION` 🔧, `JOYSTICK_CALIBRATION` 🔧, `SPEAKER_TEST` | **seulement** `ControllersPanel.qml` (code mort, voir § 5) | PureData (`M645.pd`) |

🔧 : pads / joystick, en refonte (voir l'état en tête).

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

### Champs

Relevés dans le code émetteur (clés de l'objet construit) et récepteur (champs lus).
`source` vaut `"console"`, `"pupitre"`… ; `timestamp` est un `Date.now()` en ms.

| Message | Champs |
|---|---|
| `PARAM_UPDATE` | `path` : **tableau** de clés (chaînes ou index numériques : `["sirenConfig","sirens",2,"frettedMode","enabled"]`), `value`, `source` |
| `PARAM_CHANGED` | `path` (tableau), `value`, `source` |
| `REQUEST_CONFIG` | (pupitre) aucun ; (console → PureData) `pupitreId`, `source` |
| `CONFIG_FULL` | `config` : l'objet de configuration complet (forme : étape suivante) |
| `CONSOLE_CONNECT` / `CONSOLE_DISCONNECT` | `source` |
| `GAME_MODE` | `enabled` (bool), `source` |
| `UI_CONTROLS` | `pupitreId`, `enabled` — **relayé par le serveur sous la forme** `PARAM_UPDATE` `path: ["uiControls","enabled"]`, `value: 0/1` |
| `AUTONOMY_MODE` | `pupitreId`, `device`, `enabled`, `source` |
| `ACCOMPANIMENT_ENABLED` | `enabled`, `source` |
| `GEAR` | `position` : 0–4 (rapports → 0, 1, 12, 24, 48 demi-tons) |
| `SIRENS_SELECTED` | `sirenIds`, `sirenNumbers` |
| `COMPOSESIREN_CC_CHANGED` | `controllerName`, `cc`, `value` |
| `CONDUCTOR_CUE` | transmis tel quel à `ConductorCueDriver` (voir `docs/CONDUCTOR_CUES_PROTOCOL.md`) |
| `device: MUSIC_VISUALIZER` | `config` **ou** données musicales (`midiNote`, `controllers`) |
| `SIRENCONSOLE_IDENTIFICATION`, `PING`, `PONG` | `source`, `timestamp` |
| `PUPITRE_IDENTIFICATION` | `pupitreId`, `pupitreName` |
| `PUPITRE_CONNECTED` / `PUPITRE_DISCONNECTED` | `pupitreId`, `pupitreName`, `connected`, `timestamp` |
| `INITIAL_STATUS`, `PUPITRE_STATUS_UPDATE` | `data` (état des pupitres), `timestamp` |
| `SYNC_STATUS_CHANGED` | `pupitreId`, `isSynced`, `timestamp` |
| `VOLANT_DATA` | `pupitreId`, `velocity`, `frequency`, `rpm`, `timestamp`, et **selon l'émetteur** `noteFloat` (`puredata-proxy.js`) ou `note` + `pitchbend` (`server.js`) — le client lit `noteFloat` |
| `PRESET_UPDATED_FROM_PUPITRE` | `pupitreId`, `path`, `value`, `timestamp` |
| `MIDI_TRANSPORT` | `action` : `play` \| `pause` \| `stop`, `source` |
| `MIDI_FILE_LOAD` | `path` (relatif au dépôt de compositions), `source` |
| `MIDI_SEEK` | `position` (ms) |
| `TEMPO_CHANGE` | `tempo` (BPM), `smooth` |
| `MIDI_PLAYBACK_STATE` | `playing`, `position` (ms), `beat`, `tempo`, `timeSignature {numerator, denominator}`, `duration`, `totalBeats`, `file`, et `bar`, `beatInBar`, `tick`, `ppq` |
| `MIDI_FILES_LIST` | `categories` |
| `MIDI_NOTES` | `path`, `channel`, `byChannel`, `endOfTrackTick` |
| `MIDI_NOTE` | `note`, `velocity`, `channel` |
| `device: LOOPER_SCENES` | `action`, `batch`, `composition`, `scenes` |
| `device: SIREN_LOOPER` | `loops`, `voices`, `pedals`, `clock`, `clic`, `output` |
| `device: SEQUENCES` | `sequences` |
| `device: VOICE_SELECT` | `voice`, `siren` (et, à confirmer, `sirenStates`, `sirenPings`, `systemInfo`, `temperature`, `performance`) |

## 3. Trames binaires

**Un seul flux, deux lectures.** Le patch PureData d'un pupitre (`M645.pd`) parle sur le WebSocket
10002 du pupitre. SirenePupitre **et** la console (`puredata-proxy.js`, qui se connecte au même
port) le décodent, chacun à sa façon : **le sens d'une trame dépend du premier octet *et* de la
longueur**, et les deux décodeurs ne sont pas d'accord sur `0x01`, `0x04` et `0x06`. Dans `Shared`,
une trame sera identifiée par (code, longueur), et le désaccord devra être tranché côté PureData.

Entiers en little-endian sauf mention.

### PureData (`M645.pd`) → WebSocket 10002

| Code | Long. | Lu par le pupitre | Lu par la console |
|---|---|---|---|
| `0x01` | 4 | position : `flags` (bit 0 = lecture), mesure `u16` (base 0) | — |
| `0x01` | 6 | position : `flags`, tick `u32` | — |
| `0x01` | 9 | (ancien) `flags`, mesure `u16`, temps dans la mesure `u8`, temps `f32` | — |
| `0x01` | 10 | — | POSITION : `flags`, mesure `u16`, temps dans la mesure `u16`, temps `f32` (toutes les 50 ms) |
| `0x02` | 18 | **contrôleurs physiques** : volant `u16` (0–360°), pad 1 aftertouch/vélocité, pad 2 aftertouch/vélocité 🔧, joystick x/y/z 🔧 (0–127 positif, 128–255 négatif — voir § 5), bouton joystick, levier 0–4, fader, pédale, bouton 1, bouton 2, encodeur valeur, encodeur appui | — |
| `0x02` | 10 | — | FILE_INFO : durée `u32` (ms), nombre de temps `u32` |
| `0x02` | > 100 | — | `CONFIG_FULL` : JSON après l'octet de tête |
| `0x03` | 5 | note du volant : note, vélocité, pitch bend LSB, MSB (14 bits, ±2 demi-tons) | — |
| `0x03` | 3 | — | TEMPO : `u16` (BPM) |
| `0x04` | 5 | note de séquence : note, vélocité, durée `u16` (ms) | ignorée |
| `0x04` | 3 | — | signature rythmique : numérateur, dénominateur |
| `0x05` | 3 | contrôle continu : numéro, valeur | — |
| `0x06` | 2 | encodeur : valeur 0–127 | — |
| `0x06` | 6 / 8 | — | position en ticks : `flags`, tick `u32`, (`ppq` `u16` optionnel) |
| `0x07` | 2 | appui de l'encodeur : 0 / 1 | — |
| `"SS"` + type | 7 | — | volant : type (`0x01`), note, vélocité, pitch bend `u16` **big-endian** → JSON `VOLANT_DATA` |
| `0x00 0x00` | 2 | — | battement de cœur, ignoré |
| `{` | n | — | JSON brut (`CONFIG_FULL` ou config nue) |

### Configuration complète en morceaux

PureData envoie la grosse `CONFIG_FULL` découpée :
1. un message **texte** `BINARY_START <taille> <taille d'un morceau>` (lu par le pupitre) ;
2. des trames **binaires** : `taille totale u32`, `position u32`, puis les octets du JSON à cette
   position ;
3. un message **texte** `BINARY_END`, qui force le traitement même si des morceaux manquent.

La console et le pédalier reconnaissent le même en-tête de 8 octets. Rien dans l'en-tête ne le
distingue des trames courtes du tableau ci-dessus : seules la longueur et l'ordre de test évitent
la confusion.

### Pédalier ↔ PureData (WebSocket 10000)

- JSON **dans des trames binaires**, dans les deux sens (discriminant `device`, § 2) ;
- configuration en morceaux (en-tête de 8 octets, comme ci-dessus) ;
- MIDI brut pour le moniteur : Note On `0x90`, Note Off `0x80`, Pitch Bend `0xE0`
  (`MidiMonitorController.qml`).

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
  Les deux premiers relèvent de la refonte pads / joystick.
- **Émetteurs introuvables** (⚠) : `CONSOLE_DISCONNECT`, `PAD_CONNECTED`, `MUSIC_VISUALIZER`,
  `CONDUCTOR_CUE`, `PUPITRE_IDENTIFICATION`, `PUPITRE_STATUS`. Ni dans ce dépôt ni dans
  `puredata-abstractions` : envoyés par un autre programme (Reaper, firmware du pad
  `SirenePupitre/firmware`), construits dynamiquement, ou morts.
- **Récepteurs introuvables** : `PRESET_UPDATED_FROM_PUPITRE`, `MIDI_NOTES`, `MIDI_NOTE`.
- **Un flux PureData, deux décodeurs en désaccord** (§ 3) : `0x01`, `0x04` et `0x06` n'ont pas le
  même sens pour le pupitre et pour la console. À trancher dans `M645.pd` avant de figer `Shared`.
- **`VOLANT_DATA` a deux formes** selon qui l'émet (`noteFloat` ou `note` + `pitchbend`).
- **Joystick (trame `0x02`)** : le commentaire dit « 128–255 = −0 à −127 », le code calcule
  `octet − 255` (128 → −127, 255 → 0). Concerne le joystick, en refonte.
- **Deux discriminants**, `type` et `device` (§ 2).
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
1. ~~les champs de chaque message JSON et de chaque trame~~ (fait, § 2 et § 3) ;
2. ~~la forme des `config.js`, de `CONFIG_FULL` et des presets~~ (fait, § 6 bis) ;
3. lever les ⚠ et trancher les désaccords du flux PureData (un `print` dans `M645.pd` ou une
   capture WebSocket tranche) ;
4. le projet `Shared` lui-même, avec des tests octet par octet contre des captures réelles.

**Décisions (octobre 2026).** Interfaces web en **Fable + Feliz** (React) + Elmish. **SirenePupitre
garde QML** : ses jeux demandent la souplesse graphique de QML. L'architecture est donc mixte :
serveurs en F# partout, clients Fable/Feliz là où ça simplifie, QML pour le pupitre. Le contrat est
la frontière entre les deux : `Shared` produira des exemples de messages et des tests pour que le
QML du pupitre et le F# restent d'accord.

**App pilote pour Fable : SirenConsole** — l'interface la plus simple (listes, formulaires,
réglages, pas de dessin temps réel), et le plus gros serveur Node à porter : le pilote valide les
deux moitiés de la chaîne. Elle utilise surtout les messages « Console ↔ serveur » et « Lecture
MIDI » du § 2, les routes `/api/presets` du § 4, et le flux PureData côté console du § 3.

## 6 bis. Configuration et presets (étape 3)

### Trois sources de configuration

| Fichier | Suivi par git | Lu par | Contenu |
|---|---|---|---|
| `config.json` (racine) | **non** (`.gitignore`, ligne 92), aucun modèle versionné | `config-loader.js` → `SirenConsole/webfiles/server.js`, `api-midi.js` (lève une erreur s'il manque) | la configuration d'un **pupitre** (voir ci-dessous), plus `servers` et `paths.midiRepository` |
| `SirenConsole/config.js` et `SirenConsole/webfiles/config.js` | oui, **deux copies qui divergent** (P2 : `localhost` contre `192.168.1.42`) | QML (`ConfigManager` : `webfiles/config.js` en HTTP, puis `config.js`, aussi embarqué dans `data.qrc`), `puredata-proxy.js` | `pupitres[]`, `ui`, `presets` (anciens, en objet), `colors`, `servers.websocket`, `sirenAssignment` |
| `SirenePupitre/config.js` | oui | QML du pupitre (`var configData = …`, pas un module Node) | `serverUrl`, `admin`, `controllersPanel`, `ui`, `midiFiles`, `sirenConfig`, `calibration`, `displayConfig`, `outputConfig`, `composeSiren` |

### La configuration d'un pupitre (`CONFIG_FULL.config`)

Même forme dans `config.json` et dans `SirenePupitre/config.js`, aux clés propres à chacun près :

- `sirenConfig` : `mode`, `currentSirens[]`, `cb4techID`, `sirens[7]` avec `id`, `name`, `midiChannel`,
  `ambitus {min, max}`, `restrictedMax`, `transposition`, `displayOctaveOffset`, `clef`, `outputs`,
  `frettedMode {enabled}` ;
- `displayConfig` : `camera` (reste de la 3D), `components.*` (`musicalStaff`, `rpm`, `sirenCircle`…,
  chacun avec `visible`), `rpm.ledSettings`, `controllers.*` (🔧 en partie) ;
- `composeSiren` : `enabled`, `controllers.<nom> {cc, value, range | values, description}` ;
- `reverbConfig`, `outputConfig {sirenMode}`, `calibration.joystick` 🔧, `version`.

Les chemins de `PARAM_UPDATE.path` (§ 2) sont des chemins dans cet objet
(`["sirenConfig","sirens",2,"frettedMode","enabled"]`).

### Presets de la console (`SirenConsole/webfiles/presets.json`)

Stockés dans `webfiles/presets.json` (suivi par git, écrit par le serveur via un fichier `.tmp`
puis renommé ; un `presets.json.corrupted-…` est aussi suivi). Racine : `{ presets: [...] }`.

Un preset : `id`, `name`, `description`, `created`, `modified`, `version`, et **deux formats qui
coexistent** :
- ancien : `pupitres[]` à la racine du preset ;
- actuel (écrit par `server.js`) : `config.pupitres[]`, avec en plus `sirenes`.

Sur les deux presets stockés, l'un n'a que l'ancien format, l'autre les deux. Entrée de pupitre :
`id`, `assignedSirenes[]`, `vstEnabled`, `udpEnabled`, `rtpMidiEnabled`,
`controllerMapping.<contrôle> {cc, curve}` (`curve` : `linear`, `parabolic`, `hyperbolic`,
`s curve`) 🔧 pour les contrôles joystick.

Les anciens presets de `config.js` (« Concert Standard », « Mode Fretté »…) ont une troisième forme
(`pupitreConfig`, `uiConfig`) ; aucun code ne semble plus les lire (à vérifier).

### Pour `Shared.Config`

- un type `PupitreConfig` (la forme ci-dessus), partagé par `CONFIG_FULL`, `config.json` et le
  pupitre ;
- un type `Preset` à **un seul** format, avec une lecture tolérante des deux anciens pour migrer
  `presets.json` une fois ;
- `config.json` versionné en modèle (`config.example.json`), la partie machine (adresses, chemins)
  séparée de la partie musicale ;
- une seule copie de la configuration de la console, servie par le serveur F# (fin des deux
  `config.js`).

## 7. Mesure de référence : SirenConsole avant Fable

Pour que la comparaison avec la version F# / Fable démontre quelque chose, elle se fait **à
fonctionnalités égales**, avec **la même règle de comptage**, et **sans le code généré** (ni celui
d'Emscripten aujourd'hui, ni le JavaScript produit par Fable demain).

Règle : lignes de code des fichiers suivis par git, sans les lignes vides ni les commentaires
(`//`, `/* … */`, et `(* … *)` en F#). Relevé sur `main` (`f62aaa4`), `SirenConsole/` et
`config-loader.js`.

| Partie | Fichiers | Lignes de code |
|---|---:|---:|
| Interface : QML | 36 | 7 630 |
| Interface : JS de QML (`WebSocketHelper.js`) | 1 | 32 |
| Interface : C++ (`main.cpp`) | 1 | 22 |
| Serveur : Node (`server.js`, `puredata-proxy.js`, `midi-sequencer.js`, `api-*.js`, `midi-analyzer.js`) | 7 | 3 050 |
| Config partagée (`config.js`, `config-loader.js`) | 2 | 192 |
| **Total écrit à la main** | **47** | **10 926** |
| *Serveur : F# (hôte statique actuel, inclus dans la version cible)* | *1* | *15* |
| *Tests (`test-*.js`)* | *4* | *155* |
| *Généré (`appSirenConsole.js`, `qtloader.js`)* | *2* | *11 824* |

Quatre langages écrits à la main aujourd'hui (QML, JavaScript, C++, et F# pour l'hôte) ; la cible
n'en a qu'un. La version Fable sera mesurée avec la même règle, en séparant de même interface,
serveur et `Shared` (le code de `Shared` compte une fois, bien qu'utilisé des deux côtés).
