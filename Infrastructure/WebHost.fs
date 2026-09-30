module Mecaviv.Infrastructure.Web

open System
open System.Diagnostics
open System.IO
open System.Threading
open System.Threading.Tasks
open Microsoft.AspNetCore.Builder
open Microsoft.AspNetCore.Hosting
open Microsoft.AspNetCore.Http
open Microsoft.Extensions.FileProviders
open Microsoft.Extensions.Logging
open Serilog
open Mecaviv.Infrastructure.Logging

type HostSpec = {
  LogLevel: string
  Ports: int list
  MaxRequestBodyBytes: int64
}

/// One line when the request finishes within a second. Longer requests log
/// that they are still running, then the completion line.
let requestLog (ctx: HttpContext) (next: RequestDelegate) =
  task {
    let sw = Stopwatch.StartNew()
    let method = ctx.Request.Method
    let path = $"{ctx.Request.Path}{ctx.Request.QueryString}"
    use pending = new CancellationTokenSource()

    let _slow =
      task {
        try
          do! Task.Delay(1000, pending.Token)
          info $"{method} {path} still running"
        with :? OperationCanceledException ->
          ()
      }

    try
      do! next.Invoke ctx
    finally
      pending.Cancel()
      let ms = sw.ElapsedMilliseconds
      info $"{method} {path} {ctx.Response.StatusCode} {ms}ms"
  }
  :> Task

let cors (ctx: HttpContext) (next: RequestDelegate) =
  ctx.Response.Headers.Append("Access-Control-Allow-Origin", "*")
  ctx.Response.Headers.Append("Access-Control-Allow-Headers", "*")
  ctx.Response.Headers.Append("Access-Control-Allow-Methods", "GET, POST, OPTIONS")

  if ctx.Request.Method = "OPTIONS" then
    ctx.Response.StatusCode <- 204
    Task.CompletedTask
  else
    next.Invoke ctx

/// Qt WebAssembly pages need these or the browser refuses the module.
let wasmHeaders (ctx: HttpContext) (next: RequestDelegate) =
  ctx.Response.Headers.Append("Cross-Origin-Opener-Policy", "same-origin")
  ctx.Response.Headers.Append("Cross-Origin-Embedder-Policy", "require-corp")
  ctx.Response.Headers.Append("Cross-Origin-Resource-Policy", "cross-origin")
  ctx.Response.Headers.Append("X-Content-Type-Options", "nosniff")
  next.Invoke ctx

let unfinishedApis (ctx: HttpContext) (next: RequestDelegate) =
  let path = ctx.Request.Path.Value
  let path = if isNull path then "" else path

  let blocked =
    path.StartsWith("/api", StringComparison.OrdinalIgnoreCase)
    || path.Equals("/log", StringComparison.OrdinalIgnoreCase)
    || path.StartsWith("/logs", StringComparison.OrdinalIgnoreCase)

  if blocked then
    ctx.Response.StatusCode <- 501
    ctx.Response.ContentType <- "application/json; charset=utf-8"
    ctx.Response.WriteAsync """{"status":"port-in-progress","detail":"this route is still implemented by server.js"}"""
  else
    next.Invoke ctx

let private hideBuildDirs (ctx: HttpContext) (next: RequestDelegate) =
  let path = ctx.Request.Path.Value
  let path = if isNull path then "" else path

  if path.StartsWith("/bin", StringComparison.OrdinalIgnoreCase)
     || path.StartsWith("/obj", StringComparison.OrdinalIgnoreCase) then
    ctx.Response.StatusCode <- 404
    Task.CompletedTask
  else
    next.Invoke ctx

/// `dotnet run --project <dir>` keeps the shell's working directory.
/// The page files sit next to server.js, which is the project directory
/// (three levels above bin/Debug/net10.0).
let contentRoot marker =
  let here = Directory.GetCurrentDirectory()
  let output = AppContext.BaseDirectory
  let project = Path.GetFullPath(Path.Combine(output, "..", "..", ".."))

  [ here; project; output ]
  |> List.tryFind (fun dir -> File.Exists(Path.Combine(dir, marker)))
  |> Option.defaultWith (fun () ->
    failwith $"No {marker} next to the working directory ({here}) or the project directory ({project}).")

let envPort name fallback =
  match Environment.GetEnvironmentVariable name with
  | null | "" -> fallback
  | text ->
    match Int32.TryParse text with
    | true, port -> port
    | _ -> fallback

let useStaticSite (root: string) (defaultFiles: string list) (wasm: bool) (app: WebApplication) =
  if wasm then
    app.Use wasmHeaders |> ignore

  app.Use requestLog |> ignore
  app.Use cors |> ignore
  app.Use hideBuildDirs |> ignore
  app.Use unfinishedApis |> ignore

  let provider = new PhysicalFileProvider(root)
  let defaults = DefaultFilesOptions(FileProvider = provider)
  defaults.DefaultFileNames.Clear()

  for name in defaultFiles do
    defaults.DefaultFileNames.Add name

  app.UseDefaultFiles defaults |> ignore

  let files = StaticFileOptions(FileProvider = provider)

  files.OnPrepareResponse <- fun ctx ->
    let name = ctx.File.Name

    if name.EndsWith ".wasm" || name.EndsWith ".js" then
      ctx.Context.Response.Headers.Append("Cache-Control", "no-cache") |> ignore

  app.UseStaticFiles files |> ignore

let run (spec: HostSpec) (announce: unit -> unit) (setup: WebApplicationBuilder -> unit) (configure: WebApplication -> unit) =
  start spec.LogLevel
  announce ()

  let builder = WebApplication.CreateBuilder()
  builder.Logging.ClearProviders() |> ignore
  builder.Logging.AddSerilog(Log.Logger, dispose = true) |> ignore

  builder.WebHost.ConfigureKestrel(fun options ->
    for port in spec.Ports do
      options.ListenAnyIP port

    options.Limits.MaxRequestBodySize <- spec.MaxRequestBodyBytes)
  |> ignore

  setup builder
  let app = builder.Build()
  configure app
  app.Run()
  0
