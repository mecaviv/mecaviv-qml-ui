# Démarrage de SirenManager

## Démarrage rapide

1. **Démarrer le serveur HTTP :**
   ```bash
   cd webfiles
   node server.js
   ```

2. **Ouvrir dans le navigateur :**
   - http://localhost:8080/appSirenManager.html

## Avec le backend SSH (optionnel)

Pour utiliser les fonctionnalités de maintenance système, démarrez aussi le backend :

```bash
dotnet watch --non-interactive --project SirenManager/backend/fsharpwebserver
dotnet run --project SirenManager/backend/fsharpwebserver
```

Le backend écoute sur :
- HTTP API: http://localhost:8005
- WebSocket: ws://localhost:8006

## Ports utilisés

- **8080** : Serveur HTTP pour l'application WebAssembly
- **8005** : Backend HTTP API (SSH proxy)
- **8006** : Backend WebSocket (UDP proxy + communication temps réel)


