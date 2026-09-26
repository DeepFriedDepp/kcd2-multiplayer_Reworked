using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace KcdMp.Client;

/// <summary>
/// WO-125 Phase 1: the joiner's Henry files, one folder per host world
/// (docs/WO-125-findings.md). Kept under the agent's data folder
/// (KCDMP_DATA_DIR, else %LOCALAPPDATA%\KCDMP) in <c>henry/</c>: never in a
/// playline, never in the repo.
///
/// <code>
///   henry/&lt;worldTag&gt;/snap-&lt;yyyyMMddHHmmssfff&gt;-&lt;md5&gt;-&lt;source&gt;.hblk   a Henry block (WhsSave.SerializeBlock)
///   henry/&lt;worldTag&gt;/world.json                                  last joined + log-only pair details
///   henry/ledger.json                                             saves the mod made or saw land in a playline
///   henry/swept/                                                  files moved out of a playline (newest 8 kept)
/// </code>
///
/// The world tag is <see cref="WhsSave.SeedTag"/> of the playthrough seed: the
/// seed itself is never stored. A snapshot is keyed by the md5 of the host
/// save it pairs with (the save's own footer MD5 -- the one WorldSaved and
/// WorldOffer carry); the name carries it so the index can always be rebuilt
/// from the folder. Writes are .part + rename, then read back (hash + full
/// parse). A snapshot that does not parse is skipped and logged, and the next
/// older one is used.
/// </summary>
public sealed class HenryStore
{
    /// <summary>
    /// Snapshots kept per world. 100 = the host's autosave rotation (100 slots per
    /// playline, wh_sys_PlaylineSavegameCount, observed WO-112), the rotation that
    /// turns over fastest (WO-122's 5-minute schedule): every autosave the host can
    /// still load has its pair. Quick and manual saves rotate slower or not at all;
    /// a host save older than the oldest pair falls back to the newest snapshot.
    /// </summary>
    public const int KeepPerWorld = 100;

    /// <summary>A world not joined for this many days is deleted at agent start (logged). The maintainer may change it.</summary>
    public const int StaleDays = 90;

    public const string SourceBring = "bring", SourceFresh = "fresh", SourceSnapshot = "snapshot", SourceJoin = "join", SourceRestore = "restore";

    private readonly Func<DateTime> _now;
    private readonly Action<string> _log;
    private readonly object _gate = new();

    public string Root { get; }

    public HenryStore(string root, Func<DateTime>? now = null, Action<string>? log = null)
    {
        Root = root;
        _now = now ?? (() => DateTime.UtcNow);
        _log = log ?? (s => Console.WriteLine(s));
    }

    /// <summary>&lt;data&gt;/henry, where &lt;data&gt; is KCDMP_DATA_DIR or %LOCALAPPDATA%\KCDMP.</summary>
    public static string DefaultRoot()
    {
        string data = Environment.GetEnvironmentVariable("KCDMP_DATA_DIR") is { Length: > 0 } d
            ? d : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "KCDMP");
        return Path.Combine(data, "henry");
    }

    /// <summary>KCDMP_HENRY_NOW (an ISO date, tests of the 90-day rule) or the real clock.</summary>
    public static DateTime ClockFromEnv()
    {
        var s = Environment.GetEnvironmentVariable("KCDMP_HENRY_NOW");
        return s is { Length: > 0 } && DateTime.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var t) ? t : DateTime.UtcNow;
    }

    private static readonly Regex TagRx = new("^[0-9a-f]{10}$", RegexOptions.CultureInvariant);
    private static readonly Regex SnapRx = new(@"^snap-(\d{17})-([0-9a-f]{32})-([a-z]+)\.hblk$", RegexOptions.CultureInvariant);

    public sealed record Snapshot(string Tag, string File, string Md5, DateTime TakenUtc, string Source, long Bytes)
    {
        public string Short => $"{Md5[..8]}@{TakenUtc:yyyy-MM-dd HH:mm:ss}";
    }

    public sealed record WorldInfo(string Tag, DateTime LastJoinedUtc, int Count, long Bytes, string FirstSource);

    public string WorldDir(string tag) => Path.Combine(Root, tag);

    private static void CheckTag(string tag)
    {
        if (!TagRx.IsMatch(tag)) throw new ArgumentException("not a world tag: " + tag);
    }

    // ------------------------------------------------------------------ read

    /// <summary>Every snapshot of a world, newest first (by the time in the name).</summary>
    public List<Snapshot> Snapshots(string tag)
    {
        CheckTag(tag);
        var dir = WorldDir(tag);
        var o = new List<Snapshot>();
        if (!Directory.Exists(dir)) return o;
        foreach (var f in Directory.EnumerateFiles(dir, "snap-*.hblk"))
        {
            var m = SnapRx.Match(Path.GetFileName(f));
            if (!m.Success) continue;
            if (!DateTime.TryParseExact(m.Groups[1].Value, "yyyyMMddHHmmssfff", CultureInfo.InvariantCulture,
                                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out var t)) continue;
            long len;
            try { len = new FileInfo(f).Length; } catch (IOException) { continue; }
            o.Add(new Snapshot(tag, Path.GetFileName(f), m.Groups[2].Value, t, m.Groups[3].Value, len));
        }
        return o.OrderByDescending(s => s.TakenUtc).ThenByDescending(s => s.File, StringComparer.Ordinal).ToList();
    }

    public bool HasWorld(string tag) => Snapshots(tag).Count > 0;

    /// <summary>Load and fully check one snapshot; null (logged) when it does not parse.</summary>
    public WhsSave.HenryParts? Load(Snapshot s)
    {
        try
        {
            var b = File.ReadAllBytes(Path.Combine(WorldDir(s.Tag), s.File));
            return WhsSave.ParseBlock(b);
        }
        catch (Exception ex) when (ex is IOException or InvalidDataException or UnauthorizedAccessException)
        {
            _log($"MP-HENRY world {s.Tag}: snapshot {s.Short} is BROKEN ({ex.Message}) -- skipped, trying the next older one");
            return null;
        }
    }

    public sealed record Pick(Snapshot Snapshot, WhsSave.HenryParts Parts, string How);

    /// <summary>
    /// WO-125 Phase 5: the snapshot paired with the newest save of the host's
    /// current branch that has one (<paramref name="branchNewestFirst"/>: md5s),
    /// else the newest snapshot of the world. A broken snapshot is skipped.
    /// </summary>
    public Pick? PickFor(string tag, IReadOnlyList<string> branchNewestFirst)
    {
        var all = Snapshots(tag);
        int pos = 0;
        foreach (var md5 in branchNewestFirst)
        {
            foreach (var s in all.Where(x => x.Md5 == md5))
                if (Load(s) is { } p) return new Pick(s, p, pos == 0 ? "paired with the host's newest save" : $"paired with the host's branch save #{pos} (newest = 0)");
            pos++;
        }
        foreach (var s in all)
            if (Load(s) is { } p) return new Pick(s, p, branchNewestFirst.Count == 0 ? "newest (the host sent no branch)" : "newest (no snapshot pairs with any save of the host's branch)");
        return null;
    }

    // ------------------------------------------------------------------ write

    /// <summary>
    /// Store one snapshot, paired with the host save <paramref name="md5"/>
    /// (32 hex). Atomic (.part + rename), read back by hash and a full parse.
    /// Then the world is pruned to <see cref="KeepPerWorld"/>, oldest first.
    /// </summary>
    public Snapshot Store(string tag, WhsSave.HenryParts parts, string md5, string source, string detail)
    {
        CheckTag(tag);
        md5 = md5.ToLowerInvariant();
        if (!Regex.IsMatch(md5, "^[0-9a-f]{32}$")) throw new ArgumentException("md5 must be 32 hex characters");
        if (!Regex.IsMatch(source, "^[a-z]+$")) throw new ArgumentException("bad source");
        lock (_gate)
        {
            var dir = WorldDir(tag);
            Directory.CreateDirectory(dir);
            var data = WhsSave.SerializeBlock(parts);
            var t = _now();
            string name;
            int bump = 0;
            do name = $"snap-{t.AddMilliseconds(bump++):yyyyMMddHHmmssfff}-{md5}-{source}.hblk";
            while (File.Exists(Path.Combine(dir, name)));
            string final = Path.Combine(dir, name), part = final + ".part";
            using (var fs = new FileStream(part, FileMode.CreateNew, FileAccess.Write))
            {
                fs.Write(data);
                fs.Flush(true);
            }
            File.Move(part, final);
            var back = File.ReadAllBytes(final);
            if (!SHA256.HashData(back).AsSpan().SequenceEqual(SHA256.HashData(data)))
            {
                TryDelete(final);
                throw new IOException("the snapshot does not read back as written");
            }
            WhsSave.ParseBlock(back);   // throws if it would not load later
            var snap = new Snapshot(tag, name, md5, t, source, data.Length);
            UpdateWorld(tag, w =>
            {
                w.FirstSource ??= source;
                w.Pairs[name] = detail;
            });
            _log($"MP-HENRY world {tag}: stored {source} snapshot {snap.Short} ({data.Length} B, read back: hash + parse ok){(detail != "" ? " -- " + detail : "")}");
            Prune(tag);
            return snap;
        }
    }

    private void Prune(string tag)
    {
        var all = Snapshots(tag);
        foreach (var s in all.Skip(KeepPerWorld))
        {
            TryDelete(Path.Combine(WorldDir(tag), s.File));
            UpdateWorld(tag, w => w.Pairs.Remove(s.File));
            _log($"MP-HENRY world {tag}: pruned snapshot {s.Short} (keeping the newest {KeepPerWorld})");
        }
    }

    public void MarkJoined(string tag) => UpdateWorld(tag, w => w.LastJoinedUtc = _now());

    // ------------------------------------------------------------------ world.json

    private sealed class WorldFile
    {
        public DateTime LastJoinedUtc { get; set; }
        public string? FirstSource { get; set; }
        public Dictionary<string, string> Pairs { get; set; } = new(StringComparer.Ordinal);
    }

    private WorldFile ReadWorld(string tag)
    {
        var p = Path.Combine(WorldDir(tag), "world.json");
        try
        {
            if (File.Exists(p) && JsonSerializer.Deserialize<WorldFile>(File.ReadAllText(p)) is { } w) return w;
        }
        catch (Exception ex) when (ex is IOException or JsonException) { _log($"MP-HENRY world {tag}: world.json unreadable ({ex.Message}) -- rebuilt from the snapshot names"); }
        var snaps = Snapshots(tag);
        return new WorldFile { LastJoinedUtc = snaps.Count > 0 ? snaps[0].TakenUtc : _now(), FirstSource = snaps.LastOrDefault()?.Source };
    }

    private void UpdateWorld(string tag, Action<WorldFile> f)
    {
        lock (_gate)
        {
            Directory.CreateDirectory(WorldDir(tag));
            var w = ReadWorld(tag);
            f(w);
            var p = Path.Combine(WorldDir(tag), "world.json");
            File.WriteAllText(p + ".part", JsonSerializer.Serialize(w));
            File.Move(p + ".part", p, overwrite: true);
        }
    }

    public List<WorldInfo> Worlds()
    {
        var o = new List<WorldInfo>();
        if (!Directory.Exists(Root)) return o;
        foreach (var d in Directory.EnumerateDirectories(Root))
        {
            string tag = Path.GetFileName(d);
            if (!TagRx.IsMatch(tag)) continue;
            var snaps = Snapshots(tag);
            var w = ReadWorld(tag);
            o.Add(new WorldInfo(tag, w.LastJoinedUtc, snaps.Count, snaps.Sum(s => s.Bytes), w.FirstSource ?? "-"));
        }
        return o.OrderByDescending(x => x.LastJoinedUtc).ToList();
    }

    /// <summary>Delete one world's Henry files (mp_henry_files delete, mp_henry_reset, the 90-day rule). Logged by the caller's reason.</summary>
    public bool DeleteWorld(string tag, string why)
    {
        CheckTag(tag);
        var dir = WorldDir(tag);
        if (!Directory.Exists(dir)) return false;
        int n = Snapshots(tag).Count;
        Directory.Delete(dir, recursive: true);
        _log($"MP-HENRY world {tag}: DELETED ({n} snapshot(s)) -- {why}");
        return true;
    }

    /// <summary>The 90-day rule: every world not joined for <see cref="StaleDays"/> days goes. Returns the tags deleted.</summary>
    public List<string> CleanupStale()
    {
        var gone = new List<string>();
        foreach (var w in Worlds())
        {
            double days = (_now() - w.LastJoinedUtc).TotalDays;
            if (days > StaleDays && DeleteWorld(w.Tag, $"not joined for {days:F0} days (the {StaleDays}-day rule)")) gone.Add(w.Tag);
        }
        return gone;
    }

    // ------------------------------------------------------------------ the sweep ledger

    /// <summary>
    /// A save the mod made (a snapshot's QuickSave, before the engine named it)
    /// or saw land in a playline while this game was in a host's world.
    /// </summary>
    public sealed class LedgerEntry
    {
        public string Id { get; set; } = Guid.NewGuid().ToString("N")[..12];
        public int Playline { get; set; }
        public DateTime SinceUtc { get; set; }
        public string? File { get; set; }
        public string? Md5 { get; set; }
        public string WorldTag { get; set; } = "";
        public string Kind { get; set; } = "snapshot";     // snapshot | leak
        public string State { get; set; } = "pending";     // pending | written | done
    }

    private string LedgerPath => Path.Combine(Root, "ledger.json");

    public List<LedgerEntry> Ledger()
    {
        lock (_gate)
        {
            try
            {
                if (File.Exists(LedgerPath) && JsonSerializer.Deserialize<List<LedgerEntry>>(File.ReadAllText(LedgerPath)) is { } l) return l;
            }
            catch (Exception ex) when (ex is IOException or JsonException) { _log($"MP-HENRY ledger unreadable ({ex.Message}) -- starting a new one"); }
            return [];
        }
    }

    private void WriteLedger(List<LedgerEntry> l)
    {
        Directory.CreateDirectory(Root);
        // done entries a week old are forgotten
        l = l.Where(e => e.State != "done" || (_now() - e.SinceUtc).TotalDays < 7).ToList();
        File.WriteAllText(LedgerPath + ".part", JsonSerializer.Serialize(l));
        File.Move(LedgerPath + ".part", LedgerPath, overwrite: true);
    }

    public LedgerEntry LedgerAdd(LedgerEntry e)
    {
        lock (_gate) { var l = Ledger(); l.Add(e); WriteLedger(l); }
        return e;
    }

    public void LedgerSet(string id, Action<LedgerEntry> f)
    {
        lock (_gate)
        {
            var l = Ledger();
            foreach (var e in l.Where(x => x.Id == id)) f(e);
            WriteLedger(l);
        }
    }

    /// <summary>
    /// Move a file out of a playline into henry/swept (never deleted outright:
    /// the newest 8 swept files are kept). Returns true when it is gone from
    /// the playline.
    /// </summary>
    public bool MoveOut(string path, string why)
    {
        string swept = Path.Combine(Root, "swept");
        try
        {
            Directory.CreateDirectory(swept);
            string pl = Path.GetFileName(Path.GetDirectoryName(path)) ?? "playline?";
            string dest = Path.Combine(swept, $"{_now():yyyyMMddHHmmssfff}-{pl}-{Path.GetFileName(path)}");
            File.Move(path, dest);
            _log($"MP-HENRY moved {GameBridge.SaveDisplay(path)} out of the playline -> <data>/henry/swept ({why})");
            foreach (var old in new DirectoryInfo(swept).GetFiles().OrderByDescending(f => f.Name, StringComparer.Ordinal).Skip(8))
                TryDelete(old.FullName);
            return !File.Exists(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _log($"MP-HENRY could not move {GameBridge.SaveDisplay(path)} out ({why}): {ex.Message}");
            return false;
        }
    }

    private static void TryDelete(string p) { try { File.Delete(p); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
}
