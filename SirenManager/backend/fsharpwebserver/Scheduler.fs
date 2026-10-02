/// One mailbox serialises every conversation with the boards: a machine has at
/// most one ssh request in flight, the others wait in its queue (the Artila
/// is slow enough that two concurrent sessions make each other slower). The
/// same loop times every request, keeps statistics per (machine, kind), logs a
/// summary every minute, and throttles polls of a kind whose recent runtime has
/// been poor or whose board reports a high CPU load.
module SirenManager.Backend.Scheduler

open System
open System.Collections.Generic
open System.Diagnostics
open System.Threading
open System.Threading.Tasks
open SirenManager.Backend.Protocol
open Mecaviv.Infrastructure.Logging

type Outcome =
  | Output of string
  | Failed of string
  | Throttled of retryAfterMs: int
  /// A quiet request to a board that just failed to answer: not tried again for a while.
  | Unreachable of string

/// Runs one shell command on a machine. Errors come back as Error, not as exceptions.
type Runner = bool -> string -> string -> CancellationToken -> Task<Result<string, string>>   // quiet, machine, command, deadline

/// ssh could not reach the board (as opposed to the command failing on it).
let isUnreachable (error: string) =
  [ "connect to host"; "timed out"; "No route"; "refused"; "Could not resolve"; "unreachable" ]
  |> List.exists (fun k -> error.Contains(k, StringComparison.OrdinalIgnoreCase))

type KindStats =
  { Count: int
    Errors: int
    Throttled: int
    TotalMs: float
    MaxMs: float
    LastMs: float
    EwmaMs: float }

let emptyStats =
  { Count = 0; Errors = 0; Throttled = 0; TotalMs = 0.0; MaxMs = 0.0; LastMs = 0.0; EwmaMs = 0.0 }

type StatRow =
  { Machine: string
    Kind: Kind
    Stats: KindStats
    BusyPct: float option }

/// How the throttle reads the past, and how long a request may take. Tuned for 2-3 s polls over ssh.
type Policy =
  { /// A kind slower than this (smoothed) is held back ...
    SlowMs: float
    /// ... to one request every `SlowFactor` x its smoothed runtime.
    SlowFactor: float
    /// A board busier than this (percent) is polled at most every `BusyGapMs`.
    BusyPct: float
    BusyGapMs: float
    /// How long a request of this kind may run before we stop waiting for it.
    ///
    /// Why a request needs a deadline at all: a command on a board can simply never come back. The
    /// usual cause is `df`: it asks every mounted filesystem for its size, and if one of them is a
    /// network share whose server stopped answering (the Mac's NFS share on the development
    /// bench), `df` sits there until the share is back, and so does anything else that reads the
    /// mount table. We only send one request at a time to a board, so everything queued behind a
    /// request that never ends would wait for it for ever, and the whole tab would look frozen.
    /// With a deadline the stuck request is answered with "timeout", the next ones go ahead, and
    /// what was only trying to read the disk size shows an error instead of freezing the app.
    ///
    /// The deadline is short for what should be quick (a poll, a size read), longer for what is
    /// slow by nature (the disk scan, a listing), and long for anything we cannot classify.
    TimeoutMs: Kind -> int
    ReportEveryMs: int }

let defaultPolicy =
  { SlowMs = 1500.0
    SlowFactor = 1.5
    BusyPct = 85.0
    BusyGapMs = 6000.0
    TimeoutMs =
      function
      | KSystem -> 10_000
      | KCpu | KDmesg -> 15_000
      | KDisk | KListing | KOwners -> 25_000
      | KRaw -> 60_000
    ReportEveryMs = 60000 }

type private Msg =
  | Submit of machine: string * Request * quiet: bool * AsyncReplyChannel<Outcome>
  | Finished of machine: string * Request * quiet: bool * AsyncReplyChannel<Outcome> * ms: float * Result<string, string>
  | Snapshot of AsyncReplyChannel<StatRow list>
  | Report

type private Machine =
  { Queue: Queue<Request * bool * AsyncReplyChannel<Outcome>>
    mutable DownUntil: DateTime
    mutable DownReason: string
    mutable InFlight: bool
    mutable Cpu: CpuTimes option
    mutable BusyPct: float option
    Started: Dictionary<Kind, DateTime>
    /// Kinds whose last request ran into its deadline: not asked again for a while (see `blockFor`).
    Blocked: Dictionary<Kind, DateTime> }

type Scheduler =
  { Submit: string -> Request -> Task<Outcome>
    /// For batches: no per-command logging, and boards just found unreachable are skipped.
    SubmitQuiet: string -> Request -> Task<Outcome>
    Stats: unit -> Task<StatRow list> }

let private record (st: KindStats) ms ok =
  { st with
      Count = st.Count + 1
      Errors = st.Errors + (if ok then 0 else 1)
      TotalMs = st.TotalMs + ms
      MaxMs = max st.MaxMs ms
      LastMs = ms
      EwmaMs = if st.Count = 0 then ms else 0.7 * st.EwmaMs + 0.3 * ms }

/// The requests that read the mount table (`df`) are the ones a stalled network share blocks, and
/// every one that times out leaves a process stuck on the board for good. After one times out, the
/// same kind is not sent again for this long: it is answered at once with an explanation, so the
/// board is not buried under stuck processes (until sshd stops answering), and the app does not wait
/// ten seconds each time.
let blockFor = TimeSpan.FromMinutes 5.0

let private readsMounts kind = kind = KSystem || kind = KDisk

let start (policy: Policy) (run: Runner) : Scheduler =
  let agent =
    MailboxProcessor.Start(fun inbox ->
      let machines = Dictionary<string, Machine>()
      let stats = Dictionary<string * Kind, KindStats>()

      let machineOf name =
        match machines.TryGetValue name with
        | true, m -> m
        | _ ->
          let m = { Queue = Queue(); DownUntil = DateTime.MinValue; DownReason = ""; InFlight = false; Cpu = None; BusyPct = None; Started = Dictionary(); Blocked = Dictionary() }
          machines[name] <- m
          m

      let statsOf name kind =
        match stats.TryGetValue((name, kind)) with
        | true, s -> s
        | _ -> emptyStats

      /// Why a poll should wait, if it should: how long until it may go.
      let holdBack name (m: Machine) kind =
        let st = statsOf name kind
        let slow = if st.EwmaMs > policy.SlowMs then st.EwmaMs * policy.SlowFactor else 0.0
        let busy = match m.BusyPct with Some p when p >= policy.BusyPct -> policy.BusyGapMs | _ -> 0.0
        let gap = max slow busy

        match m.Started.TryGetValue kind with
        | true, last when gap > 0.0 ->
          let wait = gap - (DateTime.UtcNow - last).TotalMilliseconds
          if wait > 0.0 then Some(int wait) else None
        | _ -> None

      let pump name (m: Machine) =
        if not m.InFlight && m.Queue.Count > 0 then
          let request, quiet, reply = m.Queue.Dequeue()
          m.InFlight <- true
          m.Started[kindOf request] <- DateTime.UtcNow

          let work =
            task {
              let sw = Stopwatch.StartNew()
              use deadline = new CancellationTokenSource()
              let job = run quiet name (command request) deadline.Token
              let! winner = Task.WhenAny(job :> Task, Task.Delay(policy.TimeoutMs(kindOf request)))

              let! result =
                task {
                  if obj.ReferenceEquals(winner, job) then
                    return! job
                  else
                    // Stop waiting, and stop the local ssh; the queue moves on. (What runs on the board
                    // cannot be stopped from here: a stuck `df` stays stuck there.)
                    deadline.Cancel()
                    return Error $"timeout after {policy.TimeoutMs(kindOf request)} ms"
                }

              inbox.Post(Finished(name, request, quiet, reply, sw.Elapsed.TotalMilliseconds, result))
            }

          work |> ignore

      /// A block per machine, a line per kind; slow averages and busy boards in color.
      let report () =
        for KeyValue(name, m) in machines do
          let rows =
            [ for KeyValue((n, kind), st) in stats do
                if n = name then
                  let avg = if st.Count > 0 then st.TotalMs / float st.Count else 0.0
                  let avgText = duration (int64 avg)
                  let errs = if st.Errors > 0 then red (string st.Errors) else dim "0"
                  let thr = if st.Throttled > 0 then yellow (string st.Throttled) else dim "0"
                  yield
                    $"  {cyan ((kindName kind).PadRight 8)} n={st.Count,-5} avg={avgText} ewma={duration (int64 st.EwmaMs)} "
                    + $"max={duration (int64 st.MaxMs)} err={errs} throttled={thr}" ]

          if not rows.IsEmpty then
            let busy =
              match m.BusyPct with
              | Some p when p >= policy.BusyPct -> "  " + red $"cpu {p:F0}%%"
              | Some p -> "  " + green $"cpu {p:F0}%%"
              | None -> ""

            info (bold $"ssh {name}" + busy + "\n" + String.Join("\n", rows))

      let rec loop () =
        async {
          let! msg = inbox.Receive()

          match msg with
          | Submit(name, request, quiet, reply) ->
            let m = machineOf name
            let kind = kindOf request

            let hold =
              if isPoll kind then
                // One poll of a kind at a time: an older one still waiting is as good as a new one.
                if m.Queue |> Seq.exists (fun (r, _, _) -> kindOf r = kind) then Some 0 else holdBack name m kind
              else
                None

            let blockedUntil = match m.Blocked.TryGetValue kind with | true, t -> t | _ -> DateTime.MinValue

            match hold with
            | None when readsMounts kind && DateTime.UtcNow < blockedUntil ->
              let secs = int (blockedUntil - DateTime.UtcNow).TotalSeconds
              reply.Reply(Failed $"df ne répond pas (partage réseau bloqué ?) : pas de nouvel essai avant {secs} s")
            | None when quiet && DateTime.UtcNow < m.DownUntil -> reply.Reply(Unreachable m.DownReason)
            | Some ms ->
              stats[(name, kind)] <- { statsOf name kind with Throttled = (statsOf name kind).Throttled + 1 }
              reply.Reply(Throttled ms)
            | None ->
              m.Queue.Enqueue((request, quiet, reply))
              pump name m

          | Finished(name, request, quiet, reply, ms, result) ->
            let m = machineOf name
            let kind = kindOf request
            m.InFlight <- false
            stats[(name, kind)] <- record (statsOf name kind) ms (Result.isOk result)

            match result with
            | Ok output ->
              if kind = KCpu then
                match parseCpu output with
                | Ok s ->
                  m.BusyPct <- m.Cpu |> Option.bind (fun prev -> cpuBusyPct prev s.Times)
                  m.Cpu <- Some s.Times
                | Error _ -> ()

              reply.Reply(Output output)
            | Error e ->
              if readsMounts kind && e.StartsWith "timeout" then m.Blocked[kind] <- DateTime.UtcNow + blockFor

              if isUnreachable e then
                m.DownUntil <- DateTime.UtcNow.AddSeconds 20.0
                m.DownReason <- e

              reply.Reply(Failed e)

            pump name m

          | Snapshot reply ->
            reply.Reply
              [ for KeyValue((name, kind), st) in stats ->
                  { Machine = name; Kind = kind; Stats = st; BusyPct = (machineOf name).BusyPct } ]

          | Report -> report ()

          return! loop ()
        }

      loop ())

  let timer = new Timer((fun _ -> agent.Post Report), null, policy.ReportEveryMs, policy.ReportEveryMs)
  GC.KeepAlive timer

  let submit quiet machine request =
    agent.PostAndAsyncReply(fun ch -> Submit(machine, request, quiet, ch)) |> Async.StartAsTask

  { Submit = submit false
    SubmitQuiet = submit true
    Stats = fun () -> agent.PostAndAsyncReply Snapshot |> Async.StartAsTask }
