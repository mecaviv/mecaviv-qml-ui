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
          let note = yellow "still running"
          info $"{httpMethod method} {path} {note}"
        with :? OperationCanceledException ->
          ()
      }

    try
      do! next.Invoke ctx
    finally
      pending.Cancel()
      let ms = sw.ElapsedMilliseconds
      info $"{httpMethod method} {path} {status ctx.Response.StatusCode} {duration ms}"
  }
  :> Task

let cors (ctx: HttpContext) (next: RequestDelegate) =
  ctx.Response.Headers.Append("Access-Control-Allow-Origin", "*")
  ctx.Response.Headers.Append("Access-Control-Allow-Headers", "*")
  ctx.Response.Headers.Append("Access-Control-Allow-Methods", "GET, POST, PUT, PATCH, DELETE, OPTIONS")

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

/// Run a tool from the monorepo root (two levels above `webfiles`).
let private runInRepoRoot (fileName: string) (args: string) =
  let root = Path.GetFullPath(Path.Combine(Directory.GetCurrentDirectory(), "..", ".."))
  let root =
    if File.Exists(Path.Combine(root, "paket.dependencies")) then root
    else Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."))

  let psi =
    ProcessStartInfo(
      FileName = fileName,
      Arguments = args,
      WorkingDirectory = root,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      UseShellExecute = false)

  use proc = Process.Start psi
  let stdout = proc.StandardOutput.ReadToEnd()
  let stderr = proc.StandardError.ReadToEnd()
  proc.WaitForExit()

  if proc.ExitCode <> 0 then
    failwith $"{fileName} {args} exited {proc.ExitCode}\n{stdout}\n{stderr}"

  stdout

/// Compile a Fable project under `webfiles/<name>` when its `App.js` is
/// missing or older than any `.fs` source (the simulateur page, etc.).
let ensureFable (webfiles: string) (name: string) =
  let dir = Path.Combine(webfiles, name)
  let outFile = Path.Combine(dir, "App.js")
  let sources =
    if Directory.Exists dir then Directory.GetFiles(dir, "*.fs") else [||]

  if sources.Length = 0 then
    false
  else
    let stale =
      not (File.Exists outFile)
      || sources
         |> Array.exists (fun f -> File.GetLastWriteTimeUtc f > File.GetLastWriteTimeUtc outFile)

    if not stale then
      false
    else
      info $"fable: building {name} (App.js missing or older than the F# sources)"
      runInRepoRoot "dotnet" "tool restore" |> ignore
      runInRepoRoot "dotnet" $"fable SirenePupitre/webfiles/{name} -o SirenePupitre/webfiles" |> ignore
      true

/// Like useStaticSite, with the application's own routes (`api`) placed after the log and
/// CORS, and before the 501 of the routes still served by Node: a route ported to F# takes
/// over, the others keep answering "port-in-progress".
let useStaticSiteWithApi (api: WebApplication -> unit) (root: string) (defaultFiles: string list) (wasm: bool) (app: WebApplication) =
  if wasm then
    app.Use wasmHeaders |> ignore

  app.Use requestLog |> ignore
  app.Use cors |> ignore
  app.Use hideBuildDirs |> ignore
  api app
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

let useStaticSite (root: string) (defaultFiles: string list) (wasm: bool) (app: WebApplication) =
  useStaticSiteWithApi ignore root defaultFiles wasm app

/// A certificate and its key, PEM files (as Node's https.createServer reads them).
type Tls = { CertificatePem: string; KeyPem: string }

/// `run`, every port serving HTTPS (and WSS) when a certificate is given.
let runWith (tls: Tls option) (spec: HostSpec) (announce: unit -> unit) (setup: WebApplicationBuilder -> unit) (configure: WebApplication -> unit) =
  start spec.LogLevel
  announce ()

  let builder = WebApplication.CreateBuilder()
  builder.Logging.ClearProviders() |> ignore
  builder.Logging.AddSerilog(Log.Logger, dispose = true) |> ignore

  let certificate =
    tls
    |> Option.map (fun t ->
      let pem =
        System.Security.Cryptography.X509Certificates.X509Certificate2.CreateFromPemFile(t.CertificatePem, t.KeyPem)
      // a PEM key is ephemeral, which macOS's TLS refuses: go through PKCS#12
      System.Security.Cryptography.X509Certificates.X509CertificateLoader.LoadPkcs12(
        pem.Export System.Security.Cryptography.X509Certificates.X509ContentType.Pkcs12, null))

  builder.WebHost.ConfigureKestrel(fun options ->
    for port in spec.Ports do
      match certificate with
      | Some cert -> options.ListenAnyIP(port, fun listen -> listen.UseHttps(cert) |> ignore)
      | None -> options.ListenAnyIP port

    options.Limits.MaxRequestBodySize <- spec.MaxRequestBodyBytes)
  |> ignore

  setup builder
  let app = builder.Build()
  configure app
  app.Run()
  0

let run (spec: HostSpec) (announce: unit -> unit) (setup: WebApplicationBuilder -> unit) (configure: WebApplication -> unit) =
  runWith None spec announce setup configure
