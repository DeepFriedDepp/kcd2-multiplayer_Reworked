using System.IO.Compression;
using System.Text;
using System.Xml;
using KcdMp.Wire;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-96 Phase 2: the fingerprint codec, the comparison, the registry-id
/// refusal, and the save-file read path on a synthetic .whs built with the
/// exact framing observed on the 2026-09-13 host's autosave009
/// ([u32 FFFFFFFF][i32 descLen][desc][ {i32 clen}{i32 rlen}{zlib} ]*[64-byte footer]).
/// The ConceptState tree below is a trimmed copy of that save's socky
/// subtree (docs/WO-96-findings.md s3): objectiveVisual38 (rekni_ptackovi_o_praci)
/// and objectiveVisual40 (zjisti_vic_o_seminove_svatbe) Active, nothing else.
/// None of these tests needs a game, a real save or the embedded registry.
/// </summary>
public class StoryFingerprintTests
{
    private const string RegistryJson = """
    {
      "id": "0123456789ab",
      "pak": "deadbeef",
      "quests": [
        { "code": "M03", "name": "socky", "key": "socky", "level": "trosecko", "title": "Laboratores",
          "objectives": [
            { "n": "zjisti_jak_se_dostat_k_bergovovi", "k": "a", "t": "Find a way to get to Bergow.", "optional": false, "paths": ["hibernable.v_hospode.objectiveVisual36"] },
            { "n": "umyj_se_u_kade", "k": "b", "t": "Wash in the trough.", "optional": false, "paths": ["hibernable.v_hospode.s_katerinou.dialogy_a_chovani.umyj_se.objectiveVisual5"] },
            { "n": "promluv_si_s_zenou_od_rybnika", "k": "c", "t": "Talk to the woman from the pond.", "optional": false, "paths": ["hibernable.v_hospode.s_katerinou.objectiveVisual6"] },
            { "n": "zjisti_vic_o_seminove_svatbe", "k": "d", "t": "Find out more about the wedding.", "optional": true, "paths": ["hibernable.v_hospode.objectiveVisual40"] },
            { "n": "rekni_ptackovi_o_praci", "k": "socky_rekni_ptackovi_o_pr_ebpz", "t": "Tell Capon about the work.", "optional": false, "paths": ["hibernable.v_hospode.objectiveVisual38"] },
            { "n": "nos_pytle_05", "k": "socky_nos_pytle__05_cQkk", "t": "Carry the sacks to the pantry.", "optional": false, "paths": ["hibernable.v_hospode.pytle_a_hadka.objectiveVisual43"] },
            { "n": "vrat_se_za_ptackem", "k": "f", "t": "Go back to Capon.", "optional": false, "paths": ["hibernable.v_hospode.pytle_a_hadka.objectiveVisual15"] },
            { "n": "bran_ptacka", "k": "g", "t": "Defend Capon.", "optional": false, "paths": ["hibernable.v_hospode.hospodska_bitka.objectiveVisual2"] }
          ] },
        { "code": "M05", "name": "svatba", "key": "svatba", "level": "trosecko", "title": "Wedding Crashers", "objectives": [] }
      ]
    }
    """;

    // the host at 16:21 on 2026-09-13: rekni_ptackovi Active, the optional svatba objective Active
    private const string HostRoots = """
    <Roots>
      <_Barbora Version="ver_01_05_05"><Nodes>
        <_trosecko Version="ver_01_05_05"><Nodes>
          <_socky Version="ver_01_05_05"><Nodes>
            <_hibernable Version="ver_01_05_05"><Nodes>
              <_sockyState value="Hospoda" />
              <_v_hospode Version="ver_01_05_05"><Nodes>
                <_objectiveVisual38><Logs><Active UpdateTime="8853546" /></Logs></_objectiveVisual38>
                <_objectiveVisual40><Logs><Active UpdateTime="8871933" /></Logs></_objectiveVisual40>
                <_rekniPtackoviOPraci value="Active" />
                <_zjistiVicOSvatbe value="Active" />
              </Nodes></_v_hospode>
            </Nodes></_hibernable>
            <_questProgress value="Active" />
          </Nodes></_socky>
        </Nodes></_trosecko>
      </Nodes></_Barbora>
    </Roots>
    """;

    // the joiner a few minutes later: rekni_ptackovi Done, the sacks Started (a minigame log name), Capon's fight Active
    private const string JoinerRoots = """
    <Roots>
      <_Barbora Version="ver_01_05_05"><Nodes>
        <_trosecko Version="ver_01_05_05"><Nodes>
          <_socky Version="ver_01_05_05"><Nodes>
            <_hibernable Version="ver_01_05_05"><Nodes>
              <_v_hospode Version="ver_01_05_05"><Nodes>
                <_objectiveVisual38><Logs><Active UpdateTime="8853546" /><Done UpdateTime="8872000" /></Logs></_objectiveVisual38>
                <_objectiveVisual40><Logs><Active UpdateTime="8871933" /></Logs></_objectiveVisual40>
                <_pytle_a_hadka Version="ver_01_05_05"><Nodes>
                  <_objectiveVisual43><Logs><ZvedniPytelZeZdrojeStart UpdateTime="8873000" /><ZvedniPytelZeZdroje UpdateTime="8873100" /></Logs></_objectiveVisual43>
                </Nodes></_pytle_a_hadka>
                <_hospodska_bitka Version="ver_01_05_05"><Nodes>
                  <_objectiveVisual2><Logs><Active UpdateTime="8874000" /></Logs></_objectiveVisual2>
                </Nodes></_hospodska_bitka>
              </Nodes></_v_hospode>
            </Nodes></_hibernable>
          </Nodes></_socky>
        </Nodes></_trosecko>
      </Nodes></_Barbora>
    </Roots>
    """;

    private static XmlDocument Doc(string xml) { var d = new XmlDocument(); d.LoadXml(xml); return d; }
    private static QuestObjectiveRegistry Reg() => QuestObjectiveRegistry.Parse(RegistryJson);

    [Fact]
    public void Host_save_reads_the_journal_state_the_player_saw()
    {
        var q = Reg().ByName("socky")!;
        var st = StoryFingerprint.Read(Doc(HostRoots), q)!;
        Assert.Equal(StoryFingerprint.Active, st[4]);   // rekni_ptackovi_o_praci -- the marker's own objective
        Assert.Equal(StoryFingerprint.Active, st[3]);   // the optional wedding objective
        Assert.Equal(StoryFingerprint.None, st[5]);     // the sacks: never started on the host
        Assert.Equal(StoryFingerprint.None, st[7]);
        Assert.Equal(2, st.Count(s => s != StoryFingerprint.None));
    }

    [Fact]
    public void A_quest_that_never_started_reads_all_none_not_null()
    {
        var q = Reg().ByName("svatba")!;
        var st = StoryFingerprint.Read(Doc(HostRoots), q);
        Assert.NotNull(st);
        Assert.Empty(st!);
        var q2 = new QuestObjectiveRegistry.Quest { Name = "zachrana", Level = "trosecko", Objectives = new[] { new QuestObjectiveRegistry.Objective { Name = "x", Paths = new[] { "a.b" } } } };
        Assert.All(StoryFingerprint.Read(Doc(HostRoots), q2)!, s => Assert.Equal(StoryFingerprint.None, s));
    }

    [Fact]
    public void Minigame_log_names_count_as_active_and_Done_wins()
    {
        var q = Reg().ByName("socky")!;
        var st = StoryFingerprint.Read(Doc(JoinerRoots), q)!;
        Assert.Equal(StoryFingerprint.Done, st[4]);
        Assert.Equal(StoryFingerprint.Active, st[5]);   // ZvedniPytelZeZdroje is not Done/Failed -> active
        Assert.Equal(StoryFingerprint.Active, st[7]);
    }

    [Fact]
    public void Encode_and_decode_round_trip_within_the_wire_budget()
    {
        var reg = Reg(); var q = reg.ByName("socky")!;
        var st = StoryFingerprint.Read(Doc(JoinerRoots), q)!;
        string text = StoryFingerprint.Encode(reg.Id, q.Key, st);
        Assert.True(text.Length <= Protocol.MaxStoryBeatTextLen);
        Assert.True(StoryFingerprint.TryDecode(text, out var id, out var key, out var packed));
        Assert.Equal(reg.Id, id); Assert.Equal("socky", key);
        Assert.Equal(st, StoryFingerprint.Unpack(packed, st.Length));
        // the largest real quest (52 objectives) fits comfortably
        var big = Enumerable.Repeat(StoryFingerprint.Done, 52).ToArray();
        Assert.True(StoryFingerprint.Encode(reg.Id, "zachrana", big).Length <= Protocol.MaxStoryBeatTextLen);
    }

    [Theory]
    [InlineData("")]
    [InlineData("nocolons")]
    [InlineData("0123456789ab:socky")]
    [InlineData("0123456789ab:socky:abc")]          // odd hex
    [InlineData("0123456789ab:so cky:ab")]           // bad key char
    [InlineData("zz:socky:ab")]                      // id too short / not hex
    [InlineData("0123456789ab:socky:ab\"); os.exit(")]
    public void Malformed_fingerprints_are_refused(string text)
    {
        Assert.False(StoryFingerprint.TryDecode(text, out _, out _, out _));
    }

    [Fact]
    public void The_bag_case_names_exactly_what_the_host_lacked()
    {
        var q = Reg().ByName("socky")!;
        var host = StoryFingerprint.Read(Doc(HostRoots), q)!;
        var joiner = StoryFingerprint.Read(Doc(JoinerRoots), q)!;
        var (theyHave, weHave, differ) = StoryFingerprint.Compare(host, joiner);
        // from the host's seat: the joiner has the sacks and Capon's fight; the host has nothing the joiner lacks
        Assert.Equal(new[] { 5, 7 }, theyHave);
        Assert.Empty(weHave);
        Assert.Equal(new[] { 4, 5, 7 }, differ);      // rekni_ptackovi differs too (Active vs Done)
        Assert.Equal("Carry the sacks to the pantry.; Defend Capon.", StoryFingerprint.Labels(q, theyHave));
        Assert.Contains("(done)", StoryFingerprint.Labels(q, differ, joiner));
    }

    [Fact]
    public void Registry_id_is_required_to_match_before_any_comparison()
    {
        var reg = Reg();
        Assert.True(StoryFingerprint.TryDecode("ffffffffffff:socky:00", out var id, out _, out _));
        Assert.NotEqual(reg.Id, id);   // the agent refuses on this inequality (GameBridge.ComparePeerFingerprint)
    }

    // --- the save-file path -------------------------------------------------------

    private static byte[] BuildWhs(string descriptionXml, string body, int blockSize = 300)
    {
        var raw = Encoding.UTF8.GetBytes("\u0001\u0002junk before the tree ConceptState " + body + " trailing bytes");
        using var ms = new MemoryStream();
        ms.Write(BitConverter.GetBytes(0xFFFFFFFFu));
        var desc = Encoding.UTF8.GetBytes(descriptionXml);
        ms.Write(BitConverter.GetBytes(desc.Length));
        ms.Write(desc);
        bool storedOnce = false;
        for (int off = 0; off < raw.Length; off += blockSize)
        {
            int n = Math.Min(blockSize, raw.Length - off);
            if (!storedOnce && off > 0)
            {
                // one STORED block (compressedLen 0xFFFFFFFF, raw bytes follow),
                // as autosave008 carries at offset 1,030,211
                storedOnce = true;
                ms.Write(BitConverter.GetBytes(-1));
                ms.Write(BitConverter.GetBytes(n));
                ms.Write(raw, off, n);
                continue;
            }
            using var z = new MemoryStream();
            z.WriteByte(0x78); z.WriteByte(0x5E);   // zlib header, as in the real file
            using (var ds = new DeflateStream(z, CompressionLevel.Optimal, leaveOpen: true)) ds.Write(raw, off, n);
            var zb = z.ToArray();
            ms.Write(BitConverter.GetBytes(zb.Length));
            ms.Write(BitConverter.GetBytes(n));
            ms.Write(zb);
        }
        ms.Write(new byte[64]);
        return ms.ToArray();
    }

    private const string Desc = "<C_SaveGameDescription FormatVersion=\"0\" SaveType=\"AutoSave\" SaveId=\"9\" SaveTime=\"1789341681\" LevelName=\"trosecko\" QuestNameOverride=\"@qname_socky_CpmD|@socky_rekni_ptackovi_o_pr_ebpz\" />";

    [Fact]
    public void Description_and_concept_tree_come_back_from_the_framed_file()
    {
        string path = Path.Combine(Path.GetTempPath(), $"wo96-{Guid.NewGuid():N}.whs");
        try
        {
            File.WriteAllBytes(path, BuildWhs(Desc, HostRoots));
            var d = SaveGameReader.TryReadDescription(path)!;
            Assert.Equal("@qname_socky_CpmD|@socky_rekni_ptackovi_o_pr_ebpz", d.QuestNameOverride);
            Assert.Equal("trosecko", d.LevelName); Assert.Equal(9, d.SaveId);
            var doc = SaveGameReader.TryReadConceptState(path)!;
            var st = StoryFingerprint.Read(doc, Reg().ByName("socky")!)!;
            Assert.Equal(StoryFingerprint.Active, st[4]);
        }
        finally { File.Delete(path); }
    }

    [Fact]
    public void Newest_save_for_a_marker_is_found_and_others_ignored()
    {
        string root = Path.Combine(Path.GetTempPath(), $"wo96-saves-{Guid.NewGuid():N}");
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "playline2"));
            string other = Path.Combine(root, "playline2", "autosave008.whs");
            string mine  = Path.Combine(root, "playline2", "autosave009.whs");
            File.WriteAllBytes(other, BuildWhs(Desc.Replace("socky_rekni_ptackovi_o_pr_ebpz", "zachrana_sitdown_visual_Dtkv"), HostRoots));
            File.WriteAllBytes(mine, BuildWhs(Desc, HostRoots));
            Assert.Equal(mine, SaveGameReader.FindNewestSaveForMarker(root, "@qname_socky_CpmD|@socky_rekni_ptackovi_o_pr_ebpz", DateTime.UtcNow.AddMinutes(-1)));
            Assert.Null(SaveGameReader.FindNewestSaveForMarker(root, "@qname_socky_CpmD|@socky_nos_pytle__05_cQkk", DateTime.UtcNow.AddMinutes(-1)));
            Assert.Null(SaveGameReader.FindNewestSaveForMarker(root, "@qname_socky_CpmD|@socky_rekni_ptackovi_o_pr_ebpz", DateTime.UtcNow.AddMinutes(1)));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void Truncated_or_foreign_files_read_as_null_not_throw()
    {
        Assert.Null(SaveGameReader.TryInflate(new byte[10]));
        Assert.Null(SaveGameReader.TryInflate(Encoding.UTF8.GetBytes(new string('x', 500))));
        var good = BuildWhs(Desc, HostRoots);
        Assert.Null(SaveGameReader.TryInflate(good[..(good.Length / 2)]));
    }

    [Fact]
    public void User_folder_line_parses_as_kcd_log_writes_it()
    {
        Assert.Equal(@"C:\Users\HostUser\Saved Games\KingdomCome2",
            SaveGameReader.TryParseUserFolder(@"<13:32:18> User folder is 'C:\Users\HostUser\Saved Games\KingdomCome2'"));
        Assert.Null(SaveGameReader.TryParseUserFolder("Loading level trosecko"));
    }
}
