module SirenConsole.Web.Program

open System
open System.IO
open Giraffe
open Microsoft.Extensions.DependencyInjection
open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// SirenConsole's server, port 8001: the WebAssembly build, and what is ported from
/// server.js so far: the presets, /api/config and the UI's WebSocket /ws. The other routes
/// still answer "port-in-progress" (server.js).
/// SIRENCONSOLE_PORT and SIRENCONSOLE_PRESETS override the port and presets.json (tests).

[<EntryPoint>]
let main _ =
  let root = contentRoot "server.js"
  let port = envPort "SIRENCONSOLE_PORT" 8001

  let presetsFile =
    match Environment.GetEnvironmentVariable "SIRENCONSOLE_PRESETS" with
    | null | "" -> Path.Combine(root, "presets.json")
    | path -> path

  let configFile = Path.GetFullPath(Path.Combine(root, "..", "config.js"))

  let pupitres =
    match ConsoleConfig.load configFile with
    | Ok list -> list
    | Error e ->
      error $"config: {e}; no pupitre configured"
      []

  let presets = Presets.Store presetsFile
  let sync = UiSocket.SyncState()
  let hub = UiSocket.Hub()
  let status = UiSocket.configuredOnly pupitres

  // PARAM_UPDATE for synced pupitres: sent once the pupitre links are ported.
  let link =
    { new Presets.PupitreLink with
        member _.IsSynced id = sync.IsSynced id
        member _.Send _ _ = () }

  run
    { LogLevel = "Debug"
      Ports = [ port ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"SirenConsole listening on http://0.0.0.0:{port}/ ({root})"
      info $"presets: {presetsFile}"
      info $"config: {configFile}, {pupitres.Length} pupitre(s)"
      info "PureData, MIDI and pupitre routes are still served by server.js")
    (fun builder -> builder.Services.AddGiraffe() |> ignore)
    (useStaticSiteWithApi
      (fun app ->
        UiSocket.install hub sync status app
        app.UseGiraffe(choose [ ConsoleConfig.route pupitres; Presets.routes presets link ]))
      root
      [ "appSirenConsole.html" ]
      true)
