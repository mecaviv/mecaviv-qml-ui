# SirenManager Node process

Description of the Node code that sits beside the Qt/QML app, written so a port to F# or Rust can keep the same contract. The siren protocol itself is not in this process.

There are two Node programs. Only the first is the service to port.

| Program | Role | Port |
|---|---|---|
| `backend/server.js` + `backend/ssh-proxy.js` | SSH proxy, playlist/MIDI sync, UDP relay for the browser build | HTTP 8005, WebSocket 8006, UDP 8000 (lazy) |
| `webfiles/server.js` | Dev static file server for the WebAssembly build. Its WebSocket only answers `{type:"ping"}`. It does not relay UDP and it does not speak SSH. | HTTP 8081, and it also binds WebSocket 8006 |

`webfiles/server.js` and `backend/server.js` cannot run together: both claim port 8006. The QML client’s real UDP relay is the backend. The static server is a local page host and is not part of the fleet protocol.

## Why this process exists

The QML app does two kinds of I/O.

On the desktop build, UDP is done in C++ (`src/UdpController.cpp`). The process binds port 8000 itself and sends datagrams straight to the machines. It does not use the Node UDP relay.

SSH is always done by this process, including on the desktop. `SshController` (`src/SshController.cpp`) POSTs JSON to `http://localhost:8005`. QML never opens an SSH connection.

On the WebAssembly build, the browser cannot bind UDP and cannot run `ssh`. `UdpController` opens `ws://localhost:8006/udp-proxy` and the backend forwards hex-encoded datagrams. The path `/udp-proxy` is not checked; any path on port 8006 is accepted.

The macOS 10.13 bundle (`packaging/macos1013/`) compiles the Qt app with `BUNDLED_BACKEND`. `main.cpp` then starts `sirenmanager-backend` from the app bundle and kills it on quit. That binary is produced with `pkg` (`node16-macos-x64`). When `process.pkg` is set, `config.json` is read from the directory of the executable so the fleet table stays editable inside the bundle. In a normal `node server.js` run, it loads `backend/config.json` from source.

## What the code actually is

About 540 lines in `server.js` and 220 in `ssh-proxy.js`. No siren opcode table, no playlist parser, no MIDI parser. Those live in the C++/QML app (`UdpController::buildPacket`, `PlaylistComposerView.qml`, `PlaylistManager`).

The Node work is:

1. A JSON HTTP API in front of the system `ssh` binary.
2. A WebSocket that turns hex strings into UDP datagrams and back.
3. Two local-disk helpers: export `~/.ssh` into a tarball, and stream a gzip of a remote directory.

`package.json` lists `ssh2` and the npm package `dgram`. Neither is used. SSH is `child_process.spawn('ssh', ...)`. UDP is Node’s built-in `dgram`. The packages that are used are `express`, `cors`, and `ws`. `zlib` (gzip of the playlist backup) and `tar` (the key archive) are the system ones, not libraries.

There is no authentication, no TLS, and no request logging beyond `console.log`. `app.listen(8005)` and the WebSocket server bind all interfaces. CORS is open.

## Config the process reads

`backend/config.json`.

Ports, with the defaults the code uses if a key is missing:

| Key | Default | Use |
|---|---|---|
| `ports.http` | 8005 | HTTP API |
| `ports.websocket` | 8006 | UDP relay |
| `ports.udp` | 8000 | Local bind for firmware replies, only while a WebSocket client is connected |
| `ports.bail` | 8004 | Present in the file. This process does not bind it. |

Each SSH-capable machine is an object under `machines`. The fields this process reads are `sshAlias`, `sshUser`, `ip`, and, for the Raspberry only, `midiPath` and `playlistPath`.

`ssh-proxy.js` does not accept every key in `config.json`. `getMachineConfig` only resolves:

`linuxMaitre`, `raspberryClic`, `s1`–`s7`, `voitureA`, `voitureB`, `pavillon1`, `pavillon2`.

Anything else (`trompe`, pupitres, `miniPC`, …) throws `Unknown machine type`, even if the JSON has an entry. The C++ side sends the same string names (`SshController::machineTypeToString`).

The SSH target is `sshAlias` when that string is non-empty (`linux-maître`, `raspberry-clic`, `sirene-s1`, …). Otherwise it is `sshUser@ip`. User, port, identity file, and the legacy key-exchange algorithms the Artila boards need are not set on the command line. They come from the operator’s `~/.ssh/config` Host block for that alias. Every invocation also passes:

```
-o BatchMode=yes
-o ConnectTimeout=5
-o StrictHostKeyChecking=accept-new
-o ForwardX11=no
```

`BatchMode` makes a missing key fail instead of prompting. `ConnectTimeout` is 5 seconds. A port must keep both.

## HTTP contract

JSON bodies, except the playlist backup, which is raw gzip. Errors are HTTP 500 (or 400 / 404 where noted) with `{ "success": false, "error": "<message>" }`. The C++ client reads that body even on non-2xx; a port that only returns a status line will surface as a generic network error in the UI.

The body parser limit is 50 MB. MIDI uploads arrive as base64 inside JSON, so the raw file is smaller than the request.

### `POST /api/ssh/execute`

```json
{ "machineType": "linuxMaitre", "command": "ls -1 '/mnt/disk/.../liste_de_lecture/'" }
```

```json
{ "success": true, "output": "<stdout>" }
```

`command` is a remote shell string. The server does not quote it. Callers quote paths themselves. Non-zero ssh status rejects with stderr (or stdout if stderr is empty).

### `POST /api/ssh/download`

```json
{ "machineType": "linuxMaitre", "remotePath": "/mnt/disk/.../derniere_liste" }
```

```json
{ "success": true, "content": "<file text>" }
```

Implementation is `ssh host cat '<path>'`. The bytes are decoded as UTF-8. Playlist files and `derniere_liste` are text. This route is the wrong shape for binary MIDI.

### `POST /api/ssh/upload`

```json
{ "machineType": "linuxMaitre", "remotePath": "/remote/file", "content": "<utf8>" }
```

or, for a local file the C++ side already read (`uploadLocalFile`):

```json
{ "machineType": "s1", "remotePath": "/remote/file.mid", "contentBase64": "<base64>" }
```

`contentBase64` wins when both are present. The response is `{ "success": true }` plus the optional prioq fields below.

Implementation pipes the buffer into `ssh host 'cat > '\''path'\'''`. `scp` is not used; BusyBox images often have no `scp`. An `EPIPE` on stdin is part of the error string.

### Raspberry prioq refresh

After a successful upload, and after a successful sync onto `raspberryClic`, the server may run:

```
sudo systemctl restart m-seq.service
```

`m_seq.ko` on the Pi 5 loads playlist and MIDI into a kernel queue at insert and does not re-read the disk. The restart is `rmmod`+`insmod` of that module only.

It runs only when `machineType` is `raspberryClic` and `remotePath` starts with that machine’s `midiPath` or `playlistPath`. Writing `derniere_liste` does not match those prefixes, so it does not restart the module; the firmware reloads that pointer from a UDP `NEWLIST` sent by the QML app.

Failure of the restart does not fail the upload or the sync. The file is already on disk. The JSON gains:

```json
{ "prioqRefreshed": false, "prioqRefreshError": "..." }
```

or `"prioqRefreshed": true` on success. Other machines omit the fields.

### `POST /api/ssh/sync-dir`

Used by the playlist composer to mirror `Midi/` and `liste_de_lecture/` from Linux Maître onto the other machines.

```json
{
  "sourceMachine": "linuxMaitre",
  "sourcePath": "/mnt/disk/.../Midi/",
  "targets": [{ "machineType": "s1", "remotePath": "/mnt/disk/.../Midi/" }],
  "mirror": true,
  "mirrorPattern": "*.mid",
  "dryRun": false
}
```

`mirror` and `dryRun` default to false. `mirror: true` without `mirrorPattern` is HTTP 400. `dryRun: true` without `mirror` is HTTP 400.

Order of work, and it matters:

1. If mirroring, list the source directory first. If that `ssh` fails, the handler returns 500 and no target is touched. An empty source list must not be treated as “delete everything” caused by a failed listing.
2. Unless `dryRun`, `tar c -C <source> .` on the source and hold the whole archive in memory.
3. For each target, sequentially (not in parallel):
   - If mirroring, `ls -1` the target, compute orphans (names in the target matching the glob that are not in the source list), and `rm -f` them unless `dryRun`.
   - Unless `dryRun`, pipe that same tar buffer into `tar x -C <target>`.
   - If the target is `raspberryClic` and this was not a dry run, refresh the prioq. A restart failure is recorded on that target’s result and does not mark the target failed.
4. One target failing does not stop the loop. The HTTP status is still 200 if the source tar (or the source listing) succeeded. Per-target errors are in `results`.

```json
{
  "success": true,
  "tarSize": 12345,
  "dryRun": false,
  "results": [
    {
      "machine": "s1",
      "success": true,
      "removed": 2,
      "orphans": ["old.mid", "gone.mid"],
      "dryRun": false
    }
  ]
}
```

A failed target is `{ "machine", "success": false, "error" }` and has no `removed` field.

Listing is `ls -1 <dir>/`, not `find`. BusyBox 1.00 on the Artila boards rejects `find -maxdepth` and still exits 0, which used to look like an empty directory and then delete every file on the target. The glob (`*`, `?` only) is matched in the server, case-insensitive, against the full basename. Paths sent to the remote shell are single-quoted with embedded quotes escaped as `'\''`.

### `GET /api/playlists/backup?machine=linuxMaitre`

`machine` defaults to `linuxMaitre`. Runs `tar c` of the fixed directory `/mnt/disk/home/guest/WorkSpaceSirenes` (not the per-machine `playlistPath`), gzips it in memory, and responds with `Content-Type: application/gzip` and `Content-Disposition: attachment`. The QML side opens this URL in the browser so the user gets a save dialog. Failure is JSON, not a file.

### `POST /api/keys/export`

No inputs. Reads the machine the process is running on:

- `~/.ssh/id_rsa_sirenes` and `.pub` must exist, or HTTP 404.
- `~/.ssh/config` is scanned for Host blocks whose first name is in a fixed alias list (`linux-maître`, `raspberry-clic`, `sirene-s1` … `sirene-s7`, `voiture-a`, `voiture-b`, `pavillon-1`, `pavillon-2`). A Host line that lists several names is keyed by the first token only, so `Host artila m508 192.168.1.101` is not exported as `linux-maître`.
- `IdentityFile` lines inside those blocks are rewritten to `~/.ssh/id_rsa_sirenes` so the archive is not tied to `/Users/<name>`.

The archive is written with the system `tar` to `~/Downloads/sirenmanager-keys-<timestamp>.tar.gz` (or `~` if Downloads is missing). It contains the two key files, `ssh_config_sirens`, an embedded POSIX `INSTALL.sh`, and a `README.txt`. Response:

```json
{ "success": true, "path": "/Users/.../Downloads/sirenmanager-keys-....tar.gz", "aliasesFound": 13 }
```

This is a local admin action, not a fleet operation. The private key in that archive is the SSH identity for the boards.

## WebSocket and UDP

One WebSocket server on 8006. Text frames, one JSON object per message.

Client to server, which is what `UdpController::sendPacket` sends in WASM:

```json
{ "type": "udp_send", "address": "192.168.1.101", "port": 8001, "data": "<hex of the raw datagram>" }
```

The hex is the packet bytes, not a hex dump with spaces. The server does not look inside them. Framing (10-byte buffer, length, BCC) is entirely in C++.

Server to every connected client, for each UDP datagram received on port 8000:

```json
{ "type": "udp_receive", "data": "<hex>", "address": "192.168.1.101", "port": 8001 }
```

Any other JSON, or a parse error, produces `{ "type": "error", "message": "..." }` to that client only. There is no subscribe filter: every client gets every inbound datagram.

The UDP socket is created on the first WebSocket connection and closed when the last client disconnects. That is deliberate. The firmware sends replies to a fixed set of client IPs on port 8000. A desktop SirenManager already binds that port. A second listener would split the replies. A port must keep the socket closed until a browser client is actually connected, and must release it when the last one leaves.

`udp_send` while the socket is unbound returns `{ "type": "error", "message": "UDP socket not bound" }`.

## Failure and concurrency semantics worth keeping

- SSH calls for one request run one after another. `sync-dir` does not fan out. A target’s `rm` happens before its `tar x`. The next target starts only after the previous one finishes, including the optional systemctl restart.
- Source-list failure aborts the whole sync before any target is modified. A later target failure does not roll back earlier targets.
- Remote shell is whatever `ssh` runs on that board (BusyBox sh on Artila). Commands must stay within that. `wc` is not there; `ls` is.
- Upload and download of text playlists share the `cat` channel with binary uploads. Binary must stay on the base64 path so it is not decoded as UTF-8.
- The whole source tar sits in RAM, then is written again to each target’s stdin. Playlist and MIDI trees are small today; the 50 MB HTTP limit is the other ceiling.
- No locking across HTTP requests. Two composer actions at once can interleave SSH sessions to the same board.

## What a port should not rewrite

The siren datagram layout, playlist file grammar (`{[n=…][s=…]…}`), and the decision of which UDP opcode to send are in the Qt app. Replacing Node does not require moving those.

Reimplementing SSH in process (`ssh2` on Node, SSH.NET in F#, `russh` in Rust) would drop the part that actually logs into the boards: the operator’s `~/.ssh/config`, with per-host legacy KEX, host-key algorithms, and ciphers. The current code is a thin supervisor of OpenSSH. A port should stay that way and shell out to `ssh` and `tar`.

## F# or Rust

The job is a single long-running process with a JSON HTTP API, one WebSocket, a lazily bound UDP socket, and supervised `ssh`/`tar` processes. Either language can do that without a new architecture.

F# matches the rest of the Mecaviv tooling (scripts, Fable, existing services) and the JSON contract is ordinary records. A Giraffe or Falco app on Kestrel, `System.Net.WebSockets` or a small websocket package, and `Process` for `ssh` cover it. The awkward part is the macOS 10.13 bundle: today’s artifact is one `pkg` binary with no installed runtime. A self-contained `dotnet publish` is large, and native AOT needs the JSON and `Process` code to stay in the AOT subset. Fine for a dev machine that already has a runtime; a worse drop-in for that old bundle.

Rust (`axum` or `warp`, `tokio::process`, `tokio::net::UdpSocket`) is the closer replacement for the `pkg` binary: one static executable, config file beside it, spawned by `main.cpp` the same way. The cost is more type ceremony around the JSON and the partially-present `prioqRefreshed` fields. That ceremony is useful here because several responses are easy to get wrong (UTF-8 download vs base64 upload, dry-run must not tar, UDP bind lifetime).

Either port can leave `SshController` and `UdpController` unchanged if the paths, ports, and JSON fields stay as they are.

## Files

| File | What to port |
|---|---|
| `backend/server.js` | Routes, prioq rule, sync loop, key export, backup, WebSocket, UDP lifetime |
| `backend/ssh-proxy.js` | `ssh` argv, quoting, `ls`/`tar`/`cat`, machine-name allow-list |
| `backend/config.json` | Fleet table and ports. Not code. Keep the file format. |
| `backend/package.json` | Dependency list only. `ssh2` and npm `dgram` are unused. |
| `webfiles/server.js` | Do not port as part of this service. Static files plus a ping socket on the same WebSocket port. |
| `src/SshController.cpp`, `src/UdpController.cpp` | The client of the contract. Not Node, but the spec the new process has to meet. |
