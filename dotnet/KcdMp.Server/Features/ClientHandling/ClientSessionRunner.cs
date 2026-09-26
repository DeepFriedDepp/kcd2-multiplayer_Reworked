using KcdMp.Server.Features.Interactions;
using KcdMp.Server.Features.Tcp;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// WO-127: one client's lifetime, from accept to the disconnect bookkeeping,
/// whatever transport carries it. Moved out of TcpSocketService unchanged so
/// the Steam listener (SteamRelayService) runs its sessions through exactly
/// the same cleanup.
/// </summary>
public sealed class ClientSessionRunner
{
	private readonly ILogger _logger;
	private readonly ClientHandler _clientHandler;
	private readonly TcpBroadcastService _broadcastService;
	private readonly SessionManager _sessions;

	/// <summary>
	/// WO-102.5 Phase 4: configurable so the relay round-trip tests can use a
	/// short timeout instead of ClientSession's 30 s field default.
	/// </summary>
	public TimeSpan IdleTimeout { get; }

	public ClientSessionRunner(ILogger logger, IConfiguration configuration, ClientHandler clientHandler,
		TcpBroadcastService broadcastService, SessionManager sessions)
	{
		_logger = logger;
		_clientHandler = clientHandler;
		_broadcastService = broadcastService;
		_sessions = sessions;
		IdleTimeout = TimeSpan.FromMilliseconds(int.Parse(configuration.GetSection("Tcp")["IdleTimeoutMs"] ?? "30000"));
	}

	public ClientSession Create(RelayConnection conn) =>
		new(_logger, conn, _broadcastService, _sessions, _clientHandler, IdleTimeout);

	public void Start(ClientSession client)
	{
		_clientHandler.AddClient(client);

		// ClientHandler is thread-safe, so the disconnect bookkeeping needs no
		// lock and no async continuation of its own.
		_ = client.RunAsync().ContinueWith(task =>
		{
			// RunAsync's own catch only covers IOException/SocketException/
			// EndOfStreamException (normal disconnects); anything else faults
			// this Task. Discarding that fault here would make a real crash
			// look identical to a normal disconnect in the log -- the exact
			// "silent catch on a background task" trap HANDOFF-WO4-combat.md
			// already warns about, just one level up (the continuation,
			// not RunAsync's own try/catch).
			if (task.IsFaulted)
			{
				_logger.Error(task.Exception?.Flatten(),
					"[!] {ClientName}'s connection handler faulted unexpectedly",
					client.Name ?? "(not ready)");
			}

			_clientHandler.RemoveClient(client);

			// WO-38: a sleeper who disconnects mid-skip must not leave the
			// session's one active-skip slot claimed until the timeout.
			_clientHandler.ClearTimeSkipFor(client);

			// WO-39: a dragger who vanishes mid-drag releases their
			// claimed bodies now, not at the claim timeout.
			_clientHandler.ClearNpcClaimsFor(client);

			// WO-81: drop this session's cached position so a later
			// reused byte Id cannot inherit a stale distance reading.
			_clientHandler.ClearPlayerPositionFor(client);

			// Before announcing the disconnect: a peer still in a session
			// with this client needs telling, or it waits forever.
			_sessions.HandleDisconnect(client);

			_logger.Information("[-] {ClientName} disconnected ({Transport}). Clients: {ClientHandlerClientCount}",
				client.Name ?? "(not ready)", client.Transport, _clientHandler.ClientCount);
			if (client.IsReady)
				_broadcastService.BroadcastDisconnect(client);

			// WO-28: losing a client can move NPC->player damage
			// authority -- it does whenever the holder is the one who
			// left. Announced after RemoveClient above, so the role is
			// recomputed over the set that actually remains.
			_broadcastService.BroadcastCombatRole();
		}, CancellationToken.None);
	}
}
