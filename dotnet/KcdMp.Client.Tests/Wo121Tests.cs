using System.Buffers.Binary;
using System.IO.Compression;
using System.Xml.Linq;
using KcdMp.Client;
using KcdMp.Wire;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>WO-121: the v8 codecs the agent owns (pipe and wire).</summary>
public class Wo121Tests
{
    private static readonly BodyState2 St = new(305, -12, BodyState2Bits.CombatMode | BodyState2Bits.Crouched,
        WireZone.UpperLeft, WireGuardStance.Left, WireZone.Lower, 0, 0, 0);

    [Fact]
    public void Avatar_sample_carries_its_state_block_behind_flag_0x80()
    {
        var plain = new NativeNpcSample(3, "kcd2mp_3", 1, 2, 3, 0.5f, 0x10, 7, 99, 12345);
        var withSt = plain with { State2 = St };
        Assert.Equal(NativeNpcCodec.SampleSize(plain) + BodyState2.Len, NativeNpcCodec.SampleSize(withSt));
        var b = NativeNpcCodec.BuildSamples(new[] { withSt, plain });
        int o = 1 + 2 + "kcd2mp_3".Length + 16;
        Assert.Equal(0x10 | NativeNpcCodec.FlagState2, b[o]);                     // riding bit kept, state bit set
        Assert.Equal(St, BodyState2.Read(b.AsSpan(o + 1 + 2 + 4 + 8)));
        int o2 = 1 + NativeNpcCodec.SampleSize(withSt) + 2 + "kcd2mp_3".Length + 16;
        Assert.Equal(0x10, b[o2]);                                                // no state: bit clear
        Assert.Equal(b.Length, 1 + NativeNpcCodec.SampleSize(withSt) + NativeNpcCodec.SampleSize(plain));
    }

    [Fact]
    public void A_wire_npc_flag_can_never_claim_a_state_block()
    {
        // A peer setting the top NpcState bit must not make the DLL expect 12
        // bytes that are not there: the builder only sets it from State2.
        var s = new NativeNpcSample(1, "ttkc_man_5", 0, 0, 0, 0, 0xFF, 1, 1, 1);
        var b = NativeNpcCodec.BuildSamples(new[] { s });
        Assert.Equal(0x7F, b[1 + 2 + "ttkc_man_5".Length + 16]);
    }

    [Fact]
    public void Local_state_v8_reply_parses_the_state_block_and_v7_still_parses()
    {
        var body = new byte[LocalStateCodec.LenV8];
        body[0] = 1; body[1] = 9;
        BinaryPrimitives.WriteSingleLittleEndian(body.AsSpan(11), 10f);
        body[LocalStateCodec.Len] = 1;
        St.Write(body.AsSpan(LocalStateCodec.Len + 1));
        Assert.True(LocalStateCodec.TryParse(body, out var st, out _));
        Assert.Equal(St, st.State2);
        Assert.Equal(10f, st.X);
        Assert.True(LocalStateCodec.TryParse(body.AsSpan(0, LocalStateCodec.Len), out var old, out _));
        Assert.Null(old.State2);
        body[LocalStateCodec.Len] = 0;
        Assert.True(LocalStateCodec.TryParse(body, out var none, out _));
        Assert.Null(none.State2);
    }

    [Fact]
    public void Local_action_frame_parses_player_and_npc_forms()
    {
        var g = Guid.Parse("c2af142a-5e9c-33e5-b5d1-dba0277a2540");
        byte[] Frame(uint eid, string name)
        {
            var n = System.Text.Encoding.UTF8.GetBytes(name);
            var b = new byte[27 + n.Length];
            b[0] = (byte)ActionKind.Attack; b[1] = (byte)ActionPhase.Commit; b[2] = 1; b[3] = 5; b[4] = 0; b[5] = 0;
            g.TryWriteBytes(b.AsSpan(6));
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(22), eid);
            b[26] = (byte)n.Length; n.CopyTo(b, 27);
            return b;
        }
        Assert.True(LocalActionFrame.TryParse(Frame(0, ""), out var p));
        Assert.Equal(0u, p.Eid); Assert.Equal(g, p.Row); Assert.Equal(5, p.ZoneTableId);
        Assert.Equal(WireZone.Lower, Protocol.ZoneFromTableId(p.ZoneTableId));
        Assert.True(LocalActionFrame.TryParse(Frame(0x8089a, "ttkc_man_5"), out var n2));
        Assert.Equal("ttkc_man_5", n2.Name);
        var bad = Frame(0, "x"); bad[26] = 5;
        Assert.False(LocalActionFrame.TryParse(bad, out _));
    }

    [Fact]
    public void Row_event_round_trips_and_refuses_unauthored_names()
    {
        var g = Guid.NewGuid();
        var e = new RowEvent(77u, RowEvent.FlagPerfect, g, "ttkc_man_5");
        Assert.True(RowEvent.TryFromBytes(e.ToBytes(), out var back));
        Assert.Equal(e, back);
        var bad = new RowEvent(1, 0, g, "x\");os.exit(").ToBytes();
        Assert.False(RowEvent.TryFromBytes(bad, out _));
        Assert.True(RowEvent.TryFromBytes(new RowEvent(1, 0, g, "").ToBytes(), out var empty));
        Assert.Equal("", empty.Name);
    }

    [Fact]
    public void Player_hit_v8_decode_refuses_absurd_damage()
    {
        var up = new PlayerHitV8(2, 1f, 5000f, 0, 0).BuildUp();
        var down = new byte[PlayerHitV8.DownLen];
        down[0] = 1; Buffer.BlockCopy(up, 3, down, 1, PlayerHitV8.UpLen);
        Assert.False(PlayerHitV8.TryDecodeDown(down, out _, out _));
        BinaryPrimitives.WriteSingleLittleEndian(down.AsSpan(6), float.NaN);
        Assert.False(PlayerHitV8.TryDecodeDown(down, out _, out _));
    }

    // ---- against this machine's install, when there is one ----------------

    private static string? Pak() => WeaponSwingCatalog.FindTablesPak();

    [Fact]
    public void Zone_and_stance_tables_match_the_shipped_names()
    {
        string? pak = Pak();
        if (pak is null) return;   // no install on this machine: nothing to compare against
        using var zip = ZipFile.OpenRead(pak);
        XDocument Load(string e) { using var s = zip.GetEntry(e)!.Open(); return XDocument.Load(s); }
        var zones = Load("Libs/Tables/combat/combat_zone.xml").Descendants("combat_zone")
            .ToDictionary(x => (int)x.Attribute("combat_zone_id")!, x => (string)x.Attribute("combat_zone_name")!);
        foreach (var (id, name, _) in Protocol.ZoneTable) Assert.Equal(name, zones[id]);
        var stances = Load("Libs/Tables/combat/combat_guard_stance.xml").Descendants("combat_guard_stance")
            .ToDictionary(x => (int)x.Attribute("combat_guard_stance_id")!, x => (string)x.Attribute("combat_guard_stance_name")!);
        foreach (var (id, name, _) in Protocol.GuardStanceTable) Assert.Equal(name, stances[id]);
    }

    [Fact]
    public void Row_catalog_holds_the_live_captured_rows()
    {
        string? pak = Pak();
        if (pak is null) return;
        var c = ActionRowCatalog.LoadFrom(pak);
        Assert.True(c.Count > 500);
        // Captured live on Henry, WO-121 session 1 (descriptor +0x84).
        Assert.True(c.TryGet(Guid.Parse("1a78ac7e-b10f-315b-bbed-6e688f3050eb"), out var slash));
        Assert.Equal("CombatAttackGen", slash.Fragment);
        Assert.Contains("aZ2", slash.Tags);
        Assert.Contains("slash", slash.Tags);
        Assert.True(c.TryGet(Guid.Parse("c2af142a-5e9c-33e5-b5d1-dba0277a2540"), out var stab));
        Assert.Contains("aZ5", stab.Tags);
        Assert.Equal("CombatAttackGen, " + stab.Tags, stab.Spec);
    }
}
