using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Globalization;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// Bridges a local KCD2 game instance with the central relay server.
///
/// Responsibilities:
///   1. Wait for the game to have a save loaded (GameTime > 0).
///   2. Connect to the relay server via TCP and send Handshake.
///   3. Push local player position every tick (only when changed).
///   4. Receive Ghost packets from the relay server and update the local
///      game's ghost NPCs.
///
/// How it talks to the game is <see cref="IGameTransport"/>'s problem, not this
/// class's. Reading a state sample is one call; whether that costs a round trip
/// (HTTP) or reads a pushed frame (log tail) is the transport's business.
///
/// Outbound Lua is batched. <c>ExecuteAsync</c> buffers and the tick loop
/// flushes once, so N ghost updates arriving between ticks become one call
/// instead of N. Round trips are the only thing the channel charges for --
/// payload is free -- so this is close to pure win.
/// </summary>
public partial class GameBridge(ClientConfig config)
{
    private const int TickMs           = 10;
    private const float PosThreshold  = 0.05f;
    private const float RotThreshold  = 0.02f;

    private IGameTransport _transport = null!;   // set in RunAsync before use

    // Last pushed position (for change detection)
    private float _lastX, _lastY, _lastZ, _lastRotZ;
    private bool _hasPushed;

    // Ping: maps sent timestamp (ticks) → Stopwatch timestamp at send time
    private readonly ConcurrentDictionary<long, long> _pingsSent = new();

    // Voice: frames captured by VoiceChat are queued here, drained in main loop
    private readonly ConcurrentQueue<byte[]> _voiceQueue = new();
    private VoiceChat? _voice;

    /// <summary>
    /// Interaction sessions (WO-2). Dice and duelling hang off this rather than
    /// adding their own protocols. Null until connected.
    /// </summary>
    public InteractionClient? Interactions { get; private set; }

    // ghostId → display name, from Name packets. Lets an invite prompt say who
    // is asking instead of showing a bare relay id.
    private readonly ConcurrentDictionary<byte, string> _ghostNames = new();

    public async Task RunAsync(CancellationToken ct = default)
    {
        var http = new HttpGameTransport(config.GameApiBase);
        await http.StartAsync(ct);
        _transport = http;

        try
        {
            await RunLoopAsync(http, ct);
        }
        finally
        {
            if (!ReferenceEquals(_transport, http))
                await _transport.DisposeAsync();
            await http.DisposeAsync();
        }
    }

    /// <summary>
    /// Picks the state-read transport once the game is up.
    ///
    /// Log tail is preferred but only works with the mod loaded and emitting,
    /// so it is verified to actually produce a frame before being adopted --
    /// otherwise the agent would sit reading nothing and look like a game that
    /// never becomes ready. HTTP polling is the fallback and always works.
    /// </summary>
    private async Task<IGameTransport> SelectTransportAsync(HttpGameTransport http, CancellationToken ct)
    {
        if (!config.Transport.Equals("logtail", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine($"[transport] {http.Name} (configured)");
            return http;
        }

        LogTailGameTransport tail;
        try
        {
            tail = LogTailGameTransport.Create(http, config.EmitIntervalMs);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[transport] log tail unavailable ({ex.Message}); falling back to {http.Name}");
            return http;
        }

        await tail.StartAsync(ct);
        Console.WriteLine($"[transport] waiting for the mod's state emitter ({Path.GetFileName(tail.LogPath)})...");

        var deadline = DateTime.UtcNow.AddSeconds(3);
        while (tail.FramesReceived == 0 && DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
            await Task.Delay(50, ct);

        if (tail.FramesReceived == 0)
        {
            Console.WriteLine($"[transport] emitter produced no frames; falling back to {http.Name}");
            Console.WriteLine("[transport] (is the mod installed and loaded? look for '=== MOD INIT ===' in kcd.log)");
            await tail.DisposeAsync();
            return http;
        }

        Console.WriteLine($"[transport] {tail.Name} — 0 round trips per state read");
        return tail;
    }

    private async Task RunLoopAsync(HttpGameTransport http, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            await WaitForGameAsync(ct);
            if (ct.IsCancellationRequested) break;

            // Chosen after the game is up, because the log-tail probe needs the
            // mod running to answer.
            if (ReferenceEquals(_transport, http))
                _transport = await SelectTransportAsync(http, ct);

            try
            {
                await ConnectAndRunAsync(ct);
            }
            catch (OperationCanceledException) { break; }
            catch (ProtocolVersionMismatchException ex)
            {
                // Fatal: reconnecting to the same relay cannot succeed.
                Console.WriteLine($"[!] {ex.Message}");
                break;
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[!] Unexpected error: {ex.Message}");
            }

            if (ct.IsCancellationRequested) break;
            Console.WriteLine("Reconnecting in 3 s...");
            Console.WriteLine();
            await Task.Delay(3000, ct).ContinueWith(_ => { });
        }
    }

    // -------------------------------------------------------------------------
    // Phase 1 – wait for a save to be loaded
    // -------------------------------------------------------------------------

    private async Task WaitForGameAsync(CancellationToken ct = default)
    {
        Console.WriteLine("Waiting for game to load a save...");
        while (!ct.IsCancellationRequested)
        {
            if (await _transport.IsGameReadyAsync(ct))
            {
                Console.WriteLine("Game ready!");
                return;
            }
            await Task.Delay(3000, ct).ContinueWith(_ => { });
        }
    }

    // -------------------------------------------------------------------------
    // Phase 2 – connected to relay server
    // -------------------------------------------------------------------------

    private async Task ConnectAndRunAsync(CancellationToken appCt = default)
    {
        using var tcp = new TcpClient();

        Console.WriteLine($"Connecting to relay server {config.ServerHost}:{config.ServerPort}...");
        try
        {
            await tcp.ConnectAsync(config.ServerHost, config.ServerPort);
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[!] Cannot connect: {ex.Message}");
            return;
        }

        var stream = tcp.GetStream();

        // --- Handshake:  [version:1][nameLen:1][name:UTF-8] ---
        var nameBytes = Encoding.UTF8.GetBytes(config.PlayerName ?? Environment.MachineName);
        if (nameBytes.Length > 255)
        {
            // Trim to 255 bytes without splitting a multi-byte UTF-8 sequence:
            // back off while the first cut byte is a continuation byte (10xxxxxx).
            int len = 255;
            while (len > 0 && (nameBytes[len] & 0xC0) == 0x80)
                len--;
            nameBytes = nameBytes[..len];
        }

        var handshake = new byte[3 + 2 + nameBytes.Length];
        handshake[0] = Protocol.Handshake;
        BinaryPrimitives.WriteUInt16LittleEndian(handshake.AsSpan(1), (ushort)(2 + nameBytes.Length));
        handshake[3] = Protocol.Version;
        handshake[4] = (byte)nameBytes.Length;
        nameBytes.CopyTo(handshake, 5);
        await stream.WriteAsync(handshake);

        // --- Ack (S→C 0xFF [id:1]) or rejection (S→C 0x09 [serverVersion:1]) ---
        // Both are 4 bytes on the wire, so the type byte decides.
        var reply = new byte[4]; // header(3) + 1
        await ReadExactAsync(stream, reply);

        if (reply[0] == Protocol.VersionMismatch)
            throw new ProtocolVersionMismatchException(reply[3]);

        if (reply[0] != Protocol.Ack)
        {
            Console.WriteLine($"[!] Expected Ack, got packet type 0x{reply[0]:X2}. Dropping connection.");
            return;
        }

        byte myId = reply[3];
        Console.WriteLine($"Connected! Assigned id={myId} (protocol v{Protocol.Version})");
        Console.WriteLine();

        _hasPushed = false;

        // --- Interaction layer ---
        // Framing lives here because this class owns the stream; the interaction
        // client only decides what to say.
        var interactions = new InteractionClient(async (type, payload, ict) =>
        {
            var pkt = new byte[3 + payload.Length];
            pkt[0] = type;
            BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(1), (ushort)payload.Length);
            payload.CopyTo(pkt, 3);
            await stream.WriteAsync(pkt, ict);
        });
        WireInteractionFeedback(interactions);
        Interactions = interactions;

        // Kick off the Lua interp tick immediately so KCD2MP.isRiding gets updated
        // even before the first ghost is spawned (e.g. player already on horse at connect time).
        try { await ExecLuaAsync("if KCD2MP_StartInterp then KCD2MP_StartInterp() end"); }
        catch { /* ignore if mod not loaded yet */ }

        // Start voice chat — frames captured on background thread, queued, sent in main loop.
        // Left null when disabled, which also suppresses every _voice?. call below.
        if (config.VoiceChatEnabled)
        {
            _voice = new VoiceChat(frame => _voiceQueue.Enqueue(frame));
            try { _voice.Start(); }
            catch (Exception ex) { Console.WriteLine($"[voice] Failed to start: {ex.Message}"); }
        }
        else
        {
            Console.WriteLine("[voice] Disabled by config — microphone will not be opened.");
        }

        using var cts = CancellationTokenSource.CreateLinkedTokenSource(appCt);

        // Start background tasks
        var receiveTask  = ReceiveLoopAsync(stream, cts.Token);
        var pingTask     = PingLoopAsync(stream, cts.Token);

        // --- Position push loop ---
        try
        {
            int tickCount = 0;
            long totalReadMs = 0;

            while (tcp.Connected)
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var state = await _transport.ReadPlayerStateAsync(cts.Token);
                sw.Stop();
                totalReadMs += sw.ElapsedMilliseconds;
                tickCount++;

                if (state.HasValue)
                {
                    var (x, y, z, rotZ, riding) = state.Value;

                    // Update voice local position and recalculate all player volumes.
                    if (_voice != null)
                    {
                        _voice.LocalPos = (x, y, z);
                        _voice.UpdateAllVolumes();
                    }

                    if (!_hasPushed || HasChanged(x, y, z, rotZ))
                    {
                        _hasPushed = true;
                        _lastX = x; _lastY = y; _lastZ = z; _lastRotZ = rotZ;
                        await SendPositionAsync(stream, x, y, z, rotZ, riding);
                        Console.WriteLine($"[pos] {x:F1} {y:F1} {z:F1}  rot={rotZ:F2}  riding={riding}  read={sw.ElapsedMilliseconds}ms");
                    }
                }

                // Drain captured voice frames and send to server.
                while (_voiceQueue.TryDequeue(out var voiceFrame))
                    await SendVoiceAsync(stream, voiceFrame);

                // Send everything the receive loop buffered this tick as one call.
                await _transport.FlushAsync(cts.Token);

                // Print average read time every 100 ticks
                if (tickCount % 100 == 0)
                    Console.WriteLine($"[stat] avg read={totalReadMs / tickCount}ms over {tickCount} ticks");

                await Task.Delay(TickMs);
            }
        }
        finally
        {
            cts.Cancel();
            try { await receiveTask;  } catch { }
            try { await pingTask;     } catch { }
            _voice?.Stop();
            _voice?.Dispose();
            _voice = null;

            // The relay drops our sessions when the socket closes, so local
            // state has to go too or a reconnect would think it is still busy.
            Interactions?.Reset();
            Interactions = null;
            _ghostNames.Clear();

            Console.WriteLine("Removing all ghosts...");
            try { await ExecLuaAsync("KCD2MP_RemoveAllGhosts()"); } catch { }
        }
    }

    // -------------------------------------------------------------------------
    // Background rotation + riding state loop (every RotStateIntervalMs)
    // -------------------------------------------------------------------------

    private async Task PingLoopAsync(NetworkStream stream, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(2000, ct);
                long ts = DateTime.UtcNow.Ticks;
                var tsBytes = new byte[8];
                BinaryPrimitives.WriteInt64LittleEndian(tsBytes, ts);
                _pingsSent[ts] = System.Diagnostics.Stopwatch.GetTimestamp();
                var packet = new byte[3 + 8];
                packet[0] = Protocol.Ping;
                BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), 8);
                tsBytes.CopyTo(packet, 3);
                await stream.WriteAsync(packet, ct);
            }
            catch (OperationCanceledException) { break; }
            catch { break; }
        }
    }

    // -------------------------------------------------------------------------
    // Receive loop – server pushes Ghost and Name packets to us
    // -------------------------------------------------------------------------

    private async Task ReceiveLoopAsync(NetworkStream stream, CancellationToken ct)
    {
        var header = new byte[3];
        try
        {
            while (!ct.IsCancellationRequested)
            {
                await ReadExactAsync(stream, header, ct);
                int type       = header[0];
                int payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));
                var payload    = new byte[payloadLen];
                await ReadExactAsync(stream, payload, ct);

                if (type == Protocol.Pong && payloadLen == 8)
                {
                    long ts = BinaryPrimitives.ReadInt64LittleEndian(payload);
                    if (_pingsSent.TryRemove(ts, out long sentAt))
                    {
                        int ms = (int)((System.Diagnostics.Stopwatch.GetTimestamp() - sentAt)
                                       * 1000L / System.Diagnostics.Stopwatch.Frequency);
                        Console.WriteLine($"[ping] {ms} ms");
                        try { await ExecLuaAsync($"KCD2MP_ShowPing({ms})"); } catch { }
                    }
                }
                else if (type == Protocol.Ghost && payloadLen == Protocol.GhostPayloadLen)
                {
                    // Ghost: [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f][flags:1]
                    // Length is exact now that the handshake pins the version.
                    byte ghostId   = payload[0];
                    float x        = ReadFloat(payload, 1);
                    float y        = ReadFloat(payload, 5);
                    float z        = ReadFloat(payload, 9);
                    float rotZ     = ReadFloat(payload, 13);
                    bool  isRiding = (payload[17] & 0x01) != 0;
                    _voice?.UpdateGhostPos(ghostId, x, y, z);
                    await UpdateGhostAsync(ghostId.ToString(), x, y, z, rotZ, isRiding);
                }
                else if (type == Protocol.Name && payloadLen >= 2)
                {
                    // Name packet: [ghostId:1][name:UTF-8...]
                    byte ghostId = payload[0];
                    string gname = Encoding.UTF8.GetString(payload, 1, payloadLen - 1);
                    _ghostNames[ghostId] = gname;
                    await SetGhostNameAsync(ghostId.ToString(), gname);
                }
                else if (type == Protocol.Disconnect && payloadLen == 1)
                {
                    // Disconnect packet: [ghostId:1]
                    byte ghostId = payload[0];
                    Console.WriteLine($"[disconnect] ghost {ghostId} removed");
                    _voice?.RemovePlayer(ghostId);
                    try { await ExecLuaAsync($"KCD2MP_RemoveGhost(\"{ghostId}\")"); } catch { }
                }
                else if (type == Protocol.VoiceDown && payloadLen == 1 + Protocol.VoiceFrameLen)
                {
                    // Voice packet: [sourceId:1][pcm: 640 bytes]
                    byte sourceId = payload[0];
                    var pcm = new byte[Protocol.VoiceFrameLen];
                    Buffer.BlockCopy(payload, 1, pcm, 0, Protocol.VoiceFrameLen);
                    _voice?.OnVoiceReceived(sourceId, pcm);
                }
                else if (Interactions?.HandlePacket(type, payload) == true)
                {
                    // Session packet consumed by the interaction layer.
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException) { }
    }

    // -------------------------------------------------------------------------
    // Game REST API helpers
    // -------------------------------------------------------------------------

    private async Task UpdateGhostAsync(string ghostId, float x, float y, float z, float rotZ, bool isRiding)
    {
        string gx   = x.ToString("F2",  CultureInfo.InvariantCulture);
        string gy   = y.ToString("F2",  CultureInfo.InvariantCulture);
        string gz   = z.ToString("F2",  CultureInfo.InvariantCulture);
        string rot  = rotZ.ToString("F4", CultureInfo.InvariantCulture);
        string ride = isRiding ? "true" : "false";

        try
        {
            await ExecLuaAsync($@"KCD2MP_UpdateGhost(""{ghostId}"",{gx},{gy},{gz},{rot},{ride})");
            Console.WriteLine($"[ghost {ghostId}] {gx} {gy} {gz} riding={isRiding}");
        }
        catch { /* game might have unloaded */ }
    }

    private async Task SetGhostNameAsync(string ghostId, string ghostName)
    {
        // Escape any quotes in name to avoid Lua injection
        var safeName = ghostName.Replace("\\", "\\\\").Replace("\"", "\\\"");
        try
        {
            await ExecLuaAsync($@"KCD2MP_SetGhostName(""{ghostId}"",""{safeName}"")");
            Console.WriteLine($"[name] ghost {ghostId} = {ghostName}");
        }
        catch { }
    }

    /// <summary>
    /// Reports session lifecycle to the console and to the game.
    ///
    /// Kept separate from <see cref="InteractionClient"/> so that class stays a
    /// pure protocol layer: presentation is queued as Lua and rides the batch
    /// like any other outbound call.
    /// </summary>
    private void WireInteractionFeedback(InteractionClient interactions)
    {
        interactions.InviteReceived += invite =>
        {
            string who = _ghostNames.TryGetValue(invite.FromGhostId, out var n) ? n : $"player {invite.FromGhostId}";
            Console.WriteLine($"[interaction] {who} invites you to {invite.Kind} (session {invite.SessionId})");
            _ = ExecLuaAsync($"if KCD2MP_ShowInvite then KCD2MP_ShowInvite({invite.SessionId},\"{Escape(who)}\",\"{invite.Kind}\") end");
        };

        interactions.SessionStarted += session =>
        {
            Console.WriteLine($"[interaction] {session.Kind} session {session.SessionId} started as {session.Role}");
            _ = ExecLuaAsync($"if KCD2MP_HideInvite then KCD2MP_HideInvite() end");
        };

        interactions.SessionEnded += (sid, reason) =>
        {
            Console.WriteLine($"[interaction] session {sid} ended: {reason}");
            _ = ExecLuaAsync($"if KCD2MP_HideInvite then KCD2MP_HideInvite() end");
            _ = ExecLuaAsync($"if KCD2MP_ShowInteractionMsg then KCD2MP_ShowInteractionMsg(\"{reason}\") end");
        };
    }

    /// <summary>Escapes a string for embedding in a double-quoted Lua literal.</summary>
    private static string Escape(string s) =>
        s.Replace("\\", "\\\\").Replace("\"", "\\\"");

    /// <summary>
    /// Queues a Lua statement. The transport batches it; the tick loop flushes.
    /// Returning without a round trip is the point -- the receive loop can take
    /// a burst of ghost updates without blocking on HTTP for each one.
    /// </summary>
    private Task ExecLuaAsync(string lua) => _transport.ExecuteAsync(lua);

    // -------------------------------------------------------------------------
    // TCP helpers
    // -------------------------------------------------------------------------

    private static async Task SendVoiceAsync(NetworkStream stream, byte[] pcm)
    {
        // 3 header + 640 payload = 643 bytes
        var packet = new byte[3 + Protocol.VoiceFrameLen];
        packet[0] = Protocol.VoiceUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.VoiceFrameLen);
        Buffer.BlockCopy(pcm, 0, packet, 3, Protocol.VoiceFrameLen);
        await stream.WriteAsync(packet);
    }

    private static async Task SendPositionAsync(NetworkStream stream, float x, float y, float z, float rotZ, bool isRiding)
    {
        // 3 header + 17 payload = 20 bytes
        var packet = new byte[3 + Protocol.PositionPayloadLen];
        packet[0] = Protocol.Position;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.PositionPayloadLen);
        WriteFloat(packet, 3,  x);
        WriteFloat(packet, 7,  y);
        WriteFloat(packet, 11, z);
        WriteFloat(packet, 15, rotZ);
        packet[19] = isRiding ? (byte)0x01 : (byte)0x00;
        await stream.WriteAsync(packet);
    }

    private static float ReadFloat(byte[] buf, int offset) =>
        BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(buf.AsSpan(offset)));

    private static void WriteFloat(byte[] buf, int offset, float value) =>
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(offset), BitConverter.SingleToInt32Bits(value));

    private static async Task ReadExactAsync(NetworkStream stream, byte[] buffer, CancellationToken ct = default)
    {
        int offset = 0;
        while (offset < buffer.Length)
        {
            int n = await stream.ReadAsync(buffer, offset, buffer.Length - offset, ct);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
    }

    private bool HasChanged(float x, float y, float z, float rotZ) =>
        Math.Abs(x - _lastX)       > PosThreshold ||
        Math.Abs(y - _lastY)       > PosThreshold ||
        Math.Abs(z - _lastZ)       > PosThreshold ||
        Math.Abs(rotZ - _lastRotZ) > RotThreshold;

    // -------------------------------------------------------------------------
    // Source-generated regexes
    // -------------------------------------------------------------------------

    // XML scraping moved to HttpGameTransport along with the calls that needed it.
}
