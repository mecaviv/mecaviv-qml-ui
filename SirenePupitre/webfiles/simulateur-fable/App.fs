#nowarn 46 // HTMLInputElement.checked
/// Page wiring: what Pd says, the settings row, the pieces list.
/// Entry point is `main` / `start()` — the same as the old inline script's
/// bottom `connecter(); chargerListe();`.
module Simulateur.App

open Browser.Dom
open Browser.Types
open Fable.Core
open Simulateur.Model
open Simulateur.Ui
open Simulateur.Link
open Simulateur.Widgets

let mutable private etatTransport = "stop"
let mutable private fichierCharge = ""
let mutable private fichiers: string[] = [||]
let mutable private cc = Map.empty<int, int>
let mutable private boutons: Map<string, HeldButton> = Map.empty

let private confirmerParc () =
  confirm "Envoyer aussi aux sirènes physiques du parc (UDP ou rtpmidi) ?"

let private appliquerSirene () =
  let s = select "sirene"
  let frette = input "frette"

  match sirenes |> Array.tryFind (fun x -> string x.n = s.value) with
  | Some r -> envoyer $"config sirene {r.n} {r.min} {r.max} {r.rmax} {(if frette.checked then 1 else 0)}"
  | None -> ()

let private appliquerSon () =
  let on = if (input "son").checked then 1 else 0
  envoyer $"config synthese {on}"
  envoyer $"simulation son {on}"

let dessinerMenu (curseur: int) =
  let items =
    menu
    |> Array.mapi (fun i e ->
      let cls = if i = curseur then "curseur" else ""
      "<li class=\"" + cls + "\">" + e + "</li>")
    |> String.concat ""

  html "menu" items

let dessinerFichiers () =
  if fichiers.Length = 0 then () else

  let f = (input "filtre").value.Trim().ToLowerInvariant()
  let vus = fichiers |> Array.filter (fun p -> f = "" || p.ToLowerInvariant().Contains f)
  text "nb-fichiers" $"{vus.Length} / {fichiers.Length}"

  let groupes = vus |> Array.groupBy (fun p -> p.Split('/')[0])
  let boite = el "fichiers"
  boite.innerHTML <- ""

  for dossier, liste in groupes do
    let det = document.createElement "details"
    setOpen det (f <> "" || (liste |> Array.contains fichierCharge) || groupes.Length = 1)
    let sum = document.createElement "summary"
    sum.textContent <- $"{dossier}  ({liste.Length})"
    det.appendChild sum |> ignore

    for p in liste do
      let b = document.createElement "button"
      b.textContent <- p.Substring(dossier.Length + 1)
      b.title <- p
      if p = fichierCharge then b.className <- "charge"
      b.onclick <- fun _ -> envoyer ("fichier charger " + p)
      det.appendChild b |> ignore

    boite.appendChild det |> ignore

let private voix (m: string list) =
  match m with
  | "note" :: note :: vel :: canal :: _ ->
    text "v-note" $"{note}  (canal {canal})"
    setStyle (el "v-vel") "width" (string (float vel / 127.0 * 100.0) + "%")
  | "bend" :: v :: _ ->
    let demi = (float v - 8192.0) / 8192.0
    let signe = if demi >= 0.0 then "+" else ""
    let d = demi.ToString "0.00"
    text "v-bend" $"{v}  ({signe}{d} demi-ton)"
  | "ctl" :: value :: n :: _ ->
    cc <- cc |> Map.add (int n) (int value)

    let lignes =
      cc
      |> Map.toList
      |> List.sortBy fst
      |> List.map (fun (n, v) ->
        let nom = ccNoms |> Map.tryFind n |> Option.defaultValue ""
        let pct = string (float v / 127.0 * 100.0) + "%"

        "<tr><td>CC "
        + string n
        + "</td><td>"
        + nom
        + "</td><td style=\"width:45%\"><div class=\"barre\"><i style=\"width:"
        + pct
        + "\"></i></div></td><td class=\"valeur\">"
        + string v
        + "</td></tr>")
      |> String.concat ""

    html "v-cc" lignes
  | _ -> ()

let private recevoir (message: string) =
  let m = message.Split ' ' |> Array.toList

  match m with
  | "simulation" :: "voix" :: rest -> voix rest
  | "refus" :: _ ->
    journal message true
    toast message
  | "etat" :: kind :: rest ->
    journal message false

    match kind, rest with
    | "contexte", v :: _ ->
      text "e-contexte" v
      markButtons "contextes" v
    | "mode", v :: _ ->
      text "e-mode" v
      markMode v
    | "menu", v :: _ -> dessinerMenu (int v)
    | "transport", "position" :: tick :: _ -> text "e-transport" $"{etatTransport} · tick {tick}"
    | "transport", v :: _ ->
      etatTransport <- v
      text "e-transport" v
    | "fichier", _ :: rest ->
      fichierCharge <- String.concat " " rest
      text "e-fichier" fichierCharge
      dessinerFichiers ()
    | "edition.mapping", _ :: _ :: rest -> text "e-edition" (String.concat " " rest)
    | "autonomie", f :: v :: _ -> setSelectValue "data-autonomie" f v
    | "mapping", f :: s1 :: rest ->
      let s2 = rest |> List.tryHead |> Option.defaultValue "aucun"
      setSelectValue "data-source1" f s1
      setSelectValue "data-source2" f s2
    | _ -> ()
  | _ -> journal message false

let private onConnected () =
  appliquerSon ()
  appliquerSirene ()
  envoyer ("config volume " + (input "volume").value)
  let ant = (input "anticipation").value
  envoyer ("config anticipation " + (if ant = "" then "0" else ant))
  if (input "parc").checked then envoyer "config parc 1"

let private urlFichiers () =
  (if window.location.protocol.StartsWith "http" then "" else "http://localhost:8000")
  + "/simulation/fichiers"

[<Emit("fetch($0).then(r => { if (!r.ok) throw new Error($0 + ': ' + r.status); return r.json(); }).then($1, $2)")>]
let private fetchJson
  (url: string)
  (ok: {| dossier: string; fichiers: string[] |} -> unit)
  (err: obj -> unit)
  : unit =
  jsNative

let rec private chargerListe () =
  fetchJson
    (urlFichiers ())
    (fun j ->
      fichiers <- if isNull j.fichiers then [||] else j.fichiers

      if fichiers.Length = 0 then
        text "fichiers" $"aucun fichier MIDI dans {j.dossier}"
      else
        dessinerFichiers ())
    (fun _ ->
      text "fichiers" "liste indisponible (serveur ?)"
      setTimeout chargerListe 3000 |> ignore)

let private options (liste: string[]) =
  liste
  |> Array.map (fun v -> "<option value=\"" + v + "\">" + v + "</option>")
  |> String.concat ""

let private tableFonctions () =
  let corps = el "fonctions"

  for f in Array.append [| "volant" |] fonctions do
    let tr = document.createElement "tr"
    let mappable = f <> "volant"

    let col1 =
      if mappable then "<select data-source1=\"" + f + "\">" + options sources + "</select>" else "volant"

    let col2 =
      if mappable then "<select data-source2=\"" + f + "\">" + options sources + "</select>" else ""

    let auto =
      if sansAutonomie.Contains f then
        "joueur"
      else
        "<select data-autonomie=\"" + f + "\">" + options [| "joueur"; "partition" |] + "</select>"

    tr.innerHTML <-
      "<td>"
      + f
      + "</td><td>"
      + auto
      + "</td><td>"
      + col1
      + "</td><td>"
      + col2
      + "</td>"

    corps.appendChild tr |> ignore

  corps.addEventListener ("change", fun e ->
    let t = e.target :?> HTMLSelectElement

    if not (isNull t.dataset["autonomie"]) then
      envoyer ("autonomie " + t.dataset["autonomie"] + " " + t.value)

    let f =
      if isNull t.dataset["source1"] then t.dataset["source2"] else t.dataset["source1"]

    if not (isNull f) then
      let get (attr: string) =
        let mutable v = ""
        forEachNode (selectBy attr f) (fun e -> v <- (e :?> HTMLSelectElement).value)
        v

      envoyer ("mapping " + f + " " + get "data-source1" + " " + get "data-source2"))

let private onOff (id: string) (f: unit -> unit) =
  (input id).onchange <- fun _ -> f ()

let start () =
  vitesses ()

  let b1 = boutonTenu (el "b1") "bouton 1 1" "bouton 1 0" (Some(input "maintien-b1"))
  let b2 = boutonTenu (el "b2") "bouton 2 1" "bouton 2 0" (Some(input "maintien-b2"))
  boutons <- Map.ofList [ "1", b1; "2", b2 ]

  (el "reset").onclick <- fun _ ->
    for g in [ "bouton 1 1"; "bouton 2 1"; "bouton 1 0"; "bouton 2 0" ] do
      geste g

  window.addEventListener ("keydown", fun e ->
    let e = e :?> KeyboardEvent

    if not e.repeat && (e.target :?> HTMLElement).tagName <> "INPUT" then
      match boutons |> Map.tryFind e.key with
      | Some b -> b.presse ()
      | None -> ())

  window.addEventListener ("keyup", fun e ->
    let e = e :?> KeyboardEvent

    match boutons |> Map.tryFind e.key with
    | Some b -> b.relache ()
    | None -> ())

  volant ()
  encodeur ()
  pad (el "pad1") 1 (input "maintien1")
  pad (el "pad2") 2 (input "maintien2")
  joystick ()

  boutonTenu
    (el "joy-bouton")
    "joystick bouton appui 100"
    "joystick bouton relache 0"
    (Some(input "maintien-joy"))
  |> ignore

  (input "slider").addEventListener ("input", fun e ->
    geste ("slider " + (e.target :?> HTMLInputElement).value))

  (input "pedale").addEventListener ("input", fun e ->
    geste ("pedale " + (e.target :?> HTMLInputElement).value))

  let s = select "sirene"

  for r in sirenes do
    let o = document.createElement "option" :?> HTMLOptionElement
    o.value <- string r.n
    o.textContent <- r.nom
    s.appendChild o |> ignore

  s.value <- "3"
  onOff "sirene" ignore
  s.onchange <- fun _ -> appliquerSirene ()
  onOff "frette" appliquerSirene

  forEachNode (queryAll document.body "[data-mode]") (fun b ->
    let h = b :?> HTMLElement
    h.onclick <- fun _ -> envoyer ("mode " + h.dataset["mode"]))

  let box' = el "contextes"

  for c in contextes do
    let b = document.createElement "button"
    b.textContent <- c
    b.dataset["valeur"] <- c
    b.onclick <- fun _ -> envoyer ("contexte " + c)
    box'.appendChild b |> ignore

  forEachNode (queryAll document.body "[data-transport]") (fun b ->
    let h = b :?> HTMLElement
    h.onclick <- fun _ -> envoyer ("transport " + h.dataset["transport"]))

  (input "filtre").addEventListener ("input", fun _ -> dessinerFichiers ())

  onOff "anticipation" (fun () ->
    let v = (input "anticipation").value
    envoyer ("config anticipation " + (if v = "" then "0" else v)))

  onOff "son" appliquerSon

  (input "volume").addEventListener ("input", fun e ->
    let t = e.target :?> HTMLInputElement
    text "volume-db" (t.value + " dB")
    envoyer ("config volume " + t.value))

  (input "parc").onchange <- fun e ->
    let t = e.target :?> HTMLInputElement

    if t.checked && not (confirmerParc ()) then
      t.checked <- false
    else
      envoyer ("config parc " + (if t.checked then "1" else "0"))

  tableFonctions ()
  dessinerMenu -1
  chargerListe ()
  Link.start onConnected recevoir

[<EntryPoint>]
let main _ =
  start ()
  0
