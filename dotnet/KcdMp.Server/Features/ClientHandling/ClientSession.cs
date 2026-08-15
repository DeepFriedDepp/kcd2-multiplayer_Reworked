using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
using System.Threading.Channels;
using KcdMp.Server.Features.Interactions;
using KcdMp.Server.Features.Tcp;
using ILogger = Serilog.ILogger;

namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// Handles one connected client agent.
///
/// See <see cref="Protocol"/> for the framing and packet layouts.
/// </summary>
public class ClientSession
{
    private static int _idCounter;

    private readonly ILogger _logger;
    private readonly TcpClient _tcp;
    private readonly NetworkStream _stream;
    private readonly TcpBroadcastService _broadcastService;
    private readonly SessionManager _sessions;
    private readonly ClientHandler _clientHandler;
    private readonly Channel<byte[]> _writeQueue = Channel.CreateUnbounded<byte[]>();

    public byte Id { get; } = (byte)Interlocked.Increment(ref _idCounter);
    public string? Name { get; private set; }
    public bool IsReady => Name is not null;

    /// <summary>WO-19. Null when the client's Handshake carried no trailing
    /// release-version field (an old build, or a synthetic test peer).</summary>
    public string? ReleaseVersion { get; private set; }

    public ClientSession(ILogger logger, TcpClient tcp, TcpBroadcastService broadcastService,
        SessionManager sessions, ClientHandler clientHandler)
    {
        _logger = logger;
        _tcp = tcp;
        _stream = tcp.GetStream();
        _broadcastService = broadcastService;
        _sessions = sessions;
        _clientHandler = clientHandler;
    }

    public async Task RunAsync()
    {
        var writeTask = WriteLoopAsync();
        try
        {
            // --- Handshake:  [version:1][nameLen:1][name:UTF-8] ---
            var header = new byte[3];
            await ReadExactAsync(header);

            if (header[0] != Protocol.Handshake)
            {
                _logger.Warning("[!] Client sent bad handshake type 0x{Type:X2}, dropping.", header[0]);
                return;
            }

            int handshakeLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));
            if (handshakeLen < 2)
            {
                // Pre-versioning clients sent [nameLen:1][name] with no version
                // byte. Their payload is the bare name, so there is nothing to
                // negotiate — reject rather than misread the first byte as a version.
                _logger.Warning("[!] Handshake payload too short ({Len} bytes) — client predates version negotiation. Rejecting.", handshakeLen);
                EnqueueRaw(BuildPacket(Protocol.VersionMismatch, [Protocol.Version]));
                return;
            }

            var handshakePayload = new byte[handshakeLen];
            await ReadExactAsync(handshakePayload);

            byte clientVersion = handshakePayload[0];
            if (clientVersion != Protocol.Version)
            {
                _logger.Warning("[!] Rejecting client with protocol v{ClientVersion}; this relay speaks v{ServerVersion}.",
                    clientVersion, Protocol.Version);
                EnqueueRaw(BuildPacket(Protocol.VersionMismatch, [Protocol.Version]));
                return;
            }

            int nameLen = handshakePayload[1]; // single byte, max 255
            if (nameLen > handshakeLen - 2)
            {
                _logger.Warning("[!] Handshake declares a {NameLen}-byte name but carries {Available}. Dropping.",
                    nameLen, handshakeLen - 2);
                return;
            }
            Name = Encoding.UTF8.GetString(handshakePayload, 2, nameLen);

            // WO-19: an optional trailing release-version field, the same
            // idiom as Invite's [configLen][config] -- whatever is left after
            // the name is the sender's release version, exactly zero bytes
            // for an old build that never sent one.
            int releaseVersionOffset = 2 + nameLen;
            if (handshakeLen > releaseVersionOffset)
                ReleaseVersion = Encoding.UTF8.GetString(handshakePayload, releaseVersionOffset, handshakeLen - releaseVersionOffset);

            _logger.Information("[+] '{Name}' connected (id={Id}, protocol v{Version}, release {Release}) from {ClientRemoteEndPoint}.",
                Name, Id, clientVersion, ReleaseVersion ?? "(none)", _tcp.Client.RemoteEndPoint);

            // Send Ack with assigned ID
            EnqueueRaw(BuildPacket(Protocol.Ack, [Id]));

            // Broadcast this client's name to all others; send existing names to this client
            _broadcastService.BroadcastName(this);
            _broadcastService.SendAllNamesTo(this);
            _broadcastService.BroadcastReleaseVersion(this);
            _broadcastService.SendAllReleaseVersionsTo(this);

            // WO-28: this client only just became ready, so the damage-authority
            // answer may have changed for it (it is the first client) or stayed
            // put (it is not). Told to everyone either way -- see
            // BroadcastCombatRole for why the current answer goes to all, not a
            // delta to the two whose answer moved.
            _broadcastService.BroadcastCombatRole();

            // --- Position receive loop ---
            // Payload length is now exact: the version byte replaced the old
            // 16-vs-17-byte sniffing, and a v1 peer always sends 17.
            var posPayload = new byte[Protocol.PositionPayloadLen];
            while (true)
            {
                await ReadExactAsync(header);
                int type = header[0];
                int payloadLen = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(1));

                if (type == Protocol.Ping && payloadLen == 8)
                {
                    // Ping → echo back as Pong with same 8-byte timestamp
                    var tsBytes = new byte[8];
                    await ReadExactAsync(tsBytes);
                    EnqueueRaw(BuildPacket(Protocol.Pong, tsBytes));
                    continue;
                }

                if (type == Protocol.VoiceUp && payloadLen == Protocol.VoiceFrameLen)
                {
                    // Voice frame → relay to all other ready clients
                    var pcm = new byte[Protocol.VoiceFrameLen];
                    await ReadExactAsync(pcm);
                    _broadcastService.BroadcastVoice(this, pcm);
                    continue;
                }

                // --- Interaction layer (WO-2) + dice layer (WO-5) ---
                if (type is Protocol.Invite or Protocol.InviteResponse
                         or Protocol.SessionEventUp or Protocol.SessionLeave
                         or Protocol.DiceIntent)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    HandleSessionPacket(type, body);
                    continue;
                }

                // --- Combat layer (WO-4) ---
                // Lengths are exact rather than minimum: a damage packet is
                // fixed-size, and accepting a short one would forward garbage
                // that the receiving client turns into a call into the game.
                if (type == Protocol.DamageUp && payloadLen == Protocol.DamageUpPayloadLen)
                {
                    var body = new byte[Protocol.DamageUpPayloadLen];
                    await ReadExactAsync(body);
                    _broadcastService.BroadcastDamage(this, body);
                    continue;
                }

                if (type == Protocol.DeathUp && payloadLen == Protocol.DeathUpPayloadLen)
                {
                    var body = new byte[Protocol.DeathUpPayloadLen];
                    await ReadExactAsync(body);
                    _broadcastService.BroadcastDeath(this, body);
                    continue;
                }

                // --- Appearance layer (WO-9) ---
                // [itemCount:1][itemClass:16]*itemCount. Validated against the
                // declared itemCount rather than trusted, so a bad count cannot
                // desync framing for the rest of the connection.
                if (type == Protocol.AppearanceUp
                    && payloadLen >= 1
                    && payloadLen <= 1 + Protocol.MaxAppearanceItems * Protocol.ItemClassLen)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    int itemCount = body[0];
                    if (payloadLen == 1 + itemCount * Protocol.ItemClassLen)
                        _broadcastService.BroadcastAppearance(this, body);
                    continue;
                }

                // --- Pause mitigation layer (WO-11) ---
                if (type == Protocol.PauseUp && payloadLen == Protocol.PauseUpPayloadLen)
                {
                    var body = new byte[Protocol.PauseUpPayloadLen];
                    await ReadExactAsync(body);
                    _broadcastService.BroadcastPause(this, body);
                    continue;
                }

                // --- Shared player combat layer (WO-28) ---
                // Lengths exact, same discipline as the combat layer above: a
                // short packet forwarded on becomes a call into the receiving
                // client's game.
                if (type == Protocol.PlayerStateUp && payloadLen == Protocol.PlayerStateUpPayloadLen)
                {
                    var body = new byte[Protocol.PlayerStateUpPayloadLen];
                    await ReadExactAsync(body);
                    _broadcastService.BroadcastPlayerState(this, body);
                    continue;
                }

                if (type == Protocol.PlayerHitUp && payloadLen == Protocol.PlayerHitUpPayloadLen)
                {
                    var body = new byte[Protocol.PlayerHitUpPayloadLen];
                    await ReadExactAsync(body);
                    // Routed to one recipient, not broadcast -- and dropped
                    // outright unless this client currently holds Rule 2's
                    // damage authority. The sending agent gates on this too;
                    // enforcing it here as well means a hand-run or buggy peer
                    // cannot inject NPC damage into someone else's game.
                    if (!_clientHandler.IsDamageAuthority(this))
                    {
                        _logger.Warning("[!] '{Name}' (id={Id}) sent PlayerHitUp without holding damage authority -- dropped.",
                            Name, Id);
                        continue;
                    }
                    _broadcastService.RoutePlayerHit(this, body);
                    continue;
                }

                if (type == Protocol.PlayerDeathUp && payloadLen == Protocol.PlayerDeathUpPayloadLen)
                {
                    // Carries nothing: the relay already knows who sent it.
                    _logger.Information("[death] '{Name}' (id={Id}) reported their own death.", Name, Id);
                    _broadcastService.BroadcastPlayerDeath(this);
                    continue;
                }

                if (type != Protocol.Position || payloadLen != Protocol.PositionPayloadLen)
                {
                    // Skip unknown/malformed packet
                    if (payloadLen > 0)
                    {
                        var skip = new byte[payloadLen];
                        await ReadExactAsync(skip);
                    }
                    continue;
                }

                await ReadExactAsync(posPayload, Protocol.PositionPayloadLen);

                float x    = ReadFloat(posPayload, 0);
                float y    = ReadFloat(posPayload, 4);
                float z    = ReadFloat(posPayload, 8);
                float rotZ = ReadFloat(posPayload, 12);
                byte  flags = posPayload[16];

                _broadcastService.Broadcast(this, x, y, z, rotZ, flags);
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException)
        {
            // Normal disconnect
        }
        finally
        {
            _writeQueue.Writer.Complete();
            await writeTask;
            _tcp.Dispose();
        }
    }

    /// <summary>Thread-safe: enqueue a Ghost packet to be sent to this client.</summary>
    public void EnqueueGhost(byte ghostId, float x, float y, float z, float rotZ, byte flags)
    {
        var payload = new byte[18];
        payload[0] = ghostId;
        WriteFloat(payload, 1, x);
        WriteFloat(payload, 5, y);
        WriteFloat(payload, 9, z);
        WriteFloat(payload, 13, rotZ);
        payload[17] = flags;
        EnqueueRaw(BuildPacket(Protocol.Ghost, payload));
    }

    /// <summary>Thread-safe: enqueue a Disconnect packet (0x06) to be sent to this client.</summary>
    public void EnqueueDisconnect(byte ghostId) =>
        EnqueueRaw(BuildPacket(Protocol.Disconnect, [ghostId]));

    /// <summary>Thread-safe: enqueue a Voice packet (0x08) to be sent to this client.</summary>
    public void EnqueueVoice(byte sourceId, byte[] pcm)
    {
        var payload = new byte[1 + pcm.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(pcm, 0, payload, 1, pcm.Length);
        EnqueueRaw(BuildPacket(Protocol.VoiceDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a Damage (0x13) packet to be sent to this client.
    /// The body is the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueDamage(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.DamageDown, payload));
    }

    /// <summary>Thread-safe: enqueue a Death (0x15) packet to be sent to this client.</summary>
    public void EnqueueDeath(byte sourceId, byte[] soulGuid)
    {
        var payload = new byte[1 + soulGuid.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(soulGuid, 0, payload, 1, soulGuid.Length);
        EnqueueRaw(BuildPacket(Protocol.DeathDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an Appearance (0x1B) packet to be sent to this
    /// client. The body is the upstream [itemCount][itemClass...] payload
    /// verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueAppearance(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.AppearanceDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a PauseDown (0x1D) packet to be sent to this
    /// client. The body is the upstream [state:1] payload verbatim, prefixed
    /// with who sent it.
    /// </summary>
    public void EnqueuePause(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.PauseDown, payload));
    }

    // -------------------------------------------------------------------------
    // Shared player combat layer (WO-28)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Thread-safe: enqueue a PlayerStateDown (0x20). The body is the upstream
    /// [health][stamina][flags] payload verbatim, prefixed with whose health it is.
    /// </summary>
    public void EnqueuePlayerState(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.PlayerStateDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a PlayerHitDown (0x22). The upstream body's leading
    /// targetGhostId is deliberately dropped -- this only ever reaches the
    /// player it names, who does not need telling it is about themselves.
    /// </summary>
    public void EnqueuePlayerHit(byte[] upstreamBody)
    {
        var payload = new byte[Protocol.PlayerHitDownPayloadLen];
        Buffer.BlockCopy(upstreamBody, 1, payload, 0, Protocol.PlayerHitDownPayloadLen);
        EnqueueRaw(BuildPacket(Protocol.PlayerHitDown, payload));
    }

    /// <summary>Thread-safe: enqueue a PlayerDeathDown (0x24). Idempotent at the receiver.</summary>
    public void EnqueuePlayerDeath(byte sourceId) =>
        EnqueueRaw(BuildPacket(Protocol.PlayerDeathDown, [sourceId]));

    /// <summary>
    /// Thread-safe: enqueue a CombatRole (0x25) telling this client whether it
    /// currently holds Rule 2's NPC→player damage authority.
    /// </summary>
    public void EnqueueCombatRole(bool isDamageAuthority) =>
        EnqueueRaw(BuildPacket(Protocol.CombatRole, [isDamageAuthority ? (byte)1 : (byte)0]));

    // -------------------------------------------------------------------------
    // Dice layer (WO-5)
    // -------------------------------------------------------------------------

    /// <summary>Thread-safe: enqueue a full DiceState snapshot (0x17). See Protocol for the layout.</summary>
    public void EnqueueDiceState(ushort sessionId, byte currentPlayerRole, int scoreInitiator, int scoreAcceptor,
        int turnTotal, int targetScore, DicePhase phase, byte[] freeFaces, byte[] keptFaces, byte[] bustedFaces)
    {
        var payload = new byte[2 + 1 + 4 + 4 + 4 + 4 + 1 + 1 + freeFaces.Length + 1 + keptFaces.Length + 1 + bustedFaces.Length];
        int o = 0;
        BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(o), sessionId); o += 2;
        payload[o++] = currentPlayerRole;
        BinaryPrimitives.WriteInt32LittleEndian(payload.AsSpan(o), scoreInitiator); o += 4;
        BinaryPrimitives.WriteInt32LittleEndian(payload.AsSpan(o), scoreAcceptor); o += 4;
        BinaryPrimitives.WriteInt32LittleEndian(payload.AsSpan(o), turnTotal); o += 4;
        BinaryPrimitives.WriteInt32LittleEndian(payload.AsSpan(o), targetScore); o += 4;
        payload[o++] = (byte)phase;
        payload[o++] = (byte)freeFaces.Length;
        freeFaces.CopyTo(payload, o); o += freeFaces.Length;
        payload[o++] = (byte)keptFaces.Length;
        keptFaces.CopyTo(payload, o); o += keptFaces.Length;
        // Trailing, appended after WO-5 shipped: empty except on the one
        // snapshot immediately after a bust, so old parsers that stop after
        // keptFaces (Test-Dice.ps1, Bot-DiceOpponent.ps1) are unaffected --
        // the wire framing is length-prefixed, so ignoring a trailer is safe.
        payload[o++] = (byte)bustedFaces.Length;
        bustedFaces.CopyTo(payload, o); o += bustedFaces.Length;
        EnqueueRaw(BuildPacket(Protocol.DiceState, payload));
    }

    /// <summary>Thread-safe: enqueue a DiceError (0x18) -- sent to the rejected sender only.</summary>
    public void EnqueueDiceError(ushort sessionId, DiceRejectReason reason)
    {
        var payload = new byte[3];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        payload[2] = (byte)reason;
        EnqueueRaw(BuildPacket(Protocol.DiceError, payload));
    }

    /// <summary>Thread-safe: enqueue a DiceEnd (0x19). wagerAmount is echoed from the session's agreed stake (WO-33), 0 for none.</summary>
    public void EnqueueDiceEnd(ushort sessionId, DiceOutcome outcome, int scoreInitiator, int scoreAcceptor, int wagerAmount = 0)
    {
        var payload = new byte[15];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        payload[2] = (byte)outcome;
        BinaryPrimitives.WriteInt32LittleEndian(payload.AsSpan(3), scoreInitiator);
        BinaryPrimitives.WriteInt32LittleEndian(payload.AsSpan(7), scoreAcceptor);
        BinaryPrimitives.WriteInt32LittleEndian(payload.AsSpan(11), wagerAmount);
        EnqueueRaw(BuildPacket(Protocol.DiceEnd, payload));
    }

    // -------------------------------------------------------------------------
    // Interaction layer (WO-2)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Dispatches an interaction packet to the session manager.
    ///
    /// Length is validated here rather than trusted: a short payload would
    /// otherwise index past the end of the array, and a client is free to send
    /// anything it likes.
    /// </summary>
    private void HandleSessionPacket(int type, byte[] body)
    {
        switch (type)
        {
            case Protocol.Invite when body.Length >= 2:
                _sessions.Invite(this, body[0], (InteractionKind)body[1], _clientHandler, ReadOpenConfig(body));
                break;

            case Protocol.InviteResponse when body.Length >= 3:
                _sessions.Respond(this, ReadUInt16(body, 0), body[2] != 0);
                break;

            case Protocol.SessionEventUp when body.Length >= 2:
                _sessions.RelayEvent(this, ReadUInt16(body, 0), body[2..]);
                break;

            case Protocol.SessionLeave when body.Length >= 3:
                _sessions.Leave(this, ReadUInt16(body, 0), (SessionEndReason)body[2]);
                break;

            case Protocol.DiceIntent when body.Length >= 3 && Enum.IsDefined((DiceIntentType)body[2]):
                _sessions.HandleDiceIntent(this, ReadUInt16(body, 0), (DiceIntentType)body[2], body[3..]);
                break;

            default:
                _logger.Warning("[!] '{Name}' sent malformed interaction packet 0x{Type:X2} ({Len} bytes)",
                    Name, type, body.Length);
                break;
        }
    }

    /// <summary>
    /// Thread-safe: enqueue an InviteReceived (0x0B). config is the same
    /// opaque bytes the inviter sent on Invite (WO-33) -- forwarded so the
    /// invitee can see kind-specific open-time settings (e.g. dice's wager)
    /// before answering, not just after accepting.
    /// </summary>
    public void EnqueueInviteReceived(ushort sessionId, byte fromGhostId, InteractionKind kind, byte[]? config = null)
    {
        config ??= [];
        var payload = new byte[5 + config.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        payload[2] = fromGhostId;
        payload[3] = (byte)kind;
        payload[4] = (byte)config.Length;
        config.CopyTo(payload, 5);
        EnqueueRaw(BuildPacket(Protocol.InviteReceived, payload));
    }

    /// <summary>Thread-safe: enqueue a SessionStart (0x0D).</summary>
    public void EnqueueSessionStart(ushort sessionId, byte peerGhostId, InteractionKind kind, SessionRole role)
    {
        var payload = new byte[5];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        payload[2] = peerGhostId;
        payload[3] = (byte)kind;
        payload[4] = (byte)role;
        EnqueueRaw(BuildPacket(Protocol.SessionStart, payload));
    }

    /// <summary>Thread-safe: enqueue a SessionEvent (0x0F) from the peer.</summary>
    public void EnqueueSessionEvent(ushort sessionId, byte fromGhostId, byte[] eventPayload)
    {
        var payload = new byte[3 + eventPayload.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        payload[2] = fromGhostId;
        eventPayload.CopyTo(payload, 3);
        EnqueueRaw(BuildPacket(Protocol.SessionEventDown, payload));
    }

    /// <summary>Thread-safe: enqueue a SessionEnd (0x11).</summary>
    public void EnqueueSessionEnd(ushort sessionId, SessionEndReason reason)
    {
        var payload = new byte[3];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        payload[2] = (byte)reason;
        EnqueueRaw(BuildPacket(Protocol.SessionEnd, payload));
    }

    private static ushort ReadUInt16(byte[] buf, int offset) =>
        BinaryPrimitives.ReadUInt16LittleEndian(buf.AsSpan(offset));

    /// <summary>
    /// Extracts an Invite's optional [configLen:1][config:configLen] tail.
    /// Absent (a bare 2-byte Invite, the pre-WO-5 shape) or truncated both
    /// yield an empty config rather than throwing -- a short/garbled config
    /// is the interaction kind's problem to reject, not a reason to drop the
    /// whole Invite.
    /// </summary>
    private static byte[] ReadOpenConfig(byte[] body)
    {
        if (body.Length < 3) return [];
        int configLen = body[2];
        if (body.Length < 3 + configLen) return [];
        return body[3..(3 + configLen)];
    }

    /// <summary>Thread-safe: enqueue a Name packet (0x03) to be sent to this client.</summary>
    public void EnqueueName(byte ghostId, string name)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        var payload = new byte[1 + nameBytes.Length];
        payload[0] = ghostId;
        nameBytes.CopyTo(payload, 1);
        EnqueueRaw(BuildPacket(Protocol.Name, payload));
    }

    /// <summary>Thread-safe: enqueue a ReleaseVersion packet (0x1E, WO-19) to be sent to this client.</summary>
    public void EnqueueReleaseVersion(byte ghostId, string releaseVersion)
    {
        var verBytes = Encoding.UTF8.GetBytes(releaseVersion);
        var payload = new byte[1 + verBytes.Length];
        payload[0] = ghostId;
        verBytes.CopyTo(payload, 1);
        EnqueueRaw(BuildPacket(Protocol.ReleaseVersion, payload));
    }

    private void EnqueueRaw(byte[] packet) =>
        _writeQueue.Writer.TryWrite(packet);

    private async Task WriteLoopAsync()
    {
        await foreach (var packet in _writeQueue.Reader.ReadAllAsync())
        {
            try { await _stream.WriteAsync(packet); }
            catch (Exception ex)
            {
                // Normal on a disconnect -- the peer's read side of the same
                // socket is what RunAsync's own catch already treats as
                // unremarkable, so this is Debug, not a warning. It still logs
                // the exception rather than swallowing it silently: an
                // unexpected write failure (not just "the peer is gone") used
                // to be indistinguishable from a normal disconnect from here.
                _logger.Debug(ex, "[!] Write loop for {Name} stopped", Name ?? $"id={Id}");
                break;
            }
        }
    }

    // ---- Helpers ----

    private static byte[] BuildPacket(byte type, byte[] payload)
    {
        var packet = new byte[3 + payload.Length];
        packet[0] = type;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payload.Length);
        payload.CopyTo(packet, 3);
        return packet;
    }

    private static float ReadFloat(byte[] buf, int offset) =>
        BitConverter.Int32BitsToSingle(BinaryPrimitives.ReadInt32LittleEndian(buf.AsSpan(offset)));

    private static void WriteFloat(byte[] buf, int offset, float value) =>
        BinaryPrimitives.WriteInt32LittleEndian(buf.AsSpan(offset), BitConverter.SingleToInt32Bits(value));

    private Task ReadExactAsync(byte[] buffer) => ReadExactAsync(buffer, buffer.Length);

    private async Task ReadExactAsync(byte[] buffer, int count)
    {
        int offset = 0;
        while (offset < count)
        {
            int n = await _stream.ReadAsync(buffer, offset, count - offset);
            if (n == 0) throw new EndOfStreamException();
            offset += n;
        }
    }
}
