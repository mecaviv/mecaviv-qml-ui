module SirenManager.Backend.Program

open System
open System.Threading.Tasks
open Giraffe
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.Http
open Microsoft.Extensions.Logging
open Serilog
open SirenManager.Backend
open SirenManager.Backend.Logging

let cfg = Config.load ()
let hub = UdpRelay.Hub cfg.UdpPort

let cors (ctx: HttpContext) (next: RequestDelegate) =
  ctx.Response.Headers.Append("Access-Control-Allow-Origin", "*")
  ctx.Response.Headers.Append("Access-Control-Allow-Headers", "*")
  ctx.Response.Headers.Append("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

  if ctx.Request.Method = "OPTIONS" then
    ctx.Response.StatusCode <- 204
    Task.CompletedTask
  else
    next.Invoke ctx

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
    .Use(cors)
    .Use(socketGate)
    .UseGiraffe(Api.webApp cfg)

[<EntryPoint>]
let main _ =
  start cfg.LogLevel
  info $"HTTP server listening on port {cfg.HttpPort}"
  info $"WebSocket server listening on port {cfg.WsPort}"
  info $"UDP socket will bind to port {cfg.UdpPort} on first WebSocket connection"

  let builder = WebApplication.CreateBuilder()
  builder.Logging.ClearProviders() |> ignore
  builder.Logging.AddSerilog(Log.Logger, dispose = true) |> ignore
  builder.Services.AddGiraffe() |> ignore

  builder.WebHost.ConfigureKestrel(fun options ->
    options.ListenAnyIP cfg.HttpPort
    options.ListenAnyIP cfg.WsPort
    options.Limits.MaxRequestBodySize <- 50L * 1024L * 1024L)
  |> ignore

  let app = builder.Build()
  configureApp app
  app.Run()
  0
