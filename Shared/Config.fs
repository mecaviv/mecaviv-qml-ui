/// Configuration and presets (docs/CONTRAT_PARTAGE.md, § 6 bis).
module Mecaviv.Shared.Config

open Thoth.Json.Core
open Mecaviv.Shared.Values

// ─────────────────────────────── the console's pupitres ───────────────────────────────

/// A pupitre as the console reaches it (SirenConsole/config.js, `pupitres`).
type ConsolePupitre =
    { Id: string
      Name: string
      Host: string
      Port: int
      WebsocketPort: int
      Enabled: bool }

module ConsolePupitre =
    let decoder: Decoder<ConsolePupitre> =
        Decode.object (fun get ->
            let id = get.Required.Field "id" Decode.string
            { Id = id
              Name = get.Optional.Field "name" Decode.string |> Option.defaultValue id
              Host = get.Required.Field "host" Decode.string
              Port = get.Optional.Field "port" Decode.int |> Option.defaultValue 8000
              WebsocketPort = get.Optional.Field "websocketPort" Decode.int |> Option.defaultValue 10002
              Enabled = get.Optional.Field "enabled" Decode.bool |> Option.defaultValue true })

    let encode (p: ConsolePupitre) : IEncodable =
        Encode.object [
            "id", Encode.string p.Id
            "name", Encode.string p.Name
            "host", Encode.string p.Host
            "port", Encode.int p.Port
            "websocketPort", Encode.int p.WebsocketPort
            "enabled", Encode.bool p.Enabled
        ]

// ─────────────────────────────── a pupitre's sirens ───────────────────────────────

/// A siren in a pupitre's configuration (`sirenConfig.sirens[]`).
type Siren =
    { Id: int
      Name: string
      MidiChannel: int option
      AmbitusMin: int
      AmbitusMax: int
      RestrictedMax: int option
      Transposition: int
      DisplayOctaveOffset: int
      Clef: string option
      Outputs: int option
      Fretted: bool }

module Siren =
    /// Siren ids were strings in older configurations ("1"): both are read, as the pupitre does
    /// (normalizeSirenNumericIds, docs/SEMANTIQUE_NOMBRES_ET_CHAÎNES.md).
    let numericId: Decoder<int> =
        Decode.oneOf [
            Decode.int
            Decode.string
            |> Decode.andThen (fun s ->
                match System.Int32.TryParse s with
                | true, n -> Decode.succeed n
                | _ -> Decode.fail $"not a siren id: {s}")
        ]

    let decoder: Decoder<Siren> =
        Decode.object (fun get ->
            let ambitus name fallback =
                get.Optional.At [ "ambitus"; name ] Decode.int |> Option.defaultValue fallback
            let id = get.Required.Field "id" numericId
            { Id = id
              Name = get.Optional.Field "name" Decode.string |> Option.defaultValue $"S{id}"
              MidiChannel = get.Optional.Field "midiChannel" Decode.int
              AmbitusMin = ambitus "min" 48
              AmbitusMax = ambitus "max" 72
              RestrictedMax = get.Optional.Field "restrictedMax" Decode.int
              Transposition = get.Optional.Field "transposition" Decode.int |> Option.defaultValue 0
              DisplayOctaveOffset = get.Optional.Field "displayOctaveOffset" Decode.int |> Option.defaultValue 0
              Clef = get.Optional.Field "clef" Decode.string
              Outputs = get.Optional.Field "outputs" Decode.int
              Fretted = get.Optional.At [ "frettedMode"; "enabled" ] Decode.bool |> Option.defaultValue false })

    /// The sirens of a pupitre configuration (CONFIG_FULL's config, config.json, the template).
    let ofPupitreConfig: Decoder<Siren list> = Decode.at [ "sirenConfig"; "sirens" ] (Decode.list decoder)

// ─────────────────────────────── presets ───────────────────────────────

/// One pupitre in a console preset. Its controller mapping concerns the pads and joystick,
/// being redesigned: kept as is.
type PresetPupitre =
    { Id: string
      AssignedSirenes: int list
      VstEnabled: bool
      UdpEnabled: bool
      RtpMidiEnabled: bool
      ControllerMapping: JsonValue option
      Sirenes: JsonValue option }

type Preset =
    { Id: string
      Name: string
      Description: string
      Created: string option
      Modified: string option
      Version: string
      Pupitres: PresetPupitre list
      /// The rest of `config`, kept as is.
      OtherConfig: (string * JsonValue) list }

type PresetsFile = { Presets: Preset list }

module PresetPupitre =
    let decoder: Decoder<PresetPupitre> =
        Decode.object (fun get ->
            { Id = get.Required.Field "id" Decode.string
              AssignedSirenes = get.Optional.Field "assignedSirenes" (Decode.list Siren.numericId) |> Option.defaultValue []
              VstEnabled = get.Optional.Field "vstEnabled" Decode.bool |> Option.defaultValue false
              UdpEnabled = get.Optional.Field "udpEnabled" Decode.bool |> Option.defaultValue false
              RtpMidiEnabled = get.Optional.Field "rtpMidiEnabled" Decode.bool |> Option.defaultValue false
              ControllerMapping = get.Optional.Field "controllerMapping" (JsonValue.decoder ())
              Sirenes = get.Optional.Field "sirenes" (JsonValue.decoder ()) })

    let encode (p: PresetPupitre) : IEncodable =
        Encode.object [
            "id", Encode.string p.Id
            "assignedSirenes", p.AssignedSirenes |> List.map Encode.int |> Encode.list
            "vstEnabled", Encode.bool p.VstEnabled
            "udpEnabled", Encode.bool p.UdpEnabled
            "rtpMidiEnabled", Encode.bool p.RtpMidiEnabled
            match p.ControllerMapping with
            | Some m -> "controllerMapping", JsonValue.encode m
            | None -> ()
            match p.Sirenes with
            | Some s -> "sirenes", JsonValue.encode s
            | None -> ()
        ]

module Preset =
    /// One format, the pupitres in `config.pupitres`. The old format had them at the root of the
    /// preset: they are used only when `config.pupitres` is missing, as normalizePreset does in
    /// SirenConsole/webfiles/api-presets.js.
    let decoder: Decoder<Preset> =
        Decode.object (fun get ->
            let config = get.Optional.Field "config" (Decode.keyValuePairs (JsonValue.decoder ())) |> Option.defaultValue []
            let inConfig = get.Optional.At [ "config"; "pupitres" ] (Decode.list PresetPupitre.decoder)
            let atRoot = get.Optional.Field "pupitres" (Decode.list PresetPupitre.decoder)
            { Id = get.Required.Field "id" Decode.string
              Name = get.Optional.Field "name" Decode.string |> Option.defaultValue ""
              Description = get.Optional.Field "description" Decode.string |> Option.defaultValue ""
              Created = get.Optional.Field "created" Decode.string
              Modified = get.Optional.Field "modified" Decode.string
              Version = get.Optional.Field "version" Decode.string |> Option.defaultValue "1.0"
              Pupitres = inConfig |> Option.orElse atRoot |> Option.defaultValue []
              OtherConfig = config |> List.filter (fun (k, _) -> k <> "pupitres") })

    let encode (p: Preset) : IEncodable =
        Encode.object [
            "id", Encode.string p.Id
            "name", Encode.string p.Name
            "description", Encode.string p.Description
            match p.Created with
            | Some c -> "created", Encode.string c
            | None -> ()
            match p.Modified with
            | Some m -> "modified", Encode.string m
            | None -> ()
            "version", Encode.string p.Version
            "config",
            Encode.object (
                ("pupitres", p.Pupitres |> List.map PresetPupitre.encode |> Encode.list)
                :: (p.OtherConfig |> List.map (fun (k, v) -> k, JsonValue.encode v)))
        ]

module PresetsFile =
    let decoder: Decoder<PresetsFile> =
        Decode.field "presets" (Decode.list Preset.decoder) |> Decode.map (fun ps -> { Presets = ps })

    let encode (f: PresetsFile) : IEncodable =
        Encode.object [ "presets", f.Presets |> List.map Preset.encode |> Encode.list ]
