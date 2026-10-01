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
//
// Every known field is optional, as in the JS (`!== undefined`): an absent setting is not a
// false one, and the conversions to PARAM_UPDATE skip it. Unknown fields are kept in Extra, so
// that the F# server can rewrite presets.json without losing anything.

/// A boolean as the console writes it (`value ? true : false`), also read from 0 / 1.
let private flag: Decoder<bool> =
    Decode.oneOf [ Decode.bool; Decode.map (fun (n: float) -> n <> 0.0) Decode.float ]

/// The fields of an object other than `known`, kept as they are.
let private extra (known: string list) : Decoder<(string * JsonValue) list> =
    Decode.keyValuePairs (JsonValue.decoder ())
    |> Decode.map (List.filter (fun (k, _) -> not (List.contains k known)))

let private encodeExtra (fields: (string * JsonValue) list) =
    fields |> List.map (fun (k, v) -> k, JsonValue.encode v)

let private opt name (encode: 'a -> IEncodable) (value: 'a option) =
    match value with
    | Some v -> [ name, encode v ]
    | None -> []

/// Per-siren settings of a pupitre in a preset (`sirenes.sireneN`).
type SireneSettings =
    { AmbitusRestricted: bool option
      FrettedMode: bool option
      Extra: (string * JsonValue) list }

/// A controller mapping (`controllerMapping.<control>`): pads and joystick, being redesigned.
type ControllerSetting =
    { Cc: int option
      Curve: string option
      Extra: (string * JsonValue) list }

/// One pupitre in a console preset (`config.pupitres[]`).
type PresetPupitre =
    { Id: string
      AssignedSirenes: int list option
      VstEnabled: bool option
      UdpEnabled: bool option
      RtpMidiEnabled: bool option
      GameMode: bool option
      /// `sirene1`, `sirene2`… in file order.
      Sirenes: (string * SireneSettings) list option
      /// Control name (`joystickX`, `fader`…) in file order.
      ControllerMapping: (string * ControllerSetting) list option
      Extra: (string * JsonValue) list }

type Preset =
    { Id: string
      Name: string option
      Description: string option
      Created: string option
      Modified: string option
      Version: string option
      Pupitres: PresetPupitre list
      /// The rest of `config`, kept as is.
      OtherConfig: (string * JsonValue) list
      Extra: (string * JsonValue) list }

type PresetsFile = { Presets: Preset list }

module SireneSettings =
    let decoder: Decoder<SireneSettings> =
        Decode.object (fun get ->
            { AmbitusRestricted = get.Optional.Field "ambitusRestricted" flag
              FrettedMode = get.Optional.Field "frettedMode" flag
              Extra = get.Required.Raw(extra [ "ambitusRestricted"; "frettedMode" ]) })

    let encode (s: SireneSettings) : IEncodable =
        Encode.object (
            opt "ambitusRestricted" Encode.bool s.AmbitusRestricted
            @ opt "frettedMode" Encode.bool s.FrettedMode
            @ encodeExtra s.Extra)

module ControllerSetting =
    let decoder: Decoder<ControllerSetting> =
        Decode.object (fun get ->
            { Cc = get.Optional.Field "cc" Decode.int
              Curve = get.Optional.Field "curve" Decode.string
              Extra = get.Required.Raw(extra [ "cc"; "curve" ]) })

    let encode (c: ControllerSetting) : IEncodable =
        Encode.object (opt "cc" Encode.int c.Cc @ opt "curve" Encode.string c.Curve @ encodeExtra c.Extra)

module PresetPupitre =
    let private known =
        [ "id"; "assignedSirenes"; "vstEnabled"; "udpEnabled"; "rtpMidiEnabled"; "gameMode"; "sirenes"; "controllerMapping" ]

    let empty id =
        { Id = id
          AssignedSirenes = None
          VstEnabled = None
          UdpEnabled = None
          RtpMidiEnabled = None
          GameMode = None
          Sirenes = None
          ControllerMapping = None
          Extra = [] }

    let decoder: Decoder<PresetPupitre> =
        Decode.object (fun get ->
            { Id = get.Required.Field "id" Decode.string
              AssignedSirenes = get.Optional.Field "assignedSirenes" (Decode.list Siren.numericId)
              VstEnabled = get.Optional.Field "vstEnabled" flag
              UdpEnabled = get.Optional.Field "udpEnabled" flag
              RtpMidiEnabled = get.Optional.Field "rtpMidiEnabled" flag
              GameMode = get.Optional.Field "gameMode" flag
              Sirenes = get.Optional.Field "sirenes" (Decode.keyValuePairs SireneSettings.decoder)
              ControllerMapping = get.Optional.Field "controllerMapping" (Decode.keyValuePairs ControllerSetting.decoder)
              Extra = get.Required.Raw(extra known) })

    let encode (p: PresetPupitre) : IEncodable =
        let pairs encode (items: (string * 'a) list) = items |> List.map (fun (k, v) -> k, encode v) |> Encode.object
        Encode.object (
            [ "id", Encode.string p.Id ]
            @ opt "assignedSirenes" (List.map Encode.int >> Encode.list) p.AssignedSirenes
            @ opt "vstEnabled" Encode.bool p.VstEnabled
            @ opt "udpEnabled" Encode.bool p.UdpEnabled
            @ opt "rtpMidiEnabled" Encode.bool p.RtpMidiEnabled
            @ opt "controllerMapping" (pairs ControllerSetting.encode) p.ControllerMapping
            @ opt "sirenes" (pairs SireneSettings.encode) p.Sirenes
            @ opt "gameMode" Encode.bool p.GameMode
            @ encodeExtra p.Extra)

module Preset =
    let private known = [ "id"; "name"; "description"; "created"; "modified"; "version"; "pupitres"; "config" ]

    /// One format, the pupitres in `config.pupitres`. The old format had them at the root of the
    /// preset: they are used only when `config.pupitres` is missing, as normalizePreset does in
    /// SirenConsole/webfiles/api-presets.js.
    let decoder: Decoder<Preset> =
        Decode.object (fun get ->
            let config = get.Optional.Field "config" (Decode.keyValuePairs (JsonValue.decoder ())) |> Option.defaultValue []
            let inConfig = get.Optional.At [ "config"; "pupitres" ] (Decode.list PresetPupitre.decoder)
            let atRoot = get.Optional.Field "pupitres" (Decode.list PresetPupitre.decoder)
            { Id = get.Required.Field "id" Decode.string
              Name = get.Optional.Field "name" Decode.string
              Description = get.Optional.Field "description" Decode.string
              Created = get.Optional.Field "created" Decode.string
              Modified = get.Optional.Field "modified" Decode.string
              Version = get.Optional.Field "version" Decode.string
              Pupitres = inConfig |> Option.orElse atRoot |> Option.defaultValue []
              OtherConfig = config |> List.filter (fun (k, _) -> k <> "pupitres")
              Extra = get.Required.Raw(extra known) })

    let encode (p: Preset) : IEncodable =
        Encode.object (
            [ "id", Encode.string p.Id ]
            @ opt "name" Encode.string p.Name
            @ opt "description" Encode.string p.Description
            @ opt "created" Encode.string p.Created
            @ opt "modified" Encode.string p.Modified
            @ opt "version" Encode.string p.Version
            @ [ "config",
                Encode.object (
                    ("pupitres", p.Pupitres |> List.map PresetPupitre.encode |> Encode.list)
                    :: encodeExtra p.OtherConfig) ]
            @ encodeExtra p.Extra)

module PresetsFile =
    let decoder: Decoder<PresetsFile> =
        Decode.field "presets" (Decode.list Preset.decoder) |> Decode.map (fun ps -> { Presets = ps })

    let encode (f: PresetsFile) : IEncodable =
        Encode.object [ "presets", f.Presets |> List.map Preset.encode |> Encode.list ]
