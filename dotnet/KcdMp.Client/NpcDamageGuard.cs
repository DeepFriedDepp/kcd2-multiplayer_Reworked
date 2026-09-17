namespace KcdMp.Client;

/// <summary>
/// WO-99 Phase 0: the two guards the name-addressed NPC damage path (0x30/0x31)
/// was missing, as pure decisions so they can be proven without a game.
///
/// <para><b>Local-player exclusion.</b> The engine names every player entity
/// and its soul <c>Dude</c>, on every machine. KCDMP.dll's outbound sampler is
/// meant to skip the player soul (<c>soul != g_player</c>) but <c>g_player</c>
/// is captured once at the RTTR walk and goes stale on a save load, so on
/// 2026-09-16 both DLLs reported their own player's health drops as hits on
/// an NPC called <c>Dude</c>. The receiver resolved that name to ITS player's
/// soul and applied the peer's wound to the local player: the joiner took the
/// host's 88.9 hp blow (100→11.1), echoed it back 12 s later, and the host
/// died of it (11.1→0.0). Nothing about a player's own health belongs on this
/// path -- player vitals have their own channel (0x1F–0x25) -- so the local
/// player's soul is excluded structurally, by its per-save <c>Soul.Guid</c>
/// read from <c>SoulList/PlayerSoul</c>, on send AND receive. The soul NAME is
/// kept as a second, weaker key for the window between a save load and the
/// next identity refresh, and is logged as a fallback when it is what fired.</para>
///
/// <para><b>Echo memory.</b> The DLL cancels applied damage against the next
/// observed drop ("credit"), but its tracked set is rebuilt every 3 s and the
/// rebuild zeroes the credit. Any soul whose readable health lags the apply
/// by more than that -- the player soul did, by 12 s -- re-emits the peer's
/// own hit back to it. A receiver must never re-send a value it just applied:
/// an outbound hit whose (name, hp, st) matches an inbound hit applied within
/// <see cref="EchoWindow"/> is dropped here, and a FATAL for a name whose
/// death was applied from a peer within the same window is dropped too (the
/// 19:16:36 joiner line <c>out … hp=2.0 fatal=1</c> was exactly that echo).</para>
///
/// Thread safety: called from the pipe reader and the receive loop; every
/// mutation is under one lock.
/// </summary>
public sealed class NpcDamageGuard
{
    /// <summary>How long an applied inbound value is remembered for echo matching.</summary>
    public static readonly TimeSpan EchoWindow = TimeSpan.FromSeconds(300);
    /// <summary>Two damage values are "the same hit" within this (the wire carries F1 precision).</summary>
    public const float EchoTolerance = 0.06f;

    public enum Outbound { Send, DropLocalPlayerGuid, DropLocalPlayerName, DropEcho, DropEchoFatal }
    public enum Inbound  { Apply, RefuseLocalPlayerGuid, RefuseLocalPlayerName }

    private readonly object _lock = new();
    private Guid?   _playerGuid;
    private string? _playerName;
    private readonly Dictionary<string, List<(float Hp, float St, DateTime At)>> _appliedIn = new(StringComparer.Ordinal);
    private readonly Dictionary<string, DateTime> _appliedFatalIn = new(StringComparer.Ordinal);

    public Guid?   PlayerGuid { get { lock (_lock) return _playerGuid; } }
    public string? PlayerName { get { lock (_lock) return _playerName; } }

    /// <summary>Set (or refresh) the local player's soul identity. Either half may be unknown.</summary>
    public void SetLocalPlayer(Guid? soulGuid, string? soulName)
    {
        lock (_lock)
        {
            if (soulGuid is Guid g && g != Guid.Empty) _playerGuid = g;
            if (!string.IsNullOrEmpty(soulName)) _playerName = soulName;
        }
    }

    /// <summary>A save load changes the per-save guid; forget it until re-read. The name survives.</summary>
    public void InvalidatePlayerGuid() { lock (_lock) _playerGuid = null; }

    /// <summary>New connection: the echo memory is about the old peer's stream.</summary>
    public void ResetEchoMemory()
    {
        lock (_lock) { _appliedIn.Clear(); _appliedFatalIn.Clear(); }
    }

    /// <summary>Is this soul (by guid, then by resolved name) the local player?</summary>
    public bool IsLocalPlayer(Guid? soulGuid, string? soulName)
    {
        lock (_lock)
        {
            if (soulGuid is Guid g && _playerGuid is Guid p && g == p) return true;
            return soulName is not null && _playerName is not null
                && string.Equals(soulName, _playerName, StringComparison.Ordinal);
        }
    }

    /// <summary>
    /// The DLL reported a local drop on <paramref name="soulGuid"/> that
    /// resolved to <paramref name="npcName"/> (null when the lookup failed).
    /// </summary>
    public Outbound CheckOutbound(Guid soulGuid, string? npcName, float hp, float st, bool fatal, DateTime nowUtc)
    {
        lock (_lock)
        {
            if (_playerGuid is Guid p && soulGuid == p) return Outbound.DropLocalPlayerGuid;
            if (npcName is not null && _playerName is not null
                && string.Equals(npcName, _playerName, StringComparison.Ordinal))
                return Outbound.DropLocalPlayerName;
            if (npcName is null) return Outbound.Send;   // guid-addressed fallback path; nothing to match by name

            if (fatal && _appliedFatalIn.TryGetValue(npcName, out var fatalAt) && nowUtc - fatalAt < EchoWindow)
                return Outbound.DropEchoFatal;

            if (_appliedIn.TryGetValue(npcName, out var list))
            {
                list.RemoveAll(e => nowUtc - e.At >= EchoWindow);
                foreach (var e in list)
                    if (Math.Abs(e.Hp - hp) < EchoTolerance && Math.Abs(e.St - st) < EchoTolerance)
                        return Outbound.DropEcho;
            }
            return Outbound.Send;
        }
    }

    /// <summary>
    /// A 0x31 arrived for <paramref name="npcName"/>; <paramref name="localGuid"/>
    /// is what this install's soul list answered for that name (null = nothing).
    /// </summary>
    public Inbound CheckInbound(string npcName, Guid? localGuid)
    {
        lock (_lock)
        {
            if (localGuid is Guid g && _playerGuid is Guid p && g == p) return Inbound.RefuseLocalPlayerGuid;
            if (_playerName is not null && string.Equals(npcName, _playerName, StringComparison.Ordinal))
                return Inbound.RefuseLocalPlayerName;
            return Inbound.Apply;
        }
    }

    /// <summary>Record an inbound hit this client APPLIED (or a death it applied), for echo matching.</summary>
    public void NoteInboundApplied(string npcName, float hp, float st, bool fatal, DateTime nowUtc)
    {
        lock (_lock)
        {
            if (fatal) _appliedFatalIn[npcName] = nowUtc;
            if (hp > 0f || st > 0f)
            {
                if (!_appliedIn.TryGetValue(npcName, out var list)) _appliedIn[npcName] = list = new();
                list.RemoveAll(e => nowUtc - e.At >= EchoWindow);
                list.Add((hp, st, nowUtc));
            }
        }
    }

    public static bool IsDrop(Outbound v) => v != Outbound.Send;

    public static string Reason(Outbound v) => v switch
    {
        Outbound.DropLocalPlayerGuid => "local_player",
        Outbound.DropLocalPlayerName => "local_player_name",
        Outbound.DropEcho            => "echo",
        Outbound.DropEchoFatal       => "echo_fatal",
        _                            => "-",
    };

    public static string Reason(Inbound v) => v switch
    {
        Inbound.RefuseLocalPlayerGuid => "local_player",
        Inbound.RefuseLocalPlayerName => "local_player_name",
        _                             => "-",
    };
}
