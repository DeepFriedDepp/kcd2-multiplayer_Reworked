using KcdMp.MasterServer.Features.Registry;
using Microsoft.AspNetCore.Mvc;

namespace KcdMp.MasterServer.Features.Listing.Controllers;

/// <summary>
/// The server browser's side of the master: read-only, anonymous, and cheap
/// enough to poll.
///
/// Nothing here can add or remove a listing. A server only appears by holding
/// a WebSocket open (see ServerConnectionEndpoint), which is what makes the
/// list trustworthy: every row is a connection that was alive when this
/// response was written.
/// </summary>
[ApiController]
// Must stay in step with MasterApi.ListPath, which is what the launcher asks
// for. A route template cannot be a const expression, so it is spelled out.
[Route("api/v1/servers")]
public class ServersController : ControllerBase
{
	private readonly ServerRegistry _registry;

	public ServersController(ServerRegistry registry)
	{
		_registry = registry;
	}

	/// <summary>Every server currently online.</summary>
	[HttpGet]
	[ProducesResponseType(StatusCodes.Status200OK)]
	public ActionResult<ServerListResponse> GetAll()
	{
		return Ok(new ServerListResponse
		{
			ApiVersion = MasterApi.Version,
			Servers = _registry.All().Select(s => s.ToListing()).ToArray(),
		});
	}

	/// <summary>
	/// One server, by the id the master assigned it. Useful for a detail view
	/// that should not have to re-read the whole list.
	/// </summary>
	[HttpGet("{id}")]
	[ProducesResponseType(StatusCodes.Status200OK)]
	[ProducesResponseType(StatusCodes.Status404NotFound)]
	public ActionResult<ServerListing> Get(string id)
	{
		var server = _registry.Get(id);

		// A 404 here means "that server went offline", which is the common
		// case rather than an error -- a listing id only lives as long as the
		// connection that owns it.
		return server is null ? NotFound() : Ok(server.ToListing());
	}
}
