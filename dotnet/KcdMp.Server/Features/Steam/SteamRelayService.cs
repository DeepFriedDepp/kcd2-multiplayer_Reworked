using KcdMp.Server.Features.ClientHandling;
using KcdMp.Steam;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.Steam;

/// <summary>
/// WO-127: what the host's launcher shows about Steam (GET api/local/status,
/// loopback only). <see cref="Code"/> is the host's join code: on the host's
/// screen only, never in a log line.
/// </summary>
public sealed class SteamRelayStatus
{
	private readonly object _lock = new();
	private string _state = "off";   // off | starting | ready | failed
	private string _message = "Steam is off for this session.";
	private uint _appId;
	private string? _code;
	private int _peers;

	public void Set(string state, string message, uint appId = 0, string? code = null)
	{
		lock (_lock)
		{
			_state = state;
			_message = message;
			if (appId != 0) _appId = appId;
			if (code is not null) _code = code;
		}
	}

	public void AddPeer(int delta) => Interlocked.Add(ref _peers, delta);

	public (string State, string Message, uint AppId, string? Code, int Peers) Snapshot()
	{
		lock (_lock) return (_state, _message, _appId, _code, Volatile.Read(ref _peers));
	}
}

/// <summary>
/// WO-127 Phase 1: the relay also listens on Steam P2P ("Also allow Steam" in
/// the launcher's Host window). Additive: the TCP listener is untouched and
/// runs whether Steam starts or not. Each Steam connection becomes an ordinary
/// ClientSession over SteamConnectionStream -- same frames, same protocol v9 --
/// marked non-loopback, so a Steam joiner never takes the relay-local
/// authority rule from the host's own agent.
///
/// Config: Steam:Enabled (bool), Steam:AppId (2429020 default), Steam:GameExe
/// (where to borrow steam_api64.dll). Everything Steam says passes through
/// SteamLogScrub before it reaches relay.log.
/// </summary>
public sealed class SteamRelayService : BackgroundService
{
	private readonly ILogger _logger;
	private readonly IConfiguration _configuration;
	private readonly ClientSessionRunner _runner;
	private readonly SteamRelayStatus _status;

	public SteamRelayService(ILogger logger, IConfiguration configuration, ClientSessionRunner runner, SteamRelayStatus status)
	{
		_logger = logger;
		_configuration = configuration;
		_runner = runner;
		_status = status;
	}

	protected override async Task ExecuteAsync(CancellationToken ct)
	{
		var cfg = _configuration.GetSection("Steam");
		if (!bool.TryParse(cfg["Enabled"], out bool enabled) || !enabled)
		{
			_status.Set("off", "Steam is off for this session.");
			return;
		}
		uint appId = uint.TryParse(cfg["AppId"], out var a) && a != 0 ? a : SteamApps.Default;
		string? gameExe = cfg["GameExe"] is { Length: > 0 } g ? g : null;
		_status.Set("starting", "Starting Steam...", appId);
		_logger.Information("[steam] starting under app {AppId} ({AppName})", appId, SteamApps.Name(appId));

		SteamSession? session;
		SteamStartFailure failure;
		string detail;
		try
		{
			// SteamAPI_InitFlat is synchronous and quick; kept off the host's startup path anyway.
			(session, failure, detail) = await Task.Run(() =>
			{
				var s = SteamSession.TryStart(appId, out var f, out var d, gameExe);
				return (s, f, d);
			}, ct);
		}
		catch (OperationCanceledException) { return; }
		catch (Exception ex)
		{
			session = null; failure = SteamStartFailure.InitFailed; detail = ex.GetType().Name + ": " + ex.Message;
		}

		if (session is null)
		{
			var kind = SteamTroubles.FromStartFailure(failure);
			_status.Set("failed", PlainConnectionError.For(kind).Sentence + " Friends can still join with your address.", appId);
			_logger.Warning("[steam] not available: {Failure} ({Detail}). The TCP listener is unaffected.", failure, SteamLogScrub.Scrub(detail));
			return;
		}

		using var owned = session;
		session.Log += l => _logger.Information("[steam] {Line}", l);   // SteamSession scrubs every line it emits
		if (detail.Length > 0) _logger.Information("[steam] {Detail}", SteamLogScrub.Scrub(detail));
		string code = SteamJoinCode.Encode(session.LocalSteamId, appId);
		_status.Set("starting", "Connecting to Steam's network...", appId, code);

		bool ready;
		try { ready = await session.WaitNetworkReadyAsync(TimeSpan.FromSeconds(30), ct); }
		catch (OperationCanceledException) { return; }
		int relay = session.RelayAvailability(out string relayDebug);
		_logger.Information("[steam] network ready={Ready} relay={Relay} auth={Auth} {Debug}", ready ? 1 : 0,
			SteamSession.AvailabilityName(relay), SteamSession.AvailabilityName(session.AuthenticationAvailability()),
			ready ? "" : "debug=" + relayDebug);

		SteamP2PListener listener;
		try { listener = session.Listen(SteamApps.RelayVirtualPort); }
		catch (Exception ex)
		{
			_status.Set("failed", "Steam couldn't open a way in for friends. Friends can still join with your address.", appId);
			_logger.Warning("[steam] listen failed: {Detail}", SteamLogScrub.Scrub(ex.Message));
			return;
		}
		using var ownedListener = listener;
		session.SetRichPresence(SteamApps.PresenceKey, $"host;{RelayReleaseVersion.Current}");
		_status.Set("ready", ready
			? "Steam: ready. Friends can join with your code."
			: "Steam: ready, but Steam's network is still warming up; the first join may take longer.", appId, code);
		_logger.Information("[steam] listening for Steam peers on virtual port {Port} (app {AppId}); rich presence set",
			SteamApps.RelayVirtualPort, appId);

		try
		{
			while (!ct.IsCancellationRequested)
			{
				var conn = await listener.AcceptAsync(ct);
				int flags = conn.InfoFlags();
				_status.AddPeer(1);
				_logger.Information("[+] a Steam peer connected (relayed={Relayed}); handshake next", (flags & 16) != 0 ? 1 : 0);
				var client = _runner.Create(RelayConnection.FromSteam(conn.GetStream()));
				_runner.Start(client);
				_ = WatchPeerAsync(conn);
			}
		}
		catch (OperationCanceledException) { }
		catch (System.Threading.Channels.ChannelClosedException) { }
		finally
		{
			try { session.ClearRichPresence(); } catch { }
			_status.Set("off", "Steam stopped.");
			_logger.Information("[steam] stopped");
		}
	}

	private async Task WatchPeerAsync(SteamP2PConnection conn)
	{
		while (conn.IsConnected) await Task.Delay(1000);
		_status.AddPeer(-1);
	}
}

/// <summary>WO-127: SteamSession start failures in the plain-error vocabulary.</summary>
public static class SteamTroubles
{
	public static ConnectionTrouble FromStartFailure(SteamStartFailure f) => f switch
	{
		SteamStartFailure.SteamNotRunning => ConnectionTrouble.SteamNotRunning,
		SteamStartFailure.NotLoggedOn => ConnectionTrouble.SteamNotLoggedIn,
		SteamStartFailure.None => ConnectionTrouble.None,
		_ => ConnectionTrouble.SteamUnavailable,
	};
}
