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

    private const int GuidLen = 16;

    private const byte LocalHit = 0x90;

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
    public Func<Guid, float, float, bool, Task>? OnLocalHit { get; set; }

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
                Console.WriteLine($"[combat] pipe frame 0x{type:X2} ({body.Length} bytes)");
                if (type == LocalHit && body.Length >= 24)
                {
                    var   soul    = new Guid(body.AsSpan(0, 16));
                    float stamina = BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(16));
                    float health  = BinaryPrimitives.ReadSingleLittleEndian(body.AsSpan(20));
                    // WO-86: trailing died byte; absent from a pre-WO-86 DLL.
                    bool  died    = body.Length >= 25 && body[24] != 0;
                    if (died) Console.WriteLine($"[npcdeath] DLL reports a FATAL local hit on {soul} (hp -{health:F1})");
                    if (OnLocalHit is { } handler)
                    {
                        try { await handler(soul, stamina, health, died); }
                        catch (Exception ex) { Console.WriteLine($"[combat] local hit not sent: {ex.Message}"); }
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
                    Console.WriteLine($"[combat] no answer to 0x{type:X2} after " +
                                      $"{(DateTime.UtcNow - started).TotalMilliseconds:F0} ms " +
                                      $"(deadline {ReplyDeadline.TotalMilliseconds:F0} ms, timeouts {TimedOut})");
                    return (null, PipeReason.NoAnswer);
                }

                using var slice = CancellationTokenSource.CreateLinkedTokenSource(ct);
                slice.CancelAfter(left);
                (byte Type, byte[] Body) reply;
                try { reply = await _replies.Reader.ReadAsync(slice.Token); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { continue; }

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
