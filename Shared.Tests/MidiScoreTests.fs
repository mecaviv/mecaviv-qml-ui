/// The MIDI score against PureData: the note times read by MidiScore are those at which
/// M645.pd's [midifile] actually played them (fixtures/pd-pink-panther-noteons.json, measured).
/// Synthetic files cover what that piece does not: x/8 signatures, running status, tempo changes.
module Mecaviv.Shared.Tests.MidiScoreTests

open System
open System.IO
open Expecto
open Thoth.Json.Core
open Mecaviv.Shared.MidiScore
open Mecaviv.Shared.Tests.TestJson

/// A format-1 file with the given tracks (each already a list of delta-timed event bytes).
let private midi (ppq: int) (tracks: byte list list) =
  let be32 (n: int) =
    [ byte (n >>> 24); byte (n >>> 16); byte (n >>> 8); byte n ]

  let be16 (n: int) = [ byte (n >>> 8); byte n ]

  [
    yield! "MThd"B
    yield! be32 6
    yield! be16 1
    yield! be16 tracks.Length
    yield! be16 ppq
    for t in tracks do
      let body = t @ [ 0uy; 0xFFuy; 0x2Fuy; 0uy ]
      yield! "MTrk"B
      yield! be32 body.Length
      yield! body
  ]
  |> Array.ofList

let private tempo (us: int) =
  [ 0xFFuy; 0x51uy; 3uy; byte (us >>> 16); byte (us >>> 8); byte us ]

/// Variable-length delta time.
let rec private delta (n: int) =
  if n < 0x80 then
    [ byte n ]
  else
    let rec groups v acc =
      if v = 0 then
        acc
      else
        groups (v >>> 7) (byte (v &&& 0x7F) :: acc)

    let g = groups n []

    (g |> List.take (g.Length - 1) |> List.map (fun b -> b ||| 0x80uy))
    @ [ List.last g ]

let private readOrFail bytes =
  match read bytes with
  | Ok s -> s
  | Error e -> failtest e

let private compositions () =
  match Environment.GetEnvironmentVariable "MECAVIV_COMPOSITIONS_PATH" with
  | null
  | "" -> Path.Combine(__SOURCE_DIRECTORY__, "..", "..", "compositions")
  | p -> p

let tests =
  testList
    "MIDI score"
    [
      test "tempo change: ms follow the tempo map, and back" {
        // 120 BPM for one quarter note, then 60 BPM
        let score =
          readOrFail (
            midi
              480
              [
                [
                  yield! 0uy :: tempo 500000
                  yield! delta 480 @ tempo 1000000
                  yield! [ 0uy; 0x90uy; 60uy; 100uy ]
                  yield! delta 480 @ [ 0x80uy; 60uy; 0uy ]
                ]
              ]
          )

        let n = score.Notes |> List.exactlyOne
        Expect.equal n.Ms 500.0 "the note starts after one quarter at 120 BPM"
        Expect.equal n.DurationMs 1000.0 "and lasts one quarter at 60 BPM"
        Expect.equal (tickOfMs score.Ppq score.Tempos 1000.0) 720.0 "500 ms into the 60 BPM part"
        Expect.equal score.DurationMs 1500.0 ""
      }

      test "running status and note-on velocity 0 as note-off" {
        let score =
          readOrFail (
            midi
              96
              [
                [
                  yield! [ 0uy; 0x91uy; 60uy; 90uy ]
                  yield! [ 0uy; 64uy; 80uy ] // running status: another note-on
                  yield! delta 96 @ [ 60uy; 0uy ] // note-on velocity 0 = off
                  yield! delta 96 @ [ 64uy; 0uy ]
                ]
              ]
          )

        let notes =
          score.Notes |> List.map (fun n -> n.Note, n.Channel, n.Velocity, n.DurationMs)

        Expect.equal notes [ 60, 2, 90, 500.0; 64, 2, 80, 1000.0 ] "channels 1-16, as Pd numbers them"
      }

      test "6/8: the beat is the eighth note, and a mid-file change starts a new bar" {
        let timeSig n d =
          [ 0xFFuy; 0x58uy; 4uy; byte n; byte d; 24uy; 8uy ]

        let score =
          readOrFail (
            midi
              480
              [
                [
                  yield! 0uy :: timeSig 6 3
                  // two bars of 6/8 (6 × 240 ticks each), then 4/4
                  yield! delta 2880 @ timeSig 4 2
                ]
              ]
          )

        let at = barBeatOfTick score.Ppq score.Signatures
        Expect.equal (at 0L) (1, 1) ""
        Expect.equal (at 240L) (1, 2) "an eighth note is a beat in 6/8"
        Expect.equal (at 1440L) (2, 1) ""
        Expect.equal (at 2880L) (3, 1) "4/4 from bar 3"
        Expect.equal (at (2880L + 480L)) (3, 2) ""
      }

      test "not a MIDI file" { Expect.isError (read "nope, not MIDI"B) "" }

      test "Pink Panther: every note-on at the time M645.pd's [midifile] played it" {
        let path = Path.Combine(compositions (), "covers", "midi", "Pink_Panther.midi")

        if not (File.Exists path) then
          skiptest $"{path} not found (set MECAVIV_COMPOSITIONS_PATH)"

        let measured =
          decodeOrFail
            (Decode.field "noteOns" (Decode.list (Decode.list Decode.float)))
            (fixture "pd-pink-panther-noteons.json")
          |> List.map (fun l -> l.[0], int l.[1], int l.[2], int l.[3])

        // The capture stopped in the middle of the last chord: leave that chord out on both
        // sides (Pd plays about 20 ms ahead of the file's times once started).
        let last = measured |> List.map (fun (t, _, _, _) -> t) |> List.max
        let measured = measured |> List.filter (fun (t, _, _, _) -> t < last)

        let score = readOrFail (File.ReadAllBytes path)

        let ours =
          score.Notes
          |> List.filter (fun n -> n.Ms < last + 10.0)
          |> List.map (fun n -> n.Ms, n.Note, n.Velocity, n.Channel)

        let key (_, n, v, c) = n, v, c
        // by note, then time: Pd's start latency reorders notes a few ms apart
        let order (t, n, v, c) = n, v, c, t

        Expect.equal
          (ours |> List.sortBy order |> List.map key)
          (measured |> List.sortBy order |> List.map key)
          "same notes, velocities and channels"

        // Pd sends the notes of the first tick about 20 ms late, then keeps time: compare the
        // others, after removing that constant start latency.
        let offsets =
          List.zip (measured |> List.sortBy order) (ours |> List.sortBy order)
          |> List.filter (fun ((t, _, _, _), _) -> t > 100.0)
          |> List.map (fun ((t, _, _, _), (ms, _, _, _)) -> t - ms)

        let median = (List.sort offsets).[offsets.Length / 2]

        for o in offsets do
          Expect.isLessThanOrEqual (abs (o - median)) 2.0 "within 2 ms of Pd's own timing, over 10 s"
      }
    ]
