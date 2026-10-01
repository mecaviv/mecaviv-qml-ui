/// Between a console preset and a pupitre: the PARAM_UPDATE messages that apply a preset to a
/// pupitre, and the change a pupitre's PARAM_UPDATE makes to the preset. Ports of
/// convertPresetToParamUpdates and convertParamUpdateToPreset (SirenConsole/webfiles/server.js),
/// checked against them by differential tests (Shared.Tests/fixtures).
module Mecaviv.Shared.PresetSync

open Mecaviv.Shared.Values
open Mecaviv.Shared.Config
open Mecaviv.Shared.Console

/// JavaScript truthiness, as in `value ? true : false`.
let truthy (v: JsonValue) =
    match v with
    | JNull -> false
    | JBool b -> b
    | JNumber n -> n <> 0.0 && not (System.Double.IsNaN n)
    | JString s -> s <> ""
    | JArray _
    | JObject _ -> true

/// JavaScript `parseInt(x, 10)`: the leading integer of a string or number, if any.
let parseInt (v: JsonValue) : int option =
    let ofString (s: string) =
        let s = s.TrimStart()
        let sign, digits =
            if s.StartsWith "-" then -1, s.Substring 1
            elif s.StartsWith "+" then 1, s.Substring 1
            else 1, s
        let lead = digits |> Seq.takeWhile System.Char.IsDigit |> Seq.toArray |> System.String
        if lead = "" then None else Some(sign * int lead)
    match v with
    | JNumber n when not (System.Double.IsNaN n) -> Some(int (truncate n))
    | JNumber _ -> None
    | JString s -> ofString s
    | _ -> None

let private pathKeyValue =
    function
    | Key k -> JString k
    | Index i -> JNumber(float i)

let private bit b = JNumber(if b then 1.0 else 0.0)

let private update path value =
    ParamUpdate(path, value, Some "console")

/// The PARAM_UPDATE messages that apply `preset` to pupitre `pupitreId`, in the JS order.
let toParamUpdates (preset: Preset) (pupitreId: string) : PupitreMessage list =
    match preset.Pupitres |> List.tryFind (fun p -> p.Id = pupitreId) with
    | None -> []
    | Some p ->
        [ match p.AssignedSirenes with
          | Some ids -> update [ Key "sirenConfig"; Key "currentSirens" ] (ids |> List.map (float >> JNumber) |> JArray)
          | None -> ()
          for key, s in defaultArg p.Sirenes [] do
              let number = key.Replace("sirene", "") |> JString |> parseInt
              match number with
              | None -> ()
              | Some n ->
                  let siren = [ Key "sirenConfig"; Key "sirens"; Index(n - 1) ]
                  match s.AmbitusRestricted with
                  | Some r -> update (siren @ [ Key "ambitus"; Key "restricted" ]) (bit r)
                  | None -> ()
                  match s.FrettedMode with
                  | Some f -> update (siren @ [ Key "frettedMode"; Key "enabled" ]) (bit f)
                  | None -> ()
          for name, value in [ "vstEnabled", p.VstEnabled; "udpEnabled", p.UdpEnabled; "rtpMidiEnabled", p.RtpMidiEnabled ] do
              match value with
              | Some v -> update [ Key "outputConfig"; Key name ] (bit v)
              | None -> ()
          for control, m in defaultArg p.ControllerMapping [] do
              match m.Cc with
              | Some cc -> update [ Key "controllerMapping"; Key control; Key "cc" ] (JNumber(float cc))
              | None -> ()
              match m.Curve with
              | Some curve when curve <> "" -> update [ Key "controllerMapping"; Key control; Key "curve" ] (JString curve)
              | _ -> ()
          match p.GameMode with
          | Some g -> update [ Key "gameMode"; Key "enabled" ] (bit g)
          | None -> () ]

/// Replace (or add at the end) the entry named `key` of an ordered list.
let private upsert key (make: 'a option -> 'a) (items: (string * 'a) list) =
    match items |> List.tryFindIndex (fun (k, _) -> k = key) with
    | Some i -> items |> List.mapi (fun j (k, v) -> if j = i then k, make (Some v) else k, v)
    | None -> items @ [ key, make None ]

/// The preset after pupitre `pupitreId` changed `path` to `value`. As in the JS, the pupitre's
/// entry is added if missing, even when the path is one the preset does not record.
let applyParamUpdate (path: ParamPath) (value: JsonValue) (pupitreId: string) (preset: Preset) : Preset =
    if List.isEmpty path then
        preset
    else
        let current =
            preset.Pupitres
            |> List.tryFind (fun p -> p.Id = pupitreId)
            |> Option.defaultWith (fun () -> PresetPupitre.empty pupitreId)
        let siren index (set: SireneSettings -> SireneSettings) (p: PresetPupitre) =
            match parseInt (pathKeyValue index) with
            | None -> p
            | Some i ->
                let blank = { AmbitusRestricted = None; FrettedMode = None; Extra = [] }
                { p with Sirenes = Some(defaultArg p.Sirenes [] |> upsert $"sirene{i + 1}" (fun s -> set (defaultArg s blank))) }
        let controller control (set: ControllerSetting -> ControllerSetting) (p: PresetPupitre) =
            let blank = { Cc = None; Curve = None; Extra = [] }
            { p with ControllerMapping = Some(defaultArg p.ControllerMapping [] |> upsert control (fun c -> set (defaultArg c blank))) }
        let numbers (v: JsonValue) =
            match v with
            | JArray items -> items |> List.choose parseInt
            | _ -> []
        let changed =
            match path with
            | [ Key "sirenConfig"; Key "assignedSirenes" ]
            | [ Key "sirenConfig"; Key "currentSirens" ] -> { current with AssignedSirenes = Some(numbers value) }
            | [ Key "sirenConfig"; Key "sirens"; index; Key "ambitus"; Key "restricted" ] ->
                current |> siren index (fun s -> { s with AmbitusRestricted = Some(truthy value) })
            | [ Key "sirenConfig"; Key "sirens"; index; Key "frettedMode"; Key "enabled" ] ->
                current |> siren index (fun s -> { s with FrettedMode = Some(truthy value) })
            | [ Key "outputConfig"; Key "vstEnabled" ] -> { current with VstEnabled = Some(truthy value) }
            | [ Key "outputConfig"; Key "udpEnabled" ] -> { current with UdpEnabled = Some(truthy value) }
            | [ Key "outputConfig"; Key "rtpMidiEnabled" ] -> { current with RtpMidiEnabled = Some(truthy value) }
            | [ Key "gameMode"; Key "enabled" ] -> { current with GameMode = Some(truthy value) }
            | [ Key "controllerMapping"; Key control; Key "cc" ] -> current |> controller control (fun c -> { c with Cc = parseInt value })
            | [ Key "controllerMapping"; Key control; Key "curve" ] ->
                let text =
                    match value with
                    | JString s -> s
                    | JNumber n -> string n
                    | JBool b -> if b then "true" else "false"
                    | other -> string other
                current |> controller control (fun c -> { c with Curve = Some text })
            | _ -> current
        let pupitres =
            if preset.Pupitres |> List.exists (fun p -> p.Id = pupitreId) then
                preset.Pupitres |> List.map (fun p -> if p.Id = pupitreId then changed else p)
            else
                preset.Pupitres @ [ changed ]
        { preset with Pupitres = pupitres }
