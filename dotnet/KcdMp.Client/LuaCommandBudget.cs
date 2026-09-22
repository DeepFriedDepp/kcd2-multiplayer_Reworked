using System.Text;

namespace KcdMp.Client;

/// <summary>
/// WO-110 (docs/WO-110-findings.md s2.9): the game's console API truncates an
/// ExecuteString command past roughly 2,100 URL-ENCODED characters -- measured
/// live 2026-09-22: 2,067 encoded characters execute, 2,167 fail with
/// "unfinished string near '&lt;eof&gt;'", whatever the decoded length. The
/// engine logs a Lua error and the HTTP call still returns 200, so nothing on
/// the agent side ever saw it. HttpGameTransport's batch budget was 4,000 RAW
/// characters (never safe past ~1,900 encoded), and the WO-103 native-scan
/// push (40 entries, colons and commas encoding to three characters each)
/// was ~2,900 encoded -- so it most likely never landed in the field.
///
/// Every command the agent sends is now measured in encoded characters
/// against <see cref="MaxEncodedCommandChars"/>: batches flush before they
/// would cross it, the native-scan push is chunked by it, and a single
/// statement that cannot fit is dropped LOUDLY (MP-BATCH-DROP reason=oversize)
/// instead of poisoning a batch.
/// </summary>
public static class LuaCommandBudget
{
    /// <summary>Safe encoded size of one ExecuteString command (the query value, excluding the base URL). Measured ceiling ~2,100; margin for the '#', the pcall wrappers and any escaping the batch adds.</summary>
    public const int MaxEncodedCommandChars = 1900;

    /// <summary>Encoded overhead of one batched statement: "pcall(function() " + " end)\n" once escaped.</summary>
    public static readonly int WrapperEncodedChars = Uri.EscapeDataString("pcall(function()  end)\n").Length;

    /// <summary>The encoded length of a Lua statement as the console would receive it.</summary>
    public static int EncodedLength(string lua) => Uri.EscapeDataString(lua).Length;

    /// <summary>
    /// Splits <paramref name="entries"/> (already-formatted CSV entries) into
    /// chunks whose joined, encoded length stays under <paramref name="budgetEncoded"/>
    /// once wrapped in <paramref name="wrapperEncoded"/> characters of statement.
    /// Entries are never split; a single entry over the budget goes into a
    /// chunk of its own and is the caller's problem to reject.
    /// </summary>
    public static List<string> ChunkCsv(IReadOnlyList<string> entries, int budgetEncoded, int wrapperEncoded)
    {
        var chunks = new List<string>();
        var cur = new StringBuilder();
        int curEncoded = 0;
        const int commaEncoded = 3;   // ',' -> %2C
        foreach (var e in entries)
        {
            int enc = EncodedLength(e);
            if (cur.Length > 0 && wrapperEncoded + curEncoded + commaEncoded + enc > budgetEncoded)
            {
                chunks.Add(cur.ToString()); cur.Clear(); curEncoded = 0;
            }
            if (cur.Length > 0) { cur.Append(','); curEncoded += commaEncoded; }
            cur.Append(e); curEncoded += enc;
        }
        if (cur.Length > 0 || chunks.Count == 0) chunks.Add(cur.ToString());
        return chunks;
    }
}
