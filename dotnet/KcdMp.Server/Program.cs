using KcdMp.Server.Features.ClientHandling;
using KcdMp.Server.Features.Interactions;
using KcdMp.Server.Features.ServerInformation;
using KcdMp.Server.Features.Steam;
using KcdMp.Server.Features.Tcp;
using Serilog;

namespace KcdMp.Server;

public class Program
{
	/// <summary>
	/// Maps the pre-refactor CLI flags onto configuration keys, so
	/// "--port 7778" still works now that settings live in appsettings.json.
	/// </summary>
	private static readonly Dictionary<string, string> SwitchMappings = new()
	{
		["--port"] = "Tcp:Port",
		["-p"]     = "Tcp:Port",
		["--echo"] = "Echo",
		// WO-127: the launcher's "Also allow Steam" (Host window).
		["--steam"]      = "Steam:Enabled",
		["--steam-app"]  = "Steam:AppId",
		["--steam-game"] = "Steam:GameExe",
	};

	/// <summary>
	/// The server's entry point.
	/// </summary>
	static async Task Main(string[] args)
	{
		await using var app = CreateApp(args);
		await app.RunAsync();
	}

	/// <summary>
	/// Builds the relay exactly as <see cref="Main"/> runs it -- same services,
	/// same configuration sources -- without starting it. WO-101: this is what
	/// the loopback round-trip gate (dotnet/KcdMp.Relay.Tests) hosts
	/// in-process, so the test exercises the REAL ClientSession /
	/// TcpBroadcastService code path over a real socket, not a copy of it.
	/// Pass "--port", "0"-free values only: TcpSocketService binds the port
	/// it is given.
	/// </summary>
	public static WebApplication CreateApp(string[] args)
	{
		args = NormaliseArgs(args);

		var builder = WebApplication.CreateBuilder(args);

		// CreateBuilder already added a command-line source, but without the
		// aliases above; re-adding it last lets "--port" win over appsettings.
		builder.Configuration.AddCommandLine(args, SwitchMappings);

		// Logging config
		builder.Services.AddSerilog(options =>
		{
			options.ReadFrom.Configuration(builder.Configuration);
		});

		// Add controllers for HTTP API's
		builder.Services.AddControllers();

		// Add TCP Socket as background service
		builder.Services.AddHostedService<TcpSocketService>();

		// Announces this relay to a master server. Does nothing unless
		// MasterServer:Url is set.
		builder.Services.AddHostedService<MasterAnnounceService>();

		builder.Services.AddSingleton<ClientHandler>();
		builder.Services.AddSingleton<TcpBroadcastService>();
		builder.Services.AddSingleton<SessionManager>();
		builder.Services.AddSingleton<ClientSessionRunner>();   // WO-127: one session lifecycle for TCP and Steam

		// WO-127: Steam P2P beside the TCP listener. Does nothing unless Steam:Enabled.
		builder.Services.AddSingleton<SteamRelayStatus>();
		builder.Services.AddHostedService<SteamRelayService>();

		var app = builder.Build();

		// Map controller routs
		app.MapControllers();

		return app;
	}

	/// <summary>
	/// The configuration command-line parser requires every switch to carry a
	/// value and throws on a bare one. The old CLI used a bare "--echo", so
	/// expand it to "--echo true" rather than crash on startup.
	/// </summary>
	private static string[] NormaliseArgs(string[] args)
	{
		var result = new List<string>(args.Length + 1);

		for (int i = 0; i < args.Length; i++)
		{
			result.Add(args[i]);

			if (!args[i].Equals("--echo", StringComparison.OrdinalIgnoreCase))
				continue;

			// A bare "--echo" is one with no value after it, or one immediately
			// followed by another switch.
			bool hasValue = i + 1 < args.Length && !args[i + 1].StartsWith('-');
			if (!hasValue)
				result.Add("true");
		}

		return [.. result];
	}
}
