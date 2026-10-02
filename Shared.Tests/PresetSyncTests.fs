/// Differential tests: the F# preset logic against the JS it replaces. The expected results in
/// fixtures/ are produced by the JS code itself (fixtures/generate.js).
module Mecaviv.Shared.Tests.PresetSyncTests

open Expecto
open Thoth.Json.Core
open Mecaviv.Shared.Values
open Mecaviv.Shared.Config
open Mecaviv.Shared.Console
open Mecaviv.Shared.PresetSync
open Mecaviv.Shared.Tests.TestJson

let private presets () =
  (decodeOrFail PresetsFile.decoder (fixture "presets.normalized.json")).Presets

let tests =
  testList
    "Preset sync, against the JS"
    [
      test "presets.json on main, normalized: same JSON as api-presets.js normalizePreset" {
        let fromMain = decodeOrFail PresetsFile.decoder (fixture "presets.main.json")
        Expect.equal (ofEncodable (PresetsFile.encode fromMain)) (parse (fixture "presets.normalized.json")) ""
      }

      test "convertPresetToParamUpdates: same messages, same order, for every preset and pupitre" {
        let cases =
          decodeOrFail (Decode.list (JsonValue.decoder ())) (fixture "param-updates.json")

        let all = presets ()

        for case in cases do
          match case with
          | JObject fields ->
            let get k =
              fields |> List.find (fun (n, _) -> n = k) |> snd

            let presetId, pupitreId =
              (match get "preset", get "pupitreId" with
               | JString a, JString b -> a, b
               | _ -> failwith "case")

            let preset = all |> List.find (fun p -> p.Id = presetId)

            let actual =
              toParamUpdates preset pupitreId |> List.map PupitreMessage.encode |> Encode.list

            Expect.equal (ofEncodable actual) (canonical (get "updates")) $"{presetId} / {pupitreId}"
          | _ -> failtest "case"
      }

      test "convertParamUpdateToPreset: same preset after each change from a pupitre" {
        let data = parse (fixture "param-to-preset.json")

        let field k (v: JsonValue) =
          match v with
          | JObject f -> f |> List.find (fun (n, _) -> n = k) |> snd
          | _ -> failwith k

        let asPreset (v: JsonValue) =
          decodeOrFail Preset.decoder (Thoth.Json.Newtonsoft.Encode.toString 0 (JsonValue.encode v))

        let steps =
          match field "steps" data with
          | JArray s -> s
          | _ -> failwith "steps"

        let mutable state = asPreset (field "start" data)

        for step in steps do
          let path =
            decodeOrFail
              ParamPath.decoder
              (Thoth.Json.Newtonsoft.Encode.toString 0 (JsonValue.encode (field "path" step)))

          let pupitreId =
            match field "pupitreId" step with
            | JString s -> s
            | _ -> failwith "id"

          state <- applyParamUpdate path (field "value" step) pupitreId state
          Expect.equal (ofEncodable (Preset.encode state)) (field "preset" step) $"after {path} on {pupitreId}"
      }

      test "JS truthiness and parseInt" {
        Expect.equal
          (List.map
            truthy
            [
              JNull
              JBool false
              JNumber 0.0
              JString ""
              JNumber 2.0
              JString "0"
              JArray []
            ])
          [ false; false; false; false; true; true; true ]
          ""

        Expect.equal
          (List.map parseInt [ JString "7"; JString " 12abc"; JString "x"; JNumber 3.9; JString "-4" ])
          [ Some 7; Some 12; None; Some 3; Some -4 ]
          ""
      }
    ]
