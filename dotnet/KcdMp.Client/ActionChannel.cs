using System.Buffers.Binary;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>
/// WO-100.5 Phase 3 -- the discrete action channel (0x3B / 0x3C).
///
/// One packet pair for every action kind, carrying the INPUT rather than the
/// result: a press that is never committed is a real thing the remote body
/// should show and then abandon, and a cancel is a message, not an absence.
///
/// Three things this class exists to get right, all of them lessons already
/// paid for elsewhere in this project:
///
///   * ORDERING per (sender, kind), by modulo comparison over a half-range
///     window -- the same comparison CombatPipe uses for its sequence byte
///     (WO-100 S3.1), widened to 16 bits. A wrap must not look like a flood of
///     stale packets.
///   * VALIDITY by `gen`. SwingInbox needs only one counter locally, because
///     death, respawn and save load all change the ghost's CryEngine entity id
///     and one observable covers all three. Across the wire the receiver
///     cannot see that discontinuity, so the sender names it.
///   * EVERY REFUSAL IS COUNTED AND NAMED. WO-100 S3.2's lesson: "ok=0" told a
///     field session nothing for fourteen different failures.
/// </summary>
public sealed class ActionOutbox
{
    private readonly Dictionary<ActionKind, ushort> _seq = new();

    /// <summary>
    /// The sender's own validity counter. Incarnation moves when this player's
    /// body is replaced (death, respawn, save load); epoch moves on reconnect.
    /// Revision is reserved and stays 0 -- the field exists so a future need
    /// does not cost a protocol bump.
    /// </summary>
    public ActionGen Gen { get; private set; } = new(1, 0, 0);

    public long Sent { get; private set; }

    /// <summary>A new body: anything still in flight for the old one is now invalid.</summary>
    public void BumpIncarnation()
    {
        Gen = new ActionGen((ushort)(Gen.Incarnation + 1), Gen.Epoch, Gen.Revision);
    }

    /// <summary>A new relay connection: an event that survived the drop is invalid.</summary>
    public void BumpEpoch()
    {
        Gen = new ActionGen(Gen.Incarnation, (byte)(Gen.Epoch + 1), Gen.Revision);
    }

    /// <summary>Builds one ActionUp packet. Payload may be empty.</summary>
    public byte[] Build(ActionKind kind, ActionPhase phase, ReadOnlySpan<byte> payload)
    {
        if (payload.Length > Protocol.ActionPayloadMaxLen)
            throw new ArgumentOutOfRangeException(nameof(payload),
                $"action payload {payload.Length} > {Protocol.ActionPayloadMaxLen}");

        _seq.TryGetValue(kind, out ushort seq);
        seq = unchecked((ushort)(seq + 1));
        _seq[kind] = seq;
        Sent++;

        int payloadLen = Protocol.ActionUpHeaderLen + payload.Length;
        var packet = new byte[3 + payloadLen];
        packet[0] = Protocol.ActionUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payloadLen);
        packet[3] = (byte)kind;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(4), seq);
        packet[6] = (byte)phase;
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(7), Gen.Pack());
        packet[11] = (byte)payload.Length;
        payload.CopyTo(packet.AsSpan(12));
        return packet;
    }
}

/// <summary>WO-100.5: why an inbound action was not dispatched.</summary>
public enum ActionReject
{
    None = 0,
    /// <summary>Not greater than the last seq for this (sender, kind).</summary>
    StaleOrDuplicate,
    /// <summary>The sender's gen differs from the one we currently hold for them.</summary>
    Expired,
    /// <summary>A kind this build has no handler for.</summary>
    UnknownKind,
    /// <summary>Truncated, or the declared payload length does not fit.</summary>
    Malformed,
}

/// <summary>One decoded inbound action.</summary>
public readonly record struct InboundAction(
    byte SourceGhostId, ActionKind Kind, ushort Seq, ActionPhase Phase, ActionGen Gen, byte[] Payload);

/// <summary>
/// WO-100.5 Phase 3: the receiving half. Decodes, orders, validates and counts.
/// Deliberately does NOT act: dispatch is the caller's, so the wire half can be
/// proven on its own even where the receiving body cannot yet perform the
/// action (Phase 1's block write was refused; the attack payload still crosses
/// and is still logged and dropped, which is what proves this layer).
/// </summary>
public sealed class ActionInbox
{
    private readonly Dictionary<(byte Sender, ActionKind Kind), ushort> _lastSeq = new();
    private readonly Dictionary<byte, ActionGen> _gen = new();

    public long Accepted { get; private set; }
    public long Stale { get; private set; }
    public long Expired { get; private set; }
    public long Unknown { get; private set; }
    public long Malformed { get; private set; }

    /// <summary>
    /// A sender's current generation, learned from the first packet we see from
    /// them and updated when it MOVES FORWARD. Learning rather than requiring
    /// a handshake is deliberate: a receiver that joined mid-session has no way
    /// to know the sender's incarnation, and refusing everything until one
    /// arrives would make a late joiner permanently deaf.
    /// </summary>
    public void NoteGen(byte sender, ActionGen gen) => _gen[sender] = gen;

    /// <summary>Forget a peer entirely -- they disconnected.</summary>
    public void Forget(byte sender)
    {
        _gen.Remove(sender);
        foreach (var key in _lastSeq.Keys.Where(k => k.Sender == sender).ToList())
            _lastSeq.Remove(key);
    }

    /// <summary>
    /// Decodes one ActionDown payload. Returns the action when it should be
    /// dispatched, or null with <paramref name="reject"/> saying precisely why.
    /// </summary>
    public InboundAction? Accept(ReadOnlySpan<byte> payload, out ActionReject reject)
    {
        reject = ActionReject.None;
        // [sourceGhostId:1][kind:1][seq:2][phase:1][gen:4][len:1][payload:len]
        if (payload.Length < 1 + Protocol.ActionUpHeaderLen) { Malformed++; reject = ActionReject.Malformed; return null; }

        byte sender = payload[0];
        var kind    = (ActionKind)payload[1];
        ushort seq  = BinaryPrimitives.ReadUInt16LittleEndian(payload.Slice(2));
        var phase   = (ActionPhase)payload[4];
        var gen     = ActionGen.Unpack(BinaryPrimitives.ReadUInt32LittleEndian(payload.Slice(5)));
        int len     = payload[9];
        if (payload.Length < 10 + len) { Malformed++; reject = ActionReject.Malformed; return null; }
        var body = payload.Slice(10, len).ToArray();

        if (!Enum.IsDefined(typeof(ActionKind), kind)) { Unknown++; reject = ActionReject.UnknownKind; return null; }

        // Generation. An event from a body that no longer exists is dropped --
        // this is the cross-machine form of the rule SwingInbox applies
        // locally with one counter.
        if (_gen.TryGetValue(sender, out var held))
        {
            if (gen != held)
            {
                // Forward is a new body: adopt it and drop the old ordering,
                // because seq restarts with the incarnation.
                bool forward = gen.Epoch > held.Epoch
                            || (gen.Epoch == held.Epoch && Protocol.SeqIsNewer(gen.Incarnation, held.Incarnation));
                if (!forward) { Expired++; reject = ActionReject.Expired; return null; }
                _gen[sender] = gen;
                foreach (var key in _lastSeq.Keys.Where(k => k.Sender == sender).ToList())
                    _lastSeq.Remove(key);
            }
        }
        else _gen[sender] = gen;

        // Ordering, per (sender, kind).
        var slot = (sender, kind);
        if (_lastSeq.TryGetValue(slot, out ushort last) && !Protocol.SeqIsNewer(seq, last))
        {
            Stale++; reject = ActionReject.StaleOrDuplicate; return null;
        }
        _lastSeq[slot] = seq;

        Accepted++;
        return new InboundAction(sender, kind, seq, phase, gen, body);
    }

    public string SummaryLine() => FormattableString.Invariant(
        $"MP-ACTION section=inbound accepted={Accepted} stale={Stale} expired={Expired} unknown_kind={Unknown} malformed={Malformed}");
}

/// <summary>
/// WO-100.5 Phase 3: turns the polled accepted-input state into press / commit /
/// cancel / complete edges.
///
/// HONEST LIMIT, stated rather than discovered later: this samples at the
/// position stream's cadence (250 ms), and WO-100 S10.4 caught a whole attack
/// inside roughly 950 ms at 300 ms sampling. A fast press-commit-release will
/// therefore sometimes be seen as a single edge, or missed. That is a property
/// of polling, not of the channel -- the fix is a native edge hook, which is a
/// behaviour change in the DLL and is not in this WO.
/// </summary>
public sealed class AttackEdgeDetector
{
    private sbyte _lastInput = -1;
    private bool  _lastPrepared;
    private bool  _sawCommit;

    /// <summary>
    /// Feeds one sample. Returns the edge to publish, or null when nothing
    /// changed. <paramref name="haveCombat"/> false means the body has no
    /// combat actor -- the resting state -- which clears the machine without
    /// emitting a cancel, because no press was ever observed.
    /// </summary>
    public (ActionPhase Phase, AttackPayload Payload)? Feed(
        bool haveCombat, sbyte inputClass, sbyte zone, sbyte attackType, bool prepared)
    {
        if (!haveCombat)
        {
            _lastInput = -1; _lastPrepared = false; _sawCommit = false;
            return null;
        }

        var payload = new AttackPayload(inputClass, zone, attackType,
                                        (byte)(prepared ? AttackPayload.FlagPrepared : 0));

        // A press: the accepted input went from nothing to an attack class.
        // move_* and block are input classes too, but this detector publishes
        // ATTACKS -- 0, 1 and 2 are attack_light / attack_heavy /
        // attack_special (WO-100 S2.1).
        bool isAttack = inputClass is >= 0 and <= 2;
        bool wasAttack = _lastInput is >= 0 and <= 2;

        (ActionPhase, AttackPayload)? result = null;
        if (isAttack && !wasAttack)
        {
            result = (ActionPhase.Press, payload);
            _sawCommit = false;
        }
        else if (isAttack && prepared && !_lastPrepared)
        {
            result = (ActionPhase.Commit, payload);
            _sawCommit = true;
        }
        else if (!isAttack && wasAttack)
        {
            // Released. Committed presses complete; uncommitted ones cancel,
            // and a cancel is a message the remote body should act on.
            result = (_sawCommit ? ActionPhase.Complete : ActionPhase.Cancel,
                      new AttackPayload(_lastInput, zone, attackType, 0));
            _sawCommit = false;
        }

        _lastInput = inputClass;
        _lastPrepared = prepared;
        return result;
    }
}

/// <summary>
/// WO-100.5: one native read of the local body -- the continuous tag state plus
/// the accepted input, which arrive together because they come from the same
/// actor in the same pipe round trip.
/// </summary>
public readonly record struct LocalBodyState(
    BodyState Body, bool HaveCombat, sbyte InputClass, sbyte Zone, sbyte AttackType, bool Prepared);
