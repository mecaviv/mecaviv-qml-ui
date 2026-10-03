/// Browser bits Fable.Browser.Dom leaves raw or typed too loosely for this page.
module Simulateur.Ui

open Fable.Core
open Browser.Dom
open Browser.Types

[<Emit("setTimeout($0, $1)")>]
let setTimeout (f: unit -> unit) (ms: int) : int = jsNative

[<Emit("clearTimeout($0)")>]
let clearTimeout (id: int) : unit = jsNative

[<Emit("performance.now()")>]
let now () : float = jsNative

[<Emit("window.confirm($0)")>]
let confirm (message: string) : bool = jsNative

[<Emit("location.protocol")>]
let windowProtocol () : string = jsNative

[<Emit("location.host")>]
let windowHost () : string = jsNative

[<Emit("$0.style[$1] = $2")>]
let setStyle (el: HTMLElement) (name: string) (value: string) : unit = jsNative

[<Emit("$0.querySelectorAll($1)")>]
let queryAll (root: Element) (selector: string) : NodeListOf<Element> = jsNative

[<Emit("$0.forEach($1)")>]
let forEachNode (nodes: NodeListOf<Element>) (f: Element -> unit) : unit = jsNative

[<Emit("$0.setAttribute('open', $1)")>]
let setOpen (el: HTMLElement) (on: bool) : unit = jsNative

let el (id: string) : HTMLElement = document.getElementById id

let svgEl (id: string) : Element = document.getElementById id

let input (id: string) : HTMLInputElement = document.getElementById id :?> HTMLInputElement

let select (id: string) : HTMLSelectElement = document.getElementById id :?> HTMLSelectElement

let text (id: string) (s: string) = (el id).textContent <- s

let html (id: string) (s: string) = (el id).innerHTML <- s

let addClass (e: HTMLElement) (c: string) = e.classList.add c

let removeClass (e: HTMLElement) (c: string) = e.classList.remove c

let toggleClass (e: HTMLElement) (c: string) (on: bool) = e.classList.toggle (c, on) |> ignore

let hasClass (e: HTMLElement) (c: string) = e.classList.contains c

/// Journal: last 300 lines, `refus` rows in red.
let journal (texte: string) (refus: bool) =
  let j = el "journal"
  let l = document.createElement "div"
  l.textContent <- texte
  if refus then l.className <- "refus"
  j.appendChild l |> ignore

  while j.childNodes.length > 300 do
    j.removeChild j.firstChild |> ignore

  j.scrollTop <- float j.scrollHeight

let mutable private toastTimer = 0

let toast (t: string) =
  let e = el "toast"
  e.textContent <- t
  addClass e "visible"
  clearTimeout toastTimer
  toastTimer <- setTimeout (fun () -> removeClass e "visible") 2600

let markButtons (boxId: string) (valeur: string) =
  forEachNode (queryAll (el boxId) "button") (fun b ->
    let h = b :?> HTMLElement
    toggleClass h "actif" (h.dataset["valeur"] = valeur))

let markMode (m: string) =
  forEachNode (queryAll document.body "[data-mode]") (fun b ->
    let h = b :?> HTMLElement
    toggleClass h "actif" (h.dataset["mode"] = m))

/// `select[attr="value"]` — build the selector without nested quotes in `$"…"`.
let selectBy (attr: string) (value: string) =
  queryAll document.body ("select[" + attr + "=\"" + value + "\"]")

let setSelectValue (attr: string) (f: string) (value: string) =
  forEachNode (selectBy attr f) (fun e -> (e :?> HTMLSelectElement).value <- value)
