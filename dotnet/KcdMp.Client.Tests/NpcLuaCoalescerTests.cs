using KcdMp.Client;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-118 follow-up: the Lua push coalescer for puppets the DLL writes --
/// unbound: every sample; bound: the latest per interval, flag and health
/// changes at once, the pending latest handed out when due or when unbound.
/// </summary>
public class NpcLuaCoalescerTests
{
    private const long I = 200;   // interval, in the caller's ticks

    [Fact]
    public void Unbound_puppets_get_every_sample()
    {
        var c = new NpcLuaCoalescer(I);
        for (int t = 0; t < 10; t++) Assert.True(c.Offer("a", bound: false, 0, 100f, t * 10, "s" + t));
        Assert.Equal(10, c.Pushed);
        Assert.Equal(0, c.Coalesced);
        Assert.Null(c.TakeDue(_ => false, 1000));
    }

    [Fact]
    public void Bound_puppets_get_the_first_sample_then_one_per_interval()
    {
        var c = new NpcLuaCoalescer(I);
        Assert.True(c.Offer("a", true, 0, 100f, 0, "s0"));
        Assert.False(c.Offer("a", true, 0, 100f, 100, "s1"));
        Assert.False(c.Offer("a", true, 0, 100f, 150, "s2"));
        Assert.True(c.Offer("a", true, 0, 100f, 200, "s3"));   // the interval is up: this one goes
        Assert.Equal(2, c.Pushed);
        Assert.Equal(2, c.Coalesced);
    }

    [Fact]
    public void Flag_and_health_changes_go_at_once()
    {
        var c = new NpcLuaCoalescer(I);
        c.Offer("a", true, 0x00, 100f, 0, "s0");
        Assert.True(c.Offer("a", true, 0x04, 100f, 10, "drawn"));       // drawn
        Assert.True(c.Offer("a", true, 0x0C, 100f, 20, "swing"));       // swing cue
        Assert.True(c.Offer("a", true, 0x04, 100f, 30, "swing-off"));   // and its end
        Assert.True(c.Offer("a", true, 0x04, 87.5f, 40, "hit"));        // health
        Assert.False(c.Offer("a", true, 0x04, 87.52f, 50, "same-hp"));  // not a change at 0.1
        Assert.True(c.Offer("a", true, 0x05, 87.5f, 60, "dead"));       // dead
    }

    [Fact]
    public void The_pending_latest_is_flushed_when_due_and_only_the_latest()
    {
        var c = new NpcLuaCoalescer(I);
        c.Offer("a", true, 0, 100f, 0, "s0");
        c.Offer("a", true, 0, 100f, 50, "s1");
        c.Offer("a", true, 0, 100f, 90, "s2");   // the puppet stops: no more samples
        Assert.Null(c.TakeDue(_ => true, 150));   // not due yet
        var due = c.TakeDue(_ => true, 200);
        Assert.Equal(new[] { "s2" }, due);        // the latest, once
        Assert.Null(c.TakeDue(_ => true, 1000));
    }

    [Fact]
    public void An_unbound_puppet_gets_its_pending_sample_at_once_and_is_forgotten()
    {
        var c = new NpcLuaCoalescer(I);
        c.Offer("a", true, 0, 100f, 0, "s0");
        c.Offer("a", true, 0, 100f, 20, "s1");
        Assert.Equal(new[] { "s1" }, c.TakeDue(_ => false, 30));   // dropped by the DLL: Lua takes over from the latest
        Assert.Equal(0, c.Tracked);
        Assert.True(c.Offer("a", false, 0, 100f, 40, "s2"));        // full rate from then on
    }

    [Fact]
    public void A_newer_sample_supersedes_the_pending_one()
    {
        var c = new NpcLuaCoalescer(I);
        c.Offer("a", true, 0, 100f, 0, "s0");
        c.Offer("a", true, 0, 100f, 50, "s1");
        Assert.True(c.Offer("a", true, 0, 100f, 250, "s2"));   // due: sent directly, pending cleared
        Assert.Null(c.TakeDue(_ => true, 600));                 // s1 is never sent after s2
    }
}
