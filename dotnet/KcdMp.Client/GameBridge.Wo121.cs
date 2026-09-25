using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net.Sockets;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>
/// WO-121 -- movement and combat, the agent half (protocol v8, ProtocolV8.cs).
///
/// Sender: the v8 state block rides the Position packet, change-gated; the
/// DLL's committed-action frames (0x96) become ActionUp events stamped with the
/// Position clock; a local hit on a peer's avatar (0x97) becomes a PlayerHit
/// when friendly fire is on.
///
/// Receiver: the state block goes to the DLL with the ghost's sample (the
/// native gait/crouch/combat applier, NativeNpc.cs FlagState2); events are
/// judged against the sender's newest Position stamp and dispatched -- an
/// attack or block/dodge row plays the row's own fragment on the avatar
/// through the WO-46 cosmetic route; a jump is a native RequestJump; a
/// PlayerHit lands on our own Henry with no attacker attached.
///
/// Policy stays thin on purpose (the maintainer's native-first rule): this file
/// routes and counts; the engine calls are in KCDMP.dll (motion.cpp, hits.cpp).
/// </summary>
public partial class GameBridge
{
    // ---- mirrors of the mod's WO-121 toggles (Lua emits wo121_cfg) --------
    private volatile bool _avatarGait = true, _npcGait = true, _avatarMoves = true, _avatarCombat = true, _npcRows = true;
    private volatile bool _npcAttribution = true;

    /// <summary>
    /// The build's friendly-fire default. WO-121: ON only if the Phase 6 gate
    /// passes; see docs/WO-121-findings.md. The host's mp_friendly_fire
    /// overrides it for the whole session.
    /// </summary>
    internal const bool FriendlyFireDefault = true;

    /// <summary>This machine's own mp_friendly_fire (it only counts on the host).</summary>
    private volatile bool _ffLocalPref = FriendlyFireDefault;
    /// <summary>The session's value: the host's lever (the host's own pref, or the last SessionSetting a joiner got).</summary>
    private volatile bool _ffSession = FriendlyFireDefault;
    private volatile bool _ffFromHost;

    private NetworkStream? _wo121Stream;
    private CancellationToken _wo121Ct;
    private readonly ConcurrentDictionary<byte, uint> _ghostLastSenderMs = new();
    private readonly ConcurrentDictionary<byte, DateTime> _peerV8AttackAt = new();
    private readonly ConcurrentDictionary<byte, DateTime> _peerState2At = new();
    private readonly ConcurrentDictionary<byte, BodyState2> _peerLastState2 = new();
    private readonly ConcurrentDictionary<string, DateTime> _npcRowAt = new();

    // WO-121: authored combat rows by GUID, read from this install's Tables.pak.
    private readonly Task<ActionRowCatalog?> _rowCatalog = Task.Run(() => ActionRowCatalog.TryLoad(Console.WriteLine));

    // The v8 state-block change gate (sender).
    private BodyState2? _st2LastSent;
    private long _st2LastSentTs;

    // Whether the local DLL captures committed attacks (Wo121Status) -- when it
    // does, the Lua "combat swing" cue (0x2C) is not sent: the v8 Attack event
    // is the swing, and sending both would play two.
    private volatile bool _dllAttackCapture;
    private string _dllWo121Status = "";

    private long _w121EvOut, _w121EvIn, _w121EvStale, _w121EvNoRow, _w121EvNoBody, _w121Swings, _w121Jumps;
    private long _w121FfOut, _w121FfOutDropped, _w121FfIn, _w121FfInDropped, _w121AttribIn, _w121AttribOut, _w121NpcRowsOut, _w121NpcRowsIn;

    private void Wo121OnConnect(NetworkStream stream, CancellationToken ct)
    {
        _wo121Stream = stream;
        _wo121Ct = ct;
        _st2LastSent = null;
        _combat.OnLocalAction = OnLocalActionAsync;
        _combat.OnPvpHit = OnPvpHitAsync;
        _ = PushWo121ConfigAsync(ct);
        _ = Wo121HeartbeatAsync(ct);
    }

    private void Wo121OnDisconnect()
    {
        _wo121Stream = null;
        _combat.OnLocalAction = null;
        _combat.OnPvpHit = null;
        _ffFromHost = false;
        _ffSession = _isDamageAuthority ? _ffLocalPref : FriendlyFireDefault;
    }

    private async Task PushWo121ConfigAsync(CancellationToken ct)
    {
        try
        {
            var m = await _combat.MotionConfigAsync(_avatarGait, _npcGait, _avatarMoves, _avatarCombat, _npcRows, ct);
            var h = await _combat.HitsConfigAsync(_ffSession, _npcAttribution, true, ct);
            Console.WriteLine(FormattableString.Invariant(
                $"MP-WO121 cfg avatar_gait={On(_avatarGait)} npc_gait={On(_npcGait)} avatar_moves={On(_avatarMoves)} avatar_combat={On(_avatarCombat)} npc_rows={On(_npcRows)} attribution={On(_npcAttribution)} friendly_fire={On(_ffSession)} ff_from={(_ffFromHost ? "host" : _isDamageAuthority ? "self-host" : "default")} dll_motion={m.ReasonTag} dll_hits={h.ReasonTag}"));
        }
        catch (Exception ex) { Console.WriteLine($"MP-WO121 cfg push failed: {ex.Message}"); }
    }

    private static string On(bool b) => b ? "on" : "off";

    /// <summary>The mod's toggles, one event: <c>wo121_cfg avatar_gait=on npc_gait=on ... ff=on</c>.</summary>
    private void Wo121OnCfgEvent(string? arg)
    {
        if (string.IsNullOrWhiteSpace(arg)) return;
        bool ffChanged = false;
        foreach (var kv in arg.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            int eq = kv.IndexOf('=');
            if (eq <= 0) continue;
            string k = kv[..eq]; bool v = kv[(eq + 1)..] == "on";
            switch (k)
            {
                case "avatar_gait": _avatarGait = v; break;
                case "npc_gait": _npcGait = v; break;
                case "avatar_moves": _avatarMoves = v; break;
                case "avatar_combat": _avatarCombat = v; break;
                case "npc_rows": _npcRows = v; break;
                case "attribution": _npcAttribution = v; break;
                case "ff": ffChanged = _ffLocalPref != v; _ffLocalPref = v; break;
            }
        }
        if (_isDamageAuthority)
        {
            _ffSession = _ffLocalPref;
            if (ffChanged) _ = SendSessionSettingAsync("toggle");
        }
        else if (ffChanged)
        {
            Console.WriteLine(FormattableString.Invariant(
                $"MP-FF local mp_friendly_fire={On(_ffLocalPref)} ignored -- the host's lever decides (session={On(_ffSession)})"));
            _ = ExecLuaAsync($"if KCD2MP_FriendlyFireSession then KCD2MP_FriendlyFireSession({(_ffSession ? "true" : "false")}, \"host-controlled\") end");
        }
        _ = PushWo121ConfigAsync(_wo121Ct);
    }

    /// <summary>The host tells every peer the session's friendly-fire value (on change, on a new peer, every 30 s).</summary>
    private async Task SendSessionSettingAsync(string why)
    {
        if (!_isDamageAuthority || _wo121Stream is not NetworkStream s) return;
        try
        {
            var pkt = _actionOut.Build(ActionKind.SessionSetting, ActionPhase.Commit,
                                       [SessionSettingKey.FriendlyFire, _ffSession ? (byte)1 : (byte)0]);
            await WritePacketAsync(s, pkt, _wo121Ct);
            Console.WriteLine($"MP-FF host sent friendly_fire={On(_ffSession)} why={why}");
        }
        catch (Exception ex) { Console.WriteLine($"MP-FF host send failed: {ex.Message}"); }
    }

    private async Task Wo121HeartbeatAsync(CancellationToken ct)
    {
        var lastSetting = DateTime.MinValue;
        var lastStats = DateTime.UtcNow;
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(1000, ct); } catch { return; }
            try
            {
                string? st = await _combat.Wo121StatusAsync(ct);
                if (st is not null)
                {
                    _dllWo121Status = st;
                    bool cap = st.Contains("attack_capture=armed", StringComparison.Ordinal);
                    if (cap != _dllAttackCapture)
                        Console.WriteLine($"MP-WO121 dll attack_capture={(cap ? "armed" : "off")} -- the Lua swing cue (0x2C) is {(cap ? "suppressed" : "sent")}");
                    _dllAttackCapture = cap;
                    bool gait = st.Contains("gait=armed", StringComparison.Ordinal);
                    bool combat = st.Contains("combat=armed", StringComparison.Ordinal);
                    await ExecLuaAsync(FormattableString.Invariant(
                        $"if KCD2MP_Wo121Alive then KCD2MP_Wo121Alive({(gait ? "true" : "false")},{(combat ? "true" : "false")},{(_ffSession ? "true" : "false")}) end"));
                }
                if (_isDamageAuthority && (DateTime.UtcNow - lastSetting).TotalSeconds >= 30)
                {
                    lastSetting = DateTime.UtcNow;
                    _ffSession = _ffLocalPref;
                    await SendSessionSettingAsync("heartbeat");
                }
                if ((DateTime.UtcNow - lastStats).TotalSeconds >= 60)
                {
                    lastStats = DateTime.UtcNow;
                    Console.WriteLine(Wo121StatsLine());
                }
            }
            catch (OperationCanceledException) { return; }
            catch { }
        }
    }

    private string Wo121StatsLine() => string.Create(CultureInfo.InvariantCulture,
        $"MP-WO121-STATS ev_out={_w121EvOut} ev_in={_w121EvIn} ev_stale={_w121EvStale} ev_norow={_w121EvNoRow} ev_nobody={_w121EvNoBody} swings={_w121Swings} jumps={_w121Jumps} " +
        $"npc_rows_out={_w121NpcRowsOut} npc_rows_in={_w121NpcRowsIn} ff_out={_w121FfOut} ff_out_dropped={_w121FfOutDropped} ff_in={_w121FfIn} ff_in_dropped={_w121FfInDropped} " +
        $"attrib_out={_w121AttribOut} attrib_in={_w121AttribIn} ff_session={On(_ffSession)} dll=\"{_dllWo121Status}\"");

    // =====================================================================
    // Sender
    // =====================================================================

    /// <summary>
    /// The state block to put on this Position packet, or null. Change-gated:
    /// a field change (speed by 10 cm/s or more, direction by 3 units, any
    /// bit/zone), or the 1 s heartbeat while anything is non-zero.
    /// <paramref name="due"/> is true when a packet should go out for the
    /// state alone (the body stood still but, say, raised a block).
    /// </summary>
    private BodyState2? Wo121State2For(LocalState? nat, long nowTs, bool consume, out bool due)
    {
        due = false;
        if (nat?.State2 is not BodyState2 c) return null;
        bool changed = _st2LastSent is not BodyState2 l
            || Math.Abs(l.SpeedCm - c.SpeedCm) >= 10 || Math.Abs(l.MoveDir - c.MoveDir) >= 3
            || l.Bits != c.Bits || l.GuardZone != c.GuardZone || l.GuardStance != c.GuardStance || l.AtkZone != c.AtkZone
            || (c.SpeedCm == 0 && l.SpeedCm != 0);
        bool nonZero = c.SpeedCm != 0 || c.Bits != BodyState2Bits.None;
        bool hb = nonZero && Stopwatch.GetElapsedTime(_st2LastSentTs, nowTs).TotalMilliseconds >= Protocol.BodyState2HeartbeatMs;
        due = changed || hb;
        if (!due) return null;
        if (consume) { _st2LastSent = c; _st2LastSentTs = nowTs; }
        return c;
    }

    /// <summary>The DLL committed an action on this machine (0x96).</summary>
    private async Task OnLocalActionAsync(LocalActionFrame f)
    {
        if (_wo121Stream is not NetworkStream s) return;
        uint ms = SenderMsNow();
        byte[]? pkt = null;
        string what;
        if (f.Eid == 0)
        {
            switch ((ActionKind)f.Kind)
            {
                case ActionKind.Attack:
                    var ae = new AttackEvent(ms, f.InputClass, Protocol.ZoneFromTableId(f.ZoneTableId), f.AttackType, f.Flags, f.Row);
                    pkt = _actionOut.Build(ActionKind.Attack, ActionPhase.Commit, ae.ToBytes());
                    what = ae.ToString();
                    break;
                case ActionKind.Jump:
                    var jb = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(jb, ms);
                    pkt = _actionOut.Build(ActionKind.Jump, ActionPhase.Commit, jb);
                    what = "jump";
                    break;
                case ActionKind.BlockImpulse:
                case ActionKind.Dodge:
                    pkt = _actionOut.Build((ActionKind)f.Kind, ActionPhase.Commit, new RowEvent(ms, f.Flags, f.Row, "").ToBytes());
                    what = $"row={f.Row} flags={f.Flags}";
                    break;
                default: return;
            }
        }
        else
        {
            // An NPC's committed attack: the owner streams it so the NPC copies
            // swing that exact row. Only the owner (the host under host
            // authority) speaks for its NPCs; a name must be authored.
            if ((ActionKind)f.Kind != ActionKind.Attack || !_npcRows || !_isDamageAuthority) return;
            if (!NpcNamePattern.IsMatch(f.Name) || Protocol.IsNeverSyncedNpcName(f.Name)) return;
            pkt = _actionOut.Build(ActionKind.NpcAttack, ActionPhase.Commit, new RowEvent(ms, 0, f.Row, f.Name).ToBytes());
            what = $"npc={f.Name} row={f.Row}";
            _w121NpcRowsOut++;
        }
        await WritePacketAsync(s, pkt, _wo121Ct);
        _w121EvOut++;
        Console.WriteLine(FormattableString.Invariant($"MP-ACTION section=outbound kind={(ActionKind)(f.Eid == 0 ? f.Kind : (byte)ActionKind.NpcAttack)} gen={_actionOut.Gen} {what}"));
    }

    /// <summary>The local player hit a peer's avatar (0x97). The avatar kept nothing; the damage goes to its owner.</summary>
    private async Task OnPvpHitAsync(uint victimEid, float stamina, float health, byte flags, byte material)
    {
        byte? victim = null;
        foreach (var kv in _ghostEntityIds)
            if (kv.Value == victimEid && byte.TryParse(kv.Key, out byte gid)) { victim = gid; break; }
        string line = FormattableString.Invariant(
            $"MP-FF dir=out victim_eid=0x{victimEid:X} ghost={(victim is byte v0 ? v0.ToString() : "?")} hp={health:F2} st={stamina:F2} unarmed={((flags & PlayerHitV8.FlagUnarmed) != 0 ? 1 : 0)} missile={((flags & PlayerHitV8.FlagMissile) != 0 ? 1 : 0)} session={On(_ffSession)}");
        if (!_ffSession || victim is not byte vid || _wo121Stream is not NetworkStream s || (health <= 0 && stamina <= 0))
        {
            _w121FfOutDropped++;
            Console.WriteLine(line + $" result=dropped reason={(!_ffSession ? "friendly-fire-off" : victim is null ? "unknown-avatar" : _wo121Stream is null ? "no-relay" : "no-damage")}");
            return;
        }
        await WritePacketAsync(s, new PlayerHitV8(vid, stamina, health, flags, material).BuildUp(), _wo121Ct);
        _w121FfOut++;
        Console.WriteLine(line + " result=sent");
    }

    // =====================================================================
    // Receiver
    // =====================================================================

    /// <summary>
    /// Dispatches one inbound WO-121 action. True when this file owned the kind
    /// (whatever it then did); false leaves it to the older handlers.
    /// </summary>
    private async Task<bool> DispatchWo121ActionAsync(InboundAction a, CancellationToken ct)
    {
        switch (a.Kind)
        {
            case ActionKind.SessionSetting:
                if (a.Payload.Length >= 2 && a.Payload[0] == SessionSettingKey.FriendlyFire)
                {
                    bool v = a.Payload[1] != 0;
                    bool changed = !_ffFromHost || _ffSession != v;
                    _ffSession = v; _ffFromHost = true;
                    if (changed)
                    {
                        Console.WriteLine($"MP-FF session friendly_fire={On(v)} from=host ghost={a.SourceGhostId}");
                        await ExecLuaAsync($"if KCD2MP_FriendlyFireSession then KCD2MP_FriendlyFireSession({(v ? "true" : "false")}, \"host\") end");
                        _ = PushWo121ConfigAsync(ct);
                    }
                }
                return true;
            case ActionKind.Attack:
            case ActionKind.Jump:
            case ActionKind.BlockImpulse:
            case ActionKind.Dodge:
            case ActionKind.NpcAttack:
                break;
            default:
                return false;
        }
        _w121EvIn++;
        uint evMs = a.Payload.Length >= 4 ? BinaryPrimitives.ReadUInt32LittleEndian(a.Payload) : 0;
        if (evMs != 0 && _ghostLastSenderMs.TryGetValue(a.SourceGhostId, out uint posMs)
            && unchecked((int)(posMs - evMs)) > Protocol.EventStaleMs)
        {
            _w121EvStale++;
            Console.WriteLine(FormattableString.Invariant(
                $"MP-ACTION section=inbound ghost={a.SourceGhostId} kind={a.Kind} seq={a.Seq} dispatch=dropped-stale behind_ms={unchecked((int)(posMs - evMs))}"));
            return true;
        }
        var catalog = await _rowCatalog;
        switch (a.Kind)
        {
            case ActionKind.Attack:
            {
                if (!AttackEvent.TryFromBytes(a.Payload, out var ae)) { Console.WriteLine($"MP-ACTION section=inbound ghost={a.SourceGhostId} kind=Attack dispatch=dropped-malformed len={a.Payload.Length}"); return true; }
                _peerV8AttackAt[a.SourceGhostId] = DateTime.UtcNow;
                await PlayAvatarRowAsync(a, ae.Row, catalog, ae.ToString(), ct);
                return true;
            }
            case ActionKind.BlockImpulse:
            case ActionKind.Dodge:
            {
                if (!RowEvent.TryFromBytes(a.Payload, out var re)) return true;
                await PlayAvatarRowAsync(a, re.Row, catalog, $"row={re.Row} flags={re.Flags}", ct);
                return true;
            }
            case ActionKind.Jump:
            {
                if (!_avatarMoves) { Console.WriteLine($"MP-ACTION section=inbound ghost={a.SourceGhostId} kind=Jump dispatch=dropped-toggle-off"); return true; }
                if (!_ghostEntityIds.TryGetValue(a.SourceGhostId.ToString(), out uint jeid))
                {
                    _w121EvNoBody++;
                    Console.WriteLine($"MP-ACTION section=inbound ghost={a.SourceGhostId} kind=Jump dispatch=dropped-no-entity");
                    return true;
                }
                var r = await _combat.AvatarEventAsync(1, jeid, ct);
                _w121Jumps++;
                Console.WriteLine($"MP-ACTION section=inbound ghost={a.SourceGhostId} kind=Jump seq={a.Seq} dispatch=native-jump result={r.ReasonTag}");
                return true;
            }
            case ActionKind.NpcAttack:
            {
                if (!RowEvent.TryFromBytes(a.Payload, out var ne) || ne.Name.Length == 0) return true;
                _w121NpcRowsIn++;
                _npcRowAt[ne.Name] = DateTime.UtcNow;
                if (!_npcRows) return true;
                if (catalog is null || !catalog.TryGet(ne.Row, out var row)) { _w121EvNoRow++; Console.WriteLine($"MP-ACTION section=inbound kind=NpcAttack npc={ne.Name} row={ne.Row} dispatch=dropped-unknown-row"); return true; }
                if (!_npcEntityIds.TryGetValue(ne.Name, out uint neid))
                {
                    _w121EvNoBody++;
                    Console.WriteLine($"MP-ACTION section=inbound kind=NpcAttack npc={ne.Name} dispatch=dropped-no-entity (not a puppet here)");
                    return true;
                }
                _ = _combat.NpcHoldAsync(ne.Name, 900, ct);
                var r = await _combat.GhostSwingForResultAsync(neid, row.Spec, ct);
                Console.WriteLine($"MP-ACTION section=inbound kind=NpcAttack npc={ne.Name} row={ne.Row} spec=\"{row.Spec}\" dispatch=native-row result={r.ReasonTag}");
                if (r.Ok) await ExecLuaAsync($"if KCD2MP_NpcNativeSwingHold then KCD2MP_NpcNativeSwingHold(\"{ne.Name}\") end");
                return true;
            }
        }
        return true;
    }

    /// <summary>The avatar plays the sender's committed row (attack / block / perfect block / dodge).</summary>
    private async Task PlayAvatarRowAsync(InboundAction a, Guid rowGuid, ActionRowCatalog? catalog, string detail, CancellationToken ct)
    {
        if (!_avatarCombat)
        {
            Console.WriteLine($"MP-ACTION section=inbound ghost={a.SourceGhostId} kind={a.Kind} {detail} dispatch=dropped-toggle-off");
            return;
        }
        if (catalog is null || !catalog.TryGet(rowGuid, out var row))
        {
            _w121EvNoRow++;
            Console.WriteLine($"MP-ACTION section=inbound ghost={a.SourceGhostId} kind={a.Kind} {detail} dispatch=dropped-unknown-row");
            return;
        }
        string gid = a.SourceGhostId.ToString();
        if (!_ghostEntityIds.TryGetValue(gid, out _))
        {
            _w121EvNoBody++;
            Console.WriteLine($"MP-ACTION section=inbound ghost={gid} kind={a.Kind} {detail} dispatch=dropped-no-entity (no entity id for the avatar yet)");
            return;
        }
        long rsid = ++_stats.SwingsRecv;
        _w121Swings++;
        Console.WriteLine($"MP-SWING hop=recv rsid={rsid} ghost={gid} kind={a.Kind} seq={a.Seq} table={row.Table} spec=\"{row.Spec}\" {detail}");
        _ = _combat.NpcHoldAsync("kcd2mp_" + gid, 900, ct);
        EnsureSwingInbox(ct).TryEnqueue(new SwingInbox.Entry(gid, a.Seq, rsid, GhostGeneration(gid), row.Spec, DateTime.UtcNow));
        await ExecLuaAsync($"if KCD2MP_GhostNativeSwingHold then KCD2MP_GhostNativeSwingHold(\"{gid}\") end");
    }

    /// <summary>
    /// WO-121: should an old 0x2C combat cue from this peer be skipped? A peer
    /// that sends v8 attack rows (seen in the last minute) swings through
    /// those; a peer whose state block says it is blocking has its block held
    /// natively.
    /// </summary>
    private bool Wo121SupersedesCombatCue(byte ghost, byte evt)
    {
        if (!_avatarCombat) return false;
        if (evt == Protocol.CombatEventSwing)
            return _peerV8AttackAt.TryGetValue(ghost, out var t) && (DateTime.UtcNow - t).TotalSeconds < 60;
        if (evt == Protocol.CombatEventBlock)
            return _peerState2At.TryGetValue(ghost, out var t2) && (DateTime.UtcNow - t2).TotalSeconds < 5;
        return false;
    }

    /// <summary>WO-121: the owner's NPC swings arrive as rows; the WO-49 heuristic cue flag is then ignored for that NPC.</summary>
    private bool Wo121SupersedesNpcCue(string npc) =>
        _npcRows && _npcRowAt.TryGetValue(npc, out var t) && (DateTime.UtcNow - t).TotalSeconds < 60;

    /// <summary>0x45: a partner's friendly-fire hit on our Henry.</summary>
    private async Task OnPlayerHitV8InAsync(byte[] payload, CancellationToken ct)
    {
        if (!PlayerHitV8.TryDecodeDown(payload, out byte attacker, out var hit))
        {
            _w121FfInDropped++;
            Console.WriteLine($"MP-FF dir=in result=dropped reason=malformed len={payload.Length}");
            return;
        }
        string line = FormattableString.Invariant($"MP-FF dir=in attacker={attacker} {hit} session={On(_ffSession)}");
        if (!_ffSession || hit.Victim != _myGhostId)
        {
            _w121FfInDropped++;
            Console.WriteLine(line + $" result=dropped reason={(!_ffSession ? "friendly-fire-off" : "not-me")}");
            return;
        }
        var r = await _combat.ApplyPvpHitAsync(hit.Stamina, hit.Health, hit.Flags, attacker, ct);
        _w121FfIn++;
        Console.WriteLine(line + $" result={(r.Ok ? "applied" : "failed")} reason={r.ReasonTag}");
    }

    /// <summary>
    /// WO-121 Phase 5: an ATTRIBUTED hit from peer <paramref name="source"/> on
    /// a local NPC, on the NPC's authority. Returns null when attribution does
    /// not apply here (the caller applies the plain damage as before).
    /// </summary>
    private async Task<bool?> TryApplyAttributedAsync(byte source, string npcName, Guid localGuid, float stamina, float health,
                                                      byte flags, CancellationToken ct)
    {
        if (!_npcAttribution || !_isDamageAuthority || (flags & Protocol.NpcDamageFlagAttributed) == 0) return null;
        if (!_ghostEntityIds.TryGetValue(source.ToString(), out uint avatarEid)) return null;
        var r = await _combat.AttributedDamageAsync(localGuid, stamina, health, flags, avatarEid, npcName, ct);
        _w121AttribIn++;
        string steps = $"damage={((r.Steps & 1) != 0 ? 1 : 0)} history={((r.Steps & 2) != 0 ? 1 : 0)} skirmish={((r.Steps & 4) != 0 ? 1 : 0)}";
        bool brain = false;
        if (r.Ok && r.AttackerWuid != 0)
        {
            // The brain's hit-reaction message, in the engine's own format
            // (WHGame CGameRules::SendAISignal: "attacker(%lld),hitStrength(%d),
            // hitType(%d),targetOrigMat(%d)") and the engine's own debug-command
            // shape. hitStrength/hitType/targetOrigMat: PROVISIONAL until one
            // vanilla sword hit is captured (needs the maintainer).
            string dec = unchecked((long)r.AttackerWuid).ToString(CultureInfo.InvariantCulture);
            await ExecLuaAsync($"pcall(function() XGenAIModule.SendMessageToEntity(System.GetEntityByName(\"{npcName}\").this.id,\"hitReaction\",\"attacker({dec}),hitStrength({Wo121HitStrength}),hitType({Wo121HitType}),targetOrigMat({Wo121TargetMat})\") end)");
            brain = true;
        }
        Console.WriteLine(FormattableString.Invariant(
            $"MP-ATTRIB npc={npcName} attacker_ghost={source} attacker_eid=0x{avatarEid:X} hp={health:F1} st={stamina:F1} result={(r.Ok ? "applied" : "failed")} {steps} brain_msg={(brain ? 1 : 0)} reason={r.Reason}"));
        return r.Ok && (r.Steps & 1) != 0;
    }

    // Provisional hitReaction values (WO-119 s2.1 saw only the brain-driven hitType 10).
    private const int Wo121HitStrength = 5, Wo121HitType = 1, Wo121TargetMat = 1;
}
