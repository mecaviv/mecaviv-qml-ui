/// The console's own configuration: SirenConsole/config.js, the file server.js requires and
/// scripts/update-all-pupitres.sh reads. It is a JavaScript object, not JSON: Newtonsoft's
/// reader accepts its unquoted keys and comments, so the file stays the single source and
/// GET /api/config serves it as strict JSON.
module SirenConsole.Web.ConsoleConfig

open System.IO
open Giraffe
open Newtonsoft.Json
open Newtonsoft.Json.Linq
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Shared.Config

/// The object after `const config =` in config.js, as strict JSON text.
let objectOf (source: string) : Result<string, string> =
  let marker = source.IndexOf "const config"
  let start = if marker < 0 then -1 else source.IndexOf('{', marker)

  if start < 0 then
    Error "no `const config = {` in config.js"
  else
    try
      use reader = new JsonTextReader(new StringReader(source.Substring start))
      Ok((JToken.ReadFrom reader).ToString(Formatting.None))
    with ex ->
      Error $"config.js: {ex.Message}"

let pupitresDecoder: Decoder<ConsolePupitre list> =
  Decode.oneOf
    [
      Decode.field "pupitres" (Decode.list ConsolePupitre.decoder)
      Decode.succeed []
    ]

/// The pupitres of config.js.
let load (path: string) : Result<ConsolePupitre list, string> =
  if not (File.Exists path) then
    Error $"{path} not found"
  else
    objectOf (File.ReadAllText path)
    |> Result.bind (Decode.fromString pupitresDecoder)

/// GET /api/config → { "pupitres": [...] }
let route (pupitres: ConsolePupitre list) : HttpHandler =
  GET
  >=> route "/api/config"
  >=> setHttpHeader "Content-Type" "application/json; charset=utf-8"
  >=> setBodyFromString (
    Encode.toString 0 (Encode.object [ "pupitres", pupitres |> List.map ConsolePupitre.encode |> Encode.list ])
  )
