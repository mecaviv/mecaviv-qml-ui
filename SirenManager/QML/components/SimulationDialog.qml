import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SirenManager

// The simulation chain, driven from here (backend /api/sim/*, which calls tap-viewer): the dev
// board runs m_seq_sim.ko (every siren's channel through the real sequencer), tap-viewer plays the
// tap on a virtual MIDI source, and ComposeSiren sounds it. The Player tab then starts songs on the
// board as usual.
//
// A window of its own, not a popup: it stays beside the main window (move it, resize it, keep
// working in the Player tab) and does not block anything. Starting is refused by the backend unless
// it runs with SIREN_ALLOW_SIM=1; the help section says how to restart it, in the shell of the
// developer's platform, with text that can be copied.
ApplicationWindow {
    id: win
    title: "Simulation du séquenceur"
    width: 760; height: 720
    minimumWidth: 560; minimumHeight: 420
    flags: Qt.Dialog | Qt.WindowTitleHint | Qt.WindowCloseButtonHint | Qt.WindowMinimizeButtonHint
    visible: false
    color: "#1e1e1e"

    property Window parentWindow: null            // the main window, for "go to the Player"
    property bool ownerVisible: true               // the view that owns this dialog is on screen
    property var sim: null                         // last /api/sim/status answer
    property bool working: false
    property string problem: ""
    property int shell: Qt.platform.os === "windows" ? 1 : 0          // 0 macOS / Linux, 1 PowerShell, 2 cmd
    property bool helpOpen: false

    readonly property bool running: sim !== null && sim.board.module === "m_seq_sim" && sim.tap.running
    readonly property var lines: sim ? sim.tap.lines : []
    readonly property bool needsHelp: sim !== null && (!sim.allowed || !sim.tap.tapViewerFound) || problem !== ""
    readonly property string board: sim && sim.boardAddress !== "" ? sim.boardAddress : "<adresse de la carte>"

    transientParent: parentWindow

    function open() { visible = true; raise(); requestActivate(); refresh() }
    function refresh() { SshManager.callBackend("/api/sim/status", "{}", "sim-status") }
    function act(what) {
        working = true; problem = ""
        SshManager.callBackend("/api/sim/" + what, "{}", "sim-" + what)
    }
    function goToPlayer() {
        if (parentWindow && parentWindow.showTab) { parentWindow.showTab(0); parentWindow.raise(); parentWindow.requestActivate() }
    }
    onNeedsHelpChanged: if (needsHelp) helpOpen = true

    Timer {
        interval: win.visible ? 2000 : 10000
        repeat: true
        running: win.ownerVisible && !win.working
        onTriggered: win.refresh()
    }

    Connections {
        target: SshManager
        function onBackendReply(requestId, success, bodyJson, error) {
            if (requestId.indexOf("sim-") !== 0) return
            win.working = false
            var body = bodyJson ? JSON.parse(bodyJson) : null
            if (success && body && body.sim) win.sim = body.sim
            if (requestId === "sim-status") {
                if (!success) win.problem = (body && body.error) || error || "le backend ne répond pas"
                else if (win.problem === "le backend ne répond pas") win.problem = ""
            } else {
                win.problem = success ? "" : ((body && body.error) || error || "pas de réponse")
            }
        }
    }

    // ---- what to show -----------------------------------------------------------------
    function dspText() {
        for (var i = 0; i < lines.length; i++) {
            var m = lines[i].match(/^ComposeSiren MIDI input: (.+?) \(port (\d+)\) now listens to the virtual source "(.+)"$/)
            if (m) return "ComposeSiren (" + m[1] + ", port " + m[2] + ") écoute la source « " + m[3] + " »"
            if (lines[i].indexOf("ComposeSiren MIDI input") === 0) return lines[i]
        }
        return ""
    }
    function progressLine() {
        for (var i = lines.length - 1; i >= 0; i--) if (lines[i].indexOf("♪") >= 0) return lines[i]
        return ""
    }
    function boardText() {
        if (!sim) return "…"
        var b = sim.board
        if (!b.reachable) return "injoignable : " + b.error
        var t = b.module === "m_seq_sim" ? "m_seq_sim : la simulation tourne" : "module " + b.module
        if (!b.master) t += " · n'est pas la maître (numero_sirene 10)"
        else if (b.module !== "m_seq_sim" && !b.simInstalled) t += " · m_seq_sim.ko absent de la carte"
        return t
    }
    function tapText() {
        if (!sim) return "…"
        if (!sim.tap.tapViewerFound) return "tap-viewer introuvable (voir le dépannage)"
        if (sim.tap.running) return "tap-viewer écoute le tap (UDP " + sim.tap.port + "), sortie MIDI : " + sim.tap.output
        if (sim.tap.orphans > 0) return "un ancien tap-viewer tourne encore (lancé avant un redémarrage du backend) : « Arrêter » le ferme"
        return "arrêté"
    }

    // ---- the commands, per shell --------------------------------------------------------------
    readonly property string repoPath: "SirenManager" + (shell === 0 ? "/" : "\\") + "backend" + (shell === 0 ? "/" : "\\") + "fsharpwebserver"
    readonly property string backendCommand:
        shell === 0 ? "SIREN_ALLOW_SIM=1 dotnet watch --non-interactive --project " + repoPath
      : shell === 1 ? "$env:SIREN_ALLOW_SIM = \"1\"; dotnet watch --non-interactive --project " + repoPath
                    : "set SIREN_ALLOW_SIM=1 && dotnet watch --non-interactive --project " + repoPath
    readonly property string viewerEnvCommand:
        shell === 0 ? "SIREN_TAP_VIEWER=/chemin/vers/tap-viewer"
      : shell === 1 ? "$env:SIREN_TAP_VIEWER = \"C:\\chemin\\vers\\tap-viewer.exe\""
                    : "set SIREN_TAP_VIEWER=C:\\chemin\\vers\\tap-viewer.exe"
    readonly property string midiPortCommand:
        shell === 0 ? "SIREN_TAP_PORT=\"IAC Driver Bus 1\""
      : shell === 1 ? "$env:SIREN_TAP_PORT = \"m_seq_sim\""
                    : "set SIREN_TAP_PORT=m_seq_sim"
    readonly property string restoreCommand: {
        var exe = sim && sim.tap.tapViewerPath !== "" ? sim.tap.tapViewerPath : "tap-viewer"
        var quoted = exe.indexOf(" ") >= 0 || shell !== 0 ? "\"" + exe + "\"" : exe
        return (shell === 1 && quoted.charAt(0) === "\"" ? "& " : "") + quoted + " sim down " + board
    }

    // ---- layout ------------------------------------------------------------------------
    ScrollView {
        id: scroll
        anchors.fill: parent
        anchors.margins: 14
        contentWidth: availableWidth
        clip: true

        ColumnLayout {
            width: scroll.availableWidth
            spacing: 14

            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#cfd8e0"
                text: "La carte de développement joue les morceaux avec le vrai séquenceur (m_seq_sim, tous les canaux), tap-viewer "
                      + "joue ce qu'elle envoie sur une source MIDI, ComposeSiren le fait entendre. Les commandes (Player) partent comme d'habitude."
            }

            // --- the chain
            GridLayout {
                columns: 3
                columnSpacing: 10; rowSpacing: 8
                Layout.fillWidth: true
                Repeater {
                    model: [
                        { label: "Carte", ok: win.sim !== null && win.sim.board.module === "m_seq_sim" && win.sim.board.reachable, text: win.boardText() },
                        { label: "Tap", ok: win.sim !== null && win.sim.tap.running, text: win.tapText() },
                        { label: "DSP", ok: win.dspText() !== "", text: win.dspText() !== "" ? win.dspText() : "ComposeSiren pas détecté (l'application doit tourner avec son serveur MCP)" }
                    ]
                    delegate: RowLayout {
                        Layout.columnSpan: 3
                        Layout.fillWidth: true
                        spacing: 10
                        Rectangle { width: 12; height: 12; radius: 6; color: modelData.ok ? "#7fbf94" : "#666"; Layout.alignment: Qt.AlignTop; Layout.topMargin: 3 }
                        Label { text: modelData.label; color: "#9ab"; font.bold: true; Layout.preferredWidth: 48; Layout.alignment: Qt.AlignTop }
                        Label { text: modelData.text; Layout.fillWidth: true; wrapMode: Text.Wrap; color: modelData.ok ? "#cfd8e0" : "#999" }
                    }
                }
            }

            // --- buttons
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Button {
                    text: "Démarrer la simulation"
                    enabled: !win.working && win.sim !== null && win.sim.allowed && !win.running
                    onClicked: win.act("start")
                }
                Button {
                    text: "Arrêter et restaurer la carte"
                    enabled: !win.working && win.sim !== null && win.sim.allowed
                             && (win.running || win.sim.board.module === "m_seq_sim" || win.sim.tap.running || win.sim.tap.orphans > 0)
                    onClicked: win.act("stop")
                }
                Button {
                    text: "Aller au Player ›"
                    enabled: win.running && win.parentWindow !== null
                    onClicked: win.goToPlayer()
                }
                BusyIndicator { running: win.working; visible: win.working; Layout.preferredWidth: 24; Layout.preferredHeight: 24 }
                Item { Layout.fillWidth: true }
            }

            // --- live line
            CopyBlock {
                visible: win.progressLine() !== ""
                Layout.fillWidth: true
                title: "En direct (tap-viewer)"
                text: win.progressLine()
            }

            // --- what to do
            Label {
                visible: win.running
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                color: "#7fbf94"
                text: "La simulation tourne. Dans le Player : choisir un morceau et le lancer, la carte le joue et ComposeSiren le fait entendre. "
                      + "Dans SYSTÈME, dmesg suit la séquence et le morceau en cours est marqué ▶ dans la playlist active. "
                      + "« Arrêter » remet le module m_seq sur la carte."
            }

            // --- problem
            CopyBlock {
                visible: win.problem !== ""
                Layout.fillWidth: true
                title: "Dernier message d'erreur"
                text: win.problem
            }

            // --- help
            Button {
                flat: true
                text: (win.helpOpen ? "▾" : "▸") + "  Dépannage : redémarrer le backend, tap-viewer, remettre la carte"
                onClicked: win.helpOpen = !win.helpOpen
            }
            ColumnLayout {
                visible: win.helpOpen
                Layout.fillWidth: true
                spacing: 12

                RowLayout {
                    spacing: 8
                    Label { text: "Votre shell :"; color: "#9ab" }
                    SegmentedToggle {
                        model: ["macOS / Linux", "PowerShell", "cmd"]
                        segmentWidth: 104
                        currentIndex: win.shell
                        onActivated: function(i) { win.shell = i }
                    }
                }

                Label {
                    visible: win.sim !== null && !win.sim.allowed
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    color: "#d4a85a"
                    text: "Le backend refuse de démarrer ou d'arrêter la simulation : elle change le module que fait tourner la carte, et l'application "
                          + "sert aussi en production. Arrêtez le backend (Ctrl+C dans son terminal) puis relancez-le avec la variable ci-dessous, "
                          + "depuis le dossier mecaviv-qml-ui."
                }
                CopyBlock {
                    Layout.fillWidth: true
                    title: "1. Lancer le backend avec la simulation autorisée"
                    hint: "À coller dans un terminal ouvert dans le dossier mecaviv-qml-ui (la variable ne vaut que pour ce terminal)."
                    text: win.backendCommand
                }
                CopyBlock {
                    Layout.fillWidth: true
                    title: "2. tap-viewer introuvable ? Le construire (une fois)"
                    hint: "Le backend le cherche dans firmwares-artila/tools/tap-viewer/target. Sinon, indiquer son chemin avec la variable plus bas."
                    text: "franz run tap-viewer -- midi --list"
                }
                CopyBlock {
                    Layout.fillWidth: true
                    title: "   ou indiquer où il se trouve"
                    text: win.viewerEnvCommand
                }
                CopyBlock {
                    Layout.fillWidth: true
                    title: "3. Sortie MIDI sans source virtuelle (Windows, ou un bus existant)"
                    hint: win.shell === 0
                          ? "Par défaut tap-viewer crée la source virtuelle « m_seq_sim ». Pour jouer sur un bus existant :"
                          : "Windows n'a pas de source MIDI virtuelle : créer un port avec loopMIDI nommé m_seq_sim, puis le désigner avant de lancer le backend :"
                    text: win.midiPortCommand
                }
                CopyBlock {
                    Layout.fillWidth: true
                    title: "4. Remettre la carte si le backend s'est arrêté en route"
                    hint: "Idempotent : sans effet si la carte fait déjà tourner m_seq. Les « arrêter » de cette fenêtre font la même chose."
                    text: win.restoreCommand
                }
            }

            Item { Layout.preferredHeight: 6 }
        }
    }
}
