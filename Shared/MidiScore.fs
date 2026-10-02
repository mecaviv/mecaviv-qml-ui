/// A standard MIDI file read whole, as a score: every note with its time in ms, the tempo and
/// time-signature maps, and the conversions between ms, ticks and bar/beat.
///
/// This is what lets a display scroll ahead of the sound with a single clock: the score is
/// known in advance, and only the sound's position has to travel while it plays. It replaces
/// midi-sequencer.js's clock, which drifted (ticks floored every 50 ms) and counted a quarter
/// note per beat whatever the signature's denominator.
module Mecaviv.Shared.MidiScore

type Note =
  {
    Tick: int64
    Ms: float
    DurationMs: float
    /// 1 to 16, as Pd's [midifile] numbers them.
    Channel: int
    Note: int
    Velocity: int
    Track: int
  }

type Signature =
  {
    Tick: int64
    Numerator: int
    Denominator: int
    /// The bar this signature starts, 1-based.
    Bar: int
  }

type Score =
  {
    Ppq: int
    /// Microseconds per quarter note from each tick on, the first at tick 0.
    Tempos: (int64 * int) list
    Signatures: Signature list
    Notes: Note list
    EndTick: int64
    DurationMs: float
  }

let private defaultTempo = 500000

type private Raw =
  | NoteOn of channel: int * note: int * velocity: int
  | NoteOff of channel: int * note: int
  | Tempo of int
  | TimeSig of numerator: int * denominator: int
  | Other

let private be16 (b: byte[]) i = (int b.[i] <<< 8) ||| int b.[i + 1]

let private be32 (b: byte[]) i =
  (int b.[i] <<< 24)
  ||| (int b.[i + 1] <<< 16)
  ||| (int b.[i + 2] <<< 8)
  ||| int b.[i + 3]

/// One track chunk's events, with absolute ticks.
let private readTrack (b: byte[]) (start: int) (length: int) =
  let stop = start + length
  let events = ResizeArray<int64 * Raw>()
  let mutable i = start
  let mutable tick = 0L
  let mutable running = 0

  let varLen () =
    let mutable v = 0
    let mutable go = true

    while go do
      let c = int b.[i]
      i <- i + 1
      v <- (v <<< 7) ||| (c &&& 0x7F)
      go <- c &&& 0x80 <> 0

    v

  while i < stop do
    tick <- tick + int64 (varLen ())
    let first = int b.[i]

    if first = 0xFF then
      let kind = int b.[i + 1]
      i <- i + 2
      let len = varLen ()

      match kind with
      | 0x51 when len = 3 -> events.Add(tick, Tempo((int b.[i] <<< 16) ||| (int b.[i + 1] <<< 8) ||| int b.[i + 2]))
      | 0x58 when len >= 2 -> events.Add(tick, TimeSig(int b.[i], 1 <<< int b.[i + 1]))
      | _ -> ()

      i <- i + len
    elif first = 0xF0 || first = 0xF7 then
      i <- i + 1
      let len = varLen ()
      i <- i + len
    else
      // Running status: a data byte reuses the previous status.
      let status =
        if first &&& 0x80 <> 0 then
          i <- i + 1
          running <- first
          first
        else
          running

      let channel = (status &&& 0x0F) + 1

      match status &&& 0xF0 with
      | 0x90 ->
        let note, velocity = int b.[i], int b.[i + 1]
        i <- i + 2

        events.Add(
          tick,
          (if velocity = 0 then
             NoteOff(channel, note)
           else
             NoteOn(channel, note, velocity))
        )
      | 0x80 ->
        events.Add(tick, NoteOff(channel, int b.[i]))
        i <- i + 2
      | 0xC0
      | 0xD0 -> i <- i + 1
      | _ -> i <- i + 2

  tick, events

/// Ticks → ms through the tempo map.
let msOfTick (ppq: int) (tempos: (int64 * int) list) (tick: int64) =
  let rec go acc (prevTick: int64) (prevTempo: int) rest =
    match rest with
    | (t, tempo) :: tail when t <= tick ->
      go (acc + float (t - prevTick) * float prevTempo / 1000.0 / float ppq) t tempo tail
    | _ -> acc + float (tick - prevTick) * float prevTempo / 1000.0 / float ppq

  match tempos with
  | (0L, first) :: rest -> go 0.0 0L first rest
  | _ -> go 0.0 0L defaultTempo tempos

/// Ms → ticks, the inverse of msOfTick (fractional).
let tickOfMs (ppq: int) (tempos: (int64 * int) list) (ms: float) =
  let rec go (prevTick: int64) (prevMs: float) (prevTempo: int) rest =
    let msPerTick = float prevTempo / 1000.0 / float ppq

    match rest with
    | (t, tempo) :: tail ->
      let msAtT = prevMs + float (t - prevTick) * msPerTick

      if msAtT <= ms then
        go t msAtT tempo tail
      else
        float prevTick + (ms - prevMs) / msPerTick
    | [] -> float prevTick + (ms - prevMs) / msPerTick

  match tempos with
  | (0L, first) :: rest -> go 0L 0.0 first rest
  | _ -> go 0L 0.0 defaultTempo tempos

/// Bar (1-based) and beat in bar (1-based), the beat being the signature's denominator.
let barBeatOfTick (ppq: int) (signatures: Signature list) (tick: int64) =
  let s =
    signatures
    |> List.filter (fun s -> s.Tick <= tick)
    |> List.tryLast
    |> Option.defaultValue
      {
        Tick = 0L
        Numerator = 4
        Denominator = 4
        Bar = 1
      }

  let ticksPerBeat = int64 ppq * 4L / int64 s.Denominator
  let ticksPerBar = ticksPerBeat * int64 s.Numerator
  let since = tick - s.Tick
  s.Bar + int (since / ticksPerBar), int ((since % ticksPerBar) / ticksPerBeat) + 1

let read (b: byte[]) : Result<Score, string> =
  try
    if b.Length < 14 || System.Text.Encoding.ASCII.GetString(b, 0, 4) <> "MThd" then
      Error "not a MIDI file (no MThd)"
    else
      let headerLength = be32 b 4
      let trackCount = be16 b 10
      let division = be16 b 12

      if division &&& 0x8000 <> 0 then
        Error "SMPTE time division is not supported"
      else
        let ppq = division
        let mutable i = 8 + headerLength
        let tracks = ResizeArray()

        while tracks.Count < trackCount && i + 8 <= b.Length do
          let id = System.Text.Encoding.ASCII.GetString(b, i, 4)
          let length = be32 b (i + 4)

          if id = "MTrk" then
            tracks.Add(readTrack b (i + 8) length)

          i <- i + 8 + length

        let all =
          tracks
          |> Seq.mapi (fun track (_, events) -> events |> Seq.map (fun (tick, e) -> tick, track, e))
          |> Seq.concat
          |> Seq.sortBy (fun (tick, _, _) -> tick) // stable: file order within a tick
          |> List.ofSeq

        let endTick =
          if tracks.Count = 0 then
            0L
          else
            tracks |> Seq.map fst |> Seq.max

        let tempos =
          let changes =
            all
            |> List.choose (fun (t, _, e) ->
              match e with
              | Tempo us -> Some(t, us)
              | _ -> None)

          let changes =
            match changes with
            | (0L, _) :: _ -> changes
            | _ -> (0L, defaultTempo) :: changes

          // the last change at a given tick wins
          changes |> List.rev |> List.distinctBy fst |> List.rev

        let signatures =
          let changes =
            all
            |> List.choose (fun (t, _, e) ->
              match e with
              | TimeSig(n, d) -> Some(t, n, d)
              | _ -> None)
            |> List.rev
            |> List.distinctBy (fun (t, _, _) -> t)
            |> List.rev

          let changes =
            match changes with
            | (0L, _, _) :: _ -> changes
            | _ -> (0L, 4, 4) :: changes

          changes
          |> List.fold
            (fun (acc: Signature list) (t, n, d) ->
              match acc with
              | [] ->
                [
                  {
                    Tick = t
                    Numerator = n
                    Denominator = d
                    Bar = 1
                  }
                ]
              | prev :: _ ->
                let ticksPerBar = int64 ppq * 4L / int64 prev.Denominator * int64 prev.Numerator
                // a signature change mid-bar starts a new bar
                let bars = (t - prev.Tick + ticksPerBar - 1L) / ticksPerBar

                {
                  Tick = t
                  Numerator = n
                  Denominator = d
                  Bar = prev.Bar + int bars
                }
                :: acc)
            []
          |> List.rev

        let ms = msOfTick ppq tempos

        // Note-ons paired with the next note-off of the same channel and note (first in, first out).
        let open' =
          System.Collections.Generic.Dictionary<int * int, System.Collections.Generic.Queue<int64 * int * int>>()

        let notes = ResizeArray<Note>()

        for tick, track, e in all do
          match e with
          | NoteOn(ch, n, v) ->
            match open'.TryGetValue((ch, n)) with
            | true, q -> q.Enqueue(tick, v, track)
            | _ ->
              let q = System.Collections.Generic.Queue()
              q.Enqueue(tick, v, track)
              open'.[(ch, n)] <- q
          | NoteOff(ch, n) ->
            match open'.TryGetValue((ch, n)) with
            | true, q when q.Count > 0 ->
              let start, v, track = q.Dequeue()

              notes.Add
                {
                  Tick = start
                  Ms = ms start
                  DurationMs = ms tick - ms start
                  Channel = ch
                  Note = n
                  Velocity = v
                  Track = track
                }
            | _ -> ()
          | _ -> ()

        // Notes never released last until the end.
        for KeyValue((ch, n), q) in open' do
          for start, v, track in q do
            notes.Add
              {
                Tick = start
                Ms = ms start
                DurationMs = ms endTick - ms start
                Channel = ch
                Note = n
                Velocity = v
                Track = track
              }

        Ok
          {
            Ppq = ppq
            Tempos = tempos
            Signatures = signatures
            Notes = notes |> Seq.sortBy (fun n -> n.Tick, n.Channel, n.Note) |> List.ofSeq
            EndTick = endTick
            DurationMs = ms endTick
          }
  with ex ->
    Error $"unreadable MIDI file ({ex.Message})"
