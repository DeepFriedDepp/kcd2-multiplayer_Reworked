using System.Buffers.Binary;
using System.IO.Pipes;
using System.Threading.Channels;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>
/// The agent side of the channel to KCDMP.dll.
///
/// The DLL hosts the pipe and the agent connects, because the DLL's lifetime is
/// the game's: the agent may be restarted, may start before the game, or may not
/// be running at all, and the game carries on regardless. So this reconnects
/// rather than assuming the pipe is there.
///
/// This is the only path by which a remote player's damage reaches the game.
/// The Lua channel cannot do it — writes through Lua are inert — so if the DLL
/// is not injected, combat replication is simply unavailable and the agent says
/// so once rather than failing on every packet.
/// </summary>
public sealed class CombatPipe : IAsyncDisposable
{
    private const string PipeName = "kcdmp";

    private const byte ApplyDamage       = 0x01;
    private const byte ApplyDeath        = 0x02;
    private const byte Ping              = 0x03;
    private const byte SetFactionHostile = 0x04;
    private const byte GhostSwing        = 0x06;
    private const byte GhostIsolate      = 0x07;
    private const byte ReadBodyState     = 0x09;   // WO-100.5 Phase 2, read-only
    private const byte ReadLocalState    = 0x0A;   // WO-102 Phase 1, read-only
    private const byte ScanNpcs          = 0x0B;   // WO-102.5 Phase 2, read-only
    private const byte Result            = 0x81;
    private const byte Pong              = 0x83;
    private const byte BodyStateReply    = 0x85;   // WO-100.5 Phase 2
    private const byte LocalStateReply   = 0x86;   // WO-102 Phase 1
    private const byte NpcScanReply      = 0x87;   // WO-102.5 Phase 2
    private const byte SetSession        = 0x0C;   // WO-113
    private const byte SetRespawn        = 0x0D;   // WO-113
    private const byte MirrorGrave       = 0x0E;   // WO-113
    private const byte ListGraves        = 0x0F;   // WO-113
    private const byte GraveListReply    = 0x88;   // WO-113
    private const byte NpcSamples        = 0x10;   // WO-118
    private const byte NpcBind           = 0x11;   // WO-118
    private const byte NpcHold           = 0x12;   // WO-118
    private const byte NpcConfig         = 0x13;   // WO-118
    private const byte NpcStatus         = 0x14;   // WO-118
    private const byte NpcTrace          = 0x15;   // WO-118
    private const byte NpcStatusReply    = 0x89;   // WO-118
    private const byte NpcDropped        = 0x94;   // WO-118, unsolicited
    private const byte NpcTraceDone      = 0x95;   // WO-118, unsolicited
    // ---- WO-121: movement and combat ----
    private const byte MotionConfig      = 0x16;   // [avatarGait][npcGait][avatarMoves][avatarCombat][npcRows]
    private const byte AvatarEvent       = 0x17;   // [kind:1][eid:4]
    private const byte HitsConfig        = 0x18;   // [ffOn][attributionOn][pvpHookOn]
    private const byte AttributedDamage  = 0x19;   // [guid:16][stamina:4f][health:4f][flags:1][attackerEid:4]
    private const byte ApplyPvpHit       = 0x1A;   // [stamina:4f][health:4f][flags:1][attackerGhost:1]
    private const byte Wo121Status       = 0x1B;   // -> 0x8A
    private const byte Wo121StatusReply  = 0x8A;
    private const byte AttributedReply   = 0x8B;   // [ok][seq][steps][attackerWuid:8][victimWuid:8]
    private const byte LocalAction       = 0x96;   // unsolicited, LocalActionFrame
    private const byte PvpHitOut         = 0x97;   // unsolicited: [victimEid:4][stamina:4f][health:4f][flags][material]

    private const int GuidLen = 16;

    private const byte LocalHit = 0x90;
    private const byte LocalDowned    = 0x91;   // WO-113, unsolicited
    private const byte LocalRespawned = 0x92;   // WO-113, unsolicited
    private const byte LocalGrave     = 0x93;   // WO-113, unsolicited

    /// <summary>
    /// WO-113: the DLL's death guard floored the player (on=true) or finished
    /// the respawn/wake-up (on=false). kind: 0 death, 1 knockdown, 2 execution.
    /// </summary>
    public Func<bool, byte, Task>? OnLocalDowned { get; set; }

    /// <summary>WO-113: where the player stands after a respawn; reason as LocalDowned's kind.</summary>
    public Func<float, float, float, byte, Task>? OnLocalRespawned { get; set; }

    /// <summary>WO-113: a grave was made (add=true) or is gone (looted empty / expired).</summary>
    public Func<bool, ulong, float, float, float, Task>? OnLocalGrave { get; set; }

    /// <summary>
    /// WO-121: an action the local engine committed -- the player's own
    /// (eid = 0), or an NPC's (eid and name set; the owner streams it as
    /// NpcAttack). kind is <see cref="KcdMp.Wire.ActionKind"/>.
    /// </summary>
    public Func<LocalActionFrame, Task>? OnLocalAction { get; set; }

    /// <summary>WO-121: the local player hit a peer's avatar: victim eid, stamina, health (what the hit took), flags, material.</summary>
    public Func<uint, float, float, byte, byte, Task>? OnPvpHit { get; set; }

    /// <summary>WO-118: the DLL's native writer stopped a bound puppet on its own (reason, name).</summary>
    public Func<byte, string, Task>? OnNpcDropped { get; set; }

    /// <summary>WO-118 Phase 5: a trace CSV was written (rows, path; rows 0 = nothing recorded).</summary>
    public Func<uint, string, Task>? OnNpcTraceDone { get; set; }

    private readonly SemaphoreSlim _gate = new(1, 1);
    private NamedPipeClientStream? _pipe;
    private bool _warnedUnavailable;

    // LocalHit arrives unsolicited, interleaved with command replies, so a
    // single background reader owns the stream and routes frames: replies to
    // whoever is waiting, hits to the callback. Reading inline per command
    // would mistake a hit for a reply.
    //
    // WO-100 Phase 4: this used to be a single `_lastReply` slot plus a
    // SemaphoreSlim, and that had a real defect. When a command timed out, its
    // reply still arrived later, set the slot and released the semaphore --
    // so the NEXT command's wait returned instantly with the PREVIOUS
    // command's answer, and every reply after one timeout was attributed to
    // the wrong request, permanently. The DLL has always echoed a per-request
    // sequence byte in the Result frame (body[1]); nothing read it. Now the
    // reader hands replies through a bounded channel and the sender drops
    // replies older than the one it is waiting for -- counted and logged,
    // never silently.
    private Task? _reader;
    private Channel<(byte Type, byte[] Body)> _replies = NewReplyChannel();

    /// <summary>Bounded so a wedged sender cannot let replies accumulate without limit.</summary>
    private static Channel<(byte, byte[])> NewReplyChannel() =>
        Channel.CreateBounded<(byte, byte[])>(new BoundedChannelOptions(ReplyInboxCapacity)
        {
            FullMode = BoundedChannelFullMode.DropOldest,
            SingleReader = false,
            SingleWriter = true,
        });

    private const int ReplyInboxCapacity = 8;

    /// <summary>The sequence byte we expect next, or null until the first reply latches it.</summary>
    private byte? _expectedSeq;

    /// <summary>Replies discarded as stale (a late answer to a timed-out command).</summary>
    public long StaleRepliesDropped { get; private set; }

    /// <summary>Commands that got no answer inside the deadline.</summary>
    public long TimedOut { get; private set; }

    /// <summary>
    /// Raised when the DLL reports that a nearby NPC lost health for a reason
    /// this client did not cause. The handler is expected to put it on the wire.
    /// Arguments: soul guid, stamina delta, health delta, died (WO-86: the DLL's
    /// own "this drop took it to zero" bit, once per soul; false from a
    /// pre-WO-86 DLL whose frame stops at 24 bytes).
    /// </summary>
    /// WO-121: the fifth argument -- the DLL saw the LOCAL PLAYER land this hit at
    /// the combat-hit chokepoint (byte 25; false from an older DLL).
    public Func<Guid, float, float, bool, bool, Task>? OnLocalHit { get; set; }

    public bool IsConnected => _pipe?.IsConnected == true;

    /// <summary>
    /// Connect if not already connected. Returns false when the DLL is absent,
    /// which is a normal state rather than an error.
    /// </summary>
    public async Task<bool> EnsureConnectedAsync(CancellationToken ct = default)
    {
        if (IsConnected) return true;

        await _gate.WaitAsync(ct);
        try
        {
            if (IsConnected) return true;

            _pipe?.Dispose();
            _pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                await _pipe.ConnectAsync(500, ct);
            }
            catch (Exception ex) when (ex is TimeoutException or IOException or UnauthorizedAccessException)
            {
                _pipe.Dispose();
                _pipe = null;
                if (!_warnedUnavailable)
                {
                    _warnedUnavailable = true;
                    Console.WriteLine("[combat] KCDMP.dll not injected — damage replication is unavailable.");
                }
                return false;
            }

            _warnedUnavailable = false;
            Console.WriteLine("[combat] connected to KCDMP.dll");
            _reader = Task.Run(ReadLoopAsync);
            return true;
        }
        finally { _gate.Release(); }
    }

    /// <summary>Apply damage from a remote peer to the soul with this SharedSoulGuid.</summary>
    public Task<bool> ApplyDamageAsync(Guid soul, float stamina, float health,
                                       bool suppressHitReaction, CancellationToken ct = default)
    {
        var payload = new byte[GuidLen + 4 + 4 + 1];
        WriteSoulGuid(soul, payload);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(16), stamina);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(20), health);
        payload[24] = suppressHitReaction ? (byte)0x01 : (byte)0x00;
        return SendAsync(ApplyDamage, payload, ct);
    }

    /// <summary>Kill the soul with this SharedSoulGuid. Idempotent in the DLL.</summary>
    public Task<bool> ApplyDeathAsync(Guid soul, CancellationToken ct = default)
    {
        var payload = new byte[GuidLen];
        WriteSoulGuid(soul, payload);
        return SendAsync(ApplyDeath, payload, ct);
    }

    /// <summary>
    /// Attach or detach a locally-spawned ghost's faction node to/from the
    /// mod's one v1 hostile faction (WO-17 reactive aggro). The DLL's own
    /// SetParent recipe (WO-15's ownership fix) does the actual write.
    ///
    /// <paramref name="ghostSoul"/> is the ghost's own Soul.Guid, NOT a
    /// SharedSoulGuid -- a locally-spawned ghost proxy carries
    /// SharedSoulGuid=0, so Guid is the identity that actually resolves
    /// through the DLL's SoulsByGuid lookup for it. Callers read it once via
    /// the debug REST API (SoulList/SoulsByName/kcd2mp_&lt;id&gt;) and may
    /// cache it for the ghost's lifetime.
    /// </summary>
    public Task<bool> SetFactionHostileAsync(Guid ghostSoulGuid, bool hostile, CancellationToken ct = default)
    {
        var payload = new byte[GuidLen + 1];
        WriteSoulGuid(ghostSoulGuid, payload);
        payload[16] = hostile ? (byte)0x01 : (byte)0x00;
        return SendAsync(SetFactionHostile, payload, ct);
    }

    /// <summary>
    /// WO-46: queue a real combat-swing animation on the ghost with this
    /// CryEngine entity id (the DLL runs the WO-45 rung-2 construction on the
    /// game thread). The id comes from the mod's spawn-time "ghostid" event,
    /// not a guid — entity ids are what the combat machinery natively
    /// resolves. fragSpec is a real "FragmentId, tag1+tag2" row from the
    /// shipped combat tables. A false return means an input failed to resolve
    /// (stale id after a respawn, unknown fragment) — normal, not fatal; a
    /// visually inert success (ghost's weapon sheathed) still returns true.
    /// </summary>
    public Task<bool> GhostSwingAsync(uint entityId, string fragSpec, CancellationToken ct = default)
        => GhostSwingForResultAsync(entityId, fragSpec, ct).ContinueWith(t => t.Result.Ok, ct,
               TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);

    /// <summary>
    /// WO-100 Phase 4 item 3: the same swing, with the DLL's specific reason.
    /// Prefer this over <see cref="GhostSwingAsync"/> anywhere the outcome is
    /// logged -- "the swing did not apply" is four different problems with four
    /// different fixes, and the bool cannot tell them apart.
    /// </summary>
    public Task<PipeResult> GhostSwingForResultAsync(uint entityId, string fragSpec, CancellationToken ct = default)
    {
        var spec = System.Text.Encoding.UTF8.GetBytes(fragSpec);
        if (spec.Length is 0 or > 191) return Task.FromResult(PipeResult.Fail(PipeReason.BadSpec));
        var payload = new byte[4 + spec.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, entityId);
        spec.CopyTo(payload.AsSpan(4));
        return SendForResultAsync(GhostSwing, payload, ct);
    }

    /// <summary>
    /// WO-68: apply (<paramref name="on"/>) or remove the seven civic-isolation
    /// script contexts on a locally-spawned ghost, natively -- the crime half
    /// WO-65 proved has no Lua setter on this build.
    ///
    /// <paramref name="ghostSoulGuid"/> is the ghost's own Soul.Guid, the same
    /// identity (and for the same reason) as
    /// <see cref="SetFactionHostileAsync"/>.
    ///
    /// A false return is routine rather than fatal: the ghost's soul may not be
    /// resolvable yet, or the DLL may have disarmed the feature after a fault.
    /// The caller logs it and carries on -- a ghost is never blocked on this.
    /// </summary>
    public Task<bool> GhostIsolateAsync(Guid ghostSoulGuid, bool on, CancellationToken ct = default)
    {
        var payload = new byte[GuidLen + 1];
        WriteSoulGuid(ghostSoulGuid, payload);
        payload[16] = on ? (byte)0x01 : (byte)0x00;
        return SendAsync(GhostIsolate, payload, ct);
    }

    /// <summary>
    /// WO-113: tell the DLL whether a multiplayer session is live. The death
    /// guard arms only while this is on (and mp_respawn is on); the pipe
    /// dropping clears it on the DLL side. Idempotent -- re-sent as a heartbeat.
    /// </summary>
    public Task<bool> SetSessionAsync(bool on, CancellationToken ct = default)
        => SendAsync(SetSession, [on ? (byte)1 : (byte)0], ct);

    /// <summary>WO-113: mp_respawn on/off, mirrored from the mod's console toggle.</summary>
    public Task<bool> SetRespawnAsync(bool on, CancellationToken ct = default)
        => SendAsync(SetRespawn, [on ? (byte)1 : (byte)0], ct);

    /// <summary>
    /// WO-113: a peer's mirror gravestone. op 1 add, 0 remove, 2 clear every
    /// mirror of <paramref name="owner"/> (0xFF = all owners).
    /// </summary>
    public Task<bool> MirrorGraveAsync(byte op, byte owner, ulong graveId, float x, float y, float z,
                                       CancellationToken ct = default)
    {
        var payload = new byte[1 + 1 + 8 + 12];
        payload[0] = op;
        payload[1] = owner;
        BinaryPrimitives.WriteUInt64LittleEndian(payload.AsSpan(2), graveId);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(10), x);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(14), y);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(18), z);
        return SendAsync(MirrorGrave, payload, ct);
    }

    /// <summary>
    /// WO-113: every grave this player still owns. Null when the DLL refused or
    /// predates the command (a pre-WO-113 DLL answers unknown-command).
    /// </summary>
    public async Task<List<(ulong Id, float X, float Y, float Z)>?> ListGravesAsync(CancellationToken ct = default)
    {
        var (body, _) = await SendAndAwaitAsync(ListGraves, [], GraveListReply, ct);
        if (body is null || body.Length < 3 || body[0] != 1) return null;
        int n = body[2];
        if (body.Length < 3 + n * 20) return null;
        var list = new List<(ulong, float, float, float)>(n);
        for (int i = 0; i < n; i++)
        {
            int o = 3 + i * 20;
            list.Add((BinaryPrimitives.ReadUInt64LittleEndian(body.AsSpan(o)),
                      BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(o + 8)),
                      BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(o + 12)),
                      BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(o + 16))));
        }
        return list;
    }

    /// <summary>WO-118: one batch of inbound NPC samples for the native writer (0x10).</summary>
    public Task<PipeResult> NpcSamplesAsync(byte[] payload, CancellationToken ct = default)
        => SendForResultAsync(NpcSamples, payload, ct);

    /// <summary>
    /// WO-118: bind (or unbind) one puppet to the native writer. The DLL verifies
    /// id, name, WUID, parent and living body on the game thread; the result's
    /// raw reason byte is a <see cref="NativeNpcReason"/>.
    /// </summary>
    public async Task<(bool Ok, byte Reason)> NpcBindAsync(bool on, uint eid, ulong wuid, float ax, float ay, float az,
                                                             ushort delayMs, string name, CancellationToken ct = default)
    {
        var (body, fail) = await SendAndAwaitAsync(NpcBind, NativeNpcCodec.BuildBind(on, eid, wuid, ax, ay, az, delayMs, name), Result, ct);
        if (body is null) return (false, (byte)fail);
        return (body[0] == 1, body.Length >= 3 ? body[2] : (byte)255);
    }

    /// <summary>WO-118: no native writes for this puppet for <paramref name="ms"/> (a swing one-shot owns it).</summary>
    public Task<PipeResult> NpcHoldAsync(string name, ushort ms, CancellationToken ct = default)
        => SendForResultAsync(NpcHold, NativeNpcCodec.BuildHold(name, ms), ct);

    /// <summary>WO-118: mirror mp_npc_native_write and mp_npc_senderclock into the DLL.</summary>
    public Task<PipeResult> NpcConfigAsync(bool nativeOn, bool senderClock, CancellationToken ct = default)
        => SendForResultAsync(NpcConfig, [nativeOn ? (byte)1 : (byte)0, senderClock ? (byte)1 : (byte)0], ct);

    /// <summary>WO-118: the writer's counters (the 1 Hz heartbeat). Null when absent or refused.</summary>
    public async Task<NativeNpcStatus?> NpcStatusAsync(CancellationToken ct = default)
    {
        var (body, _) = await SendAndAwaitAsync(NpcStatus, [], NpcStatusReply, ct);
        return NativeNpcCodec.TryParseStatus(body, out var st) ? st : null;
    }

    /// <summary>WO-118 Phase 5: start (seconds &gt; 0) or stop (0) a per-frame trace of one named entity.</summary>
    public Task<PipeResult> NpcTraceAsync(string name, ushort seconds, CancellationToken ct = default)
        => SendForResultAsync(NpcTrace, NativeNpcCodec.BuildTrace(name, seconds), ct);

    /// <summary>WO-121: mirror the movement/combat toggles into the DLL (0x16).</summary>
    public Task<PipeResult> MotionConfigAsync(bool avatarGait, bool npcGait, bool avatarMoves, bool avatarCombat, bool npcRows,
                                              CancellationToken ct = default)
        => SendForResultAsync(MotionConfig, [B(avatarGait), B(npcGait), B(avatarMoves), B(avatarCombat), B(npcRows)], ct);

    /// <summary>WO-121: a one-shot on a native-written avatar (0x17): kind 1 = jump.</summary>
    public Task<PipeResult> AvatarEventAsync(byte kind, uint eid, CancellationToken ct = default)
    {
        var p = new byte[5];
        p[0] = kind;
        BinaryPrimitives.WriteUInt32LittleEndian(p.AsSpan(1), eid);
        return SendForResultAsync(AvatarEvent, p, ct);
    }

    /// <summary>WO-121: friendly fire / NPC attribution / the hit-slot filter (0x18).</summary>
    public Task<PipeResult> HitsConfigAsync(bool friendlyFire, bool attribution, bool pvpHook, CancellationToken ct = default)
        => SendForResultAsync(HitsConfig, [B(friendlyFire), B(attribution), B(pvpHook)], ct);

    /// <summary>
    /// WO-121 Phase 5: a peer's hit on a local NPC, WITH the peer's avatar as
    /// the attacker: damage, the combat-history write, a skirmish once per
    /// engagement. Returns the steps that ran (bit 0 damage, 1 history, 2
    /// skirmish) and the two WUIDs (the agent sends the brain message).
    /// </summary>
    public async Task<(bool Ok, byte Steps, ulong AttackerWuid, ulong VictimWuid, byte Reason)> AttributedDamageAsync(
        Guid soul, float stamina, float health, byte flags, uint attackerEid, CancellationToken ct = default)
    {
        var p = new byte[GuidLen + 4 + 4 + 1 + 4];
        WriteSoulGuid(soul, p);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(16), stamina);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(20), health);
        p[24] = flags;
        BinaryPrimitives.WriteUInt32LittleEndian(p.AsSpan(25), attackerEid);
        var (body, fail) = await SendAndAwaitAsync(AttributedDamage, p, AttributedReply, ct);
        if (body is null) return (false, 0, 0, 0, (byte)fail);
        if (body.Length < 19) return (body.Length > 0 && body[0] == 1, 0, 0, 0, 254);
        return (body[0] == 1, body[2], BinaryPrimitives.ReadUInt64LittleEndian(body.AsSpan(3)),
                BinaryPrimitives.ReadUInt64LittleEndian(body.AsSpan(11)), 0);
    }

    /// <summary>
    /// WO-121 Phase 6: a partner's friendly-fire hit on OUR Henry, as plain
    /// damage with no attacker; the flags (unarmed) reach the death guard's
    /// knockdown classifier in the same call.
    /// </summary>
    public Task<PipeResult> ApplyPvpHitAsync(float stamina, float health, byte flags, byte attackerGhost, CancellationToken ct = default)
    {
        var p = new byte[10];
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(0), stamina);
        BinaryPrimitives.WriteSingleLittleEndian(p.AsSpan(4), health);
        p[8] = flags; p[9] = attackerGhost;
        return SendForResultAsync(ApplyPvpHit, p, ct);
    }

    /// <summary>WO-121: the movement/combat module's armed pieces and counters (text), or null.</summary>
    public async Task<string?> Wo121StatusAsync(CancellationToken ct = default)
    {
        var (body, _) = await SendAndAwaitAsync(Wo121Status, [], Wo121StatusReply, ct);
        if (body is null || body.Length < 3 || body[0] != 1) return null;
        return System.Text.Encoding.UTF8.GetString(body, 2, body.Length - 2);
    }

    private static byte B(bool v) => v ? (byte)1 : (byte)0;

    /// <summary>Round-trip check that the DLL is alive and pumping frames.</summary>
    public async Task<bool> PingAsync(CancellationToken ct = default)
    {
        if (!await EnsureConnectedAsync(ct)) return false;
        await _gate.WaitAsync(ct);
        try
        {
            while (_replies.Reader.TryRead(out _)) StaleRepliesDropped++;
            await WriteFrameAsync(Ping, [], ct);
            using var slice = CancellationTokenSource.CreateLinkedTokenSource(ct);
            slice.CancelAfter(ReplyDeadline);
            try
            {
                var reply = await _replies.Reader.ReadAsync(slice.Token);
                // A Ping consumes a sequence number in the DLL even though it
                // answers with Pong rather than Result, so the expectation has
                // to advance with it or every later reply looks misordered.
                if (_expectedSeq is byte want) _expectedSeq = (byte)(want + 1);
                return reply.Type == Pong;
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                TimedOut++;
                return false;
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Drop();
            return false;
        }
        finally { _gate.Release(); }
    }

    /// <summary>
    /// Guid.ToByteArray already produces the little-endian field order Windows
    /// uses, which is exactly how the game holds a CryGUID in memory and how the
    /// SoulsByGuid key is laid out. So no reordering here — the wire, the game
    /// and System.Guid all agree, and the only place a conversion is needed is
    /// when a human reads the text form.
    /// </summary>
    private static void WriteSoulGuid(Guid soul, Span<byte> dest) =>
        soul.TryWriteBytes(dest);

    /// <summary>Route frames: replies to the waiting command, hits to the callback.</summary>
    private async Task ReadLoopAsync()
    {
        try
        {
            while (_pipe?.IsConnected == true)
            {
                var (type, body) = await ReadFrameAsync(CancellationToken.None);
                // WO-118: replies are logged by their callers; 0x81/0x86/0x89
                // arrive at frame-feed and heartbeat rates and would flood.
                if (type is not (Result or LocalStateReply or NpcStatusReply or BodyStateReply or LocalAction or PvpHitOut))
                    Console.WriteLine($"[combat] pipe frame 0x{type:X2} ({body.Length} bytes)");
                if (type == LocalHit && body.Length >= 24)
                {
                    var   soul    = new Guid(body.AsSpan(0, 16));
                    float stamina = BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(16));
                    float health  = BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(20));
                    // WO-86: trailing died byte; absent from a pre-WO-86 DLL.
                    bool  died    = body.Length >= 25 && body[24] != 0;
                    bool  byPlayer = body.Length >= 26 && body[25] != 0;   // WO-121
                    if (died) Console.WriteLine($"[npcdeath] DLL reports a FATAL local hit on {soul} (hp -{health:F1})");
                    if (OnLocalHit is { } handler)
                    {
                        try { await handler(soul, stamina, health, died, byPlayer); }
                        catch (Exception ex) { Console.WriteLine($"[combat] local hit not sent: {ex.Message}"); }
                    }
                }
                else if (type == LocalDowned && body.Length >= 2)
                {
                    // WO-113: unsolicited, like LocalHit -- never a reply.
                    if (OnLocalDowned is { } h)
                    {
                        try { await h(body[0] != 0, body[1]); }
                        catch (Exception ex) { Console.WriteLine($"[respawn] downed not handled: {ex.Message}"); }
                    }
                }
                else if (type == LocalRespawned && body.Length >= 13)
                {
                    if (OnLocalRespawned is { } h)
                    {
                        try
                        {
                            await h(BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(0)),
                                    BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(4)),
                                    BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(8)), body[12]);
                        }
                        catch (Exception ex) { Console.WriteLine($"[respawn] respawned not handled: {ex.Message}"); }
                    }
                }
                else if (type == LocalGrave && body.Length >= 21)
                {
                    if (OnLocalGrave is { } h)
                    {
                        try
                        {
                            await h(body[0] != 0, BinaryPrimitives.ReadUInt64LittleEndian(body.AsSpan(1)),
                                    BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(9)),
                                    BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(13)),
                                    BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(17)));
                        }
                        catch (Exception ex) { Console.WriteLine($"[grave] local grave not handled: {ex.Message}"); }
                    }
                }
                else if (type == LocalAction && LocalActionFrame.TryParse(body, out var la))
                {
                    // WO-121: unsolicited, never a reply.
                    if (OnLocalAction is { } h)
                    {
                        try { await h(la); }
                        catch (Exception ex) { Console.WriteLine($"[wo121] local action not sent: {ex.Message}"); }
                    }
                }
                else if (type == PvpHitOut && body.Length == 14)
                {
                    if (OnPvpHit is { } h)
                    {
                        try
                        {
                            await h(BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(0)),
                                    BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(4)),
                                    BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(8)), body[12], body[13]);
                        }
                        catch (Exception ex) { Console.WriteLine($"[wo121] pvp hit not sent: {ex.Message}"); }
                    }
                }
                else if (type == NpcDropped && body.Length >= 2 && body.Length == 2 + body[1])
                {
                    // WO-118: unsolicited, never a reply.
                    if (OnNpcDropped is { } h)
                    {
                        try { await h(body[0], System.Text.Encoding.UTF8.GetString(body, 2, body[1])); }
                        catch (Exception ex) { Console.WriteLine($"[npcwrite] drop not handled: {ex.Message}"); }
                    }
                }
                else if (type == NpcTraceDone && body.Length >= 5 && body.Length == 5 + body[4])
                {
                    if (OnNpcTraceDone is { } h)
                    {
                        try { await h(BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(0)), System.Text.Encoding.UTF8.GetString(body, 5, body[4])); }
                        catch (Exception ex) { Console.WriteLine($"[npctrace] trace-done not handled: {ex.Message}"); }
                    }
                }
                else if (!_replies.Writer.TryWrite((type, body)))
                {
                    // DropOldest means TryWrite only fails on a completed
                    // writer, which happens on Drop(). Say so rather than
                    // losing the frame silently.
                    Console.WriteLine($"[combat] reply 0x{type:X2} arrived after the channel closed");
                }
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            // Normal on shutdown or if the game exits.
        }
        catch (Exception ex)
        {
            // Anything else would otherwise become an unobserved task exception:
            // the reader stops and the agent goes quiet with no output at all,
            // which is indistinguishable from the DLL never writing.
            Console.WriteLine($"[combat] reader stopped: {ex.GetType().Name}: {ex.Message}");
        }
        Console.WriteLine("[combat] pipe reader exited");
    }

    private async Task<bool> SendAsync(byte type, byte[] payload, CancellationToken ct)
        => (await SendForResultAsync(type, payload, ct)).Ok;

    /// <summary>
    /// One request/reply exchange. Returns whether the DLL applied it and, when
    /// the DLL is new enough to send one, its specific reason code (WO-100
    /// Phase 4 item 3). The reason is <see cref="PipeReason.Unknown"/> from a
    /// pre-WO-100 DLL whose Result frame stops at two bytes, and
    /// <see cref="PipeReason.NoAnswer"/> when the deadline expired -- which is
    /// NOT a refusal and is reported as its own thing.
    /// </summary>
    private async Task<PipeResult> SendForResultAsync(byte type, byte[] payload, CancellationToken ct)
    {
        var (body, fail) = await SendAndAwaitAsync(type, payload, Result, ct);
        if (body is null) return PipeResult.Fail(fail);
        var reason = body.Length >= 3 ? (PipeReason)body[2] : PipeReason.Unknown;
        return new PipeResult(body[0] == 1, reason);
    }

    /// <summary>
    /// WO-100.5 Phase 2: read one actor's live Mannequin body state (entityId 0
    /// = the local player). Returns null on any refusal -- a gate said no, the
    /// pipe is down, or the DLL predates this command and never answers. The
    /// caller counts those; nothing here logs per call, because this runs at
    /// the position stream's cadence.
    /// </summary>
    public async Task<LocalBodyState?> ReadBodyStateAsync(uint entityId, CancellationToken ct = default)
    {
        var payload = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, entityId);
        var (body, _) = await SendAndAwaitAsync(ReadBodyState, payload, BodyStateReply, ct);
        BodyStateReads++;
        // [ok:1][seq:1][pace:1][dir:1][stance:1][animSpeedCenti:2 LE][unknownTags:1]
        //   + WO-100.5 Phase 3: [haveCombat:1][inputClass:1][zone:1][atkType:1][prepared:1]
        if (body is null || body.Length < 8 || body[0] != 1) { BodyStateRefused++; return null; }
        BodyStateUnknownTags += body[7];
        var b = new BodyState(
            (BodyPace)body[2], (BodyDir)body[3], (BodyStance)body[4],
            BinaryPrimitives.ReadUInt16LittleEndian(body.AsSpan(5)));

        // Length-checked, not assumed: a DLL that predates Phase 3 answers with
        // the 8-byte form and this degrades to "no combat state", which is
        // exactly right rather than a fabricated -1 triple.
        if (body.Length < 13) return new LocalBodyState(b, false, -1, -1, -1, false);
        return new LocalBodyState(b, body[8] == 1,
            (sbyte)body[9], (sbyte)body[10], (sbyte)body[11], body[12] != 0);
    }

    /// <summary>WO-100.5: how many body-state reads were attempted.</summary>
    public long BodyStateReads { get; private set; }

    /// <summary>WO-102 Phase 1: 0x0A reads issued.</summary>
    public long LocalStateReads { get; private set; }
    /// <summary>WO-102 Phase 1: 0x0A reads the DLL refused or never answered.</summary>
    public long LocalStateRefused { get; private set; }
    /// <summary>WO-102 Phase 1: refusals by reason code (index = <see cref="LocalStateRefuse"/>; 255 folds into slot 7).</summary>
    public long[] LocalStateRefuseByCode { get; } = new long[8];

    /// <summary>
    /// WO-102 Phase 1: one native read of the local player's position, yaw,
    /// riding state and body state, all from one frame (pipe 0x0A -> 0x86).
    /// Null on any refusal; the reason is counted, never guessed. A DLL that
    /// predates the command answers nothing and lands in "Unknown" after the
    /// reply deadline -- the caller gives up on the path after a run of those.
    /// </summary>
    public async Task<LocalState?> ReadLocalStateAsync(CancellationToken ct = default)
    {
        var payload = new byte[4];   // entityId 0 = the local player (reserved for a per-entity read)
        var (body, _) = await SendAndAwaitAsync(ReadLocalState, payload, LocalStateReply, ct);
        LocalStateReads++;
        if (body is null)
        {
            LocalStateRefused++; LocalStateRefuseByCode[7]++;
            return null;
        }
        if (!LocalStateCodec.TryParse(body, out var st, out var why))
        {
            LocalStateRefused++;
            int slot = (byte)why < 7 ? (byte)why : 7;
            LocalStateRefuseByCode[slot]++;
            return null;
        }
        BodyStateUnknownTags += LocalStateCodec.UnknownTags(body);
        return st;
    }
    /// <summary>WO-100.5: how many of those the DLL refused (a gate said no, or it is an older DLL).</summary>
    public long BodyStateRefused { get; private set; }
    /// <summary>WO-100.5: running total of tags the native decode could not place. Healthy value is 0.</summary>
    public long BodyStateUnknownTags { get; private set; }

    /// <summary>WO-102.5 Phase 2: 0x0B scans issued.</summary>
    public long NpcScanReads { get; private set; }
    /// <summary>WO-102.5 Phase 2: 0x0B scans the DLL refused or never answered.</summary>
    public long NpcScanRefused { get; private set; }
    /// <summary>WO-102.5 Phase 2: refusals by reason code (index = <see cref="NpcScanRefuse"/>; 255 folds into slot 7).</summary>
    public long[] NpcScanRefuseByCode { get; } = new long[8];

    /// <summary>
    /// WO-102.5 Phase 2: one batched native NPC scan (pipe 0x0B -> 0x87).
    /// <paramref name="anchors"/> is 1..8 world positions (self + peer
    /// ghosts); an entity is returned if it is within <paramref name="radius"/>
    /// of ANY anchor. Null on any refusal, the reason counted, never guessed
    /// -- same discipline as <see cref="ReadLocalStateAsync"/>.
    /// </summary>
    public async Task<NpcScanResult?> ScanNpcsAsync(
        IReadOnlyList<(float X, float Y, float Z)> anchors, float radius, CancellationToken ct = default)
    {
        if (anchors.Count is < 1 or > 8) throw new ArgumentOutOfRangeException(nameof(anchors));
        var payload = new byte[1 + 4 + anchors.Count * 12];
        payload[0] = (byte)anchors.Count;
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(1), radius);
        int o = 5;
        foreach (var a in anchors)
        {
            BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(o), a.X); o += 4;
            BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(o), a.Y); o += 4;
            BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(o), a.Z); o += 4;
        }
        var (body, _) = await SendAndAwaitAsync(ScanNpcs, payload, NpcScanReply, ct);
        NpcScanReads++;
        if (body is null)
        {
            NpcScanRefused++; NpcScanRefuseByCode[7]++;
            return null;
        }
        if (!NpcScanCodec.TryParse(body, out var res, out var why))
        {
            NpcScanRefused++;
            int slot = (byte)why < 7 ? (byte)why : 7;
            NpcScanRefuseByCode[slot]++;
            return null;
        }
        return res;
    }

    /// <summary>
    /// The shared send-and-wait core. Sequence matching is identical for every
    /// reply kind because the DLL puts seq at body[1] in all of them (WO-100
    /// S3.1's fix, which this generalises rather than duplicates).
    /// </summary>
    private async Task<(byte[]? Body, PipeReason Fail)> SendAndAwaitAsync(
        byte type, byte[] payload, byte wantType, CancellationToken ct)
    {
        if (!await EnsureConnectedAsync(ct)) return (null, PipeReason.NotConnected);

        await _gate.WaitAsync(ct);
        try
        {
            // Drop anything left over from an earlier command that timed out.
            // Without this the first read below returns that command's answer
            // as if it were ours -- the defect described at _replies.
            while (_replies.Reader.TryRead(out var leftover))
            {
                StaleRepliesDropped++;
                Console.WriteLine($"[combat] dropped a leftover reply 0x{leftover.Type:X2} " +
                                  $"before sending 0x{type:X2} (total {StaleRepliesDropped})");
            }

            await WriteFrameAsync(type, payload, ct);

            // Bounded wait with an explicit give-up, and the waited time is
            // reported on expiry (WO-100 Phase 4 item 2).
            var deadline = DateTime.UtcNow + ReplyDeadline;
            var started  = DateTime.UtcNow;
            while (true)
            {
                var left = deadline - DateTime.UtcNow;
                if (left <= TimeSpan.Zero)
                {
                    TimedOut++;
                    // WO-110 R12 (docs/WO-109-audit.md R12): the DLL numbers
                    // every frame it READS, so the reply to this timed-out
                    // command -- if it ever comes -- carries exactly the seq we
                    // were waiting for. Left as is, the next command's wait
                    // would take that late reply as its own answer. Advancing
                    // past it makes the late reply read as "older" above and be
                    // dropped, which is what it is.
                    if (_expectedSeq is byte w) _expectedSeq = (byte)(w + 1);
                    Console.WriteLine($"[combat] no answer to 0x{type:X2} after " +
                                      $"{(DateTime.UtcNow - started).TotalMilliseconds:F0} ms " +
                                      $"(deadline {ReplyDeadline.TotalMilliseconds:F0} ms, timeouts {TimedOut}; seq advanced past the missing reply)");
                    return (null, PipeReason.NoAnswer);
                }

                using var slice = CancellationTokenSource.CreateLinkedTokenSource(ct);
                slice.CancelAfter(left);
                (byte Type, byte[] Body) reply;
                try { reply = await _replies.Reader.ReadAsync(slice.Token); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { continue; }

                // WO-118: a DLL older than this command answers 0x81 with
                // reason UnknownCommand (WO-110 R12) instead of the typed reply.
                // Waiting out the whole deadline for a frame that never comes
                // held the gate for 5 s -- per heartbeat, for the 0x14 status.
                if (reply.Type == Result && wantType != Result && reply.Body.Length >= 3
                    && reply.Body[2] == (byte)PipeReason.UnknownCommand
                    && (_expectedSeq is not byte ws || reply.Body[1] == ws))
                {
                    _expectedSeq = (byte)(reply.Body[1] + 1);
                    return (null, PipeReason.UnknownCommand);
                }
                if (reply.Type != wantType || reply.Body.Length < 2)
                {
                    StaleRepliesDropped++;   // wrong frame kind, or truncated: not ours
                    continue;
                }

                byte seq = reply.Body[1];
                if (_expectedSeq is byte want && seq != want)
                {
                    // Older than what we are waiting for? Then it belongs to a
                    // command that already gave up. Anything else means we
                    // missed a reply, so resync on it rather than hanging.
                    bool older = (byte)(want - seq) is > 0 and < 128;
                    if (older)
                    {
                        StaleRepliesDropped++;
                        Console.WriteLine($"[combat] dropped stale reply seq={seq} (expected {want}, " +
                                          $"total {StaleRepliesDropped})");
                        continue;
                    }
                    Console.WriteLine($"[combat] reply seq={seq} is ahead of the expected {want} -- resyncing");
                }
                _expectedSeq = (byte)(seq + 1);
                return (reply.Body, PipeReason.Ok);
            }
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Drop();
            return (null, PipeReason.NotConnected);
        }
        finally { _gate.Release(); }
    }

    private static readonly TimeSpan ReplyDeadline = TimeSpan.FromSeconds(5);

    private async Task WriteFrameAsync(byte type, byte[] payload, CancellationToken ct)
    {
        var frame = new byte[3 + payload.Length];
        frame[0] = type;
        BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(1), (ushort)payload.Length);
        payload.CopyTo(frame.AsSpan(3));
        await _pipe!.WriteAsync(frame, ct);
        await _pipe.FlushAsync(ct);
    }

    private async Task<(byte Type, byte[] Body)> ReadFrameAsync(CancellationToken ct)
    {
        var head = new byte[3];
        await ReadExactAsync(head, ct);
        int len = BinaryPrimitives.ReadUInt16LittleEndian(head.AsSpan(1));
        var body = new byte[len];
        if (len > 0) await ReadExactAsync(body, ct);
        return (head[0], body);
    }

    private async Task ReadExactAsync(byte[] buffer, CancellationToken ct)
    {
        int got = 0;
        while (got < buffer.Length)
        {
            int n = await _pipe!.ReadAsync(buffer.AsMemory(got), ct);
            if (n <= 0) throw new IOException("pipe closed");
            got += n;
        }
    }

    private void Drop()
    {
        _pipe?.Dispose();
        _pipe = null;
        // A reconnect gets a fresh channel and no sequence expectation: the
        // DLL's counter keeps running across connections, so carrying the old
        // expectation over would reject the first real reply.
        _replies.Writer.TryComplete();
        _replies = NewReplyChannel();
        _expectedSeq = null;
        Console.WriteLine("[combat] lost the connection to KCDMP.dll");
    }

    public ValueTask DisposeAsync()
    {
        _pipe?.Dispose();
        _pipe = null;
        _replies.Writer.TryComplete();
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }
}


/// <summary>
/// WO-121: the DLL's 0x96 frame -- an action the local engine committed.
/// <c>[kind:1][phase:1][inputClass:1][zone(table id):1][attackType:1][flags:1][rowGuid:16][eid:4][nameLen:1][name]</c>.
/// eid 0 = the local player; otherwise an NPC (by its authored entity name).
/// </summary>
public readonly record struct LocalActionFrame(byte Kind, byte Phase, sbyte InputClass, sbyte ZoneTableId, sbyte AttackType,
                                               byte Flags, Guid Row, uint Eid, string Name)
{
    public static bool TryParse(ReadOnlySpan<byte> b, out LocalActionFrame f)
    {
        f = default;
        if (b.Length < 27) return false;
        int n = b[26];
        if (b.Length != 27 + n || n > 63) return false;
        f = new LocalActionFrame(b[0], b[1], unchecked((sbyte)b[2]), unchecked((sbyte)b[3]), unchecked((sbyte)b[4]), b[5],
                                 new Guid(b.Slice(6, 16)), BinaryPrimitives.ReadUInt32LittleEndian(b[22..]),
                                 n == 0 ? "" : System.Text.Encoding.UTF8.GetString(b.Slice(27, n)));
        return true;
    }
}
