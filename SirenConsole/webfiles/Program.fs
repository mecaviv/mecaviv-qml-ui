module SirenConsole.Web.Program

open System
open System.IO
open Giraffe
open Microsoft.Extensions.DependencyInjection
open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// SirenConsole's server, port 8001: the WebAssembly build, and what is ported from
/// server.js so far: the presets, /api/config, the UI's WebSocket /ws and the links to the
/// pupitres. The other routes still answer "port-in-progress" (server.js).
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
  let nowMs () = float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())

  // What the pupitres send (handlePupitreConfigFromPupitre, handleParamChangedFromPupitre).
  let handlers: PupitreLinks.Handlers =
    { Config =
        fun id data ->
          task {
            if not (sync.IsSynced id) then
              do! hub.Send(sync.Set(id, true))
            let! changed = Presets.updateFromPupitre presets id (Presets.mergePupitreConfig data)
            if changed then
              do! hub.Send(Mecaviv.Shared.Console.PresetUpdatedFromPupitre(id, None, nowMs ()))
          }
      ParamChanged =
        fun id path value ->
          task {
            if sync.IsSynced id then
              let apply (entry: Mecaviv.Shared.Config.PresetPupitre) =
                let preset: Mecaviv.Shared.Config.Preset =
                  { Id = ""; Name = None; Description = None; Created = None; Modified = None; Version = None
                    Pupitres = [ entry ]; OtherConfig = []; Extra = [] }
                (Mecaviv.Shared.PresetSync.applyParamUpdate path value id preset).Pupitres.Head
              let! changed = Presets.updateFromPupitre presets id apply
              if changed then
                do! hub.Send(Mecaviv.Shared.Console.PresetUpdatedFromPupitre(id, Some(path, value), nowMs ()))
          }
      Ui = fun event -> hub.Send event }

  let links = PupitreLinks.Links(pupitres, handlers)
  let status = links :> UiSocket.PupitreStatusSource

  // PARAM_UPDATE for synced pupitres, through their links.
  let link =
    { new Presets.PupitreLink with
        member _.IsSynced id = sync.IsSynced id
        member _.Send id message = links.Send(id, message) |> ignore }

  run
    { LogLevel = "Debug"
      Ports = [ port ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"SirenConsole listening on http://0.0.0.0:{port}/ ({root})"
      info $"presets: {presetsFile}"
      info $"config: {configFile}, {pupitres.Length} pupitre(s)"
      info "MIDI routes are still served by server.js"
      links.Start())
    (fun builder -> builder.Services.AddGiraffe() |> ignore)
    (useStaticSiteWithApi
      (fun app ->
        UiSocket.install hub sync status app
        app.UseGiraffe(choose [ ConsoleConfig.route pupitres; Presets.routes presets link ]))
      root
      [ "appSirenConsole.html" ]
      true)
