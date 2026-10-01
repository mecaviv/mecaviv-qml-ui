/// The console UI's WebSocket, /ws (server.js handleWebSocketConnection): PING → PONG,
/// SIRENCONSOLE_IDENTIFICATION → the client joins the broadcasts and gets INITIAL_STATUS, and
/// every second PUPITRE_STATUS_UPDATE goes to every client that identified itself.
module SirenConsole.Web.UiSocket

open System
open System.Collections.Concurrent
open System.IO
open System.Net.WebSockets
open System.Text
open System.Threading
open System.Threading.Tasks
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Http
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Infrastructure.Logging
open Mecaviv.Shared.Config
open Mecaviv.Shared.Console

let nowMs () =
  float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())

/// Whether each pupitre has the current preset (syncState in server.js).
type SyncState() =
  let state = ConcurrentDictionary<string, bool * float option>()

  member _.IsSynced id =
    match state.TryGetValue id with
    | true, (s, _) -> s
    | _ -> false

  member _.Get id =
    match state.TryGetValue id with
    | true, v -> v
    | _ -> false, None

  /// Returns the event to broadcast (SYNC_STATUS_CHANGED).
  member _.Set(id, synced: bool) =
    let _, last =
      match state.TryGetValue id with
      | true, v -> v
      | _ -> false, None

    state.[id] <- (synced, (if synced then Some(nowMs ()) else last))
    SyncStatusChanged(id, synced, nowMs ())

/// The pupitres' connection state, as the pupitre links report it.
type PupitreStatusSource =
  abstract Status: unit -> PupitresStatus

/// Until the pupitre links exist: the configured pupitres, all disconnected.
let configuredOnly (pupitres: ConsolePupitre list) =
  { new PupitreStatusSource with
      member _.Status() =
        let connections =
          pupitres
          |> List.map (fun p ->
            {
              PupitreId = p.Id
              PupitreName = p.Name
              Connected = false
              Url = Some $"ws://{p.Host}:{p.WebsocketPort}"
              LastSeen = None
              IsSynced = None
              LastSync = None
            })

        {
          TotalConnections = connections.Length
          ConnectedCount = 0
          Connections = connections
        }
  }

/// The status with each connection's sync state, as PUPITRE_STATUS_UPDATE carries it.
let withSync (sync: SyncState) (status: PupitresStatus) =
  { status with
      Connections =
        status.Connections
        |> List.map (fun c ->
          let synced, last = sync.Get c.PupitreId

          { c with
              IsSynced = Some synced
              LastSync = last
          })
  }

/// The UI clients that identified themselves.
type Hub() =
  let clients = ConcurrentDictionary<Guid, WebSocket * SemaphoreSlim>()

  member _.Count = clients.Count

  member _.Add(id, socket: WebSocket) =
    clients.[id] <- (socket, new SemaphoreSlim(1, 1))

  member _.Remove id = clients.TryRemove(id: Guid) |> ignore

  member _.SendTo(socket: WebSocket, gate: SemaphoreSlim, kind, bytes: byte[]) =
    task {
      // A WebSocket takes one send at a time.
      do! gate.WaitAsync()

      try
        if socket.State = WebSocketState.Open then
          do! socket.SendAsync(ArraySegment bytes, kind, true, CancellationToken.None)
      finally
        gate.Release() |> ignore
    }

  member this.Broadcast(kind, bytes: byte[]) =
    task {
      for KeyValue(id, (socket, gate)) in clients.ToArray() do
        try
          do! this.SendTo(socket, gate, kind, bytes)
        with _ ->
          this.Remove id
    }

  /// A console event, to every identified client.
  member this.Send(event: ConsoleEvent) =
    this.Broadcast(WebSocketMessageType.Text, Encoding.UTF8.GetBytes(Encode.toString 0 (ConsoleEvent.encode event)))

  /// A binary frame, to every identified client (broadcastBinaryToUIClients).
  member this.SendBinary(frame: byte[]) =
    this.Broadcast(WebSocketMessageType.Binary, frame)

let private receive (socket: WebSocket) =
  task {
    use buffer = new MemoryStream()
    let chunk = Array.zeroCreate<byte> 8192
    let mutable result = Unchecked.defaultof<WebSocketReceiveResult>
    let mutable finished = false

    while not finished do
      let! r = socket.ReceiveAsync(ArraySegment chunk, CancellationToken.None)
      result <- r
      buffer.Write(chunk, 0, r.Count)
      finished <- r.EndOfMessage || r.MessageType = WebSocketMessageType.Close

    return result.MessageType, buffer.ToArray()
  }

/// Serves /ws until the client closes.
let private serve (hub: Hub) (sync: SyncState) (status: PupitreStatusSource) (socket: WebSocket) =
  task {
    let id = Guid.NewGuid()
    let gate = new SemaphoreSlim(1, 1)

    let reply (event: ConsoleEvent) =
      hub.SendTo(
        socket,
        gate,
        WebSocketMessageType.Text,
        Encoding.UTF8.GetBytes(Encode.toString 0 (ConsoleEvent.encode event))
      )

    try
      try
        let mutable open' = true

        while open' && socket.State = WebSocketState.Open do
          let! kind, bytes = receive socket

          if kind = WebSocketMessageType.Close then
            open' <- false
          else
            // server.js reads text and binary messages alike as JSON
            match Decode.fromString ConsoleRequest.decoder (Encoding.UTF8.GetString bytes) with
            | Ok(Ping _) -> do! reply (Pong("SERVER_FSHARP", nowMs ()))
            | Ok(Identify _) ->
              hub.Add(id, socket)
              do! reply (InitialStatus(withSync sync (status.Status())))
            | Ok other -> debug $"/ws: {other} is handled over HTTP, ignored here"
            | Error _ ->
              // PUPITRE_IDENTIFICATION (a pupitre connecting to the console) comes
              // with the pupitre links; anything else is ignored, as in server.js.
              debug $"/ws: ignored {Encoding.UTF8.GetString bytes |> fun s -> s.Substring(0, min 120 s.Length)}"
      with ex ->
        debug $"/ws: connection ended ({ex.Message})"
    finally
      hub.Remove id
  }

/// Accepts /ws, and broadcasts PUPITRE_STATUS_UPDATE every second.
let install (hub: Hub) (sync: SyncState) (status: PupitreStatusSource) (app: WebApplication) =
  app.UseWebSockets() |> ignore

  app.Use(fun (ctx: HttpContext) (next: RequestDelegate) ->
    if ctx.Request.Path.Value = "/ws" && ctx.WebSockets.IsWebSocketRequest then
      task {
        use! socket = ctx.WebSockets.AcceptWebSocketAsync()
        do! serve hub sync status socket
      }
      :> Task
    else
      next.Invoke ctx)
  |> ignore

  let ticker = new PeriodicTimer(TimeSpan.FromSeconds 1.0)

  Task.Run(fun () ->
    task {
      while true do
        let! _ = ticker.WaitForNextTickAsync()

        if hub.Count > 0 then
          do! hub.Send(PupitreStatusUpdate(withSync sync (status.Status()), nowMs ()))
    }
    :> Task)
  |> ignore
