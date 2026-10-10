/// Simulation mode (`--simulation`): the pupitre simulator page (simulateur.html) talks to
/// gyrophone.pd through this server, as the pupitre's own UI and hardware will.
///
/// /simulation is a WebSocket. Each text frame from the page is one FUDI message for Pd,
/// written to Pd's FUDI port (9100, `SIRENEPUPITRE_PD_FUDI`); each FUDI message Pd sends back
/// on that connection (announcements `etat …`, `refus …`, and the voice tap
/// `simulation voix …`) goes to the page as a text frame. Like the firmware's tap mode:
/// the connection starts with `simulation actif 1` (the tap on) and `config parc 0` (nothing
/// to the physical sirens, as `tap_mode=2` leaves the serial ports unwritten), then
/// `reannoncer` so the page starts from Pd's current state.
module SirenePupitre.Web.Simulation

open System
open System.Net.Sockets
open System.Net.WebSockets
open System.Text
open System.Threading
open System.Threading.Tasks
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Http
open Mecaviv.Infrastructure.Logging

/// What a page may send: the first word of the pupitre contract's server → Pd messages
/// (puredata-abstractions docs/pupitre-contrat.md § 5), plus the simulation's own.
let allowedWords =
  set [ "simulation"; "config"; "contexte"; "mode"; "mapping"; "autonomie"; "fichier"; "transport"; "reannoncer"; "moniteur" ]

/// One message of the page, checked: a single FUDI message, from the contract's vocabulary.
/// `;`, `,` and `\` are refused: in a FUDI stream they would start another message, or a
/// send to an arbitrary Pd receiver.
let checkMessage (text: string) =
  let t = text.Trim()

  if t = "" then
    Error "empty message"
  elif t.IndexOfAny [| ';'; ','; '\\'; '\n'; '\r' |] >= 0 then
    Error "one message per frame, without ; , \\ or line break"
  else
    let first = t.Split(' ', StringSplitOptions.RemoveEmptyEntries).[0]

    if allowedWords.Contains first then
      Ok t
    else
      Error $"'{first}' is not a pupitre message"

/// The MIDI files of the compositions repository: paths relative to it, with `/`, sorted.
let midiFiles (dir: string) =
  if not (IO.Directory.Exists dir) then
    []
  else
    IO.Directory.EnumerateFiles(dir, "*", IO.SearchOption.AllDirectories)
    |> Seq.filter (fun f ->
      let e = IO.Path.GetExtension(f).ToLowerInvariant()
      e = ".mid" || e = ".midi")
    |> Seq.map (fun f -> IO.Path.GetRelativePath(dir, f).Replace('\\', '/'))
    |> Seq.filter (fun p -> not (p.StartsWith ".git/"))
    |> Seq.sortWith (fun a b -> String.Compare(a, b, StringComparison.OrdinalIgnoreCase))
    |> List.ofSeq

/// `fichier charger <path>` for Pd: the path's spaces escaped, so that it stays one atom
/// (the page may not send a backslash itself).
let forPd (m: string) =
  let prefix = "fichier charger "

  if m.StartsWith prefix then
    prefix + m.Substring(prefix.Length).Replace(" ", "\\ ")
  else
    m

/// The complete messages of a FUDI stream (each ends with an unescaped `;`), and the rest.
let splitFudi (text: string) =
  let messages = ResizeArray<string>()
  let mutable start = 0

  for i in 0 .. text.Length - 1 do
    if text.[i] = ';' && (i = 0 || text.[i - 1] <> '\\') then
      let m = text.Substring(start, i - start).Trim()

      if m <> "" then
        messages.Add m

      start <- i + 1

  List.ofSeq messages, text.Substring start

let private send (socket: WebSocket) (gate: SemaphoreSlim) (text: string) =
  task {
    do! gate.WaitAsync()

    try
      if socket.State = WebSocketState.Open then
        do!
          socket.SendAsync(
            ArraySegment(Encoding.UTF8.GetBytes text),
            WebSocketMessageType.Text,
            true,
            CancellationToken.None
          )
    finally
      gate.Release() |> ignore
  }

/// One text or close frame, whole.
let private receive (socket: WebSocket) =
  task {
    let buffer = Array.zeroCreate<byte> 4096
    use ms = new IO.MemoryStream()
    let mutable kind = WebSocketMessageType.Text
    let mutable finished = false

    while not finished do
      let! r = socket.ReceiveAsync(ArraySegment buffer, CancellationToken.None)
      ms.Write(buffer, 0, r.Count)
      kind <- r.MessageType
      finished <- r.EndOfMessage || r.MessageType = WebSocketMessageType.Close

    return kind, Encoding.UTF8.GetString(ms.ToArray())
  }

/// Pd → page, until Pd closes the connection.
let private fromPd (stream: NetworkStream) (socket: WebSocket) (gate: SemaphoreSlim) =
  task {
    let buffer = Array.zeroCreate<byte> 4096
    let mutable rest = ""
    let mutable open' = true

    while open' do
      let! n = stream.ReadAsync(buffer, 0, buffer.Length)

      if n = 0 then
        open' <- false
      else
        let messages, r = splitFudi (rest + Encoding.UTF8.GetString(buffer, 0, n))
        rest <- r

        for m in messages do
          do! send socket gate (m.Replace("\\ ", " ")) // Pd escapes the spaces of a symbol
  }

/// Page → Pd, until the page closes.
let private toPd (stream: NetworkStream) (socket: WebSocket) (gate: SemaphoreSlim) =
  task {
    let write (m: string) =
      let bytes = Encoding.UTF8.GetBytes(m + ";\n")
      stream.WriteAsync(bytes, 0, bytes.Length)

    for m in [ "simulation actif 1"; "config parc 0"; "reannoncer" ] do
      do! write m

    let mutable open' = true

    while open' && socket.State = WebSocketState.Open do
      let! kind, text = receive socket

      if kind = WebSocketMessageType.Close then
        open' <- false
      else
        match checkMessage text with
        | Ok m -> do! write (forPd m)
        | Error why -> do! send socket gate $"refus simulateur {why}"
  }

let private serve (pdHost: string) (pdPort: int) (socket: WebSocket) =
  task {
    let gate = new SemaphoreSlim(1, 1)
    use tcp = new TcpClient()

    let! connected =
      task {
        try
          do! tcp.ConnectAsync(pdHost, pdPort)
          return true
        with ex ->
          info $"/simulation: Pd is not listening on {pdHost}:{pdPort} ({ex.Message})"
          return false
      }

    if not connected then
      do! send socket gate $"refus simulateur Pd ne répond pas sur {pdHost}:{pdPort} : ouvrir gyrophone.pd"
      do! socket.CloseAsync(WebSocketCloseStatus.EndpointUnavailable, "Pd unavailable", CancellationToken.None)
    else
      info $"/simulation: a page is connected to Pd ({pdHost}:{pdPort})"
      let stream = tcp.GetStream()

      try
        let! _ = Task.WhenAny(fromPd stream socket gate, toPd stream socket gate)
        ()
      with ex ->
        debug $"/simulation: connection ended ({ex.Message})"

      info "/simulation: the page left"
  }

/// Accepts /simulation (WebSocket) and relays it to Pd's FUDI port; GET /simulation/fichiers
/// lists the MIDI files of the compositions repository (`compositions`), as gyrophone resolves
/// `fichier charger` paths against the same repository.
let install (pdHost: string) (pdPort: int) (compositions: string) (app: WebApplication) =
  app.UseWebSockets() |> ignore

  app.Use(fun (ctx: HttpContext) (next: RequestDelegate) ->
    if ctx.Request.Path.Value = "/simulation/fichiers" && HttpMethods.IsGet ctx.Request.Method then
      ctx.Response.ContentType <- "application/json; charset=utf-8"
      let body = Text.Json.JsonSerializer.Serialize({| dossier = compositions; fichiers = midiFiles compositions |})
      ctx.Response.WriteAsync body
    else
      next.Invoke ctx)
  |> ignore

  app.Use(fun (ctx: HttpContext) (next: RequestDelegate) ->
    if ctx.Request.Path.Value = "/simulation" && ctx.WebSockets.IsWebSocketRequest then
      task {
        use! socket = ctx.WebSockets.AcceptWebSocketAsync()
        do! serve pdHost pdPort socket
      }
      :> Task
    else
      next.Invoke ctx)
  |> ignore
