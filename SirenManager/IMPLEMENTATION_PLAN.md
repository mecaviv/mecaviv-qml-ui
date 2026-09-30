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

