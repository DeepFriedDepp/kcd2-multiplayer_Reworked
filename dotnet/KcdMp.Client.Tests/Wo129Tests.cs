using System.Reflection;
using DiscordRPC;
using KCDMP_launcher.Models;

namespace KcdMp.Client.Tests;

/// <summary>WO-129: the first shared-world session's fixes (docs/WO-129-findings.md).</summary>
public class Wo129Tests
{
    // ---------------------------------------------------------------- clock skew

    [Fact]
    public void HostStamp_age_removes_the_measured_offset()
    {
        // The first session's joiner ran 8.04 s AHEAD of its host: MP-CLOCK
        // offset_ms=-8042 (relay/host clock minus this machine's).
        const long hostNow = 1_790_000_000_000;
        const long localNow = hostNow + 8042;
        const long stamp = hostNow - 50;   // the host saved 50 ms ago
        long age = Wo129.HostStampAgeMs(localNow, stamp, -8042.0, out bool corrected);
        Assert.True(corrected);
        Assert.Equal(50, age);
    }

    [Fact]
    public void HostStamp_age_without_a_clock_sample_is_raw_and_says_so()
    {
        long age = Wo129.HostStampAgeMs(1_000_100, 1_000_000, null, out bool corrected);
        Assert.False(corrected);
        Assert.Equal(100, age);
        age = Wo129.HostStampAgeMs(1_000_100, 1_000_000, double.NaN, out corrected);
        Assert.False(corrected);
        Assert.Equal(100, age);
    }

    [Fact]
    public void HostStamp_age_of_a_joiner_behind_its_host()
    {
        long age = Wo129.HostStampAgeMs(10_000 - 3000, 9_900, +3000.0, out bool corrected);
        Assert.True(corrected);
        Assert.Equal(100, age);
    }

    // ---------------------------------------------------------------- launcher status

    private static ConnectionStatusData Conn(string state, string msg = "", string via = "direct") =>
        new() { State = state, Message = msg, Via = via };
    private static JoinStatusData Join(string state, string msg) => new() { State = state, Message = msg };

    [Fact]
    public void Connecting_line_clears_once_connected()
    {
        var b = new AgentStatusBanner();
        b.Start(viaSteam: false, 0);
        Assert.Equal("Connecting to your host...", b.ConnLine);
        Assert.NotNull(b.Apply(Conn("connecting", "Connecting to your host..."), Join("idle", ""), true, 1));
        Assert.Equal("Connecting to your host...", b.ConnLine);
        Assert.NotNull(b.Apply(Conn("connected", "Connected to your host."), Join("idle", ""), true, 2));
        Assert.Equal("", b.ConnLine);
        Assert.False(b.ConnBad);
    }

    [Fact]
    public void The_first_join_question_shows_the_two_buttons()
    {
        var b = new AgentStatusBanner();
        b.Start(false, 0);
        b.Apply(Conn("connected"), Join("choose", "First time in this world: bring your character, or start fresh?"), true, 1);
        Assert.True(b.ShowChoiceButtons);
        Assert.Equal("First time in this world: bring your character, or start fresh?", b.JoinMessage);
        b.Apply(Conn("connected"), Join("requesting", "Asking your host for the world..."), true, 2);
        Assert.False(b.ShowChoiceButtons);
        b.Apply(Conn("connected"), Join("idle", "anything"), true, 3);
        Assert.Equal("", b.JoinMessage);
    }

    [Fact]
    public void An_unreadable_agent_is_said_so_never_a_frozen_connecting()
    {
        var b = new AgentStatusBanner();
        b.Start(false, 0);
        b.Apply(null, null, true, 3);
        Assert.Equal("Connecting to your host...", b.ConnLine);   // not yet: under the window
        b.Apply(null, null, true, AgentStatusBanner.UnreadableAfterS + 0.5);
        Assert.Contains("isn't answering", b.ConnLine);
        Assert.True(b.ConnBad);
        b.Apply(Conn("connected"), null, true, 20);
        Assert.Equal("", b.ConnLine);
    }

    [Fact]
    public void Once_connected_a_missed_read_keeps_the_line_clear()
    {
        var b = new AgentStatusBanner();
        b.Start(false, 0);
        b.Apply(Conn("connected"), Join("idle", ""), true, 1);
        b.Apply(null, null, true, 100);
        Assert.Equal("", b.ConnLine);
    }

    [Fact]
    public void An_agent_that_exits_before_connecting_is_reported()
    {
        var b = new AgentStatusBanner();
        b.Start(true, 0);
        Assert.Equal("Connecting to your host through Steam...", b.ConnLine);
        b.Apply(null, null, agentAlive: false, 2);
        Assert.Contains("stopped", b.ConnLine);
        var c = new AgentStatusBanner();
        c.Start(false, 0);
        c.Apply(Conn("connected"), null, true, 1);
        c.Apply(null, null, agentAlive: false, 2);
        Assert.Equal("", c.ConnLine);
    }

    [Fact]
    public void A_failure_shows_the_sentence_and_the_next_step()
    {
        var b = new AgentStatusBanner();
        b.Start(false, 0);
        b.Apply(new ConnectionStatusData { State = "failed", Message = "Your host's computer refused the connection.", Next = "Check the port." }, null, true, 1);
        Assert.Equal("Your host's computer refused the connection. Check the port.", b.ConnLine);
        Assert.True(b.ConnBad);
    }

    [Fact]
    public void Only_a_change_is_reported_for_the_launcher_log()
    {
        var b = new AgentStatusBanner();
        b.Start(false, 0);
        Assert.NotNull(b.Apply(Conn("connected"), Join("choose", "q"), true, 1));
        Assert.Null(b.Apply(Conn("connected"), Join("choose", "q"), true, 2));
        string? line = b.Apply(Conn("connected"), Join("requesting", "r"), true, 3);
        Assert.NotNull(line);
        Assert.Contains("join=requesting", line);
        Assert.Contains("buttons=hidden", line);
    }

    // ---------------------------------------------------------------- Discord

    private static void Merge(RichPresence into, RichPresence reply)
    {
        var m = typeof(RichPresence).GetMethod("Merge", BindingFlags.Instance | BindingFlags.NonPublic | BindingFlags.Public, null, new[] { typeof(BaseRichPresence) }, null)!;
        try { m.Invoke(into, new object[] { reply }); }
        catch (TargetInvocationException e) when (e.InnerException is not null) { throw e.InnerException; }
    }

    private static RichPresence Ours() => new()
    {
        Details = "Playing", State = "v0.30.0 · solo",
        Assets = new Assets { LargeImageKey = "kcd2mp", LargeImageText = "Kingdom Come: Deliverance II Multiplayer", SmallImageKey = "" },
    };

    // Discord's echo of SET_ACTIVITY: the large image only, no small image.
    private static RichPresence DiscordReply() => new()
    {
        Details = "Playing", State = "v0.30.0 · solo",
        Assets = new Assets { LargeImageKey = "kcd2mp", LargeImageText = "Kingdom Come: Deliverance II Multiplayer" },
    };

    [Fact]
    public void DiscordRPC_1_6_1_throws_merging_a_reply_without_a_small_image()
    {
        // The library bug itself (both field agent logs: "at DiscordRPC.Assets.Merge").
        Assert.Throws<NullReferenceException>(() => Merge(Ours(), DiscordReply()));
    }

    [Fact]
    public void Forgetting_the_cached_assets_stops_the_merge_exception()
    {
        var cached = Ours();
        DiscordPresence.ForgetCachedAssets(cached);
        Merge(cached, DiscordReply());   // no exception
        Assert.Equal("kcd2mp", cached.Assets?.LargeImageKey);   // it adopts Discord's own echo
        DiscordPresence.ForgetCachedAssets(null);   // a client with no presence yet
    }
}
