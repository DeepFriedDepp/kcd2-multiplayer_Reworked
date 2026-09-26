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
	private readonly TimeSpan _idleTimeout;
	private readonly ClientHandler _clientHandler;
	private readonly TcpBroadcastService _broadcastService;
	private readonly SessionManager _sessions;
	private readonly ClientSessionRunner _runner;

	public TcpSocketService(ILogger logger, IConfiguration configuration,
		ClientHandler clientHandler, TcpBroadcastService broadcastService,
		SessionManager sessions, ClientSessionRunner runner)
	{
		_runner = runner;
		_logger = logger;

		var configSection = configuration.GetSection("Tcp");
		_port = int.Parse(configSection["Port"] ?? "7778");
		// WO-102.5 Phase 4: configurable so the relay round-trip tests can use
		// a short timeout instead of ClientSession's 30 s field default.
		_idleTimeout = runner.IdleTimeout;

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
		// WO-110 R9: one MP-RELAY-DROPS line every 60 s while anything is dropped.
		var drops = ReportDropsLoopAsync(cancellationToken);

		try
		{
			while (!cancellationToken.IsCancellationRequested)
			{
				var tcpListener = await listener.AcceptTcpClientAsync(cancellationToken);
				// WO-110 R6: no Nagle coalescing on 40-byte NPC frames; the
				// agent sets the same on its side.
				tcpListener.NoDelay = true;
				var client = new ClientSession(_logger, tcpListener, _broadcastService, _sessions, _clientHandler, _idleTimeout);
				_runner.Start(client);   // WO-127: the same lifecycle for Steam sessions (SteamRelayService)
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
	private async Task ReportDropsLoopAsync(CancellationToken ct)
	{
		try
		{
			while (!ct.IsCancellationRequested)
			{
				await Task.Delay(TimeSpan.FromSeconds(60), ct);
				var line = _clientHandler.DrainDropsLine();
				if (line is not null) _logger.Warning("{Line}", line);
			}
		}
		catch (OperationCanceledException) { }
	}

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
