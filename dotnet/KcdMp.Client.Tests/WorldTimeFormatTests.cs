using System.Globalization;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-104 Phase 0. The 2026-09-18 two-player session lost time sync the
/// moment the world clock crossed 1,000,000 world-seconds: the mod's Lua
/// formatted Calendar.GetWorldTime() with tostring(), this build's Lua uses
/// "%g", and '1.00255e+06' arrived at a parser that -- correctly -- refuses
/// it. The fix is at the SENDER (kdcmp.lua now formats with "%.0f"). These
/// tests pin both halves: the agent's parse stays strict, and the mod's
/// source never goes back to tostring() for that field.
/// </summary>
public class WorldTimeFormatTests
{
    [Theory]
    [InlineData("982149", 982149u)]          // last good value in the field log
    [InlineData("1002550", 1002550u)]        // what '1.00255e+06' should have been
    [InlineData("1040080", 1040080u)]
    [InlineData("4294967295", uint.MaxValue)]
    [InlineData(" 1002550 ", 1002550u)]      // log-tail whitespace tolerated
    public void Parses_plain_integers_above_and_below_1e6(string wire, uint expected)
    {
        Assert.True(GameBridge.TryParseWorldTime(wire, out var t));
        Assert.Equal(expected, t);
    }

    [Theory]
    [InlineData("1.00255e+06")]   // the exact field failure
    [InlineData("1.02563e+06")]
    [InlineData("1e6")]
    [InlineData("1002550.0")]
    [InlineData("-5")]
    [InlineData("")]
    public void Refuses_scientific_notation_and_fractions(string wire)
    {
        // The parser must NOT be widened to accept these: six significant
        // figures at 1e6 is a ~5 s granularity, and a silently-rounded
        // reading would feed the clock-jump watcher phantom jumps.
        Assert.False(GameBridge.TryParseWorldTime(wire, out _));
    }

    [Fact]
    public void Round_trip_above_1e6_is_exact_through_the_senders_format()
    {
        // The sender's "%.0f" of an integer-valued double is exact for any
        // value a uint can hold; assert the same in .NET terms so the
        // contract is stated on both sides of the wire.
        foreach (var v in new[] { 1_000_000d, 1_002_550d, 4_294_967_295d })
        {
            var wire = v.ToString("F0", CultureInfo.InvariantCulture);
            Assert.DoesNotContain("e", wire, StringComparison.OrdinalIgnoreCase);
            Assert.True(GameBridge.TryParseWorldTime(wire, out var t));
            Assert.Equal((uint)v, t);
        }
    }

    [Fact]
    public void Mod_source_formats_time_now_with_fixed_point_not_tostring()
    {
        // Source guard on the sender. The repo root is found by walking up
        // from the test binary until the VERSION file appears.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "VERSION"))) dir = dir.Parent;
        Assert.NotNull(dir);
        var lua = File.ReadAllText(Path.Combine(dir!.FullName, "kdcmp", "Data", "Scripts", "Startup", "kdcmp.lua"));

        var emit = lua.Split('\n').Where(l => l.Contains("KCD2MP_EmitEvent(\"time_now\"")).ToArray();
        Assert.Single(emit);
        Assert.Contains("string.format(\"%.0f\"", emit[0]);
        Assert.DoesNotContain("tostring(", emit[0]);

        // The other integer-parsed event field built from a number (WO-104
        // Phase 0 audit): the dice wager on invite_send.
        var wager = lua.Split('\n').Where(l => l.Contains("kindStr == \"dice\" then payload = payload")).ToArray();
        Assert.Single(wager);
        Assert.Contains("string.format(\"%.0f\"", wager[0]);
        Assert.DoesNotContain("tostring(", wager[0]);
    }
}
