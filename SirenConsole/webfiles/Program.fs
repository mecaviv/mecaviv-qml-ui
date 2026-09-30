module SirenConsole.Web.Program

open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// Static host for the SirenConsole WebAssembly build, port 8001.
/// Preset, MIDI, and PureData routes stay in server.js. WebSocket /ws is not accepted yet.

[<EntryPoint>]
let main _ =
  let root = contentRoot "server.js"

  run
    { LogLevel = "Debug"
      Ports = [ 8001 ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"SirenConsole listening on http://0.0.0.0:8001/ ({root})"
      info "Preset, MIDI, and PureData routes are still served by server.js")
    (fun _ -> ())
    (useStaticSite root [ "appSirenConsole.html" ] true)
