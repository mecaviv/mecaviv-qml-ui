module SirenManager.Backend.UdpRelay

open System
open System.Collections.Generic
open System.IO
open System.Net
open System.Net.Sockets
open System.Net.WebSockets
open System.Text
open System.Text.Json
open System.Threading
open System.Threading.Tasks
open Mecaviv.Infrastructure.Logging

/// Binds UDP only while at least one WebSocket client is connected.
/// A desktop SirenManager already listens on this port; a second socket
/// would split firmware replies.
type Hub(port: int) =
  let gate = obj ()
  let clients = ResizeArray<WebSocket>()
  let mutable udp: UdpClient = null
  let mutable session: CancellationTokenSource = null

  let sendText (ws: WebSocket) (text: string) =
    let bytes = Encoding.UTF8.GetBytes text
    ws.SendAsync(ArraySegment bytes, WebSocketMessageType.Text, true, CancellationToken.None)

  let broadcast text =
    let snapshot = lock gate (fun () -> clients.ToArray())

    for ws in snapshot do
      if ws.State = WebSocketState.Open then
        sendText ws text
        |> fun send ->
          send.ContinueWith(
            Action<Task>(fun completed ->
              let ex = completed.Exception.GetBaseException()
              errorEx ex $"WebSocket broadcast failed: {ex.Message}"),
            TaskContinuationOptions.OnlyOnFaulted
          )
        |> ignore

  let startUdp () =
    session <- new CancellationTokenSource()
    let token = session.Token
    let client = new UdpClient(port)
    udp <- client
    info $"UDP socket bound to port {port} (WS client connected)"

    Task.Run(fun () ->
      task {
        try
          while not token.IsCancellationRequested do
            let! result = client.ReceiveAsync(token)

            let payload =
              JsonSerializer.Serialize
                {|
                  ``type`` = "udp_receive"
                  data = Convert.ToHexString(result.Buffer).ToLowerInvariant()
                  address = result.RemoteEndPoint.Address.ToString()
                  port = result.RemoteEndPoint.Port
                |}

            broadcast payload
        with
        | :? OperationCanceledException -> debug "UDP receive loop stopped"
        | :? ObjectDisposedException as ex -> debug $"UDP socket closed: {ex.Message}"
        | ex -> errorEx ex $"UDP socket error: {ex.Message}"
      }
      :> Task)
    |> ignore

  let stopUdp () =
    if not (isNull session) then
      session.Cancel()
      session.Dispose()
      session <- null

    if not (isNull udp) then
      udp.Dispose()
      udp <- null
      info "UDP socket released (no WS clients)"

  member _.Join ws =
    lock gate (fun () ->
      clients.Add ws

      if clients.Count = 1 then
        startUdp ())

    info $"WebSocket client connected (total {clients.Count})"

  member _.Leave ws =
    lock gate (fun () ->
      clients.Remove ws |> ignore

      if clients.Count = 0 then
        stopUdp ())

    info $"WebSocket client disconnected (remaining {clients.Count})"

  member _.TrySend(address, destPort, data) =
    let client = lock gate (fun () -> udp)

    if isNull client then
      Error "UDP socket not bound"
    else
      try
        client.Send(data, data.Length, address, destPort) |> ignore
        Ok()
      with ex ->
        Error ex.Message

let errorText message =
  JsonSerializer.Serialize
    {|
      ``type`` = "error"
      message = message
    |}

let handle (hub: Hub) (ws: WebSocket) =
  task {
    hub.Join ws

    try
      let buf = Array.zeroCreate 8192
      use ms = new MemoryStream()
      let mutable cont = true

      while cont && ws.State = WebSocketState.Open do
        ms.SetLength 0L
        let mutable finished = false
        let mutable closing = false

        while not finished && ws.State = WebSocketState.Open do
          let! result = ws.ReceiveAsync(ArraySegment buf, CancellationToken.None)

          if result.MessageType = WebSocketMessageType.Close then
            finished <- true
            closing <- true
            cont <- false
          else
            ms.Write(buf, 0, result.Count)
            finished <- result.EndOfMessage

        if not closing && ms.Length > 0L then
          let text = Encoding.UTF8.GetString(ms.ToArray())

          try
            use doc = JsonDocument.Parse(text)
            let root = doc.RootElement
            let mutable typeEl = Unchecked.defaultof<JsonElement>

            let typ =
              if root.TryGetProperty("type", &typeEl) && typeEl.ValueKind = JsonValueKind.String then
                typeEl.GetString()
              else
                ""

            if typ = "udp_send" then
              let address = root.GetProperty("address").GetString()
              let destPort = root.GetProperty("port").GetInt32()
              let hex = root.GetProperty("data").GetString()
              let packet = Convert.FromHexString(hex)

              match hub.TrySend(address, destPort, packet) with
              | Ok() -> ()
              | Error msg ->
                error $"UDP send error: {msg}"

                do!
                  ws.SendAsync(
                    ArraySegment(Encoding.UTF8.GetBytes(errorText msg)),
                    WebSocketMessageType.Text,
                    true,
                    CancellationToken.None
                  )
          with ex ->
            errorEx ex $"WebSocket message error: {ex.Message}"

            do!
              ws.SendAsync(
                ArraySegment(Encoding.UTF8.GetBytes(errorText ex.Message)),
                WebSocketMessageType.Text,
                true,
                CancellationToken.None
              )

      if ws.State = WebSocketState.Open || ws.State = WebSocketState.CloseReceived then
        do! ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "", CancellationToken.None)
    finally
      hub.Leave ws
  }
