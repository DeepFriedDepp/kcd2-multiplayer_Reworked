using System.Buffers.Binary;
using System.Linq;
using KcdMp.Client;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-102.5 Phase 2: the 0x87 NpcScanResult reply decoder. Codec tests prove
/// the parse, not the wire -- this reply travels agent&lt;-&gt;DLL over the local
/// pipe, not agent&lt;-&gt;relay, so it is outside the WO-101 relay round-trip
/// gate's scope by construction.
/// </summary>
public class NpcScanCodecTests
{
    private static byte[] Header(bool ok, byte refuse, bool truncated, uint totalWalked, uint nameRejects, ushort count)
    {
        var b = new byte[NpcScanCodec.HeaderLen];
        b[0] = (byte)(ok ? 1 : 0); b[1] = 3; b[2] = refuse; b[3] = (byte)(truncated ? 1 : 0);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(4), totalWalked);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(8), nameRejects);
        BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(12), count);
        return b;
    }

    private static byte[] Entry(string name, float x, float y, float z, float yaw, bool isHorse)
    {
        var nameBytes = System.Text.Encoding.ASCII.GetBytes(name);
        var e = new byte[1 + nameBytes.Length + 17];
        e[0] = (byte)nameBytes.Length;
        nameBytes.CopyTo(e.AsSpan(1));
        int o = 1 + nameBytes.Length;
        BinaryPrimitives.WriteSingleLittleEndian(e.AsSpan(o), x); o += 4;
        BinaryPrimitives.WriteSingleLittleEndian(e.AsSpan(o), y); o += 4;
        BinaryPrimitives.WriteSingleLittleEndian(e.AsSpan(o), z); o += 4;
        BinaryPrimitives.WriteSingleLittleEndian(e.AsSpan(o), yaw); o += 4;
        e[o] = (byte)(isHorse ? 1 : 0);
        return e;
    }

    [Fact]
    public void Success_with_two_entries_parses_every_field()
    {
        var body = Header(true, 0, truncated: false, totalWalked: 240, nameRejects: 1, count: 2)
            .Concat(Entry("ttkc_man_2", 100.5f, -20.25f, 3.0f, 1.57f, isHorse: false))
            .Concat(Entry("ttkc_horse_3", 5.0f, 6.0f, 0.0f, 0.0f, isHorse: true))
            .ToArray();

        Assert.True(NpcScanCodec.TryParse(body, out var res, out var why));
        Assert.Equal(NpcScanRefuse.Ok, why);
        Assert.False(res.Truncated);
        Assert.Equal(240u, res.TotalWalked);
        Assert.Equal(1u, res.NameRejects);
        Assert.Equal(2, res.Entries.Count);
        Assert.Equal(new NpcScanEntry("ttkc_man_2", 100.5f, -20.25f, 3.0f, 1.57f, false), res.Entries[0]);
        Assert.Equal(new NpcScanEntry("ttkc_horse_3", 5.0f, 6.0f, 0.0f, 0.0f, true), res.Entries[1]);
    }

    [Fact]
    public void Zero_entries_parses_to_an_empty_list()
    {
        var body = Header(true, 0, false, 12, 0, 0);
        Assert.True(NpcScanCodec.TryParse(body, out var res, out _));
        Assert.Empty(res.Entries);
        Assert.Equal(12u, res.TotalWalked);
    }

    [Fact]
    public void Truncated_flag_survives_the_round_trip()
    {
        var body = Header(true, 0, truncated: true, totalWalked: 900, nameRejects: 0, count: 0);
        Assert.True(NpcScanCodec.TryParse(body, out var res, out _));
        Assert.True(res.Truncated);
    }

    [Fact]
    public void Refusal_carries_its_reason_and_parses_nothing()
    {
        var body = Header(false, (byte)NpcScanRefuse.GEnvUnmapped, false, 0, 0, 0);
        Assert.False(NpcScanCodec.TryParse(body, out var res, out var why));
        Assert.Equal(NpcScanRefuse.GEnvUnmapped, why);
        Assert.Equal(default, res);
    }

    [Fact]
    public void Short_header_is_classified_unknown()
    {
        Assert.False(NpcScanCodec.TryParse(new byte[] { 1, 3, 0 }, out _, out var why));
        Assert.Equal(NpcScanRefuse.Unknown, why);
    }

    [Fact]
    public void Truncated_entry_bytes_fail_closed_rather_than_reading_past_the_buffer()
    {
        var full = Header(true, 0, false, 10, 0, 1)
            .Concat(Entry("ttkc_man_5", 1, 2, 3, 4, false))
            .ToArray();
        var body = full[..^5];   // cut into the last entry's tail
        Assert.False(NpcScanCodec.TryParse(body, out _, out _));
    }
}
