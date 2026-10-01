import QtQuick 2.15
import "../utils" as Utils

Item {
    id: consoleController
    
    // Instance de NetworkUtils pour obtenir l'URL de base de l'API
    Utils.NetworkUtils {
        id: networkUtils
    }
    
    // Fonction pour charger l'état de synchronisation de tous les pupitres
    function loadSyncStatus() {
        for (var i = 1; i <= 7; i++) {
            (function(index) {
                var pupitreId = "P" + index
                var xhr = new XMLHttpRequest()
                var apiUrl = networkUtils.getApiBaseUrl()
                xhr.open("GET", apiUrl + "/api/pupitres/" + pupitreId + "/sync-status")
                xhr.onreadystatechange = function() {
                    if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                        try {
                            var res = JSON.parse(xhr.responseText)
                            var propName = "pupitre" + index + "Synced"
                            try {
                                consoleController[propName] = res.isSynced || false
                            } catch (propError) {
                                // Propriété n'existe pas, ignorer silencieusement
                            }
                        } catch (e) {
                            // Ignorer les erreurs de parsing pour éviter le spam
                        }
                    }
                }
                xhr.send()
            })(i)
        }
    }
    
    // Fonction pour charger l'état d'autonomie depuis le preset courant
    function loadAutonomyFromPreset() {
        var xhr = new XMLHttpRequest()
        var apiUrl = networkUtils.getApiBaseUrl()
        xhr.open("GET", apiUrl + "/api/presets/current")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText)
                    if (res && res.preset && res.preset.config && res.preset.config.pupitres) {
                        var presetPupitres = res.preset.config.pupitres
                        for (var i = 0; i < presetPupitres.length; i++) {
                            var pp = presetPupitres[i]
                            if (pp.id && pp.autonomy) {
                                // Mettre à jour l'état d'autonomie pour chaque device
                                var devices = ["volant", "pad", "slider", "joystick"]
                                for (var j = 0; j < devices.length; j++) {
                                    var device = devices[j]
                                    if (pp.autonomy[device] !== undefined) {
                                        updateAutonomyState(pp.id, device, !!pp.autonomy[device])
                                    }
                                }
                            }
                        }
                    }
                } catch (e) {
                    // Ignorer les erreurs de parsing
                }
            }
        }
        xhr.send()
    }
    
    // Test simple pour voir si le fichier se charge
    Component.onCompleted: {
        // ConsoleController initialisé
        initializeManagers()
        
        // Charger l'état de synchronisation et l'état d'autonomie après un délai
        Qt.callLater(function() {
            loadSyncStatus()
            loadAutonomyFromPreset()
        })
    }
    
    // === PROPRIÉTÉS PUBLIQUES ===
    
    // Données du volant P3
    property real volantNote: 60
    property real volantVelocity: 0
    property real volantPitchbend: 8192
    property real volantFrequency: 261.63
    property real volantRpm: 1308.15
    property real volantNoteFloat: 60
    // Exposer les managers pour accès externe
    property alias commandManager: commandManager
    property alias configManager: configManager
    property alias pupitreManager: pupitreManager
    property alias webSocketManager: webSocketManager
    
    // Managers - Utilisation directe des composants
    ConfigManager {
        id: configManager
    }
    
    PresetManager {
        id: presetManager
        configManager: configManager
    }
    
    PupitreManager {
        id: pupitreManager
        configManager: configManager
        webSocketManager: webSocketManager
    }
    
    CommandManager {
        id: commandManager
        pupitreManager: pupitreManager
        webSocketManager: webSocketManager
    }
    
    SireneManager {
        id: sireneManager
    }
    
    SirenRouterManager {
        id: sirenRouterManager
    }
    
    WebSocketManager {
        id: webSocketManager
        consoleController: consoleController
    }

    // Un pupitre a modifié le preset courant : relire l'état qui en dépend
    Connections {
        target: webSocketManager
        function onPresetUpdatedFromPupitre(pupitreId) {
            loadAutonomyFromPreset()
        }
    }
    
    // Exposer les managers publiquement
    property var sireneManager: sireneManager
    property var sirenRouterManager: sirenRouterManager
    
    // Propriétés calculées réactives pour l'UI (P1-P7)
    // Utiliser une propriété trigger pour forcer la mise à jour
    property int pupitresUpdateTrigger: 0
    property string pupitre1Status: {
        var _ = pupitresUpdateTrigger
        var p = getPupitreById("P1")
        return p ? p.status : "disconnected"
    }
    property string pupitre2Status: {
        var _ = pupitresUpdateTrigger
        var p = getPupitreById("P2")
        return p ? p.status : "disconnected"
    }
    property string pupitre3Status: {
        var _ = pupitresUpdateTrigger
        var p = getPupitreById("P3")
        return p ? p.status : "disconnected"
    }
    property string pupitre4Status: {
        var _ = pupitresUpdateTrigger
        var p = getPupitreById("P4")
        return p ? p.status : "disconnected"
    }
    property string pupitre5Status: {
        var _ = pupitresUpdateTrigger
        var p = getPupitreById("P5")
        return p ? p.status : "disconnected"
    }
    property string pupitre6Status: {
        var _ = pupitresUpdateTrigger
        var p = getPupitreById("P6")
        return p ? p.status : "disconnected"
    }
    property string pupitre7Status: {
        var _ = pupitresUpdateTrigger
        var p = getPupitreById("P7")
        return p ? p.status : "disconnected"
    }
    
    property real pupitre1CurrentNote: pupitres.length > 0 && pupitres[0].currentNote !== undefined ? pupitres[0].currentNote : 60
    property real pupitre1CurrentHz: pupitres.length > 0 && pupitres[0].currentHz !== undefined ? pupitres[0].currentHz : 440
    property real pupitre1CurrentRpm: pupitres.length > 0 && pupitres[0].currentRpm !== undefined ? pupitres[0].currentRpm : 0
    property int pupitre1AmbitusMin: pupitres.length > 0 && pupitres[0].ambitusMin !== undefined ? pupitres[0].ambitusMin : 48
    property int pupitre1AmbitusMax: pupitres.length > 0 && pupitres[0].ambitusMax !== undefined ? pupitres[0].ambitusMax : 72
    
    // Propriétés calculées pour P2-P7
    property real pupitre2CurrentNote: pupitres.length > 1 && pupitres[1].currentNote !== undefined ? pupitres[1].currentNote : 60
    property real pupitre2CurrentHz: pupitres.length > 1 && pupitres[1].currentHz !== undefined ? pupitres[1].currentHz : 440
    property real pupitre2CurrentRpm: pupitres.length > 1 && pupitres[1].currentRpm !== undefined ? pupitres[1].currentRpm : 0
    property int pupitre2AmbitusMin: pupitres.length > 1 && pupitres[1].ambitusMin !== undefined ? pupitres[1].ambitusMin : 48
    property int pupitre2AmbitusMax: pupitres.length > 1 && pupitres[1].ambitusMax !== undefined ? pupitres[1].ambitusMax : 72
    
    property real pupitre3CurrentNote: pupitres.length > 2 && pupitres[2].currentNote !== undefined ? pupitres[2].currentNote : 60
    property real pupitre3CurrentHz: pupitres.length > 2 && pupitres[2].currentHz !== undefined ? pupitres[2].currentHz : 440
    property real pupitre3CurrentRpm: pupitres.length > 2 && pupitres[2].currentRpm !== undefined ? pupitres[2].currentRpm : 0
    property int pupitre3AmbitusMin: pupitres.length > 2 && pupitres[2].ambitusMin !== undefined ? pupitres[2].ambitusMin : 48
    property int pupitre3AmbitusMax: pupitres.length > 2 && pupitres[2].ambitusMax !== undefined ? pupitres[2].ambitusMax : 72
    
    property real pupitre4CurrentNote: pupitres.length > 3 && pupitres[3].currentNote !== undefined ? pupitres[3].currentNote : 60
    property real pupitre4CurrentHz: pupitres.length > 3 && pupitres[3].currentHz !== undefined ? pupitres[3].currentHz : 440
    property real pupitre4CurrentRpm: pupitres.length > 3 && pupitres[3].currentRpm !== undefined ? pupitres[3].currentRpm : 0
    property int pupitre4AmbitusMin: pupitres.length > 3 && pupitres[3].ambitusMin !== undefined ? pupitres[3].ambitusMin : 48
    property int pupitre4AmbitusMax: pupitres.length > 3 && pupitres[3].ambitusMax !== undefined ? pupitres[3].ambitusMax : 72
    
    property real pupitre5CurrentNote: pupitres.length > 4 && pupitres[4].currentNote !== undefined ? pupitres[4].currentNote : 60
    property real pupitre5CurrentHz: pupitres.length > 4 && pupitres[4].currentHz !== undefined ? pupitres[4].currentHz : 440
    property real pupitre5CurrentRpm: pupitres.length > 4 && pupitres[4].currentRpm !== undefined ? pupitres[4].currentRpm : 0
    property int pupitre5AmbitusMin: pupitres.length > 4 && pupitres[4].ambitusMin !== undefined ? pupitres[4].ambitusMin : 48
    property int pupitre5AmbitusMax: pupitres.length > 4 && pupitres[4].ambitusMax !== undefined ? pupitres[4].ambitusMax : 72
    
    property real pupitre6CurrentNote: pupitres.length > 5 && pupitres[5].currentNote !== undefined ? pupitres[5].currentNote : 60
    property real pupitre6CurrentHz: pupitres.length > 5 && pupitres[5].currentHz !== undefined ? pupitres[5].currentHz : 440
    property real pupitre6CurrentRpm: pupitres.length > 5 && pupitres[5].currentRpm !== undefined ? pupitres[5].currentRpm : 0
    property int pupitre6AmbitusMin: pupitres.length > 5 && pupitres[5].ambitusMin !== undefined ? pupitres[5].ambitusMin : 48
    property int pupitre6AmbitusMax: pupitres.length > 5 && pupitres[5].ambitusMax !== undefined ? pupitres[5].ambitusMax : 72
    
    property real pupitre7CurrentNote: pupitres.length > 6 && pupitres[6].currentNote !== undefined ? pupitres[6].currentNote : 60
    property real pupitre7CurrentHz: pupitres.length > 6 && pupitres[6].currentHz !== undefined ? pupitres[6].currentHz : 440
    property real pupitre7CurrentRpm: pupitres.length > 6 && pupitres[6].currentRpm !== undefined ? pupitres[6].currentRpm : 0
    property int pupitre7AmbitusMin: pupitres.length > 6 && pupitres[6].ambitusMin !== undefined ? pupitres[6].ambitusMin : 48
    property int pupitre7AmbitusMax: pupitres.length > 6 && pupitres[6].ambitusMax !== undefined ? pupitres[6].ambitusMax : 72
    
    // Propriétés de synchronisation (bindées depuis serveur)
    property bool pupitre1Synced: false
    property bool pupitre2Synced: false
    property bool pupitre3Synced: false
    property bool pupitre4Synced: false
    property bool pupitre5Synced: false
    property bool pupitre6Synced: false
    property bool pupitre7Synced: false
    
    // Modèle unique des pupitres (remplace les propriétés individuelles)
    // Inclut maintenant l'état d'autonomie pour chaque device
    property var pupitres: [
        { id: "P1", status: "disconnected", ambitusMin: 43, ambitusMax: 86, currentNote: 60.0, currentHz: 440.0, currentRpm: 0, velocity: 0, autonomy: { volant: false, pad: false, slider: false, joystick: false } },
        { id: "P2", status: "disconnected", ambitusMin: 43, ambitusMax: 86, currentNote: 60.0, currentHz: 440.0, currentRpm: 0, velocity: 0, autonomy: { volant: false, pad: false, slider: false, joystick: false } },
        { id: "P3", status: "disconnected", ambitusMin: 36, ambitusMax: 77, currentNote: 60.0, currentHz: 440.0, currentRpm: 0, velocity: 0, autonomy: { volant: false, pad: false, slider: false, joystick: false } },
        { id: "P4", status: "disconnected", ambitusMin: 36, ambitusMax: 77, currentNote: 60.0, currentHz: 440.0, currentRpm: 0, velocity: 0, autonomy: { volant: false, pad: false, slider: false, joystick: false } },
        { id: "P5", status: "disconnected", ambitusMin: 36, ambitusMax: 77, currentNote: 60.0, currentHz: 440.0, currentRpm: 0, velocity: 0, autonomy: { volant: false, pad: false, slider: false, joystick: false } },
        { id: "P6", status: "disconnected", ambitusMin: 36, ambitusMax: 77, currentNote: 60.0, currentHz: 440.0, currentRpm: 0, velocity: 0, autonomy: { volant: false, pad: false, slider: false, joystick: false } },
        { id: "P7", status: "disconnected", ambitusMin: 36, ambitusMax: 77, currentNote: 60.0, currentHz: 440.0, currentRpm: 0, velocity: 0, autonomy: { volant: false, pad: false, slider: false, joystick: false } }
    ]

    // Fonctions utilitaires pour accéder aux pupitres
    function getPupitreById(pupitreId) {
        if (!pupitres || pupitres.length === 0) return null
        for (var i = 0; i < pupitres.length; i++) {
            if (pupitres[i].id === pupitreId) return pupitres[i]
        }
        return null
    }
    
    function getPupitreStatus(pupitreId) {
        var p = getPupitreById(pupitreId)
        return p ? p.status : "disconnected"
    }

    
    // Propriétés des presets
    property var presets: []
    property string currentPreset: ""
    
    // État de l'application
    property bool isInitialized: false
    property bool isConnected: false
    property int connectedPupitresCount: 0
    
    // Fonction pour tester le séquenceur
    function testSequencer(sireneIds) {
        if (sireneManager) {
            sireneManager.setSequencerSirenes(sireneIds || [])
        }
    }
    
    // === SIGNALS ===
    
    signal initializationComplete()
    signal connectionStatusChanged(bool connected)
    signal pupitreStatusChanged(string pupitreId, string status)
    signal volantDataChanged(int note, int velocity, int pitchbend, real frequency, real rpm)
    signal presetLoaded(string presetName)
    signal presetsListChanged(var presetsList)
    signal errorOccurred(string error)
    signal autonomyStateChanged(string pupitreId, string device, bool enabled)
    
    // === TIMER DE VÉRIFICATION (désactivé) ===
    Timer {
        id: statusCheckTimer
        interval: 2000
        running: false
        repeat: false
        onTriggered: {}
    }
    
    // === INITIALISATION ===
    
    // Initialisation déplacée dans le premier Component.onCompleted
    
    function initializeManagers() {
        
        // Connecter les signaux
        connectSignals()
        
        // Initialiser les pupitres
        if (configManager && configManager.isLoaded) {
            initializePupitres()
        } else {
            // Attendre que la configuration soit chargée
            if (configManager) {
            configManager.configLoaded.connect(function(config) {
                initializePupitres()
            })
            }
        }
        
        // Charger les presets au démarrage
        if (presetManager) {
            presetManager.loadPresetsFromStorage()
        }
        
        // Le modèle pupitres est maintenant initialisé par défaut dans la propriété
    }
    
    function connectSignals() {
        // ConfigManager
        if (configManager) {
            configManager.configError.connect(function(error) {
                errorOccurred("Configuration: " + error)
            })
            // Mettre à jour le modèle local quand les sirènes assignées changent
            configManager.assignedSirenesChanged.connect(function(pupitreId, sirenes) {
                if (!pupitres || pupitres.length === 0) return
                var updated = []
                for (var i = 0; i < pupitres.length; i++) {
                    var p = pupitres[i]
                    if (p.id === pupitreId) {
                        updated.push({
                            id: p.id,
                            status: p.status,
                            ambitusMin: p.ambitusMin,
                            ambitusMax: p.ambitusMax,
                            currentNote: p.currentNote,
                            currentHz: p.currentHz,
                            currentRpm: p.currentRpm,
                            velocity: p.velocity,
                            autonomy: p.autonomy || { volant: false, pad: false, slider: false, joystick: false },
                            assignedSirenes: sirenes || []
                        })
                    } else {
                        updated.push(p)
                    }
                }
                pupitres = updated
            })
        }
        
        // PresetManager
        if (presetManager) {
            presetManager.presetsListChanged.connect(function(presetsList) {
                presets = presetsList
                presetsListChanged(presetsList) // Propager le signal
            })
            
            presetManager.presetLoaded.connect(function(presetName) {
                currentPreset = presetName
                presetLoaded(presetName)
                // Recharger l'état d'autonomie depuis le nouveau preset
                Qt.callLater(function() {
                    loadAutonomyFromPreset()
                })
            })
            
            presetManager.presetError.connect(function(error) {
                errorOccurred("Preset: " + error)
            })
        }
        
        // PupitreManager
        if (pupitreManager) {
            pupitreManager.pupitreConnected.connect(function(pupitreId) {
                updateConnectionStatus()
                updatePupitreStatus(pupitreId, "connected")
            })
            
            pupitreManager.pupitreDisconnected.connect(function(pupitreId) {
                updateConnectionStatus()
                updatePupitreStatus(pupitreId, "disconnected")
            })
            
            pupitreManager.pupitreStatusChanged.connect(function(pupitreId, status) {
                pupitreStatusChanged(pupitreId, status)
                updatePupitreStatus(pupitreId, status)
            })
            
        }
        
        // CommandManager
        if (commandManager) {
            commandManager.commandError.connect(function(command, error) {
                errorOccurred("Commande " + command + ": " + error)
            })
        }
    }
    
    function initializePupitres() {
        if (!pupitreManager || !configManager) {
            // Managers non disponibles
            return false
        }
        
        
        // Initialiser les pupitres via PupitreManager
        if (pupitreManager.initializePupitres()) {
            // Mettre à jour les propriétés pour compatibilité
            pupitres = pupitreManager.pupitres
            
            // Auto-connexion si activée
            if (configManager.config && configManager.config.console && configManager.config.console.autoConnect) {
                connectAllPupitres()
            }
            
            isInitialized = true
            initializationComplete()
            return true
        }
        
        return false
    }

    // Construire le tableau pupitres[] depuis config.json
    function buildPupitresFromConfig() {
        var built = []
        if (configManager && configManager.config && configManager.config.sirens) {
            for (var i = 0; i < configManager.config.sirens.length; i++) {
                var s = configManager.config.sirens[i]
                built.push({
                    id: "P" + (i + 1),
                    status: "disconnected",
                    ambitusMin: (s.ambitus && s.ambitus.min !== undefined) ? s.ambitus.min : 48,
                    ambitusMax: (s.ambitus && s.ambitus.max !== undefined) ? s.ambitus.max : 72,
                    currentNote: 60.0,
                    currentHz: 440.0,
                    currentRpm: 0,
                    velocity: 0,
                    autonomy: { volant: false, pad: false, slider: false, joystick: false }
                })
            }
        }
        pupitres = built
    }
    
    // === MÉTHODES PUBLIQUES (COMPATIBILITÉ) ===
    
    // Gestion des connexions
    function connectAllPupitres() {
        if (pupitreManager) {
            return pupitreManager.connectAllPupitres()
        }
        return false
    }
    
    function disconnectAllPupitres() {
        if (pupitreManager) {
            return pupitreManager.disconnectAllPupitres()
        }
        return false
    }
    
    function connectPupitre(pupitreId) {
        if (pupitreManager) {
            return pupitreManager.connectPupitre(pupitreId)
        }
        return false
    }
    
    function disconnectPupitre(pupitreId) {
        if (pupitreManager) {
            return pupitreManager.disconnectPupitre(pupitreId)
        }
        return false
    }
    
    // Gestion des presets
    function loadPreset(presetName) {
        if (presetManager) {
            return presetManager.loadPreset(presetName)
        }
        return false
    }
    
    function createPresetFromCurrent(presetName, presetDescription) {
        if (presetManager) {
            return presetManager.createPresetFromCurrent(presetName, presetDescription)
        }
        return false
    }
    
    function deletePreset(presetName) {
        if (presetManager) {
            return presetManager.deletePreset(presetName)
        }
        return false
    }
    
    function savePresetsToStorage() {
        if (presetManager) {
            // Les presets sont automatiquement sauvegardés via l'API
            return true
        }
        return false
    }
    
    function loadPresetsFromStorage() {
        if (presetManager) {
            presetManager.loadPresetsFromStorage()
            return true
        }
        return false
    }
    
    // Gestion des pupitres
    function getCurrentPupitre() {
        if (pupitreManager) {
            return pupitreManager.getCurrentPupitre()
        }
        return null
    }
    
    function setCurrentPupitre(index) {
        if (pupitreManager) {
            return pupitreManager.setCurrentPupitre(index)
        }
        return false
    }
    
    
    // === MÉTHODES DE COMPATIBILITÉ POUR L'UI ===
    
    // Méthodes pour l'interface utilisateur
    function sendMidiCommand(command) {
        if (webSocketManager && webSocketManager.connected) {
            return webSocketManager.sendMidiCommand(command)
        }
        return false
    }
    
    function sendPureDataCommand(command) {
        if (webSocketManager && webSocketManager.connected) {
            return webSocketManager.sendPureDataCommand(command)
        }
        return false
    }
    
    function requestStatus() {
        if (webSocketManager && webSocketManager.connected) {
            return webSocketManager.requestStatus()
        }
        return false
    }
    
    // Contrôle des sirènes
    function controlSirene(pupitreId, sireneNumber, enabled, ambitusRestreint, modeFrette) {
        if (pupitreManager) {
            return pupitreManager.controlSirene(pupitreId, sireneNumber, enabled, ambitusRestreint, modeFrette)
        }
        return false
    }
    
    function setPupitreAmbitus(pupitreId, min, max) {
        if (pupitreManager) {
            return pupitreManager.setPupitreAmbitus(pupitreId, min, max)
        }
        return false
    }
    
    function setPupitreFrettedMode(pupitreId, frettedMode) {
        if (pupitreManager) {
            return pupitreManager.setPupitreFrettedMode(pupitreId, frettedMode)
        }
        return false
    }
    
    // Contrôle des sorties
    function setPupitreOutputSettings(pupitreId, settings) {
        if (configManager) {
            return configManager.setOutputSettings(pupitreId, settings)
        }
        return false
    }
    
    function getPupitreOutputSettings(pupitreId) {
        if (configManager) {
            return configManager.getOutputSettings(pupitreId)
        }
        return { vstEnabled: false, udpEnabled: false, rtpMidiEnabled: false }
    }
    
    // Mapping des contrôleurs
    function setPupitreControllerMapping(pupitreId, controllerType, cc, curve) {
        if (commandManager) {
            return commandManager.setControllerMapping(pupitreId, controllerType, cc, curve)
        }
        return false
    }
    
    function getPupitreControllerMapping(pupitreId) {
        if (configManager) {
            return configManager.getControllerMapping(pupitreId)
        }
        return {}
    }
    
    // Commandes
    function sendCommand(pupitreId, command, parameters) {
        if (commandManager) {
            return commandManager.executeCommand(pupitreId, command, parameters)
        }
        return false
    }
    
    // Commandes de configuration UI du pupitre
    function setPupitreUiControlsEnabled(pupitreId, enabled) {
        if (commandManager) {
            return commandManager.setUiControlsEnabled(pupitreId, enabled)
        }
        return false
    }
    
    function setAutonomyMode(pupitreId, device, enabled) {
        if (commandManager) {
            var success = commandManager.setAutonomyMode(pupitreId, device, enabled)
            if (success) {
                // Mettre à jour l'état local immédiatement pour synchronisation UI
                updateAutonomyState(pupitreId, device, enabled)
            }
            return success
        }
        return false
    }
    
    // Met à jour l'état d'autonomie localement et émet le signal
    function updateAutonomyState(pupitreId, device, enabled) {
        if (!pupitres || pupitres.length === 0) return
        
        var updated = []
        for (var i = 0; i < pupitres.length; i++) {
            var p = pupitres[i]
            if (p.id === pupitreId) {
                var newAutonomy = p.autonomy ? JSON.parse(JSON.stringify(p.autonomy)) : { volant: false, pad: false, slider: false, joystick: false }
                newAutonomy[device] = enabled
                updated.push({
                    id: p.id,
                    status: p.status,
                    ambitusMin: p.ambitusMin,
                    ambitusMax: p.ambitusMax,
                    currentNote: p.currentNote,
                    currentHz: p.currentHz,
                    currentRpm: p.currentRpm,
                    velocity: p.velocity,
                    autonomy: newAutonomy
                })
            } else {
                updated.push(p)
            }
        }
        pupitres = updated
        pupitresUpdateTrigger++
        autonomyStateChanged(pupitreId, device, enabled)
    }
    
    // Retourne l'état d'autonomie d'un device pour un pupitre
    function getAutonomyState(pupitreId, device) {
        var p = getPupitreById(pupitreId)
        if (p && p.autonomy) {
            return p.autonomy[device] || false
        }
        return false
    }
    
    // === MÉTHODES UTILITAIRES ===
    
    function updateConnectionStatus() {
        if (pupitreManager) {
            var stats = pupitreManager.getPupitresStats()
            connectedPupitresCount = stats.connected
            isConnected = stats.connected > 0
            connectionStatusChanged(isConnected)
        }
    }
    
    // Mettre à jour les données du volant (compat ancienne signature)
    function updateVolantData(noteFloat, velocity, pitchbend, frequency, rpm) {
        // Par défaut, considérer P1
        updatePupitreVolantData("P1", noteFloat, frequency, rpm, velocity)
    }

    // Nouvelle API: mise à jour d'un pupitre par id avec note continue
    function updatePupitreVolantData(pupitreId, noteFloat, frequency, rpm, velocity) {
        if (!pupitres || pupitres.length === 0) return
        
        // Créer un nouveau tableau pour forcer QML à détecter le changement
        var updated = []
        for (var i = 0; i < pupitres.length; i++) {
            var p = pupitres[i]
            if (p.id === pupitreId) {
                updated.push({
                    id: p.id,
                    status: p.status,
                    ambitusMin: p.ambitusMin,
                    ambitusMax: p.ambitusMax,
                    currentNote: noteFloat,
                    currentHz: frequency,
                    currentRpm: rpm,
                    velocity: velocity,
                    autonomy: p.autonomy || { volant: false, pad: false, slider: false, joystick: false }
                })
            } else {
                updated.push(p)
            }
        }
        pupitres = updated
        
        // Maintenir les anciennes props pour compat (pilotent P1)
        if (pupitreId === "P1") {
            volantNoteFloat = noteFloat
            volantNote = Math.round(noteFloat)
            volantVelocity = velocity
            volantFrequency = frequency
            volantRpm = rpm
        }
    }
    
    function updatePupitreStatus(pupitreId, status) {
        // Mettre à jour le statut dans le modèle pupitres[]
        if (!pupitres || pupitres.length === 0) {
            return
        }
        
        // Créer un nouveau tableau pour forcer QML à détecter le changement
        var updated = []
        var found = false
        for (var i = 0; i < pupitres.length; i++) {
            var p = pupitres[i]
            if (p.id === pupitreId) {
                found = true
                updated.push({
                    id: p.id,
                    status: status,
                    ambitusMin: p.ambitusMin,
                    ambitusMax: p.ambitusMax,
                    currentNote: p.currentNote,
                    currentHz: p.currentHz,
                    currentRpm: p.currentRpm,
                    velocity: p.velocity,
                    autonomy: p.autonomy || { volant: false, pad: false, slider: false, joystick: false }
                })
            } else {
                updated.push(p)
            }
        }
        
        if (!found) {
            return
        }
        
        pupitres = updated
        
        // Forcer la mise à jour des propriétés calculées
        pupitresUpdateTrigger++
        
        // Émettre le signal pour compatibilité
        pupitreStatusChanged(pupitreId, status)
    }
    
    
    
    
    
    function getPupitresStats() {
        if (pupitreManager) {
            return pupitreManager.getPupitresStats()
        }
        return { total: 0, enabled: 0, connected: 0, disconnected: 0, connecting: 0 }
    }
    
    function getConnectedPupitres() {
        if (pupitreManager) {
            return pupitreManager.getConnectedPupitres()
        }
        return []
    }
    
    function getEnabledPupitres() {
        if (pupitreManager) {
            return pupitreManager.getEnabledPupitres()
        }
        return []
    }
    
    // Configuration
    function getConfiguration() {
        if (configManager) {
            return configManager.config
        }
        return null
    }
    
    function exportConfiguration() {
        if (configManager) {
            return configManager.exportConfig()
        }
        return null
    }
    
    function importConfiguration(configJson) {
        if (configManager) {
            return configManager.importConfig(configJson)
        }
        return false
    }
    
    // Presets
    function getPresetNames() {
        if (presetManager) {
            return presetManager.getPresetNames()
        }
        return []
    }
    
    function presetExists(presetName) {
        if (presetManager) {
            return presetManager.presetExists(presetName)
        }
        return false
    }
    
    // === PROPRIÉTÉS DE COMPATIBILITÉ ===
    
    // Pour maintenir la compatibilité avec l'UI existante
    property int currentPupitreIndex: pupitreManager ? pupitreManager.currentPupitreIndex : 0
    property int pupitresCount: pupitres ? pupitres.length : 0
    property bool isReady: isInitialized
    
    // Méthodes de compatibilité
    function refreshPupitres() {
        if (pupitreManager) {
            pupitreManager.syncWithConfig()
            pupitres = pupitreManager.pupitres
        }
    }
    
    function resetPupitres() {
        if (pupitreManager && configManager) {
            pupitreManager.disconnectAllPupitres()
            pupitreManager.initializePupitres()
            pupitres = pupitreManager.pupitres
        }
    }
}