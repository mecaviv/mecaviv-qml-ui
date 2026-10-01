import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import SirenManager
import "../controllers/MachinePaths.js" as MachinePaths
import "../components"

Rectangle {
    id: root
    color: "#1e1e1e"

    // Tooltip texts, one "key;text" per line in data/system_tooltips.csv
    // ("\n" in the text is a line break, kept short so the tooltip stays narrow).
    property var tips: ({})
    function tip(key) { return tips[key] || "" }

    // The memory and disk tiles fill themselves the first time the tab shows.
    onVisibleChanged: if (visible && memTotalKb < 0) refreshSystemInfo()
    Component.onCompleted: {
        loadHistory()
        if (visible) Qt.callLater(refreshSystemInfo)         // the tab was restored as the current one
        var xhr = new XMLHttpRequest()
        xhr.onreadystatechange = function() {
            if (xhr.readyState !== XMLHttpRequest.DONE) return
            var t = {}
            xhr.responseText.split("\n").forEach(function(line) {
                var i = line.indexOf(";")
                if (i > 0 && line.charAt(0) !== "#")
                    t[line.slice(0, i).trim()] = line.slice(i + 1).trim().replace(/\\n/g, "\n")
            })
            root.tips = t
        }
        xhr.open("GET", Qt.resolvedUrl("../data/system_tooltips.csv"))
        xhr.send()
    }

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
    readonly property int cpuTrackMs: 5000
    readonly property int cpuHistory: 120         // samples kept in the plot (10 min at 5 s)
    property bool dmesgInFlight: false
    property bool cpuInFlight: false
    property string lastDmesgText: ""
    property string dmesgRaw: ""                  // what the board last gave (the ring is ~50 lines)
    property bool dmesgErrorsOnly: false          // "Erreurs": filtered here, not on the board
    readonly property int dmesgTail: 100
    // BusyBox 1.00's dmesg has no -l and the lines carry no level, so "errors"
    // means lines that read like one; the filter runs on the text we already hold.
    readonly property var dmesgErrorPattern: /error|fail|warn|oops|panic|bug:|segfault|unable|cannot/i
    property var cpuPrev: null                    // {total, idle} of the last /proc/stat
    property var cpuSamples: []                   // percent, oldest first
    property bool diskDetailLoaded: false         // the full detail replaced the filesystem summary
    property var memSamples: []                   // memory used, percent, one per tick
    property string cpuLoad: ""
    property int cpuCores: 1
    property var procPrev: ({})                   // pid -> jiffies (utime+stime) of the last tick
    property var processes: []                    // [{pid, name, state, cpu, rssKb, threads}]
    property string procSort: "cpu"               // cpu | mem | pid | name
    property bool showKernelThreads: false
    property bool pollProcesses: false            // read /proc/<pid> on each CPU tick (not remembered)
    property int procTick: 0
    property var procUsers: ({})                  // pid -> owner, from the last owner reads

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
        SshManager.executeCommand(currentMachine().id, "dmesg | tail -" + dmesgTail, "dmesg-track")
    }

    function requestCpuTrack() {
        if (cpuInFlight) return
        cpuInFlight = true
        // /proc/stat's cpu lines, the load averages, the memory counters and
        // one stat file per process: small /proc reads, no top/ps (BusyBox 1.00
        // on the Artila has neither the options nor the patience), so the
        // measurement barely loads the board it measures.
        // Without the process list the tick is three reads. With it: one stat file
        // per process, plus the owners (status files and passwd) every 12th tick;
        // a process that appears in between shows no owner until then.
        var cmd = "grep '^cpu' /proc/stat; cat /proc/loadavg; cat /proc/meminfo;"
        if (pollProcesses) {
            cmd += " cat /proc/[0-9]*/stat 2>/dev/null;"
            if (procTick % 12 === 0)
                cmd += " grep '^Uid:' /proc/[0-9]*/status 2>/dev/null; cat /etc/passwd 2>/dev/null"
            procTick++
        }
        SshManager.executeCommand(currentMachine().id, cmd, "cpu-track")
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
            var dropped = Math.max(0, next.length - cpuHistory)
            staleCount = Math.max(0, staleCount - dropped)                                  // the past scrolls out
            demoPad = Math.max(0, demoPad - dropped)
            cpuSamples = next.slice(-cpuHistory)
            lastSampleMs = Date.now()
        }
        cpuPrev = { total: total, idle: idle }
        onMemSample(output)
        if (memTotalKb > 0 && memUsedKb >= 0)
            memSamples = memSamples.concat([100 * memUsedKb / memTotalKb]).slice(-cpuHistory)
        if (dTotal > 0) saveHistory()
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
        // Owners: "/proc/<pid>/status:Uid:<uid>..." lines, named from /etc/passwd.
        var uidOf = {}, nameOf = {}, users = {}
        output.split("\n").forEach(function(line) {
            var u = line.match(/^\/proc\/(\d+)\/status:Uid:\s+(\d+)/)
            if (u) { uidOf[u[1]] = u[2]; return }
            var p = line.match(/^([^:\s]+):[^:]*:(\d+):\d+:/)
            if (p) nameOf[p[2]] = p[1]
        })
        for (var k in uidOf) users[k] = nameOf[uidOf[k]] || uidOf[k]
        var known = {}
        for (var k2 in procUsers) known[k2] = procUsers[k2]
        for (var k3 in users) known[k3] = users[k3]
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
                ppid: parseInt(r[0]),
                user: known[pid] !== undefined ? known[pid] : "",
                cpu: Math.max(0, cpu),
                rssKb: parseInt(r[20]) * 4,              // pages of 4 kB
                virtKb: Math.round(parseInt(r[19]) / 1024),
                threads: parseInt(r[16])
            })
        })
        if (list.length === 0) return
        var kept = {}
        list.forEach(function(p) { if (known[p.pid] !== undefined) kept[p.pid] = known[p.pid] })
        procUsers = kept
        procPrev = now
        procSeen = true
        processes = list
    }

    readonly property var procColumns: [
        { key: "user",  label: "USER",  w: 64,  right: false },
        { key: "pid",   label: "PID",   w: 46,  right: true  },
        { key: "ppid",  label: "PPID",  w: 46,  right: true  },
        { key: "name",  label: "NOM",   w: -1,  right: false },
        { key: "state", label: "ÉT.",   w: 26,  right: false },
        { key: "thr",   label: "THR",   w: 34,  right: true  },
        { key: "cpu",   label: "CPU %", w: 52,  right: true  },
        { key: "mem",   label: "MÉM",   w: 66,  right: true  },
        { key: "virt",  label: "VIRT",  w: 66,  right: true  }
    ]
    function procCell(p, key) {
        switch (key) {
        case "user": return p.user
        case "pid": return p.pid
        case "ppid": return p.ppid
        case "name": return p.name
        case "state": return p.state
        case "thr": return p.threads
        case "cpu": return p.cpu.toFixed(1)
        case "mem": return humanKB(p.rssKb)
        default: return humanKB(p.virtKb)
        }
    }
    function procColor(p, key) {
        switch (key) {
        case "user": return p.user === "root" ? "#e0a030" : "#8fc4ff"
        case "pid": case "ppid": return "#777"
        case "name": return "#ddd"
        case "state": return p.state === "R" ? "#5ac878" : (p.state === "D" || p.state === "Z") ? "#e05555" : p.state === "T" ? "#e0a030" : "#888"
        case "thr": return p.threads > 1 ? "#bbb" : "#666"
        case "cpu": return p.cpu >= 50 ? "#e05555" : p.cpu >= 10 ? "#e0a030" : p.cpu > 0 ? "#5ac878" : "#666"
        default: return "#9ab"
        }
    }
    function sortedProcesses() {
        var key = procSort
        var list = processes.filter(function(p) { return showKernelThreads || p.rssKb > 0 })
        list.sort(function(a, b) {
            if (key === "name") return a.name < b.name ? -1 : a.name > b.name ? 1 : a.pid - b.pid
            if (key === "user") return a.user < b.user ? -1 : a.user > b.user ? 1 : a.pid - b.pid
            if (key === "state") return a.state < b.state ? -1 : a.state > b.state ? 1 : a.pid - b.pid
            if (key === "pid") return a.pid - b.pid
            if (key === "ppid") return a.ppid - b.ppid || a.pid - b.pid
            if (key === "thr") return b.threads - a.threads || a.pid - b.pid
            if (key === "virt") return b.virtKb - a.virtKb || a.pid - b.pid
            if (key === "mem") return b.rssKb - a.rssKb || a.pid - b.pid
            return b.cpu - a.cpu || b.rssKb - a.rssKb || a.pid - b.pid
        })
        return list
    }

    // ---- plot history, kept across launches -------------------------------
    // The last samples of each machine are stored; on launch they come back as
    // "stale": dimmed, with a divider and the time of the last sample. New
    // samples append after them, so the divider scrolls left until it is out of
    // the window.
    property int staleCount: 0                    // leading samples that come from before
    property int demoPad: 0                       // of those, random ones added in a debug build (never saved)
    property double lastSampleMs: 0               // when the newest sample was taken
    property double staleMs: 0                    // when the last stale sample was taken
    readonly property string staleLabel: staleCount > 0 && staleMs > 0 ? "données de " + stampText(staleMs) : ""

    Settings {
        id: historyStore
        category: "SystemHistory"
        property string byMachine: "{}"           // {"<machine id>": {cpu: [...], mem: [...], t: ms}}
    }

    function stampText(ms) {
        var d = new Date(ms), now = new Date()
        return d.toDateString() === now.toDateString() ? Qt.formatDateTime(d, "HH:mm:ss")
                                                       : Qt.formatDateTime(d, "ddd d MMM HH:mm")
    }
    function saveHistory() {
        var all = {}
        try { all = JSON.parse(historyStore.byMachine) } catch (e) { all = {} }
        var round = function(v) { return Math.round(v * 10) / 10 }
        all[currentMachine().id] = { cpu: cpuSamples.slice(demoPad).map(round), mem: memSamples.slice(demoPad).map(round), t: lastSampleMs }
        historyStore.byMachine = JSON.stringify(all)
    }
    // A smooth random walk, to pad the plots of a debug build.
    function demoSeries(n, start, spread, lo, hi) {
        var out = [], x = start
        for (var i = 0; i < n; i++) {
            x = Math.max(lo, Math.min(hi, x + (Math.random() - 0.5) * spread))
            out.push(x)
        }
        return out
    }
    function loadHistory() {
        var all = {}
        try { all = JSON.parse(historyStore.byMachine) } catch (e) { all = {} }
        var h = all[currentMachine().id]
        var cpu = [], mem = []
        staleMs = 0; lastSampleMs = 0; demoPad = 0
        if (h && h.cpu && h.cpu.length > 0) {
            cpu = h.cpu.slice(-cpuHistory)
            mem = (h.mem || []).slice(-cpuHistory)
            staleMs = h.t || 0
            lastSampleMs = staleMs
        }
        if (isDebugBuild && cpu.length < cpuHistory) {
            var n = cpuHistory - cpu.length
            cpu = demoSeries(n, 25, 30, 2, 95).concat(cpu)
            mem = demoSeries(n, 9, 4, 3, 30).concat(mem)
            demoPad = n
            if (staleMs === 0) staleMs = Date.now() - cpuHistory * cpuTrackMs
        }
        cpuSamples = cpu
        memSamples = mem
        staleCount = cpu.length
    }
    // Following starts again: everything on the plot is now from before.
    function markStale() {
        staleCount = cpuSamples.length
        if (lastSampleMs > 0) staleMs = lastSampleMs
    }

    // What belongs to the running tracking only (the plots keep their history).
    function resetCpuTrack() {
        cpuPrev = null
        cpuLoad = ""
        procPrev = ({})
        processes = []
        procSeen = false
        procUsers = ({})
        procTick = 0
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

        function onBackendReply(requestId, success, bodyJson, error) {
            var parts = requestId.split(":")
            if (parts[0] === "fleet-scan" || parts[0] === "fleet-poll") {
                if (parseInt(parts[1]) === root.fleetGen) root.fleetReply(parts[0], parts[2], success, bodyJson, error)
                return
            }
            if (parts[0] !== "midi-scan" && parts[0] !== "midi-poll") return
            if (parseInt(parts[1]) !== root.midiGen) return                 // a cancelled run
            var body = success ? JSON.parse(bodyJson) : null
            if (parts[0] === "midi-scan") {
                if (!body) { playlistStatus.text = "MIDI : " + error; return }
                root.midiJob = body.jobId
                root.midiVia = body.via
                root.pollMidi()
            } else {
                root.midiPolling = false
                if (!body || body.error === "unknown job" && !body.lines) { root.midiJob = ""; return }
                root.takeMidiLines(body)
            }
        }

        function onBatchFinished(requestId, success, resultsJson, error) {
            if (requestId === "ls-midi-batch") onMidiBatch(success, resultsJson, error)
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
                if (success && trackDmesg.checked) { dmesgRaw = output; renderDmesg() }
                return
            }
            if (requestId === "cpu-track") {
                cpuInFlight = false
                if (success && trackCpu.checked) onCpuSample(output)
                return
            }
            busy = false
            if (requestId === "disk-detail") {
                diskDetailLoaded = success
                diskDetailArea.text = success ? parseDiskDetail(output) : ("Erreur: " + error)
                return
            }
            if (requestId === "system-info") {
                if (success) {
                    onMemSample(output); onDfSample(output)
                    if (!diskDetailLoaded) {
                        var all = output.split("\n"), at = all.findIndex(function(l) { return l.indexOf("Filesystem") === 0 })
                        if (at >= 0) diskDetailArea.text = "<pre style=\"margin:0\">" + fsSummary(all.slice(at)) + "</pre>"
                    }
                }
            } else if (requestId === "dmesg") {
                dmesgRaw = success ? output : "Erreur: " + error
                lastDmesgText = ""
                renderDmesg()
            } else if (requestId === "ls-playlists") {
                if (success) {
                    var pls = parsePlaylists(output)
                    playlists = pls
                    playlistStatus.text = pls.length + " playlist(s)"
                    requestMidiInfo(pls)
                } else {
                    playlistStatus.text = "Erreur: " + error
                }
            } else if (requestId === "reboot") {
                rebootStatus.text = success ? "Reboot envoyé." : ("Erreur: " + error)
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
        return Math.round(kb) + " KB"
    }

    // ---- shared text formatting (disk detail, MIDI listing) ----
    function esc(t) { return String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;") }
    function padR(t, n) { t = String(t); while (t.length < n) t += " "; return t }
    function padL(t, n) { t = String(t); while (t.length < n) t = " " + t; return t }
    function span(color, text) { return "<span style=\"color:" + color + "\">" + text + "</span>" }
    function fmtBytes(b) {
        if (b >= 1048576) return (b / 1048576).toFixed(1) + " MB"
        if (b >= 1024) return Math.round(b / 1024) + " KB"
        return b + " B"
    }
    // Size against the biggest of its list: cool for small, hot for large.
    function sizeColor(frac) {
        return frac >= 0.75 ? "#d98a7a" : frac >= 0.4 ? "#d4a85a" : frac >= 0.1 ? "#7fbf94" : "#6a8fa8"
    }
    function sizeBar(frac, n) {
        var k = frac > 0 ? Math.max(1, Math.round(n * frac)) : 0
        return "█".repeat(k) + "·".repeat(n - k)
    }
    function fileColor(name) {
        return /\.(ko|o|so|bin)$/.test(name) ? "#c78fe0"
             : /\.midi?$/i.test(name) ? "#8fc4ff"
             : /\.listlecture$/i.test(name) ? "#e0c070" : "#dddddd"
    }
    function heading(t) { return "<span style=\"color:#ff9f1a;font-weight:bold\">" + esc(t) + "</span>" }

    function refreshSystemInfo() {
        busy = true
        // `df` (no path arg, no -h) for compat with BusyBox 1.00 on Artila:
        // `df /` there prints only the header — the actual rootfs row only
        // shows up when df is called without an argument. onDfSample
        // filters to the line mounted on "/", which is unambiguous on every
        // sample we have (Artila, Pi5, modern Linux). humanKB() turns the
        // 1k-blocks into a readable size.
        SshManager.executeCommand(currentMachine().id,
            "cat /proc/meminfo; df", "system-info")
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

    // The filesystems, as the top of the disk summary: each mount with its
    // percentage and used / total first and the bar last, so a narrow pane cuts
    // the bar, not the figures (`df` lines, header first). The root's usage
    // (what the DISQUE tile used to show) sits in the pane's top line.
    function fsSummary(dfLines) {
        var rows = dfLines.slice(1).map(function(l) { return l.trim().split(/\s+/) }).filter(function(f) {
            return f.length >= 6 && /^\d+$/.test(f[1]) && parseInt(f[1]) > 0
        })
        var t = heading("Systèmes de fichiers")
        t += "\n"
        rows.forEach(function(f) {
            var frac = parseInt(f[2]) / parseInt(f[1])
            t += "  " + span("#8fc4ff", esc(padR(f[5], 12)))
               + span(sizeColor(frac), padL(f[4], 5)) + "  "
               + padL(humanKB(parseInt(f[2])), 9) + span("#777", " / ") + padR(humanKB(parseInt(f[1])), 9) + " "
               + span(sizeColor(frac), sizeBar(frac, 16)) + "\n"
        })
        return t
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
        function sum(list) { return list.reduce(function(a, f) { return a + f.bytes }, 0) / 1024 }

        var home = du("home"), midi = du("midi"), lists = du("playlists")
        var homeFiles = files("homefiles")
        // Modules and objects, and executables without an extension (scripts such
        // as lance_taches): every file on the boards is rwx, so the mode is no clue.
        var binaries = homeFiles.filter(function(f) { return /\.(ko|o|so|bin|debianbuilt)$/.test(f.name) || (f.exec && f.name.indexOf(".") < 0) })
        var binKb = sum(binaries)
        var other = home >= 0 ? Math.max(0, home - Math.max(midi, 0) - Math.max(lists, 0) - binKb) : -1

        // Columns, in a <pre>: label 26 | bar 20 | size 9 | share 5.
        var t = fsSummary(sec["df"] || [])
        t += "\n" + heading("Répertoire personnel") + span("#9ab", "  " + (home >= 0 ? humanKB(home) : "?")) + "\n"
        function row(label, kb, color) {
            if (kb < 0) return "  " + span(color, esc(padR(label, 26))) + "?\n"
            var frac = home > 0 ? kb / home : 0
            return "  " + span(color, esc(padR(label, 26))) + span(sizeColor(frac), sizeBar(frac, 20)) + " "
                 + padL(humanKB(kb), 9) + span(sizeColor(frac), padL(home > 0 ? (100 * kb / home).toFixed(0) + " %" : "", 6)) + "\n"
        }
        t += row("Fichiers MIDI", midi, "#8fc4ff")
        t += row("Playlists", lists, "#e0c070")
        t += row("Binaires / modules (.ko)", binKb, "#c78fe0")
        t += row("Autres (config, logs…)", other, "#dddddd")
        var tmp = du("tmp"), log = du("log")
        if (tmp >= 0 || log >= 0)
            t += "\n  " + span("#888", "/tmp ") + (tmp >= 0 ? humanKB(tmp) : "?") + span("#888", "   /var/log ") + (log >= 0 ? humanKB(log) : "?") + span("#777", "  (mémoire vive)") + "\n"

        // Biggest files of a list: size, a bar against the biggest, then the name.
        function top(title, list, n) {
            if (list.length === 0) return ""
            var sorted = list.slice().sort(function(a, b) { return b.bytes - a.bytes })
            var max = sorted[0].bytes
            var out = "\n" + heading(title) + span("#777", "  " + list.length + " fichiers, " + humanKB(sum(list))) + "\n"
            sorted.slice(0, n).forEach(function(f) {
                var frac = max > 0 ? f.bytes / max : 0
                out += "  " + span(sizeColor(frac), padL(fmtBytes(f.bytes), 9) + " " + sizeBar(frac, 10)) + "  "
                     + span(fileColor(f.name), esc(f.name)) + "\n"
            })
            if (sorted.length > n) out += span("#777", "  … " + (sorted.length - n) + " autres") + "\n"
            return out
        }
        t += top("Binaires et modules", binaries, 8)
        t += top("Plus gros fichiers MIDI", files("midifiles"), 8)
        t += top("Playlists", files("playlistfiles"), 5)
        return "<pre style=\"margin:0\">" + t + "</pre>"
    }

    function scrollDmesgToEnd() {
        var bar = dmesgScroll.ScrollBar.vertical
        if (bar) bar.position = 1.0 - bar.size
    }

    function refreshDmesg() {
        busy = true
        dmesgArea.text = "Chargement..."
        SshManager.executeCommand(currentMachine().id, "dmesg | tail -" + dmesgTail, "dmesg")
    }

    // Shows the held text, filtered when "Erreurs" is chosen (no request needed).
    function renderDmesg() {
        var text = dmesgRaw
        if (dmesgErrorsOnly && !text.startsWith("Erreur:")) {
            text = text.split("\n").filter(function(l) { return dmesgErrorPattern.test(l) }).join("\n")
            if (text === "") text = "(aucune ligne d'erreur)"
        }
        var html = ansiToHtml(text)
        if (html === lastDmesgText) return
        lastDmesgText = html
        dmesgArea.text = html
        Qt.callLater(scrollDmesgToEnd)
    }
    function setDmesgFilter(errorsOnly) {
        dmesgErrorsOnly = errorsOnly
        if (dmesgRaw === "") refreshDmesg()
        else renderDmesg()
    }

    // One ssh round trip: every playlist file's content, then the pointer
    // (derniere_liste, "<string>/path/X.ListLecture</string>") naming the
    // active one. Playlist entries are {[n=slot][s=file][a=pseudo][B=loop][E=chain]}.
    function listPlaylists() {
        var p = MachinePaths.playlistPath(currentMachine().id)
        var ptr = MachinePaths.derniereListePath(currentMachine().id)
        busy = true
        playlistStatus.text = "Chargement..."
        SshManager.executeCommand(currentMachine().id,
            "cd " + p + " && for f in *; do [ -f \"$f\" ] && echo \"##pl $f\" && cat \"$f\" && echo; done;"
            + " echo '##active'; cat " + ptr + " 2>/dev/null", "ls-playlists")
    }

    function parsePlaylists(output) {
        var out = [], cur = null, active = ""
        var inActive = false
        output.split("\n").forEach(function(line) {
            if (line.indexOf("##pl ") === 0) {
                cur = { file: line.substring(5).trim(), content: "" }
                inActive = false
                out.push(cur)
            } else if (line.indexOf("##active") === 0) {
                cur = null; inActive = true
            } else if (inActive) {
                var m = line.match(/<string>([^<]+)<\/string>/)
                if (m) active = m[1].trim().split("/").pop()
            } else if (cur) {
                cur.content += line + "\n"
            }
        })
        var rx = /\{[^}]*\[n=(\d+)\][^}]*\[s=([^\]]*)\][^}]*\[a=([^\]]*)\][^}]*\[B=(\d)\][^}]*\[E=(\d)\][^}]*\}/g
        return out.filter(function(p) { return p.file !== "ALLLIST" }).map(function(p) {
            var entries = [], m
            rx.lastIndex = 0
            while ((m = rx.exec(p.content)) !== null)
                entries.push({ slot: parseInt(m[1]), file: m[2], pseudo: m[3], loop: m[4] === "1", chain: m[5] === "1" })
            entries.sort(function(x, y) { return x.slot - y.slot })
            return { name: p.file.replace(/\.ListLecture$/i, ""), active: p.file === active, entries: entries }
        })
    }

    property var playlists: []
    property var midiInfo: ({})               // MIDI file name -> what the file says (backend /api/midi/info)

    // MIDI facts come in gradually. The playlists name some files, many of them in
    // several playlists: each distinct file is asked about once. The backend runs a
    // job: readings it already holds (size and mtime unchanged) come first, the rest
    // are read on the board by midi-info-board (or through ssh on a Pi), one file at a
    // time with a pause in between, so the sequencer keeps the CPU. The job is polled;
    // each line fills its rows as it lands, and `midiReading` is the file being read.
    property int midiGen: 0                       // bumped to cancel a run (machine change, new listing)
    property string midiJob: ""                   // the running job's id
    property int midiNext: 0                      // result lines already taken
    property int midiTotal: 0                     // files in the run
    property var midiSeen: ({})                   // files that have answered
    property string midiReading: ""               // the file being read now
    property string midiVia: ""                   // "board" or "transfer"
    property var midiFailed: ({})                 // file -> why it could not be read
    property bool midiPolling: false
    readonly property int midiPauseMs: 1000       // after every file: low CPU matters more than speed

    function stopMidi() {
        if (midiJob !== "") SshManager.callBackend("/api/midi/scan/cancel", JSON.stringify({ jobId: midiJob }), "midi-cancel")
        midiGen++
        midiJob = ""; midiReading = ""; midiPolling = false
    }
    function requestMidiInfo(pls) {
        var seen = {}, files = []
        pls.forEach(function(p) { p.entries.forEach(function(e) {
            if (e.file && !seen[e.file]) { seen[e.file] = true; files.push(e.file) }
        }) })
        stopMidi()
        midiNext = 0; midiTotal = files.length; midiSeen = ({}); midiFailed = ({}); midiVia = ""
        if (files.length === 0) return
        var id = currentMachine().id
        SshManager.callBackend("/api/midi/scan",
            JSON.stringify({ machineType: id, dir: MachinePaths.midiPath(id), files: files, pauseMs: midiPauseMs }), "midi-scan:" + midiGen)
    }
    function mergeMidi(more) {
        var merged = {}
        for (var k in midiInfo) merged[k] = midiInfo[k]
        for (var n in more) merged[n] = more[n]
        midiInfo = merged
    }
    function pollMidi() {
        if (midiJob === "" || midiPolling) return
        midiPolling = true
        SshManager.callBackend("/api/midi/scan/poll", JSON.stringify({ jobId: midiJob, from: midiNext }), "midi-poll:" + midiGen)
    }
    // One poll answered: its lines go into the readings, the status line says where it is.
    function takeMidiLines(body) {
        var more = {}, failed = null, seen = null
        body.lines.forEach(function(l) {
            if (!seen) { seen = {}; for (var k in midiSeen) seen[k] = true }
            seen[l.file] = true
            if (l.info) {
                var i = l.info
                i.masterMatch = l.masterMatch              // undefined while the master is unknown
                more[l.file] = i
            } else {
                if (!failed) { failed = {}; for (var f in midiFailed) failed[f] = midiFailed[f] }
                failed[l.file] = l.error || "illisible"
            }
        })
        midiNext += body.lines.length
        if (seen) midiSeen = seen
        if (failed) midiFailed = failed
        mergeMidi(more)
        midiReading = body.current
        var done = Object.keys(midiSeen).length
        if (body.done) {
            midiJob = ""; midiReading = ""
            playlistStatus.text = body.error ? "MIDI : " + body.error : playlists.length + " playlist(s)"
        } else {
            playlistStatus.text = "MIDI " + (midiVia === "board" ? "(carte) " : "") + done + " / " + midiTotal
                                  + (body.current !== "" ? " · " + body.current : "")
        }
    }
    Timer {
        interval: 600; repeat: true
        running: root.midiJob !== "" && root.visible
        onTriggered: root.pollMidi()
    }

    function fmtDur(sec) {
        sec = Math.round(sec)
        var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60
        return h > 0 ? h + ":" + (m < 10 ? "0" : "") + m + ":" + (s < 10 ? "0" : "") + s
                     : m + ":" + (s < 10 ? "0" : "") + s
    }
    function fmtChannels(ch) {          // [1,2,3,4,10] -> "1-4,10"
        var out = [], i = 0
        while (i < ch.length) {
            var j = i
            while (j + 1 < ch.length && ch[j + 1] === ch[j] + 1) j++
            out.push(j - i >= 2 ? ch[i] + "-" + ch[j] : ch.slice(i, j + 1).join(","))
            i = j + 1
        }
        return out.join(",")
    }

    // Playlists with their MIDI facts and the text widths that fit them: each
    // column is as wide as its longest row, no wider.
    function buildPlaylistsView(pls, info, reading, failed, busyReading) {
        var maxDur = 1
        pls.forEach(function(p) { p.entries.forEach(function(e) {
            var i = info[e.file]; if (i && i.durationSec) maxDur = Math.max(maxDur, i.durationSec)
        }) })
        return pls.map(function(p) {
            var total = 0, known = 0
            var rows = p.entries.map(function(e) {
                var i = info[e.file]
                var ok = i && i.durationSec !== undefined
                if (ok) { total += i.durationSec; known++ }
                var tip = e.file
                var state = ok ? "ok" : e.file === reading ? "reading" : failed[e.file] !== undefined ? "failed" : "pending"
                if (state === "reading") tip += "\nlecture en cours…"
                if (state === "failed") tip += "\nillisible : " + failed[e.file]
                var mark = "", markColor = "#888"
                if (ok && i.riskLevel > 0) {
                    // What the production C reader gives up on (m_seq/POSTMORTEM_SONG_END.md).
                    var what = []
                    if (i.riskMask & 1) what.push("changement de programme")
                    if (i.riskMask & 2) what.push("pression")
                    if (i.riskMask & 4) what.push("SysEx")
                    mark = "!"; markColor = i.riskLevel === 2 ? "#d98a7a" : "#d4a85a"
                    tip += i.riskLevel === 2 ? "\nne se charge pas avec le module de production : " : "\npiste tronquée avec le module de production : "
                    tip += what.join(", ")
                }
                if (ok && i.split) {
                    // A file cut by midi-split: its own hash, and the master it came from.
                    var sp = i.split
                    tip += "\ndécoupé : canal " + (sp.channel) + " · maître " + sp.masterSha.substring(0, 10) + "…"
                    if (sp.ownOk === false) { mark = "✗"; markColor = "#d98a7a"; tip += "\nfichier endommagé (somme de contrôle)" }
                    else if (i.masterMatch === true) { mark = "✓"; markColor = "#7fbf94"; tip += "\nidentique au maître (somme de contrôle valide)" }
                    else if (i.masterMatch === false) { mark = "⚠"; markColor = "#d4a85a"; tip += "\nle maître a changé depuis la découpe" }
                    else { mark = "·"; tip += "\nmaître pas encore comparé" + (sp.ownOk === true ? " (somme du fichier valide)" : "") }
                }
                if (ok) tip += "\n" + i.tracks + " pistes · " + i.notes + " notes · " + i.timeSig + " · " + i.ppq + " ppq"
                              + "\ncanaux " + fmtChannels(i.channels)
                              + (i.tempoChanges > 1 ? "\n" + i.tempoChanges + " changements de tempo" : "")
                return {
                    slot: e.slot, label: e.pseudo !== "" ? e.pseudo : e.file, loop: e.loop, chain: e.chain,
                    state: state, mark: mark, markColor: markColor,
                    dur: ok ? fmtDur(i.durationSec) : state === "reading" ? "…" : state === "failed" ? "✗" : "", durFrac: ok ? i.durationSec / maxDur : 0,
                    bpm: ok ? String(Math.round(i.bpm)) : "", ch: ok ? fmtChannels(i.channels) : "", tip: tip
                }
            })
            function w(key, reserve) { return Math.max(busyReading ? reserve : 0, rows.reduce(function(a, r) { return Math.max(a, String(r[key]).length) }, 0)) }
            return {
                name: p.name, active: p.active, count: rows.length,
                total: known > 0 ? fmtDur(total) + (known < rows.length ? "+" : "") : "",
                rows: rows, labelChars: w("label", 0), durChars: w("dur", 5), bpmChars: w("bpm", 3), chChars: w("ch", 8),
                markChars: rows.some(function(r) { return r.mark !== "" }) ? 2 : 0
            }
        })
    }
    readonly property var playlistsView: buildPlaylistsView(playlists, midiInfo, midiReading, midiFailed, midiJob !== "")
    TextMetrics { id: monoM; font.family: "Menlo"; font.pixelSize: 11; text: "0000000000" }
    readonly property real charW: monoM.advanceWidth / 10

    // Master actions: one click for every refresh / every live follow.
    function refreshAll() {
        refreshSystemInfo()
        requestDiskDetail()
        refreshDmesg()
        listPlaylists()
    }

    // MIDI cross-machine listing. Fires `ls -l Midi/` on every machine in
    // parallel, collects size + filename, then renders the Maître as
    // reference and tags the rest with ✓ (size match) / ⚠ (size differs) /
    // ✗ (missing) / + (extra not on Maître). Lets the user spot a stale
    // .mid sitting on one siren but not the others.
    property var midiByMachine: ({})
    property var midiDown: ({})              // machine id -> why it did not answer
    // `ls -l` (not `-la`) skips . and ..; the cd makes the absolute path explicit
    // in errors when Midi/ is missing on a siren. One batch request for all the
    // machines: the backend logs a single summary and skips unreachable boards.
    function listAllMidi() {
        midiByMachine = {}
        midiDown = {}
        busy = true
        midiStatus.text = "Listing " + machines.length + " machines…"
        midiArea.text = ""
        var items = machines.map(function(m) {
            return { machineType: m.id, command: "cd " + MachinePaths.midiPath(m.id) + " && ls -l" }
        })
        SshManager.executeBatch(JSON.stringify(items), "ls-midi-batch")
    }
    function onMidiBatch(success, resultsJson, error) {
        busy = false
        if (!success) {
            midiStatus.text = "Erreur: " + error
            return
        }
        var results = JSON.parse(resultsJson), byMachine = {}, down = {}
        results.forEach(function(r, i) {
            var id = machines[i].id
            if (!r.success) { down[id] = r.unreachable ? "injoignable" : (r.error || "erreur"); return }
            var entries = []
            r.output.split("\n").forEach(function(l) {
                var line = l.trim()
                if (!line || line.charAt(0) !== '-') return
                var f = line.split(/\s+/)
                if (f.length < 9) return
                // BusyBox ls -l: <perms> <links> <user> <group> <size>
                //                <month> <day> <time> <name…>
                entries.push({ name: f.slice(8).join(' '), size: parseInt(f[4]) })
            })
            byMachine[id] = entries
        })
        midiByMachine = byMachine
        midiDown = down
        renderMidi()
        startFleetScan()
    }

    // ---- what every machine's files say about themselves ---------------------------------
    // After the listing, each machine that answered gets a scan job (the Maitre first: its masters'
    // hashes are what the others are compared with). Each job reads the files on the board, at
    // low priority, one by one; the listing below fills in as lines arrive.
    property int fleetGen: 0
    property var fleet: ({})                    // machine id -> {job, next, done, inflight, current, via, byName, failed}
    property var fleetWaiting: []               // machine ids not started yet (they wait for the Maitre)
    readonly property int fleetPauseMs: 1000

    function midiNames(id) {
        return (midiByMachine[id] || []).map(function(e) { return e.name }).filter(function(n) { return /\.(midi?|MIDI?)$/.test(n) })
    }
    function startFleetScan() {
        fleetGen++
        fleet = ({})
        var ids = machines.map(function(m) { return m.id }).filter(function(id) { return midiByMachine[id] !== undefined })
        fleetWaiting = ids.filter(function(id) { return id !== 0 })
        if (midiByMachine[0] !== undefined) startFleetJob(0)
        else { var all = fleetWaiting; fleetWaiting = []; all.forEach(startFleetJob) }
    }
    function startFleetJob(id) {
        var names = midiNames(id)
        var st = {}
        for (var k in fleet) st[k] = fleet[k]
        st[id] = { job: "", next: 0, done: names.length === 0, inflight: false, current: "", via: "", byName: {}, failed: {} }
        fleet = st
        if (names.length === 0) { renderMidi(); return }
        SshManager.callBackend("/api/midi/scan",
            JSON.stringify({ machineType: id, dir: MachinePaths.midiPath(id), files: names, pauseMs: fleetPauseMs }),
            "fleet-scan:" + fleetGen + ":" + id)
    }
    function pollFleet() {
        for (var k in fleet) {
            var m = fleet[k]
            if (m.job !== "" && !m.done && !m.inflight) {
                m.inflight = true
                SshManager.callBackend("/api/midi/scan/poll", JSON.stringify({ jobId: m.job, from: m.next }),
                                       "fleet-poll:" + fleetGen + ":" + k)
            }
        }
    }
    property int fleetRev: 0                    // bumped when a machine's state changed in place
    readonly property bool fleetActive: { fleetRev; return Object.keys(fleet).some(function(k) { return fleet[k].job !== "" && !fleet[k].done }) }
    Timer {
        interval: 800; repeat: true
        running: root.fleetActive && root.visible
        onTriggered: root.pollFleet()
    }
    function fleetReply(kind, id, success, bodyJson, error) {
        var m = fleet[id]
        if (!m) return
        var body = success ? JSON.parse(bodyJson) : null
        if (kind === "fleet-scan") {
            if (!body) { m.done = true; m.failed["*"] = error; fleetRev++; return }
            m.job = body.jobId; m.via = body.via
            pollFleet()
            return
        }
        m.inflight = false
        if (!body) { m.done = true; fleetRev++; return }
        body.lines.forEach(function(l) {
            if (l.info) m.byName[l.file] = { info: l.info, masterMatch: l.masterMatch }
            else m.failed[l.file] = l.error || "illisible"
        })
        m.next += body.lines.length
        m.current = body.current
        if (body.done) {
            m.done = true; m.current = ""
            if (id == 0 && fleetWaiting.length > 0) { var go = fleetWaiting; fleetWaiting = []; go.forEach(startFleetJob) }
        }
        fleetRev++                                    // tell the bindings
        renderMidi()
    }

    // The channel a siren plays (S1..S7 are the machines 2..8); unknown for the others.
    function expectedChannel(id) { return id >= 2 && id <= 8 ? id - 1 : 0 }

    // What a file on a machine is, against the Maitre's: [text, color, rank] (rank: 0 fine, 1 warn, 2 bad).
    function fileVerdict(id, name, size, refMap) {
        var scan = fleet[id] && fleet[id].byName[name]
        if (id === 0) {
            var i0 = scan && scan.info
            if (i0 && i0.riskLevel > 0)
                return [i0.riskLevel === 2 ? "! ne se charge pas (module de production)" : "! piste tronquée (module de production)", i0.riskLevel === 2 ? "#d98a7a" : "#d4a85a", 1]
            return ["", "#888", 0]
        }
        if (!refMap.hasOwnProperty(name)) return ["+ absent du Maître", "#8fc4ff", 1]
        if (!scan) {
            if (fleet[id] && fleet[id].failed[name] !== undefined) return ["? illisible", "#d98a7a", 2]
            return [fleet[id] && !fleet[id].done ? "…" : (refMap[name] === size ? "✓ (taille)" : "⚠ taille ≠ Maître"), "#888", 0]
        }
        var i = scan.info, sp = i.split
        if (sp) {
            if (sp.ownOk === false) return ["✗ endommagé", "#d98a7a", 2]
            if (scan.masterMatch === false) return ["⚠ le maître a changé", "#d4a85a", 1]
            var want = expectedChannel(id)
            if (want > 0 && sp.channel !== want) return ["⚠ canal " + sp.channel + " (attendu " + want + ")", "#d4a85a", 1]
            if (scan.masterMatch === true) return ["✓ découpé, canal " + sp.channel, "#7fbf94", 0]
            return ["· maître non comparé", "#888", 0]
        }
        if (scan.masterMatch === true) return ["✓ copie identique", "#7fbf94", 0]
        if (scan.masterMatch === false) return ["⚠ différent du Maître", "#d4a85a", 1]
        return ["· non comparé", "#888", 0]
    }

    function renderMidi() {
        // The Maitre (id 0) is the reference: its file set is canonical, the other machines are
        // judged against it (see fileVerdict). Files only on another machine are tagged "+".
        var ref = midiByMachine[0] || []
        var refMap = {}
        var maxSize = 1, maxName = 10
        for (var i = 0; i < ref.length; i++) refMap[ref[i].name] = ref[i].size
        for (var k in midiByMachine) midiByMachine[k].forEach(function(e) {
            maxSize = Math.max(maxSize, e.size); maxName = Math.max(maxName, e.name.length)
        })
        maxName = Math.min(maxName, 40)

        var out = ""
        for (var i = 0; i < machines.length; i++) {
            var m = machines[i]
            if (midiDown[m.id] !== undefined) {
                out += heading(m.name) + span("#e05555", " — " + midiDown[m.id]) + "\n\n"
                continue
            }
            var entries = (midiByMachine[m.id] || []).slice()
            entries.sort(function(a, b) { return a.name < b.name ? -1 : a.name > b.name ? 1 : 0 })
            var rows = "", counts = [0, 0, 0]
            for (var j = 0; j < entries.length; j++) {
                var e = entries[j]
                var frac = e.size / maxSize
                var v = fileVerdict(m.id, e.name, e.size, refMap)
                counts[v[2]]++
                rows += "  " + span(sizeColor(frac), padL(fmtBytes(e.size), 9)) + "  "
                      + span(v[2] === 0 ? "#dddddd" : v[1], esc(padR(e.name, maxName))) + "  " + span(v[1], esc(v[0])) + "\n"
            }
            // On the Maitre's list but not here.
            var gone = 0
            if (m.id !== 0 && ref.length > 0) {
                var present = {}
                for (var j = 0; j < entries.length; j++) present[entries[j].name] = true
                var missing = []
                for (var rname in refMap) if (!present[rname]) missing.push(rname)
                missing.sort()
                gone = missing.length
                for (var q = 0; q < missing.length; q++)
                    rows += "  " + span("#777", padL("absent", 9)) + "  " + span("#e05555", esc(padR(missing[q], maxName))) + "  " + span("#e05555", "✗ manquant") + "\n"
            }
            var f = fleet[m.id]
            var working = f && !f.done
            var summary = span("#777", " — " + entries.length + " fichier(s)")
            if (m.id !== 0 || ref.length > 0) {
                summary += (counts[1] > 0 ? "  " + span("#d4a85a", "⚠ " + counts[1]) : "")
                         + (counts[2] + gone > 0 ? "  " + span("#d98a7a", "✗ " + (counts[2] + gone)) : "")
            }
            if (working) summary += "  " + span("#ff9f1a", "lecture… " + f.current)
            out += heading(m.name + (m.id === 0 ? " (référence)" : "")) + summary + "\n" + rows + "\n"
        }
        midiArea.text = "<pre style=\"margin:0\">" + out + "</pre>"
        var downNames = machines.filter(function(m) { return midiDown[m.id] !== undefined }).map(function(m) { return m.name })
        midiStatus.text = (machines.length - downNames.length) + " / " + machines.length + " joignables"
                          + (downNames.length > 0 ? " — hors ligne : " + downNames.join(", ") : "")
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
                    ToolTip.visible: hovered && ToolTip.text.length > 0
                    ToolTip.delay: 600
                    ToolTip.text: root.tip("machine")
                    model: machines.map(function(m) { return m.name })
                    Layout.preferredWidth: 200
                    onCurrentIndexChanged: {
                        root.selectedMachineIdx = currentIndex
                        root.resetSystemInfo()
                        dmesgArea.text = ""
                        root.dmesgRaw = ""
                        root.lastDmesgText = ""
                        diskDetailArea.text = ""
                        root.diskDetailLoaded = false
                        root.resetCpuTrack()
                        root.loadHistory()
                        root.refreshSystemInfo()
                        root.playlists = []
                        root.stopMidi()
                        root.midiInfo = ({})
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
                    text: "Tout rafraîchir"
                    Layout.preferredHeight: 32
                    onClicked: refreshAll()
                    ToolTip.visible: hovered && ToolTip.text.length > 0
                    ToolTip.delay: 600
                    ToolTip.text: root.tip("refreshAll")
                }
                Button {
                    id: followAll
                    text: "Tout suivre"
                    Layout.preferredHeight: 32
                    checkable: true
                    checked: trackCpu.checked && trackDmesg.checked
                    onToggled: { var on = checked; trackCpu.checked = on; trackDmesg.checked = on; root.showKernelThreads = on; root.pollProcesses = on
                                 if (!on) { root.processes = []; root.procSeen = false } }
                    ToolTip.visible: hovered && ToolTip.text.length > 0
                    ToolTip.delay: 600
                    ToolTip.text: root.tip("followAll")
                }
                Button {
                    text: "Exporter clés SSH"
                    ToolTip.visible: hovered && ToolTip.text.length > 0
                    ToolTip.delay: 600
                    ToolTip.text: root.tip("exportKeys")
                    Layout.preferredHeight: 32
                    onClicked: exportKeysDialog.open()
                }
                Button {
                    text: "Reboot"
                    ToolTip.visible: hovered && ToolTip.text.length > 0
                    ToolTip.delay: 600
                    ToolTip.text: root.tip("reboot")
                    Layout.preferredHeight: 32
                    onClicked: rebootDialog.open()
                }
                Button {
                    text: "Reboot all"
                    ToolTip.visible: hovered && ToolTip.text.length > 0
                    ToolTip.delay: 600
                    ToolTip.text: root.tip("rebootAll")
                    Layout.preferredHeight: 32
                    onClicked: rebootAllDialog.open()
                }
            }
        }

        // System info and the lower panes share the height; the handle between them is draggable.
        StyledSplitView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            orientation: Qt.Vertical
            stateKey: "systemMain"

        // ==================== SYSTEM INFO ====================
        Rectangle {
            SplitView.fillWidth: true
            SplitView.preferredHeight: 26 + 190
            SplitView.minimumHeight: 120
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
                        ToolTip.visible: hovered && ToolTip.text.length > 0
                        ToolTip.delay: 600
                        ToolTip.text: root.tip("refresh")
                        Layout.preferredHeight: 26
                        onClicked: refreshSystemInfo()
                    }
                }
                // CPU plot and disk breakdown side by side, both resizable.
                StyledSplitView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    orientation: Qt.Horizontal
                    stateKey: "systemCpuDisk"

                // CPU and memory history, as Activity Monitor draws them: 0-100 %
                // against time, newest on the right. Two plots share the pane; each
                // reading and its controls float over the plot's top right corner.
                Rectangle {
                    SplitView.fillWidth: true
                    SplitView.minimumWidth: 200
                    color: "#111"; border.color: "#444"

                    ColumnLayout {
                        anchors.fill: parent
                        spacing: 1

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            SparkPlot {
                                id: cpuPlot
                                anchors.fill: parent
                                samples: root.cpuSamples
                                history: root.cpuHistory
                                staleCount: root.staleCount
                                staleLabel: root.staleLabel
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
                                color: "#c3ccd4"; font.pixelSize: 12; font.family: "Menlo"
                                HoverHandler { cursorShape: Qt.PointingHandCursor }
                                TapHandler { onTapped: trackCpu.checked = !trackCpu.checked }
                            }
                            Label {
                                visible: trackCpu.checked && root.cpuLoad.length > 0
                                text: root.cpuCores + " c.  charge " + root.cpuLoad
                                color: "#888"; font.pixelSize: 11; font.family: "Menlo"
                            }
                            CheckBox {
                                id: trackCpu
                                ToolTip.visible: hovered && ToolTip.text.length > 0
                                ToolTip.delay: 600
                                ToolTip.text: root.tip("trackCpu")
                                text: "Suivre"
                                Layout.preferredHeight: 24
                                padding: 0
                                onCheckedChanged: { root.resetCpuTrack(); if (checked) root.markStale() }
                            }
                        }
                    }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            SparkPlot {
                                anchors.fill: parent
                                samples: root.memSamples
                                history: root.cpuHistory
                                staleCount: root.staleCount
                                staleLabel: root.staleLabel
                            }

                            Rectangle {
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.topMargin: 4
                                anchors.rightMargin: 4
                                width: memLabel.implicitWidth + 12
                                height: memLabel.implicitHeight + 8
                                radius: 5
                                color: "#d92a2a2a"; border.color: "#555"
                                Label {
                                    id: memLabel
                                    anchors.centerIn: parent
                                    text: root.memTotalKb > 0 && root.memUsedKb >= 0
                                          ? "MÉM " + Math.round(100 * root.memUsedKb / root.memTotalKb) + " %   "
                                            + root.humanKB(root.memUsedKb) + " / " + root.humanKB(root.memTotalKb)
                                          : "MÉM"
                                    color: "#c3ccd4"; font.pixelSize: 12; font.family: "Menlo"
                                }
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
                            textFormat: TextEdit.RichText
                            color: "#ccc"
                            font.family: "Menlo"
                            font.pixelSize: 12
                            wrapMode: TextEdit.NoWrap
                            leftPadding: 6; topPadding: 32; rightPadding: 6; bottomPadding: 4     // below the floating controls
                            placeholderText: "Détail disque: MIDI, playlists, binaires"
                            background: null
                        }
                    }

                    // The root's usage, left aligned on the refresh button's line.
                    Label {
                        anchors.left: parent.left
                        anchors.leftMargin: 8
                        y: 4 + (diskControls.implicitHeight + 6 - height) / 2
                        textFormat: Text.RichText
                        font.pixelSize: 12; font.family: "Menlo"
                        text: {
                            if (root.diskTotalKb <= 0 || root.diskUsedKb < 0) return "<span style='color:#888'><b>DISQUE /</b></span>"
                            var frac = root.diskUsedKb / root.diskTotalKb
                            return "<span style='color:#888'><b>DISQUE /</b></span>  <b><span style='color:" + root.sizeColor(frac) + "'>"
                                   + root.diskPct + "</span></b>  <span style='color:#9ab'>"
                                   + root.humanKB(root.diskUsedKb) + " / " + root.humanKB(root.diskTotalKb) + "</span>"
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
                            Button {
                                text: "↻"
                                Accessible.name: "Rafraîchir le détail disque"
                                font.pixelSize: 15
                                Layout.preferredWidth: 28
                                ToolTip.visible: hovered && ToolTip.text.length > 0
                                ToolTip.delay: 600
                                ToolTip.text: root.tip("diskDetail")
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
                    SplitView.preferredWidth: 560
                    SplitView.minimumWidth: 300
                    color: "#111"; border.color: "#444"

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 0
                        spacing: 0

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6; Layout.rightMargin: 6
                            Layout.preferredHeight: 28
                            spacing: 8
                            Label {
                                text: "PROCESSUS" + (root.procSeen ? "  " + procList.count + " / " + root.processes.length : "")
                                color: "#888"; font.pixelSize: 11; font.bold: true
                            }
                            Item { Layout.fillWidth: true }
                            CheckBox {
                                text: "Lecture"
                                ToolTip.visible: hovered && ToolTip.text.length > 0
                                ToolTip.delay: 600
                                ToolTip.text: root.tip("pollProcs")
                                Layout.preferredHeight: 24
                                padding: 0
                                checked: root.pollProcesses
                                onToggled: { root.pollProcesses = checked; if (!checked) { root.processes = []; root.procSeen = false } }
                            }
                            CheckBox {
                                text: "Noyau"
                                ToolTip.visible: hovered && ToolTip.text.length > 0
                                ToolTip.delay: 600
                                ToolTip.text: root.tip("kernelThreads")
                                Layout.preferredHeight: 24
                                padding: 0
                                checked: root.showKernelThreads
                                onToggled: root.showKernelThreads = checked
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.leftMargin: 6; Layout.rightMargin: 16
                            spacing: 4
                            Repeater {
                                model: root.procColumns
                                Text {
                                    Layout.preferredWidth: modelData.w
                                    Layout.fillWidth: modelData.w < 0
                                    horizontalAlignment: modelData.right ? Text.AlignRight : Text.AlignLeft
                                    text: modelData.label + (root.procSort === modelData.key
                                          ? (["pid", "ppid", "name", "user", "state"].indexOf(modelData.key) >= 0 ? " ▲" : " ▼") : "")
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
                                id: procRow
                                readonly property var p: modelData
                                width: ListView.view.width
                                height: 18
                                color: index % 2 ? "#161616" : "transparent"
                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6; anchors.rightMargin: 16
                                    spacing: 4
                                    Repeater {
                                        model: root.procColumns
                                        Text {
                                            Layout.preferredWidth: modelData.w
                                            Layout.fillWidth: modelData.w < 0
                                            horizontalAlignment: modelData.right ? Text.AlignRight : Text.AlignLeft
                                            text: root.procCell(procRow.p, modelData.key)
                                            color: root.procColor(procRow.p, modelData.key)
                                            font.pixelSize: 11; font.family: "Menlo"
                                            elide: Text.ElideRight
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            visible: !root.procSeen
                            Layout.fillWidth: true
                            Layout.margins: 8
                            text: !root.pollProcesses ? "Lecture des processus désactivée (case « Lecture »)"
                                  : trackCpu.checked ? "Lecture des processus…" : "Cocher « Suivre » (CPU) pour lister les processus"
                            color: "#777"; font.pixelSize: 11
                            wrapMode: Text.Wrap
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
            SplitView.fillWidth: true
            SplitView.fillHeight: true
            SplitView.minimumHeight: 150
            orientation: Qt.Vertical
            stateKey: "systemDmesg"

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
                    Label {
                        text: "DMESG"; color: "#888"; font.pixelSize: 11; font.bold: true
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: trackDmesg.checked = !trackDmesg.checked }
                    }
                    CheckBox {
                        id: trackDmesg
                        ToolTip.visible: hovered && ToolTip.text.length > 0
                        ToolTip.delay: 600
                        ToolTip.text: root.tip("trackDmesg")
                        text: "Suivre"
                        Layout.preferredHeight: 24
                        padding: 0
                        onCheckedChanged: if (checked) root.lastDmesgText = ""
                    }
                    SegmentedToggle {
                        model: ["Tout", "Erreurs"]
                        currentIndex: root.dmesgErrorsOnly ? 1 : 0
                        onActivated: function(index) { root.setDmesgFilter(index === 1) }
                        ToolTip.visible: tipHover.hovered && ToolTip.text.length > 0
                        ToolTip.delay: 600
                        ToolTip.text: root.tip("dmesgFilter")
                        HoverHandler { id: tipHover }
                    }
                    Button {
                        text: "↻"
                        Accessible.name: "Relire dmesg"
                        font.pixelSize: 15
                        Layout.preferredWidth: 28
                        Layout.preferredHeight: 24
                        onClicked: root.refreshDmesg()
                        ToolTip.visible: hovered && ToolTip.text.length > 0
                        ToolTip.delay: 600
                        ToolTip.text: root.tip("dmesgRefresh")
                    }
                }
            }
        }

        // ==================== PLAYLISTS + MIDI ====================
        // One pane, scrolling left to right: a column per playlist (scrolling
        // up/down when long), then the cross-machine MIDI listing. The list
        // button floats over the top right corner, as dmesg's controls do.
        Rectangle {
            SplitView.preferredHeight: 240
            SplitView.minimumHeight: 70
            color: "#2a2a2a"; border.color: "#444"

            Flickable {
                id: plFlick
                anchors.fill: parent
                anchors.margins: 6
                contentWidth: plRow.width
                contentHeight: height
                flickableDirection: Flickable.HorizontalFlick
                boundsBehavior: Flickable.StopAtBounds
                clip: true
                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }

                Row {
                    id: plRow
                    height: plFlick.height - 12
                    spacing: 6

                    Repeater {
                        model: root.playlistsView
                        delegate: Rectangle {
                            id: plBox
                            readonly property real cw: root.charW
                            readonly property real rowsW: cw * 2 + 6 + cw * modelData.labelChars
                                + (modelData.durChars > 0 ? 6 + cw * modelData.durChars : 0)
                                + (modelData.bpmChars > 0 ? 6 + cw * modelData.bpmChars : 0)
                                + (modelData.chChars > 0 ? 6 + cw * modelData.chChars : 0)
                                + (modelData.markChars > 0 ? 6 + cw * modelData.markChars : 0) + 6 + 20
                            // As wide as its longest row (or its title), no wider.
                            width: Math.max(plTitle.implicitWidth + 8, rowsW + 8 + 12)
                            height: plRow.height
                            color: "#1e1e1e"; border.color: modelData.active ? "#ff9f1a" : "#444"

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 4
                                spacing: 2
                                Label {
                                    id: plTitle
                                    Layout.fillWidth: true
                                    text: (modelData.active ? "★ " : "") + modelData.name + "  (" + modelData.count + ")"
                                          + (modelData.total !== "" ? "  ·  " + modelData.total : "")
                                    color: modelData.active ? "#ff9f1a" : "#9ab"
                                    font.pixelSize: 11; font.bold: true
                                    elide: Text.ElideRight
                                }
                                ListView {
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    clip: true
                                    model: modelData.rows
                                    boundsBehavior: Flickable.StopAtBounds
                                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                                    delegate: Item {
                                        id: plRowItem
                                        readonly property var r: modelData
                                        width: ListView.view.width; height: 20
                                        ToolTip.visible: hov.hovered
                                        ToolTip.delay: 600
                                        ToolTip.text: r.tip
                                        HoverHandler { id: hov }
                                        Row {
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 6
                                            Label { width: plBox.cw * 2; horizontalAlignment: Text.AlignRight; text: plRowItem.r.slot; color: "#777"; font.family: "Menlo"; font.pixelSize: 11 }
                                            Label { width: plBox.cw * plBox.modelDataChars("labelChars"); text: plRowItem.r.label; color: "#ddd"; font.family: "Menlo"; font.pixelSize: 11 }
                                            Label {
                                                visible: width > 0
                                                width: plBox.cw * plBox.modelDataChars("durChars"); horizontalAlignment: Text.AlignRight
                                                text: plRowItem.r.dur
                                                color: plRowItem.r.state === "reading" ? "#ff9f1a" : plRowItem.r.state === "failed" ? "#d98a7a" : root.sizeColor(plRowItem.r.durFrac); font.family: "Menlo"; font.pixelSize: 11
                                            }
                                            Label {
                                                visible: width > 0
                                                width: plBox.cw * plBox.modelDataChars("bpmChars"); horizontalAlignment: Text.AlignRight
                                                text: plRowItem.r.bpm; color: "#8fc4ff"; font.family: "Menlo"; font.pixelSize: 11
                                            }
                                            Label {
                                                visible: width > 0
                                                width: plBox.cw * plBox.modelDataChars("chChars")
                                                text: plRowItem.r.ch; color: "#c78fe0"; font.family: "Menlo"; font.pixelSize: 11
                                            }
                                            Label {
                                                visible: width > 0
                                                width: plBox.cw * plBox.modelDataChars("markChars")
                                                text: plRowItem.r.mark; color: plRowItem.r.markColor; font.pixelSize: 11
                                            }
                                            Label { width: 20; text: (plRowItem.r.loop ? "↻" : "") + (plRowItem.r.chain ? "⛓" : ""); color: "#5a9ae0"; font.pixelSize: 11 }
                                        }
                                    }
                                }
                            }

                            function modelDataChars(key) { return modelData[key] }
                        }
                    }

                    // MIDI files of every machine, compared with the Maître.
                    Rectangle {
                        width: 620; height: plRow.height
                        color: "#1e1e1e"; border.color: "#444"
                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 2
                            RowLayout {
                                Label { text: "MIDI DISTANTS"; color: "#9ab"; font.pixelSize: 11; font.bold: true }
                                Label { id: midiStatus; text: ""; color: "#777"; font.pixelSize: 10 }
                            }
                            ScrollView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                TextArea {
                                    id: midiArea
                                    readOnly: true
                                    textFormat: TextEdit.RichText
                                    color: "#ccc"
                                    font.family: "Menlo"
                                    font.pixelSize: 11
                                    wrapMode: TextEdit.NoWrap
                                    background: Rectangle { color: "#111" }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                anchors.top: parent.top; anchors.right: parent.right
                anchors.topMargin: 6; anchors.rightMargin: 14
                width: plOverlay.implicitWidth + 12; height: plOverlay.implicitHeight + 8
                color: "#cc2a2a2a"; radius: 4
                RowLayout {
                    id: plOverlay
                    anchors.centerIn: parent
                    spacing: 8
                    Label { id: playlistStatus; text: ""; color: "#777"; font.pixelSize: 10 }
                    Button {
                        text: "Lister playlists + MIDI"
                        Layout.preferredHeight: 24
                        onClicked: { listPlaylists(); listAllMidi() }
                        ToolTip.visible: hovered && ToolTip.text.length > 0
                        ToolTip.delay: 600
                        ToolTip.text: root.tip("listPlaylists")
                    }
                }
            }
        }
        } // StyledSplitView (DMESG / PLAYLISTS + MIDI)
        } // StyledSplitView (SYSTEM INFO / rest)
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
