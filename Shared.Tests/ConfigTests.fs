module Mecaviv.Shared.Tests.ConfigTests

open System.IO
open Expecto
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Shared.Config

/// A file of this repository, read as it is committed.
let private repoFile (relative: string) =
    File.ReadAllText(Path.Combine(__SOURCE_DIRECTORY__, "..", relative))

let private decodeOrFail decoder text =
    match Decode.fromString decoder text with
    | Ok v -> v
    | Error e -> failtest e

let presets =
    testList "Presets" [
        test "presets.json reads in one format, as normalizePreset does" {
            let file = decodeOrFail PresetsFile.decoder (repoFile "SirenConsole/webfiles/presets.json")
            let summary = file.Presets |> List.map (fun p -> p.Id, p.Pupitres |> List.map (fun x -> x.Id))
            // preset_001: config.pupitres wins over the stale root pupitres; preset_002 has
            // only the root ones, which move into config.
            Expect.equal
                summary
                [ "preset_001", [ "P3"; "P5"; "P7"; "P1"; "P2"; "P4"; "P6" ]
                  "preset_002", [ "P1" ] ]
                ""
        }
        test "a preset written back reads the same" {
            let file = decodeOrFail PresetsFile.decoder (repoFile "SirenConsole/webfiles/presets.json")
            let again = decodeOrFail PresetsFile.decoder (Encode.toString 2 (PresetsFile.encode file))
            Expect.equal again file ""
        }
        test "written back, pupitres are in config only" {
            let file = decodeOrFail PresetsFile.decoder (repoFile "SirenConsole/webfiles/presets.json")
            let text = Encode.toString 0 (PresetsFile.encode file)
            Expect.isFalse (text.Contains "\"version\":\"1.0\",\"pupitres\"") "no root pupitres"
            Expect.stringContains text "\"config\":{\"pupitres\":[" "config.pupitres"
        }
    ]

let sirens =
    testList "Sirens" [
        test "config.template.json: seven sirens, numeric ids even when written as strings" {
            let sirens = decodeOrFail Siren.ofPupitreConfig (repoFile "config.template.json")
            Expect.equal (sirens |> List.map (fun s -> s.Id)) [ 1..7 ] ""
            let s1 = sirens.Head
            Expect.equal (s1.Name, s1.AmbitusMin, s1.AmbitusMax, s1.Fretted) ("S1", 43, 86, true) ""
        }
        test "a pupitre of the console" {
            let p =
                decodeOrFail
                    ConsolePupitre.decoder
                    """{"id":"P1","name":"Pupitre 1","host":"192.168.1.41","port":8000,"websocketPort":10002,"enabled":true,"status":"disconnected"}"""
            Expect.equal p { Id = "P1"; Name = "Pupitre 1"; Host = "192.168.1.41"; Port = 8000; WebsocketPort = 10002; Enabled = true } ""
        }
    ]

let tests = testList "Config" [ presets; sirens ]
