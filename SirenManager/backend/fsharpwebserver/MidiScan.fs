/// Scan jobs: what a list of MIDI files says about itself, read where it is cheapest.
///
/// On an Artila the parsing is done ON the board by `midi-info-board` (firmwares-artila/tools/midi-split-board,
/// a 12 KB static program): it reads each file from flash and sends back one short line, about
/// 0.26 ms of CPU per KB against ~2.7 ms per KB to push the bytes through ssh's cipher, and
/// it runs at the lowest priority with a pause after every file so m_seq keeps the CPU. On a
/// board that cannot run it (the Raspberry Pi), or when the program cannot be found, the files
/// are read through ssh in paced steps and parsed here (Midi.fs).
///
/// A job runs in the background and is polled: its result lines are kept in order, so a
/// client can show each file as it lands and which one is being read. Readings are cached
/// per (machine, file) with the size and mtime they were read at (MidiCache), and a split
/// file's master hash is compared with the one the Maitre's master of the same name has.
module SirenManager.Backend.MidiScan

open System
open System.Collections.Concurrent
open System.IO
open System.Text.Json.Nodes
open System.Threading
open System.Threading.Tasks
open SirenManager.Backend.Config
open SirenManager.Backend.Midi
open Mecaviv.Infrastructure.Logging

let toolName = "midi-info-board"
let boardPath = "/tmp/" + toolName

/// Where every Artila (Maitre, sirens, cars, pavilions) keeps its MIDI files.
let artilaMidiDir = "/mnt/disk/home/guest/WorkSpaceSirenes/Midi"
let maitre = "linuxMaitre"

/// The Pi is not an Artila: no old-ABI ARM userland there.
let canRunBoardTool (machine: string) = machine <> "raspberryClic"

/// The board program (firmwares-artila/tools/midi-split-board, `./build.sh` there):
/// $SIREN_MIDI_INFO_BOARD, boardtools/ next to the backend, or the firmwares-artila checkout
/// found by walking up from the backend or the working folder.
let findTool () : string option =
  let rel =
    Path.Combine("firmwares-artila", "tools", "midi-split-board", "target", "armv4t-unknown-linux-gnueabi", "release", toolName)

  let rec up (d: DirectoryInfo) =
    seq {
      if not (isNull d) then
        yield Path.Combine(d.FullName, rel)
        yield! up d.Parent
    }

  [ yield Environment.GetEnvironmentVariable "SIREN_MIDI_INFO_BOARD"
    yield Path.Combine(AppContext.BaseDirectory, "boardtools", toolName)
    yield! up (DirectoryInfo AppContext.BaseDirectory)
    yield! up (DirectoryInfo(Directory.GetCurrentDirectory())) ]
  |> List.tryFind (fun p -> not (String.IsNullOrEmpty p) && File.Exists p)

/// Puts the program on the board when it is missing or of another size (/tmp is a ramdisk:
/// a reboot takes it away, the next scan puts it back).
let ensureTool cfg machine (local: string) =
  task {
    let bytes = File.ReadAllBytes local
    let! listing = SshProxy.executeQuiet cfg machine $"ls -l {boardPath} 2>/dev/null; true"
    let f = listing.Trim().Split([| ' '; '\t' |], StringSplitOptions.RemoveEmptyEntries)
    let present = f.Length >= 5 && f[4] = string bytes.Length

    if not present then
      do! SshProxy.upload cfg machine (boardPath + ".new") bytes
      let! _ = SshProxy.executeQuiet cfg machine $"chmod +x {boardPath}.new && mv {boardPath}.new {boardPath}"
      info $"midi scan {machine}: {toolName} put on the board ({bytes.Length} bytes)"
  }

type Job =
  { Id: string
    Machine: string
    Files: string list
    Lines: ResizeArray<JsonNode>
    mutable Current: string
    mutable Done: bool
    mutable Error: string
    mutable Via: string
    Cts: CancellationTokenSource }

let private jobs = ConcurrentDictionary<string, Job>()

let tryJob id =
  match jobs.TryGetValue id with
  | true, j -> Some j
  | _ -> None

/// Whether a split file's master is the Maitre's file of that name (or a plain copy is the same
/// file as the Maitre's): None while unknown.
let masterMatch machine name (i: MidiInfo) =
  if machine = maitre then
    None
  else
    match MidiCache.tryAny maitre name with
    | Some e when e.Info.Sha256 <> "" ->
      match i.Split with
      | Some s -> Some(e.Info.Sha256 = s.MasterSha)                      // a split: its master is the Maitre's file
      | None when i.Sha256 <> "" -> Some(e.Info.Sha256 = i.Sha256)       // a copy: the same bytes
      | None -> None
    | _ -> None

let private lineOf (machine: string) (name: string) (st: FileStat) (fromCache: bool) (result: Result<MidiInfo, string>) =
  let o = JsonObject()
  o["file"] <- JsonValue.Create name
  o["size"] <- JsonValue.Create st.Size
  o["mtime"] <- JsonValue.Create st.Mtime
  o["fromCache"] <- JsonValue.Create fromCache

  match result with
  | Ok i ->
    o["info"] <- MidiCache.infoToJson i

    match masterMatch machine name i with
    | Some m -> o["masterMatch"] <- JsonValue.Create m
    | None -> ()
  | Error e -> o["error"] <- JsonValue.Create e

  o :> JsonNode

let private add (job: Job) (n: JsonNode) = lock job.Lines (fun () -> job.Lines.Add n)

let private quote (s: string) = SshProxy.shellQuote s

/// Cached readings are answered at once; the rest are read, on the board when it can.
/// `emit` gets every result as it lands (None for the files only wanted in the cache).
let private scan cfg (machine: string) (dir: string) (files: string list) pauseMs (ct: CancellationToken) (setCurrent: string -> unit) (emit: string -> FileStat -> bool -> Result<MidiInfo, string> -> unit) =
  task {
    let! statText = SshProxy.executeQuiet cfg machine (statCommand dir)
    let stats = parseStat statText
    let missing = ResizeArray<string>()

    for name in files do
      match Map.tryFind name stats with
      | None -> emit name { Size = 0L; Mtime = "" } false (Error "absent")
      | Some st ->
        match MidiCache.tryFresh machine name st with
        | Some e -> emit name st true (Ok e.Info)
        | None -> missing.Add name

    if missing.Count > 0 then
      let tool = if canRunBoardTool machine then findTool () else None
      let keep (name: string) (st: FileStat) (i: MidiInfo) =
        MidiCache.put machine name { Stat = st; Sha256 = i.Sha256; Info = i }

      match tool with
      | Some local ->
        do! ensureTool cfg machine local
        // Hash every file (the Maitre's masters are what the others are compared with) and check
        // the split files' own hash, which costs nothing on a file that is not a split.
        let flag = "--sha --verify"
        let paths = missing |> Seq.map (fun n -> quote (dir.TrimEnd('/') + "/" + n)) |> String.concat " "
        let todo = Collections.Generic.Queue<string>(missing)
        setCurrent (todo.Peek())

        let onLine (line: string) =
          match parseBoardLine line with
          | Some(name, _, result) ->
            if todo.Count > 0 then todo.Dequeue() |> ignore
            let st = stats[name]
            (match result with Ok i -> keep name st i | Error _ -> ())
            emit name st false result
            setCurrent (if todo.Count > 0 then todo.Peek() else "")
          | None -> ()

        let! code = SshProxy.streamLines cfg machine $"{boardPath} --pause-ms {pauseMs} {flag} {paths}" onLine ct
        if code > 0 then failwith $"{toolName} exited {code}"
      | None ->
        // Paced reads through ssh, parsed here.
        for name in missing do
          ct.ThrowIfCancellationRequested()
          setCurrent name
          let st = stats[name]
          let! bytes, _ = SshProxy.readPaced cfg machine (dir.TrimEnd('/') + "/" + name) (64 * 1024) pauseMs
          let result: Result<MidiInfo, string> =
            if int64 bytes.Length <> st.Size then
              Error "short read"
            else
              parse bytes |> Result.map (fun i -> { i with Sha256 = sha256 bytes })

          match result with
          | Ok i -> keep name st i
          | Error _ -> ()

          emit name st false result
        setCurrent ""
  }

/// Starts a job and returns at once; poll it with `tryJob`.
let start cfg machine (dir: string) (files: string list) (pauseMs: int) =
  let job =
    { Id = Guid.NewGuid().ToString("N")
      Machine = machine
      Files = files
      Lines = ResizeArray()
      Current = ""
      Done = false
      Error = ""
      Via = (if canRunBoardTool machine && (findTool ()).IsSome then "board" else "transfer")
      Cts = new CancellationTokenSource() }

  jobs[job.Id] <- job
  // Old jobs are forgotten once a few newer ones exist.
  for old in jobs.Values |> Seq.filter (fun j -> j.Done) |> Seq.sortBy (fun j -> j.Id) |> Seq.truncate (max 0 (jobs.Count - 8)) do
    jobs.TryRemove old.Id |> ignore

  let sw = Diagnostics.Stopwatch.StartNew()

  let work =
    task {
      try
        let results = ResizeArray<string * Result<MidiInfo, string>>()

        do!
          scan cfg machine dir files pauseMs job.Cts.Token (fun n -> job.Current <- n) (fun name st fromCache result ->
            results.Add((name, result))
            add job (lineOf machine name st fromCache result))

        // Split files whose master hash we do not know yet: hash those masters on the Maitre,
        // then say again, for each, whether it matches.
        let unknown =
          results
          |> Seq.choose (fun (n, r) -> match r with Ok i when (masterMatch machine n i).IsNone && machine <> maitre && (i.Split.IsSome || i.Sha256 <> "") -> Some n | _ -> None)
          |> List.ofSeq

        if not unknown.IsEmpty then
          job.Current <- "maître : " + (List.head unknown)
          do! scan cfg maitre artilaMidiDir unknown pauseMs job.Cts.Token (fun _ -> ()) (fun _ _ _ _ -> ())

          for name, r in results do
            match r with
            | Ok i when List.contains name unknown ->
              let st = { Size = 0L; Mtime = "" }
              add job (lineOf machine name st true (Ok i))
            | _ -> ()

        let n = results.Count
        let took = duration sw.ElapsedMilliseconds
        info $"midi scan {machine} ({job.Via}): {n} files  {took}"
      with
      | :? OperationCanceledException -> ()
      | ex ->
        job.Error <- ex.Message
        error $"midi scan {machine}: {ex.Message}"

      job.Current <- ""
      job.Done <- true
    }

  work |> ignore
  job

let lines (job: Job) (from: int) =
  lock job.Lines (fun () -> [ for i in max 0 from .. job.Lines.Count - 1 -> job.Lines[i] ])
