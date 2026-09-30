# Serveur de connexion aux sirènes — plan

Septembre 2026. Propositions à valider par Gauthier ; Patrice porte le travail, Joseph en appui.
Le volet ComposeSiren (SirenLink, c-siren~, pont UDP de SirenOrchestra) est dans la note de
discussion du dépôt ComposeSiren ; ce document couvre ce qui vit dans `mecaviv-qml-ui`.

## Constat

Quatre clients parlent directement aux cartes des sirènes, chacun avec ses adresses en dur, son
handshake et, pour ceux qui le font, sa propre lecture des variateurs KEB :

| Client | Où | Comment |
|---|---|---|
| patch Pd `sirenMidi2Udp` (régie, concert) | puredata-abstractions | `udpSend` par sirène, `connect` au chargement |
| pédalier Sirénium (Pd sur Raspberry) | pedalierSirenium | neuf sockets ouvertes au chargement ; si le réseau est en retard, la session tourne sans sirène (`deploy/device/wait-network.sh`) |
| pont `SirenUdpBridge` de SirenOrchestra | ComposeSiren | thread JUCE, IPs et type de KEB en constantes |
| SirenManager (remplace SireneControlMac) | SirenManager/src/UdpController + backend/fsharpwebserver | mêmes trames et opcodes que l'app Obj-C historique ; relais UDP ↔ WebSocket pour la version WASM, écoute sur 8000. `server.js` est le code Node d'origine |

`sirenRouter/` est le point central prévu, mais conçu en monitoring passif (« le Router ne
contrôle pas les sirènes ») et à l'état de spécification : seul `src/api/control.js` (takeover
REST, dernier arrivé premier servi) existe.

## Décision : le serveur de connexion est le service de SirenManager

SirenManager est indispensable dans tous les cas de figure : c'est le produit de régie. Son
backend (`backend/fsharpwebserver`) est donc *le* service du parc, et les autres clients (SirenOrchestra via
SirenLink, patch Pd, pédalier) lui parlent — comme les pupitres parlent à SirenConsole.
`sirenRouter/` disparaît : son takeover (`control.js`) est absorbé, sa spec « monitoring
passif » ne correspond plus à rien.

L'application QML SirenManager ne change pas : elle devient un client de son propre service,
séparée de lui dans le code et les processus, pas dans le déploiement — UI et service
s'installent ensemble.

SirenManager est le successeur de SireneControlMac, l'application macOS historique de régie
(playlists, séquenceur, maintenance, ST, KEB, volets, SSH vers les cartes). Son backend porte
donc déjà le protocole complet du parc, pas seulement le MIDI — c'est ce qui en fait le bon
point de départ.

`SirenManager/backend/fsharpwebserver` sert le contrat de `server.js` : les sockets, la
table du parc (`backend/config.json`), le port 8000 où le firmware — et les KEB — répondent, un
relais UDP ↔ WebSocket, et un jeu de commandes plus large que le MIDI (ST, vitesse KEB, volets,
playlists, synchro). On y ajoute le bail de `control.js`, et ce service devient le serveur de
connexion. Deux processus sur le port 8000 se partageraient le trafic entrant au hasard —
c'est aussi ce qui interdit un second service à côté.

Conditions :

1. **Service toujours actif, avec ou sans UI ouverte.** Aujourd'hui le socket UDP n'est ouvert
   que quand un client WebSocket est connecté. Le service est lancé par systemd et tient ses
   sockets en permanence ; SirenManager desktop passe aussi par lui (plus de socket UDP propre
   dans `UdpController`, donc plus de second listener sur 8000).
2. **Un processus, des modules lisibles.** Bail / état / relais d'un côté, proxy SSH et
   playlists de l'autre. Même dépôt, le projet `backend/fsharpwebserver`, fichiers séparés.
3. **Une seule table du parc.** `backend/config.json` est aujourd'hui la plus complète (Linux
   Maître, Raspberry clic, S1–S7, voitures, pavillons). On y ajoute les KEB (`192.168.1.70–76`,
   port 8000, type F5/F6 — seule S4 est en F6 depuis avril 2026) et le port des cartes (8001).
   Ce fichier devient la source de vérité que `SirenLink` (ComposeSiren) lit aussi.

Emplacement : le code reste dans `SirenManager/backend/`. Ports : 8005 (HTTP) et 8006
(WebSocket) actuels, plus 8004 (UDP, bail). Les 8002/8003 prévus pour sirenRouter n'ont jamais
servi. Le dossier `sirenRouter/` est supprimé.

## Le bail : une condition, pas une obligation

Chaque client garde un accès direct aux cartes. S'il y a un serveur, il lui demande la main
avant d'émettre du MIDI ; sinon il émet comme aujourd'hui. Pas de point de panne unique,
migration client par client.

- **Bail par sirène**, valable T secondes (proposition : 5 s), renouvelé par heartbeat toutes
  les 2 s. Un autre client prend la main → refus de renouvellement → le premier s'arrête à
  l'expiration, même s'il a raté le message (UDP).
- **Demande répétée en continu** : un client lancé avant le serveur est repris dès que le
  serveur répond.
- **UDP texte sur 8004** — `[netsend -u]` côté Pd, `DatagramSocket` côté JUCE, `dgram` côté Node :

```
client → serveur :  request <sourceId> <sirène|all>     (répété = heartbeat)
                    release <sourceId>
serveur → client :  grant <sourceId> <sirène> <ttl>
                    deny  <sourceId> <sirène> <détenteur>
```

Ce que ça ne donne pas : le serveur sait qui a la main, pas ce qui est joué. Le monitoring des
notes viendra après, quand le serveur tiendra lui-même le polling KEB et que les clients lui
remonteront leur activité.

## Ce que le serveur tient

| Rôle | Aujourd'hui | Après |
|---|---|---|
| Table du parc | `backend/config.json`, `SirenConfig.h`, `MachineType.h`, `SirenUdpBridge.h` | `config.json` seul, lu par tous |
| Port 8000 (réponses firmware, KEB) | backend, ouvert à la demande | serveur, permanent |
| Bail / qui a la main | `control.js` REST, jamais déployé | UDP 8004, dans le serveur |
| État ST des sirènes | pont JUCE, polling par client | serveur, un seul polling, diffusé en WebSocket |
| Relais UDP ↔ WebSocket | backend, WASM seulement | serveur, desktop et WASM |
| Proxy SSH, playlists | backend | serveur, module séparé |

## Lots

### Patrice

1. Service permanent : socket ouvert au démarrage, unité systemd, `sirenRouter/` supprimé
   (`control.js` récupéré) ; `UdpController` desktop passe par le service.
2. Étendre `config.json` (KEB, ports) ; SirenManager lit le parc depuis ce fichier au lieu de
   `SirenConfig.h`.
3. Bail UDP 8004 à partir de `control.js`.
4. Polling KEB F5/F6 dans le serveur, état diffusé aux clients WebSocket.
5. Convertir les clients dans l'ordre : pont JUCE (via SirenLink), patch `sirenMidi2Udp`,
   pédalier, SirenManager.
6. Test sur le parc.

### Joseph

- Rien dans ce dépôt pour l'instant ; son lot est côté ComposeSiren (merge PR #20, scission
  CMake, cible de build c-siren~).

### Validation Gauthier

- après le lot 1 (structure du service) ;
- après le lot 3 testé avec deux clients concurrents ;
- avant mise en concert.

## Mise à jour de la documentation

À faire quand le lot 1 est mergé : `README.md` (retirer la section sirenRouter, ajouter
SirenManager et son service, table des ports), `docs/COMMUNICATION.md` (le UDP n'est plus du
monitoring passif), `SirenManager/README.md` (le service), `TODO.md` (les entrées sirenRouter,
« Client PureData pour communication avec Router » et « Gestion des autorisations de contrôle »
sont ce plan).
