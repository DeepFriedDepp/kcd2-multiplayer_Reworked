using System.Buffers.Binary;
using KcdMp.Farkle;
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

		/// <summary>Kind-specific data carried on the Invite, opaque to this layer. Empty for kinds that don't use it.</summary>
		public byte[] OpenConfig { get; init; } = [];

		/// <summary>The live Farkle engine, once Kind == Dice and the session is Active. Null otherwise.</summary>
		public FarkleGame? DiceGame { get; set; }

		public bool Involves(ClientSession c) => Initiator == c || Acceptor == c;
		public ClientSession Other(ClientSession c) => Initiator == c ? Acceptor : Initiator;
	}

	/// <summary>
	/// Handles an Invite. Returns the created session, or null when it was
	/// refused — in which case the caller has already been told why.
	/// </summary>
	public Session? Invite(ClientSession from, byte targetId, InteractionKind kind, ClientHandler clients, byte[] openConfig)
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
				OpenConfig = openConfig,
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
				if (session.Kind == InteractionKind.Dice)
					session.DiceGame = CreateDiceGame(session.OpenConfig);
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

		if (session.DiceGame is not null)
			SendDiceState(session);
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

	/// <summary>
	/// Applies a DiceIntent to the session's Farkle engine. Unlike RelayEvent,
	/// this terminates here rather than forwarding -- the relay is the dice
	/// authority, so it interprets the intent, mutates its own engine, and
	/// tells both participants (or just the sender, for a rejection) what the
	/// result is.
	/// </summary>
	public void HandleDiceIntent(ClientSession from, ushort sessionId, DiceIntentType intentType, byte[] data)
	{
		Session? session;
		lock (_lock)
		{
			if (!_sessions.TryGetValue(sessionId, out session)) return;
			if (!session.IsActive || session.DiceGame is null || !session.Involves(from)) return;
		}

		var game = session.DiceGame;
		int player = session.Initiator == from ? 0 : 1;

		IntentResult result = intentType switch
		{
			DiceIntentType.Roll => game.Roll(player),
			DiceIntentType.Keep => data.Length >= 1
				? game.Keep(player, data[0])
				: IntentResult.Reject(IntentRejectReason.InvalidKeepSelection),
			DiceIntentType.Bank => game.Bank(player),
			DiceIntentType.Forfeit => game.Forfeit(player),
			_ => throw new ArgumentOutOfRangeException(nameof(intentType), intentType,
				"caller must validate intentType before calling HandleDiceIntent"),
		};

		if (!result.Accepted)
		{
			_logger.Information("[session {Id}] dice intent {Intent} from {Who} rejected: {Reason}",
				sessionId, intentType, from.Name, result.RejectReason);
			from.EnqueueDiceError(sessionId, ToWireReason(result.RejectReason));
			return;
		}

		if (result.GameEnded)
		{
			_logger.Information("[session {Id}] dice match ended: {Outcome}", sessionId, game.Outcome);
			lock (_lock) _sessions.Remove(sessionId);

			var outcome = game.Outcome == FarkleOutcome.Player0Won ? DiceOutcome.InitiatorWon : DiceOutcome.AcceptorWon;
			session.Initiator.EnqueueDiceEnd(sessionId, outcome, game.Scores[0], game.Scores[1]);
			session.Acceptor.EnqueueDiceEnd(sessionId, outcome, game.Scores[0], game.Scores[1]);

			session.Initiator.EnqueueSessionEnd(sessionId, SessionEndReason.Completed);
			session.Acceptor.EnqueueSessionEnd(sessionId, SessionEndReason.Completed);
			return;
		}

		SendDiceState(session);
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
	/// Builds the Farkle engine for a newly-accepted dice session from the
	/// Invite's opaque config: [targetScore:2 LE][debugSeedOverride:4 LE, optional].
	/// The seed override only exists in a debug build -- in release, those
	/// trailing bytes (if a client sends them at all) are simply never read,
	/// which is what "refuse the override in release" means in practice.
	/// </summary>
	private static FarkleGame CreateDiceGame(byte[] openConfig)
	{
		int targetScore = Protocol.DefaultDiceTargetScore;
		if (openConfig.Length >= 2)
			targetScore = BinaryPrimitives.ReadUInt16LittleEndian(openConfig.AsSpan(0, 2));

		IDiceRng rng = new CryptoDiceRng();
#if DEBUG
		if (openConfig.Length >= 6)
			rng = new SeededDiceRng(BinaryPrimitives.ReadInt32LittleEndian(openConfig.AsSpan(2, 4)));
#endif

		return new FarkleGame(rng, targetScore);
	}

	/// <summary>Sends the current Farkle state to both participants, identically -- see DiceState (0x17).</summary>
	private static void SendDiceState(Session session)
	{
		var game = session.DiceGame!;
		var phase = game.Phase == TurnPhase.AwaitingRoll ? DicePhase.AwaitingRoll : DicePhase.AwaitingKeep;
		byte[] freeFaces = [.. game.FreeDice.Select(d => d.Face)];
		byte[] keptFaces = [.. game.KeptDiceThisTurn.Select(d => d.Face)];

		session.Initiator.EnqueueDiceState(session.Id, (byte)game.CurrentPlayer, game.Scores[0], game.Scores[1],
			game.TurnTotal, game.TargetScore, phase, freeFaces, keptFaces);
		session.Acceptor.EnqueueDiceState(session.Id, (byte)game.CurrentPlayer, game.Scores[0], game.Scores[1],
			game.TurnTotal, game.TargetScore, phase, freeFaces, keptFaces);
	}

	/// <summary>
	/// Explicit mapping rather than a cast: KcdMp.Farkle.IntentRejectReason is an
	/// engine-internal enum the wire format should not be coupled to by numeric
	/// coincidence, the same lesson the duplicated Protocol.cs drift taught.
	/// </summary>
	private static DiceRejectReason ToWireReason(IntentRejectReason reason) => reason switch
	{
		IntentRejectReason.NotYourTurn => DiceRejectReason.NotYourTurn,
		IntentRejectReason.WrongPhase => DiceRejectReason.WrongPhase,
		IntentRejectReason.EmptyKeep => DiceRejectReason.EmptyKeep,
		IntentRejectReason.KeepIndexOutOfRange => DiceRejectReason.KeepIndexOutOfRange,
		IntentRejectReason.InvalidKeepSelection => DiceRejectReason.InvalidKeepSelection,
		IntentRejectReason.NothingToBank => DiceRejectReason.NothingToBank,
		IntentRejectReason.GameAlreadyOver => DiceRejectReason.GameAlreadyOver,
		_ => throw new ArgumentOutOfRangeException(nameof(reason), reason, "None should never reach a rejected result"),
	};

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
