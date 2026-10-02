/// The simulation chain, driven from the manager: the dev Artila runs `m_seq_sim.ko` (the whole
/// song, every siren's channel, through the real sequencer code), it copies every MIDI message
/// it dispatches to this machine (the "tap", UDP 9000), and `tap-viewer midi` plays them on a
/// virtual MIDI source that ComposeSiren sounds (m_seq/rs/SIMULATION.md). With it running, the
/// manager's Player tab starts songs on the board with the usual V1 commands and the rest of the
/// tabs see a Maitre that really plays.
///
/// Everything that changes the board goes through `tap-viewer` itself, which owns those steps and
/// has tested them (firmwares-artila/tools/tap-viewer): `tap-viewer sim up|down HOST` swaps the
/// module, `tap-viewer midi 9000 --virtual m_seq_sim --channels 1-7` hears the tap. This module only
/// starts and stops those two, keeps the listener's output for the UI, and reads the board's state
/// (read-only, as the unprivileged user, over the shared connection: cheap enough to poll).
///
/// Because it changes the module a board runs, starting and stopping are refused unless the
/// backend was started with SIREN_ALLOW_SIM=1: the manager is also the production control
/// program, and only the development board should ever be swapped.
module SirenManager.Backend.Sim

open System
open System.IO
open System.Net
open System.Net.Sockets
open System.Text
open System.Text.Json.Nodes
open System.Text.RegularExpressions
open System.Threading
open System.Threading.Tasks
open CliWrap
open SirenManager.Backend.Config
open Mecaviv.Infrastructure.Logging

let allowed () = Environment.GetEnvironmentVariable "SIREN_ALLOW_SIM" = "1"

let home = "/mnt/disk/home/guest"
let tapPort = 9000
let maitre = "linuxMaitre"

// ---------------------------------------------------------------- the local tap-viewer

/// $SIREN_TAP_VIEWER, or the newest build found in the firmwares-artila checkout by walking up
/// from the backend or the working folder (`franz run tap-viewer` builds it).
let findTapViewer () : string option =
  let rec up (d: DirectoryInfo) =
    seq {
      if not (isNull d) then
        for profile in [ "release"; "debug" ] do
          yield Path.Combine(d.FullName, "firmwares-artila", "tools", "tap-viewer", "target", profile, "tap-viewer")

        yield! up d.Parent
    }

  [ yield Environment.GetEnvironmentVariable "SIREN_TAP_VIEWER"
    yield! up (DirectoryInfo AppContext.BaseDirectory)
    yield! up (DirectoryInfo(Directory.GetCurrentDirectory())) ]
  |> List.filter (fun p -> not (String.IsNullOrEmpty p) && File.Exists p)
  |> List.sortByDescending (fun p -> File.GetLastWriteTimeUtc p)
  |> List.tryHead

let private ansi = Regex(@"\x1b\[[0-9;?]*[A-Za-z]", RegexOptions.Compiled)
let private plain (s: string) = ansi.Replace(s, "").Trim()

type private Tap =
  { Lines: ResizeArray<string>
    Graceful: CancellationTokenSource
    Forceful: CancellationTokenSource
    Started: DateTime
    mutable Exited: bool
    mutable ExitCode: int }

let mutable private tap: Tap option = None
let private gate = obj ()

let private tapRunning () =
  match tap with
  | Some t when not t.Exited -> true
  | _ -> false

let private tapLines n =
  match tap with
  | Some t -> lock t.Lines (fun () -> t.Lines |> Seq.rev |> Seq.truncate n |> Seq.rev |> List.ofSeq)
  | None -> []

/// Starts `tap-viewer midi 9000 --virtual m_seq_sim --channels 1-7` and keeps its output.
let private startTap (path: string) =
  let t =
    { Lines = ResizeArray()
      Graceful = new CancellationTokenSource()
      Forceful = new CancellationTokenSource()
      Started = DateTime.UtcNow
      Exited = false
      ExitCode = 0 }

  let onLine (l: string) =
    let l = plain l
    // The progress line is redrawn over and over: keep only the latest, not a page of them.
    if l <> "" then
      lock t.Lines (fun () ->
        if l.Contains "♪" && t.Lines.Count > 0 && t.Lines[t.Lines.Count - 1].Contains "♪" then
          t.Lines[t.Lines.Count - 1] <- l
        else
          t.Lines.Add l

        if t.Lines.Count > 200 then t.Lines.RemoveAt 0)

  tap <- Some t

  task {
    try
      let! r =
        Cli
          .Wrap(path)
          .WithArguments([ "midi"; string tapPort; "--virtual"; "m_seq_sim"; "--channels"; "1-7"; "--progress" ])
          .WithValidation(CommandResultValidation.None)
          .WithStandardOutputPipe(PipeTarget.ToDelegate onLine)
          .WithStandardErrorPipe(PipeTarget.ToDelegate onLine)
          .ExecuteAsync(t.Forceful.Token, t.Graceful.Token)

      t.ExitCode <- r.ExitCode
    with _ ->
      t.ExitCode <- -1

    t.Exited <- true
    info $"tap-viewer ended ({t.ExitCode})"
  }
  |> ignore

/// Interrupts the tap-viewer like Ctrl-C (it silences the notes), then kills it if it lingers.
let private stopTap () =
  task {
    match tap with
    | Some t when not t.Exited ->
      t.Graceful.Cancel()
      let mutable waited = 0

      while not t.Exited && waited < 50 do
        do! Task.Delay 100
        waited <- waited + 1

      if not t.Exited then t.Forceful.Cancel()
    | _ -> ()
  }

// ---------------------------------------------------------------- the board

let private ipOf cfg machine =
  match cfg.Machines.TryFind machine with
  | Some m when not (String.IsNullOrEmpty m.Ip) -> m.Ip
  | _ -> failwith $"no address for {machine} in config.json"

type Board =
  { Reachable: bool
    Error: string
    Master: bool            // numero_sirene says 10
    Module: string          // "m_seq_sim", "m_seq_rs", "m_seq", "none"
    SimInstalled: bool }    // m_seq_sim.ko is in the guest's home

let private withDeadline (ms: int) (work: Task<'a>) (what: string) =
  task {
    let! winner = Task.WhenAny(work :> Task, Task.Delay ms)

    if obj.ReferenceEquals(winner, work) then
      return! work
    else
      return failwith $"{what}: no answer in {ms / 1000} s"
  }

let board cfg machine =
  task {
    try
      let script =
        $"grep -q '>10<' {home}/numero_sirene && echo master; "
        + "if grep -q '^m_seq_sim ' /proc/modules; then echo module m_seq_sim; "
        + "elif grep -q '^m_seq_rs ' /proc/modules; then echo module m_seq_rs; "
        + "elif grep -q '^m_seq ' /proc/modules; then echo module m_seq; "
        + "else echo module none; fi; "
        + $"[ -f {home}/m_seq_sim.ko ] && echo installed; true"

      let! out = withDeadline 8000 (SshProxy.executeQuiet cfg machine script) "board"
      let lines = out.Split('\n', StringSplitOptions.RemoveEmptyEntries ||| StringSplitOptions.TrimEntries)

      return
        { Reachable = true
          Error = ""
          Master = Array.contains "master" lines
          Module = lines |> Array.tryPick (fun l -> if l.StartsWith "module " then Some(l.Substring 7) else None) |> Option.defaultValue "none"
          SimInstalled = Array.contains "installed" lines }
    with ex ->
      return { Reachable = false; Error = ex.Message; Master = false; Module = "?"; SimInstalled = false }
  }

/// Runs `tap-viewer <args>` to its end (a few seconds at most) and returns what it printed.
let private runViewer (path: string) (args: string list) (deadlineMs: int) =
  task {
    use cts = new CancellationTokenSource(deadlineMs)
    let out = StringBuilder()
    let err = StringBuilder()

    try
      let! r =
        Cli
          .Wrap(path)
          .WithArguments(args)
          .WithValidation(CommandResultValidation.None)
          .WithStandardOutputPipe(PipeTarget.ToStringBuilder out)
          .WithStandardErrorPipe(PipeTarget.ToStringBuilder err)
          .ExecuteAsync(cts.Token)

      if r.ExitCode = 0 then
        return Ok(plain (out.ToString()))
      else
        return Error(plain (err.ToString() + out.ToString()))
    with :? OperationCanceledException ->
      return Error $"tap-viewer {String.Join(' ', args)}: no end after {deadlineMs / 1000} s"
  }

let private portIsFree () =
  try
    use probe = new UdpClient(tapPort)
    true
  with _ ->
    false

// ---------------------------------------------------------------- status

let status cfg machine =
  task {
    let! b = board cfg machine
    let o = JsonObject()
    o["allowed"] <- JsonValue.Create(allowed ())
    o["machine"] <- JsonValue.Create machine

    let bo = JsonObject()
    bo["reachable"] <- JsonValue.Create b.Reachable
    bo["error"] <- JsonValue.Create b.Error
    bo["master"] <- JsonValue.Create b.Master
    bo["module"] <- JsonValue.Create b.Module
    bo["simInstalled"] <- JsonValue.Create b.SimInstalled
    o["board"] <- bo

    let to_ = JsonObject()
    to_["tapViewerFound"] <- JsonValue.Create((findTapViewer ()).IsSome)
    to_["running"] <- JsonValue.Create(tapRunning ())
    to_["port"] <- JsonValue.Create tapPort
    let lines = JsonArray()
    for l in tapLines 25 do lines.Add(JsonValue.Create l)
    to_["lines"] <- lines

    let exitCode =
      match tap with
      | Some t -> if t.Exited then t.ExitCode else -999
      | None -> -999

    to_["exitCode"] <- JsonValue.Create exitCode

    o["tap"] <- to_
    return o
  }

// ---------------------------------------------------------------- start and stop

let private refuse () =
  if not (allowed ()) then
    failwith "simulation disabled: start the backend with SIREN_ALLOW_SIM=1 (it swaps the module a board runs)"

/// Starts the listener, then has the board swap to m_seq_sim.ko (`tap-viewer sim up`).
let start cfg machine =
  task {
    refuse ()

    let viewer =
      match findTapViewer () with
      | Some p -> p
      | None -> failwith "tap-viewer is not built: run `franz run tap-viewer -- midi --list` once (or set SIREN_TAP_VIEWER)"

    let ip = ipOf cfg machine

    // 1. The tap must have a listener before the board starts sending.
    if not (tapRunning ()) then
      if not (portIsFree ()) then failwith $"UDP {tapPort} is taken by another program"
      startTap viewer
      do! Task.Delay 1500

      if not (tapRunning ()) then
        failwith ("tap-viewer stopped at once: " + String.Join(" | ", tapLines 4))

    // 2. The board's module, by tap-viewer. Anything wrong (not the master, no m_seq_sim.ko, root
    //    unreachable) comes back as its message, and the listener is stopped again.
    let! r = runViewer viewer [ "sim"; "up"; ip ] 60_000

    match r with
    | Ok msg ->
      info $"simulation: {msg}"
      return! status cfg machine
    | Error e ->
      do! stopTap ()
      return failwith e
  }

/// Stops the listener and has the board put m_seq back (`tap-viewer sim down`).
let stop cfg machine =
  task {
    refuse ()
    do! stopTap ()

    match findTapViewer () with
    | Some viewer ->
      let! r = runViewer viewer [ "sim"; "down"; ipOf cfg machine ] 60_000

      match r with
      | Ok msg -> info $"simulation: {msg}"
      | Error e -> failwith e
    | None -> failwith "tap-viewer is not built: the board cannot be put back from here"

    return! status cfg machine
  }
