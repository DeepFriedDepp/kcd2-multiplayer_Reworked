namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// Helper class for client handling.
///
/// All members are thread-safe: connects and disconnects arrive on the accept
/// loop while broadcasts and the info endpoint read the list concurrently, so
/// the lock lives here rather than at each call site.
/// </summary>
public class ClientHandler
{
	private readonly List<ClientSession> _clients = [];
	private readonly object _lock = new();

	/// <summary>
	/// Add a client.
	///
	/// Called when a client connects.
	/// </summary>
	/// <param name="client"></param>
	public void AddClient(ClientSession client)
	{
		lock (_lock)
			_clients.Add(client);
	}

	/// <summary>
	/// Remove a client.
	///
	/// Called when a client disconnects.
	/// </summary>
	/// <param name="client"></param>
	public void RemoveClient(ClientSession client)
	{
		lock (_lock)
			_clients.Remove(client);
	}

	/// <summary>
	/// Gets a copy of the client list to prevent outside manipulation.
	/// </summary>
	/// <returns></returns>
	public ClientSession[] GetClients()
	{
		lock (_lock)
			return _clients.ToArray();
	}

	/// <summary>
	/// The client currently holding Rule 2's NPC→player damage authority
	/// (WO-28), or null when nobody is connected yet.
	///
	/// Only one client's NPC simulation may generate hits against players, or
	/// N peers produce N independent damage streams for one conceptual fight
	/// and the damage multiplies by N -- see Protocol's 0x21 documentation.
	///
	/// Defined as the lowest-id ready client. That is the session host in
	/// practice (the host's own agent connects to its local relay first), but
	/// it is deliberately defined on the connection set rather than on who
	/// started the relay process, because the relay cannot observe the latter
	/// and because it must keep having an answer after the host leaves.
	/// Derived on read from state the handler already keeps -- no world state
	/// is introduced here.
	/// </summary>
	public ClientSession? DamageAuthority
	{
		get
		{
			lock (_lock)
			{
				ClientSession? best = null;
				foreach (var c in _clients)
					if (c.IsReady && (best is null || c.Id < best.Id))
						best = c;
				return best;
			}
		}
	}

	/// <summary>True if <paramref name="client"/> currently holds damage authority.</summary>
	public bool IsDamageAuthority(ClientSession client) =>
		ReferenceEquals(DamageAuthority, client);

	/// <summary>
	/// Returns the current player count.
	/// </summary>
	public int ClientCount
	{
		get
		{
			lock (_lock)
				return _clients.Count;
		}
	}

	/// <summary>
	/// Clients that finished the handshake, as opposed to <see cref="ClientCount"/>
	/// which includes a connection still mid-handshake or one that opened and
	/// dropped without ever sending one -- exactly what a launcher's reachability
	/// probe to the game port looks like from here. Used for the master server
	/// listing (WO-35) so a probe cannot show up as a phantom player.
	/// </summary>
	public int ReadyClientCount
	{
		get
		{
			lock (_lock)
			{
				int count = 0;
				foreach (var c in _clients)
					if (c.IsReady) count++;
				return count;
			}
		}
	}
}
