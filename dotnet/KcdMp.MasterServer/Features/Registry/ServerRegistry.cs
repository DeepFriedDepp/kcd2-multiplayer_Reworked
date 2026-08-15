using System.Collections.Concurrent;

namespace KcdMp.MasterServer.Features.Registry;

/// <summary>
/// The list of servers that are online right now.
///
/// In memory, deliberately. A listing only exists while its relay holds a
/// WebSocket open, so nothing here outlives the process anyway: if the master
/// restarts, every relay reconnects within its heartbeat and the list rebuilds
/// itself. Persisting it would only preserve rows that are already known to be
/// wrong -- which is exactly the failure the timestamp-and-hope scheme in the
/// old Python service was built to paper over.
/// </summary>
public sealed class ServerRegistry
{
	private readonly ConcurrentDictionary<string, RegisteredServer> _servers = new();
	private readonly int _maxServers;
	private readonly ILogger<ServerRegistry> _log;

	public ServerRegistry(IConfiguration configuration, ILogger<ServerRegistry> log)
	{
		_log = log;
		_maxServers = Math.Max(1, configuration.GetValue("Registry:MaxServers", 500));
	}

	public int Count => _servers.Count;

	public int TotalPlayers => _servers.Values.Sum(s => s.Players);

	/// <summary>
	/// Lists a server, replacing any earlier listing for the same address.
	///
	/// A relay that crashes and restarts before its old socket is reaped would
	/// otherwise appear twice, and a player picking the stale row would dial a
	/// server that is not there. The newer connection wins because it is the
	/// one demonstrably alive; the older one finds its id gone on its next
	/// message and closes itself.
	/// </summary>
	/// <returns>False when the master is already at its configured limit.</returns>
	public bool Add(RegisteredServer server)
	{
		foreach (var existing in _servers.Values)
		{
			if (existing.Endpoint != server.Endpoint || existing.Id == server.Id)
				continue;

			if (_servers.TryRemove(existing.Id, out _))
				_log.LogInformation("Replaced the listing for {Endpoint}; a newer connection claimed it.", existing.Endpoint);
		}

		if (_servers.Count >= _maxServers)
		{
			_log.LogWarning("Refused {Endpoint}: already listing {Count} servers (Registry:MaxServers).",
				server.Endpoint, _servers.Count);
			return false;
		}

		_servers[server.Id] = server;
		return true;
	}

	/// <summary>
	/// Applies the mutable part of a listing.
	/// </summary>
	/// <returns>
	/// False when the id is no longer listed, which means this connection was
	/// replaced by a newer one for the same address. The caller closes the
	/// socket on that, rather than letting a superseded relay keep talking.
	/// </returns>
	public bool Update(string id, ServerUpdate update, DateTimeOffset now)
	{
		while (_servers.TryGetValue(id, out var existing))
		{
			var updated = existing with
			{
				MapName    = update.MapName,
				Players    = update.Players,
				MaxPlayers = update.MaxPlayers,
				LastUpdate = now,
			};

			// Compare-and-swap rather than a plain assignment: two updates for
			// one id can only overlap if the relay's socket is being replaced,
			// and the loop then re-reads whichever record won.
			if (_servers.TryUpdate(id, updated, existing))
				return true;
		}

		return false;
	}

	/// <summary>Marks a heartbeat, so a listing can show it is still being talked to.</summary>
	public bool Touch(string id, DateTimeOffset now)
	{
		while (_servers.TryGetValue(id, out var existing))
		{
			if (_servers.TryUpdate(id, existing with { LastUpdate = now }, existing))
				return true;
		}

		return false;
	}

	/// <summary>
	/// Drops a listing.
	/// </summary>
	/// <returns>
	/// False when the id was not listed, which is the ordinary end of a
	/// connection that had already been replaced -- its listing belongs to
	/// somebody else now, and it must not be reported as going offline.
	/// </returns>
	public bool Remove(string id) => _servers.TryRemove(id, out _);

	public RegisteredServer? Get(string id) => _servers.GetValueOrDefault(id);

	/// <summary>Snapshot for the listing endpoint, ordered so the browser is stable between refreshes.</summary>
	public IReadOnlyList<RegisteredServer> All() =>
		_servers.Values.OrderByDescending(s => s.Players).ThenBy(s => s.Name, StringComparer.OrdinalIgnoreCase).ToArray();
}
