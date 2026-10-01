/// SirenConsole's messages (docs/CONTRAT_PARTAGE.md, § 2): between the console's UI and its
/// server (WebSocket /ws on 8001), and between the server and each pupitre's PureData
/// (WebSocket 10002, JSON part). Encoders write the field names the current code uses, so an
/// F# server stays compatible with the QML UI; decoders accept the optional fields as optional.
/// Timestamps are `Date.now()`: milliseconds, as a JSON number.
module Mecaviv.Shared.Console

open Thoth.Json.Core
open Mecaviv.Shared.Values

// ─────────────────────────────── shared pieces ───────────────────────────────

type TransportAction =
    | Play
    | Pause
    | Stop

module TransportAction =
    let toString =
        function
        | Play -> "play"
        | Pause -> "pause"
        | Stop -> "stop"

    let decoder: Decoder<TransportAction> =
        Decode.string
        |> Decode.andThen (function
            | "play" -> Decode.succeed Play
            | "pause" -> Decode.succeed Pause
            | "stop" -> Decode.succeed Stop
            | other -> Decode.fail $"unknown transport action {other}")

/// One pupitre in the server's status (puredata-proxy.js, getStatus).
type PupitreConnection =
    { PupitreId: string
      PupitreName: string
      Connected: bool
      Url: string option
      LastSeen: float option
      /// Added by the server to PUPITRE_STATUS_UPDATE (and INITIAL_STATUS on identification).
      IsSynced: bool option
      LastSync: float option }

/// The server's view of the pupitres (INITIAL_STATUS, PUPITRE_STATUS_UPDATE).
type PupitresStatus =
    { TotalConnections: int
      ConnectedCount: int
      Connections: PupitreConnection list }

let private pupitreConnectionDecoder: Decoder<PupitreConnection> =
    Decode.object (fun get ->
        { PupitreId = get.Required.Field "pupitreId" Decode.string
          PupitreName = get.Optional.Field "pupitreName" Decode.string |> Option.defaultValue ""
          Connected = get.Optional.Field "connected" Decode.bool |> Option.defaultValue false
          Url = get.Optional.Field "url" Decode.string
          LastSeen = get.Optional.Field "lastSeen" Decode.float
          IsSynced = get.Optional.Field "isSynced" Decode.bool
          LastSync = get.Optional.Field "lastSync" Decode.float })

let private encodePupitreConnection (c: PupitreConnection) =
    Encode.object [
        "pupitreId", Encode.string c.PupitreId
        "pupitreName", Encode.string c.PupitreName
        "connected", Encode.bool c.Connected
        match c.Url with
        | Some u -> "url", Encode.string u
        | None -> ()
        "lastSeen", (match c.LastSeen with Some t -> Encode.float t | None -> Encode.nil)
        match c.IsSynced with
        | Some s ->
            "isSynced", Encode.bool s
            "lastSync", (match c.LastSync with Some t -> Encode.float t | None -> Encode.nil)
        | None -> ()
    ]

let private pupitresStatusDecoder: Decoder<PupitresStatus> =
    Decode.object (fun get ->
        let connections =
            get.Optional.Field "connections" (Decode.list pupitreConnectionDecoder)
            |> Option.defaultValue []
        { TotalConnections = get.Optional.Field "totalConnections" Decode.int |> Option.defaultValue connections.Length
          ConnectedCount =
            get.Optional.Field "connectedCount" Decode.int
            |> Option.defaultValue (connections |> List.filter (fun c -> c.Connected) |> List.length)
          Connections = connections })

let private encodePupitresStatus (s: PupitresStatus) =
    Encode.object [
        "totalConnections", Encode.int s.TotalConnections
        "connectedCount", Encode.int s.ConnectedCount
        "connections", s.Connections |> List.map encodePupitreConnection |> Encode.list
    ]

let private optionalString name (value: string option) =
    match value with
    | Some v -> [ name, Encode.string v ]
    | None -> []

// ─────────────────────────────── UI → console server ───────────────────────────────

type ConsoleRequest =
    /// SIRENCONSOLE_IDENTIFICATION: the UI says who it is when it connects.
    | Identify of source: string * timestamp: float
    | Ping of source: string * timestamp: float
    | MidiTransport of action: TransportAction * source: string option
    /// MIDI_FILE_LOAD: path relative to the compositions repository.
    | MidiFileLoad of path: string * source: string option
    /// MIDI_SEEK: position in milliseconds.
    | MidiSeek of positionMs: float
    | TempoChange of bpm: float * smooth: bool
    /// UI_CONTROLS: the server relays it to the pupitre as PARAM_UPDATE ["uiControls","enabled"].
    | UiControls of pupitreId: string * enabled: bool
    | AutonomyMode of pupitreId: string * device: string * enabled: bool * source: string option

module ConsoleRequest =
    let encode (request: ConsoleRequest) : IEncodable =
        match request with
        | Identify(source, ts) ->
            Encode.object [ "type", Encode.string "SIRENCONSOLE_IDENTIFICATION"; "source", Encode.string source; "timestamp", Encode.float ts ]
        | Ping(source, ts) ->
            Encode.object [ "type", Encode.string "PING"; "source", Encode.string source; "timestamp", Encode.float ts ]
        | MidiTransport(action, source) ->
            Encode.object (
                [ "type", Encode.string "MIDI_TRANSPORT"; "action", Encode.string (TransportAction.toString action) ]
                @ optionalString "source" source)
        | MidiFileLoad(path, source) ->
            Encode.object ([ "type", Encode.string "MIDI_FILE_LOAD"; "path", Encode.string path ] @ optionalString "source" source)
        | MidiSeek position -> Encode.object [ "type", Encode.string "MIDI_SEEK"; "position", Encode.float position ]
        | TempoChange(bpm, smooth) ->
            Encode.object [ "type", Encode.string "TEMPO_CHANGE"; "tempo", Encode.float bpm; "smooth", Encode.bool smooth ]
        | UiControls(pupitreId, enabled) ->
            Encode.object [ "type", Encode.string "UI_CONTROLS"; "pupitreId", Encode.string pupitreId; "enabled", Encode.bool enabled ]
        | AutonomyMode(pupitreId, device, enabled, source) ->
            Encode.object (
                [ "type", Encode.string "AUTONOMY_MODE"
                  "pupitreId", Encode.string pupitreId
                  "device", Encode.string device
                  "enabled", Encode.bool enabled ]
                @ optionalString "source" source)

    let decoder: Decoder<ConsoleRequest> =
        Decode.field "type" Decode.string
        |> Decode.andThen (function
            | "SIRENCONSOLE_IDENTIFICATION" ->
                Decode.object (fun get ->
                    Identify(
                        get.Optional.Field "source" Decode.string |> Option.defaultValue "",
                        get.Optional.Field "timestamp" Decode.float |> Option.defaultValue 0.0))
            | "PING" ->
                Decode.object (fun get ->
                    Ping(
                        get.Optional.Field "source" Decode.string |> Option.defaultValue "",
                        get.Optional.Field "timestamp" Decode.float |> Option.defaultValue 0.0))
            | "MIDI_TRANSPORT" ->
                Decode.object (fun get ->
                    MidiTransport(get.Required.Field "action" TransportAction.decoder, get.Optional.Field "source" Decode.string))
            | "MIDI_FILE_LOAD" ->
                Decode.object (fun get ->
                    MidiFileLoad(get.Required.Field "path" Decode.string, get.Optional.Field "source" Decode.string))
            | "MIDI_SEEK" -> Decode.object (fun get -> MidiSeek(get.Required.Field "position" Decode.float))
            | "TEMPO_CHANGE" ->
                Decode.object (fun get ->
                    TempoChange(
                        get.Required.Field "tempo" Decode.float,
                        get.Optional.Field "smooth" Decode.bool |> Option.defaultValue false))
            | "UI_CONTROLS" ->
                Decode.object (fun get ->
                    // server.js: enabled defaults to true when absent
                    UiControls(
                        get.Optional.Field "pupitreId" Decode.string |> Option.defaultValue "",
                        get.Optional.Field "enabled" Decode.bool |> Option.defaultValue true))
            | "AUTONOMY_MODE" ->
                Decode.object (fun get ->
                    AutonomyMode(
                        get.Optional.Field "pupitreId" Decode.string |> Option.defaultValue "",
                        get.Optional.Field "device" Decode.string |> Option.defaultValue "",
                        get.Optional.Field "enabled" Decode.bool |> Option.defaultValue false,
                        get.Optional.Field "source" Decode.string))
            | other -> Decode.fail $"not a console request: {other}")

// ─────────────────────────────── console server → UI ───────────────────────────────

type VolantData =
    { PupitreId: string
      /// The wheel's note, continuous (note + pitch bend).
      NoteFloat: float
      Velocity: int
      Frequency: int
      Rpm: int
      Timestamp: float }

type ConsoleEvent =
    | Pong of source: string * timestamp: float
    | InitialStatus of PupitresStatus
    | PupitreStatusUpdate of PupitresStatus * timestamp: float
    | SyncStatusChanged of pupitreId: string * isSynced: bool * timestamp: float
    | PupitreConnected of PupitreConnection * timestamp: float
    | PupitreDisconnected of PupitreConnection * timestamp: float
    | Volant of VolantData
    /// PRESET_UPDATED_FROM_PUPITRE: a pupitre changed the current preset; path and value when
    /// one parameter changed, neither when a whole configuration came in.
    | PresetUpdatedFromPupitre of pupitreId: string * change: (ParamPath * JsonValue) option * timestamp: float

module ConsoleEvent =
    let private connectionFields typeName (c: PupitreConnection) ts =
        Encode.object [
            "type", Encode.string typeName
            "pupitreId", Encode.string c.PupitreId
            "pupitreName", Encode.string c.PupitreName
            "connected", Encode.bool c.Connected
            "timestamp", Encode.float ts
        ]

    let encode (event: ConsoleEvent) : IEncodable =
        match event with
        | Pong(source, ts) -> Encode.object [ "type", Encode.string "PONG"; "source", Encode.string source; "timestamp", Encode.float ts ]
        | InitialStatus status -> Encode.object [ "type", Encode.string "INITIAL_STATUS"; "data", encodePupitresStatus status ]
        | PupitreStatusUpdate(status, ts) ->
            Encode.object [ "type", Encode.string "PUPITRE_STATUS_UPDATE"; "data", encodePupitresStatus status; "timestamp", Encode.float ts ]
        | SyncStatusChanged(id, synced, ts) ->
            Encode.object [
                "type", Encode.string "SYNC_STATUS_CHANGED"
                "pupitreId", Encode.string id
                "isSynced", Encode.bool synced
                "timestamp", Encode.float ts
            ]
        | PupitreConnected(c, ts) -> connectionFields "PUPITRE_CONNECTED" c ts
        | PupitreDisconnected(c, ts) -> connectionFields "PUPITRE_DISCONNECTED" c ts
        | Volant v ->
            Encode.object [
                "type", Encode.string "VOLANT_DATA"
                "pupitreId", Encode.string v.PupitreId
                "noteFloat", Encode.float v.NoteFloat
                "velocity", Encode.int v.Velocity
                "frequency", Encode.int v.Frequency
                "rpm", Encode.int v.Rpm
                "timestamp", Encode.float v.Timestamp
            ]
        | PresetUpdatedFromPupitre(id, change, ts) ->
            Encode.object [
                "type", Encode.string "PRESET_UPDATED_FROM_PUPITRE"
                "pupitreId", Encode.string id
                match change with
                | Some(path, value) ->
                    "path", ParamPath.encode path
                    "value", JsonValue.encode value
                | None -> "configUpdated", Encode.bool true
                "timestamp", Encode.float ts
            ]

    let private connectionDecoder =
        Decode.object (fun get ->
            { PupitreId = get.Required.Field "pupitreId" Decode.string
              PupitreName = get.Optional.Field "pupitreName" Decode.string |> Option.defaultValue ""
              Connected = get.Optional.Field "connected" Decode.bool |> Option.defaultValue false
              Url = None
              LastSeen = None
              IsSynced = None
              LastSync = None },
            get.Optional.Field "timestamp" Decode.float |> Option.defaultValue 0.0)

    let decoder: Decoder<ConsoleEvent> =
        let ts (get: Decode.IGetters) = get.Optional.Field "timestamp" Decode.float |> Option.defaultValue 0.0
        Decode.field "type" Decode.string
        |> Decode.andThen (function
            | "PONG" -> Decode.object (fun get -> Pong(get.Optional.Field "source" Decode.string |> Option.defaultValue "", ts get))
            | "INITIAL_STATUS" -> Decode.field "data" pupitresStatusDecoder |> Decode.map InitialStatus
            | "PUPITRE_STATUS_UPDATE" ->
                Decode.object (fun get -> PupitreStatusUpdate(get.Required.Field "data" pupitresStatusDecoder, ts get))
            | "SYNC_STATUS_CHANGED" ->
                Decode.object (fun get ->
                    SyncStatusChanged(get.Required.Field "pupitreId" Decode.string, get.Required.Field "isSynced" Decode.bool, ts get))
            | "PUPITRE_CONNECTED" -> connectionDecoder |> Decode.map PupitreConnected
            | "PUPITRE_DISCONNECTED" -> connectionDecoder |> Decode.map PupitreDisconnected
            | "VOLANT_DATA" ->
                Decode.object (fun get ->
                    Volant
                        { PupitreId = get.Required.Field "pupitreId" Decode.string
                          NoteFloat = get.Required.Field "noteFloat" Decode.float
                          Velocity = get.Optional.Field "velocity" Decode.int |> Option.defaultValue 0
                          Frequency = get.Optional.Field "frequency" Decode.int |> Option.defaultValue 0
                          Rpm = get.Optional.Field "rpm" Decode.int |> Option.defaultValue 0
                          Timestamp = ts get })
            | "PRESET_UPDATED_FROM_PUPITRE" ->
                Decode.object (fun get ->
                    let path = get.Optional.Field "path" ParamPath.decoder
                    let value = get.Optional.Field "value" (JsonValue.decoder ())
                    let change =
                        match path, value with
                        | Some p, Some v -> Some(p, v)
                        | _ -> None
                    PresetUpdatedFromPupitre(get.Required.Field "pupitreId" Decode.string, change, ts get))
            | other -> Decode.fail $"not a console event: {other}")

// ─────────────────────────────── console server ↔ pupitre (JSON) ───────────────────────────────

type PupitreMessage =
    /// PARAM_UPDATE: set one parameter of the pupitre's configuration.
    | ParamUpdate of path: ParamPath * value: JsonValue * source: string option
    /// PARAM_CHANGED: the pupitre changed a parameter itself.
    | ParamChanged of path: ParamPath * value: JsonValue * source: string option
    | RequestConfig of pupitreId: string option * source: string option
    | ConsoleConnect of source: string option
    | GameMode of enabled: bool * source: string option

module PupitreMessage =
    let encode (message: PupitreMessage) : IEncodable =
        let pathValue typeName path value source =
            Encode.object (
                [ "type", Encode.string typeName; "path", ParamPath.encode path; "value", JsonValue.encode value ]
                @ optionalString "source" source)
        match message with
        | ParamUpdate(path, value, source) -> pathValue "PARAM_UPDATE" path value source
        | ParamChanged(path, value, source) -> pathValue "PARAM_CHANGED" path value source
        | RequestConfig(id, source) ->
            Encode.object ([ "type", Encode.string "REQUEST_CONFIG" ] @ optionalString "pupitreId" id @ optionalString "source" source)
        | ConsoleConnect source -> Encode.object ([ "type", Encode.string "CONSOLE_CONNECT" ] @ optionalString "source" source)
        | GameMode(enabled, source) ->
            Encode.object ([ "type", Encode.string "GAME_MODE"; "enabled", Encode.bool enabled ] @ optionalString "source" source)

    let decoder: Decoder<PupitreMessage> =
        let pathValue make =
            Decode.object (fun get ->
                make (
                    get.Required.Field "path" ParamPath.decoder,
                    get.Required.Field "value" (JsonValue.decoder ()),
                    get.Optional.Field "source" Decode.string
                ))
        Decode.field "type" Decode.string
        |> Decode.andThen (function
            | "PARAM_UPDATE" -> pathValue ParamUpdate
            | "PARAM_CHANGED" -> pathValue ParamChanged
            | "REQUEST_CONFIG" ->
                Decode.object (fun get -> RequestConfig(get.Optional.Field "pupitreId" Decode.string, get.Optional.Field "source" Decode.string))
            | "CONSOLE_CONNECT" -> Decode.object (fun get -> ConsoleConnect(get.Optional.Field "source" Decode.string))
            | "GAME_MODE" ->
                Decode.object (fun get ->
                    GameMode(get.Optional.Field "enabled" Decode.bool |> Option.defaultValue false, get.Optional.Field "source" Decode.string))
            | other -> Decode.fail $"not a pupitre message: {other}")
