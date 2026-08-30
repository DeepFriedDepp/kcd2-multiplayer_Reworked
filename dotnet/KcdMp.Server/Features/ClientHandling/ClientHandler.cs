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
	private readonly HashSet<ClientSession> _readyClients = [];
	private readonly object _lock = new();
	private readonly int _maxPlayers;

	// ---- WO-66 claim-update validation tunables ----
	//
	// Config-backed like Tcp:Port / Echo, with the shipped defaults inline.
	// MaxSpeedMps: plausibility cap on how fast a claimed NPC may move between
	// two ACCEPTED updates from its claim holder. The fastest legitimate mover
	// on this channel is a world horse (the rescan tracks Horse-class
	// entities); 40 m/s is roughly 3x a KCD2 horse gallop -- teleport-class
	// garbage is orders of magnitude past it, so the headroom costs nothing.
	// SlackMeters absorbs jitter when elapsed time between packets is tiny.
	// Semantics ported from KCD2Online's npc_registry.cpp:240-248 (WO-64
	// Phase 3): reject if distance > MaxSpeedMps * elapsed + SlackMeters.
	private readonly double _maxNpcSpeedMps;
	private readonly double _npcSpeedSlackMeters;

	public ClientHandler(IConfiguration configuration)
	{
		_maxPlayers          = configuration.GetValue("ServerInfo:MaxPlayers", 64);
		_maxNpcSpeedMps      = configuration.GetValue("NpcClaimValidation:MaxSpeedMps", 40.0);
		_npcSpeedSlackMeters = configuration.GetValue("NpcClaimValidation:SlackMeters", 2.0);
	}

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
	/// Reserves one player slot after a valid handshake. The check and reserve
	/// happen under the same lock so simultaneous handshakes cannot overbook
	/// the relay; a socket that never handshakes consumes no player slot.
	/// </summary>
	public bool TryMarkReady(ClientSession client)
	{
		lock (_lock)
		{
			if (_readyClients.Count >= _maxPlayers)
				return false;

			return _readyClients.Add(client);
		}
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
		{
			_clients.Remove(client);
			_readyClients.Remove(client);
		}
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

	private uint? _skipOwnerId;
	private DateTime _skipStartedUtc;
	private readonly HashSet<uint> _skipJoined = [];

	// Grace record of the most recently cleared skip, so a joined client
	// whose own vanilla skip resolves shortly *after* the owner's still gets
	// its result forwarded quietly rather than announced as a second skip.
	private HashSet<uint>? _lastSkipJoined;
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

	// ---- Per-entity NPC authority (WO-39 Phase 2) ----
	//
	// The handoff item C of docs/WO-38-gaps-and-next-WOs.md asks for: "the
	// player acting on a body owns that body's stream while acting on it."
	// Same first-claim shape as the time-skip arbitration above, applied per
	// entity name, and enforced HERE -- the relay is the single arbitration
	// point, so two clients acting on the same body resolve deterministically
	// by relay arrival order, never by comparing world states.
	//
	// There is deliberately NO claim packet. A non-authority client claims an
	// entity simply by sending NpcStateUp for it (the mod only does that while
	// its player is physically manipulating the body); the claim is refreshed
	// by every packet and expires after NpcClaimTimeoutSeconds of silence, at
	// which point the global authority's ordinary stream for that entity
	// resumes flowing. The global authority's own packets never create claims
	// -- its right to emit is the default, not a claim.
	//
	// This SUPERSEDES the WO-38 Phase 6 note that a non-authority's corpse
	// drag crosses no machine. The receive side needs no change at all: the
	// body-follow one-shot in KCD2MP_NpcPuppetTick applies whoever the sender
	// is, and the echo loop is closed by this same gate (the authority's
	// re-sample of a body someone else is driving is dropped here).

	// WO-60 adds EngagedUtc: the last time the OWNER's packet carried the
	// ENGAGED flag (its player actively fighting this NPC). While that is
	// recent (NpcClaimEngagedHoldSeconds), the claim is HELD -- it cannot
	// expire on silence and cannot be taken by anyone, so a menu pause or
	// packet gap mid-fight cannot snap the entity to another sender's
	// diverged stream and back (the flap this hold exists to prevent). A
	// claim never engaged (a corpse drag) keeps the plain 5 s expiry
	// unchanged. Disconnect still releases immediately either way.
	//
	// WO-66 adds X/Y/Z: the position of the last ACCEPTED update, the speed
	// gate's baseline. It lives inside the claim entry ON PURPOSE: claim
	// expiry, disconnect clear, and reclaim all destroy it with the entry, so
	// a new claimant's first packet is never speed-checked against a previous
	// owner's data -- it seeds a fresh baseline instead.
	private readonly Dictionary<string, (uint OwnerId, DateTime LastUtc, DateTime EngagedUtc, float X, float Y, float Z)> _npcClaims = [];

	/// <summary>How <see cref="RouteNpcState"/> disposed of one NpcStateUp.</summary>
	public enum NpcRoute
	{
		/// <summary>Accepted: fan it out.</summary>
		Broadcast,
		/// <summary>The authority's re-sample of an entity someone else is
		/// driving -- the WO-39 echo-loop mute. Normal operation, not a
		/// validation rejection: dropped quietly, not counted.</summary>
		MutedEcho,
		/// <summary>WO-66: claimed-NPC update implying implausible movement.</summary>
		RejectSpeed,
		/// <summary>WO-66: NPC claim for one of the mod's own spawn names.</summary>
		RejectReservedName,
		/// <summary>WO-66: update for a claimed NPC from a sender who is not
		/// the current claim holder (a rival, or a former owner's late
		/// packet after release-and-reclaim).</summary>
		RejectStaleOwner,
	}

	// ---- WO-66 rejection counters ----
	//
	// One per reason tag; Interlocked because the rotation/finite counter is
	// bumped from ClientSession outside _lock. Read at runtime through the
	// relay's existing diagnostics surface, GET api/information/npc-validation
	// (InformationController), alongside the [WO66-REJECT] log lines.
	private long _rejectSpeed, _rejectRotation, _rejectReservedName, _rejectStaleOwner;

	/// <summary>WO-66: count one rejected packet whose rotation (or position)
	/// failed the finite check in ClientSession's framing layer.</summary>
	public void CountNpcRejectRotation() => Interlocked.Increment(ref _rejectRotation);

	/// <summary>WO-66: count one non-finite-position rejection (tagged under
	/// the speed reason: it is the position-plausibility class).</summary>
	public void CountNpcRejectSpeed() => Interlocked.Increment(ref _rejectSpeed);

	/// <summary>Snapshot of the WO-66 rejection counters.</summary>
	public NpcValidationCounters GetNpcValidationCounters() => new(
		Interlocked.Read(ref _rejectSpeed),
		Interlocked.Read(ref _rejectRotation),
		Interlocked.Read(ref _rejectReservedName),
		Interlocked.Read(ref _rejectStaleOwner));

	/// <summary>
	/// Decides whether one NpcStateUp for <paramref name="npcName"/> from
	/// <paramref name="sender"/> may be broadcast, updating the per-entity
	/// claim table. <paramref name="engaged"/> is the packet's
	/// <see cref="Protocol.NpcStateFlagEngaged"/> bit; it only matters on a
	/// claimant's own packets. <paramref name="x"/>/<paramref name="y"/>/
	/// <paramref name="z"/> are the packet's position, for the WO-66 speed
	/// gate. See the field comment for the claim rules.
	///
	/// WO-66 invariant: a rejected packet mutates NOTHING -- not the claim,
	/// not its timestamps (so garbage cannot refresh a claim or re-arm the
	/// engaged hold), not the baseline. It is bad data, not evidence the
	/// owner is gone; a claim fed only garbage simply expires on the
	/// ordinary silence path and the next claim re-seeds the baseline --
	/// which is also how a genuine legitimate teleport (claimant reload)
	/// self-heals within one expiry window.
	/// </summary>
	public NpcRoute RouteNpcState(ClientSession sender, string npcName, bool engaged, float x, float y, float z)
	{
		lock (_lock)
		{
			var now = DateTime.UtcNow;
			bool claimed = _npcClaims.TryGetValue(npcName, out var claim);
			if (claimed
			    && (now - claim.LastUtc).TotalSeconds > Protocol.NpcClaimTimeoutSeconds
			    && (now - claim.EngagedUtc).TotalSeconds > Protocol.NpcClaimEngagedHoldSeconds)
			{
				_npcClaims.Remove(npcName);
				claimed = false;
			}

			if (IsDamageAuthority(sender))
			{
				// The default stream. Yields only to someone else's live claim.
				return !claimed || claim.OwnerId == sender.Id
					? NpcRoute.Broadcast : NpcRoute.MutedEcho;
			}

			if (claimed && claim.OwnerId != sender.Id)
			{
				// Someone else holds this body. Sender identity is the TCP
				// session itself, so this also covers the stale-owner case: a
				// former owner's late packet after release-and-reclaim arrives
				// as a non-owner and lands here. Never releases anything.
				Interlocked.Increment(ref _rejectStaleOwner);
				return NpcRoute.RejectStaleOwner;
			}

			if (!claimed)
			{
				// A new claim. Never for one of our own spawns: see
				// Protocol.NpcReservedNamePrefix.
				if (npcName.StartsWith(Protocol.NpcReservedNamePrefix, StringComparison.OrdinalIgnoreCase))
				{
					Interlocked.Increment(ref _rejectReservedName);
					return NpcRoute.RejectReservedName;
				}
				// First claim wins, by relay arrival order. This packet seeds
				// the speed-gate baseline; it is deliberately not speed-checked
				// (there is nothing of THIS owner's to check it against).
				_npcClaims[npcName] = (sender.Id, now, engaged ? now : DateTime.MinValue, x, y, z);
				return NpcRoute.Broadcast;
			}

			// Owner refresh. Speed gate BEFORE the state write, so a rejected
			// packet cannot refresh the claim or re-arm the engaged hold.
			double elapsed = (now - claim.LastUtc).TotalSeconds;
			double allowed = _maxNpcSpeedMps * elapsed + _npcSpeedSlackMeters;
			double dx = x - claim.X, dy = y - claim.Y, dz = z - claim.Z;
			if (dx * dx + dy * dy + dz * dz > allowed * allowed)
			{
				Interlocked.Increment(ref _rejectSpeed);
				return NpcRoute.RejectSpeed;
			}

			_npcClaims[npcName] = (sender.Id, now, engaged ? now : claim.EngagedUtc, x, y, z);
			return NpcRoute.Broadcast;   // refresh (and re-arm the hold if still engaged)
		}
	}

	/// <summary>
	/// Drops every claim <paramref name="client"/> holds -- called on
	/// disconnect, so a dragger who vanishes mid-drag releases their bodies
	/// immediately instead of wedging them until the timeout.
	/// </summary>
	public void ClearNpcClaimsFor(ClientSession client)
	{
		lock (_lock)
		{
			var mine = new List<string>();
			foreach (var kv in _npcClaims)
				if (kv.Value.OwnerId == client.Id) mine.Add(kv.Key);
			foreach (var name in mine)
				_npcClaims.Remove(name);
		}
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
				return _readyClients.Count;
		}
	}
}
