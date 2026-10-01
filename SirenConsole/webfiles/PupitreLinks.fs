/// The console's links to the pupitres (puredata-proxy.js): one WebSocket client per pupitre
/// of config.js, to its PureData (M645.pd, WebSocket 10002 or the simulation's port).
///
/// What was measured on a real M645.pd and is followed here:
/// * JSON goes to PureData in **binary** frames (a text frame is split at its commas);
/// * CONFIG_FULL comes back in chunks with the 8-byte header, about 3 s after REQUEST_CONFIG;
/// * frames are read by code and length (Shared.PureDataFrames): POSITION frames are no longer
///   taken for configuration chunks.
module SirenConsole.Web.PupitreLinks

open System
open System.Collections.Concurrent
open System.IO
open System.Net.WebSockets
open System.Text
open System.Threading
open System.Threading.Tasks
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Infrastructure.Logging
open Mecaviv.Shared.Values
open Mecaviv.Shared.Config
open Mecaviv.Shared.Console
open Mecaviv.Shared.PureDataFrames

let private reconnectDelay = TimeSpan.FromSeconds 1.0
let private handshakeTimeout = TimeSpan.FromSeconds 5.0

/// Note and pitch bend of the wheel → frequency (puredata-proxy.js midiToFrequency): pitch bend
/// ±1 semitone, transposition in octaves.
let midiToFrequency (note: int) (pitchBend: int) (transposition: int) =
  let transposed = float note + float transposition * 12.0
  let baseFrequency = 440.0 * 2.0 ** ((transposed - 69.0) / 12.0)
  baseFrequency * 2.0 ** (((float pitchBend - 8192.0) / 8192.0) / 12.0)

let frequencyToRpm (frequency: float) (outputs: int) = frequency * 60.0 / float outputs

/// What the links report to the rest of the server.
type Handlers =
  {
    /// A pupitre sent its whole configuration (already reduced, or PUPITRE_STATUS's data).
    Config: string -> JsonValue -> Task
    /// A pupitre changed one parameter itself (PARAM_CHANGED, source pupitre).
    ParamChanged: string -> ParamPath -> JsonValue -> Task
    /// An event for the console's UI clients.
    Ui: ConsoleEvent -> Task
  }

type private Link(pupitre: ConsolePupitre) =
  member val Socket: ClientWebSocket option = None with get, set
  member val Connected = false with get, set
  member val LastSeen: DateTime option = None with get, set
  member val SendGate = new SemaphoreSlim(1, 1)
  /// The configuration being received in chunks: total size and bytes so far.
  member val Chunks: (int * byte[] * int) option = None with get, set
  member val Playback = ConcurrentDictionary<string, PureDataFrame>()
  member _.Pupitre = pupitre
  member _.Url = $"ws://{pupitre.Host}:{pupitre.WebsocketPort}"

type Links(pupitres: ConsolePupitre list, handlers: Handlers) =
  let links =
    pupitres
    |> List.filter (fun p -> p.Enabled)
    |> List.map (fun p -> p.Id, Link p)
    |> dict

  /// The JSON messages received, newest last, at most 100 (eventBuffer): what
  /// /api/puredata/events serves. The Node proxy never fills it (its JSON branch is dead).
  let events = ConcurrentQueue<float * string * string * JsonValue>()
  let maxEvents = 100

  /// The last wheel state, for /api/volant-data.
  let mutable lastVolant: JsonValue option = None

  let sendBytes (link: Link) (bytes: byte[]) =
    task {
      match link.Socket with
      | Some socket when link.Connected && socket.State = WebSocketState.Open ->
        do! link.SendGate.WaitAsync()

        try
          do! socket.SendAsync(ArraySegment bytes, WebSocketMessageType.Binary, true, CancellationToken.None)
          return true
        finally
          link.SendGate.Release() |> ignore
      | _ -> return false
    }

  /// A JSON message to one pupitre, in a binary frame. False when it is not connected.
  let send (link: Link) (message: PupitreMessage) =
    sendBytes link (Encoding.UTF8.GetBytes(Encode.toString 0 (PupitreMessage.encode message)))

  let onJson (link: Link) (text: string) =
    task {
      let id = link.Pupitre.Id

      match Decode.fromString (JsonValue.decoder ()) text with
      | Ok(JObject fields as json) ->
        events.Enqueue(float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()), id, link.Pupitre.Name, json)

        while events.Count > maxEvents do
          events.TryDequeue() |> ignore

        let field name =
          fields |> List.tryFind (fun (k, _) -> k = name) |> Option.map snd

        match field "type" with
        | Some(JString "CONFIG_FULL") ->
          match field "config" with
          | Some config -> do! handlers.Config id (Presets.convertPureDataConfig config)
          | None -> ()
        | Some(JString "PARAM_CHANGED") when field "source" = Some(JString "pupitre") ->
          match Decode.fromString PupitreMessage.decoder text with
          | Ok(ParamChanged(path, value, _)) -> do! handlers.ParamChanged id path value
          | _ -> ()
        | Some(JString "PUPITRE_STATUS") ->
          match field "data" with
          | Some data -> do! handlers.Config id data
          | None -> ()
        | Some(JString other) -> debug $"pupitre {id}: {other} not handled"
        | _ ->
          // A bare configuration object (puredata-proxy.js: JSON without type).
          match field "config" with
          | Some config -> do! handlers.Config id (Presets.convertPureDataConfig config)
          | None -> do! handlers.Config id (Presets.convertPureDataConfig json)
      | Ok _ -> ()
      | Error e -> debug $"pupitre {id}: unreadable JSON ({e})"
    }

  let onFrame (link: Link) (bytes: byte[]) =
    task {
      let id = link.Pupitre.Id

      match decode bytes with
      | Heartbeat
      | Unknown _ -> ()
      | VolantState(note, velocity, pitchBend) ->
        // puredata-proxy.js: S3's settings (an octave up, 8 outputs) for every pupitre
        let frequency = midiToFrequency note pitchBend 1
        let now = float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())

        lastVolant <-
          Some(
            JObject
              [
                "pupitreId", JString id
                "note", JNumber(float note)
                "velocity", JNumber(float velocity)
                "pitchbend", JNumber(float pitchBend)
                "frequency", JNumber frequency
                "rpm", JNumber(frequencyToRpm frequency 8)
                "timestamp", JNumber now
              ]
          )

        do!
          handlers.Ui(
            Volant
              {
                PupitreId = id
                NoteFloat = float note + (float pitchBend - 8192.0) / 8192.0
                Velocity = velocity
                Frequency = int (Math.Round frequency)
                Rpm = int (Math.Round(frequencyToRpm frequency 8))
                Timestamp = float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())
              }
          )
      | Json text -> do! onJson link text
      | ConfigChunk(total, position, data) ->
        let buffer, received =
          match link.Chunks with
          | Some(t, b, r) when t = total -> b, r
          | _ -> Array.zeroCreate total, 0

        let count = min data.Length (total - position)
        Array.blit data 0 buffer position count
        let received = received + count

        if received >= total then
          link.Chunks <- None
          do! onJson link (Encoding.UTF8.GetString buffer)
        else
          link.Chunks <- Some(total, buffer, received)
      | Position _ as f -> link.Playback.["position"] <- f
      | FileInfo _ as f -> link.Playback.["file"] <- f
      | Tempo _ as f -> link.Playback.["tempo"] <- f
      | TimeSignature _ as f -> link.Playback.["timeSignature"] <- f
      | TickPosition _ as f -> link.Playback.["tick"] <- f
    }

  let receiveLoop (link: Link) (socket: ClientWebSocket) =
    task {
      let chunk = Array.zeroCreate<byte> 16384
      use message = new MemoryStream()
      let mutable go = true

      while go && socket.State = WebSocketState.Open do
        let! r = socket.ReceiveAsync(ArraySegment chunk, CancellationToken.None)

        if r.MessageType = WebSocketMessageType.Close then
          go <- false
        else
          message.Write(chunk, 0, r.Count)

          if r.EndOfMessage then
            link.LastSeen <- Some DateTime.UtcNow
            let bytes = message.ToArray()
            message.SetLength 0L

            try
              do! onFrame link bytes
            with ex ->
              error $"pupitre {link.Pupitre.Id}: {ex.Message}"
    }

  let connection (link: Link) =
    let p = link.Pupitre

    let ev connected =
      {
        PupitreId = p.Id
        PupitreName = p.Name
        Connected = connected
        Url = None
        LastSeen = None
        IsSynced = None
        LastSync = None
      }

    task {
      while true do
        use socket = new ClientWebSocket()

        try
          try
            use timeout = new CancellationTokenSource(handshakeTimeout)
            do! socket.ConnectAsync(Uri link.Url, timeout.Token)
            link.Socket <- Some socket
            link.Connected <- true
            link.LastSeen <- Some DateTime.UtcNow
            link.Chunks <- None
            info $"pupitre {p.Id}: connected to {link.Url}"
            do! handlers.Ui(PupitreConnected(ev true, float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())))

            let _ =
              task {
                do! Task.Delay 100
                let! sent = send link (RequestConfig(Some p.Id, Some "console"))

                if not sent then
                  debug $"pupitre {p.Id}: REQUEST_CONFIG not sent"
              }

            do! receiveLoop link socket
          with _ ->
            ()
        finally
          let wasConnected = link.Connected
          link.Connected <- false
          link.Socket <- None
          link.LastSeen <- None

          if wasConnected then
            info $"pupitre {p.Id}: disconnected"
            handlers.Ui(PupitreDisconnected(ev false, float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()))).Wait()

        do! Task.Delay reconnectDelay
    }

  /// Starts one connection loop per enabled pupitre.
  member _.Start() =
    for link in links.Values do
      Task.Run(fun () -> connection link :> Task) |> ignore

  /// A message to one pupitre (binary JSON); false when it is not connected.
  member _.Send(pupitreId: string, message: PupitreMessage) : Task<bool> =
    match links.TryGetValue pupitreId with
    | true, link -> send link message
    | _ -> Task.FromResult false

  /// A message to every connected pupitre; how many got it.
  member _.SendAll(message: PupitreMessage) : Task<int> =
    task {
      let mutable n = 0

      for link in links.Values do
        let! sent = send link message

        if sent then
          n <- n + 1

      return n
    }

  /// JSON messages received after `since` (ms), as /api/puredata/events serves them.
  member _.Events(since: float) =
    events.ToArray()
    |> Array.filter (fun (t, _, _, _) -> t > since)
    |> Array.map (fun (t, id, name, data) ->
      JObject
        [
          "timestamp", JNumber t
          "pupitreId", JString id
          "pupitreName", JString name
          "data", data
        ])
    |> Array.toList

  member _.LastVolant = lastVolant

  member _.IsConnected(pupitreId: string) =
    match links.TryGetValue pupitreId with
    | true, link -> link.Connected
    | _ -> false

  interface UiSocket.PupitreStatusSource with
    member _.Status() =
      let connections =
        pupitres
        |> List.choose (fun p ->
          match links.TryGetValue p.Id with
          | true, l -> Some l
          | _ -> None)
        |> List.map (fun link ->
          {
            PupitreId = link.Pupitre.Id
            PupitreName = link.Pupitre.Name
            Connected = link.Connected
            Url = Some link.Url
            LastSeen =
              link.LastSeen
              |> Option.map (fun t -> t.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))
            IsSynced = None
            LastSync = None
          })

      {
        TotalConnections = connections.Length
        ConnectedCount = connections |> List.filter (fun c -> c.Connected) |> List.length
        Connections = connections
      }
