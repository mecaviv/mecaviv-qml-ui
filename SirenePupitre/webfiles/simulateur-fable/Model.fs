/// What the simulator sends and shows: siren ranges, function names, menu.
/// SIRENES rows come from pupitre-sirens.csv (playable min, category max + 12, restricted max).
module Simulateur.Model

type Siren =
  { n     : int
    nom   : string
    min   : int
    max   : int
    rmax  : int }

let sirenes =
  [| { n = 1; nom = "S1 alto";   min = 43; max = 86; rmax = 72 }
     { n = 2; nom = "S2 alto";   min = 43; max = 86; rmax = 72 }
     { n = 3; nom = "S3 basse";  min = 36; max = 77; rmax = 60 }
     { n = 4; nom = "S4 ténor";  min = 36; max = 79; rmax = 60 }
     { n = 5; nom = "S5 soprano"; min = 48; max = 94; rmax = 84 }
     { n = 6; nom = "S6 soprano"; min = 48; max = 94; rmax = 84 }
     { n = 7; nom = "S7 piccolo"; min = 48; max = 94; rmax = 84 } |]

let fonctions =
  [| "velocite"
     "vibrato.profondeur"
     "vibrato.vitesse"
     "tremolo.profondeur"
     "tremolo.vitesse"
     "attaque"
     "relache"
     "bend" |]

/// Fonctions sans autonomie (expression du joueur, ajoutée même quand la partition joue).
let sansAutonomie = set [ "bend" ]

let sources =
  [| "aucun"; "pads"; "pad1"; "pad2"; "slider"; "pedale"; "joystick.x"; "joystick.y"; "joystick.z" |]

let menu =
  [| "jeu.libre"; "jeu.partition"; "calibration"; "mapping"; "admin" |]

let ccNoms =
  [ 1, "vibrato prof."
    9, "vibrato vit."
    92, "trémolo prof."
    15, "trémolo vit."
    73, "attaque"
    72, "relâchement"
    5, "portamento"
    121, "reset" ]
  |> Map.ofList

let contextes =
  [| "menu"; "jeu.libre"; "jeu.partition"; "calibration"; "mapping" |]
