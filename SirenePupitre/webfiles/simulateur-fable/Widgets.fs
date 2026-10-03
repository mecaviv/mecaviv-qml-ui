#nowarn 46 // HTMLInputElement.checked
/// Pad / button / wheel / encoder / joystick wiring: pointer gestures become
/// `simulation geste.brut …` frames, the same vocabulary as the CB4TEK card.
module Simulateur.Widgets

open Browser.Dom
open Browser.Types
open Simulateur.Ui
open Simulateur.Link

let private angleDe (svg: Element) (e: Event) : float =
  let e = e :?> PointerEvent
  let r: ClientRect = svg.getBoundingClientRect ()

  atan2 (e.clientY - r.top - r.height / 2.0) (e.clientX - r.left - r.width / 2.0)
  * 180.0
  / System.Math.PI

type HeldButton =
  { presse  : unit -> unit
    relache : unit -> unit }

let boutonTenu
  (node: HTMLElement)
  (appui: string)
  (relacheGeste: string)
  (maintien: HTMLInputElement option)
  : HeldButton =

  let presse () =
    if not (hasClass node "presse") then
      addClass node "presse"
      geste appui

  let relache () =
    if hasClass node "presse" then
      removeClass node "presse"
      geste relacheGeste

  let lacher () =
    match maintien with
    | Some m when m.checked -> ()
    | _ -> relache ()

  node.addEventListener ("pointerdown", fun e ->
    node.setPointerCapture ((e :?> PointerEvent).pointerId)
    presse ()
    ())

  node.addEventListener ("pointerup", fun _ ->
    lacher ()
    ())

  node.addEventListener ("pointercancel", fun _ ->
    lacher ()
    ())

  match maintien with
  | Some m ->
    m.addEventListener ("change", fun _ ->
      if not m.checked then relache ()
      ())
  | None -> ()

  { presse = presse
    relache = lacher }

/// Volant: position in the turn, at most every 30 ms (like the CB4TEK card).
let volant () =
  let svg = svgEl "volant"
  let aiguille: Browser.Types.Element = svg.querySelector "#volant-aiguille"
  let mutable angle = 0.0
  let mutable prec: float option = None
  let mutable dernier = 0.0
  let mutable attente: int option = None

  let envoyerPosition () =
    attente <- None
    dernier <- now ()
    let tour = ((angle / 360.0) % 1.0 + 1.0) % 1.0
    let t = tour.ToString "0.0000"
    geste $"volant {t}"

  let bouger (delta: float) =
    angle <- angle + delta
    aiguille.setAttribute ("transform", $"rotate({angle})")
    let turns = (angle / 360.0).ToString "0.00"
    text "volant-valeur" $"{turns} tour"
    let reste = 30.0 - (now () - dernier)

    if reste <= 0.0 then
      envoyerPosition ()
    else
      match attente with
      | None -> attente <- Some(setTimeout envoyerPosition (int reste))
      | Some _ -> ()

  svg.addEventListener ("pointerdown", fun e ->
    let p = e :?> PointerEvent
    svg.setPointerCapture p.pointerId
    prec <- Some(angleDe svg e)
    ())

  svg.addEventListener ("pointermove", fun e ->
    match prec with
    | None -> ()
    | Some p ->
      let a = angleDe svg e
      let mutable d = a - p
      if d > 180.0 then d <- d - 360.0
      if d < -180.0 then d <- d + 360.0
      prec <- Some a
      bouger d

    ())

  svg.addEventListener ("pointerup", fun _ ->
    prec <- None
    ())

  svg.addEventListener ("wheel", fun e ->
    let w = e :?> WheelEvent
    w.preventDefault ()
    bouger (if w.deltaY > 0.0 then 6.0 else -6.0)
    ())

/// One detent per 20°, mouse wheel, and a push button that stays down while held.
let encodeur () =
  let svg = svgEl "encodeur"
  let aiguille: Browser.Types.Element = svg.querySelector "#encodeur-aiguille"
  let crans = el "encodeur-crans"

  for i in 0..17 do
    let l = document.createElementNS ("http://www.w3.org/2000/svg", "line")
    l.setAttribute ("x1", "0")
    l.setAttribute ("y1", "-47")
    l.setAttribute ("x2", "0")
    l.setAttribute ("y2", "-42")
    l.setAttribute ("stroke", "var(--trait)")
    l.setAttribute ("stroke-width", "2")
    l.setAttribute ("transform", $"rotate({i * 20})")
    crans.appendChild l |> ignore

  let mutable angle = 0.0
  let mutable prec: float option = None
  let mutable cumul = 0.0

  let cran (d: int) =
    angle <- angle + float d * 20.0
    aiguille.setAttribute ("transform", $"rotate({angle})")
    geste $"encodeur cran {d}"

  let poussoir = el "poussoir"
  let mutable enfonce = false

  poussoir.addEventListener ("pointerdown", fun e ->
    let p = e :?> PointerEvent
    p.stopPropagation ()
    poussoir.setPointerCapture p.pointerId
    enfonce <- true
    poussoir.setAttribute ("fill", "var(--accent)")
    geste "encodeur poussoir 1"
    ())

  let lacherPoussoir () =
    if enfonce then
      enfonce <- false
      poussoir.setAttribute ("fill", "var(--panneau)")
      geste "encodeur poussoir 0"

  poussoir.addEventListener ("pointerup", fun _ ->
    lacherPoussoir ()
    ())

  poussoir.addEventListener ("pointercancel", fun _ ->
    lacherPoussoir ()
    ())

  svg.addEventListener ("pointerdown", fun e ->
    let p = e :?> PointerEvent
    svg.setPointerCapture p.pointerId
    prec <- Some(angleDe svg e)
    cumul <- 0.0
    ())

  svg.addEventListener ("pointermove", fun e ->
    match prec with
    | None -> ()
    | Some p ->
      let a = angleDe svg e
      let mutable d = a - p
      if d > 180.0 then d <- d - 360.0
      if d < -180.0 then d <- d + 360.0
      prec <- Some a
      cumul <- cumul + d

      while cumul >= 20.0 do
        cran 1
        cumul <- cumul - 20.0

      while cumul <= -20.0 do
        cran -1
        cumul <- cumul + 20.0

    ())

  svg.addEventListener ("pointerup", fun _ ->
    prec <- None
    ())

  svg.addEventListener ("wheel", fun e ->
    let w = e :?> WheelEvent
    w.preventDefault ()
    cran (if w.deltaY > 0.0 then 1 else -1)
    ())

/// Pad: press, pressure while held, release. `maintien` keeps it in play.
let pad (node: HTMLElement) (n: int) (maintien: HTMLInputElement) =
  let mutable tenu = false
  let mutable derniere = -1
  let mutable enJeu = false
  let niveau: HTMLElement = node.querySelector ".niveau" :?> HTMLElement

  let pression (e: PointerEvent) =
    if e.pointerType = "pen" && e.pressure > 0.0 then
      max 1 (int (System.Math.Round(e.pressure * 127.0)))
    else
      let r: ClientRect = node.getBoundingClientRect ()
      max 1 (min 127 (int (System.Math.Round((1.0 - (e.clientY - r.top) / r.height) * 127.0))))

  let montrer (v: int) = setStyle niveau "height" $"{float v / 127.0 * 100.0}%%"

  node.addEventListener ("pointerdown", fun e ->
    let p = e :?> PointerEvent
    node.setPointerCapture p.pointerId
    tenu <- true
    derniere <- pression p
    montrer derniere

    if enJeu then
      geste $"pad {n} pression {derniere}"
    else
      geste $"pad {n} appui {derniere}"

    enJeu <- true
    ())

  node.addEventListener ("pointermove", fun e ->
    if tenu then
      let v = pression (e :?> PointerEvent)

      if v <> derniere then
        derniere <- v
        montrer v
        geste $"pad {n} pression {v}"

    ())

  let relacher () =
    enJeu <- false
    derniere <- -1
    montrer 0
    geste $"pad {n} relache 0"

  let lacher () =
    if tenu then
      tenu <- false
      if not maintien.checked then relacher ()

  node.addEventListener ("pointerup", fun _ ->
    lacher ()
    ())

  node.addEventListener ("pointercancel", fun _ ->
    lacher ()
    ())

  toggleClass node "maintenu" maintien.checked

  maintien.addEventListener ("change", fun _ ->
    toggleClass node "maintenu" maintien.checked
    if not maintien.checked && enJeu && not tenu then relacher ()
    ())

/// Joystick: returns to centre (64) on release.
let joystick () =
  let zone = el "joy"
  let manche = el "manche"
  let mutable tenu = false
  let mutable x = 64
  let mutable y = 64
  let mutable z = 64

  let montrer () = text "joy-valeur" $"x {x} · y {y} · z {z}"

  let placer (nx: int) (ny: int) =
    setStyle manche "left" $"{float nx / 127.0 * 100.0}%%"
    setStyle manche "top" $"{float (127 - ny) / 127.0 * 100.0}%%"

    if nx <> x then
      x <- nx
      geste $"joystick x {x}"

    if ny <> y then
      y <- ny
      geste $"joystick y {y}"

    montrer ()

  let depuis (e: PointerEvent) =
    let r: ClientRect = zone.getBoundingClientRect ()
    let fx = min 1.0 (max 0.0 ((e.clientX - r.left) / r.width))
    let fy = min 1.0 (max 0.0 ((e.clientY - r.top) / r.height))
    placer (int (System.Math.Round(fx * 127.0))) (int (System.Math.Round((1.0 - fy) * 127.0)))

  zone.addEventListener ("pointerdown", fun e ->
    let p = e :?> PointerEvent
    zone.setPointerCapture p.pointerId
    tenu <- true
    depuis p
    ())

  zone.addEventListener ("pointermove", fun e ->
    if tenu then depuis (e :?> PointerEvent)
    ())

  let lacher () =
    tenu <- false
    placer 64 64

  zone.addEventListener ("pointerup", fun _ ->
    lacher ()
    ())

  zone.addEventListener ("pointercancel", fun _ ->
    lacher ()
    ())

  let rz = input "joyz"

  rz.addEventListener ("input", fun _ ->
    z <- int rz.value
    geste $"joystick z {z}"
    montrer ()
    ())

  rz.addEventListener ("change", fun _ ->
    rz.value <- "64"
    z <- 64
    geste "joystick z 64"
    montrer ()
    ())

/// N / 1..4 gear buttons.
let vitesses () =
  let box' = el "vitesses"

  for v in 0..4 do
    let b = document.createElement "button"
    b.textContent <- (if v = 0 then "N" else string v)
    b.dataset["vitesse"] <- string v

    b.onclick <- fun _ ->
      geste $"vitesse {v}"

      forEachNode (queryAll box' "button") (fun x ->
        toggleClass (x :?> HTMLElement) "actif" (x :?> HTMLElement = b))

    box'.appendChild b |> ignore
