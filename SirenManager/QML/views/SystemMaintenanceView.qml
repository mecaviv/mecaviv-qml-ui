import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SirenManager
import "../controllers/MachinePaths.js" as MachinePaths
import "../components"

Rectangle {
    id: root
    color: "#1e1e1e"

    // MachineType enum values mirrored in QML (see src/Config/MachineType.h).
    // Paths come from MachinePaths so they stay in sync with PlaylistComposerView.
    readonly property var machines: [
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

    property int selectedMachineIdx: 0
    property bool busy: false

    function currentMachine() { return machines[selectedMachineIdx] }

    // ---- Live tracking ("Suivre"), kept cheap on the boards: one ssh command
    // per tick, never two in flight, nothing while the view is hidden or the
    // box unchecked, and the dmesg text is only redrawn when it changed.
    // Each tick opens a new ssh session: on the Artila (old key exchange) that
    // costs about a second, so a `ControlMaster auto` + `ControlPersist 60` in
    // ~/.ssh/config for the board makes the ticks nearly free.
    readonly property int dmesgTrackMs: 3000
    readonly property int cpuTrackMs: 2000
    readonly property int cpuHistory: 90          // samples kept in the plot
    property bool dmesgInFlight: false
    property bool cpuInFlight: false
    property string lastDmesgText: ""
    property var cpuPrev: null                    // {total, idle} of the last /proc/stat
    property var cpuSamples: []                   // percent, oldest first
    property string cpuLoad: ""
    property int cpuCores: 1
    property var procPrev: ({})                   // pid -> jiffies (utime+stime) of the last tick
    property var processes: []                    // [{pid, name, state, cpu, rssKb, threads}]
    property string procSort: "cpu"               // cpu | mem | pid | name
    property bool showKernelThreads: false
    property bool procSeen: false                 // a tick has delivered a process list

    // Readings of the summary tiles: set by "Rafraîchir" (system-info) and,
    // for the memory, by every tracked tick as well.
    property real memTotalKb: -1
    property real memUsedKb: -1
    property real diskTotalKb: -1
    property real diskUsedKb: -1
    property string diskPct: ""

    function requestDmesgTrack() {
        if (dmesgInFlight) return
        dmesgInFlight = true
        SshManager.executeCommand(currentMachine().id, "dmesg | tail -150", "dmesg-track")
    }

    function requestCpuTrack() {
        if (cpuInFlight) return
        cpuInFlight = true
        // /proc/stat's cpu lines, the load averages, the memory counters and
        // one stat file per process: small /proc reads, no top/ps (BusyBox 1.00
        // on the Artila has neither the options nor the patience), so the
        // measurement barely loads the board it measures.
        SshManager.executeCommand(currentMachine().id,
            "grep '^cpu' /proc/stat; cat /proc/loadavg;"
            + " grep -E '^(MemTotal|MemFree|Buffers|Cached):' /proc/meminfo;"
            + " cat /proc/[0-9]*/stat 2>/dev/null", "cpu-track")
    }

    function onCpuSample(output) {
        var m = output.match(/^cpu\s+(.*)$/m)
        if (!m) return
        var f = m[1].trim().split(/\s+/).map(Number)
        var total = f.reduce(function(a, b) { return a + b }, 0)
        var idle = f[3] + (f[4] || 0)            // idle + iowait
        var l = output.match(/^(\d+\.\d+\s+\d+\.\d+\s+\d+\.\d+)/m)
        cpuLoad = l ? l[1] : ""
        // "cpu" alone on a uniprocessor kernel, "cpu" + "cpuN" lines on SMP.
        var cpuLines = (output.match(/^cpu\d*\s/mg) || []).length
        cpuCores = Math.max(1, cpuLines - 1)
        var dTotal = cpuPrev !== null ? total - cpuPrev.total : 0
        if (dTotal > 0) {
            var pct = 100 * (1 - (idle - cpuPrev.idle) / dTotal)
            var next = cpuSamples.concat([Math.max(0, Math.min(100, pct))])
            cpuSamples = next.slice(-cpuHistory)
        }
        cpuPrev = { total: total, idle: idle }
        cpuCanvas.requestPaint()
        onMemSample(output)
        onProcessSample(output, dTotal)
    }

    // MemTotal/MemFree/Buffers/Cached (kB): "used" leaves out the buffers and
    // the page cache, as a task manager does, since the kernel gives those back.
    function onMemSample(output) {
        function kb(name) {
            var m = output.match(new RegExp("^" + name + ":\\s+(\\d+)", "m"))
            return m ? parseInt(m[1]) : -1
        }
        var total = kb("MemTotal"), free = kb("MemFree")
        if (total < 0 || free < 0) return
        memTotalKb = total
        memUsedKb = Math.max(0, total - free - Math.max(0, kb("Buffers")) - Math.max(0, kb("Cached")))
    }

    // One /proc/<pid>/stat per line: "pid (comm) state ppid ... utime stime ...".
    // comm may hold spaces and parentheses, so it is cut at the last ") ".
    // CPU is the process's share of the jiffies elapsed since the last tick, in
    // units of one core (a busy thread on a 4 core box reads 100 %, not 25 %).
    function onProcessSample(output, dTotal) {
        var list = [], now = {}
        output.split("\n").forEach(function(line) {
            var m = line.match(/^(\d+) \((.*)\) (\S) (.*)$/)
            if (!m) return
            var r = m[4].split(" ")                      // r[0] = ppid (field 4)
            var jiffies = parseInt(r[10]) + parseInt(r[11])    // utime + stime
            var pid = parseInt(m[1])
            now[pid] = jiffies
            var prev = procPrev[pid]
            var cpu = (prev !== undefined && dTotal > 0) ? 100 * cpuCores * (jiffies - prev) / dTotal : 0
            list.push({
                pid: pid, name: m[2], state: m[3],
                cpu: Math.max(0, cpu),
                rssKb: parseInt(r[20]) * 4,              // pages of 4 kB
                threads: parseInt(r[16])
            })
        })
        if (list.length === 0) return
        procPrev = now
        procSeen = true
        processes = list
    }

    function sortedProcesses() {
        var key = procSort
        var list = processes.filter(function(p) { return showKernelThreads || p.rssKb > 0 })
        list.sort(function(a, b) {
            if (key === "name") return a.name < b.name ? -1 : a.name > b.name ? 1 : a.pid - b.pid
            if (key === "pid") return a.pid - b.pid
            if (key === "mem") return b.rssKb - a.rssKb || a.pid - b.pid
            return b.cpu - a.cpu || b.rssKb - a.rssKb || a.pid - b.pid
        })
        return list
    }

    function resetCpuTrack() {
        cpuPrev = null
        cpuSamples = []
        cpuLoad = ""
        procPrev = ({})
        processes = []
        procSeen = false
        cpuCanvas.requestPaint()
    }

    function resetSystemInfo() {
        memTotalKb = -1; memUsedKb = -1
        diskTotalKb = -1; diskUsedKb = -1; diskPct = ""
    }

    Connections {
        target: SshManager

        function onKeysArchiveExportFinished(requestId, success, archivePath, aliasesFound, error) {
            if (requestId !== "export-keys") return
            exportKeysDialog.exportRunning = false
            if (success) {
                exportKeysDialog.exportPath = archivePath
                exportKeysDialog.exportAliases = aliasesFound
                exportKeysDialog.exportError = ""
            } else {
                exportKeysDialog.exportPath = ""
                exportKeysDialog.exportError = error || "Erreur inconnue"
            }
        }

        function onCommandFinished(requestId, success, output, error) {
            // Reboot-all results: don't toggle the global busy flag here; the
            // dialog tracks its own in-flight count and we want partial
            // results to keep streaming until the last one lands.
            if (requestId.indexOf("reboot-all-") === 0) {
                var mid = parseInt(requestId.substring("reboot-all-".length))
                rebootAllDialog.recordResult(mid, success, error)
                return
            }
            // Tracked polls run in the background: no spinner, no busy flag.
            if (requestId === "dmesg-track") {
                dmesgInFlight = false
                if (success && trackDmesg.checked) {
                    var html = ansiToHtml(output)
                    if (html !== lastDmesgText) {
                        lastDmesgText = html
                        dmesgArea.text = html
                        Qt.callLater(scrollDmesgToEnd)
                    }
                }
                return
            }
            if (requestId === "cpu-track") {
                cpuInFlight = false
                if (success && trackCpu.checked) onCpuSample(output)
                return
            }
            busy = false
            if (requestId === "disk-detail") {
                diskDetailArea.text = success ? parseDiskDetail(output) : ("Erreur: " + error)
                return
            }
            if (requestId === "system-info") {
                if (success) { onMemSample(output); onDfSample(output) }
            } else if (requestId === "dmesg") {
                dmesgArea.text = success ? ansiToHtml(output) : ansiToHtml("Erreur: " + error)
            } else if (requestId === "ls-playlists") {
                if (success) {
                    var lines = output.split("\n").filter(function(l) { return l.trim().length > 0 })
                    playlistsModel.clear()
                    for (var i = 0; i < lines.length; i++) {
                        playlistsModel.append({ name: lines[i] })
                    }
                    playlistStatus.text = lines.length + " playlist(s) trouvée(s)"
                } else {
                    playlistStatus.text = "Erreur: " + error
                }
            } else if (requestId === "reboot") {
                rebootStatus.text = success ? "Reboot envoyé." : ("Erreur: " + error)
            } else if (requestId.indexOf("ls-midi-") === 0) {
                var mid = parseInt(requestId.substring("ls-midi-".length))
                recordMidi(mid, success, output)
            }
        }
    }

    function onDfSample(output) {
        // BusyBox `df` (no -h, since old versions reject it) reports in 1k
        // blocks: "Filesystem  1024-blocks  Used  Available  Use%  Mounted on"
        var lines = output.split("\n")
        for (var i = 0; i < lines.length; i++) {
            if (!lines[i].match(/\s\/\s*$/)) continue
            var fields = lines[i].split(/\s+/).filter(function(f) { return f.length > 0 })
            if (fields.length < 5) continue
            var totalK = parseInt(fields[1]), usedK = parseInt(fields[2])
            if (isNaN(totalK) || isNaN(usedK)) continue
            diskTotalKb = totalK
            diskUsedKb = usedK
            diskPct = fields[4]
            return
        }
    }

    function humanKB(kb) {
        if (kb >= 1024 * 1024) return (kb / 1024 / 1024).toFixed(1) + " GB"
        if (kb >= 1024) return (kb / 1024).toFixed(1) + " MB"
        return kb + " KB"
    }

    function refreshSystemInfo() {
        busy = true
        // `df` (no path arg, no -h) for compat with BusyBox 1.00 on Artila:
        // `df /` there prints only the header — the actual rootfs row only
        // shows up when df is called without an argument. onDfSample
        // filters to the line mounted on "/", which is unambiguous on every
        // sample we have (Artila, Pi5, modern Linux). humanKB() turns the
        // 1k-blocks into a readable size.
        SshManager.executeCommand(currentMachine().id,
            "grep -E '^(MemTotal|MemFree|Buffers|Cached):' /proc/meminfo && df", "system-info")
    }

    // The kernel log carries ANSI colors (m_seq_sim's progress lines: ESC[<codes>m,
    // with 256-color 38;5;n, 24-bit 38;2;r;g;b and bold/dim): shown as rich
    // text, the other escapes dropped. The text is escaped first, then each SGR
    // sequence opens or closes a <span>.
    function xterm256(n) {
        var base = ["#000000", "#cd3131", "#0dbc79", "#e5e510", "#2472c8", "#bc3fbc", "#11a8cd", "#e5e5e5",
                    "#666666", "#f14c4c", "#23d18b", "#f5f543", "#3b8eea", "#d670d6", "#29b8db", "#ffffff"]
        if (n < 16) return base[n]
        if (n >= 232) { var g = 8 + (n - 232) * 10; return "rgb(" + g + "," + g + "," + g + ")" }
        n -= 16
        var lv = function(v) { return v === 0 ? 0 : 55 + v * 40 }
        return "rgb(" + lv(Math.floor(n / 36)) + "," + lv(Math.floor(n / 6) % 6) + "," + lv(n % 6) + ")"
    }

    function ansiToHtml(text) {
        var palette = { 30: "#777", 31: "#f55", 32: "#5f5", 33: "#fd5", 34: "#69f", 35: "#f7f", 36: "#5dd", 37: "#ccc" }
        var html = String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
        var open = false
        html = html.replace(/\x1b\[([0-9;]*)m/g, function(_, codes) {
            var style = ""
            var list = codes === "" ? [0] : codes.split(";").map(function(x) { return parseInt(x) })
            for (var i = 0; i < list.length; i++) {
                var c = list[i]
                if (c === 0) style = ""
                else if (c === 1) style += "font-weight:bold;"
                else if (c === 2) style += "color:#777;"
                else if ((c === 38 || c === 48) && list[i + 1] === 5 && i + 2 < list.length) {
                    if (c === 38) style += "color:" + xterm256(list[i + 2]) + ";"
                    i += 2
                }
                else if ((c === 38 || c === 48) && list[i + 1] === 2 && i + 4 < list.length) {
                    if (c === 38) style += "color:rgb(" + list[i + 2] + "," + list[i + 3] + "," + list[i + 4] + ");"
                    i += 4
                }
                else if (palette[c] !== undefined) style += "color:" + palette[c] + ";"
                else if (c >= 90 && c <= 97 && palette[c - 60] !== undefined) style += "color:" + palette[c - 60] + ";"
            }
            var out = open ? "</span>" : ""
            open = style !== ""
            return out + (open ? "<span style=\"" + style + "\">" : "")
        })
        html = html.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "")
        return "<pre style=\"margin:0\">" + html + (open ? "</span>" : "") + "</pre>"
    }

    // ---- Disk breakdown: where the space goes on the board, by kind. One ssh
    // command of `du -sk` and `ls -l` (BusyBox-safe: no -h, no --max-depth),
    // sorted and totalled here.
    function requestDiskDetail() {
        var id = currentMachine().id
        var w = MachinePaths.basePathFor(id).replace(/\/$/, "")     // .../WorkSpaceSirenes
        var home = w.replace(/\/WorkSpaceSirenes$/, "")
        var cmd = "H='" + home + "'; W='" + w + "';"
            + "echo '##df'; df;"
            + "echo '##home'; du -sk \"$H\" 2>/dev/null;"
            + "echo '##midi'; du -sk \"$W/Midi\" 2>/dev/null;"
            + "echo '##playlists'; du -sk \"$W/liste_de_lecture\" 2>/dev/null;"
            + "echo '##tmp'; du -sk /tmp 2>/dev/null;"
            + "echo '##log'; du -sk /var/log 2>/dev/null;"
            + "echo '##homefiles'; ls -l \"$H\" 2>/dev/null;"
            + "echo '##midifiles'; ls -l \"$W/Midi\" 2>/dev/null;"
            + "echo '##playlistfiles'; ls -l \"$W/liste_de_lecture\" 2>/dev/null"
        busy = true
        diskDetailArea.text = "..."
        SshManager.executeCommand(id, cmd, "disk-detail")
    }

    function parseDiskDetail(output) {
        var sec = {}, cur = ""
        output.split("\n").forEach(function(l) {
            var h = l.match(/^##(\w+)/)
            if (h) { cur = h[1]; sec[cur] = []; return }
            if (cur && l.trim().length > 0) sec[cur].push(l)
        })
        function du(name) {
            var l = (sec[name] || [])[0]
            var m = l ? l.match(/^(\d+)/) : null
            return m ? parseInt(m[1]) : -1
        }
        // Regular files of an `ls -l`: {name, kb (bytes/1024), exec}.
        function files(name) {
            var out = []
            ;(sec[name] || []).forEach(function(l) {
                if (l.charAt(0) !== "-") return
                var f = l.trim().split(/\s+/)
                if (f.length < 9) return
                out.push({ name: f.slice(8).join(" "), bytes: parseInt(f[4]), exec: f[0].indexOf("x") >= 0 })
            })
            return out
        }
        function bar(kb, total) {
            var n = total > 0 ? Math.max(kb > 0 ? 1 : 0, Math.round(20 * kb / total)) : 0
            return "█".repeat(n) + "·".repeat(20 - n)
        }
        function pct(kb, total) { return total > 0 ? (100 * kb / total).toFixed(0) + " %" : "" }
        function sum(list) { return list.reduce(function(a, f) { return a + f.bytes }, 0) / 1024 }
        function pad(t, n) { t = String(t); while (t.length < n) t += " "; return t }

        var home = du("home"), midi = du("midi"), lists = du("playlists")
        var homeFiles = files("homefiles")
        // Modules and objects, and executables without an extension (scripts such
        // as lance_taches): every file on the boards is rwx, so the mode is no clue.
        var binaries = homeFiles.filter(function(f) { return /\.(ko|o|so|bin|debianbuilt)$/.test(f.name) || (f.exec && f.name.indexOf(".") < 0) })
        var binKb = sum(binaries)
        var other = home >= 0 ? Math.max(0, home - Math.max(midi, 0) - Math.max(lists, 0) - binKb) : -1

        var t = ""
        t += "Systèmes de fichiers\n"
        ;(sec["df"] || []).slice(1).forEach(function(l) {
            var f = l.trim().split(/\s+/)
            if (f.length >= 6 && /^\d+$/.test(f[1]) && parseInt(f[1]) > 0)
                t += "  " + pad(f[5], 16) + humanKB(parseInt(f[2])) + " / " + humanKB(parseInt(f[1])) + "  (" + f[4] + ")\n"
        })
        t += "\nRépertoire personnel (" + (home >= 0 ? humanKB(home) : "?") + ")\n"
        function row(label, kb) {
            if (kb < 0) return "  " + pad(label, 26) + "?\n"
            return "  " + pad(label, 26) + bar(kb, home) + " " + pad(humanKB(kb), 10) + pct(kb, home) + "\n"
        }
        t += row("Fichiers MIDI", midi)
        t += row("Playlists", lists)
        t += row("Binaires / modules (.ko)", binKb)
        t += row("Autres (config, logs…)", other)
        var tmp = du("tmp"), log = du("log")
        if (tmp >= 0 || log >= 0)
            t += "\n  /tmp " + (tmp >= 0 ? humanKB(tmp) : "?") + "   /var/log " + (log >= 0 ? humanKB(log) : "?") + "  (mémoire vive)\n"

        function top(title, list, n) {
            if (list.length === 0) return ""
            var sorted = list.slice().sort(function(a, b) { return b.bytes - a.bytes })
            var out = "\n" + title + " (" + list.length + " fichiers, " + humanKB(sum(list)) + ")\n"
            sorted.slice(0, n).forEach(function(f) {
                out += "  " + pad(humanKB(f.bytes / 1024), 10) + f.name + "\n"
            })
            if (sorted.length > n) out += "  … " + (sorted.length - n) + " autres\n"
            return out
        }
        t += top("Binaires et modules", binaries, 8)
        t += top("Plus gros fichiers MIDI", files("midifiles"), 8)
        t += top("Playlists", files("playlistfiles"), 5)
        return t
    }

    function scrollDmesgToEnd() {
        var bar = dmesgScroll.ScrollBar.vertical
        if (bar) bar.position = 1.0 - bar.size
    }

    function refreshDmesg(filterErr) {
        busy = true
        dmesgArea.text = "Chargement..."
        var cmd = filterErr ? "dmesg -l err" : "dmesg | tail -200"
        SshManager.executeCommand(currentMachine().id, cmd, "dmesg")
    }

    function listPlaylists() {
        var p = MachinePaths.playlistPath(currentMachine().id)
        busy = true
        playlistStatus.text = "Chargement..."
        SshManager.executeCommand(currentMachine().id, "ls -1 " + p, "ls-playlists")
    }

    ListModel { id: playlistsModel }

    // MIDI cross-machine listing. Fires `ls -l Midi/` on every machine in
    // parallel, collects size + filename, then renders the Maître as
    // reference and tags the rest with ✓ (size match) / ⚠ (size differs) /
    // ✗ (missing) / + (extra not on Maître). Lets the user spot a stale
    // .mid sitting on one siren but not the others.
    property var midiByMachine: ({})
    property int midiInflight: 0
    function listAllMidi() {
        midiByMachine = {}
        midiInflight = machines.length
        midiStatus.text = "Listing " + machines.length + " machines…"
        midiArea.text = ""
        for (var i = 0; i < machines.length; i++) {
            var m = machines[i]
            var p = MachinePaths.midiPath(m.id)
            // `ls -l` (not `-la`) skips . and ..; the cd makes the absolute
            // path explicit in errors when Midi/ is missing on a siren.
            SshManager.executeCommand(m.id,
                "cd " + p + " && ls -l", "ls-midi-" + m.id)
        }
    }
    function recordMidi(machineId, success, output) {
        var entries = []
        if (success) {
            var lines = output.split("\n")
            for (var i = 0; i < lines.length; i++) {
                var line = lines[i].trim()
                if (!line || line.charAt(0) !== '-') continue
                var f = line.split(/\s+/)
                if (f.length < 9) continue
                // BusyBox ls -l: <perms> <links> <user> <group> <size>
                //                <month> <day> <time> <name…>
                entries.push({ name: f.slice(8).join(' '), size: parseInt(f[4]) })
            }
        }
        var copy = {}
        for (var k in midiByMachine) copy[k] = midiByMachine[k]
        copy[machineId] = entries
        midiByMachine = copy
        midiInflight = Math.max(0, midiInflight - 1)
        if (midiInflight === 0) renderMidi()
    }
    function renderMidi() {
        // Maître is id=0; treat its file set as canonical and annotate
        // others against it. Files only on a non-Maître show up tagged "+".
        var ref = midiByMachine[0] || []
        var refMap = {}
        for (var i = 0; i < ref.length; i++) refMap[ref[i].name] = ref[i].size

        var out = ""
        for (var i = 0; i < machines.length; i++) {
            var m = machines[i]
            var entries = midiByMachine[m.id] || []
            var label = (m.id === 0 ? " (référence)" : "")
            out += "=== " + m.name + label + " — " + entries.length + " fichier(s) ===\n"
            // Sort entries by name for consistent display.
            entries.sort(function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0 })
            for (var j = 0; j < entries.length; j++) {
                var e = entries[j]
                var sizeStr = ("         " + e.size).slice(-9)
                var tag = ""
                if (m.id === 0) {
                    tag = ""
                } else if (refMap.hasOwnProperty(e.name)) {
                    tag = (refMap[e.name] === e.size)
                            ? "  ✓"
                            : "  ⚠ (Maître: " + refMap[e.name] + ")"
                } else {
                    tag = "  + (absent du Maître)"
                }
                out += sizeStr + "  " + e.name + tag + "\n"
            }
            // For non-Maître machines, list files present on Maître but missing here.
            if (m.id !== 0 && ref.length > 0) {
                var present = {}
                for (var j = 0; j < entries.length; j++) present[entries[j].name] = true
                var missing = []
                for (var rname in refMap) if (!present[rname]) missing.push(rname)
                missing.sort()
                for (var k = 0; k < missing.length; k++) {
                    out += "         (absent)  " + missing[k] + "  ✗\n"
                }
            }
            out += "\n"
        }
        midiArea.text = out
        midiStatus.text = "Listing terminé"
    }

    Timer {
        interval: root.dmesgTrackMs
        repeat: true
        running: trackDmesg.checked && root.visible
        triggeredOnStart: true
        onTriggered: root.requestDmesgTrack()
    }
    Timer {
        interval: root.cpuTrackMs
        repeat: true
        running: trackCpu.checked && root.visible
        triggeredOnStart: true
        onTriggered: root.requestCpuTrack()
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 4
        spacing: 4

        // ==================== MACHINE SELECTOR ====================
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 40
            color: "#2a2a2a"; border.color: "#444"; radius: 4

            RowLayout {
                anchors.fill: parent
                anchors.margins: 4
                spacing: 10

                Label { text: "Machine:"; color: "#aaa"; font.pixelSize: 12 }
                ComboBox {
                    id: machineCombo
                    model: machines.map(function(m) { return m.name })
                    Layout.preferredWidth: 200
                    onCurrentIndexChanged: {
                        root.selectedMachineIdx = currentIndex
                        root.resetSystemInfo()
                        dmesgArea.text = ""
                        root.lastDmesgText = ""
                        diskDetailArea.text = ""
                        root.resetCpuTrack()
                        playlistsModel.clear()
                        playlistStatus.text = ""
                    }
                }

                BusyIndicator {
                    Layout.preferredWidth: 24
                    Layout.preferredHeight: 24
                    running: busy
                    visible: busy
                }

                Item { Layout.fillWidth: true }

                Button {
                    text: "Lister playlists + MIDI"
                    Layout.preferredHeight: 32
                    onClicked: { listPlaylists(); listAllMidi() }
                }
                Button {
                    text: "Exporter clés SSH"
                    Layout.preferredHeight: 32
                    onClicked: exportKeysDialog.open()
                }
                Button {
                    text: "Reboot"
                    Layout.preferredHeight: 32
                    onClicked: rebootDialog.open()
                }
                Button {
                    text: "Reboot all"
                    Layout.preferredHeight: 32
                    onClicked: rebootAllDialog.open()
                }
            }
        }

        // ==================== SYSTEM INFO ====================
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 26 + 62 + 190
            color: "#2a2a2a"; border.color: "#444"; radius: 4

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 2

                RowLayout {
                    Label { text: "ÉTAT SYSTÈME"; color: "#888"; font.pixelSize: 11; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "Rafraîchir"
                        Layout.preferredHeight: 26
                        onClicked: refreshSystemInfo()
                    }
                }
                // The summary as a task manager gives it: one tile per resource.
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    GaugeTile {
                        Layout.fillWidth: true
                        title: "CPU"
                        accent: "#5ac878"
                        readonly property real last: root.cpuSamples.length > 0 ? root.cpuSamples[root.cpuSamples.length - 1] : -1
                        fraction: last < 0 ? -1 : last / 100
                        value: last < 0 ? "—" : last.toFixed(0) + " %"
                        detail: !trackCpu.checked ? "cocher Suivre"
                                : root.cpuLoad.length > 0 ? root.cpuCores + " c.  charge " + root.cpuLoad
                                : root.cpuCores + " c."
                    }
                    GaugeTile {
                        Layout.fillWidth: true
                        title: "MÉMOIRE"
                        accent: "#5a9ae0"
                        fraction: root.memTotalKb > 0 && root.memUsedKb >= 0 ? root.memUsedKb / root.memTotalKb : -1
                        value: fraction < 0 ? "—" : (100 * fraction).toFixed(0) + " %"
                        detail: fraction < 0 ? "" : root.humanKB(root.memUsedKb) + " / " + root.humanKB(root.memTotalKb)
                    }
                    GaugeTile {
                        Layout.fillWidth: true
                        title: "DISQUE /"
                        accent: "#c78fe0"
                        fraction: root.diskTotalKb > 0 && root.diskUsedKb >= 0 ? root.diskUsedKb / root.diskTotalKb : -1
                        value: fraction < 0 ? "—" : root.diskPct
                        detail: fraction < 0 ? "" : root.humanKB(root.diskUsedKb) + " / " + root.humanKB(root.diskTotalKb)
                    }
                }

                // CPU plot and disk breakdown side by side, both resizable.
                StyledSplitView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    orientation: Qt.Horizontal

                // CPU history, as Activity Monitor draws it: 0-100 % against
                // time, newest on the right, a filled area under the line. The
                // plot takes the whole pane; the reading and the box float over
                // its top right corner.
                Rectangle {
                    SplitView.fillWidth: true
                    SplitView.minimumWidth: 200
                    color: "#111"; border.color: "#444"

                    Canvas {
                        id: cpuCanvas
                        anchors.fill: parent
                        onWidthChanged: requestPaint()
                        onHeightChanged: requestPaint()
                        onPaint: {
                            var ctx = getContext("2d")
                            var w = width, h = height
                            ctx.reset()
                            ctx.fillStyle = "#111"
                            ctx.fillRect(0, 0, w, h)
                            ctx.strokeStyle = "#333"
                            ctx.lineWidth = 1
                            ctx.beginPath()
                            for (var g = 1; g < 4; g++) {          // 25, 50, 75 %
                                var gy = Math.round(h * g / 4) + 0.5
                                ctx.moveTo(0, gy); ctx.lineTo(w, gy)
                            }
                            ctx.stroke()
                            var data = root.cpuSamples
                            if (data.length < 2) return
                            var step = w / (root.cpuHistory - 1)
                            var x0 = w - (data.length - 1) * step
                            function y(v) { return h - (v / 100) * (h - 2) - 1 }
                            ctx.beginPath()
                            ctx.moveTo(x0, h)
                            for (var i = 0; i < data.length; i++) ctx.lineTo(x0 + i * step, y(data[i]))
                            ctx.lineTo(w, h)
                            ctx.closePath()
                            ctx.fillStyle = "rgba(90, 200, 120, 0.30)"
                            ctx.fill()
                            ctx.beginPath()
                            for (var j = 0; j < data.length; j++) {
                                if (j === 0) ctx.moveTo(x0, y(data[0]))
                                else ctx.lineTo(x0 + j * step, y(data[j]))
                            }
                            ctx.strokeStyle = "#5ac878"
                            ctx.lineWidth = 1.5
                            ctx.stroke()
                        }
                    }

                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: 4
                        anchors.rightMargin: 4
                        width: cpuControls.implicitWidth + 12
                        height: cpuControls.implicitHeight + 6
                        radius: 5
                        color: "#d92a2a2a"; border.color: "#555"

                        RowLayout {
                            id: cpuControls
                            anchors.centerIn: parent
                            spacing: 8
                            Label {
                                text: !trackCpu.checked ? "CPU"
                                      : root.cpuSamples.length > 0
                                        ? "CPU " + root.cpuSamples[root.cpuSamples.length - 1].toFixed(0) + " %"
                                        : "CPU …"
                                color: "white"; font.pixelSize: 12; font.family: "Menlo"; font.bold: true
                            }
                            Label {
                                visible: trackCpu.checked && root.cpuLoad.length > 0
                                text: "charge " + root.cpuLoad
                                color: "#888"; font.pixelSize: 11; font.family: "Menlo"
                            }
                            CheckBox {
                                id: trackCpu
                                text: "Suivre"
                                Layout.preferredHeight: 24
                                padding: 0
                                onCheckedChanged: root.resetCpuTrack()
                            }
                        }
                    }
                }

                Rectangle {
                    SplitView.preferredWidth: 440
                    SplitView.minimumWidth: 200
                    color: "#111"; border.color: "#444"

                    ScrollView {
                        anchors.fill: parent
                        TextArea {
                            id: diskDetailArea
                            readOnly: true
                            color: "#ccc"
                            font.family: "Menlo"
                            font.pixelSize: 12
                            wrapMode: TextEdit.NoWrap
                            leftPadding: 6; topPadding: 4; rightPadding: 6; bottomPadding: 4
                            placeholderText: "Détail disque: MIDI, playlists, binaires"
                            background: null
                        }
                    }

                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: 4
                        anchors.rightMargin: 16
                        width: diskControls.implicitWidth + 12
                        height: diskControls.implicitHeight + 6
                        radius: 5
                        color: "#d92a2a2a"; border.color: "#555"

                        RowLayout {
                            id: diskControls
                            anchors.centerIn: parent
                            spacing: 8
                            Label { text: "DISQUE"; color: "#888"; font.pixelSize: 11; font.bold: true }
                            Button {
                                text: "Détail disque"
                                Layout.preferredHeight: 24
                                onClicked: root.requestDiskDetail()
                            }
                        }
                    }
                }

                // Processes, sorted as a task manager sorts them: click a column
                // title to change the key. Fed by the CPU tick, so it moves
                // with "Suivre" and costs no ssh session of its own.
                Rectangle {
                    SplitView.preferredWidth: 400
                    SplitView.minimumWidth: 220
                    color: "#111"; border.color: "#444"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 0
                        spacing: 0

                        Item { Layout.preferredHeight: 28 }       // under the floating label

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6; Layout.rightMargin: 16
                            spacing: 4
                            Repeater {
                                model: [
                                    { key: "pid",  label: "PID",  w: 44,  right: true  },
                                    { key: "name", label: "NOM",  w: -1,  right: false },
                                    { key: "cpu",  label: "CPU %", w: 52, right: true  },
                                    { key: "mem",  label: "MÉM",  w: 64,  right: true  }
                                ]
                                Text {
                                    Layout.preferredWidth: modelData.w
                                    Layout.fillWidth: modelData.w < 0
                                    horizontalAlignment: modelData.right ? Text.AlignRight : Text.AlignLeft
                                    text: modelData.label + (root.procSort === modelData.key ? (modelData.key === "pid" || modelData.key === "name" ? " ▲" : " ▼") : "")
                                    color: root.procSort === modelData.key ? "#ff9f1a" : "#888"
                                    font.pixelSize: 11; font.bold: true
                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.procSort = modelData.key
                                    }
                                }
                            }
                        }
                        Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: "#333" }

                        ListView {
                            id: procList
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            clip: true
                            model: root.procSeen ? root.sortedProcesses() : []
                            ScrollBar.vertical: ScrollBar {}

                            delegate: Rectangle {
                                width: ListView.view.width
                                height: 18
                                color: index % 2 ? "#161616" : "transparent"
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6; anchors.rightMargin: 16
                                    spacing: 4
                                    Text { Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight; text: modelData.pid; color: "#777"; font.pixelSize: 11; font.family: "Menlo" }
                                    Text { Layout.fillWidth: true; text: modelData.name; color: "#ddd"; font.pixelSize: 11; font.family: "Menlo"; elide: Text.ElideRight }
                                    Text {
                                        Layout.preferredWidth: 52; horizontalAlignment: Text.AlignRight
                                        text: modelData.cpu.toFixed(1)
                                        color: modelData.cpu >= 50 ? "#e05555" : modelData.cpu >= 10 ? "#e0a030" : modelData.cpu > 0 ? "#5ac878" : "#666"
                                        font.pixelSize: 11; font.family: "Menlo"
                                    }
                                    Text { Layout.preferredWidth: 64; horizontalAlignment: Text.AlignRight; text: root.humanKB(modelData.rssKb); color: "#9ab"; font.pixelSize: 11; font.family: "Menlo" }
                                }
                            }
                        }

                        Text {
                            visible: !root.procSeen
                            Layout.fillWidth: true
                            Layout.margins: 8
                            text: trackCpu.checked ? "Lecture des processus…" : "Cocher « Suivre » (CPU) pour lister les processus"
                            color: "#777"; font.pixelSize: 11
                            wrapMode: Text.Wrap
                        }
                    }

                    Rectangle {
                        anchors.top: parent.top
                        anchors.right: parent.right
                        anchors.topMargin: 4
                        anchors.rightMargin: 16
                        width: procControls.implicitWidth + 12
                        height: procControls.implicitHeight + 6
                        radius: 5
                        color: "#d92a2a2a"; border.color: "#555"

                        RowLayout {
                            id: procControls
                            anchors.centerIn: parent
                            spacing: 8
                            Label {
                                text: "PROCESSUS" + (root.procSeen ? " " + procList.count + " / " + root.processes.length : "")
                                color: "#888"; font.pixelSize: 11; font.bold: true
                            }
                            CheckBox {
                                text: "Noyau"
                                Layout.preferredHeight: 24
                                padding: 0
                                checked: root.showKernelThreads
                                onToggled: root.showKernelThreads = checked
                            }
                        }
                    }
                }
                }
            }
        }

        // ========= DMESG / PLAYLISTS / MIDI (redimensionnables) =========
        // SplitView vertical : l'utilisateur répartit la hauteur entre les
        // trois panneaux à contenu long. dmesg (lignes noyau longues, NoWrap)
        // prend la part par défaut ; les poignées permettent de l'agrandir
        // quand la fenêtre est trop courte pour tout afficher.
        StyledSplitView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: Qt.Vertical

        // ==================== DMESG ====================
        // The console takes the whole pane; the label and controls float over
        // its top right corner (clear of the scrollbar).
        Rectangle {
            SplitView.fillHeight: true
            SplitView.minimumHeight: 120
            color: "#111"; border.color: "#444"

            ScrollView {
                id: dmesgScroll
                anchors.fill: parent
                TextArea {
                    id: dmesgArea
                    readOnly: true
                    textFormat: TextEdit.RichText
                    text: ""
                    color: "#ccc"
                    font.family: "Menlo"
                    font.pixelSize: 11
                    wrapMode: TextEdit.NoWrap
                    leftPadding: 6; topPadding: 4; rightPadding: 6; bottomPadding: 4
                    background: null
                }
            }

            Rectangle {
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.topMargin: 4
                anchors.rightMargin: 16
                width: dmesgControls.implicitWidth + 12
                height: dmesgControls.implicitHeight + 6
                radius: 5
                color: "#d92a2a2a"; border.color: "#555"

                RowLayout {
                    id: dmesgControls
                    anchors.centerIn: parent
                    spacing: 6
                    Label { text: "DMESG"; color: "#888"; font.pixelSize: 11; font.bold: true }
                    CheckBox {
                        id: trackDmesg
                        text: "Suivre"
                        Layout.preferredHeight: 24
                        padding: 0
                        onCheckedChanged: if (checked) root.lastDmesgText = ""
                    }
                    Button { text: "Tout";    Layout.preferredHeight: 24; onClicked: refreshDmesg(false) }
                    Button { text: "Erreurs"; Layout.preferredHeight: 24; onClicked: refreshDmesg(true)  }
                }
            }
        }

        // ==================== PLAYLISTS | MIDI, side by side ====================
        StyledSplitView {
            SplitView.preferredHeight: 240
            SplitView.minimumHeight: 70
            orientation: Qt.Horizontal

        // ==================== PLAYLISTS ====================
        Rectangle {
            SplitView.preferredWidth: 280
            SplitView.minimumWidth: 140
            color: "#2a2a2a"; border.color: "#444"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 3

                RowLayout {
                    Label { text: "PLAYLISTS DISTANTES"; color: "#888"; font.pixelSize: 11; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Label { id: playlistStatus; text: ""; color: "#777"; font.pixelSize: 10 }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    ListView {
                        model: playlistsModel
                        delegate: Rectangle {
                            width: ListView.view.width
                            height: 22
                            color: "transparent"
                            Label {
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.left: parent.left
                                anchors.leftMargin: 8
                                text: name
                                color: "#ccc"
                                font.family: "Menlo"
                                font.pixelSize: 12
                            }
                        }
                    }
                }
            }
        }

        // ==================== MIDI DISTANTS ====================
        Rectangle {
            SplitView.fillWidth: true
            SplitView.minimumWidth: 200
            color: "#2a2a2a"; border.color: "#444"

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 6
                spacing: 3

                RowLayout {
                    Label { text: "MIDI DISTANTS"; color: "#888"; font.pixelSize: 11; font.bold: true }
                    Item { Layout.fillWidth: true }
                    Label { id: midiStatus; text: ""; color: "#777"; font.pixelSize: 10 }
                }

                ScrollView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    TextArea {
                        id: midiArea
                        readOnly: true
                        text: ""
                        color: "#ccc"
                        font.family: "Menlo"
                        font.pixelSize: 11
                        wrapMode: TextEdit.NoWrap
                        background: Rectangle { color: "#111" }
                    }
                }
            }
        }
        } // StyledSplitView (PLAYLISTS | MIDI)
        } // StyledSplitView (DMESG / PLAYLISTS + MIDI)
    }

    // ==================== EXPORT KEYS ARCHIVE ====================
    // Bundles ~/.ssh/id_rsa_sirenes(.pub) + Host blocks for the 13 siren
    // aliases + INSTALL.sh + README.txt into a tar.gz dropped in ~/Downloads/
    // on the BACKEND host. Lets the user clone SSH access onto a 2nd control
    // machine (the receiving machine runs the bundled INSTALL.sh, interactive,
    // POSIX sh, macOS 10.15+ / Linux compatible).
    Dialog {
        id: exportKeysDialog
        title: "Exporter les clés SSH"
        modal: true
        anchors.centerIn: parent
        closePolicy: Popup.NoAutoClose

        property bool exportStarted: false
        property bool exportRunning: false
        property string exportPath: ""
        property int exportAliases: 0
        property string exportError: ""

        onOpened: {
            exportStarted = false
            exportRunning = false
            exportPath = ""
            exportAliases = 0
            exportError = ""
        }

        contentItem: ColumnLayout {
            spacing: 8
            Layout.preferredWidth: 480

            Label {
                visible: !exportKeysDialog.exportStarted
                text: "Crée une archive tar.gz dans ~/Downloads/ contenant la clé privée " +
                      "id_rsa_sirenes, les Host alias des 13 sirènes, et un script INSTALL.sh " +
                      "interactif pour installer le tout sur une autre machine de contrôle."
                color: "white"
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: !exportKeysDialog.exportStarted
                text: "⚠ La clé privée donne un accès root à toutes les sirènes. Transférer via canal sûr (USB, scp, AirDrop), pas par email/Slack."
                color: "#FFA500"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }

            BusyIndicator {
                visible: exportKeysDialog.exportRunning
                running: exportKeysDialog.exportRunning
                Layout.alignment: Qt.AlignHCenter
            }

            Label {
                visible: exportKeysDialog.exportStarted && !exportKeysDialog.exportRunning && exportKeysDialog.exportPath.length > 0
                text: "✓ Archive créée\n\n" +
                      exportKeysDialog.exportPath +
                      "\n\n" + exportKeysDialog.exportAliases + " alias Host extraits."
                color: "white"
                font.family: "Menlo"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: exportKeysDialog.exportStarted && !exportKeysDialog.exportRunning && exportKeysDialog.exportError.length > 0
                text: "✗ Erreur: " + exportKeysDialog.exportError
                color: "#FF6666"
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
        }

        footer: DialogButtonBox {
            Button {
                text: "Annuler"
                visible: !exportKeysDialog.exportStarted
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
            }
            Button {
                text: "Exporter"
                visible: !exportKeysDialog.exportStarted
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
            Button {
                text: "Révéler dans le Finder"
                visible: exportKeysDialog.exportStarted && exportKeysDialog.exportPath.length > 0
                onClicked: {
                    // Open the parent dir in the system file browser. macOS
                    // Finder + Linux file managers both honor file:// URLs
                    // pointing at a directory.
                    var parent = exportKeysDialog.exportPath.replace(/\/[^/]+$/, "")
                    Qt.openUrlExternally("file://" + parent)
                }
                DialogButtonBox.buttonRole: DialogButtonBox.ActionRole
            }
            Button {
                text: "Fermer"
                visible: exportKeysDialog.exportStarted && !exportKeysDialog.exportRunning
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
        }

        onAccepted: {
            if (!exportStarted) {
                exportStarted = true
                exportRunning = true
                SshManager.exportKeysArchive("export-keys")
            } else {
                close()
            }
        }
        onRejected: close()
    }

    // ==================== REBOOT CONFIRMATION ====================
    Dialog {
        id: rebootDialog
        title: "Confirmer le reboot"
        modal: true
        anchors.centerIn: parent
        standardButtons: Dialog.Ok | Dialog.Cancel
        contentItem: ColumnLayout {
            spacing: 8
            Label {
                text: "Redémarrer " + currentMachine().name + " ?"
                color: "white"
            }
            Label {
                id: rebootStatus
                text: ""
                color: "#888"
                font.pixelSize: 11
            }
        }
        onAccepted: {
            rebootStatus.text = "Envoi en cours..."
            SshManager.executeCommand(currentMachine().id, "reboot", "reboot")
        }
    }

    // ==================== REBOOT ALL ====================
    // Fires `reboot` over SSH on every machine in parallel. Results stream
    // in via onCommandFinished — we treat "success=false, error=ssh closed"
    // as a reboot-actually-happened: the connection drops mid-command
    // because sshd dies during the reboot. So both true and false outcomes
    // are reported to the user but neither is a hard error here.
    Dialog {
        id: rebootAllDialog
        title: "Reboot de TOUTES les machines"
        modal: true
        anchors.centerIn: parent
        // Disable auto-close on Ok so the dialog stays up to show streaming
        // results. We swap the footer manually based on `rebootAllStarted`.
        closePolicy: Popup.NoAutoClose

        property int rebootAllInFlight: 0
        property bool rebootAllStarted: false
        // Per-machine result: id → { success: bool, error: string }
        property var rebootAllResults: ({})

        function recordResult(mid, success, error) {
            var copy = {}
            for (var k in rebootAllResults) copy[k] = rebootAllResults[k]
            copy[mid] = { success: success, error: error }
            rebootAllResults = copy
            rebootAllInFlight = Math.max(0, rebootAllInFlight - 1)
        }

        onOpened: {
            rebootAllStarted = false
            rebootAllInFlight = 0
            rebootAllResults = ({})
        }

        contentItem: ColumnLayout {
            spacing: 8
            Layout.preferredWidth: 460

            Label {
                text: rebootAllDialog.rebootAllStarted
                      ? (rebootAllDialog.rebootAllInFlight > 0
                         ? ("Reboot en cours… " + rebootAllDialog.rebootAllInFlight + " machine(s) en attente")
                         : "Reboot envoyé sur toutes les machines.")
                      : "Redémarrer les " + machines.length + " machines en parallèle ?"
                color: "white"
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Label {
                visible: !rebootAllDialog.rebootAllStarted
                text: "Le SSH se ferme dès qu'une machine reboot — un échec de connexion = reboot quand même parti."
                color: "#FFA500"
                font.pixelSize: 11
                wrapMode: Text.Wrap
                Layout.fillWidth: true
            }
            Repeater {
                model: rebootAllDialog.rebootAllStarted ? machines : []
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 8
                    Label {
                        text: modelData.name
                        color: "#ccc"
                        Layout.preferredWidth: 140
                    }
                    Label {
                        property var res: rebootAllDialog.rebootAllResults[modelData.id]
                        text: res === undefined ? "…"
                              : (res.success ? "✓ envoyé"
                                             : "↺ reboot parti (ssh fermé : " + (res.error || "?") + ")")
                        color: res === undefined ? "#888" : (res.success ? "#33CC33" : "#FFA500")
                        font.pixelSize: 11
                        Layout.fillWidth: true
                    }
                }
            }
        }

        footer: DialogButtonBox {
            Button {
                text: "Annuler"
                visible: !rebootAllDialog.rebootAllStarted
                DialogButtonBox.buttonRole: DialogButtonBox.RejectRole
            }
            Button {
                text: "Reboot all"
                visible: !rebootAllDialog.rebootAllStarted
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
            Button {
                text: rebootAllDialog.rebootAllInFlight > 0 ? "Patienter…" : "Fermer"
                enabled: rebootAllDialog.rebootAllInFlight === 0
                visible: rebootAllDialog.rebootAllStarted
                DialogButtonBox.buttonRole: DialogButtonBox.AcceptRole
            }
        }

        onAccepted: {
            if (!rebootAllStarted) {
                rebootAllStarted = true
                rebootAllInFlight = machines.length
                for (var i = 0; i < machines.length; i++) {
                    SshManager.executeCommand(machines[i].id, "reboot", "reboot-all-" + machines[i].id)
                }
            } else {
                close()
            }
        }
        onRejected: close()
    }
}
