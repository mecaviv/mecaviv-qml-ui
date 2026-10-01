/// Helpers around Thoth.Json.Core, the JSON codecs that compile both for .NET (the servers)
/// and with Fable (the web clients). The backend (Newtonsoft on .NET, the browser's JSON with
/// Fable) is picked at the edges, never here.
module Mecaviv.Shared.Json

open Thoth.Json.Core

/// Decoder for a message whose discriminant field (`type` or `device`) has one exact value.
let tagged (field: string) (value: string) (decoder: Decoder<'a>) : Decoder<'a> =
    Decode.field field Decode.string
    |> Decode.andThen (fun v ->
        if v = value then decoder
        else Decode.fail $"expected {field} = {value}, got {v}")
