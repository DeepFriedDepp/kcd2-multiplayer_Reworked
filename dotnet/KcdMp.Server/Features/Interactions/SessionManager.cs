using KcdMp.Server.Features.ClientHandling;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.Interactions;

/// <summary>
/// Owns paired-interaction sessions.
///
/// This is the one place in the relay that holds state, and it is deliberate.
/// The presence layer is a dumb rebroadcaster because there is nothing to
/// arbitrate about two players' positions. Interactions are different: somebody
/// has to decide who is in a session, refuse a second one, and rule on what
/// happens when a participant walks out or drops off the network. Doing that on
/// either client would mean trusting a peer, and dice (WO-3) explicitly needs
/// the relay to own the RNG so neither side can cheat a roll.
///
/// The state machine is small on purpose:
///
///   Pending  — invite sent, waiting on the invitee. Expires after
///              <see cref="Protocol.InviteTimeoutSeconds"/>.
///   Active   — both accepted. Session events flow between the two.
///   (gone)   — ended for some <see cref="SessionEndReason"/> and forgotten.
///
/// A client may be in at most one session, pending or active. That is what
/// makes "is this player busy?" answerable, and it keeps invite storms from
/// turning into a scheduling problem.
/// </summary>
public class SessionManager
{
	private readonly ILogger _logger;
	private readonly object _lock = new();

	private readonly Dictionary<ushort, Session> _sessions = [];
	private ushort _nextId = 1;

	public SessionManager(ILogger logger)
	{
		_logger = logger;
	}

	/// <summary>One paired interaction, pending or active.</summary>
	public sealed class Session
	{
		public required ushort Id { get; init; }
		public required InteractionKind Kind { get; init; }
		public required ClientSession Initiator { get; init; }
		public required ClientSession Acceptor { get; init; }
		public bool IsActive { get; set; }
		public DateTime CreatedUtc { get; init; } = DateTime.UtcNow;

		public bool Involves(ClientSession c) => Initiator == c || Acceptor == c;
		public ClientSession Other(ClientSession c) => Initiator == c ? Acceptor : Initiator;
	}

	/// <summary>
	/// Handles an Invite. Returns the created session, or null when it was
	/// refused — in which case the caller has already been told why.
	/// </summary>
	public Session? Invite(ClientSession from, byte targetId, InteractionKind kind, ClientHandler clients)
	{
		if (!Enum.IsDefined(kind))
		{
			_logger.Warning("[session] {From} sent an invite with unknown kind {Kind}", from.Name, (byte)kind);
			from.EnqueueSessionEnd(0, SessionEndReason.ProtocolError);
			return null;
		}

		var target = clients.GetClients().FirstOrDefault(c => c.Id == targetId && c.IsReady);
		if (target is null || target == from)
		{
			// Inviting yourself is a client bug, not a hostile act, but there is
			// no session to be had either way.
			from.EnqueueSessionEnd(0, SessionEndReason.TargetUnavailable);
			return null;
		}

		lock (_lock)
		{
			if (FindByClient(from) is not null || FindByClient(target) is not null)
			{
				from.EnqueueSessionEnd(0, SessionEndReason.TargetBusy);
				return null;
			}

			var session = new Session
			{
				Id = NextId(),
				Kind = kind,
				Initiator = from,
				Acceptor = target,
			};
			_sessions[session.Id] = session;

			_logger.Information("[session {Id}] {From} invited {To} to {Kind}",
				session.Id, from.Name, target.Name, kind);

			target.EnqueueInviteReceived(session.Id, from.Id, kind);
			return session;
		}
	}

	/// <summary>
	/// Handles an InviteResponse. Only the invitee may answer, and only while
	/// the session is still pending.
	/// </summary>
	public void Respond(ClientSession from, ushort sessionId, bool accept)
	{
		Session? session;
		lock (_lock)
		{
			if (!_sessions.TryGetValue(sessionId, out session)) return;

			// Guard against a client answering its own invite or re-answering an
			// already-active session.
			if (session.Acceptor != from || session.IsActive)
			{
				from.EnqueueSessionEnd(sessionId, SessionEndReason.ProtocolError);
				return;
			}

			if (!accept)
			{
				_sessions.Remove(sessionId);
			}
			else
			{
				session.IsActive = true;
			}
		}

		if (!accept)
		{
			_logger.Information("[session {Id}] declined by {Who}", sessionId, from.Name);
			session.Initiator.EnqueueSessionEnd(sessionId, SessionEndReason.Declined);
			session.Acceptor.EnqueueSessionEnd(sessionId, SessionEndReason.Declined);
			return;
		}

		_logger.Information("[session {Id}] {Kind} started: {A} vs {B}",
			sessionId, session.Kind, session.Initiator.Name, session.Acceptor.Name);

		session.Initiator.EnqueueSessionStart(sessionId, session.Acceptor.Id, session.Kind, SessionRole.Initiator);
		session.Acceptor.EnqueueSessionStart(sessionId, session.Initiator.Id, session.Kind, SessionRole.Acceptor);
	}

	/// <summary>
	/// Relays a session event to the other participant. Only active sessions
	/// carry events, and only participants may send them — otherwise a client
	/// could inject events into somebody else's game by guessing a session id.
	/// </summary>
	public void RelayEvent(ClientSession from, ushort sessionId, byte[] payload)
	{
		Session? session;
		lock (_lock)
		{
			if (!_sessions.TryGetValue(sessionId, out session)) return;
			if (!session.IsActive || !session.Involves(from)) return;
		}

		session.Other(from).EnqueueSessionEvent(sessionId, from.Id, payload);
	}

	/// <summary>Handles a participant deliberately leaving.</summary>
	public void Leave(ClientSession from, ushort sessionId, SessionEndReason reason)
	{
		Session? session;
		lock (_lock)
		{
			if (!_sessions.TryGetValue(sessionId, out session)) return;
			if (!session.Involves(from)) return;
			_sessions.Remove(sessionId);
		}

		// Completed is the only reason a client may claim on its own behalf;
		// anything else it sends is normalised to Left so a client cannot
		// misreport how a session finished to its peer.
		var end = reason == SessionEndReason.Completed ? reason : SessionEndReason.Left;

		_logger.Information("[session {Id}] ended by {Who}: {Reason}", sessionId, from.Name, end);
		session.Initiator.EnqueueSessionEnd(sessionId, end);
		session.Acceptor.EnqueueSessionEnd(sessionId, end);
	}

	/// <summary>
	/// Tears down whatever session a disconnecting client was in and tells the
	/// survivor. Without this the other player would sit in a session forever
	/// waiting on a peer that is gone.
	/// </summary>
	public void HandleDisconnect(ClientSession gone)
	{
		List<Session> affected;
		lock (_lock)
		{
			affected = [.. _sessions.Values.Where(s => s.Involves(gone))];
			foreach (var s in affected) _sessions.Remove(s.Id);
		}

		foreach (var s in affected)
		{
			var survivor = s.Other(gone);
			_logger.Information("[session {Id}] ended: {Who} disconnected", s.Id, gone.Name);
			survivor.EnqueueSessionEnd(s.Id, SessionEndReason.PeerDisconnected);
		}
	}

	/// <summary>
	/// Expires pending invites nobody answered. Called periodically; active
	/// sessions are never timed out here, because a long dice game is not a
	/// stuck one and only the interaction itself knows what "too long" means.
	/// </summary>
	public void ExpireStaleInvites()
	{
		var cutoff = DateTime.UtcNow.AddSeconds(-Protocol.InviteTimeoutSeconds);

		List<Session> expired;
		lock (_lock)
		{
			expired = [.. _sessions.Values.Where(s => !s.IsActive && s.CreatedUtc < cutoff)];
			foreach (var s in expired) _sessions.Remove(s.Id);
		}

		foreach (var s in expired)
		{
			_logger.Information("[session {Id}] invite expired unanswered", s.Id);
			s.Initiator.EnqueueSessionEnd(s.Id, SessionEndReason.Timeout);
			s.Acceptor.EnqueueSessionEnd(s.Id, SessionEndReason.Timeout);
		}
	}

	/// <summary>The session this client is in, pending or active, if any.</summary>
	public Session? FindByClient(ClientSession c)
	{
		// Callers inside this class already hold the lock; Monitor is reentrant.
		lock (_lock)
			return _sessions.Values.FirstOrDefault(s => s.Involves(c));
	}

	public int ActiveCount
	{
		get { lock (_lock) return _sessions.Count(kv => kv.Value.IsActive); }
	}

	/// <summary>
	/// Session ids wrap rather than grow, skipping any still in use. Two players
	/// will never come close, but a wrap that silently reused a live id would be
	/// a genuinely confusing bug.
	/// </summary>
	private ushort NextId()
	{
		for (int attempts = 0; attempts <= ushort.MaxValue; attempts++)
		{
			if (_nextId == 0) _nextId = 1;   // 0 is reserved for "no session"
			ushort candidate = _nextId++;
			if (!_sessions.ContainsKey(candidate)) return candidate;
		}
		throw new InvalidOperationException("No free session id.");
	}
}
