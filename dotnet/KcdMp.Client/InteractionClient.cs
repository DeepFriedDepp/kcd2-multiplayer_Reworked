using System.Buffers.Binary;

namespace KcdMp.Client;

/// <summary>An invite waiting on this player's answer.</summary>
public sealed record PendingInvite(ushort SessionId, byte FromGhostId, InteractionKind Kind, DateTime ReceivedUtc);

/// <summary>A session both players agreed to.</summary>
public sealed record ActiveSession(ushort SessionId, byte PeerGhostId, InteractionKind Kind, SessionRole Role);

/// <summary>
/// Agent-side half of the interaction layer (WO-2).
///
/// Tracks whatever session this player is in and turns session packets into
/// something the game and higher layers can act on. Dice (WO-3) and duelling
/// (WO-5) are meant to sit on top of this rather than each inventing their own
/// handshake: they get <see cref="SessionEvent"/> and
/// <see cref="SendEventAsync"/> and define their own payloads inside that.
///
/// The relay is the authority on session state, so this class does not try to
/// be. It never invents a session, never decides an invite is stale, and treats
/// SessionEnd as final whatever it thought was happening. Keeping the client
/// dumb is what makes "the relay arbitrates" true rather than aspirational.
/// </summary>
public sealed class InteractionClient(Func<byte, byte[], CancellationToken, Task> sendPacket)
{
    private readonly object _lock = new();
    private PendingInvite? _pending;
    private ActiveSession? _active;

    /// <summary>An invite awaiting an answer, if any.</summary>
    public PendingInvite? PendingIncoming { get { lock (_lock) return _pending; } }

    /// <summary>The session in progress, if any.</summary>
    public ActiveSession? Current { get { lock (_lock) return _active; } }

    /// <summary>True when an invite or session is in play, so a new invite would be refused.</summary>
    public bool Busy { get { lock (_lock) return _pending is not null || _active is not null; } }

    /// <summary>Somebody invited this player.</summary>
    public event Action<PendingInvite>? InviteReceived;

    /// <summary>A session began. Carries the role, which decides turn order.</summary>
    public event Action<ActiveSession>? SessionStarted;

    /// <summary>
    /// An opaque event arrived from the peer. Interpreting the payload is the
    /// interaction's job, not this layer's.
    /// </summary>
    public event Action<ushort, byte, byte[]>? SessionEvent;

    /// <summary>A session or pending invite ended, for the given reason.</summary>
    public event Action<ushort, SessionEndReason>? SessionEnded;

    // -------------------------------------------------------------------------
    // Outbound
    // -------------------------------------------------------------------------

    /// <summary>Invites another player. The relay refuses if either side is busy.</summary>
    public Task InviteAsync(byte targetGhostId, InteractionKind kind, CancellationToken ct = default) =>
        sendPacket(Protocol.Invite, [targetGhostId, (byte)kind], ct);

    /// <summary>
    /// Answers the pending invite. Does nothing when there is none, so a
    /// stray keypress after an invite expires is harmless.
    /// </summary>
    public async Task<bool> RespondAsync(bool accept, CancellationToken ct = default)
    {
        PendingInvite? invite;
        lock (_lock) invite = _pending;
        if (invite is null) return false;

        var payload = new byte[3];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, invite.SessionId);
        payload[2] = accept ? (byte)1 : (byte)0;
        await sendPacket(Protocol.InviteResponse, payload, ct);

        // The relay confirms with SessionStart or SessionEnd; the invite is
        // cleared then rather than here, so a declined-then-resent invite
        // cannot be lost to a local guess about ordering.
        return true;
    }

    /// <summary>Sends an interaction-defined event to the peer.</summary>
    public async Task<bool> SendEventAsync(byte[] payload, CancellationToken ct = default)
    {
        ActiveSession? session;
        lock (_lock) session = _active;
        if (session is null) return false;

        var body = new byte[2 + payload.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(body, session.SessionId);
        payload.CopyTo(body, 2);
        await sendPacket(Protocol.SessionEventUp, body, ct);
        return true;
    }

    /// <summary>Leaves the current session.</summary>
    public async Task<bool> LeaveAsync(SessionEndReason reason = SessionEndReason.Left, CancellationToken ct = default)
    {
        ActiveSession? session;
        lock (_lock) session = _active;
        if (session is null) return false;

        var payload = new byte[3];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, session.SessionId);
        payload[2] = (byte)reason;
        await sendPacket(Protocol.SessionLeave, payload, ct);
        return true;
    }

    // -------------------------------------------------------------------------
    // Inbound
    // -------------------------------------------------------------------------

    /// <summary>
    /// Feeds an inbound interaction packet in. Returns false if the packet was
    /// not one of ours, so the caller can carry on matching other types.
    /// Malformed payloads are dropped rather than trusted — the relay is
    /// friendly but the wire is still a wire.
    /// </summary>
    public bool HandlePacket(int type, byte[] payload)
    {
        switch (type)
        {
            case Protocol.InviteReceived when payload.Length >= 4:
            {
                var invite = new PendingInvite(
                    BinaryPrimitives.ReadUInt16LittleEndian(payload),
                    payload[2],
                    (InteractionKind)payload[3],
                    DateTime.UtcNow);

                lock (_lock) _pending = invite;
                InviteReceived?.Invoke(invite);
                return true;
            }

            case Protocol.SessionStart when payload.Length >= 5:
            {
                var session = new ActiveSession(
                    BinaryPrimitives.ReadUInt16LittleEndian(payload),
                    payload[2],
                    (InteractionKind)payload[3],
                    (SessionRole)payload[4]);

                lock (_lock)
                {
                    _active = session;
                    _pending = null;
                }
                SessionStarted?.Invoke(session);
                return true;
            }

            case Protocol.SessionEventDown when payload.Length >= 3:
            {
                ushort sid = BinaryPrimitives.ReadUInt16LittleEndian(payload);
                byte from = payload[2];

                // Ignore events for a session we are not in: the relay should
                // never send one, and acting on it would be worse than dropping.
                lock (_lock)
                {
                    if (_active is null || _active.SessionId != sid) return true;
                }

                SessionEvent?.Invoke(sid, from, payload[3..]);
                return true;
            }

            case Protocol.SessionEnd when payload.Length >= 3:
            {
                ushort sid = BinaryPrimitives.ReadUInt16LittleEndian(payload);
                var reason = (SessionEndReason)payload[2];

                lock (_lock)
                {
                    // Session id 0 means "your request was refused outright"
                    // (busy target, bad target), so there is no local state to
                    // clear — only a reason to report.
                    if (_active?.SessionId == sid) _active = null;
                    if (_pending?.SessionId == sid) _pending = null;
                }

                SessionEnded?.Invoke(sid, reason);
                return true;
            }

            // Right type, wrong length: consume it so it is not mistaken for
            // another packet, but do not act on it.
            case Protocol.InviteReceived:
            case Protocol.SessionStart:
            case Protocol.SessionEventDown:
            case Protocol.SessionEnd:
                Console.WriteLine($"[interaction] dropped malformed packet 0x{type:X2} ({payload.Length} bytes)");
                return true;

            default:
                return false;
        }
    }

    /// <summary>Clears local state on disconnect; the relay forgets sessions too.</summary>
    public void Reset()
    {
        lock (_lock)
        {
            _pending = null;
            _active = null;
        }
    }
}
