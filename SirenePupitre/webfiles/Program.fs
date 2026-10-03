module SirenePupitre.Web.Program

open System
open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// Static host for the SirenePupitre WebAssembly build, port 8000.
/// /api/midi/* stays in server.js.
/// `--simulation` (or SIRENEPUPITRE_SIMULATION=1): also the simulator, simulateur.html and its
/// WebSocket /simulation relayed to gyrophone.pd's FUDI port (SIRENEPUPITRE_PD_FUDI, 9100), and
/// the list of the compositions' MIDI files (SIRENEPUPITRE_COMPOSITIONS).

[<EntryPoint>]
let main argv =
  let root = contentRoot "server.js"

  // simulateur.html loads simulateur-fable/App.js (Fable); build it when missing.
  ensureFable root "simulateur-fable" |> ignore

  let simulation =
    Array.contains "--simulation" argv
    || Environment.GetEnvironmentVariable "SIRENEPUPITRE_SIMULATION" = "1"

  let pdPort = envPort "SIRENEPUPITRE_PD_FUDI" 9100

  // the compositions repository, next to mecaviv-qml-ui (as gyrophone finds it next to
  // puredata-abstractions), unless SIRENEPUPITRE_COMPOSITIONS says otherwise
  let compositions =
    match Environment.GetEnvironmentVariable "SIRENEPUPITRE_COMPOSITIONS" with
    | null
    | "" -> IO.Path.GetFullPath(IO.Path.Combine(root, "..", "..", "..", "compositions"))
    | dir -> dir

  run
    { LogLevel = "Debug"
      Ports = [ 8000 ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"SirenePupitre listening on http://0.0.0.0:8000/ ({root})"
      info "MIDI routes are still served by server.js"

      if simulation then
        info $"simulation: http://localhost:8000/simulateur.html, relayed to Pd on 127.0.0.1:{pdPort}, compositions in {compositions}")
    (fun _ -> ())
    (if simulation then
       useStaticSiteWithApi (Simulation.install "127.0.0.1" pdPort compositions) root [ "appSirenePupitre.html" ] true
     else
       useStaticSite root [ "appSirenePupitre.html" ] true)
