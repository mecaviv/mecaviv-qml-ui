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
    Channels: int list }  // 1..16

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
  { EndTick: int64
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
          | 0x51 when len = 3 -> tempos <- (tick, (int b[p2] <<< 16) ||| (int b[p2 + 1] <<< 8) ||| int b[p2 + 2]) :: tempos
          | 0x58 when len >= 2 && timeSig.IsNone -> timeSig <- Some $"{int b[p2]}/{1 <<< int b[p2 + 1]}"
          | 0x03 when name.IsNone && len > 0 -> name <- Some((Encoding.Latin1.GetString(b, p2, len)).Trim())
          | _ -> ()

        i <- p2 + len
      elif first = 0xF0 || first = 0xF7 then
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

        if kind = 0x90 && dataStart + 1 < b.Length && b[dataStart + 1] > 0uy then
          notes <- notes + 1
          channels <- Set.add channel channels
        elif kind = 0x80 then
          channels <- Set.add channel channels

        i <- dataStart + dataLen

  { EndTick = tick
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

      if division &&& 0x8000 <> 0 then
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

        let seconds =
          let rec go (lastTick: int64) (us: int) acc rest =
            match rest with
            | (t, newUs) :: tail -> go t newUs (acc + float (t - lastTick) * float us / float division / 1e6) tail
            | [] -> acc + float (endTick - lastTick) * float us / float division / 1e6

          go 0L 500000 0.0 tempos

        Ok
          { Name = tracks |> Seq.tryPick (fun t -> t.Name) |> Option.defaultValue ""
            Format = format
            Tracks = tracks.Count
            Ppq = division
            DurationSec = seconds
            Bpm = (match tempos with (_, us) :: _ -> 60e6 / float us | [] -> 120.0)
            TempoChanges = tempos.Length
            TimeSig = tracks |> Seq.tryPick (fun t -> t.TimeSig) |> Option.defaultValue "4/4"
            Notes = tracks |> Seq.sumBy (fun t -> t.Notes)
            Channels = tracks |> Seq.collect (fun t -> t.Channels) |> Set.ofSeq |> Set.toList }
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
