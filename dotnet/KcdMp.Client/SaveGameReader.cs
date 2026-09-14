using System.IO.Compression;
using System.Text;
using System.Xml;

namespace KcdMp.Client;

/// <summary>
/// WO-96: read-only access to a KCD2 <c>.whs</c> save file.
///
/// Format, established by WO-92 §7 item 3 and confirmed byte-for-byte here on
/// the 2026-09-13 host's <c>autosave009.whs</c>:
/// <code>
///   [u32 0xFFFFFFFF][i32 descLen][UTF-8 XML description, descLen bytes]
///   then N blocks of [i32 compressedLen][i32 rawLen][zlib stream, compressedLen bytes]
///   then a 64-byte footer
/// </code>
/// The inflated stream is the engine's serialised state; somewhere inside it
/// a <c>ConceptState</c> chunk carries a plain XML tree
/// <c>&lt;Roots&gt;&lt;_Barbora&gt;&lt;Nodes&gt;&lt;_trosecko&gt;&lt;Nodes&gt;&lt;_socky&gt;…</c>
/// whose leaves are the concept graph's State-node values
/// (<c>&lt;_sockyState value="Hospoda"/&gt;</c>) and, for every journal
/// objective, a display node <c>&lt;_objectiveVisual38&gt;&lt;Logs&gt;&lt;Active UpdateTime="…"/&gt;</c>.
/// Only non-default state is persisted: a quest that has never started has
/// no subtree, an objective that was never shown has no display node.
///
/// Nothing here writes. The file is opened with read sharing so the game's
/// own writer is never blocked.
/// </summary>
public static class SaveGameReader
{
    public sealed record Description(string QuestNameOverride, string LevelName, string SaveType, long SaveTime, int SaveId);

    /// <summary>Only the plaintext header: cheap, no inflation.</summary>
    public static Description? TryReadDescription(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var head = new byte[8];
            if (fs.Read(head, 0, 8) != 8) return null;
            if (BitConverter.ToUInt32(head, 0) != 0xFFFFFFFFu) return null;
            int descLen = BitConverter.ToInt32(head, 4);
            if (descLen <= 0 || descLen > 1 << 20) return null;
            var desc = new byte[descLen];
            int got = 0;
            while (got < descLen) { int n = fs.Read(desc, got, descLen - got); if (n <= 0) break; got += n; }
            if (got != descLen) return null;
            string xml = Encoding.UTF8.GetString(desc);
            return ParseDescription(xml);
        }
        catch { return null; }
    }

    internal static Description? ParseDescription(string xml)
    {
        static string Attr(string xml, string name)
        {
            int at = xml.IndexOf(name + "=\"", StringComparison.Ordinal);
            if (at < 0) return string.Empty;
            int s = at + name.Length + 2;
            int e = xml.IndexOf('"', s);
            return e < 0 ? string.Empty : xml[s..e];
        }
        if (xml.IndexOf("<C_SaveGameDescription", StringComparison.Ordinal) < 0) return null;
        long.TryParse(Attr(xml, "SaveTime"), out long t);
        int.TryParse(Attr(xml, "SaveId"), out int id);
        return new Description(Attr(xml, "QuestNameOverride"), Attr(xml, "LevelName"), Attr(xml, "SaveType"), t, id);
    }

    /// <summary>
    /// Inflates every zlib block and returns the raw state stream, or null
    /// when the framing does not match (not a save, truncated, still being
    /// written). Bounded: refuses more than <paramref name="maxInflated"/>.
    /// </summary>
    public static byte[]? TryInflate(byte[] file, int maxInflated = 64 << 20)
    {
        try
        {
            if (file.Length < 8 + 64 || BitConverter.ToUInt32(file, 0) != 0xFFFFFFFFu) return null;
            int descLen = BitConverter.ToInt32(file, 4);
            int pos = 8 + descLen;
            if (descLen <= 0 || pos >= file.Length - 64) return null;
            using var outMs = new MemoryStream();
            while (pos + 8 <= file.Length - 64)
            {
                int clen = BitConverter.ToInt32(file, pos);
                int rlen = BitConverter.ToInt32(file, pos + 4);
                if (clen == -1)
                {
                    // a STORED block: compressedLen 0xFFFFFFFF, then rawLen bytes
                    // verbatim (incompressible data; seen once in the 2026-09-13
                    // host's autosave008 at offset 1,030,211, rawLen 32,768,
                    // followed by an ordinary zlib block)
                    if (rlen <= 0 || rlen > file.Length - pos - 8) return null;
                    outMs.Write(file, pos + 8, rlen);
                    pos += 8 + rlen;
                }
                else
                {
                    if (clen <= 2 || clen > file.Length - pos - 8) return null;
                    // skip the 2-byte zlib header; DeflateStream wants the raw stream
                    using var ms = new MemoryStream(file, pos + 10, clen - 2, writable: false);
                    using var ds = new DeflateStream(ms, CompressionMode.Decompress);
                    ds.CopyTo(outMs);
                    pos += 8 + clen;
                }
                if (outMs.Length > maxInflated) return null;
            }
            // the blocks must end exactly at the 64-byte footer (observed on
            // every real save read); anything else is truncated or foreign
            if (pos != file.Length - 64) return null;
            return outMs.ToArray();
        }
        catch { return null; }
    }

    /// <summary>
    /// The <c>&lt;Roots&gt;…&lt;/Roots&gt;</c> concept-state tree of a save,
    /// parsed, or null. The tree is line-broken plain XML embedded in a
    /// binary stream; it is located by its markers, not by chunk framing.
    /// </summary>
    public static XmlDocument? TryReadConceptState(string path)
    {
        try
        {
            byte[] file = File.ReadAllBytes(path);
            var raw = TryInflate(file);
            if (raw is null) return null;
            return ParseConceptState(raw);
        }
        catch { return null; }
    }

    internal static XmlDocument? ParseConceptState(byte[] raw)
    {
        int s = IndexOf(raw, "<Roots>"u8);
        if (s < 0) return null;
        int e = IndexOf(raw, "</Roots>"u8, s);
        if (e < 0) return null;
        string xml = Encoding.UTF8.GetString(raw, s, e + 8 - s);
        var doc = new XmlDocument { PreserveWhitespace = false };
        doc.LoadXml(xml);
        return doc;
    }

    private static int IndexOf(byte[] hay, ReadOnlySpan<byte> needle, int from = 0)
    {
        int idx = hay.AsSpan(from).IndexOf(needle);
        return idx < 0 ? -1 : idx + from;
    }

    /// <summary>
    /// The newest save under <paramref name="savesRoot"/><c>/playline*/</c>
    /// whose description carries exactly <paramref name="marker"/>, or null.
    /// The engine names the folder <c>saves</c> under its user folder
    /// (kcd.log: <c>User folder is '…\Saved Games\KingdomCome2'</c>) and one
    /// <c>playlineN</c> per profile slot.
    /// </summary>
    public static string? FindNewestSaveForMarker(string savesRoot, string marker, DateTime notOlderThanUtc)
    {
        try
        {
            if (!Directory.Exists(savesRoot)) return null;
            string? best = null; DateTime bestT = DateTime.MinValue;
            foreach (var f in Directory.EnumerateFiles(savesRoot, "*.whs", SearchOption.AllDirectories))
            {
                DateTime t = File.GetLastWriteTimeUtc(f);
                if (t < notOlderThanUtc || t <= bestT) continue;
                var d = TryReadDescription(f);
                if (d is null || !string.Equals(d.QuestNameOverride, marker, StringComparison.Ordinal)) continue;
                best = f; bestT = t;
            }
            return best;
        }
        catch { return null; }
    }

    /// <summary>The newest save of any kind under the root, or null.</summary>
    public static string? FindNewestSave(string savesRoot)
    {
        try
        {
            if (!Directory.Exists(savesRoot)) return null;
            string? best = null; DateTime bestT = DateTime.MinValue;
            foreach (var f in Directory.EnumerateFiles(savesRoot, "*.whs", SearchOption.AllDirectories))
            {
                DateTime t = File.GetLastWriteTimeUtc(f);
                if (t > bestT) { best = f; bestT = t; }
            }
            return best;
        }
        catch { return null; }
    }

    /// <summary>
    /// <c>User folder is 'C:\…\Saved Games\KingdomCome2'</c> from kcd.log, or
    /// null. The line is written once at engine start, before the agent's
    /// tail begins, so the agent reads the head of the file for it.
    /// </summary>
    public static string? TryParseUserFolder(ReadOnlySpan<char> line)
    {
        const string marker = "User folder is '";
        int at = line.IndexOf(marker, StringComparison.Ordinal);
        if (at < 0) return null;
        var rest = line[(at + marker.Length)..];
        int end = rest.IndexOf('\'');
        if (end <= 0) return null;
        return rest[..end].ToString();
    }

    public static string? TryReadUserFolderFromLogHead(string logPath, int maxLines = 4000)
    {
        try
        {
            using var fs = new FileStream(logPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var sr = new StreamReader(fs, Encoding.UTF8, true);
            for (int i = 0; i < maxLines; i++)
            {
                string? line = sr.ReadLine();
                if (line is null) break;
                var uf = TryParseUserFolder(line);
                if (uf is not null) return uf;
            }
        }
        catch { }
        return null;
    }

    /// <summary>The default user folder when kcd.log has not said otherwise.</summary>
    public static string DefaultUserFolder() =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Saved Games", "kingdomcome2");
}
