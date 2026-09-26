using System.Net;
using KcdMp.Server.Features.ClientHandling;
using KcdMp.Steam;
using Microsoft.AspNetCore.Mvc;

namespace KcdMp.Server.Features.Steam;

/// <summary>
/// WO-127: the host's own launcher reads Steam's state and the host's join
/// code here, and the last refused joiner release (the mixed-build message on
/// the host's side). Answers loopback callers only: the relay's HTTP port is
/// bound on every interface for the master server, and the code must never
/// leave this machine except on the host's screen.
/// </summary>
[ApiController]
[Route("api/local")]
public class LocalController : ControllerBase
{
	private readonly SteamRelayStatus _steam;
	private readonly ClientHandler _clients;

	public LocalController(SteamRelayStatus steam, ClientHandler clients)
	{
		_steam = steam;
		_clients = clients;
	}

	[HttpGet("status")]
	public IActionResult GetStatus()
	{
		var ip = HttpContext.Connection.RemoteIpAddress;
		if (ip is null || !IPAddress.IsLoopback(ip)) return NotFound();
		var s = _steam.Snapshot();
		var (rel, utc) = _clients.LastRefusedRelease;
		return Ok(new
		{
			release = RelayReleaseVersion.Current,
			steam = new
			{
				state = s.State,
				message = s.Message,
				appId = s.AppId,
				appName = s.AppId == 0 ? "" : SteamApps.Name(s.AppId),
				code = s.Code,
				peers = s.Peers,
			},
			players = _clients.ReadyClientCount,
			hostConnected = _clients.HasHostConnected(),
			refusedRelease = rel,
			refusedSecondsAgo = rel is null ? -1 : (int)(DateTime.UtcNow - utc).TotalSeconds,
		});
	}
}
