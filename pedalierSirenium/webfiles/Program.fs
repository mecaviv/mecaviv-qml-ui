module PedalierSirenium.Web.Program

open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// Static host for the pedalier WebAssembly build.
/// WEB_PORT defaults to 8010, same as server.js.
/// /log, /logs, and /api/* (config, temperature, system-info) stay in server.js.
/// The PureData WebSocket on 10000 is not bound yet.

[<EntryPoint>]
let main _ =
  let port = envPort "WEB_PORT" 8010
  let root = contentRoot "server.js"

  run
    { LogLevel = "Debug"
      Ports = [ port ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"pedalierSirenium listening on http://0.0.0.0:{port}/ ({root})"
      info "Log and system-info routes are still served by server.js. WebSocket 10000 is not bound.")
    (fun _ -> ())
    (useStaticSite root [ "qmlwebsocketserver.html" ] true)
