module SirenRouter.Program

open System.Threading.Tasks
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Http
open Mecaviv.Infrastructure.Logging
open Mecaviv.Infrastructure.Web

/// Reserves the REST port described in README.md.
/// src/server.js is not in the tree. The Node module to port is src/api/control.js.
/// WebSocket 8003 and UDP 8004 are not bound yet.

let home (ctx: HttpContext) (next: RequestDelegate) =
  if ctx.Request.Path.Value = "/" then
    ctx.Response.ContentType <- "application/json; charset=utf-8"

    ctx.Response.WriteAsync
      """{"app":"sirenRouter","status":"port-in-progress","http":8002,"websocket":8003,"udp":8004}"""
  else
    next.Invoke ctx

let configure (app: WebApplication) =
  app.Use(requestLog).Use(cors).Use(unfinishedApis).Use(home) |> ignore

[<EntryPoint>]
let main _ =
  run
    { LogLevel = "Debug"
      Ports = [ 8002 ]
      MaxRequestBodyBytes = 1_048_576L }
    (fun () ->
      info "sirenRouter listening on http://0.0.0.0:8002/"
      info "WebSocket 8003 and UDP 8004 are not bound. src/api/control.js is the Node module still to port.")
    (fun _ -> ())
    configure
