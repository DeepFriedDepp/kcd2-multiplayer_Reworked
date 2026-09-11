using KcdMp.Server.Features.ClientHandling;
using KcdMp.Server.Features.ServerInformation.Dtos;
using Microsoft.AspNetCore.Mvc;

namespace KcdMp.Server.Features.ServerInformation.Controllers;

/// <summary>
/// Controller for endpoints that provide server information.
///
/// Called by the master server.
/// </summary>
[ApiController]
[Route("api/[controller]")]
public class InformationController : ControllerBase
{
	private readonly ServerInfo _serverInfo;
	private readonly ClientHandler _clientHandler;
	
	public InformationController(IConfiguration configuration, ClientHandler clientHandler)
	{
		// TODO: Make this actually configurable
		var infoSection = configuration.GetSection("ServerInfo");
		infoSection.Bind(_serverInfo = new ServerInfo());
		
		_clientHandler = clientHandler;
	}
	
	/// <summary>
	/// Returns the server's main information.
	/// </summary>
	/// <returns></returns>
	[HttpGet]
	[ProducesResponseType(StatusCodes.Status200OK)]
	public IActionResult GetInfo()
	{
		_serverInfo.Players = _clientHandler.ReadyClientCount;

		return Ok(_serverInfo);
	}

	/// <summary>
	/// WO-66: running NPC claim-update rejection counters, one per
	/// [WO66-REJECT] reason tag. All zero on a healthy wire.
	/// </summary>
	[HttpGet("npc-validation")]
	[ProducesResponseType(StatusCodes.Status200OK)]
	public IActionResult GetNpcValidation() =>
		Ok(_clientHandler.GetNpcValidationCounters());

	/// <summary>
	/// WO-81: running NPC claim-lifecycle counters (grants, releases,
	/// reassignments, contested), one per [CLAIM]/[CLAIM-CONTESTED] log line.
	/// A sibling of npc-validation rather than an addition to it -- that
	/// record is WO-66's rejection-reason tally, a different concern from
	/// lifecycle events on claims that were accepted.
	/// </summary>
	[HttpGet("npc-claims")]
	[ProducesResponseType(StatusCodes.Status200OK)]
	public IActionResult GetNpcClaims() =>
		Ok(_clientHandler.GetNpcClaimCounters());
}
