module Mecaviv.Shared.Tests.Program

open Expecto

[<EntryPoint>]
let main argv =
    runTestsWithCLIArgs [] argv (testList "Shared" [ JsonTests.tests ])
