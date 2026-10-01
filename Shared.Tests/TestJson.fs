/// Comparing JSON as the receiving code sees it: object field order and 120 vs 120.0 don't
/// matter, array order does.
module Mecaviv.Shared.Tests.TestJson

open System.IO
open Expecto
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Shared.Values

let rec canonical (v: JsonValue) =
    match v with
    | JObject fields -> fields |> List.map (fun (k, x) -> k, canonical x) |> List.sortBy fst |> JObject
    | JArray items -> items |> List.map canonical |> JArray
    | other -> other

let parse (text: string) =
    match Decode.fromString (JsonValue.decoder ()) text with
    | Ok v -> canonical v
    | Error e -> failwith e

let ofEncodable (e: IEncodable) = parse (Encode.toString 0 e)

let decodeOrFail decoder (text: string) =
    match Decode.fromString decoder text with
    | Ok v -> v
    | Error e -> failtest e

let fixture name = File.ReadAllText(Path.Combine(__SOURCE_DIRECTORY__, "fixtures", name))

let repoFile (relative: string) = File.ReadAllText(Path.Combine(__SOURCE_DIRECTORY__, "..", relative))
