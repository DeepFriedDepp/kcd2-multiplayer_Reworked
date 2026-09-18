using KcdMp.Client;
using KcdMp.Wire;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>WO-102 Phase 6: the NpcState codec the relay gate now shares with the agent.</summary>
public class NpcStateCodecTests
{
    [Fact]
    public void Up_then_down_round_trips_with_the_resync_flag()
    {
        byte flags = (byte)(Protocol.NpcStateFlagDead | Protocol.NpcStateFlagResync);
        var up = NpcStateCodec.BuildUp("ttkc_man_20", 2340.5f, 2047.25f, 109.0f, 1.5f, 0f, flags);
        Assert.Equal(Protocol.NpcStateUp, up[0]);
        Assert.Equal(3 + 1 + 11 + Protocol.NpcStateFixedTail, up.Length);
        // relay shape: [src] + body verbatim
        var down = new byte[1 + up.Length - 3];
        down[0] = 0;
        Array.Copy(up, 3, down, 1, up.Length - 3);
        Assert.True(NpcStateCodec.TryParseDown(down, out var d));
        Assert.Equal((byte)0, d.SourceGhostId);
        Assert.Equal("ttkc_man_20", d.Name);
        Assert.Equal(2340.5f, d.X); Assert.Equal(2047.25f, d.Y); Assert.Equal(109.0f, d.Z); Assert.Equal(1.5f, d.RotZ);
        Assert.Equal(0f, d.Health);
        Assert.Equal(flags, d.Flags);
        Assert.NotEqual(0, d.Flags & Protocol.NpcStateFlagResync);
    }

    [Fact]
    public void Resync_bit_does_not_collide_with_the_shipped_bits()
    {
        Assert.Equal(0, Protocol.NpcStateFlagResync & (Protocol.NpcStateFlagDead | Protocol.NpcStateFlagUnconscious | Protocol.NpcStateFlagEngaged | 0x04 | 0x08 | 0x10));
    }

    [Fact]
    public void Lying_name_length_is_refused()
    {
        var up = NpcStateCodec.BuildUp("abc", 0, 0, 0, 0, 100, 0);
        var down = new byte[1 + up.Length - 3];
        Array.Copy(up, 3, down, 1, up.Length - 3);
        down[1] = 5;   // claims a longer name than the frame holds
        Assert.False(NpcStateCodec.TryParseDown(down, out _));
    }

    [Fact]
    public void Empty_or_oversized_names_cannot_be_built()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => NpcStateCodec.BuildUp("", 0, 0, 0, 0, 0, 0));
        Assert.Throws<ArgumentOutOfRangeException>(() => NpcStateCodec.BuildUp(new string('a', Protocol.MaxNpcNameLen + 1), 0, 0, 0, 0, 0, 0));
    }
}
