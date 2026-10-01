/// Values that travel as free JSON: a parameter's value, and the path to it in a
/// configuration (`["sirenConfig","sirens",2,"frettedMode","enabled"]`).
module Mecaviv.Shared.Values

open Thoth.Json.Core

/// Any JSON value, kept as is (PARAM_UPDATE's value, a configuration not typed yet).
type JsonValue =
    | JNull
    | JBool of bool
    | JNumber of float
    | JString of string
    | JArray of JsonValue list
    | JObject of (string * JsonValue) list

/// One step of a path in a configuration: a key, or an index in an array.
type PathKey =
    | Key of string
    | Index of int

type ParamPath = PathKey list

module JsonValue =
    let rec decoder () : Decoder<JsonValue> =
        // The recursion goes through andThen, so the decoder is built when it is used.
        let inner = Decode.succeed () |> Decode.andThen decoder
        Decode.oneOf [
            Decode.nil JNull
            Decode.map JBool Decode.bool
            Decode.map JNumber Decode.float
            Decode.map JString Decode.string
            Decode.map JArray (Decode.list inner)
            Decode.map JObject (Decode.keyValuePairs inner)
        ]

    let rec encode (v: JsonValue) : IEncodable =
        match v with
        | JNull -> Encode.nil
        | JBool b -> Encode.bool b
        // Integers are written as integers (1, not 1.0), as JavaScript does.
        | JNumber n when n = floor n && abs n <= 2147483647.0 -> Encode.int (int n)
        | JNumber n -> Encode.float n
        | JString s -> Encode.string s
        | JArray items -> items |> List.map encode |> Encode.list
        | JObject fields -> fields |> List.map (fun (k, x) -> k, encode x) |> Encode.object

module ParamPath =
    let private key =
        Decode.oneOf [
            Decode.map Index Decode.int
            Decode.map Key Decode.string
        ]

    let decoder: Decoder<ParamPath> = Decode.list key

    let encode (path: ParamPath) : IEncodable =
        path
        |> List.map (function
            | Key k -> Encode.string k
            | Index i -> Encode.int i)
        |> Encode.list
