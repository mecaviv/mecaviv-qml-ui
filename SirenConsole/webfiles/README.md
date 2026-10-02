# F# server of SirenConsole

Replaces `server.js` on port 8001. Same host shape as `SirenManager/backend/fsharpwebserver`: Giraffe on Kestrel, logging and host in `Infrastructure/`. It speaks the Node contract described in `NODE_CODEBASE.md`, so the QML UI does not change. The types of what travels (console messages, PureData frames, presets, the MIDI score) are in `Shared/`, with their tests in `Shared.Tests/`.

```bash
dotnet run --project SirenConsole/webfiles                      # https://0.0.0.0:8001, needs ssl/*.pem
USE_HTTPS=false dotnet run --project SirenConsole/webfiles      # http
dotnet run --project Shared.Tests                               # tests
```

| Variable | Default | Use |
|---|---|---|
| `SIRENCONSOLE_PORT` | 8001 | port |
| `USE_HTTPS`, `SSL_CERT_PATH`, `SSL_KEY_PATH` | on, `ssl/cert.pem`, `ssl/key.pem` | as `server.js` |
| `SIRENCONSOLE_PRESETS` | `presets.json` | presets file (tests) |
| `MECAVIV_COMPOSITIONS_PATH` | `config.json` `paths.midiRepository` | compositions repository |
| `SIRENCONSOLE_PREROLL_MS` | 5000 | the sound's delay behind Pd's position frames (M645.pd's `[pipelist 5000]`) |

To try it without a park, run simulated pupitres (`puredata-abstractions/simulation/`, M645.pd on the Mac) and point `config.js` at them.

| File | What |
|---|---|
| `Presets.fs` | `/api/presets…`, the store (atomic writes), the five PATCH routes |
| `ConsoleConfig.fs` | reads `../config.js`, `/api/config` |
| `UiSocket.fs` | `/ws`: PING, identification, status every second, broadcasts |
| `PupitreLinks.fs` | one WebSocket client per pupitre, frames decoded by code and length |
| `Midi.fs` | compositions, commands relayed to Pd, playback position on the sound's time, the score |
| `Api.fs` | every route, composed |
| `Program.fs` | configuration, wiring |

## What is implemented

Every route and WebSocket message of `server.js` that something uses. Each step was compared with `server.js` running beside it, against the real pupitre P2 or simulated ones: same responses, except where Node is wrong.

## Where it differs from Node, on purpose

- **The PATCH preset routes save.** In Node they write a copy they did not modify.
- **Position frames are no longer taken for configuration chunks**, so `/api/puredata/events` is filled and the wheel's data has one shape.
- **`download` answers at once.** Node waited 5 s on a list it never emptied; the pupitres' answers still come back through their links.
- **No MIDI clock of its own.** `/api/puredata/playback` follows the first connected pupitre's position frames, extrapolated between them, minus the preroll: the position is the sound's, negative while the preroll counts in. Commands are relayed as the UI sent them, without the position Node's clock added; one that reaches no pupitre is reported as such.
- **`GET /api/midi/score`** (new): the loaded piece as a score, every note in ms, so a display can scroll it ahead of the sound with a single clock. `Shared/MidiScore.fs` was checked against the notes M645.pd's `[midifile]` played (2 ms over 10 s).
- **`MIDI_FILE_LOAD` paths stay inside the compositions repository.**
- No `/tmp/ui-controls.log`.

## What is outside

- `PUPITRE_IDENTIFICATION` and the relay of Pd's `GAME_MODE` to the UI: nothing sends the first, nothing handles the second (`NODE_CODEBASE.md`).
- The `0x06` tick frames `midi-sequencer.js` broadcast to the pupitres and UI clients from its own clock.

## Starting it

`franz run console-server` builds and starts it (and stops a running one); `franz stop console-server`, `franz logs console-server -f`. The WebAssembly page: `franz build qml-ui -p wasm -t console`. `server.js` and its modules stay beside it for comparison until they are removed.
