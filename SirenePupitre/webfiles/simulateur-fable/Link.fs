/// WebSocket /simulation: one text frame = one FUDI message for gyrophone.pd
/// (no `;`, `,` or `\` — the server refuses those).
module Simulateur.Link

open Fable.Core
open Simulateur.Ui

type private Socket =
  abstract send: string -> unit
  abstract readyState: float
  abstract onopen: (obj -> obj) with get, set
  abstract onclose: (obj -> obj) with get, set
  abstract onmessage: (obj -> obj) with get, set

[<Emit("new WebSocket($0)")>]
let private createSocket (url: string) : Socket = jsNative

[<Emit("$0.data")>]
let private dataOf (e: obj) : string = jsNative

let mutable private ws: Socket option = None
let mutable private onMessage: string -> unit = ignore
let mutable private onOpen: unit -> unit = ignore

let private urlServeur () =
  let proto = windowProtocol ()
  let host = windowHost ()

  if proto = "http:" || proto = "https:" then
    (if proto = "https:" then "wss://" else "ws://") + host + "/simulation"
  else
    "ws://localhost:8000/simulation"

let envoyer (message: string) =
  match ws with
  | Some w when w.readyState = 1.0 -> w.send message
  | _ -> ()

let geste (g: string) = envoyer ($"simulation geste.brut {g}")

let rec private connecter () =
  let url = urlServeur ()
  let w = createSocket url

  w.onopen <- fun _ ->
    addClass (el "pastille") "ok"
    text "etat-connexion" "connecté"
    journal ($"— connecté à {url}") false
    onOpen ()
    box ()

  w.onclose <- fun _ ->
    removeClass (el "pastille") "ok"
    text "etat-connexion" "déconnecté — nouvel essai…"
    setTimeout connecter 1500 |> ignore
    box ()

  w.onmessage <- fun e ->
    onMessage (dataOf e)
    box ()

  ws <- Some w

/// `open'` runs on each successful connect (including reconnects);
/// `message` is every text frame from Pd (via the simulation relay).
let start (open': unit -> unit) (message: string -> unit) =
  onOpen <- open'
  onMessage <- message
  connecter ()
