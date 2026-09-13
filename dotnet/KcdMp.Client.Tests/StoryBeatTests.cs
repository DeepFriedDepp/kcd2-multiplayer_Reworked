using KcdMp.Wire;
using static KcdMp.Client.StoryBeat;

namespace KcdMp.Client.Tests;

/// <summary>
/// WO-90: pins the quest-objective marker parse to the exact lines the
/// 2026-09-12 field logs contain, on both machines. Every literal below is
/// copied verbatim from a real kcd.log line cited in docs/WO-90-findings.md;
/// none of these tests needs a game, relay or agent.
/// </summary>
public class StoryBeatTests
{
    // ------------------------------------------------------------------
    // The parse
    // ------------------------------------------------------------------

    [Theory]
    // host kcd.log 183300, 20:51:03.3 -- "ask Hans about the ambush"
    [InlineData(
        "InitiateSaveGame() type: AutoSave, overwriteSaveId: -1, questNameOverride: '@qname_prepadeni_KsSs|@prepadeni_zjisti_od_ptack_3seP'",
        "@qname_prepadeni_KsSs|@prepadeni_zjisti_od_ptack_3seP")]
    // host kcd.log 422892, 21:50:00.1 / joiner kcd.log 224774, 21:40:36.0 -- the sneak beat
    [InlineData(
        "InitiateSaveGame() type: AutoSave, overwriteSaveId: -1, questNameOverride: '@qname_prepadeni_KsSs|@mq01__pre_crouch_GayI'",
        "@qname_prepadeni_KsSs|@mq01__pre_crouch_GayI")]
    // host kcd.log 15918 -- the prologue's permanent save
    [InlineData(
        "InitiateSaveGame() type: PermanentSave, overwriteSaveId: -1, questNameOverride: '@qname_poslednipomazani_1DR8|@poslednip_objective1_9O8s'",
        "@qname_poslednipomazani_1DR8|@poslednip_objective1_9O8s")]
    // host kcd.log 966471, 22:02:53.1 -- the next quest
    [InlineData(
        "InitiateSaveGame() type: PermanentSave, overwriteSaveId: -1, questNameOverride: '@qname_zachrana_FbKt|@zachrana_zastav_krvaceni__tHDn'",
        "@qname_zachrana_FbKt|@zachrana_zastav_krvaceni__tHDn")]
    public void RealCheckpointLinesYieldTheirKey(string line, string expected)
    {
        Assert.True(TryParseObjectiveMarker(line, out var marker));
        Assert.Equal(expected, marker);
    }

    [Fact]
    public void TheSameObjectiveIsByteIdenticalOnBothMachines()
    {
        // host kcd.log 429569 (21:52:39.5) and joiner kcd.log 268335 (21:52:42.1):
        // the two players crossed the same beat 2.6 s apart. Exact equality is
        // the whole basis for comparing two clients' story position.
        const string host   = "InitiateSaveGame() type: AutoSave, overwriteSaveId: -1, questNameOverride: '@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB'";
        const string joiner = "InitiateSaveGame() type: AutoSave, overwriteSaveId: -1, questNameOverride: '@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB'";

        Assert.True(TryParseObjectiveMarker(host, out var a));
        Assert.True(TryParseObjectiveMarker(joiner, out var b));
        Assert.Equal(a, b);
        Assert.Null(DescribeDivergence(a, b, "peer"));
    }

    [Fact]
    public void ALevelSwitchSaveCarriesNoObjectiveAndIsNotABeat()
        // host kcd.log 143508, 20:43:34.6 -- the kutnohorsko -> trosecko switch
        => Assert.False(TryParseObjectiveMarker(
            "InitiateSaveGame() type: LevelSwitchSave, overwriteSaveId: -1, questNameOverride: ''", out _));

    [Theory]
    // The two lines that repeat the same value a few lines after every
    // InitiateSaveGame. Matching these too would fire each beat three times.
    [InlineData("Sending E_MMI_SaveGameRequestBegin for savegame type AutoSave, questNameOverride: '@qname_prepadeni_KsSs|@mq01__pre_crouch_GayI'")]
    [InlineData("Sending E_MMI_SaveGameRequestEnd for savegame type AutoSave, questNameOverride: '@qname_prepadeni_KsSs|@mq01__pre_crouch_GayI'")]
    // The save-slot listing printed at startup, which names quests too.
    [InlineData("#04 '%USER%/saves/playline1/autosave010.whs', ver: 10505, newGameVer: 10505, DLCs: , Size: 1323 kB, level:'trosecko', 1|10|@qname_zachrana_FbKt|@zachrana_f")]
    [InlineData("[KCD2-MP-DATA] v2 8418 581.980 755.163 3371.982 149.683 -0.0012 0 100.00 126.67")]
    [InlineData("")]
    public void NonBeatLinesAreIgnored(string line)
        => Assert.False(TryParseObjectiveMarker(line, out _));

    [Fact]
    public void AnUnterminatedOverrideIsRefusedRatherThanGuessed()
        => Assert.False(TryParseObjectiveMarker(
            "InitiateSaveGame() type: AutoSave, overwriteSaveId: -1, questNameOverride: '@qname_truncated", out _));

    [Fact]
    public void AnOverlongKeyIsRefusedRatherThanTruncated()
        => Assert.False(TryParseObjectiveMarker(
            "InitiateSaveGame() questNameOverride: '" + new string('x', Protocol.MaxStoryBeatTextLen + 1) + "'", out _));

    // ------------------------------------------------------------------
    // Display
    // ------------------------------------------------------------------

    [Theory]
    [InlineData("@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB", "prepadeni: prepadeni nasleduj ptacka")]
    // Two real keys carry a doubled separator; neither may reach the screen
    // as a double space or a trailing one.
    [InlineData("@qname_zachrana_FbKt|@zachrana_zastav_krvaceni__tHDn", "zachrana: zachrana zastav krvaceni")]
    [InlineData("@qname_prepadeni_KsSs|@mq01__pre_crouch_GayI", "prepadeni: mq01 pre crouch")]
    [InlineData("@qname_prepadeni_KsSs", "prepadeni")]
    public void KeysArePrettifiedForTheScreen(string marker, string expected)
        => Assert.Equal(expected, Humanize(marker));

    [Fact]
    public void AKeyWithoutTheFourCharacterTailKeepsEveryWord()
        => Assert.Equal("quest: do the thing", Humanize("@qname_quest|@do_the_thing"));

    [Fact]
    public void AnEmptyMarkerIsNamedRatherThanBlank()
        => Assert.Equal("(no quest)", Humanize(""));

    // ------------------------------------------------------------------
    // Divergence
    // ------------------------------------------------------------------

    [Fact]
    public void DifferentObjectivesAreDescribedWithBothSidesNamed()
    {
        // The real 21:40:36 - 21:50:00 window: the joiner had reached the
        // sneak beat, the host was still on "ask Hans", and the joiner held
        // the claim on Hans and four other camp NPCs throughout.
        var msg = DescribeDivergence(
            "@qname_prepadeni_KsSs|@prepadeni_zjisti_od_ptack_3seP",
            "@qname_prepadeni_KsSs|@mq01__pre_crouch_GayI",
            "MooseSplosion");

        Assert.NotNull(msg);
        Assert.Contains("MooseSplosion", msg);
        Assert.Contains("mq01", msg);
        Assert.Contains("zjisti", msg);
    }

    [Theory]
    [InlineData(null, "@qname_a|@b")]
    [InlineData("@qname_a|@b", null)]
    [InlineData("", "@qname_a|@b")]
    public void AnUnknownSideIsNeverReportedAsADivergence(string? local, string? peer)
        => Assert.Null(DescribeDivergence(local, peer, "peer"));

    // ------------------------------------------------------------------
    // Wire shape
    // ------------------------------------------------------------------

    [Fact]
    public void TheUpPayloadIsKindLengthText()
    {
        const string marker = "@qname_prepadeni_KsSs|@mq01__pre_crouch_GayI";
        var payload = BuildUpPayload(Protocol.StoryBeatKindObjective, marker);

        Assert.Equal(Protocol.StoryBeatKindObjective, payload[0]);
        Assert.Equal(marker.Length, payload[1]);             // pure ASCII here
        Assert.Equal(2 + marker.Length, payload.Length);
        Assert.Equal(marker, System.Text.Encoding.UTF8.GetString(payload, 2, payload[1]));
    }

    [Fact]
    public void AnOverlongTextIsClampedSoTheLengthByteStaysHonest()
    {
        var payload = BuildUpPayload(Protocol.StoryBeatKindObjective, new string('x', 400));
        Assert.Equal(Protocol.MaxStoryBeatTextLen, payload[1]);
        Assert.Equal(2 + Protocol.MaxStoryBeatTextLen, payload.Length);
    }
}
