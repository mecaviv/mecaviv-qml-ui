import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15
import "../utils" as Utils

Rectangle {
    id: configPage
    
    color: "#1a1a1a"
    
    // Instance de NetworkUtils pour obtenir l'URL de base de l'API
    Utils.NetworkUtils {
        id: networkUtils
    }
    
    property var consoleController: null
    property int currentPupitreIndex: 0
    property int currentTabIndex: 0
    property var _currentPreset: null
    
    // Déclencher la mise à jour des Loader quand consoleController devient disponible
    onConsoleControllerChanged: {
        if (consoleController) {
            // Forcer la mise à jour du PresetSelector
            if (presetSelectorLoader.item) {
                presetSelectorLoader.item.consoleController = consoleController
                if (consoleController.presetManager) {
                    presetSelectorLoader.item.presetManager = consoleController.presetManager
                }
            }
            // Mettre à jour le PupitreSelector avec le modèle réel
            if (pupitreSelectorLoader.item) {
                pupitreSelectorLoader.item.pupitres = consoleController ? consoleController.pupitres : []
                pupitreSelectorLoader.item.consoleController = consoleController
            }
            
            // Mettre à jour le SireneManager quand il devient disponible
            if (consoleController.sireneManager) {
                if (tabLoader.item && tabLoader.item.hasOwnProperty('sireneManager')) {
                    tabLoader.item.sireneManager = consoleController.sireneManager
                }
            }
            
            // Mettre à jour le SirenRouterManager quand il devient disponible
            if (consoleController.sirenRouterManager) {
                if (tabLoader.item && tabLoader.item.hasOwnProperty('sirenRouterManager')) {
                    tabLoader.item.sirenRouterManager = consoleController.sirenRouterManager
                }
            }
        }
    }
    
    // Mettre à jour les données des tabs quand on change de pupitre
    onCurrentPupitreIndexChanged: {
        loadCurrentPresetAndBind()
    }
    // Recharger aussi le snapshot quand on change d'onglet
    onCurrentTabIndexChanged: {
        loadCurrentPresetAndBind()
    }
    
    function updateTabData() {
        // Mettre à jour les données du pupitre pour le tab actuel
        if (tabLoader.item) {
            if (tabLoader.item.hasOwnProperty('pupitre')) {
                tabLoader.item.pupitre = configPage.pupitres[configPage.currentPupitreIndex]
            }
            if (tabLoader.item.hasOwnProperty('currentPupitreIndex')) {
                tabLoader.item.currentPupitreIndex = configPage.currentPupitreIndex
            }
            if (tabLoader.item.hasOwnProperty('allPupitres')) {
                tabLoader.item.allPupitres = configPage.pupitres
            }
            if (tabLoader.item.hasOwnProperty('sireneManager') && consoleController && consoleController.sireneManager) {
                tabLoader.item.sireneManager = consoleController.sireneManager
            }
            if (tabLoader.item.hasOwnProperty('sirenRouterManager') && consoleController && consoleController.sirenRouterManager) {
                tabLoader.item.sirenRouterManager = consoleController.sirenRouterManager
            }
        }
    }
    
    // Liste des noms de pupitres
    property var pupitreNames: [
        "P1", "P2", "P3", "P4", 
        "P5", "P6", "P7"
    ]
    
    // Liste des pupitres (lier directement le modèle du contrôleur)
    property var pupitres: consoleController ? consoleController.pupitres : []
    
    // Repropager la liste vers le PupitreSelector quand elle change
    onPupitresChanged: {
        if (pupitreSelectorLoader.item) {
            pupitreSelectorLoader.item.pupitres = pupitres
        }
        // Re-binder aussi le pupitre courant dans l'onglet actif
        updateTabData()
    }
    
    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 20
        spacing: 15
        
        // Sélecteur de presets
        Loader {
            id: presetSelectorLoader
            source: "../components/config/PresetSelector.qml"
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            
            onLoaded: {
                item.consoleController = configPage.consoleController
                if (configPage.consoleController && configPage.consoleController.presetManager) {
                    item.presetManager = configPage.consoleController.presetManager
                }
                // Écouter le signal de download pour recharger le snapshot
                item.presetDownloaded.connect(function() {
                    loadCurrentPresetAndBind()
                })
            }
        }
        
        // Sélecteur de pupitres
        Loader {
            id: pupitreSelectorLoader
            source: "../components/config/PupitreSelector.qml"
            Layout.fillWidth: true
            Layout.preferredHeight: 80
            
            onLoaded: {
                item.pupitreNames = configPage.pupitreNames
                item.pupitres = configPage.pupitres
                item.currentPupitreIndex = configPage.currentPupitreIndex
                
                item.onPupitreSelected.connect(function(index) {
                    configPage.currentPupitreIndex = index
                })
                
                item.onAllModeToggled.connect(function(enabled) {
                    // Propager le mode "All" aux tabs (SirensTab, GameModeTab, etc.)
                    if (tabLoader.item && tabLoader.item.hasOwnProperty('isAllMode')) {
                        tabLoader.item.isAllMode = enabled
                        tabLoader.item.allPupitres = configPage.pupitres
                    }
                })
            }
        }
        
        // Panneau de navigation et contenu
        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 20
            
            // Panneau de navigation à gauche
            Loader {
                source: "../components/config/ConfigNavigationPanel.qml"
                Layout.preferredWidth: 200
                Layout.fillHeight: true
                
                onLoaded: {
                    item.currentTabIndex = configPage.currentTabIndex
                    
                    item.onTabSelected.connect(function(index) {
                        configPage.currentTabIndex = index
                    })
                }
            }
            
            // Contenu principal à droite
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#2a2a2a"
                border.color: "#444444"
                border.width: 1
                radius: 8
                
                Loader {
                    id: tabLoader
                    anchors.fill: parent
                    anchors.margins: 15
                    source: {
                        switch(configPage.currentTabIndex) {
                            case 0: return "../components/config/tabs/SirensTab.qml"
                            case 1: return "../components/config/tabs/ControllersTab.qml"
                            case 2: return "../components/config/tabs/OutputsTab.qml"
                            case 3: return "../components/config/tabs/GameModeTab.qml"
                            case 4: return "../components/config/tabs/DisplayTab.qml"
                            default: return "../components/config/tabs/SirensTab.qml"
                        }
                    }
                    
                    onLoaded: {
                        
                        if (item.hasOwnProperty('consoleController')) {
                            item.consoleController = configPage.consoleController
                        }
                        if (item.hasOwnProperty('currentPresetSnapshot')) {
                            item.currentPresetSnapshot = _currentPreset
                        }
                        if (item.hasOwnProperty('sireneManager') && configPage.consoleController && configPage.consoleController.sireneManager) {
                            item.sireneManager = configPage.consoleController.sireneManager
                        }
                        if (item.hasOwnProperty('allPupitres')) {
                            item.allPupitres = configPage.pupitres
                        }
                        // Délai pour s'assurer que tout est initialisé
                        Qt.callLater(function() {
                            updateTabData() // Mettre à jour les données du pupitre
                        })
                    }
                }
            }
        }
    }

    // Un pupitre a modifié le preset courant : relire et réafficher le preset
    Connections {
        target: consoleController ? consoleController.webSocketManager : null
        function onPresetUpdatedFromPupitre(pupitreId) {
            loadCurrentPresetAndBind()
        }
    }

    // Rafraîchir les voyants à chaque changement de statut d'un pupitre
    Connections {
        target: consoleController
        function onPupitreStatusChanged(pupitreId, status) {
            if (pupitreSelectorLoader.item) {
                pupitreSelectorLoader.item.pupitres = consoleController ? consoleController.pupitres : []
            }
        }
    }

    function loadCurrentPresetAndBind() {
        var xhr = new XMLHttpRequest()
        var apiUrl = networkUtils.getApiBaseUrl()
        xhr.open("GET", apiUrl + "/api/presets/current")
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE && xhr.status === 200) {
                try {
                    var res = JSON.parse(xhr.responseText)
                    _currentPreset = res && res.preset ? res.preset : null
                    if (tabLoader.item && tabLoader.item.hasOwnProperty('currentPresetSnapshot')) {
                        tabLoader.item.currentPresetSnapshot = _currentPreset
                    }
                    updateTabData()
                } catch (e) {}
            }
        }
        xhr.send()
    }
}