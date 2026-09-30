# F# sketch of the SirenManager backend

Same host shape as `reaper-extensibility/server`: Giraffe on Kestrel, `UseGiraffe`, `AddGiraffe`. Logging and the Kestrel host live in `Infrastructure/` (`Mecaviv.Infrastructure`). It speaks the Node JSON contract in `../NODE_CODEBASE.md`, so `SshController` and the WebAssembly `UdpController` do not change.

```bash
dotnet watch --non-interactive --project SirenManager/backend/fsharpwebserver
dotnet run --project SirenManager/backend/fsharpwebserver
```

It reads `../config.json` (or a `config.json` beside the executable) and listens on `ports.http` (8005) and `ports.websocket` (8006). `logLevel` selects the Serilog console level (`Verbose`, `Debug`, `Information`, `Warning`, `Error`, `Fatal`). It defaults to `Debug`.

## What carries over from the Reaper server

The Reaper process (`reaper-extensibility/server/Program.fs`) is a long-running Kestrel exe. Routes are Giraffe handlers. That is the part worth copying: one console process, started and killed by whoever hosts it.

`V1Access.fs` already knows Linux Maître. It is not the model for this port.

| Reaper server | This sketch |
|---|---|
| Fable.Remoting, because the UI is Fable (`/api/IPlaylistManagementApi/...`) | Giraffe `route`s. The client is C++ posting the Node paths (`/api/ssh/execute`, …). Remoting would be a second API the QML app does not call. |
| `SSH.NET` as `root`/`root` to `192.168.1.101`, playlist path `/home/guest/WorkSpaceSirenes` | `ssh` on PATH, target = `sshAlias` from `config.json`, options `BatchMode`, `ConnectTimeout=5`, `StrictHostKeyChecking=accept-new`, `ForwardX11=no`. User, key, and legacy KEX stay in `~/.ssh/config`. SSH.NET does not read that file, and the Artila boards need those algorithms. |
| One UDP socket per command, send 8001, bind 28003, opcodes inside `V1SendCommandIds` | Opaque hex relay. Desktop Qt already binds UDP 8000 and builds the 10-byte frame. This process binds 8000 only while a WebSocket client is connected, then releases it. |
| Paket (`SSH.NET`, `Elmish.Bridge.Giraffe`, `Fable.Remoting.Giraffe`, `UnMango.CliWrap.FSharp`) | Giraffe routes. `UnMango.CliWrap.FSharp` runs `ssh` and the local `tar`, same argv as before. No Remoting, no SSH.NET. |
| Default Kestrel port | 8005 and 8006, because those numbers are compiled into the Qt app. |

CliWrap is the Reaper server's `command { args; stdout; exec }` shape. It does not change which binary runs or which arguments it gets.

## What the sketch implements

- `POST /api/ssh/execute`, `/download`, `/upload`, `/sync-dir`
- `GET /api/playlists/backup`
- `POST /api/keys/export`
- WebSocket `udp_send` / `udp_receive` on the second port
- Raspberry `m-seq.service` restart after a MIDI or playlist upload, without failing the upload
- Source listing before any mirror delete, sequential targets, dry-run that does not tar or `rm`
- `ls -1` plus a case-insensitive glob, not `find`

`/api/keys/export` builds the same archive layout. The embedded `INSTALL.sh` is shorter than the one in `server.js`; lift that string across when this replaces Node.

## What is still outside the sketch

- The macOS 10.13 bundle starts `sirenmanager-backend` from `main.cpp` (`BUNDLED_BACKEND`). A `dotnet publish -c Release -r osx-x64 --self-contained` binary can take that slot. It is larger than the `pkg` Node 16 binary and needs the 10.13-era runtime story checked separately. This project targets `net10.0`, which is not a 10.13 runtime.
- No tests. The behaviours that have already bitten the Node version are the ones to pin: BusyBox `ls` instead of `find`, dry-run must not delete, UDP 8000 stays closed with zero WebSocket clients, download is UTF-8, upload may be base64.
- `webfiles/server.js` is a separate static server. Its project is `SirenManager/webfiles`. Port 8006 stays with this SSH process.
