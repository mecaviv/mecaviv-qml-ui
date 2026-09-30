import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import QtQuick.Window 2.15

import "components"
import "controllers"

ApplicationWindow {
    id: mainWindow
    visible: true
    title: "SirenConsole - Console de Contrôle des Pupitres"
    
    // Screen.desktopAvailable* is the virtual desktop (every monitor combined).
    // Binding the window to it stretches the layout across all displays.
    // Desktop: maximize on the screen the window is on.
    // WebAssembly: one canvas, follow the browser size.
    readonly property bool followBrowserCanvas: Qt.platform.os === "wasm"

    width: followBrowserCanvas ? (Screen.width > 0 ? Screen.width : 1920) : 1280
    height: followBrowserCanvas ? (Screen.height > 0 ? Screen.height : 1080) : 800

    minimumWidth: 800
    minimumHeight: 600

    Component.onCompleted: {
        if (!followBrowserCanvas)
            Qt.callLater(showMaximized)
    }

    Timer {
        interval: 100
        running: mainWindow.followBrowserCanvas
        repeat: true
        onTriggered: {
            var newWidth = Screen.width > 0 ? Screen.width : 1920
            var newHeight = Screen.height > 0 ? Screen.height : 1080
            if (Math.abs(mainWindow.width - newWidth) > 10 || Math.abs(mainWindow.height - newHeight) > 10) {
                mainWindow.width = newWidth
                mainWindow.height = newHeight
            }
        }
    }
    
    // Police Emoji globale
    FontLoader {
        id: emojiFont
        source: "qrc:/fonts/NotoEmoji-VariableFont_wght.ttf"
        onStatusChanged: {
            // Police chargée
        }
    }
    
    // Rendre la police accessible globalement
    readonly property string globalEmojiFont: emojiFont.name
    
    // Contrôleur principal
    ConsoleController {
        id: consoleController
        
    }
    
    // Interface principale
    Rectangle {
        anchors.fill: parent
        color: "#1a1a1a"
        
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            
            // Barre de navigation
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 60
                color: "#2a2a2a"
                border.color: "#555555"
                border.width: 1
                
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 20
                    
                    // Logo/Titre
                    Text {
                        text: "🎛️ SirenConsole"
                        color: "#ffffff"
                        font.pixelSize: 20
                        font.bold: true
                    }
                    
                    Item {
                        Layout.fillWidth: true
                    }
                    
                    // Boutons de navigation
                    Row {
                        spacing: 10
                        
                        Button {
                            text: "Vue d'ensemble"
                            highlighted: swipeView.currentIndex === 0
                            onClicked: swipeView.currentIndex = 0
                        }
                        
                        Button {
                            text: "Compositions"
                            highlighted: swipeView.currentIndex === 1
                            onClicked: swipeView.currentIndex = 1
                        }
                        
                        Button {
                            text: "Configuration"
                            highlighted: swipeView.currentIndex === 2
                            onClicked: swipeView.currentIndex = 2
                        }
                        
                        Button {
                            text: "Logs"
                            highlighted: swipeView.currentIndex === 3
                            onClicked: swipeView.currentIndex = 3
                        }
                    }
                }
            }
            
            // Contenu principal
            SwipeView {
                id: swipeView
                Layout.fillWidth: true
                Layout.fillHeight: true
                currentIndex: 0
                
                // Page Vue d'ensemble
                Loader {
    source: "pages/OverviewPage.qml"
    property var consoleController: consoleController // Pass reference directly
    onLoaded: {
        item.consoleController = consoleController
        // console.log("🔍 Main: consoleController ID =", consoleController)
        // console.log("🔍 Main: item.consoleController ID =", item.consoleController)
    }
}
                
                // Page Compositions
                Loader {
                    source: "pages/CompositionsPage.qml"
                    onLoaded: {
                        item.consoleController = consoleController
                    }
                }
                
                // Page Configuration
                Loader {
                    source: "pages/ConfigPage.qml"
                    onLoaded: {
                        item.consoleController = consoleController
                    }
                }
                
                // Page Logs
                Loader {
                    source: "pages/LogsPage.qml"
                    onLoaded: {
                        item.consoleController = consoleController
                    }
                }
            }
        }
    }
}