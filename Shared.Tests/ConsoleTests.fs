module Mecaviv.Shared.Tests.ConsoleTests

open Expecto
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Shared.Values
open Mecaviv.Shared.Console

/// A JSON text as a value with sorted object fields: two texts are "the same message" when
/// these are equal (field order and 120 vs 120.0 don't matter).
let rec private canonical (v: JsonValue) =
  match v with
  | JObject fields -> fields |> List.map (fun (k, x) -> k, canonical x) |> List.sortBy fst |> JObject
  | JArray items -> items |> List.map canonical |> JArray
  | other -> other

let private parse text =
  match Decode.fromString (JsonValue.decoder ()) text with
  | Ok v -> canonical v
  | Error e -> failwith e

let private roundTrip name (decoder: Decoder<'a>) (encode: 'a -> IEncodable) (text: string) =
  test name {
    let decoded =
      match Decode.fromString decoder text with
      | Ok d -> d
      | Error e -> failtest e

    let again = Encode.toString 0 (encode decoded)
    Expect.equal (parse again) (parse text) "re-encoded as the original"
  }

// Messages as the current code builds them (file noted for each).

let requests =
  testList
    "ConsoleRequest, as the QML UI sends them"
    [
      // CommandManager.qml
      roundTrip
        "MIDI_TRANSPORT"
        ConsoleRequest.decoder
        ConsoleRequest.encode
        """{"type":"MIDI_TRANSPORT","action":"play"}"""
      roundTrip
        "MIDI_FILE_LOAD"
        ConsoleRequest.decoder
        ConsoleRequest.encode
        """{"type":"MIDI_FILE_LOAD","path":"louette/ouies.midi"}"""
      roundTrip "MIDI_SEEK" ConsoleRequest.decoder ConsoleRequest.encode """{"type":"MIDI_SEEK","position":12500}"""
      roundTrip
        "TEMPO_CHANGE"
        ConsoleRequest.decoder
        ConsoleRequest.encode
        """{"type":"TEMPO_CHANGE","tempo":96,"smooth":true}"""
      roundTrip
        "UI_CONTROLS"
        ConsoleRequest.decoder
        ConsoleRequest.encode
        """{"type":"UI_CONTROLS","pupitreId":"P2","enabled":false}"""
      roundTrip
        "AUTONOMY_MODE"
        ConsoleRequest.decoder
        ConsoleRequest.encode
        """{"type":"AUTONOMY_MODE","pupitreId":"P4","device":"pad","enabled":true,"source":"console"}"""
      // WebSocketManager.qml
      roundTrip
        "SIRENCONSOLE_IDENTIFICATION"
        ConsoleRequest.decoder
        ConsoleRequest.encode
        """{"type":"SIRENCONSOLE_IDENTIFICATION","source":"SirenConsole","timestamp":1790885723748}"""
      roundTrip
        "PING"
        ConsoleRequest.decoder
        ConsoleRequest.encode
        """{"type":"PING","source":"SirenConsole","timestamp":1790885723748}"""
      test "UI_CONTROLS without enabled means enabled (server.js)" {
        Expect.equal
          (Decode.fromString ConsoleRequest.decoder """{"type":"UI_CONTROLS","pupitreId":"P1"}""")
          (Ok(UiControls("P1", true)))
          ""
      }
      test "an unknown action is an error, not a default" {
        Expect.isError (Decode.fromString ConsoleRequest.decoder """{"type":"MIDI_TRANSPORT","action":"rewind"}""") ""
      }
    ]

let events =
  testList
    "ConsoleEvent, as the server sends them"
    [
      // produced by puredata-proxy.js broadcastVolantData (measured)
      roundTrip
        "VOLANT_DATA"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"VOLANT_DATA","pupitreId":"P3","noteFloat":60.5,"velocity":100,"frequency":523,"rpm":3924,"timestamp":1790885723748}"""
      // server.js + puredata-proxy.js getStatus
      roundTrip
        "INITIAL_STATUS"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"INITIAL_STATUS","data":{"totalConnections":2,"connectedCount":1,"connections":[
                {"pupitreId":"P1","pupitreName":"Pupitre 1","connected":true,"url":"ws://192.168.1.41:10002","lastSeen":"2026-10-01T21:55:34.202Z"},
                {"pupitreId":"P2","pupitreName":"Pupitre 2","connected":false,"url":"ws://localhost:10002","lastSeen":null}]}}"""
      // server.js adds isSynced / lastSync to each connection every second
      roundTrip
        "PUPITRE_STATUS_UPDATE with sync"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"PUPITRE_STATUS_UPDATE","timestamp":1790885723748,"data":{"totalConnections":1,"connectedCount":1,"connections":[
                {"pupitreId":"P1","pupitreName":"Pupitre 1","connected":true,"url":"ws://192.168.1.41:10002","lastSeen":"2026-10-01T21:55:34.202Z","isSynced":true,"lastSync":1790885720000}]}}"""
      // measured: server.js with a real pupitre (M645.pd) connected as P2
      roundTrip
        "INITIAL_STATUS, a real connected pupitre"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"INITIAL_STATUS","data":{"totalConnections":1,"connectedCount":1,"connections":[
                {"pupitreId":"P2","pupitreName":"Pupitre 2","connected":true,"url":"ws://localhost:10002","lastSeen":"2026-10-01T21:55:34.202Z","isSynced":true,"lastSync":1790891737315}]}}"""
      roundTrip
        "PUPITRE_CONNECTED"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"PUPITRE_CONNECTED","pupitreId":"P1","pupitreName":"Pupitre 1","connected":true,"timestamp":1790885723748}"""
      roundTrip
        "SYNC_STATUS_CHANGED"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"SYNC_STATUS_CHANGED","pupitreId":"P1","isSynced":true,"timestamp":1790885723748}"""
      roundTrip
        "PRESET_UPDATED_FROM_PUPITRE, one parameter"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"PRESET_UPDATED_FROM_PUPITRE","pupitreId":"P1","path":["sirenConfig","sirens",0,"ambitus","max"],"value":84,"timestamp":1790885723748}"""
      roundTrip
        "PRESET_UPDATED_FROM_PUPITRE, whole configuration"
        ConsoleEvent.decoder
        ConsoleEvent.encode
        """{"type":"PRESET_UPDATED_FROM_PUPITRE","pupitreId":"P1","configUpdated":true,"timestamp":1790885723748}"""
      test "VOLANT_DATA without noteFloat is refused, as the QML UI ignores it" {
        Expect.isError
          (Decode.fromString ConsoleEvent.decoder """{"type":"VOLANT_DATA","pupitreId":3,"note":60,"pitchbend":8192}""")
          ""
      }
    ]

let pupitre =
  testList
    "PupitreMessage, server ↔ pupitre"
    [
      // server.js relays UI_CONTROLS as this
      roundTrip
        "PARAM_UPDATE uiControls"
        PupitreMessage.decoder
        PupitreMessage.encode
        """{"type":"PARAM_UPDATE","path":["uiControls","enabled"],"value":0,"source":"console"}"""
      // WebSocketController.qml (SirenePupitre): path with a numeric index
      roundTrip
        "PARAM_UPDATE frettedMode"
        PupitreMessage.decoder
        PupitreMessage.encode
        """{"type":"PARAM_UPDATE","path":["sirenConfig","sirens",2,"frettedMode","enabled"],"value":true,"source":"console"}"""
      roundTrip
        "PARAM_CHANGED color"
        PupitreMessage.decoder
        PupitreMessage.encode
        """{"type":"PARAM_CHANGED","path":["displayConfig","components","cursor","color"],"value":"#ff6b6b","source":"pupitre"}"""
      roundTrip
        "REQUEST_CONFIG"
        PupitreMessage.decoder
        PupitreMessage.encode
        """{"type":"REQUEST_CONFIG","pupitreId":"P1","source":"console"}"""
      roundTrip
        "CONSOLE_CONNECT"
        PupitreMessage.decoder
        PupitreMessage.encode
        """{"type":"CONSOLE_CONNECT","source":"console"}"""
      roundTrip
        "GAME_MODE"
        PupitreMessage.decoder
        PupitreMessage.encode
        """{"type":"GAME_MODE","enabled":true,"source":"console"}"""
      test "a path keeps keys and indexes apart" {
        match
          Decode.fromString PupitreMessage.decoder """{"type":"PARAM_UPDATE","path":["sirens",2,"name"],"value":"S3"}"""
        with
        | Ok(ParamUpdate(path, JString "S3", None)) -> Expect.equal path [ Key "sirens"; Index 2; Key "name" ] ""
        | other -> failtest $"%A{other}"
      }
    ]

let tests = testList "Console" [ requests; events; pupitre ]
