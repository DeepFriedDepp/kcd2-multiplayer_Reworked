using ILogger = Serilog.ILogger;

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
	private readonly ILogger _logger;
	private readonly List<ClientSession> _clients = [];
	private readonly HashSet<ClientSession> _readyClients = [];
	private readonly object _lock = new();
	private readonly int _maxPlayers;

	// WO-76 (docs/WO-75-audit-findings.md s1): a free-list pool of the wire's
	// byte-wide session ids. ClientSession.Id stays a byte until PR #3 widens
	// it to uint; until then, an ever-incrementing counter wraps after 256
	// connections in one relay lifetime and two live sessions can end up
	// sharing an id. Reserved only here, when a handshake actually completes
	// (TryMarkReady) -- a probe, a version mismatch, or a rejected-for-full
	// connection never burns one -- and released back to the pool on
	// disconnect (RemoveClient), so a long-lived relay can serve far more
	// than 256 total connections without ever handing out a live-colliding id.
	private readonly Queue<byte> _freeIds = new(Enumerable.Range(0, 256).Select(i => (byte)i));

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

	// ---- WO-81 claim-lifecycle logging tunables ----
	//
	// A claim transition (grant/release/reassignment) happens orders of
	// magnitude less often than a per-tick position update, so unlike a hot
	// path there is no real cost argument for shipping this off by default --
	// and the project is actively bug-hunting the claim system on a live field
	// report (a 2026-09-11 session describing NPC jitter that "fought over
	// authority" when players stood close together). Visibility now is worth
	// more than saving a few log lines nobody asked to see, so this defaults
	// ON rather than requiring an operator to discover and flip a flag before
	// the next incident. Same section as the WO-66 gates it instruments.
	private readonly bool _claimLifecycleLoggingEnabled;
	private readonly double _contestedGapSeconds;

	public ClientHandler(ILogger logger, IConfiguration configuration)
	{
		_logger = logger;

		// WO-76 (docs/WO-75-audit-findings.md s1): 0 was accepted at face
		// value and refused every handshake (TryMarkReady's count-vs-limit
		// check can never pass), bricking the relay with no indication why.
		int configuredMaxPlayers = configuration.GetValue("ServerInfo:MaxPlayers", 64);
		_maxPlayers = Math.Max(1, configuredMaxPlayers);
		if (_maxPlayers != configuredMaxPlayers)
			logger.Warning("[!] ServerInfo:MaxPlayers={Configured} is invalid; clamped to {Effective}.",
				configuredMaxPlayers, _maxPlayers);
		logger.Information("Max players: {MaxPlayers}", _maxPlayers);

		_maxNpcSpeedMps      = configuration.GetValue("NpcClaimValidation:MaxSpeedMps", 40.0);
		_npcSpeedSlackMeters = configuration.GetValue("NpcClaimValidation:SlackMeters", 2.0);

		_claimLifecycleLoggingEnabled = configuration.GetValue("NpcClaimValidation:ClaimLifecycleLogging", true);
		_contestedGapSeconds          = configuration.GetValue("NpcClaimValidation:ContestedGapSeconds", 10.0);
	}

	/// <summary>The effective (clamped) player cap, echoed in the ServerFull (0x36) packet.</summary>
	public int MaxPlayers => _maxPlayers;

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
	/// Reserves one player slot and one wire id after a valid handshake. The
	/// check and reserve happen under the same lock so simultaneous
	/// handshakes cannot overbook the relay; a socket that never handshakes
	/// consumes neither a player slot nor an id (WO-76).
	/// </summary>
	public bool TryMarkReady(ClientSession client)
	{
		lock (_lock)
		{
			if (_readyClients.Count >= _maxPlayers || _freeIds.Count == 0)
				return false;

			client.Id = _freeIds.Dequeue();
			return _readyClients.Add(client);
		}
	}

	/// <summary>
	/// Remove a client.
	///
	/// Called when a client disconnects. Only a client that was ever marked
	/// ready holds a pooled id to release (WO-76) -- one that dropped mid- or
	/// pre-handshake never reserved one.
	/// </summary>
	/// <param name="client"></param>
	public void RemoveClient(ClientSession client)
	{
		lock (_lock)
		{
			_clients.Remove(client);
			if (_readyClients.Remove(client))
				_freeIds.Enqueue(client.Id);
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

	// ---- WO-81 diagnostic position cache ----
	//
	// The relay already parses every Position (0x01) packet in ClientSession
	// to build the outgoing Ghost packet, but never retained it -- Phase 0 of
	// this WO confirmed there was no existing cache to reuse. This one exists
	// SOLELY to answer "how far apart were the two players" on a contested
	// claim log line; it is never read by RouteNpcState or any other decision
	// path. Read-only observation, same discipline as every other diagnostic
	// surface in this project -- see docs/WO-81-findings.md.
	private readonly Dictionary<byte, (float X, float Y, float Z)> _playerPositions = [];

	/// <summary>WO-81: records the sender's latest reported position, diagnostic-only.</summary>
	public void RecordPlayerPosition(ClientSession sender, float x, float y, float z)
	{
		lock (_lock)
			_playerPositions[sender.Id] = (x, y, z);
	}

	/// <summary>WO-81: drops a disconnected client's cached position.</summary>
	public void ClearPlayerPositionFor(ClientSession client)
	{
		lock (_lock)
			_playerPositions.Remove(client.Id);
	}

	/// <summary>
	/// WO-81: Euclidean distance between two sessions' last-known positions,
	/// or "unknown" if either has not reported one. Caller must already hold
	/// <see cref="_lock"/> -- this reads <see cref="_playerPositions"/> directly.
	/// </summary>
	private string DistanceBetweenLocked(byte a, byte b)
	{
		if (!_playerPositions.TryGetValue(a, out var pa) || !_playerPositions.TryGetValue(b, out var pb))
			return "unknown";
		double dx = pa.X - pb.X, dy = pa.Y - pb.Y, dz = pa.Z - pb.Z;
		return Math.Sqrt(dx * dx + dy * dy + dz * dz).ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
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
	// WO-81 adds GrantedUtc: when this claim entry was first created, kept
	// alongside LastUtc (last accepted refresh) so a release can log
	// heldForSec -- how long the claim actually lasted, not just how stale it
	// was when it finally lapsed.
	private readonly Dictionary<string, (byte OwnerId, DateTime GrantedUtc, DateTime LastUtc, DateTime EngagedUtc, float X, float Y, float Z)> _npcClaims = [];

	// WO-81: the previous owner and last-touched moment for a name that has
	// been released, kept AFTER the entry leaves _npcClaims so the next claim
	// on that name can tell "brand new" (granted) apart from "someone is
	// reclaiming a body that had an owner before" (reassigned), and compute
	// the gap between the two.
	//
	// LastActiveUtc is the released claim's OWN LastUtc (its last accepted
	// packet), not the moment of removal. Removal is lazy -- an expired claim
	// is only actually deleted when some later packet triggers the check in
	// RouteNpcState, which for the reassignment path is the SAME packet that
	// then grants the new claim. Stamping "now" at removal would therefore
	// make every expiry-driven reassignment's gap read as ~0.0 regardless of
	// how long the body actually sat unclaimed (caught by
	// Test-NpcClaimLifecycle.ps1's T5 case). LastUtc is the real moment
	// nobody was touching this claim any more, so "now - LastActiveUtc" is
	// the genuine silence duration a rival reassignment interrupted.
	//
	// Overwritten on every release; never cleaned up otherwise -- the NPC
	// name space here is bounded (named world NPCs + the capped ghost/horse
	// pool), so this cannot grow unbounded over a relay's lifetime.
	private readonly Dictionary<string, (byte PrevOwnerId, DateTime LastActiveUtc)> _recentReleases = [];

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

	// ---- WO-81 claim-lifecycle counters ----
	//
	// One per event kind, matching the [CLAIM]/[CLAIM-CONTESTED] log lines,
	// same shape as WO-66's rejection counters above. Interlocked for the
	// same reason: read from the HTTP endpoint outside _lock. ContestedByNpc
	// is the one per-NPC breakdown kept (guarded by _lock, not Interlocked --
	// it is only ever touched from inside RouteNpcState/ClearNpcClaimsFor,
	// which already hold it): grants/releases/reassignments happen routinely
	// for any claim-using feature, but a contested claim is the rare, actually
	// diagnostic event this WO exists to surface, so only it gets a per-NPC
	// breakdown -- a per-NPC table for the other three would just be a bigger
	// version of the same totals for no analytical gain.
	private long _claimGrants, _claimReleases, _claimReassignments, _claimContested;
	private readonly Dictionary<string, long> _claimContestedByNpc = [];

	/// <summary>Snapshot of the WO-81 claim-lifecycle counters.</summary>
	public NpcClaimCounters GetNpcClaimCounters()
	{
		lock (_lock)
			return new NpcClaimCounters(
				Interlocked.Read(ref _claimGrants),
				Interlocked.Read(ref _claimReleases),
				Interlocked.Read(ref _claimReassignments),
				Interlocked.Read(ref _claimContested),
				new Dictionary<string, long>(_claimContestedByNpc));
	}

	/// <summary>
	/// WO-81: logs and counts a contested claim -- a reassignment or a
	/// stale-owner rejection whose gap since the current/previous owner's
	/// last accepted packet is under <see cref="_contestedGapSeconds"/>. Caller
	/// must already hold <see cref="_lock"/>.
	/// </summary>
	private void LogContestedLocked(string npcName, byte prevOwnerId, byte newOwnerId, double gapSec)
	{
		Interlocked.Increment(ref _claimContested);
		_claimContestedByNpc.TryGetValue(npcName, out long count);
		_claimContestedByNpc[npcName] = count + 1;
		_logger.Information(
			"[CLAIM-CONTESTED] npc={Npc} prevOwner={PrevOwner} newOwner={NewOwner} gapSec={GapSec:F1} distanceBetweenPlayers={Distance}",
			npcName, prevOwnerId, newOwnerId, gapSec, DistanceBetweenLocked(prevOwnerId, newOwnerId));
	}

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

				if (_claimLifecycleLoggingEnabled)
				{
					_recentReleases[npcName] = (claim.OwnerId, claim.LastUtc);
					Interlocked.Increment(ref _claimReleases);
					_logger.Information("[CLAIM] released npc={Npc} owner={Owner} reason=expiry heldForSec={HeldForSec:F1}",
						npcName, claim.OwnerId, (now - claim.GrantedUtc).TotalSeconds);
				}
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

				// WO-81: this is "someone tried to take an actively-live
				// claim" by definition -- claimed is only still true here
				// because claim.LastUtc is within NpcClaimTimeoutSeconds (5s),
				// which is well under the default 10s ContestedGapSeconds, so
				// under shipped defaults every stale-owner rejection reports
				// contested. That is not double-counting a coincidence: a
				// rival being rejected because the claim is LIVE is exactly
				// the contest this detector exists to surface, just via the
				// rejection path rather than the reassignment path below.
				if (_claimLifecycleLoggingEnabled)
				{
					double gapSec = (now - claim.LastUtc).TotalSeconds;
					if (gapSec < _contestedGapSeconds)
						LogContestedLocked(npcName, claim.OwnerId, sender.Id, gapSec);
				}
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
				_npcClaims[npcName] = (sender.Id, now, now, engaged ? now : DateTime.MinValue, x, y, z);

				if (_claimLifecycleLoggingEnabled)
				{
					// WO-81: a name this WO has seen released before is a
					// reassignment (someone claiming a body that had an owner);
					// one it has never seen released is a fresh grant. A
					// same-session reclaim of its own prior release (nobody
					// else ever took it) is left as a grant too -- nothing was
					// contested for that case.
					if (_recentReleases.TryGetValue(npcName, out var released) && released.PrevOwnerId != sender.Id)
					{
						double gapSec = (now - released.LastActiveUtc).TotalSeconds;
						Interlocked.Increment(ref _claimReassignments);
						_logger.Information("[CLAIM] reassigned npc={Npc} prevOwner={PrevOwner} newOwner={NewOwner} gapSec={GapSec:F1}",
							npcName, released.PrevOwnerId, sender.Id, gapSec);
						if (gapSec < _contestedGapSeconds)
							LogContestedLocked(npcName, released.PrevOwnerId, sender.Id, gapSec);
					}
					else
					{
						Interlocked.Increment(ref _claimGrants);
						_logger.Information("[CLAIM] granted npc={Npc} owner={Owner} pos=({X:F1},{Y:F1},{Z:F1})",
							npcName, sender.Id, x, y, z);
					}
				}
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

			_npcClaims[npcName] = (sender.Id, claim.GrantedUtc, now, engaged ? now : claim.EngagedUtc, x, y, z);
			return NpcRoute.Broadcast;   // refresh (and re-arm the hold if still engaged; NOT logged -- see class notes)
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
			var now = DateTime.UtcNow;
			var mine = new List<string>();
			foreach (var kv in _npcClaims)
				if (kv.Value.OwnerId == client.Id) mine.Add(kv.Key);
			foreach (var name in mine)
			{
				var claim = _npcClaims[name];
				_npcClaims.Remove(name);

				if (_claimLifecycleLoggingEnabled)
				{
					_recentReleases[name] = (claim.OwnerId, claim.LastUtc);
					Interlocked.Increment(ref _claimReleases);
					_logger.Information("[CLAIM] released npc={Npc} owner={Owner} reason=disconnect heldForSec={HeldForSec:F1}",
						name, client.Id, (now - claim.GrantedUtc).TotalSeconds);
				}
			}
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
