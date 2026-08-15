namespace KcdMp.MasterServer.Features.Registry;

/// <summary>
/// One listed server, as the master holds it.
///
/// Immutable: the socket thread swaps a whole new instance into the registry
/// when a player count changes while the listing endpoint may be reading the
/// old one. A mutable object shared between the two would need a lock at every
/// field, and would let the launcher observe a half-applied update.
/// </summary>
public sealed record RegisteredServer
{
	/// <summary>Assigned by the master, held by the relay's connection for its lifetime.</summary>
	public required string Id { get; init; }

	/// <summary>The address peers connect to, together with <see cref="Port"/>.</summary>
	public required string Address { get; init; }

	public required int Port { get; init; }
	public int InfoPort { get; init; }

	public required string Name { get; init; }
	public string ReleaseVersion { get; init; } = "";
	public byte ProtocolVersion { get; init; }

	public string MapName { get; init; } = "";
	public int Players { get; init; }
	public int MaxPlayers { get; init; }

	public string[] Tags { get; init; } = [];
	public string? Description { get; init; }

	public DateTimeOffset OnlineSince { get; init; }
	public DateTimeOffset LastUpdate { get; init; }

	/// <summary>
	/// Identifies the server by what a player actually dials, which is the
	/// only thing two registrations can genuinely collide on -- see
	/// <see cref="ServerRegistry.Add"/>.
	/// </summary>
	public string Endpoint => $"{Address}:{Port}";

	public ServerListing ToListing() => new()
	{
		Id              = Id,
		Name            = Name,
		Address         = Address,
		Port            = Port,
		InfoPort        = InfoPort,
		MapName         = MapName,
		Players         = Players,
		MaxPlayers      = MaxPlayers,
		ReleaseVersion  = ReleaseVersion,
		ProtocolVersion = ProtocolVersion,
		Tags            = Tags,
		Description     = Description,
		OnlineSince     = OnlineSince,
	};
}
