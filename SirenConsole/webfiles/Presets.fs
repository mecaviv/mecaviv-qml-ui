/// SirenConsole's presets: presets.json and the routes of api-presets.js and of server.js
/// (/api/presets/current…). Same requests and same answers as the Node server, so the QML UI
/// works unchanged. Every read-modify-write holds one lock: the Node routes could interleave.
module SirenConsole.Web.Presets

open System
open System.IO
open System.Threading
open System.Threading.Tasks
open Giraffe
open Microsoft.AspNetCore.Http
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Infrastructure.Logging
open Mecaviv.Shared.Values
open Mecaviv.Shared.Config
open Mecaviv.Shared.Console
open Mecaviv.Shared.PresetSync

/// Where PARAM_UPDATE goes when a preset changes for a synced pupitre. Wired to the pupitres'
/// WebSocket links by the server; the presets don't know how.
type PupitreLink =
  abstract IsSynced: pupitreId: string -> bool
  abstract Send: pupitreId: string -> message: PupitreMessage -> unit

let noLink =
  { new PupitreLink with
      member _.IsSynced _ = false
      member _.Send _ _ = ()
  }

let isoNow () =
  DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")

/// The presets written when the file is missing or unreadable (createDefaultPresets).
let defaults () : PresetsFile =
  let mapping (pairs: (string * int * string) list) =
    Some(
      pairs
      |> List.map (fun (name, cc, curve) ->
        name,
        {
          Cc = Some cc
          Curve = Some curve
          Extra = []
        })
    )

  let pupitre vst rtp cc =
    { PresetPupitre.empty "P1" with
        AssignedSirenes = Some [ 1 ]
        VstEnabled = Some vst
        UdpEnabled = Some true
        RtpMidiEnabled = Some rtp
        ControllerMapping =
          mapping
            [
              "joystickX", cc, (if vst then "linear" else "parabolic")
              "joystickY", cc + 1, (if vst then "parabolic" else "hyperbolic")
              "fader", cc + 2, (if vst then "hyperbolic" else "linear")
              "selector", cc + 3, "s curve"
              "pedalId", cc + 4, "linear"
            ]
    }

  let preset id name description p =
    {
      Id = id
      Name = Some name
      Description = Some description
      Created = Some(isoNow ())
      Modified = Some(isoNow ())
      Version = Some "1.0"
      Pupitres = [ p ]
      OtherConfig = []
      Extra = []
    }

  {
    Presets =
      [
        preset "preset_001" "Configuration Théâtre" "Setup pour spectacle théâtral" (pupitre true true 1)
        preset "preset_002" "Configuration Studio" "Setup pour enregistrement studio" (pupitre false false 10)
      ]
  }

/// presets.json, behind one lock.
type Store(path: string) =
  let gate = new SemaphoreSlim(1, 1)
  let mutable currentId: string option = None

  let write (file: PresetsFile) =
    let tmp = path + ".tmp"
    File.WriteAllText(tmp, Encode.toString 2 (PresetsFile.encode file))
    File.Move(tmp, path, true)

  let read () =
    if not (File.Exists path) then
      let d = defaults ()
      write d
      info $"presets: {path} created with the default presets"
      d
    else
      match Decode.fromString PresetsFile.decoder (File.ReadAllText path) with
      | Ok file -> file
      | Error e ->
        // healPresetsFile: keep the unreadable file aside, start again from the defaults
        let stamp = DateTime.UtcNow.ToString("yyyy-MM-dd'T'HH-mm-ss-fff'Z'")
        let backup = $"{path}.corrupted-{stamp}"
        Mecaviv.Infrastructure.Logging.error $"presets: {path} unreadable ({e}), kept as {backup}, defaults written"

        (try
          File.Move(path, backup)
         with ex ->
           Mecaviv.Infrastructure.Logging.error $"presets: backup failed: {ex.Message}")

        let d = defaults ()
        write d
        d

  /// The current preset of `file` (ensureCurrentPreset): the remembered one, else the first.
  let current (file: PresetsFile) =
    match
      currentId
      |> Option.bind (fun id -> file.Presets |> List.tryFind (fun p -> p.Id = id))
    with
    | Some p -> Some p
    | None ->
      let first = List.tryHead file.Presets
      currentId <- first |> Option.map (fun p -> p.Id)
      first

  member _.Path = path

  /// Runs `f` on the file under the lock; `f` returns the file to write (if changed) and a result.
  member _.Locked(f: PresetsFile -> PresetsFile option * 'r) : Task<'r> =
    task {
      do! gate.WaitAsync()

      try
        let file = read ()
        let changed, result = f file
        changed |> Option.iter write
        return result
      finally
        gate.Release() |> ignore
    }

  /// The current preset, creating the defaults when there is none (getOrCreateCurrentPreset).
  member this.Current() : Task<Preset> =
    this.Locked(fun file ->
      match current file with
      | Some p -> None, p
      | None ->
        let d = defaults ()
        currentId <- Some d.Presets.Head.Id
        Some d, d.Presets.Head)

  member _.CurrentId
    with get () = currentId
    and set v = currentId <- v

// ─────────────────────────────── HTTP ───────────────────────────────

let private json (status: int) (body: IEncodable) : HttpHandler =
  setStatusCode status
  >=> setHttpHeader "Content-Type" "application/json; charset=utf-8"
  >=> setBodyFromString (Encode.toString 0 body)

let private error status (message: string) =
  json status (Encode.object [ "error", Encode.string message ])

let private patchError (message: string) =
  json 400 (Encode.object [ "success", Encode.bool false; "error", Encode.string message ])

let private body (ctx: HttpContext) =
  task { return! ctx.ReadBodyFromRequestAsync() }

/// The fields of a JSON object body (anything else is an error).
let private objectFields (text: string) : Result<(string * JsonValue) list, string> =
  match Decode.fromString (JsonValue.decoder ()) text with
  | Ok(JObject fields) -> Ok fields
  | Ok _ -> Error "expected a JSON object"
  | Error e -> Error e

let private field name (fields: (string * JsonValue) list) =
  fields |> List.tryFind (fun (k, _) -> k = name) |> Option.map snd

let private textOf (v: JsonValue) =
  match v with
  | JString s -> s
  | JNumber n -> string n
  | JBool b -> if b then "true" else "false"
  | JNull -> "null"
  | other -> string other

/// A preset from a request body, which may have no id yet (POST).
let private presetOfBody (text: string) : Result<Preset, string> =
  objectFields text
  |> Result.bind (fun fields ->
    let fields =
      if field "id" fields |> Option.isSome then
        fields
      else
        ("id", JString "") :: fields

    Decode.fromString Preset.decoder (Encode.toString 0 (JsonValue.encode (JObject fields))))

let private replace (preset: Preset) (file: PresetsFile) =
  if file.Presets |> List.exists (fun p -> p.Id = preset.Id) then
    { file with
        Presets = file.Presets |> List.map (fun p -> if p.Id = preset.Id then preset else p)
    }
  else
    { file with
        Presets = file.Presets @ [ preset ]
    }

let private generateId () =
  let rnd = Random.Shared
  let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
  let suffix = String(Array.init 9 (fun _ -> chars.[rnd.Next chars.Length]))
  $"preset_{DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()}_{suffix}"

/// GET /api/presets
let private list (store: Store) : HttpHandler =
  fun next ctx ->
    task {
      let! file = store.Locked(fun f -> None, f)
      return! json 200 (PresetsFile.encode file) next ctx
    }

/// GET /api/presets/:id
let private getOne (store: Store) (id: string) : HttpHandler =
  fun next ctx ->
    task {
      let! found =
        store.Locked(fun f -> None, f.Presets |> List.tryFind (fun p -> p.Id = id))

      match found with
      | Some p -> return! json 200 (Preset.encode p) next ctx
      | None -> return! error 404 "Preset non trouvé" next ctx
    }

/// POST /api/presets
let private create (store: Store) : HttpHandler =
  fun next ctx ->
    task {
      let! text = body ctx

      match presetOfBody text with
      | Ok p when p.Name |> Option.exists (fun n -> n <> "") ->
        let now = isoNow ()

        let created =
          { p with
              Id = generateId ()
              Created = Some now
              Modified = Some now
              Version = p.Version |> Option.orElse (Some "1.0")
          }

        do!
          store.Locked(fun f ->
            Some
              { f with
                  Presets = f.Presets @ [ created ]
              },
            ())

        return! json 201 (Preset.encode created) next ctx
      | Ok _ -> return! error 400 "Le nom du preset est requis" next ctx
      | Error e -> return! error 400 e next ctx
    }

/// PUT /api/presets/:id
let private update (store: Store) (id: string) : HttpHandler =
  fun next ctx ->
    task {
      let! text = body ctx

      match presetOfBody text with
      | Error e -> return! error 400 e next ctx
      | Ok p ->
        let! result =
          store.Locked(fun f ->
            match f.Presets |> List.tryFind (fun x -> x.Id = id) with
            | None -> None, None
            | Some existing ->
              let updated =
                { p with
                    Id = id
                    Modified = Some(isoNow ())
                    Created = existing.Created |> Option.orElse p.Created
                }

              Some(replace updated f), Some updated)

        match result with
        | Some updated -> return! json 200 (Preset.encode updated) next ctx
        | None -> return! error 404 "Preset non trouvé" next ctx
    }

/// DELETE /api/presets/:id
let private delete (store: Store) (id: string) : HttpHandler =
  fun next ctx ->
    task {
      let! found =
        store.Locked(fun f ->
          if f.Presets |> List.exists (fun p -> p.Id = id) then
            Some
              { f with
                  Presets = f.Presets |> List.filter (fun p -> p.Id <> id)
              },
            true
          else
            None, false)

      if found then
        return! (setStatusCode 204 >=> setBodyFromString "") next ctx
      else
        return! error 404 "Preset non trouvé" next ctx
    }

/// GET /api/presets/current → { preset, currentId }
let private getCurrent (store: Store) : HttpHandler =
  fun next ctx ->
    task {
      let! preset = store.Current()

      let currentId =
        store.CurrentId |> Option.map Encode.string |> Option.defaultValue Encode.nil

      return! json 200 (Encode.object [ "preset", Preset.encode preset; "currentId", currentId ]) next ctx
    }

/// PUT /api/presets/current: the body becomes the current preset.
let private putCurrent (store: Store) : HttpHandler =
  fun next ctx ->
    task {
      let! text = body ctx

      match Decode.fromString Preset.decoder text with
      | Error e -> return! error 400 e next ctx
      | Ok p ->
        do! store.Locked(fun f -> Some(replace p f), ())
        store.CurrentId <- Some p.Id
        return! json 200 (Encode.object [ "preset", Preset.encode p; "currentId", Encode.string p.Id ]) next ctx
    }

/// getOrCreatePupitreEntry: a new entry has these fields, as in server.js.
let private entryIn (preset: Preset) (pupitreId: string) =
  preset.Pupitres
  |> List.tryFind (fun p -> p.Id = pupitreId)
  |> Option.defaultWith (fun () ->
    { PresetPupitre.empty pupitreId with
        AssignedSirenes = Some []
        ControllerMapping = Some []
        Sirenes = Some []
        GameMode = Some false
    })

let private withEntry (preset: Preset) (entry: PresetPupitre) =
  if preset.Pupitres |> List.exists (fun p -> p.Id = entry.Id) then
    { preset with
        Pupitres = preset.Pupitres |> List.map (fun p -> if p.Id = entry.Id then entry else p)
    }
  else
    { preset with
        Pupitres = preset.Pupitres @ [ entry ]
    }

/// A PATCH on the current preset's entry for one pupitre: `change` reads the request body and
/// returns the changed entry, the PARAM_UPDATE messages for a synced pupitre, and the answer's
/// own fields. The change is written into the file (the Node routes lost it: fixed in #9).
let private patchEntry
  (store: Store)
  (link: PupitreLink)
  (change:
    (string * JsonValue) list -> PresetPupitre -> PresetPupitre * PupitreMessage list * (string * IEncodable) list)
  : HttpHandler =
  fun next ctx ->
    task {
      let! text = body ctx

      let decoded =
        objectFields text
        |> Result.map (fun fields ->
          let id =
            field "pupitreId" fields
            |> Option.filter truthy
            |> Option.map textOf
            |> Option.defaultValue ""

          id, fields)

      match decoded with
      | Error e -> return! patchError e next ctx
      | Ok("", _) -> return! patchError "Missing pupitreId" next ctx
      | Ok(pupitreId, fields) ->
        try
          let! current = store.Current()

          let! outcome =
            store.Locked(fun f ->
              let preset =
                f.Presets
                |> List.tryFind (fun p -> p.Id = current.Id)
                |> Option.defaultValue current

              let entry, messages, answer = change fields (entryIn preset pupitreId)
              Some(replace (withEntry preset entry) f), (preset.Id, messages, answer))

          let presetId, messages, answer = outcome

          if link.IsSynced pupitreId then
            messages |> List.iter (link.Send pupitreId)

          let fields =
            [
              "success", Encode.bool true
              "presetId", Encode.string presetId
              "pupitreId", Encode.string pupitreId
            ]
            @ answer

          return! json 200 (Encode.object fields) next ctx
        with ex ->
          return! patchError ex.Message next ctx
    }

let private send path value =
  ParamUpdate(path, value, Some "console")

let private bit b = JNumber(if b then 1.0 else 0.0)

let private optBool name (v: bool option) =
  match v with
  | Some b -> [ name, Encode.bool b ]
  | None -> []

/// PATCH /api/presets/current/assigned-sirenes { pupitreId, assignedSirenes }
let private assignedSirenes store link =
  patchEntry store link (fun fields entry ->
    let ids =
      field "assignedSirenes" fields
      |> Option.map (function
        | JArray items -> items |> List.choose parseInt
        | _ -> [])
      |> Option.defaultValue []

    { entry with
        AssignedSirenes = Some ids
    },
    [
      send [ Key "sirenConfig"; Key "currentSirens" ] (ids |> List.map (float >> JNumber) |> JArray)
    ],
    [ "assignedSirenes", ids |> List.map Encode.int |> Encode.list ])

/// PATCH /api/presets/current/sirene-config { pupitreId, sireneId, changes }
let private sireneConfig store link =
  patchEntry store link (fun fields entry ->
    let sireneId =
      match field "sireneId" fields |> Option.filter truthy |> Option.bind parseInt with
      | Some n -> n
      | None -> failwith "Missing sireneId"

    let changes =
      match field "changes" fields with
      | Some(JObject c) -> c
      | _ -> []

    let key = $"sirene{sireneId}"

    let blank =
      {
        AmbitusRestricted = Some false
        FrettedMode = Some false
        Extra = []
      }

    let sirenes = defaultArg entry.Sirenes []

    let settings =
      sirenes
      |> List.tryFind (fun (k, _) -> k = key)
      |> Option.map snd
      |> Option.defaultValue blank

    let settings =
      changes
      |> List.fold
        (fun (s: SireneSettings) (k, v) ->
          match k with
          | "ambitusRestricted" ->
            { s with
                AmbitusRestricted = Some(truthy v)
            }
          | "frettedMode" -> { s with FrettedMode = Some(truthy v) }
          | other ->
            { s with
                Extra = (s.Extra |> List.filter (fun (n, _) -> n <> other)) @ [ other, v ]
            })
        settings

    let sirenes =
      if sirenes |> List.exists (fun (k, _) -> k = key) then
        sirenes |> List.map (fun (k, s) -> if k = key then k, settings else k, s)
      else
        sirenes @ [ key, settings ]

    let siren = [ Key "sirenConfig"; Key "sirens"; Index(sireneId - 1) ]

    let messages =
      changes
      |> List.choose (fun (k, v) ->
        match k with
        | "ambitusRestricted" -> Some(send (siren @ [ Key "ambitus"; Key "restricted" ]) (bit (truthy v)))
        | "frettedMode" -> Some(send (siren @ [ Key "frettedMode"; Key "enabled" ]) (bit (truthy v)))
        | _ -> None)

    { entry with Sirenes = Some sirenes },
    messages,
    [ "sireneId", Encode.int sireneId; "sirene", SireneSettings.encode settings ])

/// PATCH /api/presets/current/outputs { pupitreId, changes }
let private outputs store link =
  patchEntry store link (fun fields entry ->
    let changes =
      match field "changes" fields with
      | Some(JObject c) -> c
      | _ -> []

    let value name =
      changes |> List.tryFind (fun (k, _) -> k = name) |> Option.map (snd >> truthy)

    let pick name current = value name |> Option.orElse current

    let entry =
      { entry with
          VstEnabled = pick "vstEnabled" entry.VstEnabled
          UdpEnabled = pick "udpEnabled" entry.UdpEnabled
          RtpMidiEnabled = pick "rtpMidiEnabled" entry.RtpMidiEnabled
      }

    let messages =
      [ "vstEnabled"; "udpEnabled"; "rtpMidiEnabled" ]
      |> List.choose (fun name ->
        value name
        |> Option.map (fun b -> send [ Key "outputConfig"; Key name ] (bit b)))

    entry,
    messages,
    [
      "outputs",
      Encode.object (
        optBool "vstEnabled" entry.VstEnabled
        @ optBool "udpEnabled" entry.UdpEnabled
        @ optBool "rtpMidiEnabled" entry.RtpMidiEnabled
      )
    ])

/// PATCH /api/presets/current/controller-mapping { pupitreId, controller, cc, curve }
let private controllerMapping store link =
  patchEntry store link (fun fields entry ->
    let controller =
      match field "controller" fields |> Option.filter truthy with
      | Some c -> textOf c
      | None -> failwith "Missing controller"

    let cc = field "cc" fields
    let curveText = field "curve" fields |> Option.filter truthy |> Option.map textOf
    let mapping = defaultArg entry.ControllerMapping []

    let setting =
      mapping
      |> List.tryFind (fun (k, _) -> k = controller)
      |> Option.map snd
      |> Option.defaultValue { Cc = None; Curve = None; Extra = [] }

    let setting =
      { setting with
          Cc =
            (match cc with
             | Some v -> parseInt v
             | None -> setting.Cc)
          Curve = curveText |> Option.orElse setting.Curve
      }

    let mapping =
      if mapping |> List.exists (fun (k, _) -> k = controller) then
        mapping |> List.map (fun (k, s) -> if k = controller then k, setting else k, s)
      else
        mapping @ [ controller, setting ]

    let messages =
      [
        match cc |> Option.bind parseInt with
        | Some n -> send [ Key "controllerMapping"; Key controller; Key "cc" ] (JNumber(float n))
        | None -> ()
        match curveText with
        | Some c -> send [ Key "controllerMapping"; Key controller; Key "curve" ] (JString c)
        | None -> ()
      ]

    { entry with
        ControllerMapping = Some mapping
    },
    messages,
    [
      "controller", Encode.string controller
      "mapping", ControllerSetting.encode setting
    ])

/// PATCH /api/presets/current/game-mode { pupitreId, gameMode }
let private gameMode store link =
  patchEntry store link (fun fields entry ->
    let enabled =
      field "gameMode" fields |> Option.map truthy |> Option.defaultValue false

    { entry with GameMode = Some enabled },
    [ send [ Key "gameMode"; Key "enabled" ] (bit enabled) ],
    [ "gameMode", Encode.bool enabled ])

/// The preset routes. `link` sends PARAM_UPDATE to synced pupitres.
let routes (store: Store) (link: PupitreLink) : HttpHandler =
  choose
    [
      GET >=> route "/api/presets" >=> list store
      GET >=> routeStartsWith "/api/presets/current" >=> getCurrent store
      PUT >=> route "/api/presets/current" >=> putCurrent store
      PATCH
      >=> route "/api/presets/current/assigned-sirenes"
      >=> assignedSirenes store link
      PATCH >=> route "/api/presets/current/sirene-config" >=> sireneConfig store link
      PATCH >=> route "/api/presets/current/outputs" >=> outputs store link
      PATCH
      >=> route "/api/presets/current/controller-mapping"
      >=> controllerMapping store link
      PATCH >=> route "/api/presets/current/game-mode" >=> gameMode store link
      GET >=> routef "/api/presets/%s" (getOne store)
      POST >=> route "/api/presets" >=> create store
      PUT >=> routef "/api/presets/%s" (update store)
      DELETE >=> routef "/api/presets/%s" (delete store)
    ]

// ─────────────────────────────── from a pupitre ───────────────────────────────

let private member' name (v: JsonValue) =
  match v with
  | JObject fields -> fields |> List.tryFind (fun (k, _) -> k = name) |> Option.map snd
  | _ -> None

let private path (names: string list) (v: JsonValue) =
  names |> List.fold (fun acc n -> acc |> Option.bind (member' n)) (Some v)

let private sirenNumbers (v: JsonValue option) =
  match v with
  | Some(JArray items) -> Some(items |> List.choose parseInt)
  | _ -> None

/// A pupitre's configuration as PureData sends it (CONFIG_FULL's config), reduced to what the
/// console records (puredata-proxy.js convertPureDataConfigToPupitreConfig).
let convertPureDataConfig (config: JsonValue) : JsonValue =
  let assigned =
    sirenNumbers (path [ "sirenConfig"; "currentSirens" ] config)
    |> Option.orElse (
      match path [ "sirenConfig"; "assignedSirenes" ] config with
      | Some(JArray items) -> Some(items |> List.choose parseInt)
      | _ -> None
    )
    |> Option.defaultValue []

  let output name =
    path [ "outputConfig"; name ] config
    |> Option.map truthy
    |> Option.defaultValue false

  JObject
    [
      "assignedSirenes", JArray(assigned |> List.map (float >> JNumber))
      "vstEnabled", JBool(output "vstEnabled")
      "udpEnabled", JBool(output "udpEnabled")
      "rtpMidiEnabled", JBool(output "rtpMidiEnabled")
      "controllerMapping", (member' "controllerMapping" config |> Option.defaultValue (JObject []))
      "sirens",
      (match path [ "sirenConfig"; "sirens" ] config with
       | Some(JArray s) -> JArray s
       | _ -> JArray [])
    ]

/// The current preset's entry for `pupitreId` after the pupitre sent its configuration
/// (`data`: converted by convertPureDataConfig, or PUPITRE_STATUS's raw data), as
/// server.js handlePupitreConfigFromPupitre merges it.
let mergePupitreConfig (data: JsonValue) (entry: PresetPupitre) : PresetPupitre =
  let flag name = member' name data |> Option.map truthy

  let assigned =
    sirenNumbers (path [ "sirenConfig"; "currentSirens" ] data)
    |> Option.orElse (
      match member' "assignedSirenes" data with
      | Some(JArray items) -> Some(items |> List.choose parseInt)
      | Some _ -> Some []
      | None -> None
    )

  let mapping =
    member' "controllerMapping" data
    |> Option.map (fun m ->
      match
        Decode.fromString (Decode.keyValuePairs ControllerSetting.decoder) (Encode.toString 0 (JsonValue.encode m))
      with
      | Ok pairs -> pairs
      | Error _ -> [])

  let sirenes =
    match member' "sirens" data with
    | Some(JArray sirens) ->
      let start = defaultArg entry.Sirenes []

      sirens
      |> List.indexed
      |> List.fold
        (fun acc (i, siren) ->
          let key = $"sirene{i + 1}"

          let current =
            acc
            |> List.tryFind (fun (k, _) -> k = key)
            |> Option.map snd
            |> Option.defaultValue
              {
                AmbitusRestricted = None
                FrettedMode = None
                Extra = []
              }

          let restricted =
            path [ "ambitus"; "restricted" ] siren
            |> Option.orElse (member' "ambitusRestricted" siren)
            |> Option.map truthy

          let fretted =
            match member' "frettedMode" siren with
            | Some(JObject _ as f) -> member' "enabled" f |> Option.map truthy |> Option.orElse (Some true)
            | Some other -> Some(truthy other)
            | None -> None

          let updated =
            { current with
                AmbitusRestricted = restricted |> Option.orElse current.AmbitusRestricted
                FrettedMode = fretted |> Option.orElse current.FrettedMode
            }

          if acc |> List.exists (fun (k, _) -> k = key) then
            acc |> List.map (fun (k, s) -> if k = key then k, updated else k, s)
          else
            acc @ [ key, updated ])
        start
      |> Some
    | _ -> entry.Sirenes

  { entry with
      AssignedSirenes = assigned |> Option.orElse entry.AssignedSirenes
      VstEnabled = flag "vstEnabled" |> Option.orElse entry.VstEnabled
      UdpEnabled = flag "udpEnabled" |> Option.orElse entry.UdpEnabled
      RtpMidiEnabled = flag "rtpMidiEnabled" |> Option.orElse entry.RtpMidiEnabled
      ControllerMapping = mapping |> Option.orElse entry.ControllerMapping
      GameMode = flag "gameMode" |> Option.orElse entry.GameMode
      Sirenes = sirenes
  }

/// Writes a change of the current preset coming from a pupitre; returns false when there is
/// no current preset to change.
let updateFromPupitre (store: Store) (pupitreId: string) (change: PresetPupitre -> PresetPupitre) : Task<bool> =
  task {
    let! current = store.Current()

    return!
      store.Locked(fun f ->
        match f.Presets |> List.tryFind (fun p -> p.Id = current.Id) with
        | None -> None, false
        | Some preset ->
          let entry =
            preset.Pupitres
            |> List.tryFind (fun p -> p.Id = pupitreId)
            |> Option.defaultWith (fun () -> PresetPupitre.empty pupitreId)

          Some(replace (withEntry preset (change entry)) f), true)
  }
