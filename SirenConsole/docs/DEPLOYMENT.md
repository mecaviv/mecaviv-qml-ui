# Déploiement SirenConsole

## 🚀 Démarrage Rapide

```bash
# Build + Serveur + Chrome
./scripts/run.sh
```

## 🔧 Configuration

### 1. Vérifier les IPs
```bash
# Tester connectivité
./scripts/test-connections.sh 192.168.1
```

### 2. Configuration Pupitres
- **P1** : `192.168.1.41:10001`
- **P2** : `192.168.1.42:10001`
- **P3** : `192.168.1.43:10001`
- **P4** : `192.168.1.44:10001`
- **P5** : `192.168.1.45:10001`
- **P6** : `192.168.1.46:10001`
- **P7** : `192.168.1.47:10001`

## 📁 Structure

```
SirenConsole/
├── config.js              # Configuration réseau uniquement
├── webfiles/
│   ├── server.js          # Serveur Node.js
│   └── config.js          # Config web
├── QML/                    # Interface Qt
└── scripts/
    ├── run.sh             # Démarrage complet
    └── test-connections.sh # Test réseau
```

## ⚠️ Important

- **Ne pas dupliquer** les données de `config.json`
- **SirenConsole** = Interface de contrôle uniquement
- **Sirènes physiques** = Définies dans `config.json`

## 🔄 Procédure de synchro

1. **Connexion WebSocket** : chaque pupitre doit accepter `ws://<host>:<websocketPort>` (par défaut 10002).
2. **CONFIG_FULL / Upload** :
   - soit SirenePupitre envoie `CONFIG_FULL`/`PUPITRE_STATUS` après un `REQUEST_CONFIG` → le serveur marque `P?` comme synchronisé ;
   - soit l’opérateur déclenche `POST /api/presets/current/upload` (ou le bouton « Upload preset ») pour pousser les paramètres et activer la synchro.
3. **PARAM_UPDATE** : seulement lorsque `GET /api/pupitres/:id/sync-status` renvoie `isSynced: true`.
4. **Vérification** : surveiller `server.js` pour les logs `CONFIG_FULL reçu` et `PARAM_UPDATE`.

Si un preset est illisible, `api-presets.js` sauvegarde automatiquement le fichier corrompu (`presets.json.corrupted-<timestamp>`) puis recrée un set par défaut pour éviter les erreurs 400.

## 🧪 Tests en local

- `SirenConsole/config.js` → mettre `host: "localhost"` pour les pupitres de test.
- `SirenePupitre/config.js` → `serverUrl: "ws://localhost:10002"`.
- Ports critiques à surveiller :
  | Service             | Port |
  |---------------------|------|
  | SirenePupitre HTTP  | 8000 |
  | SirenConsole HTTP   | 8001 |
  | WebSocket Pupitre   | 10002 |
  | Cursor (par défaut) | 10001 |
- Utiliser `lsof -i :PORT` pour diagnostiquer les conflits (`ECONNRESET`, `socket hang up`, etc.).
- Après démarrage, lancer un `Upload preset` pour initialiser `syncState` avant de tester l’UI.
