namespace KcdMp.Client.Tests;

/// <summary>
/// WO-99 Phase 0: the "Dude" collision and the echo loop, replayed from the
/// 2026-09-16 bundles (docs/WO-99-findings.md Phase 0). Two guards stand in
/// for two agents; each has its own per-save player guid and the engine's
/// shared player soul name. Nothing here needs a game, relay or agent.
/// </summary>
public class NpcDamageGuardTests
{
    private static readonly DateTime T0 = new(2026, 9, 16, 19, 17, 23, DateTimeKind.Utc);
    private static readonly Guid HostPlayer   = Guid.Parse("e8bc9aed-7739-44e3-ac4b-6ebabcc20e91");   // host  agent.log 19:17:26.030
    private static readonly Guid JoinerPlayer = Guid.Parse("2e6edb16-0807-4f11-b58e-30d5b4620111");   // joiner agent.log 19:17:35.829
    private static readonly Guid Robber       = Guid.NewGuid();

    private static (NpcDamageGuard host, NpcDamageGuard joiner) TwoAgents()
    {
        var h = new NpcDamageGuard(); h.SetLocalPlayer(HostPlayer, "Dude");
        var j = new NpcDamageGuard(); j.SetLocalPlayer(JoinerPlayer, "Dude");
        return (h, j);
    }

    // ------------------------------------------------------------------
    // The collision: two players, one name, zero cross-application
    // ------------------------------------------------------------------

    [Fact]
    public void HostsOwnWoundNeverLeavesTheHost()
    {
        var (host, _) = TwoAgents();
        // host 19:17:26.030: DLL LocalHit 88.9 on the host's own player soul
        Assert.Equal(NpcDamageGuard.Outbound.DropLocalPlayerGuid,
            host.CheckOutbound(HostPlayer, "Dude", 88.9f, 0f, false, T0));
    }

    [Fact]
    public void APreFixPeerPacketForDudeIsRefusedByGuidOnTheJoiner()
    {
        var (_, joiner) = TwoAgents();
        // joiner 19:17:23.977: 0x31 npc=Dude hp=88.9 -- the name resolves to the joiner's OWN player soul
        Assert.Equal(NpcDamageGuard.Inbound.RefuseLocalPlayerGuid, joiner.CheckInbound("Dude", JoinerPlayer));
    }

    [Fact]
    public void NameIsTheFallbackWhenTheGuidIsNotYetKnown()
    {
        var g = new NpcDamageGuard();
        g.SetLocalPlayer(null, "Dude");                       // PlayerSoul read failed, name known from an earlier read
        Assert.Equal(NpcDamageGuard.Inbound.RefuseLocalPlayerName, g.CheckInbound("Dude", JoinerPlayer));
        Assert.Equal(NpcDamageGuard.Outbound.DropLocalPlayerName,
            g.CheckOutbound(JoinerPlayer, "Dude", 7.7f, 0f, false, T0));
    }

    [Fact]
    public void AfterASaveLoadTheStaleGuidIsGoneButTheNameStillHolds()
    {
        var g = new NpcDamageGuard();
        g.SetLocalPlayer(HostPlayer, "Dude");
        g.InvalidatePlayerGuid();
        var newGuid = Guid.NewGuid();                          // the reloaded save's PlayerSoul
        Assert.Equal(NpcDamageGuard.Outbound.DropLocalPlayerName,
            g.CheckOutbound(newGuid, "Dude", 16.2f, 0f, false, T0));
        g.SetLocalPlayer(newGuid, "Dude");                     // forced re-read lands
        Assert.Equal(NpcDamageGuard.Outbound.DropLocalPlayerGuid,
            g.CheckOutbound(newGuid, "Dude", 16.2f, 0f, false, T0));
    }

    [Fact]
    public void ARealNpcIsUntouchedByThePlayerExclusion()
    {
        var (host, joiner) = TwoAgents();
        // host 19:16:06.730: out npc=hledaniPsa_corpseRobber hp=4.3
        Assert.Equal(NpcDamageGuard.Outbound.Send,
            host.CheckOutbound(Robber, "hledaniPsa_corpseRobber", 4.3f, 0f, false, T0));
        Assert.Equal(NpcDamageGuard.Inbound.Apply, joiner.CheckInbound("hledaniPsa_corpseRobber", Guid.NewGuid()));
    }

    [Fact]
    public void FullSessionReplayProducesNoCrossApplicationAndNoReEmission()
    {
        var (host, joiner) = TwoAgents();
        // The nine Dude MP-DMG lines per side, in wire order (host clock).
        (bool hostSide, float hp)[] events =
        {
            (true, 88.9f), (false, 7.7f), (true, 16.2f), (false, 16.9f), (true, 28.2f),
        };
        int sent = 0, applied = 0;
        var t = T0;
        foreach (var (hostSide, hp) in events)
        {
            var (src, srcGuid, dst, dstGuid) = hostSide ? (host, HostPlayer, joiner, JoinerPlayer) : (joiner, JoinerPlayer, host, HostPlayer);
            if (src.CheckOutbound(srcGuid, "Dude", hp, 0f, false, t) == NpcDamageGuard.Outbound.Send)
            {
                sent++;
                if (dst.CheckInbound("Dude", dstGuid) == NpcDamageGuard.Inbound.Apply) applied++;
            }
            t = t.AddSeconds(12);
        }
        Assert.Equal(0, sent);
        Assert.Equal(0, applied);
    }

    // ------------------------------------------------------------------
    // The echo guard, independent of the player exclusion
    // ------------------------------------------------------------------

    [Fact]
    public void AnAppliedInboundValueIsNotReEmittedWithinTheWindow()
    {
        var g = new NpcDamageGuard();
        g.NoteInboundApplied("hledaniPsa_corpseRobber", 21.6f, 0f, false, T0);           // joiner 19:16:34.164 in applied
        // the DLL reports the same drop 12 s later (the credit was wiped by the 3 s rescan)
        Assert.Equal(NpcDamageGuard.Outbound.DropEcho,
            g.CheckOutbound(Robber, "hledaniPsa_corpseRobber", 21.6f, 0f, false, T0.AddSeconds(12)));
        // F1 wire rounding: 21.64 is the same hit
        Assert.Equal(NpcDamageGuard.Outbound.DropEcho,
            g.CheckOutbound(Robber, "hledaniPsa_corpseRobber", 21.64f, 0f, false, T0.AddSeconds(12)));
    }

    [Fact]
    public void ADifferentValueOnTheSameNpcStillGoesOut()
    {
        var g = new NpcDamageGuard();
        g.NoteInboundApplied("hledaniPsa_corpseRobber", 21.6f, 0f, false, T0);
        Assert.Equal(NpcDamageGuard.Outbound.Send,
            g.CheckOutbound(Robber, "hledaniPsa_corpseRobber", 15.9f, 0f, false, T0.AddSeconds(1)));
    }

    [Fact]
    public void TheEchoMemoryExpires()
    {
        var g = new NpcDamageGuard();
        g.NoteInboundApplied("hledaniPsa_corpseRobber", 21.6f, 0f, false, T0);
        Assert.Equal(NpcDamageGuard.Outbound.Send,
            g.CheckOutbound(Robber, "hledaniPsa_corpseRobber", 21.6f, 0f, false, T0 + NpcDamageGuard.EchoWindow));
    }

    [Fact]
    public void ARemoteDeathDoesNotEchoAsALocalFatal()
    {
        var g = new NpcDamageGuard();
        g.NoteInboundApplied("hledaniPsa_corpseRobber", 0f, 0f, fatal: true, T0);        // joiner 19:16:36.008 in fatal nodelta
        // joiner 19:16:36.107: out hp=2.0 fatal=1 -- the lethal apply's own drop
        Assert.Equal(NpcDamageGuard.Outbound.DropEchoFatal,
            g.CheckOutbound(Robber, "hledaniPsa_corpseRobber", 2.0f, 0f, true, T0.AddMilliseconds(99)));
        // but a genuine later kill of a same-named respawn, outside the window, still travels
        Assert.Equal(NpcDamageGuard.Outbound.Send,
            g.CheckOutbound(Robber, "hledaniPsa_corpseRobber", 2.0f, 0f, true, T0 + NpcDamageGuard.EchoWindow));
    }

    [Fact]
    public void ResetForgetsEchoesButNotWhoThePlayerIs()
    {
        var g = new NpcDamageGuard();
        g.SetLocalPlayer(HostPlayer, "Dude");
        g.NoteInboundApplied("x", 5f, 0f, false, T0);
        g.ResetEchoMemory();
        Assert.Equal(NpcDamageGuard.Outbound.Send, g.CheckOutbound(Robber, "x", 5f, 0f, false, T0.AddSeconds(1)));
        Assert.Equal(NpcDamageGuard.Outbound.DropLocalPlayerGuid, g.CheckOutbound(HostPlayer, "Dude", 5f, 0f, false, T0));
    }

    [Fact]
    public void GuidAddressedFallbackHitsPassWhenTheNameIsUnknownAndTheSoulIsNotThePlayer()
    {
        var g = new NpcDamageGuard();
        g.SetLocalPlayer(HostPlayer, "Dude");
        Assert.Equal(NpcDamageGuard.Outbound.Send, g.CheckOutbound(Robber, null, 9f, 0f, false, T0));
        Assert.Equal(NpcDamageGuard.Outbound.DropLocalPlayerGuid, g.CheckOutbound(HostPlayer, null, 9f, 0f, false, T0));
    }
}
