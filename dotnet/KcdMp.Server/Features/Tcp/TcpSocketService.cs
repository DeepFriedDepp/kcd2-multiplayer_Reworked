using System.Net;
using System.Net.Sockets;
using KcdMp.Server.Features.ClientHandling;
using KcdMp.Server.Features.Interactions;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.Tcp;

/// <summary>
/// Background service that exposes a TCP socket and handles incoming traffic.
/// </summary>
public class TcpSocketService : BackgroundService
{
	private readonly ILogger _logger;
	private readonly int _port;
	private readonly ClientHandler _clientHandler;
	private readonly TcpBroadcastService _broadcastService;
	private readonly SessionManager _sessions;

	public TcpSocketService(ILogger logger, IConfiguration configuration,
		ClientHandler clientHandler, TcpBroadcastService broadcastService,
		SessionManager sessions)
	{
		_logger = logger;

		var configSection = configuration.GetSection("Tcp");
		_port = int.Parse(configSection["Port"] ?? "7778");

		_clientHandler = clientHandler;
		_broadcastService = broadcastService;
		_sessions = sessions;
	}

	/// <summary>
	/// The actual logic executed by the service on startup.
	///
	/// Handles the TCP socket.
	/// </summary>
	/// <param name="cancellationToken"></param>
	protected override async Task ExecuteAsync(CancellationToken cancellationToken)
	{
		var listener = new TcpListener(IPAddress.Any, _port);
		listener.Start();
		_logger.Information("Listening on port {Port}...", _port);
		_logger.Information("Waiting for clients to connect.");

		// Pending invites nobody answers have to expire, or the invitee stays
		// marked busy and can never be invited again.
		var expiry = ExpireInvitesLoopAsync(cancellationToken);

		try
		{
			while (!cancellationToken.IsCancellationRequested)
			{
				var tcpListener = await listener.AcceptTcpClientAsync(cancellationToken);
				var client = new ClientSession(_logger, tcpListener, _broadcastService, _sessions, _clientHandler);

				_clientHandler.AddClient(client);

				// ClientHandler is thread-safe, so the disconnect bookkeeping needs no
				// lock and no async continuation of its own.
				_ = client.RunAsync().ContinueWith(task =>
				{
					// RunAsync's own catch only covers IOException/SocketException/
					// EndOfStreamException (normal disconnects); anything else faults
					// this Task. Discarding that fault here would make a real crash
					// look identical to a normal disconnect in the log — the exact
					// "silent catch on a background task" trap HANDOFF-WO4-combat.md
					// already warns about, just one level up (the continuation,
					// not RunAsync's own try/catch).
					if (task.IsFaulted)
					{
						_logger.Error(task.Exception?.Flatten(),
							"[!] {ClientName}'s connection handler faulted unexpectedly",
							client.Name ?? $"id={client.Id}");
					}

					_clientHandler.RemoveClient(client);

					// Before announcing the disconnect: a peer still in a session
					// with this client needs telling, or it waits forever.
					_sessions.HandleDisconnect(client);

					_logger.Information("[-] {ClientName} disconnected. Clients: {ClientHandlerClientCount}",
						client.Name ?? $"id={client.Id}", _clientHandler.ClientCount);
					if (client.IsReady)
						_broadcastService.BroadcastDisconnect(client);
				}, CancellationToken.None);
			}
		}
		catch (OperationCanceledException)
		{
			// Normal shutdown. TaskCanceledException derives from this, and
			// AcceptTcpClientAsync throws the base type on cancellation.
			_logger.Information("TCP Socket closed.");
		}
		finally
		{
			listener.Stop();
			try { await expiry; } catch { }
		}
	}

	/// <summary>
	/// Sweeps unanswered invites. Runs on a coarse interval because the timeout
	/// is 30 s — checking more often would only add wakeups.
	/// </summary>
	private async Task ExpireInvitesLoopAsync(CancellationToken ct)
	{
		try
		{
			while (!ct.IsCancellationRequested)
			{
				await Task.Delay(TimeSpan.FromSeconds(2), ct);
				try { _sessions.ExpireStaleInvites(); }
				catch (Exception ex) { _logger.Warning(ex, "[session] invite expiry sweep failed"); }
			}
		}
		catch (OperationCanceledException) { }
	}
}
