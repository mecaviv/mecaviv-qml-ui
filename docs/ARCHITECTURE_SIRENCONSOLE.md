# 🏗️ Architecture SirenConsole

## 📋 **Vue d'ensemble**

SirenConsole est une application de contrôle centralisée pour gérer des pupitres de sirènes électroniques.

### 🎯 **Composants Principaux**

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   SirenConsole  │    │   Serveur Node  │    │   PureData     │
│   (QML/WebASM)  │◄──►│   (Proxy)       │◄──►│   (Raspberry)  │
│                 │    │                 │    │                │
│ • Interface     │    │ • WebSocket     │    │ • Audio        │
│ • LEDs Status   │    │ • API REST      │    │ • MIDI         │
│ • Contrôles     │    │ • Proxy         │    │ • Sirènes      │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

## 🔄 **Flux de Communication**

### 1. **QML → Node.js**
- **Protocole** : HTTP REST API
- **Endpoint** : `/api/pupitres/status`
- **Fréquence** : Toutes les 2 secondes
- **Données** : Statut des connexions

### 2. **Node.js → PureData**
- **Protocole** : WebSocket
- **URL** : `ws://192.168.1.4X:10002`
- **Données** : Commandes MIDI, contrôle des sirènes

### 3. **PureData → Sirènes**
- **Protocole** : Audio/MIDI physique
- **Sorties** : Haut-parleurs, contrôleurs MIDI

## 📁 **Structure des Fichiers**

```
SirenConsole/
├── QML/
│   ├── Main.qml                    # Application principale
│   ├── controllers/
│   │   ├── ConsoleController.qml   # Contrôleur central
│   │   ├── PupitreManager.qml     # Gestion des pupitres
│   │   ├── WebSocketManager.qml   # Gestion WebSocket
│   │   └── ConfigManager.qml      # Gestion configuration
│   ├── pages/
│   │   └── OverviewPage.qml        # Page principale avec LEDs
│   └── components/
│       └── overview/
│           └── OverviewRow.qml     # Ligne pupitre avec LED
├── webfiles/
│   ├── server.js                   # Serveur Node.js
│   └── puredata-proxy.js          # Proxy WebSocket
└── config.js                      # Configuration pupitres
```

## 🎯 **Gestion des LEDs de Statut**

### **Problème Identifié**
Les LEDs ne s'allument pas car les objets `pupitre1`, `pupitre2`, etc. ne sont pas mis à jour quand le statut change.

### **Solution**
1. **ConsoleController** écoute les signaux de statut
2. **updatePupitreStatus()** met à jour les objets pupitres
3. **OverviewRow** affiche la LED selon `pupitre.status`

### **Code LED (OverviewRow.qml)**
```qml
Rectangle {
    width: 12
    height: 12
    radius: 6
    color: {
        if (!pupitre) return "#666666"
        switch(pupitre.status) {
            case "connected": return "#00ff00"  // Vert
            case "connecting": return "#ffff00" // Jaune
            case "error": return "#ff0000"     // Rouge
            default: return "#666666"         // Gris
        }
    }
}
```

## 🔧 **Configuration**

### **Fichiers de Configuration**
- `config.json` : Configuration système (sirènes, serveurs)
- `SirenConsole/config.js` : Configuration pupitres (IPs, ports)

### **IPs des Pupitres**
- P1 : `192.168.1.41:10002`
- P2 : `192.168.1.42:10002`
- P3 : `192.168.1.43:10002`
- P4 : `192.168.1.44:10002`
- P5 : `192.168.1.45:10002`
- P6 : `192.168.1.46:10002`
- P7 : `192.168.1.47:10002`

## 🚀 **Démarrage**

### **1. Serveur (F#)**
```bash
franz run console-server   # SirenConsole/webfiles, voir son README.md
```

### **2. Application QML**
```bash
# Compilation
cd SirenConsole
./scripts/build.sh

# Lancement
open http://localhost:8001/appSirenConsole.html
```

## 🐛 **Débogage**

### **Logs Importants**
- **Node.js** : `✅ Connecté à Pupitre X (PX)`
- **QML** : `📊 Statut pupitres: X/7 connectés`
- **LED** : `🔄 Mise à jour statut pupitre: PX -> connected`

### **Test LED**
```javascript
// Dans la console QML
consoleController.testLedUpdate()
```

## 📊 **API Endpoints**

- `GET /api/pupitres/status` : Statut de tous les pupitres
- `GET /api/pupitres/{id}/status` : Statut d'un pupitre spécifique
- `GET /api/puredata/status` : Statut PureData

## 🎯 **Prochaines Étapes**

1. **Tester la fonction `testLedUpdate()`** pour vérifier que les LEDs fonctionnent
2. **Vérifier que les signaux sont bien connectés** dans `ConsoleController`
3. **S'assurer que l'API `/api/pupitres/status`** retourne les bonnes données
4. **Tester avec un pupitre réel** pour valider l'architecture complète
