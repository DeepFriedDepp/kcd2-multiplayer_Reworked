using System.Net.Http.Json;
using System.Text.Json.Serialization;
using KcdMp.Server.Features.ServerInformation.Dtos;

namespace KcdMp.Server.Features.ServerInformation;

/// <summary>
/// Announces this relay to a master server so it appears in the launcher's
/// browser.
///
/// The master server has always had a /servers/register endpoint and the relay
/// has always served /api/information, but nothing ever connected the two —
/// the browser was empty no matter what was running. This is that missing half.
///
/// It is <b>opt-in</b>: with no <c>MasterServer:Url</c> configured it does
/// nothing at all. Publishing a relay's address to a third party is not
/// something to do by default on the operator's behalf.
///
/// Registration doubles as the heartbeat. The master upserts on address and
/// hides listings it has not heard from recently, so a relay that crashes
/// disappears on its own rather than lingering as a dead entry.
/// </summary>
public sealed class MasterRegistrationService : BackgroundService
{
	private readonly MasterServerOptions _options;
	private readonly ServerInfo _serverInfo;
	private readonly int _relayPort;
	private readonly ILogger<MasterRegistrationService> _log;
	private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(10) };

	/// <summary>
	/// Handed back by the first registration and presented on every refresh, so
	/// the master can tell a genuine update from someone else claiming the
	/// address. Held in memory only: after a restart the relay registers
	/// without one, which the master accepts.
	/// </summary>
	private string? _token;

	public MasterRegistrationService(IConfiguration configuration, ILogger<MasterRegistrationService> log)
	{
		_log = log;

		configuration.GetSection("MasterServer").Bind(_options = new MasterServerOptions());
		configuration.GetSection("ServerInfo").Bind(_serverInfo = new ServerInfo());
		_relayPort = configuration.GetValue("Tcp:Port", 7778);
	}

	protected override async Task ExecuteAsync(CancellationToken stoppingToken)
	{
		if (string.IsNullOrWhiteSpace(_options.Url))
		{
			_log.LogInformation(
				"Master server registration is off. Set MasterServer:Url to list this relay in the browser.");
			return;
		}

		// Tag names are validated against a fixed list on the master, which
		// rejects the whole registration for one bad name. Saying so here beats
		// a 400 with no explanation.
		if (_serverInfo.Tags.Length > 3)
		{
			_log.LogWarning(
				"ServerInfo:Tags has {Count} entries but the master server allows at most 3; registration will be refused.",
				_serverInfo.Tags.Length);
		}

		var period = TimeSpan.FromSeconds(Math.Max(15, _options.HeartbeatSeconds));

		while (!stoppingToken.IsCancellationRequested)
		{
			await RegisterOnceAsync(stoppingToken);

			try { await Task.Delay(period, stoppingToken); }
			catch (OperationCanceledException) { break; }
		}
	}

	private async Task RegisterOnceAsync(CancellationToken ct)
	{
		var payload = new RegistrationRequest
		{
			Name = string.IsNullOrWhiteSpace(_options.Name) ? Environment.MachineName : _options.Name,
			// Left null unless configured, so the master falls back to the
			// address the request arrived from. A relay behind NAT cannot know
			// the address peers reach it on, but the master can see it.
			IpAddress   = string.IsNullOrWhiteSpace(_options.AdvertisedIp) ? null : _options.AdvertisedIp,
			Port        = _relayPort,
			MapName     = _serverInfo.MapName,
			Description = _options.Description,
			Tags        = _serverInfo.Tags,
			Token       = _token,
		};

		try
		{
			var response = await _http.PostAsJsonAsync(_options.Url, payload, ct);

			if (!response.IsSuccessStatusCode)
			{
				var body = await response.Content.ReadAsStringAsync(ct);
				_log.LogWarning("Master server refused the registration ({Status}): {Body}",
					(int)response.StatusCode, body);
				return;
			}

			var result = await response.Content.ReadFromJsonAsync<RegistrationResponse>(ct);
			if (result?.Token is { Length: > 0 } token && _token is null)
			{
				_token = token;
				_log.LogInformation("Registered with the master server at {Url} as \"{Name}\" on port {Port}.",
					_options.Url, payload.Name, payload.Port);
			}
		}
		catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
		{
			// A master server that is down must not take the relay with it —
			// peers connect over TCP directly and do not need the browser.
			_log.LogWarning("Could not reach the master server at {Url}: {Message}", _options.Url, ex.Message);
		}
	}

	public override void Dispose()
	{
		_http.Dispose();
		base.Dispose();
	}

	private sealed record RegistrationRequest
	{
		[JsonPropertyName("name")]        public string   Name        { get; init; } = "";
		[JsonPropertyName("ip_address")]  public string?  IpAddress   { get; init; }
		[JsonPropertyName("port")]        public int      Port        { get; init; }
		[JsonPropertyName("map_name")]    public string   MapName     { get; init; } = "";
		[JsonPropertyName("description")] public string?  Description { get; init; }
		[JsonPropertyName("tags")]        public string[] Tags        { get; init; } = [];
		[JsonPropertyName("token")]       public string?  Token       { get; init; }
	}

	private sealed record RegistrationResponse
	{
		[JsonPropertyName("token")] public string? Token { get; init; }
	}
}

/// <summary>Settings for <see cref="MasterRegistrationService"/>.</summary>
public sealed class MasterServerOptions
{
	/// <summary>Full URL of the master's register endpoint. Empty disables registration.</summary>
	public string Url { get; set; } = "";

	/// <summary>Shown in the browser. Defaults to the machine name.</summary>
	public string Name { get; set; } = "";

	/// <summary>Free text shown on the server's detail view.</summary>
	public string Description { get; set; } = "";

	/// <summary>Only needed when the master cannot infer the address, e.g. behind a proxy.</summary>
	public string AdvertisedIp { get; set; } = "";

	/// <summary>How often to refresh the listing. The master hides anything unseen for 5 minutes.</summary>
	public int HeartbeatSeconds { get; set; } = 120;
}
