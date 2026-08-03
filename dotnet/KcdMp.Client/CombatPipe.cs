using System.Buffers.Binary;
using System.IO.Pipes;

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
    private const byte Result            = 0x81;
    private const byte Pong              = 0x83;

    private const int GuidLen = 16;

    private const byte LocalHit = 0x90;

    private readonly SemaphoreSlim _gate = new(1, 1);
    private NamedPipeClientStream? _pipe;
    private bool _warnedUnavailable;

    // LocalHit arrives unsolicited, interleaved with command replies, so a
    // single background reader owns the stream and routes frames: replies to
    // whoever is waiting, hits to the callback. Reading inline per command
    // would mistake a hit for a reply.
    private Task? _reader;
    private readonly SemaphoreSlim _replyReady = new(0);
    private (byte Type, byte[] Body) _lastReply;

    /// <summary>
    /// Raised when the DLL reports that a nearby NPC lost health for a reason
    /// this client did not cause. The handler is expected to put it on the wire.
    /// </summary>
    public Func<Guid, float, float, Task>? OnLocalHit { get; set; }

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

    /// <summary>Round-trip check that the DLL is alive and pumping frames.</summary>
    public async Task<bool> PingAsync(CancellationToken ct = default)
    {
        if (!await EnsureConnectedAsync(ct)) return false;
        await _gate.WaitAsync(ct);
        try
        {
            await WriteFrameAsync(Ping, [], ct);
            if (!await _replyReady.WaitAsync(TimeSpan.FromSeconds(5), ct)) return false;
            return _lastReply.Type == Pong;
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
                    if (OnLocalHit is { } handler)
                    {
                        try { await handler(soul, stamina, health); }
                        catch (Exception ex) { Console.WriteLine($"[combat] local hit not sent: {ex.Message}"); }
                    }
                }
                else
                {
                    _lastReply = (type, body);
                    _replyReady.Release();
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
    {
        if (!await EnsureConnectedAsync(ct)) return false;

        await _gate.WaitAsync(ct);
        try
        {
            await WriteFrameAsync(type, payload, ct);
            // Wait for the reader to hand over a reply. A timeout here means the
            // DLL is wedged, not that the command failed, so it is reported
            // distinctly rather than folded into "not applied".
            if (!await _replyReady.WaitAsync(TimeSpan.FromSeconds(5), ct))
            {
                Console.WriteLine("[combat] the DLL did not answer within 5 s");
                return false;
            }
            var (rtype, body) = _lastReply;
            // The DLL answers with the truth after applying on the game thread,
            // so a false here means the soul is not loaded on this client —
            // normal when the peer is somewhere we have not streamed in.
            return rtype == Result && body.Length >= 1 && body[0] == 1;
        }
        catch (Exception ex) when (ex is IOException or ObjectDisposedException)
        {
            Drop();
            return false;
        }
        finally { _gate.Release(); }
    }

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
        Console.WriteLine("[combat] lost the connection to KCDMP.dll");
    }

    public ValueTask DisposeAsync()
    {
        _pipe?.Dispose();
        _pipe = null;
        _gate.Dispose();
        return ValueTask.CompletedTask;
    }
}
