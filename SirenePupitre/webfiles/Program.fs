module SirenePupitre.Web.Program

open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// Static host for the SirenePupitre WebAssembly build, port 8000.
/// /api/midi/* stays in server.js.

[<EntryPoint>]
let main _ =
  let root = contentRoot "server.js"

  run
    { LogLevel = "Debug"
      Ports = [ 8000 ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"SirenePupitre listening on http://0.0.0.0:8000/ ({root})"
      info "MIDI routes are still served by server.js")
    (fun _ -> ())
    (useStaticSite root [ "appSirenePupitre.html" ] true)
