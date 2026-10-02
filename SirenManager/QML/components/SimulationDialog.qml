import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import SirenManager

// The simulation chain, driven from here (backend /api/sim/*, which calls tap-viewer): the dev
// board runs m_seq_sim.ko (every siren's channel through the real sequencer), tap-viewer plays the
// tap on a virtual MIDI source, and ComposeSiren sounds it. The Player tab then starts songs on the
// board as usual. Starting is refused unless the backend runs with SIREN_ALLOW_SIM=1.
Dialog {
    id: dlg
    title: "Simulation : carte de dev → tap-viewer → ComposeSiren"
    modal: false
    width: 640
    closePolicy: Popup.CloseOnEscape

    property var sim: null                       // last /api/sim/status answer
    property bool working: false
    property string problem: ""
    readonly property bool running: sim !== null && sim.board.module === "m_seq_sim" && sim.tap.running
    readonly property var lines: sim ? sim.tap.lines : []

    function refresh() { SshManager.callBackend("/api/sim/status", "{}", "sim-status") }
    function act(what) {
        working = true; problem = ""
        SshManager.callBackend("/api/sim/" + what, "{}", "sim-" + what)
    }
    onOpened: refresh()
    Timer { interval: 2000; repeat: true; running: dlg.visible && !dlg.working; onTriggered: dlg.refresh() }

    Connections {
        target: SshManager
        function onBackendReply(requestId, success, bodyJson, error) {
            if (requestId.indexOf("sim-") !== 0) return
            dlg.working = false
            var body = bodyJson ? JSON.parse(bodyJson) : null
            if (success && body && body.sim) { dlg.sim = body.sim; if (requestId !== "sim-status") dlg.problem = "" }
            else dlg.problem = (body && body.error) || error || "pas de réponse"
        }
    }

    function dspLine() {
        for (var i = 0; i < lines.length; i++) if (lines[i].indexOf("ComposeSiren MIDI input") === 0) return lines[i].substring(24)
        return ""
    }
    function progressLine() {
        for (var i = lines.length - 1; i >= 0; i--) if (lines[i].indexOf("♪") >= 0) return lines[i]
        return ""
    }
    function chip(label, text, ok) { return { label: label, text: text, ok: ok } }

    contentItem: ColumnLayout {
        spacing: 10

        Label {
            visible: dlg.sim !== null && !dlg.sim.allowed
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: "#d4a85a"
            text: "Simulation désactivée : elle change le module que tourne la carte. Lancer le backend avec SIREN_ALLOW_SIM=1 (carte de dev seulement)."
        }

        GridLayout {
            columns: 2
            columnSpacing: 12; rowSpacing: 6
            Layout.fillWidth: true
            Repeater {
                model: dlg.sim === null ? [] : [
                    dlg.chip("Carte", !dlg.sim.board.reachable ? "injoignable"
                                      : dlg.sim.board.module + (dlg.sim.board.master ? "" : " · n'est pas la maître (numero_sirene 10)")
                                        + (dlg.sim.board.module !== "m_seq_sim" && !dlg.sim.board.simInstalled ? " · m_seq_sim.ko absent" : ""),
                             dlg.sim.board.reachable && dlg.sim.board.module === "m_seq_sim"),
                    dlg.chip("Tap", !dlg.sim.tap.tapViewerFound ? "tap-viewer absent : franz run tap-viewer -- midi --list"
                                    : dlg.sim.tap.running ? "tap-viewer écoute UDP " + dlg.sim.tap.port : "arrêté",
                             dlg.sim.tap.running),
                    dlg.chip("DSP", dlg.dspLine() !== "" ? dlg.dspLine() : "ComposeSiren non détecté (lancer l'application avec son serveur MCP)",
                             dlg.dspLine() !== "")
                ]
                delegate: RowLayout {
                    Layout.columnSpan: 2
                    spacing: 8
                    Rectangle { width: 10; height: 10; radius: 5; color: modelData.ok ? "#7fbf94" : "#888" }
                    Label { text: modelData.label; color: "#9ab"; font.bold: true; Layout.preferredWidth: 50 }
                    Label { text: modelData.text; color: modelData.ok ? "#cfd8e0" : "#999"; Layout.fillWidth: true; elide: Text.ElideRight }
                }
            }
        }

        Rectangle {
            visible: dlg.progressLine() !== ""
            Layout.fillWidth: true; implicitHeight: 28
            color: "#111"; border.color: "#444"; radius: 4
            Label {
                anchors.fill: parent; anchors.margins: 6
                text: dlg.progressLine(); elide: Text.ElideRight
                color: "#cfd8e0"; font.family: "Menlo"; font.pixelSize: 11
            }
        }

        Label {
            visible: dlg.problem !== ""
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: "#d98a7a"
            text: dlg.problem
        }

        Label {
            Layout.fillWidth: true
            wrapMode: Text.Wrap
            color: "#888"
            font.pixelSize: 11
            text: "Une fois démarrée : l'onglet Player lance un morceau, la carte le joue (tous les canaux), tap-viewer l'envoie à ComposeSiren. "
                  + "SYSTÈME suit la séquence dans dmesg et marque le morceau en cours ▶ dans la playlist active. "
                  + "Arrêter remet le module m_seq sur la carte."
        }

        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            BusyIndicator { running: dlg.working; visible: dlg.working; Layout.preferredWidth: 22; Layout.preferredHeight: 22 }
            Item { Layout.fillWidth: true }
            Button {
                text: "Démarrer la simulation"
                enabled: !dlg.working && dlg.sim !== null && dlg.sim.allowed && !dlg.running
                onClicked: dlg.act("start")
            }
            Button {
                text: "Arrêter et restaurer"
                enabled: !dlg.working && dlg.sim !== null && dlg.sim.allowed
                         && (dlg.running || dlg.sim.board.module === "m_seq_sim" || dlg.sim.tap.running)
                onClicked: dlg.act("stop")
            }
            Button { text: "Fermer"; onClicked: dlg.close() }
        }
    }
}
