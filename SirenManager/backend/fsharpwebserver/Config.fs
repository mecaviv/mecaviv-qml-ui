module SirenManager.Backend.Config

open System
open System.IO
open FSharp.Data

type Machine =
  {
    Alias: string
    User: string
    Ip: string
    MidiPath: string
    PlaylistPath: string
  }

type AppConfig =
  {
    HttpPort: int
    WsPort: int
    UdpPort: int
    LogLevel: string
    Machines: Map<string, Machine>
  }

/// Same allow-list as ssh-proxy.js getMachineConfig. Other keys in
/// config.json are ignored even when present.
let sshMachines =
  set
    [
      "linuxMaitre"
      "raspberryClic"
      "s1"
      "s2"
      "s3"
      "s4"
      "s5"
      "s6"
      "s7"
      "voitureA"
      "voitureB"
      "pavillon1"
      "pavillon2"
    ]

type ConfigJson = JsonProvider<const (__SOURCE_DIRECTORY__ + "/../config.json")>

/// Machines are one JSON object, and the entries do not share a shape
/// (a pupitre has no sshAlias; only the Raspberry has midiPath). The sample
/// list is the fields this process reads. Absent fields are optional.
type MachineJson =
  JsonProvider<"""
[
  {
    "ip": "192.168.1.101",
    "sshUser": "root",
    "sshAlias": "linux-maître",
    "midiPath": "/midi/",
    "playlistPath": "/playlists/"
  },
  {}
]
""", SampleIsList = true>

let machine (value: JsonValue) =
  let parsed = MachineJson.Parse(value.ToString())

  {
    Alias = defaultArg parsed.SshAlias ""
    User = defaultArg parsed.SshUser ""
    Ip = defaultArg parsed.Ip ""
    MidiPath = defaultArg parsed.MidiPath ""
    PlaylistPath = defaultArg parsed.PlaylistPath ""
  }

let load () =
  let besideExe = Path.Combine(AppContext.BaseDirectory, "config.json")
  let dev = Path.GetFullPath(Path.Combine(__SOURCE_DIRECTORY__, "..", "config.json"))

  let path =
    if File.Exists besideExe then
      besideExe
    elif File.Exists dev then
      dev
    else
      failwith $"config.json not found next to the executable or at {dev}"

  let parsed = ConfigJson.Load path

  let machines =
    parsed.Machines.JsonValue.Properties()
    |> Array.map (fun (name, value) -> name, machine value)
    |> Map.ofArray

  let logLevel =
    match parsed.JsonValue.TryGetProperty "logLevel" with
    | Some (JsonValue.String level) when not (String.IsNullOrWhiteSpace level) -> level
    | _ -> "Debug"

  {
    HttpPort = parsed.Ports.Http
    WsPort = parsed.Ports.Websocket
    UdpPort = parsed.Ports.Udp
    LogLevel = logLevel
    Machines = machines
  }
