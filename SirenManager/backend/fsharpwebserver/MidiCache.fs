/// Parsed MIDI readings, kept per (machine, file) with the size and mtime they were
/// read at, and the SHA-256 of the bytes that were parsed. A reading is served only
/// while `ls -le` still shows that size and mtime; otherwise the file is read again.
/// Persisted next to the executable so a restart does not read everything again.
module SirenManager.Backend.MidiCache

open System
open System.Collections.Concurrent
open System.IO
open System.Text.Json.Nodes
open SirenManager.Backend.Midi

type Entry =
  { Stat: FileStat
    Sha256: string
    Info: MidiInfo }

let private file = Path.Combine(AppContext.BaseDirectory, "midi-cache.json")
let private store = ConcurrentDictionary<string, Entry>()
let private key machine name = machine + "|" + name
let private gate = obj ()

let infoToJson (i: MidiInfo) =
  let o = JsonObject()
  o["name"] <- JsonValue.Create i.Name
  o["format"] <- JsonValue.Create i.Format
  o["tracks"] <- JsonValue.Create i.Tracks
  o["ppq"] <- JsonValue.Create i.Ppq
  o["durationSec"] <- JsonValue.Create i.DurationSec
  o["bpm"] <- JsonValue.Create i.Bpm
  o["tempoChanges"] <- JsonValue.Create i.TempoChanges
  o["timeSig"] <- JsonValue.Create i.TimeSig
  o["notes"] <- JsonValue.Create i.Notes
  let ch = JsonArray()
  for c in i.Channels do ch.Add(JsonValue.Create c)
  o["channels"] <- ch
  if i.Sha256 <> "" then o["sha256"] <- JsonValue.Create i.Sha256

  match i.Split with
  | Some s ->
    let so = JsonObject()
    so["channel"] <- JsonValue.Create s.Channel
    so["masterLen"] <- JsonValue.Create s.MasterLen
    so["masterSha"] <- JsonValue.Create s.MasterSha
    (match s.OwnOk with Some b -> so["ownOk"] <- JsonValue.Create b | None -> ())
    o["split"] <- so
  | None -> ()

  o

let private infoOfJson (o: JsonNode) : MidiInfo =
  { Name = string o["name"]
    Format = int o["format"]
    Tracks = int o["tracks"]
    Ppq = int o["ppq"]
    DurationSec = float o["durationSec"]
    Bpm = float o["bpm"]
    TempoChanges = int o["tempoChanges"]
    TimeSig = string o["timeSig"]
    Notes = int o["notes"]
    Channels = [ for c in o["channels"].AsArray() -> int c ]
    Sha256 = (match o["sha256"] with | null -> "" | v -> string v)
    Split =
      match o["split"] with
      | null -> None
      | s ->
        Some
          { Channel = int s["channel"]
            MasterLen = int64 s["masterLen"]
            MasterSha = string s["masterSha"]
            OwnOk = (match s["ownOk"] with | null -> None | v -> Some(v.GetValue<bool>())) } }

let private save () =
  lock gate (fun () ->
    let root = JsonObject()

    for KeyValue(k, e) in store do
      let o = JsonObject()
      o["size"] <- JsonValue.Create e.Stat.Size
      o["mtime"] <- JsonValue.Create e.Stat.Mtime
      o["sha256"] <- JsonValue.Create e.Sha256
      o["info"] <- infoToJson e.Info
      root[k] <- o

    File.WriteAllText(file, root.ToJsonString()))

let load () =
  try
    if File.Exists file then
      for KeyValue(k, o) in (JsonNode.Parse(File.ReadAllText file)).AsObject() do
        store[k] <-
          { Stat = { Size = int64 o["size"]; Mtime = string o["mtime"] }
            Sha256 = string o["sha256"]
            Info = infoOfJson o["info"] }
  with _ ->
    ()

/// The cached reading, when the file is still the one it was read from.
let tryFresh machine name (stat: FileStat) =
  match store.TryGetValue(key machine name) with
  | true, e when e.Stat = stat -> Some e
  | _ -> None

/// A reading whatever its freshness (the master's hash, for a split file to compare with).
let tryAny machine name =
  match store.TryGetValue(key machine name) with
  | true, e -> Some e
  | _ -> None

let put machine name (e: Entry) =
  store[key machine name] <- e
  save ()

let count () = store.Count
