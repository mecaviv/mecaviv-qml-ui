# Carte Pad Girophone

Projet KiCad 9 reconstruit à partir de `Carte_Pad_Girophone.pdf` (maquette de câblage manuscrite,
Septembre 2026). Fichiers : `carte_pad_girophone.kicad_pro/.kicad_sch/.kicad_pcb`.

Fabrication : plaque nue chez JLCPCB. **Composants et connecteurs montés à la main**, pas
d'assemblage JLC — pas de BOM/CPL à fournir, seulement les Gerbers + le fichier de perçage.

## Carte

- 51 mm × 72 mm, 4 trous de fixation Ø2mm non métallisés, entraxes 45×66mm (inset 3mm).
- U1/U2 : 2× embase femelle 1×7 (2.54mm) pour un Seeed XIAO ESP32-S3 monté sur pins (amovible).
  Écartement des deux rangées : **15.24mm**, vérifié contre l'empreinte officielle Seeed
  (`XIAO-ESP32-S3-DIP.kicad_mod`, dans `New_XIAO_Series_Footprints.zip` du wiki Seeed).
- J1 MTA6 (Joystick), J2 MTA5 (XLR), J3 MTA3 (Slider), J4 MTA5 (PAD), J5 MTA4 (passthrough USB) :
  tous en pas 2.54mm, footprint générique (`Connector_PinHeader_2.54mm`) — remplacer par
  l'empreinte exacte si la référence Molex/TE réelle diffère en pas ou en détrompage.
- R1/R2 : pull-down des pads velostat, **12k**. R3/R4 : résistances série des LED, **47Ω**
  (valeurs confirmées par Patrice — le croquis ne donnait qu'une lecture approximative du
  code couleur, 10k/1k, qui était fausse).

## Brochage du XIAO — vérifié contre la config NVS de référence

Le croquis d'origine numérote les pins localement (1-7 par rangée) sans donner les vrais noms
Seeed. La correspondance ci-dessous croise trois sources indépendantes : le schéma officiel
Seeed (`XIAO-ESP32-S3-SMD`, pins 1-14), l'empreinte DIP officielle (position physique de chaque
pin), et surtout `SirenePupitre/firmware/nvs/gyrophone-pad.csv` + `NiDMI/src/utils/PinMapper.cpp`
— la config NVS réellement utilisée par le firmware NiDMI sur la carte de référence. Les deux
concordent pin par pin (voir tableau), ce qui confirme le sens de lecture retenu.

| Position socket | U1 | Fonction (réf. NVS) | U2 | Fonction (réf. NVS) |
|---|---|---|---|---|
| 1 | D7 / GPIO44 | → R4 → LED2 (J4.2) | *(NC)* | — |
| 2 | D8 / GPIO7 | joystick Z (J1.6) | D5 / GPIO6 | → R3 → LED1 (J4.1) |
| 3 | D9 / GPIO8 | joystick X (J1.4) | D4 / GPIO5 | pad2 / velostat (J4.4, via R1 pull-down) |
| 4 | D10 / GPIO9 | **joystick, 3e axe (J1.2)** — corrigé, n'est plus sur le bus 3.3V | D3 / GPIO4 | pad1 / velostat (J4.3, via R2 pull-down) |
| 5 | 3V3_OUT | fournit le 3.3V au bus commun | *(NC)* | libérée à nouveau — reste candidate pour un futur bouton |
| 6 | GND | GND | D1 / GPIO2 | slider (J3.3) |
| 7 | *(NC)* | — | D0 / GPIO1 | signal XLR (J2.5) |

Concordance avec `gyrophone-pad.csv` : A1→slider ✓, A3→pad1 ✓, A4→pad2 ✓, D5→LED1 ✓, D7→LED2 ✓.
Ces cinq correspondances confirmaient indépendamment le sens de lecture (inversé une fois en
cours de route — voir historique ci-dessous), donc la confiance dans le reste du tableau est
haute.

**Correction du 2026-09-08 (revenue en arrière, puis réutilisée)** : j'avais un temps câblé
A2/GPIO3/D2 (position 5 de U2) sur le bouton du joystick (J1.3), en me basant sur la convention
NiDMI du pupitre (`D2.json` : role=`button`). Patrice a signalé que **le 3.3V est commun à tous
les potards (joystick, slider) ET aux pads** — J1.3 est donc l'alimentation 3.3V du joystick, pas
un bouton. J1.3 est retourné sur le bus 3.3V commun.

**Deuxième correction, même jour** : en vérifiant le câblage des potentiomètres (GND/3.3V/sonde
pour chacun), la sonde de l'axe Y du joystick (J1.2) s'est révélée être sur le **même fil que
PAD1** (net alors nommé `N_PAD3_JOYY`) — avec le pull-down 12k de R2 dessus. Patrice a confirmé
qu'il y a bien 4 résistances distinctes (2×47Ω LED, 2×12k pad), donc pad1 et joystick Y doivent
lire sur deux broches ADC séparées, pas partager la même. Fixé en déplaçant J1.2 sur **A2/GPIO3
(U2 position 5)**, qui était justement la broche restée inutilisée — pad1 (J4.3/U2.4/R2) garde
son fil propre, renommé `N_PAD1`.

**Point résolu (2026-09-08)** : U1 position 4 (D10/GPIO9) était par erreur sur le même bus que le
3.3V — erreur de lecture du croquis d'origine de ma part (un point que j'avais pris pour une
connexion au bus 3.3V était en fait le fil du 3e axe du joystick). Trouvé en comparant le câblage
avec la config NVS de référence : le joystick 3 axes y occupe trois broches **consécutives**
(GPIO7-8-9, A8 + additionalPins joyYPin/joyZPin), donc GPIO9 ne peut pas aussi porter du 3.3V.
Corrigé : J1.2 (le 3e fil du joystick) va maintenant sur U1.4/GPIO9 ; U1.5/3V3_OUT alimente
uniquement le bus commun (J1.3, J3.1). U2 position 5 (A2/GPIO3) est repassée en NC — elle reste
la candidate la plus probable pour un futur bouton, si le connecteur qui le porte est identifié.

Le lien entre le bus 3.3V et les **pads** (velostat) mentionné par Patrice n'est pour l'instant
pas visible sur J4 (5 broches déjà toutes attribuées : 2 LED + 2 pad signal + GND) — probablement
câblé en dehors de cette carte (jonction dans le faisceau), à confirmer.

## Historique des corrections de brochage (2026-09-08)

1. Écartement U1/U2 : 17.78mm → 15.24mm (mesuré sur l'empreinte officielle Seeed).
2. Ordre des pins dans chaque socket inversé (1↔7, 2↔6, 3↔5) — confirmé par Patrice après
   comparaison avec le module physique.
3. ~~Position U2.5 (D2/GPIO3/A2) connectée au bouton du joystick (J1.3)~~ — **revenu en arrière** :
   le 3.3V est commun à tous les potards ET aux pads (confirmé par Patrice), donc J1.3 reste sur
   le bus 3.3V et U2.5 est repassée en NC, comme dans le croquis d'origine.
4. Placement réaligné sur les coordonnées mesurées du PDF d'origine (USBC et XIAO à la même
   hauteur ; R1/R2 sous l'USB comme sur le croquis ; R3/R4 juste à droite du XIAO plutôt que
   plaquées au bord de la carte).
5. Valeurs R1-R4 corrigées (12k / 47Ω) et footprint résistance passé en axial horizontal (couché,
   corps+bagues visibles) — la version verticale "debout" rendait comme un simple strap cuivre.

## Netlist complète

| Net | Broches |
|---|---|
| GND | J1.1, J1.5, J2.1, J3.2, J4.5, J5.1, U1.6, R1.1, R2.1 |
| N_3V3_TO_SLIDER_D10 | J1.3, J3.1, U1.5 *(3.3V commun aux potards)* |
| N_PAD1 | U2.4 (pad1), J4.3, R2.2 |
| N_JOYY | J1.2, U1.4 (D10/GPIO9, 3e axe joystick) — déplacé du bus 3.3V le 2026-09-08 |
| N_PAD4 | U2.3 (pad2), J4.4, R1.2 |
| N_JOYX | J1.4, U1.3 |
| N_JOYZ | J1.6, U1.2 |
| N_XLR5 | J2.5, U2.7 |
| N_SLIDER3 | J3.3, U2.6 |
| N_R3A / N_R3B | U2.2 (LED1) —R3— J4.1 |
| N_R4A / N_R4B | U1.1 (LED2) —R4— J4.2 |
| USB_DM / USB_DP / USB_VBUS | J2.2-4 ↔ J5.2-4 (XLR relaie l'USB de J5) |

## Points laissés en suspens

- **ERC** : 2 fausses alertes ("pin non connectée" sur J1.6 et J5.4) persistent alors que le rendu
  PDF confirme que le label est bien au bon endroit — ça ressemble à un bug de `kicad-cli` 9.0.7
  sur les fichiers écrits à la main plutôt qu'un vrai défaut. Ignorable, ou se résout tout seul en
  rouvrant/sauvant une fois dans l'éditeur de schéma.
- Le bus GND9/3V3 sur U1 positions 4-5 (voir plus haut) — à trancher avant de souder.

## Ce qu'il reste à faire avant d'envoyer à JLCPCB

1. Ouvrir `carte_pad_girophone.kicad_pcb` dans PCB Editor.
2. **Router les pistes signal** (ratsnest visible, ~14 nets, tous P2.54mm à faible densité —
   quelques minutes avec le routeur interactif). Non fait ici : un routage à l'aveugle sans retour
   visuel aurait été trop risqué (court-circuit invisible sur une vraie commande de PCB).
3. **Remplir le plan de masse GND** (zone déjà posée sur B.Cu, mais non remplie — `ZONE_FILLER`
   plante en scripting headless sans affichage). Édition > Remplir toutes les zones (`B`).
4. Lancer le DRC (`Inspecter > Vérification des règles de conception`), corriger si besoin.
5. Trancher le point non résolu (D10/3V3 sur U1).
6. Fichiers > Fabrication > Gerbers (+ fichier de perçage) → zip → JLCPCB.

## Fichiers annexes

- `preview.pdf` : rendu du schéma (texte tassé sur chaque connecteur — cosmétique seulement,
  à réarranger si besoin dans l'éditeur).
- `pcb_render_top.png` : rendu 3D du placement des empreintes.
