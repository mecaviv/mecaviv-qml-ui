module Mecaviv.Shared.Tests.JsonTests

open Expecto
open Thoth.Json.Core
open Thoth.Json.Newtonsoft
open Mecaviv.Shared

let tests =
    testList "Json" [
        test "tagged accepts its value and rejects another" {
            let d = Json.tagged "type" "PING" (Decode.succeed ())
            Expect.isOk (Decode.fromString d """{"type":"PING"}""") "PING"
            Expect.isError (Decode.fromString d """{"type":"PONG"}""") "PONG"
        }
    ]
