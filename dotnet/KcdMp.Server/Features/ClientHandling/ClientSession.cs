using System.Buffers.Binary;
using System.Net.Sockets;
using System.Text;
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
    private static long _idCounter;

    private readonly ILogger _logger;
    private readonly TcpClient _tcp;
    private readonly NetworkStream _stream;
    private readonly TcpBroadcastService _broadcastService;
    private readonly SessionManager _sessions;
    private readonly ClientHandler _clientHandler;
    private const int MaxQueuedPackets = 512;
    private readonly object _writeQueueLock = new();
    private readonly Queue<QueuedWrite> _writeQueue = new();
    private readonly Dictionary<uint, byte[]> _pendingGhostPackets = new();
    private readonly SemaphoreSlim _writeSignal = new(0);
    private bool _writeQueueStopped;

    private readonly record struct QueuedWrite(byte[]? Packet, uint? GhostId);

    public uint Id { get; } = checked((uint)Interlocked.Increment(ref _idCounter));
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
            string name = Encoding.UTF8.GetString(handshakePayload, 2, nameLen);

            // WO-19: an optional trailing release-version field, the same
            // idiom as Invite's [configLen][config] -- whatever is left after
            // the name is the sender's release version, exactly zero bytes
            // for an old build that never sent one.
            int releaseVersionOffset = 2 + nameLen;
            if (handshakeLen > releaseVersionOffset)
                ReleaseVersion = Encoding.UTF8.GetString(handshakePayload, releaseVersionOffset, handshakeLen - releaseVersionOffset);

            if (!_clientHandler.TryMarkReady(this))
            {
                _logger.Warning("[!] Rejecting '{Name}' from {ClientRemoteEndPoint}: server is full.",
                    name, _tcp.Client.RemoteEndPoint);
                return;
            }

            Name = name;

            _logger.Information("[+] '{Name}' connected (id={Id}, protocol v{Version}, release {Release}) from {ClientRemoteEndPoint}.",
                Name, Id, clientVersion, ReleaseVersion ?? "(none)", _tcp.Client.RemoteEndPoint);

            // Send Ack with assigned ID
            EnqueueRaw(BuildPacket(Protocol.Ack, EncodeGhostId(Id)));

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

                // --- NPC sync layer (WO-32; per-entity authority WO-39 Phase 2) ---
                // [nameLen:1][name][x:4f][y:4f][z:4f][rotZ:4f][health:4f][flags:1].
                // Validated against the declared nameLen like Appearance's
                // itemCount. Routing is per entity now (ClientHandler.RouteNpcState):
                // the global authority's stream is the default, but a
                // non-authority sending state for an entity claims that entity
                // -- first claim wins, refreshed per packet, expired on
                // silence -- so a player dragging a body owns that body's
                // stream while dragging it, and the authority's re-sample of
                // the same body is dropped here (which is also what closes
                // the echo loop).
                if (type == Protocol.NpcStateUp
                    && payloadLen >= 1 + 1 + Protocol.NpcStateFixedTail
                    && payloadLen <= 1 + Protocol.MaxNpcNameLen + Protocol.NpcStateFixedTail)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    int npcNameLen = body[0];
                    if (npcNameLen != payloadLen - 1 - Protocol.NpcStateFixedTail)
                        continue;   // nameLen disagrees with the framing: malformed, drop
                    string npcName = System.Text.Encoding.UTF8.GetString(body, 1, npcNameLen);
                    // WO-60: the flags byte (last byte of the fixed tail) may
                    // carry the ENGAGED bit -- the sender's player is actively
                    // fighting this NPC -- which arms the claim's anti-flap
                    // hold in the routing table.
                    bool engaged = (body[payloadLen - 1] & Protocol.NpcStateFlagEngaged) != 0;

                    // WO-66 gates. Finite checks first, any sender: a NaN/Inf
                    // never legitimately leaves the game, and a NaN position
                    // would sail through the speed compare (NaN > cap is
                    // false). Our rotation is a scalar yaw, not a quaternion,
                    // so "non-normalizable" degrades to non-finite -- any
                    // finite angle is broadcast as-is (receivers wrap).
                    // Rejection drops the packet and counts it; it never
                    // releases a claim, disconnects a peer, or mutates state.
                    float npcX    = BitConverter.ToSingle(body, 1 + npcNameLen);
                    float npcY    = BitConverter.ToSingle(body, 1 + npcNameLen + 4);
                    float npcZ    = BitConverter.ToSingle(body, 1 + npcNameLen + 8);
                    float npcRotZ = BitConverter.ToSingle(body, 1 + npcNameLen + 12);
                    if (!float.IsFinite(npcX) || !float.IsFinite(npcY) || !float.IsFinite(npcZ))
                    {
                        _clientHandler.CountNpcRejectSpeed();
                        _logger.Information("[WO66-REJECT] speed '{Name}' (id={Id}) npc '{Npc}': non-finite position.",
                            Name, Id, npcName);
                        continue;
                    }
                    if (!float.IsFinite(npcRotZ))
                    {
                        _clientHandler.CountNpcRejectRotation();
                        _logger.Information("[WO66-REJECT] rotation '{Name}' (id={Id}) npc '{Npc}': non-finite rotZ.",
                            Name, Id, npcName);
                        continue;
                    }

                    switch (_clientHandler.RouteNpcState(this, npcName, engaged, npcX, npcY, npcZ))
                    {
                        case ClientHandler.NpcRoute.Broadcast:
                            _broadcastService.BroadcastNpcState(this, body);
                            break;
                        case ClientHandler.NpcRoute.MutedEcho:
                            // WO-39 echo-loop mute, normal operation.
                            _logger.Debug("[npcclaim] authority re-sample of '{Npc}' muted (claimed).", npcName);
                            break;
                        case ClientHandler.NpcRoute.RejectSpeed:
                            _logger.Information("[WO66-REJECT] speed '{Name}' (id={Id}) npc '{Npc}': implausible movement.",
                                Name, Id, npcName);
                            break;
                        case ClientHandler.NpcRoute.RejectReservedName:
                            _logger.Information("[WO66-REJECT] reserved-name '{Name}' (id={Id}) npc '{Npc}': claim refused for mod-spawned entity name.",
                                Name, Id, npcName);
                            break;
                        case ClientHandler.NpcRoute.RejectStaleOwner:
                            _logger.Information("[WO66-REJECT] stale-owner '{Name}' (id={Id}) npc '{Npc}': claimed by another client.",
                                Name, Id, npcName);
                            break;
                    }
                    continue;
                }

                // --- Time-skip sync layer (WO-38 Phase 1) ---
                // [phase:1][kind:1][worldTime:4 LE uint32]. Deliberately not
                // gated on damage authority: any player's sleep counts. The
                // handler decides first-come ownership; see Protocol's 0x28
                // notes for the routing rules.
                if (type == Protocol.TimeSkipUp && payloadLen == Protocol.TimeSkipUpPayloadLen)
                {
                    var body = new byte[Protocol.TimeSkipUpPayloadLen];
                    await ReadExactAsync(body);
                    byte phase = body[0];
                    var routing = phase switch
                    {
                        Protocol.TimeSkipPhaseStart => _clientHandler.BeginTimeSkip(this),
                        Protocol.TimeSkipPhaseDone  => _clientHandler.CompleteTimeSkip(this),
                        // WO-59: a plain clock report -- no active-skip
                        // bookkeeping at all; rebroadcast quietly so behind
                        // peers converge forward without a toast.
                        Protocol.TimeSkipPhaseSync  => ClientHandler.TimeSkipRouting.BroadcastDoneQuiet,
                        _ => ClientHandler.TimeSkipRouting.None,   // done-quiet is S→C only; a client sending it is malformed
                    };
                    switch (routing)
                    {
                        case ClientHandler.TimeSkipRouting.BroadcastStart:
                            _logger.Information("[timeskip] '{Name}' (id={Id}) began the session's active skip (kind={Kind}).", Name, Id, body[1]);
                            _broadcastService.BroadcastTimeSkip(this, body);
                            break;
                        case ClientHandler.TimeSkipRouting.BroadcastDone:
                            _logger.Information("[timeskip] '{Name}' (id={Id}) skip done -> worldTime={Time} (announced).",
                                Name, Id, BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(2)));
                            _broadcastService.BroadcastTimeSkip(this, body);
                            break;
                        case ClientHandler.TimeSkipRouting.BroadcastDoneQuiet:
                            _logger.Information("[timeskip] '{Name}' (id={Id}) {What} -> worldTime={Time} (quiet).",
                                Name, Id, phase == Protocol.TimeSkipPhaseSync ? "clock sync" : "joined-skip done",
                                BinaryPrimitives.ReadUInt32LittleEndian(body.AsSpan(2)));
                            body[0] = Protocol.TimeSkipPhaseDoneQuiet;
                            _broadcastService.BroadcastTimeSkip(this, body);
                            break;
                        default:
                            _logger.Information("[timeskip] '{Name}' (id={Id}) phase={Phase} absorbed (joined/duplicate).", Name, Id, phase);
                            break;
                    }
                    continue;
                }

                // --- Horse identity layer (WO-38 Phase 5) ---
                // [nameLen:1][name]. nameLen 0 = dismounted/unknown. Validated
                // against the declared nameLen like Appearance's itemCount; no
                // authority gate -- it is a fact about the sender's own mount.
                if (type == Protocol.HorseInfoUp
                    && payloadLen >= 1
                    && payloadLen <= 1 + Protocol.MaxHorseNameLen)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    if (body[0] == payloadLen - 1)
                        _broadcastService.BroadcastHorseInfo(this, body);
                    continue;
                }

                // --- Combat visibility layer (WO-39 Phase 1) ---
                // [event:1]. Cosmetic on every receiver (draw/sheathe/swing/
                // block visuals only -- damage keeps its own authoritative
                // paths), so like HorseInfo there is no authority gate: it is
                // a fact about the sender, not about the shared world.
                if (type == Protocol.CombatEventUp && payloadLen == Protocol.CombatEventUpPayloadLen)
                {
                    var body = new byte[Protocol.CombatEventUpPayloadLen];
                    await ReadExactAsync(body);
                    _broadcastService.BroadcastCombatEvent(this, body);
                    continue;
                }

                // --- Name-addressed NPC damage (WO-40 Phase 5) ---
                // [nameLen:1][name][stamina:4f][health:4f][flags:1]. Same
                // shape discipline as NpcStateUp; no authority gate -- like
                // 0x12, any client reports damage it observed locally.
                if (type == Protocol.NpcDamageUp
                    && payloadLen >= 1 + 1 + Protocol.NpcDamageFixedTail
                    && payloadLen <= 1 + Protocol.MaxNpcNameLen + Protocol.NpcDamageFixedTail)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    if (body[0] == payloadLen - 1 - Protocol.NpcDamageFixedTail)
                        _broadcastService.BroadcastNpcDamage(this, body);
                    continue;
                }

                // --- Weather sync layer (WO-40 Phase 3) ---
                // [nameLen:1][profileName][blendSec:2]. Cosmetic; only the
                // damage-authority agent sends by convention, and a spoofed
                // profile can only name a real table row on receivers -- so
                // like HorseInfo there is no relay-side gate.
                if (type == Protocol.WeatherUp
                    && payloadLen >= 1 + 2
                    && payloadLen <= 1 + Protocol.MaxWeatherNameLen + 2)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    if (body[0] == payloadLen - 3)
                        _broadcastService.BroadcastWeather(this, body);
                    continue;
                }

                // --- Dropped-item sync layer (WO-48) ---
                // [dropId:4][itemClass:16][amount:2][health:4f][x:4f][y:4f][z:4f].
                // Fixed-size, exact-length discipline like the combat layer: a
                // short packet forwarded on becomes a call into the receiving
                // client's game (it spawns an entity there).
                if (type == Protocol.ItemDropUp && payloadLen == Protocol.ItemDropUpPayloadLen)
                {
                    var body = new byte[Protocol.ItemDropUpPayloadLen];
                    await ReadExactAsync(body);
                    _broadcastService.BroadcastItemDrop(this, body);
                    continue;
                }

                // [dropId:4]. Echoed to ALL clients including the claimant, in
                // arrival order -- the relay's TCP serialization is the whole
                // race arbiter (see Protocol's 0x34 notes: an others-only
                // broadcast would make two simultaneous claimants both roll
                // back and the item would evaporate). No claim table: clients
                // resolve on the first echo they see and ignore repeats.
                if (type == Protocol.ItemClaimUp && payloadLen == Protocol.ItemClaimUpPayloadLen)
                {
                    var body = new byte[Protocol.ItemClaimUpPayloadLen];
                    await ReadExactAsync(body);
                    _logger.Information("[itemsync] '{Name}' (id={Id}) claimed drop {DropId}.",
                        Name, Id, BinaryPrimitives.ReadUInt32LittleEndian(body));
                    _broadcastService.BroadcastItemClaim(this, body);
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
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException or ObjectDisposedException)
        {
            // Normal disconnect
        }
        finally
        {
            StopWriteQueue();
            await writeTask;
            _tcp.Dispose();
        }
    }

    /// <summary>Thread-safe: enqueue a Ghost packet to be sent to this client.</summary>
    public void EnqueueGhost(uint ghostId, float x, float y, float z, float rotZ, byte flags)
    {
        var payload = new byte[Protocol.GhostPayloadLen];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, ghostId);
        WriteFloat(payload, Protocol.GhostIdLen, x);
        WriteFloat(payload, Protocol.GhostIdLen + 4, y);
        WriteFloat(payload, Protocol.GhostIdLen + 8, z);
        WriteFloat(payload, Protocol.GhostIdLen + 12, rotZ);
        payload[Protocol.GhostIdLen + 16] = flags;
        EnqueueGhostPacket(ghostId, BuildPacket(Protocol.Ghost, payload));
    }

    /// <summary>Thread-safe: enqueue a Disconnect packet (0x06) to be sent to this client.</summary>
    public void EnqueueDisconnect(uint ghostId) =>
        EnqueueRaw(BuildPacket(Protocol.Disconnect, EncodeGhostId(ghostId)));

    /// <summary>Thread-safe: enqueue a Voice packet (0x08) to be sent to this client.</summary>
    public void EnqueueVoice(uint sourceId, byte[] pcm)
    {
        var payload = PrefixGhostId(sourceId, pcm);
        EnqueueRaw(BuildPacket(Protocol.VoiceDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a Damage (0x13) packet to be sent to this client.
    /// The body is the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueDamage(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.DamageDown, payload));
    }

    /// <summary>Thread-safe: enqueue a Death (0x15) packet to be sent to this client.</summary>
    public void EnqueueDeath(uint sourceId, byte[] soulGuid)
    {
        var payload = PrefixGhostId(sourceId, soulGuid);
        EnqueueRaw(BuildPacket(Protocol.DeathDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an Appearance (0x1B) packet to be sent to this
    /// client. The body is the upstream [itemCount][itemClass...] payload
    /// verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueAppearance(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.AppearanceDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a PauseDown (0x1D) packet to be sent to this
    /// client. The body is the upstream [state:1] payload verbatim, prefixed
    /// with who sent it.
    /// </summary>
    public void EnqueuePause(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.PauseDown, payload));
    }

    // -------------------------------------------------------------------------
    // Shared player combat layer (WO-28)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Thread-safe: enqueue a PlayerStateDown (0x20). The body is the upstream
    /// [health][stamina][flags] payload verbatim, prefixed with whose health it is.
    /// </summary>
    public void EnqueuePlayerState(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.PlayerStateDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a TimeSkipDown (0x29, WO-38). The body is the
    /// upstream payload (with the phase byte possibly rewritten to done-quiet
    /// by the routing rules), prefixed with who sent it.
    /// </summary>
    public void EnqueueTimeSkip(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.TimeSkipDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a CombatEventDown (0x2D, WO-39 Phase 1). The body
    /// is the upstream [event:1] payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueCombatEvent(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.CombatEventDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an NpcDamageDown (0x31, WO-40 Phase 5). The body
    /// is the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueNpcDamage(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.NpcDamageDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an ItemDropDown (0x33, WO-48). The body is the
    /// upstream payload verbatim, prefixed with who dropped it.
    /// </summary>
    public void EnqueueItemDrop(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.ItemDropDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an ItemClaimDown (0x35, WO-48). The body is the
    /// upstream payload verbatim, prefixed with who claimed it. Unlike every
    /// other Down packet this one also goes back to its own sender -- the
    /// echo is the claim's confirmation (see Protocol's 0x34 notes).
    /// </summary>
    public void EnqueueItemClaim(uint claimerId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(claimerId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.ItemClaimDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a WeatherDown (0x2F, WO-40 Phase 3). The body is
    /// the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueWeather(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.WeatherDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a HorseInfoDown (0x2B, WO-38 Phase 5). The body is
    /// the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueHorseInfo(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.HorseInfoDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an NpcStateDown (0x27, WO-32). The body is the
    /// upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueNpcState(uint sourceId, byte[] upstreamBody)
    {
        var payload = PrefixGhostId(sourceId, upstreamBody);
        EnqueueRaw(BuildPacket(Protocol.NpcStateDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a PlayerHitDown (0x22). The upstream body's leading
    /// targetGhostId is deliberately dropped -- this only ever reaches the
    /// player it names, who does not need telling it is about themselves.
    /// </summary>
    public void EnqueuePlayerHit(byte[] upstreamBody)
    {
        var payload = new byte[Protocol.PlayerHitDownPayloadLen];
        Buffer.BlockCopy(upstreamBody, Protocol.GhostIdLen, payload, 0, Protocol.PlayerHitDownPayloadLen);
        EnqueueRaw(BuildPacket(Protocol.PlayerHitDown, payload));
    }

    /// <summary>Thread-safe: enqueue a PlayerDeathDown (0x24). Idempotent at the receiver.</summary>
    public void EnqueuePlayerDeath(uint sourceId) =>
        EnqueueRaw(BuildPacket(Protocol.PlayerDeathDown, EncodeGhostId(sourceId)));

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
            case Protocol.Invite when body.Length >= Protocol.GhostIdLen + 1:
                _sessions.Invite(this, ReadUInt32(body, 0), (InteractionKind)body[Protocol.GhostIdLen], _clientHandler, ReadOpenConfig(body));
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
    public void EnqueueInviteReceived(ushort sessionId, uint fromGhostId, InteractionKind kind, byte[]? config = null)
    {
        config ??= [];
        var payload = new byte[2 + Protocol.GhostIdLen + 2 + config.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(2), fromGhostId);
        payload[2 + Protocol.GhostIdLen] = (byte)kind;
        payload[3 + Protocol.GhostIdLen] = (byte)config.Length;
        config.CopyTo(payload, 4 + Protocol.GhostIdLen);
        EnqueueRaw(BuildPacket(Protocol.InviteReceived, payload));
    }

    /// <summary>Thread-safe: enqueue a SessionStart (0x0D).</summary>
    public void EnqueueSessionStart(ushort sessionId, uint peerGhostId, InteractionKind kind, SessionRole role)
    {
        var payload = new byte[2 + Protocol.GhostIdLen + 2];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(2), peerGhostId);
        payload[2 + Protocol.GhostIdLen] = (byte)kind;
        payload[3 + Protocol.GhostIdLen] = (byte)role;
        EnqueueRaw(BuildPacket(Protocol.SessionStart, payload));
    }

    /// <summary>Thread-safe: enqueue a SessionEvent (0x0F) from the peer.</summary>
    public void EnqueueSessionEvent(ushort sessionId, uint fromGhostId, byte[] eventPayload)
    {
        var payload = new byte[2 + Protocol.GhostIdLen + eventPayload.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(payload, sessionId);
        BinaryPrimitives.WriteUInt32LittleEndian(payload.AsSpan(2), fromGhostId);
        eventPayload.CopyTo(payload, 2 + Protocol.GhostIdLen);
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

    private static uint ReadUInt32(byte[] buf, int offset) =>
        BinaryPrimitives.ReadUInt32LittleEndian(buf.AsSpan(offset));

    /// <summary>
    /// Extracts an Invite's optional [configLen:1][config:configLen] tail.
    /// Absent (an Invite containing only id + kind) or truncated both
    /// yield an empty config rather than throwing -- a short/garbled config
    /// is the interaction kind's problem to reject, not a reason to drop the
    /// whole Invite.
    /// </summary>
    private static byte[] ReadOpenConfig(byte[] body)
    {
        int configLenOffset = Protocol.GhostIdLen + 1;
        if (body.Length <= configLenOffset) return [];
        int configLen = body[configLenOffset];
        int configOffset = configLenOffset + 1;
        if (body.Length < configOffset + configLen) return [];
        return body[configOffset..(configOffset + configLen)];
    }

    /// <summary>Thread-safe: enqueue a Name packet (0x03) to be sent to this client.</summary>
    public void EnqueueName(uint ghostId, string name)
    {
        var nameBytes = Encoding.UTF8.GetBytes(name);
        var payload = PrefixGhostId(ghostId, nameBytes);
        EnqueueRaw(BuildPacket(Protocol.Name, payload));
    }

    /// <summary>Thread-safe: enqueue a ReleaseVersion packet (0x1E, WO-19) to be sent to this client.</summary>
    public void EnqueueReleaseVersion(uint ghostId, string releaseVersion)
    {
        var verBytes = Encoding.UTF8.GetBytes(releaseVersion);
        var payload = PrefixGhostId(ghostId, verBytes);
        EnqueueRaw(BuildPacket(Protocol.ReleaseVersion, payload));
    }

    private void EnqueueRaw(byte[] packet)
    {
        bool overflow;
        lock (_writeQueueLock)
        {
            if (_writeQueueStopped) return;
            overflow = _writeQueue.Count >= MaxQueuedPackets;
            if (!overflow) _writeQueue.Enqueue(new(packet, null));
        }

        if (overflow) AbortWriteQueue("outbound queue limit reached");
        else _writeSignal.Release();
    }

    private void EnqueueGhostPacket(uint ghostId, byte[] packet)
    {
        bool overflow;
        bool queued = false;
        lock (_writeQueueLock)
        {
            if (_writeQueueStopped) return;

            if (_pendingGhostPackets.ContainsKey(ghostId))
            {
                // A marker for this source is already queued. Replace only its
                // payload so a slow client receives the newest position.
                _pendingGhostPackets[ghostId] = packet;
                return;
            }

            overflow = _writeQueue.Count >= MaxQueuedPackets;
            if (!overflow)
            {
                _pendingGhostPackets[ghostId] = packet;
                _writeQueue.Enqueue(new(null, ghostId));
                queued = true;
            }
        }

        if (overflow) AbortWriteQueue("outbound queue limit reached");
        else if (queued) _writeSignal.Release();
    }

    private void StopWriteQueue()
    {
        lock (_writeQueueLock) _writeQueueStopped = true;
        _writeSignal.Release();
    }

    private void AbortWriteQueue(string? reason)
    {
        lock (_writeQueueLock)
        {
            if (_writeQueueStopped) return;
            _writeQueueStopped = true;
            _writeQueue.Clear();
            _pendingGhostPackets.Clear();
        }

        if (reason is not null)
            _logger.Warning("[!] Disconnecting {Name}: {Reason}.", Name ?? $"id={Id}", reason);
        _writeSignal.Release();
        _tcp.Dispose();
    }

    private async Task WriteLoopAsync()
    {
        while (true)
        {
            await _writeSignal.WaitAsync();

            byte[]? packet = null;
            lock (_writeQueueLock)
            {
                if (_writeQueue.Count > 0)
                {
                    var queued = _writeQueue.Dequeue();
                    if (queued.GhostId is uint ghostId)
                    {
                        _pendingGhostPackets.Remove(ghostId, out packet);
                    }
                    else
                    {
                        packet = queued.Packet;
                    }
                }
                else if (_writeQueueStopped)
                {
                    return;
                }
            }

            if (packet is null) continue;

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
                AbortWriteQueue(null);
                break;
            }
        }
    }

    // ---- Helpers ----

    private static byte[] EncodeGhostId(uint ghostId)
    {
        var payload = new byte[Protocol.GhostIdLen];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, ghostId);
        return payload;
    }

    private static byte[] PrefixGhostId(uint ghostId, byte[] body)
    {
        var payload = new byte[Protocol.GhostIdLen + body.Length];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, ghostId);
        body.CopyTo(payload, Protocol.GhostIdLen);
        return payload;
    }

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
