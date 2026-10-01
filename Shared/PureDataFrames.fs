/// The binary frames a pupitre's PureData (M645.pd, WebSocket 10002) sends, as the console
/// reads them (docs/CONTRAT_PARTAGE.md, § 3, console column). Little-endian unless noted.
///
/// A frame is recognised by its first byte **and its length**. Known fixed-size frames are
/// tried before the 8-byte header of a configuration chunk: puredata-proxy.js does the
/// reverse, and so takes most 10-byte POSITION frames for configuration chunks (measured: bar
/// 5 / 1 / 0 are swallowed, bar 120 gets through).
module Mecaviv.Shared.PureDataFrames

type PureDataFrame =
    /// Two zero bytes.
    | Heartbeat
    /// "SS" + 0x01, note, velocity, pitch bend (u16 **big-endian**, centre 8192). 7 bytes.
    | VolantState of note: int * velocity: int * pitchBend: int
    /// 0x01, 10 bytes: flags (bit 0 = playing), bar u16, beat in bar u16, beat f32.
    | Position of playing: bool * bar: int * beatInBar: int * beat: float
    /// 0x02, 10 bytes: duration u32 (ms), total beats u32.
    | FileInfo of durationMs: int64 * totalBeats: int64
    /// 0x03, 3 bytes: tempo u16 (BPM).
    | Tempo of bpm: int
    /// 0x04, 3 bytes: numerator, denominator.
    | TimeSignature of numerator: int * denominator: int
    /// 0x06, 6 or 8 bytes: flags, tick u32, optional ppq u16.
    | TickPosition of playing: bool * tick: int64 * ppq: int option
    /// A whole JSON text: raw (starting with '{'), or 0x02 followed by JSON (more than 100 bytes).
    | Json of text: string
    /// Part of a configuration sent in chunks: total size u32, position u32, then the bytes.
    | ConfigChunk of totalSize: int64 * position: int64 * data: byte[]
    | Unknown of byte[]

let private u16 (b: byte[]) i = int b.[i] ||| (int b.[i + 1] <<< 8)
let private u16be (b: byte[]) i = (int b.[i] <<< 8) ||| int b.[i + 1]

let private u32 (b: byte[]) i =
    int64 b.[i] ||| (int64 b.[i + 1] <<< 8) ||| (int64 b.[i + 2] <<< 16) ||| (int64 b.[i + 3] <<< 24)

/// IEEE 754 single precision, little-endian, decoded by hand (no BitConverter: Fable-safe).
let private f32 (b: byte[]) i =
    let bits = u32 b i
    let sign = if bits &&& 0x80000000L <> 0L then -1.0 else 1.0
    let exponent = int ((bits >>> 23) &&& 0xFFL)
    let mantissa = float (bits &&& 0x7FFFFFL)
    match exponent with
    | 0 -> sign * mantissa * (2.0 ** -149.0)
    | 255 -> if mantissa = 0.0 then sign * infinity else nan
    | e -> sign * (1.0 + mantissa / 8388608.0) * (2.0 ** float (e - 127))

let private utf8 (b: byte[]) (start: int) =
    System.Text.Encoding.UTF8.GetString(b, start, b.Length - start)

let private maxConfigSize = 10L * 1024L * 1024L

let decode (b: byte[]) : PureDataFrame =
    let len = b.Length
    if len = 0 then Unknown b
    elif len = 2 && b.[0] = 0uy && b.[1] = 0uy then Heartbeat
    elif len = 7 && b.[0] = 0x53uy && b.[1] = 0x53uy && b.[2] = 0x01uy then VolantState(int b.[3], int b.[4], u16be b 5)
    elif b.[0] = 0x7Buy then Json(utf8 b 0)
    else
        match b.[0], len with
        | 0x01uy, 10 -> Position(b.[1] &&& 1uy = 1uy, u16 b 2, u16 b 4, f32 b 6)
        | 0x02uy, 10 -> FileInfo(u32 b 2, u32 b 6)
        | 0x02uy, n when n > 100 && b.[1] = 0x7Buy -> Json(utf8 b 1)
        | 0x03uy, 3 -> Tempo(u16 b 1)
        | 0x04uy, 3 -> TimeSignature(int b.[1], int b.[2])
        | 0x06uy, (6 | 8) -> TickPosition(b.[1] &&& 1uy = 1uy, u32 b 2, (if len = 8 then Some(u16 b 6) else None))
        | _ when len >= 8 ->
            let total = u32 b 0
            let position = u32 b 4
            if total > 0L && total <= maxConfigSize && position < total then ConfigChunk(total, position, Array.sub b 8 (len - 8))
            else Unknown b
        | _ -> Unknown b
