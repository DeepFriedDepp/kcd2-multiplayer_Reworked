using KcdMp.Wire;

namespace KcdMp.Client.Tests;

/// <summary>WO-122: the WorldSaved wire body and the save-file naming it rides on.</summary>
public class Wo122Tests
{
    private static string P(params string[] parts) => Path.Combine(parts);

    [Theory]
    [InlineData("autosave042.whs", "playline1", Protocol.SaveKindAuto, 1, 42)]
    [InlineData("quicksave037.whs", "playline1", Protocol.SaveKindQuick, 1, 37)]
    [InlineData("save009.whs", "playline2", Protocol.SaveKindManual, 2, 9)]
    [InlineData("permanent014.whs", "playline2", Protocol.SaveKindPermanent, 2, 14)]
    [InlineData("crucialdecision003.whs", "playline0", Protocol.SaveKindCrucial, 0, 3)]
    [InlineData("exit.whs", "playline3", Protocol.SaveKindExit, 3, 0)]
    [InlineData("AutoSave100.WHS", "Playline4", Protocol.SaveKindAuto, 4, 100)]
    public void Engine_named_saves_parse(string file, string dir, byte kind, byte playline, ushort idx)
    {
        var r = WorldSaved.ParsePath(P("C:", "saves", dir, file));
        Assert.Equal((kind, playline, idx), r);
    }

    [Theory]
    [InlineData("mpworld115.whs", "playline1")]      // the mod's transient world copy (WO-112 O1)
    [InlineData("mpworld115bad.whs", "playline1")]
    [InlineData("save 12.whs", "playline1")]
    [InlineData("autosave42.whs", "playline1")]       // the engine always writes three digits
    [InlineData("autosave042.whs.tmp", "playline1")]
    [InlineData("autosave042.whs", "playline1 - Copy")]
    [InlineData("autosave042.whs", "backups")]
    public void Anything_else_is_not_a_world_save(string file, string dir) =>
        Assert.Null(WorldSaved.ParsePath(P("C:", "saves", dir, file)));

    [Fact]
    public void The_display_name_never_carries_the_profile_path()
    {
        string full = P("C:", "Users", "SomeAccount", "Saved Games", "KingdomCome2", "saves", "playline1", "autosave042.whs");
        string d = GameBridge.SaveDisplay(full);
        Assert.Equal("playline1/autosave042.whs", d);
        Assert.DoesNotContain("SomeAccount", d);
    }

    [Fact]
    public void World_saved_round_trips()
    {
        var md5 = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
        var ws = new WorldSaved(12, 1_790_000_000_000L, Protocol.SaveKindAuto, 1, 42, md5);
        var up = ws.Encode();
        Assert.Equal(Protocol.WorldSavedUpPayloadLen, up.Length);
        var back = WorldSaved.TryDecode(up, down: false, out _);
        Assert.Equal(ws.Seq, back!.Value.Seq);
        Assert.Equal(ws.SenderUnixMs, back.Value.SenderUnixMs);
        Assert.Equal(md5, back.Value.Md5);
        var down = new byte[] { 3 }.Concat(up).ToArray();
        var d = WorldSaved.TryDecode(down, down: true, out byte src);
        Assert.Equal(3, src);
        Assert.Equal("autosave042.whs", d!.Value.FileName);
        Assert.Null(WorldSaved.TryDecode(up.AsSpan(1), down: false, out _));   // exact length only
        Assert.Equal("exit.whs", (ws with { Kind = Protocol.SaveKindExit }).FileName);
    }

    [Fact]
    public void Shared_world_and_owner_death_ship_on()
    {
        Assert.True(GameBridge.SharedWorldDefault);   // 0.30.0: the maintainer's default for every build from here on
        Assert.True(GameBridge.OwnerDeathDefault);
        Assert.Equal(5, GameBridge.AutosaveMinutesDefault);
    }
}
