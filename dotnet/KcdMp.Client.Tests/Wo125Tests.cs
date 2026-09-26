using System.Buffers.Binary;
using System.Text;
using KcdMp.Wire;
using Spec = KcdMp.Client.Tests.WhsSaveTests.Spec;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-125: continuity (per-world Henry files), on SYNTHETIC saves and
/// synthetic seeds only (WhsSaveTests' builder). No real save, snapshot or
/// playthrough seed anywhere.
/// </summary>
public class Wo125Tests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "kcdmp-wo125-" + Guid.NewGuid().ToString("N"));
    private DateTime _now = new(2026, 9, 25, 12, 0, 0, DateTimeKind.Utc);
    private readonly List<string> _log = [];

    public Wo125Tests() => Directory.CreateDirectory(_root);

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch { }
    }

    private HenryStore Store() => new(Path.Combine(_root, "henry"), () => _now, s => _log.Add(s));

    private static readonly Dictionary<string, string> Q = WhsSaveTests.Quest;
    private static byte[] F(Spec s) => WhsSaveTests.File(s);
    private static string Md5Of(byte[] file) => WhsSave.Verify(file).Md5;

    // ---------------------------------------------------------------- the Henry block

    [Fact]
    public void A_block_splices_byte_for_byte_like_the_save_it_came_from()
    {
        var (hs, js) = WhsSaveTests.Pair();
        byte[] h = F(hs), j = F(js);
        var viaSave = WhsSave.Splice(h, j, Q, WhsSave.QuestItemMode.Strip).File;
        var parts = WhsSave.PartsFromFile(j, WhsSave.HenryParts.OriginSnapshot);
        var block = WhsSave.SerializeBlock(parts);
        var back = WhsSave.ParseBlock(block);
        var viaBlock = WhsSave.SpliceParts(h, back, Q, WhsSave.QuestItemMode.Strip).File;
        Assert.Equal(viaSave, viaBlock);
        Assert.Empty(WhsSave.CheckParts(h, back, viaBlock, Q, WhsSave.QuestItemMode.Strip));
        Assert.Empty(WhsSave.DiffBlocks(parts, back));
        // the block carries nothing of the save's header or world
        Assert.DoesNotContain("joiner-world", Encoding.ASCII.GetString(block));
        Assert.DoesNotContain("SaveGame", Encoding.ASCII.GetString(block));
    }

    [Fact]
    public void A_snapshot_taken_in_the_shared_world_round_trips_to_an_identical_block()
    {
        // snapshot -> splice -> "load" (the spliced file) -> snapshot again: the Henry is the same bytes
        var (hs, js) = WhsSaveTests.Pair();
        byte[] h = F(hs);
        var first = WhsSave.SpliceParts(h, WhsSave.PartsFromFile(F(js), "save"), Q, WhsSave.QuestItemMode.Strip).File;
        var snap1 = WhsSave.PartsFromFile(first, WhsSave.HenryParts.OriginSnapshot);
        var second = WhsSave.SpliceParts(h, WhsSave.ParseBlock(WhsSave.SerializeBlock(snap1)), Q, WhsSave.QuestItemMode.Strip).File;
        var snap2 = WhsSave.PartsFromFile(second, WhsSave.HenryParts.OriginSnapshot);
        Assert.Empty(WhsSave.DiffBlocks(snap1, snap2));
        Assert.Equal(first, second);
    }

    [Fact]
    public void A_damaged_block_is_refused()
    {
        var (_, js) = WhsSaveTests.Pair();
        var block = WhsSave.SerializeBlock(WhsSave.PartsFromFile(F(js), "save"));
        var flipped = (byte[])block.Clone();
        flipped[block.Length / 2] ^= 1;
        Assert.Throws<InvalidDataException>(() => WhsSave.ParseBlock(flipped));
        Assert.Throws<InvalidDataException>(() => WhsSave.ParseBlock(block.AsSpan(0, block.Length - 40).ToArray()));
        var magic = (byte[])block.Clone();
        magic[0] = (byte)'X';
        Assert.Throws<InvalidDataException>(() => WhsSave.ParseBlock(magic));
        Assert.Throws<InvalidDataException>(() => WhsSave.ParseBlock(new byte[10]));
    }

    [Fact]
    public void DiffBlocks_names_what_changed()
    {
        var (_, js) = WhsSaveTests.Pair();
        var a = WhsSave.PartsFromFile(F(js), "save");
        js.Strength = 223;
        js.Side = 3;
        var b = WhsSave.PartsFromFile(F(js), "save");
        var d = WhsSave.DiffBlocks(a, b);
        Assert.Contains(d, x => x.StartsWith("record 12fb#1/0927/1385", StringComparison.Ordinal));
        Assert.Contains(d, x => x.StartsWith("side 01f4/01f8/7308/352e", StringComparison.Ordinal));
        Assert.DoesNotContain(d, x => x.StartsWith("keys", StringComparison.Ordinal));
    }

    // ---------------------------------------------------------------- story stat edge cases

    [Fact]
    public void A_host_without_a_story_stat_leaves_the_joiner_without_one()
    {
        var (hs, js) = WhsSaveTests.Pair();
        hs.NoStory = true;
        byte[] h = F(hs), j = F(js);
        var res = WhsSave.Splice(h, j, Q, WhsSave.QuestItemMode.Strip);
        Assert.Null(res.Report.StoryHost);
        Assert.Equal(9999u, res.Report.StoryJoiner);
        Assert.Empty(WhsSave.Check(h, j, res.File, Q, WhsSave.QuestItemMode.Strip));
        var o = WhsSave.Inflate(res.File).Raw;
        Assert.False(WhsSave.DecodePlayerSoul(o, WhsSave.FindSoul(o, WhsSave.HenrySoul)!.Value).StatXp.ContainsKey("storyProgress"));
    }

    [Fact]
    public void A_new_games_first_henry_save_gets_the_hosts_story_stat_inserted()
    {
        var (hs, js) = WhsSaveTests.Pair();
        js.Pristine = true;
        byte[] h = F(hs), j = F(js);
        var parts = WhsSave.PartsFromFile(j, WhsSave.HenryParts.OriginFreshSave);
        var res = WhsSave.SpliceParts(h, parts, Q, WhsSave.QuestItemMode.Strip);
        Assert.Null(res.Report.StoryJoiner);
        Assert.Empty(WhsSave.CheckParts(h, parts, res.File, Q, WhsSave.QuestItemMode.Strip));
        var o = WhsSave.Inflate(res.File).Raw;
        var d = WhsSave.DecodePlayerSoul(o, WhsSave.FindSoul(o, WhsSave.HenrySoul)!.Value);
        Assert.Equal(new SortedDictionary<string, uint> { ["storyProgress"] = 4242 }, d.StatXp);
    }

    [Fact]
    public void A_joiner_without_a_story_slot_gets_it_in_key_order()
    {
        var (hs, js) = WhsSaveTests.Pair();
        js.NoStory = true;
        byte[] h = F(hs), j = F(js);
        var res = WhsSave.Splice(h, j, Q, WhsSave.QuestItemMode.Strip);
        Assert.Empty(WhsSave.Check(h, j, res.File, Q, WhsSave.QuestItemMode.Strip));
        var o = WhsSave.Inflate(res.File).Raw;
        var d = WhsSave.DecodePlayerSoul(o, WhsSave.FindSoul(o, WhsSave.HenrySoul)!.Value);
        Assert.Equal(4242u, d.StatXp["storyProgress"]);
        Assert.Equal(222u, d.StatXp["strength"]);
    }

    [Fact]
    public void The_engine_default_fresh_record_splices_and_checks_though_the_game_refuses_it()
    {
        // Research only: the game fails to load this (observed live, WO-125 findings s3). Kept as a CLI probe.
        var (hs, _) = WhsSaveTests.Pair();
        byte[] h = F(hs);
        var parts = WhsSave.FreshDefaultParts(WhsSave.Inflate(h).Raw);
        var res = WhsSave.SpliceParts(h, parts, Q, WhsSave.QuestItemMode.Strip);
        Assert.Empty(WhsSave.CheckParts(h, parts, res.File, Q, WhsSave.QuestItemMode.Strip));
    }

    // ---------------------------------------------------------------- seed, player

    [Fact]
    public void The_seed_is_read_from_the_stream_and_straight_from_the_file()
    {
        var s = new Spec { Seed = 0x1234ABCD };
        var f = F(s);
        Assert.Equal(0x1234ABCDu, WhsSave.ReadSeed(WhsSave.Inflate(f).Raw));
        string p = Path.Combine(_root, "quicksave001.whs");
        File.WriteAllBytes(p, f);
        Assert.Equal(0x1234ABCDu, WhsSave.ReadSeedFromFile(p));
        File.WriteAllBytes(p, Encoding.ASCII.GetBytes("no save here at all, just some bytes padding padding padding"));
        Assert.Null(WhsSave.ReadSeedFromFile(p));
        Assert.Null(WhsSave.ReadSeedFromFile(Path.Combine(_root, "missing.whs")));
    }

    [Fact]
    public void The_seed_tag_is_short_stable_and_not_the_seed()
    {
        string a = WhsSave.SeedTag(1), b = WhsSave.SeedTag(2);
        Assert.Matches("^[0-9a-f]{10}$", a);
        Assert.Equal(a, WhsSave.SeedTag(1));
        Assert.NotEqual(a, b);
        Assert.DoesNotContain("00000001", a);
    }

    [Fact]
    public void PlayerOf_tells_henry_from_godwin_and_a_first_save()
    {
        var h = WhsSave.PlayerOf(WhsSave.Inflate(F(new Spec())).Raw);
        Assert.True(h.IsHenry);
        Assert.Equal("player_henry", h.Player);
        Assert.False(h.Pristine);
        var g = WhsSave.PlayerOf(WhsSave.Inflate(F(new Spec { Bohuta = true })).Raw);
        Assert.False(g.IsHenry);
        Assert.Equal("player_bohuta", g.Player);
        var p = WhsSave.PlayerOf(WhsSave.Inflate(F(new Spec { Pristine = true })).Raw);
        Assert.True(p.IsHenry && p.Pristine);
    }

    // ---------------------------------------------------------------- the store

    private static WhsSave.HenryParts Parts(byte side = 2)
    {
        var (_, js) = WhsSaveTests.Pair();
        js.Side = side;
        return WhsSave.PartsFromFile(F(js), WhsSave.HenryParts.OriginSnapshot);
    }

    private static string M(int i) => i.ToString("x32");

    [Fact]
    public void Store_writes_atomically_reads_back_and_lists_newest_first()
    {
        var st = Store();
        string tag = WhsSave.SeedTag(77);
        var a = st.Store(tag, Parts(2), M(1), HenryStore.SourceBring, "join");
        _now = _now.AddMinutes(5);
        var b = st.Store(tag, Parts(3), M(2), HenryStore.SourceSnapshot, "autosave");
        var all = st.Snapshots(tag);
        Assert.Equal([b.File, a.File], all.Select(x => x.File));
        Assert.Empty(Directory.GetFiles(st.WorldDir(tag), "*.part"));
        Assert.NotNull(st.Load(all[0]));
        Assert.True(st.HasWorld(tag));
        Assert.False(st.HasWorld(WhsSave.SeedTag(78)));
        Assert.Contains(_log, l => l.Contains("read back: hash + parse ok"));
        Assert.Single(st.Worlds());
        Assert.Equal("bring", st.Worlds()[0].FirstSource);
    }

    [Fact]
    public void Pick_prefers_the_newest_pair_on_the_hosts_branch_then_the_newest_snapshot()
    {
        var st = Store();
        string tag = WhsSave.SeedTag(5);
        st.Store(tag, Parts(2), M(1), "snapshot", ""); _now = _now.AddMinutes(5);
        st.Store(tag, Parts(3), M(2), "snapshot", ""); _now = _now.AddMinutes(5);
        st.Store(tag, Parts(4), M(3), "snapshot", "");
        // the host reloaded save 1 and saved "9" since (no pair): branch newest first = 9, 1
        var p = st.PickFor(tag, [M(9), M(1)])!;
        Assert.Equal(M(1), p.Snapshot.Md5);
        Assert.Contains("branch save #1", p.How);
        // the newest save of the branch has a pair
        Assert.Equal(M(2), st.PickFor(tag, [M(2), M(1)])!.Snapshot.Md5);
        // nothing on the branch pairs: the newest snapshot
        var n = st.PickFor(tag, [M(42)])!;
        Assert.Equal(M(3), n.Snapshot.Md5);
        Assert.StartsWith("newest", n.How);
    }

    [Fact]
    public void A_broken_snapshot_is_skipped_for_the_next_older_one()
    {
        var st = Store();
        string tag = WhsSave.SeedTag(6);
        st.Store(tag, Parts(2), M(1), "snapshot", ""); _now = _now.AddMinutes(5);
        var newer = st.Store(tag, Parts(3), M(1), "snapshot", "");
        var path = Path.Combine(st.WorldDir(tag), newer.File);
        var b = File.ReadAllBytes(path); b[100] ^= 0xFF; File.WriteAllBytes(path, b);
        var p = st.PickFor(tag, [M(1)])!;
        Assert.NotEqual(newer.File, p.Snapshot.File);
        Assert.Contains(_log, l => l.Contains("BROKEN"));
    }

    [Fact]
    public void Worlds_are_pruned_to_the_keep_count_oldest_first()
    {
        var st = Store();
        string tag = WhsSave.SeedTag(8);
        var parts = Parts(2);
        for (int i = 0; i < HenryStore.KeepPerWorld + 3; i++) { st.Store(tag, parts, M(i), "snapshot", ""); _now = _now.AddSeconds(1); }
        var all = st.Snapshots(tag);
        Assert.Equal(HenryStore.KeepPerWorld, all.Count);
        Assert.Equal(M(HenryStore.KeepPerWorld + 2), all[0].Md5);
        Assert.DoesNotContain(all, s => s.Md5 == M(0) || s.Md5 == M(1) || s.Md5 == M(2));
    }

    [Fact]
    public void The_ninety_day_rule_deletes_only_stale_worlds()
    {
        var st = Store();
        string old = WhsSave.SeedTag(10), fresh = WhsSave.SeedTag(11);
        st.Store(old, Parts(), M(1), "snapshot", ""); st.MarkJoined(old);
        _now = _now.AddDays(60);
        st.Store(fresh, Parts(), M(2), "snapshot", ""); st.MarkJoined(fresh);
        _now = _now.AddDays(31);   // old: 91 days, fresh: 31 days
        var gone = st.CleanupStale();
        Assert.Equal([old], gone);
        Assert.False(st.HasWorld(old));
        Assert.True(st.HasWorld(fresh));
        Assert.Contains(_log, l => l.Contains("90-day rule"));
    }

    [Fact]
    public void Deleting_one_world_never_touches_another()
    {
        var st = Store();
        string a = WhsSave.SeedTag(20), b = WhsSave.SeedTag(21);
        st.Store(a, Parts(2), M(1), "snapshot", "");
        var kb = st.Store(b, Parts(3), M(2), "snapshot", "");
        byte[] before = File.ReadAllBytes(Path.Combine(st.WorldDir(b), kb.File));
        Assert.True(st.DeleteWorld(a, "test"));
        Assert.False(st.HasWorld(a));
        Assert.Equal(before, File.ReadAllBytes(Path.Combine(st.WorldDir(b), kb.File)));
        Assert.False(st.DeleteWorld(a, "again"));
    }

    [Fact]
    public void A_corrupt_world_index_is_rebuilt_from_the_snapshot_names()
    {
        var st = Store();
        string tag = WhsSave.SeedTag(30);
        st.Store(tag, Parts(), M(1), "bring", "");
        File.WriteAllText(Path.Combine(st.WorldDir(tag), "world.json"), "{ not json");
        var w = st.Worlds().Single();
        Assert.Equal(1, w.Count);
        Assert.Equal(M(1), st.PickFor(tag, [M(1)])!.Snapshot.Md5);
    }

    [Fact]
    public void MoveOut_keeps_the_newest_eight_swept_files()
    {
        var st = Store();
        string pl = Path.Combine(_root, "saves", "playline2");
        Directory.CreateDirectory(pl);
        for (int i = 0; i < 10; i++)
        {
            string f = Path.Combine(pl, $"quicksave{i:D3}.whs");
            File.WriteAllText(f, "x");
            Assert.True(st.MoveOut(f, "test"));
            Assert.False(File.Exists(f));
            _now = _now.AddSeconds(1);
        }
        var swept = Directory.GetFiles(Path.Combine(st.Root, "swept"));
        Assert.Equal(8, swept.Length);
        Assert.Contains(swept, s => s.EndsWith("playline2-quicksave009.whs", StringComparison.Ordinal));
        Assert.All(_log.Where(l => l.Contains("moved")), l => Assert.DoesNotContain(_root, l));   // playlineN/file only
    }

    [Fact]
    public void The_ledger_round_trips_and_forgets_old_done_entries()
    {
        var st = Store();
        var e = st.LedgerAdd(new HenryStore.LedgerEntry { Playline = 2, SinceUtc = _now, WorldTag = WhsSave.SeedTag(1) });
        st.LedgerSet(e.Id, x => { x.File = "quicksave039.whs"; x.State = "written"; });
        Assert.Equal("quicksave039.whs", st.Ledger().Single().File);
        st.LedgerSet(e.Id, x => x.State = "done");
        _now = _now.AddDays(8);
        st.LedgerAdd(new HenryStore.LedgerEntry { Playline = 1, SinceUtc = _now });
        Assert.Single(st.Ledger());
    }

    // ---------------------------------------------------------------- "own" saves

    [Fact]
    public void A_save_with_the_hosts_seed_is_never_own()
    {
        string saves = Path.Combine(_root, "saves");
        void Put(string pl, string name, uint seed, long t)
        {
            Directory.CreateDirectory(Path.Combine(saves, pl));
            File.WriteAllBytes(Path.Combine(saves, pl, name), F(new Spec { Seed = seed, SaveTime = t }));
        }
        Put("playline2", "quicksave022.whs", 0x2222, 100);
        Put("playline2", "save021.whs", 0x2222, 90);
        Put("playline1", "quicksave038.whs", 0x1111, 200);   // a copy of the host's world, newest by save time
        var log = new List<string>();
        var own = GameBridge.OwnSaves(saves, 0x1111, log.Add);
        Assert.Equal(["playline2/quicksave022.whs", "playline2/save021.whs"], own.Select(o => o.Save.Display));
        Assert.Contains(log, l => l.Contains("playline1/quicksave038.whs") && l.Contains("copies of the host's world"));
        Assert.Equal(3, GameBridge.OwnSaves(saves, null).Count);   // no host known: every save is own
        Assert.True(File.Exists(Path.Combine(saves, "playline1", "quicksave038.whs")));   // never touched
    }

    // ---------------------------------------------------------------- the wire

    [Fact]
    public void Branch_entries_ride_on_WorldSaved_without_a_new_type()
    {
        var w = new WorldSaved(3, 1, (byte)(Protocol.SaveKindBranchFlag | Protocol.SaveKindAuto), 1, 42, new byte[16]);
        var dec = WorldSaved.TryDecode(w.Encode(), down: false, out _)!.Value;
        Assert.True(dec.IsBranchEntry);
        Assert.Equal("autosave042.whs", dec.FileName);
        Assert.Equal("autosave", Protocol.SaveKindName(dec.Kind));
        Assert.Equal(Protocol.WorldSavedUpPayloadLen, w.Encode().Length);
        Assert.False(new WorldSaved(1, 0, Protocol.SaveKindAuto, 1, 1, new byte[16]).IsBranchEntry);
    }

    [Fact]
    public void The_session_status_carries_the_seed_in_the_join_id_slot()
    {
        var pkt = JoinStatusCodec.Build(1, 0xCAFEF00D, Protocol.JoinStateSession, Protocol.JoinReasonId("shared-world"),
                                        (ushort)(Protocol.SessionSeedKnown | Protocol.SessionHenryWorld));
        Assert.Equal(3 + Protocol.JoinHeaderLen + 4, pkt.Length);   // the same exact length the relay gates on
        var down = new byte[1 + pkt.Length - 3];
        down[0] = 0;
        pkt.AsSpan(3).CopyTo(down.AsSpan(1));
        Assert.True(Protocol.TrySplitJoinDown(down, out _, out _, out uint joinId, out var body));
        Assert.Equal(0xCAFEF00Du, joinId);
        Assert.True(JoinStatusCodec.TryDecode(body, out byte state, out _, out ushort arg));
        Assert.Equal(Protocol.JoinStateSession, state);
        Assert.Equal(3, arg);
    }

    [Fact]
    public void Wo125_reasons_and_states_are_appended_only()
    {
        Assert.Equal("session", Protocol.JoinStateName(8));
        Assert.Equal("reloading", Protocol.JoinStateName(Protocol.JoinStateReloading));
        Assert.Equal(9, Protocol.JoinStateReloading);
        Assert.Equal(28, Array.IndexOf(Protocol.JoinBusyReasons, "joiner-abort"));   // WO-124's last, unchanged
        Assert.True(Protocol.JoinReasonId("not-henry") > 28);
        Assert.Equal("world-changed", Protocol.JoinAbortName(18));
        Assert.Equal("not-henry", Protocol.JoinAbortName(19));
        Assert.Equal("no-henry-source", Protocol.JoinAbortName(20));
        Assert.Equal("place-failed", Protocol.JoinAbortName(17));
    }
}
