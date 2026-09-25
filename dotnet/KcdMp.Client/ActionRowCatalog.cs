using System.IO.Compression;
using System.Xml.Linq;

namespace KcdMp.Client;

/// <summary>
/// WO-121: authored combat rows by their <c>mn_fragment_guid</c> -- the key a
/// v8 Attack / BlockImpulse / Dodge / NpcAttack event carries.
///
/// Read from the installed game's own Data\Tables.pak (the same pak
/// <see cref="WeaponSwingCatalog"/> reads): combat_action_attack,
/// combat_action_block, combat_action_perfect_block and combat_action_dodge.
/// Each row's own fragment and tags are the spec the receiver hands the
/// WO-46 cosmetic route (<c>"FragmentId, tag+tag"</c>), so the avatar plays
/// the exact row the sender's engine committed -- overhead is overhead, a
/// thrust is a thrust -- instead of the one rotating FreeAttack row.
///
/// Live finding (WO-121 session 1): a committed attack action's descriptor
/// (action +0x60) holds this GUID at +0x84 in Windows GUID byte order; five
/// captured rows all matched this table.
/// </summary>
public sealed class ActionRowCatalog
{
    public readonly record struct Row(string Table, string Fragment, string Tags, int Zone, int InputClass, int AttackType)
    {
        public string Spec => $"{Fragment}, {Tags}";
    }

    private readonly Dictionary<Guid, Row> _rows;
    private ActionRowCatalog(Dictionary<Guid, Row> rows) { _rows = rows; }

    public int Count => _rows.Count;
    public bool TryGet(Guid g, out Row r) => _rows.TryGetValue(g, out r);

    public static readonly string[] Tables =
    {
        "Libs/Tables/combat/combat_action_attack.xml",
        "Libs/Tables/combat/combat_action_block.xml",
        "Libs/Tables/combat/combat_action_perfect_block.xml",
        "Libs/Tables/combat/combat_action_dodge.xml",
    };

    public static ActionRowCatalog LoadFrom(string tablesPakPath)
    {
        var rows = new Dictionary<Guid, Row>();
        using var zip = ZipFile.OpenRead(tablesPakPath);
        foreach (var entry in Tables)
        {
            var e = zip.GetEntry(entry);
            if (e is null) continue;
            using var s = e.Open();
            var doc = XDocument.Load(s);
            string table = Path.GetFileNameWithoutExtension(entry);
            foreach (var el in doc.Descendants())
            {
                var g = (string?)el.Attribute("mn_fragment_guid");
                var frag = (string?)el.Attribute("mn_fragment_id");
                if (g is null || frag is null || !Guid.TryParse(g, out var guid)) continue;
                rows[guid] = new Row(table, frag, (string?)el.Attribute("mn_tags") ?? "",
                    Int((string?)el.Attribute("attack_zone_id") ?? (string?)el.Attribute("block_zone_id")),
                    Int((string?)el.Attribute("input_class_id")), Int((string?)el.Attribute("attack_type_id")));
            }
        }
        return new ActionRowCatalog(rows);
    }

    private static int Int(string? s) => int.TryParse(s, out int v) ? v : -1;

    public static ActionRowCatalog? TryLoad(Action<string> log)
    {
        try
        {
            string? pak = WeaponSwingCatalog.FindTablesPak();
            if (pak is null) { log("[rowcatalog] Tables.pak not found -- v8 attack events fall back to the weapon swing rows"); return null; }
            var c = LoadFrom(pak);
            log($"[rowcatalog] loaded {c.Count} combat rows (attack/block/perfect_block/dodge) from {pak}");
            return c;
        }
        catch (Exception ex)
        {
            log($"[rowcatalog] load failed ({ex.GetType().Name}: {ex.Message}) -- v8 attack events fall back to the weapon swing rows");
            return null;
        }
    }
}
