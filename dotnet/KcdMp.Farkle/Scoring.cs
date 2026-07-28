namespace KcdMp.Farkle;

/// <summary>
/// The v1 Farkle scoring table, exactly as specified for this mod -- not
/// researched from the in-game rules, and deliberately narrower in places
/// (no badges, no Devil's Head).
///
/// A KEEP selection is valid only if every die in it belongs to some scoring
/// group; a straight consumes the entire selection as a single group, so it
/// can never combine with anything else. Everything else decomposes per
/// face: three or more of a face is one "of a kind" group (with 4/5/6 of a
/// kind doubling/quadrupling/octupling the base triple), and any leftover 1s
/// or 5s each score individually. A leftover 2, 3, 4, or 6 that isn't part of
/// a three-or-more group makes the whole selection invalid.
/// </summary>
public static class Scoring
{
    /// <summary>
    /// Scores a KEEP selection. Returns false (with <paramref name="score"/>
    /// left at 0) if the selection contains any die that isn't part of a
    /// valid scoring group -- the caller must reject the intent rather than
    /// score the dice that did qualify.
    /// </summary>
    public static bool TryScore(IReadOnlyList<Die> selected, out int score)
    {
        score = 0;
        if (selected.Count == 0) return false;

        Span<int> counts = stackalloc int[7]; // index 1..6; 0 unused
        foreach (var die in selected) counts[die.Face]++;

        // A straight consumes every die in the selection; nothing else can
        // be mixed in, so these checks are only reachable when the counts
        // match exactly.
        if (selected.Count == 6 && IsExactly(counts, 1, 1, 1, 1, 1, 1)) { score = 1500; return true; }
        if (selected.Count == 5 && IsExactly(counts, 1, 1, 1, 1, 1, 0)) { score = 500; return true; }
        if (selected.Count == 5 && IsExactly(counts, 0, 1, 1, 1, 1, 1)) { score = 750; return true; }

        int total = 0;
        for (byte face = 1; face <= 6; face++)
        {
            int c = counts[face];
            if (c == 0) continue;

            if (c >= 3)
            {
                int baseValue = face == 1 ? 1000 : face * 100;
                int multiplier = c switch { 3 => 1, 4 => 2, 5 => 4, 6 => 8, _ => 0 };
                total += baseValue * multiplier;
            }
            else if (face == 1) total += 100 * c;
            else if (face == 5) total += 50 * c;
            else return false; // a lone 2/3/4/6 outside a straight or a triple scores nothing
        }

        score = total;
        return true;
    }

    /// <summary>
    /// Whether any non-empty subset of these dice could score at all --
    /// i.e. whether rolling exactly this set is a bust. A straight always
    /// contains a 1 or a 5, so the single/triple checks alone are sufficient;
    /// no separate straight case is needed here.
    /// </summary>
    public static bool HasAnyScoringDie(IReadOnlyList<Die> dice)
    {
        Span<int> counts = stackalloc int[7];
        foreach (var die in dice) counts[die.Face]++;

        if (counts[1] > 0 || counts[5] > 0) return true;
        for (byte face = 1; face <= 6; face++)
            if (counts[face] >= 3) return true;
        return false;
    }

    private static bool IsExactly(Span<int> counts, int c1, int c2, int c3, int c4, int c5, int c6)
        => counts[1] == c1 && counts[2] == c2 && counts[3] == c3
        && counts[4] == c4 && counts[5] == c5 && counts[6] == c6;
}
