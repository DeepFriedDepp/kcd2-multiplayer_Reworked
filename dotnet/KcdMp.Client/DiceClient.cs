using System.Buffers.Binary;

namespace KcdMp.Client;

/// <summary>
/// A full Farkle snapshot, as the relay sees it. Never a delta. BustedFaces is
/// the roll that just busted -- non-empty only on the one snapshot immediately
/// after a bust, since FreeFaces is already empty by then.
/// </summary>
public sealed record DiceSnapshot(
    ushort SessionId, byte CurrentPlayerRole, int ScoreInitiator, int ScoreAcceptor,
    int TurnTotal, int TargetScore, DicePhase Phase, byte[] FreeFaces, byte[] KeptFaces, byte[] BustedFaces);

/// <summary>An intent this agent sent was rejected. The game state did not change.</summary>
public sealed record DiceRejection(ushort SessionId, DiceRejectReason Reason);

/// <summary>
/// The match reached a conclusion. WagerAmount (WO-33) is the agreed stake in
/// whole groschen, echoed back by the relay so the receiver need not have
/// remembered it from the original invite; 0 for no stake.
/// </summary>
public sealed record DiceResult(ushort SessionId, DiceOutcome Outcome, int ScoreInitiator, int ScoreAcceptor, int WagerAmount = 0);

/// <summary>
/// Agent-side half of the dice wire protocol (WO-5).
///
/// Unlike <see cref="InteractionClient"/>'s SessionEvent, dice packets are
/// relay-authoritative end to end: this class never computes a roll, a score,
/// or whose turn it is. It sends an intent and renders whatever DiceState,
/// DiceError, or DiceEnd comes back -- the same "the relay arbitrates" rule
/// InteractionClient follows for session lifecycle.
/// </summary>
public sealed class DiceClient(Func<byte, byte[], CancellationToken, Task> sendPacket)
{
    /// <summary>A new authoritative snapshot arrived.</summary>
    public event Action<DiceSnapshot>? StateChanged;

    /// <summary>An intent this agent sent was rejected.</summary>
    public event Action<DiceRejection>? IntentRejected;

    /// <summary>The match ended.</summary>
    public event Action<DiceResult>? MatchEnded;

    public Task RollAsync(ushort sessionId, CancellationToken ct = default) =>
        SendIntentAsync(sessionId, DiceIntentType.Roll, [], ct);

    /// <summary><paramref name="mask"/> selects which of the last snapshot's FreeFaces to keep.</summary>
    public Task KeepAsync(ushort sessionId, byte mask, CancellationToken ct = default) =>
        SendIntentAsync(sessionId, DiceIntentType.Keep, [mask], ct);

    public Task BankAsync(ushort sessionId, CancellationToken ct = default) =>
        SendIntentAsync(sessionId, DiceIntentType.Bank, [], ct);

    public Task ForfeitAsync(ushort sessionId, CancellationToken ct = default) =>
        SendIntentAsync(sessionId, DiceIntentType.Forfeit, [], ct);

    private Task SendIntentAsync(ushort sessionId, DiceIntentType type, byte[] data, CancellationToken ct)
    {
        var payload = new byte[3 + data.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        payload[2] = (byte)type;
        data.CopyTo(payload, 3);
        return sendPacket(Protocol.DiceIntent, payload, ct);
    }

    /// <summary>
    /// Feeds an inbound packet in. Returns false if it was not one of ours, so
    /// the caller can carry on matching other types. A malformed payload is
    /// logged and dropped, not trusted -- the relay is friendly but the wire
    /// is still a wire.
    /// </summary>
    public bool HandlePacket(int type, byte[] payload)
    {
        if (type == Protocol.DiceState)
        {
            if (payload.Length < 21)
            {
                Console.WriteLine($"[dice] dropped malformed DiceState ({payload.Length} bytes)");
                return true;
            }

            ushort sessionId = BinaryPrimitives.ReadUInt16LittleEndian(payload);
            byte role = payload[2];
            int scoreInitiator = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(3));
            int scoreAcceptor  = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(7));
            int turnTotal      = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(11));
            int targetScore    = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(15));
            var phase = (DicePhase)payload[19];

            int freeCount = payload[20];
            if (payload.Length < 21 + freeCount + 1)
            {
                Console.WriteLine("[dice] dropped malformed DiceState (free dice truncated)");
                return true;
            }
            byte[] freeFaces = payload.AsSpan(21, freeCount).ToArray();

            int o = 21 + freeCount;
            int keptCount = payload[o];
            if (payload.Length < o + 1 + keptCount)
            {
                Console.WriteLine("[dice] dropped malformed DiceState (kept dice truncated)");
                return true;
            }
            byte[] keptFaces = payload.AsSpan(o + 1, keptCount).ToArray();

            // Appended after the original WO-5 layout. Defaults to empty for
            // a shorter payload rather than dropping the whole packet --
            // everything before this point is still perfectly usable.
            o = o + 1 + keptCount;
            byte[] bustedFaces = [];
            if (payload.Length > o)
            {
                int bustedCount = payload[o];
                if (payload.Length >= o + 1 + bustedCount)
                    bustedFaces = payload.AsSpan(o + 1, bustedCount).ToArray();
            }

            StateChanged?.Invoke(new DiceSnapshot(sessionId, role, scoreInitiator, scoreAcceptor,
                turnTotal, targetScore, phase, freeFaces, keptFaces, bustedFaces));
            return true;
        }

        if (type == Protocol.DiceError)
        {
            if (payload.Length < 3)
            {
                Console.WriteLine($"[dice] dropped malformed DiceError ({payload.Length} bytes)");
                return true;
            }
            ushort sessionId = BinaryPrimitives.ReadUInt16LittleEndian(payload);
            IntentRejected?.Invoke(new DiceRejection(sessionId, (DiceRejectReason)payload[2]));
            return true;
        }

        if (type == Protocol.DiceEnd)
        {
            if (payload.Length < 11)
            {
                Console.WriteLine($"[dice] dropped malformed DiceEnd ({payload.Length} bytes)");
                return true;
            }
            ushort sessionId = BinaryPrimitives.ReadUInt16LittleEndian(payload);
            var outcome = (DiceOutcome)payload[2];
            int scoreInitiator = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(3));
            int scoreAcceptor  = BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(7));

            // wagerAmount appended WO-33, optional trailing field like
            // DiceState's bustedFaces above -- a pre-WO-33 relay's 11-byte
            // payload still parses fine, just with no wager.
            int wagerAmount = payload.Length >= 15
                ? BinaryPrimitives.ReadInt32LittleEndian(payload.AsSpan(11))
                : 0;

            MatchEnded?.Invoke(new DiceResult(sessionId, outcome, scoreInitiator, scoreAcceptor, wagerAmount));
            return true;
        }

        return false;
    }
}
