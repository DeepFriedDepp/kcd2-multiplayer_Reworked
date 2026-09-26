using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-122 Phase 5: the ported save tools against SYNTHETIC .whs files built
/// here. No real save is ever used as a fixture: every real save header
/// carries the writing machine's account name.
/// </summary>
public class WhsSaveTests
{
    // ---------------------------------------------------------------- fixture builder

    private static byte[] Tlv(ushort tag, byte[] payload)
    {
        var b = new byte[6 + payload.Length];
        BinaryPrimitives.WriteUInt16LittleEndian(b, tag);
        BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(2), (uint)payload.Length);
        payload.CopyTo(b, 6);
        return b;
    }
    private static byte[] Cat(params byte[][] parts) => parts.SelectMany(p => p).ToArray();
    private static byte[] U32(uint v) { var b = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(b, v); return b; }
    private static byte[] G(string guid) => new Guid(guid).ToByteArray();   // bytes_le, as the save stores it

    private const string Henry = WhsSave.HenrySoul;
    private const string Shared = "11111111-2222-3333-4444-555555555555";
    private const string Npc = "aaaaaaaa-0000-0000-0000-000000000001";
    private const string Apple = "0a0a0a0a-0000-0000-0000-00000000a001";
    private const string Letter = "0b0b0b0b-0000-0000-0000-00000000b002";   // a quest-item class
    private const string Money = "5ef63059-322e-4e1b-abe8-926e100c770e";

    private sealed record Item(string Inst, string Cls, uint Amount = 1, uint Flags = 0);

    private sealed class Spec
    {
        public string Build = "1.5.5-release_1_5";
        public uint Story = 1000, Strength = 500;
        public byte[] Renown = [1, 2, 3, 4];
        public List<Item> Items = [];
        public List<string> Equipped = [];
        public List<string> Perks = [];
        public bool Field1300;
        public List<(string Owner, string Key)> Keys = [];
        public byte Side = 0;   // stamps the side blocks so host and joiner differ
        public string World = "host-world";
        public byte NpcMood = 7;
    }

    private static byte[] ItemRec(Item it)
    {
        var p = Cat(G(it.Inst), U32(it.Flags), G(it.Cls));
        if (it.Amount != 1) p = Cat(p, Tlv(0x0000, U32(it.Amount - 1)));
        return Tlv(0x0001, p);
    }

    private static byte[] HenryRecord(Spec s)
    {
        var stats = Cat(U32(0), U32(s.Strength), U32(8), U32(s.Story), U32(0xFFFFFFFF), U32(0));
        var skills = Cat(U32(2), U32(77), U32(0xFFFFFFFF), U32(0));
        var states = new byte[24];
        BinaryPrimitives.WriteSingleLittleEndian(states, 55.5f + s.Side);
        var perks = Cat(s.Perks.Select(pk => Tlv(0x03D8, Tlv(0x137E, Tlv(0x1379, Cat(G(pk), new byte[4]))))).ToArray());
        var core = Cat(Tlv(0x1385, stats), Tlv(0x138D, skills), Tlv(0x138B, states), Tlv(0x137E, perks.Length > 0 ? perks : Tlv(0x0001, [9])));
        var buffs = Cat(U32(1), Tlv(0x0001, Cat(new byte[8], G("cccccccc-0000-0000-0000-00000000c003"), [s.Side])));
        var main = Cat(Tlv(0x0927, core), Tlv(0x0928, buffs));
        var list = Cat(new[] { Tlv(0x0000, G("dddddddd-0000-0000-0000-00000000d004")) }.Concat(s.Items.Select(ItemRec)).ToArray());
        var eq = Tlv(0x0001, Tlv(0x0000, Cat(s.Equipped.Select(G).ToArray()).Length > 0 ? Cat(s.Equipped.Select(G).ToArray()) : new byte[16]));
        var inv = Cat(Tlv(0x0007, list), Tlv(0x0006, eq));
        var name = Cat(Encoding.Latin1.GetBytes("player_henry\0"), BitConverter.GetBytes(0x7777UL));
        var fields = Cat(Tlv(0x12F9, name), Tlv(0x12FB, main), Tlv(0x12FF, s.Renown), Tlv(0x1301, inv));
        if (s.Field1300) fields = Cat(fields, Tlv(0x1300, G("eeeeeeee-0000-0000-0000-00000000e005")));
        return Tlv(0x115E, Cat(G(Henry), G(Shared), fields));
    }

    private static byte[] NpcRecord(Spec s) =>
        Tlv(0x115E, Cat(G(Npc), G(Shared), Tlv(0x12F9, Cat(Encoding.Latin1.GetBytes("ttkc_man_1\0"), new byte[8])), Tlv(0x12FF, [s.NpcMood, 0, 0, 0])));

    private static byte[] Stream(Spec s)
    {
        var keys = Cat(new[] { new byte[8] { 1, 0, 0, 0, s.Side, 0, 0, 0 } }
            .Concat(s.Keys.Select(k => Tlv(0x05AD, Cat(G(k.Owner), new byte[9], G(k.Key))))).ToArray());
        var souls = Tlv(0x1161, Cat(NpcRecord(s), HenryRecord(s)));
        var rpg = Tlv(0x7308, Cat(Tlv(0x3529, Cat(Tlv(0x1160, new byte[4]), souls)), Tlv(0x352C, Encoding.ASCII.GetBytes(s.World)),
                                  Tlv(0x352D, [0x2D, s.Side, 1, 1, 1, 1, 1]), Tlv(0x352E, [0x2E, s.Side, 2, 2, 2, 2, 2])));
        var ent = Tlv(0x7302, Cat(Tlv(0x000A, Encoding.ASCII.GetBytes(s.World + "-qim")), Tlv(0x000B, keys)));
        var pm = Tlv(0x7309, Cat(Tlv(0x0000, [0x90, s.Side, 3, 3, 3, 3, 3]), Tlv(0x0001, [0x91, s.Side, 4, 4, 4, 4, 4]), Tlv(0x0002, Encoding.ASCII.GetBytes(s.World))));
        var gui = Tlv(0x7301, [0x71, s.Side, 5, 5, 5, 5, 5]);
        var cry = Tlv(0x01F7, Cat(Tlv(0x20A9, Cat(Encoding.ASCII.GetBytes("GameState\0"), Encoding.ASCII.GetBytes(s.World))),
                                  Tlv(0x20A7, Cat(Encoding.ASCII.GetBytes("level\0"), Encoding.ASCII.GetBytes("trosecko")))));
        var phaseB = Tlv(0x01F8, Cat(ent, rpg, pm, gui));
        var phaseC = Tlv(0x01F9, Cat(Tlv(0x7302, Tlv(0x0002, [0x72, s.Side, 6, 6, 6, 6, 6])), Tlv(0x7305, Encoding.ASCII.GetBytes(s.World + "-weather"))));
        var body = Tlv(0x01F4, Cat(Tlv(0x01FB, U32(0xB0D1)), Tlv(0x01F6, Tlv(0x730A, Encoding.ASCII.GetBytes(s.World + "-quests"))), cry, phaseB, phaseC));
        // pad the world with a large filler so the stream spans several 32 KB blocks
        var filler = Tlv(0x01F5, Enumerable.Range(0, 70000).Select(i => (byte)(i * 7 + s.World.Length)).ToArray());
        return Cat(U32(23), filler, body, Tlv(0x01FA, []));
    }

    private static byte[] File(Spec s)
    {
        var desc = Encoding.UTF8.GetBytes($"<SaveGame SaveType=\"QuickSave\" SaveId=\"7\" LevelName=\"trosecko\" BuildInfo=\"{s.Build}\" GameMode=\"normal\" World=\"{s.World}\"/>");
        var tail = Enumerable.Range(0, 44).Select(i => (byte)(i == 0 ? 0x5A : 0)).ToArray();
        return WhsSave.Deflate(desc, Stream(s), tail);
    }

    /// <summary>WO-123: a valid synthetic save for the transfer tests (verifies; never a real file).</summary>
    internal static byte[] SyntheticSave(string world = "host-world") => File(new Spec { World = world });

    private static readonly Dictionary<string, string> Quest = new() { [Letter] = "loveLetter" };

    private static (Spec Host, Spec Join) Pair()
    {
        var host = new Spec
        {
            Story = 4242, Strength = 111, Renown = Enumerable.Range(0, 81).Select(i => (byte)i).ToArray(), World = "host-world",
            Items = [new("10000000-0000-0000-0000-000000000001", Apple, 3), new("10000000-0000-0000-0000-000000000002", Letter),
                     new("10000000-0000-0000-0000-000000000003", Money, 79)],
            Keys = [(Henry, "10000000-0000-0000-0000-000000000001"), (Npc, "90000000-0000-0000-0000-000000000009")],
            Side = 1, NpcMood = 9,
        };
        var join = new Spec
        {
            Story = 9999, Strength = 222, Renown = [1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1], World = "joiner-world", Field1300 = true,
            Items = [new("20000000-0000-0000-0000-000000000001", Apple, 5), new("20000000-0000-0000-0000-000000000002", Letter, 1, 2),
                     new("20000000-0000-0000-0000-000000000003", Money, 151), new("20000000-0000-0000-0000-000000000004", Apple)],
            Equipped = ["20000000-0000-0000-0000-000000000004"],
            Perks = ["30000000-0000-0000-0000-000000000001", "30000000-0000-0000-0000-000000000002"],
            Keys = [(Henry, "20000000-0000-0000-0000-000000000003"), (Henry, "99999999-0000-0000-0000-000000000000")],
            Side = 2, NpcMood = 3,
        };
        return (host, join);
    }

    // ---------------------------------------------------------------- container + verify

    [Fact]
    public void Deflate_then_inflate_round_trips_and_verifies()
    {
        var s = new Spec();
        var f = File(s);
        var c = WhsSave.Inflate(f);
        Assert.Equal(Stream(s), c.Raw);
        Assert.True(WhsSave.VerifyFooter(f).Ok);
        var v = WhsSave.Verify(f);
        Assert.True(v.Ok, v.Reason);
        Assert.True(v.HenryFound);
        // several 32 KB blocks, all but the last exactly 32 KB raw
        int dl = BinaryPrimitives.ReadInt32LittleEndian(f.AsSpan(4));
        int p = 8 + dl, blocks = 0;
        var raws = new List<int>();
        while (p + 8 <= f.Length - 64)
        {
            int cl = BinaryPrimitives.ReadInt32LittleEndian(f.AsSpan(p));
            raws.Add(BinaryPrimitives.ReadInt32LittleEndian(f.AsSpan(p + 4)));
            p += 8 + cl; blocks++;
        }
        Assert.True(blocks >= 3);
        Assert.All(raws.Take(raws.Count - 1), r => Assert.Equal(WhsSave.ChunkRaw, r));
    }

    [Fact]
    public void A_flipped_md5_byte_fails_verify()
    {
        var f = File(new Spec());
        f[^60] ^= 0xFF;
        Assert.False(WhsSave.VerifyFooter(f).Ok);
        var v = WhsSave.Verify(f);
        Assert.False(v.Ok);
        Assert.StartsWith("md5 mismatch", v.Reason);
    }

    [Fact]
    public void A_corrupt_byte_that_still_inflates_is_caught_only_by_the_footer()
    {
        // The game would load this (WO-115 s5): the blocks still inflate.
        var f = File(new Spec());
        f[12] ^= 0x01;   // inside the description
        WhsSave.Inflate(f);
        var v = WhsSave.Verify(f);
        Assert.False(v.Ok);
        Assert.StartsWith("md5 mismatch", v.Reason);
    }

    [Fact]
    public void Truncated_and_foreign_files_fail_verify()
    {
        var f = File(new Spec());
        Assert.False(WhsSave.Verify(f.AsSpan(0, f.Length - 1000).ToArray()).Ok);
        Assert.False(WhsSave.Verify(new byte[100]).Ok);
        Assert.False(WhsSave.Verify(Encoding.ASCII.GetBytes("<not a save at all, just some text padding padding padding padding padding>")).Ok);
    }

    [Fact]
    public void A_block_whose_length_header_lies_fails_framing_even_with_a_valid_footer()
    {
        var desc = Encoding.UTF8.GetBytes("<d/>");
        var f = WhsSave.Deflate(desc, Stream(new Spec()), new byte[44]);
        BinaryPrimitives.WriteInt32LittleEndian(f.AsSpan(8 + desc.Length + 4), WhsSave.ChunkRaw + 1);
        // re-sign, so only the framing is wrong
        using (var md5 = System.Security.Cryptography.IncrementalHash.CreateHash(System.Security.Cryptography.HashAlgorithmName.MD5))
        {
            md5.AppendData(f, 0, f.Length - 64);
            md5.AppendData("0XBP"u8);
            md5.AppendData(new byte[16]);
            md5.AppendData(f, f.Length - 44, 44);
            md5.GetHashAndReset().CopyTo(f, f.Length - 60);
        }
        Assert.True(WhsSave.VerifyFooter(f).Ok);
        var v = WhsSave.Verify(f);
        Assert.False(v.Ok);
        Assert.StartsWith("framing", v.Reason);
    }

    [Fact]
    public void A_stream_without_a_henry_record_fails_verify()
    {
        var raw = Cat(U32(23), Tlv(0x01F4, Tlv(0x01F8, Tlv(0x7308, Tlv(0x3529, Tlv(0x1161, Tlv(0x115E, Cat(G(Npc), G(Shared), Tlv(0x12F9, [0])))))))));
        var f = WhsSave.Deflate(Encoding.UTF8.GetBytes("<d/>"), raw, new byte[44]);
        var v = WhsSave.Verify(f);
        Assert.False(v.Ok);
        Assert.Contains("player_henry", v.Reason);
    }

    // ---------------------------------------------------------------- TLV + leaves

    [Fact]
    public void Children_requires_an_exact_non_empty_parse()
    {
        var two = Cat(Tlv(1, [1, 2]), Tlv(2, []));
        Assert.Equal(2, WhsSave.Children(two, 0, two.Length)!.Count);
        Assert.Null(WhsSave.Children(two, 0, two.Length - 1));
        Assert.Null(WhsSave.Children(two, 0, 0));
        Assert.Null(WhsSave.Children(Cat(two, [0]), 0, two.Length + 1));
    }

    [Fact]
    public void Replace_fixes_every_ancestor_length()
    {
        var raw = Cat(U32(23), Tlv(0x01F4, Cat(Tlv(0x0001, [9]), Tlv(0x0002, Tlv(0x0003, [1, 2, 3])))), Tlv(0x01FA, []));
        var chain = WhsSave.PathNodes(raw, 0x01F4, 0x0002, 0x0003);
        var outRaw = WhsSave.Replace(raw, chain, [7, 7, 7, 7, 7, 7]);
        var n = WhsSave.PathGet(outRaw, 0x01F4, 0x0002, 0x0003)!.Value;
        Assert.Equal([7, 7, 7, 7, 7, 7], WhsSave.Payload(outRaw, n));
        var top = WhsSave.TopLevel(outRaw);
        Assert.Equal(2, top.Count);
        Assert.Equal(raw.Length + 3, outRaw.Length);
        Assert.NotNull(WhsSave.Children(outRaw, top[0].PayloadOff, top[0].End));
    }

    [Fact]
    public void Leaves_key_cryaction_blobs_by_name()
    {
        var leaves = WhsSave.Leaves(Stream(new Spec()));
        Assert.Contains("01f4/01f7/GameState", leaves.Keys);
        Assert.Contains("01f4/01f7/level", leaves.Keys);
        Assert.Contains("01f4/01f8/7308/3529/1161", leaves.Keys);   // the soul list is one leaf
        Assert.DoesNotContain(leaves.Keys, k => k.StartsWith("01f4/01f8/7308/3529/1161/", StringComparison.Ordinal));
    }

    [Fact]
    public void Decode_reads_the_henry_record()
    {
        var (_, j) = Pair();
        var raw = Stream(j);
        var d = WhsSave.DecodePlayerSoul(raw, WhsSave.FindSoul(raw, Henry)!.Value);
        Assert.Equal("player_henry", d.Scalars["name"]);
        Assert.Equal("0x0000000000007777", d.Scalars["entity_guid"]);
        Assert.Equal(9999u, d.StatXp["storyProgress"]);
        Assert.Equal(222u, d.StatXp["strength"]);
        Assert.Equal(4, d.Inventory.Count);
        Assert.Equal("amount=5", d.Inventory[0].Params);
        Assert.Equal("", d.Inventory[3].Params);   // amount 1 is stored as absent
        Assert.Equal("30000000-0000-0000-0000-000000000001,30000000-0000-0000-0000-000000000002", d.Scalars["perks"]);
        Assert.Equal("20000000-0000-0000-0000-000000000004", d.Scalars["equipped_instances"]);
    }

    // ---------------------------------------------------------------- the splice

    [Fact]
    public void Splice_puts_the_joiners_henry_into_the_hosts_world_and_passes_check()
    {
        var (hs, js) = Pair();
        byte[] h = File(hs), j = File(js);
        var res = WhsSave.Splice(h, j, Quest, WhsSave.QuestItemMode.Strip);
        Assert.True(WhsSave.Verify(res.File).Ok);
        Assert.Empty(WhsSave.Check(h, j, res.File, Quest, WhsSave.QuestItemMode.Strip));

        var o = WhsSave.Inflate(res.File);
        Assert.Equal(WhsSave.Inflate(h).DescBytes, o.DescBytes);           // the host's header, byte for byte
        var d = WhsSave.DecodePlayerSoul(o.Raw, WhsSave.FindSoul(o.Raw, Henry)!.Value);
        Assert.Equal(4242u, d.StatXp["storyProgress"]);                      // the host's story stat
        Assert.Equal(222u, d.StatXp["strength"]);                            // the joiner's own stat
        Assert.Equal(new[] { "20000000-0000-0000-0000-000000000001", "20000000-0000-0000-0000-000000000003", "20000000-0000-0000-0000-000000000004" },
                     d.Inventory.Select(i => i.Instance));                   // the joiner's items, quest letter stripped
        Assert.Equal(["loveLetter"], res.Report.QuestItemsRemoved);
        var f = WhsSave.SoulFields(o.Raw, WhsSave.FindSoul(o.Raw, Henry)!.Value);
        Assert.Equal(hs.Renown, WhsSave.Payload(o.Raw, f[0x12FF][0]));      // the host's renown
        Assert.True(f.ContainsKey(0x1300));                                  // 0x1300 carried (the game drops it itself)
        // side blocks are the joiner's; the world is the host's
        Assert.Equal(2, WhsSave.Payload(o.Raw, WhsSave.PathGet(o.Raw, 0x01F4, 0x01F8, 0x7308, 0x352E)!.Value)[1]);
        Assert.Equal(2, WhsSave.Payload(o.Raw, WhsSave.PathGet(o.Raw, 0x01F4, 0x01F9, 0x7302, 0x0002)!.Value)[1]);
        Assert.Equal("host-world", Encoding.ASCII.GetString(WhsSave.Payload(o.Raw, WhsSave.PathGet(o.Raw, 0x01F4, 0x01F8, 0x7308, 0x352C)!.Value)));
        Assert.Equal("host-world-qim", Encoding.ASCII.GetString(WhsSave.Payload(o.Raw, WhsSave.PathGet(o.Raw, 0x01F4, 0x01F8, 0x7302, 0x000A)!.Value)));
        // the other soul is the host's
        var npc = WhsSave.SoulFields(o.Raw, WhsSave.FindSoul(o.Raw, Npc)!.Value);
        Assert.Equal(9, WhsSave.Payload(o.Raw, npc[0x12FF][0])[0]);
    }

    [Fact]
    public void Key_bindings_merge_drops_host_henry_keys_and_adds_joiner_henry_keys()
    {
        var (hs, js) = Pair();
        var res = WhsSave.Splice(File(hs), File(js), Quest, WhsSave.QuestItemMode.Strip);
        Assert.Equal(1, res.Report.KeysHostKept);      // the NPC's key stays
        Assert.Equal(1, res.Report.KeysHostDropped);   // the host Henry's key goes
        Assert.Equal(1, res.Report.KeysJoinerAdded);   // only the one naming a joiner Henry item
        var o = WhsSave.Inflate(res.File).Raw;
        var b = WhsSave.Payload(o, WhsSave.PathGet(o, 0x01F4, 0x01F8, 0x7302, 0x000B)!.Value);
        Assert.Equal(1, b[4]);   // the host's header
        var keys = WhsSave.Children(b, 8, b.Length)!.Select(k => WhsSave.GuidStr(b.AsSpan(k.Off + 6 + 25))).ToList();
        Assert.Equal(["90000000-0000-0000-0000-000000000009", "20000000-0000-0000-0000-000000000003"], keys);
    }

    [Fact]
    public void Host_mode_carries_the_hosts_quest_items()
    {
        var (hs, js) = Pair();
        byte[] h = File(hs), j = File(js);
        var res = WhsSave.Splice(h, j, Quest, WhsSave.QuestItemMode.Host);
        Assert.Empty(WhsSave.Check(h, j, res.File, Quest, WhsSave.QuestItemMode.Host));
        Assert.Equal(["loveLetter"], res.Report.QuestItemsAdded);
        var o = WhsSave.Inflate(res.File).Raw;
        var d = WhsSave.DecodePlayerSoul(o, WhsSave.FindSoul(o, Henry)!.Value);
        Assert.Equal("10000000-0000-0000-0000-000000000002", d.Inventory[^1].Instance);
        // and a strip-mode check of a host-mode file fails
        Assert.NotEmpty(WhsSave.Check(h, j, res.File, Quest, WhsSave.QuestItemMode.Strip));
    }

    [Fact]
    public void An_equipped_quest_item_on_the_joiner_is_refused()
    {
        var (hs, js) = Pair();
        js.Equipped = ["20000000-0000-0000-0000-000000000002"];
        Assert.Throws<InvalidDataException>(() => WhsSave.Splice(File(hs), File(js), Quest, WhsSave.QuestItemMode.Strip));
    }

    [Fact]
    public void Check_fails_when_the_output_is_the_host_or_tampered()
    {
        var (hs, js) = Pair();
        byte[] h = File(hs), j = File(js);
        Assert.True(WhsSave.Check(h, j, h, Quest, WhsSave.QuestItemMode.Strip).Count >= 5);
        // the joiner's own file as the output: the world is wrong
        Assert.Contains(WhsSave.Check(h, j, j, Quest, WhsSave.QuestItemMode.Strip), f => f.StartsWith("host block changed", StringComparison.Ordinal));
        // variant C: one extra item on the spliced Henry
        js.Items = [.. js.Items.Where(i => i.Cls != Letter), new("20000000-0000-0000-0000-00000000000c", Apple)];
        var res = WhsSave.Splice(h, File(js), Quest, WhsSave.QuestItemMode.Strip);
        Assert.Contains(WhsSave.Check(h, j, res.File, Quest, WhsSave.QuestItemMode.Strip), f => f.Contains("inventory", StringComparison.Ordinal));
    }

    [Fact]
    public void Splice_refuses_mixed_builds_and_unverified_inputs()
    {
        var (hs, js) = Pair();
        js.Build = "1.5.4-release_1_5";
        Assert.Throws<InvalidDataException>(() => WhsSave.Splice(File(hs), File(js), Quest, WhsSave.QuestItemMode.Strip));
        js.Build = hs.Build;
        var bad = File(js);
        bad[^60] ^= 1;
        Assert.Throws<InvalidDataException>(() => WhsSave.Splice(File(hs), bad, Quest, WhsSave.QuestItemMode.Strip));
    }

    [Fact]
    public void Splice_is_deterministic()
    {
        var (hs, js) = Pair();
        byte[] h = File(hs), j = File(js);
        Assert.Equal(WhsSave.Splice(h, j, Quest, WhsSave.QuestItemMode.Strip).File, WhsSave.Splice(h, j, Quest, WhsSave.QuestItemMode.Strip).File);
    }

    [Fact]
    public void Quest_classes_come_from_the_item_tables_only()
    {
        string pak = Path.Combine(Path.GetTempPath(), $"wo122-tables-{Guid.NewGuid():N}.pak");
        try
        {
            using (var z = ZipFile.Open(pak, ZipArchiveMode.Create))
            {
                void Put(string name, string xml) { using var s = new StreamWriter(z.CreateEntry(name).Open()); s.Write(xml); }
                Put("Libs/Tables/item/item__quest.xml",
                    $"<database><MiscItem Id=\"{Letter.ToUpperInvariant()}\" Name=\"loveLetter\" IsQuestItem=\"true\"/><MiscItem Id=\"{Apple}\" Name=\"apple\" IsQuestItem=\"false\"/></database>");
                Put("Libs/Tables/rpg/perk.xml", $"<database><Perk Id=\"{Money}\" Name=\"notAnItem\" IsQuestItem=\"true\"/></database>");
            }
            var q = WhsSave.QuestClasses(pak);
            Assert.Equal(["loveLetter"], q.Values);
            Assert.True(q.ContainsKey(Letter));
        }
        finally { System.IO.File.Delete(pak); }
    }

    [Fact]
    public void Cli_verify_prints_no_header_text()
    {
        string dir = Path.Combine(Path.GetTempPath(), $"wo122-cli-{Guid.NewGuid():N}");
        Directory.CreateDirectory(dir);
        try
        {
            var (hs, _) = Pair();
            string p = Path.Combine(dir, "synthetic.whs");
            System.IO.File.WriteAllBytes(p, File(hs));
            var w = new StringWriter();
            Assert.Equal(0, WhsSave.RunCli(["--save-tool", "verify", p], w));
            Assert.StartsWith("OK ", w.ToString());
            Assert.DoesNotContain("host-world", w.ToString());
        }
        finally { Directory.Delete(dir, true); }
    }
}
