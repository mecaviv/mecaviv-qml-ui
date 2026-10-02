module SirenManager.Backend.SshProxy

open System
open System.IO
open System.Text
open System.Text.RegularExpressions
open CliWrap
open UnMango.CliWrap.FSharp
open SirenManager.Backend.Config
open Mecaviv.Infrastructure.Logging

exception SshError of string

/// OpenSSH target. Alias wins so ~/.ssh/config supplies user, key, and the
/// legacy KEX the Artila boards need. This is the Node behaviour, not
/// SSH.NET with a password.
let target cfg machineType =
  match sshMachines.Contains machineType, cfg.Machines.TryFind machineType with
  | true, Some m when not (String.IsNullOrEmpty m.Alias) -> m.Alias
  | true, Some m -> $"{m.User}@{m.Ip}"
  | _ -> raise (SshError $"Unknown machine type: {machineType}")

let shellQuote (s: string) = "'" + s.Replace("'", "'\\''") + "'"

let globToRegex glob =
  let escaped = Regex.Escape(glob).Replace("\\*", ".*").Replace("\\?", ".")
  Regex("^" + escaped + "$", RegexOptions.IgnoreCase ||| RegexOptions.CultureInvariant)

/// One ssh connection per board, kept open and shared by every request: OpenSSH
/// `ControlMaster auto` starts the master on the first request and keeps it for
/// `ControlPersist` seconds (10 minutes) after the last; a request finding the master gone (board
/// rebooted, socket stale) simply starts a new one. The keep-alive makes a silently
/// lost link die within ~20 s instead of hanging requests. Set SIREN_SSH_NOMUX=1 to
/// go back to one connection per request.
let muxOptions =
  if Environment.GetEnvironmentVariable "SIREN_SSH_NOMUX" = "1" then
    []
  else
    let sock = Path.Combine(Environment.GetFolderPath Environment.SpecialFolder.UserProfile, ".ssh", "sm-%C")

    [ "-o"; "ControlMaster=auto"
      "-o"; $"ControlPath={sock}"
      "-o"; "ControlPersist=600"
      "-o"; "ServerAliveInterval=10"
      "-o"; "ServerAliveCountMax=2" ]

/// The options every request starts with (the Node behaviour).
let baseOptions =
  [ "-o"; "BatchMode=yes"
    "-o"; "ConnectTimeout=5"
    "-o"; "StrictHostKeyChecking=accept-new"
    "-o"; "ForwardX11=no" ]

/// OpenSSH argv, unchanged. CliWrap replaces Process.
let runBytesCt (ct: System.Threading.CancellationToken) (quiet: bool) label sshTarget remoteCommand stdin =
  task {
    use stdoutBytes = new MemoryStream()
    let stderrText = StringBuilder()

    let input =
      match stdin with
      | Some(bytes: byte[]) -> PipeSource.FromBytes bytes
      | None -> PipeSource.Null

    let sw = System.Diagnostics.Stopwatch.StartNew()

    // Cancelling the token kills the local ssh client (the request's deadline is over).
    let! result =
      Cli
        .Wrap("ssh")
        .WithArguments(baseOptions @ muxOptions @ [ sshTarget; remoteCommand ])
        .WithValidation(CommandResultValidation.None)
        .WithStandardInputPipe(input)
        .WithStandardOutputPipe(PipeTarget.ToStream stdoutBytes)
        .WithStandardErrorPipe(PipeTarget.ToStringBuilder stderrText)
        .ExecuteAsync(ct)

    let bytes = stdoutBytes.ToArray()
    let stderr = stderrText.ToString()

    let shown =
      match stdin with
      | Some inputBytes -> $"ssh {sshTarget} {remoteCommand} < {inputBytes.Length} bytes"
      | None -> $"ssh {sshTarget} {remoteCommand}"

    if not quiet then
      traceTimed shown result.ExitCode sw.ElapsedMilliseconds (Some bytes) stderr

    if result.ExitCode <> 0 then
      let detail =
        let err = stderr.Trim()

        if err <> "" then
          err
        else
          let text = Encoding.UTF8.GetString(bytes).Trim()
          if text <> "" then text else "no output"

      raise (SshError $"{label} exited {result.ExitCode}: {detail}")

    return bytes
  }

let runBytesQ quiet label sshTarget remoteCommand stdin =
  runBytesCt System.Threading.CancellationToken.None quiet label sshTarget remoteCommand stdin

let runBytes label sshTarget remoteCommand stdin = runBytesQ false label sshTarget remoteCommand stdin

/// Same as `execute` but without the per-command log lines: for batches, which log one summary.
let executeQuiet cfg machineType command =
  task {
    let! bytes = runBytesQ true "ssh" (target cfg machineType) command None
    return Encoding.UTF8.GetString bytes
  }

/// Collects the bytes of a stream and, after every `chunk` bytes, waits `pauseMs`
/// before accepting more. While it waits the local ssh cannot hand its stdout over,
/// the channel window fills, and the board's `cat` blocks: the transfer goes in
/// steps and the board's CPU, which the cipher saturates, is left to m_seq between
/// them. (BusyBox 1.00 has no `dd`/`head -c`, and `tail -c +N` fails from 64 KB.)
type private PacedStream(chunk: int, pauseMs: int) =
  inherit Stream()
  let buf = new MemoryStream()
  let mutable sinceBreak = 0
  member _.Bytes = buf.ToArray()
  member _.Chunks = (int buf.Length + chunk - 1) / chunk
  override _.CanRead = false
  override _.CanSeek = false
  override _.CanWrite = true
  override _.Length = raise (NotSupportedException())
  override _.Position with get () = raise (NotSupportedException()) and set _ = raise (NotSupportedException())
  override _.Flush() = ()
  override _.Read(_, _, _) = raise (NotSupportedException())
  override _.Seek(_, _) = raise (NotSupportedException())
  override _.SetLength _ = raise (NotSupportedException())

  override _.Write(data: byte[], offset: int, count: int) =
    buf.Write(data, offset, count)
    sinceBreak <- sinceBreak + count

  override this.WriteAsync(data: ReadOnlyMemory<byte>, ct: System.Threading.CancellationToken) =
    buf.Write(data.Span)
    sinceBreak <- sinceBreak + data.Length

    if pauseMs > 0 && sinceBreak >= chunk then
      sinceBreak <- 0
      System.Threading.Tasks.ValueTask(System.Threading.Tasks.Task.Delay(pauseMs, ct))
    else
      System.Threading.Tasks.ValueTask()

/// A remote file read in paced steps (see PacedStream); returns the bytes and the step count.
let readPaced cfg machineType (path: string) (chunkBytes: int) (pauseMs: int) =
  task {
    use paced = new PacedStream(chunkBytes, pauseMs)

    let argv =
      baseOptions @ muxOptions @ [ target cfg machineType; "cat " + shellQuote path ]

    let! result =
      Cli
        .Wrap("ssh")
        .WithArguments(argv)
        .WithValidation(CommandResultValidation.None)
        .WithStandardOutputPipe(PipeTarget.ToStream paced)
        .ExecuteAsync()

    if result.ExitCode <> 0 then
      raise (SshError $"cat {path} exited {result.ExitCode}")

    return paced.Bytes, paced.Chunks
  }

/// Runs a remote command and hands every stdout line to `onLine` as it arrives; the
/// token stops it (the ssh client is killed). Returns the exit code.
let streamLines cfg machineType (remoteCommand: string) (onLine: string -> unit) (ct: System.Threading.CancellationToken) =
  task {
    let argv = baseOptions @ muxOptions @ [ target cfg machineType; remoteCommand ]

    try
      let! result =
        Cli
          .Wrap("ssh")
          .WithArguments(argv)
          .WithValidation(CommandResultValidation.None)
          .WithStandardOutputPipe(PipeTarget.ToDelegate(fun l -> onLine l))
          .ExecuteAsync(ct)

      return result.ExitCode
    with :? OperationCanceledException -> return -1
  }

/// Reboots a board. `guest` may not (BusyBox says "no permission to run this applet"), `root` may,
/// so this one command is run as root (`-l root` keeps the host alias, hence the same keys and the
/// old key-exchange settings from ~/.ssh/config). It is the only thing run as root, and on its own
/// connection: no shared one is kept open for root. The board drops the link while rebooting, which
/// is what success looks like; only a failure to connect is an error.
let rebootAsRoot cfg machineType =
  task {
    let stderrText = StringBuilder()

    let! result =
      Cli
        .Wrap("ssh")
        .WithArguments(baseOptions @ [ "-o"; "ControlMaster=no"; "-o"; "ControlPath=none"; "-l"; "root"; target cfg machineType; "reboot" ])
        .WithValidation(CommandResultValidation.None)
        .WithStandardErrorPipe(PipeTarget.ToStringBuilder stderrText)
        .ExecuteAsync()

    let err = stderrText.ToString()

    let refused =
      [ "timed out"; "No route"; "refused"; "Could not resolve"; "Permission denied"; "banner" ]
      |> List.exists (fun k -> err.Contains(k, StringComparison.OrdinalIgnoreCase))

    if result.ExitCode <> 0 && refused then
      raise (SshError $"reboot: {err.Trim()}")
  }

/// `execute`, stoppable: the token is the request's deadline (see Scheduler.Policy.TimeoutMs).
let executeCt (ct: System.Threading.CancellationToken) (quiet: bool) cfg machineType command =
  task {
    let! bytes = runBytesCt ct quiet "ssh" (target cfg machineType) command None
    return Encoding.UTF8.GetString bytes
  }

let execute cfg machineType command =
  task {
    let! bytes = runBytes "ssh" (target cfg machineType) command None
    return Encoding.UTF8.GetString bytes
  }

let download cfg machineType remotePath =
  task {
    let cmd = "cat " + shellQuote remotePath
    let! bytes = runBytes "ssh cat" (target cfg machineType) cmd None
    return Encoding.UTF8.GetString bytes
  }

let upload cfg machineType remotePath content =
  task {
    let cmd = "cat > " + shellQuote remotePath
    let! _ = runBytes "ssh upload" (target cfg machineType) cmd (Some content)
    return ()
  }

let tarRemote cfg machineType remotePath =
  task {
    let cmd = "tar c -C " + shellQuote remotePath + " ."
    return! runBytes "tar export" (target cfg machineType) cmd None
  }

let untarRemote cfg machineType remotePath tar =
  task {
    let cmd = "tar x -C " + shellQuote remotePath
    let! _ = runBytes "tar import" (target cfg machineType) cmd (Some tar)
    return ()
  }

/// ls -1, not find. BusyBox 1.00 exits 0 on `find -maxdepth` and prints nothing useful.
let listFiles cfg machineType (remotePath: string) globPattern =
  task {
    let dir = remotePath.TrimEnd '/'

    try
      let! text = execute cfg machineType ("ls -1 " + shellQuote (dir + "/"))
      let re = globToRegex globPattern

      return
        text.Split('\n', StringSplitOptions.RemoveEmptyEntries)
        |> Array.map (fun s -> s.Trim())
        |> Array.filter (fun s -> s <> "" && re.IsMatch s)
        |> Array.toList
    with SshError msg ->
      return raise (SshError $"listFiles {dir} (pattern {globPattern}): {msg}")
  }

let removeFiles cfg machineType (remoteDir: string) (basenames: string list) =
  task {
    if not basenames.IsEmpty then
      let dir = remoteDir.TrimEnd '/'

      let paths =
        basenames |> List.map (fun b -> shellQuote $"{dir}/{b}") |> String.concat " "

      let! _ = execute cfg machineType ("rm -f " + paths)
      return ()
    else
      return ()
  }

/// Best-effort. None means "not applicable". Some (Error _) must not fail the upload.
let maybeRefreshPi5 cfg machineType (remotePath: string) =
  task {
    if machineType <> "raspberryClic" then
      return None
    else
      match cfg.Machines.TryFind "raspberryClic" with
      | None -> return None
      | Some m ->
        let hits =
          [ m.MidiPath; m.PlaylistPath ]
          |> List.exists (fun p -> p <> "" && remotePath.StartsWith p)

        if not hits then
          return None
        else
          try
            let! _ = execute cfg "raspberryClic" "sudo systemctl restart m-seq.service"
            info "raspberryClic m-seq prioq refreshed"
            return Some(Ok())
          with
          | SshError msg ->
            error $"raspberryClic m-seq restart: {msg}"
            return Some(Error msg)
          | ex ->
            errorEx ex $"raspberryClic m-seq restart: {ex.Message}"
            return Some(Error ex.Message)
  }
