namespace KcdMp.Farkle;

/// <summary>What the game is waiting for next.</summary>
public enum TurnPhase : byte
{
    /// <summary>Roll is the only legal action (or Bank, if TurnTotal > 0).</summary>
    AwaitingRoll,

    /// <summary>A roll just happened; Keep is the only legal action.</summary>
    AwaitingKeep,
}

/// <summary>Whether and how the match has ended.</summary>
public enum FarkleOutcome : byte
{
    InProgress,
    Player0Won,
    Player1Won,
}

/// <summary>Why an intent was rejected. <see cref="None"/> only appears on an accepted result.</summary>
public enum IntentRejectReason : byte
{
    None = 0,
    NotYourTurn,
    WrongPhase,
    EmptyKeep,
    KeepIndexOutOfRange,
    InvalidKeepSelection,
    NothingToBank,
    GameAlreadyOver,
}

/// <summary>
/// Result of applying an intent. Rejections never mutate the game -- callers
/// can retry with a corrected intent. An accepted result may also carry a
/// side effect the caller needs to narrate (busted, hot dice, game won).
/// </summary>
public readonly struct IntentResult
{
    public bool Accepted { get; }
    public IntentRejectReason RejectReason { get; }
    public bool Busted { get; }
    public bool HotDice { get; }
    public bool GameEnded { get; }

    private IntentResult(bool accepted, IntentRejectReason rejectReason, bool busted, bool hotDice, bool gameEnded)
    {
        Accepted = accepted;
        RejectReason = rejectReason;
        Busted = busted;
        HotDice = hotDice;
        GameEnded = gameEnded;
    }

    public static IntentResult Reject(IntentRejectReason reason) => new(false, reason, false, false, false);

    public static readonly IntentResult Ok = new(true, IntentRejectReason.None, false, false, false);
    public static readonly IntentResult OkBusted = new(true, IntentRejectReason.None, true, false, false);
    public static readonly IntentResult OkHotDice = new(true, IntentRejectReason.None, false, true, false);
    public static readonly IntentResult OkGameWon = new(true, IntentRejectReason.None, false, false, true);
}

/// <summary>
/// A deterministic, allocation-light Farkle state machine for exactly two
/// players. Has no idea sockets or a relay exist -- it just applies intents
/// and reports what happened. All randomness comes from the injected
/// <see cref="IDiceRng"/>, so the same RNG sequence always reproduces the
/// same match.
/// </summary>
public sealed class FarkleGame
{
    public int TargetScore { get; }
    public int[] Scores { get; } = new int[2];
    public int CurrentPlayer { get; private set; }
    public int TurnTotal { get; private set; }
    public TurnPhase Phase { get; private set; } = TurnPhase.AwaitingRoll;
    public FarkleOutcome Outcome { get; private set; } = FarkleOutcome.InProgress;

    /// <summary>The dice from the most recent roll, awaiting a Keep decision. Empty in AwaitingRoll.</summary>
    public IReadOnlyList<Die> FreeDice => _freeDice;

    /// <summary>Dice already kept this turn, in the order they were kept. Cleared on hot dice, bust, or bank.</summary>
    public IReadOnlyList<Die> KeptDiceThisTurn => _keptDiceThisTurn;

    private readonly IDiceRng _rng;
    private Die[] _freeDice = [];
    private int _freeDiceCount = 6;
    private readonly List<Die> _keptDiceThisTurn = [];

    public FarkleGame(IDiceRng rng, int targetScore = 4000, int? firstPlayer = null)
    {
        _rng = rng;
        TargetScore = targetScore;
        CurrentPlayer = firstPlayer ?? _rng.Next(0, 2);
    }

    /// <summary>
    /// The exact roll that caused the most recent bust, so callers can narrate
    /// what was rolled -- <see cref="ResetTurnState"/> clears <see cref="FreeDice"/>
    /// in the same call that busts it, so nothing else preserves this. Empty
    /// except in the tick immediately after a busting Roll; a following Roll
    /// (busted or not) always overwrites it first, so it is never stale.
    /// </summary>
    public IReadOnlyList<Die> LastBustedDice { get; private set; } = [];

    public IntentResult Roll(int player)
    {
        if (Outcome != FarkleOutcome.InProgress) return IntentResult.Reject(IntentRejectReason.GameAlreadyOver);
        if (player != CurrentPlayer) return IntentResult.Reject(IntentRejectReason.NotYourTurn);
        if (Phase != TurnPhase.AwaitingRoll) return IntentResult.Reject(IntentRejectReason.WrongPhase);

        _freeDice = new Die[_freeDiceCount];
        for (int i = 0; i < _freeDiceCount; i++)
            _freeDice[i] = new Die((byte)_rng.Next(1, 7));

        if (!Scoring.HasAnyScoringDie(_freeDice))
        {
            LastBustedDice = _freeDice;
            ResetTurnState();
            CurrentPlayer = 1 - CurrentPlayer;
            return IntentResult.OkBusted;
        }

        LastBustedDice = [];
        Phase = TurnPhase.AwaitingKeep;
        return IntentResult.Ok;
    }

    /// <summary>
    /// <paramref name="mask"/> is a bitmask over <see cref="FreeDice"/>
    /// (bit i selects FreeDice[i]) naming which just-rolled dice to keep.
    /// The selected subset must, on its own, be a fully valid scoring group
    /// -- see <see cref="Scoring"/>.
    /// </summary>
    public IntentResult Keep(int player, int mask)
    {
        if (Outcome != FarkleOutcome.InProgress) return IntentResult.Reject(IntentRejectReason.GameAlreadyOver);
        if (player != CurrentPlayer) return IntentResult.Reject(IntentRejectReason.NotYourTurn);
        if (Phase != TurnPhase.AwaitingKeep) return IntentResult.Reject(IntentRejectReason.WrongPhase);
        if (mask == 0) return IntentResult.Reject(IntentRejectReason.EmptyKeep);
        if (mask < 0 || (mask >> _freeDice.Length) != 0) return IntentResult.Reject(IntentRejectReason.KeepIndexOutOfRange);

        var selected = new List<Die>(_freeDice.Length);
        for (int i = 0; i < _freeDice.Length; i++)
            if ((mask & (1 << i)) != 0) selected.Add(_freeDice[i]);

        if (!Scoring.TryScore(selected, out int gained))
            return IntentResult.Reject(IntentRejectReason.InvalidKeepSelection);

        TurnTotal += gained;
        _keptDiceThisTurn.AddRange(selected);
        _freeDiceCount -= selected.Count;
        _freeDice = [];
        Phase = TurnPhase.AwaitingRoll;

        if (_keptDiceThisTurn.Count >= 6)
        {
            _keptDiceThisTurn.Clear();
            _freeDiceCount = 6;
            return IntentResult.OkHotDice;
        }

        return IntentResult.Ok;
    }

    public IntentResult Bank(int player)
    {
        if (Outcome != FarkleOutcome.InProgress) return IntentResult.Reject(IntentRejectReason.GameAlreadyOver);
        if (player != CurrentPlayer) return IntentResult.Reject(IntentRejectReason.NotYourTurn);
        if (Phase != TurnPhase.AwaitingRoll) return IntentResult.Reject(IntentRejectReason.WrongPhase);
        if (TurnTotal <= 0) return IntentResult.Reject(IntentRejectReason.NothingToBank);

        int banker = CurrentPlayer;
        Scores[banker] += TurnTotal;
        bool won = Scores[banker] >= TargetScore;

        ResetTurnState();

        if (won)
        {
            Outcome = banker == 0 ? FarkleOutcome.Player0Won : FarkleOutcome.Player1Won;
            return IntentResult.OkGameWon;
        }

        CurrentPlayer = 1 - banker;
        return IntentResult.Ok;
    }

    /// <summary>Ends the match immediately with the other player winning. Legal regardless of whose turn it is.</summary>
    public IntentResult Forfeit(int player)
    {
        if (Outcome != FarkleOutcome.InProgress) return IntentResult.Reject(IntentRejectReason.GameAlreadyOver);

        int winner = 1 - player;
        Outcome = winner == 0 ? FarkleOutcome.Player0Won : FarkleOutcome.Player1Won;
        return IntentResult.OkGameWon;
    }

    private void ResetTurnState()
    {
        TurnTotal = 0;
        _freeDiceCount = 6;
        _freeDice = [];
        _keptDiceThisTurn.Clear();
        Phase = TurnPhase.AwaitingRoll;
    }
}
