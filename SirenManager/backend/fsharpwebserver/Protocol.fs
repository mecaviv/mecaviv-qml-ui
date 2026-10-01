/// The conversation with a board as a grammar: what can be asked (`Request`),
/// how each question is worded for BusyBox (`command`), and what comes back
/// (`Response`, produced by `parse`). A request is a closed union, so the
/// scheduler can reason about it (kind, weight) instead of seeing a shell string,
/// and the shell strings live in one place, written for the weakest board
/// (BusyBox 1.00 on the Artila: no `stat -c`, no `find -maxdepth`, `df` needs
/// no argument).
///
/// Cheap by construction: one process per section where possible (`cat` of many
/// files, one `du` over many paths, one `ls -l` over many dirs), shell builtins
/// (`echo`) for markers, and nothing that forks per file.
module SirenManager.Backend.Protocol

open System
open System.Text.RegularExpressions

// ---------------------------------------------------------------- requests

type DmesgScope =
  | Tail of lines: int
  | ErrorsOnly

type Request =
  /// /proc/stat, loadavg, meminfo and every /proc/<pid>/stat: CPU, memory and
  /// the process table in a single `cat`. Meant to be polled.
  | CpuTick
  /// Owner uids of the given pids (only pids not seen before) and /etc/passwd.
  | Owners of pids: int list
  /// meminfo and df.
  | SystemInfo
  /// du over home, Midi, playlists, /tmp and /var/log plus the three listings.
  | DiskDetail of home: string * workspace: string
  | Dmesg of DmesgScope
  /// Every playlist file of a directory, then the pointer file naming the active one.
  | Playlists of dir: string * pointer: string
  | MidiDir of dir: string
  /// Today's /api/ssh/execute: a shell string the grammar does not know.
  | Raw of command: string

/// What a request is, for statistics and throttling.
type Kind =
  | KCpu
  | KOwners
  | KSystem
  | KDisk
  | KDmesg
  | KListing
  | KRaw

let kindOf =
  function
  | CpuTick -> KCpu
  | Owners _ -> KOwners
  | SystemInfo -> KSystem
  | DiskDetail _ -> KDisk
  | Dmesg _ -> KDmesg
  | Playlists _
  | MidiDir _ -> KListing
  | Raw c ->
    // The Qt client still sends shell strings: recognise the polls it makes so
    // they are counted (and throttled) as what they are.
    if c.Contains "/proc/[0-9]*/stat" then KCpu
    elif c.StartsWith "dmesg" then KDmesg
    elif c.Contains "du -sk" then KDisk
    else KRaw

/// Polls are cheap one by one and expensive in number: they are the ones to slow down.
let isPoll kind = kind = KCpu || kind = KDmesg

let kindName =
  function
  | KCpu -> "cpu"
  | KOwners -> "owners"
  | KSystem -> "system"
  | KDisk -> "disk"
  | KDmesg -> "dmesg"
  | KListing -> "listing"
  | KRaw -> "raw"

// ---------------------------------------------------------------- wording

let private q (s: string) = "'" + s.Replace("'", "'\\''") + "'"

/// The remote command for a request. Sections are announced with `echo '##name'`.
let command =
  function
  | CpuTick ->
    "cat /proc/stat /proc/loadavg /proc/meminfo; echo '##procs'; cat /proc/[0-9]*/stat 2>/dev/null"
  | Owners pids ->
    let files = pids |> List.map (fun p -> $"/proc/{p}/status") |> String.concat " "
    $"echo '##uids'; grep '^Uid:' {files} 2>/dev/null; echo '##passwd'; cat /etc/passwd 2>/dev/null"
  | SystemInfo -> "cat /proc/meminfo; echo '##df'; df"
  | DiskDetail(home, ws) ->
    let midi, lists = ws + "/Midi", ws + "/liste_de_lecture"
    $"echo '##df'; df; echo '##du'; du -sk {q home} {q midi} {q lists} /tmp /var/log 2>/dev/null; "
    + $"echo '##ls'; ls -l {q home} {q midi} {q lists} 2>/dev/null"
  | Dmesg(Tail n) -> $"dmesg | tail -{n}"
  | Dmesg ErrorsOnly -> "dmesg -l err"
  | Playlists(dir, pointer) ->
    $"cd {q dir} && for f in *; do [ -f \"$f\" ] && echo \"##pl $f\" && cat \"$f\" && echo; done; "
    + $"echo '##active'; cat {q pointer} 2>/dev/null"
  | MidiDir dir -> $"cd {q dir} && ls -l"
  | Raw c -> c

// ---------------------------------------------------------------- answers

type CpuTimes = { Total: int64; Idle: int64 }

type MemInfo =
  { TotalKb: int64
    FreeKb: int64
    BuffersKb: int64
    CachedKb: int64 }

/// "Used" as a task manager counts it: buffers and page cache are given back.
let memUsedKb m = max 0L (m.TotalKb - m.FreeKb - m.BuffersKb - m.CachedKb)

type ProcStat =
  { Pid: int
    Name: string
    State: char
    Ppid: int
    Jiffies: int64      // utime + stime
    RssKb: int64
    VirtKb: int64
    Threads: int }

type CpuSample =
  { Times: CpuTimes
    Cores: int
    Load: float * float * float
    Mem: MemInfo option
    Procs: ProcStat list }

type FileEntry =
  { Name: string
    Bytes: int64
    Executable: bool }

type DfRow =
  { Mount: string
    UsedKb: int64
    TotalKb: int64
    UsePct: string }

type DiskReport =
  { Df: DfRow list
    DuKb: Map<string, int64>                  // path -> kB
    Files: Map<string, FileEntry list> }      // directory -> regular files

type PlaylistEntry =
  { Slot: int
    File: string
    Pseudo: string
    Loop: bool
    Chain: bool }

type Playlist =
  { Name: string
    Active: bool
    Entries: PlaylistEntry list }

type Response =
  | Cpu of CpuSample
  | OwnerMap of Map<int, string>               // pid -> user name (or numeric uid)
  | System of MemInfo option * DfRow list
  | Disk of DiskReport
  | Log of string
  | Listing of FileEntry list
  | PlaylistSet of Playlist list
  | Text of string

type ParseError = Malformed of expected: string * got: string

// ---------------------------------------------------------------- parsing

let private lines (s: string) = s.Split([| '\n' |], StringSplitOptions.None)

/// Splits at "##name" marker lines; text before the first marker is section "".
let sections (output: string) =
  let acc = Collections.Generic.List<string * Collections.Generic.List<string>>()
  acc.Add(("", Collections.Generic.List()))

  for l in lines output do
    if l.StartsWith "##" then
      acc.Add((l.Substring(2).Trim(), Collections.Generic.List()))
    else
      (snd acc[acc.Count - 1]).Add l

  [ for name, ls in acc -> name, List.ofSeq ls ]

let private memInfo (text: string) =
  let kb name =
    let m = Regex.Match(text, "^" + name + @":\s+(\d+)", RegexOptions.Multiline)
    if m.Success then Some(int64 m.Groups[1].Value) else None

  match kb "MemTotal", kb "MemFree" with
  | Some t, Some f ->
    Some
      { TotalKb = t
        FreeKb = f
        BuffersKb = defaultArg (kb "Buffers") 0L
        CachedKb = defaultArg (kb "Cached") 0L }
  | _ -> None

/// BusyBox 1.00 prints the `/` row of `df` only without an argument; rows are
/// "fs 1k-blocks used avail use% mount".
let private dfRows (ls: string list) =
  ls
  |> List.skip (min 1 ls.Length)
  |> List.choose (fun l ->
    let f = l.Trim().Split([| ' '; '\t' |], StringSplitOptions.RemoveEmptyEntries)

    if f.Length >= 6 && Regex.IsMatch(f[1], @"^\d+$") && int64 f[1] > 0L then
      Some
        { Mount = f[5]
          UsedKb = int64 f[2]
          TotalKb = int64 f[1]
          UsePct = f[4] }
    else
      None)

/// "pid (comm) state ppid ...": comm may hold spaces and parentheses, so it is
/// cut at the last ") ".
let private procLine (l: string) =
  let m = Regex.Match(l, @"^(\d+) \((.*)\) (\S) (.*)$")

  if not m.Success then
    None
  else
    let r = m.Groups[4].Value.Split ' '

    if r.Length < 21 then
      None
    else
      Some
        { Pid = int m.Groups[1].Value
          Name = m.Groups[2].Value
          State = m.Groups[3].Value[0]
          Ppid = int r[0]
          Jiffies = int64 r[10] + int64 r[11]
          RssKb = int64 r[20] * 4L                 // pages of 4 kB
          VirtKb = int64 r[19] / 1024L
          Threads = int r[16] }

let private lsEntries (ls: string list) =
  ls
  |> List.choose (fun l ->
    if l.StartsWith "-" then
      let f = l.Trim().Split([| ' '; '\t' |], StringSplitOptions.RemoveEmptyEntries)

      if f.Length >= 9 then
        Some
          { Name = String.Join(" ", f[8..])
            Bytes = int64 f[4]
            Executable = f[0].Contains "x" }
      else
        None
    else
      None)

let private playlistEntries (content: string) =
  let rx =
    Regex(@"\{[^}]*\[n=(\d+)\][^}]*\[s=([^\]]*)\][^}]*\[a=([^\]]*)\][^}]*\[B=(\d)\][^}]*\[E=(\d)\][^}]*\}")

  [ for m in rx.Matches content ->
      { Slot = int m.Groups[1].Value
        File = m.Groups[2].Value
        Pseudo = m.Groups[3].Value
        Loop = m.Groups[4].Value = "1"
        Chain = m.Groups[5].Value = "1" } ]
  |> List.sortBy (fun e -> e.Slot)

let parseCpu (output: string) : Result<CpuSample, ParseError> =
  let secs = sections output
  let head = secs |> List.head |> snd |> String.concat "\n"
  let m = Regex.Match(head, @"^cpu\s+(.*)$", RegexOptions.Multiline)

  if not m.Success then
    Error(Malformed("a 'cpu' line of /proc/stat", output.Substring(0, min 80 output.Length)))
  else
    let f = m.Groups[1].Value.Trim().Split([| ' ' |], StringSplitOptions.RemoveEmptyEntries) |> Array.map int64
    // "cpu" alone on a uniprocessor kernel, "cpu" + "cpuN" lines on SMP.
    let cpuLines = Regex.Matches(head, @"^cpu\d*\s", RegexOptions.Multiline).Count

    let load =
      let l = Regex.Match(head, @"^(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)", RegexOptions.Multiline)

      if l.Success then
        float l.Groups[1].Value, float l.Groups[2].Value, float l.Groups[3].Value
      else
        0.0, 0.0, 0.0

    let procs =
      secs
      |> List.tryFind (fun (n, _) -> n = "procs")
      |> Option.map (snd >> List.choose procLine)
      |> Option.defaultValue []

    Ok
      { Times = { Total = Array.sum f; Idle = f[3] + (if f.Length > 4 then f[4] else 0L) }
        Cores = max 1 (cpuLines - 1)
        Load = load
        Mem = memInfo head
        Procs = procs }

let parseOwners (output: string) =
  let secs = sections output |> Map.ofList
  let get n = secs |> Map.tryFind n |> Option.defaultValue []

  let uidOf =
    get "uids"
    |> List.choose (fun l ->
      let m = Regex.Match(l, @"^/proc/(\d+)/status:Uid:\s+(\d+)")
      if m.Success then Some(int m.Groups[1].Value, m.Groups[2].Value) else None)

  let names =
    get "passwd"
    |> List.choose (fun l ->
      let m = Regex.Match(l, @"^([^:\s]+):[^:]*:(\d+):\d+:")
      if m.Success then Some(m.Groups[2].Value, m.Groups[1].Value) else None)
    |> Map.ofList

  uidOf |> List.map (fun (pid, uid) -> pid, defaultArg (Map.tryFind uid names) uid) |> Map.ofList

let parseDisk (output: string) : DiskReport =
  let secs = sections output |> Map.ofList
  let get n = secs |> Map.tryFind n |> Option.defaultValue []

  let du =
    get "du"
    |> List.choose (fun l ->
      let m = Regex.Match(l.Trim(), @"^(\d+)\s+(.+)$")
      if m.Success then Some(m.Groups[2].Value.TrimEnd '/', int64 m.Groups[1].Value) else None)
    |> Map.ofList

  // `ls -l d1 d2 d3` prints "d1:" then "total N" and the entries, per directory.
  let files =
    get "ls"
    |> List.fold
      (fun (cur, acc) l ->
        if l.EndsWith ":" && not (l.StartsWith "-") then
          Some(l.TrimEnd(':').TrimEnd '/'), acc
        else
          match cur with
          | Some d -> cur, Map.add d (defaultArg (Map.tryFind d acc) [] @ lsEntries [ l ]) acc
          | None -> cur, acc)
      (None, Map.empty)
    |> snd

  { Df = dfRows (get "df"); DuKb = du; Files = files }

let parsePlaylists (output: string) =
  let secs = sections output
  let active =
    secs
    |> List.tryFind (fun (n, _) -> n = "active")
    |> Option.bind (fun (_, ls) ->
      ls |> List.tryPick (fun l ->
        let m = Regex.Match(l, "<string>([^<]+)</string>")
        if m.Success then Some(m.Groups[1].Value.Trim().Split('/') |> Array.last) else None))

  [ for name, ls in secs do
      if name.StartsWith "pl " then
        let file = name.Substring 3 |> fun s -> s.Trim()

        if file <> "ALLLIST" then
          yield
            { Name = Regex.Replace(file, @"\.ListLecture$", "", RegexOptions.IgnoreCase)
              Active = (Some file = active)
              Entries = playlistEntries (String.concat "\n" ls) } ]

/// Reads the output of a request. `Raw` and anything unmodelled stays `Text`.
let parse (request: Request) (output: string) : Result<Response, ParseError> =
  match request with
  | CpuTick -> parseCpu output |> Result.map Cpu
  | Owners _ -> Ok(OwnerMap(parseOwners output))
  | SystemInfo ->
    let secs = sections output |> Map.ofList
    let head = secs |> Map.tryFind "" |> Option.defaultValue [] |> String.concat "\n"
    Ok(System(memInfo head, dfRows (secs |> Map.tryFind "df" |> Option.defaultValue [])))
  | DiskDetail _ -> Ok(Disk(parseDisk output))
  | Dmesg _ -> Ok(Log output)
  | Playlists _ -> Ok(PlaylistSet(parsePlaylists output))
  | MidiDir _ -> Ok(Listing(lsEntries (List.ofArray (lines output))))
  | Raw _ -> Ok(Text output)

// ---------------------------------------------------------------- derived figures

/// Busy share of the CPU between two samples, 0..100, None when no time passed.
let cpuBusyPct (prev: CpuTimes) (cur: CpuTimes) =
  let dTotal = cur.Total - prev.Total

  if dTotal <= 0L then
    None
  else
    Some(max 0.0 (min 100.0 (100.0 * (1.0 - float (cur.Idle - prev.Idle) / float dTotal))))

/// A process's share of the elapsed jiffies in units of one core (a busy thread
/// on a 4 core board reads 100 %, not 25 %).
let procCpuPct cores (dTotal: int64) (prevJiffies: int64) (p: ProcStat) =
  if dTotal > 0L then max 0.0 (100.0 * float cores * float (p.Jiffies - prevJiffies) / float dTotal) else 0.0
