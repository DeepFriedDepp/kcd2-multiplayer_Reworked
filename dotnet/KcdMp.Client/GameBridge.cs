using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
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
    private readonly SemaphoreSlim _tcpWriteLock = new(1, 1);

    // Last pushed position (for change detection)
    private float _lastX, _lastY, _lastZ, _lastRotZ;
    private bool _lastRiding;
    private bool _hasPushed;
    // WO-99 Phase 1: stale heartbeats sent in the current suspension (0 = mod is live).
    private int _staleRun;

    // Ping: maps sent timestamp (ticks) → Stopwatch timestamp at send time
    private readonly ConcurrentDictionary<long, long> _pingsSent = new();

    // WO-98 Phase 1: clock-offset estimator -- relay wall clock minus ours,
    // NTP-shaped over ClockSyncUp/Down (0x39/0x3A, sent on the ping cadence).
    // Running median of the last ClockSamplesKept samples; a single sample
    // is one round trip's worth of asymmetric-latency error, the median of
    // fifteen is not. MEASUREMENT ONLY (docs/WO-98-findings.md s1): nothing
    // consumes it yet. Logged as MP-CLOCK, pushed to the mod for display,
    // and stamped into every agent.log line by TeeTextWriter.
    private readonly object _clockLock = new();
    private readonly List<(double OffsetMs, double RttMs)> _clockSamples = new();
    private const int ClockSamplesKept = 15;
    private double? _clockOffsetMs;
    private double? _clockRttMedianMs;
    private int _clockSampleCount;
    private long _lastClockLogTimestamp;
    /// <summary>WO-98: relay clock minus this machine's clock, ms; null until the first reply.</summary>
    public double? ClockOffsetMs => _clockOffsetMs;

    // Voice: frames captured by VoiceChat are queued here, drained in main loop
    private readonly ConcurrentQueue<byte[]> _voiceQueue = new();
    private VoiceChat? _voice;

    // Combat (WO-4): the channel to KCDMP.dll. Remote damage can only be
    // applied through native code, so this is the one path for it.
    private readonly CombatPipe _combat = new();

    // --- WO-100.5 Phase 2: the local body-state read ------------------------
    //
    // Read once per position push, not per tick, and switched off for the rest
    // of the session after a run of refusals. A DLL that predates 0x09 never
    // answers, and paying a pipe round trip per push forever to re-learn that
    // is the kind of quiet cost that does not show up until a field log is
    // read. One line when it gives up, and the counters say so in MP-ANIM.
    private bool _bodyStateOff;
    private int  _bodyStateMisses;
    private const int BodyStateGiveUpAfter = 20;

    // --- WO-100.5 Phase 3: the discrete action channel ----------------------
    private readonly ActionOutbox       _actionOut  = new();
    private readonly ActionInbox        _actionIn   = new();
    private readonly AttackEdgeDetector _attackEdge = new();

    // WO-99 Phase 0: local-player exclusion + echo memory for the 0x30/0x31
    // NPC damage path (docs/WO-99-findings.md Phase 0). The player identity
    // is re-read on a TTL and forced after a save load / MOD INIT.
    private readonly NpcDamageGuard _dmgGuard = new();
    private DateTime _dmgGuardIdentityAtUtc = DateTime.MinValue;
    private static readonly TimeSpan DmgGuardIdentityTtl = TimeSpan.FromSeconds(60);

    /// <summary>
    /// Refresh the guard's view of the local player's soul (guid + name) from
    /// SoulList/PlayerSoul when the cache is older than the TTL or a caller
    /// has reason to distrust it (a name matched but the guid did not).
    /// </summary>
    private async Task RefreshPlayerIdentityAsync(bool force, CancellationToken ct)
    {
        var now = DateTime.UtcNow;
        if (!force && now - _dmgGuardIdentityAtUtc < DmgGuardIdentityTtl) return;
        _dmgGuardIdentityAtUtc = now;
        try
        {
            var (guid, name) = await _transport.ReadPlayerSoulIdentityAsync(ct);
            var before = _dmgGuard.PlayerGuid;
            _dmgGuard.SetLocalPlayer(guid, name);
            if (guid != before || force)
                Console.WriteLine($"[dmgguard] local player soul guid={(guid?.ToString() ?? "?")} name={name ?? "?"}{(force ? " (forced re-read)" : "")}");
        }
        catch (Exception ex) { Console.WriteLine($"[dmgguard] player identity read failed: {ex.Message}"); }
    }

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

    // ghostId → CryEngine entity id, from the mod's spawn-time "ghostid"
    // event (WO-46). This is what the native swing path addresses a ghost by;
    // entries go stale when a ghost despawns and are simply overwritten by
    // the next spawn report — a stale id makes the DLL's resolve fail cleanly
    // (Result=false), it cannot touch the wrong actor because entity ids are
    // never reused within a session.
    private readonly ConcurrentDictionary<string, uint> _ghostEntityIds = new();

    // WO-100 Phase 4 item 1 -- the validity counter for a ghost body.
    //
    // A ghost's CryEngine entity id changes when its body is replaced (a save
    // load -> RECONCILE -> fresh spawn; a reconnect; a despawn/respawn). WO-88
    // already used "the entity id changed" to invalidate the appearance sets;
    // this makes the same fact available to events IN FLIGHT. Bumped on every
    // observed id change and on every ghost removal, so an event that names
    // generation N is discarded rather than replayed onto generation N+1.
    //
    // One counter, not the incarnation/epoch/revision triple the WO describes:
    // all three of that triple's causes (death, respawn, reload) produce a new
    // body here and therefore a new entity id, so a second and third field
    // would carry no information this one does not. Stated so the difference
    // from the WO's text is a decision rather than an omission.
    private readonly ConcurrentDictionary<string, int> _ghostBodyGen = new();

    private int GhostGeneration(string ghostId) =>
        _ghostBodyGen.TryGetValue(ghostId, out int g) ? g : 0;

    private void BumpGhostGeneration(string ghostId, string why)
    {
        int now = _ghostBodyGen.AddOrUpdate(ghostId, 1, (_, g) => g + 1);
        Console.WriteLine($"[combatviz] ghost {ghostId} body generation -> {now} ({why})");
    }

    private SwingInbox? _swingInbox;
    private readonly object _swingInboxGate = new();

    /// <summary>
    /// The inbound-swing queue, created on first use because it needs the
    /// session's cancellation token. One per process: the bound is a bound on
    /// pending native calls, and they all contend on the same pipe gate.
    /// </summary>
    private SwingInbox EnsureSwingInbox(CancellationToken ct)
    {
        lock (_swingInboxGate)
        {
            if (_swingInbox is not null) return _swingInbox;
            var inbox = new SwingInbox(
                resolveEntityId:   g => _ghostEntityIds.TryGetValue(g, out uint id) ? id : null,
                currentGeneration: GhostGeneration,
                apply:             (id, spec, c) => _combat.GhostSwingForResultAsync(id, spec, c),
                log:               Console.WriteLine);
            inbox.OnOutcome = o =>
            {
                if (o.Ok) { _stats.SwingsQueued++; return; }
                _stats.SwingsFailed++;
                // An EXPIRED swing must not fall back: the body it described is
                // gone, and playing a cue on the body that replaced it is the
                // wrong animation on the wrong character. Everything else --
                // the DLL absent, the fragment missing on this build, the
                // engine refusing -- still gets the old Lua cue, late but
                // visible, which is what it has always done.
                if (o.Reason == PipeReason.Expired) return;
                Console.WriteLine($"[combatviz] native swing for ghost {o.Entry.GhostId} did not apply " +
                                  $"(reason={new PipeResult(false, o.Reason).ReasonTag}) -- falling back to the Lua cue");
                _ = ExecLuaAsync($"if KCD2MP_GhostCombat then KCD2MP_GhostCombat(\"{o.Entry.GhostId}\",{Protocol.CombatEventSwing}) end");
            };
            inbox.Start();
            _swingInbox = inbox;
            return inbox;
        }
    }

    // WO-46: the one fragment row native ghost swings play, verbatim from the
    // shipped combat_action_attack.xml (WO-43 pulled it; WO-45 live-verified
    // it renders a full swing). Longsword-tagged because the armed ghost
    // loadout is the longsword preset; a ghost without a drawn weapon renders
    // nothing on this row (also live-verified), which is the correct visual
    // for a peer whose weapon state says sheathed anyway.
    // WO-47: now the fallback -- used when the shipped-table catalog below
    // failed to load or has nothing for the ghost's synced weapon.
    private const string NativeSwingFragmentSpec =
        "FreeAttack, l_longsword+r_longsword+freeGuard+endFreeGuard+slash+attack_heavy";

    // WO-47: per-weapon-class swing rows read from the installed game's own
    // Tables.pak, so a ghost holding the peer's real synced weapon swings with
    // that weapon's real animations instead of always the longsword row.
    // Loaded off the hot path; null (load failed) keeps the WO-46 constant.
    private readonly Task<WeaponSwingCatalog?> _swingCatalog =
        Task.Run(() => WeaponSwingCatalog.TryLoad(Console.WriteLine));

    // WO-47: per-ghost swing counter -- rotates through the several real rows
    // a weapon class ships (slash/stab), so consecutive swings vary.
    private readonly ConcurrentDictionary<byte, int> _ghostSwingIndex = new();

    // WO-49: npcName → local entity id of this world's copy of a puppeted
    // NPC, from the mod's puppet-start "npcid" event (same tostring-hex idiom
    // as _ghostEntityIds). What the native NPC-swing path addresses the local
    // copy by. Same staleness policy as ghosts: a save reload mints new
    // entity ids, the next puppet start re-reports, and a stale id in the
    // window between fails cleanly in the DLL (falls back to the Lua cue).
    private readonly ConcurrentDictionary<string, uint> _npcEntityIds = new();

    // WO-104 Phase 1: replica body name -> the world NPC it stands in for,
    // from the mod's "npc_replica <npc> <replica|->" event. A contested
    // puppet under mp_npc_replica_on is driven through a brainless
    // soul-bound body named kcd2mp_r_<npc> while the real NPC is hidden in
    // place. The DLL's hit sensor reports the struck body's own soul, which
    // REST resolves to the replica's name -- a name the owner cannot
    // resolve and one this agent would otherwise drop as a ghost body
    // (kcd2mp_ prefix). This map turns it back into the NPC's name before
    // the outbound-damage guard and the send. Inbound damage needs nothing:
    // the NPC keeps its name, so 0x31 still lands on the canonical copy.
    private readonly ConcurrentDictionary<string, string> _npcReplicaOrig = new();

    // WO-49: npcName → the LOCAL copy's own equipped item classes, read over
    // the same SoulsByName REST surface the ghost appearance layer uses
    // (proven for spawned souls in WO-10/47; whether world NPCs resolve by
    // entity name is probed live -- an empty read degrades to the WO-46
    // longsword constant, never blocks the swing). Refreshed on each
    // sheathed→drawn transition in the incoming stream.
    private readonly ConcurrentDictionary<string, Guid[]> _npcEquipped = new();
    private readonly ConcurrentDictionary<string, int> _npcSwingIndex = new();
    private readonly ConcurrentDictionary<string, bool> _npcLastDrawn = new();

    // WO-86: NPC death sync. _npcLastDead is the dead bit of the last 0x27
    // packet seen per NPC name (so a 0->1 transition can be told from a body
    // that was already dead on its first packet -- a late-join corpse, which
    // must only freeze, never kill). _npcDeathAppliedUtc dedupes the two
    // inbound death routes (0x31 FATAL and a witnessed 0x27 dead transition)
    // per name; ApplyDeath is idempotent in the DLL anyway, this only saves
    // the REST lookup and keeps the log to one line per death.
    private readonly ConcurrentDictionary<string, bool> _npcLastDead = new();
    private readonly ConcurrentDictionary<string, DateTime> _npcDeathAppliedUtc = new();
    private static readonly TimeSpan NpcDeathDedupeWindow = TimeSpan.FromSeconds(60);
    // Mirror of the mod's mp_npc_deathsync toggle (default on), kept in step
    // by the npc_deathsync event line -- the agent cannot read Lua state back.
    private volatile bool _npcDeathSyncEnabled = true;

    // WO-102 Phase 0: the toggle set. Both start from ClientConfig and flip at
    // runtime from the console (mp_authority_host_on|off, mp_pos_native_on|off)
    // via the wo102_toggle event; the mod mirrors the same two flags. With
    // both false this agent is byte-for-byte 0.23.2 on the wire.
    private volatile bool _hostAuthority = config.HostAuthorityEnabled;
    private volatile bool _posNative     = config.NativePositionEnabled;

    // WO-102 Phase 1: the native position path's own state. Both cadences are
    // measured every tick whatever the toggle says (the log path is free to
    // measure: a seq change is a fresh line), so a session with the native
    // path on yields both distributions on one machine.
    private readonly CadenceStats _cadLog = new(), _cadNative = new();
    private long _lastLogSeq = -1;
    private ulong _lastNativeFrame;
    private LocalState? _lastNative;
    private int _posNativeMisses;
    private bool _posNativeGaveUp;                 // 20 consecutive refusals: DLL too old / hop unmapped
    private bool _posNativeRefusedByOracle;        // the known-answer check failed: native disagrees with the log line
    private int _oracleBadRun;
    private long _oracleN; private double _oracleSum, _oracleMax;
    private const int    PosNativeGiveUpAfter = 20;
    private const double OracleMaxM = 3.0;         // log sample may lag the frame by ~60 ms+; a horse covers ~0.7 m in that
    private const int    OracleBadRunToRefuse = 20;
    private static readonly TimeSpan CadenceReportInterval = TimeSpan.FromSeconds(30);

    // WO-102.5 Phase 2: the native NPC scan's own state. Same give-up
    // discipline as pos-native (PosNativeGiveUpAfter above): a run of
    // consecutive refusals means an older DLL or an unmapped gEnv hop, not a
    // transient hiccup, so the path disarms itself for the session rather
    // than retrying forever.
    private volatile bool _npcScanNative = config.NpcScanNativeEnabled;
    private int  _npcScanMisses;
    private bool _npcScanGaveUp;
    private const int PosNpcScanGiveUpAfter = 20;
    private static readonly TimeSpan NpcScanInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan NpcScanGhostStaleAfter = TimeSpan.FromSeconds(5);   // an anchor this old is dropped, not used
    // WO-102.5 Phase 3: the mod's authority radius is runtime-adjustable
    // (#KCD2MP_SetAuthorityRadius) and Lua-owned -- the mod announces a
    // change on the event channel ("authority_radius") because this agent
    // cannot read KCD2MP.wo1025 back, mirrored the same way _hostAuthority
    // etc. mirror the wo102_toggle events. Starts at the mod's own default
    // -- WO-103 Phase 1 raised this to 300 m (the maintainer's original
    // target) and removed the upper clamp; the live runbook at 45/90/150m
    // (WO-102.5 findings S6.3) held zero violations and culling kept 150m's
    // streaming cost to 22-of-78, so the two agree before any change.
    private volatile float _npcScanRadiusM = 300.0f;
    // WO-110 R3 (docs/WO-109-audit.md R3). Until 0.26.4 this was a constant
    // 40, applied in the DLL's iterator order, and the comment here claimed
    // the rest "fall back to the live Lua read". They did not: under host
    // authority mp_npc_rescan tracks ONLY pushed names and untracks
    // everything else, so the owner owned at most the first 40 NPCs the
    // engine happened to walk, not the nearest -- roughly half the NPCs
    // inside the streaming radius were never streamed or paused.
    //
    // Now: entries are sorted by distance to the nearest anchor BEFORE the
    // cap, the push is chunked into several KCD2MP_ApplyNativeScan(csv, gen,
    // idx, total) statements (each under ~3 KB, so the cap is no longer
    // forced by HttpGameTransport.MaxBatchChars), and the cap is a runtime
    // setting: mp_npc_track_max <n> in the mod, mirrored here through the
    // npc_track_max event exactly like authority_radius. Default 200: the
    // largest NPC/NPC_Female/Horse count observed inside 150 m of a dense
    // town spot was 76 (WO-109 s4.3) and the 60 m streaming radius holds
    // 45-48, so with distance ordering the STREAMING RADIUS decides
    // coverage, not this number; 200 is also the lower end of the native
    // reply's own byte ceiling (kMaxReplyBytes=8000, ~200-400 entries), and
    // the owner's per-tick state reads cost ~1.5 ms per 100 ms at 78 tracked
    // (WO-103 s5.1), i.e. ~4 ms at 200 -- affordable. mp_preset_legacy sets
    // 40 (the 0.26.4 value; the ordering fix is unconditional).
    private const int    NpcTrackMaxDefault = 200;
    private const int    NpcTrackMaxFloor = 10, NpcTrackMaxCeiling = 400;
    private const int    NpcScanChunkChars = 3000;
    private volatile int _npcTrackMax = NpcTrackMaxDefault;
    private uint _npcScanGen;
    private bool _npcScanSkipLogged;   // WO-110 R13: one line per skip/resume transition
    private long _npcScanPushes, _npcScanTruncatedWire, _npcScanNamesTruncated;
    private bool _npcScanWasReplyTruncated;   // WO-103 Phase 1: edge-triggered loud log, mirrors npc_scan.cpp's g_wasTruncated

    // WO-102 Phase 5: the request channel. _npcTarget is the nearest owned
    // puppet the mod reports us facing (npc_target event); a COMMIT edge at it
    // becomes an NpcRequest action. The owner correlates each inbound request
    // with the 0x30 damage that follows from the same sender for the same
    // name; the requester correlates its own outbound request with the hit it
    // then sends. Both sides print MP-REQUEST; nothing else acts on it yet.
    private volatile string? _npcTarget;
    private readonly Dictionary<(byte From, string Npc), DateTime> _requestsIn = new();
    private readonly Dictionary<string, DateTime> _requestsOut = new();
    private readonly Dictionary<string, DateTime> _ownedNpcSeenUtc = new();   // names this authority streamed recently
    private long _reqOut, _reqOutResolved, _reqIn, _reqInResolved, _reqInUnresolved, _reqInRefused, _reqOutUnresolved;
    private static readonly TimeSpan RequestResolveWindow = TimeSpan.FromMilliseconds(1500);

    // WO-102 Phase 6: NPC resync. The owner bursts (ordinary NpcStateUp with
    // the RESYNC bit) on the events that already resync world time; a
    // non-owner asks for one over the action channel. Rate-limited so a
    // sleep that both machines notice costs one burst, not two.
    private DateTime _lastResyncBurstUtc = DateTime.MinValue;
    private volatile NetworkStream? _resyncStream;
    private static readonly TimeSpan ResyncBurstMinGap = TimeSpan.FromSeconds(5);
    private long _resyncOut, _resyncBursts, _resyncEmitted, _resyncInPackets, _resyncDeadApplied, _resyncSkipped, _resyncInRequests, _resyncInRefused;
    private static readonly TimeSpan OwnedNpcRecent = TimeSpan.FromSeconds(10);
    private static double NowMs() => Stopwatch.GetTimestamp() * 1000.0 / Stopwatch.Frequency;

    // ghostId → release version, from ReleaseVersion packets (WO-19). Empty
    // for a peer whose Handshake carried none (an old build). Read by
    // VersionIpcServer so the launcher can compare it against this agent's
    // own ReleaseVersionInfo.Current without the wire protocol itself caring.
    private readonly ConcurrentDictionary<byte, string> _ghostReleaseVersions = new();

    // WO-50: one instance for the whole agent process, surviving reconnects —
    // see RunAsync. Null-safe throughout: Discord not running degrades to no
    // presence shown, never to a crash.
    private DiscordPresence? _discordPresence;

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
    // WO-58: item classes a ghost has proven it will never equip -- a full
    // verify-and-retry schedule ran and the final read still lacked them.
    // Without this, the failed class is dropped from `applied`, the next
    // appearance heartbeat re-diffs it right back in, and the cycle repeats
    // forever: the 2026-08-25 session shows the same 9 classes 404-ing
    // through equip retries every ~30 s on BOTH machines for the entire
    // session -- constant REST traffic into the game's main thread for
    // items that will never take. One failed schedule is the retry budget.
    //
    // WO-59: entries now carry an expiry (value = UTC time the entry stops
    // suppressing) instead of living for the whole ghost lifetime. A
    // lifetime blacklist turned any transient failure -- game busy at the
    // 800 ms REST timeout, a menu open, a slot exclusivity that resolves
    // when the peer changes outfit again -- into "this player's clothing
    // never updates again until reconnect", which is exactly the shape of
    // the one-way clothing reports. Ten minutes keeps ~95% of WO-58's
    // churn reduction (one 10 s retry cycle per item per 10 min instead of
    // one every 30 s) while letting legitimate changes heal.
    private readonly ConcurrentDictionary<byte, Dictionary<Guid, DateTime>> _ghostNeverEquips = new();

    /// <summary>How long one exhausted verify schedule suppresses an item class for a ghost.</summary>
    private static readonly TimeSpan NeverEquipTtl = TimeSpan.FromMinutes(10);

    // WO-59: one-shot log latch for the local equipped-set read failing
    // (see AppearanceLoopAsync) -- a busy game times out for minutes and a
    // per-poll line would flood the agent log.
    private bool _appearanceReadDown;

    // Set by the "appearance_sync" game event (mp_sync_appearance console
    // command) to force the next poll to send unconditionally, bypassing the
    // change check -- the honest floor for a tester who does not want to wait
    // for the poll interval or the heartbeat.
    private volatile bool _forceAppearanceResync;

    // WO-17 reactive aggro. Set by the "aggro_toggle" game event
    // (mp_enable_aggro console command) -- the mod's own runtime trigger for
    // rttr::set_ghost_faction_hostile, replacing WO-16's hand-written
    // kcdmp-faction.txt research file. Off by default: every connected ghost
    // keeps today's exact behaviour unless a player explicitly opts in on
    // their own client.
    private bool _aggroEnabled;

    // WO-68: mirrors the mod's KCD2MP.ghostIsolate, which defaults to ON, so
    // this defaults to ON too -- a client that never sees an "isolate" event
    // (mod older than this build, or the toggle simply never touched) still
    // isolates, which is the shipped default on both sides. The Lua half owns
    // the switch; this is only the native half's copy of it.
    private bool _ghostIsolate = true;

    // A ghost's own Soul.Guid, read once via the debug REST API and cached
    // for its lifetime -- it does not change, and re-reading it on every
    // damage event would add a round trip to the hot path. Invalidated on
    // Disconnect alongside the other per-ghost caches.
    private readonly ConcurrentDictionary<byte, Guid> _ghostSoulGuidCache = new();

    // How long a ghost stays attached to the hostile faction after the most
    // recent combat event involving it, before the sweep in the main tick
    // loop detaches it back to normal. Refreshed on every qualifying event,
    // so a sustained fight keeps it attached continuously rather than
    // flapping attach/detach every few seconds.
    private static readonly TimeSpan AggroHoldDuration = TimeSpan.FromSeconds(20);
    private readonly ConcurrentDictionary<byte, DateTime> _ghostHostileUntilUtc = new();

    // The only channel to KCDMP_launcher's dice window -- see DiceIpcServer.
    private DiceIpcServer? _diceIpcServer;

    // WO-19. The launcher's channel to this agent's release-version state --
    // there is no other one (WO-6 deleted the only prior launcher<->agent
    // link; DiceIpcServer above survives strictly as a headless test surface,
    // deliberately unwired on the launcher side, see its own doc comment). A
    // second small HttpListener rather than repurposing DiceIpcServer, so that
    // one keeps meaning exactly what its comment says.
    private VersionIpcServer? _versionIpcServer;

    // Local menu state (WO-11 detection, WO-13 semantics). Two independent
    // sources OR'd into one reported state -- automatic detection (the tail
    // transport's PauseStateChanged, log-marker driven) and the manual
    // mp_slow_time override, so either alone is enough to report "in a menu",
    // and only a transition of the OR'd result sends a packet.
    //
    // There is deliberately no remote-side state here any more. WO-11 tracked
    // which peers were paused so it could slow this client's own t_scale;
    // WO-13 retired that outright -- see ApplyPeerPauseAsync.
    private bool _localAutoPaused;
    private bool _localManualPaused;
    private bool? _lastSentPauseState;
    private readonly SemaphoreSlim _pauseSendLock = new(1, 1);

    // WO-13 Phase 1. Script.SetTimer is frozen for the whole duration of a
    // local menu (WO-12 s0.3), which stops KCD2MP_InterpTick and leaves every
    // other player's ghost standing still on this player's own screen. While
    // the local menu state is active this pumps the tick in from outside,
    // which keeps working because ExecuteString-driven Lua still executes
    // with a menu open (WO-12 s0.4).
    private CancellationTokenSource? _interpPumpCts;
    private readonly object _interpPumpLock = new();

    // ---- Time-skip sync (WO-38 Phase 1) ----

    // Local skip state, driven by the tail transport's SkipTimeStateChanged
    // (the AfterSkipTime marker edges). Log-tail only, like pause detection:
    // under HttpGameTransport the event never fires and only the clock-jump
    // watcher below still contributes.
    private bool _localSkipActive;

    // WO-39 Phase 8: latest BedTrigger-proximity report from the mod's 1 Hz
    // poll ("bed_near" event line). Read at skip start to pick sleep vs wait.
    private volatile bool _nearBed;

    // Set when our own skip's end marker fires: the next time_now event from
    // the mod carries the resulting clock and becomes our TimeSkipUp(done).
    private bool _awaitSkipDoneTime;
    private byte _localSkipKind = Protocol.TimeSkipKindUnknown;

    // A peer's skip that resolved while our own was still resolving. Applied
    // once our own skip ends (SetWorldTime mid-skip is untested); only the
    // highest target is kept -- applying is forward-only anyway.
    private (byte SourceId, byte Kind, uint WorldTime, bool Quiet)? _pendingTimeSkip;
    private readonly object _timeSkipLock = new();

    // Clock-jump watcher: the fallback detector for time advances that emit
    // no AfterSkipTime marker (fast travel's sped-up clock was never
    // confirmed to). The mod reports Calendar.GetWorldTime() on a slow
    // cadence; a jump far beyond what the elapsed real time can explain is a
    // skip in effect. A jump is only reported once its rate settles back to
    // normal, so one fast travel is one packet, not one per poll.
    private uint? _lastPolledWorldTime;
    private DateTime _lastPollUtc;
    private bool _fastAdvanceActive;
    private uint _fastAdvanceStartTime;
    private DateTime _suppressJumpUntilUtc = DateTime.MinValue;

    // WO-40 Phase 4: reload detection. A save load is the fourth clock-change
    // trigger, and the only backward one -- the 2026-08-18 session captured a
    // reload leaving PA ~24.5 game-hours behind PB with nothing ever
    // converging (backward writes are engine-ignored, so PB could never
    // apply PA's post-reload broadcast). Convergence is therefore forward and
    // ours: on a detected backward jump, this client fast-forwards ITSELF to
    // the best-known session clock. Solo reloads are left alone.
    private readonly ConcurrentDictionary<byte, DateTime> _peerLastSeenUtc = new();
    private uint _peerWorldTime;               // last clock any peer reported (TimeSkipDown)
    private DateTime _peerWorldTimeUtc = DateTime.MinValue;

    // WO-90 story progress. The mod had no notion of where either player was
    // in the campaign; these three fields are all of it. _localObjective is
    // the last quest+objective key this client crossed, _peerObjective is the
    // same per peer, and _storyDivergenceTold stops the same "you are at
    // different points" line being repeated for an unchanged pair. Reporting
    // only -- nothing in this class gates on them, deliberately (the marker
    // is a checkpoint-coarse clock; see StoryBeat's class notes).
    //
    // WO-96 amends the last sentence: the divergence signal now DOES gate one
    // thing -- the Shared Quests readiness prompt / WAITING_FOR_PEER status in
    // the mod (SendQuestDivergence). It still gates no NPC, movement or input
    // behaviour, and the mod side is informational plus an opt-in F11.
    private string? _localObjective;
    private readonly ConcurrentDictionary<byte, string> _peerObjective = new();
    private readonly ConcurrentDictionary<byte, string> _storyDivergenceTold = new();
    // WO-96: the last marker this client and each peer were BOTH on. When the
    // pair then differs, whichever side still sits on it is the one behind --
    // the markers themselves carry no order, so this is the only ordering the
    // agent can give without a registry. Reset on convergence to the new
    // shared marker; absent for a peer that has never agreed with us.
    private readonly ConcurrentDictionary<byte, string> _lastSharedObjective = new();
    private Func<byte, string, Task>? _sendStoryBeat;

    // WO-96 Phase 2: story fingerprints. After each own marker the engine has
    // just written an autosave; the agent finds it, reads the ConceptState
    // tree and sends the current quest's objective states (kind 5). A peer's
    // fingerprint is compared against OUR newest save's states for THAT quest
    // -- the save holds every started quest -- and the objective-level gap is
    // told to the mod. Read-only throughout; nothing writes a save or a node.
    private string? _savesRoot;                                        // <user folder>\saves
    private string? _latestSavePath;                                   // newest save this agent has parsed
    private DateTime _latestSaveWriteUtc = DateTime.MinValue;
    private System.Xml.XmlDocument? _latestConcept;                    // its ConceptState tree
    private readonly object _saveLock = new();
    private readonly ConcurrentDictionary<byte, string> _peerFingerprint = new();   // ghostId -> last kind-5 text
    private readonly ConcurrentDictionary<byte, string> _peerGapTold = new();       // ghostId -> last gap key told to the mod
    private readonly ConcurrentDictionary<byte, bool> _peerRegistryMismatchTold = new();
    private int _fingerprintSeq;

    // WO-94 Shared Quests. The agent is a relay between the mod's proximity
    // detector and the peer's prompt; the decisions that matter (is this a
    // registered beat, fire or not) are the mod's and the player's. What the
    // agent adds: "do the two objectives differ" (only it knows both), the
    // level and quest pushes, and the hazard tags on its own log lines.
    private string? _localLevel;                       // lowercase, from "Loading level"
    private string? _localQuest;                       // lowercase quest from our marker (null = side content / unknown)
    private readonly ConcurrentDictionary<byte, string> _peerApproach = new();   // ghostId -> last approach path
    private readonly ConcurrentDictionary<byte, (float X, float Y, float Z, DateTime AtUtc)> _ghostLastPos = new();
    private readonly ConcurrentDictionary<byte, (string Beat, DateTime AtUtc)> _peerCatchup = new();
    private (string Beat, DateTime AtUtc)? _localCatchup;

    // WO-98 Phase 5: cutscene state -- ours (from the tail's CutsceneEdge) and
    // each peer's (StoryBeat kind 6). Logged as MP-CUTSCENE on both sides with
    // the other side's state; handed to the mod so the readiness prompt is
    // held while a cutscene plays. Nothing is gated or aligned on it yet.
    private bool _localCutsceneActive;
    private string _localCutsceneName = "";
    private readonly ConcurrentDictionary<byte, (bool Active, string Type, string Name)> _peerCutscene = new();

    // WO-98 Phase 7: standing divergences are re-pushed to the mod when its
    // Lua was reborn (MOD INIT seen by the tail) or on a slow heartbeat --
    // not on every 2.5 s re-arm, which produced ~50 identical
    // QUEST-DIVERGENCE lines per side in the 2026-09-15 logs.
    private volatile bool _questRepushDue;
    private static readonly TimeSpan QuestRepushHeartbeat = TimeSpan.FromSeconds(60);
    // WO-99 Phase 4: MP-SUMMARY only ever printed on a clean disconnect, and
    // 2026-09-16 ended with both agents killed under the launcher (last lines
    // are pings). A periodic snapshot makes the block exist however the
    // session ends; counters are cumulative, so the last one is the summary.
    private static readonly TimeSpan SummaryHeartbeat = TimeSpan.FromSeconds(300);

    // WO-98 Phase 6: per-connection counters behind the MP-SUMMARY block and
    // the MP-GHOSTPKT aggregate. KCDMP_LOG_LEVEL=verbose adds a raw
    // MP-GHOSTPKT line per packet (the smoothing work's tuning data);
    // the default is the 10 s aggregate only.
    private SessionCounters _stats = new();
    private static readonly bool VerboseLog =
        string.Equals(Environment.GetEnvironmentVariable("KCDMP_LOG_LEVEL"), "verbose", StringComparison.OrdinalIgnoreCase);

    private sealed class SessionCounters
    {
        public long Pongs, SwingsSent, SwingsRecv, SwingsQueued, SwingsFailed, SwingsNoEntity,
                    DmgOut, DmgOutFatal, DmgIn, DmgInApplied, DmgInFailed, DmgOutDropped, DmgInRefused,
                    NpcStateOut, NpcClaimOut, NpcDragOut, StoryDivergencesPushed,
                    CutsceneLocalEdges, CutscenePeerEdges, GhostPackets, PosStaleOut, GhostStaleIn;
        public double RttMin = double.PositiveInfinity, RttMax, RttSum;
        public readonly long StartedTs = Stopwatch.GetTimestamp();
        public readonly long StartedLines = TeeTextWriter.LinesWritten;

        private sealed class GhostAgg
        {
            public long N, Snaps, WinN, WinSnaps, LastTs, WinStartTs, Stale, WinStale;
            public double IaSum, IaMax, DSum, DMax, WinIaSum, WinIaMax, WinDSum, WinDMax;
            public float X, Y, Z;
            // WO-100.5 Phase 2: the continuous body-state channel, per peer.
            public long BodyN;
            public BodyState LastBody;
            public bool HaveBody;
            public long PaceChanges, DirChanges, StanceChanges;
        }

        /// <summary>WO-100.5: peers that set the BODYSTATE flag but sent a short packet. Should be 0.</summary>
        public long BodyStateShortPackets;
        private readonly object _g = new();
        private readonly Dictionary<byte, GhostAgg> _ghosts = new();

        public void OnPong(int ms)
        {
            lock (_g) { Pongs++; RttSum += ms; if (ms < RttMin) RttMin = ms; if (ms > RttMax) RttMax = ms; }
        }

        /// <summary>One inbound Ghost packet: inter-arrival and position delta, windowed per 10 s.</summary>
        public string? OnGhostPacket(byte id, float x, float y, float z, bool stale, out string? raw)
        {
            long now = Stopwatch.GetTimestamp();
            raw = null;
            lock (_g)
            {
                GhostPackets++;
                if (stale) GhostStaleIn++;
                if (!_ghosts.TryGetValue(id, out var g))
                {
                    _ghosts[id] = new GhostAgg { LastTs = now, WinStartTs = now, X = x, Y = y, Z = z };
                    return null;
                }
                double ia = (now - g.LastTs) * 1000.0 / Stopwatch.Frequency;
                double d = Math.Sqrt((x - g.X) * (x - g.X) + (y - g.Y) * (y - g.Y) + (z - g.Z) * (z - g.Z));
                g.LastTs = now; g.X = x; g.Y = y; g.Z = z;
                g.N++; g.IaSum += ia; if (ia > g.IaMax) g.IaMax = ia; g.DSum += d; if (d > g.DMax) g.DMax = d; if (d > 5.0) g.Snaps++;
                g.WinN++; g.WinIaSum += ia; if (ia > g.WinIaMax) g.WinIaMax = ia; g.WinDSum += d; if (d > g.WinDMax) g.WinDMax = d; if (d > 5.0) g.WinSnaps++;
                if (stale) { g.Stale++; g.WinStale++; }
                if (VerboseLog)
                    raw = FormattableString.Invariant($"MP-GHOSTPKT-RAW ghost={id} ia_ms={ia:F1} d_m={d:F3} snap={(d > 5.0 ? 1 : 0)} stale={(stale ? 1 : 0)}");
                if (now - g.WinStartTs < Stopwatch.Frequency * 10) return null;
                string line = FormattableString.Invariant(
                    $"MP-GHOSTPKT ghost={id} n={g.WinN} ia_mean_ms={g.WinIaSum / g.WinN:F1} ia_max_ms={g.WinIaMax:F1} d_mean_m={g.WinDSum / g.WinN:F2} d_max_m={g.WinDMax:F2} snaps={g.WinSnaps} stale={g.WinStale}");
                g.WinN = 0; g.WinSnaps = 0; g.WinIaSum = 0; g.WinIaMax = 0; g.WinDSum = 0; g.WinDMax = 0; g.WinStale = 0; g.WinStartTs = now;
                return line;
            }
        }

        /// <summary>
        /// WO-100.5 Phase 2: one inbound body-state reading. Counts transitions
        /// rather than samples, because the tags are stable continuous state
        /// (WO-100 S10.2) -- "how many times did the pace change" is the
        /// interesting number and "how many packets carried a pace" is not.
        /// </summary>
        public void OnBodyState(byte id, BodyState b)
        {
            lock (_g)
            {
                if (!_ghosts.TryGetValue(id, out var g)) { _ghosts[id] = g = new GhostAgg(); }
                g.BodyN++;
                if (g.HaveBody)
                {
                    if (g.LastBody.Pace   != b.Pace)   g.PaceChanges++;
                    if (g.LastBody.Dir    != b.Dir)    g.DirChanges++;
                    if (g.LastBody.Stance != b.Stance) g.StanceChanges++;
                }
                g.LastBody = b; g.HaveBody = true;
            }
        }

        /// <summary>WO-100.5 Phase 2: the MP-ANIM summary lines.</summary>
        public IEnumerable<string> BodyStateSummaryLines()
        {
            lock (_g)
            {
                if (BodyStateShortPackets > 0)
                    yield return FormattableString.Invariant(
                        $"MP-ANIM section=inbound short_packets={BodyStateShortPackets}");
                foreach (var kv in _ghosts)
                {
                    var g = kv.Value;
                    if (g.BodyN == 0) continue;
                    yield return FormattableString.Invariant(
                        $"MP-ANIM section=ghost ghost={kv.Key} samples={g.BodyN} pace_changes={g.PaceChanges} dir_changes={g.DirChanges} stance_changes={g.StanceChanges} last_pace={g.LastBody.Pace} last_dir={g.LastBody.Dir} last_stance={g.LastBody.Stance} last_anim_speed={g.LastBody.AnimSpeed:F2}");
                }
            }
        }

        public IEnumerable<string> GhostSummaryLines()
        {
            lock (_g)
            {
                foreach (var kv in _ghosts)
                {
                    var g = kv.Value;
                    if (g.N == 0) continue;
                    yield return FormattableString.Invariant(
                        $"MP-SUMMARY section=ghost ghost={kv.Key} packets={g.N} ia_mean_ms={g.IaSum / g.N:F1} ia_max_ms={g.IaMax:F1} d_mean_m={g.DSum / g.N:F2} d_max_m={g.DMax:F2} snaps={g.Snaps} stale={g.Stale}");
                }
            }
        }
    }

    /// <summary>
    /// WO-98 Phase 6: the per-connection summary block, one structured line
    /// per channel, printed when the relay connection ends. Most of WO-98's
    /// analysis was counting things by hand; this is the mod counting them.
    /// </summary>
    private void PrintSessionSummary(string reason)
    {
        var s = _stats;
        double secs = Math.Max(0.001, (Stopwatch.GetTimestamp() - s.StartedTs) / (double)Stopwatch.Frequency);
        long lines = TeeTextWriter.LinesWritten - s.StartedLines;
        string off = _clockOffsetMs is double o ? o.ToString("F1", CultureInfo.InvariantCulture) : "?";
        string rttm = _clockRttMedianMs is double r ? r.ToString("F1", CultureInfo.InvariantCulture) : "?";
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=session reason={reason} duration_s={secs:F0} agent_lines={lines} agent_lines_per_s={lines / secs:F2} clock_offset_ms={off} clock_rtt_ms={rttm} clock_samples={_clockSampleCount}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=ping pongs={s.Pongs} rtt_min_ms={(s.Pongs > 0 ? s.RttMin : 0):F0} rtt_avg_ms={(s.Pongs > 0 ? s.RttSum / s.Pongs : 0):F1} rtt_max_ms={s.RttMax:F0}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=position stale_out={s.PosStaleOut} ghost_stale_in={s.GhostStaleIn}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=swings sent={s.SwingsSent} recv={s.SwingsRecv} queued={s.SwingsQueued} failed={s.SwingsFailed} no_entity={s.SwingsNoEntity}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=damage out={s.DmgOut} out_fatal={s.DmgOutFatal} out_dropped={s.DmgOutDropped} in={s.DmgIn} in_applied={s.DmgInApplied} in_failed={s.DmgInFailed} in_refused={s.DmgInRefused} authority={(_isDamageAuthority ? 1 : 0)}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=npc state_out={s.NpcStateOut} claim_out={s.NpcClaimOut} drag_out={s.NpcDragOut}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=wo102 authority_host={(_hostAuthority ? 1 : 0)} pos_native={(_posNative ? 1 : 0)} pos_native_gave_up={(_posNativeGaveUp ? 1 : 0)} pos_native_oracle_refused={(_posNativeRefusedByOracle ? 1 : 0)} native_reads={_combat.LocalStateReads} native_refused={_combat.LocalStateRefused} authority={(_isDamageAuthority ? 1 : 0)}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=wo1025 npc_scan_native={(_npcScanNative ? 1 : 0)} npc_scan_gave_up={(_npcScanGaveUp ? 1 : 0)} npc_scan_reads={_combat.NpcScanReads} npc_scan_refused={_combat.NpcScanRefused} npc_scan_pushes={_npcScanPushes} npc_scan_wire_truncated={_npcScanTruncatedWire} npc_scan_names_truncated={_npcScanNamesTruncated}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-REQUEST section=summary out={_reqOut} out_resolved={_reqOutResolved} out_unresolved={_reqOutUnresolved} in={_reqIn} in_resolved={_reqInResolved} in_unresolved={_reqInUnresolved} in_refused={_reqInRefused}"));
        Console.WriteLine(FormattableString.Invariant(
            $"MP-NPCRESYNC section=summary requests_out={_resyncOut} requests_in={_resyncInRequests} requests_refused={_resyncInRefused} bursts={_resyncBursts} emitted={_resyncEmitted} in_packets={_resyncInPackets} dead_applied={_resyncDeadApplied} skipped={_resyncSkipped}"));
        if (_cadLog.Summary("log") is string cl) Console.WriteLine(cl);
        if (_cadNative.Summary("native") is string cn) Console.WriteLine(cn);
        Console.WriteLine(FormattableString.Invariant(
            $"MP-SUMMARY section=story divergences_pushed={s.StoryDivergencesPushed} cutscene_local_edges={s.CutsceneLocalEdges} cutscene_peer_edges={s.CutscenePeerEdges} ghost_packets={s.GhostPackets}"));
        if (_swingInbox is { } inbox) Console.WriteLine(inbox.SummaryLine());
        foreach (var line in s.GhostSummaryLines()) Console.WriteLine(line);
        // WO-100.5 Phase 2: the MP-ANIM channel. Outbound first (did we read
        // anything at all), then per-peer inbound.
        Console.WriteLine(FormattableString.Invariant(
            $"MP-ANIM section=outbound reads={_combat.BodyStateReads} refused={_combat.BodyStateRefused} unknown_tags={_combat.BodyStateUnknownTags} disabled={(_bodyStateOff ? 1 : 0)}"));
        foreach (var line in s.BodyStateSummaryLines()) Console.WriteLine(line);
        Console.WriteLine(_actionIn.SummaryLine());
        Console.WriteLine(FormattableString.Invariant(
            $"MP-ACTION section=outbound sent={_actionOut.Sent} gen={_actionOut.Gen}"));
        _ = ExecLuaAsync($"if KCD2MP_LogSummary then KCD2MP_LogSummary(\"{reason}\") end");
    }

    private static bool IsPlainToken(string s)
    {
        if (s.Length == 0 || s.Length > 64) return false;
        foreach (char c in s) if (!(char.IsAsciiLetterOrDigit(c) || c == '_' || c == '-')) return false;
        return true;
    }

    /// <summary>WO-98 Phase 5: a Rendered/Ingame cutscene edge on this machine.</summary>
    private void OnLocalCutsceneEdge(bool active, string type, string name)
    {
        // WO-99 Phase 4: Fader/Text/SkipTime are logged (acted=0) and nothing
        // else -- no peer beat, no prompt hold. Only Rendered/Ingame act.
        bool acts = type is "Rendered" or "Ingame";
        string peers = string.Join(",", _peerCutscene.Select(kv => $"{kv.Key}:{(kv.Value.Active ? 1 : 0)}"));
        _stats.CutsceneLocalEdges++;
        if (!acts)
        {
            Console.WriteLine($"MP-CUTSCENE side=local state={(active ? "start" : "end")} type={type} name={name} peers={(peers.Length == 0 ? "-" : peers)} acted=0");
            return;
        }
        _localCutsceneActive = active;
        _localCutsceneName = active ? name : "";
        Console.WriteLine($"MP-CUTSCENE side=local state={(active ? "start" : "end")} type={type} name={name} peers={(peers.Length == 0 ? "-" : peers)} acted=1");
        string text = $"{(active ? "start" : "end")} {type} {name}";
        if (text.Length > Protocol.MaxStoryBeatTextLen) text = text[..Protocol.MaxStoryBeatTextLen];
        _ = _sendStoryBeat?.Invoke(Protocol.StoryBeatKindCutscene, text);
        _ = ExecLuaAsync($"if KCD2MP_SetCutscene then KCD2MP_SetCutscene({(active ? "true" : "false")}, \"{EscapeLua(name)}\") end");
    }

    /// <summary>WO-98 Phase 7: the mod's Lua was reborn; re-push standing state on the next re-arm.</summary>
    private void OnModInitDetected()
    {
        _questRepushDue = true;
        _dmgGuard.InvalidatePlayerGuid();          // WO-99 Phase 0
        _dmgGuardIdentityAtUtc = DateTime.MinValue;
        Console.WriteLine("[quest] mod Lua (re)initialised -- standing divergences will be re-pushed on the next re-arm");
    }
    private static readonly TimeSpan CatchupWindow = TimeSpan.FromSeconds(120);   // mirrors KCD2MP.quest.windowS

    /// <summary>
    /// WO-94: "" outside any catch-up window, else the distinct hazard tag
    /// naming the beat, who fired it (here or a peer) and how long ago.
    /// Appended to the agent's own death / clock / cutscene / teleport lines.
    /// </summary>
    private string CatchupTag()
    {
        var now = DateTime.UtcNow;
        if (_localCatchup is { } lc && now - lc.AtUtc < CatchupWindow)
            return StoryBeat.CatchupHazardTag(lc.Beat, "us", "here", now - lc.AtUtc);
        (string Beat, DateTime AtUtc)? best = null; byte bestId = 0;
        foreach (var kv in _peerCatchup)
            if (now - kv.Value.AtUtc < CatchupWindow && (best is null || kv.Value.AtUtc > best.Value.AtUtc)) { best = kv.Value; bestId = kv.Key; }
        if (best is null) return string.Empty;
        string who = _ghostNames.TryGetValue(bestId, out var n) ? n : $"player {bestId}";
        return StoryBeat.CatchupHazardTag(best.Value.Beat, who, "by a peer", now - best.Value.AtUtc);
    }

    // WO-88 finding 4: a reload convergence is no longer one fire-and-forget
    // ExecuteString. The target stays outstanding until a world-clock reading
    // proves the write landed (or the window closes), and every reading in
    // between re-sends it. Field instance: host reload #5 (2026-09-12
    // 17:16:13) logged "converging forward to session clock 584692" and no
    // ApplyTimeSkip ever appeared in kcd.log -- the batch flush met the
    // post-load REST outage and was dropped silently; the host then ran
    // 15,808 game-seconds behind until the joiner waited manually.
    private uint? _reloadConvergeTarget;
    private DateTime _reloadConvergeDeadlineUtc = DateTime.MinValue;
    private static readonly TimeSpan ReloadConvergeWindow = TimeSpan.FromSeconds(120);

    // WO-88 finding 4 (secondary): re-announce our clock to the session on a
    // slow cadence, not only at connect / new peer. Every receiver applies
    // forward-only and ignores a report within natural skew
    // (ReloadReconcile.QuietSyncWorthApplying), so this converges the session
    // onto one clock instead of each reloader chasing a stale private one.
    private static readonly TimeSpan TimeAnnounceInterval = TimeSpan.FromSeconds(60);

    // WO-88 finding 2: the outfit each peer last sent, kept so a respawned
    // ghost body (local save load -> RECONCILE -> fresh entity in its spawn
    // preset) can be dressed again immediately instead of waiting for a
    // heartbeat that diffs to nothing against the stale applied set.
    private readonly ConcurrentDictionary<byte, Guid[]> _ghostLastAppearance = new();
    /// <summary>Game-seconds per real second (WO-38 live: ratio 15, confirmed exactly).</summary>
    private const double WorldTimeRatio = 15.0;

    /// <summary>How often the mod is asked for the world clock.</summary>
    private static readonly TimeSpan TimePollInterval = TimeSpan.FromSeconds(10);

    /// <summary>
    /// How many game-seconds beyond the plausible natural advance between two
    /// polls counts as a jump. KCD2's default world-time ratio is ~15 (one
    /// real second is ~15 game seconds), so ~10 s of real time advances the
    /// clock ~150 s naturally; the allowance below is several times that.
    /// </summary>
    private const uint TimeJumpThresholdSeconds = 900;

    // Reassigned per connection, same idiom as _sendPauseIfChanged.
    private Func<byte, byte, uint, Task>? _sendTimeSkip;

    // WO-59: when true, the next world-time reading is also announced to the
    // session as a TimeSkipPhaseSync -- set at connect and whenever a new
    // peer's ghost first appears, so clocks converge without anyone sleeping.
    // Volatile: set from the receive loop, consumed on the position loop.
    private volatile bool _timeSyncPending;

    // ---- Horse identity (WO-38 Phase 5) ----
    // Carries one horse_info event line from the mod onto the wire as a
    // HorseInfoUp (0x2A). Reassigned per connection like _sendNpcState.
    private Func<string, Task>? _sendHorseInfo;

    // ---- Combat visibility (WO-39 Phase 1) ----
    // Carries one combat event line from the mod onto the wire as a
    // CombatEventUp (0x2C). Reassigned per connection like _sendHorseInfo.
    private Func<byte, ushort, Task>? _sendCombatEvent;   // WO-99 Phase 4: (event, sid)

    // ---- Per-entity NPC authority (WO-39 Phase 2) ----
    // Same wire packet as _sendNpcState but flagged as a claim emission, so
    // the agent's authority gate is skipped (a non-authority claims a body
    // by sending state for it; the relay arbitrates).
    private Func<string, float, float, float, float, float, byte, Task>? _sendNpcDrag;

    // WO-86: the mod's npc_death event line onto the wire as a zero-delta 0x30
    // with the FATAL bit. Reassigned per connection like _sendNpcState.
    private Func<string, Task>? _sendNpcDeath;

    // ---- Dropped-item sync (WO-48) ----
    // Both reassigned per connection like _sendCombatEvent. Drop takes the
    // prebuilt 0x32 payload because the heartbeat resends it verbatim.
    private Func<byte[], Task>? _sendItemDrop;
    private Func<uint, Task>? _sendItemClaim;

    // This agent's own still-unclaimed drops: dropId -> the exact 0x32
    // payload sent, re-broadcast every ItemDropHeartbeatSeconds so a late
    // joiner converges (the relay replays nothing; receivers dedupe by
    // dropId). An entry leaves on the drop's ItemClaimDown echo -- whoever
    // claimed it -- and the whole map clears on disconnect: dropIds are
    // minted per connection and a re-minted broadcast after reconnect would
    // duplicate the item on every peer that kept the old one.
    private readonly ConcurrentDictionary<uint, byte[]> _myOpenDrops = new();
    private static readonly TimeSpan ItemDropHeartbeatInterval = TimeSpan.FromSeconds(30);

    // Relay-assigned ghost id of THIS client, from the connect Ack. The
    // receive loop needs it to tell the mod whether an ItemClaimDown echo
    // means "you won" (claimer == us) or "you lost, roll back".
    private byte _myGhostId;

    // ---- Shared player combat (WO-28) ----

    // Flow A outbound: the last health/stamina actually put on the wire, plus
    // when. Both are needed because the send rule is "changed materially OR the
    // heartbeat is due" -- a peer who joins mid-session has missed every change
    // and would otherwise render no health at all until this player next gets
    // hit, exactly as for appearance.
    private float? _lastSentHealth, _lastSentStamina;
    private byte _lastSentVitalFlags;
    private DateTime _lastPlayerStateSentUtc = DateTime.MinValue;

    // Flow C: latched on the emitter reporting death, cleared when it reports
    // the player alive again (which is what a completed save reload looks like
    // from here). The latch is what makes PlayerDeathUp idempotent at the
    // source -- the emitter reports "dead" at ~50 Hz for as long as the death
    // screen is up, and every one of those must not be a packet.
    private bool _sentDeathForThisLife;

    // Rule 2. Set from a CombatRole (0x25) packet; false until the relay says
    // otherwise, so a client that was never told cannot assume it holds
    // authority. Mirrored into the mod (KCD2MP_SetHitSensor) so the sampling
    // cost is skipped as well as the send.
    private bool _isDamageAuthority;

    // WO-28 Phase 0. A save load destroys every ghost ENTITY in the world while
    // leaving KCD2MP.ghosts still holding a stale, non-nil Lua reference to it,
    // so KCD2MP_UpdateGhost's "spawn if missing" check never fires again and
    // the ghost stays permanently bodiless -- observed live: the nameplate kept
    // walking its path with nothing under it. Re-verified on the same slow
    // cadence as the interp re-arm; see the position loop.
    private static readonly TimeSpan ReconcileGhostsInterval = TimeSpan.FromSeconds(5);

    /// <summary>
    /// How often the position loop re-arms the mod's Script.SetTimer loops.
    /// </summary>
    private static readonly TimeSpan ReArmInterpInterval = TimeSpan.FromMilliseconds(2500);

    /// <summary>
    /// WO-59: how often the last position is re-sent even when the player has
    /// not moved (every 2 s). Positions were purely
    /// change-gated, which left a standing-still player unspawnable on any
    /// peer whose reload had just cleared the ghost row -- WO-38's
    /// "invisible after reload" candidate (a), now closed: Reconcile clears
    /// the stale row within 5 s and this heartbeat re-delivers the spawn
    /// trigger within 2 s more, moving or not. One 18-byte packet per 2 s
    /// of stillness is the whole cost.
    /// </summary>
    private static readonly TimeSpan PositionHeartbeatInterval = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan AggroSweepInterval = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan WeatherTickInterval = TimeSpan.FromSeconds(5);
    // Reassigned per connection, same idiom as _combat.OnLocalHit: closes
    // over that connection's stream, so callers that don't have it
    // themselves (OnGameEvent, the tail transport's own event thread) can
    // still trigger a send.
    private Func<Task>? _sendPauseIfChanged;

    // Same idiom for WO-28 Flow B: the mod reports a ghost health drop on the
    // log-tail event channel, which is read on the tail loop's own thread and
    // has no access to this connection's stream.
    private Func<byte, float, float, Task>? _sendPlayerHit;

    // NPC sync (WO-32): set per connection like _sendPlayerHit; carries one
    // npc_state event line from the mod onto the wire as an NpcStateUp (0x26).
    private Func<string, float, float, float, float, float, byte, Task>? _sendNpcState;
    private readonly Dictionary<string, ushort> _npcSeqOut = new();   // WO-110 R6: per-name outbound sequence

    // The only characters that appear in authored entity names. Enforced both
    // before sending (our own emitter should never produce anything else) and
    // before an inbound name is interpolated into a Lua call -- relay data must
    // not be able to inject Lua.
    private static readonly Regex NpcNamePattern = new("^[A-Za-z0-9_]+$", RegexOptions.Compiled);

    // ---- Name-addressed NPC damage (WO-40 Phase 5) ----
    // Per-save Soul.Guids are NOT stable across installs (2026-08-18 bundles:
    // 571/571 guard hits unresolvable on the peer, 176/176 choke hits fine),
    // so outbound hits translate guid -> soul name once (reflection REST,
    // cached) and travel as 0x30; receivers translate name -> THEIR local
    // guid once and apply through the existing pipe. Positive entries are
    // TTL'd (a save reload re-rolls per-save guids) and negatives briefly
    // (so a failing lookup is not hammered per hit).
    private readonly ConcurrentDictionary<Guid, (string? Name, DateTime At)> _soulNameByGuid = new();
    private readonly ConcurrentDictionary<string, (Guid? Guid, DateTime At)> _soulGuidByName = new();
    private static readonly TimeSpan SoulLookupPositiveTtl = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan SoulLookupNegativeTtl = TimeSpan.FromMinutes(1);

    // ---- Weather sync (WO-40 Phase 3) ----
    // The engine has a write (EnvironmentModule.BlendTimeOfDay) but no
    // current-profile read, so session weather is mod-arbitrated: the
    // damage-authority holder picks from this pool on a slow cadence,
    // applies locally, broadcasts; receivers apply on change. With no live
    // peers the arbiter stays silent and vanilla weather runs untouched.
    private Func<string, ushort, Task>? _sendWeather;
    private string? _sessionWeatherProfile;       // arbiter: current session pick
    private string? _lastAppliedWeatherProfile;   // receiver: change gate
    private DateTime _weatherNextRepickUtc = DateTime.MinValue;
    private DateTime _weatherNextHeartbeatUtc = DateTime.MinValue;
    private readonly Random _weatherRng = new();
    /// <summary>BlendTimeOfDay's duration argument for synced changes. Units are undocumented; Warhorse's own scripts pass 0/1. Tuned live if needed.</summary>
    private const ushort WeatherBlendSeconds = 30;
    // Weighted by repetition: clear skies common, storms rare. Names from the
    // shipped time_of_day_profile.xml; quest-specific rows deliberately absent.
    private static readonly string[] WeatherProfilePool =
    {
        "cloudless_sunny", "cloudless_sunny", "cloudless_sunny_B",
        "semicloudy_clear", "semicloudy_clear", "semicloudy_clear_B",
        "cloudy_no_rain", "cloudy_no_rain_B", "cloudy_no_rain_C",
        "summer_overcast", "summer_overcast_B",
        "cloudy_frequent_showers", "cloudy_frequent_showers_B",
        "foggy_drizzly_light", "foggy_drizzly",
        "foggy_storm",
    };
    private static readonly Regex WeatherNamePattern = new("^[A-Za-z0-9_]{1,48}$", RegexOptions.Compiled);

    public async Task RunAsync(CancellationToken ct = default)
    {
        var http = new HttpGameTransport(config.GameApiBase);
        await http.StartAsync(ct);
        _transport = http;

        // WO-50: created once for the process's whole lifetime (not per relay
        // connection) so a reconnect doesn't tear down and re-open the
        // Discord IPC pipe.
        _discordPresence = new DiscordPresence(config);

        try
        {
            await RunLoopAsync(http, ct);
        }
        finally
        {
            _discordPresence?.Dispose();
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

        // One retry before giving up (WO-13). Falling back to HTTP is not a
        // cosmetic downgrade: PauseStateChanged and GameEvent only exist on
        // this transport, so a spurious fallback silently disables the local
        // menu signal, the interp pump and the "[in menu]" ghost tag. Observed
        // live: the emitter-start call did not take effect on one startup
        // (the mod was loaded and healthy, and the identical call issued by
        // hand a moment later worked immediately), so the failure is real,
        // transient, and cheap to paper over. The batched send swallows its
        // own exceptions, so there is nothing to catch upstream -- retrying
        // the call is the only available remedy.
        if (tail.FramesReceived == 0 && !ct.IsCancellationRequested)
        {
            Console.WriteLine("[transport] no frames yet; re-issuing the emitter start");
            tail.ResetEmitterStart();
            try { await tail.StartAsync(ct); } catch { }
            deadline = DateTime.UtcNow.AddSeconds(3);
            while (tail.FramesReceived == 0 && DateTime.UtcNow < deadline && !ct.IsCancellationRequested)
                await Task.Delay(50, ct);
        }

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
            catch (ServerFullException ex)
            {
                // Fatal for this attempt (WO-76): looping every 3 s against a
                // relay that just said it is full only burns another pooled
                // id for nothing until someone else leaves.
                Console.WriteLine($"[!] {ex.Message}");
                break;
            }
            catch (ReleaseVersionMismatchException ex)
            {
                // WO-110 R9: fatal, same as the protocol byte -- the relay
                // will refuse this build every time.
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

    // WO-50: same "seen within 2 minutes" liveness window this file's own
    // hasLivePeers checks already use — reused here rather than invented, so
    // a peer who silently vanished (crash, alt-F4, no Disconnect packet ever
    // arriving) ages out of the presence text on the same schedule it
    // already ages out everywhere else in this class.
    private void RefreshDiscordPeerCount()
    {
        var now = DateTime.UtcNow;
        int count = _peerLastSeenUtc.Count(kv => (now - kv.Value) < TimeSpan.FromMinutes(2));
        _discordPresence?.SetPeerCount(count);
    }

    private async Task ConnectAndRunAsync(CancellationToken appCt = default)
    {
        using var tcp = new TcpClient();
        tcp.NoDelay = true;   // WO-110 R6: no Nagle on the 40-byte NPC frames (the relay sets it on its accepted sockets too)

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

        // WO-19: trailing release-version field, appended after the name.
        // Optional and unlengthed on purpose -- see Protocol.cs's release
        // version layer doc -- so an old relay that only reads
        // [version][nameLen][name] is unaffected by these extra bytes.
        var releaseVersionBytes = Encoding.UTF8.GetBytes(ReleaseVersionInfo.Current);
        int handshakePayloadLen = 2 + nameBytes.Length + releaseVersionBytes.Length;
        var handshake = new byte[3 + handshakePayloadLen];
        handshake[0] = Protocol.Handshake;
        BinaryPrimitives.WriteUInt16LittleEndian(handshake.AsSpan(1), (ushort)handshakePayloadLen);
        handshake[3] = Protocol.Version;
        handshake[4] = (byte)nameBytes.Length;
        nameBytes.CopyTo(handshake, 5);
        releaseVersionBytes.CopyTo(handshake, 5 + nameBytes.Length);
        await stream.WriteAsync(handshake);

        // --- Ack (S→C 0xFF [id:1]) or a rejection: 0x09 [serverVersion:1],
        // 0x36 [maxPlayers:1], or 0x3D [relayRelease:UTF-8] (WO-110 R9). The
        // first three are 4 bytes; 0x3D is variable, so the header is read
        // first and the payload sized from it.
        var replyHeader = new byte[3];
        await ReadExactAsync(stream, replyHeader);
        int replyLen = BinaryPrimitives.ReadUInt16LittleEndian(replyHeader.AsSpan(1));
        var replyBody = new byte[replyLen];
        if (replyLen > 0) await ReadExactAsync(stream, replyBody);

        if (replyHeader[0] == Protocol.VersionMismatch && replyLen >= 1)
            throw new ProtocolVersionMismatchException(replyBody[0]);

        if (replyHeader[0] == Protocol.ServerFull && replyLen >= 1)
            throw new ServerFullException(replyBody[0]);

        if (replyHeader[0] == Protocol.ReleaseVersionMismatch)
        {
            string relayRelease = Encoding.UTF8.GetString(replyBody);
            // Into the game too: the player sees why nothing connects.
            try { await ExecLuaAsync($"if KCD2MP_ShowNativeToast then KCD2MP_ShowNativeToast(\"KCD2-MP: relay runs {EscapeLua(relayRelease)}, you run {EscapeLua(ReleaseVersionInfo.Current)} -- both machines must install the same release\") end"); await _transport.FlushAsync(appCt); } catch { }
            throw new ReleaseVersionMismatchException(relayRelease);
        }

        if (replyHeader[0] != Protocol.Ack || replyLen < 1)
        {
            Console.WriteLine($"[!] Expected Ack, got packet type 0x{replyHeader[0]:X2}. Dropping connection.");
            return;
        }

        byte myId = replyBody[0];
        _myGhostId = myId;
        Console.WriteLine($"Connected! Assigned id={myId} (protocol v{Protocol.Version})");
        Console.WriteLine();

        _discordPresence?.SetConnected(config.IsHosting);

        // WO-48: dropIds are minted per connection; a stale heartbeat after a
        // reconnect would re-broadcast drops the peers may already hold.
        _myOpenDrops.Clear();

        _hasPushed = false;
        _staleRun = 0;                              // WO-99 Phase 1
        // WO-100.5 Phase 3: a new connection is a new epoch, so an action that
        // survived a relay round trip across the drop is discarded by every
        // receiver rather than replayed onto a body that has moved on.
        _actionOut.BumpEpoch();
        _lastSentAppearance = null;
        _ghostAppearance.Clear();
        _ghostKnownItemClasses.Clear();
        _ghostNeverEquips.Clear();
        _ghostLastAppearance.Clear();      // WO-88: per-connection, like the sets above
        _reloadConvergeTarget = null;      // WO-88: a convergence belongs to one connection
        // WO-17: ghost ids are reassigned per relay connection; a cached
        // Guid or hold-timer from a previous session would point at nothing.
        // _aggroEnabled itself is a deliberate local user setting and
        // deliberately survives a reconnect.
        _ghostSoulGuidCache.Clear();
        _ghostHostileUntilUtc.Clear();
        _localAutoPaused = false;
        _localManualPaused = false;
        _lastSentPauseState = null;
        // WO-28: relay ids are per-connection, so nothing about who was hurt,
        // dead, or authoritative survives a reconnect. _isDamageAuthority
        // especially: it is the relay's to grant and it will re-grant it (or
        // not) on this connection's own handshake.
        _lastSentHealth = null;
        _lastSentStamina = null;
        _lastSentVitalFlags = 0;
        _lastPlayerStateSentUtc = DateTime.MinValue;
        _sentDeathForThisLife = false;
        _isDamageAuthority = false;
        // WO-86: per-stream dead-bit memory and the death dedupe are about
        // THIS connection's streams; a reconnect starts them over so the first
        // packet of every body is a "first packet" again (freeze-only rule).
        _npcLastDead.Clear();
        _npcDeathAppliedUtc.Clear();
        // WO-90: a peer's story position and the "we have diverged" latch are
        // both keyed by per-connection ghost id, so neither survives a
        // reconnect. Our OWN objective deliberately does survive -- it is a
        // fact about this playthrough, not about the socket, and re-deriving
        // it would mean waiting for the next checkpoint save.
        _peerObjective.Clear();
        _storyDivergenceTold.Clear();
        // WO-59: announce our clock once this connection's first world-time
        // reading arrives, so saves that sit days apart converge without
        // anyone having to sleep first (Thread B: the day/night split).
        _timeSyncPending = true;
        StopInterpPump();

        // --- Interaction layer ---
        // Framing lives here because this class owns the stream; the interaction
        // and dice clients only decide what to say.
        async Task SendPacketAsync(byte type, byte[] payload, CancellationToken ict)
        {
            var pkt = new byte[3 + payload.Length];
            pkt[0] = type;
            BinaryPrimitives.WriteUInt16LittleEndian(pkt.AsSpan(1), (ushort)payload.Length);
            payload.CopyTo(pkt, 3);
            await WritePacketAsync(stream, pkt, ict);
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

        // WO-19: lets the launcher poll this agent's own release version plus
        // whatever release versions have arrived for connected peers so far.
        _versionIpcServer = new VersionIpcServer(() => _ghostReleaseVersions.ToArray(), config.VersionIpcPort);
        _versionIpcServer.Start();

        // Kick off the Lua interp tick immediately so KCD2MP.isRiding gets updated
        // even before the first ghost is spawned (e.g. player already on horse at connect time).
        try { await ExecLuaAsync("if KCD2MP_StartInterp then KCD2MP_StartInterp() end"); }
        catch { /* ignore if mod not loaded yet */ }

        // WO-58: clear any ghost bodies embedded in the loaded save. A save
        // made with a peer's ghost standing nearby captures that entity like
        // any other NPC; on a later session the relay hands out different
        // ids, so nothing in the normal spawn path ever reclaims the old
        // body -- it just stands there wearing the old session's face
        // (which is what a "player joined as the wrong gender/face on an
        // old save" report looks like). Once per connection, before any
        // ghost of this session spawns.
        try { await ExecLuaAsync("if KCD2MP_SweepStrayGhosts then KCD2MP_SweepStrayGhosts() end"); }
        catch { }

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
        _combat.OnLocalHit = async (soul, stamina, health, died) =>
        {
            // WO-86: a FATAL hit is never noise, whatever its delta -- the
            // DLL's sampler reports the drop that took the soul to zero, which
            // is bounded by the hp it had left (an overkill blow on a 3 hp NPC
            // reports 3.0). That bound is also why death has to travel as its
            // own fact: a peer whose copy sat at 20 hp receives 3.0, survives,
            // and nothing ever tells it otherwise.
            if (died)
            {
                Console.WriteLine($"[npcdeath] out: local kill of {soul} (blow -{health:F1}) -- sending FATAL{CatchupTag()}");
            }
            else
            // WO-40 Phase 5: the DLL's hit hook fires per contact frame, and
            // the 2026-08-18 bundles show what that costs -- 1,025 of PB's
            // 1,058 hit events carried 0.0 damage (bursts of ~26/s across 3
            // souls), and the one applied flood (176 events/18 s during the
            // 20:14 choke) coincided with PB's worst engine stall of the
            // session, right before the global animation collapse. A hit that
            // moved no health and no stamina carries no information: drop it
            // here, before the wire.
            //
            // WO-58: the exact-zero filter was not enough in the field. The
            // 2026-08-25 session's joiner sent 1,972 hit messages in under
            // four minutes -- all sub-0.05 hp contact-frame chips from an
            // NPC-vs-NPC siege battle running in the joiner's own world --
            // and every one cost the host a synchronous main-thread damage
            // apply while it was fighting the same battle locally. Real
            // player hits in that same log are 6.5-100 hp; the DLL hardcodes
            // stamina to 0 on this path (pipe_server.cpp send_local_hit).
            // Anything under half a hit point is sensor noise, not combat
            // state worth a wire message and a peer-side game-thread apply.
            if (health < 0.5f && stamina < 0.5f) return;
            try
            {
                // WO-40 Phase 5: per-save guids are unreliable across
                // installs; send name-addressed (0x30) when the name
                // resolves, guid-addressed (0x12) as the fallback -- one or
                // the other, never both (both resolving would double-apply).
                // Ghost souls (kcd2mp_*) stay on the guid path: their damage
                // has its own authoritative flow (0x21) and a name like
                // "kcd2mp_6" means a different entity on every machine.
                string? npcName = await ResolveSoulNameAsync(soul, cts.Token);
                if (npcName is not null && _npcReplicaOrig.TryGetValue(npcName, out var replicaOf))
                {
                    // WO-104: a hit on a replica body is a hit on the NPC it stands in for.
                    Console.WriteLine($"[combat] hit on replica '{npcName}' attributed to '{replicaOf}'");
                    npcName = replicaOf;
                }

                // WO-99 Phase 0: never put the LOCAL PLAYER's own health drop
                // on the NPC path, and never re-send a value a peer just made
                // us apply. Structural key = the per-save PlayerSoul guid; the
                // soul name is the fallback for the window after a save load
                // (a name match with a guid miss forces the re-read first, so
                // the guid gets its chance to be the reason).
                await RefreshPlayerIdentityAsync(force: false, cts.Token);
                var verdict = _dmgGuard.CheckOutbound(soul, npcName, health, stamina, died, DateTime.UtcNow);
                if (verdict == NpcDamageGuard.Outbound.DropLocalPlayerName)
                {
                    await RefreshPlayerIdentityAsync(force: true, cts.Token);
                    verdict = _dmgGuard.CheckOutbound(soul, npcName, health, stamina, died, DateTime.UtcNow);
                }
                if (NpcDamageGuard.IsDrop(verdict))
                {
                    _stats.DmgOutDropped++;
                    Console.WriteLine(FormattableString.Invariant(
                        $"MP-DMG dir=drop npc={npcName ?? "?"} hp={health:F1} st={stamina:F1} fatal={(died ? 1 : 0)} reason={NpcDamageGuard.Reason(verdict)} authority={(_isDamageAuthority ? 1 : 0)}"));
                    return;
                }

                if (npcName is not null && !npcName.StartsWith("kcd2mp_", StringComparison.Ordinal))
                {
                    await SendNpcDamageAsync(stream, npcName, stamina, health, suppressHitReaction: true, fatal: died);
                    Console.WriteLine($"[combat] sent hit {health:F1} on '{npcName}' ({soul}){(died ? " FATAL" : "")}");
                    NoteRequestResolvedOut(npcName);   // WO-102 Phase 5
                    _stats.DmgOut++; if (died) _stats.DmgOutFatal++;
                    Console.WriteLine(FormattableString.Invariant($"MP-DMG dir=out npc={npcName} hp={health:F1} st={stamina:F1} fatal={(died ? 1 : 0)} authority={(_isDamageAuthority ? 1 : 0)}"));
                    if (died)
                    {
                        // Tell the mod's death observer this death is already
                        // announced, so its own IsDead transition read does not
                        // send a second FATAL for the same body.
                        _ = ExecLuaAsync($"if KCD2MP_NpcDeathAnnounced then KCD2MP_NpcDeathAnnounced(\"{npcName}\", \"dll\") end");
                    }
                }
                else
                {
                    // WO-100.5 Phase 4: the guid-addressed fallback. Already
                    // gated on the name lookup having failed (npcName is null)
                    // or on the target being a ghost body, whose soul guid IS
                    // the shared roster soul and therefore stable. What it
                    // lacked was visibility: WO-40 field-measured 571/571
                    // failures on one machine and 176/176 successes on
                    // another, and nothing in a field log distinguished "this
                    // path fired and did nothing" from "this path never fired".
                    bool ghostTarget = npcName is not null;   // i.e. a kcd2mp_ body
                    if (!ghostTarget && !config.GuidDamageFallbackEnabled)
                    {
                        _stats.DmgOutDropped++;
                        Console.WriteLine(FormattableString.Invariant(
                            $"MP-DMG dir=drop route=guid-fallback soul={soul} hp={health:F1} st={stamina:F1} fatal={(died ? 1 : 0)} reason=fallback-disabled"));
                        return;
                    }
                    await SendLocalHitAsync(stream, soul, stamina, health, suppressHitReaction: true);
                    Console.WriteLine(FormattableString.Invariant(
                        $"MP-DMG dir=out route={(ghostTarget ? "guid-ghost" : "guid-fallback")} soul={soul} hp={health:F1} st={stamina:F1} fatal={(died ? 1 : 0)} reason={(ghostTarget ? "ghost-body" : "name-lookup-failed")}"));
                    Console.WriteLine($"[combat] sent hit {health:F1} on {soul}"
                        + (npcName is null ? " (name lookup failed -- guid-addressed)" : ""));
                    if (died && npcName is null)
                    {
                        // WO-100.5 Phase 4: gated by the same toggle, implicitly
                        // -- npcName is null means this is not a ghost target,
                        // so the early return above has already fired when the
                        // fallback is off. Said out loud rather than left to be
                        // re-derived.
                        //
                        // WO-86: the guid-addressed death packet (0x14) has had
                        // a sender since WO-4 and no caller until now. It is
                        // the fallback for the fallback: it lands only when the
                        // per-save guids happen to match (WO-40), which is
                        // exactly when 0x12 landed too.
                        await SendLocalDeathAsync(stream, soul);
                        Console.WriteLine($"[npcdeath] out: 0x14 guid-addressed death for {soul} (name lookup failed)");
                    }
                }
            }
            catch (Exception ex) { Console.WriteLine($"[combat] hit not sent: {ex.Message}"); }

            // WO-17: Henry (the local player) just landed a real hit too --
            // per Phase B, that should mark any ghost present in this world
            // hostile the same as if the ghost had thrown the punch itself,
            // so a fight either player starts is one both characters are
            // recognisably part of. Simplification for >2 players: this
            // flags every currently-named ghost rather than only ones
            // actually near Henry, which is exactly equivalent to "the one
            // ghost" in this project's real (2-player) usage. No-op when
            // aggro is disabled.
            if (_aggroEnabled)
            {
                foreach (var ghostId in _ghostNames.Keys)
                    _ = TriggerReactiveAggroAsync(ghostId, cts.Token);
            }
        };
        // Connect now rather than lazily, so the DLL has somewhere to push hits
        // before the first inbound packet ever arrives.
        _ = _combat.EnsureConnectedAsync(cts.Token);
        // WO-99 Phase 0: learn who the local player is before the first hit.
        _dmgGuard.ResetEchoMemory();
        await RefreshPlayerIdentityAsync(force: true, cts.Token);

        // Pause mitigation (WO-11): only the log-tail transport can see the
        // kcd.log markers this relies on (docs/WO-11-findings.md addendum),
        // so this is a no-op under HttpGameTransport -- the event simply
        // never fires. Re-subscribed per connection like _combat.OnLocalHit
        // above, since the handler closes over this connection's stream.
        _sendPauseIfChanged = () => SendPauseIfChangedAsync(stream, cts.Token);
        _sendPlayerHit = (target, hLoss, sLoss) => SendPlayerHitAsync(stream, target, hLoss, sLoss, cts.Token);
        _sendNpcState = (npc, x, y, z, rot, hp, flags) => SendNpcStateAsync(stream, npc, x, y, z, rot, hp, flags, cts.Token);
        _sendNpcDrag = (npc, x, y, z, rot, hp, flags) => SendNpcStateAsync(stream, npc, x, y, z, rot, hp, flags, cts.Token, asClaim: true);
        _resyncStream = stream;   // WO-102 Phase 6
        _sendNpcDeath = npc => SendNpcDamageAsync(stream, npc, 0f, 0f, suppressHitReaction: true, fatal: true);
        _sendHorseInfo = horseName => SendHorseInfoAsync(stream, horseName, cts.Token);
        _sendCombatEvent = (evt, sid) => SendCombatEventAsync(stream, evt, sid, cts.Token);
        _sendWeather = (profile, blend) => SendWeatherAsync(stream, profile, blend, cts.Token);
        // Dropped-item sync (WO-48): both fire from the tail transport's event
        // thread (item_drop / item_claim event lines), which has no stream.
        _sendItemDrop = payload => SendItemDropAsync(stream, payload, cts.Token);
        _sendItemClaim = dropId => SendItemClaimAsync(stream, dropId, cts.Token);
        void OnLocalPauseDetected(bool paused)
        {
            _localAutoPaused = paused;
            _ = _sendPauseIfChanged?.Invoke();
            // WO-13: the local tick is frozen for as long as this is true.
            if (paused) StartInterpPump(); else StopInterpPump();
        }
        // Time-skip sync (WO-38 Phase 1): log-tail only, like pause detection.
        _sendTimeSkip = (phase, kind, worldTime) => SendTimeSkipAsync(stream, phase, kind, worldTime, cts.Token);
        void OnLocalSkipTime(bool active)
        {
            _localSkipActive = active;
            if (active)
            {
                // WO-39 Phase 8: the bed interaction itself is the sleep-vs-
                // wait discriminator (kcd.log was a confirmed dead end). The
                // mod polls BedTrigger proximity at 1 Hz and this flag holds
                // the latest value, so by the time a skip marker arrives we
                // already know whether the player was standing at a bed.
                // A marker-based skip away from any bed is the wait function;
                // fast travel never emits these markers at all (it arrives
                // via the clock-jump watcher as an instant skip).
                // (This event only ever fires on the log-tail transport, so
                // there is no third case to consider here.)
                _localSkipKind = _nearBed ? Protocol.TimeSkipKindSleep : Protocol.TimeSkipKindWait;
                _ = _sendTimeSkip?.Invoke(Protocol.TimeSkipPhaseStart, _localSkipKind, 0);
            }
            else
            {
                // The resulting clock is read from the mod; the reply arrives
                // as a time_now game event and becomes our TimeSkipUp(done).
                _awaitSkipDoneTime = true;
                _ = ExecLuaAsync("if KCD2MP_ReportWorldTime then KCD2MP_ReportWorldTime() end");
            }
        }
        // Story progress (WO-90): log-tail only, like pause and skip-time
        // detection -- the marker is a raw engine log line and there is no
        // other surface that carries it.
        _sendStoryBeat = (kind, text) => SendStoryBeatAsync(stream, kind, text, cts.Token);

        if (_transport is LogTailGameTransport tailForPause)
        {
            tailForPause.PauseStateChanged += OnLocalPauseDetected;
            tailForPause.SkipTimeStateChanged += OnLocalSkipTime;
            tailForPause.StoryBeatDetected += OnLocalStoryBeat;
            tailForPause.LevelDetected += OnLocalLevel;              // WO-94
            tailForPause.CutsceneStateChanged += OnLocalCutscene;    // WO-94
            tailForPause.PlayerTeleported += OnLocalTeleport;        // WO-94
            tailForPause.CutsceneEdge += OnLocalCutsceneEdge;        // WO-98 Phase 5
            tailForPause.ModInitDetected += OnModInitDetected;       // WO-98 Phase 7

            // A reconnect keeps the tail (and its last marker) alive, so seed
            // from it rather than waiting for the next checkpoint -- at a
            // handful of markers an hour that wait can be most of a session.
            _localObjective ??= tailForPause.LastStoryMarker;
        }

        var receiveTask     = ReceiveLoopAsync(stream, cts.Token);
        var pingTask        = PingLoopAsync(stream, cts.Token);
        var appearanceTask  = AppearanceLoopAsync(stream, cts.Token);

        // --- Position push loop ---
        try
        {
            int tickCount = 0;
            long totalReadMs = 0;
            long nowTimestamp = Stopwatch.GetTimestamp();
            long lastReArm = nowTimestamp;
            long lastDropHeartbeat = nowTimestamp;
            long lastGhostReconcile = nowTimestamp;
            long lastAggroSweep = nowTimestamp;
            long lastTimePoll = nowTimestamp;
            long lastTimeAnnounce = nowTimestamp;   // WO-88: periodic quiet clock announce
            long lastWeatherTick = nowTimestamp;
            long lastPositionHeartbeat = nowTimestamp;
            long lastCadenceReport = Stopwatch.GetTimestamp();   // WO-102 Phase 1
            long lastDropReport = 0;   // WO-110 R9
            long lastRequestSweep = Stopwatch.GetTimestamp();     // WO-102 Phase 5
            long lastNpcScan = Stopwatch.GetTimestamp();          // WO-102.5 Phase 2
            long lastQuestRepush = nowTimestamp;    // WO-98 Phase 7
            long lastSummary = nowTimestamp;        // WO-99 Phase 4

            while (tcp.Connected)
            {
                var sw = System.Diagnostics.Stopwatch.StartNew();
                var state = await _transport.ReadPlayerStateAsync(cts.Token);
                sw.Stop();
                totalReadMs += sw.ElapsedMilliseconds;
                tickCount++;
                nowTimestamp = Stopwatch.GetTimestamp();

                // Re-arm the mod's own timer loops periodically (WO-13).
                // Loading a save destroys every pending Script.SetTimer in the
                // game, which kills the interp and label loops outright -- and
                // before the liveness check added in kdcmp.lua, left them
                // permanently unrestartable. Observed live: every remote
                // ghost frozen for the rest of the session after one save
                // load. StartInterp is idempotent and cheap (a stamp
                // comparison) so calling it on a slow cadence costs nothing
                // and makes the recovery automatic rather than a restart.
                if (IntervalElapsed(ref lastReArm, ReArmInterpInterval, nowTimestamp))
                {
                    // WO-28 Phase 0 found this was only half a fix. WO-13
                    // re-armed the interp loop and stopped there, but a save
                    // load kills the *emitter's* Script.SetTimer chain too --
                    // and the emitter is this client's only outbound channel.
                    // Measured live: after one reload the interp loop recovered
                    // in ~17 s while the emitter stayed dead for the rest of
                    // the session (heartbeat age climbing past 120 s), so the
                    // player transmitted no position at all and simply vanished
                    // for every peer, permanently. StartEmitter is idempotent
                    // and liveness-checked exactly like StartInterp, so calling
                    // it on the same cadence costs a stamp comparison.
                    //
                    // The transport's own latch has to be cleared as well or
                    // its StartAsync would never re-issue the command either.
                    try
                    {
                        await ExecLuaAsync("if KCD2MP_StartInterp then KCD2MP_StartInterp() end");
                        await ExecLuaAsync($"if KCD2MP_StartEmitter then KCD2MP_StartEmitter({config.EmitIntervalMs}) end");
                        // WO-32: the NPC-sync emit chain dies on a save load
                        // like every other Script.SetTimer chain (WO-13). Its
                        // own liveness stamp makes this a no-op while healthy.
                        // The puppet chain needs no re-arm: any inbound
                        // NpcStateDown restarts it via KCD2MP_ApplyNpcState.
                        await ExecLuaAsync("if KCD2MP_StartNpcSync and KCD2MP.npcSync and KCD2MP.npcSync.enabled then KCD2MP_StartNpcSync() end");
                        // WO-102 Phase 0: the agent's configured defaults are
                        // the session's starting toggle state; the mod
                        // mirrors them (source "agent" -> no echo back).
                        await ExecLuaAsync(FormattableString.Invariant(
                            $"if KCD2MP_Wo102Set then KCD2MP_Wo102Set(\"authority_host\", {(_hostAuthority ? "true" : "false")}, \"agent\") KCD2MP_Wo102Set(\"pos_native\", {(_posNative ? "true" : "false")}, \"agent\") KCD2MP_Wo102Set(\"npc_scan_native\", {(_npcScanNative ? "true" : "false")}, \"agent\") end"));
                        // WO-48: the item-sync tick is a Script.SetTimer chain
                        // like the others and dies with them on a save load.
                        await ExecLuaAsync("if KCD2MP_StartItemSync then KCD2MP_StartItemSync() end");
                        // WO-58: re-assert every known ghost name. A game
                        // restart mid-connection wipes the mod's Lua state
                        // while this agent's relay session lives on, and the
                        // relay only sends Name packets once -- so every
                        // ghost respawned into the fresh Lua was nameless
                        // and face-picked from the "Player<id>" fallback
                        // (both joiner kcd.logs of the 2026-08-25 session
                        // carry the "no Steam nick yet" spawn; "Player1"
                        // hashes to a female body). SetGhostName is a no-op
                        // in Lua when the name is already applied, so this
                        // costs a stamp comparison on the same cadence as
                        // the other re-arms.
                        foreach (var kv in _ghostNames)
                            await ExecLuaAsync(
                                $"if KCD2MP_SetGhostName then KCD2MP_SetGhostName(\"{kv.Key}\", \"{EscapeLua(kv.Value)}\") end");
                        // WO-94: level and current main quest survive in the
                        // agent but not in a restarted game's Lua; re-push
                        // them on the same cadence (idempotent in Lua).
                        PushQuestContext();
                        // WO-98 Phase 7: WO-96 re-pushed on every 2.5 s
                        // re-arm for as long as the pair differed -- ~50
                        // identical QUEST-DIVERGENCE lines per side in the
                        // 2026-09-15 logs, ten in one 21 s window. The
                        // re-push exists for a RESTARTED game's fresh Lua,
                        // so it now fires when the tail sees MOD INIT, with
                        // a 60 s heartbeat as the safety net.
                        if (_questRepushDue || IntervalElapsed(ref lastQuestRepush, QuestRepushHeartbeat, nowTimestamp))
                        {
                            _questRepushDue = false;
                            RepushQuestDivergences();   // WO-96
                        }
                        // WO-59 Thread C: re-assert stimulus-deafness on every
                        // live ghost. AI.SetIgnorant was applied exactly once
                        // at spawn with its result discarded, so a failed call
                        // or an engine-side reset left a ghost's brain fully
                        // perceptive with nothing ever noticing -- and a
                        // perceptive ghost brain is a real crime witness (the
                        // "caught stealing, killed by the ghost" report). One
                        // flag write per ghost per 2.5 s; failures log once.
                        await ExecLuaAsync("if KCD2MP_ReassertGhostIgnorance then KCD2MP_ReassertGhostIgnorance() end");
                    }
                    catch { }
                }

                // WO-48: re-broadcast my still-unclaimed drops so a peer who
                // joined after the drop still converges. Receivers dedupe by
                // dropId, so a resend costs nothing when everyone has it.
                if (IntervalElapsed(ref lastDropHeartbeat, ItemDropHeartbeatInterval, nowTimestamp)
                    && !_myOpenDrops.IsEmpty)
                {
                    foreach (var payload in _myOpenDrops.Values)
                        try { await SendItemDropAsync(stream, payload, cts.Token); } catch { }
                }

                // WO-28 Phase 0. A save load destroys every ghost entity while
                // KCD2MP.ghosts keeps a stale, non-nil reference to it, so
                // KCD2MP_UpdateGhost's own "spawn if missing" test never fires
                // again. Observed live: the nameplate carried on walking its
                // path with no body under it, indefinitely. The mod cannot
                // notice on its own without paying a world lookup on the hot
                // 20 ms path, so it is asked on a slow cadence from here.
                if (IntervalElapsed(ref lastGhostReconcile, ReconcileGhostsInterval, nowTimestamp))
                {
                    try { await ExecLuaAsync("if KCD2MP_ReconcileGhosts then KCD2MP_ReconcileGhosts() end"); }
                    catch { }
                }

                // WO-17: cheap when nothing is attached -- see the method doc.
                if (IntervalElapsed(ref lastAggroSweep, AggroSweepInterval, nowTimestamp))
                    _ = SweepAggroCooldownsAsync(cts.Token);

                // WO-88 finding 4: re-announce our clock about once a minute
                // while anyone is here. Consumed by the next world-time poll
                // (below), exactly like the connect-time and new-peer
                // announces; receivers apply forward-only and ignore reports
                // inside natural skew, so this is idle when clocks agree and
                // is what closes the gap when a reloader's own convergence
                // was lost or aimed at a stale private "session clock".
                if (IntervalElapsed(ref lastTimeAnnounce, TimeAnnounceInterval, nowTimestamp)
                    && !_localSkipActive && !_awaitSkipDoneTime
                    && _peerLastSeenUtc.Any(kv => (DateTime.UtcNow - kv.Value) < TimeSpan.FromMinutes(2)))
                {
                    _timeSyncPending = true;
                }

                // WO-38 Phase 1: poll the world clock on a slow cadence. Feeds
                // the clock-jump watcher (fast travel emits no confirmed skip
                // marker) -- the reading itself arrives as a time_now game
                // event, handled in OnGameEvent. One batched Lua call per
                // ~10 s; suppressed while our own marker-skip is resolving,
                // since the skip-end path requests the same reading itself.
                if (IntervalElapsed(ref lastTimePoll, TimePollInterval, nowTimestamp)
                    && !_localSkipActive && !_awaitSkipDoneTime)
                {
                    try { await ExecLuaAsync("if KCD2MP_ReportWorldTime then KCD2MP_ReportWorldTime() end"); }
                    catch { }
                }

                // WO-40 Phase 3: weather arbitration, checked every ~5 s.
                // All the real gates (authority, live peers, cadences) live
                // inside the tick.
                if (IntervalElapsed(ref lastWeatherTick, WeatherTickInterval, nowTimestamp))
                    WeatherArbiterTick();

                // WO-99 Phase 4: periodic MP-SUMMARY / MP-SUMMARY-MOD snapshot.
                if (IntervalElapsed(ref lastSummary, SummaryHeartbeat, nowTimestamp))
                {
                    try { PrintSessionSummary("periodic"); } catch { }
                }

                if (state.HasValue && _staleRun > 0)
                {
                    // WO-99 Phase 1: the mod's emitter is back (menu closed,
                    // load finished, cutscene over). One line per suspension.
                    Console.WriteLine($"[pos] mod emitter resumed after {_staleRun} stale heartbeat(s)");
                    _staleRun = 0;
                }
                if (!state.HasValue && _hasPushed
                    && IntervalElapsed(ref lastPositionHeartbeat, PositionHeartbeatInterval, nowTimestamp))
                {
                    // WO-99 Phase 1: no fresh sample -- the mod's emitter chain
                    // is halted (every Script.SetTimer stops in a menu, a
                    // loading screen, a cutscene, a dialogue: WO-78 "suspended
                    // != dead"). 2026-09-16: 100% of the >2.3 s inbound ghost
                    // gaps on both machines were this (the only packets that
                    // crossed were the 2.5 s re-arm running the emitter once,
                    // hence the observed ~20 s cadence), zero were transport.
                    // Re-send the last sample at the heartbeat cadence, flagged
                    // STALE, so a receiver can tell "paused" from "gone".
                    await SendPositionAsync(stream, _lastX, _lastY, _lastZ, _lastRotZ, _lastRiding, stale: true);
                    _stats.PosStaleOut++;
                    if (++_staleRun == 1)
                        Console.WriteLine("[pos] mod emitter silent -- sending stale heartbeats until it resumes");
                }
                // WO-102 Phase 1: cadence of the log path -- a seq change is one
                // fresh emitter line. Measured whatever the toggle says.
                if (_transport is LogTailGameTransport cadTail)
                {
                    long seqNow = cadTail.LatestSeq;
                    if (seqNow >= 0 && seqNow != _lastLogSeq)
                    {
                        if (_lastLogSeq >= 0 && seqNow < _lastLogSeq) _cadLog.Break();   // emitter restart
                        _lastLogSeq = seqNow;
                        _cadLog.Sample(NowMs());
                    }
                }
                // The native read, when the toggle is on and the mod's emitter is
                // live. The emitter's silence is the pause signal (menu, load,
                // cutscene -- WO-99 Phase 1) and the STALE heartbeat below keys
                // on it; the native read is not consulted while it is silent, so
                // a paused game never streams "live" frames.
                LocalState? nat = null;
                if (_posNative && state.HasValue)
                    nat = await ReadNativeStateAsync(state.Value, cts.Token);
                else if (!_posNative || !state.HasValue)
                    _cadNative.Break();
                if (IntervalElapsed(ref lastCadenceReport, CadenceReportInterval, nowTimestamp))
                    ReportCadence();
                if (IntervalElapsed(ref lastDropReport, DropReportInterval, nowTimestamp))
                    ReportDrops();   // WO-110 R9
                if (IntervalElapsed(ref lastRequestSweep, RequestResolveWindow, nowTimestamp))
                    SweepRequests();   // WO-102 Phase 5

                if (state.HasValue)
                {
                    var st = state.Value;
                    // WO-102 Phase 1: one frame, one read, one packet -- position,
                    // yaw, riding and body state all from the native sample when
                    // there is one; the log line otherwise (0.23.2 behaviour).
                    float x, y, z, rotZ; bool riding; LocalBodyState? local = null;
                    if (nat is LocalState ns)
                    {
                        x = ns.X; y = ns.Y; z = ns.Z; rotZ = ns.RotZ; riding = ns.IsRiding; local = ns.Body;
                    }
                    else
                    {
                        x = st.X; y = st.Y; z = st.Z; rotZ = st.RotZ; riding = st.IsRiding;
                    }

                    // WO-28 Flows A and C ride the same sample the position
                    // push already reads, so neither adds a read of its own.
                    // Both are no-ops on a v1 emit line, where Health/IsDead
                    // are null -- "unknown, leave it alone".
                    await SendPlayerStateIfChangedAsync(stream, st, cts.Token);
                    await SendDeathIfNewAsync(stream, st, cts.Token);

                    // Update voice local position and recalculate all player volumes.
                    if (_voice != null)
                    {
                        _voice.LocalPos = (x, y, z);
                        _voice.UpdateAllVolumes();
                    }

                    // WO-102.5 Phase 2: its own cadence, independent of the
                    // position tick's -- this feeds a background candidate
                    // list, not a per-frame read.
                    // WO-110 R13: under host authority only the owner's Lua
                    // ever consumes the push (a non-authority's
                    // KCD2MP_NpcSyncTick returns before the rescan runs), so
                    // the joiner used to walk every entity on its main thread
                    // every 2 s and hold the pipe for nothing. Gate on the
                    // relay's CombatRole; the claim model (host authority off)
                    // still needs candidates on every machine.
                    bool scanWanted = _isDamageAuthority || !_hostAuthority;
                    if (_npcScanNative && !scanWanted && !_npcScanSkipLogged)
                    {
                        _npcScanSkipLogged = true;
                        Console.WriteLine("MP-NPCSCAN dir=native verdict=skipped reason=not-authority -- this machine renders puppets, it does not own NPCs (WO-110 R13)");
                    }
                    else if (_npcScanNative && scanWanted && _npcScanSkipLogged)
                    {
                        _npcScanSkipLogged = false;
                        Console.WriteLine("MP-NPCSCAN dir=native verdict=resumed reason=authority-acquired");
                    }
                    if (_npcScanNative && scanWanted && IntervalElapsed(ref lastNpcScan, NpcScanInterval, nowTimestamp))
                        _ = NpcScanTickAsync(x, y, z, cts.Token);

                    bool posHeartbeat = IntervalElapsed(
                        ref lastPositionHeartbeat, PositionHeartbeatInterval, nowTimestamp);
                    if (!_hasPushed || HasChanged(x, y, z, rotZ) || posHeartbeat)
                    {
                        bool moved = !_hasPushed || HasChanged(x, y, z, rotZ);
                        _hasPushed = true;
                        _lastX = x; _lastY = y; _lastZ = z; _lastRotZ = rotZ; _lastRiding = riding;
                        // WO-100.5 Phase 2: published at the position stream's
                        // own cadence, with no debouncing, smoothing or
                        // hold-and-confirm. WO-100 S10.2 settled that live: the
                        // MoveSpeed/MoveDir tags are stable continuous state
                        // (6.3 s of unbroken run+forward at 50 ms) and the
                        // earlier "flicker" was 300 ms sampling over tapped
                        // keys. Adding smoothing here would be inventing a
                        // problem the engine does not have.
                        if (nat is null) local = await ReadLocalBodyStateAsync(cts.Token);   // log path: the separate 0x09 read, as before
                        await SendPositionAsync(stream, x, y, z, rotZ, riding,
                                                body: local?.Body);
                        // WO-100.5 Phase 3: the accepted input rides the same
                        // read -- one pipe round trip serves both channels.
                        if (local is LocalBodyState lb)
                            await SendAttackEdgeAsync(stream, lb, cts.Token);
                        if (moved)
                            Console.WriteLine($"[pos] {x:F1} {y:F1} {z:F1}  rot={rotZ:F2}  riding={riding}  read={sw.ElapsedMilliseconds}ms path={(nat is null ? "log" : "native")}");
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
            try { PrintSessionSummary("disconnect"); } catch { }   // WO-98 Phase 6
            _stats = new SessionCounters();
            _peerCutscene.Clear();
            cts.Cancel();
            try { await receiveTask;     } catch { }
            try { await pingTask;        } catch { }
            try { await appearanceTask;  } catch { }
            _voice?.Stop();
            _voice?.Dispose();
            _voice = null;

            if (_transport is LogTailGameTransport tailForPause2)
            {
                tailForPause2.PauseStateChanged -= OnLocalPauseDetected;
                tailForPause2.SkipTimeStateChanged -= OnLocalSkipTime;
                tailForPause2.StoryBeatDetected -= OnLocalStoryBeat;   // WO-90
                tailForPause2.LevelDetected -= OnLocalLevel;            // WO-94
                tailForPause2.CutsceneStateChanged -= OnLocalCutscene;  // WO-94
                tailForPause2.PlayerTeleported -= OnLocalTeleport;      // WO-94
                tailForPause2.CutsceneEdge -= OnLocalCutsceneEdge;      // WO-98 Phase 5
                tailForPause2.ModInitDetected -= OnModInitDetected;     // WO-98 Phase 7
            }
            _sendPauseIfChanged = null;
            _sendPlayerHit = null;
            _sendNpcState = null;
            _sendNpcDrag = null;
            _resyncStream = null;   // WO-102 Phase 6
            _sendNpcDeath = null;
            _sendTimeSkip = null;
            _sendHorseInfo = null;
            _sendCombatEvent = null;
            _sendWeather = null;
            _sendItemDrop = null;
            _sendItemClaim = null;
            _myOpenDrops.Clear();
            _sessionWeatherProfile = null;
            _lastAppliedWeatherProfile = null;
            _weatherNextRepickUtc = DateTime.MinValue;
            _weatherNextHeartbeatUtc = DateTime.MinValue;
            _soulNameByGuid.Clear();
            _soulGuidByName.Clear();
            lock (_timeSkipLock) { _pendingTimeSkip = null; }
            _localSkipActive = false;
            _awaitSkipDoneTime = false;
            _lastPolledWorldTime = null;
            _fastAdvanceActive = false;

            // Stop pumping the interp tick. Nothing else would: the pump is
            // driven off the local menu signal, and a menu that is still open
            // when the socket drops never delivers its "exited" edge.
            StopInterpPump();

            // The relay drops our sessions when the socket closes, so local
            // state has to go too or a reconnect would think it is still busy.
            Interactions?.Reset();
            Interactions = null;
            Dice = null;
            _diceIpcServer?.Stop();
            _diceIpcServer = null;
            _versionIpcServer?.Stop();
            _versionIpcServer = null;
            _ghostNames.Clear();
            _ghostReleaseVersions.Clear();
            _discordPresence?.ResetForReconnect();

            // WO-110 R11 (docs/WO-109-audit.md R11): these two used to go into
            // the BATCH, which is flushed only by the next connected main loop
            // or a clean dispose -- so on a relay drop, a crash that still ran
            // this finally, or the launcher's stop, they were queued and never
            // sent. ExecuteNowAsync sends immediately (one round trip each).
            // A hard process kill still runs nothing here; for that case the
            // peer's ghost removal is the RELAY's Disconnect broadcast, and the
            // local NPCs resume through Lua's own silence path (release +
            // dwell), which needs no agent.
            Console.WriteLine("Removing all ghosts (sent now, not batched -- WO-110 R11)...");
            try { await _transport.ExecuteNowAsync("KCD2MP_RemoveAllGhosts()"); }
            catch (Exception ex) { Console.WriteLine($"[disconnect] RemoveAllGhosts did not send: {ex.Message}"); }
            // WO-102.5 Phase 1: guarantee resume when THIS agent goes away --
            // closed, crashed, or the relay dropped it. The game and its Lua
            // state keep running without us, so whatever it still believes is
            // paused must not be left that way.
            try { await _transport.ExecuteNowAsync("if KCD2MP_Wo102ResumeAll then KCD2MP_Wo102ResumeAll(\"agent-disconnect\") end"); }
            catch (Exception ex) { Console.WriteLine($"[disconnect] Wo102ResumeAll did not send: {ex.Message}"); }
        }
    }

    // -------------------------------------------------------------------------
    // Background rotation + riding state loop (every RotStateIntervalMs)
    // -------------------------------------------------------------------------

    /// <summary>
    /// WO-98 Phase 1: fold one ClockSyncDown reply into the running estimate.
    /// offset = ((t1-t0)+(t2-t3))/2 is the relay's clock minus ours; the relay
    /// runs on the host, so on a joiner this IS the host-vs-joiner skew.
    /// Logs MP-CLOCK on the 1st and 5th sample and every 30 s after, and
    /// pushes the median to the mod on the same cadence.
    /// </summary>
    private void OnClockSample(long t0, long t1, long t2, long t3)
    {
        double offsetMs = ((t1 - t0) + (t2 - t3)) / 2.0 / TimeSpan.TicksPerMillisecond;
        double rttMs    = ((t3 - t0) - (t2 - t1)) / (double)TimeSpan.TicksPerMillisecond;
        if (rttMs < 0 || rttMs > 5000) return;   // a wall-clock step landed mid-sample; not a measurement
        double off, rtt; int n; bool logDue;
        lock (_clockLock)
        {
            _clockSamples.Add((offsetMs, rttMs));
            if (_clockSamples.Count > ClockSamplesKept) _clockSamples.RemoveAt(0);
            _clockSampleCount++;
            var offs = _clockSamples.Select(s => s.OffsetMs).OrderBy(v => v).ToArray();
            var rtts = _clockSamples.Select(s => s.RttMs).OrderBy(v => v).ToArray();
            off = offs[offs.Length / 2];
            rtt = rtts[rtts.Length / 2];
            _clockOffsetMs = off;
            _clockRttMedianMs = rtt;
            n = _clockSampleCount;
            long now = Stopwatch.GetTimestamp();
            logDue = n == 1 || n == 5 || (now - _lastClockLogTimestamp) >= Stopwatch.Frequency * 30;
            if (logDue) _lastClockLogTimestamp = now;
        }
        TeeTextWriter.ClockOffsetMs = off;
        if (!logDue) return;
        Console.WriteLine(FormattableString.Invariant(
            $"MP-CLOCK offset_ms={off:F1} rtt_ms={rtt:F1} n={n} sample_offset_ms={offsetMs:F1} sample_rtt_ms={rttMs:F1}"));
        _ = ExecLuaAsync(FormattableString.Invariant(
            $"if KCD2MP_SetClockOffset then KCD2MP_SetClockOffset({off:F1},{rtt:F1},{n}) end"));
    }

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
                await WritePacketAsync(stream, packet, ct);

                // WO-98 Phase 1: one clock-offset sample per ping. Stamped
                // immediately before the write so t0 is as close to the wire
                // as this code can get it.
                var cs = new byte[3 + Protocol.ClockSyncUpPayloadLen];
                cs[0] = Protocol.ClockSyncUp;
                BinaryPrimitives.WriteUInt16LittleEndian(cs.AsSpan(1), (ushort)Protocol.ClockSyncUpPayloadLen);
                BinaryPrimitives.WriteInt64LittleEndian(cs.AsSpan(3), DateTime.UtcNow.Ticks);
                await WritePacketAsync(stream, cs, ct);
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
        long lastSentTimestamp = 0; // zero forces the first successful poll to send
        var heartbeatInterval = TimeSpan.FromSeconds(Protocol.AppearanceHeartbeatSeconds);

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var current = await _transport.ReadEquippedItemClassesAsync(ct);
                if (current is null)
                {
                    // WO-59: a failed read (either endpoint timed out) is not
                    // an empty outfit. Acting on it was the host-outbound half
                    // of the one-way clothing asymmetry: the busy host's
                    // partial reads went out as real changes and peers
                    // stripped half the outfit. Skip the poll; the next good
                    // read diffs against _lastSentAppearance and self-heals.
                    if (!_appearanceReadDown)
                    {
                        _appearanceReadDown = true;
                        Console.WriteLine("[appearance] local equipped-set read failed -- skipping polls until it answers again");
                    }
                }
                else if (current.Length > 0)
                {
                    if (_appearanceReadDown)
                    {
                        _appearanceReadDown = false;
                        Console.WriteLine("[appearance] local equipped-set read recovered");
                    }
                    var currentSet = new HashSet<Guid>(current);
                    bool changed = _lastSentAppearance is null || !currentSet.SetEquals(_lastSentAppearance);
                    bool heartbeatDue = lastSentTimestamp == 0
                        || Stopwatch.GetElapsedTime(lastSentTimestamp) >= heartbeatInterval;
                    bool forced = _forceAppearanceResync;

                    if (changed || heartbeatDue || forced)
                    {
                        var items = currentSet.Count <= Protocol.MaxAppearanceItems
                            ? [.. currentSet]
                            : currentSet.Take(Protocol.MaxAppearanceItems).ToArray();
                        await SendAppearanceAsync(stream, items, ct);
                        _lastSentAppearance = currentSet;
                        lastSentTimestamp = Stopwatch.GetTimestamp();
                        _forceAppearanceResync = false;
                        Console.WriteLine($"[appearance] sent {items.Length} item class(es)" +
                            (forced ? " (forced)" : changed ? "" : " (heartbeat)"));
                    }
                }
            }
            catch (Exception ex) { Console.WriteLine($"[appearance] poll failed: {ex.Message}"); }

            try { await Task.Delay(AppearancePollMs, ct); }
            catch (OperationCanceledException) { break; }
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
    /// WO-40 Phase 10: quest-item ALIAS classes -> their real source item.
    /// The 2026-08-18 session's clothing failures were item-specific, not
    /// directional-by-architecture: PB's outfit contained several
    /// alias_prepadeni_* rows (ItemAlias entries, some IsQuestItem="true"),
    /// and an alias class can fail to create/equip/render on a ghost soul
    /// (observed: alias_prepadeni_collarChain never equipped through four
    /// full 10 s retry cycles). An alias looks identical to its source item,
    /// so receivers substitute the source class before equipping. All 40
    /// ItemAlias rows from the shipped item.xml (this game version).
    /// </summary>
    private static readonly Dictionary<Guid, Guid> ItemAliasToSource = new()
    {
        [Guid.Parse("08c35fd2-9f7d-427e-bbfa-007d51773940")] = Guid.Parse("dea2883f-6bd9-4f6e-bae8-80322d428652"),
        [Guid.Parse("127b31c2-a47a-45d7-927b-94eadd40a61c")] = Guid.Parse("505b8feb-9447-462f-ab3d-68557f89d9f3"),
        [Guid.Parse("205aec51-1cde-4618-95c2-84c4ba8ab83d")] = Guid.Parse("6dc80a04-dad0-4259-a854-e085caa74cc1"),
        [Guid.Parse("25893637-c2a6-45c1-8de3-0371dd49f7bb")] = Guid.Parse("07016792-531f-4ef2-8c3c-ea7566326c04"),
        [Guid.Parse("292a24a8-556e-43ff-ac73-ddef833399fb")] = Guid.Parse("3b97b6ed-09dd-428c-ad6b-b0888ac0ec1b"),
        [Guid.Parse("2ebd6f82-4495-47df-8079-d79ee1470cd2")] = Guid.Parse("0b4e244a-e3de-4502-afd0-fb7fe309629a"),
        [Guid.Parse("2f13a4b9-22c1-40b3-95df-a1436eb07577")] = Guid.Parse("036661e4-4556-4295-82f3-264e48cb2d49"),
        [Guid.Parse("3269615a-4b22-4f39-8f1f-e33bb44ea1a7")] = Guid.Parse("f879ac63-2ce2-4114-83a2-89643c1ed102"),
        [Guid.Parse("33d169b5-b511-4149-ae1b-96d964ddd15a")] = Guid.Parse("ec7148ad-7998-455d-ade8-7bddf358d515"),
        [Guid.Parse("391b0fdc-b7a2-443a-9dc6-3c51cd11e3f1")] = Guid.Parse("81e27f41-709f-47c8-96b3-8f8c9619d2fa"),
        [Guid.Parse("3fc9d5f4-1e24-4d52-b4ea-64d79565d973")] = Guid.Parse("ab25a50a-7836-47a9-acb2-5fd93684b8c5"),
        [Guid.Parse("45a8290d-4491-43bc-8d2e-c5962b94ed50")] = Guid.Parse("6f6bc011-d298-4f69-8877-71f94abe6d9e"),
        [Guid.Parse("469fdbf9-4e6a-4ab6-b52b-b7ffb4241aa8")] = Guid.Parse("40411559-a4bc-44e7-8f2e-8d4d510426e5"),
        [Guid.Parse("4ee86b89-aa4e-49b5-99a6-60617996ac19")] = Guid.Parse("942a42a0-5c46-4c46-983a-71d86adb43c4"),
        [Guid.Parse("556de5e7-350a-4b85-963d-6d6753f0ced9")] = Guid.Parse("272357ec-8722-4b1d-9ee7-03f29ab465ef"),
        [Guid.Parse("5bf2deb5-22b7-4d21-9f37-7892205fd204")] = Guid.Parse("18f3756f-9d76-48a4-afa5-72f4ccc0e16b"),
        [Guid.Parse("5e90d505-f647-4fbb-9a82-a9bfa1633e19")] = Guid.Parse("56271b31-57c1-443a-8d97-9524ee2a8240"),
        [Guid.Parse("6a5aba05-bbb5-45f6-83a8-c45128c586c5")] = Guid.Parse("2529e246-6f1b-4529-8d6b-64245207bae8"),
        [Guid.Parse("73b693a0-8dda-456e-8590-a2f291a1bccc")] = Guid.Parse("29a4f58e-6e00-4f9c-9273-1a76e0eccff0"),
        [Guid.Parse("7857db34-2407-4585-a4a7-d7546be3cf81")] = Guid.Parse("4ea3ec22-970d-4ac7-b802-e801e0340253"),
        [Guid.Parse("7b31ad0f-1443-4421-a43f-f380dde5bdf0")] = Guid.Parse("3a640e5d-d8bd-4e8b-b61d-8cd5180e79e7"),
        [Guid.Parse("7d45902e-57ea-43e7-96bc-71dc79caedae")] = Guid.Parse("942a42a0-5c46-4c46-983a-71d86adb43c4"),
        [Guid.Parse("a4d57e1d-217a-4f02-84a2-4052b4cf150a")] = Guid.Parse("a8723887-ac6e-45a0-a6a4-0cf905716b6d"),
        [Guid.Parse("a8d552a9-3f9b-4e4e-b032-7328bdac5d96")] = Guid.Parse("8662ab7a-6af0-468a-8bce-a1a8768c24b7"),
        [Guid.Parse("ab5b3ad5-5bb5-4fe9-a5bb-8ee1c4f713b5")] = Guid.Parse("0a8b54b4-93f5-4b21-bb1e-4bc94b9724b4"),
        [Guid.Parse("ac508737-02c0-4780-a226-32975ed1b2f4")] = Guid.Parse("f2e16499-8a27-4acc-a4af-f29e00300507"),
        [Guid.Parse("b24cef83-a8d7-4d2a-9ae0-079beccfa9df")] = Guid.Parse("3a640e5d-d8bd-4e8b-b61d-8cd5180e79e7"),
        [Guid.Parse("b5704a7a-2cd7-41c0-9705-4df6ca723d21")] = Guid.Parse("0cb47176-06c5-42a9-8d70-969e917eb999"),
        [Guid.Parse("b7ff26f3-24a4-46c2-97b8-655da1827190")] = Guid.Parse("42e54d97-6e63-4e50-a09d-325ef4dd2286"),
        [Guid.Parse("b862b26e-0ec4-4932-89ca-e99c05c970e1")] = Guid.Parse("a363573e-57dd-4eda-9b44-d9d9ddf47a5d"),
        [Guid.Parse("b867dd0e-1bfe-40e9-b114-4b126a3ff1b0")] = Guid.Parse("c164f346-0463-4116-b790-094b11274e5e"),
        [Guid.Parse("c1dd4160-f2bd-4451-87c0-05ccdcf1be0f")] = Guid.Parse("3c056762-3e14-471a-8f0e-8d57919fb9c4"),
        [Guid.Parse("c86aa334-66e2-43f4-8fbf-1f65bdc09dbe")] = Guid.Parse("059893ea-3aef-48b3-b1ce-7eb3391fa028"),
        [Guid.Parse("cb8ab8cb-949a-4e9f-910a-0a7dfd5b9cac")] = Guid.Parse("4835b390-05a4-42d8-a77d-d4fb30ea03d9"),
        [Guid.Parse("cbac5af5-ce2a-43fc-acf9-e979fda27915")] = Guid.Parse("272357ec-8722-4b1d-9ee7-03f29ab465ef"),
        [Guid.Parse("cd7ac55b-4bda-43d6-a58d-331a30733eda")] = Guid.Parse("1113ab25-a055-478e-b0c9-42b5d0cb2c6d"),
        [Guid.Parse("d192726b-1170-47fb-aa1a-300b9aad7d4a")] = Guid.Parse("ea84be32-b3fc-4dfa-8dab-7169bd9e441d"),
        [Guid.Parse("d6ead753-0660-491a-b093-8654290841cd")] = Guid.Parse("5dd0afa5-3c76-475c-9775-6ed5c69132fd"),
        [Guid.Parse("e485dff2-7673-4b2b-9f5e-770b5bbcd800")] = Guid.Parse("d7b58b33-f452-4408-ba18-e8618eb3f1dd"),
        [Guid.Parse("ef6eb320-91c3-4f8e-a5c5-3640fe19a0da")] = Guid.Parse("4ea3ec22-970d-4ac7-b802-e801e0340253"),
    };

    /// <summary>
    /// WO-47: the swing spec for this ghost's currently-synced weapon, from
    /// the shipped-table catalog; the WO-46 longsword constant when the
    /// catalog is unavailable, still loading, or has no row for the weapon.
    /// The appearance set is seeded with the spawn preset (longsword), so a
    /// ghost that has not yet received an Appearance packet resolves to the
    /// longsword rows -- the same visual WO-46 shipped.
    /// </summary>
    /// <summary>
    /// WO-47: the ghost's equipped Oversized-slot item class (halberd/polearm),
    /// or null when it has none / the catalog is unavailable.
    /// </summary>
    private Guid? OversizedItemFor(byte ghostId)
    {
        var catalog = _swingCatalog.IsCompletedSuccessfully ? _swingCatalog.Result : null;
        if (catalog is null || !_ghostAppearance.TryGetValue(ghostId, out var applied))
            return null;
        Guid[] snapshot;
        lock (applied) snapshot = [.. applied];
        return catalog.OversizedItemOf(snapshot);
    }

    private string ResolveSwingSpec(byte ghostId)
    {
        var catalog = _swingCatalog.IsCompletedSuccessfully ? _swingCatalog.Result : null;
        if (catalog is null || !_ghostAppearance.TryGetValue(ghostId, out var applied))
            return NativeSwingFragmentSpec;

        Guid[] snapshot;
        lock (applied) snapshot = [.. applied];
        int idx = _ghostSwingIndex.AddOrUpdate(ghostId, 0, static (_, v) => v + 1);
        string? spec = catalog.SpecFor(snapshot, idx, out string weaponName);
        if (spec is null)
        {
            Console.WriteLine($"[combatviz] ghost {ghostId}: no table row for its weapon set -- longsword fallback");
            return NativeSwingFragmentSpec;
        }
        Console.WriteLine($"[combatviz] ghost {ghostId} swing as {weaponName}: {spec}");
        return spec;
    }

    /// <summary>
    /// WO-49: reads the LOCAL copy of a puppeted NPC's own equipped item
    /// classes off the hot path. Empty (soul not addressable by entity name,
    /// REST down) leaves no entry -- the swing path then uses the WO-46
    /// longsword constant, the same degradation a pre-appearance ghost gets.
    /// </summary>
    private void RefreshNpcEquipped(string npcName)
    {
        _ = Task.Run(async () =>
        {
            try
            {
                var set = await _transport.ReadGhostEquippedItemClassesAsync(npcName);
                if (set is { Length: > 0 })
                {
                    _npcEquipped[npcName] = set;
                    Console.WriteLine($"[npcsync] {npcName}: {set.Length} equipped item class(es) read for swing resolution");
                    // An Oversized main-hand (halberd/polearm) never attaches
                    // through DrawWeapon() (WO-47) -- hand the guid to the
                    // puppet tick so its draw goes through DrawFromInventory
                    // INSTEAD (the WO-47 ordering trap: after is too late).
                    var catalog = _swingCatalog.IsCompletedSuccessfully ? _swingCatalog.Result : null;
                    if (catalog?.OversizedItemOf(set) is Guid npcOversized)
                        await ExecLuaAsync($"if KCD2MP_NpcSetOversized then KCD2MP_NpcSetOversized(\"{npcName}\",\"{npcOversized}\") end");
                }
                else
                {
                    Console.WriteLine($"[npcsync] {npcName}: equipped-set read {(set is null ? "failed" : "came back empty")} -- native swings will use the longsword fallback row");
                }
            }
            catch (Exception ex)
            {
                Console.WriteLine($"[npcsync] {npcName}: equipped-set read failed: {ex.Message}");
            }
        });
    }

    /// <summary>
    /// WO-49: the swing spec for a puppeted NPC, resolved from the LOCAL
    /// copy's own equipment through the same shipped-table catalog as ghosts
    /// -- the observer's copy swings with the weapon visible in the
    /// observer's world. The WO-46 constant when nothing resolves.
    /// </summary>
    private string ResolveNpcSwingSpec(string npcName)
    {
        var catalog = _swingCatalog.IsCompletedSuccessfully ? _swingCatalog.Result : null;
        if (catalog is null || !_npcEquipped.TryGetValue(npcName, out var equipped) || equipped.Length == 0)
            return NativeSwingFragmentSpec;

        int idx = _npcSwingIndex.AddOrUpdate(npcName, 0, static (_, v) => v + 1);

        // Consistency with the draw: when an Oversized item is equipped the
        // puppet tick drew THAT (DrawFromInventory), so the swing must use its
        // class's rows -- SpecFor's min-class-first pick would choose a
        // sidearm's rows over the halberd visibly in hand.
        if (catalog.OversizedItemOf(equipped) is Guid oversized
            && catalog.WeaponClassOfItem(oversized) is int oversizedClass)
        {
            var rows = catalog.RowsFor(oversizedClass, hasShield: false, hasTorch: false);
            if (rows.Count > 0)
            {
                string ospec = rows[((idx % rows.Count) + rows.Count) % rows.Count].Spec;
                Console.WriteLine($"[npcsync] {npcName} swing as {catalog.WeaponClassName(oversizedClass)}: {ospec}");
                return ospec;
            }
        }

        string? spec = catalog.SpecFor(equipped, idx, out string weaponName);
        if (spec is null)
        {
            Console.WriteLine($"[npcsync] {npcName}: no table row for its equipped set -- longsword fallback");
            return NativeSwingFragmentSpec;
        }
        Console.WriteLine($"[npcsync] {npcName} swing as {weaponName}: {spec}");
        return spec;
    }

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
        // WO-40 Phase 10: substitute quest-item aliases with their real
        // source items before any diffing -- the alias class is what fails.
        for (int i = 0; i < target.Length; i++)
        {
            if (ItemAliasToSource.TryGetValue(target[i], out var src))
            {
                Console.WriteLine($"[appearance] ghost {ghostId}: alias {target[i]} -> source {src}");
                target[i] = src;
            }
        }
        target = target.Distinct().ToArray();

        string soulName = $"kcd2mp_{ghostId}";
        var applied = _ghostAppearance.GetOrAdd(ghostId, static _ => [.. GhostSpawnPresetItems]);
        // The preset's items are already sitting in the ghost's inventory from
        // spawn (EquipClothingPreset put them there) -- CreateItems must never
        // run for them again.
        var known = _ghostKnownItemClasses.GetOrAdd(ghostId, static _ => [.. GhostSpawnPresetItems]);
        var targetSet = new HashSet<Guid>(target);

        List<Guid> toRemove;
        List<Guid> toAdd;
        var neverEquips = _ghostNeverEquips.GetOrAdd(ghostId, static _ => []);
        lock (applied)
        {
            toRemove = applied.Except(targetSet).ToList();
            lock (neverEquips)
            {
                // WO-59: prune expired blacklist entries so a transient
                // failure stops suppressing once its TTL runs out.
                var nowUtc = DateTime.UtcNow;
                foreach (var expired in neverEquips.Where(kv => kv.Value <= nowUtc).Select(kv => kv.Key).ToList())
                    neverEquips.Remove(expired);
                toAdd = targetSet.Except(applied).Where(c => !neverEquips.ContainsKey(c)).ToList();
            }
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
            var actualArr = await _transport.ReadGhostEquippedItemClassesAsync(soulName, ct);
            if (actualArr is null)
            {
                // WO-59: the read failed -- we learned nothing about what is
                // equipped. Re-equipping blind would be noise; skip this
                // round and let the next delay try again.
                Console.WriteLine($"[appearance] ghost {ghostId}: verify read failed -- skipping this round");
                continue;
            }
            var actual = new HashSet<Guid>(actualArr);
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
        var finalArr = await _transport.ReadGhostEquippedItemClassesAsync(soulName, ct);
        if (finalArr is null)
        {
            // WO-59: the final read failed, so nothing was PROVEN unequippable.
            // The pre-WO-58 behaviour is correct here: drop the items from
            // `applied` so the next heartbeat retries, and blacklist nothing.
            // Blacklisting on a timed-out read mass-suppressed whole outfits
            // for the ghost's lifetime -- the receiver-side half of the
            // one-way clothing asymmetry.
            Console.WriteLine($"[appearance] ghost {ghostId}: final verify read failed -- {pending.Count} item(s) left for the next heartbeat, none blacklisted");
            lock (applied) foreach (var cls in pending) applied.Remove(cls);
            return;
        }
        var final = new HashSet<Guid>(finalArr);
        var blacklist = _ghostNeverEquips.GetOrAdd(ghostId, static _ => []);
        foreach (var cls in pending)
        {
            if (final.Contains(cls)) continue;
            // WO-58: one exhausted schedule is the retry budget. Dropping it
            // from `applied` alone put it right back into the next
            // heartbeat's diff, which re-ran the whole 10 s retry cycle
            // forever (observed all session on both machines, 2026-08-25).
            // WO-59: the suppression now expires (NeverEquipTtl) instead of
            // lasting the ghost's lifetime.
            Console.WriteLine($"[appearance] ghost {ghostId}: {cls} never equipped after {AppearanceRetryDelaysMs.Sum()}ms of retrying -- suppressing it for {NeverEquipTtl.TotalMinutes:F0} min");
            lock (applied) applied.Remove(cls);
            lock (blacklist) blacklist[cls] = DateTime.UtcNow + NeverEquipTtl;
        }
    }

    // -------------------------------------------------------------------------
    // Pause mitigation (WO-11)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Sends a PauseUp packet if the OR of the two local sources
    /// (<see cref="_localAutoPaused"/>, <see cref="_localManualPaused"/>)
    /// actually changed since the last send. Both sources call this on every
    /// change rather than computing the OR themselves, so a lock here is the
    /// one place that has to reason about the two racing -- the tail
    /// transport's thread (auto) and the log-tail event thread (manual, via
    /// <see cref="OnGameEvent"/>) can both fire in close succession.
    /// </summary>
    private async Task SendPauseIfChangedAsync(NetworkStream stream, CancellationToken ct)
    {
        await _pauseSendLock.WaitAsync(ct);
        try
        {
            bool aggregate = _localAutoPaused || _localManualPaused;
            if (_lastSentPauseState == aggregate) return;
            _lastSentPauseState = aggregate;

            var packet = new byte[3 + Protocol.PauseUpPayloadLen];
            packet[0] = Protocol.PauseUp;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.PauseUpPayloadLen);
            packet[3] = aggregate ? Protocol.PauseStateEntered : Protocol.PauseStateExited;
            await WritePacketAsync(stream, packet, ct);
            Console.WriteLine($"[pause] local state -> {(aggregate ? "entered" : "exited")}");
        }
        catch (Exception ex) { Console.WriteLine($"[pause] send failed: {ex.Message}"); }
        finally { _pauseSendLock.Release(); }
    }

    // -------------------------------------------------------------------------
    // Time-skip sync (WO-38 Phase 1)
    // -------------------------------------------------------------------------

    /// <summary>Puts one TimeSkipUp (0x28) on the wire.</summary>
    private async Task SendTimeSkipAsync(NetworkStream stream, byte phase, byte kind, uint worldTime, CancellationToken ct)
    {
        try
        {
            var packet = new byte[3 + Protocol.TimeSkipUpPayloadLen];
            packet[0] = Protocol.TimeSkipUp;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.TimeSkipUpPayloadLen);
            packet[3] = phase;
            packet[4] = kind;
            BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(5), worldTime);
            await WritePacketAsync(stream, packet, ct);
            Console.WriteLine($"[timeskip] sent {phase switch { Protocol.TimeSkipPhaseStart => "start", Protocol.TimeSkipPhaseSync => "sync", _ => "done" }} kind={kind} t={worldTime}");
        }
        catch (Exception ex) { Console.WriteLine($"[timeskip] send failed: {ex.Message}"); }
    }

    /// <summary>
    /// Consumes one time_now reading from the mod (Calendar.GetWorldTime()).
    /// Two consumers share the one reading: a just-finished local skip turns it
    /// into our TimeSkipUp(done), and otherwise it feeds the clock-jump
    /// watcher that catches marker-less advances (fast travel).
    /// </summary>
    private void OnWorldTimeReading(uint worldTime)
    {
        var now = DateTime.UtcNow;

        if (_awaitSkipDoneTime)
        {
            _awaitSkipDoneTime = false;
            _ = _sendTimeSkip?.Invoke(Protocol.TimeSkipPhaseDone, _localSkipKind, worldTime);
            // WO-102 Phase 6: a finished sleep/wait is a resync point.
            _ = RequestNpcResyncAsync(NpcResyncReason.Sleep, _resyncStream, CancellationToken.None);
            _localSkipKind = Protocol.TimeSkipKindUnknown;
            // Our own skip may have raced a peer's: apply the queued target
            // now that our skip is over. Forward-only, so a stale one is a no-op.
            ApplyPendingTimeSkipIfAny();
            // The jump watcher must not re-report the advance the skip caused.
            _lastPolledWorldTime = Math.Max(worldTime, _lastPolledWorldTime ?? 0);
            _lastPollUtc = now;
            _fastAdvanceActive = false;
            return;
        }

        // WO-88 finding 4: an outstanding reload convergence is checked
        // against every reading before the jump watcher sees it. Until the
        // clock reads at/past the target the apply is re-sent (forward-only in
        // Lua, so a late duplicate is harmless); once it does, the reading is
        // the new baseline and the forward jump it represents is ours.
        switch (ReloadReconcile.EvaluateConvergence(_reloadConvergeTarget, worldTime,
                    TimeJumpThresholdSeconds, now, _reloadConvergeDeadlineUtc))
        {
            case ReloadReconcile.ConvergeStep.Satisfied:
                Console.WriteLine($"[timeskip] reload: converged (clock {worldTime} >= target {_reloadConvergeTarget} - {TimeJumpThresholdSeconds})");
                _reloadConvergeTarget = null;
                _fastAdvanceActive = false;
                _lastPolledWorldTime = worldTime;
                _lastPollUtc = now;
                return;
            case ReloadReconcile.ConvergeStep.Resend:
                Console.WriteLine($"[timeskip] reload: clock still {worldTime}, target {_reloadConvergeTarget} not applied yet -- re-sending the convergence");
                _ = SendReloadConvergenceAsync(_reloadConvergeTarget!.Value);
                _suppressJumpUntilUtc = now.AddSeconds(30);
                _lastPolledWorldTime = worldTime;
                _lastPollUtc = now;
                return;
            case ReloadReconcile.ConvergeStep.Expired:
                Console.WriteLine($"[timeskip] reload: convergence to {_reloadConvergeTarget} never landed within {ReloadConvergeWindow.TotalSeconds:F0}s -- giving up (clock {worldTime}); the next peer announce will retry");
                _reloadConvergeTarget = null;
                break;
        }

        // WO-59: announce our clock to the session (connect-time sync, or a
        // new peer just appeared). Quiet at the relay, forward-only at every
        // receiver -- a behind player converges, an ahead player no-ops.
        if (_timeSyncPending && !_localSkipActive)
        {
            _timeSyncPending = false;
            Console.WriteLine($"[timeskip] announcing clock t={worldTime} (connect/new-peer sync)");
            _ = _sendTimeSkip?.Invoke(Protocol.TimeSkipPhaseSync, Protocol.TimeSkipKindUnknown, worldTime);
            _ = RequestNpcResyncAsync(NpcResyncReason.NewPeer, _resyncStream, CancellationToken.None);   // WO-102 Phase 6
        }

        if (_lastPolledWorldTime is uint last)
        {
            double elapsedReal = (now - _lastPollUtc).TotalSeconds;
            // Allowance: the largest natural advance the elapsed real time
            // can explain (ratio ~15, doubled for headroom) plus the flat
            // jump threshold.
            uint allowance = TimeJumpThresholdSeconds + (uint)Math.Max(0, elapsedReal * 30);
            bool suppressed = now < _suppressJumpUntilUtc || _localSkipActive;

            if (!suppressed && worldTime > last && worldTime - last > allowance)
            {
                if (!_fastAdvanceActive)
                {
                    _fastAdvanceActive = true;
                    _fastAdvanceStartTime = last;
                    Console.WriteLine($"[timeskip] clock jumping ({last} -> {worldTime}); waiting for it to settle{CatchupTag()}");
                }
            }
            else if (worldTime < last && last - worldTime > TimeJumpThresholdSeconds)
            {
                // WO-40 Phase 4: the clock went BACKWARD -- only a save load
                // does that. Never broadcast it (receivers cannot go back);
                // instead converge this client forward to the session clock.
                _fastAdvanceActive = false;
                Console.WriteLine($"[timeskip] clock went backward ({last} -> {worldTime}) -- save reload detected{CatchupTag()}");
                _ = OnReloadDetectedAsync(last, worldTime);
            }
            else if (_fastAdvanceActive)
            {
                _fastAdvanceActive = false;
                if (suppressed)
                {
                    // WO-40: a jump that settles inside a marker skip or an
                    // inbound-apply window is that event's own advance, and
                    // reporting it here double-reports one skip (observed
                    // 2026-08-18 19:44:23: one bed sleep emitted both kind=2
                    // and kind=0). Swallow it; the marker path reports it.
                    Console.WriteLine($"[timeskip] clock jump settled ({_fastAdvanceStartTime} -> {worldTime}) inside a skip/apply window -- swallowed");
                }
                else
                {
                    // The advance settled: report the whole jump as one skip.
                    Console.WriteLine($"[timeskip] clock jump settled ({_fastAdvanceStartTime} -> {worldTime}); reporting");
                    _ = ReportClockJumpAsync(worldTime);
                }
            }
        }

        _lastPolledWorldTime = worldTime;
        _lastPollUtc = now;
    }

    /// <summary>
    /// Reports a settled marker-less clock jump as a start+done pair. The
    /// relay treats a bare done with no active skip as an instant skip; the
    /// start is sent anyway so that a concurrent sleeper still wins the
    /// active-skip claim deterministically by arrival order.
    /// </summary>
    private async Task ReportClockJumpAsync(uint worldTime)
    {
        var send = _sendTimeSkip;
        if (send is null) return;
        await send(Protocol.TimeSkipPhaseStart, Protocol.TimeSkipKindFastTravel, 0);
        await send(Protocol.TimeSkipPhaseDone, Protocol.TimeSkipKindFastTravel, worldTime);
        await RequestNpcResyncAsync(NpcResyncReason.FastTravel, _resyncStream, CancellationToken.None);   // WO-102 Phase 6
    }

    /// <summary>
    /// WO-40 Phase 4: a save load moved this client's clock backward. The
    /// engine ignores backward writes on every receiver, so the only way the
    /// session can converge is for the RELOADER to move forward again. The
    /// best-known session clock is the max of (a) our own pre-reload clock
    /// (seconds stale at most) and (b) the newest peer-reported skip time,
    /// extrapolated by the world-time ratio for the real time since. With no
    /// live peers the clock is left alone -- a solo reload means the player
    /// wanted that earlier time.
    /// </summary>
    private async Task OnReloadDetectedAsync(uint preReloadTime, uint currentTime)
    {
        // WO-102 Phase 6: a reload replaced this machine's NPC state wholesale;
        // ask the owner for a burst (or burst, if this is the owner).
        _ = RequestNpcResyncAsync(NpcResyncReason.Reload, _resyncStream, CancellationToken.None);
        // A different save means different per-save Soul.Guids -- both
        // damage-translation caches are stale the moment a reload happens.
        _soulNameByGuid.Clear();
        _soulGuidByName.Clear();
        _dmgGuard.InvalidatePlayerGuid();          // WO-99 Phase 0: new save = new PlayerSoul guid
        _dmgGuardIdentityAtUtc = DateTime.MinValue;

        var now = DateTime.UtcNow;
        bool hasLivePeers = _peerLastSeenUtc.Any(kv => (now - kv.Value) < TimeSpan.FromMinutes(2));
        if (!hasLivePeers)
        {
            Console.WriteLine("[timeskip] reload: no live peers -- leaving the reloaded clock alone");
            return;
        }

        uint candidate = preReloadTime;
        if (_peerWorldTimeUtc != DateTime.MinValue)
        {
            double elapsed = (now - _peerWorldTimeUtc).TotalSeconds;
            if (elapsed >= 0 && elapsed < 3600)
            {
                uint peerNow = _peerWorldTime + (uint)(elapsed * WorldTimeRatio);
                if (peerNow > candidate) candidate = peerNow;
            }
        }

        if (candidate <= currentTime + TimeJumpThresholdSeconds)
        {
            Console.WriteLine($"[timeskip] reload: session clock ({candidate}) is within threshold of the reloaded clock ({currentTime}) -- nothing to converge");
            return;
        }

        Console.WriteLine($"[timeskip] reload: converging forward to session clock {candidate} (reloaded to {currentTime}, was {preReloadTime})");
        // WO-88 finding 4: keep the target outstanding until a reading proves
        // the write landed. OnWorldTimeReading re-sends on every poll until
        // then (see ReloadReconcile.EvaluateConvergence).
        _reloadConvergeTarget = candidate;
        _reloadConvergeDeadlineUtc = now + ReloadConvergeWindow;
        await SendReloadConvergenceAsync(candidate);

        // The convergence write must not read as a fresh local jump.
        _suppressJumpUntilUtc = DateTime.UtcNow.AddSeconds(30);
        // WO-88: the baseline stays at the RELOADED value on purpose. The old
        // code set it to the target here, and OnWorldTimeReading's own tail
        // then overwrote it with the reloaded reading anyway (this method is
        // fire-and-forget from there), so a lost apply was never re-detected.
        // The outstanding target above is what now carries that knowledge.
        _lastPolledWorldTime = currentTime;
        _lastPollUtc = DateTime.UtcNow;
    }

    /// <summary>
    /// One forward-only convergence write. Batched like every other Lua call,
    /// so it rides the next flush -- and a flush that meets the post-load REST
    /// outage is dropped without a word (HttpGameTransport.FlushAsync is
    /// fire-and-forget by design). That is why the caller keeps the target
    /// outstanding and re-sends from each clock reading until it lands.
    /// </summary>
    private async Task SendReloadConvergenceAsync(uint target)
    {
        try
        {
            await ExecLuaAsync(string.Format(CultureInfo.InvariantCulture,
                "if KCD2MP_ApplyTimeSkip then KCD2MP_ApplyTimeSkip(\"session\",{0},{1},true) end " +
                "if KCD2MP_ShowInteractionMsg then KCD2MP_ShowInteractionMsg(\"Clock re-synced to the session's time\") end",
                Protocol.TimeSkipKindUnknown, target));
        }
        catch { /* game might have unloaded */ }
    }

    // -------------------------------------------------------------------------
    // Horse identity (WO-38 Phase 5)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Puts one HorseInfoUp (0x2A) on the wire. An empty name means
    /// dismounted, or a mount whose identity the mod could not read.
    /// </summary>
    // -------------------------------------------------------------------------
    // Story progress (WO-90)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Puts one StoryBeatUp (0x37) on the wire: this client just crossed a
    /// quest objective. Pure telemetry -- the receiver only ever reports it.
    /// </summary>
    private async Task SendStoryBeatAsync(NetworkStream stream, byte kind, string text, CancellationToken ct)
    {
        var body = StoryBeat.BuildUpPayload(kind, text);
        var packet = new byte[3 + body.Length];
        packet[0] = Protocol.StoryBeatUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)body.Length);
        Buffer.BlockCopy(body, 0, packet, 3, body.Length);
        await WritePacketAsync(stream, packet, ct);
    }

    /// <summary>
    /// Our own checkpoint. Records it, tells the session, and re-checks every
    /// known peer for divergence -- crossing a beat can just as easily CLOSE
    /// a gap as open one, and a player who has caught up should stop being
    /// told they are behind.
    /// </summary>
    private void OnLocalStoryBeat(string marker)
    {
        if (string.Equals(marker, _localObjective, StringComparison.Ordinal)) return;
        _localObjective = marker;
        Console.WriteLine($"[story] local objective -> {StoryBeat.Humanize(marker)}");

        _ = _sendStoryBeat?.Invoke(Protocol.StoryBeatKindObjective, marker);

        foreach (var kv in _peerObjective)
            ReportStoryDivergence(kv.Key, kv.Value);

        // WO-94: tell the mod which main quest we are on (it decides whether
        // that name is in its registry), and withdraw any prompt whose pair
        // no longer differs.
        _localQuest = StoryBeat.TryQuestNameFromMarker(marker);
        PushQuestContext();
        ReevaluateQuestPrompts();

        // WO-96 Phase 2: the marker line IS the engine writing an autosave;
        // read it once it has landed and tell peers our objective states.
        _ = Task.Run(() => FingerprintAfterSaveAsync(marker));
    }

    // -------------------------------------------------------------------------
    // Shared Quests (WO-94)
    // -------------------------------------------------------------------------

    private void OnLocalLevel(string level)
    {
        if (string.Equals(level, _localLevel, StringComparison.Ordinal)) return;
        _localLevel = level;
        Console.WriteLine($"[quest] level loaded: {level}");
        PushQuestContext();
    }

    /// <summary>Level and current quest, to the mod. Idempotent; also re-sent on the 2.5 s re-arm.</summary>
    private void PushQuestContext()
    {
        if (_localLevel is string lvl)
            _ = ExecLuaAsync($"if KCD2MP_QuestSetLevel then KCD2MP_QuestSetLevel(\"{EscapeLua(lvl)}\") end");
        if (_localObjective is not null)
            _ = ExecLuaAsync($"if KCD2MP_QuestSetCurrent then KCD2MP_QuestSetCurrent(\"{EscapeLua(_localQuest ?? string.Empty)}\") end");
    }

    /// <summary>
    /// WO-96: a standing divergence survives in the agent but not in a
    /// restarted game's Lua. Re-pushed on the 2.5 s re-arm only (idempotent
    /// per pair in the mod); the live path is ReportStoryDivergence.
    /// </summary>
    private void RepushQuestDivergences()
    {
        if (_localObjective is not string mine) return;
        foreach (var kv in _peerObjective)
            if (!string.Equals(kv.Value, mine, StringComparison.Ordinal))
                SendQuestDivergence(kv.Key, kv.Value);
    }

    // -------------------------------------------------------------------------
    // Story fingerprints (WO-96 Phase 2)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Where the engine keeps saves: kcd.log's "User folder is '…'" line (read
    /// from the head of the log, since the tail starts at its end) + \saves,
    /// else the engine default under the user's profile.
    /// </summary>
    private string SavesRoot()
    {
        if (_savesRoot is not null) return _savesRoot;
        string? userFolder = null;
        if (_transport is LogTailGameTransport t) userFolder = SaveGameReader.TryReadUserFolderFromLogHead(t.LogPath);
        userFolder ??= SaveGameReader.DefaultUserFolder();
        _savesRoot = Path.Combine(userFolder, "saves");
        Console.WriteLine($"[quest] saves root: {_savesRoot}" + (Directory.Exists(_savesRoot) ? "" : " (not found -- fingerprints disabled until it appears)"));
        return _savesRoot;
    }

    /// <summary>
    /// Parses a save's ConceptState tree once and keeps the newest. Returns
    /// null when no save is readable. The file is read with sharing, never
    /// written.
    /// </summary>
    private System.Xml.XmlDocument? LoadConceptState(string path)
    {
        lock (_saveLock)
        {
            DateTime w = File.GetLastWriteTimeUtc(path);
            if (_latestConcept is not null && string.Equals(path, _latestSavePath, StringComparison.OrdinalIgnoreCase) && w == _latestSaveWriteUtc)
                return _latestConcept;
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var doc = SaveGameReader.TryReadConceptState(path);
            if (doc is null) { Console.WriteLine($"[quest] save unreadable (still being written?): {Path.GetFileName(path)}"); return null; }
            _latestConcept = doc; _latestSavePath = path; _latestSaveWriteUtc = w;
            Console.WriteLine($"[quest] parsed save {Path.GetFileName(path)} in {sw.ElapsedMilliseconds} ms");
            return doc;
        }
    }

    /// <summary>
    /// Our newest save's ConceptState tree, or null. Used to answer a peer's
    /// fingerprint for a quest we may not be on: the tree holds every quest
    /// that has ever started.
    /// </summary>
    private System.Xml.XmlDocument? LatestConceptState()
    {
        string? newest = SaveGameReader.FindNewestSave(SavesRoot());
        return newest is null ? null : LoadConceptState(newest);
    }

    /// <summary>
    /// After an own marker: wait (up to 20 s) for the autosave carrying exactly
    /// that marker to land, read our current quest's objective states from it
    /// and send them as kind 5. Silent when the quest is outside the registry.
    /// </summary>
    private async Task FingerprintAfterSaveAsync(string marker)
    {
        try
        {
            var reg = QuestObjectiveRegistry.Embedded;
            if (reg is null) return;
            var quest = reg.ByMarkerKey(StoryBeat.TryQuestNameFromMarker(marker));
            if (quest is null) return;           // side content: no fingerprint
            int seq = Interlocked.Increment(ref _fingerprintSeq);
            DateTime since = DateTime.UtcNow.AddSeconds(-30);
            string? path = null;
            for (int i = 0; i < 40 && path is null; i++)
            {
                path = SaveGameReader.FindNewestSaveForMarker(SavesRoot(), marker, since);
                if (path is null) await Task.Delay(500);
            }
            if (path is null)
            {
                Console.WriteLine($"[quest] no save carrying this marker appeared within 20 s -- fingerprint #{seq} skipped (marker {StoryBeat.Humanize(marker)})");
                return;
            }
            if (seq != _fingerprintSeq) return;   // a newer marker superseded this one
            // the file may still be closing: retry the parse briefly
            System.Xml.XmlDocument? doc = null;
            for (int i = 0; i < 6 && doc is null; i++) { doc = LoadConceptState(path); if (doc is null) await Task.Delay(500); }
            if (doc is null) return;
            var states = StoryFingerprint.Read(doc, quest);
            if (states is null) { Console.WriteLine("[quest] save has no ConceptState roots -- fingerprint skipped"); return; }
            string text = StoryFingerprint.Encode(reg.Id, quest.Key, states);
            int active = states.Count(s => s == StoryFingerprint.Active), done = states.Count(s => s == StoryFingerprint.Done);
            Console.WriteLine($"[quest] fingerprint #{seq} {quest.Code} \"{quest.Label}\" from {Path.GetFileName(path)}: {active} active, {done} done of {states.Length} -- telling peers ({text.Length} chars)");
            _ = _sendStoryBeat?.Invoke(Protocol.StoryBeatKindFingerprint, text);
            // and re-check every peer whose fingerprint we hold against the fresh save
            foreach (var kv in _peerFingerprint) ComparePeerFingerprint(kv.Key, kv.Value);
        }
        catch (Exception ex) { Console.WriteLine($"[quest] fingerprint failed: {ex.Message}"); }
    }

    /// <summary>
    /// A peer's fingerprint against our newest save for the same quest. Refuses
    /// across a registry-id mismatch (told once per peer). Tells the mod the
    /// objective-level gap; the mod toasts on change and shows it on the
    /// waiting row.
    /// </summary>
    private void ComparePeerFingerprint(byte ghostId, string text)
    {
        try
        {
            var reg = QuestObjectiveRegistry.Embedded;
            if (reg is null) return;
            string who = _ghostNames.TryGetValue(ghostId, out var dn) ? dn : $"player {ghostId}";
            if (!StoryFingerprint.TryDecode(text, out var regId, out var questKey, out var packed))
            {
                Console.WriteLine($"[quest] {who} sent a malformed fingerprint; dropped");
                return;
            }
            if (!string.Equals(regId, reg.Id, StringComparison.OrdinalIgnoreCase))
            {
                if (_peerRegistryMismatchTold.TryAdd(ghostId, true))
                {
                    Console.WriteLine($"[quest] {who} runs a different objective registry ({regId} vs ours {reg.Id}) -- objective comparison refused; only the quest marker is compared");
                    _ = ExecLuaAsync($"if KCD2MP_ShowNativeToast then KCD2MP_ShowNativeToast(\"{EscapeLua(who)} runs a different mod build -- objective comparison off\") end");
                }
                return;
            }
            var quest = reg.ByMarkerKey(questKey);
            if (quest is null) { Console.WriteLine($"[quest] {who} fingerprinted unknown quest '{questKey}'; dropped"); return; }
            var theirs = StoryFingerprint.Unpack(packed, quest.Objectives.Length);
            var doc = LatestConceptState();
            if (doc is null) { Console.WriteLine($"[quest] {who} sent a {quest.Code} fingerprint but we have no readable save to compare against"); return; }
            var ours = StoryFingerprint.Read(doc, quest);
            if (ours is null) return;
            var (theyHave, weHave, differ) = StoryFingerprint.Compare(ours, theirs);
            string theyStr = StoryFingerprint.Labels(quest, theyHave);
            string weStr = StoryFingerprint.Labels(quest, weHave);
            string gapKey = $"{quest.Key}|{theyStr}|{weStr}";
            bool changed = !_peerGapTold.TryGetValue(ghostId, out var told) || !string.Equals(told, gapKey, StringComparison.Ordinal);
            _peerGapTold[ghostId] = gapKey;
            if (changed)
            {
                if (differ.Count == 0)
                    Console.WriteLine($"[quest] objectives agree with {who} in {quest.Code} \"{quest.Label}\" ({quest.Objectives.Length} compared, save {Path.GetFileName(_latestSavePath ?? "?")})");
                else
                    Console.WriteLine($"[quest] OBJECTIVE GAP with {who} in {quest.Code} \"{quest.Label}\": they have [{theyStr}] we lack; we have [{weStr}] they lack; {differ.Count} differ in all: {StoryFingerprint.Labels(quest, differ, theirs)} (theirs) vs {StoryFingerprint.Labels(quest, differ, ours)} (ours)");
            }
            string theySpec = StoryFingerprint.Spec(quest, theyHave, theirs);
            _ = ExecLuaAsync($"if KCD2MP_QuestObjectiveGap then KCD2MP_QuestObjectiveGap(\"{ghostId}\", \"{EscapeLua(who)}\", \"{EscapeLua(quest.Key)}\", \"{EscapeLua(quest.Label)}\", \"{EscapeLua(theyStr)}\", \"{EscapeLua(weStr)}\", \"{theySpec}\") end");
        }
        catch (Exception ex) { Console.WriteLine($"[quest] fingerprint compare failed: {ex.Message}"); }
    }

    /// <summary>
    /// A peer said it is nearing a registered main-quest beat. The agent
    /// contributes the one fact only it has -- whether the two objectives are
    /// known to differ -- and hands the rest to the mod, which re-validates the
    /// path against its registry before anything reaches the screen.
    /// </summary>
    private void OnPeerApproach(byte ghostId, string path)
    {
        // WO-96: an approach is a HINT for which beat to offer, not a trigger.
        // WO-95 s5: M03 has one registered beat, so an approach-gated prompt
        // fired three times across five divergence windows. The trigger is
        // now the divergence signal; the hint only refines the destination.
        _peerApproach[ghostId] = path;
        string who = _ghostNames.TryGetValue(ghostId, out var dn) ? dn : $"player {ghostId}";
        bool diverged = _peerObjective.TryGetValue(ghostId, out var theirs)
                        && _localObjective is not null
                        && !string.Equals(theirs, _localObjective, StringComparison.Ordinal);
        Console.WriteLine($"[quest] {who} is approaching {path}" + (diverged ? " -- objectives differ, re-evaluating the offer with this beat as the hint" : " -- objectives not known to differ, hint recorded only"));
        if (diverged) SendQuestDivergence(ghostId, theirs!);
    }

    /// <summary>On any objective change: a prompt or waiting state whose pair now agrees is withdrawn.</summary>
    private void ReevaluateQuestPrompts()
    {
        foreach (var kv in _peerObjective)
        {
            bool diverged = _localObjective is not null
                            && !string.Equals(kv.Value, _localObjective, StringComparison.Ordinal);
            if (!diverged)
                _ = ExecLuaAsync($"if KCD2MP_QuestConverged then KCD2MP_QuestConverged(\"{kv.Key}\") end");
        }
    }

    /// <summary>
    /// WO-96: the one gate. Both markers known and different -> tell the mod
    /// who is behind, which quest the peer is on, and the peer's last approach
    /// hint; the mod decides between a readiness prompt and WAITING_FOR_PEER
    /// against its registry. "behind"/"ahead" come from the last marker the
    /// pair shared (whoever still sits on it is behind); "unknown" when both
    /// have moved or the pair never agreed, and the mod's production-code
    /// order takes over. Idempotent in the mod, so it is also re-pushed on the
    /// 2.5 s re-arm for a restarted game's fresh Lua.
    /// </summary>
    private void SendQuestDivergence(byte ghostId, string peerMarker)
    {
        if (_localObjective is not string mine) return;
        if (string.Equals(mine, peerMarker, StringComparison.Ordinal)) return;
        string who = _ghostNames.TryGetValue(ghostId, out var dn) ? dn : $"player {ghostId}";
        string rel = "unknown";
        if (_lastSharedObjective.TryGetValue(ghostId, out var shared))
        {
            if (string.Equals(mine, shared, StringComparison.Ordinal)) rel = "behind";
            else if (string.Equals(peerMarker, shared, StringComparison.Ordinal)) rel = "ahead";
        }
        string peerQuest = StoryBeat.TryQuestNameFromMarker(peerMarker) ?? string.Empty;
        string hint = _peerApproach.TryGetValue(ghostId, out var h) && StoryBeat.IsValidBeatPath(h) ? h : string.Empty;
        Console.WriteLine($"[quest] divergence -> mod: {who} rel={rel} peerQuest='{peerQuest}' ours='{_localQuest ?? string.Empty}' hint='{hint}'");
        _stats.StoryDivergencesPushed++;
        _ = ExecLuaAsync(
            $"if KCD2MP_QuestDivergence then KCD2MP_QuestDivergence(\"{ghostId}\", \"{EscapeLua(who)}\", \"{EscapeLua(peerQuest)}\", " +
            $"\"{EscapeLua(StoryBeat.Humanize(peerMarker))}\", \"{EscapeLua(StoryBeat.Humanize(mine))}\", \"{rel}\", \"{hint}\") end");
    }

    private void OnPeerCatchup(byte ghostId, string path, bool begin)
    {
        string who = _ghostNames.TryGetValue(ghostId, out var dn) ? dn : $"player {ghostId}";
        if (begin)
        {
            _peerCatchup[ghostId] = (path, DateTime.UtcNow);
            Console.WriteLine($"[quest] CATCH-UP FIRED BY PEER {who}: {path} -- hazard window open on this machine for {CatchupWindow.TotalSeconds:F0}s");
        }
        else
        {
            _peerCatchup.TryRemove(ghostId, out _);
            Console.WriteLine($"[quest] peer {who} catch-up window closed: {path}");
        }
        _ = ExecLuaAsync($"if KCD2MP_QuestCatchupRemote then KCD2MP_QuestCatchupRemote(\"{ghostId}\", \"{EscapeLua(who)}\", \"{path}\", {(begin ? 1 : 0)}) end");
    }

    private void OnLocalTeleport(string engineLine)
    {
        string tag = CatchupTag();
        if (tag.Length > 0)
            Console.WriteLine($"[quest] engine teleported the local player: {engineLine}{tag}");
    }

    private void OnLocalCutscene(bool active)
    {
        string tag = CatchupTag();
        if (tag.Length > 0)
            Console.WriteLine($"[quest] Rendered cutscene {(active ? "STARTED" : "ended")} on this machine{tag}");
    }

    /// <summary>
    /// Says once, on screen, when this client and a peer are at different
    /// objectives -- and says so again only when the pair changes. The point
    /// is to make an NPC behaving oddly explicable: the receiver-side
    /// divergence release in kdcmp.lua is already handing such NPCs back to
    /// the local world, silently, and this is the sentence that explains why.
    /// </summary>
    private void ReportStoryDivergence(byte ghostId, string peerMarker)
    {
        string who = _ghostNames.TryGetValue(ghostId, out var dn) ? dn : $"player {ghostId}";
        string? line = StoryBeat.DescribeDivergence(_localObjective, peerMarker, who);

        if (line is null)
        {
            // Same beat (or one side unknown): clear the latch so a later
            // divergence is reported afresh.
            if (_storyDivergenceTold.TryRemove(ghostId, out _) && _localObjective is not null)
                Console.WriteLine($"[story] {who} is on the same objective as us again");
            // WO-96: remember the marker the pair agrees on -- it decides who
            // is "behind" the next time they differ.
            if (_localObjective is string agreed && string.Equals(agreed, peerMarker, StringComparison.Ordinal))
                _lastSharedObjective[ghostId] = agreed;
            return;
        }

        string key = $"{_localObjective}{peerMarker}";
        if (_storyDivergenceTold.TryGetValue(ghostId, out var told)
            && string.Equals(told, key, StringComparison.Ordinal)) return;
        _storyDivergenceTold[ghostId] = key;

        Console.WriteLine($"[story] divergence: {line}");
        _ = ExecLuaAsync(
            $"if KCD2MP_ShowNativeToast then KCD2MP_ShowNativeToast(\"{EscapeLua(line)}\") end");
        // WO-96: the prompt / WAITING_FOR_PEER decision rides this signal, once
        // per new pair (the latch above); the mod is idempotent per pair.
        SendQuestDivergence(ghostId, peerMarker);
    }

    private async Task SendHorseInfoAsync(NetworkStream stream, string horseName, CancellationToken ct)
    {
        try
        {
            var nameBytes = Encoding.UTF8.GetBytes(horseName);
            var packet = new byte[3 + 1 + nameBytes.Length];
            packet[0] = Protocol.HorseInfoUp;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)(1 + nameBytes.Length));
            packet[3] = (byte)nameBytes.Length;
            nameBytes.CopyTo(packet, 4);
            await WritePacketAsync(stream, packet, ct);
            Console.WriteLine($"[horse] sent mount identity '{(horseName.Length == 0 ? "(none)" : horseName)}'");
        }
        catch (Exception ex) { Console.WriteLine($"[horse] send failed: {ex.Message}"); }
    }

    /// <summary>
    /// Sends one CombatEventUp (0x2C, WO-39 Phase 1): a discrete combat visual
    /// (draw/sheathe/swing/block) from the mod's combat event line. The mod
    /// already rate-limits swings; this just puts the byte on the wire.
    /// </summary>
    private async Task SendCombatEventAsync(NetworkStream stream, byte evt, ushort sid, CancellationToken ct)
    {
        try
        {
            // WO-99 Phase 4: [event:1][sid:2] -- the sender's swing counter,
            // so a `hop=sent sid=N` here matches `hop=recv sid=N` on the peer.
            var packet = new byte[3 + Protocol.CombatEventUpPayloadLenV2];
            packet[0] = Protocol.CombatEventUp;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.CombatEventUpPayloadLenV2);
            packet[3] = evt;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(4), sid);
            await WritePacketAsync(stream, packet, ct);
        }
        catch (Exception ex) { Console.WriteLine($"[combatviz] send failed: {ex.Message}"); }
    }

    // -------------------------------------------------------------------------
    // Name-addressed NPC damage (WO-40 Phase 5)
    // -------------------------------------------------------------------------

    /// <summary>Guid → soul name, cached (sender side of 0x30).</summary>
    private async Task<string?> ResolveSoulNameAsync(Guid soul, CancellationToken ct)
    {
        var now = DateTime.UtcNow;
        if (_soulNameByGuid.TryGetValue(soul, out var hit)
            && now - hit.At < (hit.Name is null ? SoulLookupNegativeTtl : SoulLookupPositiveTtl))
            return hit.Name;

        string? name = null;
        try { name = await _transport.ReadSoulNameByGuidAsync(soul, ct); } catch { }
        if (name is not null && !NpcNamePattern.IsMatch(name)) name = null;
        _soulNameByGuid[soul] = (name, now);
        return name;
    }

    /// <summary>Soul name → this install's per-save guid, cached (receiver side of 0x31).</summary>
    private async Task<Guid?> ResolveLocalSoulGuidAsync(string npcName, CancellationToken ct)
    {
        var now = DateTime.UtcNow;
        if (_soulGuidByName.TryGetValue(npcName, out var hit)
            && now - hit.At < (hit.Guid is null ? SoulLookupNegativeTtl : SoulLookupPositiveTtl))
            return hit.Guid;

        Guid? guid = null;
        try { guid = await _transport.ReadGhostSoulGuidAsync(npcName, ct); } catch { }
        _soulGuidByName[npcName] = (guid, now);
        return guid;
    }

    // -------------------------------------------------------------------------
    // NPC death sync (WO-86)
    // -------------------------------------------------------------------------

    /// <summary>
    /// A peer's world says the named NPC is dead: kill this world's copy so
    /// the two agree. Two inbound routes land here -- a 0x31 with the FATAL
    /// bit (the killer's DLL or Lua observer saw it die) and a witnessed 0x27
    /// dead transition (the body's stream owner saw it die) -- deduped per
    /// name for <see cref="NpcDeathDedupeWindow"/>. Order matters: the mod is
    /// told FIRST that this death is remote, so its own IsDead transition read
    /// (which fires the moment ApplyDeath lands) does not announce it back;
    /// then ApplyDeath runs through the DLL (Lua writes are inert). The DLL's
    /// own credit-out keeps the lethal TakeDamage from echoing as a LocalHit.
    /// Gated by the mod's mp_npc_deathsync toggle on the Lua side: when it is
    /// off, KCD2MP_NpcRemoteDeath returns false and nothing is applied.
    /// </summary>
    private async Task ApplyRemoteNpcDeathAsync(string npcName, Guid? knownLocalGuid, byte sourceGhostId, string via, CancellationToken ct)
    {
        var now = DateTime.UtcNow;
        if (_npcDeathAppliedUtc.TryGetValue(npcName, out var lastUtc) && now - lastUtc < NpcDeathDedupeWindow)
        {
            Console.WriteLine($"[npcdeath] in: '{npcName}' via {via} from ghost {sourceGhostId} -- already applied {(now - lastUtc).TotalSeconds:F0}s ago, ignoring");
            return;
        }
        _npcDeathAppliedUtc[npcName] = now;

        if (!_npcDeathSyncEnabled)
        {
            Console.WriteLine($"[npcdeath] in: '{npcName}' via {via} from ghost {sourceGhostId} -- mp_npc_deathsync is off, local copy left alone");
            return;
        }

        // The mod logs its own copy's state ("local state before", Phase 1),
        // records the remote-death mark and flags its puppet entry dead.
        // ExecuteNow rather than the batched pump so the mark lands before
        // the lethal apply below can trip the observer.
        try
        {
            await _transport.ExecuteNowAsync(
                $"if KCD2MP_NpcRemoteDeath then KCD2MP_NpcRemoteDeath(\"{npcName}\", \"{via.Replace('"', '\'')}\") end", ct);
        }
        catch (Exception ex) { Console.WriteLine($"[npcdeath] Lua remote-death mark failed for '{npcName}': {ex.Message}"); }

        Guid? localGuid = knownLocalGuid ?? await ResolveLocalSoulGuidAsync(npcName, ct);
        if (localGuid is not Guid lg)
        {
            Console.WriteLine($"[npcdeath] in: '{npcName}' via {via} from ghost {sourceGhostId} -- no local soul answers to that name, cannot apply");
            return;
        }
        bool applied = false;
        try { applied = await _combat.ApplyDeathAsync(lg, ct); }
        catch (Exception ex) { Console.WriteLine($"[npcdeath] ApplyDeath threw for '{npcName}': {ex.Message}"); }
        // WO-99 Phase 0: the lethal apply's own drop will surface as a
        // LocalHit(fatal) from the DLL (ApplyDeath books no credit); the
        // guard drops that echo for EchoWindow.
        _dmgGuard.NoteInboundApplied(npcName, 0f, 0f, fatal: true, DateTime.UtcNow);
        Console.WriteLine($"[npcdeath] in: '{npcName}' via {via} from ghost {sourceGhostId} -> ApplyDeath "
                        + (applied ? "applied (or already dead here)" : "FAILED (soul not loaded, or the DLL is absent)"));
    }

    // -------------------------------------------------------------------------
    // Dropped-item sync (WO-48)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Builds the exact ItemDropUp (0x32) payload -- kept verbatim in
    /// <see cref="_myOpenDrops"/> so the late-joiner heartbeat resends the
    /// identical bytes (receivers dedupe by the dropId inside).
    /// </summary>
    private static byte[] BuildItemDropPayload(uint dropId, Guid itemClass, ushort amount, float health, float x, float y, float z)
    {
        var payload = new byte[Protocol.ItemDropUpPayloadLen];
        BinaryPrimitives.WriteUInt32LittleEndian(payload, dropId);
        itemClass.TryWriteBytes(payload.AsSpan(4));
        BinaryPrimitives.WriteUInt16LittleEndian(payload.AsSpan(20), amount);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(22), health);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(26), x);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(30), y);
        BinaryPrimitives.WriteSingleLittleEndian(payload.AsSpan(34), z);
        return payload;
    }

    /// <summary>Puts one ItemDropUp (0x32) on the wire (first send and heartbeat both).</summary>
    private async Task SendItemDropAsync(NetworkStream stream, byte[] payload, CancellationToken ct)
    {
        try
        {
            var packet = new byte[3 + payload.Length];
            packet[0] = Protocol.ItemDropUp;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payload.Length);
            payload.CopyTo(packet, 3);
            await WritePacketAsync(stream, packet, ct);
        }
        catch (Exception ex) { Console.WriteLine($"[itemsync] drop send failed: {ex.Message}"); }
    }

    /// <summary>Puts one ItemClaimUp (0x34) on the wire.</summary>
    private async Task SendItemClaimAsync(NetworkStream stream, uint dropId, CancellationToken ct)
    {
        try
        {
            var packet = new byte[3 + Protocol.ItemClaimUpPayloadLen];
            packet[0] = Protocol.ItemClaimUp;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.ItemClaimUpPayloadLen);
            BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(3), dropId);
            await WritePacketAsync(stream, packet, ct);
            Console.WriteLine($"[itemsync] sent claim for drop {dropId}");
        }
        catch (Exception ex) { Console.WriteLine($"[itemsync] claim send failed: {ex.Message}"); }
    }

    // -------------------------------------------------------------------------
    // Weather sync (WO-40 Phase 3)
    // -------------------------------------------------------------------------

    /// <summary>Puts one WeatherUp (0x2E) on the wire.</summary>
    private async Task SendWeatherAsync(NetworkStream stream, string profile, ushort blendSec, CancellationToken ct)
    {
        try
        {
            var nameBytes = Encoding.UTF8.GetBytes(profile);
            var packet = new byte[3 + 1 + nameBytes.Length + 2];
            packet[0] = Protocol.WeatherUp;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)(1 + nameBytes.Length + 2));
            packet[3] = (byte)nameBytes.Length;
            nameBytes.CopyTo(packet, 4);
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(4 + nameBytes.Length), blendSec);
            await WritePacketAsync(stream, packet, ct);
            Console.WriteLine($"[weather] sent profile '{profile}' blend={blendSec}");
        }
        catch (Exception ex) { Console.WriteLine($"[weather] send failed: {ex.Message}"); }
    }

    /// <summary>
    /// The weather arbiter, run from the position loop on a slow check
    /// cadence. Only acts when this client holds damage authority AND at
    /// least one peer is live -- solo, vanilla weather stays untouched.
    /// Re-rolls every <see cref="Protocol.WeatherRepickSeconds"/> (half the
    /// rolls keep the current profile), re-sends every
    /// <see cref="Protocol.WeatherHeartbeatSeconds"/> for late joiners.
    /// </summary>
    private void WeatherArbiterTick()
    {
        if (!config.WeatherSyncEnabled || !_isDamageAuthority) return;
        var now = DateTime.UtcNow;
        if (!_peerLastSeenUtc.Any(kv => (now - kv.Value) < TimeSpan.FromMinutes(2))) return;

        if (now >= _weatherNextRepickUtc)
        {
            _weatherNextRepickUtc = now.AddSeconds(Protocol.WeatherRepickSeconds);
            bool keep = _sessionWeatherProfile is not null && _weatherRng.Next(2) == 0;
            if (!keep)
            {
                string pick = WeatherProfilePool[_weatherRng.Next(WeatherProfilePool.Length)];
                if (pick != _sessionWeatherProfile)
                {
                    _sessionWeatherProfile = pick;
                    Console.WriteLine($"[weather] arbiter picked '{pick}'");
                    _weatherNextHeartbeatUtc = DateTime.MinValue; // send now
                }
            }
        }

        if (_sessionWeatherProfile is string profile && now >= _weatherNextHeartbeatUtc)
        {
            _weatherNextHeartbeatUtc = now.AddSeconds(Protocol.WeatherHeartbeatSeconds);
            _ = _sendWeather?.Invoke(profile, WeatherBlendSeconds);
            _ = ApplyWeatherAsync(profile, WeatherBlendSeconds);
        }
    }

    /// <summary>
    /// Applies a weather profile in the mod (idempotent: change-gated here so
    /// arbiter heartbeats do not restart the blend every two minutes).
    /// </summary>
    private async Task ApplyWeatherAsync(string profile, ushort blendSec)
    {
        if (profile == _lastAppliedWeatherProfile) return;
        _lastAppliedWeatherProfile = profile;
        Console.WriteLine($"[weather] applying profile '{profile}' blend={blendSec}");
        try
        {
            await ExecLuaAsync(string.Format(CultureInfo.InvariantCulture,
                "if KCD2MP_ApplyWeather then KCD2MP_ApplyWeather(\"{0}\",{1}) end", profile, blendSec));
        }
        catch { /* game might have unloaded */ }
    }

    /// <summary>
    /// Applies a peer's resolved skip to this world: forward-only
    /// Calendar.SetWorldTime plus the toast, both in the mod. Queued instead
    /// when our own skip is still resolving -- SetWorldTime mid-skip is
    /// untested, and our own skip's result may supersede it anyway.
    /// </summary>
    private async Task ApplyTimeSkipAsync(byte sourceId, byte kind, uint worldTime, bool quiet, CancellationToken ct)
    {
        if (_localSkipActive || _awaitSkipDoneTime)
        {
            lock (_timeSkipLock)
            {
                if (_pendingTimeSkip is null || worldTime > _pendingTimeSkip.Value.WorldTime)
                    _pendingTimeSkip = (sourceId, kind, worldTime, quiet);
            }
            return;
        }

        string who = _ghostNames.TryGetValue(sourceId, out var dn) ? dn : $"player {sourceId}";

        // WO-88 finding 4: quiet reports now arrive about once a minute from
        // every peer (periodic announce). One that sits within natural skew of
        // our own extrapolated clock is not a gap to close -- writing it would
        // nudge the sky forward for nothing, and two clients doing that to
        // each other would ratchet. Announced skips (quiet=false) are never
        // gated: a real sleep/wait is applied as it always was.
        if (quiet && !ReloadReconcile.QuietSyncWorthApplying(worldTime, _lastPolledWorldTime, _lastPollUtc,
                DateTime.UtcNow, WorldTimeRatio, TimeJumpThresholdSeconds))
        {
            Console.WriteLine($"[timeskip] {who} -> worldTime={worldTime} (quiet) within skew of our clock ({_lastPolledWorldTime}) -- not applied");
            return;
        }

        Console.WriteLine($"[timeskip] {who} -> worldTime={worldTime} kind={kind}{(quiet ? " (quiet)" : "")}");
        try
        {
            await ExecLuaAsync(string.Format(CultureInfo.InvariantCulture,
                "if KCD2MP_ApplyTimeSkip then KCD2MP_ApplyTimeSkip(\"{0}\",{1},{2},{3}) end",
                EscapeLua(who), kind, worldTime, quiet ? "true" : "false"));
            // WO-102 Phase 6: a peer's announced sleep/wait/fast travel is a
            // resync point here too (quiet clock reports are not).
            if (!quiet)
                await RequestNpcResyncAsync(kind == Protocol.TimeSkipKindFastTravel ? NpcResyncReason.FastTravel : NpcResyncReason.Sleep, _resyncStream, ct);
        }
        catch { /* game might have unloaded */ }

        // The applied advance must not read as a fresh local jump on the next
        // poll, or two clients would bounce the same skip back and forth.
        _suppressJumpUntilUtc = DateTime.UtcNow.AddSeconds(30);
        _lastPolledWorldTime = Math.Max(worldTime, _lastPolledWorldTime ?? 0);
        _lastPollUtc = DateTime.UtcNow;
    }

    private void ApplyPendingTimeSkipIfAny()
    {
        (byte SourceId, byte Kind, uint WorldTime, bool Quiet)? pending;
        lock (_timeSkipLock)
        {
            pending = _pendingTimeSkip;
            _pendingTimeSkip = null;
        }
        if (pending is not null)
            _ = ApplyTimeSkipAsync(pending.Value.SourceId, pending.Value.Kind,
                pending.Value.WorldTime, pending.Value.Quiet, CancellationToken.None);
    }

    /// <summary>
    /// Applies a received PauseDown (0x1D): a peer entered or left a menu.
    ///
    /// WO-11 originally had every receiver drop its own <c>t_scale</c> for as
    /// long as any peer was paused. **That is retired (WO-13 Phase 0) and must
    /// not come back**: it is correct for two players and wrong at any real
    /// size, because in a 20-person session one player opening their inventory
    /// would visibly slow the other nineteen. Nothing here touches the local
    /// simulation any more -- a player's own game never slows because someone
    /// else paused.
    ///
    /// The packet survives as a pure presence signal. The peer's ghost gets an
    /// "[in menu]" tag on its nameplate so a motionless, unresponsive figure
    /// reads as "stepped away" rather than as a broken ghost.
    /// </summary>
    /// <summary>
    /// Starts pumping <c>KCD2MP_InterpPump()</c> into the game (WO-13 Phase 1).
    ///
    /// Idempotent: the local menu state can be re-asserted (two overlapping
    /// markers, or the manual override arriving on top of automatic
    /// detection) without stacking a second pump.
    ///
    /// Sent unbatched. The batch buffer is flushed by the agent's own position
    /// loop, which would add a whole tick of latency to every pumped frame for
    /// no reason -- and unlike most Lua this agent sends, the *timing* is the
    /// entire point.
    /// </summary>
    private void StartInterpPump()
    {
        lock (_interpPumpLock)
        {
            if (_interpPumpCts is not null) return;
            var cts = new CancellationTokenSource();
            _interpPumpCts = cts;
            _ = Task.Run(async () =>
            {
                Console.WriteLine("[menu] local menu open -- pumping interp tick");
                int frames = 0;
                var sw = System.Diagnostics.Stopwatch.StartNew();
                try
                {
                    while (!cts.IsCancellationRequested)
                    {
                        try { await _transport.ExecuteNowAsync("KCD2MP_InterpPump()", cts.Token); }
                        catch (OperationCanceledException) { break; }
                        catch { /* a dropped frame is not worth stopping the pump for */ }
                        frames++;
                    }
                }
                finally
                {
                    sw.Stop();
                    double hz = sw.Elapsed.TotalSeconds > 0.05 ? frames / sw.Elapsed.TotalSeconds : 0;
                    Console.WriteLine($"[menu] local menu closed -- pumped {frames} frames in "
                                    + $"{sw.Elapsed.TotalSeconds:F1}s ({hz:F1} Hz)");
                }
            }, cts.Token);
        }
    }

    /// <summary>Stops the pump if running. Safe to call when it is not.</summary>
    private void StopInterpPump()
    {
        CancellationTokenSource? cts;
        lock (_interpPumpLock)
        {
            cts = _interpPumpCts;
            _interpPumpCts = null;
        }
        if (cts is null) return;
        try { cts.Cancel(); } catch { }
        cts.Dispose();
    }

    private async Task ApplyPeerPauseAsync(byte sourceGhostId, bool paused, CancellationToken ct)
    {
        try
        {
            await ExecLuaAsync(
                $"KCD2MP_SetGhostMenuState(\"{sourceGhostId}\", {(paused ? "true" : "false")})");
            Console.WriteLine($"[menu] ghost {sourceGhostId} {(paused ? "entered" : "left")} a menu");
        }
        catch (Exception ex) { Console.WriteLine($"[menu] ghost {sourceGhostId} tag failed: {ex.Message}"); }
    }

    // -------------------------------------------------------------------------
    // Shared player combat (WO-28)
    // -------------------------------------------------------------------------

    /// <summary>
    /// Flow A: puts this player's own health on the wire (0x1F) when it has
    /// moved materially, rate-limited, plus a slow unconditional heartbeat.
    ///
    /// Silently does nothing when the sample carries no health -- a v1 emit
    /// line from an older kdcmp.pak, or the HTTP transport, which never reads
    /// it. That is the whole of this layer's mixed-version story: an old pak
    /// means peers see no health for this player, not a broken session.
    ///
    /// The heartbeat exists for the same reason appearance has one: the relay
    /// is stateless and replays nothing, so a peer who joins after this
    /// player's last real health change would otherwise render no health at
    /// all until the next time they got hit.
    /// </summary>
    private async Task SendPlayerStateIfChangedAsync(NetworkStream stream, PlayerState st, CancellationToken ct)
    {
        if (st.Health is not { } health) return;
        float stamina = st.Stamina ?? Protocol.UnknownStat;

        byte flags = 0;
        if (st.IsUnconscious == true) flags |= Protocol.PlayerStateFlagUnconscious;
        // Bleeding has no confirmed read on this build -- it is a buff, and the
        // mod's emitter does not sample the buff list. The bit stays clear
        // rather than being faked from low health, which would be a guess a
        // receiver could not tell from a measurement.

        var now = DateTime.UtcNow;
        bool changed = _lastSentHealth is null
            || Math.Abs(_lastSentHealth.Value - health) >= Protocol.PlayerStateHealthThreshold
            || (stamina >= 0 && _lastSentStamina is not null
                && Math.Abs(_lastSentStamina.Value - stamina) >= Protocol.PlayerStateHealthThreshold)
            || flags != _lastSentVitalFlags;
        bool heartbeatDue = (now - _lastPlayerStateSentUtc).TotalSeconds >= Protocol.PlayerStateHeartbeatSeconds;

        if (!changed && !heartbeatDue) return;
        // The rate limit applies to change-driven sends only. A heartbeat is
        // already slower than it by two orders of magnitude, and letting the
        // limiter swallow one would defeat the point of having it.
        if (changed && !heartbeatDue
            && (now - _lastPlayerStateSentUtc).TotalMilliseconds < Protocol.PlayerStateMinIntervalMs) return;

        var packet = new byte[3 + Protocol.PlayerStateUpPayloadLen];
        packet[0] = Protocol.PlayerStateUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.PlayerStateUpPayloadLen);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(3), health);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(7), stamina);
        packet[11] = flags;
        try
        {
            await WritePacketAsync(stream, packet, ct);
            if (changed)
                Console.WriteLine($"[vitals] sent health={health:F1} stamina={stamina:F1} flags={flags}");
            _lastSentHealth = health;
            _lastSentStamina = stamina;
            _lastSentVitalFlags = flags;
            _lastPlayerStateSentUtc = now;
        }
        catch (Exception ex) { Console.WriteLine($"[vitals] send failed: {ex.Message}"); }
    }

    /// <summary>
    /// Flow C: declares this player's own death (0x23) exactly once per life.
    ///
    /// Sent by the dying player's own client and never inferred by a peer from
    /// health reaching zero -- see Protocol's 0x23 documentation. The emitter
    /// reports "dead" on every frame for as long as the death screen is up, so
    /// the latch here is what makes that one packet rather than fifty a second;
    /// the receiver treats a repeat as idempotent anyway, but flooding the relay
    /// to rely on that would be rude.
    ///
    /// The latch clears when the emitter reports the player alive again, which
    /// is what a completed save reload looks like from here. That is also why
    /// this reads IsDead rather than tracking a one-way "has died" bit: a player
    /// reloads and lives again in the same session, repeatedly.
    /// </summary>
    private async Task SendDeathIfNewAsync(NetworkStream stream, PlayerState st, CancellationToken ct)
    {
        if (st.IsDead is not { } dead) return;   // v1 line: no opinion either way

        if (!dead)
        {
            if (_sentDeathForThisLife)
                Console.WriteLine("[death] local player is alive again -- ready to report a future death");
            _sentDeathForThisLife = false;
            return;
        }

        if (_sentDeathForThisLife) return;
        _sentDeathForThisLife = true;
        // WO-100.5 Phase 3: our body is about to be replaced. Everything in
        // flight for the old one is now invalid, and the receiver cannot see
        // that discontinuity -- so name it.
        _actionOut.BumpIncarnation();

        var packet = new byte[3];
        packet[0] = Protocol.PlayerDeathUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.PlayerDeathUpPayloadLen);
        try
        {
            await WritePacketAsync(stream, packet, ct);
            Console.WriteLine("[death] local player died -- told the relay");
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[death] send failed: {ex.Message}");
            _sentDeathForThisLife = false;   // unsent: let the next tick try again
        }
    }

    /// <summary>
    /// Flow B outbound: an NPC in THIS world hurt the ghost standing in for
    /// player <paramref name="targetGhostId"/>, so tell that player (0x21).
    ///
    /// Only reached when this client holds Rule 2's damage authority -- gated
    /// both here and in the mod, which does not even sample ghost health
    /// otherwise, and again at the relay, which drops a PlayerHitUp from a
    /// non-holder. Three gates for one rule because getting it wrong does not
    /// look like a bug: it looks like players taking N times the damage they
    /// should in an N-peer session.
    ///
    /// <paramref name="healthLoss"/> is a positive loss amount, matching
    /// CombatSoul::TakeDamage's own argument semantics on the receiving end.
    /// </summary>
    /// <summary>
    /// NPC sync (WO-32): puts one tracked NPC's state on the wire (0x26).
    /// Rate limiting and change detection live in the mod's emitter, not here
    /// -- by the time an npc_state event reaches this method it is already
    /// worth sending. The mod also gates ambient emission on
    /// KCD2MP.hitSensorOn (only the Rule 2 authority samples the 30 m set)
    /// and the relay routes per entity anyway, the same two-layer defence
    /// PlayerHitUp has.
    ///
    /// <paramref name="asClaim"/> (WO-39 Phase 2) marks a manipulated-body
    /// emission from the mod's drag sensor: a non-authority IS allowed to
    /// send those -- sending is how an entity is claimed -- so the authority
    /// gate is skipped and the relay's per-entity table arbitrates.
    /// </summary>
    private async Task SendNpcStateAsync(NetworkStream stream, string npcName,
                                         float x, float y, float z, float rotZ,
                                         float health, byte flags, CancellationToken ct,
                                         bool asClaim = false)
    {
        if (!asClaim && !_isDamageAuthority)
        {
            Console.WriteLine($"[npcsync] not the world authority -- discarding state for '{npcName}'");
            return;
        }
        if (!NpcNamePattern.IsMatch(npcName) || npcName.Length > Protocol.MaxNpcNameLen)
        {
            Console.WriteLine($"[npcsync] refusing to send malformed NPC name '{npcName}'");
            return;
        }

        // WO-102 Phase 6: bytes from NpcStateCodec so the relay round-trip gate
        // sends exactly what this method sends (the WO-101 rule).
        // WO-110 R6: per-name sequence and this agent's ms clock ride along
        // (protocol v7) so the receiver renders on sender time.
        ushort seq;
        lock (_npcSeqOut) { _npcSeqOut.TryGetValue(npcName, out ushort s0); seq = unchecked((ushort)(s0 + 1)); _npcSeqOut[npcName] = seq; }
        uint senderMs = unchecked((uint)Environment.TickCount64);
        var packet = NpcStateCodec.BuildUp(npcName, x, y, z, rotZ, health, flags, seq, senderMs);
        if ((flags & Protocol.NpcStateFlagResync) != 0) _resyncEmitted++;
        try { await WritePacketAsync(stream, packet, ct); }
        catch (Exception ex) { Console.WriteLine($"[npcsync] send failed: {ex.Message}"); }
    }

    private async Task SendPlayerHitAsync(NetworkStream stream, byte targetGhostId,
                                          float healthLoss, float staminaLoss, CancellationToken ct)
    {
        if (!_isDamageAuthority)
        {
            Console.WriteLine($"[playerhit] not the damage authority -- discarding a {healthLoss:F1} delta on ghost {targetGhostId}");
            return;
        }
        if (healthLoss <= 0) return;   // guard 3, again: regeneration is not a hit

        var packet = new byte[3 + Protocol.PlayerHitUpPayloadLen];
        packet[0] = Protocol.PlayerHitUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.PlayerHitUpPayloadLen);
        packet[3] = targetGhostId;
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(4), healthLoss);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(8), staminaLoss);
        packet[12] = 0;
        try
        {
            await WritePacketAsync(stream, packet, ct);
            Console.WriteLine($"[playerhit] ghost {targetGhostId} lost {healthLoss:F1} here -- told its owner");
        }
        catch (Exception ex) { Console.WriteLine($"[playerhit] send failed: {ex.Message}"); }
    }

    /// <summary>
    /// Flow B inbound: the damage authority says an NPC in its world hurt this
    /// player, so apply it to the real local Henry (0x22).
    ///
    /// Applied through the DLL, not Lua, for the same reason all damage is:
    /// Lua health writes are inert (docs/PROJECT-STATE.md s2). The soul is
    /// addressed by <see cref="PlayerHenrySharedSoulGuid"/> -- the same value on
    /// every installation, which is precisely why it is useless as a
    /// cross-client *identifier* (WO-26 Phase 1) and exactly right as a local
    /// "the player, here" lookup.
    ///
    /// No echo is possible from this: the damage lands on the local player, and
    /// the outbound sampler that could re-report it (the DLL's) deliberately
    /// excludes the player from its tracked set, while the mod's ghost sampler
    /// only ever looks at ghosts.
    ///
    /// The recipient does not reply. Their next Flow A broadcast carries the
    /// new authoritative health, which is what corrects everyone -- including
    /// the sender, whose own locally-damaged ghost health is deliberately not
    /// treated as the truth.
    /// </summary>
    private async Task ApplyPlayerHitAsync(float healthLoss, float staminaLoss, CancellationToken ct)
    {
        if (healthLoss <= 0 && staminaLoss <= 0) return;

        // A stamina reading the sender could not obtain arrives as
        // Protocol.UnknownStat; passing that straight into TakeDamage would
        // *restore* stamina, so it is floored rather than forwarded.
        float st = staminaLoss > 0 ? staminaLoss : 0f;
        bool applied = await _combat.ApplyDamageAsync(PlayerHenrySharedSoulGuid, st, healthLoss,
                                                     suppressHitReaction: false, ct);
        if (applied)
            Console.WriteLine($"[playerhit] took {healthLoss:F1} damage from an NPC in the authority's world");
        else
            Console.WriteLine($"[playerhit] {healthLoss:F1} damage NOT applied -- KCDMP.dll is not injected, so " +
                              "NPC hits from other players' worlds cannot reach this player");
    }

    /// <summary>
    /// The local player's soul id. Identical on every installation
    /// (4c2dcffb-dea1-6263-72d7-b39f4db2d8b5 = player_henry, read live in
    /// WO-26 Phase 1), which makes it useless for telling one player from
    /// another on the wire -- and exactly right for "the player, in this
    /// process", which is all Flow B's receiver needs.
    /// </summary>
    private static readonly Guid PlayerHenrySharedSoulGuid =
        new("4c2dcffb-dea1-6263-72d7-b39f4db2d8b5");

    /// <summary>
    /// Applies a CombatRole (0x25): the relay saying whether this client now
    /// holds NPC→player damage authority. Pushed into the mod so the ghost
    /// health sampling is not merely ignored but never runs.
    /// </summary>
    private async Task ApplyCombatRoleAsync(bool isAuthority, CancellationToken ct)
    {
        if (_isDamageAuthority == isAuthority) return;
        _isDamageAuthority = isAuthority;
        Console.WriteLine(isAuthority
            ? "[role] this client now holds NPC->player damage authority"
            : "[role] this client no longer holds NPC->player damage authority");
        try { await ExecLuaAsync($"if KCD2MP_SetHitSensor then KCD2MP_SetHitSensor({(isAuthority ? "true" : "false")}) end"); }
        catch (Exception ex) { Console.WriteLine($"[role] could not tell the mod: {ex.Message}"); }
    }

    private async Task SendAppearanceAsync(NetworkStream stream, Guid[] itemClasses, CancellationToken ct)
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
        await WritePacketAsync(stream, packet, ct);
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
                        _stats.OnPong(ms);
                        try { await ExecLuaAsync($"KCD2MP_ShowPing({ms})"); } catch { }
                    }
                }
                else if (type == Protocol.ClockSyncDown && payloadLen == Protocol.ClockSyncDownPayloadLen)
                {
                    // WO-98 Phase 1: [t0 client send][t1 relay recv][t2 relay send]; t3 = now.
                    long t3 = DateTime.UtcNow.Ticks;
                    long t0 = BinaryPrimitives.ReadInt64LittleEndian(payload);
                    long t1 = BinaryPrimitives.ReadInt64LittleEndian(payload.AsSpan(8));
                    long t2 = BinaryPrimitives.ReadInt64LittleEndian(payload.AsSpan(16));
                    OnClockSample(t0, t1, t2, t3);
                }
                else if (type == Protocol.Ghost
                         && (payloadLen == Protocol.GhostPayloadLen || payloadLen == Protocol.GhostPayloadLenV2))
                {
                    // Ghost: [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f][flags:1]
                    // WO-100.5 Phase 2 appends [pace:1][dir:1][stance:1][animSpeedCenti:2].
                    // WO-101: decoded by PositionCodec, shared with the relay
                    // round-trip gate; the length was already gated above.
                    PositionCodec.TryDecodeGhost(payload.AsSpan(0, payloadLen), out var gs);
                    byte ghostId   = gs.GhostId;
                    float x        = gs.X;
                    float y        = gs.Y;
                    float z        = gs.Z;
                    float rotZ     = gs.RotZ;
                    bool  isRiding = gs.IsRiding;
                    bool  isStale  = gs.IsStale;   // WO-99 Phase 1

                    // Both conditions, not just the flag: a sender that sets
                    // the bit but sends a short packet is a bug we must not
                    // read past the end of. The codec applies that rule.
                    BodyState? body = gs.Body;
                    if (body is BodyState bs) _stats.OnBodyState(ghostId, bs);
                    else if (gs.BodyStateShort) _stats.BodyStateShortPackets++;
                    // WO-59: a ghost id we have never seen this connection is
                    // a newly-arrived peer -- re-announce our clock so THEY
                    // converge too (our connect-time sync went out before
                    // they were ready to hear it). Consumed by the next
                    // world-time poll (<=10 s), which is also a natural
                    // debounce against their position stream.
                    if (!_peerLastSeenUtc.ContainsKey(ghostId))
                    {
                        _timeSyncPending = true;
                        // WO-90: and tell the new arrival where we are in the
                        // story. Checkpoints are rare enough that waiting for
                        // our next one could mean they never hear it.
                        if (_localObjective is string mine)
                            _ = _sendStoryBeat?.Invoke(Protocol.StoryBeatKindObjective, mine);
                    }
                    _peerLastSeenUtc[ghostId] = DateTime.UtcNow;   // WO-40 Phase 4: live-peer gate for reload convergence
                    RefreshDiscordPeerCount();
                    if (_stats.OnGhostPacket(ghostId, x, y, z, isStale, out string? rawPkt) is string pktAgg) Console.WriteLine(pktAgg);   // WO-98 Phase 6
                    if (rawPkt is not null) Console.WriteLine(rawPkt);
                    // WO-94: a peer position that jumps further than any horse
                    // between two samples, inside a catch-up window, is the
                    // "untracked teleport" hazard (WO-92 s6.4 hazard 1).
                    if (_ghostLastPos.TryGetValue(ghostId, out var lastP))
                    {
                        float ddx = x - lastP.X, ddy = y - lastP.Y, ddz = z - lastP.Z;
                        double jump = Math.Sqrt(ddx * ddx + ddy * ddy + ddz * ddz);
                        double dtS = Math.Max(0.05, (DateTime.UtcNow - lastP.AtUtc).TotalSeconds);
                        if (jump > 50 && jump / dtS > 60)
                        {
                            string tag = CatchupTag();
                            if (tag.Length > 0)
                                Console.WriteLine($"[quest] ghost {ghostId} teleported {jump:F0} m in {dtS:F1}s{tag}");
                        }
                    }
                    _ghostLastPos[ghostId] = (x, y, z, DateTime.UtcNow);
                    _voice?.UpdateGhostPos(ghostId, x, y, z);
                    await UpdateGhostAsync(ghostId.ToString(), x, y, z, rotZ, isRiding, body);
                }
                else if (type == Protocol.ActionDown)
                {
                    // WO-100.5 Phase 3. The inbox does the ordering, the
                    // generation check and the counting; dispatch is separate
                    // so the wire half stands on its own.
                    var action = _actionIn.Accept(payload.AsSpan(0, payloadLen), out var reject);
                    if (action is InboundAction a)
                    {
                        string detail = a.Kind == ActionKind.Attack && a.Payload.Length >= AttackPayload.Len
                            ? AttackPayload.FromBytes(a.Payload).ToString()
                            : $"payload_len={a.Payload.Length}";
                        if (a.Kind == ActionKind.NpcRequest)
                        {
                            OnNpcRequestIn(a);
                        }
                        else if (a.Kind == ActionKind.NpcResync)
                        {
                            // WO-102 Phase 6: a non-owner asks for a burst.
                            byte rr = a.Payload.Length >= 1 ? a.Payload[0] : (byte)0;
                            _resyncInRequests++;
                            if (!_hostAuthority || !_isDamageAuthority)
                            {
                                _resyncInRefused++;
                                Console.WriteLine($"MP-NPCRESYNC dir=in from={a.SourceGhostId} reason={NpcResyncReason.Name(rr)} result=refused cause={(!_hostAuthority ? "host-authority-off" : "not-owner")}");
                            }
                            else await BurstNpcResyncAsync(rr, $"ghost-{a.SourceGhostId}", ct);
                        }
                        else
                        // No receiver acts on this yet: Phase 1's block write
                        // was refused by the engine (docs/WO-100.5-findings.md
                        // S2.3), so an accepted action is logged and dropped.
                        // Named as a drop rather than left looking applied.
                        Console.WriteLine(FormattableString.Invariant(
                            $"MP-ACTION section=inbound ghost={a.SourceGhostId} kind={a.Kind} phase={a.Phase} seq={a.Seq} gen={a.Gen} {detail} dispatch=dropped-no-receiver"));
                    }
                    else
                    {
                        Console.WriteLine(FormattableString.Invariant(
                            $"MP-ACTION section=inbound reject={reject}"));
                    }
                }
                else if (type == Protocol.Name && payloadLen >= 2)
                {
                    // Name packet: [ghostId:1][name:UTF-8...]
                    byte ghostId = payload[0];
                    string gname = Encoding.UTF8.GetString(payload, 1, payloadLen - 1);
                    _ghostNames[ghostId] = gname;
                    await SetGhostNameAsync(ghostId.ToString(), gname);
                }
                else if (type == Protocol.ReleaseVersion && payloadLen >= 2)
                {
                    // ReleaseVersion (0x1E, WO-19): [ghostId:1][releaseVersion:UTF-8...]
                    byte ghostId = payload[0];
                    string releaseVersion = Encoding.UTF8.GetString(payload, 1, payloadLen - 1);
                    _ghostReleaseVersions[ghostId] = releaseVersion;
                    Console.WriteLine($"[version] ghost {ghostId} is on release {releaseVersion}");
                }
                else if (type == Protocol.Disconnect && payloadLen == 1)
                {
                    // Disconnect packet: [ghostId:1]
                    byte ghostId = payload[0];
                    Console.WriteLine($"[disconnect] ghost {ghostId} removed");
                    _peerLastSeenUtc.TryRemove(ghostId, out _);
                    _peerCutscene.TryRemove(ghostId, out _);   // WO-98 Phase 5
                    RefreshDiscordPeerCount();
                    _voice?.RemovePlayer(ghostId);
                    _ghostAppearance.TryRemove(ghostId, out _);
                    _ghostKnownItemClasses.TryRemove(ghostId, out _);
                    _ghostNeverEquips.TryRemove(ghostId, out _);
                    _ghostLastAppearance.TryRemove(ghostId, out _);   // WO-88
                    // WO-17: a respawned ghost gets a fresh Soul.Guid, and a
                    // gone ghost has nothing left to detach.
                    _ghostSoulGuidCache.TryRemove(ghostId, out _);
                    _ghostHostileUntilUtc.TryRemove(ghostId, out _);
                    // WO-94: a gone peer's prompt is moot and its catch-up
                    // window on our side is closed.
                    _peerObjective.TryRemove(ghostId, out _);
                    _storyDivergenceTold.TryRemove(ghostId, out _);
                    _lastSharedObjective.TryRemove(ghostId, out _);      // WO-96
                    _peerFingerprint.TryRemove(ghostId, out _);          // WO-96
                    _peerGapTold.TryRemove(ghostId, out _);
                    _peerRegistryMismatchTold.TryRemove(ghostId, out _);
                    _ghostLastPos.TryRemove(ghostId, out _);
                    // WO-100 Phase 4 item 1: the body is gone, so every event
                    // still queued for it is invalid. Forgetting the entity id
                    // alone is not enough -- a reconnecting peer reuses the
                    // ghost id, and a queued swing would then wait for the NEW
                    // body's id and play on it.
                    _ghostEntityIds.TryRemove(ghostId.ToString(), out _);
                    BumpGhostGeneration(ghostId.ToString(), "peer disconnected");
                    if (_peerApproach.TryRemove(ghostId, out _))
                        try { await ExecLuaAsync($"if KCD2MP_QuestPromptMoot then KCD2MP_QuestPromptMoot(\"peer left\", \"{ghostId}\") end"); } catch { }
                    if (_peerCatchup.TryRemove(ghostId, out _))
                        try { await ExecLuaAsync($"if KCD2MP_QuestCatchupRemote then KCD2MP_QuestCatchupRemote(\"{ghostId}\", \"\", \"\", 0) end"); } catch { }
                    // A peer who disconnects mid-pause must not leave us
                    // slowed forever with no PauseDown(exit) ever coming.
                    await ApplyPeerPauseAsync(ghostId, paused: false, ct);
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

                    bool applied = config.GuidDamageFallbackEnabled
                                && await _combat.ApplyDamageAsync(soul, stamina, health, suppress, ct);
                    // WO-100.5 Phase 4: the receiving half of the same
                    // visibility. A guid that does not resolve here is the
                    // per-save-identity hazard WO-39/WO-40 measured, and it now
                    // says so on the MP-DMG channel instead of only in prose.
                    Console.WriteLine(FormattableString.Invariant(
                        $"MP-DMG dir=in route=guid-fallback ghost={sourceId} soul={soul} hp={health:F1} st={stamina:F1} result={(!config.GuidDamageFallbackEnabled ? "disabled" : applied ? "applied" : "unresolved")}"));
                    if (!applied)
                        Console.WriteLine($"[combat] damage from ghost {sourceId} not applied " +
                                          $"(soul {soul} not loaded here, the fallback is off, or the DLL is absent)");
                    else
                        // WO-17: the ghost representing sourceId just landed a
                        // real hit in this world -- the "Henry is attacking an
                        // innocent NPC" moment. No-op when aggro is disabled.
                        _ = TriggerReactiveAggroAsync(sourceId, ct);
                }
                else if (type == Protocol.NpcDamageDown
                         && payloadLen >= 1 + 1 + 1 + Protocol.NpcDamageFixedTail
                         && payloadLen <= 1 + 1 + Protocol.MaxNpcNameLen + Protocol.NpcDamageFixedTail)
                {
                    // Name-addressed NPC damage (WO-40 Phase 5):
                    // [sourceGhostId:1][nameLen:1][name][stamina:4f][health:4f][flags:1].
                    // The name resolves to THIS install's per-save guid via the
                    // reflection REST (cached), then applies through the same
                    // DLL pipe as 0x22 -- so the DLL's credit-out still stops
                    // echoes.
                    byte ndSource = payload[0];
                    int ndNameLen = payload[1];
                    if (payloadLen == 2 + ndNameLen + Protocol.NpcDamageFixedTail)
                    {
                        string ndName = Encoding.UTF8.GetString(payload, 2, ndNameLen);
                        if (NpcNamePattern.IsMatch(ndName))
                        {
                            int no = 2 + ndNameLen;
                            float ndStamina = ReadFloat(payload, no);
                            float ndHealth  = ReadFloat(payload, no + 4);
                            bool  ndSupp    = (payload[no + 8] & Protocol.DamageFlagSuppressHitReaction) != 0;
                            bool  ndFatal   = (payload[no + 8] & Protocol.NpcDamageFlagFatal) != 0;   // WO-86
                            NoteRequestResolvedIn(ndSource, ndName);   // WO-102 Phase 5
                            Guid? localGuid = await ResolveLocalSoulGuidAsync(ndName, ct);
                            // WO-99 Phase 0: a name that resolves to OUR player
                            // soul is the peer's player, not a shared NPC --
                            // refuse it before anything touches the local body.
                            await RefreshPlayerIdentityAsync(force: false, ct);
                            var ndVerdict = _dmgGuard.CheckInbound(ndName, localGuid);
                            if (ndVerdict != NpcDamageGuard.Inbound.Apply)
                            {
                                _stats.DmgIn++; _stats.DmgInRefused++;
                                Console.WriteLine(FormattableString.Invariant(
                                    $"MP-DMG dir=in ghost={ndSource} npc={ndName} hp={ndHealth:F1} st={ndStamina:F1} fatal={(ndFatal ? 1 : 0)} result=refused reason={NpcDamageGuard.Reason(ndVerdict)} authority={(_isDamageAuthority ? 1 : 0)}"));
                                continue;
                            }
                            // WO-86: a FATAL packet may carry no delta at all
                            // (the Lua observer saw the death, not the blow);
                            // there is nothing to apply then, only the death.
                            bool ndHasDelta = ndHealth > 0f || ndStamina > 0f;
                            bool ndApplied = ndHasDelta && localGuid is Guid lg
                                && await _combat.ApplyDamageAsync(lg, ndStamina, ndHealth, ndSupp, ct);
                            if (ndApplied || (ndFatal && localGuid is not null))
                                _dmgGuard.NoteInboundApplied(ndName, ndApplied ? ndHealth : 0f, ndApplied ? ndStamina : 0f, ndFatal, DateTime.UtcNow);
                            // WO-86 Phase 1: every inbound NPC damage event, with
                            // what this client did about it.
                            Console.WriteLine($"[npcdmg] in: ghost {ndSource} hit '{ndName}' hp -{ndHealth:F1} st -{ndStamina:F1}"
                                            + (ndFatal ? " FATAL" : "")
                                            + (localGuid is null ? " -> no local soul answers to that name"
                                               : !ndHasDelta ? " -> no delta to apply"
                                               : ndApplied ? " -> applied" : " -> pipe apply FAILED")
                                            + (ndFatal ? CatchupTag() : string.Empty));
                            _stats.DmgIn++; if (ndApplied) _stats.DmgInApplied++; else _stats.DmgInFailed++;
                            Console.WriteLine(FormattableString.Invariant(
                                $"MP-DMG dir=in ghost={ndSource} npc={ndName} hp={ndHealth:F1} st={ndStamina:F1} fatal={(ndFatal ? 1 : 0)} result={(localGuid is null ? "nosoul" : !ndHasDelta ? "nodelta" : ndApplied ? "applied" : "failed")} authority={(_isDamageAuthority ? 1 : 0)}"));
                            if (ndApplied)
                                _ = TriggerReactiveAggroAsync(ndSource, ct);
                            if (ndFatal)
                                await ApplyRemoteNpcDeathAsync(ndName, localGuid, ndSource, "0x31 FATAL", ct);
                        }
                    }
                }
                else if (type == Protocol.DeathDown && payloadLen == Protocol.DeathDownPayloadLen)
                {
                    // Death is its own packet rather than inferred from health
                    // reaching zero, and the DLL treats it as idempotent.
                    byte sourceId = payload[0];
                    var  soul     = new Guid(payload.AsSpan(1, 16));
                    // WO-100.5 Phase 4: 0x14 carries the same per-save guid as
                    // 0x12 and is gated by the same toggle, for the same
                    // reason. Reported on the MP-DMG channel so "the death
                    // never arrived" and "the death arrived and the guid did
                    // not resolve" stop looking identical in a field log.
                    bool applied  = config.GuidDamageFallbackEnabled
                                 && await _combat.ApplyDeathAsync(soul, ct);
                    Console.WriteLine(FormattableString.Invariant(
                        $"MP-DMG dir=in route=guid-fallback-death ghost={sourceId} soul={soul} result={(!config.GuidDamageFallbackEnabled ? "disabled" : applied ? "applied" : "unresolved")}"));
                    if (!applied)
                        Console.WriteLine($"[combat] death from ghost {sourceId} not applied " +
                                          $"(soul {soul} not loaded here, the fallback is off, or the DLL is absent)");
                }
                else if (type == Protocol.PauseDown && payloadLen == Protocol.PauseDownPayloadLen)
                {
                    // PauseDown: [sourceGhostId:1][state:1]
                    byte sourceId = payload[0];
                    bool paused = payload[1] == Protocol.PauseStateEntered;
                    await ApplyPeerPauseAsync(sourceId, paused, ct);
                }
                else if (type == Protocol.PlayerStateDown && payloadLen == Protocol.PlayerStateDownPayloadLen)
                {
                    // WO-28 Flow A: [ghostId:1][health:4f][stamina:4f][flags:1]
                    // Rendered, not reconciled -- a player's health is
                    // authoritative on their own machine, so this is simply
                    // what that ghost's health IS.
                    byte  sourceId = payload[0];
                    float health   = ReadFloat(payload, 1);
                    float stamina  = ReadFloat(payload, 5);
                    byte  vflags   = payload[9];
                    await ApplyGhostVitalsAsync(sourceId, health, stamina, vflags, ct);
                }
                else if (type == Protocol.PlayerHitDown && payloadLen == Protocol.PlayerHitDownPayloadLen)
                {
                    // WO-28 Flow B: [health:4f][stamina:4f][flags:1] -- loss
                    // amounts. No ghost id: the relay routed this to us
                    // precisely because it is about us.
                    float healthLoss  = ReadFloat(payload, 0);
                    float staminaLoss = ReadFloat(payload, 4);
                    await ApplyPlayerHitAsync(healthLoss, staminaLoss, ct);
                }
                else if (type == Protocol.PlayerDeathDown && payloadLen == Protocol.PlayerDeathDownPayloadLen)
                {
                    // WO-28 Flow C: [ghostId:1]. Idempotent -- the mod's own
                    // setter only logs on an actual transition.
                    byte sourceId = payload[0];
                    string who = _ghostNames.TryGetValue(sourceId, out var dn) ? dn : $"player {sourceId}";
                    Console.WriteLine($"[death] {who} died and is reloading their own save");
                    try
                    {
                        await ExecLuaAsync($"KCD2MP_SetGhostDead(\"{sourceId}\", true)");
                        await ExecLuaAsync($"if KCD2MP_ShowInteractionMsg then KCD2MP_ShowInteractionMsg(\"{EscapeLua(who)} died\") end");
                    }
                    catch { }
                }
                else if (type == Protocol.CombatRole && payloadLen == Protocol.CombatRolePayloadLen)
                {
                    // WO-110 R4: every authority decision the relay sends, on
                    // this machine's console AND in kcd.log (the runbook reads
                    // kcd.log), whether or not it changes anything.
                    bool amAuthority = payload[0] != 0;
                    Console.WriteLine(FormattableString.Invariant(
                        $"MP-AUTHORITY-OWNER self_id={_myGhostId} authority={(amAuthority ? "self" : "peer")} reason=relay-combatrole"));
                    try { await ExecLuaAsync(FormattableString.Invariant($"if KCD2MP_AuthorityOwnerLog then KCD2MP_AuthorityOwnerLog({_myGhostId},{(amAuthority ? "true" : "false")}) end")); } catch { }
                    await ApplyCombatRoleAsync(amAuthority, ct);
                }
                else if (type == Protocol.TimeSkipDown && payloadLen == Protocol.TimeSkipDownPayloadLen)
                {
                    // Time-skip sync (WO-38): [sourceGhostId:1][phase:1][kind:1][worldTime:4].
                    // A start carries no time and needs nothing done here --
                    // the join rule is enforced relay-side. Both done phases
                    // apply the clock; only the announced one shows a toast.
                    byte  tsSource = payload[0];
                    byte  tsPhase  = payload[1];
                    byte  tsKind   = payload[2];
                    uint  tsTime   = BinaryPrimitives.ReadUInt32LittleEndian(payload.AsSpan(3));
                    if (tsPhase == Protocol.TimeSkipPhaseStart)
                    {
                        string tsWho = _ghostNames.TryGetValue(tsSource, out var tsName) ? tsName : $"player {tsSource}";
                        Console.WriteLine($"[timeskip] {tsWho} began a skip (kind={tsKind})");
                    }
                    else if (tsPhase is Protocol.TimeSkipPhaseDone or Protocol.TimeSkipPhaseDoneQuiet)
                    {
                        // WO-40 Phase 4: remember the newest peer-reported
                        // clock (latest report wins, whatever its direction --
                        // it is only consulted if WE reload) for reload
                        // convergence.
                        _peerWorldTime = tsTime;
                        _peerWorldTimeUtc = DateTime.UtcNow;
                        await ApplyTimeSkipAsync(tsSource, tsKind, tsTime,
                            quiet: tsPhase == Protocol.TimeSkipPhaseDoneQuiet, ct);
                    }
                }
                else if (type == Protocol.NpcStateDown
                         && payloadLen >= 1 + 1 + 1 + Protocol.NpcStateFixedTail
                         && payloadLen <= 1 + 1 + Protocol.MaxNpcNameLen + Protocol.NpcStateFixedTail)
                {
                    // NPC sync (WO-32): [sourceGhostId:1][nameLen:1][name][x][y][z][rotZ][health][flags]
                    // The name is validated before interpolation -- it crosses
                    // into a Lua string literal and relay data must not be able
                    // to inject code. A name for an entity not loaded in this
                    // world is handled (ignored) on the Lua side.
                    int nameLen = payload[1];
                    if (payloadLen != 2 + nameLen + Protocol.NpcStateFixedTail) CountDrop(type, "namelen-mismatch");   // WO-110 R9
                    if (payloadLen == 2 + nameLen + Protocol.NpcStateFixedTail)
                    {
                        string npcName = Encoding.UTF8.GetString(payload, 2, nameLen);
                        if (!NpcNamePattern.IsMatch(npcName)) CountDrop(type, "name-rejected");   // WO-110 R9
                        if (NpcNamePattern.IsMatch(npcName))
                        {
                            int o = 2 + nameLen;
                            float nx    = ReadFloat(payload, o);
                            float ny    = ReadFloat(payload, o + 4);
                            float nz    = ReadFloat(payload, o + 8);
                            float nrot  = ReadFloat(payload, o + 12);
                            float nhp   = ReadFloat(payload, o + 16);
                            byte nflags = payload[o + Protocol.NpcStateFlagsOffset];
                            ushort nseq = BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(o + Protocol.NpcStateSeqOffset));      // WO-110 R6
                            uint nSenderMs = BinaryPrimitives.ReadUInt32LittleEndian(payload.AsSpan(o + Protocol.NpcStateSenderMsOffset));

                            // WO-49: a sheathed→drawn transition in the stream
                            // is the moment the local copy's hands change --
                            // re-read its equipped set for swing resolution.
                            bool npcDrawn = (nflags & 0x04) != 0;
                            bool wasDrawn = _npcLastDrawn.TryGetValue(npcName, out bool d0) && d0;
                            _npcLastDrawn[npcName] = npcDrawn;
                            if (npcDrawn && !wasDrawn && _npcEntityIds.ContainsKey(npcName))
                                RefreshNpcEquipped(npcName);

                            // WO-49: the swing cue (bit 3) rides the same
                            // native path ghost swings use (WO-46) when this
                            // world's copy is known by entity id: strip the
                            // bit so the Lua does not also play its WO-40
                            // guard-flick cue; native failure re-arms that
                            // cue explicitly, late but visible. Dead/KO bits
                            // veto, matching the Lua cue's own guard.
                            bool npcKnown = _npcEntityIds.TryGetValue(npcName, out uint npcEntityId);
                            bool npcSwingNative = (nflags & 0x08) != 0
                                && (nflags & 0x03) == 0
                                && npcKnown;
                            if (npcSwingNative) nflags &= 0xF7;

                            // WO-86: the stream's dead bit. Logged on every
                            // transition (Phase 1), and a WITNESSED 0->1 -- a
                            // body this client saw alive on this stream and now
                            // sees dead -- kills the local copy too, so both
                            // worlds agree. A body dead on its FIRST packet is
                            // a late-join corpse or a save-state difference and
                            // only freezes, exactly as before: nothing kills a
                            // living NPC on the strength of a stranger's save.
                            byte  nsrc    = payload[0];
                            bool  nDead   = (nflags & Protocol.NpcStateFlagDead) != 0;
                            bool  nResync = (nflags & Protocol.NpcStateFlagResync) != 0;   // WO-102 Phase 6
                            if (nResync) _resyncInPackets++;
                            bool  nSeen   = _npcLastDead.TryGetValue(npcName, out bool nWasDead);
                            _npcLastDead[npcName] = nDead;
                            if (nDead && (!nSeen || !nWasDead))
                            {
                                Console.WriteLine($"[npcdeath] in: 0x27 from ghost {nsrc} says '{npcName}' is dead (hp={nhp:F1})"
                                                + (nSeen ? " -- witnessed transition, killing the local copy"
                                                         : " -- dead on its first packet here (late join / save state): freeze only"));
                            }
                            else if (!nDead && nSeen && nWasDead)
                            {
                                Console.WriteLine($"[npcdeath] in: 0x27 from ghost {nsrc} says '{npcName}' is ALIVE again (hp={nhp:F1}) -- was dead on this stream; a reload on their side?");
                            }

                            await ExecLuaAsync(string.Format(CultureInfo.InvariantCulture,
                                "if KCD2MP_ApplyNpcState then KCD2MP_ApplyNpcState(\"{0}\",{1:F3},{2:F3},{3:F3},{4:F4},{5:F1},{6},{7},{8},{9}) end",
                                npcName, nx, ny, nz, nrot, nhp, nflags, nsrc, nseq, nSenderMs));   // WO-102 Phase 2: source id = the stream's owner (MP-AUTHORITY); WO-110 R6: seq + sender ms

                            if (nDead && nSeen && !nWasDead)
                                await ApplyRemoteNpcDeathAsync(npcName, null, nsrc, "0x27 dead transition", ct);
                            else if (nDead && nResync && _hostAuthority && !nWasDead)
                            {
                                // WO-102 Phase 6: under host authority the owner's
                                // life state IS the truth, including on a first
                                // packet -- the WO-86 "freeze only on a first dead
                                // packet" rule is the claim model's caution about a
                                // stranger's save, and here the stranger is the owner.
                                _resyncDeadApplied++;
                                await ApplyRemoteNpcDeathAsync(npcName, null, nsrc, "0x27 resync dead", ct);
                            }

                            if (npcSwingNative)
                            {
                                string npcFragSpec = ResolveNpcSwingSpec(npcName);
                                _ = _combat.GhostSwingAsync(npcEntityId, npcFragSpec, ct)
                                    .ContinueWith(t =>
                                    {
                                        if (t.IsFaulted || !t.Result)
                                        {
                                            Console.WriteLine($"[npcsync] native swing for {npcName} did not apply — falling back to the Lua cue");
                                            _ = ExecLuaAsync($"if KCD2MP_NpcSwingCueFallback then KCD2MP_NpcSwingCueFallback(\"{npcName}\") end");
                                        }
                                    }, TaskScheduler.Default);
                                await ExecLuaAsync($"if KCD2MP_NpcNativeSwingHold then KCD2MP_NpcNativeSwingHold(\"{npcName}\") end");
                            }
                        }
                    }
                }
                else if (type == Protocol.HorseInfoDown
                         && payloadLen >= 2
                         && payloadLen <= 2 + Protocol.MaxHorseNameLen)
                {
                    // Horse identity (WO-38 Phase 5): [sourceGhostId:1][nameLen:1][name].
                    // Same validate-before-Lua-interpolation discipline as NpcStateDown.
                    byte hiSource = payload[0];
                    int hiNameLen = payload[1];
                    if (payloadLen == 2 + hiNameLen)
                    {
                        string horseName = hiNameLen == 0 ? "" : Encoding.UTF8.GetString(payload, 2, hiNameLen);
                        if (hiNameLen == 0 || NpcNamePattern.IsMatch(horseName))
                            await ExecLuaAsync($"if KCD2MP_SetGhostHorse then KCD2MP_SetGhostHorse(\"{hiSource}\",\"{horseName}\") end");
                    }
                }
                else if (type == Protocol.WeatherDown
                         && payloadLen >= 1 + 1 + 2
                         && payloadLen <= 1 + 1 + Protocol.MaxWeatherNameLen + 2)
                {
                    // Weather sync (WO-40 Phase 3):
                    // [sourceGhostId:1][nameLen:1][profileName][blendSec:2].
                    // Same validate-before-Lua-interpolation discipline as
                    // NpcStateDown; the apply is change-gated.
                    int wNameLen = payload[1];
                    if (config.WeatherSyncEnabled && payloadLen == 2 + wNameLen + 2)
                    {
                        string wProfile = Encoding.UTF8.GetString(payload, 2, wNameLen);
                        ushort wBlend = BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(2 + wNameLen));
                        if (WeatherNamePattern.IsMatch(wProfile))
                            await ApplyWeatherAsync(wProfile, wBlend);
                    }
                }
                else if (type == Protocol.StoryBeatDown
                         && payloadLen >= 1 + 2
                         && payloadLen <= 1 + 2 + Protocol.MaxStoryBeatTextLen)
                {
                    // Story progress (WO-90):
                    // [sourceGhostId:1][kind:1][len:1][text utf8].
                    //
                    // The text is a peer-supplied string that ends up inside a
                    // Lua literal, so it is length-checked here and escaped at
                    // the call site (ReportStoryDivergence -> EscapeLua). It
                    // drives a toast and a console line and nothing else --
                    // deliberately: this layer reports divergence, it never
                    // gates behaviour on it.
                    byte sbSource = payload[0];
                    byte sbKind   = payload[1];
                    int  sbLen    = payload[2];
                    if (sbKind == Protocol.StoryBeatKindObjective && payloadLen == 3 + sbLen && sbLen > 0)
                    {
                        string sbText = Encoding.UTF8.GetString(payload, 3, sbLen);
                        _peerObjective[sbSource] = sbText;
                        Console.WriteLine($"[story] ghost {sbSource} objective -> {StoryBeat.Humanize(sbText)}");
                        ReportStoryDivergence(sbSource, sbText);
                        ReevaluateQuestPrompts();   // WO-94
                    }
                    else if ((sbKind == Protocol.StoryBeatKindApproach
                              || sbKind == Protocol.StoryBeatKindCatchupBegin
                              || sbKind == Protocol.StoryBeatKindCatchupEnd)
                             && payloadLen == 3 + sbLen && sbLen > 0)
                    {
                        // WO-94 Shared Quests. The text is peer-supplied and
                        // ends up in a Lua literal: shape-checked here (path
                        // characters only), registry-checked in the mod.
                        string qText = Encoding.UTF8.GetString(payload, 3, sbLen);
                        if (!StoryBeat.IsValidBeatPath(qText))
                            Console.WriteLine($"[quest] ghost {sbSource} sent a malformed beat path (kind {sbKind}); dropped");
                        else if (sbKind == Protocol.StoryBeatKindApproach)
                            OnPeerApproach(sbSource, qText);
                        else
                            OnPeerCatchup(sbSource, qText, begin: sbKind == Protocol.StoryBeatKindCatchupBegin);
                    }
                    else if (sbKind == Protocol.StoryBeatKindCutscene && payloadLen == 3 + sbLen && sbLen > 0)
                    {
                        // WO-98 Phase 5: "start|end <type> <name>" -- shape-checked
                        // (plain tokens only) before it reaches a log line or Lua.
                        string csText = Encoding.UTF8.GetString(payload, 3, sbLen);
                        var csParts = csText.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                        if (csParts.Length == 3 && (csParts[0] == "start" || csParts[0] == "end")
                            && IsPlainToken(csParts[1]) && IsPlainToken(csParts[2]))
                        {
                            bool csActive = csParts[0] == "start";
                            _peerCutscene[sbSource] = (csActive, csParts[1], csParts[2]);
                            _stats.CutscenePeerEdges++;
                            string csWho = _ghostNames.TryGetValue(sbSource, out var csDn) ? csDn : $"player {sbSource}";
                            Console.WriteLine($"MP-CUTSCENE side=peer ghost={sbSource} who=\"{csWho}\" state={csParts[0]} type={csParts[1]} name={csParts[2]} local={(_localCutsceneActive ? 1 : 0)}");
                            _ = ExecLuaAsync($"if KCD2MP_SetPeerCutscene then KCD2MP_SetPeerCutscene(\"{sbSource}\", {(csActive ? "true" : "false")}, \"{EscapeLua(csParts[2])}\") end");
                        }
                        else Console.WriteLine($"[quest] ghost {sbSource} sent a malformed cutscene edge; dropped");
                    }
                    else if (sbKind == Protocol.StoryBeatKindFingerprint && payloadLen == 3 + sbLen && sbLen > 0)
                    {
                        // WO-96 Phase 2: a peer's per-quest objective fingerprint.
                        // Shape-checked by TryDecode before anything else looks
                        // at it; compared off the receive thread.
                        string fpText = Encoding.UTF8.GetString(payload, 3, sbLen);
                        _peerFingerprint[sbSource] = fpText;
                        _ = Task.Run(() => ComparePeerFingerprint(sbSource, fpText));
                    }
                }
                else if (type == Protocol.ItemDropDown && payloadLen == Protocol.ItemDropDownPayloadLen)
                {
                    // Dropped-item sync (WO-48):
                    // [sourceGhostId:1][dropId:4][itemClass:16][amount:2][health:4f][x:4f][y:4f][z:4f].
                    // Handed to the mod as a pending drop; it materializes the
                    // pickup entity only once the local player is near enough
                    // for the ground to be streamed (placing far away was
                    // observed to drop the item through the world). Dedupe by
                    // dropId is the mod's job -- heartbeats repeat this packet.
                    byte idSource   = payload[0];
                    uint idDropId   = BinaryPrimitives.ReadUInt32LittleEndian(payload.AsSpan(1));
                    var  idClass    = new Guid(payload.AsSpan(5, Protocol.ItemClassLen));
                    ushort idAmount = BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(21));
                    float idHealth  = ReadFloat(payload, 23);
                    float idX       = ReadFloat(payload, 27);
                    float idY       = ReadFloat(payload, 31);
                    float idZ       = ReadFloat(payload, 35);
                    if (idDropId != 0 && idAmount > 0)
                        await ExecLuaAsync(string.Format(CultureInfo.InvariantCulture,
                            "if KCD2MP_ItemDropAdd then KCD2MP_ItemDropAdd(\"{0}\",\"{1}\",{2},{3:F4},{4:F3},{5:F3},{6:F3},\"{7}\") end",
                            idDropId, idClass, idAmount, idHealth, idX, idY, idZ, idSource));
                }
                else if (type == Protocol.ItemClaimDown && payloadLen == Protocol.ItemClaimDownPayloadLen)
                {
                    // [claimerGhostId:1][dropId:4]. The relay echoes claims to
                    // everyone INCLUDING the claimant, in arrival order -- the
                    // first echo a client sees for a dropId settles that drop
                    // everywhere (the mod ignores repeats). Also retires the
                    // drop from our own heartbeat set, whoever won it.
                    byte icClaimer = payload[0];
                    uint icDropId  = BinaryPrimitives.ReadUInt32LittleEndian(payload.AsSpan(1));
                    _myOpenDrops.TryRemove(icDropId, out _);
                    bool claimIsMine = icClaimer == _myGhostId;
                    Console.WriteLine($"[itemsync] drop {icDropId} claimed by {(claimIsMine ? "us" : $"ghost {icClaimer}")}");
                    await ExecLuaAsync($"if KCD2MP_ItemDropClaimed then KCD2MP_ItemDropClaimed(\"{icDropId}\",\"{icClaimer}\",{(claimIsMine ? "true" : "false")}) end");
                }
                else if (type == Protocol.CombatEventDown
                         && (payloadLen == Protocol.CombatEventDownPayloadLen || payloadLen == Protocol.CombatEventDownPayloadLenV2))
                {
                    // Combat visibility (WO-39 Phase 1): [sourceGhostId:1][event:1].
                    // WO-99 Phase 4: v2 appends [sid:2], the sender's swing counter.
                    ushort ceSid = payloadLen == Protocol.CombatEventDownPayloadLenV2
                        ? BinaryPrimitives.ReadUInt16LittleEndian(payload.AsSpan(2)) : (ushort)0;
                    // Purely cosmetic on this side -- the Lua applies a
                    // draw/holster call or a one-shot animation to the ghost.
                    // An event byte this build does not know is passed through
                    // anyway; the Lua ignores unknown values, so a newer peer
                    // can emit new events without breaking us.
                    byte ceSource = payload[0];
                    byte ceEvent  = payload[1];
                    // WO-46: swings go native when the ghost's entity id is
                    // known and the DLL pipe is up — the WO-45 rung-2 route
                    // renders a real, complete Mannequin swing where the Lua
                    // clip path could only manage a guard-transition cue. The
                    // Lua side still gets a call for the one-shot locomotion
                    // hold; everything else (draw/sheathe/block, or a swing
                    // with no native path available) stays on the old call.
                    if (ceEvent == Protocol.CombatEventSwing
                        && _ghostEntityIds.TryGetValue(ceSource.ToString(), out uint ceEntityId))
                    {
                        // No IsConnected pre-check: GhostSwingAsync connects the
                        // pipe on demand (the agent's one startup connect can
                        // race the injection and give up), and on failure —
                        // DLL absent, stale entity id after a respawn — the old
                        // Lua cue runs as the fallback, late but visible.
                        string fragSpec = ResolveSwingSpec(ceSource);
                        // WO-98 Phase 6: the receive-side hops, correlated by a
                        // per-machine rsid. (A cross-machine id would need a
                        // wire field on CombatEventUp; docs/WO-98-findings.md s6.)
                        long rsid = ++_stats.SwingsRecv;
                        Console.WriteLine($"MP-SWING hop=recv rsid={rsid} sid={ceSid} ghost={ceSource} entity=0x{ceEntityId:X} spec=\"{fragSpec}\"");
                        // WO-100 Phase 4: the inbox owns validity, the bounded
                        // precondition wait, the reason vocabulary and the
                        // queue bound. The fire-and-forget task this replaced
                        // had none of the four.
                        EnsureSwingInbox(ct).TryEnqueue(new SwingInbox.Entry(
                            ceSource.ToString(), ceSid, rsid,
                            GhostGeneration(ceSource.ToString()), fragSpec, DateTime.UtcNow));
                        await ExecLuaAsync($"if KCD2MP_GhostNativeSwingHold then KCD2MP_GhostNativeSwingHold(\"{ceSource}\") end");
                    }
                    else if (ceEvent == Protocol.CombatEventWeaponDrawn
                             && OversizedItemFor(ceSource) is Guid oversized)
                    {
                        // WO-47: a ghost whose synced main-hand weapon lives in
                        // the Oversized slot (halberd/polearm) never gets it
                        // attached by DrawWeapon() -- route the draw through
                        // DrawFromInventory instead (live-verified; see
                        // KCD2MP_GhostDrawItem for the ordering trap).
                        await ExecLuaAsync($"if KCD2MP_GhostDrawItem then KCD2MP_GhostDrawItem(\"{ceSource}\",\"{oversized}\") end");
                    }
                    else
                    {
                        await ExecLuaAsync($"if KCD2MP_GhostCombat then KCD2MP_GhostCombat(\"{ceSource}\",{ceEvent}) end");
                    }
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
                        // WO-88 finding 2: remember the raw set (ApplyAppearanceAsync
                        // rewrites aliases in place) so a respawned body can be
                        // re-dressed from it without waiting for the next heartbeat.
                        _ghostLastAppearance[sourceId] = (Guid[])items.Clone();
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
                else
                {
                    // WO-110 R9: a known type that failed its exact-length gate
                    // above, or a type this build does not know. Counted, not
                    // silent -- MP-RELAY-DROPS side=client every 60 s.
                    CountDrop(type, "unknown-or-wrong-length");
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) when (ex is IOException or SocketException or EndOfStreamException) { }
    }

    // -------------------------------------------------------------------------
    // Game REST API helpers
    // -------------------------------------------------------------------------

    private async Task UpdateGhostAsync(string ghostId, float x, float y, float z, float rotZ,
                                        bool isRiding, BodyState? body = null)
    {
        string gx   = x.ToString("F2",  CultureInfo.InvariantCulture);
        string gy   = y.ToString("F2",  CultureInfo.InvariantCulture);
        string gz   = z.ToString("F2",  CultureInfo.InvariantCulture);
        string rot  = rotZ.ToString("F4", CultureInfo.InvariantCulture);
        string ride = isRiding ? "true" : "false";

        // WO-100.5 Phase 2: four extra arguments, appended. A pre-WO-100.5 pak
        // has a 6-parameter KCD2MP_UpdateGhost and ignores the extras, so a
        // mod/agent mismatch degrades to the old call rather than erroring --
        // the same additive discipline the wire uses.
        string tail = body is BodyState b
            ? $",{(byte)b.Pace},{(byte)b.Dir},{(byte)b.Stance},{b.AnimSpeedCenti}"
            : string.Empty;

        try
        {
            await ExecLuaAsync($@"KCD2MP_UpdateGhost(""{ghostId}"",{gx},{gy},{gz},{rot},{ride}{tail})");
            Console.WriteLine($"[ghost {ghostId}] {gx} {gy} {gz} riding={isRiding}");
        }
        catch { /* game might have unloaded */ }
    }

    /// <summary>
    /// Pushes a peer's authoritative health onto their ghost's nameplate
    /// (WO-28 Flow A), and clears the death tag when they report themselves
    /// alive -- a completed save reload is exactly "their vitals started
    /// arriving again", so nothing else has to detect the end of a death.
    /// </summary>
    private async Task ApplyGhostVitalsAsync(byte ghostId, float health, float stamina, byte flags, CancellationToken ct)
    {
        string h = health.ToString("F1", CultureInfo.InvariantCulture);
        string s = stamina.ToString("F1", CultureInfo.InvariantCulture);
        try
        {
            await ExecLuaAsync($"KCD2MP_SetGhostHealth(\"{ghostId}\",{h},{s},{flags})");
            // Health arriving means that player's game is running and they are
            // in a world -- so any death tag from before their reload is stale.
            // Cheap: batched with the call above into the same flush.
            //
            // WO-88 finding 1: only when the vitals say ALIVE. The dying
            // player's emitter sends health=0 in the same tick as its 0x23;
            // whichever the relay delivered second used to win, and when it
            // was the vitals the tag was cleared within milliseconds of being
            // set (host kcd.log 141413->141416, 164600->164632 on 2026-09-12)
            // -- a dead player's stand-in then kept walking its stale stream.
            if (ReloadReconcile.VitalsClearDeathTag(health))
                await ExecLuaAsync($"KCD2MP_SetGhostDead(\"{ghostId}\", false)");
        }
        catch { /* game might have unloaded */ }
    }

    /// <summary>Escapes a string for embedding in a Lua double-quoted literal.</summary>
    /// <summary>
    /// Escapes a string for interpolation inside a double-quoted Lua literal.
    /// WO-110 R15: also newlines and every other control character (as Lua
    /// 5.1 decimal escapes) -- a peer name with a newline used to end the
    /// literal early and fail the WHOLE ExecuteString batch it was in.
    /// </summary>
    private static string EscapeLua(string s)
    {
        var sb = new StringBuilder(s.Length + 8);
        foreach (char c in s)
        {
            switch (c)
            {
                case '\\': sb.Append("\\\\"); break;
                case '"':  sb.Append("\\\""); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20 || c == 0x7F) sb.Append('\\').Append(((int)c).ToString("D3", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        return sb.ToString();
    }

    private async Task SetGhostNameAsync(string ghostId, string ghostName)
    {
        // Escape any quotes in name to avoid Lua injection (WO-110 R15: the shared helper, control characters too)
        var safeName = EscapeLua(ghostName);
        try
        {
            await ExecLuaAsync($@"KCD2MP_SetGhostName(""{ghostId}"",""{safeName}"")");
            Console.WriteLine($"[name] ghost {ghostId} = {ghostName}");
        }
        catch { }
    }

    /// <summary>
    /// The time_now parse. Deliberately STRICT: plain decimal digits only.
    /// WO-104: the 2026-09-18 session lost time sync when the world clock
    /// crossed 1e6 and the mod's tostring() switched to scientific notation
    /// ('1.00255e+06'). The fix is at the sender (kdcmp.lua formats with
    /// "%.0f" now), not here -- a parser that accepted the exponent form
    /// would also silently accept a reading that had already lost digits
    /// (six significant figures at 1e6 is a ~5 s granularity), and the
    /// clock-jump watcher would then see phantom jumps.
    /// </summary>
    public static bool TryParseWorldTime(string arg, out uint worldTime)
        => uint.TryParse(arg, NumberStyles.AllowLeadingWhite | NumberStyles.AllowTrailingWhite, CultureInfo.InvariantCulture, out worldTime);

    /// <summary>
    /// Handles a discrete event the player triggered in game, delivered via the
    /// log tail. Fire-and-forget because this runs on the tail loop's thread and
    /// must not block it.
    /// </summary>
    private void OnGameEvent(string name, string arg)
    {
        // WO-38: the world-clock reading is consumed regardless of the
        // interaction layer's state -- it feeds the time-skip sync, which has
        // no dependency on sessions being up.
        if (name == "time_now")
        {
            if (TryParseWorldTime(arg, out uint worldTime))
                OnWorldTimeReading(worldTime);
            else
                Console.WriteLine($"[timeskip] malformed time_now '{arg}'");
            return;
        }

        // WO-94 Shared Quests: the mod's proximity detector and its own fire.
        // Consumed regardless of interaction-session state, like time_now.
        if (name == "quest_approach")
        {
            if (StoryBeat.IsValidBeatPath(arg))
            {
                Console.WriteLine($"[quest] approaching {arg} -- telling peers");
                _ = _sendStoryBeat?.Invoke(Protocol.StoryBeatKindApproach, arg);
            }
            else Console.WriteLine($"[quest] malformed quest_approach '{arg}'");
            return;
        }
        if (name == "quest_catchup")
        {
            // "begin <path>" | "end <path>" | "decline <path>"
            var qp = arg.Split(' ', 2, StringSplitOptions.RemoveEmptyEntries);
            string qpath = qp.Length == 2 ? qp[1] : string.Empty;
            if (qp.Length != 2 || !StoryBeat.IsValidBeatPath(qpath)) { Console.WriteLine($"[quest] malformed quest_catchup '{arg}'"); return; }
            switch (qp[0])
            {
                case "begin":
                    _localCatchup = (qpath, DateTime.UtcNow);
                    Console.WriteLine($"[quest] CATCH-UP FIRED HERE: wh_concept_HasteTrigger {qpath} -- hazard window open for {CatchupWindow.TotalSeconds:F0}s; peers told");
                    _ = _sendStoryBeat?.Invoke(Protocol.StoryBeatKindCatchupBegin, qpath);
                    break;
                case "end":
                    _localCatchup = null;
                    Console.WriteLine($"[quest] catch-up window closed here: {qpath}");
                    _ = _sendStoryBeat?.Invoke(Protocol.StoryBeatKindCatchupEnd, qpath);
                    break;
                case "decline":
                    Console.WriteLine($"[quest] player declined to catch up to {qpath} (staying on own story; WO-90 divergence release remains the safety net)");
                    break;
                default:
                    Console.WriteLine($"[quest] unknown quest_catchup verb '{qp[0]}'");
                    break;
            }
            return;
        }

        if (name == "ghostid")
        {
            // WO-46: "<ghostId> <entityIdHex>" from KCD2MP_SpawnGhost. The hex
            // is the tail of Lua's tostring(entity.id) userdata print — the
            // only numeric form the stripped sandbox can produce (its floats
            // lose integer precision above 2^24, so a decimal path would
            // corrupt large ids). Cached for the native swing path; consumed
            // regardless of interaction-session state, like time_now above.
            var giParts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (giParts.Length == 2
                && ulong.TryParse(giParts[1], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out ulong rawId)
                && rawId is > 0 and <= uint.MaxValue)
            {
                uint? previousEntityId = _ghostEntityIds.TryGetValue(giParts[0], out uint prevId) ? prevId : null;
                _ghostEntityIds[giParts[0]] = (uint)rawId;
                // WO-100 Phase 4 item 1: a different id is a different body, so
                // every event still in flight for the old one is now invalid.
                if (previousEntityId is uint had && had != (uint)rawId)
                    BumpGhostGeneration(giParts[0], $"entity 0x{had:X} -> 0x{rawId:X}");
                Console.WriteLine($"[combatviz] ghost {giParts[0]} entity id 0x{rawId:X} cached for native swings");

                // WO-88 finding 2: a NEW entity id for a ghost we already
                // dressed is a respawned body (local save load -> RECONCILE ->
                // fresh spawn in its preset). The per-ghost applied/known/
                // blacklist sets describe the destroyed body; drop them and
                // re-apply the outfit the peer last sent. Without this the
                // heartbeat diffed to nothing against the stale applied set
                // and the ghost stayed in default armour for the rest of the
                // session (both machines, 2026-09-12, after each side's first
                // reload). Same edge WO-68 uses for civic isolation below.
                if (ReloadReconcile.RespawnInvalidatesAppearance(previousEntityId, (uint)rawId)
                    && byte.TryParse(giParts[0], NumberStyles.Integer, CultureInfo.InvariantCulture, out byte respawnedId))
                {
                    _ghostAppearance.TryRemove(respawnedId, out _);
                    _ghostKnownItemClasses.TryRemove(respawnedId, out _);
                    _ghostNeverEquips.TryRemove(respawnedId, out _);
                    if (_ghostLastAppearance.TryGetValue(respawnedId, out var lastOutfit))
                    {
                        Console.WriteLine($"[appearance] ghost {respawnedId}: body respawned (entity 0x{prevId:X} -> 0x{rawId:X}) -- re-applying its last {lastOutfit.Length} item class(es)");
                        _ = ApplyAppearanceAsync(respawnedId, (Guid[])lastOutfit.Clone(), CancellationToken.None);
                    }
                    else
                    {
                        Console.WriteLine($"[appearance] ghost {respawnedId}: body respawned (entity 0x{prevId:X} -> 0x{rawId:X}) -- no outfit received yet, next packet dresses it");
                    }
                }

                // WO-68: this event is the ghost-ready edge -- it fires from
                // KCD2MP_SpawnGhost, so it also fires on every respawn and
                // after a save load rebuilds the bodies, which is exactly when
                // the native contexts need (re-)applying. Fire-and-forget: a
                // ghost is never blocked on its civic isolation.
                if (_ghostIsolate)
                    _ = IsolateGhostAsync(giParts[0], on: true, CancellationToken.None);
            }
            else
            {
                Console.WriteLine($"[combatviz] malformed ghostid '{arg}'");
            }
            return;
        }

        if (name == "isolate")
        {
            // WO-68: "on"|"off" from KCD2MP_SetGhostIsolate. mp_ghost_isolate is
            // one switch for the whole feature, and its Lua half cannot reach
            // the contexts on this build -- so the toggle has to cross over to
            // the native half, and this event is that crossing. Consumed
            // regardless of interaction-session state, like ghostid above.
            var want = arg.Equals("on", StringComparison.OrdinalIgnoreCase);
            if (want == _ghostIsolate)
            {
                Console.WriteLine($"[isolate] already {(want ? "on" : "off")}; nothing to do");
                return;
            }
            _ghostIsolate = want;
            Console.WriteLine($"[isolate] native context isolation {(want ? "enabled" : "disabled")}");
            // Both directions act on the ghosts standing right now: on -> apply,
            // off -> remove. The engine's store is refcounted and the DLL only
            // writes a context that is not already in the wanted state, so
            // repeated toggling cannot strand a context set with count > 1.
            foreach (var ghostId in _ghostEntityIds.Keys.ToArray())
                _ = IsolateGhostAsync(ghostId, on: want, CancellationToken.None);
            return;
        }

        if (name == "npcid")
        {
            // WO-49: "<npcName> <entityIdHex>" from KCD2MP_ApplyNpcState's
            // puppet-start path -- the ghostid idiom applied to this world's
            // copy of a puppeted NPC. The name is re-validated here because it
            // is later interpolated into Lua on the swing-fallback path.
            var niParts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (niParts.Length == 2
                && NpcNamePattern.IsMatch(niParts[0])
                && ulong.TryParse(niParts[1], NumberStyles.HexNumber, CultureInfo.InvariantCulture, out ulong npcRawId)
                && npcRawId is > 0 and <= uint.MaxValue)
            {
                _npcEntityIds[niParts[0]] = (uint)npcRawId;
                Console.WriteLine($"[npcsync] puppet {niParts[0]} entity id 0x{npcRawId:X} cached for native swings");
                RefreshNpcEquipped(niParts[0]);
            }
            else
            {
                Console.WriteLine($"[npcsync] malformed npcid '{arg}'");
            }
            return;
        }

        if (name == "npc_replica")
        {
            // WO-104 Phase 1: "<npc> <replicaName|->" from KCD2MP_NpcReplicaPromote/Demote.
            var rp = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (rp.Length == 2 && NpcNamePattern.IsMatch(rp[0]))
            {
                if (rp[1] == "-")
                {
                    foreach (var kv in _npcReplicaOrig)
                        if (kv.Value == rp[0]) _npcReplicaOrig.TryRemove(kv.Key, out _);
                    Console.WriteLine($"[npcsync] replica for {rp[0]} released");
                }
                else if (NpcNamePattern.IsMatch(rp[1]))
                {
                    _npcReplicaOrig[rp[1]] = rp[0];
                    Console.WriteLine($"[npcsync] replica {rp[1]} now stands in for {rp[0]} (hits on it are attributed to {rp[0]})");
                }
                else Console.WriteLine($"[npcsync] malformed npc_replica '{arg}'");
            }
            else Console.WriteLine($"[npcsync] malformed npc_replica '{arg}'");
            return;
        }

        if (name == "npc_replica_toggle")
        {
            // WO-104: console flip of mp_npc_replica_on|off. Log only -- the
            // mechanism is entirely mod-side; the agent has no gate to mirror.
            Console.WriteLine($"[npcsync] mp_npc_replica {arg} (mod-side toggle; ships on since 0.26.2, unverified live)");
            return;
        }

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

            case "aggro_toggle":
                // mp_enable_aggro on|off (WO-17): the real, always-available
                // toggle Phase B agreed on. Decided locally, per player -- it
                // only changes how THIS client's world treats an incoming
                // ghost, so it needs no session invite/agreement the way dice
                // does. Off means every damage event below is a no-op, which
                // is what keeps the default (never-toggled) path byte-for-
                // byte identical to pre-WO-17 behaviour.
                _aggroEnabled = arg.Equals("on", StringComparison.OrdinalIgnoreCase);
                Console.WriteLine($"[aggro] {(_aggroEnabled ? "enabled" : "disabled")}");
                if (!_aggroEnabled)
                {
                    // Turning it off mid-fight must not leave a ghost stuck
                    // hostile forever with nothing left to detach it.
                    foreach (var id in _ghostHostileUntilUtc.Keys.ToArray())
                        _ = DetachGhostAggroAsync(id, CancellationToken.None);
                }
                break;

            case "ghost_hit":
            {
                // WO-28 Flow B: "<ghostId> <healthLoss>". The mod samples each
                // ghost's local health in KCD2MP_InterpTick and reports drops
                // -- it only samples at all while this client holds damage
                // authority, so reaching here already implies the host-only
                // gate, which SendPlayerHitAsync then checks again anyway.
                //
                // Stamina is deliberately absent: there is no confirmed Lua
                // stamina binding on this build, and inventing a number here
                // would drain a real player's stamina on a guess.
                var bits = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (bits.Length < 2
                    || !byte.TryParse(bits[0], out byte hitGhostId)
                    || !float.TryParse(bits[1], NumberStyles.Float, CultureInfo.InvariantCulture, out float loss))
                {
                    Console.WriteLine($"[playerhit] malformed ghost_hit '{arg}'");
                    break;
                }
                var send = _sendPlayerHit;
                if (send is null) break;
                _ = send(hitGhostId, loss, 0f);
                break;
            }

            case "npc_resync_request":
                // WO-102 Phase 6: mp_resync_npcs from the console.
                _ = RequestNpcResyncAsync(NpcResyncReason.Manual, _resyncStream, CancellationToken.None);
                break;

            case "npc_target":
            {
                // WO-102 Phase 5: "<name>" or "-" from the puppet tick -- the
                // owned NPC this player is facing, for the request channel.
                string tgt = arg.Trim();
                if (tgt == "-" || tgt.Length == 0) { _npcTarget = null; break; }
                if (!NpcNamePattern.IsMatch(tgt) || tgt.Length > NpcRequestPayload.MaxNameLen)
                {
                    Console.WriteLine($"[request] rejected npc_target '{arg}' (not an authored entity name)");
                    break;
                }
                _npcTarget = tgt;
                break;
            }

            case "wo102_toggle":
            {
                // WO-102 Phase 0: "<name> on|off" from KCD2MP_Wo102Set (console).
                var tp = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (tp.Length != 2) { Console.WriteLine($"[wo102] malformed wo102_toggle '{arg}'"); break; }
                bool on = tp[1].Equals("on", StringComparison.OrdinalIgnoreCase);
                switch (tp[0])
                {
                    case "authority_host": _hostAuthority = on; break;
                    case "pos_native":
                        _posNative = on;
                        // A fresh start each time it is switched on: the give-up
                        // and oracle verdicts belong to the previous run.
                        _posNativeMisses = 0; _posNativeGaveUp = false; _posNativeRefusedByOracle = false;
                        _oracleBadRun = 0; _oracleN = 0; _oracleSum = 0; _oracleMax = 0;
                        _cadNative.Reset(); _lastNativeFrame = 0; _lastNative = null;
                        break;
                    case "npc_scan_native":
                        _npcScanNative = on;
                        _npcScanMisses = 0; _npcScanGaveUp = false;
                        break;
                    // WO-108: the brain-pause lever is Lua-only (System.ExecuteCommand
                    // from the mod); nothing agent-side mirrors it. Acknowledged so
                    // a preset or mp_authority_pause_on/off does not log "unknown".
                    case "authority_pause": break;
                    default: Console.WriteLine($"[wo102] unknown toggle '{tp[0]}'"); break;
                }
                Console.WriteLine($"WO102-TOGGLE name={tp[0]} state={(on ? "on" : "off")} source=console authority={(_isDamageAuthority ? 1 : 0)}");
                break;
            }

            case "authority_radius":
            {
                // WO-102.5 Phase 3: #KCD2MP_SetAuthorityRadius announces its
                // new value here so the native scan's own radius (agent-side,
                // NpcScanTickAsync) does not silently stay capped at the old
                // number -- Lua's fallback path (System.GetEntitiesInSphere)
                // already reads the mod's own config directly and needs no
                // mirror.
                if (float.TryParse(arg, System.Globalization.NumberStyles.Float,
                        System.Globalization.CultureInfo.InvariantCulture, out var radiusM) && radiusM > 0)
                {
                    _npcScanRadiusM = radiusM;
                    Console.WriteLine(FormattableString.Invariant($"[npcscan] authority radius set to {radiusM:F1}m"));
                }
                else
                {
                    Console.WriteLine($"[npcscan] ignored malformed authority_radius '{arg}'");
                }
                break;
            }

            case "npc_track_max":
            {
                // WO-110 R3: mp_npc_track_max <n> in the mod -- the push cap
                // is Lua-owned like authority_radius and announced the same way.
                if (int.TryParse(arg, NumberStyles.Integer, CultureInfo.InvariantCulture, out int cap))
                {
                    _npcTrackMax = Math.Clamp(cap, NpcTrackMaxFloor, NpcTrackMaxCeiling);
                    Console.WriteLine(FormattableString.Invariant($"[npcscan] track cap set to {_npcTrackMax} (asked {cap})"));
                }
                else Console.WriteLine($"[npcscan] ignored malformed npc_track_max '{arg}'");
                break;
            }

            case "npc_deathsync":
                // WO-86: mp_npc_deathsync on|off, mirrored here because the
                // inbound death apply runs in the agent (Lua writes are inert)
                // and the agent cannot read the mod's toggle back.
                _npcDeathSyncEnabled = !arg.Equals("off", StringComparison.OrdinalIgnoreCase);
                Console.WriteLine($"[npcdeath] mp_npc_deathsync {(_npcDeathSyncEnabled ? "on" : "off")} -- inbound NPC deaths will {(_npcDeathSyncEnabled ? "" : "NOT ")}be applied here");
                break;

            case "npc_death":
            {
                // WO-86: "<npcName> <hp> <source>" from the mod's death
                // observer -- a world NPC this client saw ALIVE and now reads
                // as actor:IsDead() in this world, not announced yet by the
                // DLL's FATAL hit (which is frame-accurate but only fires for
                // hits the DLL's sampler attributed to this client). Any
                // client may report a death it observed, like damage: no
                // authority gate. Travels as a zero-delta 0x30 with the FATAL
                // bit; the receiver's ApplyDeath is idempotent.
                var dp = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (dp.Length < 1 || !NpcNamePattern.IsMatch(dp[0]) || dp[0].Length > Protocol.MaxNpcNameLen)
                {
                    Console.WriteLine($"[npcdeath] malformed npc_death '{arg}'");
                    break;
                }
                string deadName = dp[0];
                string deadHp   = dp.Length > 1 ? dp[1] : "?";
                string deadSrc  = dp.Length > 2 ? dp[2] : "lua";
                var sendDeath = _sendNpcDeath;
                if (sendDeath is null) break;
                Console.WriteLine($"[npcdeath] out: mod observed '{deadName}' die locally (hp={deadHp}, seen by {deadSrc}) -- sending FATAL{CatchupTag()}");
                _ = sendDeath(deadName)
                    .ContinueWith(t =>
                    {
                        if (t.IsFaulted)
                            Console.WriteLine($"[npcdeath] FATAL for '{deadName}' not sent: {t.Exception?.GetBaseException().Message}");
                    }, TaskScheduler.Default);
                break;
            }

            case "npc_state":
            case "npc_drag":
            case "npc_claim":
            {
                // NPC sync (WO-32): "<name> <x> <y> <z> <rotZ> <health> [flags]"
                // from KCD2MP_NpcSyncTick. npc_state is the world authority's
                // ambient 30 m stream; npc_drag (WO-39 Phase 2) is the drag
                // sensor's manipulated-body stream, allowed from ANY client --
                // sending it is how a body is claimed; the relay arbitrates.
                // npc_claim (WO-60) is a non-authority's proximity stream for
                // NPCs near ITS player: same payload, same claim-by-sending
                // rule, so it rides the same asClaim send path as npc_drag.
                var f = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (f.Length < 6
                    || !float.TryParse(f[1], NumberStyles.Float, CultureInfo.InvariantCulture, out float nsx)
                    || !float.TryParse(f[2], NumberStyles.Float, CultureInfo.InvariantCulture, out float nsy)
                    || !float.TryParse(f[3], NumberStyles.Float, CultureInfo.InvariantCulture, out float nsz)
                    || !float.TryParse(f[4], NumberStyles.Float, CultureInfo.InvariantCulture, out float nsrot)
                    || !float.TryParse(f[5], NumberStyles.Float, CultureInfo.InvariantCulture, out float nshp))
                {
                    Console.WriteLine($"[npcsync] malformed {name} '{arg}'");
                    break;
                }
                byte nsflags = f.Length > 6 && byte.TryParse(f[6], out byte nf) ? nf : (byte)0;
                var sendNpc = name == "npc_state" ? _sendNpcState : _sendNpcDrag;
                if (sendNpc is null) break;
                if (name == "npc_state") lock (_requestsIn) _ownedNpcSeenUtc[f[0]] = DateTime.UtcNow;   // WO-102 Phase 5
                _ = sendNpc(f[0], nsx, nsy, nsz, nsrot, nshp, nsflags);
                if (name == "npc_state") _stats.NpcStateOut++; else if (name == "npc_claim") _stats.NpcClaimOut++; else _stats.NpcDragOut++;   // WO-98
                break;
            }

            case "horse_info":
            {
                // Horse identity (WO-38 Phase 5): "<entityName>" from the
                // riding check, "-" for dismounted or an unreadable mount.
                // Validated exactly like NPC names -- it is the same kind of
                // authored entity name and crosses the same trust boundary.
                string horseName = arg.Trim();
                if (horseName == "-") horseName = "";
                if (horseName.Length > 0 && (!NpcNamePattern.IsMatch(horseName) || horseName.Length > Protocol.MaxHorseNameLen))
                {
                    Console.WriteLine($"[horse] rejected mount name '{arg}' (not an authored entity name)");
                    break;
                }
                var sendHorse = _sendHorseInfo;
                if (sendHorse is null) break;
                _ = sendHorse(horseName);
                break;
            }

            case "bed_near":
                // WO-39 Phase 8: BedTrigger proximity transitions from the
                // mod's 1 Hz poll. Held, not acted on -- OnLocalSkipTime reads
                // it when a skip marker arrives.
                _nearBed = arg.Trim() == "1";
                Console.WriteLine($"[timeskip] player is {(_nearBed ? "at a bed" : "away from beds")}");
                break;

            case "combat":
            {
                // Combat visibility (WO-39 Phase 1): "draw", "sheathe",
                // "swing", "block" from the mod's drawn-state poll and
                // OnAction hook. Unknown words are dropped here so a future
                // pak can emit new ones without crashing an old agent.
                byte? evt = arg.Trim() switch
                {
                    "draw"    => Protocol.CombatEventWeaponDrawn,
                    "sheathe" => Protocol.CombatEventWeaponSheathed,
                    "swing"   => Protocol.CombatEventSwing,
                    "block"   => Protocol.CombatEventBlock,
                    _         => null,
                };
                if (evt is null)
                {
                    Console.WriteLine($"[combatviz] unknown combat event '{arg}' ignored");
                    break;
                }
                var sendCombat = _sendCombatEvent;
                if (sendCombat is null) break;
                ushort swingSid = evt.Value == Protocol.CombatEventSwing ? (ushort)(++_stats.SwingsSent) : (ushort)0;
                _ = sendCombat(evt.Value, swingSid);
                if (evt.Value == Protocol.CombatEventSwing)
                    Console.WriteLine($"MP-SWING hop=sent sid={swingSid}");   // WO-98 Phase 6 / WO-99 Phase 4: sid is on the wire
                break;
            }

            case "item_drop":
            {
                // Dropped-item sync (WO-48):
                // "<classGuid> <amount> <health> <x> <y> <z> <entityName>"
                // from the mod's drop detector. The agent mints the dropId
                // here (random nonzero -- a player-dropped item has no
                // authored identity) and hands it straight back to the mod so
                // both sides key the same drop the same way. entityName is
                // engine-generated; validated like every name that crosses
                // back into a Lua string literal.
                var df = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (df.Length < 7
                    || !Guid.TryParse(df[0], out Guid dropClass)
                    || !ushort.TryParse(df[1], out ushort dropAmount)
                    || !float.TryParse(df[2], NumberStyles.Float, CultureInfo.InvariantCulture, out float dropHealth)
                    || !float.TryParse(df[3], NumberStyles.Float, CultureInfo.InvariantCulture, out float dropX)
                    || !float.TryParse(df[4], NumberStyles.Float, CultureInfo.InvariantCulture, out float dropY)
                    || !float.TryParse(df[5], NumberStyles.Float, CultureInfo.InvariantCulture, out float dropZ)
                    || !NpcNamePattern.IsMatch(df[6]))
                {
                    Console.WriteLine($"[itemsync] malformed item_drop '{arg}'");
                    break;
                }
                var sendDrop = _sendItemDrop;
                if (sendDrop is null) break;
                uint dropId;
                var dropPayload = BuildItemDropPayload(0, dropClass, dropAmount, dropHealth, dropX, dropY, dropZ);
                do { dropId = (uint)Random.Shared.Next(1, int.MaxValue); }
                while (!_myOpenDrops.TryAdd(dropId, dropPayload));
                BinaryPrimitives.WriteUInt32LittleEndian(dropPayload, dropId);
                Console.WriteLine($"[itemsync] local drop {dropId}: {dropClass} x{dropAmount} at {dropX:F1},{dropY:F1},{dropZ:F1}");
                _ = sendDrop(dropPayload);
                // The dropId travels to Lua as a STRING: the stripped Lua 5.1
                // floats lose integer precision above 2^24 (the WO-46 ghostid
                // lesson) and a random 31-bit id usually exceeds that.
                _ = ExecLuaAsync($"if KCD2MP_ItemDropRegistered then KCD2MP_ItemDropRegistered(\"{dropId}\",\"{df[6]}\") end");
                break;
            }

            case "item_claim":
            {
                // "<dropId>" -- the mod's watcher saw a tracked drop's entity
                // vanish without the mod itself removing it: something in this
                // world (normally the local player) took it. The relay's echo
                // (ItemClaimDown) is what settles who actually won.
                if (!uint.TryParse(arg.Trim(), out uint claimDropId) || claimDropId == 0)
                {
                    Console.WriteLine($"[itemsync] malformed item_claim '{arg}'");
                    break;
                }
                var sendClaim = _sendItemClaim;
                if (sendClaim is null) break;
                _ = sendClaim(claimDropId);
                break;
            }

            case "appearance_sync":
                // mp_sync_appearance (WO-9): the honest floor. Forces the next
                // poll tick to send regardless of whether the equipped set
                // actually changed, so a tester never has to wait out the poll
                // interval or the heartbeat to demo or fix a desync.
                Console.WriteLine("[appearance] manual resync requested");
                _forceAppearanceResync = true;
                break;

            case "slow_time_toggle":
                // mp_slow_time (WO-11): the honest floor for pause detection,
                // same idea as mp_sync_appearance above. Automatic detection
                // only covers the four states confirmed live (menu,
                // inventory, skip-time, Rendered cutscenes -- WO-80) --
                // dialogs, a tutorial popup or photo mode were never
                // confirmed to emit a usable log marker, so this lets a player
                // manually declare "I'm effectively unavailable" regardless
                // of why. Toggles rather than a one-shot, since Lua has no
                // way to know the current state; OR'd with automatic
                // detection in SendPauseIfChangedAsync, so this never turns
                // OFF a pause that automatic detection still considers active.
                _localManualPaused = !_localManualPaused;
                Console.WriteLine($"[pause] manual override -> {(_localManualPaused ? "paused" : "cleared")}");
                _ = ExecLuaAsync($"if KCD2MP_ShowInteractionMsg then KCD2MP_ShowInteractionMsg(\"{(_localManualPaused ? "Slow-time: broadcasting paused" : "Slow-time: override cleared")}\") end");
                _ = _sendPauseIfChanged?.Invoke();
                break;

            case "invite_send":
            {
                // "<ghostId> <kind> [wagerAmount]" — Lua picks the target
                // because it has the ghost positions; we only know relay ids.
                // wagerAmount (WO-33) is dice-only and optional, groschen, from
                // KCD2MP.dice.wagerAmount; Lua already checked its own balance
                // before emitting this, so no re-check happens here.
                var parts = arg.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                if (parts.Length < 1 || !byte.TryParse(parts[0], out byte targetId))
                {
                    Console.WriteLine($"[interaction] malformed invite_send '{arg}'");
                    break;
                }
                var kind = parts.Length > 1 && parts[1].Equals("duel", StringComparison.OrdinalIgnoreCase)
                    ? InteractionKind.Duel
                    : InteractionKind.Dice;

                byte[]? config = null;
                if (kind == InteractionKind.Dice)
                {
                    int wager = parts.Length > 2 && int.TryParse(parts[2], out int w) ? w : 0;
                    config = new byte[10];
                    BinaryPrimitives.WriteUInt16LittleEndian(config, (ushort)Protocol.DefaultDiceTargetScore);
                    BinaryPrimitives.WriteInt32LittleEndian(config.AsSpan(6), wager);
                }

                Console.WriteLine($"[interaction] inviting ghost {targetId} to {kind}"
                    + (config is not null ? $" (wager {BinaryPrimitives.ReadInt32LittleEndian(config.AsSpan(6))})" : ""));
                _ = interactions.InviteAsync(targetId, kind, config);
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

    // -------------------------------------------------------------------------
    // WO-17 reactive aggro
    //
    // The toggle (mp_enable_aggro, above) only gates whether this machinery
    // runs at all. What actually attaches/detaches a ghost's faction is
    // combat itself: a ghost keeps the mod's original invisible-to-NPCs
    // behaviour right up until it lands a hit, or a hit lands on it, exactly
    // like Henry -- not a standing "this player is a bandit" flag. This is
    // deliberately a coarser proxy than the game's own crime/witness system
    // (out of scope, ties into private per-player reputation), but it is
    // driven by real combat events already flowing through this class, not a
    // guess.
    // -------------------------------------------------------------------------

    /// <summary>
    /// Resolves and caches a ghost's own Soul.Guid. Returns null (and caches
    /// nothing) while the ghost is not yet a real soul the game will answer
    /// for -- a normal, transient state right after spawn.
    /// </summary>
    private async Task<Guid?> ResolveGhostSoulGuidAsync(byte ghostId, CancellationToken ct)
    {
        if (_ghostSoulGuidCache.TryGetValue(ghostId, out var cached)) return cached;

        var guid = await _transport.ReadGhostSoulGuidAsync($"kcd2mp_{ghostId}", ct);
        if (guid is { } g) _ghostSoulGuidCache[ghostId] = g;
        return guid;
    }

    /// <summary>
    /// Marks a ghost as currently "in a fight" -- attaches it to the hostile
    /// faction if it was not already attached, and always refreshes the hold
    /// timer so a sustained fight does not flap attach/detach every sweep.
    /// No-op, silently, when aggro is disabled: every caller of this can stay
    /// unconditional, keeping the toggle-off path simple to audit.
    /// </summary>
    private async Task TriggerReactiveAggroAsync(byte ghostId, CancellationToken ct)
    {
        if (!_aggroEnabled) return;

        bool wasHeld = _ghostHostileUntilUtc.ContainsKey(ghostId);
        _ghostHostileUntilUtc[ghostId] = DateTime.UtcNow + AggroHoldDuration;
        if (wasHeld) return; // already attached; just refreshed the hold

        var guid = await ResolveGhostSoulGuidAsync(ghostId, ct);
        if (guid is null)
        {
            Console.WriteLine($"[aggro] ghost {ghostId} has no resolvable soul yet; not attaching");
            _ghostHostileUntilUtc.TryRemove(ghostId, out _);
            return;
        }

        bool ok = await _combat.SetFactionHostileAsync(guid.Value, hostile: true, ct);
        Console.WriteLine($"[aggro] ghost {ghostId} attached to hostile faction: {ok}");
        if (!ok) _ghostHostileUntilUtc.TryRemove(ghostId, out _); // failed -- nothing to detach later
    }

    /// <summary>
    /// WO-68: apply or remove the seven civic-isolation script contexts on one
    /// ghost, through the DLL (pipe 0x07). The soul Guid is read fresh every
    /// time rather than cached: a ghost's own Soul.Guid is minted per spawn
    /// (WO-39/WO-40 -- per-save Guids are field-confirmed unstable), and this
    /// runs once per spawn or per toggle, not on any hot path.
    ///
    /// Ghost ids are strings here, not the byte ids <see cref="_ghostSoulGuidCache"/>
    /// uses, so the locally-spawned test ghost ("test_ghost") is covered too.
    ///
    /// Never throws into its caller: every failure is a log line. A ghost that
    /// cannot be isolated is still a ghost.
    /// </summary>
    private async Task IsolateGhostAsync(string ghostId, bool on, CancellationToken ct)
    {
        try
        {
            Guid? guid = null;
            try { guid = await _transport.ReadGhostSoulGuidAsync($"kcd2mp_{ghostId}", ct); }
            catch (Exception ex) { Console.WriteLine($"[isolate] ghost {ghostId} guid read failed: {ex.Message}"); }

            if (guid is null)
            {
                Console.WriteLine($"[isolate] ghost {ghostId}: no soul guid yet -- contexts not "
                                + (on ? "applied" : "removed") + " (next spawn retries)");
                return;
            }

            bool ok = await _combat.GhostIsolateAsync(guid.Value, on, ct);
            Console.WriteLine($"[isolate] ghost {ghostId} contexts {(on ? "applied" : "removed")}: {ok}"
                            + (ok ? "" : " -- see the SCTX lines in kcdmp-native.log"));
        }
        catch (Exception ex)
        {
            Console.WriteLine($"[isolate] ghost {ghostId} failed: {ex.Message}");
        }
    }

    /// <summary>Detaches one ghost back to its pre-attach orphan state.</summary>
    private async Task DetachGhostAggroAsync(byte ghostId, CancellationToken ct)
    {
        _ghostHostileUntilUtc.TryRemove(ghostId, out _);
        if (!_ghostSoulGuidCache.TryGetValue(ghostId, out var guid)) return;
        try
        {
            bool ok = await _combat.SetFactionHostileAsync(guid, hostile: false, ct);
            Console.WriteLine($"[aggro] ghost {ghostId} detached from hostile faction: {ok}");
        }
        catch (Exception ex) { Console.WriteLine($"[aggro] detach failed: {ex.Message}"); }
    }

    /// <summary>
    /// Called on a slow cadence from the main tick loop. Cheap when nothing
    /// is attached (one dictionary scan, no I/O) -- only a ghost whose hold
    /// timer has actually expired triggers a pipe round trip.
    /// </summary>
    private async Task SweepAggroCooldownsAsync(CancellationToken ct)
    {
        if (_ghostHostileUntilUtc.IsEmpty) return;
        var now = DateTime.UtcNow;
        foreach (var (ghostId, until) in _ghostHostileUntilUtc)
        {
            if (until > now) continue;
            await DetachGhostAggroAsync(ghostId, ct);
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
            //
            // invite.WagerAmount (WO-33) rides along so the prompt can show
            // the stake before the player decides -- KCD2MP_AcceptInvite
            // checks it against Inventory.GetMoney() before responding.
            _ = ExecLuaAsync($"if KCD2MP_ShowInvite then KCD2MP_ShowInvite({invite.SessionId},\"{Escape(who)}\",\"{invite.Kind}\",{invite.WagerAmount}) end");
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

            // result.WagerAmount (WO-33) is echoed by the relay on the DiceEnd
            // packet itself -- see Protocol.cs's note on why that, not a
            // remembered value, is what a client applies. KCD2MP_DiceEnd is
            // reached only for a match that ran to a clean conclusion: a
            // mid-match disconnect fires SessionEnded instead (below), which
            // never calls this, so a dropped connection can never debit or
            // credit either side.
            _ = ExecLuaAsync(
                $"if KCD2MP_DiceEnd then KCD2MP_DiceEnd(\"{(won ? "win" : "lose")}\"," +
                $"{result.ScoreInitiator},{result.ScoreAcceptor},{result.WagerAmount}) end");
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

    // WO-110 R9: the client side of the framing-drop counters (the relay has
    // ClientHandler.CountDrop). Drained into one MP-RELAY-DROPS line every
    // 60 s from the main loop, only when something was dropped.
    private readonly Dictionary<string, long> _drops = new();
    private long _dropsTotal;
    private void CountDrop(int type, string reason)
    {
        lock (_drops)
        {
            string key = $"0x{type:X2}:{reason}";
            _drops[key] = _drops.TryGetValue(key, out var n) ? n + 1 : 1;
            _dropsTotal++;
        }
    }
    private void ReportDrops()
    {
        string? line = null;
        lock (_drops)
        {
            if (_drops.Count > 0)
            {
                long interval = _drops.Values.Sum();
                string by = string.Join(",", _drops.OrderByDescending(kv => kv.Value).Select(kv => $"{kv.Key}={kv.Value}"));
                _drops.Clear();
                line = $"MP-RELAY-DROPS side=client interval_s=60 dropped={interval} total={_dropsTotal} by={by}";
            }
        }
        if (line is not null) Console.WriteLine(line);
    }
    private static readonly TimeSpan DropReportInterval = TimeSpan.FromSeconds(60);

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
    public async Task SendLocalHitAsync(NetworkStream stream, Guid soul,
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
        await WritePacketAsync(stream, packet);
    }

    /// <summary>
    /// Sends one name-addressed NPC damage event (0x30, WO-40 Phase 5) -- the
    /// cross-install-reliable alternative to guid-addressed 0x12. The caller
    /// has already translated the local per-save guid to the soul's name.
    /// </summary>
    public async Task SendNpcDamageAsync(NetworkStream stream, string npcName,
                                                float stamina, float health,
                                                bool suppressHitReaction,
                                                bool fatal = false)
    {
        var nb = Encoding.UTF8.GetBytes(npcName);
        var packet = new byte[3 + 1 + nb.Length + Protocol.NpcDamageFixedTail];
        packet[0] = Protocol.NpcDamageUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)(1 + nb.Length + Protocol.NpcDamageFixedTail));
        packet[3] = (byte)nb.Length;
        nb.CopyTo(packet, 4);
        int o = 4 + nb.Length;
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(o), stamina);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(o + 4), health);
        byte ndFlags = suppressHitReaction ? Protocol.DamageFlagSuppressHitReaction : (byte)0;
        if (fatal) ndFlags |= Protocol.NpcDamageFlagFatal;   // WO-86
        packet[o + 8] = ndFlags;
        await WritePacketAsync(stream, packet);
    }

    /// <summary>Report an NPC our client killed. Idempotent at every receiver.</summary>
    public async Task SendLocalDeathAsync(NetworkStream stream, Guid soul)
    {
        var packet = new byte[3 + Protocol.DeathUpPayloadLen];
        packet[0] = Protocol.DeathUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.DeathUpPayloadLen);
        soul.TryWriteBytes(packet.AsSpan(3, 16));
        await WritePacketAsync(stream, packet);
    }

    private async Task SendVoiceAsync(NetworkStream stream, byte[] pcm)
    {
        // 3 header + 640 payload = 643 bytes
        var packet = new byte[3 + Protocol.VoiceFrameLen];
        packet[0] = Protocol.VoiceUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), Protocol.VoiceFrameLen);
        Buffer.BlockCopy(pcm, 0, packet, 3, Protocol.VoiceFrameLen);
        await WritePacketAsync(stream, packet);
    }

    private async Task SendPositionAsync(NetworkStream stream, float x, float y, float z, float rotZ,
                                         bool isRiding, bool stale = false, BodyState? body = null)
    {
        // WO-100.5 Phase 2: body state rides along when we have one, as five
        // extra bytes behind a flag bit. Additive in the WO-99 STALE-bit shape:
        // the packet is the old 17-byte one whenever body is null, so a peer
        // that never gets a reading is byte-for-byte what every previous
        // release sent. WO-101: the bytes come from PositionCodec so the relay
        // round-trip gate sends exactly what this method sends.
        await WritePacketAsync(stream, PositionCodec.BuildPosition(x, y, z, rotZ, isRiding, stale, body));
    }

    /// <summary>
    /// WO-102 Phase 1: the native sample for this tick, or null when the log
    /// path must be used. Three ways to null, each counted and each logged
    /// once: the DLL refuses/does not answer (gives up after
    /// <see cref="PosNativeGiveUpAfter"/> in a row -- an older DLL, or a build
    /// whose actor-to-entity hop is unmapped); the known-answer check fails
    /// (<see cref="OracleBadRunToRefuse"/> consecutive samples more than
    /// <see cref="OracleMaxM"/> from the log line's position -- a plausible
    /// number is not a read, WO-100 S10.5); or the same frame was already
    /// sampled (returned as the cached sample so the coordinates stay native,
    /// but not counted as a fresh one).
    /// </summary>
    private async Task<LocalState?> ReadNativeStateAsync(PlayerState oracle, CancellationToken ct)
    {
        if (_posNativeGaveUp || _posNativeRefusedByOracle) return null;
        LocalState? r = null;
        try { r = await _combat.ReadLocalStateAsync(ct); }
        catch (OperationCanceledException) { throw; }
        catch { }
        if (r is not LocalState ls)
        {
            if (++_posNativeMisses == PosNativeGiveUpAfter)
            {
                _posNativeGaveUp = true;
                var by = _combat.LocalStateRefuseByCode;
                Console.WriteLine(FormattableString.Invariant(
                    $"MP-POSNATIVE verdict=gave-up after={PosNativeGiveUpAfter} refused={_combat.LocalStateRefused} module_missing={by[1]} no_player={by[2]} hop_unmapped={by[3]} faulted={by[4]} nonfinite={by[5]} vtable={by[6]} no_answer={by[7]} -- position stays on the log tail this session (mp_pos_native_off then _on to retry)"));
            }
            _cadNative.Break();
            return null;
        }
        _posNativeMisses = 0;
        if (ls.Frame == _lastNativeFrame && _lastNative is LocalState same) return same;   // same frame: not a new sample
        _lastNativeFrame = ls.Frame;
        _lastNative = ls;
        _cadNative.Sample(NowMs());

        // Known-answer check against the log line's own reading of the same
        // player. The log sample can be a few frames old, so the tolerance is
        // generous and the refusal needs a sustained run -- but it is a hard
        // refusal: a native path that reads a plausible wrong position is worse
        // than the log path it replaces.
        double dx = ls.X - oracle.X, dy = ls.Y - oracle.Y, dz = ls.Z - oracle.Z;
        double d = Math.Sqrt(dx * dx + dy * dy + dz * dz);
        _oracleN++; _oracleSum += d; if (d > _oracleMax) _oracleMax = d;
        if (d > OracleMaxM)
        {
            if (++_oracleBadRun >= OracleBadRunToRefuse)
            {
                _posNativeRefusedByOracle = true;
                Console.WriteLine(FormattableString.Invariant(
                    $"MP-POSNATIVE verdict=refused reason=oracle-mismatch run={_oracleBadRun} last_delta_m={d:F2} native=({ls.X:F2},{ls.Y:F2},{ls.Z:F2}) log=({oracle.X:F2},{oracle.Y:F2},{oracle.Z:F2}) -- the native read is not this player's position; position stays on the log tail"));
                _cadNative.Break();
                return null;
            }
        }
        else _oracleBadRun = 0;
        return ls;
    }

    /// <summary>
    /// WO-102.5 Phase 2: the native NPC scan's own tick, on <see cref="NpcScanInterval"/>
    /// rather than the position tick's cadence -- this is a background
    /// population step, not a per-frame read. Anchors are this player's own
    /// current position plus every peer ghost whose last-known position is
    /// fresher than <see cref="NpcScanGhostStaleAfter"/> (a stale anchor would
    /// scan around a body that has since moved, which is worse than not
    /// scanning around it).
    ///
    /// WO-103 Phase 2: position and yaw now ride along with each name (the
    /// native scan has always read them, per-entity, in npc_scan.cpp -- only
    /// the agent-to-Lua push used to drop them). Health/dead/KO/drawn/engaged
    /// stay read fresh per name in the mod's existing KCD2MP_NpcSyncTick
    /// (unmapped offsets, WO-103.5's job), so the push still stays small
    /// regardless of how many NPCs are in radius: a handful of floats per
    /// name, not a script-table construction.
    /// </summary>
    private async Task NpcScanTickAsync(float px, float py, float pz, CancellationToken ct)
    {
        if (!_npcScanNative || _npcScanGaveUp) return;

        var anchors = new List<(float X, float Y, float Z)> { (px, py, pz) };
        var cutoff = DateTime.UtcNow - NpcScanGhostStaleAfter;
        foreach (var kv in _ghostLastPos)
        {
            if (anchors.Count >= 8) break;
            if (kv.Value.AtUtc >= cutoff) anchors.Add((kv.Value.X, kv.Value.Y, kv.Value.Z));
        }

        var sw = System.Diagnostics.Stopwatch.StartNew();
        NpcScanResult? r = null;
        try { r = await _combat.ScanNpcsAsync(anchors, _npcScanRadiusM, ct); }
        catch (OperationCanceledException) { throw; }
        catch { }
        sw.Stop();

        if (r is not NpcScanResult res)
        {
            if (++_npcScanMisses == PosNpcScanGiveUpAfter)
            {
                _npcScanGaveUp = true;
                var by = _combat.NpcScanRefuseByCode;
                Console.WriteLine(FormattableString.Invariant(
                    $"MP-NPCSCAN verdict=gave-up after={PosNpcScanGiveUpAfter} refused={_combat.NpcScanRefused} module_missing={by[1]} genv_unmapped={by[2]} class_unmapped={by[3]} faulted={by[4]} no_answer={by[7]} -- native NPC scan stays off this session (mp_npc_scan_native_off then _on to retry)"));
            }
            return;
        }
        _npcScanMisses = 0;

        // Same name gate the mod itself applies (kdcmp.lua's "^[%w_]+$"):
        // dropped here too, both so a stray non-conforming read (WO-97's
        // CryString caution -- npc_scan.cpp's own printable-ASCII gate is
        // looser than this) cannot reach the Lua string literal below, and so
        // the pushed list only ever contains names Lua would have kept anyway.
        // Each entry now carries name:x:y:z:yaw:isHorse -- colon-separated,
        // comma-joined; safe with no escaping since the name gate already
        // forbids ':' and ',' and the floats never produce either.
        // WO-110 R3: nearest-first, THEN the cap. Distance is to the nearest
        // anchor (the owner's player and each co-located peer ghost), XY only
        // like the mod's own cull test. Without this the cap truncated in the
        // DLL iterator's order, which has nothing to do with proximity.
        int filtered = 0;
        var ranked = new List<(float D2, NpcScanEntry E)>(res.Entries.Count);
        foreach (var e in res.Entries)
        {
            if (!NpcNamePattern.IsMatch(e.Name)) { filtered++; continue; }
            float best = float.MaxValue;
            foreach (var a in anchors)
            {
                float dx = e.X - a.X, dy = e.Y - a.Y;
                float d2 = dx * dx + dy * dy;
                if (d2 < best) best = d2;
            }
            ranked.Add((best, e));
        }
        ranked.Sort((p, q) => p.D2.CompareTo(q.D2));
        int cap = _npcTrackMax;
        var entries = new List<string>(Math.Min(cap, ranked.Count));
        foreach (var (_, e) in ranked)
        {
            if (entries.Count >= cap) { _npcScanNamesTruncated++; break; }
            entries.Add(FormattableString.Invariant(
                $"{e.Name}:{e.X:F3}:{e.Y:F3}:{e.Z:F3}:{e.Yaw:F4}:{(e.IsHorse ? 1 : 0)}"));
        }
        // Chunk so no single ExecuteString statement outgrows the transport
        // (HttpGameTransport.MaxBatchChars is 4000 and a statement is never
        // split); the mod reassembles by (gen, idx, total) and commits when
        // every chunk of a generation has arrived, in any order.
        var chunks = new List<string>();
        var cur = new StringBuilder();
        foreach (var s in entries)
        {
            if (cur.Length > 0 && cur.Length + 1 + s.Length > NpcScanChunkChars) { chunks.Add(cur.ToString()); cur.Clear(); }
            if (cur.Length > 0) cur.Append(',');
            cur.Append(s);
        }
        if (cur.Length > 0 || chunks.Count == 0) chunks.Add(cur.ToString());
        float farthestM = entries.Count > 0 ? MathF.Sqrt(ranked[entries.Count - 1].D2) : 0f;

        Console.WriteLine(FormattableString.Invariant(
            $"MP-NPCSCAN dir=native anchors={anchors.Count} radius_m={_npcScanRadiusM:F0} total_walked={res.TotalWalked} matched={res.Entries.Count} pushed={entries.Count} cap={cap} farthest_pushed_m={farthestM:F1} chunks={chunks.Count} name_filtered={filtered} name_rejects={res.NameRejects} wire_truncated={(res.Truncated ? 1 : 0)} dur_ms={sw.Elapsed.TotalMilliseconds:F1}"));
        if (res.Truncated) _npcScanTruncatedWire++;

        // WO-103 Phase 1: this used to be silent past the wire_truncated=
        // flag folded into the routine line above. Edge-triggered so a
        // persistently-truncated radius doesn't spam every ~2s scan.
        if (res.Truncated != _npcScanWasReplyTruncated)
        {
            _npcScanWasReplyTruncated = res.Truncated;
            if (res.Truncated)
                Console.WriteLine(FormattableString.Invariant(
                    $"MP-NPCSCAN-TRUNCATED dropped={res.DroppedCount} returned={res.Entries.Count} radius_m={_npcScanRadiusM:F0} -- the native reply hit its byte budget; raise the ceiling is not an option here (WO-103), shrink the radius or accept the drop"));
            else
                Console.WriteLine("MP-NPCSCAN-TRUNCATED cleared -- reply fits the budget again");
        }

        _npcScanPushes++;
        uint gen = unchecked(++_npcScanGen);
        for (int i = 0; i < chunks.Count; i++)
        {
            string payload = EscapeLua(chunks[i]);
            _ = ExecLuaAsync(FormattableString.Invariant(
                $"if KCD2MP_ApplyNativeScan then KCD2MP_ApplyNativeScan(\"{payload}\",{gen},{i + 1},{chunks.Count}) end"));
        }
    }

    /// <summary>
    /// WO-102 Phase 5: an inbound NpcRequest. Refusals are specific: a request
    /// at a machine that is not the owner, or with the model off, or for a
    /// name this authority has not streamed in the last 10 s, is named as
    /// such. An accepted one is logged with dispatch=logged-awaiting-damage and
    /// resolved by the 0x30 that follows (NoteRequestResolvedIn) or reported
    /// unresolved after RequestResolveWindow (SweepRequests) -- a miss, or a
    /// blow the requester's world never landed.
    /// </summary>
    private void OnNpcRequestIn(InboundAction a)
    {
        if (!NpcRequestPayload.TryFromBytes(a.Payload, out var req))
        {
            lock (_requestsIn) _reqInRefused++;
            Console.WriteLine(FormattableString.Invariant(
                $"MP-REQUEST dir=in from={a.SourceGhostId} result=refused reason=malformed-name payload_len={a.Payload.Length}"));
            return;
        }
        string why = !_hostAuthority ? "host-authority-off"
                   : !_isDamageAuthority ? "not-owner"
                   : "";
        if (why.Length == 0)
        {
            lock (_requestsIn)
            {
                if (!_ownedNpcSeenUtc.TryGetValue(req.TargetName, out var seen) || DateTime.UtcNow - seen > OwnedNpcRecent)
                    why = "target-not-owned";
            }
        }
        lock (_requestsIn)
        {
            _reqIn++;
            if (why.Length > 0) _reqInRefused++;
            else _requestsIn[(a.SourceGhostId, req.TargetName)] = DateTime.UtcNow;
        }
        if (why.Length > 0)
            Console.WriteLine(FormattableString.Invariant(
                $"MP-REQUEST dir=in from={a.SourceGhostId} kind=attack {req} result=refused reason={why}"));
        else
            Console.WriteLine(FormattableString.Invariant(
                $"MP-REQUEST dir=in from={a.SourceGhostId} kind=attack {req} seq={a.Seq} gen={a.Gen} dispatch=logged-awaiting-damage resolve=damage-path"));
    }

    private void NoteRequestResolvedIn(byte from, string npc)
    {
        double dtMs;
        lock (_requestsIn)
        {
            if (!_requestsIn.Remove((from, npc), out var at)) return;
            dtMs = (DateTime.UtcNow - at).TotalMilliseconds;
            _reqInResolved++;
        }
        Console.WriteLine(FormattableString.Invariant(
            $"MP-REQUEST dir=in from={from} target={npc} result=resolved via=damage-path dt_ms={dtMs:F0}"));
    }

    private void NoteRequestResolvedOut(string npc)
    {
        double dtMs;
        lock (_requestsIn)
        {
            if (!_requestsOut.Remove(npc, out var at)) return;
            dtMs = (DateTime.UtcNow - at).TotalMilliseconds;
            _reqOutResolved++;
        }
        Console.WriteLine(FormattableString.Invariant(
            $"MP-REQUEST dir=out target={npc} result=resolved via=damage-sent dt_ms={dtMs:F0}"));
    }

    private void SweepRequests()
    {
        var now = DateTime.UtcNow;
        var lines = new List<string>();
        lock (_requestsIn)
        {
            foreach (var kv in _requestsIn.Where(kv => now - kv.Value > RequestResolveWindow).ToList())
            {
                _requestsIn.Remove(kv.Key); _reqInUnresolved++;
                lines.Add(FormattableString.Invariant($"MP-REQUEST dir=in from={kv.Key.From} target={kv.Key.Npc} result=unresolved after_ms={RequestResolveWindow.TotalMilliseconds:F0}"));
            }
            foreach (var kv in _requestsOut.Where(kv => now - kv.Value > RequestResolveWindow).ToList())
            {
                _requestsOut.Remove(kv.Key); _reqOutUnresolved++;
                lines.Add(FormattableString.Invariant($"MP-REQUEST dir=out target={kv.Key} result=unresolved after_ms={RequestResolveWindow.TotalMilliseconds:F0} (no blow landed here)"));
            }
        }
        foreach (var l in lines) Console.WriteLine(l);
    }

    /// <summary>
    /// WO-102 Phase 6: ask for (or perform) an NPC state resync. Under the
    /// claim model there is no single owner to resync from, so it is skipped
    /// and said so. The owner runs the mod's burst; a non-owner sends an
    /// NpcResync action to the owner.
    /// </summary>
    private async Task RequestNpcResyncAsync(byte reason, NetworkStream? stream, CancellationToken ct)
    {
        string why = NpcResyncReason.Name(reason);
        if (!_hostAuthority)
        {
            _resyncSkipped++;
            Console.WriteLine($"MP-NPCRESYNC dir=skip reason={why} cause=host-authority-off");
            return;
        }
        if (_isDamageAuthority)
        {
            await BurstNpcResyncAsync(reason, "self", ct);
            return;
        }
        if (stream is null) { _resyncSkipped++; Console.WriteLine($"MP-NPCRESYNC dir=skip reason={why} cause=not-connected"); return; }
        var pkt = _actionOut.Build(ActionKind.NpcResync, ActionPhase.Commit, new[] { reason });
        await WritePacketAsync(stream, pkt, ct);
        _resyncOut++;
        Console.WriteLine($"MP-NPCRESYNC dir=out reason={why} gen={_actionOut.Gen}");
    }

    /// <summary>The owner's burst: the mod scans around every player and emits one flagged sample per NPC.</summary>
    private async Task BurstNpcResyncAsync(byte reason, string from, CancellationToken ct)
    {
        string why = NpcResyncReason.Name(reason);
        var now = DateTime.UtcNow;
        if (now - _lastResyncBurstUtc < ResyncBurstMinGap)
        {
            Console.WriteLine($"MP-NPCRESYNC dir=burst reason={why} from={from} result=collapsed (within {ResyncBurstMinGap.TotalSeconds:F0} s of the last burst)");
            return;
        }
        _lastResyncBurstUtc = now;
        _resyncBursts++;
        Console.WriteLine($"MP-NPCRESYNC dir=burst reason={why} from={from}");
        try { await ExecLuaAsync($"if KCD2MP_NpcResyncBurst then KCD2MP_NpcResyncBurst(\"{why}\") end"); }
        catch (Exception ex) { Console.WriteLine($"MP-NPCRESYNC dir=burst reason={why} result=failed err=\"{ex.Message}\""); }
    }

    /// <summary>WO-102 Phase 1: the 30 s cadence window for both paths, plus the oracle window.</summary>
    private void ReportCadence()
    {
        double now = NowMs();
        if (_cadLog.Report("log", now) is string l) Console.WriteLine(l);
        if (_cadNative.Report("native", now) is string n) Console.WriteLine(n);
        if (_oracleN > 0)
        {
            Console.WriteLine(FormattableString.Invariant(
                $"MP-POSNATIVE oracle n={_oracleN} delta_mean_m={_oracleSum / _oracleN:F2} delta_max_m={_oracleMax:F2} bad_run={_oracleBadRun} active={(_posNative && !_posNativeGaveUp && !_posNativeRefusedByOracle ? 1 : 0)}"));
            _oracleN = 0; _oracleSum = 0; _oracleMax = 0;
        }
    }

    /// <summary>
    /// WO-100.5 Phase 2: the local player's Mannequin body state, or null.
    /// Null is an ordinary outcome, not an error: no DLL, an older DLL, or a
    /// refusal gate. The packet then goes out in its pre-WO-100.5 shape.
    /// </summary>
    private async Task<LocalBodyState?> ReadLocalBodyStateAsync(CancellationToken ct)
    {
        if (_bodyStateOff) return null;
        LocalBodyState? b = null;
        try { b = await _combat.ReadBodyStateAsync(0, ct); }
        catch (OperationCanceledException) { throw; }
        catch { /* the pipe reports its own faults; treat as a miss */ }

        if (b is not null) { _bodyStateMisses = 0; return b; }
        if (++_bodyStateMisses == BodyStateGiveUpAfter)
        {
            _bodyStateOff = true;
            Console.WriteLine(
                $"[anim] body state unavailable after {BodyStateGiveUpAfter} consecutive refusals -- " +
                "not asking again this session. Peers will see this player's ghost on the legacy " +
                "animation path. Usual cause: KCDMP.dll is older than this agent and has no 0x09 command.");
        }
        return null;
    }

    /// <summary>
    /// WO-100.5 Phase 3: publish an attack edge if this sample produced one.
    ///
    /// Sent whether or not the RECEIVING side can act on it. Phase 1's block
    /// write was refused by the engine, so today a peer logs this and drops it
    /// -- and that is the point: it proves the wire half on its own, so that
    /// when the native write lands the only new thing is the dispatch.
    /// </summary>
    private async Task SendAttackEdgeAsync(NetworkStream stream, LocalBodyState lb, CancellationToken ct)
    {
        var edge = _attackEdge.Feed(lb.HaveCombat, lb.InputClass, lb.Zone, lb.AttackType, lb.Prepared);
        if (edge is not (ActionPhase phase, AttackPayload payload)) return;
        var packet = _actionOut.Build(ActionKind.Attack, phase, payload.ToBytes());
        await WritePacketAsync(stream, packet, ct);
        Console.WriteLine(FormattableString.Invariant(
            $"MP-ACTION section=outbound kind=attack phase={phase} gen={_actionOut.Gen} {payload}"));

        // WO-102 Phase 5: under host authority a non-owner's committed attack
        // at an owned NPC is a REQUEST to the owner. Same accepted input, plus
        // the target's name. The owner resolves it through the existing
        // damage path (our 0x30 follows when the blow lands here); this packet
        // is the intent, sent first, so both sides can measure the gap.
        if (phase == ActionPhase.Commit && _hostAuthority && !_isDamageAuthority && _npcTarget is string target)
        {
            var req = new NpcRequestPayload(payload, target);
            var rpkt = _actionOut.Build(ActionKind.NpcRequest, ActionPhase.Commit, req.ToBytes());
            await WritePacketAsync(stream, rpkt, ct);
            lock (_requestsIn) { _requestsOut[target] = DateTime.UtcNow; _reqOut++; }
            Console.WriteLine(FormattableString.Invariant(
                $"MP-REQUEST dir=out kind=attack target={target} {payload} gen={_actionOut.Gen} resolve=damage-path"));
        }
    }

    private async Task WritePacketAsync(NetworkStream stream, byte[] packet, CancellationToken ct = default)
    {
        await _tcpWriteLock.WaitAsync(ct);
        try { await stream.WriteAsync(packet, ct); }
        finally { _tcpWriteLock.Release(); }
    }

    private static bool IntervalElapsed(ref long lastTimestamp, TimeSpan interval, long nowTimestamp)
    {
        if (Stopwatch.GetElapsedTime(lastTimestamp, nowTimestamp) < interval) return false;
        lastTimestamp = nowTimestamp;
        return true;
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
