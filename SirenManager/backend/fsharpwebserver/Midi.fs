/// What a standard MIDI file says about a composition: length, tempo, tracks,
/// the channels it plays on (a siren per channel) and how many notes. Read from
/// the file itself, so it works for every playlist, not only the one loaded in
/// the sequencer (the firmware reports slot lengths over UDP, one slot at a
/// time, for the active playlist only).
///
/// `command` asks a board for several files in ONE ssh session, framing each
/// as "##MIDI <name> <bytes>\n<raw bytes>", and `parseStream` splits that back.
module SirenManager.Backend.Midi

open System
open System.Text

/// What a midi-split file says about itself (see tools/midi-split): the channel it was cut
/// for, the length and SHA-256 of the master it came from, and whether its own hash holds.
type SplitInfo =
  { Channel: int
    MasterLen: int64
    MasterSha: string
    OwnOk: bool option }  // None: not checked

type MidiInfo =
  { Name: string          // first track name meta, when the file has one
    Format: int
    Tracks: int
    Ppq: int
    DurationSec: float
    Bpm: float            // first tempo, 120 when the file sets none
    TempoChanges: int
    TimeSig: string       // "4/4"
    Notes: int
    Channels: int list    // 1..16
    Sha256: string        // of the file, when it was asked for ("" otherwise)
    Split: SplitInfo option
    /// What the production C reader cannot take (m_seq/POSTMORTEM_SONG_END.md): level 2 = in a
    /// track that is not the last (the song is not loaded), 1 = in the last track (cut short);
    /// mask bit 0 program change, bit 1 pressure, bit 2 SysEx. 0 / 0 when the file is fine.
    RiskLevel: int
    RiskMask: int }

let private be16 (b: byte[]) i = int b[i] <<< 8 ||| int b[i + 1]
let private be32 (b: byte[]) i = (int64 b[i] <<< 24) ||| (int64 b[i + 1] <<< 16) ||| (int64 b[i + 2] <<< 8) ||| int64 b[i + 3]

/// Variable-length quantity: returns (value, next index).
let private vlq (b: byte[]) (i: int) =
  let mutable v = 0L
  let mutable p = i
  let mutable go = true

  while go && p < b.Length do
    let c = b[p]
    v <- (v <<< 7) ||| int64 (c &&& 0x7Fuy)
    p <- p + 1
    go <- c &&& 0x80uy <> 0uy

  v, p

type private TrackScan =
  { EndTick: int64         // the firmware's rule: latest end of track, channel message or marker
    Unsafe: int            // mask of what the production reader gives up on
    Tempos: (int64 * int) list     // tick, microseconds per quarter note
    Notes: int
    Channels: Set<int>
    TimeSig: string option
    Name: string option }

let private scanTrack (b: byte[]) (start: int) (stop: int) =
  let mutable i = start
  let mutable tick = 0L
  let mutable status = 0
  let mutable tempos = []
  let mutable notes = 0
  let mutable channels = Set.empty
  let mutable timeSig = None
  let mutable name = None
  let mutable endTick = 0L
  let mutable unsafeMask = 0

  while i < stop do
    let dt, p = vlq b i
    tick <- tick + dt
    i <- p

    if i < stop then
      let first = int b[i]

      if first = 0xFF then
        // meta: FF type len data
        let kind = int b[i + 1]
        let len, p2 = vlq b (i + 2)
        let len = int len

        if p2 + len <= b.Length then
          match kind with
          | 0x2F | 0x06 -> endTick <- max endTick tick        // end of track, marker
          | _ -> ()

          match kind with
          | 0x51 when len = 3 -> tempos <- (tick, (int b[p2] <<< 16) ||| (int b[p2 + 1] <<< 8) ||| int b[p2 + 2]) :: tempos
          | 0x58 when len >= 2 && timeSig.IsNone -> timeSig <- Some $"{int b[p2]}/{1 <<< int b[p2 + 1]}"
          | 0x03 when name.IsNone && len > 0 -> name <- Some((Encoding.Latin1.GetString(b, p2, len)).Trim())
          | _ -> ()

        i <- p2 + len
      elif first = 0xF0 || first = 0xF7 then
        unsafeMask <- unsafeMask ||| 4
        let len, p2 = vlq b (i + 1)
        i <- p2 + int len
      else
        // channel message; running status when the first byte is a data byte
        let dataStart =
          if first >= 0x80 then
            status <- first
            i + 1
          else
            i

        let kind = status &&& 0xF0
        let channel = (status &&& 0x0F) + 1
        let dataLen = if kind = 0xC0 || kind = 0xD0 then 1 else 2
        endTick <- max endTick tick                          // a channel message
        unsafeMask <- unsafeMask ||| (match kind with 0xC0 -> 1 | 0xA0 | 0xD0 -> 2 | _ -> 0)

        if kind = 0x90 && dataStart + 1 < b.Length && b[dataStart + 1] > 0uy then
          notes <- notes + 1
          channels <- Set.add channel channels
        elif kind = 0x80 then
          channels <- Set.add channel channels

        i <- dataStart + dataLen

  { EndTick = endTick
    Unsafe = unsafeMask
    Tempos = List.rev tempos
    Notes = notes
    Channels = channels
    TimeSig = timeSig
    Name = name }

let parse (b: byte[]) : Result<MidiInfo, string> =
  try
    if b.Length < 14 || Encoding.ASCII.GetString(b, 0, 4) <> "MThd" then
      Error "not a MIDI file"
    else
      let format, ntrks, division = be16 b 8, be16 b 10, be16 b 12

      if division &&& 0x8000 <> 0 || division = 0 then
        Error "SMPTE time division"
      else
        let mutable pos = 8 + int (be32 b 4)
        let tracks = ResizeArray<TrackScan>()

        while pos + 8 <= b.Length && tracks.Count < ntrks do
          let len = int (be32 b (pos + 4))
          let stop = min b.Length (pos + 8 + len)

          if Encoding.ASCII.GetString(b, pos, 4) = "MTrk" then
            tracks.Add(scanTrack b (pos + 8) stop)

          pos <- pos + 8 + len

        // Tempo map across tracks, then the length of the longest track in seconds.
        let tempos = tracks |> Seq.collect (fun t -> t.Tempos) |> Seq.sortBy fst |> List.ofSeq
        let endTick = if tracks.Count = 0 then 0L else tracks |> Seq.map (fun t -> t.EndTick) |> Seq.max

        // Microseconds through the tempo map in integer maths (as midi-info-board does), then
        // milliseconds; a tempo change after the end does not count.
        let micros =
          let rec go (lastTick: int64) (us: int64) (acc: int64) rest =
            match rest with
            | (t: int64, newUs: int) :: tail when t <= endTick -> go t (int64 newUs) (acc + (t - lastTick) * us / int64 division) tail
            | _ -> acc + (endTick - lastTick) * us / int64 division

          go 0L 500000L 0L tempos

        let risk =
          tracks |> Seq.mapi (fun i t -> i, t.Unsafe) |> Seq.filter (fun (_, u) -> u <> 0) |> List.ofSeq

        let riskLevel =
          if risk.IsEmpty then 0
          elif risk |> List.exists (fun (i, _) -> i < tracks.Count - 1) then 2
          else 1

        Ok
          { Name = tracks |> Seq.tryPick (fun t -> t.Name) |> Option.defaultValue ""
            Format = format
            Tracks = tracks.Count
            Ppq = division
            DurationSec = float (micros / 1000L) / 1000.0
            Bpm = (match tempos with (_, us) :: _ -> 60e6 / float us | [] -> 120.0)
            TempoChanges = tempos.Length
            TimeSig = tracks |> Seq.tryPick (fun t -> t.TimeSig) |> Option.defaultValue "4/4"
            Notes = tracks |> Seq.sumBy (fun t -> t.Notes)
            Channels = tracks |> Seq.collect (fun t -> t.Channels) |> Set.ofSeq |> Set.toList
            Sha256 = ""
            Split = None
            RiskLevel = riskLevel
            RiskMask = risk |> List.fold (fun a (_, u) -> a ||| u) 0 }
  with ex ->
    Error ex.Message

/// One ssh session for many files. The frame length is field 5 of `ls -l`:
/// the Artila has no `wc`, and `stat -c` is missing from BusyBox 1.00.
let command (dir: string) (files: string list) =
  let q (s: string) = "'" + s.Replace("'", "'\\''") + "'"
  let names = files |> List.map q |> String.concat " "

  $"cd {q dir} && for f in {names}; do [ -f \"$f\" ] && set -- $(ls -l \"$f\") && printf '##MIDI %%s %%s\\n' \"$f\" \"$5\" && cat \"$f\"; done"

/// Splits "##MIDI <name> <bytes>\n<raw>" frames (name may hold spaces; the size is the last word).
let parseStream (b: byte[]) : (string * Result<MidiInfo, string>) list =
  let marker = Encoding.ASCII.GetBytes "##MIDI "
  let acc = ResizeArray()
  let mutable i = 0

  let startsWithMarker p =
    p + marker.Length <= b.Length && b[p] = byte '#' && Seq.forall2 (=) marker b[p .. p + marker.Length - 1]

  while i < b.Length do
    if startsWithMarker i then
      let eol = Array.IndexOf(b, byte '\n', i)

      if eol < 0 then
        i <- b.Length
      else
        let header = Encoding.UTF8.GetString(b, i + marker.Length, eol - i - marker.Length)
        let cut = header.LastIndexOf ' '

        if cut <= 0 then
          i <- eol + 1
        else
          let name = header.Substring(0, cut)
          let size = match Int32.TryParse(header.Substring(cut + 1)) with | true, n -> n | _ -> 0
          let body = b[eol + 1 .. min (b.Length - 1) (eol + size)]
          acc.Add((name, parse body))
          i <- eol + 1 + size
    else
      i <- i + 1

  List.ofSeq acc

// ---------------------------------------------------------------- freshness

/// What `ls -le` says about a file. The mtime has seconds and the year, and every
/// write moves it: size + mtime tell whether a cached reading is still the file.
type FileStat = { Size: int64; Mtime: string }

/// `ls -le <dir>/`: full timestamps (BusyBox 1.00 has no --full-time and no md5sum/cksum).
let statCommand (dir: string) =
  let q (s: string) = "'" + s.Replace("'", "'\\''") + "'"
  let slashed = dir.TrimEnd('/') + "/"
  "ls -le " + q slashed

/// "-rwxrwxrwx 1 root root 9765 Fri Jul 3 08:21:33 2026 name" (for a single file, name is its path)
let parseStat (output: string) : Map<string, FileStat> =
  output.Split '\n'
  |> Array.choose (fun l ->
    let f = l.Trim().Split([| ' '; '\t' |], StringSplitOptions.RemoveEmptyEntries)

    // perms links user group size | Fri Jul 3 08:21:33 2026 | name...
    if l.StartsWith "-" && f.Length >= 11 then
      Some(String.Join(" ", f[10..]), { Size = int64 f[4]; Mtime = String.Join(" ", f[5..9]) })
    else
      None)
  |> Map.ofArray

let sha256 (bytes: byte[]) =
  Security.Cryptography.SHA256.HashData bytes |> Convert.ToHexString |> fun s -> s.ToLowerInvariant()

// ---------------------------------------------------------------- on-board tool

/// One line of `midi-info-board` (tools/midi-split-board): the board parses the file
/// itself and sends back what is shown. Returns the file name, its size and the reading.
///   I size=N ms=N fmt=N tracks=N ppq=N end=N ch=0xHHHH notes=N tempos=N tempo=N sig=N/N dur=N
///     [risk=L:M] [split=ch:N,mlen:N,msha:HEX[,own:ok|bad]] [sha=HEX] name=NAME
///   E err=KIND size=N name=NAME
let parseBoardLine (line: string) : (string * int64 * Result<MidiInfo, string>) option =
  let at = line.IndexOf " name="

  if not (line.StartsWith "I " || line.StartsWith "E ") || at < 0 then
    None
  else
    let name = line.Substring(at + 6)
    let kv =
      line.Substring(2, at - 2).Split(' ', StringSplitOptions.RemoveEmptyEntries)
      |> Array.choose (fun t ->
        let i = t.IndexOf '='
        if i > 0 then Some(t.Substring(0, i), t.Substring(i + 1)) else None)
      |> dict

    let get k = match kv.TryGetValue k with | true, v -> v | _ -> ""
    let num k = match Int64.TryParse(get k) with | true, v -> v | _ -> 0L
    let size = num "size"

    if line.StartsWith "E " then
      Some(name, size, Error(get "err"))
    else
      let channels =
        let mask = Convert.ToInt32((get "ch").Replace("0x", ""), 16)
        [ for c in 0..15 do if mask &&& (1 <<< c) <> 0 then yield c + 1 ]

      let sigText =
        match (get "sig").Split '/' with
        | [| n; d |] -> $"{n}/{d}"
        | _ -> "4/4"

      let split =
        match get "split" with
        | "" -> None
        | s ->
          let f = s.Split(',') |> Array.choose (fun p -> match p.Split(':') with | [| k; v |] -> Some(k, v) | _ -> None) |> dict
          let g k = match f.TryGetValue k with | true, v -> v | _ -> ""
          Some
            { Channel = (match Int32.TryParse(g "ch") with | true, v -> v | _ -> 0)
              MasterLen = (match Int64.TryParse(g "mlen") with | true, v -> v | _ -> 0L)
              MasterSha = g "msha"
              OwnOk = (match g "own" with | "ok" -> Some true | "bad" -> Some false | _ -> None) }

      let tempoUs = max 1L (num "tempo")

      // risk=L:M
      let riskLevel, riskMask =
        match (get "risk").Split ':' with
        | [| l; k |] -> (match Int32.TryParse l, Int32.TryParse k with | (true, a), (true, b) -> a, b | _ -> 0, 0)
        | _ -> 0, 0

      Some(
        name,
        size,
        Ok
          { Name = ""
            Format = int (num "fmt")
            Tracks = int (num "tracks")
            Ppq = int (num "ppq")
            DurationSec = float (num "dur") / 1000.0
            Bpm = 60e6 / float tempoUs
            TempoChanges = int (num "tempos")
            TimeSig = sigText
            Notes = int (num "notes")
            Channels = channels
            Sha256 = get "sha"
            Split = split
            RiskLevel = riskLevel
            RiskMask = riskMask }
      )
