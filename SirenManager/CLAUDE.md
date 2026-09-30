# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project context

SirenManager is one of several Qt6/QML applications inside the `mecaviv-qml-ui` monorepo (parent at `..`). It is a port of the legacy macOS app `SireneControlMac` into QML/WebAssembly and acts as the central "control panel" app, distinct from the per-pupitre visualizer (`SirenePupitre`), the central console (`SirenConsole`), the 3D pedalier (`pedalierSirenium`), and the Node.js monitoring service (`sirenRouter`). When the user references behavior in those siblings (e.g. WebSocket message shapes, UDP framing, machine IDs), check `../docs/COMMUNICATION.md` and the sibling project before assuming this project is authoritative.

The project is partially implemented. `IMPLEMENTATION_PLAN.md`, `COMPLETION_STATUS.txt`, and `STATUS_FINAL.txt` flag many views as stubs — treat the QML under `QML/views/` as scaffolding, not finished UI, and verify before assuming a view is wired.

### Legacy reference: SireneControlMac (Obj-C macOS app)

The original app being ported lives at **`/Users/patricecolet/repo/mecaviv/SireneControlMac/`**. It is the authoritative source for anything ambiguous in the QML port — view layouts, UDP opcode payload semantics, MIDI sequencer behavior, playlist edge cases. Mapping:

- View controllers map 1:1 with `QML/views/`: `FirstViewController.m` → PlayerView, `SecondViewController.m` → MixerView, `MaintenanceViewController.m` → MaintenanceView, `ControleurViewController.m` → ControleurView, `PianoViewController.mm` → PianoView, `ViewControllerSirenium.m` → SireniumView, `viewVoiture.m`/`voitureViewControleur.m` → VoitureView, `ViewPavillon.m`/`pavillonViewControleur.m` → PavillonView, `SystemMaintenanceViewController.m` → SystemMaintenanceView, `PlaylistComposerViewController.m` → PlaylistComposerView.
- `Base.lproj/Main.storyboard` + `MainStoryboard.storyboard` — pixel-level layouts (positions, sizes, colors of sliders/buttons to reproduce in QML).
- `Utilitaires/SendUdp.{h,m}` — actual payload format per opcode `0x01–0x40` (the constants in `src/Config/SirenConfig.h::UdpCommands` are names only, not semantics).
- `Utilitaires/MIDIParser.{h,m}` — sequencer parsing.
- `Utilitaires/SSHManager.{h,m}` + `FTPManager.{h,m}` — note the legacy app uses `cat` over SSH for upload (BusyBox compat); `backend/ssh-proxy.js` should match that approach for any new endpoints.
- Custom UI widgets `mButton`/`mSlider`/`mSwitch`/`mLabel`/`mSegment`/`mTable` (in `Utilitaires/`) — reference for visual style when porting.

## Build

The monorepo's top-level `CMakeLists.txt` includes SirenManager via `add_subdirectory(SirenManager)` and exposes `-DBUILD_SIRENMANAGER=ON/OFF`. Two ways to build:

```bash
# From monorepo root (preferred — uses presets, builds all enabled projects)
cmake --preset=default     # desktop debug
cmake --preset=wasm        # WebAssembly
cmake --build build --target appSirenManager --parallel

# Standalone WebAssembly build (script hardcodes Qt 6.10.0 wasm_singlethread)
./scripts/build.sh
```

`scripts/build.sh` post-processes `webfiles/appSirenManager.html` to reorder `<script>` tags so `appSirenManager.js` loads after `qtloader.js`. If you regenerate the HTML, re-run the script or the page won't boot.

The CMake file disables `Qt6Quick3D`, `Qt6Graphs`, and `Qt6VirtualKeyboard` — this app is intentionally 2D-only (unlike `SirenePupitre`/`pedalierSirenium`). Don't add Quick3D imports here; they will fail under WASM.

## Backend (F# SSH + UDP proxy)

The C++/QML app cannot speak SSH or raw UDP from the browser, so `backend/fsharpwebserver` provides the contract in `backend/NODE_CODEBASE.md` (`backend/server.js` is the Node original):

- **HTTP REST on 8005** — `/api/ssh/{execute,download,upload}` for system maintenance (reads `backend/config.json` for per-machine IPs and SSH key paths).
- **WebSocket on 8006** — bidirectional UDP proxy. Browser sends `{type:"udp_send", address, port, data:<hex>}`; server forwards on UDP socket and broadcasts received UDP packets back as `{type:"udp_receive", ...}`.
- **UDP on 4443** — local socket bound by the proxy.

```bash
# from mecaviv-qml-ui
dotnet watch --non-interactive --project SirenManager/backend/fsharpwebserver
dotnet run --project SirenManager/backend/fsharpwebserver
```

SSH delegates entirely to the user's `~/.ssh/config` via the system `ssh` binary (CliWrap in `SshProxy.fs`, same argv as `ssh-proxy.js`). The backend does NOT load private keys itself. This keeps key/port/user/algorithm decisions in one place: the user's existing SSH config. Each machine entry in `backend/config.json` may set an optional `sshAlias` to target a `Host <alias>` block; otherwise the backend falls back to `<sshUser>@<ip>`. The `sshKeyPath` field in older configs is now ignored.

Uploads pipe content through `ssh host 'cat > remotePath'` rather than scp, because the busybox-based sirens often lack scp (matches the legacy SireneControlMac approach).

## Architecture

### Dual transport in `UdpController`

`src/UdpController.{h,cpp}` is the heart of the app. At compile time it picks one of two paths via `#ifdef EMSCRIPTEN`:

- **Desktop**: `QUdpSocket` directly. Local bind = port **8000** (receive). Send port depends on target: **8001** for Linux Maître, **1234** for individual sirens S1–S7. Source: legacy `AppDelegate.m:116-123`.
- **WebAssembly**: `QWebSocket` to `ws://localhost:8006/udp-proxy`, with packets serialized as JSON `{type:"udp_send", address, port, data:<hex>}` — the backend forwards them as real UDP (the backend itself binds UDP **8000** locally to receive replies). This is why the backend service is mandatory in WASM mode.

If you add a UDP command, add it in both `UdpController` (Q_INVOKABLE) and as a constant in `src/Config/SirenConfig.h::UdpCommands` — QML calls the invokables, and command codes (0x01–0x40) must stay in sync with what the sirens' firmware expects.

### Wire format

`buildPacket()` produces a fixed 10-byte frame matching the legacy `SireneControlMac/Utilitaires/SendUdp.m` `senddata:` method: **`[cmd, length=10, BCC, payload×7]`** — `cmd` is at byte 0, length at byte 1, BCC at byte 2. The caller passes input as `[cmd, 0x04, 0x00, payload...]` (the 0x04/0x00 are markers that get clobbered by length and BCC). **BCC = XOR of output bytes 4–9** (byte 3 is excluded — this is a legacy quirk from the original loop where the first XOR iteration cancels itself; the firmware on the sirens validates against this same algorithm, so don't "fix" it). Don't change the framing without coordinating with the firmware.

Receive side: the Linux Maître replies with text-prefixed messages (`'SL'`, `'TI'`, `'RU'`, `'RB'`, `'PS'`) and binary opcodes (e.g. `0x34` for slot length). `UdpController::parseIncomingData` recognizes these and emits typed signals (`sequenceInfoReceived`, `timingUpdated`, `runningStateChanged`, `loopStateChanged`, `playlistSlotReceived`, `slotLengthReceived`) that QML views connect to. If you add a new message type, parse it there.

### Machine model

Targets are an enum (`MachineType` in `src/Config/MachineType.h`) covering `LinuxMaitre`, `RaspberryClic`, `S1–S7`, `VoitureA/B`, `Pavillon1/2`. Three places must agree for a new machine: the C++ enum, `SirenConfig` (IPs/paths/credentials), and `backend/config.json` (`machines.*`). Adding an entry to only one of those is a common source of silent failures.

### QML structure

- `QML/Main.qml` — `ApplicationWindow` with a `TabBar` of 10 tabs driving a `StackLayout` of `Loader`s pointing at `QML/views/*.qml`.
- `QML/views/` — one file per tab (PLAYER / MIXAGE / SIRENIUM / MAINTENANCE / CONTROLEURS / PIANO / VOITURES / PAVILLONS / SYSTÈME / PLAYLISTS). Most are stubs; check before claiming a view "works".
- `QML/components/` — reusable widgets (SirenButton, PlaylistSlot, ClockDisplay, MidiController, MachineSelector).
- `QML/controllers/` — pure-QML controller singletons that wrap the C++ `UdpController`/`PlaylistManager` etc.

`main.cpp` registers C++ types under the QML import name `SirenManager` (e.g. `import SirenManager` then `UdpController { ... }`). The QRC prefix is `/SirenManager` and the entry point is `qrc:/SirenManager/QML/Main.qml`. **Adding a new QML file requires editing `data.qrc`** — it is not auto-discovered.

### Playlist format

`PlaylistManager` parses entries shaped `{[n=X][s=filename][a=pseudo][B=0/1][E=0/1]}` (slot, file, pseudo, boucle, enchaînement). 48 slots total. The format is shared with the legacy `SireneControlMac` playlist files retrieved via SSH from `linuxMaitre`/`raspberryClic`.

## Conventions worth knowing

- Existing code, comments, and commit messages are in **French**. Match that when adding adjacent code; user-facing strings in QML are French.
- The `webfiles/` directory contains build artifacts (`appSirenManager.{js,wasm,html}` etc.). Don't hand-edit them — they're regenerated by `scripts/build.sh`.
- The repo's working tree often shows modifications under `../SirenePupitre/` and `../docs/` because work spans the monorepo. Confirm scope with the user before committing across project boundaries.
