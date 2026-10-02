module Mecaviv.Shared.Tests.PureDataFramesTests

open Expecto
open Mecaviv.Shared.PureDataFrames

/// A POSITION frame as M645.pd sends it: 0x01, flags, bar u16, beat in bar u16, beat f32 (LE).
let private position (playing: bool) (bar: int) (beatInBar: int) (beat: float32) =
  Array.concat
    [
      [| 0x01uy; (if playing then 1uy else 0uy) |]
      [| byte bar; byte (bar >>> 8); byte beatInBar; byte (beatInBar >>> 8) |]
      System.BitConverter.GetBytes beat
    ]

let tests =
  testList
    "PureData frames (console)"
    [
      test "POSITION frames that puredata-proxy.js takes for configuration chunks" {
        // Measured on the JS proxy: these three are swallowed as chunks there.
        for bar, beatInBar, beat in [ 5, 2, 18.0f; 1, 1, 0.0f; 0, 0, 0.0f; 120, 4, 479.0f ] do
          Expect.equal
            (decode (position true bar beatInBar beat))
            (Position(true, bar, beatInBar, float beat))
            $"bar {bar}"
      }
      test "a configuration chunk is still a chunk" {
        let json =
          System.Text.Encoding.UTF8.GetBytes """{"type":"CONFIG_FULL","config":{}}"""

        let total = json.Length

        let header =
          Array.concat [ System.BitConverter.GetBytes(uint32 total); System.BitConverter.GetBytes 0u ]

        match decode (Array.append header json) with
        | ConfigChunk(t, 0, data) -> Expect.equal (t, data) (total, json) ""
        | other -> failtest $"%A{other}"
      }
      test "the wheel: SS, pitch bend big-endian" {
        Expect.equal
          (decode [| 0x53uy; 0x53uy; 0x01uy; 60uy; 100uy; 0x30uy; 0x00uy |])
          (VolantState(60, 100, 0x3000))
          ""
      }
      test "short frames by code and length" {
        Expect.equal (decode [| 0x03uy; 96uy; 0uy |]) (Tempo 96) "tempo"
        Expect.equal (decode [| 0x04uy; 6uy; 8uy |]) (TimeSignature(6, 8)) "time signature"
        Expect.equal (decode [| 0x06uy; 1uy; 0x10uy; 0x27uy; 0uy; 0uy |]) (TickPosition(true, 10000.0, None)) "ticks"

        Expect.equal
          (decode [| 0x06uy; 0uy; 0x10uy; 0x27uy; 0uy; 0uy; 0xE0uy; 0x01uy |])
          (TickPosition(false, 10000.0, Some 480))
          "ticks + ppq"

        Expect.equal
          (decode [| 0x02uy; 0uy; 0x10uy; 0x27uy; 0uy; 0uy; 64uy; 0uy; 0uy; 0uy |])
          (FileInfo(10000.0, 64.0))
          "file info"

        Expect.equal (decode [| 0uy; 0uy |]) Heartbeat "heartbeat"
      }
      test "the pupitre's 5-byte 0x04 (note + duration) is not a time signature" {
        Expect.equal
          (decode [| 0x04uy; 60uy; 100uy; 0xF4uy; 0x01uy |])
          (Unknown [| 0x04uy; 60uy; 100uy; 0xF4uy; 0x01uy |])
          ""
      }
      test "JSON, raw or after 0x02" {
        Expect.equal (decode (System.Text.Encoding.UTF8.GetBytes """{"a":"é"}""")) (Json """{"a":"é"}""") "raw, UTF-8"

        let long =
          """{"type":"CONFIG_FULL","config":{"x":""" + String.replicate 100 "1" + "}}"

        Expect.equal
          (decode (Array.append [| 0x02uy |] (System.Text.Encoding.UTF8.GetBytes long)))
          (Json long)
          "0x02 + JSON"
      }
    ]
