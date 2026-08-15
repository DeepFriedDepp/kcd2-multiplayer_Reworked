using System.Net.WebSockets;
using System.Reflection;
using System.Text.Json;
using KcdMp.Server.Features.ClientHandling;
using KcdMp.Server.Features.ServerInformation.Dtos;

namespace KcdMp.Server.Features.ServerInformation;

/// <summary>
/// Announces this relay to a master server, so it appears in the launcher's
/// browser, and keeps it announced.
///
/// The connection is the listing: one WebSocket, opened when the relay starts
/// and held for as long as it runs. Going offline needs no message at all --
/// the socket closing is the message, whether the relay was stopped politely
/// or killed. Player counts are pushed as they change rather than waited for.
///
/// It is <b>opt-in</b>: with no <c>MasterServer:Url</c> configured it does
/// nothing at all. Publishing a relay's address to a third party is not
/// something to do by default on the operator's behalf.
///
/// A master server that is down must never take the relay with it. Every
/// failure here ends in a retry with a growing delay; peers connect over TCP
/// directly and do not need the browser to play.
/// </summary>
public sealed class MasterAnnounceService : BackgroundService
{
	/// <summary>How often local state is checked for something worth pushing.</summary>
	private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);

	private static readonly TimeSpan FirstRetryDelay = TimeSpan.FromSeconds(5);
	private static readonly TimeSpan MaxRetryDelay = TimeSpan.FromMinutes(5);

	/// <summary>How long the master has to answer an announce.</summary>
	private static readonly TimeSpan AcceptTimeout = TimeSpan.FromSeconds(30);

	/// <summary>How long a closing connection is given to finish closing.</summary>
	private static readonly TimeSpan GoodbyeTimeout = TimeSpan.FromSeconds(3);

	private readonly MasterServerOptions _options;
	private readonly ServerInfo _serverInfo;
	private readonly ClientHandler _clients;
	private readonly ILogger<MasterAnnounceService> _log;
	private readonly int _relayPort;
	private readonly int _infoPort;

	public MasterAnnounceService(IConfiguration configuration, ClientHandler clients, ILogger<MasterAnnounceService> log)
	{
		_log = log;
		_clients = clients;

		configuration.GetSection("MasterServer").Bind(_options = new MasterServerOptions());
		configuration.GetSection("ServerInfo").Bind(_serverInfo = new ServerInfo());

		_relayPort = configuration.GetValue("Tcp:Port", 7778);
		_infoPort = ResolveInfoPort(configuration);
	}

	protected override async Task ExecuteAsync(CancellationToken stoppingToken)
	{
		if (string.IsNullOrWhiteSpace(_options.Url))
		{
			_log.LogInformation(
				"Master server announcing is off. Set MasterServer:Url to list this relay in the browser.");
			return;
		}

		if (!TryBuildConnectUri(_options.Url, out var uri, out var error))
		{
			_log.LogError("MasterServer:Url is not usable: {Error}", error);
			return;
		}

		var retry = FirstRetryDelay;

		while (!stoppingToken.IsCancellationRequested)
		{
			// Reset only on a session the master accepted. A relay that is
			// refused -- wrong API version, say -- backs off to the far end of
			// the scale instead of hammering a master that will refuse it
			// again for exactly the same reason.
			retry = await RunSessionAsync(uri, stoppingToken) ? FirstRetryDelay : retry;

			if (stoppingToken.IsCancellationRequested)
				break;

			_log.LogDebug("Retrying the master server in {Seconds}s.", (int)retry.TotalSeconds);

			try { await Task.Delay(retry, stoppingToken); }
			catch (OperationCanceledException) { break; }

			retry = TimeSpan.FromTicks(Math.Min(retry.Ticks * 2, MaxRetryDelay.Ticks));
		}
	}

	/// <summary>
	/// One connection, from announce to disconnect.
	/// </summary>
	/// <returns>True if the master accepted the announce, however it ended afterwards.</returns>
	private async Task<bool> RunSessionAsync(Uri uri, CancellationToken ct)
	{
		using var socket = new ClientWebSocket();
		socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(MasterApi.HeartbeatSeconds);

		var accepted = false;

		var announce = BuildAnnounce();

		try
		{
			await socket.ConnectAsync(uri, ct);
			await SendAsync(socket, new MasterMessage
			{
				Type = MasterApi.MessageType.Announce,
				ApiVersion = MasterApi.Version,
				Announce = announce,
			}, ct);

			var reply = await ReceiveAsync(socket, AcceptTimeout, ct);

			if (reply is null)
			{
				_log.LogWarning("The master server at {Uri} closed the connection without answering the announce.", uri);
				return false;
			}

			if (reply.Type == MasterApi.MessageType.Rejected)
			{
				_log.LogError("The master server refused this relay ({Code}): {Reason}",
					reply.Rejected?.Code ?? "unknown", reply.Rejected?.Reason ?? "no reason given");
				return false;
			}

			if (reply.Type != MasterApi.MessageType.Accepted || reply.Accepted is null)
			{
				_log.LogWarning("The master server answered the announce with \"{Type}\", which means nothing here.", reply.Type);
				return false;
			}

			accepted = true;

			_log.LogInformation("Listed on the master server at {Uri} as \"{Name}\", reachable at {Address}:{Port}.",
				uri, announce.Name, reply.Accepted.Address, _relayPort);

			foreach (var warning in reply.Accepted.Warnings)
				_log.LogWarning("Master server note: {Warning}", warning);

			await MaintainAsync(socket, reply.Accepted.HeartbeatSeconds, ct);
		}
		catch (OperationCanceledException) when (ct.IsCancellationRequested)
		{
			// The relay is shutting down. Fall through to the close below so
			// the listing goes away now rather than when the master times out.
		}
		catch (Exception ex) when (ex is WebSocketException or OperationCanceledException or JsonException)
		{
			_log.LogWarning("Lost the master server at {Uri}: {Message}", uri, ex.Message);
		}
		finally
		{
			await CloseAsync(socket);
		}

		return accepted;
	}

	/// <summary>
	/// Pushes changes for as long as the connection holds.
	///
	/// Local state is polled rather than raised as an event: the counts this
	/// reports already live in <see cref="ClientHandler"/>, and reading them on
	/// a timer cannot miss a change or fire twice for one, which a hook on
	/// every connect and disconnect path would have to be careful not to do.
	/// </summary>
	private async Task MaintainAsync(ClientWebSocket socket, int heartbeatSeconds, CancellationToken ct)
	{
		var heartbeat = TimeSpan.FromSeconds(Math.Clamp(heartbeatSeconds, 5, 300));

		// Nothing is expected from the master after the accept, but a socket
		// nobody reads never notices a close. This is what turns "the master
		// went away" into the end of the session.
		//
		// Its token is deliberately not the shutdown one: cancelling a read
		// aborts the whole WebSocket, which would tear the connection down
		// before the goodbye below could be sent.
		using var reader = new CancellationTokenSource();
		var reading = DrainAsync(socket, reader.Token);

		var last = Snapshot();
		var lastSent = DateTimeOffset.UtcNow;

		try
		{
			while (!ct.IsCancellationRequested && socket.State == WebSocketState.Open && !reading.IsCompleted)
			{
				await Task.Delay(PollInterval, ct);

				var current = Snapshot();

				if (current != last)
				{
					await SendAsync(socket, new MasterMessage
					{
						Type = MasterApi.MessageType.Update,
						ApiVersion = MasterApi.Version,
						Update = new ServerUpdate
						{
							MapName = current.MapName,
							Players = current.Players,
							MaxPlayers = current.MaxPlayers,
						},
					}, ct);

					last = current;
					lastSent = DateTimeOffset.UtcNow;
					continue;
				}

				if (DateTimeOffset.UtcNow - lastSent < heartbeat)
					continue;

				await SendAsync(socket, new MasterMessage
				{
					Type = MasterApi.MessageType.Heartbeat,
					ApiVersion = MasterApi.Version,
				}, ct);

				lastSent = DateTimeOffset.UtcNow;
			}
		}
		finally
		{
			// Only the outgoing half is closed here, so the read above stays
			// alive to collect the master's answering close. Then it is given
			// a moment to arrive, and dropped if it does not: the relay is on
			// its way out and the listing is gone either way.
			await CloseAsync(socket);
			reader.CancelAfter(GoodbyeTimeout);
			await reading;
		}
	}

	/// <summary>
	/// Reads until the master closes the socket or stops answering. A rejection
	/// arriving here is the master hanging up on a listing it had accepted --
	/// another connection claimed the same address, normally -- and is worth
	/// saying out loud, because from the outside it looks like the browser
	/// simply forgot this relay.
	/// </summary>
	private async Task DrainAsync(ClientWebSocket socket, CancellationToken ct)
	{
		try
		{
			while (socket.State == WebSocketState.Open)
			{
				var message = await ReceiveAsync(socket, Timeout.InfiniteTimeSpan, ct);
				if (message is null)
					return;

				if (message.Type == MasterApi.MessageType.Rejected)
					_log.LogWarning("The master server dropped this listing ({Code}): {Reason}",
						message.Rejected?.Code ?? "unknown", message.Rejected?.Reason ?? "no reason given");
			}
		}
		catch (Exception ex) when (ex is WebSocketException or OperationCanceledException or JsonException)
		{
			// Whatever went wrong, the session is over; RunSessionAsync's own
			// handling reports it and schedules the retry.
		}
	}

	private ServerAnnounce BuildAnnounce()
	{
		var state = Snapshot();

		return new ServerAnnounce
		{
			Name = string.IsNullOrWhiteSpace(_options.Name) ? Environment.MachineName : _options.Name,
			ReleaseVersion = ReleaseVersion,
			ProtocolVersion = Protocol.Version,

			// Left empty unless configured, so the master publishes the
			// address the connection actually came from. A relay behind NAT
			// cannot know the address peers reach it on; the master can see it.
			Address = string.IsNullOrWhiteSpace(_options.AdvertisedIp) ? null : _options.AdvertisedIp,

			Port = _relayPort,
			InfoPort = _infoPort,
			MapName = state.MapName,
			Players = state.Players,
			MaxPlayers = state.MaxPlayers,
			Tags = _serverInfo.Tags,
			Description = _options.Description,
		};
	}

	/// <summary>
	/// What the browser shows about this relay right now. Players counts only
	/// clients that finished the handshake -- a launcher checking whether the
	/// port answers opens a connection and drops it, and that is not a player.
	/// </summary>
	private RelayState Snapshot() => new(_serverInfo.MapName, _clients.ReadyClientCount, _serverInfo.MaxPlayers);

	private readonly record struct RelayState(string MapName, int Players, int MaxPlayers);

	/// <summary>
	/// Turns the configured master server URL into the WebSocket URL to dial.
	///
	/// The operator configures where the master <i>is</i> ("https://master.example.com"),
	/// not the path within it: the path belongs to the API, and pasting it into
	/// every relay's configuration is how a contract change turns into a fleet
	/// of relays pointed at an endpoint that no longer exists.
	/// </summary>
	internal static bool TryBuildConnectUri(string configured, out Uri uri, out string error)
	{
		uri = null!;

		if (!Uri.TryCreate(configured.Trim(), UriKind.Absolute, out var parsed))
		{
			error = $"\"{configured}\" is not an absolute URL. Use something like \"http://master.example.com:5100\".";
			return false;
		}

		var scheme = parsed.Scheme.ToLowerInvariant() switch
		{
			"http" or "ws" => "ws",
			"https" or "wss" => "wss",
			_ => null,
		};

		if (scheme is null)
		{
			error = $"\"{parsed.Scheme}\" is not a scheme this can connect over. Use http, https, ws or wss.";
			return false;
		}

		var path = parsed.AbsolutePath.TrimEnd('/');

		var builder = new UriBuilder(parsed)
		{
			Scheme = scheme,
			// Tolerates a URL that already names the endpoint, so an operator
			// who copied it out of the docs is not punished for it.
			Path = path.EndsWith(MasterApi.ConnectPath, StringComparison.OrdinalIgnoreCase)
				? path
				: path + MasterApi.ConnectPath,
			Query = "",
			Fragment = "",
		};

		uri = builder.Uri;
		error = "";
		return true;
	}

	/// <summary>
	/// The port this relay's own /api/information listener is on, published so
	/// the launcher does not have to assume a default that stops being true the
	/// moment two relays share a host.
	/// </summary>
	private static int ResolveInfoPort(IConfiguration configuration)
	{
		// "Urls" is the same key Kestrel binds from, whether it came from
		// appsettings.json or the ASPNETCORE_URLS environment variable.
		var urls = configuration["Urls"];
		if (string.IsNullOrWhiteSpace(urls))
			return 0;

		foreach (var candidate in urls.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
		{
			if (Uri.TryCreate(candidate, UriKind.Absolute, out var parsed) && parsed.Port > 0)
				return parsed.Port;
		}

		return 0;
	}

	/// <summary>
	/// This relay's release version, from the assembly attribute the SDK fills
	/// in from the repo's VERSION file at build time (see the csproj). Never
	/// written here; see docs/VERSIONING.md.
	/// </summary>
	private static string ReleaseVersion =>
		Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
		?? "0.0.0";

	private static async Task SendAsync(ClientWebSocket socket, MasterMessage message, CancellationToken ct)
	{
		var bytes = JsonSerializer.SerializeToUtf8Bytes(message, MasterApi.Json);
		await socket.SendAsync(bytes, WebSocketMessageType.Text, endOfMessage: true, ct);
	}

	private static async Task<MasterMessage?> ReceiveAsync(ClientWebSocket socket, TimeSpan timeout, CancellationToken ct)
	{
		using var timeoutSource = CancellationTokenSource.CreateLinkedTokenSource(ct);

		if (timeout != Timeout.InfiniteTimeSpan)
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
				throw new JsonException($"The master server sent more than {MasterApi.MaxMessageBytes} bytes in one message.");

			if (received.EndOfMessage)
				break;
		}

		return JsonSerializer.Deserialize<MasterMessage>(message.ToArray(), MasterApi.Json);
	}

	/// <summary>
	/// Says goodbye properly when there is still a socket to say it on, so the
	/// listing disappears on the master's side immediately rather than when the
	/// connection is eventually noticed to be dead.
	///
	/// Uses its own token, because this runs while the relay is shutting down
	/// and the shutdown token is already cancelled by then. Sends the close
	/// frame without waiting for the answer -- <see cref="DrainAsync"/> is
	/// still reading, and only one read may be outstanding at a time.
	/// </summary>
	private static async Task CloseAsync(ClientWebSocket socket)
	{
		if (socket.State is not (WebSocketState.Open or WebSocketState.CloseReceived))
			return;

		using var timeout = new CancellationTokenSource(GoodbyeTimeout);

		try
		{
			await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "Relay stopping", timeout.Token);
		}
		catch (Exception ex) when (ex is WebSocketException or OperationCanceledException or ObjectDisposedException)
		{
			// The socket is gone, which is the outcome this was after anyway.
		}
	}
}

/// <summary>Settings for <see cref="MasterAnnounceService"/>.</summary>
public sealed class MasterServerOptions
{
	/// <summary>
	/// Where the master server is, e.g. "http://localhost:5100". Empty
	/// disables announcing entirely. The endpoint path is appended by the
	/// relay; https/wss is used when the URL says so.
	/// </summary>
	public string Url { get; set; } = "";

	/// <summary>Shown in the browser. Defaults to the machine name.</summary>
	public string Name { get; set; } = "";

	/// <summary>Free text shown alongside the listing.</summary>
	public string Description { get; set; } = "";

	/// <summary>
	/// Only needed when the master cannot see the address peers should use,
	/// e.g. when the relay is announced through a tunnel. Otherwise the master
	/// publishes the address the connection came from.
	/// </summary>
	public string AdvertisedIp { get; set; } = "";
}
