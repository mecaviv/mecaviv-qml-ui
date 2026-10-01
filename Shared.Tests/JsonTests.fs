module Mecaviv.Shared.Tests.JsonTests

open Expecto
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Shared
open Mecaviv.Shared.Values

let tests =
    testList "Json" [
        test "tagged accepts its value and rejects another" {
            let d = Json.tagged "type" "PING" (Decode.succeed ())
            Expect.isOk (Decode.fromString d """{"type":"PING"}""") "PING"
            Expect.isError (Decode.fromString d """{"type":"PONG"}""") "PONG"
        }
        test "integers are written as integers, as JavaScript does" {
            let text v = Encode.toString 0 (JsonValue.encode v)
            Expect.equal (List.map text [ JNumber 1.0; JNumber -3.0; JNumber 0.5 ]) [ "1"; "-3"; "0.5" ] ""
        }
    ]
