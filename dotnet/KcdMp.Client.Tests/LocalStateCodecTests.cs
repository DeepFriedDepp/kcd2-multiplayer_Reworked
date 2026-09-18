using System.Buffers.Binary;
using KcdMp.Client;
using KcdMp.Wire;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-102 Phase 1: the 0x86 LocalState reply decoder and the cadence stats.
/// Codec tests prove the parse, not the wire (docs/WO-101-findings.md S0.6);
/// the Position packet this feeds is unchanged in shape, so the WO-101 relay
/// round-trip gate covers the wire half.
/// </summary>
public class LocalStateCodecTests
{
    private static byte[] Reply(bool ok, byte refuse, ulong frame, float x, float y, float z, float rot,
                                byte flags, bool haveBody, byte pace = 2, byte dir = 1, byte stance = 0,
                                ushort speed = 150, byte unknown = 0, byte haveCombat = 1,
                                sbyte ic = 1, sbyte zone = 3, sbyte atk = 2, byte prepared = 1)
    {
        var b = new byte[LocalStateCodec.Len];
        b[0] = (byte)(ok ? 1 : 0); b[1] = 7; b[2] = refuse;
        BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(3), frame);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(11), x);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(15), y);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(19), z);
        BinaryPrimitives.WriteSingleLittleEndian(b.AsSpan(23), rot);
        b[27] = flags; b[28] = (byte)(haveBody ? 1 : 0);
        b[29] = pace; b[30] = dir; b[31] = stance;
        BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(32), speed);
        b[34] = unknown; b[35] = haveCombat; b[36] = (byte)ic; b[37] = (byte)zone; b[38] = (byte)atk; b[39] = prepared;
        return b;
    }

    [Fact]
    public void Success_with_body_parses_every_field()
    {
        var body = Reply(true, 0, 123456789UL, 2340.12f, 2047.04f, 109.17f, 1.68f, flags: 0x01, haveBody: true);
        Assert.True(LocalStateCodec.TryParse(body, out var st, out var why));
        Assert.Equal(LocalStateRefuse.Ok, why);
        Assert.Equal(123456789UL, st.Frame);
        Assert.Equal(2340.12f, st.X); Assert.Equal(2047.04f, st.Y); Assert.Equal(109.17f, st.Z); Assert.Equal(1.68f, st.RotZ);
        Assert.True(st.IsRiding);
        Assert.NotNull(st.Body);
        var lb = st.Body!.Value;
        Assert.Equal(BodyPace.Run, lb.Body.Pace); Assert.Equal(BodyDir.Forward, lb.Body.Dir);
        Assert.Equal(BodyStance.Upright, lb.Body.Stance); Assert.Equal((ushort)150, lb.Body.AnimSpeedCenti);
        Assert.True(lb.HaveCombat); Assert.Equal((sbyte)1, lb.InputClass); Assert.Equal((sbyte)3, lb.Zone);
        Assert.Equal((sbyte)2, lb.AttackType); Assert.True(lb.Prepared);
        Assert.Equal(0, LocalStateCodec.UnknownTags(body));
    }

    [Fact]
    public void Success_without_body_leaves_body_null()
    {
        var body = Reply(true, 0, 5, 1, 2, 3, 0.5f, flags: 0, haveBody: false);
        Assert.True(LocalStateCodec.TryParse(body, out var st, out _));
        Assert.Null(st.Body);
        Assert.False(st.IsRiding);
    }

    [Fact]
    public void Refusal_carries_its_reason_and_parses_nothing()
    {
        var body = Reply(false, (byte)LocalStateRefuse.EntityHopUnmapped, 0, 0, 0, 0, 0, 0, false);
        Assert.False(LocalStateCodec.TryParse(body, out var st, out var why));
        Assert.Equal(LocalStateRefuse.EntityHopUnmapped, why);
        Assert.Equal(default, st);
    }

    [Fact]
    public void Short_refusal_frame_is_still_classified()
    {
        // A future DLL that answers a refusal with only [ok][seq][refuse].
        Assert.False(LocalStateCodec.TryParse(new byte[] { 0, 9, (byte)LocalStateRefuse.NoPlayerActor }, out _, out var why));
        Assert.Equal(LocalStateRefuse.NoPlayerActor, why);
    }

    [Fact]
    public void Non_finite_coordinate_is_refused_not_forwarded()
    {
        var body = Reply(true, 0, 5, float.NaN, 2, 3, 0.5f, 0, false);
        Assert.False(LocalStateCodec.TryParse(body, out _, out var why));
        Assert.Equal(LocalStateRefuse.NonFinite, why);
    }

    [Fact]
    public void Truncated_success_frame_is_refused()
    {
        var body = Reply(true, 0, 5, 1, 2, 3, 0.5f, 0, true)[..30];
        Assert.False(LocalStateCodec.TryParse(body, out _, out var why));
        Assert.Equal(LocalStateRefuse.Unknown, why);
    }

    [Fact]
    public void Body_block_matches_the_0x85_layout_byte_for_byte()
    {
        // The 0x85 reply is [ok][seq][pace][dir][stance][speed:2][unknown][haveCombat][ic][zone][atk][prepared];
        // the 0x86 body block (bytes 29..39) is that reply's bytes 2..12. Same numbers must decode alike.
        var body = Reply(true, 0, 1, 0, 0, 0, 0, 0, true, pace: 3, dir: 2, stance: 4, speed: 1234, unknown: 2, haveCombat: 1, ic: 0, zone: 5, atk: 7, prepared: 0);
        Assert.True(LocalStateCodec.TryParse(body, out var st, out _));
        var lb = st.Body!.Value;
        Assert.Equal(BodyPace.Sprint, lb.Body.Pace); Assert.Equal(BodyDir.Backward, lb.Body.Dir);
        Assert.Equal(BodyStance.Horse, lb.Body.Stance); Assert.Equal((ushort)1234, lb.Body.AnimSpeedCenti);
        Assert.Equal(2, LocalStateCodec.UnknownTags(body));
        Assert.Equal((sbyte)0, lb.InputClass); Assert.Equal((sbyte)5, lb.Zone); Assert.Equal((sbyte)7, lb.AttackType); Assert.False(lb.Prepared);
    }
}

public class CadenceStatsTests
{
    [Fact]
    public void Even_cadence_reports_tight_percentiles()
    {
        var c = new CadenceStats();
        for (int i = 0; i <= 100; i++) c.Sample(i * 16.0);
        string? line = c.Report("native", 1600.0);
        Assert.NotNull(line);
        Assert.Contains("path=native n=100 mean_ms=16.0 p50_ms=16 p95_ms=16 max_ms=16", line);
        Assert.Contains("window_s=2", line);   // 1600 ms from the first sample at 0 -> rounds to 2
        Assert.Null(c.Report("native", 1700.0));   // window reset, nothing new
        Assert.Contains("n=100", c.Summary("native"));
    }

    [Fact]
    public void Spread_shows_in_p95_and_max_but_not_p50()
    {
        var c = new CadenceStats();
        double t = 0;
        for (int i = 0; i < 95; i++) { t += 50; c.Sample(t); }
        for (int i = 0; i < 5; i++) { t += 200; c.Sample(t); }
        string line = c.Report("log", t)!;
        Assert.Contains("n=99", line);           // 100 samples -> 99 intervals
        Assert.Contains("p50_ms=50", line);
        Assert.Contains("p95_ms=200", line);
        Assert.Contains("max_ms=200", line);
    }

    [Fact]
    public void Break_does_not_count_the_gap()
    {
        var c = new CadenceStats();
        c.Sample(0); c.Sample(20);
        c.Break();
        c.Sample(5000); c.Sample(5020);
        string line = c.Report("log", 5020)!;
        Assert.Contains("n=2", line);
        Assert.Contains("max_ms=20", line);
    }

    [Fact]
    public void Percentile_on_empty_is_minus_one_and_reset_clears_lifetime()
    {
        Assert.Equal(-1, CadenceStats.Percentile(new int[10], 0, 0.5));
        var c = new CadenceStats();
        c.Sample(0); c.Sample(10);
        c.Reset();
        Assert.Null(c.Summary("native"));
        Assert.Null(c.Report("native", 100));
    }

    [Fact]
    public void Intervals_beyond_the_range_fold_into_the_last_bucket()
    {
        var c = new CadenceStats();
        c.Sample(0); c.Sample(9000);
        string line = c.Report("log", 9000)!;
        Assert.Contains("p50_ms=>=2000", line);
        Assert.Contains("max_ms=9000", line);
    }
}
