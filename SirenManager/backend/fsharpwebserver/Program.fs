module SirenManager.Backend.Program

open System.Threading.Tasks
open Giraffe
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Http
open SirenManager.Backend
open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

let cfg = Config.load ()
MidiCache.load ()
let hub = UdpRelay.Hub cfg.UdpPort

/// One mailbox for every ssh `execute`: serialised per machine, timed, throttled.
let scheduler =
  Scheduler.start Scheduler.defaultPolicy (fun quiet machine command ->
    task {
      try
        let! out = (if quiet then SshProxy.executeQuiet else SshProxy.execute) cfg machine command
        return Ok out
      with
      | SshProxy.SshError msg -> return Error msg
      | ex -> return Error ex.Message
    })

/// HTTP stays on ports.http. WebSocket stays on ports.websocket, which is what
/// UdpController opens (ws://localhost:8006/udp-proxy). The path is not checked.
let socketGate (ctx: HttpContext) (next: RequestDelegate) =
  if ctx.Connection.LocalPort = cfg.WsPort then
    if ctx.WebSockets.IsWebSocketRequest then
      task {
        let! ws = ctx.WebSockets.AcceptWebSocketAsync()
        do! UdpRelay.handle hub ws
      }
      :> Task
    else
      ctx.Response.StatusCode <- 404
      Task.CompletedTask
  else
    next.Invoke ctx

let configureApp (app: WebApplication) =
  app
    .UseWebSockets()
    .Use(requestLog)
    .Use(cors)
    .Use(socketGate)
    .UseGiraffe(Api.webApp cfg scheduler)
  |> ignore

[<EntryPoint>]
let main _ =
  run
    { LogLevel = cfg.LogLevel
      Ports = [ cfg.HttpPort; cfg.WsPort ]
      MaxRequestBodyBytes = 50L * 1024L * 1024L }
    (fun () ->
      info $"HTTP server listening on port {cfg.HttpPort}"
      info $"WebSocket server listening on port {cfg.WsPort}"
      info $"UDP socket will bind to port {cfg.UdpPort} on first WebSocket connection")
    (fun builder -> builder.Services.AddGiraffe() |> ignore)
    configureApp
