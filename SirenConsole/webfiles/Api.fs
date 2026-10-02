/// SirenConsole's HTTP routes besides the presets (server.js): config.js, the pupitres'
/// status and sync, sending the current preset to the pupitres, PureData's status and events.
/// `webApp` composes every route of the server, as SirenManager's backend does.
module SirenConsole.Web.Api

open System
open System.IO
open Giraffe
open Microsoft.AspNetCore.Http
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Shared.Values
open Mecaviv.Shared.Console
open Mecaviv.Shared.PresetSync

type Deps =
  {
    Presets: Presets.Store
    PresetLink: Presets.PupitreLink
    Links: PupitreLinks.Links
    Sync: UiSocket.SyncState
    Hub: UiSocket.Hub
    Pupitres: Mecaviv.Shared.Config.ConsolePupitre list
    /// SirenConsole/config.js, served as /config.js (the QML UI loads it).
    ConfigJs: string
    /// The compositions repository.
    Compositions: string
    Playback: Midi.Playback
  }

let private json (status: int) (body: IEncodable) : HttpHandler =
  setStatusCode status
  >=> setHttpHeader "Content-Type" "application/json; charset=utf-8"
  >=> setBodyFromString (Encode.toString 0 body)

let private nowMs () =
  float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())

let private status (deps: Deps) =
  (deps.Links :> UiSocket.PupitreStatusSource).Status()

/// GET /config.js: server.js serves ../config.js under this name.
let private configJs (deps: Deps) : HttpHandler =
  fun next ctx ->
    if File.Exists deps.ConfigJs then
      (setHttpHeader "Content-Type" "application/javascript; charset=utf-8"
       >=> setBodyFromString (File.ReadAllText deps.ConfigJs))
        next
        ctx
    else
      (setStatusCode 404 >=> text "config.js not found") next ctx

/// GET /api/pupitres/:id/sync-status
let private syncStatus (deps: Deps) (id: string) : HttpHandler =
  let synced, last = deps.Sync.Get id

  json
    200
    (Encode.object
      [
        "pupitreId", Encode.string id
        "isSynced", Encode.bool synced
        "lastSync", (last |> Option.map Encode.float |> Option.defaultValue Encode.nil)
      ])

/// GET /api/pupitres/status and /api/puredata/status: the links' status, without sync state.
let private allStatus (deps: Deps) : HttpHandler =
  fun next ctx -> json 200 (encodePupitresStatus (status deps)) next ctx

/// GET /api/pupitres/:id/status
let private oneStatus (deps: Deps) (id: string) : HttpHandler =
  fun next ctx ->
    match (status deps).Connections |> List.tryFind (fun c -> c.PupitreId = id) with
    | Some c -> json 200 (encodePupitreConnection c) next ctx
    | None -> json 404 (Encode.object [ "error", Encode.string "Pupitre non trouvé" ]) next ctx

/// GET /api/puredata/events?since=<ms>
let private events (deps: Deps) : HttpHandler =
  fun next ctx ->
    let since =
      match Double.TryParse(string ctx.Request.Query.["since"]) with
      | true, v -> v
      | _ -> 0.0

    let list = deps.Links.Events since |> List.map JsonValue.encode |> Encode.list
    json 200 (Encode.object [ "events", list ]) next ctx

/// GET /api/volant-data
let private volant (deps: Deps) : HttpHandler =
  fun next ctx ->
    let data =
      deps.Links.LastVolant
      |> Option.map JsonValue.encode
      |> Option.defaultValue Encode.nil

    json 200 (Encode.object [ "volantData", data ]) next ctx

/// POST /api/presets/current/upload: the current preset to every connected pupitre
/// (CONSOLE_CONNECT, then its PARAM_UPDATE messages); each pupitre becomes synced.
let private upload (deps: Deps) : HttpHandler =
  fun next ctx ->
    task {
      let! preset = deps.Presets.Current()
      let results = Collections.Generic.List<string * IEncodable>()

      for c in (status deps).Connections do
        if c.Connected then
          if not (deps.Sync.IsSynced c.PupitreId) then
            do! deps.Hub.Send(deps.Sync.Set(c.PupitreId, true))

          let! _ = deps.Links.Send(c.PupitreId, ConsoleConnect(Some "console"))
          let updates = toParamUpdates preset c.PupitreId
          let mutable sent = 0

          for u in updates do
            let! ok = deps.Links.Send(c.PupitreId, u)

            if ok then
              sent <- sent + 1

          results.Add(
            c.PupitreId,
            Encode.object
              [
                "success", Encode.bool true
                "updatesSent", Encode.int sent
                "totalUpdates", Encode.int updates.Length
              ]
          )
        else
          results.Add(
            c.PupitreId,
            Encode.object [ "success", Encode.bool false; "error", Encode.string "Pupitre not connected" ]
          )

      return!
        json 200 (Encode.object [ "success", Encode.bool true; "results", Encode.object (List.ofSeq results) ]) next ctx
    }

/// POST /api/presets/current/download: every connected pupitre is asked for its
/// configuration; each answer comes back through its link (about 3 s later) and updates the
/// preset. server.js then waited 5 s on a list it never emptied; this answers at once.
let private download (deps: Deps) : HttpHandler =
  fun next ctx ->
    task {
      let! _ = deps.Presets.Current()
      let requested = Collections.Generic.List<string>()

      for c in (status deps).Connections do
        if c.Connected then
          if not (deps.Sync.IsSynced c.PupitreId) then
            do! deps.Hub.Send(deps.Sync.Set(c.PupitreId, true))

          let! _ =
            deps.Links.Send(c.PupitreId, RequestConfig(Some c.PupitreId, Some "console"))

          requested.Add c.PupitreId

      return!
        json
          200
          (Encode.object
            [
              "success", Encode.bool true
              "message",
              Encode.string "Download initiated. PureData will send CONFIG_FULL responses via existing connections."
              "requestedFrom", requested |> Seq.map Encode.string |> List.ofSeq |> Encode.list
            ])
          next
          ctx
    }

/// POST /api/test/pupitre-connected { pupitreId }: announces a pupitre to the UI (test aid).
let private testPupitreConnected (deps: Deps) : HttpHandler =
  fun next ctx ->
    task {
      let! body = ctx.ReadBodyFromRequestAsync()

      match Decode.fromString (Decode.field "pupitreId" Decode.string) body with
      | Ok id when id <> "" ->
        let connection =
          {
            PupitreId = id
            PupitreName = $"Pupitre {id}"
            Connected = true
            Url = None
            LastSeen = None
            IsSynced = None
            LastSync = None
          }

        do! deps.Hub.Send(PupitreConnected(connection, nowMs ()))

        return!
          json
            200
            (Encode.object
              [
                "success", Encode.bool true
                "message", Encode.string $"PUPITRE_CONNECTED envoyé pour {id}"
                "clients", Encode.int deps.Hub.Count
              ])
            next
            ctx
      | _ ->
        return!
          json 400 (Encode.object [ "success", Encode.bool false; "error", Encode.string "Missing pupitreId" ]) next ctx
    }

/// Every route of the server.
let webApp (deps: Deps) : HttpHandler =
  choose
    [
      GET >=> route "/config.js" >=> configJs deps
      ConsoleConfig.route deps.Pupitres
      Presets.routes deps.Presets deps.PresetLink
      POST >=> route "/api/presets/current/upload" >=> upload deps
      POST >=> route "/api/presets/current/download" >=> download deps
      GET >=> routef "/api/pupitres/%s/sync-status" (syncStatus deps)
      GET >=> route "/api/pupitres/status" >=> allStatus deps
      GET >=> routef "/api/pupitres/%s/status" (oneStatus deps)
      GET >=> route "/api/puredata/status" >=> allStatus deps
      GET >=> routeStartsWith "/api/puredata/events" >=> events deps
      Midi.routes deps.Compositions deps.Playback deps.Links
      GET >=> route "/api/volant-data" >=> volant deps
      POST >=> route "/api/test/pupitre-connected" >=> testPupitreConnected deps
    ]
