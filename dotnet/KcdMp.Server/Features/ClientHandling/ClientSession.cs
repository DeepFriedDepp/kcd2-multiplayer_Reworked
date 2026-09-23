using System.Buffers.Binary;
using System.Net;
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
    private readonly ILogger _logger;
    private readonly TcpClient _tcp;
    private readonly NetworkStream _stream;
    private readonly TcpBroadcastService _broadcastService;
    private readonly SessionManager _sessions;
    private readonly ClientHandler _clientHandler;
    // WO-110 Phase 4.4 (docs/WO-109-audit.md s4.3/s4.7): the per-client
    // outbound queue is sized in BYTES, and a slow client degrades before it
    // is dropped. Until 0.26.4 the queue was 512 packets and overflow meant
    // an immediate disconnect -- a joiner whose Lua ingress fell behind a
    // dense town's NPC stream was cut off rather than thinned. Now:
    //   * under PressureBytes queued, a new NpcStateDown for a (source, name)
    //     that already has one waiting REPLACES the waiting one (same
    //     coalescing the Ghost packets always had, per name): stale NPC
    //     samples are dropped first, counted as 0x27:pressure-coalesced;
    //   * only past MaxQueuedBytes is the client disconnected, as before.
    // The Lua receiver renders on sender time (R6), so a thinned stream keeps
    // its timeline; only its sample density drops.
    private const int MaxQueuedBytes = 512 * 1024;
    private const int PressureBytes  = 64 * 1024;
    private readonly object _writeQueueLock = new();
    private readonly Queue<QueuedWrite> _writeQueue = new();
    private readonly Dictionary<byte, byte[]> _pendingGhostPackets = new();
    private readonly Dictionary<string, byte[]> _pendingNpcPackets = new();   // WO-110 4.4: "<src>|<name>" -> newest packet, only under pressure
    private readonly SemaphoreSlim _writeSignal = new(0);
    private bool _writeQueueStopped;
    private int _queuedBytes;
    private long _npcCoalesced;

    private readonly record struct QueuedWrite(byte[]? Packet, byte? GhostId, string? NpcKey = null);

    /// <summary>
    /// WO-76: assigned by <see cref="ClientHandler.TryMarkReady"/> from its
    /// byte-id free-list pool, not at construction. Meaningless (default 0)
    /// before that -- check <see cref="IsReady"/>, not this, to tell a
    /// pre-handshake socket from a real peer with id 0.
    /// </summary>
    public byte Id { get; internal set; }
    public string? Name { get; private set; }
    public bool IsReady => Name is not null;

    /// <summary>WO-110 R4: connected over a loopback address, i.e. the relay
    /// host's own agent. Read once at construction; see ClientHandler.PickAuthority.</summary>
    public bool IsLoopback { get; }

    /// <summary>WO-19. Null when the client's Handshake carried no trailing
    /// release-version field (an old build, or a synthetic test peer).</summary>
    public string? ReleaseVersion { get; private set; }

    // WO-102.5 Phase 4: departure handoff needs the ungraceful case caught by
    // a timeout, not only a clean disconnect (FIN) or an immediate reset
    // (RST) -- a client whose machine or network vanishes silently (cable
    // pulled, hard crash) leaves this read parked forever with neither. The
    // real client sends a position heartbeat at least every 2 s even at a
    // menu or a loading screen (GameBridge.cs's PositionHeartbeatInterval,
    // which keeps running independent of the game's own Script.SetTimer
    // chains) -- Tcp:IdleTimeoutMs (default 30 s, TcpSocketService) is 15x
    // that margin before calling it dead.
    private readonly TimeSpan _idleTimeout;

    public ClientSession(ILogger logger, TcpClient tcp, TcpBroadcastService broadcastService,
        SessionManager sessions, ClientHandler clientHandler, TimeSpan idleTimeout)
    {
        _logger = logger;
        _tcp = tcp;
        _stream = tcp.GetStream();
        _idleTimeout = idleTimeout;
        _broadcastService = broadcastService;
        _sessions = sessions;
        _clientHandler = clientHandler;
        IsLoopback = tcp.Client.RemoteEndPoint is IPEndPoint ep && IPAddress.IsLoopback(ep.Address);
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
                _clientHandler.CountDrop(Protocol.Handshake, "protocol-mismatch");   // WO-110 R9
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
            string rawName = Encoding.UTF8.GetString(handshakePayload, 2, nameLen);
            // WO-110 R15: the peer name is logged raw into both machines'
            // kcd.log and interpolated into Lua by the agents; a name carrying
            // a newline or a "[KCD2-MP-EVT]" tag could break a Lua batch or
            // forge a log-tail event (docs/WO-109-audit.md R15). Sanitised
            // once, here, for every consumer downstream.
            string name = SanitizeName(rawName);
            if (!string.Equals(name, rawName, StringComparison.Ordinal))
                _logger.Warning("[!] Peer name sanitised: {Raw} -> {Clean}", rawName.Replace('\n', ' ').Replace('\r', ' '), name);

            // WO-19: an optional trailing release-version field, the same
            // idiom as Invite's [configLen][config] -- whatever is left after
            // the name is the sender's release version, exactly zero bytes
            // for an old build that never sent one.
            int releaseVersionOffset = 2 + nameLen;
            if (handshakeLen > releaseVersionOffset)
                ReleaseVersion = Encoding.UTF8.GetString(handshakePayload, releaseVersionOffset, handshakeLen - releaseVersionOffset);

            // WO-110 R9: a declared release version must equal this relay's.
            // Protocol.cs, "Release-version enforcement": 0.26.4 + 0.26.5 must
            // not connect; a peer that declares nothing (pre-WO-19 build or a
            // synthetic test peer) is still accepted and logged as such.
            if (ReleaseVersion is { Length: > 0 } && !string.Equals(ReleaseVersion, RelayReleaseVersion.Current, StringComparison.Ordinal))
            {
                _logger.Warning("[!] Rejecting '{Name}' from {ClientRemoteEndPoint}: release {ClientRelease} does not match this relay's {RelayRelease} (both machines must run the same build).",
                    name, _tcp.Client.RemoteEndPoint, ReleaseVersion, RelayReleaseVersion.Current);
                _clientHandler.CountDrop(Protocol.Handshake, "release-mismatch");
                EnqueueRaw(BuildPacket(Protocol.ReleaseVersionMismatch, Encoding.UTF8.GetBytes(RelayReleaseVersion.Current)));
                return;
            }

            if (!_clientHandler.TryMarkReady(this))
            {
                _logger.Warning("[!] Rejecting '{Name}' from {ClientRemoteEndPoint}: server is full.",
                    name, _tcp.Client.RemoteEndPoint);
                // WO-76: previously just returned, closing the socket with no
                // packet -- the client's generic "expected Ack" failure looked
                // identical to any other refusal, so it retried forever,
                // burning one pooled id per attempt. See Protocol's 0x36 notes.
                EnqueueRaw(BuildPacket(Protocol.ServerFull, [(byte)Math.Min(_clientHandler.MaxPlayers, byte.MaxValue)]));
                return;
            }

            // WO-110 R4: the Ack is queued BEFORE this session becomes visible
            // as ready (Name != null). Broadcasts to "all ready clients" run on
            // other sessions' threads; with the Ack queued after Name was set,
            // a Ghost/Name/CombatRole packet could land in this client's queue
            // ahead of the Ack, and the agent -- which reads exactly one reply
            // and expects 0xFF -- dropped the connection ("Expected Ack, got
            // packet type ..."). The write queue is FIFO, so first-queued is
            // first-sent. Id is already assigned (TryMarkReady above).
            EnqueueRaw(BuildPacket(Protocol.Ack, [Id]));
            Name = name;

            _logger.Information("[+] '{Name}' connected (id={Id}, protocol v{Version}, release {Release}, loopback={Loopback}) from {ClientRemoteEndPoint}.",
                Name, Id, clientVersion, ReleaseVersion ?? "(none)", IsLoopback ? 1 : 0, _tcp.Client.RemoteEndPoint);

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
            // Two exact lengths, not one: 17 (pre-WO-100.5, and every STALE
            // heartbeat) or 22 (WO-100.5 body state behind flag 0x04). WO-101:
            // in 0.23.1 this gate took only 17, so every live sample -- all of
            // which carried a body -- was skipped below with no log line, and
            // only the 17-byte heartbeats crossed. docs/WO-101-findings.md S0.
            var posPayload = new byte[Protocol.PositionPayloadLenV2];
            while (true)
            {
                // WO-102.5 Phase 4: only the wait for the NEXT message is
                // timed -- once a header has arrived the rest of that
                // message is assumed to already be in flight on the same
                // stream. NetworkStream.ReadTimeout does not reliably apply
                // to ReadAsync (verified empirically this session), so the
                // timeout is an explicit CancellationTokenSource instead.
                await ReadExactWithIdleTimeoutAsync(header);
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

                if (type == Protocol.ClockSyncUp && payloadLen == Protocol.ClockSyncUpPayloadLen)
                {
                    // WO-98 Phase 1: NTP-shaped clock-offset sample. Echo the
                    // client's send stamp with our receive and send stamps
                    // appended; the client does the arithmetic (Protocol.cs
                    // header, "Clock-offset sampling"). The send stamp is taken
                    // when the reply is queued, not when the socket writes it,
                    // so a busy outbound queue reads as a few ms of RTT.
                    var t0 = new byte[Protocol.ClockSyncUpPayloadLen];
                    await ReadExactAsync(t0);
                    long t1 = DateTime.UtcNow.Ticks;
                    var body = new byte[Protocol.ClockSyncDownPayloadLen];
                    t0.CopyTo(body, 0);
                    BinaryPrimitives.WriteInt64LittleEndian(body.AsSpan(8), t1);
                    BinaryPrimitives.WriteInt64LittleEndian(body.AsSpan(16), DateTime.UtcNow.Ticks);
                    EnqueueRaw(BuildPacket(Protocol.ClockSyncDown, body));
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
                    {
                        _clientHandler.CountDrop(Protocol.NpcStateUp, "namelen-mismatch");   // WO-110 R9: counted, not silent
                        continue;   // nameLen disagrees with the framing: malformed, drop
                    }
                    string npcName = System.Text.Encoding.UTF8.GetString(body, 1, npcNameLen);
                    // WO-60: the flags byte (last byte of the fixed tail) may
                    // carry the ENGAGED bit -- the sender's player is actively
                    // fighting this NPC -- which arms the claim's anti-flap
                    // hold in the routing table.
                    // WO-110 R6 (v7): flags is no longer the last byte -- seq and senderMs follow it.
                    bool engaged = (body[1 + npcNameLen + Protocol.NpcStateFlagsOffset] & Protocol.NpcStateFlagEngaged) != 0;

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
                            _logger.Information("[WO66-REJECT] reserved-name '{Name}' (id={Id}) npc '{Npc}': refused, never-synced entity name (mod spawn or engine conversation stand-in).",
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
                    else
                        _clientHandler.CountDrop(Protocol.HorseInfoUp, "namelen-mismatch");   // WO-110 R9
                    continue;
                }

                // --- Combat visibility layer (WO-39 Phase 1) ---
                // [event:1]. Cosmetic on every receiver (draw/sheathe/swing/
                // block visuals only -- damage keeps its own authoritative
                // paths), so like HorseInfo there is no authority gate: it is
                // a fact about the sender, not about the shared world.
                if (type == Protocol.CombatEventUp
                    && (payloadLen == Protocol.CombatEventUpPayloadLen || payloadLen == Protocol.CombatEventUpPayloadLenV2))
                {
                    // WO-99 Phase 4: v2 carries [sid:2] after the event byte;
                    // forwarded verbatim either way.
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    _broadcastService.BroadcastCombatEvent(this, body);
                    continue;
                }

                // --- Discrete action channel (WO-100.5 Phase 3) ---
                // [kind:1][seq:2][phase:1][gen:4][len:1][payload:len].
                // Forwarded verbatim, prefixed with the sender -- the relay
                // does not interpret the payload, exactly as it does not
                // interpret a session event. A fact about the sender's own
                // input, so no authority gate.
                //
                // The relay DOES check the declared payload length against the
                // frame, because a body whose len byte lies is the one thing a
                // verbatim forward would otherwise pass straight through to
                // every receiver's decoder.
                if (type == Protocol.ActionUp
                    && payloadLen >= Protocol.ActionUpHeaderLen
                    && payloadLen <= Protocol.ActionUpHeaderLen + Protocol.ActionPayloadMaxLen)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    if (body[Protocol.ActionUpHeaderLen - 1] == payloadLen - Protocol.ActionUpHeaderLen)
                        _broadcastService.BroadcastAction(this, body);
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
                    {
                        // WO-86: an NPC death crossing the relay is rare and
                        // load-bearing -- it is the one event that makes two
                        // worlds agree a body is dead -- so it gets a line
                        // (WO-81 idiom: name the silent decision). Ordinary
                        // hits stay quiet; the body is forwarded verbatim
                        // either way, no relay-side state or gate.
                        if ((body[payloadLen - 1] & Protocol.NpcDamageFlagFatal) != 0)
                        {
                            string fatalNpc = System.Text.Encoding.UTF8.GetString(body, 1, body[0]);
                            float fatalHp = BitConverter.ToSingle(body, 1 + body[0] + 4);
                            _logger.Information("[NPCDEATH] relayed FATAL npc={Npc} from='{Name}' (id={Id}) blowHp={BlowHp:F1}",
                                fatalNpc, Name, Id, fatalHp);
                        }
                        _broadcastService.BroadcastNpcDamage(this, body);
                    }
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

                // --- Story progress layer (WO-90) ---
                // [kind:1][len:1][text]. A fact about the sender's own
                // campaign, like HorseInfo -- nothing to arbitrate, so it is
                // relayed verbatim with no authority gate. Receivers only
                // report it.
                if (type == Protocol.StoryBeatUp
                    && payloadLen >= 2
                    && payloadLen <= 2 + Protocol.MaxStoryBeatTextLen)
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    if (body[1] == payloadLen - 2)
                        _broadcastService.BroadcastStoryBeat(this, body);
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

                // --- Death without Game Over (WO-113) ---
                // Exact lengths: a short body forwarded on becomes a pipe
                // command in the receiving game (a mirror gravestone spawn).
                // Rare and load-bearing, so each is one relay line.
                if ((type == Protocol.PlayerRespawnedUp && payloadLen == Protocol.PlayerRespawnedUpPayloadLen)
                    || (type == Protocol.GraveAddUp && payloadLen == Protocol.GraveAddUpPayloadLen)
                    || (type == Protocol.GraveRemoveUp && payloadLen == Protocol.GraveRemoveUpPayloadLen))
                {
                    var body = new byte[payloadLen];
                    await ReadExactAsync(body);
                    if (type == Protocol.PlayerRespawnedUp)
                    {
                        _logger.Information("[respawn] '{Name}' (id={Id}) respawned at ({X:F1}, {Y:F1}, {Z:F1}) reason={Reason}.",
                            Name, Id, BitConverter.ToSingle(body, 0), BitConverter.ToSingle(body, 4),
                            BitConverter.ToSingle(body, 8), Protocol.RespawnReasonName(body[12]));
                        _broadcastService.BroadcastSenderFact(this, Protocol.PlayerRespawnedDown, body);
                    }
                    else if (type == Protocol.GraveAddUp)
                    {
                        _logger.Information("[grave] '{Name}' (id={Id}) grave 0x{Grave:X16} at ({X:F1}, {Y:F1}, {Z:F1}).",
                            Name, Id, BinaryPrimitives.ReadUInt64LittleEndian(body), BitConverter.ToSingle(body, 8),
                            BitConverter.ToSingle(body, 12), BitConverter.ToSingle(body, 16));
                        _broadcastService.BroadcastSenderFact(this, Protocol.GraveAddDown, body);
                    }
                    else
                    {
                        _logger.Information("[grave] '{Name}' (id={Id}) grave 0x{Grave:X16} removed.",
                            Name, Id, BinaryPrimitives.ReadUInt64LittleEndian(body));
                        _broadcastService.BroadcastSenderFact(this, Protocol.GraveRemoveDown, body);
                    }
                    continue;
                }

                if (type == Protocol.PlayerDeathUp && payloadLen == Protocol.PlayerDeathUpPayloadLen)
                {
                    // Carries nothing: the relay already knows who sent it.
                    _logger.Information("[death] '{Name}' (id={Id}) reported their own death.", Name, Id);
                    _broadcastService.BroadcastPlayerDeath(this);
                    continue;
                }

                if (type != Protocol.Position
                    || (payloadLen != Protocol.PositionPayloadLen && payloadLen != Protocol.PositionPayloadLenV2))
                {
                    // Skip unknown/malformed packet. WO-110 R9: counted by type
                    // -- a known type landing here failed one of the exact-
                    // length gates above (the 0.23.1 shape), an unknown type
                    // is a newer peer; either way MP-RELAY-DROPS says so.
                    _clientHandler.CountDrop((byte)type, type == Protocol.Position ? "wrong-length" : "unknown-or-wrong-length");
                    if (payloadLen > 0)
                    {
                        var skip = new byte[payloadLen];
                        await ReadExactAsync(skip);
                    }
                    continue;
                }

                await ReadExactAsync(posPayload, payloadLen);

                float x    = ReadFloat(posPayload, 0);
                float y    = ReadFloat(posPayload, 4);
                float z    = ReadFloat(posPayload, 8);
                float rotZ = ReadFloat(posPayload, 12);
                byte  flags = posPayload[16];
                // WO-101: everything after the flags byte is the body-state
                // tail -- 5 bytes on a V2 packet, none on a 17-byte one --
                // forwarded verbatim. The relay does not interpret it, exactly
                // as it does not interpret a CombatEvent v2's [sid:2].
                var tail = posPayload.AsSpan(Protocol.PositionPayloadLen, payloadLen - Protocol.PositionPayloadLen).ToArray();

                // WO-81: diagnostic-only cache of this session's last reported
                // position, read solely by the contested-claim detector's
                // distance correlation -- never a routing decision.
                _clientHandler.RecordPlayerPosition(this, x, y, z);

                _broadcastService.Broadcast(this, x, y, z, rotZ, flags, tail);
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

    /// <summary>
    /// Thread-safe: enqueue a Ghost packet to be sent to this client.
    /// <paramref name="tail"/> is the sender's body-state bytes (WO-100.5),
    /// appended verbatim after the flags byte -- empty for a 17-byte Position,
    /// so the Ghost is 18 or 23 bytes and never anything else (WO-101).
    /// </summary>
    public void EnqueueGhost(byte ghostId, float x, float y, float z, float rotZ, byte flags, byte[] tail)
    {
        var payload = new byte[Protocol.GhostPayloadLen + tail.Length];
        payload[0] = ghostId;
        WriteFloat(payload, 1, x);
        WriteFloat(payload, 5, y);
        WriteFloat(payload, 9, z);
        WriteFloat(payload, 13, rotZ);
        payload[17] = flags;
        tail.CopyTo(payload, Protocol.GhostPayloadLen);
        EnqueueGhostPacket(ghostId, BuildPacket(Protocol.Ghost, payload));
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
    /// Thread-safe: enqueue a TimeSkipDown (0x29, WO-38). The body is the
    /// upstream payload (with the phase byte possibly rewritten to done-quiet
    /// by the routing rules), prefixed with who sent it.
    /// </summary>
    public void EnqueueTimeSkip(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.TimeSkipDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a CombatEventDown (0x2D, WO-39 Phase 1). The body
    /// is the upstream [event:1] payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueCombatEvent(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.CombatEventDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an ActionDown (0x3C, WO-100.5 Phase 3). The body is
    /// the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueAction(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.ActionDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an NpcDamageDown (0x31, WO-40 Phase 5). The body
    /// is the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueNpcDamage(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.NpcDamageDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an ItemDropDown (0x33, WO-48). The body is the
    /// upstream payload verbatim, prefixed with who dropped it.
    /// </summary>
    public void EnqueueItemDrop(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.ItemDropDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an ItemClaimDown (0x35, WO-48). The body is the
    /// upstream payload verbatim, prefixed with who claimed it. Unlike every
    /// other Down packet this one also goes back to its own sender -- the
    /// echo is the claim's confirmation (see Protocol's 0x34 notes).
    /// </summary>
    public void EnqueueItemClaim(byte claimerId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = claimerId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.ItemClaimDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a StoryBeatDown (0x38, WO-90). The body is the
    /// upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueStoryBeat(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.StoryBeatDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a WeatherDown (0x2F, WO-40 Phase 3). The body is
    /// the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    /// <summary>
    /// Thread-safe (WO-113): enqueue a sender-prefixed copy of an upstream body
    /// under <paramref name="downType"/> -- PlayerRespawnedDown (0x3F),
    /// GraveAddDown (0x41) or GraveRemoveDown (0x43). Facts about the sender,
    /// relayed verbatim like WeatherDown.
    /// </summary>
    public void EnqueueSenderFact(byte downType, byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(downType, payload));
    }

    public void EnqueueWeather(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.WeatherDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue a HorseInfoDown (0x2B, WO-38 Phase 5). The body is
    /// the upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueHorseInfo(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        EnqueueRaw(BuildPacket(Protocol.HorseInfoDown, payload));
    }

    /// <summary>
    /// Thread-safe: enqueue an NpcStateDown (0x27, WO-32). The body is the
    /// upstream payload verbatim, prefixed with who sent it.
    /// </summary>
    public void EnqueueNpcState(byte sourceId, byte[] upstreamBody)
    {
        var payload = new byte[1 + upstreamBody.Length];
        payload[0] = sourceId;
        Buffer.BlockCopy(upstreamBody, 0, payload, 1, upstreamBody.Length);
        // WO-110 4.4: keyed by source + NPC name so pressure thinning is per NPC.
        int nameLen = upstreamBody[0];
        string key = sourceId + "|" + Encoding.UTF8.GetString(upstreamBody, 1, nameLen);
        EnqueueNpcPacket(key, BuildPacket(Protocol.NpcStateDown, payload));
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

    private void EnqueueRaw(byte[] packet)
    {
        bool overflow;
        lock (_writeQueueLock)
        {
            if (_writeQueueStopped) return;
            overflow = _queuedBytes + packet.Length > MaxQueuedBytes;
            if (!overflow) { _writeQueue.Enqueue(new(packet, null)); _queuedBytes += packet.Length; }
        }

        if (overflow) AbortWriteQueue($"outbound queue limit reached ({MaxQueuedBytes / 1024} KB queued; {_npcCoalesced} NPC samples were already thinned)");
        else _writeSignal.Release();
    }

    /// <summary>
    /// WO-110 4.4: an NpcStateDown for a (source, name). Below PressureBytes
    /// it is an ordinary FIFO entry (full sample density). Above it, one slot
    /// per key: a waiting sample for the same NPC is replaced by the newer
    /// one and counted, so a slow client sees fewer, newer samples instead
    /// of a disconnect.
    /// </summary>
    private void EnqueueNpcPacket(string key, byte[] packet)
    {
        bool overflow = false, queued = false, coalesced = false;
        lock (_writeQueueLock)
        {
            if (_writeQueueStopped) return;
            if (_queuedBytes >= PressureBytes && _pendingNpcPackets.TryGetValue(key, out var old))
            {
                _queuedBytes += packet.Length - old.Length;
                _pendingNpcPackets[key] = packet;
                _npcCoalesced++;
                coalesced = true;
            }
            else if (_queuedBytes >= PressureBytes)
            {
                overflow = _queuedBytes + packet.Length > MaxQueuedBytes;
                if (!overflow) { _pendingNpcPackets[key] = packet; _writeQueue.Enqueue(new(null, null, key)); _queuedBytes += packet.Length; queued = true; }
            }
            else
            {
                overflow = _queuedBytes + packet.Length > MaxQueuedBytes;
                if (!overflow) { _writeQueue.Enqueue(new(packet, null)); _queuedBytes += packet.Length; queued = true; }
            }
        }
        if (coalesced) _clientHandler.CountDrop(Protocol.NpcStateDown, "pressure-coalesced");
        if (overflow) AbortWriteQueue($"outbound queue limit reached ({MaxQueuedBytes / 1024} KB queued; {_npcCoalesced} NPC samples were already thinned)");
        else if (queued) _writeSignal.Release();
    }

    private void EnqueueGhostPacket(byte ghostId, byte[] packet)
    {
        bool overflow;
        bool queued = false;
        lock (_writeQueueLock)
        {
            if (_writeQueueStopped) return;

            if (_pendingGhostPackets.TryGetValue(ghostId, out var oldGhost))
            {
                // A marker for this source is already queued. Replace only its
                // payload so a slow client receives the newest position.
                _queuedBytes += packet.Length - oldGhost.Length;
                _pendingGhostPackets[ghostId] = packet;
                return;
            }

            overflow = _queuedBytes + packet.Length > MaxQueuedBytes;
            if (!overflow)
            {
                _pendingGhostPackets[ghostId] = packet;
                _writeQueue.Enqueue(new(null, ghostId));
                _queuedBytes += packet.Length;
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
            _pendingNpcPackets.Clear();
            _queuedBytes = 0;
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
                    if (queued.GhostId is byte ghostId)
                    {
                        _pendingGhostPackets.Remove(ghostId, out packet);
                    }
                    else if (queued.NpcKey is string npcKey)
                    {
                        _pendingNpcPackets.Remove(npcKey, out packet);   // WO-110 4.4
                    }
                    else
                    {
                        packet = queued.Packet;
                    }
                    if (packet is not null) _queuedBytes -= packet.Length;
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

    /// <summary>
    /// WO-110 R15: printable characters only (no control characters, so no
    /// newline), no square brackets (the mod's log tags are bracketed), trimmed,
    /// at most 32 characters; an empty result becomes "player".
    /// </summary>
    public static string SanitizeName(string raw)
    {
        var sb = new StringBuilder(raw.Length);
        foreach (char c in raw)
        {
            if (char.IsControl(c) || c == '[' || c == ']' || char.IsSurrogate(c)) continue;
            sb.Append(c);
            if (sb.Length >= 32) break;
        }
        string s = sb.ToString().Trim();
        return s.Length == 0 ? "player" : s;
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

    /// <summary>
    /// WO-102.5 Phase 4: the idle-timeout read at the top of the main
    /// per-packet loop. A cancellation from the timeout is converted to an
    /// IOException so it reaches RunAsync's existing "normal disconnect"
    /// catch clause unchanged, running the same BroadcastCombatRole /
    /// HandleDisconnect cleanup an ordinary FIN or RST would.
    /// </summary>
    private async Task ReadExactWithIdleTimeoutAsync(byte[] buffer)
    {
        using var cts = new CancellationTokenSource(_idleTimeout);
        try
        {
            int offset = 0;
            while (offset < buffer.Length)
            {
                int n = await _stream.ReadAsync(buffer.AsMemory(offset), cts.Token);
                if (n == 0) throw new EndOfStreamException();
                offset += n;
            }
        }
        catch (OperationCanceledException) when (cts.IsCancellationRequested)
        {
            throw new IOException($"idle timeout ({_idleTimeout.TotalSeconds:F0}s) waiting for the next packet");
        }
    }
}
