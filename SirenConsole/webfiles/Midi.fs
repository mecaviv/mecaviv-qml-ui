/// The pieces and their playback (api-midi.js, midi-sequencer.js, /api/puredata/command).
///
/// The console has no clock of its own: the pupitres' PureData plays the file (M645.pd's
/// [midifile]) and reports, once per beat, the beat it has reached. The console reads the
/// same file into a score (Shared.MidiScore), so that a display knows every note in advance
/// and only needs the sound's position to scroll it.
///
/// Measured on M645.pd: the sound leaves [mrpeach/pipelist 5000], 5 s after [midifile] and
/// after its position frames. The sound's position is therefore the reported one minus that
/// preroll; `Playback` applies it in one place.
module SirenConsole.Web.Midi

open System
open System.Diagnostics
open System.IO
open Giraffe
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Infrastructure.Logging
open Mecaviv.Shared.Values
open Mecaviv.Shared.MidiScore

/// The compositions repository: MECAVIV_COMPOSITIONS_PATH, else config.json's
/// paths.midiRepository (relative to mecaviv-qml-ui/, as config-loader.js resolves it), else
/// config.template.json's default.
let compositionsDir (repoRoot: string) =
  match Environment.GetEnvironmentVariable "MECAVIV_COMPOSITIONS_PATH" with
  | null
  | "" ->
    let configured =
      let file = Path.Combine(repoRoot, "config.json")

      if File.Exists file then
        Decode.fromString (Decode.at [ "paths"; "midiRepository" ] Decode.string) (File.ReadAllText file)
        |> Result.toOption
      else
        None

    let relative = configured |> Option.defaultValue "../mecaviv/compositions"

    Path.GetFullPath(
      if Path.IsPathRooted relative then
        relative
      else
        Path.Combine(repoRoot, relative)
    )
  | path -> Path.GetFullPath path

/// A path from the UI, under the compositions directory only.
let resolve (dir: string) (relative: string) =
  let full = Path.GetFullPath(Path.Combine(dir, relative))

  if full.StartsWith(Path.TrimEndingDirectorySeparator dir + string Path.DirectorySeparatorChar) then
    Some full
  else
    None

/// Whether a piece has conductor cues (api-midi.js hasConductorCuesJson): microtonal pieces.
let private hasConductorCues (midi: string) =
  let dir = Path.GetDirectoryName midi
  let name = Path.GetFileNameWithoutExtension midi
  let json = Path.GetFullPath(Path.Combine(dir, "..", "json"))

  [
    for d in [ dir; json ] do
      Path.Combine(d, $"{name}_conductor-cues.json")
      Path.Combine(d, "conductor-cues.json")
      Path.Combine(d, $"{name}.json")
  ]
  |> List.exists File.Exists

type PieceFile =
  {
    Name: string
    Path: string
    Category: string
    Microtonal: bool
    FullPath: string
  }

/// Every .mid / .midi under the directory, its category being its folder (scanDirectory).
let scan (dir: string) =
  if not (Directory.Exists dir) then
    []
  else
    Directory.EnumerateFiles(dir, "*", SearchOption.AllDirectories)
    |> Seq.filter (fun f ->
      let ext = (Path.GetExtension f).ToLowerInvariant()
      ext = ".mid" || ext = ".midi")
    |> Seq.map (fun f ->
      let relative = (Path.GetRelativePath(dir, f)).Replace('\\', '/')
      let folder = Path.GetDirectoryName relative

      {
        Name = Path.GetFileName f
        Path = relative
        Category =
          (if String.IsNullOrEmpty folder then
             "uncategorized"
           else
             folder.Replace('\\', '/'))
        Microtonal = hasConductorCues f
        FullPath = f
      })
    |> Seq.sortBy (fun f -> f.Path)
    |> List.ofSeq

let private encodeFile (f: PieceFile) =
  Encode.object
    [
      "name", Encode.string f.Name
      "path", Encode.string f.Path
      "category", Encode.string f.Category
      "microtonal", Encode.bool f.Microtonal
      "fullPath", Encode.string f.FullPath
    ]

/// The loaded piece and where the sound is in it, from the reference pupitre's frames.
type Playback(prerollMs: float) =
  let gate = obj ()
  let clock = Stopwatch.StartNew()
  let mutable piece: (string * Score) option = None
  let mutable playing = false
  /// The file's beat (quarter notes) of the last frame, and when it came (clock ms).
  let mutable beat = 0.0
  let mutable frameAt = 0.0

  /// Between two frames (one per beat) the position is extrapolated; never further than this
  /// past the last frame, should the frames stop.
  let maxExtrapolationMs = 2000.0

  member _.PrerollMs = prerollMs

  member _.Load(path: string, score: Score) =
    lock gate (fun () ->
      piece <- Some(path, score)
      playing <- false
      beat <- 0.0
      frameAt <- clock.Elapsed.TotalMilliseconds)

  member _.Piece = lock gate (fun () -> piece)

  /// A transport command relayed to the pupitres: Pd starts at once, but its first frame
  /// comes a beat later, so the clock starts (or stops) on the command itself.
  member _.OnTransport(action: string) =
    lock gate (fun () ->
      let now = clock.Elapsed.TotalMilliseconds

      match action with
      | "play" when not playing ->
        playing <- true
        frameAt <- now
      // Measured: M645.pd's stop keeps the position, as pause does (play goes on from there).
      | "pause"
      | "stop" when playing ->
        // keep where the extrapolation had got to
        let s = piece |> Option.map snd

        let elapsed = min maxExtrapolationMs (now - frameAt)

        beat <-
          match s with
          | Some s ->
            let ms = msOfTick s.Ppq s.Tempos (int64 (Math.Round(beat * float s.Ppq))) + elapsed
            tickOfMs s.Ppq s.Tempos ms / float s.Ppq
          | None -> beat + elapsed / 500.0

        playing <- false
        frameAt <- now
      | _ -> ())

  /// Measured on M645.pd: frames come on each whole beat, and the frame sent on pause or stop
  /// repeats the last whole beat reached. The position kept is therefore the extrapolated one
  /// when that frame is less than a beat behind it.
  member _.OnPosition(isPlaying: bool, fileBeat: float) =
    lock gate (fun () ->
      let now = clock.Elapsed.TotalMilliseconds

      if isPlaying then
        beat <- fileBeat
      else
        let current =
          if playing then
            match piece with
            | Some(_, s) ->
              let ms =
                msOfTick s.Ppq s.Tempos (int64 (Math.Round(beat * float s.Ppq)))
                + min maxExtrapolationMs (now - frameAt)

              tickOfMs s.Ppq s.Tempos ms / float s.Ppq
            | None -> beat + min maxExtrapolationMs (now - frameAt) / 500.0
          else
            beat

        beat <-
          if current - fileBeat >= 0.0 && current - fileBeat < 1.0 then
            current
          else
            fileBeat

      playing <- isPlaying
      frameAt <- now)

  /// The sound's position in ms (negative while the preroll counts in), and the state.
  member _.Now() =
    lock gate (fun () ->
      let fileMs =
        match piece with
        | Some(_, s) -> msOfTick s.Ppq s.Tempos (int64 (Math.Round(beat * float s.Ppq)))
        | None -> beat * 500.0

      let elapsed =
        if playing then
          min maxExtrapolationMs (clock.Elapsed.TotalMilliseconds - frameAt)
        else
          0.0

      playing, fileMs + elapsed - prerollMs, piece)

  /// GET /api/puredata/playback, as server.js served it, the position being the sound's.
  member this.Encode() : IEncodable =
    let isPlaying, soundMs, piece = this.Now()

    match piece with
    | None ->
      Encode.object
        [
          "playing", Encode.bool isPlaying
          "bar", Encode.int 1
          "beatInBar", Encode.int 1
          "beat", Encode.int 0
          "position", Encode.int 0
          "tempo", Encode.int 120
          "duration", Encode.int 0
          "totalBeats", Encode.int 0
          "timeSignature", Encode.object [ "numerator", Encode.int 4; "denominator", Encode.int 4 ]
          "file", Encode.string ""
          "prerollMs", Encode.float prerollMs
        ]
    | Some(path, s) ->
      let tick = int64 (Math.Floor(tickOfMs s.Ppq s.Tempos (max 0.0 soundMs)))
      let bar, beatInBar = barBeatOfTick s.Ppq s.Signatures tick

      let signature =
        s.Signatures |> List.filter (fun x -> x.Tick <= tick) |> List.tryLast

      let tempo = s.Tempos |> List.filter (fun (t, _) -> t <= tick) |> List.last |> snd

      Encode.object
        [
          "playing", Encode.bool isPlaying
          // during the count-in, bar 0
          "bar", Encode.int (if soundMs < 0.0 then 0 else bar)
          "beatInBar", Encode.int (if soundMs < 0.0 then 0 else beatInBar)
          "beat", Encode.float (float tick / float s.Ppq)
          "position", Encode.int (int (Math.Round soundMs))
          "tempo", Encode.int (int (Math.Round(60000000.0 / float tempo)))
          "duration", Encode.int (int (Math.Round s.DurationMs))
          "totalBeats", Encode.int (int (s.EndTick / int64 s.Ppq))
          "timeSignature",
          Encode.object
            [
              "numerator", Encode.int (signature |> Option.map (fun x -> x.Numerator) |> Option.defaultValue 4)
              "denominator", Encode.int (signature |> Option.map (fun x -> x.Denominator) |> Option.defaultValue 4)
            ]
          "file", Encode.string path
          "prerollMs", Encode.float prerollMs
        ]

/// The score for a display: every note as [ms, durationMs, channel, note, velocity], the maps
/// with their times in ms.
let encodeScore (path: string) (s: Score) (prerollMs: float) : IEncodable =
  let ms = msOfTick s.Ppq s.Tempos

  Encode.object
    [
      "success", Encode.bool true
      "file", Encode.string path
      "ppq", Encode.int s.Ppq
      "durationMs", Encode.float s.DurationMs
      "totalBeats", Encode.int (int (s.EndTick / int64 s.Ppq))
      "prerollMs", Encode.float prerollMs
      "tempos",
      s.Tempos
      |> List.map (fun (t, us) ->
        Encode.object
          [
            "tick", Encode.float (float t)
            "ms", Encode.float (ms t)
            "bpm", Encode.float (60000000.0 / float us)
          ])
      |> Encode.list
      "signatures",
      s.Signatures
      |> List.map (fun x ->
        Encode.object
          [
            "tick", Encode.float (float x.Tick)
            "ms", Encode.float (ms x.Tick)
            "numerator", Encode.int x.Numerator
            "denominator", Encode.int x.Denominator
            "bar", Encode.int x.Bar
          ])
      |> Encode.list
      "notes",
      s.Notes
      |> List.map (fun n ->
        Encode.list
          [
            Encode.float (Math.Round(n.Ms, 1))
            Encode.float (Math.Round(n.DurationMs, 1))
            Encode.int n.Channel
            Encode.int n.Note
            Encode.int n.Velocity
          ])
      |> Encode.list
    ]

let private json (status: int) (body: IEncodable) : HttpHandler =
  setStatusCode status
  >=> setHttpHeader "Content-Type" "application/json; charset=utf-8"
  >=> setBodyFromString (Encode.toString 0 body)

let private result (ok: bool) (message: string) =
  json (if ok then 200 else 400) (Encode.object [ "success", Encode.bool ok; "message", Encode.string message ])

/// GET /api/midi/files
let files (dir: string) : HttpHandler =
  fun next ctx ->
    let list = scan dir

    json
      200
      (Encode.object
        [
          "success", Encode.bool true
          "count", Encode.int list.Length
          "files", list |> List.map encodeFile |> Encode.list
          "repositoryPath", Encode.string dir
        ])
      next
      ctx

/// GET /api/midi/categories
let categories (dir: string) : HttpHandler =
  fun next ctx ->
    let groups =
      scan dir
      |> List.groupBy (fun f -> f.Category)
      |> List.map (fun (name, fs) ->
        Encode.object
          [
            "name", Encode.string name
            "count", Encode.int fs.Length
            "files", fs |> List.map encodeFile |> Encode.list
          ])

    json 200 (Encode.object [ "success", Encode.bool true; "categories", Encode.list groups ]) next ctx

/// GET /api/midi/score: the loaded piece's score.
let score (playback: Playback) : HttpHandler =
  fun next ctx ->
    match playback.Piece with
    | Some(path, s) -> json 200 (encodeScore path s playback.PrerollMs) next ctx
    | None ->
      json 404 (Encode.object [ "success", Encode.bool false; "error", Encode.string "no piece loaded" ]) next ctx

/// POST /api/puredata/command: the UI's commands, relayed to the pupitres' PureData as they
/// came. What differs from server.js: no sequencer of its own (MIDI_TRANSPORT is relayed
/// without the position its clock added; Pd keeps its own), and a command reaching no
/// pupitre is reported as such.
let command (dir: string) (playback: Playback) (links: PupitreLinks.Links) : HttpHandler =
  fun next ctx ->
    task {
      let! body = ctx.ReadBodyFromRequestAsync()

      match Decode.fromString (JsonValue.decoder ()) body with
      | Ok(JObject fields as command) ->
        let field name =
          fields |> List.tryFind (fun (k, _) -> k = name) |> Option.map snd

        let str name =
          match field name with
          | Some(JString s) -> Some s
          | _ -> None

        let toAll json =
          task {
            let! n = links.SendAllJson json
            return n > 0
          }

        let toPupitreOrAll json =
          match str "pupitreId" with
          | Some id -> links.SendJson(id, json)
          | None -> toAll json

        match str "type" with
        | Some "MIDI_FILE_LOAD" ->
          match str "path" |> Option.bind (resolve dir) with
          | Some full when File.Exists full ->
            match read (File.ReadAllBytes full) with
            | Ok s ->
              playback.Load((str "path").Value, s)
              let! sent = toAll command
              info $"MIDI file {full}: {s.Notes.Length} notes, {s.DurationMs / 1000.0:F1} s"

              return!
                result
                  true
                  (if sent then
                     "Fichier chargé"
                   else
                     "Fichier chargé (aucun pupitre connecté)")
                  next
                  ctx
            | Error e -> return! result false $"Erreur chargement fichier: {e}" next ctx
          | _ -> return! result false "Erreur chargement fichier" next ctx
        | Some "UI_CONTROLS" ->
          let enabled =
            match field "enabled" with
            | Some(JBool false) -> false
            | _ -> true

          let update =
            JObject
              [
                "type", JString "PARAM_UPDATE"
                "path", JArray [ JString "uiControls"; JString "enabled" ]
                "value", JNumber(if enabled then 1.0 else 0.0)
                "source", JString "console"
              ]

          let! sent = toPupitreOrAll update
          return! result sent "Commande UI envoyée" next ctx
        | Some "AUTONOMY_MODE" ->
          let! sent = toPupitreOrAll command
          // success either way: the UI keeps its state for a pupitre that connects later
          return!
            result
              true
              (if sent then
                 "Commande autonomie envoyée"
               else
                 "État mis à jour (pupitre non connecté)")
              next
              ctx
        | Some kind ->
          let! sent = toAll command

          match kind, str "action" with
          | "MIDI_TRANSPORT", Some action when sent -> playback.OnTransport action
          | _ -> ()

          let message =
            match kind, field "action" with
            | "MIDI_TRANSPORT", Some(JString action) -> action
            | _ -> kind

          return! result sent (if sent then message else "PureData non connecté") next ctx
        | None -> return! result false "type manquant" next ctx
      | Ok _ -> return! result false "commande invalide" next ctx
      | Error e -> return! result false e next ctx
    }

let routes (dir: string) (playback: Playback) (links: PupitreLinks.Links) : HttpHandler =
  choose
    [
      GET >=> route "/api/midi/files" >=> files dir
      GET >=> route "/api/midi/categories" >=> categories dir
      GET >=> route "/api/midi/score" >=> score playback
      GET
      >=> route "/api/puredata/playback"
      >=> (fun next ctx -> json 200 (playback.Encode()) next ctx)
      POST >=> route "/api/puredata/command" >=> command dir playback links
    ]
