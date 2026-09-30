module Mecaviv.Infrastructure.Logging

open System
open System.Text
open Serilog
open Serilog.Events

/// Text shorter than this is written under the command line. Longer text,
/// and anything with a NUL, is reported by size only.
let [<Literal>] private OutputLimit = 800

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
      .WriteTo.Console(outputTemplate = "[{Timestamp:HH:mm:ss} {Level:u3}] {Message:lj}{NewLine}{Exception}")
      .CreateLogger()

  if unknown then
    Log.Warning("{Text:l}", [| box $"logLevel '{levelName}' is not recognised; using Debug" |])

let private write level text =
  Log.Write(level, "{Text:l}", [| box text |])

let debug text = write LogEventLevel.Debug text
let info text = write LogEventLevel.Information text
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

/// Command line, exit code, and a short text dump of stdout/stderr.
/// stdout = None when the process did not capture it (the local tar writes a file).
let trace commandLine exitCode (stdout: byte[] option) (stderr: string) =
  let stdoutText =
    match stdout with
    | None -> None
    | Some bytes when bytes |> Array.exists (fun b -> b = 0uy) -> Some $"stdout: {bytes.Length} bytes"
    | Some bytes -> describe "stdout" (Encoding.UTF8.GetString bytes)

  let parts = [ stdoutText; describe "stderr" stderr ] |> List.choose id

  let detail =
    match parts with
    | [] -> ""
    | lines -> "\n  " + String.concat "\n  " lines

  debug $"$ {commandLine} -> {exitCode}{detail}"
