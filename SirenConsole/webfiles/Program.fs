module SirenConsole.Web.Program

open System
open System.IO
open Giraffe
open Microsoft.Extensions.DependencyInjection
open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// SirenConsole's server, port 8001: the WebAssembly build, and the routes ported from
/// server.js (presets so far). The other routes still answer "port-in-progress" (server.js).
/// SIRENCONSOLE_PORT and SIRENCONSOLE_PRESETS override the port and presets.json (tests).

[<EntryPoint>]
let main _ =
  let root = contentRoot "server.js"
  let port = envPort "SIRENCONSOLE_PORT" 8001

  let presetsFile =
    match Environment.GetEnvironmentVariable "SIRENCONSOLE_PRESETS" with
    | null | "" -> Path.Combine(root, "presets.json")
    | path -> path

  let presets = Presets.Store presetsFile

  run
    { LogLevel = "Debug"
      Ports = [ port ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"SirenConsole listening on http://0.0.0.0:{port}/ ({root})"
      info $"presets: {presetsFile}"
      info "PureData, MIDI and WebSocket routes are still served by server.js")
    (fun builder -> builder.Services.AddGiraffe() |> ignore)
    (useStaticSiteWithApi
      (fun app -> app.UseGiraffe(Presets.routes presets Presets.noLink))
      root
      [ "appSirenConsole.html" ]
      true)
