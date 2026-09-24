using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;
using KcdMp.Client;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-118: the agent -&gt; DLL frames of the native per-frame writer (0x10-0x15)
/// and the 0x89 status reply. The layouts must match native/KCDMP/npc_drive.cpp
/// (on_samples / parse_bind / on_hold) byte for byte; these tests pin them.
/// Local pipe only -- outside the relay round-trip gate by construction.
/// </summary>
public class NativeNpcCodecTests
{
    private static NativeNpcSample S(string name, byte src = 1, ushort seq = 7) =>
        new(src, name, 1.5f, -2.25f, 100.125f, 0.5f, 0x04, seq, 123456u, 987654321012L);

    [Fact]
    public void Samples_layout_matches_the_dll_parser()
    {
        var b = NativeNpcCodec.BuildSamples(new[] { S("ttkc_man_22"), S("x", src: 3, seq: 65535) });
        Assert.Equal(2, b[0]);
        int o = 1;
        Assert.Equal(1, b[o]); Assert.Equal(11, b[o + 1]); o += 2;
        Assert.Equal("ttkc_man_22", Encoding.UTF8.GetString(b, o, 11)); o += 11;
        Assert.Equal(1.5f, BinaryPrimitives.ReadSingleLittleEndian(b.AsSpan(o))); o += 4;
        Assert.Equal(-2.25f, BinaryPrimitives.ReadSingleLittleEndian(b.AsSpan(o))); o += 4;
        Assert.Equal(100.125f, BinaryPrimitives.ReadSingleLittleEndian(b.AsSpan(o))); o += 4;
        Assert.Equal(0.5f, BinaryPrimitives.ReadSingleLittleEndian(b.AsSpan(o))); o += 4;
        Assert.Equal(0x04, b[o]); o += 1;
        Assert.Equal((ushort)7, BinaryPrimitives.ReadUInt16LittleEndian(b.AsSpan(o))); o += 2;
        Assert.Equal(123456u, BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(o))); o += 4;
        Assert.Equal(987654321012L, BinaryPrimitives.ReadInt64LittleEndian(b.AsSpan(o))); o += 8;
        Assert.Equal(3, b[o]); Assert.Equal(1, b[o + 1]);
        Assert.Equal(1 + NativeNpcCodec.SampleSize("ttkc_man_22") + NativeNpcCodec.SampleSize("x"), b.Length);
        Assert.Equal(2 + 11 + 16 + 1 + 2 + 4 + 8, NativeNpcCodec.SampleSize("ttkc_man_22"));
    }

    [Fact]
    public void Batching_stays_under_the_dll_cap_and_255_entries()
    {
        var pending = new List<NativeNpcSample>();
        for (int i = 0; i < 600; i++) pending.Add(S("npc_with_a_long_name_" + i));
        var batch = new List<NativeNpcSample>();
        int total = 0, frames = 0;
        while (pending.Count > 0)
        {
            int n = NativeNpcCodec.TakeBatch(pending, batch);
            Assert.True(n > 0);
            var payload = NativeNpcCodec.BuildSamples(batch);
            Assert.True(payload.Length <= NativeNpcCodec.TargetSamplesPayload, $"payload {payload.Length}");
            Assert.True(payload.Length <= NativeNpcCodec.MaxSamplesPayload);
            Assert.True(n <= 255);
            pending.RemoveRange(0, n);
            total += n; frames++;
        }
        Assert.Equal(600, total);
        Assert.True(frames >= 600 / 255);
    }

    [Fact]
    public void Bind_layout_matches_parse_bind()
    {
        var b = NativeNpcCodec.BuildBind(true, 0x0D00AB, 0x05000000000001DCUL, 1f, 2f, 3f, 120, "ttkc_woman_2");
        Assert.Equal(28 + 12, b.Length);
        Assert.Equal(1, b[0]);
        Assert.Equal(0x0D00ABu, BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(1)));
        Assert.Equal(0x05000000000001DCUL, BinaryPrimitives.ReadUInt64LittleEndian(b.AsSpan(5)));
        Assert.Equal(1f, BinaryPrimitives.ReadSingleLittleEndian(b.AsSpan(13)));
        Assert.Equal(2f, BinaryPrimitives.ReadSingleLittleEndian(b.AsSpan(17)));
        Assert.Equal(3f, BinaryPrimitives.ReadSingleLittleEndian(b.AsSpan(21)));
        Assert.Equal((ushort)120, BinaryPrimitives.ReadUInt16LittleEndian(b.AsSpan(25)));
        Assert.Equal(12, b[27]);
        Assert.Equal("ttkc_woman_2", Encoding.UTF8.GetString(b, 28, 12));
        var off = NativeNpcCodec.BuildBind(false, 0, 0, 0, 0, 0, 0, "a");
        Assert.Equal(0, off[0]);
    }

    [Fact]
    public void Hold_and_trace_layouts()
    {
        var h = NativeNpcCodec.BuildHold("abc", 900);
        Assert.Equal(new byte[] { 0x84, 0x03, 3, (byte)'a', (byte)'b', (byte)'c' }, h);
        var t = NativeNpcCodec.BuildTrace("abc", 10);
        Assert.Equal(new byte[] { 10, 0, 3, (byte)'a', (byte)'b', (byte)'c' }, t);
    }

    [Fact]
    public void Names_outside_1_to_63_bytes_are_refused()
    {
        Assert.Throws<System.ArgumentException>(() => NativeNpcCodec.BuildHold("", 1));
        Assert.Throws<System.ArgumentException>(() => NativeNpcCodec.BuildHold(new string('a', 64), 1));
        Assert.Throws<System.ArgumentException>(() => NativeNpcCodec.BuildBind(true, 1, 0, 0, 0, 0, 1, new string('a', 64)));
    }

    [Fact]
    public void Status_parses_the_24_byte_reply()
    {
        var b = new byte[24];
        b[0] = 1; b[1] = 9; b[2] = 1; b[3] = 0;
        BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(4), 12);
        BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(6), 11);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(8), 5000);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(12), 60000);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(16), 3);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(20), 70000);
        Assert.True(NativeNpcCodec.TryParseStatus(b, out var st));
        Assert.Equal(new NativeNpcStatus(true, false, 12, 11, 5000, 60000, 3, 70000), st);
        Assert.False(NativeNpcCodec.TryParseStatus(new byte[23], out _));
        b[0] = 0;
        Assert.False(NativeNpcCodec.TryParseStatus(b, out _));
        Assert.False(NativeNpcCodec.TryParseStatus(null, out _));
    }

    [Fact]
    public void Reason_tags_mirror_the_native_enum()
    {
        Assert.Equal("ok", NativeNpcCodec.ReasonTag((byte)NativeNpcReason.Ok));
        Assert.Equal("wuid-mismatch", NativeNpcCodec.ReasonTag((byte)NativeNpcReason.WuidMismatch));
        Assert.Equal("not-living", NativeNpcCodec.ReasonTag((byte)NativeNpcReason.NotLiving));
        Assert.Equal("entity-gone", NativeNpcCodec.ReasonTag((byte)NativeNpcReason.EntityGone));
        Assert.Equal("pipe-closed", NativeNpcCodec.ReasonTag((byte)NativeNpcReason.PipeClosed));
        Assert.Equal("no-answer", NativeNpcCodec.ReasonTag(201));
    }
}
