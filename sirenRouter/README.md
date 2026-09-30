# SireneRouter - Centre de Monitoring des Sirènes

## 🎯 Vue d'ensemble

**SireneRouter** est un service de monitoring pour centraliser l'état des sirènes mécaniques et fournir une vue d'ensemble aux consoles de contrôle. Il fonctionne comme un "monitoring center" qui observe l'activité des sirènes et informe les consoles en temps réel.

## 🏗️ Architecture du Système

```
┌─────────────┐     ┌──────────────┐     ┌─────────────┐
│   Sources   │────▶│   PureData   │────▶│   Sirènes   │
│ (Reaper,    │     │   (Client    │     │  (Contrôle  │
│  Sirénium,  │     │    Router)   │     │   MIDI)     │
│  Pupitres)  │     │              │     │             │
└─────────────┘     └──────────────┘     └─────────────┘
       │                     ▲                   
       │                     │                   
       ▼                     │                   
┌──────────────┐             │                   
│   Router     │─────────────┘                   
│ (Monitoring  │                                  
│ + Console)   │                                  
└──────────────┘                                  
```

### Flux de Communication
- **Sources → PureData** : MIDI (Reaper, Sirénium) + UDP (Pupitres)
- **PureData → Router** : WebSocket (demandes de contrôle)
- **Router → PureData** : WebSocket (notifications et autorisations)
- **PureData → Sirènes** : MIDI (si autorisé par Router)
- **Sirènes → Router** : État et monitoring (UDP)

## 🚀 Fonctionnalités Principales

### 1. **Monitoring Centralisé**
- **État des sirènes** : Status, note courante, volume, contrôleurs MIDI
- **Sources actives** : Qui contrôle quoi actuellement
- **Historique** : Log des changements et activités
- **Dashboard web** : Interface de monitoring pour les consoles

### 2. **Communication avec les Consoles**
- **API REST** : Consultation de l'état des sirènes
- **WebSocket** : Notifications temps réel des changements
- **Vue d'ensemble** : État global du système pour les consoles

### 3. **Réception des Données**
- **UDP** : Réception des états des sirènes (monitoring passif)
- **Pas d'envoi** : Le Router ne contrôle pas les sirènes
- **Observation uniquement** : Monitoring sans intervention

## 📁 Structure du Projet

```
SireneRouter/
├── README.md                       # Documentation complète
├── package.json                    # Configuration Node.js
├── src/
│   ├── server.js                   # Serveur principal
│   ├── config.js                   # Configuration du service
│   ├── api/                        # Endpoints REST
│   │   ├── status.js               # État des sirènes
│   │   └── console.js              # API pour consoles
│   ├── websocket/                  # Gestion WebSocket
│   │   ├── connection.js           # Connexions consoles
│   │   └── notifications.js        # Notifications temps réel
│   ├── monitoring/                 # Monitoring UDP
│   │   ├── udpServer.js            # Réception des états
│   │   └── stateManager.js         # Gestion des états
│   ├── console/                    # Logique pour consoles
│   │   ├── stateAggregator.js      # Agrégation des états
│   │   └── notificationManager.js  # Gestion des notifications
│   └── dashboard/                  # Interface web
│       ├── index.html              # Dashboard principal
│       ├── assets/                 # CSS, JS, images
│       └── components/             # Composants web
├── puredata/                       # Patch PureData Router Client
│   ├── router-client.pd            # Client Router principal
│   ├── websocket-client.pd         # Communication WebSocket
│   ├── midi-router.pd              # Routage MIDI conditionnel
│   └── README.md                   # Documentation PureData
├── config/
│   ├── default.json                # Configuration par défaut
│   └── examples/                   # Exemples de configuration
├── scripts/
│   ├── build.js                    # Script de build
│   ├── install.js                  # Script d'installation
│   └── start.js                    # Script de démarrage
├── installer/                      # Scripts d'installation
│   ├── windows/                    # Installateur Windows
│   ├── macos/                      # Installateur macOS
│   └── linux/                      # Installateur Linux
└── docs/                           # Documentation technique
    ├── API.md                      # Documentation API
    ├── PROTOCOL.md                 # Protocoles de communication
    └── DEPLOYMENT.md               # Guide de déploiement
```

## 🔧 Configuration

### Configuration Principale (config/default.json)
```json
{
  "server": {
    "port": 8002,
    "host": "0.0.0.0",
    "cors": {
      "enabled": true,
      "origins": ["*"]
    }
  },
  "websocket": {
    "port": 8003,
    "heartbeat": 30000
  },
  "monitoring": {
    "udp": {
      "port": 8004,
      "address": "0.0.0.0"
    }
  },
  "monitoring": {
    "sources": {
      "reaper": { "enabled": true },
      "sirenium": { "enabled": true },
      "console": { "enabled": true },
      "pupitre": { "enabled": true },
      "external": { "enabled": true }
    }
  },
  "sirenes": {
    "count": 7,
    "protocol": {
      "type": "midi",
      "port": "SireneRouter"
    }
  },
  "logging": {
    "level": "info",
    "file": "logs/sirenrouter.log"
  }
}
```

## 📡 Protocoles de Communication

### 1. **API REST - Consultation de l'État**

#### État de toutes les sirènes
```http
GET /api/status/sirenes
```

#### Réponse
```json
{
  "sirenes": {
    "1": {
      "status": "playing",
      "currentNote": 69.5,
      "volume": 0.8,
      "controller": "reaper",
      "timestamp": "2024-01-01T12:00:00Z",
      "controllers": {
        "wheel": { "position": 45, "velocity": 10.5 },
        "joystick": { "x": 0.0, "y": 0.0, "z": 0.0, "button": false }
      }
    },
    "2": {
      "status": "stopped",
      "controller": null,
      "timestamp": "2024-01-01T12:00:00Z"
    }
  }
}
```

#### État d'une sirène spécifique
```http
GET /api/status/sirenes/1
```

### 2. **WebSocket - Notifications Temps Réel (Consoles uniquement)**

#### Connexion
```javascript
const ws = new WebSocket('ws://localhost:8003');
```

#### Messages entrants (Router → Console)
```json
{
  "type": "sirene_status_changed",
  "data": {
    "sireneId": 1,
    "status": "playing",
    "currentNote": 69.5,
    "volume": 0.8,
    "controller": "reaper",
    "timestamp": "2024-01-01T12:00:00Z"
  }
}
```

```json
{
  "type": "sirene_controller_changed",
  "data": {
    "sireneId": 1,
    "previousController": "console",
    "newController": "reaper",
    "timestamp": "2024-01-01T12:00:00Z"
  }
}
```

### 3. **UDP - Monitoring des Sirènes**

#### Format des trames UDP (Sirène → Router)
```json
{
  "sireneId": 1,
  "status": "playing",
  "currentNote": 69.5,
  "volume": 0.8,
  "frequency": 440.0,
  "rpm": 1200,
  "controllers": {
    "wheel": { "position": 45, "velocity": 10.5 },
    "joystick": { "x": 0.0, "y": 0.0, "z": 0.0, "button": false },
    "gearShift": { "position": 2, "mode": "THIRD" },
    "fader": { "value": 64, "percent": 50.0 },
    "modPedal": { "value": 0, "percent": 0.0 },
    "pad": { "velocity": 0, "aftertouch": 0, "active": false }
  },
  "timestamp": "2024-01-01T12:00:00Z",
  "metadata": {
    "controller": "reaper",
    "session": "concert_2024"
  }
}
```

## 🎛️ Dashboard Web

### Interface de Monitoring
- **Vue d'ensemble** : État de toutes les sirènes
- **Contrôleurs actifs** : Qui contrôle quoi actuellement
- **Historique** : Log des changements et activités
- **Configuration** : Paramètres du Router
- **Statistiques** : Métriques de performance

### URL d'accès
```
http://localhost:8002/dashboard
```

## 🚀 Installation et Utilisation

Le projet de ce dossier est `SirenRouter.fsproj`. Depuis `mecaviv-qml-ui` :

```bash
dotnet watch --non-interactive --project sirenRouter
dotnet run --project sirenRouter
```

Il écoute sur le port 8002. Le module Node présent est `src/api/control.js`.

### Service spécifié

Les étapes qui suivent décrivent le service visé par ce document (API, WebSocket, UDP, tableau de bord).

### Prérequis
- Node.js 18+
- npm ou yarn

### Installation depuis le code source
```bash
# Cloner le projet
git clone <repository>
cd SireneRouter

# Installer les dépendances
npm install

# Configuration
cp config/default.json config/local.json
# Éditer config/local.json selon vos besoins

# Démarrer le service
npm start
```

### Installation avec executable
```bash
# Télécharger l'installeur
# Windows: SireneRouter-Setup.exe
# macOS: SireneRouter.pkg
# Linux: sirenrouter.deb

# Exécuter l'installeur
# Le service sera installé et démarré automatiquement
```

### Service système
```bash
# Démarrer le service
sudo systemctl start sirenrouter

# Arrêter le service
sudo systemctl stop sirenrouter

# Statut du service
sudo systemctl status sirenrouter

# Auto-démarrage
sudo systemctl enable sirenrouter
```

## 🎵 Client PureData

### Architecture PureData
PureData agit comme **hub central** qui traduit tous les protocoles et gère la communication avec le Router.

### Fonctionnalités du patch PureData :
- **Réception** : MIDI (Reaper, Sirénium) + UDP (Pupitres)
- **Communication** : WebSocket bidirectionnel avec Router
- **Routage conditionnel** : MIDI vers sirènes (si autorisé)
- **Gestion des autorisations** : Demande et libération de contrôle

### Messages WebSocket PureData ↔ Router :

#### Demande de contrôle
```json
{
  "type": "request_control",
  "data": {
    "sourceId": "puredata",
    "sireneId": 1,
    "force": false,
    "timeout": 5000
  }
}
```

#### Réponse d'autorisation
```json
{
  "type": "control_granted",
  "data": {
    "sireneId": 1,
    "sourceId": "puredata",
    "requestId": "req_123"
  }
}
```

#### Notification de déconnexion
```json
{
  "type": "control_revoked",
  "data": {
    "sireneId": 1,
    "sourceId": "puredata",
    "reason": "new_source_request"
  }
}
```

#### Libération de contrôle
```json
{
  "type": "control_released",
  "data": {
    "sireneId": 1,
    "sourceId": "puredata",
    "requestId": "req_123"
  }
}
```

## 🔌 Intégration avec les Sources

### SirenConsole
```javascript
// Consultation de l'état des sirènes
const response = await fetch('http://localhost:8002/api/status/sirenes');
const sireneStatus = await response.json();

// Connexion WebSocket pour notifications
const ws = new WebSocket('ws://localhost:8003');
ws.onmessage = (event) => {
  const notification = JSON.parse(event.data);
  if (notification.type === 'sirene_status_changed') {
    // Mettre à jour l'interface avec le nouvel état
    updateConsoleUI(notification.data);
  }
};
```

### Reaper
```javascript
// Reaper envoie simplement du MIDI à PureData
function playSirene(sireneId, note, velocity) {
    // Envoi MIDI vers PureData (qui gère l'autorisation)
    reaper.MIDI_Send(sireneId, 144, note, velocity, 0) // Note On
}
```

### Sirénium
```javascript
// Sirénium envoie simplement du MIDI à PureData
function playSireneFromSirenium(sireneId, note, velocity) {
    // Envoi MIDI vers PureData (qui gère l'autorisation)
    sendMidiToPureData(sireneId, 144, note, velocity, 0)
}
```

### Pupitres (SirenePupitre)
```javascript
// Pupitres envoient des trames UDP à PureData
function playSireneFromPupitre(sireneId, note, velocity) {
    // Envoi UDP vers PureData (qui gère l'autorisation)
    sendUDPToPureData({
        sireneId: sireneId,
        note: note,
        velocity: velocity,
        timestamp: Date.now()
    })
}
```

## 🛠️ Développement

### Scripts disponibles
```bash
# Développement
npm run dev          # Mode développement avec hot reload
npm run test         # Tests unitaires
npm run lint         # Vérification du code

# Build
npm run build        # Build pour production
npm run package      # Créer l'executable
npm run installer    # Créer les installateurs

# Déploiement
npm run deploy       # Déploiement automatique
npm run logs         # Voir les logs
```

### Structure du code
- **src/server.js** : Point d'entrée principal
- **src/api/** : Endpoints REST pour consoles
- **src/websocket/** : Gestion WebSocket pour consoles
- **src/monitoring/** : Monitoring UDP des sirènes
- **src/console/** : Logique pour consoles
- **src/dashboard/** : Interface web de monitoring

## 📊 Monitoring et Logs

### Logs
```bash
# Logs en temps réel
tail -f logs/sirenrouter.log

# Logs avec rotation automatique
# Niveau de log configurable : debug, info, warn, error
```

### Métriques
- **Connexions actives** : Nombre de sources connectées
- **Sirènes contrôlées** : Répartition par source
- **Takeovers** : Nombre de changements de contrôle
- **Latence** : Temps de réponse des API
- **Erreurs** : Taux d'erreur par endpoint

## 🔒 Sécurité

### Authentification (optionnelle)
```json
{
  "security": {
    "enabled": true,
    "apiKey": "your-secret-api-key",
    "allowedSources": ["reaper", "console", "pupitre_*"]
  }
}
```

### Firewall
- **Port 8002** : API REST
- **Port 8003** : WebSocket
- **Port 8004** : UDP Monitoring

## 🐛 Dépannage

### Problèmes courants

#### Service ne démarre pas
```bash
# Vérifier les logs
cat logs/sirenrouter.log

# Vérifier la configuration
node -e "console.log(require('./config/local.json'))"

# Tester la connectivité
curl http://localhost:8002/api/status
```

#### Conflits de ports
```bash
# Vérifier les ports utilisés
netstat -tulpn | grep :8002
netstat -tulpn | grep :8003
netstat -tulpn | grep :8004

# Changer les ports dans config/local.json
```

#### Sirènes non détectées
```bash
# Vérifier le monitoring UDP
tcpdump -i any port 8004

# Tester l'envoi UDP
echo '{"sireneId":1,"status":"test"}' | nc -u localhost 8004
```

## 📚 Documentation Technique

- **[API.md](docs/API.md)** : Documentation complète de l'API REST
- **[PROTOCOL.md](docs/PROTOCOL.md)** : Protocoles de communication détaillés
- **[DEPLOYMENT.md](docs/DEPLOYMENT.md)** : Guide de déploiement avancé

## 🤝 Contribution

### Développement
1. Fork le projet
2. Créer une branche feature (`git checkout -b feature/amazing-feature`)
3. Commit les changements (`git commit -m 'Add amazing feature'`)
4. Push vers la branche (`git push origin feature/amazing-feature`)
5. Ouvrir une Pull Request

### Tests
```bash
# Tests unitaires
npm test

# Tests d'intégration
npm run test:integration

# Tests de performance
npm run test:performance
```

## 📄 Licence

Ce projet est sous licence MIT. Voir le fichier [LICENSE](LICENSE) pour plus de détails.

## 🆘 Support

- **Issues** : [GitHub Issues](https://github.com/your-repo/sirenrouter/issues)
- **Documentation** : [Wiki](https://github.com/your-repo/sirenrouter/wiki)
- **Discussions** : [GitHub Discussions](https://github.com/your-repo/sirenrouter/discussions)

---

**SireneRouter** - Centre de monitoring pour sirènes mécaniques 🎵
