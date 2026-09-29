import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

ScrollView {
    id: logViewer
    
    property var consoleController: null
    
    // Couleurs
    property color backgroundColor: "#1e1e1e"
    property color textColor: "#ffffff"
    property color errorColor: "#ff6b6b"
    property color warningColor: "#ffd93d"
    property color infoColor: "#6bcf7f"
    
    // Logs
    property var logs: []
    
    // Initialiser les logs
    Component.onCompleted: {
        if (!logs) {
            logs = []
        }
        addLog("🎛️ LogViewer initialisé")
        addLog("📊 Prêt à recevoir les logs de la console")
    }
    
    // Interface
    Rectangle {
        anchors.fill: parent
        color: backgroundColor
        border.color: "#333333"
        border.width: 1
        radius: 4
        
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 10
            spacing: 10
            
            // En-tête
            Rectangle {
                Layout.fillWidth: true
                height: 40
                color: "#2d2d2d"
                radius: 4
                
                RowLayout {
                    anchors.fill: parent
                    anchors.margins: 10
                    
                    Text {
                        text: "📋 Logs de la Console"
                        color: textColor
                        font.pixelSize: 16
                        font.bold: true
                    }
                    
                    Item { Layout.fillWidth: true }
                    
                    Button {
                        text: "🗑️ Effacer"
                        onClicked: clearLogs()
                    }
                }
            }
            
            // Zone de logs
            ListView {
                id: logList
                Layout.fillWidth: true
                Layout.fillHeight: true
                model: logs
                spacing: 2
                
                delegate: Rectangle {
                    width: logList.width
                    height: logText.height + 10
                    color: index % 2 === 0 ? "#252525" : "#2a2a2a"
                    radius: 2
                    
                    Text {
                        id: logText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        anchors.margins: 8
                        text: modelData
                        color: getLogColor(modelData)
                        font.family: "Consolas, Monaco, monospace"
                        font.pixelSize: 12
                        wrapMode: Text.Wrap
                    }
                }
            }
        }
    }
    
    // Fonction pour obtenir la couleur selon le type de log
    function getLogColor(logText) {
        if (logText.includes("❌") || logText.includes("ERROR")) {
            return errorColor
        } else if (logText.includes("⚠️") || logText.includes("WARNING")) {
            return warningColor
        } else if (logText.includes("✅") || logText.includes("INFO")) {
            return infoColor
        } else {
            return textColor
        }
    }
    
    // Fonction pour ajouter un log
    function addLog(message) {
        if (!logs) {
            logs = []
        }
        
        var timestamp = new Date().toLocaleTimeString()
        var logEntry = "[" + timestamp + "] " + message
        logs.push(logEntry)
        
        // Limiter à 1000 logs maximum
        if (logs.length > 1000) {
            logs.shift()
        }
        
        // Auto-scroll vers le bas
        Qt.callLater(function() {
            logList.positionViewAtEnd()
        })
    }
    
    // Fonction pour effacer les logs
    function clearLogs() {
        logs = []
    }
    
    // Connexion au contrôleur
    Connections {
        target: consoleController
        function onLogMessage(message) {
            addLog(message)
        }
    }
    
}