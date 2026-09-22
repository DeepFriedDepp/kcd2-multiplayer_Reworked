using KcdMp.Client;
using Xunit;

namespace KcdMp.Client.Tests;

/// <summary>WO-110: the console's measured ~2,100-encoded-character ceiling, kept as arithmetic.</summary>
public class LuaCommandBudgetTests
{
    [Fact]
    public void Encoded_length_counts_url_escaping_not_raw_characters()
    {
        Assert.Equal(1000, LuaCommandBudget.EncodedLength(new string('a', 1000)));
        Assert.Equal(3000, LuaCommandBudget.EncodedLength(new string(':', 1000)));   // %3A
        Assert.True(LuaCommandBudget.WrapperEncodedChars is > 20 and < 80);
    }

    [Fact]
    public void Budget_sits_under_the_measured_ceiling()
    {
        // 2,067 executed live, 2,167 did not (2026-09-22). The budget must sit
        // below the lower bound with room for the '#' and the pcall wrapper.
        Assert.True(LuaCommandBudget.MaxEncodedCommandChars <= 2000);
        Assert.True(LuaCommandBudget.MaxEncodedCommandChars >= 1500);
    }

    [Fact]
    public void A_77_entry_native_scan_chunks_under_the_budget_and_loses_nothing()
    {
        var entries = new List<string>();
        for (int i = 0; i < 77; i++)
            entries.Add(string.Create(System.Globalization.CultureInfo.InvariantCulture, $"ttkc_some_npc_name_{i:D2}:{2300 + i * 1.5:F3}:{2000 + i * 0.7:F3}:{100 + i * 0.1:F3}:{i * 0.05:F4}:0"));
        var chunks = LuaCommandBudget.ChunkCsv(entries, 1500, 120);
        Assert.True(chunks.Count >= 3, $"expected several chunks, got {chunks.Count}");
        foreach (var c in chunks)
            Assert.True(120 + LuaCommandBudget.EncodedLength(c) <= 1500, $"chunk of {c.Length} raw / {LuaCommandBudget.EncodedLength(c)} encoded over budget");
        var rejoined = string.Join(',', chunks).Split(',');
        Assert.Equal(entries, rejoined);   // order and content preserved, nothing dropped
    }

    [Fact]
    public void Empty_input_yields_one_empty_chunk()
    {
        var chunks = LuaCommandBudget.ChunkCsv(Array.Empty<string>(), 1500, 120);
        Assert.Single(chunks);
        Assert.Equal(string.Empty, chunks[0]);
    }
}
