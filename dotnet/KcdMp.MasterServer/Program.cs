using System.Net;
using System.Text.Json.Serialization;
using KcdMp.MasterServer.Features.Announce;
using KcdMp.MasterServer.Features.Registry;
using Microsoft.AspNetCore.HttpOverrides;
using Serilog;

namespace KcdMp.MasterServer;

class Program
{
	static async Task Main(string[] args)
	{
		var builder = WebApplication.CreateBuilder(args);

		builder.Services.AddSerilog(options =>
		{
			options.ReadFrom.Configuration(builder.Configuration);
		});

		builder.Services.AddControllers().AddJsonOptions(options =>
		{
			options.JsonSerializerOptions.DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull;
		});

		builder.Services.AddSingleton<ServerRegistry>();

		await using var app = builder.Build();

		ConfigureForwardedHeaders(app);

		app.UseWebSockets(new WebSocketOptions
		{
			KeepAliveInterval = TimeSpan.FromSeconds(MasterApi.HeartbeatSeconds),
		});

		app.MapControllers();

		// Shares a prefix with ServersController's "{id}" route. A literal
		// segment outranks a parameter one in ASP.NET Core routing, so
		// /servers/connect reaches this and /servers/<id> reaches the
		// controller; the id the master hands out is a hex GUID and can never
		// collide with the literal either way.
		app.MapServerConnection();

		await app.RunAsync();
	}

	/// <summary>
	/// A listing is published under the address the relay's connection came
	/// from, so behind a reverse proxy every server would be listed as the
	/// proxy itself. Off by default: honouring X-Forwarded-For from an
	/// untrusted caller would let anyone list a server under any address.
	/// </summary>
	private static void ConfigureForwardedHeaders(WebApplication app)
	{
		if (!app.Configuration.GetValue("ForwardedHeaders:Enabled", false))
			return;

		var options = new ForwardedHeadersOptions
		{
			ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto,
		};

		// Defaults to loopback only, which covers a proxy on the same host.
		// Anything else has to be named, or its headers are ignored.
		foreach (var proxy in app.Configuration.GetSection("ForwardedHeaders:KnownProxies").Get<string[]>() ?? [])
		{
			if (IPAddress.TryParse(proxy, out var address))
				options.KnownProxies.Add(address);
			else
				app.Logger.LogWarning("Ignoring ForwardedHeaders:KnownProxies entry \"{Proxy}\": not an IP address.", proxy);
		}

		app.UseForwardedHeaders(options);
	}
}
