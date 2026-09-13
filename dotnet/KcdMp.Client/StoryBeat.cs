using System.Text;

namespace KcdMp.Client;

/// <summary>
/// WO-90: reading each player's story position out of the log the agent is
/// already tailing, and saying in words when the two have drifted apart.
///
/// Background, because this is the first quest-state anything in the project:
/// nothing here existed before. An exhaustive search of the Lua, the agent,
/// the relay and the native DLL found no quest, objective, journal, chapter
/// or cutscene STATE of any kind -- only a Rendered-cutscene pause detector
/// (<see cref="LogTailGameTransport"/>) whose entire job is to keep ghost
/// bodies moving while <c>Script.SetTimer</c> is frozen. Two players
/// therefore ran two independent campaigns in one shared NPC name space.
///
/// The signal used here is the engine's own, and it costs nothing to obtain:
/// at every checkpoint save kcd.log writes
///
///   InitiateSaveGame() type: AutoSave, overwriteSaveId: -1,
///     questNameOverride: '@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB'
///
/// The key is byte-identical on both machines for the same objective -- true
/// of every shared beat in the 2026-09-12 field logs -- so exact equality is
/// a sound "are we at the same point" test.
///
/// **It is a coarse clock and is used accordingly.** Six markers in ninety
/// minutes on the host, four on the joiner. For most of the half hour in
/// which one player held and dragged the other's story NPCs, both clients'
/// last-known objective was the same string. That is why this layer reports
/// and never gates: the fix for the damage is the receiver-side divergence
/// release in kdcmp.lua, which needs no wire state at all.
/// </summary>
public static class StoryBeat
{
    /// <summary>
    /// The one kcd.log line that marks a quest objective. Deliberately
    /// anchored on <c>InitiateSaveGame()</c> and not on the two
    /// <c>E_MMI_SaveGameRequestBegin/End</c> lines that carry the same
    /// <c>questNameOverride</c> value a few lines later -- matching all three
    /// would fire the same beat three times per save.
    /// </summary>
    private const string InitiateMarker = "InitiateSaveGame()";

    private const string OverrideMarker = "questNameOverride: '";

    /// <summary>
    /// Extracts the quest+objective key from one raw engine log line.
    /// Returns false for any line that is not an <c>InitiateSaveGame()</c>
    /// with a non-empty override -- including the level-switch saves, which
    /// legitimately carry <c>questNameOverride: ''</c>.
    /// </summary>
    public static bool TryParseObjectiveMarker(ReadOnlySpan<char> line, out string marker)
    {
        marker = string.Empty;
        if (line.IndexOf(InitiateMarker, StringComparison.Ordinal) < 0) return false;

        int at = line.IndexOf(OverrideMarker, StringComparison.Ordinal);
        if (at < 0) return false;

        var rest = line[(at + OverrideMarker.Length)..];
        int end = rest.IndexOf('\'');
        if (end <= 0) return false;                    // empty or unterminated

        var value = rest[..end].Trim();
        if (value.Length == 0) return false;
        if (value.Length > Protocol.MaxStoryBeatTextLen) return false;

        marker = value.ToString();
        return true;
    }

    /// <summary>
    /// Turns a raw key into something worth putting on a player's screen:
    /// <c>"@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB"</c> becomes
    /// <c>"prepadeni: nasleduj ptacka"</c>.
    ///
    /// Display only. The comparison everywhere else uses the raw key, so a
    /// wrong guess here can make a toast uglier and can never make two
    /// clients disagree about whether they are at the same beat. That matters
    /// because the trailing four-character token on every key
    /// (<c>_KsSs</c>, <c>_ZyXB</c>, <c>_9O8s</c>) is an unexplained
    /// localisation disambiguator -- stripping it is a cosmetic guess, and it
    /// is confined to this method on purpose.
    /// </summary>
    public static string Humanize(string marker)
    {
        if (string.IsNullOrWhiteSpace(marker)) return "(no quest)";

        var parts = marker.Split('|', 2);
        string quest = Prettify(parts[0], "@qname_");
        string objective = parts.Length > 1 ? Prettify(parts[1], "@") : string.Empty;

        if (quest.Length == 0) return objective.Length == 0 ? marker : objective;
        if (objective.Length == 0) return quest;
        return $"{quest}: {objective}";
    }

    private static string Prettify(string raw, string prefix)
    {
        var s = raw.Trim();
        if (s.StartsWith(prefix, StringComparison.Ordinal)) s = s[prefix.Length..];

        // Drop the trailing "_XXXX" disambiguator when it looks like one: an
        // underscore followed by exactly four alphanumerics at the very end.
        if (s.Length > 5 && s[^5] == '_')
        {
            bool allAlnum = true;
            for (int i = s.Length - 4; i < s.Length; i++)
                if (!char.IsLetterOrDigit(s[i])) { allAlnum = false; break; }
            if (allAlnum) s = s[..^5];
        }

        // Several real keys carry a doubled separator ("@mq01__pre_crouch_GayI",
        // "@zachrana_zastav_krvaceni__tHDn"), so collapse runs rather than
        // emitting double spaces on screen.
        var sb = new StringBuilder(s.Length);
        bool lastWasSpace = false;
        foreach (char c in s)
        {
            char outc = c == '_' ? ' ' : c;
            if (outc == ' ')
            {
                if (lastWasSpace) continue;
                lastWasSpace = true;
            }
            else lastWasSpace = false;
            sb.Append(outc);
        }
        return sb.ToString().Trim();
    }

    /// <summary>
    /// One line for the player when this client and a peer are at different
    /// objectives, or null when they agree (or when either side is unknown).
    /// Naming both sides is the point: the symptom a player actually sees is
    /// an NPC behaving oddly, and "you are at a different point in the story"
    /// is the missing half of that sentence.
    /// </summary>
    public static string? DescribeDivergence(string? localMarker, string? peerMarker, string peerName)
    {
        if (string.IsNullOrEmpty(localMarker) || string.IsNullOrEmpty(peerMarker)) return null;
        if (string.Equals(localMarker, peerMarker, StringComparison.Ordinal)) return null;
        return $"{peerName} is on \"{Humanize(peerMarker)}\" -- you are on \"{Humanize(localMarker)}\"";
    }

    // -------------------------------------------------------------------------
    // WO-94 Shared Quests
    // -------------------------------------------------------------------------

    /// <summary>
    /// WO-94: the quest half of an objective marker, lowercased, or null.
    /// "@qname_prepadeni_KsSs|@prepadeni_nasleduj_ptacka_ZyXB" -> "prepadeni";
    /// "@qname_poslednipomazani_1DR8|..." -> "poslednipomazani" (the engine
    /// lowercases the XML name posledniPomazani here, field log 2026-08-25).
    /// The trailing four-character disambiguator is dropped by the same rule
    /// <see cref="Prettify"/> uses. The mod matches this case-insensitively
    /// against its generated registry.
    /// </summary>
    public static string? TryQuestNameFromMarker(string? marker)
    {
        if (string.IsNullOrWhiteSpace(marker)) return null;
        var quest = marker.Split('|', 2)[0].Trim();
        const string prefix = "@qname_";
        if (!quest.StartsWith(prefix, StringComparison.Ordinal)) return null;
        quest = quest[prefix.Length..];
        if (quest.Length > 5 && quest[^5] == '_')
        {
            bool allAlnum = true;
            for (int i = quest.Length - 4; i < quest.Length; i++)
                if (!char.IsLetterOrDigit(quest[i])) { allAlnum = false; break; }
            if (allAlnum) quest = quest[..^5];
        }
        quest = quest.Trim('_');
        if (quest.Length == 0) return null;
        foreach (char c in quest)
            if (!(char.IsLetterOrDigit(c) || c == '_')) return null;
        return quest.ToLowerInvariant();
    }

    /// <summary>
    /// WO-94: a Haste path as this project emits it -- "quest.trigger",
    /// ASCII letters/digits/underscore/dot only, 3..128 chars, exactly one dot
    /// with non-empty halves. Applied to every kind-2/3/4 text BEFORE it is
    /// interpolated into a Lua literal; the mod then additionally requires the
    /// path to be in its generated registry.
    /// </summary>
    public static bool IsValidBeatPath(string? path)
    {
        if (string.IsNullOrEmpty(path) || path.Length < 3 || path.Length > Protocol.MaxStoryBeatTextLen) return false;
        int dots = 0;
        foreach (char c in path)
        {
            if (c == '.') { dots++; continue; }
            if (!(c < 128 && (char.IsLetterOrDigit(c) || c == '_'))) return false;
        }
        if (dots != 1) return false;
        return path[0] != '.' && path[^1] != '.';
    }

    /// <summary>
    /// WO-94: the suffix appended to an agent log line that fires inside a
    /// catch-up hazard window. Distinct on purpose: grep "CATCHUP-HAZARD".
    /// </summary>
    public static string CatchupHazardTag(string beat, string who, string where, TimeSpan sinceFire) =>
        $" [CATCHUP-HAZARD during catch-up {beat} (fired {where} by {who} {sinceFire.TotalSeconds:F1}s ago)]";

    /// <summary>Builds the 0x37 payload: [kind:1][len:1][text utf8].</summary>
    public static byte[] BuildUpPayload(byte kind, string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        if (bytes.Length > Protocol.MaxStoryBeatTextLen)
            bytes = bytes[..Protocol.MaxStoryBeatTextLen];

        var payload = new byte[2 + bytes.Length];
        payload[0] = kind;
        payload[1] = (byte)bytes.Length;
        Buffer.BlockCopy(bytes, 0, payload, 2, bytes.Length);
        return payload;
    }
}
