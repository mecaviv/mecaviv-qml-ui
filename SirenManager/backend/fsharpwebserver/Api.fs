module SirenManager.Backend.Api

open System
open System.IO
open System.IO.Compression
open System.Text
open System.Text.Json
open System.Text.Json.Nodes
open System.Text.RegularExpressions
open System.Threading.Tasks
open CliWrap
open Giraffe
open Microsoft.AspNetCore.Http
open UnMango.CliWrap.FSharp
open SirenManager.Backend
open SirenManager.Backend.Config
open SirenManager.Backend.Logging

let tryProp (el: JsonElement) (name: string) =
  let mutable found = Unchecked.defaultof<JsonElement>
  if el.TryGetProperty(name, &found) then Some found else None

let str el name =
  match tryProp el name with
  | Some v when v.ValueKind = JsonValueKind.String -> v.GetString()
  | _ -> ""

let flag el name =
  match tryProp el name with
  | Some v when v.ValueKind = JsonValueKind.True -> true
  | _ -> false

let jstr (s: string) : JsonNode = JsonValue.Create s
let jbool (b: bool) : JsonNode = JsonValue.Create b
let jint (i: int) : JsonNode = JsonValue.Create i

let node (pairs: (string * JsonNode) list) =
  let o = JsonObject()

  for k, v in pairs do
    if not (isNull (box v)) then
      o[k] <- v

  o

let writeJson (ctx: HttpContext) status (body: JsonNode) =
  task {
    ctx.Response.StatusCode <- status
    ctx.Response.ContentType <- "application/json; charset=utf-8"
    do! ctx.Response.WriteAsync(body.ToJsonString())
    return Some ctx
  }

let ok pairs = node (("success", jbool true) :: pairs)

let fail message =
  node [ "success", jbool false; "error", jstr message ]

let readRoot (ctx: HttpContext) =
  task {
    use reader = new StreamReader(ctx.Request.Body, Encoding.UTF8)
    let! text = reader.ReadToEndAsync()
    let json = if String.IsNullOrWhiteSpace text then "{}" else text
    use doc = JsonDocument.Parse json
    return doc.RootElement.Clone()
  }

let prioqFields result =
  match result with
  | None -> []
  | Some(Ok()) -> [ "prioqRefreshed", jbool true ]
  | Some(Error msg) -> [ "prioqRefreshed", jbool false; "prioqRefreshError", jstr msg ]

let catch (ctx: HttpContext) work =
  task {
    try
      return! work ()
    with
    | SshProxy.SshError msg ->
      error $"SSH error: {msg}"
      return! writeJson ctx 500 (fail msg)
    | ex ->
      errorEx ex $"error: {ex.Message}"
      return! writeJson ctx 500 (fail ex.Message)
  }

let execute cfg =
  fun _ ctx ->
    catch ctx (fun () ->
      task {
        let! root = readRoot ctx
        let! output = SshProxy.execute cfg (str root "machineType") (str root "command")
        return! writeJson ctx 200 (ok [ "output", jstr output ])
      })

let download cfg =
  fun _ ctx ->
    catch ctx (fun () ->
      task {
        let! root = readRoot ctx
        let! content = SshProxy.download cfg (str root "machineType") (str root "remotePath")
        return! writeJson ctx 200 (ok [ "content", jstr content ])
      })

let upload cfg =
  fun _ ctx ->
    catch ctx (fun () ->
      task {
        let! root = readRoot ctx
        let machineType = str root "machineType"
        let remotePath = str root "remotePath"

        let bytes =
          match tryProp root "contentBase64" with
          | Some v when v.ValueKind = JsonValueKind.String && not (String.IsNullOrEmpty(v.GetString())) ->
            Convert.FromBase64String(v.GetString())
          | _ -> Encoding.UTF8.GetBytes(str root "content")

        info $"upload: machine={machineType} path={remotePath} bytes={bytes.Length}"
        do! SshProxy.upload cfg machineType remotePath bytes
        let! prioq = SshProxy.maybeRefreshPi5 cfg machineType remotePath
        return! writeJson ctx 200 (ok (prioqFields prioq))
      })

let syncDir cfg =
  fun _ ctx ->
    catch ctx (fun () ->
      task {
        let! root = readRoot ctx
        let sourceMachine = str root "sourceMachine"
        let sourcePath = str root "sourcePath"
        let mirror = flag root "mirror"
        let dryRun = flag root "dryRun"
        let mirrorPattern = str root "mirrorPattern"

        let targets =
          match tryProp root "targets" with
          | Some v when v.ValueKind = JsonValueKind.Array ->
            v.EnumerateArray()
            |> Seq.map (fun t -> str t "machineType", str t "remotePath")
            |> Seq.toList
          | _ -> failwith "targets is required"

        if mirror && mirrorPattern = "" then
          return! writeJson ctx 400 (fail "mirrorPattern is required when mirror=true")
        elif dryRun && not mirror then
          return! writeJson ctx 400 (fail "dryRun only meaningful when mirror=true")
        else
          info $"sync-dir: source={sourceMachine}:{sourcePath} -> {targets.Length} target(s)"
          // Source listing first. A failure here must not touch any target.
          let! sourceFiles =
            if mirror then
              task {
                let! files = SshProxy.listFiles cfg sourceMachine sourcePath mirrorPattern
                info $"sync-dir: source has {files.Length} file(s) matching {mirrorPattern}"
                return Some(Set.ofList files)
              }
            else
              task { return None }

          let! tarBuffer =
            if dryRun then
              task { return None }
            else
              task {
                let! bytes = SshProxy.tarRemote cfg sourceMachine sourcePath
                info $"sync-dir: tarball size={bytes.Length}"
                return Some bytes
              }

          let results = JsonArray()

          for machine, remotePath in targets do
            try
              let! removed, orphans =
                match sourceFiles with
                | None -> task { return 0, [] }
                | Some sourceSet ->
                  task {
                    let! targetFiles = SshProxy.listFiles cfg machine remotePath mirrorPattern
                    let orphans = targetFiles |> List.filter (fun f -> not (sourceSet.Contains f))

                    if not orphans.IsEmpty && not dryRun then
                      do! SshProxy.removeFiles cfg machine remotePath orphans
                      info $"sync-dir: {machine} - removed {orphans.Length} orphan(s)"

                    return orphans.Length, orphans
                  }

              if not dryRun then
                do! SshProxy.untarRemote cfg machine remotePath tarBuffer.Value

              let! prioq =
                if (not dryRun) && machine = "raspberryClic" then
                  SshProxy.maybeRefreshPi5 cfg machine remotePath
                else
                  task { return None }

              let entry =
                node (
                  [
                    "machine", jstr machine
                    "success", jbool true
                    "removed", jint removed
                    "orphans", JsonArray(orphans |> List.map jstr |> Array.ofList)
                    "dryRun", jbool dryRun
                  ]
                  @ prioqFields prioq
                )

              results.Add entry
            with
            | SshProxy.SshError msg ->
              error $"sync-dir: {machine}: {msg}"
              results.Add(node [ "machine", jstr machine; "success", jbool false; "error", jstr msg ])
            | ex ->
              errorEx ex $"sync-dir: {machine}: {ex.Message}"
              results.Add(node [ "machine", jstr machine; "success", jbool false; "error", jstr ex.Message ])

          let tarSize =
            match tarBuffer with
            | Some b -> b.Length
            | None -> 0

          return! writeJson ctx 200 (ok [ "tarSize", jint tarSize; "dryRun", jbool dryRun; "results", results ])
      })

let backup cfg =
  fun _ ctx ->
    catch ctx (fun () ->
      task {
        let machine =
          match ctx.Request.Query.TryGetValue "machine" with
          | true, v when not (String.IsNullOrEmpty(v.ToString())) -> v.ToString()
          | _ -> "linuxMaitre"

        let remoteRoot = "/mnt/disk/home/guest/WorkSpaceSirenes"
        let! tar = SshProxy.tarRemote cfg machine remoteRoot
        use ms = new MemoryStream()

        do
          use gz = new GZipStream(ms, CompressionLevel.Optimal, true)
          gz.Write(tar, 0, tar.Length)

        let body = ms.ToArray()
        let filename = $"sirenmanager-playlists-{DateTime.UtcNow:yyyyMMdd_HHmmss}.tar.gz"
        info $"playlists/backup: streaming {filename} ({body.Length} bytes)"
        ctx.Response.StatusCode <- 200
        ctx.Response.ContentType <- "application/gzip"
        ctx.Response.Headers.Append("Content-Disposition", $"attachment; filename=\"{filename}\"")
        do! ctx.Response.Body.WriteAsync(body)
        return Some ctx
      })

/// Host blocks whose first name is in this list. A line such as
/// `Host artila m508 192.168.1.101` is keyed as `artila` and is not exported.
let sirenAliases =
  [
    "linux-maître"
    "raspberry-clic"
    "sirene-s1"
    "sirene-s2"
    "sirene-s3"
    "sirene-s4"
    "sirene-s5"
    "sirene-s6"
    "sirene-s7"
    "voiture-a"
    "voiture-b"
    "pavillon-1"
    "pavillon-2"
  ]

let extractHostBlocks (text: string) =
  let lines = text.Replace("\r\n", "\n").Split '\n'
  let blocks = ResizeArray()
  let mutable current: (string * string list) option = None

  let flush () =
    match current with
    | Some(alias, ls) when List.contains alias sirenAliases ->
      let trimmed = ls |> List.rev |> List.skipWhile (fun l -> l.Trim() = "") |> List.rev
      blocks.Add(String.concat "\n" trimmed)
    | _ -> ()

    current <- None

  for line in lines do
    let m = Regex.Match(line, @"^\s*Host\s+(.+?)\s*$")

    if m.Success then
      flush ()

      let names =
        m.Groups[1].Value.Split([| ' ' |], StringSplitOptions.RemoveEmptyEntries)

      current <- Some(names[0], [ line ])
    else
      match current with
      | Some(alias, ls) -> current <- Some(alias, ls @ [ line ])
      | None -> ()

  flush ()
  blocks |> Seq.toList

let installSh =
  """#!/bin/sh
# Sketch of backend/server.js INSTALL_SH. Lift that script verbatim when this
# replaces the Node process; the archive layout is what the route must produce.
set -e
DIR=$(cd "$(dirname "$0")" && pwd)
SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
cp "$DIR/id_rsa_sirenes" "$SSH_DIR/id_rsa_sirenes"
cp "$DIR/id_rsa_sirenes.pub" "$SSH_DIR/id_rsa_sirenes.pub"
chmod 600 "$SSH_DIR/id_rsa_sirenes"
chmod 644 "$SSH_DIR/id_rsa_sirenes.pub"
touch "$SSH_DIR/config"
cat "$DIR/ssh_config_sirens" >> "$SSH_DIR/config"
echo "Installed. Test: ssh linux-maître 'echo OK'"
"""

let exportKeys =
  fun _ ctx ->
    catch ctx (fun () ->
      task {
        let home = Environment.GetFolderPath Environment.SpecialFolder.UserProfile
        let sshDir = Path.Combine(home, ".ssh")
        let keyPath = Path.Combine(sshDir, "id_rsa_sirenes")
        let pubPath = keyPath + ".pub"

        if not (File.Exists keyPath) || not (File.Exists pubPath) then
          return! writeJson ctx 404 (fail $"Clé absente: {keyPath}. Lance d'abord scripts/setup-ssh.sh.")
        else
          let stamp = DateTime.UtcNow.ToString("yyyyMMdd_HHmmss")
          let stem = $"sirenmanager-keys-{stamp}"
          let tmpRoot = Directory.CreateTempSubdirectory("sirenmanager-keys-").FullName
          let bundle = Path.Combine(tmpRoot, stem)
          Directory.CreateDirectory bundle |> ignore
          let destKey = Path.Combine(bundle, "id_rsa_sirenes")
          File.Copy(keyPath, destKey)
          File.SetUnixFileMode(destKey, UnixFileMode.UserRead ||| UnixFileMode.UserWrite)
          let destPub = Path.Combine(bundle, "id_rsa_sirenes.pub")
          File.Copy(pubPath, destPub)

          File.SetUnixFileMode(
            destPub,
            UnixFileMode.UserRead
            ||| UnixFileMode.UserWrite
            ||| UnixFileMode.GroupRead
            ||| UnixFileMode.OtherRead
          )

          let cfgPath = Path.Combine(sshDir, "config")

          let blocks =
            if File.Exists cfgPath then
              extractHostBlocks (File.ReadAllText cfgPath)
            else
              []

          let normalized =
            blocks
            |> List.map (fun b ->
              Regex.Replace(
                b,
                @"^(\s*IdentityFile\s+).*id_rsa_sirenes(\.pub)?\s*$",
                "$1~/.ssh/id_rsa_sirenes$2",
                RegexOptions.Multiline
              ))

          let blocksText =
            if normalized.IsEmpty then
              "# (no Host blocks found in ~/.ssh/config — run scripts/setup-ssh.sh --config first)\n"
            else
              String.concat "\n\n" normalized + "\n"

          File.WriteAllText(Path.Combine(bundle, "ssh_config_sirens"), blocksText)
          let installPath = Path.Combine(bundle, "INSTALL.sh")
          File.WriteAllText(installPath, installSh.Replace("\r\n", "\n"))

          File.SetUnixFileMode(
            installPath,
            UnixFileMode.UserRead ||| UnixFileMode.UserWrite ||| UnixFileMode.UserExecute
          )

          File.WriteAllText(
            Path.Combine(bundle, "README.txt"),
            "SirenManager SSH key bundle. See backend/server.js for the original INSTALL.sh.\n"
          )

          let downloads = Path.Combine(home, "Downloads")
          let outDir = if Directory.Exists downloads then downloads else home
          let outPath = Path.Combine(outDir, stem + ".tar.gz")
          let err = StringBuilder()

          let! tar =
            command "tar" {
              args [ "czf"; outPath; "-C"; tmpRoot; stem ]
              validation CommandResultValidation.None
              stderr (PipeTo.string err)
              exec
            }

          trace $"tar czf {outPath} -C {tmpRoot} {stem}" tar.ExitCode None (string err)
          Directory.Delete(tmpRoot, true)

          if tar.ExitCode <> 0 then
            return! writeJson ctx 500 (fail $"tar failed: {err}")
          else
            info $"keys/export: {outPath} ({blocks.Length} aliases)"
            return! writeJson ctx 200 (ok [ "path", jstr outPath; "aliasesFound", jint blocks.Length ])
      })

let webApp cfg =
  choose
    [
      POST >=> route "/api/ssh/execute" >=> execute cfg
      POST >=> route "/api/ssh/download" >=> download cfg
      POST >=> route "/api/ssh/upload" >=> upload cfg
      POST >=> route "/api/ssh/sync-dir" >=> syncDir cfg
      GET >=> route "/api/playlists/backup" >=> backup cfg
      POST >=> route "/api/keys/export" >=> exportKeys
      setStatusCode 404 >=> text "not found"
    ]
