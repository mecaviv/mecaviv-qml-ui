module SirenConsole.Web.Program

open System
open System.IO
open Giraffe
open Microsoft.Extensions.DependencyInjection
open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// SirenConsole's server, port 8001: the WebAssembly build, and what is ported from
/// server.js so far: the presets, /api/config, the UI's WebSocket /ws, the links to the
/// pupitres, the pieces and their playback.
/// SIRENCONSOLE_PORT and SIRENCONSOLE_PRESETS override the port and presets.json (tests);
/// SIRENCONSOLE_PREROLL_MS the sound's delay behind the score (M645.pd's [pipelist 5000]).
/// HTTPS and WSS unless USE_HTTPS=false, with ssl/cert.pem and ssl/key.pem (SSL_CERT_PATH,
/// SSL_KEY_PATH), as server.js.

[<EntryPoint>]
let main _ =
  let root = contentRoot "server.js"
  let port = envPort "SIRENCONSOLE_PORT" 8001

  let presetsFile =
    match Environment.GetEnvironmentVariable "SIRENCONSOLE_PRESETS" with
    | null
    | "" -> Path.Combine(root, "presets.json")
    | path -> path

  let configFile = Path.GetFullPath(Path.Combine(root, "..", "config.js"))

  let pupitres =
    match ConsoleConfig.load configFile with
    | Ok list -> list
    | Error e ->
      error $"config: {e}; no pupitre configured"
      []

  let tls =
    if Environment.GetEnvironmentVariable "USE_HTTPS" = "false" then
      None
    else
      let path name fallback =
        match Environment.GetEnvironmentVariable name with
        | null
        | "" -> Path.Combine(root, "ssl", fallback)
        | p -> p

      let cert, key = path "SSL_CERT_PATH" "cert.pem", path "SSL_KEY_PATH" "key.pem"

      if not (File.Exists cert && File.Exists key) then
        eprintfn $"SSL certificates not found: {cert}, {key}. Create them with"

        eprintfn
          "  openssl req -x509 -newkey rsa:4096 -keyout ssl/key.pem -out ssl/cert.pem -days 365 -nodes -subj \"/CN=localhost\""

        eprintfn "or start with USE_HTTPS=false."
        exit 1

      Some { CertificatePem = cert; KeyPem = key }

  let compositions =
    Midi.compositionsDir (Path.GetFullPath(Path.Combine(root, "..", "..")))

  let prerollMs =
    match Double.TryParse(Environment.GetEnvironmentVariable "SIRENCONSOLE_PREROLL_MS") with
    | true, ms -> ms
    | _ -> 5000.0

  let playback = Midi.Playback prerollMs

  // The reference pupitre for the playback position: the first one of config.js that is
  // connected (the links exist after the handlers, hence the reference cell).
  let connected: (string -> bool) ref = ref (fun _ -> false)

  let isReference id =
    pupitres
    |> List.filter (fun p -> p.Enabled)
    |> List.tryFind (fun p -> connected.Value p.Id)
    |> Option.exists (fun p -> p.Id = id)

  let presets = Presets.Store presetsFile
  let sync = UiSocket.SyncState()
  let hub = UiSocket.Hub()

  let nowMs () =
    float (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds())

  // What the pupitres send (handlePupitreConfigFromPupitre, handleParamChangedFromPupitre).
  let handlers: PupitreLinks.Handlers =
    {
      Config =
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
                  {
                    Id = ""
                    Name = None
                    Description = None
                    Created = None
                    Modified = None
                    Version = None
                    Pupitres = [ entry ]
                    OtherConfig = []
                    Extra = []
                  }

                (Mecaviv.Shared.PresetSync.applyParamUpdate path value id preset).Pupitres.Head

              let! changed = Presets.updateFromPupitre presets id apply

              if changed then
                do! hub.Send(Mecaviv.Shared.Console.PresetUpdatedFromPupitre(id, Some(path, value), nowMs ()))
          }
      Ui = fun event -> hub.Send event
      Position =
        fun id playing beat ->
          if isReference id then
            playback.OnPosition(playing, beat)
    }

  let links = PupitreLinks.Links(pupitres, handlers)
  connected.Value <- links.IsConnected
  let status = links :> UiSocket.PupitreStatusSource

  // PARAM_UPDATE for synced pupitres, through their links.
  let link =
    { new Presets.PupitreLink with
        member _.IsSynced id = sync.IsSynced id
        member _.Send id message = links.Send(id, message) |> ignore
    }

  let deps: Api.Deps =
    {
      Presets = presets
      PresetLink = link
      Links = links
      Sync = sync
      Hub = hub
      Pupitres = pupitres
      ConfigJs = configFile
      Compositions = compositions
      Playback = playback
    }

  /// The UI's WebSocket, then every HTTP route, before the static files (WebAssembly build).
  let configureApp (app: Microsoft.AspNetCore.Builder.WebApplication) =
    UiSocket.install hub sync status app
    app.UseGiraffe(Api.webApp deps)

  runWith
    tls
    {
      LogLevel = "Debug"
      Ports = [ port ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L
    }
    (fun () ->
      let scheme = if tls.IsSome then "https" else "http"
      info $"SirenConsole listening on {scheme}://0.0.0.0:{port}/ ({root})"
      info $"presets: {presetsFile}"
      info $"config: {configFile}, {pupitres.Length} pupitre(s)"
      info $"compositions: {compositions}; sound {prerollMs} ms behind the score"
      links.Start())
    (fun builder -> builder.Services.AddGiraffe() |> ignore)
    (useStaticSiteWithApi configureApp root [ "appSirenConsole.html" ] true)
