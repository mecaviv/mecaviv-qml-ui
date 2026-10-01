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

/// OpenSSH argv, unchanged. CliWrap replaces Process.
let runBytesQ (quiet: bool) label sshTarget remoteCommand stdin =
  task {
    use stdoutBytes = new MemoryStream()
    let stderrText = StringBuilder()

    let input =
      match stdin with
      | Some bytes -> ReadFrom.bytes bytes
      | None -> ReadFrom.devnull

    let sw = System.Diagnostics.Stopwatch.StartNew()

    let! result =
      command "ssh" {
        args
          [
            "-o"
            "BatchMode=yes"
            "-o"
            "ConnectTimeout=5"
            "-o"
            "StrictHostKeyChecking=accept-new"
            "-o"
            "ForwardX11=no"
            sshTarget
            remoteCommand
          ]

        validation CommandResultValidation.None
        stdin input
        stdout (PipeTo.stream stdoutBytes)
        stderr (PipeTo.string stderrText)
        exec
      }

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

let runBytes label sshTarget remoteCommand stdin = runBytesQ false label sshTarget remoteCommand stdin

/// Same as `execute` but without the per-command log lines: for batches, which log one summary.
let executeQuiet cfg machineType command =
  task {
    let! bytes = runBytesQ true "ssh" (target cfg machineType) command None
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
