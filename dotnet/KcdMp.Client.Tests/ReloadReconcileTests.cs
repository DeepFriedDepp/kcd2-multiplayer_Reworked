using static KcdMp.Client.ReloadReconcile;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-88: pins the four post-reload decisions to the 2026-09-12 field
/// session's numbers. Each test names the log evidence it stands on
/// (docs/WO-88-findings.md); none of them needs a game, relay or agent.
/// </summary>
public class ReloadReconcileTests
{
    // ------------------------------------------------------------------
    // Finding 1 -- death tag vs the dying tick's own vitals
    // ------------------------------------------------------------------

    [Theory]
    [InlineData(0.0f)]      // the dying tick: "[vitals] sent health=0.0" in the same ms as "[death] local player died"
    [InlineData(-1.0f)]     // "unknown" sentinel the mod uses when the read fails
    public void DeadOrUnknownVitalsLeaveTheDeathTagAlone(float health)
        => Assert.False(VitalsClearDeathTag(health));

    [Theory]
    [InlineData(100.0f)]    // first post-reload packet: "[vitals] sent health=100.0" + "alive again"
    [InlineData(0.3f)]      // host 17:08:32.818: nearly dead but still standing
    public void AliveVitalsClearTheDeathTag(float health)
        => Assert.True(VitalsClearDeathTag(health));

    // ------------------------------------------------------------------
    // Finding 2 -- appearance after the ghost body is respawned
    // ------------------------------------------------------------------

    [Fact]
    public void FirstEntityIdForAGhostIsNotARespawn()
        => Assert.False(RespawnInvalidatesAppearance(previousEntityId: null, newEntityId: 0x2802F7));

    [Fact]
    public void SameEntityIdAgainIsNotARespawn()
        => Assert.False(RespawnInvalidatesAppearance(0x2802F7, 0x2802F7));

    [Fact]
    public void NewEntityIdForADressedGhostInvalidatesTheAppliedSet()
        // host kcd.log 2026-09-12: "[KCD2-MP-EVT] v1 7506 ghostid 1 00000000002802F7" after
        // "RECONCILE id=1 entity 'kcd2mp_1' is gone from the world (save load?)"
        => Assert.True(RespawnInvalidatesAppearance(0x2801A0, 0x2802F7));

    // ------------------------------------------------------------------
    // Finding 4 (primary) -- reload convergence must be proven, not assumed
    // ------------------------------------------------------------------

    private static readonly DateTime T0 = new(2026, 9, 12, 17, 16, 13, DateTimeKind.Utc);

    [Fact]
    public void NoOutstandingTargetMeansNoStep()
        => Assert.Equal(ConvergeStep.None,
            EvaluateConvergence(null, 568956, 900, T0.AddSeconds(5), T0.AddSeconds(120)));

    [Fact]
    public void HostReload5ReadingProvesTheApplyWasLostAndAsksForAResend()
    {
        // agent: "converging forward to session clock 584692 (reloaded to 568884, was 584692)"
        // kcd.log next time_now: 568956 -- no ApplyTimeSkip line ever appeared.
        var step = EvaluateConvergence(584692, 568956, 900, T0.AddSeconds(5), T0.AddSeconds(120));
        Assert.Equal(ConvergeStep.Resend, step);
    }

    [Fact]
    public void ReadingAtOrPastTargetIsSatisfied()
        => Assert.Equal(ConvergeStep.Satisfied,
            EvaluateConvergence(584692, 584700, 900, T0.AddSeconds(15), T0.AddSeconds(120)));

    [Fact]
    public void ReadingWithinThresholdBelowTargetIsSatisfied()
        // the target was computed from a reading up to ~10 s old; 900 game-s of slack covers that
        => Assert.Equal(ConvergeStep.Satisfied,
            EvaluateConvergence(584692, 584692 - 899, 900, T0.AddSeconds(15), T0.AddSeconds(120)));

    [Fact]
    public void ReadingJustOutsideThresholdStillResends()
        => Assert.Equal(ConvergeStep.Resend,
            EvaluateConvergence(584692, 584692 - 901, 900, T0.AddSeconds(15), T0.AddSeconds(120)));

    [Fact]
    public void StillBehindAfterTheWindowExpires()
        => Assert.Equal(ConvergeStep.Expired,
            EvaluateConvergence(584692, 570000, 900, T0.AddSeconds(121), T0.AddSeconds(120)));

    [Fact]
    public void SatisfiedWinsOverExpiry()
        // a late reading that does show the write landed is still "done", not "gave up"
        => Assert.Equal(ConvergeStep.Satisfied,
            EvaluateConvergence(584692, 584800, 900, T0.AddSeconds(300), T0.AddSeconds(120)));

    [Fact]
    public void ThresholdArithmeticDoesNotOverflow()
        => Assert.Equal(ConvergeStep.Satisfied,
            EvaluateConvergence(uint.MaxValue, uint.MaxValue - 10, 900, T0, T0.AddSeconds(1)));

    // ------------------------------------------------------------------
    // Finding 4 (secondary) -- quiet peer announces vs natural skew
    // ------------------------------------------------------------------

    [Fact]
    public void QuietSyncWithNoLocalReadingIsApplied()
        => Assert.True(QuietSyncWorthApplying(573601, lastPolled: null, DateTime.MinValue, T0, 15.0, 900));

    [Fact]
    public void QuietSyncWithinSkewOfOurClockIsIgnored()
    {
        // our clock read 580000 six real seconds ago -> ~580090 now; peer says 580200
        Assert.False(QuietSyncWorthApplying(580200, 580000, T0.AddSeconds(-6), T0, 15.0, 900));
    }

    [Fact]
    public void QuietSyncFromAPeerHoursAheadIsApplied()
    {
        // the 17:24 field state: host at ~576492, joiner announcing ~594226 (4.9 game-hours ahead)
        Assert.True(QuietSyncWorthApplying(594226, 576492, T0.AddSeconds(-3), T0, 15.0, 900));
    }

    [Fact]
    public void QuietSyncBehindOurClockIsIgnored()
        // forward-only: a peer who is behind never pulls us back (Lua would refuse anyway)
        => Assert.False(QuietSyncWorthApplying(560000, 580000, T0.AddSeconds(-1), T0, 15.0, 900));

    [Fact]
    public void QuietSyncAtExactlyThresholdIsIgnoredJustBeyondIsApplied()
    {
        // lastPolled 580000 read "now": estimate 580000; threshold 900
        Assert.False(QuietSyncWorthApplying(580900, 580000, T0, T0, 15.0, 900));
        Assert.True(QuietSyncWorthApplying(580901, 580000, T0, T0, 15.0, 900));
    }

    [Fact]
    public void QuietSyncExtrapolatesOurClockByTheWorldTimeRatio()
    {
        // 60 real seconds since our last poll = 900 game-s of natural advance; a peer 1,000 ahead
        // of the stale reading is only ~100 ahead of where we are now -> noise
        Assert.False(QuietSyncWorthApplying(581000, 580000, T0.AddSeconds(-60), T0, 15.0, 900));
        // whereas without the extrapolation it would have looked like a real gap
        Assert.True(QuietSyncWorthApplying(581000, 580000, T0, T0, 15.0, 900));
    }
}
