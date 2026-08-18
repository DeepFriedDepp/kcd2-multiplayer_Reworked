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

	// ---- Time-skip sync (WO-38 Phase 1) ----
	//
	// The session's one active skip: whichever client's TimeSkipUp(start)
	// arrived first owns it; everyone who starts a skip while it is active is
	// recorded as joined instead of getting a competing claim. Deterministic
	// by arrival order at this relay -- never by comparing finished results.
	// Deliberately NOT tied to Rule 2's damage authority: any player's sleep
	// counts (WO-38 spec), so this layer has its own first-come arbitration.

	private byte? _skipOwnerId;
	private DateTime _skipStartedUtc;
	private readonly HashSet<byte> _skipJoined = [];

	// Grace record of the most recently cleared skip, so a joined client
	// whose own vanilla skip resolves shortly *after* the owner's still gets
	// its result forwarded quietly rather than announced as a second skip.
	private HashSet<byte>? _lastSkipJoined;
	private DateTime _lastSkipClearedUtc;

	/// <summary>What the relay should do with an inbound TimeSkipUp.</summary>
	public enum TimeSkipRouting
	{
		/// <summary>Drop it (a duplicate start, or a joined player's start).</summary>
		None,
		/// <summary>Broadcast it as phase=start.</summary>
		BroadcastStart,
		/// <summary>Broadcast it as phase=done (announced).</summary>
		BroadcastDone,
		/// <summary>Broadcast it as phase=done-quiet (applied, not announced).</summary>
		BroadcastDoneQuiet,
	}

	/// <summary>
	/// A client reported a skip starting. First claim wins and is broadcast;
	/// anyone else is joined to the active skip and their start is dropped.
	/// </summary>
	public TimeSkipRouting BeginTimeSkip(ClientSession client)
	{
		lock (_lock)
		{
			ExpireTimeSkipLocked();
			if (_skipOwnerId is null)
			{
				_skipOwnerId = client.Id;
				_skipStartedUtc = DateTime.UtcNow;
				_skipJoined.Clear();
				return TimeSkipRouting.BroadcastStart;
			}
			if (_skipOwnerId == client.Id)
				return TimeSkipRouting.None;   // duplicate start marker for the same skip
			_skipJoined.Add(client.Id);
			return TimeSkipRouting.None;       // joined -- absorbed into the active skip
		}
	}

	/// <summary>
	/// A client reported a skip finishing (or a detected clock jump, which
	/// arrives as a bare done). See <see cref="Protocol"/>'s 0x28 notes for the
	/// three outcomes.
	/// </summary>
	public TimeSkipRouting CompleteTimeSkip(ClientSession client)
	{
		lock (_lock)
		{
			ExpireTimeSkipLocked();
			if (_skipOwnerId is not null)
			{
				if (_skipOwnerId == client.Id)
				{
					ClearTimeSkipToGraceLocked();
					return TimeSkipRouting.BroadcastDone;
				}
				// A joined player's own skip resolved before the owner's.
				// Forward quietly: convergence without a second notification.
				return TimeSkipRouting.BroadcastDoneQuiet;
			}
			if (_lastSkipJoined is not null
			    && (DateTime.UtcNow - _lastSkipClearedUtc).TotalSeconds <= Protocol.TimeSkipJoinGraceSeconds
			    && _lastSkipJoined.Contains(client.Id))
				return TimeSkipRouting.BroadcastDoneQuiet;
			// No active skip, not a late joiner: an instant skip (the
			// fast-travel clock-jump shape). Announce it.
			return TimeSkipRouting.BroadcastDone;
		}
	}

	/// <summary>Clears the active skip if <paramref name="client"/> owned it -- called on disconnect.</summary>
	public void ClearTimeSkipFor(ClientSession client)
	{
		lock (_lock)
			if (_skipOwnerId == client.Id)
				ClearTimeSkipToGraceLocked();
	}

	private void ExpireTimeSkipLocked()
	{
		if (_skipOwnerId is not null
		    && (DateTime.UtcNow - _skipStartedUtc).TotalSeconds > Protocol.TimeSkipTimeoutSeconds)
			ClearTimeSkipToGraceLocked();
	}

	private void ClearTimeSkipToGraceLocked()
	{
		_lastSkipJoined = [.. _skipJoined];
		_lastSkipClearedUtc = DateTime.UtcNow;
		_skipOwnerId = null;
		_skipJoined.Clear();
	}

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
