import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import SirenManager
import "components"

ApplicationWindow {
    id: root
    visible: true
    width: 1200
    height: 700
    title: "SirenManager - Contrôle des Sirènes Mecaviv"

    // For the windows of the app that have to bring the user somewhere (the simulation dialog).
    function showTab(index) { tabBar.currentIndex = index }

    // Tooltips: keep the default translucent background, text in a soft orange
    // (the default dark text was unreadable on the dark theme).
    palette.toolTipText: "#f0a54a"

    // Background
    color: "#1e1e1e"

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // TabBar avec les 10 onglets
        TabBar {
            id: tabBar
            Layout.fillWidth: true
            currentIndex: 0

            // Reopen on the tab that was showing when the app was closed.
            Settings {
                id: appState
                category: "MainWindow"
                property int lastTab: 0
            }
            // The saved tab is applied once the tabs exist; nothing is saved before
            // that, or the initial index would overwrite it.
            property bool restored: false
            Component.onCompleted: Qt.callLater(function() {
                if (appState.lastTab >= 0 && appState.lastTab < count) currentIndex = appState.lastTab
                restored = true
            })
            onCurrentIndexChanged: if (restored && currentIndex >= 0) appState.lastTab = currentIndex
            
            background: Rectangle {
                color: "#2a2a2a"
            }

            TabButton {
                text: "PLAYER"
            }
            TabButton {
                text: "MIXAGE"
            }
            TabButton {
                text: "SIRENIUM"
            }
            TabButton {
                text: "MAINTENANCE"
            }
            TabButton {
                text: "CONTROLEURS"
            }
            TabButton {
                text: "PIANO"
            }
            TabButton {
                text: "VOITURES"
            }
            TabButton {
                text: "PAVILLONS"
            }
            TabButton {
                text: "SYSTÈME"
            }
            TabButton {
                text: "PLAYLISTS"
            }
        }

        // StackLayout pour afficher la vue correspondante
        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: tabBar.currentIndex

            Loader {
                source: "views/PlayerView.qml"
            }

            Loader {
                source: "views/MixerView.qml"
            }

            Loader {
                source: "views/SireniumView.qml"
            }

            Loader {
                source: "views/MaintenanceView.qml"
            }

            Loader {
                source: "views/ControleurView.qml"
            }

            Loader {
                source: "views/PianoView.qml"
            }

            Loader {
                source: "views/VoitureView.qml"
            }

            Loader {
                source: "views/PavillonView.qml"
            }

            Loader {
                source: "views/SystemMaintenanceView.qml"
            }

            Loader {
                source: "views/PlaylistComposerView.qml"
            }
        }
    }
}

