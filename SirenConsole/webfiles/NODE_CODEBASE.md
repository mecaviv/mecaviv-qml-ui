# SirenConsole Node process

Description of the Node server beside the SirenConsole Qt/QML app (`server.js` and its modules), written so the F# port in this directory keeps the same contract. Where the Node code and what actually travels on the wire disagree, this document says what was **measured** — on a real M645.pd (pupitre P2) or on simulated pupitres running M645.pd on a Mac (`puredata-abstractions/simulation/`).

| File | Lines | Role |
|---|---|---|
| `server.js` | 1650 | HTTP routes, the UI's WebSocket, sync state, presets glue |
| `puredata-proxy.js` | 1190 | One WebSocket client per pupitre, to its PureData |
| `api-presets.js` | 329 | `presets.json`: read, normalise, write |
| `midi-sequencer.js` | 518 | A playback clock of its own (see below: not ported) |
| `midi-analyzer.js` | 138 | Duration and tempo of a file; its result is computed and never used |
| `api-midi.js` | 143 | The compositions repository: files and categories |

One port, 8001, HTTPS by default (`USE_HTTPS=false` for HTTP), certificates `ssl/cert.pem` and `ssl/key.pem` (`SSL_CERT_PATH`, `SSL_KEY_PATH`). Without them the process exits with the `openssl` command to create them. The same port carries the static WebAssembly build (`appSirenConsole.html`), the JSON API and the WebSocket `/ws`.

## Config the process reads

- `../config.js` — a JavaScript object (`const config = {...}`), not JSON: unquoted keys, comments. Its `pupitres` list (`id`, `name`, `host`, `port`, `websocketPort`, `enabled`) is the park the console connects to. Served as-is under `/config.js` (the QML UI loads it) and as JSON under `/api/config`.
- `../../config.json` through `config-loader.js` — only `paths.midiRepository`, relative to `mecaviv-qml-ui/` (`../mecaviv/compositions` in `config.template.json`). `MECAVIV_COMPOSITIONS_PATH` overrides it.
- `presets.json` beside `server.js`.

## The pupitres: one WebSocket client each

`puredata-proxy.js` connects to `ws://<host>:<websocketPort>` for every enabled pupitre (M645.pd's `[websocket-server 10002]`), reconnects after a second, and on connection sends `REQUEST_CONFIG` 100 ms later.

Measured on M645.pd, and what a port must do:

- **JSON goes to PureData in binary frames.** A text frame is split at its commas by the Pd side.
- **`CONFIG_FULL` comes back in chunks**, about 3 s after `REQUEST_CONFIG`: each chunk is `totalSize u32 LE, position u32 LE`, then the bytes. There is no start marker.
- **A frame is identified by its first byte and its length**, never by the first byte alone:

| Bytes | Length | Meaning |
|---|---|---|
| `00 00` | 2 | heartbeat |
| `53 53 01` note velocity pitchbend(u16 **BE**) | 7 | wheel (volant) state |
| `01` flags bar(u16) beatInBar(u16) beat(f32) | 10 | playback position, one per beat |
| `02` duration(u32) totalBeats(u32) | 10 | file info |
| `03` tempo(u16) | 3 | tempo |
| `04` num den | 3 | time signature |
| `04` note velocity duration(u16) | 5 | game-mode note (for SirenePupitre, not the console) |
| `05` cc value | 3 | game-mode CC (for SirenePupitre) |
| `06` flags tick(u32) [ppq(u16)] | 6 / 8 | tick position |
| `{...}` | any | JSON |
| 8-byte chunk header + data | ≥ 8 | configuration chunk |

  `puredata-proxy.js` tries the chunk header before the fixed frames, and so takes most 10-byte position frames for configuration chunks (measured: bars 5, 1, 0 are swallowed, bar 120 gets through).
- **Node's `ws` 8 delivers text messages as `Buffer`**: the proxy's JSON branch never runs, so `/api/puredata/events` is always empty.
- **Pd relays `PARAM_UPDATE` to all its clients but does not apply it**; the SirenePupitre UI applies it. Pd does not relay `PARAM_CHANGED`.
- `lastSeen` is an ISO string.
- The wheel's frequency uses ±1 semitone of pitch bend and S3's settings (an octave up, 8 outputs) for every pupitre.

### Playback, measured

M645.pd plays the MIDI file itself (`[midifile]`, `MIDI_FILE_LOAD` with a path relative to the compositions repository). What it sends while playing:

- one position frame (`01`, 10 bytes) per **whole** beat; bar and beat in bar are **0-based**;
- **no** tempo, signature or file-info frame (`02`/`03`/`04` 3-byte are never sent);
- the sound leaves through `[mrpeach/pipelist 5000]`: **5000 ms (±1) after** `[midifile]`, its game-mode notes and its position frames;
- on pause the delayed output stops at once and resumes from the file's position: the 5 s that were in the delay line are not played;
- **stop keeps the position**, as pause does: the next play goes on from there;
- the frame sent on pause or stop repeats the last whole beat, not the position reached;
- `MIDI_SEEK` is not handled.

`midi-sequencer.js` runs a second clock beside Pd's. It drifts (ticks floored every 50 ms: about 2 % at 97 BPM), counts a quarter note per beat whatever the signature's denominator, and converts a seek with the current tempo only. The F# port has no clock of its own and follows the pupitres' frames.

## WebSocket `/ws` (the console's UI)

Text frames, one JSON object each; binary frames are read as JSON too.

- `{type:"PING"}` → `{type:"PONG", source, timestamp}`.
- `SIRENCONSOLE_IDENTIFICATION` → the client joins the broadcasts and receives `INITIAL_STATUS` (`{totalConnections, connectedCount, connections:[...]}`).
- Every second, `PUPITRE_STATUS_UPDATE` with each connection's `isSynced` / `lastSync`.
- Broadcasts: `SYNC_STATUS_CHANGED`, `PUPITRE_CONNECTED`, `PUPITRE_DISCONNECTED`, `VOLANT_DATA`, `PRESET_UPDATED_FROM_PUPITRE`.
- `PUPITRE_IDENTIFICATION` (a pupitre connecting to the console, `handleIncomingConnection`): **nothing sends it** — no repository of the project (qml-ui, puredata-abstractions, firmwares-artila, mecaviv-rs) has a sender.
- `GAME_MODE` from Pd is broadcast to the UI clients: the SirenConsole UI does not handle it.

## HTTP contract

JSON unless noted. CORS open.

| Route | What |
|---|---|
| `GET /config.js`, `GET /api/config` | the console's configuration |
| `GET/POST/PUT/DELETE /api/presets[/:id]`, `GET/PUT /api/presets/current` | presets |
| `PATCH /api/presets/current/{sirene-config,outputs,controller-mapping,game-mode,assigned-sirenes}` | one part of the current preset for one pupitre, then `PARAM_UPDATE` to it if synced. **In Node these save nothing**: they modify one copy of the file and write another. |
| `POST /api/presets/current/upload` | the current preset to every connected pupitre (`CONSOLE_CONNECT`, then its `PARAM_UPDATE`s) |
| `POST /api/presets/current/download` | `REQUEST_CONFIG` to every connected pupitre; Node then waits 5 s on a list it never empties |
| `GET /api/pupitres/status`, `/api/pupitres/:id/status`, `/api/pupitres/:id/sync-status`, `GET /api/puredata/status` | the links' state |
| `GET /api/puredata/events?since=` | JSON received from the pupitres (always empty in Node, see above) |
| `GET /api/volant-data` | the last wheel state |
| `GET /api/puredata/playback` | `{playing, bar, beatInBar, beat, position, tempo, duration, totalBeats, timeSignature, file}` |
| `POST /api/puredata/command` | `MIDI_FILE_LOAD`, `MIDI_TRANSPORT` (play/pause/stop), `MIDI_SEEK`, `TEMPO_CHANGE`, `GAME_MODE`, `UI_CONTROLS` (→ `PARAM_UPDATE uiControls.enabled`), `AUTONOMY_MODE`; anything else is relayed to Pd. Node writes `UI_CONTROLS` debug lines to `/tmp/ui-controls.log`. |
| `GET /api/midi/files`, `GET /api/midi/categories` | the `.mid`/`.midi` files of the compositions repository, with `microtonal` when conductor cues exist beside them |
| `POST /api/test/pupitre-connected` | test aid: announces a pupitre to the UI |

## Files

| File | What to port |
|---|---|
| `server.js` | routes, `/ws`, sync state, the handlers of what the pupitres send |
| `puredata-proxy.js` | the links, frame decoding (by code and length), chunk reassembly |
| `api-presets.js` | normalisation and the five PATCH routes (with the save they lack) |
| `api-midi.js` | the file scan |
| `midi-sequencer.js`, `midi-analyzer.js` | not ported: Pd keeps time; the score is read by `Shared/MidiScore.fs` |
