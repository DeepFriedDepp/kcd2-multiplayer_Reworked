using System.IO.Compression;
using System.Xml.Linq;

namespace KcdMp.Client;

/// <summary>
/// WO-47: per-weapon-class swing fragments, read from the game's own shipped
/// combat tables instead of the one hardcoded longsword row WO-46 shipped.
///
/// The mapping chain, every link of it shipped data in Data\Tables.pak:
///
///   equipped ItemClass GUID           (what the appearance sync already tracks)
///     -> item/item*.xml               MeleeWeapon rows carry Class="N"
///                                     (ItemAlias rows redirect to SourceItemId)
///     -> item/weapon_class.xml        N is the game's weapon-class id
///                                     (4=longsword, 5=mace, 3=axe, ...)
///     -> combat/combat_action_attack.xml
///                                     FreeAttack rows carry r_weapon_class_id
///                                     in the SAME id space.
///
/// Longsword (4), halberd (7) and unarmed (12) have their own FreeAttack rows.
/// Every one-handed weapon instead rides rows with r_weapon_class_id="-1"
/// whose tags name a weapon GROUP (r_shortSwords, r_swords, r_bluntWeapon);
/// combat/combat_weapon_group.xml + combat_weapon_group_to_class.xml are the
/// shipped group-to-class mapping, so those rows are resolved through the same
/// tables the game uses, not a hand-maintained list. The l_-side tag on a
/// generic row encodes the off-hand (l_shield / l_torch / neither), so row
/// selection also respects the ghost's synced shield/torch.
///
/// Only on-foot rows (no "horse" tag) of the FreeAttack fragment are kept:
/// FreeAttack is the one fragment proven to render standalone on a ghost
/// (WO-45/46); everything else in the table needs combat context this path
/// does not construct.
/// </summary>
public sealed class WeaponSwingCatalog
{
    public readonly record struct Row(string Fragment, string Tags)
    {
        /// <summary>The exact "FragmentId, tag1+tag2" form ghost_swing takes.</summary>
        public string Spec => $"{Fragment}, {Tags}";
    }

    // ItemClass GUID -> weapon-class id, melee weapons only, aliases resolved.
    private readonly Dictionary<Guid, int> _itemToWeaponClass;
    // weapon-class id -> (name, equip_slot) from weapon_class.xml.
    private readonly Dictionary<int, (string Name, string EquipSlot)> _weaponClasses;
    // r_weapon_class_id != -1 on-foot FreeAttack rows.
    private readonly Dictionary<int, List<Row>> _explicitRows;
    // r_weapon_class_id == -1 on-foot FreeAttack rows (group-tagged).
    private readonly List<Row> _genericRows;
    // group mn_tag ("shortSwords", "bluntWeapon", ...) -> weapon-class ids in it.
    private readonly Dictionary<string, HashSet<int>> _groupTagClasses;

    private const string HumanActorClassHash = "1578932418"; // WO-42 §9.2
    private const int ShieldClass = 8, ShieldBrokenClass = 17, TorchClass = 11;

    private WeaponSwingCatalog(
        Dictionary<Guid, int> itemToWeaponClass,
        Dictionary<int, (string, string)> weaponClasses,
        Dictionary<int, List<Row>> explicitRows,
        List<Row> genericRows,
        Dictionary<string, HashSet<int>> groupTagClasses)
    {
        _itemToWeaponClass = itemToWeaponClass;
        _weaponClasses = weaponClasses;
        _explicitRows = explicitRows;
        _genericRows = genericRows;
        _groupTagClasses = groupTagClasses;
    }

    public int MeleeItemCount => _itemToWeaponClass.Count;

    /// <summary>
    /// Resolves a swing spec for a ghost wearing this set of item classes.
    /// <paramref name="swingIndex"/> rotates through the real rows available
    /// for the weapon (slash / stab / ...), so consecutive swings vary.
    /// Null when nothing resolves -- caller falls back to the WO-46 constant.
    /// </summary>
    public string? SpecFor(IReadOnlyCollection<Guid> equipped, int swingIndex, out string weaponName)
    {
        weaponName = "?";
        var classes = new HashSet<int>();
        foreach (var g in equipped)
            if (_itemToWeaponClass.TryGetValue(g, out int c))
                classes.Add(c);
        if (classes.Count == 0) return null;

        // The weapon a drawn ghost actually swings: the main-hand melee slot.
        int primary = -1;
        foreach (int c in classes.OrderBy(c => c))
        {
            if (_weaponClasses.TryGetValue(c, out var wc)
                && wc.EquipSlot is "PrimaryMainHand" or "Oversized")
            {
                primary = c;
                break;
            }
        }
        if (primary < 0) return null;
        weaponName = _weaponClasses[primary].Name;

        var rows = RowsFor(primary,
            hasShield: classes.Contains(ShieldClass) || classes.Contains(ShieldBrokenClass),
            hasTorch: classes.Contains(TorchClass));
        if (rows.Count == 0) return null;
        return rows[((swingIndex % rows.Count) + rows.Count) % rows.Count].Spec;
    }

    /// <summary>All candidate rows for a weapon class + off-hand state, deterministic order.</summary>
    public List<Row> RowsFor(int weaponClass, bool hasShield, bool hasTorch)
    {
        if (_explicitRows.TryGetValue(weaponClass, out var explicitRows))
        {
            // Explicit rows can still vary by off-hand (unarmed ships l_torch
            // and l_noweapon variants). Filter the same way as group rows, but
            // never filter down to nothing -- a two-handed class's rows carry
            // their own l_ tag (l_longsword) and must survive untouched.
            var filtered = explicitRows.Where(r => OffhandOk(r.Tags.Split('+'), hasShield, hasTorch)).ToList();
            return filtered.Count > 0 ? filtered : explicitRows;
        }

        var result = new List<Row>();
        foreach (var row in _genericRows)
        {
            var tags = row.Tags.Split('+');
            bool groupMatch = false;
            foreach (var t in tags)
            {
                if (t.StartsWith("r_", StringComparison.Ordinal)
                    && _groupTagClasses.TryGetValue(t[2..], out var members)
                    && members.Contains(weaponClass))
                {
                    groupMatch = true;
                    break;
                }
            }
            if (groupMatch && OffhandOk(tags, hasShield, hasTorch)) result.Add(row);
        }
        return result;
    }

    private static bool OffhandOk(string[] tags, bool hasShield, bool hasTorch)
    {
        bool lShield = tags.Contains("l_shield");
        bool lTorch = tags.Contains("l_torch");
        return hasShield ? lShield
             : hasTorch ? lTorch
             : !lShield && !lTorch;
    }

    public IEnumerable<int> KnownWeaponClasses => _weaponClasses.Keys.OrderBy(k => k);

    public string WeaponClassName(int id) =>
        _weaponClasses.TryGetValue(id, out var wc) ? wc.Name : $"#{id}";

    public int? WeaponClassOfItem(Guid itemClass) =>
        _itemToWeaponClass.TryGetValue(itemClass, out int c) ? c : null;

    /// <summary>
    /// WO-47: the equipped item whose weapon class lives in the Oversized
    /// slot (halberds/polearms), or null. Those never attach through the
    /// plain DrawWeapon() path -- the ghost draw event must go through
    /// KCD2MP_GhostDrawItem (DrawFromInventory) for them instead.
    /// </summary>
    public Guid? OversizedItemOf(IReadOnlyCollection<Guid> equipped)
    {
        foreach (var g in equipped)
        {
            if (_itemToWeaponClass.TryGetValue(g, out int c)
                && _weaponClasses.TryGetValue(c, out var wc)
                && wc.EquipSlot == "Oversized")
                return g;
        }
        return null;
    }

    // -------------------------------------------------------------------------

    /// <summary>
    /// Loads from the installed game's Data\Tables.pak (located the same way
    /// the agent already locates kcd.log). Returns null -- never throws -- when
    /// the pak or any table is unreadable; the caller keeps the WO-46 constant.
    /// </summary>
    public static WeaponSwingCatalog? TryLoad(Action<string> log)
    {
        try
        {
            string? pak = FindTablesPak();
            if (pak is null)
            {
                log("[swingcatalog] Tables.pak not found in any Steam library -- swings stay on the fixed longsword row");
                return null;
            }
            var catalog = LoadFrom(pak);
            log($"[swingcatalog] loaded {pak}: {catalog.MeleeItemCount} melee items, "
                + $"explicit rows for [{string.Join(",", catalog._explicitRows.Keys.OrderBy(k => k).Select(catalog.WeaponClassName))}], "
                + $"{catalog._genericRows.Count} group rows");
            return catalog;
        }
        catch (Exception ex)
        {
            log($"[swingcatalog] load failed ({ex.Message}) -- swings stay on the fixed longsword row");
            return null;
        }
    }

    private static string? FindTablesPak()
    {
        // Prefer the install the running/last-run game wrote its log into.
        string? kcdLog = KcdLogLocator.Find();
        if (kcdLog is not null)
        {
            string p = Path.Combine(Path.GetDirectoryName(kcdLog)!, "Data", "Tables.pak");
            if (File.Exists(p)) return p;
        }
        foreach (var root in KcdLogLocator.SteamLibraryRoots())
        {
            string common = Path.Combine(root, "steamapps", "common");
            if (!Directory.Exists(common)) continue;
            foreach (var dir in Directory.EnumerateDirectories(common))
            {
                string name = Path.GetFileName(dir);
                if (!name.Contains("Kingdom", StringComparison.OrdinalIgnoreCase) &&
                    !name.Contains("KCD", StringComparison.OrdinalIgnoreCase)) continue;
                string p = Path.Combine(dir, "Data", "Tables.pak");
                if (File.Exists(p)) return p;
            }
        }
        return null;
    }

    /// <summary>Parses the five tables out of one pak (a plain zip).</summary>
    public static WeaponSwingCatalog LoadFrom(string tablesPakPath)
    {
        using var zip = ZipFile.OpenRead(tablesPakPath);

        XDocument Open(string entry)
        {
            var e = zip.GetEntry(entry) ?? throw new FileNotFoundException(entry);
            using var s = e.Open();
            return XDocument.Load(s);
        }

        // weapon_class.xml: id -> (name, equip_slot).
        var weaponClasses = new Dictionary<int, (string, string)>();
        foreach (var el in Open("Libs/Tables/item/weapon_class.xml").Descendants())
        {
            string? id = el.Attribute("id")?.Value;
            string? nm = el.Attribute("name")?.Value;
            string? slot = el.Attribute("equip_slot")?.Value;
            if (id is not null && nm is not null && slot is not null && int.TryParse(id, out int i))
                weaponClasses[i] = (nm, slot);
        }

        // combat_weapon_group.xml + combat_weapon_group_to_class.xml:
        // mn_tag -> set of weapon-class ids.
        var groupTagById = new Dictionary<int, string>();
        foreach (var el in Open("Libs/Tables/combat/combat_weapon_group.xml")
                     .Descendants("combat_weapon_group"))
        {
            if (int.TryParse(el.Attribute("combat_weapon_group_id")?.Value, out int gid)
                && el.Attribute("mn_tag")?.Value is { } tag)
                groupTagById[gid] = tag;
        }
        var groupTagClasses = new Dictionary<string, HashSet<int>>();
        foreach (var el in Open("Libs/Tables/combat/combat_weapon_group_to_class.xml")
                     .Descendants("combat_weapon_group_to_class"))
        {
            if (int.TryParse(el.Attribute("combat_weapon_group_id")?.Value, out int gid)
                && int.TryParse(el.Attribute("weapon_class_id")?.Value, out int wcid)
                && groupTagById.TryGetValue(gid, out var tag))
            {
                if (!groupTagClasses.TryGetValue(tag, out var set))
                    groupTagClasses[tag] = set = [];
                set.Add(wcid);
            }
        }

        // combat_action_attack.xml: on-foot human FreeAttack rows.
        var explicitRows = new Dictionary<int, List<Row>>();
        var genericRows = new List<Row>();
        foreach (var el in Open("Libs/Tables/combat/combat_action_attack.xml")
                     .Root!.Elements().First().Elements())
        {
            if (el.Attribute("mn_fragment_id")?.Value != "FreeAttack") continue;
            if (el.Attribute("actor_class_hash")?.Value != HumanActorClassHash) continue;
            string? tags = el.Attribute("mn_tags")?.Value;
            if (tags is null || tags.Split('+').Contains("horse")) continue;
            if (!int.TryParse(el.Attribute("r_weapon_class_id")?.Value, out int wcid)) continue;

            var row = new Row("FreeAttack", tags);
            if (wcid == -1)
            {
                genericRows.Add(row);
            }
            else
            {
                if (!explicitRows.TryGetValue(wcid, out var list))
                    explicitRows[wcid] = list = [];
                list.Add(row);
            }
        }
        foreach (var list in explicitRows.Values) list.Sort((a, b) => string.CompareOrdinal(a.Tags, b.Tags));
        genericRows.Sort((a, b) => string.CompareOrdinal(a.Tags, b.Tags));

        // item*.xml: melee-weapon ItemClass GUID -> weapon-class id, plus
        // alias -> source redirects (resolved after all files are read, since
        // an alias may point into a different item file).
        var itemToClass = new Dictionary<Guid, int>();
        var aliasToSource = new Dictionary<Guid, Guid>();
        foreach (var entry in zip.Entries)
        {
            if (!entry.FullName.StartsWith("Libs/Tables/item/item", StringComparison.Ordinal)
                || !entry.FullName.EndsWith(".xml", StringComparison.Ordinal)) continue;
            XDocument doc;
            using (var s = entry.Open()) doc = XDocument.Load(s);
            foreach (var el in doc.Descendants())
            {
                if (el.Name.LocalName == "MeleeWeapon")
                {
                    if (Guid.TryParse(el.Attribute("Id")?.Value, out var id)
                        && int.TryParse(el.Attribute("Class")?.Value, out int cls))
                        itemToClass[id] = cls;
                }
                else if (el.Name.LocalName == "ItemAlias")
                {
                    if (Guid.TryParse(el.Attribute("Id")?.Value, out var id)
                        && Guid.TryParse(el.Attribute("SourceItemId")?.Value, out var src))
                        aliasToSource[id] = src;
                }
            }
        }
        foreach (var (alias, source) in aliasToSource)
        {
            // Follow alias chains defensively; shipped data is one hop.
            Guid cur = source;
            for (int hop = 0; hop < 4 && !itemToClass.ContainsKey(cur); hop++)
            {
                if (!aliasToSource.TryGetValue(cur, out var next)) break;
                cur = next;
            }
            if (itemToClass.TryGetValue(cur, out int cls) && !itemToClass.ContainsKey(alias))
                itemToClass[alias] = cls;
        }

        return new WeaponSwingCatalog(itemToClass, weaponClasses, explicitRows, genericRows, groupTagClasses);
    }
}
