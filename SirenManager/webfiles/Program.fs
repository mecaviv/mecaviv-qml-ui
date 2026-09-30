module SirenManager.Web.Program

open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// Static host for the SirenManager WebAssembly page.
/// PORT defaults to 8081, same as server.js.
/// WebSocket 8006 stays on the SSH backend (SirenManager/backend/fsharpwebserver).
/// This process must not bind it: the Node static server and the backend cannot share that port.

[<EntryPoint>]
let main _ =
  let port = envPort "PORT" 8081
  let root = contentRoot "server.js"

  run
    { LogLevel = "Debug"
      Ports = [ port ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"SirenManager web listening on http://0.0.0.0:{port}/ ({root})"
      info "WebSocket 8006 stays on SirenManager/backend/fsharpwebserver")
    (fun _ -> ())
    (useStaticSite root [ "index.html"; "appSirenManager.html" ] false)
