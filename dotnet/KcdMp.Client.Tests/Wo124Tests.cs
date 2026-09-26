using System.Buffers.Binary;
using System.Text;
using KcdMp.Wire;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-124: the joiner's side of the join, on SYNTHETIC files only (headers and
/// saves built here, in a temp folder shaped like the engine's saves folder).
/// No real save anywhere: every real header carries the writing machine's
/// account name.
/// </summary>
public class Wo124Tests : IDisposable
{
    private readonly string _saves = Path.Combine(Path.GetTempPath(), "kcdmp-wo124-" + Guid.NewGuid().ToString("N"));

    public Wo124Tests() => Directory.CreateDirectory(_saves);

    public void Dispose()
    {
        try { Directory.Delete(_saves, true); } catch { }
    }

    /// <summary>A file with a save-shaped description header only (enough for ReadSaveTime).</summary>
    private string Header(string dir, string file, long? saveTime)
    {
        string d = Path.Combine(_saves, dir);
        Directory.CreateDirectory(d);
        string desc = saveTime is long t
            ? $"<C_SaveGameDescription FormatVersion=\"0\" SaveType=\"QuickSave\" SaveId=\"1\" SaveTime=\"{t}\" LevelName=\"trosecko\"/>"
            : "<C_SaveGameDescription FormatVersion=\"0\" SaveType=\"QuickSave\"/>";
        var db = Encoding.UTF8.GetBytes(desc);
        var b = new byte[8 + db.Length + 32];
        BinaryPrimitives.WriteUInt32LittleEndian(b, 0xFFFFFFFFu);
        BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(4), db.Length);
        db.CopyTo(b, 8);
        string p = Path.Combine(d, file);
        File.WriteAllBytes(p, b);
        return p;
    }

    // ---------------------------------------------------------------- Phase 1: which Henry

    [Fact]
    public void ReadSaveTime_reads_the_header_and_refuses_other_files()
    {
        string p = Header("playline1", "save001.whs", 1789944903);
        Assert.Equal(1789944903L, GameBridge.ReadSaveTime(p));
        Assert.Null(GameBridge.ReadSaveTime(Header("playline1", "save002.whs", null)));
        string junk = Path.Combine(_saves, "playline1", "save003.whs");
        File.WriteAllBytes(junk, Encoding.ASCII.GetBytes("not a save at all"));
        Assert.Null(GameBridge.ReadSaveTime(junk));
    }

    [Fact]
    public void ListOwnSaves_is_newest_first_across_playlines_and_never_a_transient_world()
    {
        Header("playline0", "autosave244.whs", 100);
        Header("playline1", "quicksave038.whs", 300);
        Header("playline2", "save021.whs", 200);
        Header("playline2", "exit.whs", 250);
        Header("playline2", "mpworld1a2b3c4d.whs", 999);      // a received world: never the Henry source
        Header("playline3", "notes.whs", 998);                // not an engine name
        Header("playline5", "save001.whs", 997);              // no such playline for the engine
        Header("playline1 - Copy", "save002.whs", 996);       // a copied folder the scanner never lists
        Header("playline4", "save005.whs", null);             // no SaveTime

        var all = GameBridge.ListOwnSaves(_saves);
        Assert.Equal(new[] { "playline1/quicksave038.whs", "playline2/exit.whs", "playline2/save021.whs", "playline0/autosave244.whs" },
                     all.Select(s => s.Display).ToArray());
        Assert.Equal("quicksave038", all[0].Base);
        Assert.Equal(1, all[0].Playline);
    }

    [Fact]
    public void ListOwnSaves_of_a_fresh_install_is_empty()
    {
        Directory.CreateDirectory(Path.Combine(_saves, "playline0"));
        Assert.Empty(GameBridge.ListOwnSaves(_saves));
    }

    // ---------------------------------------------------------------- Phase 3: the transient file

    [Fact]
    public void Sweep_removes_every_transient_world_and_nothing_else()
    {
        string keep = Header("playline2", "quicksave022.whs", 10);
        string a = Header("playline2", "mpworld227213e4.whs", 11);
        string b = Header("playline0", "mpworld00000001.part", null);
        string c = Header("playline4", "mpworldabc.whs", 12);
        string d = Header("playline1 - Copy", "mpworld1.whs", 13);   // not a playline: not ours to touch
        string e = Header("playline2", "mpworldnothex.whs", 14);     // not the join's name shape

        int n = GameBridge.SweepTransientWorlds(_saves, keep: null);
        Assert.Equal(3, n);
        Assert.True(File.Exists(keep));
        Assert.False(File.Exists(a));
        Assert.False(File.Exists(b));
        Assert.False(File.Exists(c));
        Assert.True(File.Exists(d));
        Assert.True(File.Exists(e));
    }

    [Fact]
    public void Sweep_keeps_the_file_it_is_told_to_keep()
    {
        string a = Header("playline2", "mpworld00000002.whs", 11);
        Assert.Equal(0, GameBridge.SweepTransientWorlds(_saves, keep: a));
        Assert.True(File.Exists(a));
    }

    // ---------------------------------------------------------------- Phase 4: the Henry check

    private const string Money = GameBridge.MoneyClass;
    private const string Keyring = GameBridge.KeyringClass;
    private const string Apple = "0a0a0a0a-0000-0000-0000-00000000a001";
    private const string Sword = "0c0c0c0c-0000-0000-0000-00000000c001";

    private static WhsSave.PlayerSoul FileHenry()
    {
        var h = new WhsSave.PlayerSoul();
        h.Inventory.Add(new WhsSave.InvItem("i-money", 1, Money, "amount=151;p2=00020000"));
        h.Inventory.Add(new WhsSave.InvItem("i-apple", 0, Apple, "amount=3"));
        h.Inventory.Add(new WhsSave.InvItem("i-apple2", 0, Apple, ""));
        h.Inventory.Add(new WhsSave.InvItem("i-sword", 0, Sword, "p1=00"));
        return h;
    }

    [Fact]
    public void CompareHenry_matches_money_and_items_with_the_live_only_keyring_aside()
    {
        string live = $"money=15.10 items={Apple}:3;{Apple}:1;{Sword}:1;{Keyring}:1;{Money}:151 skills=fencing:7:0.1953";
        var (ok, why) = GameBridge.CompareHenry(FileHenry(), live);
        Assert.True(ok, why);
        Assert.Contains("money file=151 live=151", why);
        Assert.Contains("differing=0", why);
    }

    [Fact]
    public void CompareHenry_refuses_other_money()
    {
        var (ok, why) = GameBridge.CompareHenry(FileHenry(), $"money=15.20 items={Apple}:4;{Sword}:1 skills=");
        Assert.False(ok);
        Assert.Contains("money file=151 live=152", why);
    }

    [Fact]
    public void CompareHenry_refuses_a_missing_or_extra_item()
    {
        Assert.False(GameBridge.CompareHenry(FileHenry(), $"money=15.10 items={Apple}:4 skills=").Ok);
        Assert.False(GameBridge.CompareHenry(FileHenry(), $"money=15.10 items={Apple}:4;{Sword}:1;{Sword}:1 skills=").Ok);
        Assert.False(GameBridge.CompareHenry(FileHenry(), $"money=15.10 items={Apple}:3;{Sword}:1 skills=").Ok);   // an apple short
    }

    [Fact]
    public void CompareHenry_refuses_an_incomplete_live_read()
    {
        Assert.False(GameBridge.CompareHenry(FileHenry(), "timeout").Ok);
        Assert.False(GameBridge.CompareHenry(FileHenry(), "missing").Ok);
        Assert.False(GameBridge.CompareHenry(FileHenry(), "money=? items= skills=").Ok);
    }

    [Fact]
    public void CompareHenry_on_a_spliced_synthetic_save()
    {
        // The splice keeps the joiner's inventory; the decoder reads it back as the check does.
        var file = WhsSaveTests.SyntheticSave("joiner-world");
        var raw = WhsSave.Inflate(file).Raw;
        var henry = WhsSave.DecodePlayerSoul(raw, WhsSave.FindSoul(raw, WhsSave.HenrySoul)!.Value);
        var items = string.Join(";", henry.Inventory.Select(i => $"{i.Class}:{(i.Params.Contains("amount=") ? i.Params.Split("amount=")[1].Split(';')[0] : "1")}"));
        long money = henry.Inventory.Where(i => i.Class == Money).Sum(i => long.Parse(i.Params.Split("amount=")[1].Split(';')[0]));
        var (ok, why) = GameBridge.CompareHenry(henry, $"money={(money / 10.0).ToString("F2", System.Globalization.CultureInfo.InvariantCulture)} items={items} skills=");
        Assert.True(ok, why);
    }

    // ---------------------------------------------------------------- the menu

    [Fact]
    public void ScanAtMainMenu_takes_the_later_of_the_menu_and_gameplay()
    {
        string log = Path.Combine(_saves, "kcd.log");
        File.WriteAllText(log, "boot\r\nPlayVideoOnly 'main_menu_trosecko', loopBeginFrame:2\r\nstuff\r\n");
        Assert.True(LogTailGameTransport.ScanAtMainMenu(log));
        File.AppendAllText(log, "Loading saved game (idx:14)...\r\nGameplay started\r\nmore\r\n");
        Assert.False(LogTailGameTransport.ScanAtMainMenu(log));
        File.AppendAllText(log, "Exiting to main menu because save game loading failed.\r\nPlayVideoOnly 'main_menu_trosecko', loopBeginFrame:2\r\n");
        Assert.True(LogTailGameTransport.ScanAtMainMenu(log));
        File.WriteAllText(log, "nothing yet\r\n");
        Assert.Null(LogTailGameTransport.ScanAtMainMenu(log));
    }

    [Theory]
    [InlineData("if KCD2MP_Wo124Where then KCD2MP_Wo124Where() end", true)]
    [InlineData("if KCD2MP_Wo124LoadGame then KCD2MP_Wo124LoadGame(2, \"mpworld1\", \"join\") end", true)]
    [InlineData("if KCD2MP_HostOnlyLock then KCD2MP_HostOnlyLock(true, \"join\") end", true)]
    [InlineData("if KCD2MP_JoinTry then KCD2MP_JoinTry(\"1\", \"x\", 180) end", true)]
    [InlineData("if KCD2MP_Wo122CfgEmit then KCD2MP_Wo122CfgEmit() end", true)]
    [InlineData("if KCD2MP_SetHitSensor then KCD2MP_SetHitSensor(false) end", true)]
    [InlineData("KCD2MP_UpdateGhost(\"0\",2511.20,2128.80,123.38,0.0000,false)", false)]
    [InlineData("if KCD2MP_ApplyNpcState then KCD2MP_ApplyNpcState(\"ttkc_man_1\",1,2,3) end", false)]
    [InlineData("if KCD2MP_ReportWorldTime then KCD2MP_ReportWorldTime() end", false)]
    public void The_menu_gate_lets_only_the_joins_calls_through(string lua, bool safe) =>
        Assert.Equal(safe, GameBridge.IsMenuSafeLua(lua));

    // ---------------------------------------------------------------- wire names (append-only)

    [Fact]
    public void The_new_abort_reasons_and_states_are_named_and_appended()
    {
        Assert.Equal("no-own-save", Protocol.JoinAbortName(Protocol.JoinAbortNoOwnSave));
        Assert.Equal("splice-failed", Protocol.JoinAbortName(Protocol.JoinAbortSpliceFailed));
        Assert.Equal("load-failed", Protocol.JoinAbortName(Protocol.JoinAbortLoadFailed));
        Assert.Equal("henry-mismatch", Protocol.JoinAbortName(Protocol.JoinAbortHenryMismatch));
        Assert.Equal("lock-failed", Protocol.JoinAbortName(Protocol.JoinAbortLockFailed));
        Assert.Equal("place-failed", Protocol.JoinAbortName(Protocol.JoinAbortPlaceFailed));
        Assert.Equal(12, Protocol.JoinAbortNoOwnSave);   // after WO-123's 1..11
        Assert.Equal("session", Protocol.JoinStateName(Protocol.JoinStateSession));
        Assert.Equal(8, Protocol.JoinStateSession);
        // WO-123's reasons keep their ids; WO-124's follow.
        Assert.Equal(19, Protocol.JoinReasonId("clock-sync"));
        Assert.True(Protocol.JoinReasonId("shared-world") > 19);
        Assert.Equal("shared-world", Protocol.JoinReasonName(Protocol.JoinReasonId("shared-world")));
        Assert.Equal("separate", Protocol.JoinReasonName(Protocol.JoinReasonId("separate")));
    }

    [Fact]
    public void The_session_mode_rides_on_join_status_to_one_peer()
    {
        var pkt = JoinStatusCodec.Build(1, 0, Protocol.JoinStateSession, Protocol.JoinReasonId("shared-world"), 0);
        Assert.Equal(Protocol.JoinStatusUp, pkt[0]);
        Assert.Equal(1, pkt[3]);                                          // the target peer
        Assert.Equal(0u, BinaryPrimitives.ReadUInt32LittleEndian(pkt.AsSpan(4)));   // joinId 0
        var row = Protocol.JoinWireFor(Protocol.JoinStatusUp)!.Value;
        Assert.Equal(Protocol.JoinFrom.Host, row.From);                   // the relay accepts it only from the host
        Assert.InRange(pkt.Length - 3, row.Min, row.Max);
        Assert.True(JoinStatusCodec.TryDecode(pkt.AsSpan(8), out byte st, out byte rs, out _));
        Assert.Equal(Protocol.JoinStateSession, st);
        Assert.Equal("shared-world", Protocol.JoinReasonName(rs));
    }
}
