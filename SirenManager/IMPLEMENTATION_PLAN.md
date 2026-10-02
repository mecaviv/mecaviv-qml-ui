# Plan d'implémentation SirenManager

## Statut actuel
- ✅ Structure de base (CMakeLists.txt, main.cpp, Main.qml)
- ✅ 10 vues créées (stubs seulement)
- ✅ Configuration (SirenConfig, MachineType)
- ✅ UdpController (structure de base)
- ✅ Backend Node.js (server.js, ssh-proxy.js)
- ✅ Backend F# (`SirenManager/backend/fsharpwebserver`) — même contrat ; c'est le processus à lancer

## À implémenter

### 1. Composants réutilisables
- [ ] SirenButton.qml - Bouton personnalisé pour sirènes
- [ ] PlaylistSlot.qml - Slot de playlist (48 slots)
- [ ] ClockDisplay.qml - Affichage de l'heure
- [ ] MachineSelector.qml - Sélecteur de machine
- [ ] MidiController.qml - Contrôleur MIDI

### 2. PlayerView (FirstViewController)
- [ ] Séquenceur MIDI (viewSeq)
- [ ] Contrôles play/stop/reset/boucle
- [ ] Index et mesure
- [ ] Synchronisation
- [ ] Slider de temps
- [ ] Support MIDI

### 3. MixerView (SecondViewController)
- [ ] Contrôleurs de volume S1-S8
- [ ] Sourdines S1-S7
- [ ] Timbre S5-S7
- [ ] LED S1-S8
- [ ] Volumes GN (haut/bas) S1-S7
- [ ] Presets LED
- [ ] Boutons Mute

### 4. MaintenanceView
- [ ] Sliders moteurs S1-S7
- [ ] Sliders clapets S1-S7
- [ ] Switches KEB S1-S7
- [ ] Switch ST et Trompe
- [ ] Transposition globale
- [ ] Table de listes

### 5. SystemMaintenanceView
- [ ] Sélection machine
- [ ] Affichage RAM/disque
- [ ] Logs dmesg avec filtres
- [ ] Gestion playlists (upload/download)

### 6. PlaylistComposerView
- [ ] 48 slots de playlist
- [ ] Liste fichiers MIDI disponibles
- [ ] Drag & drop
- [ ] Upload/download via SSH

### 7. Autres vues
- [ ] SireniumView
- [ ] ControleurView (contrôleurs MIDI)
- [ ] PianoView
- [ ] VoitureView
- [ ] PavillonView

### 8. Finalisation
- [ ] Toutes les commandes UDP
- [ ] Parsing complet playlists
- [ ] Intégration WebSocket
- [ ] Tests complets

## Retour de production (2026-05-25)

Première utilisation en production confirmée : administration via interface
considérée pratique et fiable sur le périmètre testé (Player, Maintenance,
SystemMaintenance, PlaylistComposer, sirènes S1–S7 + Maître + Pi5).

### À ajouter (manqué en prod)
- [ ] Presets de lumière (équivalents des "Presets LED" de la `MixerView`,
      à recroiser avec `SecondViewController.m` côté legacy pour la liste
      exacte et les opcodes UDP)
- [ ] Reset individuel par sirène (actuellement le reset est global ou
      passe par `SystemMaintenanceView` ; ajouter un bouton par sirène
      depuis `MixerView` ou `MaintenanceView`)

### À corriger (bugs UX repérés en prod)
- [ ] `SystemMaintenanceView` non scrollable : la section dmesg en bas du
      `ColumnLayout` est hors écran et inaccessible. Envelopper le contenu
      dans un `ScrollView` / `Flickable` (le `TextArea` MIDI distants a déjà
      son propre ScrollView, mais le conteneur principal n'en a pas).

### À valider (non testé en prod, accès matériel requis)
- [ ] Vue Pavillons : envoi UDP réel vers `pavillon1` / `pavillon2`
- [ ] Vue Voitures : envoi UDP réel vers `voitureA` / `voitureB` ("pchits")
- [ ] Workflow MIDI swap voitures (cf. memory `reference_midi_swap_workflow`)


## Onglet SYSTÈME : décisions et limites connues (2026-10-02)

### Reboot
- Le compte `guest` des Artila **ne peut pas** lancer `reboot` (BusyBox 1.00 : « You have no permission
  to run this applet! ») : les boutons Reboot / Reboot all échouaient. `root@carte` fonctionne.
- Correctif (backend, `SshProxy.rebootAsRoot`) : `/api/ssh/execute` lance **exactement** la commande
  `reboot` en root (`ssh -l root <alias>`, mêmes clés et réglages que `~/.ssh/config`), sur sa propre
  connexion (pas de connexion partagée gardée ouverte pour root). Rien d'autre n'est lancé en root.
  Le QML n'a pas changé. À valider sur la carte (la coupure de la liaison pendant le reboot = succès).

### Cartes sans réponse (partage NFS du banc de dev)
- Sur le banc, la Maître monte le partage NFS du Mac. Quand il bloque, `df` et la lecture de
  `/proc/mounts` ne reviennent plus, puis sshd ne répond plus (ping ok, bannière en timeout).
  La production n'a pas de montage NFS.
- Une seule requête à la fois par carte : sans échéance, une requête bloquée gèlerait l'onglet.
  Chaque type de requête a donc une échéance (`Scheduler.defaultPolicy.TimeoutMs`) : 10 s pour
  meminfo + df, 15 s pour les suivis, 25 s pour disque/listes, 60 s pour le reste.
  Après l'échéance : erreur « timeout » et la file continue. Le processus bloqué reste sur la carte
  (impossible à tuer d'ici) : il faut réparer le montage ou redémarrer.

### Lecture des fichiers MIDI
- Les infos (durée, tempo, canaux, notes, découpe `midi-split`) sont lues **sur la carte** par
  `midi-info-board` (firmwares-artila/tools/midi-split-board), priorité minimale, 1 s de pause par
  fichier, posé dans `/tmp` de la carte à la demande (disparaît au reboot). Résultats mis en cache
  (taille + mtime). La Raspberry Pi lit par ssh (lecture espacée) et analyse côté serveur.
- Les listes « MIDI distants » comparent chaque machine à la Maître (somme de contrôle, canal attendu
  pour S1–S7), et signalent les fichiers que le lecteur C de production ne charge pas.

### Morceau en cours
- La Maître envoie `RU` (lecture, numéro de slot) au démarrage/arrêt d'un morceau et `TI` (temps écoulé) ;
  `UdpManager` les analyse déjà (onglet Player). L'onglet SYSTÈME marque le slot dans la playlist
  active quand la machine affichée est la Maître. À valider avec un morceau réellement lancé.
- Limites : seule la Maître envoie ces trames ; le numéro est celui de sa playlist active
  (`derniere_liste`) ; il faut que l'application soit enregistrée comme interface côté Maître (le
  bouton « synchro » du Player le fait ; l'onglet SYSTÈME envoie aussi `sendAskSynchro` à l'affichage).

### À faire
- [ ] Valider Reboot en root sur une carte (le banc vient d'être redémarré à la main).
- [ ] Lecture de `df` sans passer par `/proc/mounts` si possible, ou le retirer du suivi automatique.
- [ ] Marquer aussi le morceau en cours sur les sirènes (leurs fichiers sont des découpes du même slot).
