# Risques liés à la sémantique « nombre » vs « chaîne » (audit statique)

Ce document recense les **défaillances possibles** quand des valeurs numériques circulent en JSON ou en QML tantôt comme `number`, tantôt comme `string` (`"1"`, `"480"`), alors que le code teste **`typeof x === "number"`** ou compare avec **`===`** sans coercition.

Il ne prétend pas être une liste d’incidents runtime observés : ce sont des **zones à risque** identifiées dans le dépôt `mecaviv-qml-ui` (recherche `typeof … === "number"`, lecture des chemins `PARAM_UPDATE`, templates de config).

---

## 1. Mécanismes d’échec typiques

| Mécanisme | Effet utilisateur / technique |
|-----------|-------------------------------|
| **Garde `typeof x === "number"`** | Si `x` est `"123"`, la branche est **ignorée** : durées nulles, pas de fin de note, pas de `ppq`, pas de phase/harmonique, etc. |
| **`===` entre id et littéral** | `1 === "1"` est **faux** : sélection, filtrage, indexation ratés. |
| **Tri / soustraction** | `a.tick - b.tick` peut **coercer** des strings numériques en nombre en JS, mais reste fragile si `NaN` ou mélange de types. |
| **Index de tableau** | `path[2]` numérique vs chaîne : chemins `sirens` / copie de tableau / logs de debug interprètent différemment index 0-based et id sirène. |
| **`parseInt` sans radix ou chaîne non trim** | Comportements inattendus sur entrées partielles ; préférer `Number(x)` ou `parseInt(String(x), 10)` avec contrôle `isFinite`. |

---

## 2. Fichiers et comportements à risque (inventaire)

### 2.1 `SirenePupitre/QML/game/microtonal/ConductorCueDriver.qml`

**Rôle** : charger et interpréter les cues conducteur (JSON) — ticks, barres, `durationTicks`, `endTick`, métadonnées MIDI, etc.

**Points sensibles** :

- **`_asFiniteNumber`** (vers L302+) : normalise correctement nombre et chaîne numérique pour certains chemins ; **les autres** restent soumis à des gardes `typeof … === "number"` **sans** passage par cette fonction.
- Champs vérifiés uniquement si type `number` (exemples repérés) : `durationTicks`, `endTick`, `tick`, `durationTicks` + `tick` combinés, `endBar`, `voletOpen`, `doc.metadata.ppq`, `data.phase`, `data.harmonicIndex`, `beatsPerBar`, indices de gear/volet (L120), `beat` dans un contexte transport.
- **Conséquence** : un export JSON où ces champs sont des **strings** (souvent le cas après copier-coller ou outils qui sérialisent tout en texte) fait **sauter** la logique de durée, de synchronisation barre/tick, ou la lecture du `ppq`.
- **Partiellement protégé** : `_cueMatchesChannel` utilise `parseInt` pour `sirenTrackIndex` si ce n’est pas un `number` ; le filtrage par sirène côté config (`id` / `midiChannel`) parse aussi les ids.

**Symptômes possibles** : silence ou cues « figés », durées incorrectes, mauvais canal piste si seulement certains champs sont string.

---

### 2.2 `SirenePupitre/QML/controllers/ConfigController.qml`

**Rôle** : config pupitre, `setValueAtPath`, normalisation des ids sirène.

**Mitigations déjà en place** :

- `normalizeSirenNumericIds` : convertit `sirens[].id` et `currentSirens[]` en nombres au chargement.
- Pour `sirenConfig.currentSirens`, les écritures mappent chaînes → `parseInt`.
- Résolution `path` : `sirens` accepte index **number** ou **string** id (legacy) et réécrit l’index.

**Risques résiduels** :

- **`path[2] === "number"`** (copie du tableau `sirens` après mutation) : si un segment reste une chaîne id au lieu d’un index numérique résolu, la branche « copie pour bindings » peut ne pas s’appliquer comme prévu.
- **`typeof id === "number"`** dans certains chemins (ex. autour de L402) : une id encore string après une voie d’entrée atypique peut être **rejetée** ou mal traitée.
- Comparaison **`Number(sirens[i].id) === Number(primarySiren.id)`** (L358 environ) : bonne pratique ; à généraliser partout où des `===` directs sur `id` subsisteraient ailleurs.

---

### 2.3 `SirenePupitre/QML/controllers/WebSocketController.qml`

- **`GEAR`** : `data.position` doit être un `number` ; sinon position **0** (défaut). Une position `"2"` en string → **traitée comme 0**.
- **`PARAM_UPDATE`** : Délégation à `setValueAtPath` ; le typage des **segments de path** (nombre vs chaîne) reste aligné avec `ConfigController`.
- **Debug frettedMode** : `isNumericIndex = typeof sirenIdentifier === "number"` — le log seulement interprète autrement index vs id ; pas un bug fonctionnel mais confusion possible au diagnostic.

---

### 2.4 `SirenePupitre/QML/game/SequencerController.qml`

- `beat` : si ce n’est pas un `number` fini, retombée sur **1** — perte du beat réel si la source envoie une string.

---

### 2.5 `SirenePupitre/QML/game/microtonal/MicrotonalMath.js`

- `semitoneRange` : comme pour `beat`, défaut si pas `number` — chaîne non prise en charge.

---

### 2.6 `SirenConsole/webfiles/server.js`

- **Normalisation** fréquente : `assignedSirenes` / `currentSirens` mappés avec `typeof n === 'number' ? n : parseInt(String(n), 10)`.
- **Réception `currentSirens`** : `typeof v === 'string' ? parseInt(v, 10) : v` — les **nombres** passent tels quels ; cohérent si l’UI envoie déjà des numbers.
- **Risque** : tout chemin qui **n’applique** pas cette normalisation avant stockage ou renvoi vers le pupitre peut réintroduire des strings.

---

### 2.7 `SirenConsole/webfiles/puredata-proxy.js`

- Même logique `currentSirens` → `parseInt` pour les strings ; même limite si un nombre est attendu ailleurs sans garde.

---

### 2.8 Templates et exemples de configuration

- **`config.template.json`** (racine du dépôt) : **aligné sur les nombres** depuis octobre 2026 (`"id": 1`, `currentSirens: [1]`, comme `SirenePupitre/config.js`). Il portait auparavant des chaînes (`"id": "1"`, `currentSirens: ["1"]`).
- **Effet** : les `config.json` créés avant cet alignement peuvent encore contenir des chaînes ; le pupitre les compense via `normalizeSirenNumericIds`.

---

### 2.9 Fichiers Emscripten / WASM (`appSirenePupitre.js`, `appSirenConsole.js`, etc.)

- `assert(typeof ptr === "number")` : concerne les **pointeurs WASM**, pas la sémantique JSON métier — **hors périmètre** des risques « id / tick en string », sauf confusion lors d’un grep.

---

## 3. Bonnes pratiques déjà visibles dans le projet

- Comparaison d’ids : **`Number(a) === Number(b)`** dans `AdminPanel.qml`, `SirenSelectionSection.qml`, `Test2D.qml`, `Test2DButtons.qml`, `ConfigController.qml`.
- **`normalizeSirenNumericIds`** au chargement config pupitre.
- **`_asFiniteNumber`** dans `ConductorCueDriver` pour certains chargements — à **étendre** ou à compléter par une passe **unique** à l’import JSON des cues (normaliser tous les champs numériques attendus).

---

## 4. Recommandations (sans modifier le code ici)

1. **Document contractuel** : pour `*_conductor-cues.json`, préciser le type attendu (`number` JSON) pour `tick`, `durationTicks`, `ppq`, etc. — voir aussi `docs/CONDUCTOR_CUES_PROTOCOL.md` si présent.
2. ~~**Aligner les templates**~~ : fait, `config.template.json` utilise des nombres (ids et `currentSirens`).
3. **Normalisation à l’import** : une fonction unique `normalizeCueNumbers(cue)` appelée après `JSON.parse` réduit les branches `typeof === "number"` éparpillées.
4. **Éviter `===` sur valeurs JSON** pour les identifiants et mesures : préférer `Number` / `parseInt` avec `isFinite`, ou schéma validé en amont.

---

## 5. Méthode de reproduction de cet inventaire

- Recherche ciblée : `typeof` + `"number"` dans `*.qml` et `*.js` du dépôt (hors bundles minifiés si applicable).
- Lecture des sections `PARAM_UPDATE`, `setValueAtPath`, `GEAR`, et du driver de cues microtonal.

**Date de rédaction** : 2026-03-28.
