import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SirenManager
import "../controllers/MachinePaths.js" as MachinePaths

// Edit a 48-slot playlist on any machine. Loads `derniere_liste` from the
// selected target, parses the {[n=X][s=…][a=…][B=…][E=…]} format, exposes
// per-slot editing and saves back via SSH upload. Also lists available MIDI
// files on the target so you can assign one to a slot via the dropdown.
//
// "Sync vers sirènes" pushes Linux Maître's MIDI dir + liste_de_lecture/ +
// derniere_liste pointer to every checked target, regardless of the current
// load/edit target — the source for sync is always Linux Maître.
Rectangle {
    id: root
    color: "#1e1e1e"

    readonly property int linuxMaitre: 0

    // 13-machine target list (mirrors SystemMaintenanceView). The combo
    // selects which machine Load/Save acts on; sync source is always Maître.
    readonly property var allMachines: [
        { name: "Linux Maître",   id: 0  },
        { name: "Raspberry Clic", id: 1  },
        { name: "Sirène S1",      id: 2  },
        { name: "Sirène S2",      id: 3  },
        { name: "Sirène S3",      id: 4  },
        { name: "Sirène S4",      id: 5  },
        { name: "Sirène S5",      id: 6  },
        { name: "Sirène S6",      id: 7  },
        { name: "Sirène S7",      id: 8  },
        { name: "Voiture A",      id: 9  },
        { name: "Voiture B",      id: 10 },
        { name: "Pavillon 1",     id: 11 },
        { name: "Pavillon 2",     id: 12 }
    ]

    property int targetMachine: linuxMaitre
    property bool busy: false

    ListModel { id: slotsModel }

    // Tracks whether any slot has unsaved local changes. Reset to false on
    // load/save success; bumped to true whenever a slot field changes.
    property int dirtyCount: 0

    function makeEmptySlots() {
        slotsModel.clear()
        for (var i = 0; i < 48; i++) {
            slotsModel.append({ slot: i, filename: "", pseudo: "", loop: false, chain: false, dirty: false })
        }
        dirtyCount = 0
    }

    function markDirty(slotIdx) {
        if (slotsModel.get(slotIdx).dirty) return  // already dirty
        slotsModel.setProperty(slotIdx, "dirty", true)
        dirtyCount = dirtyCount + 1
    }

    function clearAllDirty() {
        for (var i = 0; i < 48; i++) {
            if (slotsModel.get(i).dirty) slotsModel.setProperty(i, "dirty", false)
        }
        dirtyCount = 0
    }

    function clearSlot(idx) {
        slotsModel.setProperty(idx, "filename", "")
        slotsModel.setProperty(idx, "pseudo",   "")
        slotsModel.setProperty(idx, "loop",     false)
        slotsModel.setProperty(idx, "chain",    false)
        markDirty(idx)
    }

    // Drag a slot's content to another slot. Default = move (source emptied),
    // swapMode = exchange both slots' content. Empty-source moves are a no-op
    // so that an accidental drag from a blank row doesn't clobber the target.
    function moveSlot(srcIdx, dstIdx) {
        if (srcIdx === dstIdx) return
        var src = slotsModel.get(srcIdx)
        if (!src.filename && !src.pseudo && !src.loop && !src.chain) return
        slotsModel.setProperty(dstIdx, "filename", src.filename)
        slotsModel.setProperty(dstIdx, "pseudo",   src.pseudo)
        slotsModel.setProperty(dstIdx, "loop",     src.loop)
        slotsModel.setProperty(dstIdx, "chain",    src.chain)
        slotsModel.setProperty(srcIdx, "filename", "")
        slotsModel.setProperty(srcIdx, "pseudo",   "")
        slotsModel.setProperty(srcIdx, "loop",     false)
        slotsModel.setProperty(srcIdx, "chain",    false)
        markDirty(srcIdx)
        markDirty(dstIdx)
    }

    // In-memory clipboard for copy/cut/paste of a single slot. Holds the four
    // editable fields (no slot index). Null until first copy/cut.
    property var clipboardSlot: null

    function slotIsEmpty(idx) {
        if (idx < 0 || idx >= 48) return true
        var s = slotsModel.get(idx)
        if (!s) return true
        return !s.filename && !s.pseudo && !s.loop && !s.chain
    }

    function copySlot(idx) {
        var s = slotsModel.get(idx)
        clipboardSlot = { filename: s.filename, pseudo: s.pseudo, loop: s.loop, chain: s.chain }
    }

    function cutSlot(idx) {
        copySlot(idx)
        clearSlot(idx)
    }

    function pasteSlot(idx) {
        if (!clipboardSlot) return
        slotsModel.setProperty(idx, "filename", clipboardSlot.filename)
        slotsModel.setProperty(idx, "pseudo",   clipboardSlot.pseudo)
        slotsModel.setProperty(idx, "loop",     clipboardSlot.loop)
        slotsModel.setProperty(idx, "chain",    clipboardSlot.chain)
        markDirty(idx)
    }

    // Delete the .mid file referenced by a slot from Linux Maître's MIDI dir,
    // then clear the slot. The user is expected to run a mirror sync afterward
    // to propagate the deletion to the other sirens — that's the whole point
    // of the source-of-truth model: change once on Maître, sync once everywhere.
    function deleteMidiFromMaster(idx) {
        var s = slotsModel.get(idx)
        if (!s || !s.filename) return
        var fname = s.filename
        var fullPath = MachinePaths.midiPath(linuxMaitre) + fname
        statusLabel.text = "Suppression de " + fname + " sur Linux Maître…"
        SshManager.executeCommand(linuxMaitre,
            "rm -f '" + fullPath.replace(/'/g, "'\\''") + "'",
            "delete-midi-" + idx)
        clearSlot(idx)
    }

    function swapSlots(a, b) {
        if (a === b) return
        var sa = slotsModel.get(a)
        var ta = { filename: sa.filename, pseudo: sa.pseudo, loop: sa.loop, chain: sa.chain }
        var sb = slotsModel.get(b)
        slotsModel.setProperty(a, "filename", sb.filename)
        slotsModel.setProperty(a, "pseudo",   sb.pseudo)
        slotsModel.setProperty(a, "loop",     sb.loop)
        slotsModel.setProperty(a, "chain",    sb.chain)
        slotsModel.setProperty(b, "filename", ta.filename)
        slotsModel.setProperty(b, "pseudo",   ta.pseudo)
        slotsModel.setProperty(b, "loop",     ta.loop)
        slotsModel.setProperty(b, "chain",    ta.chain)
        markDirty(a)
        markDirty(b)
    }

    // Le backend Node embarqué (proxy SSH) démarre en parallèle de l'app ; au
    // tout premier refresh il peut ne pas encore écouter 8005, l'erreur est
    // silencieuse et la liste resterait vide. On retente jusqu'à la 1re réponse.
    property bool catalogLoaded: false

    Timer {
        id: bootRetryTimer
        interval: 800
        repeat: true
        running: false
        property int attempts: 0
        onTriggered: {
            if (root.catalogLoaded || attempts >= 10) { running = false; return }
            attempts++
            root.refreshPlaylists()
        }
    }

    Component.onCompleted: {
        makeEmptySlots()
        refreshPlaylists()
        bootRetryTimer.running = true
    }

    // Path of the actual playlist file, resolved from `derniere_liste`. Empty
    // until loadFromMaster() succeeds (or set manually if user types one).
    property string activePlaylistPath: ""

    // Multi-playlist state — populated by refreshPlaylists() from the target's
    // liste_de_lecture/ dir. Names are basenames stripped of `.ListLecture`
    // (the extension is hidden in the UI). We keep `playlistFiles` as a map
    // name→originalBasename because the on-disk extension casing is mixed
    // (e.g. `2024.ListLecture` vs `2025.listlecture`); rebuilding paths with
    // a fixed-case extension would 404 on case-sensitive filesystems.
    property var playlistNames: []
    property var playlistFiles: ({})
    property string selectedName: ""   // currently selected in the combo
    property string activeName: ""     // basename pointed at by derniere_liste
    // When a create/delete bumps the catalog, we want to rebuild ALLLIST after
    // the refresh has updated playlistNames. The flag carries that intent
    // through the async ls roundtrip.
    property bool pendingAllListRebuild: false

    // Derive the absolute remote path for a playlist name on the current target.
    // Uses the recorded original basename when known so we don't munge the
    // extension's casing.
    function playlistPathFor(name) {
        var fname = playlistFiles[name] || (name + ".ListLecture")
        return MachinePaths.playlistPath(targetMachine) + fname
    }

    // List liste_de_lecture/ on the target and read its derniere_liste pointer.
    // Both responses land in the SshManager Connections handler below.
    function refreshPlaylists() {
        SshManager.executeCommand(targetMachine,
            "ls -1 '" + MachinePaths.playlistPath(targetMachine).replace(/'/g, "'\\''") + "'",
            "list-playlists")
        SshManager.downloadFile(targetMachine,
            MachinePaths.derniereListePath(targetMachine),
            "read-active-pointer")
    }

    // Load the currently-selected playlist's content into the editor. Replaces
    // the legacy loadFromMaster() flow (which always loaded derniere_liste).
    function loadSelectedPlaylist() {
        if (!selectedName) {
            statusLabel.text = "Aucune playlist sélectionnée."
            return
        }
        busy = true
        var path = playlistPathFor(selectedName)
        activePlaylistPath = path
        statusLabel.text = "Chargement de " + selectedName + "…"
        SshManager.downloadFile(targetMachine, path, "load-playlist")
    }

    // Set a playlist as active by rewriting derniere_liste. Same XML wrapper
    // format as the sync flow uses (see syncStep_pushDerniere).
    function setActivePlaylist(name) {
        if (!name) return
        busy = true
        var path = playlistPathFor(name)
        var content = "<string>" + path + "</string>\n"
        statusLabel.text = "Activation de " + name + "…"
        SshManager.uploadFile(targetMachine,
            MachinePaths.derniereListePath(targetMachine),
            content, "set-active")
    }

    // Create an empty playlist file. Name validation is permissive but rejects
    // empties, slashes, and the literal ".ListLecture" suffix (we add it).
    function createPlaylist(name) {
        var trimmed = String(name || "").trim()
        if (!trimmed) {
            statusLabel.text = "Nom de playlist vide."
            return
        }
        if (trimmed.indexOf("/") >= 0) {
            statusLabel.text = "Nom invalide (pas de '/')."
            return
        }
        // Strip .ListLecture if user typed it — extension is implicit.
        trimmed = trimmed.replace(/\.ListLecture$/i, "")
        if (playlistNames.indexOf(trimmed) >= 0) {
            statusLabel.text = "Une playlist '" + trimmed + "' existe déjà."
            return
        }
        busy = true
        statusLabel.text = "Création de " + trimmed + "…"
        SshManager.uploadFile(targetMachine, playlistPathFor(trimmed), "",
                              "create-playlist:" + trimmed)
    }

    function deletePlaylist(name) {
        if (!name) return
        if (name === activeName) {
            statusLabel.text = "⚠ '" + name + "' est la playlist active. Définis-en une autre d'abord."
            return
        }
        busy = true
        var path = playlistPathFor(name)
        statusLabel.text = "Suppression de " + name + "…"
        SshManager.executeCommand(targetMachine,
            "rm -f '" + path.replace(/'/g, "'\\''") + "'",
            "delete-playlist:" + name)
    }

    // Rewrite the firmware's ALLLIST catalog from the current playlistNames.
    // Format mimics the legacy: `{[n=N][l=filename]}` per line, slot N starts
    // at 1 and is sequential. The firmware reads ALLLIST on CMD_ASKSYNCHRO
    // (udp.c:112) — sending one after gives it the new catalog. Only meaningful
    // on Maître; other machines get it via Sync vers sirènes.
    function rebuildAllList() {
        if (targetMachine !== linuxMaitre) {
            return  // ALLLIST management only on Maître (source of truth)
        }
        var lines = []
        for (var i = 0; i < playlistNames.length; i++) {
            var fname = playlistFiles[playlistNames[i]] || (playlistNames[i] + ".ListLecture")
            lines.push("{[n=" + (i + 1) + "] [l=" + fname + "]}")
        }
        var content = lines.join("\n") + "\n"
        var path = MachinePaths.playlistPath(linuxMaitre) + "ALLLIST"
        SshManager.uploadFile(linuxMaitre, path, content, "rebuild-alllist")
    }

    // Tell the firmware to hot-reload a specific playlist. listIndex is the
    // position in playlistNames (also our ALLLIST order). Combined with a
    // prior rebuildAllList + ASKSYNCHRO so the firmware sees the entry first.
    function firmwareLoadPlaylist(name) {
        var idx = playlistNames.indexOf(name)
        if (idx < 0) return
        UdpManager.sendNewList(linuxMaitre, idx)
    }

    function loadFromMaster() {
        busy = true
        statusLabel.text = "Lecture du pointeur derniere_liste…"
        // Step 1: read the pointer file on the selected target. Step 2 (in
        // onDownloadFinished below) extracts the wrapped path and downloads
        // the actual playlist from that same target.
        SshManager.downloadFile(targetMachine,
            MachinePaths.derniereListePath(targetMachine), "load-pointer")
    }

    function saveToMaster() {
        if (!selectedName) {
            statusLabel.text = "Aucune playlist sélectionnée."
            return
        }
        // Save always targets the currently-selected playlist. We don't reuse
        // activePlaylistPath here because the user can edit playlist X while
        // Y is "active" — saving must follow the combo, not the ★ marker.
        var path = playlistPathFor(selectedName)
        activePlaylistPath = path   // keep legacy var in sync
        busy = true
        statusLabel.text = "Sauvegarde vers " + selectedName + "…"
        var lines = []
        for (var i = 0; i < 48; i++) {
            var s = slotsModel.get(i)
            lines.push("{[n=" + s.slot + "]\t\t[s=" + s.filename + "]\t\t\t[a=" +
                       s.pseudo + "]\t\t[B=" + (s.loop ? 1 : 0) + "]\t[E=" +
                       (s.chain ? 1 : 0) + "]}")
        }
        var content = lines.join("\n") + "\n"
        SshManager.uploadFile(targetMachine, activePlaylistPath, content, "save-playlist")
    }

    // Pull a basename out of an URL or path. "file:///foo/bar/baz.mid" → "baz.mid"
    function basename(urlOrPath) {
        var s = urlOrPath.toString()
        if (s.indexOf("file://") === 0) s = s.substring(7)
        var idx = s.lastIndexOf("/")
        return idx >= 0 ? s.substring(idx + 1) : s
    }

    // Upload a local file to the master's MIDI dir. assignToSlot >=0 also
    // assigns the dropped basename to that slot once the upload succeeds.
    property int pendingAssignSlot: -1
    property string pendingFilename: ""

    function uploadLocalMidi(localUrl, assignToSlot) {
        var name = basename(localUrl)
        if (!name.match(/\.midi?$/i)) {
            statusLabel.text = "Ignoré (pas un .mid): " + name
            return
        }
        pendingAssignSlot = assignToSlot !== undefined ? assignToSlot : -1
        pendingFilename = name
        busy = true
        statusLabel.text = "Upload de " + name + "…"
        SshManager.uploadLocalFile(targetMachine, localUrl,
                                   MachinePaths.midiPath(targetMachine) + name, "upload-midi")
    }

    function parsePlaylist(content) {
        // Match {[n=X]...[s=...]...[a=...]...[B=X]...[E=X]} for each entry.
        // The legacy uses tabs as separators; we just look for the bracketed fields.
        makeEmptySlots()
        var rx = /\{[^}]*\[n=(\d+)\][^}]*\[s=([^\]]*)\][^}]*\[a=([^\]]*)\][^}]*\[B=(\d)\][^}]*\[E=(\d)\][^}]*\}/g
        var match
        while ((match = rx.exec(content)) !== null) {
            var idx = parseInt(match[1])
            if (idx >= 0 && idx < 48) {
                slotsModel.set(idx, {
                    slot: idx,
                    filename: match[2],
                    pseudo:   match[3],
                    loop:     match[4] === "1",
                    chain:    match[5] === "1",
                    dirty:    false
                })
            }
        }
        dirtyCount = 0
    }

    // Sync targets. Remote paths come from MachinePaths so Artila vs Pi5
    // layouts stay in one place. The `liveness` field tells us how to
    // pre-check the entry:
    //   "trampresence:N"  → check based on sirenOnline[N-1] (artila S1-S7 + Trompe)
    //   "always"          → pre-check by default (raspberry-clic, voitures, pavillons —
    //                       no live ping for them, user unchecks if not needed)
    // Raspberry Clic = m_seq/pi5 firmware (Pi2 deployment is obsolete).
    // See firmwares-artila/m_seq/pi5/seq.h:85.
    readonly property var syncTargets: [
        { machineType: 2,  name: "S1",         liveness: "trampresence:1" },
        { machineType: 3,  name: "S2",         liveness: "trampresence:2" },
        { machineType: 4,  name: "S3",         liveness: "trampresence:3" },
        { machineType: 5,  name: "S4",         liveness: "trampresence:4" },
        { machineType: 6,  name: "S5",         liveness: "trampresence:5" },
        { machineType: 7,  name: "S6",         liveness: "trampresence:6" },
        { machineType: 8,  name: "S7",         liveness: "trampresence:7" },
        { machineType: 1,  name: "Raspberry",  liveness: "always" },
        { machineType: 9,  name: "Voiture A",  liveness: "always" },
        { machineType: 10, name: "Voiture B",  liveness: "always" },
        { machineType: 11, name: "Pavillon 1", liveness: "always" },
        { machineType: 12, name: "Pavillon 2", liveness: "always" }
    ]

    // Live siren-online state, driven by TRAMPRESENCE 0x21 from the master
    // (same data MaintenanceView's KEB dots use). Only S1-S7 are tracked
    // there — for other machines we ssh-ping them when the sync dialog opens.
    property var sirenOnline: [false, false, false, false, false, false, false]

    // Per-target ping state for "always" liveness machines (raspberry/voitures/
    // pavillons). Index = syncTargets index. Values: "online"|"offline"|"unknown".
    // Empty entry = not yet probed (still "unknown"). Updated as ssh-ping
    // results arrive without blocking dialog interaction.
    property var pingState: []

    function setPingState(idx, state) {
        var copy = pingState.slice()
        copy[idx] = state
        pingState = copy
    }

    // "online" | "offline" | "unknown"
    function targetStatus(idx) {
        var t = syncTargets[idx]
        if (t.liveness === "always") {
            return pingState[idx] || "unknown"
        }
        if (t.liveness.indexOf("trampresence:") === 0) {
            var n = parseInt(t.liveness.split(":")[1])
            return sirenOnline[n - 1] ? "online" : "offline"
        }
        return "unknown"
    }

    function statusColor(s) {
        if (s === "online") return "#33CC33"
        if (s === "offline") return "#AA3333"
        return "#FFC107"   // unknown — yellow
    }
    // Renamed from statusLabel(s) to avoid colliding with `id: statusLabel`
    // on the status bar Label. The collision made bindings that referenced
    // this function (sync dialog) silently throw a TypeError every frame.
    function statusText(s) {
        if (s === "online") return "en ligne"
        if (s === "offline") return "hors ligne"
        return "?"
    }

    // Fire `ssh <target> "true"` in parallel for every "always"-liveness target
    // and let the responses update pingState as they arrive.
    function pingAlwaysTargets() {
        // Reset all "always" entries to unknown.
        var copy = []
        for (var i = 0; i < syncTargets.length; i++) {
            copy[i] = (syncTargets[i].liveness === "always") ? "unknown" : ""
        }
        pingState = copy
        // Send the pings.
        for (var j = 0; j < syncTargets.length; j++) {
            if (syncTargets[j].liveness === "always") {
                SshManager.executeCommand(syncTargets[j].machineType, "true", "ping-" + j)
            }
        }
    }

    Connections {
        target: UdpManager
        function onKebPresenceReceived(sirenIdx, present) {
            if (sirenIdx < 1 || sirenIdx > 7) return
            var copy = sirenOnline.slice()
            copy[sirenIdx - 1] = present
            sirenOnline = copy
        }
    }

    // Multi-step sync state. Set by startSync, mutated as steps complete,
    // cleared by syncFinish. null when no sync is in flight.
    //   masterActivePath  — path of the active .ListLecture on Maître (read first)
    //   midiResults       — array aligned with picked[], from sync-midi syncDir
    //   playlistResults   — array aligned with picked[], from sync-playlist-dir
    //   derniereResults   — sparse map machineType→{success,error}, filled
    //                       as per-target sync-derniere-* uploads complete
    //   derniereInFlight  — count of pending sync-derniere-* uploads
    property var syncRun: null

    function startSync(selectedIndices, mirror, dryRun) {
        var picked = []
        for (var i = 0; i < syncTargets.length; i++) {
            if (selectedIndices.indexOf(i) >= 0) picked.push(syncTargets[i])
        }
        if (picked.length === 0) {
            statusLabel.text = "Aucune cible sélectionnée pour la sync."
            return
        }
        busy = true
        if (dryRun) statusLabel.text = "Aperçu miroir — calcul des fichiers à supprimer…"
        else if (mirror) statusLabel.text = "Mode miroir — lecture du pointeur Maître…"
        else statusLabel.text = "Lecture du pointeur Maître…"
        syncRun = {
            picked: picked,
            mirror: !!mirror,
            dryRun: !!dryRun,
            masterActivePath: "",
            midiResults: null,
            playlistResults: null,
            derniereResults: ({}),
            derniereInFlight: 0
        }
        if (syncRun.dryRun) {
            // No derniere/pointer step in dry-run — we're only checking what
            // mirror would delete on each target's Midi/ + liste_de_lecture/.
            syncStep_pushMidi()
        } else {
            // Step 1: read Maître's `derniere_liste` so we know the active
            // playlist path. We need it to write each target's pointer (rewritten
            // for Pi5's base path on the Raspberry Clic).
            SshManager.downloadFile(linuxMaitre,
                MachinePaths.derniereListePath(linuxMaitre), "sync-read-derniere")
        }
    }

    function syncStep_pushMidi() {
        statusLabel.text = (syncRun.dryRun ? "Aperçu" : "Sync") +
                           " MIDI vers " + syncRun.picked.length + " cible(s)…"
        var targets = syncRun.picked.map(function(p) {
            return { machineType: p.machineType, remotePath: MachinePaths.midiPath(p.machineType) }
        })
        // *.mid* matches both .mid and .midi (case-insensitive on the backend).
        SshManager.syncDir(linuxMaitre, MachinePaths.midiPath(linuxMaitre),
                           JSON.stringify(targets),
                           syncRun.mirror, "*.mid*", syncRun.dryRun, "sync-midi")
    }

    function syncStep_pushPlaylistDir() {
        statusLabel.text = (syncRun.dryRun ? "Aperçu" : "Sync") +
                           " liste_de_lecture vers " + syncRun.picked.length + " cible(s)…"
        var targets = syncRun.picked.map(function(p) {
            return { machineType: p.machineType, remotePath: MachinePaths.playlistPath(p.machineType) }
        })
        SshManager.syncDir(linuxMaitre, MachinePaths.playlistPath(linuxMaitre),
                           JSON.stringify(targets),
                           syncRun.mirror, "*.ListLecture", syncRun.dryRun, "sync-playlist-dir")
    }

    function syncStep_pushDerniere() {
        statusLabel.text = "Mise à jour des pointeurs derniere_liste…"
        syncRun.derniereInFlight = syncRun.picked.length
        for (var i = 0; i < syncRun.picked.length; i++) {
            var p = syncRun.picked[i]
            var pathOnTarget = MachinePaths.rewritePathForTarget(syncRun.masterActivePath, p.machineType)
            // Match the legacy XML wrapper format (cf. SireneControlMac).
            var content = "<string>" + pathOnTarget + "</string>\n"
            SshManager.uploadFile(p.machineType,
                MachinePaths.derniereListePath(p.machineType),
                content, "sync-derniere-" + p.machineType)
        }
    }

    function syncFinish() {
        busy = false
        var lines = []
        var ok = 0, fail = 0
        var totalOrphans = 0   // dry-run only — for the summary line
        for (var i = 0; i < syncRun.picked.length; i++) {
            var p = syncRun.picked[i]
            var midiR = (syncRun.midiResults && syncRun.midiResults[i]) || { success: false, error: "non synced" }
            var plR   = (syncRun.playlistResults && syncRun.playlistResults[i]) || { success: false, error: "non synced" }
            // Pointer step is skipped in dry-run; treat as success.
            var deR   = syncRun.dryRun
                ? { success: true }
                : (syncRun.derniereResults[p.machineType] || { success: false, error: "non synced" })
            var allOk = midiR.success && plR.success && deR.success
            if (allOk) {
                ok++
                if (syncRun.dryRun) {
                    // List the files that would be deleted, per dir.
                    var midiOrphans = (midiR.orphans || [])
                    var plOrphans   = (plR.orphans || [])
                    totalOrphans += midiOrphans.length + plOrphans.length
                    if (midiOrphans.length === 0 && plOrphans.length === 0) {
                        lines.push("✓ " + p.name + " — rien à supprimer")
                    } else {
                        lines.push("⚠ " + p.name + " — " +
                                   (midiOrphans.length + plOrphans.length) +
                                   " fichier(s) seraient supprimés:")
                        for (var mi = 0; mi < midiOrphans.length; mi++) {
                            lines.push("    .mid: " + midiOrphans[mi])
                        }
                        for (var pi = 0; pi < plOrphans.length; pi++) {
                            lines.push("    playlist: " + plOrphans[pi])
                        }
                    }
                } else {
                    // Normal sync — show how many orphans we cleared per dir.
                    var midiRm = (midiR.removed || 0)
                    var plRm   = (plR.removed || 0)
                    var rmStr = ""
                    if (syncRun.mirror && (midiRm > 0 || plRm > 0)) {
                        var parts = []
                        if (midiRm > 0) parts.push(midiRm + " .mid")
                        if (plRm > 0)   parts.push(plRm + " playlist(s)")
                        rmStr = " (-" + parts.join(", -") + ")"
                    }
                    lines.push("✓ " + p.name + rmStr)
                    // Pi5 only: the backend tries `systemctl restart m-seq.service`
                    // after sync so the kernel prioq picks up new MIDI/playlist
                    // content. Surface only failures — success is silent.
                    var prioqErr = (midiR.prioqRefreshError || plR.prioqRefreshError)
                    if (prioqErr) {
                        lines.push("    ⚠ prioq non rafraîchie: " + prioqErr)
                    }
                }
            } else {
                fail++
                var msgs = []
                if (!midiR.success) msgs.push("midi: "     + (midiR.error || "?"))
                if (!plR.success)   msgs.push("playlist: " + (plR.error   || "?"))
                if (!deR.success)   msgs.push("pointeur: " + (deR.error   || "?"))
                lines.push("✗ " + p.name + " — " + msgs.join("; "))
            }
        }
        if (syncRun.dryRun) {
            statusLabel.text = "Aperçu: " + totalOrphans + " fichier(s) à supprimer (rien n'a été touché)"
        } else {
            statusLabel.text = "Sync: " + ok + " OK / " + fail + " échec(s)"
        }
        syncResultDialog.summary = lines.join("\n")
        syncResultDialog.open()
        syncRun = null
    }

    function syncAbort(reason) {
        busy = false
        statusLabel.text = "Sync interrompue: " + reason
        syncResultDialog.summary = "Échec global: " + reason
        syncResultDialog.open()
        syncRun = null
    }

    Connections {
        target: SshManager

        function onSyncDirFinished(requestId, success, tarSize, resultsJson, error) {
            if (requestId === "sync-midi") {
                if (!success) { syncAbort("MIDI: " + error); return }
                syncRun.midiResults = JSON.parse(resultsJson)
                syncStep_pushPlaylistDir()
                return
            }
            if (requestId === "sync-playlist-dir") {
                if (!success) { syncAbort("playlist: " + error); return }
                syncRun.playlistResults = JSON.parse(resultsJson)
                if (syncRun.dryRun) {
                    // Dry-run done — nothing else to do, format and show.
                    syncFinish()
                } else {
                    syncStep_pushDerniere()
                }
                return
            }
        }

        function onDownloadFinished(requestId, success, content, error) {
            if (requestId === "load-pointer") {
                if (!success) {
                    busy = false
                    statusLabel.text = "Erreur (pointeur): " + error
                    return
                }
                // The pointer file content looks like:
                //   <string>/mnt/disk/.../liste_de_lecture/2024.ListLecture</string>
                // Pull the path out and chain into the real download.
                var m = content.match(/<string>([^<]+)<\/string>/)
                if (!m) {
                    busy = false
                    statusLabel.text = "Format de derniere_liste inattendu: " + content.substring(0, 80)
                    return
                }
                activePlaylistPath = m[1].trim()
                statusLabel.text = "Chargement de " + activePlaylistPath + "…"
                SshManager.downloadFile(targetMachine, activePlaylistPath, "load-playlist")
                return
            }
            if (requestId === "load-playlist") {
                busy = false
                if (success) {
                    parsePlaylist(content)
                    statusLabel.text = "Playlist chargée: " + activePlaylistPath
                } else {
                    statusLabel.text = "Erreur (playlist): " + error
                }
                return
            }
            if (requestId === "sync-read-derniere") {
                if (!success) { syncAbort("lecture pointeur Maître: " + error); return }
                var m2 = content.match(/<string>([^<]+)<\/string>/)
                if (!m2) { syncAbort("format derniere_liste inattendu"); return }
                syncRun.masterActivePath = m2[1].trim()
                syncStep_pushMidi()
                return
            }
            if (requestId === "read-active-pointer") {
                if (!success) {
                    // Pointer file might just not exist yet — that's not fatal,
                    // it just means no active playlist on this target.
                    activeName = ""
                    return
                }
                var pm = content.match(/<string>([^<]+)<\/string>/)
                if (pm) {
                    var basename = pm[1].trim().split("/").pop()
                    activeName = basename.replace(/\.ListLecture$/i, "")
                } else {
                    activeName = ""
                }
                return
            }
        }
        function onUploadFinished(requestId, success, error) {
            if (requestId === "save-playlist") {
                busy = false
                if (success) {
                    clearAllDirty()
                    // If we just saved the *active* playlist on Maître, ask
                    // the firmware to hot-reload that exact entry from disk
                    // so it picks up the slot edits without a reboot.
                    if (targetMachine === linuxMaitre && selectedName === activeName) {
                        firmwareLoadPlaylist(selectedName)
                        statusLabel.text = "Sauvegardé. Firmware notifié pour rechargement."
                    } else {
                        statusLabel.text = "Sauvegardé."
                    }
                } else {
                    statusLabel.text = "Erreur: " + error
                }
                return
            }
            if (requestId === "set-active") {
                busy = false
                if (success) {
                    // The pointer file is updated; tell the firmware to load
                    // the new playlist hot. activeName won't be updated until
                    // refresh, so resolve the index from selectedName instead.
                    if (targetMachine === linuxMaitre) {
                        firmwareLoadPlaylist(selectedName)
                    }
                    statusLabel.text = "Playlist active changée."
                    refreshPlaylists()
                } else {
                    statusLabel.text = "Erreur: " + error
                }
                return
            }
            if (requestId.indexOf("create-playlist:") === 0) {
                busy = false
                var newName = requestId.substring("create-playlist:".length)
                if (success) {
                    statusLabel.text = "Playlist '" + newName + "' créée."
                    selectedName = newName    // preselect it after refresh
                    pendingAllListRebuild = true
                    refreshPlaylists()
                } else {
                    statusLabel.text = "Erreur création: " + error
                }
                return
            }
            if (requestId === "rebuild-alllist") {
                if (success) {
                    // Tell the firmware to re-scan ALLLIST so the new/changed
                    // entries are visible to subsequent CMD_NEWLIST calls.
                    UdpManager.sendAskSynchro(linuxMaitre)
                } else {
                    statusLabel.text = "Erreur ALLLIST: " + error
                }
                return
            }
            if (requestId === "upload-midi") {
                busy = false
                if (success) {
                    statusLabel.text = "Uploadé: " + pendingFilename
                    if (pendingAssignSlot >= 0 && pendingAssignSlot < 48) {
                        slotsModel.setProperty(pendingAssignSlot, "filename", pendingFilename)
                        // Auto-fill pseudo from basename if the slot didn't have
                        // one, mirroring legacy SireneControlMac behavior
                        // (PlaylistComposerViewController.m:794). Without this,
                        // saving produced [a=] which the firmware then echoed
                        // as empty pseudos in PS messages.
                        var existingPseudo = slotsModel.get(pendingAssignSlot).pseudo
                        if (!existingPseudo || existingPseudo.length === 0) {
                            var defaultPseudo = pendingFilename.replace(/\.midi?$/i, "")
                            slotsModel.setProperty(pendingAssignSlot, "pseudo", defaultPseudo)
                        }
                        markDirty(pendingAssignSlot)
                    }
                    midiFilesStatus.text = "Uploadé: " + pendingFilename
                } else {
                    statusLabel.text = "Erreur upload " + pendingFilename + ": " + error
                }
                pendingFilename = ""
                pendingAssignSlot = -1
                return
            }
            if (requestId.indexOf("sync-derniere-") === 0) {
                if (!syncRun) return
                var mt = parseInt(requestId.substring("sync-derniere-".length))
                syncRun.derniereResults[mt] = { success: success, error: error }
                syncRun.derniereInFlight = syncRun.derniereInFlight - 1
                if (syncRun.derniereInFlight <= 0) syncFinish()
                return
            }
        }
        function onCommandFinished(requestId, success, output, error) {
            // Sync-dialog ssh pings — keep `busy` untouched (these run silently
            // alongside whatever the user is doing).
            if (requestId.indexOf("ping-") === 0) {
                var idx = parseInt(requestId.substring(5))
                setPingState(idx, success ? "online" : "offline")
                return
            }
            if (requestId.indexOf("delete-midi-") === 0) {
                if (success) {
                    statusLabel.text = "Fichier supprimé sur Maître. Lance 'Sync vers sirènes' (mode miroir) pour propager."
                } else {
                    statusLabel.text = "Erreur suppression: " + error
                }
                return
            }
            if (requestId === "list-playlists") {
                if (!success) {
                    statusLabel.text = "Erreur lecture playlists: " + error
                    return
                }
                // Backend joignable : on arrête le retry de course au boot.
                root.catalogLoaded = true
                var rawFiles = output.split("\n")
                    .map(function (s) { return s.trim() })
                    .filter(function (s) { return s.length > 0 })
                    .filter(function (s) { return /\.ListLecture$/i.test(s) })
                var fileMap = ({})
                var names = []
                for (var ri = 0; ri < rawFiles.length; ri++) {
                    var rf = rawFiles[ri]
                    var name = rf.replace(/\.ListLecture$/i, "")
                    names.push(name)
                    fileMap[name] = rf   // preserve original casing
                }
                names.sort()
                playlistFiles = fileMap
                playlistNames = names
                // If selectedName disappeared after a refresh, fall back to
                // active (or first available) so the combo always points at
                // something valid.
                if (names.indexOf(selectedName) < 0) {
                    selectedName = (names.indexOf(activeName) >= 0)
                        ? activeName
                        : (names.length > 0 ? names[0] : "")
                }
                if (pendingAllListRebuild) {
                    pendingAllListRebuild = false
                    rebuildAllList()
                }
                return
            }
            if (requestId.indexOf("delete-playlist:") === 0) {
                var deletedName = requestId.substring("delete-playlist:".length)
                if (success) {
                    statusLabel.text = "Playlist '" + deletedName + "' supprimée."
                    pendingAllListRebuild = true
                    refreshPlaylists()
                } else {
                    statusLabel.text = "Erreur suppression playlist: " + error
                }
                busy = false
                return
            }
            busy = false
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 12

        // ==================== TOP CONTROLS ====================
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: "#2a2a2a"; border.color: "#444"; radius: 6

            RowLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 12

                Label { text: "Cible:"; color: "#aaa"; font.pixelSize: 12 }
                ComboBox {
                    model: allMachines.map(function(m) { return m.name })
                    currentIndex: 0
                    Layout.preferredWidth: 180
                    onCurrentIndexChanged: {
                        targetMachine = allMachines[currentIndex].id
                        refreshPlaylists()
                    }
                }

                Button { text: "Charger";    Layout.preferredHeight: 32; onClicked: loadSelectedPlaylist() }
                Button {
                    id: saveButton
                    text: dirtyCount > 0 ? ("Sauvegarder (" + dirtyCount + " modif)") : "Sauvegarder"
                    Layout.preferredHeight: 32
                    background: Rectangle {
                        color: dirtyCount > 0 ? "#FFA500" : "#444"
                        border.color: "#666"; border.width: 1; radius: 4
                    }
                    contentItem: Text {
                        text: parent.text
                        color: dirtyCount > 0 ? "black" : "white"
                        font.bold: dirtyCount > 0
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                    }
                    onClicked: saveToMaster()
                }
                Button { text: "Vider";       Layout.preferredHeight: 32; onClicked: makeEmptySlots() }
                Button {
                    text: "Sync vers sirènes"
                    Layout.preferredHeight: 32
                    onClicked: syncDialog.open()
                }
                Button {
                    text: "Backup local"
                    Layout.preferredHeight: 32
                    onClicked: {
                        statusLabel.text = "Backup demandé — choisis l'emplacement dans le navigateur."
                        Qt.openUrlExternally("http://localhost:8005/api/playlists/backup?machine=linuxMaitre")
                    }
                }

                BusyIndicator {
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    running: busy
                    visible: busy
                }

                Item { Layout.fillWidth: true }

                Label { id: statusLabel; text: ""; color: "#888"; font.pixelSize: 11 }
            }
        }

        // ==================== PLAYLIST PICKER ====================
        // Combo lists every .ListLecture in the target's liste_de_lecture/ dir.
        // The active one (per derniere_liste) is prefixed with ★. Selection
        // drives Charger/Sauvegarder; "Définir comme active" rewrites the
        // pointer; Nouvelle/Supprimer create/rm files. The .ListLecture
        // extension is hidden from the user — added when building paths.
        RowLayout {
            Layout.fillWidth: true
            spacing: 8

            Label { text: "Playlist:"; color: "#aaa"; font.pixelSize: 12 }
            ComboBox {
                id: playlistCombo
                Layout.preferredWidth: 260
                Layout.preferredHeight: 30
                model: playlistNames.map(function (n) {
                    return (n === activeName ? "★ " : "    ") + n
                })
                currentIndex: playlistNames.indexOf(selectedName)
                onActivated: {
                    if (currentIndex >= 0 && currentIndex < playlistNames.length) {
                        selectedName = playlistNames[currentIndex]
                    }
                }
                Connections {
                    target: root
                    function onSelectedNameChanged() {
                        playlistCombo.currentIndex = playlistNames.indexOf(selectedName)
                    }
                    function onPlaylistNamesChanged() {
                        playlistCombo.currentIndex = playlistNames.indexOf(selectedName)
                    }
                }
            }
            Button {
                text: "↻"
                Layout.preferredHeight: 30
                Layout.preferredWidth: 32
                onClicked: refreshPlaylists()
                ToolTip.visible: hovered
                ToolTip.text: "Rafraîchir la liste"
            }
            Button {
                text: "Définir comme active"
                Layout.preferredHeight: 30
                enabled: selectedName.length > 0 && selectedName !== activeName
                onClicked: setActivePlaylist(selectedName)
            }
            Button {
                text: "Nouvelle…"
                Layout.preferredHeight: 30
                onClicked: newPlaylistDialog.open()
            }
            Button {
                text: "Supprimer"
                Layout.preferredHeight: 30
                enabled: selectedName.length > 0
                onClicked: {
                    if (selectedName === activeName) {
                        statusLabel.text = "⚠ '" + selectedName + "' est active. Définis-en une autre d'abord."
                    } else {
                        deletePlaylistDialog.targetName = selectedName
                        deletePlaylistDialog.open()
                    }
                }
            }
            Item { Layout.fillWidth: true }
        }
        // Drop zone for new MIDI files: drag from Finder onto this band to
        // upload to the master's MIDI dir. Multi-file drops are supported.
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 50
            color: globalDrop.containsDrag ? "#3a3a1a" : "#1a1a1a"
            border.color: globalDrop.containsDrag ? "#FFD700" : "#444"
            border.width: globalDrop.containsDrag ? 2 : 1
            radius: 4

            RowLayout {
                anchors.fill: parent
                anchors.margins: 8
                spacing: 8

                Label {
                    text: "📥"
                    color: "#888"
                    font.pixelSize: 18
                }
                Label {
                    id: midiFilesStatus
                    text: "Glisser des .mid ici pour les uploader sur la cible"
                    color: "#888"
                    font.pixelSize: 11
                    Layout.fillWidth: true
                }
            }

            DropArea {
                id: globalDrop
                anchors.fill: parent
                onDropped: function(drop) {
                    if (!drop.hasUrls) return
                    for (var i = 0; i < drop.urls.length; i++) {
                        uploadLocalMidi(drop.urls[i], -1)
                    }
                    drop.accept()
                }
            }
        }

        // ==================== HEADER ====================
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 28
            color: "#222"
            radius: 4

            RowLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 6
                Label { text: "#";       color: "#888"; font.pixelSize: 11; Layout.preferredWidth: 28 }
                Label { text: "Fichier"; color: "#888"; font.pixelSize: 11; Layout.fillWidth: true }
                Label { text: "Pseudo";  color: "#888"; font.pixelSize: 11; Layout.preferredWidth: 200 }
                Label { text: "Boucle";  color: "#888"; font.pixelSize: 11; Layout.preferredWidth: 60; horizontalAlignment: Text.AlignHCenter }
                Label { text: "Enchaîné"; color: "#888"; font.pixelSize: 11; Layout.preferredWidth: 70; horizontalAlignment: Text.AlignHCenter }
                Item { Layout.preferredWidth: 24 }
            }
        }

        // Discoverability hint for the slot-row interactions added on top of the
        // legacy edit-fields layout. Drag is from the "#" column; Shift toggles
        // swap; ✕ appears only on filled rows.
        Label {
            text: "Glisser le n° pour déplacer (Shift = échanger) — clic droit : couper/copier/coller/effacer — ✕ : vider"
            color: "#666"
            font.pixelSize: 10
            Layout.fillWidth: true
        }

        // ==================== 48 SLOTS ====================
        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
                model: slotsModel
                spacing: 2
                delegate: Rectangle {
                    id: slotRow
                    width: ListView.view.width
                    height: 32
                    color: slotDrop.containsDrag
                           ? "#3a3a1a"
                           : (index % 2 === 0 ? "#2a2a2a" : "#252525")
                    border.color: slotDrop.containsDrag
                                  ? "#FFD700"
                                  : (dirty ? "#FFA500" : "transparent")
                    border.width: (slotDrop.containsDrag || dirty) ? 2 : 0
                    radius: 3

                    DropArea {
                        id: slotDrop
                        anchors.fill: parent
                        onDropped: function(drop) {
                            if (drop.hasUrls) {
                                uploadLocalMidi(drop.urls[0], index)
                                for (var i = 1; i < drop.urls.length; i++) {
                                    uploadLocalMidi(drop.urls[i], -1)
                                }
                                drop.accept()
                                return
                            }
                            var src = drop.source
                            if (src && src.slotIdx !== undefined) {
                                if (src.swapMode === true) swapSlots(src.slotIdx, index)
                                else moveSlot(src.slotIdx, index)
                                drop.accept()
                            }
                        }
                    }

                    // Row-wide right-click context menu. acceptedButtons is
                    // RightButton only, so left-clicks fall through to the
                    // TextFields, CheckBoxes and the # drag handle below. This
                    // makes the slot menu reachable from anywhere on the row,
                    // not just the narrow 28px # column.
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.RightButton
                        onPressed: function(m) {
                            slotMenu.slotIdx = index
                            slotMenu.popup()
                        }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 4
                        spacing: 6

                        // 28px placeholder reserves the column; the actual
                        // # display + drag handle (numCell) lives outside the
                        // RowLayout (see below) so it's free to move during a
                        // drag without the Layout re-positioning it.
                        Item { Layout.preferredWidth: 28; Layout.preferredHeight: 24 }

                        TextField {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 24
                            text: filename
                            placeholderText: "(fichier .midi)"
                            font.family: "Menlo"
                            font.pixelSize: 12
                            onTextEdited: {
                                slotsModel.setProperty(index, "filename", text)
                                markDirty(index)
                            }
                            // Override TextField's built-in right-click
                            // edit menu (Qt's English Cut/Copy/Paste/Delete)
                            // with our slot context menu. acceptedButtons
                            // RightButton only, so left-clicks/text editing
                            // still go to the TextField underneath.
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                onPressed: {
                                    slotMenu.slotIdx = index
                                    slotMenu.popup()
                                }
                            }
                        }

                        TextField {
                            Layout.preferredWidth: 200
                            Layout.preferredHeight: 24
                            text: pseudo
                            placeholderText: "(pseudo)"
                            onTextEdited: {
                                slotsModel.setProperty(index, "pseudo", text)
                                markDirty(index)
                            }
                            MouseArea {
                                anchors.fill: parent
                                acceptedButtons: Qt.RightButton
                                onPressed: {
                                    slotMenu.slotIdx = index
                                    slotMenu.popup()
                                }
                            }
                        }

                        CheckBox {
                            Layout.preferredWidth: 60
                            Layout.alignment: Qt.AlignHCenter
                            checked: loop
                            onToggled: {
                                slotsModel.setProperty(index, "loop", checked)
                                markDirty(index)
                            }
                        }

                        CheckBox {
                            Layout.preferredWidth: 70
                            Layout.alignment: Qt.AlignHCenter
                            checked: chain
                            onToggled: {
                                slotsModel.setProperty(index, "chain", checked)
                                markDirty(index)
                            }
                        }

                        // Per-slot clear button. The Item always reserves the
                        // 24px column so empty rows align with filled ones; the
                        // ✕ Label inside is only shown (and hit-testable) when
                        // the slot has content.
                        Item {
                            Layout.preferredWidth: 24
                            Layout.preferredHeight: 24
                            Layout.alignment: Qt.AlignHCenter
                            Label {
                                anchors.centerIn: parent
                                text: "✕"
                                font.pixelSize: 14
                                color: clearMA.containsMouse ? "#FF6666" : "#666"
                                visible: filename.length > 0 || pseudo.length > 0 || loop || chain
                                MouseArea {
                                    id: clearMA
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: clearSlot(index)
                                }
                            }
                        }
                    }

                    // # display + drag handle, absolute child of slotRow so
                    // drag.target can move it freely without RowLayout fighting
                    // back. ParentChange reparents to `root` while dragging so
                    // it can leave its row's bounds (otherwise the ScrollView
                    // would clip it AND DropAreas in other rows wouldn't
                    // necessarily see the hotspot).
                    Item {
                        id: numCell
                        property int slotIdx: index
                        property bool swapMode: false
                        x: 4
                        y: 4
                        width: 28
                        height: 24
                        z: 5

                        Drag.active: dragMA.drag.active
                        Drag.hotSpot.x: 14
                        Drag.hotSpot.y: 12

                        states: State {
                            name: "dragging"
                            when: dragMA.drag.active
                            ParentChange { target: numCell; parent: root }
                        }

                        Label {
                            anchors.fill: parent
                            text: (index + 1).toString()
                            color: dragMA.containsMouse ? "#ddd" : "#888"
                            font.pixelSize: 11
                            horizontalAlignment: Text.AlignRight
                            verticalAlignment: Text.AlignVCenter
                        }

                        MouseArea {
                            id: dragMA
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.OpenHandCursor
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            drag.target: parent
                            drag.threshold: 4
                            onPressed: function(m) {
                                if (m.button === Qt.RightButton) {
                                    slotMenu.slotIdx = index
                                    slotMenu.popup()
                                    return
                                }
                                numCell.swapMode = (m.modifiers & Qt.ShiftModifier) !== 0
                            }
                            onReleased: {
                                // MouseArea + drag.target cancels the drag on
                                // release without notifying DropAreas. Calling
                                // Drag.drop() turns it into a real drop event
                                // on whatever DropArea is currently entered.
                                if (numCell.Drag.active) {
                                    numCell.Drag.drop()
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // ==================== SYNC CONFIRMATION ====================
    Dialog {
        id: syncDialog
        title: "Synchroniser MIDI + playlist vers les machines"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok | Dialog.Cancel

        // Per-target picked state, keyed by syncTargets index. On open, we
        // pre-check based on each target's liveness rule (TRAMPRESENCE for
        // sirens, optimistically true for the others until ping returns).
        property var picked: []
        // Mirror mode: if checked, files on each target that don't exist on
        // Maître get rm'd before the tar untar. Unchecked by default — the
        // sync stays additive unless the user explicitly opts in.
        property bool mirror: false
        // Dry-run: list orphans per target without deleting anything. Implies
        // mirror; ignored when mirror is false.
        property bool dryRun: false
        onOpened: {
            var copy = []
            for (var i = 0; i < syncTargets.length; i++) {
                var t = syncTargets[i]
                if (t.liveness.indexOf("trampresence:") === 0) {
                    var n = parseInt(t.liveness.split(":")[1])
                    copy.push(sirenOnline[n - 1] === true)
                } else {
                    copy.push(true)   // optimistic until ping says otherwise
                }
            }
            picked = copy
            mirror = false   // don't carry the choice between opens — opt-in each time
            dryRun = false
            pingAlwaysTargets()
        }

        contentItem: ColumnLayout {
            spacing: 6
            Label {
                text: "Source : Linux Maître (Midi/ + liste_de_lecture/ + derniere_liste). Le contenu est copié vers chaque cible cochée."
                color: "white"
                wrapMode: Text.Wrap
                Layout.preferredWidth: 460
            }
            Label {
                text: "Pastilles : ● vert = en ligne, ● rouge = hors ligne, ● jaune = ping en cours."
                color: "#888"
                font.pixelSize: 10
                wrapMode: Text.Wrap
                Layout.preferredWidth: 460
            }

            Repeater {
                model: syncTargets
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Rectangle {
                        Layout.preferredWidth: 10
                        Layout.preferredHeight: 10
                        radius: 5
                        color: statusColor(targetStatus(index))
                    }
                    CheckBox {
                        text: modelData.name
                        checked: syncDialog.picked[index] === true
                        onToggled: {
                            var c = syncDialog.picked.slice()
                            c[index] = checked
                            syncDialog.picked = c
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Label {
                        text: MachinePaths.midiPath(modelData.machineType)
                        color: "#666"
                        font.pixelSize: 9
                        font.family: "Menlo"
                    }
                    Label {
                        text: statusText(targetStatus(index))
                        color: statusColor(targetStatus(index))
                        font.pixelSize: 10
                        Layout.preferredWidth: 80
                        horizontalAlignment: Text.AlignRight
                    }
                }
            }

            Label {
                text: "Les fichiers existants sur les cibles cochées seront écrasés (MIDI + playlists + pointeur actif)."
                color: "#FFA500"
                font.pixelSize: 11
            }

            // Opt-in mirror checkbox. When checked, each target's .mid +
            // .ListLecture files that don't exist on Maître get rm'd before
            // the tar extract — turning the additive sync into a real mirror.
            CheckBox {
                checked: syncDialog.mirror
                onToggled: syncDialog.mirror = checked
                contentItem: Label {
                    text: "Supprimer aussi les fichiers absents de Linux Maître (miroir)"
                    color: "white"
                    leftPadding: 24
                    verticalAlignment: Text.AlignVCenter
                }
            }
            // Dry-run: list orphans without deleting. Only relevant when
            // mirror is on. Lets the user audit what would be removed before
            // committing — important because Maître's Midi/ may be sparser
            // than the targets and a hot mirror would wipe lots of files.
            CheckBox {
                visible: syncDialog.mirror
                checked: syncDialog.dryRun
                onToggled: syncDialog.dryRun = checked
                contentItem: Label {
                    text: "Aperçu uniquement (liste les fichiers, ne supprime rien)"
                    color: "white"
                    leftPadding: 24
                    verticalAlignment: Text.AlignVCenter
                }
            }
            Label {
                visible: syncDialog.mirror && !syncDialog.dryRun
                text: "⚠ En mode miroir, les .mid et .ListLecture présents sur les cibles mais pas sur Maître seront supprimés."
                color: "#FF6666"
                font.pixelSize: 10
                wrapMode: Text.Wrap
                Layout.preferredWidth: 460
            }
            Label {
                visible: syncDialog.mirror && syncDialog.dryRun
                text: "✓ Aperçu : aucune suppression ne sera effectuée. La fenêtre de résultat listera les fichiers concernés."
                color: "#33CC33"
                font.pixelSize: 10
                wrapMode: Text.Wrap
                Layout.preferredWidth: 460
            }
        }
        onAccepted: {
            var indices = []
            for (var i = 0; i < syncTargets.length; i++) if (picked[i]) indices.push(i)
            startSync(indices, mirror, mirror && dryRun)
        }
    }

    // ==================== SYNC RESULT ====================
    Dialog {
        id: syncResultDialog
        title: "Résultat de la synchronisation"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok
        property string summary: ""
        contentItem: ColumnLayout {
            spacing: 6
            TextEdit {
                text: syncResultDialog.summary
                readOnly: true
                selectByMouse: true
                color: "white"
                font.family: "Menlo"
                font.pixelSize: 12
                Layout.preferredWidth: 360
                Layout.preferredHeight: 200
                wrapMode: TextEdit.NoWrap
            }
        }
    }

    // ==================== SLOT CONTEXT MENU ====================
    // Single shared instance, popup'd from each row's contextMA on right-click.
    // slotIdx is set just before popup so the action handlers know the target.
    Menu {
        id: slotMenu
        property int slotIdx: -1
        property bool selectionHasContent: !slotIsEmpty(slotIdx)
        property bool hasClipboard: clipboardSlot !== null && clipboardSlot !== undefined

        MenuItem {
            text: "Couper"
            enabled: slotMenu.selectionHasContent
            onTriggered: cutSlot(slotMenu.slotIdx)
        }
        MenuItem {
            text: "Copier"
            enabled: slotMenu.selectionHasContent
            onTriggered: copySlot(slotMenu.slotIdx)
        }
        MenuItem {
            text: "Coller"
            enabled: slotMenu.hasClipboard && slotMenu.slotIdx >= 0
            onTriggered: pasteSlot(slotMenu.slotIdx)
        }
        MenuSeparator {}
        MenuItem {
            text: "Effacer"
            enabled: slotMenu.selectionHasContent
            onTriggered: clearSlot(slotMenu.slotIdx)
        }
        MenuItem {
            text: "Supprimer le .mid (sur Maître)"
            enabled: slotMenu.selectionHasContent
            onTriggered: deleteMidiFromMaster(slotMenu.slotIdx)
        }
    }

    // ==================== NEW PLAYLIST DIALOG ====================
    Dialog {
        id: newPlaylistDialog
        title: "Nouvelle playlist"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok | Dialog.Cancel
        onOpened: { newNameField.text = ""; newNameField.forceActiveFocus() }
        contentItem: ColumnLayout {
            spacing: 8
            Label {
                text: "Nom de la playlist (l'extension .ListLecture sera ajoutée) :"
                color: "white"
                Layout.preferredWidth: 320
                wrapMode: Text.Wrap
            }
            TextField {
                id: newNameField
                Layout.fillWidth: true
                placeholderText: "(ex: 2026)"
                onAccepted: newPlaylistDialog.accept()
            }
        }
        onAccepted: createPlaylist(newNameField.text)
    }

    // ==================== DELETE PLAYLIST CONFIRMATION ====================
    Dialog {
        id: deletePlaylistDialog
        title: "Supprimer la playlist"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Yes | Dialog.No
        property string targetName: ""
        contentItem: Label {
            text: "Supprimer la playlist '" + deletePlaylistDialog.targetName +
                  "' sur " + (allMachines[targetMachine] ? allMachines[targetMachine].name : "?") +
                  " ?\n\nLe fichier .ListLecture sera retiré du disque."
            color: "white"
            wrapMode: Text.Wrap
        }
        onAccepted: deletePlaylist(targetName)
    }

}
