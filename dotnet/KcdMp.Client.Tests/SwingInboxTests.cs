using KcdMp.Client;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-100 Phase 4. These are synthetic — no game, no pipe, no real clock — and
/// that is stated rather than implied: they prove the inbox's own rules, not
/// that a swing renders.
/// </summary>
public class SwingInboxTests
{
    /// <summary>A controllable clock, so a 750 ms deadline costs no wall time.</summary>
    private sealed class FakeClock
    {
        public DateTime Now = new(2026, 9, 17, 12, 0, 0, DateTimeKind.Utc);
        public TimeSpan Step = TimeSpan.FromMilliseconds(100);
        public Task Advance(CancellationToken ct) { Now += Step; return Task.CompletedTask; }
    }

    private static (SwingInbox Inbox, List<SwingInbox.Outcome> Outcomes, List<string> Log)
        Build(Func<string, uint?> resolve,
              Func<string, int> gen,
              Func<uint, string, CancellationToken, Task<PipeResult>>? apply = null,
              FakeClock? clock = null,
              int capacity = 16)
    {
        clock ??= new FakeClock();
        var log = new List<string>();
        var outcomes = new List<SwingInbox.Outcome>();
        var inbox = new SwingInbox(
            resolve, gen,
            apply ?? ((_, _, _) => Task.FromResult(new PipeResult(true, PipeReason.Ok))),
            line => { lock (log) log.Add(line); },
            capacity: capacity,
            now: () => clock.Now,
            pollDelay: clock.Advance);
        inbox.OnOutcome = o => { lock (outcomes) outcomes.Add(o); };
        return (inbox, outcomes, log);
    }

    private static SwingInbox.Entry E(string ghost = "3", int gen = 0, ushort sid = 1, long rsid = 1) =>
        new(ghost, sid, rsid, gen, "CombatAttack, aZ2+slash", DateTime.UtcNow);

    private static async Task<SwingInbox.Outcome> One(SwingInbox inbox,
                                                      List<SwingInbox.Outcome> outcomes,
                                                      SwingInbox.Entry e)
    {
        inbox.Start();
        Assert.True(inbox.TryEnqueue(e));
        for (int i = 0; i < 400 && outcomes.Count == 0; i++) await Task.Delay(5);
        Assert.Single(outcomes);
        return outcomes[0];
    }

    [Fact]
    public async Task Applies_when_the_body_is_known_and_the_generation_matches()
    {
        var (inbox, outcomes, _) = Build(_ => 0x1234u, _ => 7);
        await using var _d = inbox;
        var o = await One(inbox, outcomes, E(gen: 7));
        Assert.True(o.Ok);
        Assert.Equal(PipeReason.Ok, o.Reason);
        Assert.Equal(1, inbox.Applied);
    }

    [Fact]
    public async Task Discards_an_event_whose_body_generation_has_moved_on()
    {
        // The whole point of Phase 4 item 1: a swing sent for the body that was
        // standing there must not play on the body that replaced it.
        bool applied = false;
        var (inbox, outcomes, _) = Build(_ => 0x1234u, _ => 8,
            apply: (_, _, _) => { applied = true; return Task.FromResult(new PipeResult(true, PipeReason.Ok)); });
        await using var _d = inbox;
        var o = await One(inbox, outcomes, E(gen: 7));
        Assert.False(o.Ok);
        Assert.Equal(PipeReason.Expired, o.Reason);
        Assert.False(applied);
        Assert.Equal(1, inbox.Expired);
    }

    [Fact]
    public async Task Waits_for_the_entity_id_and_then_applies()
    {
        // The window between a ghost spawning and its ghostid event: this used
        // to be a permanent downgrade to the Lua cue.
        int calls = 0;
        var clock = new FakeClock();
        var (inbox, outcomes, _) = Build(
            _ => ++calls >= 3 ? 0x99u : null,
            _ => 0, clock: clock);
        await using var _d = inbox;
        var o = await One(inbox, outcomes, E());
        Assert.True(o.Ok);
        Assert.True(o.WaitedMs > 0);
        Assert.Equal(1, inbox.Waited);
        Assert.Equal(0, inbox.GaveUp);
    }

    [Fact]
    public async Task Gives_up_on_the_precondition_at_the_deadline_and_reports_the_waited_time()
    {
        var clock = new FakeClock();
        var (inbox, outcomes, log) = Build(_ => null, _ => 0, clock: clock);
        await using var _d = inbox;
        var o = await One(inbox, outcomes, E());
        Assert.False(o.Ok);
        Assert.Equal(PipeReason.PreconditionTimeout, o.Reason);
        Assert.Equal(1, inbox.GaveUp);
        // Never unbounded, and the waited time is on the line so the deadline
        // can be tuned with evidence rather than by taste.
        Assert.True(o.WaitedMs >= 750);
        Assert.Contains(log, l => l.Contains("reason=precondition-timeout") && l.Contains("waited_ms="));
    }

    [Fact]
    public async Task Discards_an_event_whose_body_is_replaced_while_it_waits()
    {
        var clock = new FakeClock();
        int gen = 0;
        int polls = 0;
        var (inbox, outcomes, _) = Build(
            _ => { if (++polls >= 2) gen = 1; return null; },
            _ => gen, clock: clock);
        await using var _d = inbox;
        var o = await One(inbox, outcomes, E(gen: 0));
        Assert.Equal(PipeReason.Expired, o.Reason);
        Assert.Equal(1, inbox.Expired);
        Assert.Equal(0, inbox.GaveUp);
    }

    [Fact]
    public async Task Carries_the_native_reason_through_instead_of_a_bare_false()
    {
        var (inbox, outcomes, log) = Build(_ => 1u, _ => 0,
            apply: (_, _, _) => Task.FromResult(new PipeResult(false, PipeReason.RowNotOnThisBuild)));
        await using var _d = inbox;
        var o = await One(inbox, outcomes, E());
        Assert.False(o.Ok);
        Assert.Equal(PipeReason.RowNotOnThisBuild, o.Reason);
        Assert.Contains(log, l => l.Contains("reason=row-not-on-this-build"));
        Assert.Equal(1, inbox.Refused);
    }

    [Fact]
    public void Refuses_and_counts_beyond_the_bound_rather_than_growing()
    {
        // Not started, so nothing drains: the queue fills and then refuses.
        var (inbox, _, log) = Build(_ => 1u, _ => 0, capacity: 4);
        for (int i = 0; i < 4; i++) Assert.True(inbox.TryEnqueue(E(rsid: i)));
        Assert.False(inbox.TryEnqueue(E(rsid: 99)));
        Assert.Equal(1, inbox.Dropped);
        Assert.Equal(4, inbox.Accepted);
        Assert.Contains(log, l => l.Contains("reason=inbox-full") && l.Contains("bound=4"));
    }

    [Fact]
    public void Reports_pressure_before_the_bound_is_reached()
    {
        var (inbox, _, log) = Build(_ => 1u, _ => 0, capacity: 4);
        for (int i = 0; i < 3; i++) inbox.TryEnqueue(E(rsid: i));
        Assert.Contains(log, l => l.Contains("hop=pressure") && l.Contains("bound=4"));
    }

    [Fact]
    public async Task A_throwing_apply_does_not_stop_the_worker()
    {
        // The fire-and-forget task this replaced could die unobserved and the
        // channel would go quiet, which looks exactly like "no swings arrived".
        int n = 0;
        var (inbox, outcomes, _) = Build(_ => 1u, _ => 0,
            apply: (_, _, _) => ++n == 1
                ? throw new InvalidOperationException("boom")
                : Task.FromResult(new PipeResult(true, PipeReason.Ok)));
        await using var _d = inbox;
        inbox.Start();
        inbox.TryEnqueue(E(rsid: 1));
        inbox.TryEnqueue(E(rsid: 2));
        for (int i = 0; i < 400 && outcomes.Count < 2; i++) await Task.Delay(5);
        Assert.Equal(2, outcomes.Count);
        Assert.True(outcomes[1].Ok);
    }

    [Fact]
    public void Summary_line_carries_every_counter()
    {
        var (inbox, _, _) = Build(_ => 1u, _ => 0, capacity: 9);
        string line = inbox.SummaryLine();
        foreach (var key in new[] { "accepted=", "applied=", "refused=", "expired=",
                                    "waited=", "gaveup=", "dropped=", "peak_depth=", "bound=9" })
            Assert.Contains(key, line);
    }
}
