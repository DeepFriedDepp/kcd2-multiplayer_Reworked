using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Globalization;
using System.Linq;
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

    // Combat (WO-4): the channel to KCDMP.dll. Remote damage can only be
    // applied through native code, so this is the one path for it.
    private readonly CombatPipe _combat = new();

    /// <summary>
    /// Interaction sessions (WO-2). Dice and duelling hang off this rather than
    /// adding their own protocols. Null until connected.
    /// </summary>
    public InteractionClient? Interactions { get; private set; }

    /// <summary>Dice wire protocol (WO-5), relay-authoritative. Null until connected.</summary>
    public DiceClient? Dice { get; private set; }

    // ghostId → display name, from Name packets. Lets an invite prompt say who
    // is asking instead of showing a bare relay id.
    private readonly ConcurrentDictionary<byte, string> _ghostNames = new();

    // Appearance (WO-9 armor, WO-10 weapons). Outbound: the local player's
    // item classes as of the last successful send, so the poll loop only
    // sends on an actual change. Armor and weapon classes share this one set
    // -- EquipItem/UnequipItem do not care which map a class came from, so
    // there was no need for a second wire message. Inbound: per ghost, what
    // is currently applied and which classes have ever been created in that
    // ghost's inventory -- tracked here rather than re-read from the game, so
    // applying a diff never needs an extra round trip to ask "what does this
    // ghost have on already".
    private HashSet<Guid>? _lastSentAppearance;
    private readonly ConcurrentDictionary<byte, HashSet<Guid>> _ghostAppearance = new();
    private readonly ConcurrentDictionary<byte, HashSet<Guid>> _ghostKnownItemClasses = new();

    // Set by the "appearance_sync" game event (mp_sync_appearance console
    // command) to force the next poll to send unconditionally, bypassing the
    // change check -- the honest floor for a tester who does not want to wait
    // for the poll interval or the heartbeat.
    private volatile bool _forceAppearanceResync;

    // The only channel to KCDMP_launcher's dice window -- see DiceIpcServer.
    private DiceIpcServer? _diceIpcServer;

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

        // Player decisions (accepting an invite, initiating one) come back out
        // through the same log channel, since nothing else leads out of the game.
        tail.GameEvent += OnGameEvent;

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
        _lastSentAppearance = null;
        _ghostAppearance.Clear();
        _ghostKnownItemClasses.Clear();

        // --- Interaction layer ---
        // Framing lives here because this class owns the stream; the interaction
        // and dice clients only decide what to say.
        async Task SendPacketAsync(byte type, byte[] payload, CancellationToken ict)
        {
            var pkt = new byte[3 + payload.Length];
            pkt[0] = type;
            BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(1), (ushort)payload.Length);
            payload.CopyTo(pkt, 3);
            await stream.WriteAsync(pkt, ict);
        }

        var interactions = new InteractionClient(SendPacketAsync);
        var dice = new DiceClient(SendPacketAsync);
        WireInteractionFeedback(interactions);
        WireDiceFeedback(dice, interactions);
        Interactions = interactions;
        Dice = dice;

        // The launcher's dice window has no other way to reach this agent (see
        // DiceIpcServer) -- neither process depends on the other having started
        // first, so this cannot ride the launcher's own process-start plumbing.
        var diceIpc = new DiceIpcState(interactions, dice,
            ghostId => _ghostNames.TryGetValue(ghostId, out var n) ? n : null);
        _diceIpcServer = new DiceIpcServer(diceIpc, config.DiceIpcPort);
        _diceIpcServer.Start();

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
        // Outbound combat: the DLL notices a nearby NPC lose health and we put
        // it on the wire. Never fired for damage we applied on a peer's behalf —
        // the DLL credits those out — or two clients would echo a hit forever.
        _combat.OnLocalHit = async (soul, stamina, health) =>
        {
            try
            {
                await SendLocalHitAsync(stream, soul, stamina, health, suppressHitReaction: true);
                Console.WriteLine($"[combat] sent hit {health:F1} on {soul}");
            }
            catch (Exception ex) { Console.WriteLine($"[combat] hit not sent: {ex.Message}"); }
        };
        // Connect now rather than lazily, so the DLL has somewhere to push hits
        // before the first inbound packet ever arrives.
        _ = _combat.EnsureConnectedAsync(cts.Token);

        var receiveTask     = ReceiveLoopAsync(stream, cts.Token);
        var pingTask        = PingLoopAsync(stream, cts.Token);
        var appearanceTask  = AppearanceLoopAsync(stream, cts.Token);

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
            try { await receiveTask;     } catch { }
            try { await pingTask;        } catch { }
            try { await appearanceTask;  } catch { }
            _voice?.Stop();
            _voice?.Dispose();
            _voice = null;

            // The relay drops our sessions when the socket closes, so local
            // state has to go too or a reconnect would think it is still busy.
            Interactions?.Reset();
            Interactions = null;
            Dice = null;
            _diceIpcServer?.Stop();
            _diceIpcServer = null;
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
    // Appearance poll loop (WO-9)
    // -------------------------------------------------------------------------

    /// <summary>How often the local player's equipped set is checked for a change.</summary>
    private const int AppearancePollMs = 3000;

    /// <summary>
    /// Polls the local player's equipped item classes on a slow timer and
    /// sends an Appearance packet only when the set actually changed, plus an
    /// unconditional resend every <see cref="Protocol.AppearanceHeartbeatSeconds"/>
    /// so a peer who connects after the last real change still converges --
    /// the relay does not remember or replay it for a late joiner.
    ///
    /// A poll on a multi-second timer is deliberate, not a placeholder: outfit
    /// changes are a player action, not a per-frame concern, and this is the
    /// same reasoning WO-1 applied to the position tick versus a slower yaw
    /// refresh. Reading a preset id off spawn state was tried and rejected in
    /// Phase 0 -- see docs/WO-9-appearance-sync.md -- because a player who
    /// re-equips by hand instead of via a preset leaves BaseClothingPreset all
    /// zero, so only the per-item read is trustworthy.
    /// </summary>
    private async Task AppearanceLoopAsync(NetworkStream stream, CancellationToken ct)
    {
        int ticksSinceSend = int.MaxValue; // force the first poll to send
        int ticksPerHeartbeat = Math.Max(1, Protocol.AppearanceHeartbeatSeconds * 1000 / AppearancePollMs);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var current = await _transport.ReadEquippedItemClassesAsync(ct);
                if (current.Length > 0)
                {
                    var currentSet = new HashSet<Guid>(current);
                    bool changed = _lastSentAppearance is null || !currentSet.SetEquals(_lastSentAppearance);
                    bool heartbeatDue = ticksSinceSend >= ticksPerHeartbeat;
                    bool forced = _forceAppearanceResync;

                    if (changed || heartbeatDue || forced)
                    {
                        var items = currentSet.Count <= Protocol.MaxAppearanceItems
                            ? [.. currentSet]
                            : currentSet.Take(Protocol.MaxAppearanceItems).ToArray();
                        await SendAppearanceAsync(stream, items, ct);
                        _lastSentAppearance = currentSet;
                        ticksSinceSend = 0;
                        _forceAppearanceResync = false;
                        Console.WriteLine($"[appearance] sent {items.Length} item class(es)" +
                            (forced ? " (forced)" : changed ? "" : " (heartbeat)"));
                    }
                }
            }
            catch (Exception ex) { Console.WriteLine($"[appearance] poll failed: {ex.Message}"); }

            try { await Task.Delay(AppearancePollMs, ct); }
            catch (OperationCanceledException) { break; }
            ticksSinceSend++;
        }
    }

    /// <summary>
    /// The ghost's spawn-time outfit AND weapon (kdcmp.lua's
    /// <c>KCD2MP.armorPresets.white_red</c>, applied via
    /// <c>EquipClothingPreset</c> + <c>EquipWeaponPreset</c> in
    /// <c>KCD2MP_SpawnGhost</c>), mirrored here as data -- same rule as the
    /// animation tables: port it, never regenerate it. This exists so the
    /// *first* appearance diff for a ghost has something to unequip. Without
    /// it, the preset's own items are never in <see cref="_ghostAppearance"/>
    /// (they were never applied through this path, only at spawn), so the
    /// diff would only ever add to the preset and never remove from it -- a
    /// real player wearing nothing like full plate would still show a ghost
    /// head-to-toe in the spawn preset with their actual gear invisible
    /// underneath. Observed live, WO-9 Phase 2: the only visible difference
    /// before this fix was a gambeson collar peeking out from under an
    /// otherwise-unchanged suit of plate.
    ///
    /// The weapon entry (WO-10) is the identical trap for
    /// <c>EquipWeaponPreset(p.weapons)</c>, which the WO-9 session never
    /// noticed because it only looked at armor: a spawned ghost carries
    /// <c>sermiry_longSwordMenhart</c> from the <c>kkut_menhart</c> weapon
    /// preset the moment it exists, confirmed live by reading a freshly
    /// spawned ghost's own EquippedWeaponsByClassId (WO-10). Left unseeded,
    /// the first weapon diff would only ever add a player's real weapon
    /// alongside the preset's sword rather than replacing it.
    /// </summary>
    private static readonly Guid[] GhostSpawnPresetItems =
    [
        Guid.Parse("a8b22da0-e42e-4d79-abe7-52e6eebad6eb"), // LegsBrigandine04
        Guid.Parse("cc1adb78-fa5a-45c9-be7b-b7b50e182cb3"), // LegsPadded01
        Guid.Parse("36a701ed-2144-452a-b113-385efba2c0d1"), // knackersGloves
        Guid.Parse("46b051c4-d4e2-4f3a-8b88-e3f64dae4618"), // GambesonLong01
        Guid.Parse("1aadf1e5-c37b-41c3-bc65-354187022c91"), // Brigandine10
        Guid.Parse("a5322fcd-27b4-4f4e-bfbf-49c519c74c74"), // ArmPlate04
        Guid.Parse("cfc1fd72-dbb7-49a4-8713-6acf215a72be"), // CoifMail01
        Guid.Parse("b6fe59ec-c854-402a-848e-a77f55661c19"), // BascinetVisor05
        Guid.Parse("a06cfbf0-3d59-4003-89d4-69a82eb735af"), // BootsKnee03
        Guid.Parse("204c1852-dd30-42ae-9317-bc3123a3e301"), // sermiry_longSwordMenhart (kkut_menhart weapon preset)
    ];

    /// <summary>
    /// Applies a received Appearance packet to the ghost identified by
    /// <paramref name="ghostId"/>: diffs the target set against what was last
    /// applied to that ghost -- seeded with <see cref="GhostSpawnPresetItems"/>
    /// the first time this ghost is seen, so the preset itself is a proper
    /// part of the diff -- unequips what dropped out, equips what is new.
    /// Never re-touches a slot that did not change.
    /// </summary>
    private async Task ApplyAppearanceAsync(byte ghostId, Guid[] target, CancellationToken ct)
    {
        string soulName = $"kcd2mp_{ghostId}";
        var applied = _ghostAppearance.GetOrAdd(ghostId, static _ => [.. GhostSpawnPresetItems]);
        // The preset's items are already sitting in the ghost's inventory from
        // spawn (EquipClothingPreset put them there) -- CreateItems must never
        // run for them again.
        var known = _ghostKnownItemClasses.GetOrAdd(ghostId, static _ => [.. GhostSpawnPresetItems]);
        var targetSet = new HashSet<Guid>(target);

        List<Guid> toRemove;
        List<Guid> toAdd;
        lock (applied)
        {
            toRemove = applied.Except(targetSet).ToList();
            toAdd    = targetSet.Except(applied).ToList();
        }

        foreach (var cls in toRemove)
        {
            try
            {
                await _transport.UnequipItemOnGhostAsync(soulName, cls, ct);
                lock (applied) applied.Remove(cls);
            }
            catch (Exception ex) { Console.WriteLine($"[appearance] unequip {cls} on {soulName} failed: {ex.Message}"); }
        }

        foreach (var cls in toAdd)
        {
            bool createIfMissing;
            lock (known) createIfMissing = known.Add(cls);
            try
            {
                await _transport.EquipItemOnGhostAsync(soulName, cls, createIfMissing, ct);
                lock (applied) applied.Add(cls);
            }
            catch (Exception ex) { Console.WriteLine($"[appearance] equip {cls} on {soulName} failed: {ex.Message}"); }
        }

        if (toRemove.Count > 0 || toAdd.Count > 0)
        {
            Console.WriteLine($"[appearance] ghost {ghostId}: +{toAdd.Count} -{toRemove.Count}");
            await VerifyAndRetryAsync(soulName, ghostId, toAdd, applied, ct);
        }
    }

    /// <summary>
    /// A fault-free EquipItem invoke is not a successful one. Measured live
    /// (WO-9 Phase 2, two-agent test): under the agent's normal concurrent
    /// load -- its own position tick flushing Lua every ~10 ms plus this same
    /// poll loop's other traffic -- EquipItem returns <c>true</c> immediately
    /// but the actual game-state commit lagged several seconds behind on a
    /// freshly-spawned ghost. A lone manual call against a quiet API answered
    /// instantly; the identical call through the running agent needed up to
    /// ~10 s to actually land. So this is a real, reproduced processing
    /// delay, not a guessed one, and the retry schedule below (1/2/3/4 s,
    /// ~10 s total) is sized to the worst case actually observed rather than
    /// an arbitrary short backoff.
    ///
    /// Reads the ghost's own EquippedArmorsByClassId back, and for anything
    /// this call just tried to add but is still missing, retries EquipItem
    /// (never CreateItems again -- the item instance from the first attempt
    /// is already sitting in the ghost's inventory). Anything still missing
    /// once the schedule is exhausted is dropped from <paramref name="applied"/>
    /// so the next change or heartbeat naturally tries again, rather than the
    /// diff believing a slot is settled when it never took.
    /// </summary>
    private static readonly int[] AppearanceRetryDelaysMs = [1000, 1000, 1000, 2000, 2000, 3000];

    private async Task VerifyAndRetryAsync(string soulName, byte ghostId, List<Guid> toAdd,
        HashSet<Guid> applied, CancellationToken ct)
    {
        var pending = new List<Guid>(toAdd);

        foreach (int delayMs in AppearanceRetryDelaysMs)
        {
            if (pending.Count == 0) return;

            await Task.Delay(delayMs, ct);
            var actual = new HashSet<Guid>(await _transport.ReadGhostEquippedItemClassesAsync(soulName, ct));
            pending = pending.Where(cls => !actual.Contains(cls)).ToList();
            if (pending.Count == 0) return;

            Console.WriteLine($"[appearance] ghost {ghostId}: {pending.Count} item(s) still not applied, retrying");
            foreach (var cls in pending)
            {
                try { await _transport.EquipItemOnGhostAsync(soulName, cls, createIfMissing: false, ct); }
                catch (Exception ex) { Console.WriteLine($"[appearance] retry equip {cls} on {soulName} failed: {ex.Message}"); }
            }
        }

        // Schedule exhausted: one final read to tell a genuine failure (a
        // slot the game will never grant, e.g. the Hood-vs-Helmet exclusivity
        // found in Phase 0) from one more round of lag.
        var final = new HashSet<Guid>(await _transport.ReadGhostEquippedItemClassesAsync(soulName, ct));
        foreach (var cls in pending)
        {
            if (final.Contains(cls)) continue;
            Console.WriteLine($"[appearance] ghost {ghostId}: {cls} never equipped after {AppearanceRetryDelaysMs.Sum()}ms of retrying -- leaving it out of the applied set");
            lock (applied) applied.Remove(cls);
        }
    }

    private static async Task SendAppearanceAsync(NetworkStream stream, Guid[] itemClasses, CancellationToken ct)
    {
        int payloadLen = 1 + itemClasses.Length * Protocol.ItemClassLen;
        var packet = new byte[3 + payloadLen];
        packet[0] = Protocol.AppearanceUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payloadLen);
        packet[3] = (byte)itemClasses.Length;
        int o = 4;
        foreach (var cls in itemClasses)
        {
            cls.TryWriteBytes(packet.AsSpan(o, Protocol.ItemClassLen));
            o += Protocol.ItemClassLen;
        }
        await stream.WriteAsync(packet, ct);
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
                    _ghostAppearance.TryRemove(ghostId, out _);
                    _ghostKnownItemClasses.TryRemove(ghostId, out _);
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
                else if (type == Protocol.DamageDown && payloadLen == Protocol.DamageDownPayloadLen)
                {
                    // Damage: [sourceGhostId:1][guid:16][stamina:4f][health:4f][flags:1]
                    // Applied through the DLL, not Lua: Lua writes are inert.
                    byte  sourceId = payload[0];
                    var   soul     = new Guid(payload.AsSpan(1, 16));
                    float stamina  = ReadFloat(payload, 17);
                    float health   = ReadFloat(payload, 21);
                    bool  suppress = (payload[25] & Protocol.DamageFlagSuppressHitReaction) != 0;

                    bool applied = await _combat.ApplyDamageAsync(soul, stamina, health, suppress, ct);
                    if (!applied)
                        Console.WriteLine($"[combat] damage from ghost {sourceId} not applied " +
                                          $"(soul {soul} not loaded here, or the DLL is absent)");
                }
                else if (type == Protocol.DeathDown && payloadLen == Protocol.DeathDownPayloadLen)
                {
                    // Death is its own packet rather than inferred from health
                    // reaching zero, and the DLL treats it as idempotent.
                    byte sourceId = payload[0];
                    var  soul     = new Guid(payload.AsSpan(1, 16));
                    bool applied  = await _combat.ApplyDeathAsync(soul, ct);
                    if (!applied)
                        Console.WriteLine($"[combat] death from ghost {sourceId} not applied " +
                                          $"(soul {soul} not loaded here, or the DLL is absent)");
                }
                else if (type == Protocol.AppearanceDown && payloadLen >= 2)
                {
                    // Appearance: [sourceGhostId:1][itemCount:1][itemClass:16]*itemCount
                    byte sourceId = payload[0];
                    int itemCount = payload[1];
                    if (payloadLen == 2 + itemCount * Protocol.ItemClassLen)
                    {
                        var items = new Guid[itemCount];
                        for (int i = 0; i < itemCount; i++)
                            items[i] = new Guid(payload.AsSpan(2 + i * Protocol.ItemClassLen, Protocol.ItemClassLen));
                        _ = ApplyAppearanceAsync(sourceId, items, ct);
                    }
                }
                else if (Interactions?.HandlePacket(type, payload) == true)
                {
                    // Session packet consumed by the interaction layer.
                }
                else if (Dice?.HandlePacket(type, payload) == true)
                {
                    // Dice packet consumed by the dice layer.
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
    /// Handles a discrete event the player triggered in game, delivered via the
    /// log tail. Fire-and-forget because this runs on the tail loop's thread and
    /// must not block it.
    /// </summary>
    private void OnGameEvent(string name, string arg)
    {
        var interactions = Interactions;
        if (interactions is null) return;

        switch (name)
        {
            case "invite_accept":
                Console.WriteLine("[interaction] player accepted");
                _ = interactions.RespondAsync(true);
                break;

            case "invite_decline":
                Console.WriteLine("[interaction] player declined");
                _ = interactions.RespondAsync(false);
                break;

            case "appearance_sync":
                // mp_sync_appearance (WO-9): the honest floor. Forces the next
                // poll tick to send regardless of whether the equipped set
                // actually changed, so a tester never has to wait out the poll
                // interval or the heartbeat to demo or fix a desync.
                Console.WriteLine("[appearance] manual resync requested");
                _forceAppearanceResync = true;
                break;

            case "invite_send":
            {
                // "<ghostId> <kind>" — Lua picks the target because it has the
                // ghost positions; we only know relay ids.
                var parts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 1 || !byte.TryParse(parts[0], out byte targetId))
                {
                    Console.WriteLine($"[interaction] malformed invite_send '{arg}'");
                    break;
                }
                var kind = parts.Length > 1 && parts[1].Equals("duel", StringComparison.OrdinalIgnoreCase)
                    ? InteractionKind.Duel
                    : InteractionKind.Dice;
                Console.WriteLine($"[interaction] inviting ghost {targetId} to {kind}");
                _ = interactions.InviteAsync(targetId, kind);
                break;
            }

            case "dice_intent":
            {
                // The in-game board asked for something (WO-6). Before this the
                // only way to send an intent was the launcher window over IPC;
                // now the game itself is the input surface, so intents ride the
                // same log-tail event channel invite_accept already uses.
                //
                // Nothing here validates the request: the relay owns the
                // FarkleGame and answers with a snapshot or a DiceError. Sending
                // an illegal intent is safe by design.
                var dice = Dice;
                var session = interactions.Current;
                if (dice is null || session is null || session.Kind != InteractionKind.Dice)
                {
                    Console.WriteLine("[dice] ignoring intent with no dice session in play");
                    break;
                }

                var bits = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var verb = bits.Length > 0 ? bits[0].ToLowerInvariant() : "";
                switch (verb)
                {
                    case "roll":    _ = dice.RollAsync(session.SessionId); break;
                    case "bank":    _ = dice.BankAsync(session.SessionId); break;
                    case "forfeit": _ = dice.ForfeitAsync(session.SessionId); break;
                    case "keep":
                        // "keep <mask>" -- a 6-bit selection over the snapshot's
                        // FreeFaces, built by the board from the player's marks.
                        if (bits.Length > 1 && byte.TryParse(bits[1], out byte mask))
                            _ = dice.KeepAsync(session.SessionId, mask);
                        else
                            Console.WriteLine($"[dice] malformed keep mask '{arg}'");
                        break;
                    default:
                        Console.WriteLine($"[dice] unknown intent '{arg}'");
                        break;
                }
                break;
            }

            default:
                Console.WriteLine($"[event] ignoring unknown game event '{name}'");
                break;
        }
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

            // Every kind now prompts in game. Dice used to be excluded here
            // because its UI lived in the launcher window; that window is
            // retired (WO-6), so there is no longer anywhere else for a dice
            // invite to appear.
            _ = ExecLuaAsync($"if KCD2MP_ShowInvite then KCD2MP_ShowInvite({invite.SessionId},\"{Escape(who)}\",\"{invite.Kind}\") end");
        };

        interactions.SessionStarted += session =>
        {
            Console.WriteLine($"[interaction] {session.Kind} session {session.SessionId} started as {session.Role}");
            _ = ExecLuaAsync($"if KCD2MP_HideInvite then KCD2MP_HideInvite() end");

            if (session.Kind == InteractionKind.Dice)
            {
                // Open the board now so the panel is already on screen when the
                // first snapshot lands, rather than popping in with it. Role and
                // peer name are session facts and are not carried on DiceState;
                // the target score arrives with the first snapshot and corrects
                // the placeholder.
                string peer = _ghostNames.TryGetValue(session.PeerGhostId, out var pn) ? pn : "opponent";
                _ = ExecLuaAsync($"if KCD2MP_DiceOpen then KCD2MP_DiceOpen({(byte)session.Role},\"{Escape(peer)}\",0) end");
            }
        };

        interactions.SessionEnded += (sid, reason) =>
        {
            Console.WriteLine($"[interaction] session {sid} ended: {reason}");
            _ = ExecLuaAsync($"if KCD2MP_HideInvite then KCD2MP_HideInvite() end");
            _ = ExecLuaAsync($"if KCD2MP_ShowInteractionMsg then KCD2MP_ShowInteractionMsg(\"{reason}\") end");

            // Harmless no-ops if this wasn't a dice session. DiceEnd already
            // ran for a match that finished normally, so this is what closes the
            // board after a decline, a timeout or a peer disconnect.
            _ = ExecLuaAsync("if KCD2MP_ShowDiceTurn then KCD2MP_ShowDiceTurn(nil) end");
            _ = ExecLuaAsync("if KCD2MP_DiceClose then KCD2MP_DiceClose() end");
        };
    }

    /// <summary>
    /// Feeds the in-game dice board (WO-6).
    ///
    /// This replaced a one-line "whose turn" hint: the launcher's DiceWindow was
    /// the dice UI until WO-6 retired it, and the board drawn by kdcmp.lua is
    /// now the whole presentation. What changed is only how much of the snapshot
    /// gets forwarded -- this class still holds no dice state of its own and
    /// still never decides anything, exactly as before.
    ///
    /// Cost per update: one queued Lua statement of roughly 90 bytes, batched
    /// onto the same ExecuteString flush ghost positions already ride. A Farkle
    /// turn produces a handful of snapshots, so at 2-4 players this is far below
    /// the noise floor of the position stream (50 Hz per ghost).
    /// </summary>
    private void WireDiceFeedback(DiceClient dice, InteractionClient interactions)
    {
        dice.StateChanged += snapshot =>
        {
            var session = interactions.Current;
            if (session is null || session.Kind != InteractionKind.Dice) return;

            // Faces go over as CSV rather than a Lua table literal: it keeps the
            // statement short for the batcher and the Lua side parses it with one
            // gmatch. Empty string means no dice in that row.
            string free   = string.Join(",", snapshot.FreeFaces);
            string kept   = string.Join(",", snapshot.KeptFaces);
            string busted = string.Join(",", snapshot.BustedFaces);

            _ = ExecLuaAsync(
                $"if KCD2MP_DiceState then KCD2MP_DiceState({snapshot.CurrentPlayerRole}," +
                $"{snapshot.ScoreInitiator},{snapshot.ScoreAcceptor},{snapshot.TurnTotal}," +
                $"{snapshot.TargetScore},{(byte)snapshot.Phase},\"{free}\",\"{kept}\",\"{busted}\") end");
        };

        dice.IntentRejected += rejection =>
        {
            // The relay refused something this player asked for. The board says
            // why and shakes; state is unchanged, so nothing else to do.
            Console.WriteLine($"[dice] intent rejected: {rejection.Reason}");
            _ = ExecLuaAsync($"if KCD2MP_DiceError then KCD2MP_DiceError(\"{Escape(Humanise(rejection.Reason))}\") end");
        };

        dice.MatchEnded += result =>
        {
            _ = ExecLuaAsync("if KCD2MP_ShowDiceTurn then KCD2MP_ShowDiceTurn(nil) end");

            var session = interactions.Current;
            bool won = session is not null
                && ((session.Role == SessionRole.Initiator && result.Outcome == DiceOutcome.InitiatorWon)
                 || (session.Role == SessionRole.Acceptor  && result.Outcome == DiceOutcome.AcceptorWon));

            _ = ExecLuaAsync(
                $"if KCD2MP_DiceEnd then KCD2MP_DiceEnd(\"{(won ? "win" : "lose")}\"," +
                $"{result.ScoreInitiator},{result.ScoreAcceptor}) end");
        };
    }

    /// <summary>
    /// A reject reason in words the board can show. Kept here rather than in
    /// <see cref="DiceClient"/> so that class stays presentation-free.
    /// </summary>
    private static string Humanise(DiceRejectReason reason) => reason switch
    {
        DiceRejectReason.NotYourTurn          => "not thy turn",
        DiceRejectReason.WrongPhase           => "not now",
        DiceRejectReason.EmptyKeep            => "set aside at least one die",
        DiceRejectReason.KeepIndexOutOfRange  => "no such die",
        DiceRejectReason.InvalidKeepSelection => "those dice score nothing",
        DiceRejectReason.NothingToBank        => "nothing to bank",
        DiceRejectReason.GameAlreadyOver      => "the match is done",
        _                                     => "not allowed",
    };

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

    /// <summary>
    /// Report a hit our player landed, so peers apply it to the same NPC.
    ///
    /// NOTHING CALLS THIS YET. Detecting a local hit needs a hook on the game's
    /// own combat path, and TakeDamage is not exported, so that hook does not
    /// exist. The send side is written now so the outbound work is only the
    /// detection, not the plumbing.
    ///
    /// Must never be called for damage that arrived from a peer, or two clients
    /// will bounce the same hit back and forth forever. That is why applying
    /// remote damage goes straight to the pipe and never through here.
    /// </summary>
    public static async Task SendLocalHitAsync(NetworkStream stream, Guid soul,
                                               float stamina, float health,
                                               bool suppressHitReaction)
    {
        var packet = new byte[3 + Protocol.DamageUpPayloadLen];
        packet[0] = Protocol.DamageUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.DamageUpPayloadLen);
        soul.TryWriteBytes(packet.AsSpan(3, 16));
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(19), stamina);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(23), health);
        packet[27] = suppressHitReaction ? Protocol.DamageFlagSuppressHitReaction : (byte)0;
        await stream.WriteAsync(packet);
    }

    /// <summary>Report an NPC our client killed. Idempotent at every receiver.</summary>
    public static async Task SendLocalDeathAsync(NetworkStream stream, Guid soul)
    {
        var packet = new byte[3 + Protocol.DeathUpPayloadLen];
        packet[0] = Protocol.DeathUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.DeathUpPayloadLen);
        soul.TryWriteBytes(packet.AsSpan(3, 16));
        await stream.WriteAsync(packet);
    }

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
