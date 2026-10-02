import QtQuick 2.15
import QtWebSockets 1.0
import "../utils" as Utils

// WebSocketManager pour SirenConsole
// Gère les connexions WebSocket vers les pupitres SirenePupitre
Item {
    id: webSocketManager
    
    // Instance de NetworkUtils pour obtenir l'URL de base de l'API
    Utils.NetworkUtils {
        id: networkUtils
    }
    
    // === PROPRIÉTÉS ===
    property var connections: ({})
    property var consoleController: null
    property bool pureDataConnected: false
    
    // WebSocket vers le serveur Node.js
    property var webSocket: null
    property bool connected: false
    property string serverUrl: "wss://localhost:8001/ws"  // Valeur par défaut, sera mise à jour dans onCompleted
    
    // Fonction pour détecter automatiquement l'URL WebSocket
    function getWebSocketUrl() {
        try {
            var apiUrl = networkUtils.getApiBaseUrl()
            
            if (apiUrl && apiUrl !== "") {
                var wsUrl = apiUrl.replace(/^https?:/, function(match) {
                    return match === 'https:' ? 'wss:' : 'ws:'
                }) + "/ws"
                return wsUrl
            }
        } catch (e) {
            // Ignorer
        }
        
        // Fallback direct : détecter l'origine pour WebSocket
        try {
            var origin = null
            if (typeof self !== 'undefined' && self.location && self.location.origin) {
                origin = self.location.origin
            } else if (typeof globalThis !== 'undefined' && globalThis.location && globalThis.location.origin) {
                origin = globalThis.location.origin
            } else if (typeof window !== 'undefined' && window.location && window.location.origin) {
                origin = window.location.origin
            } else if (typeof document !== 'undefined' && document.location && document.location.origin) {
                origin = document.location.origin
            } else if (typeof location !== 'undefined' && location.origin) {
                origin = location.origin
            }
            
            if (origin) {
                var wsUrl = origin.replace(/^https?:/, function(match) {
                    return match === 'https:' ? 'wss:' : 'ws:'
                }) + "/ws"
                return wsUrl
            }
            
            var locationObj = null
            if (typeof window !== 'undefined' && window.location) {
                locationObj = window.location
            } else if (typeof document !== 'undefined' && document.location) {
                locationObj = document.location
            }
            
            if (locationObj) {
                var protocol = locationObj.protocol
                var hostname = locationObj.hostname
                var port = locationObj.port || (protocol === 'https:' ? '443' : '80')
                
                if (hostname === '0.0.0.0' || hostname === '') {
                    hostname = 'localhost'
                }
                
                var wsProtocol = (protocol === 'https:') ? 'wss:' : 'ws:'
                var wsPort = (port === '443' || port === '80' || !port || port === '') ? '8001' : port
                return wsProtocol + "//" + hostname + ":" + wsPort + "/ws"
            }
        } catch (e) {
            // Ignorer
        }
        
        return "wss://127.0.0.1:8001/ws"
    }
    
    // === SIGNAUX ===
    signal connectionOpened(string url)
    signal connectionClosed(string url)
    signal messageReceived(string url, string message)
    signal errorOccurred(string url, string error)
    // Un pupitre a modifié un réglage du preset courant : l'interface doit le relire
    signal presetUpdatedFromPupitre(string pupitreId)
    
    onConnectionOpened: function(url) {
        // Envoyer immédiatement l'identification
        if (webSocket && connected) {
            webSocket.sendTextMessage(JSON.stringify({
                type: "SIRENCONSOLE_IDENTIFICATION",
                source: "SIRENCONSOLE_QML",
                timestamp: Date.now()
            }));
        }
    }
    
    // === TIMER DE VÉRIFICATION (statut pupitres + ping) ===
    Timer {
        id: statusTimer
        interval: 2000 // Vérifier toutes les 2 secondes
        running: true
        repeat: true
        onTriggered: {
            // Poll HTTP en secours
            webSocketManager.checkPureDataStatus()
            webSocketManager.checkPupitresStatus()
            
            // Ping pour maintenir la connexion WS
            if (webSocketManager.connected) {
                webSocketManager.sendMessage({
                    type: "PING",
                    source: "SIRENCONSOLE_QML",
                    timestamp: Date.now()
                })
            }
        }
    }
    
    // === MÉTHODES PRIVÉES ===
    
    // Créer et configurer la connexion WebSocket
    function createWebSocket() {
        if (webSocket) {
            webSocket.destroy()
        }
        
        webSocket = Qt.createQmlObject('
            import QtWebSockets 1.0
            WebSocket {
                id: ws
                url: "' + serverUrl + '"
                active: true
                
                onStatusChanged: function(status) {
                    if (status === WebSocket.Open) {
                        webSocketManager.connected = true
                        webSocketManager.connectionOpened(url)
                    } else if (status === WebSocket.Closed) {
                        webSocketManager.connected = false
                        webSocketManager.connectionClosed(url)
                    } else if (status === WebSocket.Error) {
                        webSocketManager.connected = false
                        var errorMsg = ws.errorString || "Erreur connexion WebSocket"
                        webSocketManager.errorOccurred(url, errorMsg)
                    }
                }
                
                onTextMessageReceived: function(message) {
                    webSocketManager.handleWebSocketMessage(message)
                }
            }
        ', webSocketManager)
    }
    
    // Gérer les messages WebSocket reçus
    function handleWebSocketMessage(message) {
        try {
            var data = JSON.parse(message)
            
            // Traiter les messages du serveur
            switch (data.type) {
                case "PONG":
                    // Pong reçu (log supprimé pour éviter le spam)
                    break
                case "INITIAL_STATUS":
                    // Mettre à jour les statuts initiaux des pupitres
                    if (data.data && data.data.connections && consoleController) {
                        for (var i = 0; i < data.data.connections.length; i++) {
                            try {
                                var pupitreStatus = data.data.connections[i]
                                var statusText = pupitreStatus.connected ? "connected" : "disconnected"
                                // Mettre à jour le statut via updatePupitreStatus
                                if (consoleController.updatePupitreStatus) {
                                    consoleController.updatePupitreStatus(pupitreStatus.pupitreId, statusText)
                                }
                                // Émettre aussi le signal pour compatibilité
                                if (consoleController.pupitreStatusChanged) {
                                    consoleController.pupitreStatusChanged(pupitreStatus.pupitreId, statusText)
                                }
                                
                                // Mettre à jour aussi l'état de synchronisation si présent
                                if (pupitreStatus.isSynced !== undefined) {
                                    var propName = "pupitre" + pupitreStatus.pupitreId.substring(1) + "Synced" // P1 -> pupitre1Synced
                                    try {
                                        consoleController[propName] = pupitreStatus.isSynced || false
                                    } catch (e) {
                                        // Propriété n'existe pas, ignorer
                                    }
                                }
                            } catch (e) {
                                // Ignorer les erreurs pour éviter le spam
                            }
                        }
                    }
                    break
                case "SYNC_STATUS_CHANGED":
                    // Mettre à jour l'état de synchronisation
                    if (data.pupitreId && consoleController) {
                        try {
                            var propName = "pupitre" + data.pupitreId.substring(1) + "Synced" // P1 -> pupitre1Synced
                            // Vérifier que la propriété existe en testant l'accès
                            var testValue = consoleController[propName]
                            if (testValue !== undefined || consoleController[propName] !== undefined) {
                                consoleController[propName] = data.isSynced || false
                            }
                        } catch (e) {
                            // Ignorer les erreurs d'accès aux propriétés
                        }
                    }
                    break
                    
                case "PUPITRE_CONNECTED":
                    // Mettre à jour immédiatement le statut de connexion
                    if (data.pupitreId && consoleController) {
                        try {
                            if (consoleController.updatePupitreStatus) {
                                consoleController.updatePupitreStatus(data.pupitreId, "connected");
                            }
                            // Mettre à jour aussi la synchronisation si présente
                            if (data.isSynced !== undefined) {
                                var propName = "pupitre" + data.pupitreId.substring(1) + "Synced"
                                try {
                                    consoleController[propName] = data.isSynced || false
                                } catch (e) {
                                    // Propriété n'existe pas, ignorer
                                }
                            }
                        } catch (e) {
                            // Ignorer les erreurs
                        }
                    }
                    break
                    
                case "PUPITRE_DISCONNECTED":
                    // Mettre à jour immédiatement le statut de déconnexion
                    if (data.pupitreId && consoleController) {
                        try {
                            if (consoleController.updatePupitreStatus) {
                                consoleController.updatePupitreStatus(data.pupitreId, "disconnected")
                            }
                        } catch (e) {
                            // Ignorer les erreurs
                        }
                    }
                    break
                    
                case "PUPITRE_STATUS_UPDATE":
                    // Mettre à jour les statuts des pupitres dans l'interface
                    if (data.data && data.data.connections && consoleController) {
                        // console.log("🎛️ consoleController trouvé, mise à jour des statuts")
                        for (var i = 0; i < data.data.connections.length; i++) {
                            try {
                                var pupitreStatus = data.data.connections[i]
                                // console.log("🎛️ Pupitre", pupitreStatus.pupitreId, "connected:", pupitreStatus.connected)
                                var statusText = pupitreStatus.connected ? "connected" : "disconnected"
                                // console.log("🎛️ Appel updatePupitreStatus pour", pupitreStatus.pupitreId, "avec status:", statusText)
                                if (consoleController.updatePupitreStatus) {
                                    consoleController.updatePupitreStatus(pupitreStatus.pupitreId, statusText)
                                }
                                
                                // Mettre à jour aussi l'état de synchronisation si présent
                                if (pupitreStatus.isSynced !== undefined) {
                                    var propName = "pupitre" + pupitreStatus.pupitreId.substring(1) + "Synced" // P1 -> pupitre1Synced
                                    try {
                                        consoleController[propName] = pupitreStatus.isSynced || false
                                    } catch (e) {
                                        // Propriété n'existe pas, ignorer
                                    }
                                }
                            } catch (e) {
                                // Ignorer les erreurs pour éviter le spam
                            }
                        }
                    } else {
                        // console.log("❌ consoleController non trouvé ou données manquantes")
                        // console.log("❌ consoleController:", consoleController)
                        // console.log("❌ data.data:", data.data)
                        // console.log("❌ data.data.connections:", data.data ? data.data.connections : "undefined")
                    }
                    break
                case "VOLANT_DATA":
                    // Mettre à jour la note continue du pupitre concerné
                    if (consoleController && data.pupitreId && data.noteFloat !== undefined) {
                        consoleController.updatePupitreVolantData(
                            data.pupitreId,
                            data.noteFloat,
                            data.frequency || 261,
                            data.rpm || 1308,
                            data.velocity || 0
                        )
                    } else if (consoleController && data.noteFloat !== undefined) {
                        // Compat: si pas d'id, on considère P1
                        consoleController.updatePupitreVolantData(
                            "P1",
                            data.noteFloat,
                            data.frequency || 261,
                            data.rpm || 1308,
                            data.velocity || 0
                        )
                    }
                    break
                case "PRESET_UPDATED_FROM_PUPITRE":
                    presetUpdatedFromPupitre(data.pupitreId || "")
                    break
                default:
                    // console.log("📨 Autre message reçu:", data.type)
            }
        } catch (e) {
            // console.log("📦 Message non-JSON reçu:", message.substring(0, 50))
        }
        
        messageReceived(serverUrl, message)
    }
    
    // Vérifier le statut de la connexion PureData (via HTTP)
    function checkPureDataStatus() {
        var xhr = new XMLHttpRequest()
        var self = webSocketManager
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    var status = JSON.parse(xhr.responseText)
                    self.pureDataConnected = status.connected
                } catch (e) {
                    // Ignorer erreur silencieusement
                }
            }
        }
        var apiUrl = networkUtils.getApiBaseUrl()
        xhr.open("GET", apiUrl + "/api/puredata/status")
        xhr.send()
    }
    
    // Vérifier le statut des pupitres (pour les LEDs)
    function checkPupitresStatus() {
        var xhr = new XMLHttpRequest()
        var self = webSocketManager
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    var status = JSON.parse(xhr.responseText)
                    // Statut pupitres mis à jour
                    
                    // Mettre à jour le statut de chaque pupitre
                    for (var i = 0; i < status.connections.length; i++) {
                        var pupitreStatus = status.connections[i]
                        var statusText = pupitreStatus.connected ? "connected" : "disconnected"
                        
                        // Notifier le ConsoleController du changement de statut
                        if (self.consoleController) {
                            self.consoleController.pupitreStatusChanged(pupitreStatus.pupitreId, statusText)
                        }
                    }
                } catch (e) {
                    // Erreur parsing statut pupitres
                }
            }
        }
        var apiUrl = networkUtils.getApiBaseUrl()
        xhr.open("GET", apiUrl + "/api/pupitres/status")
        xhr.send()
    }
    
    // === MÉTHODES PUBLIQUES ===
    
    // Se connecter au serveur Node.js
    function connect() {
        createWebSocket()
        return true
    }
    
    // Se déconnecter du serveur Node.js
    function disconnect() {
        if (webSocket) {
            webSocket.active = false
            webSocket.destroy()
            webSocket = null
        }
        connected = false
        // console.log("❌ Déconnecté du serveur Node.js")
    }
    
    // Envoyer un message au serveur Node.js
    function sendMessage(message) {
        if (!connected || !webSocket) {
            // console.error("❌ WebSocket non connecté")
            return false
        }
        
        var messageStr = typeof message === 'string' ? message : JSON.stringify(message)
        // Log supprimé pour éviter le spam des ping/pong
        
        webSocket.sendTextMessage(messageStr)
        return true
    }
    
    // Envoyer une commande à PureData (via HTTP POST au proxy) - MÉTHODE LEGACY
    function sendPureDataCommand(message) {
        // Envoi commande via proxy HTTP (legacy)
        
        // Valider le message
        if (!message) {
            return false
        }
        
        // Si c'est un objet, le convertir en JSON
        var messageStr = message
        if (typeof message === 'object') {
            try {
                messageStr = JSON.stringify(message)
            } catch (e) {
                return false
            }
        }
        
        // Vérifier que c'est une string JSON valide
        if (typeof messageStr !== 'string' || messageStr.trim() === '') {
            return false
        }
        
        try {
            var xhr = new XMLHttpRequest()
            var apiUrl = networkUtils.getApiBaseUrl()
            xhr.open("POST", apiUrl + "/api/puredata/command")
            xhr.setRequestHeader("Content-Type", "application/json")
            
            // Gérer les erreurs silencieusement pour éviter le spam
            xhr.onerror = function() {
                // Erreur réseau, ignorer silencieusement
            }
            xhr.onreadystatechange = function() {
                if (xhr.readyState === XMLHttpRequest.DONE) {
                    if (xhr.status !== 200) {
                        // Erreur serveur, ignorer silencieusement pour éviter le spam
                        // Les erreurs 400 sont normales si PureData n'est pas connecté
                    }
                }
            }
            
            xhr.send(messageStr)
            return true
        } catch (e) {
            return false
        }
    }
    
    // Connexion à un pupitre
    function connectToPupitre(host, port, pupitreId) {
        // Connexion pupitre via proxy Node.js uniquement
        // Pas de vérification HTTP directe pour éviter les erreurs Mixed Content
        // Le proxy Node.js gère toutes les connexions WebSocket vers les pupitres
        
        var self = webSocketManager
        try {
            // Stocker la connexion simulée (le proxy Node.js gère le vrai WebSocket)
            self.connections[pupitreId] = {
                websocket: null, // Pas de WebSocket direct depuis le client
                url: "ws://" + host + ":10002",
                host: host,
                port: 10002,
                connected: true // Le proxy Node.js gère la connexion
            }
            
            // Connexion simulée via proxy
            self.connectionOpened(self.connections[pupitreId].url)
            if (self.consoleController) {
                self.consoleController.pupitreStatusChanged(pupitreId, "connected")
            }
        } catch (e) {
            // Ignorer les erreurs silencieusement
        }
        
        return true
    }
    
    // Déconnexion d'un pupitre
    function disconnectFromPupitre(pupitreId) {
        if (webSocketManager.connections[pupitreId]) {
            // Déconnexion pupitre
            
            if (webSocketManager.connections[pupitreId].websocket) {
                webSocketManager.connections[pupitreId].websocket.close()
            }
            
            webSocketManager.connections[pupitreId].connected = false
            webSocketManager.connectionClosed(webSocketManager.connections[pupitreId].url)
            
            // Mettre à jour le statut du pupitre
            if (webSocketManager.consoleController) {
                webSocketManager.consoleController.pupitreStatusChanged(pupitreId, "disconnected")
            }
            
            delete webSocketManager.connections[pupitreId]
        }
    }
    
    // Déconnexion de tous les pupitres
    function disconnectAll() {
        // Déconnexion de tous les pupitres
        for (var pupitreId in webSocketManager.connections) {
            webSocketManager.disconnectFromPupitre(pupitreId)
        }
    }
    
    // Vérifier si un pupitre est connecté
    function isConnected(pupitreId) {
        return webSocketManager.connections[pupitreId] && webSocketManager.connections[pupitreId].connected
    }
    
    // Obtenir les connexions actives
    function getActiveConnections() {
        var active = []
        for (var pupitreId in webSocketManager.connections) {
            if (webSocketManager.connections[pupitreId].connected) {
                active.push({
                    pupitreId: pupitreId,
                    url: webSocketManager.connections[pupitreId].url,
                    host: webSocketManager.connections[pupitreId].host,
                    port: webSocketManager.connections[pupitreId].port
                })
            }
        }
        return active
    }
    
    // Envoyer un message à un pupitre spécifique
    function sendToPupitre(pupitreId, message) {
        if (webSocketManager.connections[pupitreId] && webSocketManager.connections[pupitreId].connected) {
            var ws = webSocketManager.connections[pupitreId].websocket
            if (ws && ws.readyState === WebSocket.OPEN) {
                ws.send(message)
                // Message envoyé
                return true
            }
        }
        // Pupitre non connecté
        return false
    }
    
    // Envoyer un message à tous les pupitres connectés
    function broadcast(message) {
        var sent = 0
        for (var pupitreId in webSocketManager.connections) {
            if (webSocketManager.sendToPupitre(pupitreId, message)) {
                sent++
            }
        }
        // Message broadcast envoyé
        return sent
    }
    
    // === TIMER D'IDENTIFICATION ===
    Timer {
        id: identificationTimer
        interval: 1000 // Attendre 1 seconde que la connexion soit établie
        running: false
        repeat: false
        onTriggered: {
            if (webSocketManager.connected) {
                // console.log("🔑 Envoi identification SirenConsole QML")
                webSocketManager.sendMessage({
                    type: "SIRENCONSOLE_IDENTIFICATION",
                    source: "SIRENCONSOLE_QML",
                    timestamp: Date.now()
                })
            }
        }
    }

    // === INITIALISATION ===
    Component.onCompleted: {
        // Détecter l'URL du serveur automatiquement depuis window.location
        // Utiliser plusieurs tentatives avec délais pour s'assurer que window.location est disponible
        function tryDetectUrl(attempt) {
            var detectedUrl = getWebSocketUrl()
            
            // Si on obtient toujours localhost et qu'on a fait moins de 5 tentatives, réessayer
            if (detectedUrl.indexOf("localhost") >= 0 && attempt < 5) {
                Qt.callLater(function() {
                    tryDetectUrl(attempt + 1)
                })
                return
            }
            
            webSocketManager.serverUrl = detectedUrl
            
            // Se connecter automatiquement au démarrage
            webSocketManager.connect()
            
            // Démarrer le timer d'identification (vérifier qu'il existe)
            if (webSocketManager.identificationTimer) {
                webSocketManager.identificationTimer.start()
            }
        }
        
        // Première tentative immédiate
        Qt.callLater(function() {
            tryDetectUrl(0)
        })
    }
    
    Component.onDestruction: {
        // console.log("🔌 WebSocketManager détruit")
        disconnect()
    }
}