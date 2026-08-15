using System.Net.WebSockets;
using System.Text.Json;
using KcdMp.MasterServer.Features.Registry;

namespace KcdMp.MasterServer.Features.Announce;

/// <summary>
/// The relay's end of the master server: one WebSocket, held open for exactly
/// as long as the server is up.
///
/// The connection *is* the listing. A relay announces itself when the socket
/// opens, pushes an update whenever its player count or map changes, and is
/// delisted the moment the socket closes -- including when it closes because
/// the relay died, since a dropped TCP connection is noticed by the operating
/// system without either program having to say anything.
///
/// That is the whole reason this is not a POST. Registration-by-heartbeat
/// cannot tell "stopped" from "slow": the old service kept a crashed server in
/// the browser for five minutes because nothing could report its own death,
/// and a player who picked it in that window simply got no connection.
/// <see cref="MasterApi.TimeoutSeconds"/> still exists, but only for the case
/// a close never arrives at all -- a half-open socket after a router reboot,
/// say -- rather than as the primary way liveness is judged.
/// </summary>
internal static class ServerConnectionEndpoint
{
	/// <summary>How long a relay has to send its announce after connecting.</summary>
	private static readonly TimeSpan AnnounceTimeout = TimeSpan.FromSeconds(30);

	public static void MapServerConnection(this WebApplication app) =>
		app.Map(MasterApi.ConnectPath, HandleAsync);

	private static async Task HandleAsync(HttpContext context, ServerRegistry registry, ILoggerFactory loggerFactory)
	{
		var log = loggerFactory.CreateLogger("KcdMp.MasterServer.ServerConnection");

		if (!context.WebSockets.IsWebSocketRequest)
		{
			// Reachable by anyone who opens the URL in a browser, so say what
			// the endpoint is instead of a bare 400.
			context.Response.StatusCode = StatusCodes.Status400BadRequest;
			await context.Response.WriteAsync(
				$"This endpoint is a WebSocket. Servers announce themselves here; the launcher reads {MasterApi.ListPath}.");
			return;
		}

		using var socket = await context.WebSockets.AcceptWebSocketAsync();
		var address = AnnounceValidator.ObservedAddress(context.Connection.RemoteIpAddress);

		await RunAsync(socket, address, registry, log, context.RequestAborted);
	}

	private static async Task RunAsync(WebSocket socket, string address, ServerRegistry registry,
		ILogger log, CancellationToken ct)
	{
		string? id = null;
		string? name = null;

		try
		{
			var announce = await ReceiveAsync(socket, AnnounceTimeout, ct);
			if (announce is null)
				return;

			if (announce.ApiVersion != MasterApi.Version)
			{
				// The one mismatch worth being loud about: a relay built
				// against a different contract may otherwise appear to work
				// and publish fields nobody reads.
				log.LogWarning("Refused a server from {Address}: it speaks master API v{Theirs}, this master speaks v{Ours}.",
					address, announce.ApiVersion, MasterApi.Version);

				await RejectAsync(socket, MasterApi.RejectCode.ApiVersion,
					$"This master server speaks master API v{MasterApi.Version}; the server sent v{announce.ApiVersion}. Update whichever is older.",
					ct);
				return;
			}

			if (announce.Type != MasterApi.MessageType.Announce || announce.Announce is null)
			{
				await RejectAsync(socket, MasterApi.RejectCode.Invalid,
					$"The first message on this socket must be \"{MasterApi.MessageType.Announce}\".", ct);
				return;
			}

			var now = DateTimeOffset.UtcNow;
			var result = AnnounceValidator.Build(announce.Announce, address, Guid.NewGuid().ToString("n"), now);

			if (result.Server is null)
			{
				log.LogWarning("Refused a server from {Address}: {Error}", address, result.Error);
				await RejectAsync(socket, MasterApi.RejectCode.Invalid, result.Error ?? "The announce was rejected.", ct);
				return;
			}

			if (!registry.Add(result.Server))
			{
				await RejectAsync(socket, MasterApi.RejectCode.Full,
					"This master server is already listing as many servers as it is configured to hold.", ct);
				return;
			}

			id = result.Server.Id;
			name = result.Server.Name;

			await SendAsync(socket, new MasterMessage
			{
				Type = MasterApi.MessageType.Accepted,
				ApiVersion = MasterApi.Version,
				Accepted = new MasterAccepted
				{
					Id = id,
					Address = result.Server.Address,
					HeartbeatSeconds = MasterApi.HeartbeatSeconds,
					Warnings = result.Warnings,
				},
			}, ct);

			log.LogInformation("Listed \"{Name}\" at {Endpoint} (release {Release}, relay protocol v{Protocol}).",
				name, result.Server.Endpoint,
				result.Server.ReleaseVersion.Length == 0 ? "unknown" : result.Server.ReleaseVersion,
				result.Server.ProtocolVersion);

			foreach (var warning in result.Warnings)
				log.LogInformation("  \"{Name}\": {Warning}", name, warning);

			await PumpAsync(socket, id, registry, log, ct);
		}
		catch (OperationCanceledException)
		{
			// Two cases, and they are worth telling apart in a log that is
			// mostly read when a server has vanished from the browser.
			if (ct.IsCancellationRequested)
			{
				// The request was aborted: the server's socket died without a
				// close frame, which is what a crashed or killed relay looks
				// like. This is the path that makes a listing disappear the
				// moment the server does.
				log.LogInformation("Connection from {Address} was cut off.", address);
			}
			else
			{
				log.LogInformation("Connection from {Address} went quiet for {Seconds}s; dropping it.",
					address, MasterApi.TimeoutSeconds);
			}
		}
		catch (JsonException ex)
		{
			log.LogWarning("Dropping the connection from {Address}: it sent something that is not a master API message ({Message}).",
				address, ex.Message);
			await CloseAsync(socket, WebSocketCloseStatus.InvalidPayloadData, "Malformed message", ct);
		}
		catch (WebSocketException ex)
		{
			// The ordinary way a server goes away: the socket died without a
			// close frame. Logged at information because it is not a fault.
			log.LogInformation("Connection from {Address} dropped: {Message}", address, ex.Message);
		}
		finally
		{
			if (id is not null && registry.Remove(id))
				log.LogInformation("Delisted \"{Name}\" ({Address}).", name, address);
		}
	}

	/// <summary>Reads updates and heartbeats until the relay stops sending them.</summary>
	private static async Task PumpAsync(WebSocket socket, string id, ServerRegistry registry, ILogger log, CancellationToken ct)
	{
		var timeout = TimeSpan.FromSeconds(MasterApi.TimeoutSeconds);

		while (socket.State == WebSocketState.Open)
		{
			var message = await ReceiveAsync(socket, timeout, ct);
			if (message is null)
				break;

			var now = DateTimeOffset.UtcNow;
			bool listed;

			switch (message.Type)
			{
				case MasterApi.MessageType.Update when message.Update is not null:
					listed = registry.Update(id, AnnounceValidator.CleanUpdate(message.Update), now);
					break;

				case MasterApi.MessageType.Heartbeat:
					listed = registry.Touch(id, now);
					break;

				default:
					// Forward compatibility: a newer relay may send something
					// this master has no use for. Ignoring it is correct, and
					// the api version check already caught the case where the
					// two are genuinely incompatible.
					log.LogDebug("Ignoring a \"{Type}\" message from a listed server.", message.Type);
					continue;
			}

			if (listed)
				continue;

			// The id is gone, so another connection claimed this address --
			// see ServerRegistry.Add. Close rather than keep reading from a
			// relay whose listing no longer exists.
			await CloseAsync(socket, WebSocketCloseStatus.NormalClosure, "Superseded by a newer connection", ct);
			return;
		}
	}

	/// <summary>
	/// Reads one whole message, or null when the peer closed the socket.
	/// </summary>
	/// <exception cref="OperationCanceledException">Nothing arrived within <paramref name="timeout"/>.</exception>
	private static async Task<MasterMessage?> ReceiveAsync(WebSocket socket, TimeSpan timeout, CancellationToken ct)
	{
		using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(ct);
		timeoutSource.CancelAfter(timeout);

		var buffer = new byte[4096];
		using var message = new MemoryStream();

		while (true)
		{
			var received = await socket.ReceiveAsync(buffer, timeoutSource.Token);

			if (received.MessageType == WebSocketMessageType.Close)
				return null;

			message.Write(buffer, 0, received.Count);

			if (message.Length > MasterApi.MaxMessageBytes)
				throw new JsonException($"Message exceeded {MasterApi.MaxMessageBytes} bytes.");

			if (received.EndOfMessage)
				break;
		}

		return JsonSerializer.Deserialize<MasterMessage>(message.ToArray(), MasterApi.Json);
	}

	private static async Task SendAsync(WebSocket socket, MasterMessage message, CancellationToken ct)
	{
		var bytes = JsonSerializer.SerializeToUtf8Bytes(message, MasterApi.Json);
		await socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, ct);
	}

	private static async Task RejectAsync(WebSocket socket, string code, string reason, CancellationToken ct)
	{
		// Sent as a message before the close frame: a close reason is capped
		// at 123 bytes and is awkward to read from a client library, and the
		// relay logs this verbatim for its operator.
		await SendAsync(socket, new MasterMessage
		{
			Type = MasterApi.MessageType.Rejected,
			ApiVersion = MasterApi.Version,
			Rejected = new MasterRejected { Code = code, Reason = reason },
		}, ct);

		await CloseAsync(socket, WebSocketCloseStatus.PolicyViolation, code, ct);
	}

	private static async Task CloseAsync(WebSocket socket, WebSocketCloseStatus status, string description, CancellationToken ct)
	{
		if (socket.State is not (WebSocketState.Open or WebSocketState.CloseReceived))
			return;

		try
		{
			await socket.CloseAsync(status, description, ct);
		}
		catch (Exception ex) when (ex is WebSocketException or OperationCanceledException or ObjectDisposedException)
		{
			// Closing a socket that is already gone is the normal case here,
			// and there is nothing left to do about it either way.
		}
	}
}
