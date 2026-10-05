module Mecaviv.Infrastructure.Logging

open System
open System.Text
open Serilog
open Serilog.Events
open Serilog.Sinks.SystemConsole.Themes

/// Text shorter than this is written under the command line. Longer text,
/// and anything with a NUL, is reported by size only.
let [<Literal>] private OutputLimit = 800

/// ANSI colors for the text of a message (the theme colors the level and the
/// timestamp). Off when output is redirected or NO_COLOR is set, so logs piped
/// to a file stay plain.
let private colorOn =
  not Console.IsOutputRedirected && isNull (Environment.GetEnvironmentVariable "NO_COLOR")

let private paint (code: string) (text: string) =
  if colorOn then $"\u001b[{code}m{text}\u001b[0m" else text

let dim text = paint "90" text
let red text = paint "31" text
let green text = paint "32" text
let yellow text = paint "33" text
let blue text = paint "34" text
let magenta text = paint "35" text
let cyan text = paint "36" text
let bold text = paint "1" text

/// 2xx green, 3xx cyan, 4xx yellow, 5xx red.
let status (code: int) =
  let t = string code
  if code >= 500 then red t elif code >= 400 then yellow t elif code >= 300 then cyan t else green t

/// Dim when quick, plain, then yellow and red as it drags (the boards are slow:
/// an ssh round trip under a second is normal).
let duration (ms: int64) =
  let t = if ms >= 10000L then $"{float ms / 1000.0:F1}s" else $"{ms}ms"
  if ms >= 3000L then red t elif ms >= 1000L then yellow t elif ms >= 200L then t else dim t

let httpMethod (m: string) =
  match m with
  | "GET" -> green m
  | "POST" -> blue m
  | "PUT" | "PATCH" -> yellow m
  | "DELETE" -> red m
  | _ -> m

let parseLevel (name: string) =
  match (if isNull name then "" else name).Trim().ToLowerInvariant() with
  | "" | "debug" -> LogEventLevel.Debug, false
  | "verbose" | "trace" -> LogEventLevel.Verbose, false
  | "information" | "info" -> LogEventLevel.Information, false
  | "warning" | "warn" -> LogEventLevel.Warning, false
  | "error" -> LogEventLevel.Error, false
  | "fatal" -> LogEventLevel.Fatal, false
  | _ -> LogEventLevel.Debug, true

let start levelName =
  let level, unknown = parseLevel levelName

  // The configured level applies to this process. Hosting internals stay at
  // Information unless the configured level is already stricter.
  let frameworkLevel =
    if level < LogEventLevel.Information then
      LogEventLevel.Information
    else
      level

  Log.Logger <-
    LoggerConfiguration()
      .MinimumLevel.Is(level)
      .MinimumLevel.Override("Microsoft.AspNetCore.Hosting.Diagnostics", LogEventLevel.Warning)
      .MinimumLevel.Override("Microsoft.AspNetCore.StaticFiles", LogEventLevel.Warning)
      .MinimumLevel.Override("Microsoft", frameworkLevel)
      .MinimumLevel.Override("System", frameworkLevel)
      .MinimumLevel.Override("Giraffe", frameworkLevel)
      .WriteTo.Console(
        outputTemplate = "[{Timestamp:HH:mm:ss.fff} {Level:u3}] {Message:lj}{NewLine}{Exception}",
        theme = AnsiConsoleTheme.Code
      )
      .CreateLogger()

  if unknown then
    Log.Warning("{Text:l}", [| box $"logLevel '{levelName}' is not recognised; using Debug" |])

let private write level text =
  Log.Write(level, "{Text:l}", [| box text |])

let debug text = write LogEventLevel.Debug text
let info text = write LogEventLevel.Information text
let warn text = write LogEventLevel.Warning text
let error text = write LogEventLevel.Error text

let errorEx (ex: exn) text =
  Log.Write(LogEventLevel.Error, ex, "{Text:l}", [| box text |])

let private isSmallText (text: string) =
  text.Length > 0
  && text.Length <= OutputLimit
  && text.IndexOf '\000' < 0
  && text
     |> Seq.forall (fun c ->
       not (Char.IsControl c) || c = '\n' || c = '\r' || c = '\t')

let private describe name (text: string) =
  let trimmed = text.Trim()

  if trimmed.Length = 0 then
    None
  elif isSmallText trimmed then
    let body =
      trimmed.Replace("\r\n", "\n").Split '\n'
      |> Array.map (fun line -> $"    {line}")
      |> String.concat "\n"

    Some $"{name}:\n{body}"
  else
    Some $"{name}: {trimmed.Length} characters"

let private elide n (t: string) = if t.Length > n then t.Substring(0, n - 1) + "…" else t

/// One line per command: `$ ssh s1 'cmd' ✓ 412ms`. Output and stderr are
/// dumped below it only when they matter: on failure, or at Verbose level.
/// stdout = None when the process did not capture it (the local tar writes a file).
let traceTimed commandLine exitCode (elapsedMs: int64) (stdout: byte[] option) (stderr: string) =
  let size =
    match stdout with
    | Some b -> dim $" {b.Length}B"
    | None -> ""

  let mark = if exitCode = 0 then green "✓" else red $"✗ {exitCode}"
  let took = if elapsedMs >= 0L then " " + duration elapsedMs else ""

  let stdoutText =
    match stdout with
    | None -> None
    | Some bytes when bytes |> Array.exists (fun b -> b = 0uy) -> Some $"stdout: {bytes.Length} bytes"
    | Some bytes -> describe "stdout" (Encoding.UTF8.GetString bytes)

  let dump = exitCode <> 0 || Log.IsEnabled LogEventLevel.Verbose

  let parts =
    if dump then
      [ stdoutText; describe "stderr" stderr ] |> List.choose id
    else
      []

  let detail =
    match parts with
    | [] -> ""
    | lines -> "\n  " + (String.concat "\n  " lines |> fun t -> if exitCode <> 0 then red t else dim t)

  let prompt = dim "$"
  let line = $"{prompt} {cyan (elide 140 commandLine)} {mark}{took}{size}{detail}"
  if exitCode = 0 then debug line else warn line

/// Same, without a measured duration.
let trace commandLine exitCode stdout stderr = traceTimed commandLine exitCode -1L stdout stderr
