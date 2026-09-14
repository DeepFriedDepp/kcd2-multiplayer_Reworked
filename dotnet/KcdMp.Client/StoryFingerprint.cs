using System.Text;
using System.Xml;

namespace KcdMp.Client;

/// <summary>
/// WO-96: a per-quest story fingerprint -- the state of every registered
/// journal objective of one main quest, read from the ConceptState tree of a
/// save (<see cref="SaveGameReader"/>), two bits per objective, indexed by
/// <see cref="QuestObjectiveRegistry"/> order so both machines read the same
/// index the same way.
///
/// Wire text (StoryBeat kind 5, ≤ 128 chars):
/// <c>&lt;registryId&gt;:&lt;questKey&gt;:&lt;hex&gt;</c>. A receiver whose registry id differs
/// refuses to compare (the indices would silently mean different things).
///
/// State per objective: 0 = none (no display node in the tree, or an empty
/// log), 1 = active (a log exists whose last entry is not Done/Failed --
/// covers Started/Active/Updated and the minigame-specific names such as the
/// sack-carrying tracker's), 2 = done, 3 = failed. An objective displayed by
/// several nodes takes the highest state seen.
/// </summary>
public static class StoryFingerprint
{
    public const byte None = 0, Active = 1, Done = 2, Failed = 3;

    public static string StateName(byte s) => s switch { Active => "active", Done => "done", Failed => "failed", _ => "none" };

    /// <summary>
    /// Reads the states of <paramref name="quest"/>'s objectives from a parsed
    /// ConceptState tree. Returns all-None when the quest has no subtree (never
    /// started) -- that is a real answer, not an error. Null only when the
    /// document has no Roots.
    /// </summary>
    public static byte[]? Read(XmlDocument concept, QuestObjectiveRegistry.Quest quest)
    {
        var roots = concept.DocumentElement;
        if (roots is null || roots.Name != "Roots") return null;
        var states = new byte[quest.Objectives.Length];
        // /Roots/<db>/Nodes/_<level>/Nodes/_<quest>
        XmlNode? questNode = null;
        foreach (XmlNode db in roots.ChildNodes)
        {
            if (db.NodeType != XmlNodeType.Element) continue;
            questNode = db.SelectSingleNode($"Nodes/_{quest.Level}/Nodes/_{quest.Name}");
            if (questNode is not null) break;
        }
        if (questNode is null) return states;
        for (int i = 0; i < quest.Objectives.Length; i++)
        {
            byte best = None;
            foreach (var p in quest.Objectives[i].Paths)
            {
                var sb = new StringBuilder();
                foreach (var seg in p.Split('.')) sb.Append("Nodes/_").Append(seg).Append('/');
                sb.Append("Logs");
                var logs = questNode.SelectSingleNode(sb.ToString());
                if (logs is null) continue;
                byte s = None;
                XmlNode? last = null;
                foreach (XmlNode l in logs.ChildNodes) if (l.NodeType == XmlNodeType.Element) last = l;
                if (last is not null)
                    s = last.Name switch { "Done" => Done, "Completed" => Done, "Failed" => Failed, _ => Active };
                if (s > best) best = s;
            }
            states[i] = best;
        }
        return states;
    }

    public static string Encode(string registryId, string questKey, byte[] states)
    {
        int bytes = (states.Length * 2 + 7) / 8;
        var buf = new byte[bytes];
        for (int i = 0; i < states.Length; i++)
            buf[i / 4] |= (byte)((states[i] & 3) << (2 * (i % 4)));
        return $"{registryId}:{questKey}:{Convert.ToHexString(buf).ToLowerInvariant()}";
    }

    public static bool TryDecode(string text, out string registryId, out string questKey, out byte[] packed)
    {
        registryId = questKey = string.Empty; packed = Array.Empty<byte>();
        if (string.IsNullOrEmpty(text) || text.Length > Protocol.MaxStoryBeatTextLen) return false;
        var parts = text.Split(':');
        if (parts.Length != 3) return false;
        if (parts[0].Length is < 6 or > 32 || parts[1].Length is < 1 or > 40) return false;
        foreach (char c in parts[0]) if (!Uri.IsHexDigit(c)) return false;
        foreach (char c in parts[1]) if (!(char.IsAsciiLetterOrDigit(c) || c == '_')) return false;
        if (parts[2].Length % 2 != 0 || parts[2].Length > 128) return false;
        foreach (char c in parts[2]) if (!Uri.IsHexDigit(c)) return false;
        try { packed = Convert.FromHexString(parts[2]); } catch { return false; }
        registryId = parts[0]; questKey = parts[1].ToLowerInvariant();
        return true;
    }

    public static byte[] Unpack(byte[] packed, int count)
    {
        var states = new byte[count];
        for (int i = 0; i < count && i / 4 < packed.Length; i++)
            states[i] = (byte)((packed[i / 4] >> (2 * (i % 4))) & 3);
        return states;
    }

    /// <summary>
    /// Objectives the peer has reached (active/done) that we have not started,
    /// and the reverse. Indices into the quest's objective list.
    /// </summary>
    public static (List<int> TheyHaveWeLack, List<int> WeHaveTheyLack, List<int> Differ) Compare(byte[] ours, byte[] theirs)
    {
        var a = new List<int>(); var b = new List<int>(); var d = new List<int>();
        int n = Math.Min(ours.Length, theirs.Length);
        for (int i = 0; i < n; i++)
        {
            if (ours[i] == theirs[i]) continue;
            d.Add(i);
            if (theirs[i] != None && ours[i] == None) a.Add(i);
            else if (ours[i] != None && theirs[i] == None) b.Add(i);
        }
        return (a, b, d);
    }

    public static string Labels(QuestObjectiveRegistry.Quest quest, IEnumerable<int> idx, byte[]? states = null)
    {
        var sb = new StringBuilder();
        foreach (int i in idx)
        {
            if (i < 0 || i >= quest.Objectives.Length) continue;
            if (sb.Length > 0) sb.Append("; ");
            sb.Append(quest.Objectives[i].Label);
            if (states is not null && i < states.Length) sb.Append(" (").Append(StateName(states[i])).Append(')');
        }
        return sb.ToString();
    }
}
