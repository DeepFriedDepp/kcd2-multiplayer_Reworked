namespace KcdMp.Client;

/// <summary>
/// The dice state the launcher can currently see, as plain DTOs for
/// System.Text.Json. One flat snapshot rather than an event log: the launcher
/// polls and re-renders from whatever is current, the same "full snapshot,
/// never a delta" rule the wire protocol itself uses -- a missed poll just
/// means the next one already has the answer.
/// </summary>
public sealed class DiceIpcSnapshotDto
{
    public DiceInviteDto? Invite { get; set; }
    public DiceSessionDto? Session { get; set; }
}

public sealed class DiceInviteDto
{
    public ushort SessionId { get; set; }
    public string FromName { get; set; } = "";
}

public sealed class DiceSessionDto
{
    public ushort SessionId { get; set; }
    public string Role { get; set; } = "";           // "Initiator" | "Acceptor"
    public string PeerName { get; set; } = "";
    public byte CurrentPlayerRole { get; set; }
    public int ScoreInitiator { get; set; }
    public int ScoreAcceptor { get; set; }
    public int TurnTotal { get; set; }
    public int TargetScore { get; set; }
    public string Phase { get; set; } = "";          // "AwaitingRoll" | "AwaitingKeep"
    public byte[] FreeFaces { get; set; } = [];
    public byte[] KeptFaces { get; set; } = [];
    public string? LastError { get; set; }           // DiceRejectReason name, cleared on the next state change
    public DiceResultDto? Result { get; set; }       // set once the match ends; the session lingers so the result stays on screen
}

public sealed class DiceResultDto
{
    public string Outcome { get; set; } = "";        // "InitiatorWon" | "AcceptorWon"
    public int ScoreInitiator { get; set; }
    public int ScoreAcceptor { get; set; }
}

/// <summary>
/// Aggregates <see cref="InteractionClient"/> and <see cref="DiceClient"/>
/// events into the single snapshot <see cref="DiceIpcServer"/> serves, and
/// turns the launcher's HTTP commands back into calls on those two clients.
///
/// Dice-only: an invite or session for any other <see cref="InteractionKind"/>
/// is not this class's concern and is left to whatever already handles it
/// in-game.
/// </summary>
public sealed class DiceIpcState
{
    private readonly InteractionClient _interactions;
    private readonly DiceClient _dice;
    private readonly Func<byte, string?> _lookupGhostName;

    private readonly object _lock = new();
    private DiceInviteDto? _invite;
    private DiceSessionDto? _session;
    private ushort? _trackedSessionId;

    public DiceIpcState(InteractionClient interactions, DiceClient dice, Func<byte, string?> lookupGhostName)
    {
        _interactions = interactions;
        _dice = dice;
        _lookupGhostName = lookupGhostName;

        interactions.InviteReceived += OnInviteReceived;
        interactions.SessionStarted += OnSessionStarted;
        interactions.SessionEnded += OnSessionEnded;
        dice.StateChanged += OnStateChanged;
        dice.IntentRejected += OnIntentRejected;
        dice.MatchEnded += OnMatchEnded;
    }

    public DiceIpcSnapshotDto GetSnapshot()
    {
        lock (_lock) return new DiceIpcSnapshotDto { Invite = _invite, Session = _session };
    }

    public Task<bool> RespondAsync(bool accept) => _interactions.RespondAsync(accept);

    public Task RollAsync()
    {
        ushort? sid = CurrentSessionId();
        return sid is null ? Task.CompletedTask : _dice.RollAsync(sid.Value);
    }

    public Task KeepAsync(byte mask)
    {
        ushort? sid = CurrentSessionId();
        return sid is null ? Task.CompletedTask : _dice.KeepAsync(sid.Value, mask);
    }

    public Task BankAsync()
    {
        ushort? sid = CurrentSessionId();
        return sid is null ? Task.CompletedTask : _dice.BankAsync(sid.Value);
    }

    public Task ForfeitAsync()
    {
        ushort? sid = CurrentSessionId();
        return sid is null ? Task.CompletedTask : _dice.ForfeitAsync(sid.Value);
    }

    private ushort? CurrentSessionId() { lock (_lock) return _session?.SessionId; }

    private void OnInviteReceived(PendingInvite invite)
    {
        if (invite.Kind != InteractionKind.Dice) return;

        lock (_lock)
        {
            _invite = new DiceInviteDto
            {
                SessionId = invite.SessionId,
                FromName = _lookupGhostName(invite.FromGhostId) ?? $"player {invite.FromGhostId}",
            };
        }
    }

    private void OnSessionStarted(ActiveSession session)
    {
        if (session.Kind != InteractionKind.Dice) return;

        lock (_lock)
        {
            _invite = null;
            _trackedSessionId = session.SessionId;
            _session = new DiceSessionDto
            {
                SessionId = session.SessionId,
                Role = session.Role.ToString(),
                PeerName = _lookupGhostName(session.PeerGhostId) ?? $"player {session.PeerGhostId}",
            };
        }
    }

    private void OnStateChanged(DiceSnapshot s)
    {
        lock (_lock)
        {
            if (_trackedSessionId != s.SessionId || _session is null) return;
            _session.CurrentPlayerRole = s.CurrentPlayerRole;
            _session.ScoreInitiator = s.ScoreInitiator;
            _session.ScoreAcceptor = s.ScoreAcceptor;
            _session.TurnTotal = s.TurnTotal;
            _session.TargetScore = s.TargetScore;
            _session.Phase = s.Phase.ToString();
            _session.FreeFaces = s.FreeFaces;
            _session.KeptFaces = s.KeptFaces;
            _session.LastError = null; // a fresh accepted state supersedes any prior rejection
        }
    }

    private void OnIntentRejected(DiceRejection r)
    {
        lock (_lock)
        {
            if (_trackedSessionId != r.SessionId || _session is null) return;
            _session.LastError = r.Reason.ToString();
        }
    }

    private void OnMatchEnded(DiceResult r)
    {
        lock (_lock)
        {
            if (_trackedSessionId != r.SessionId || _session is null) return;
            _session.Result = new DiceResultDto
            {
                Outcome = r.Outcome.ToString(),
                ScoreInitiator = r.ScoreInitiator,
                ScoreAcceptor = r.ScoreAcceptor,
            };
        }
    }

    private void OnSessionEnded(ushort sessionId, SessionEndReason reason)
    {
        lock (_lock)
        {
            if (_invite?.SessionId == sessionId) _invite = null;

            // The session lingers (with Result already set by MatchEnded, if it
            // got that far) so the end screen has something to show. It only
            // clears once nothing is tracking it any more -- the next Invite or
            // SessionStarted for dice overwrites it outright.
            if (_trackedSessionId == sessionId && _session?.Result is null)
            {
                _session = null;
                _trackedSessionId = null;
            }
        }
    }
}
