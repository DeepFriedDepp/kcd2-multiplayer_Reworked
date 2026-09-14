using System.Text.Json;
using System.Text.Json.Serialization;

namespace KcdMp.Client;

/// <summary>
/// WO-96: the generated main-quest objective registry
/// (<c>mainquest-objectives.json</c>, embedded; built by
/// <c>tools/Build-MainQuestObjectives.ps1</c> from the same 32 M-coded quest
/// roots WO-94's beat registry uses). For each quest: its objectives in
/// document order, each with the English journal title, the localisation key
/// the engine writes into <c>questNameOverride</c> markers, and the path(s)
/// of its display node inside the save's ConceptState tree.
///
/// <see cref="Id"/> is a hash over everything a fingerprint index depends on.
/// Two agents compare fingerprints only when their ids match; otherwise the
/// comparison is refused and the mod keeps the single-marker behaviour.
/// </summary>
public sealed class QuestObjectiveRegistry
{
    public sealed class Objective
    {
        [JsonPropertyName("n")] public string Name { get; set; } = "";
        [JsonPropertyName("k")] public string StringName { get; set; } = "";
        [JsonPropertyName("t")] public string Title { get; set; } = "";
        [JsonPropertyName("optional")] public bool Optional { get; set; }
        [JsonPropertyName("paths")] public string[] Paths { get; set; } = Array.Empty<string>();
        public string Label => Title.Length > 0 ? Title : Name;
    }

    public sealed class Quest
    {
        [JsonPropertyName("code")] public string Code { get; set; } = "";
        [JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonPropertyName("key")] public string Key { get; set; } = "";
        [JsonPropertyName("level")] public string Level { get; set; } = "";
        [JsonPropertyName("title")] public string Title { get; set; } = "";
        [JsonPropertyName("objectives")] public Objective[] Objectives { get; set; } = Array.Empty<Objective>();
        public string Label => Title.Length > 0 ? Title : Name;
    }

    private sealed class Root
    {
        [JsonPropertyName("id")] public string Id { get; set; } = "";
        [JsonPropertyName("pak")] public string Pak { get; set; } = "";
        [JsonPropertyName("quests")] public Quest[] Quests { get; set; } = Array.Empty<Quest>();
    }

    public string Id { get; }
    public string PakSha256 { get; }
    public IReadOnlyList<Quest> Quests { get; }
    private readonly Dictionary<string, Quest> _byKey = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, Quest> _byName = new(StringComparer.Ordinal);

    private QuestObjectiveRegistry(Root r)
    {
        Id = r.Id; PakSha256 = r.Pak; Quests = r.Quests;
        foreach (var q in r.Quests) { _byKey[q.Key] = q; _byName[q.Name] = q; }
    }

    public Quest? ByMarkerKey(string? keyLower) =>
        keyLower is not null && _byKey.TryGetValue(keyLower, out var q) ? q : null;
    public Quest? ByName(string name) => _byName.TryGetValue(name, out var q) ? q : null;

    public static QuestObjectiveRegistry Parse(string json)
    {
        var r = JsonSerializer.Deserialize<Root>(json) ?? throw new InvalidDataException("empty objective registry");
        if (string.IsNullOrEmpty(r.Id) || r.Quests.Length == 0) throw new InvalidDataException("objective registry has no id or no quests");
        return new QuestObjectiveRegistry(r);
    }

    private static QuestObjectiveRegistry? _embedded;
    private static readonly object _lock = new();

    /// <summary>The registry compiled into this agent, or null if the resource is missing/corrupt (logged once).</summary>
    public static QuestObjectiveRegistry? Embedded
    {
        get
        {
            lock (_lock)
            {
                if (_embedded is not null) return _embedded;
                try
                {
                    var asm = typeof(QuestObjectiveRegistry).Assembly;
                    string? name = asm.GetManifestResourceNames().FirstOrDefault(n => n.EndsWith("mainquest-objectives.json", StringComparison.OrdinalIgnoreCase));
                    if (name is null) { Console.WriteLine("[quest] objective registry resource missing -- fingerprints disabled"); return null; }
                    using var s = asm.GetManifestResourceStream(name)!;
                    using var sr = new StreamReader(s);
                    _embedded = Parse(sr.ReadToEnd());
                    return _embedded;
                }
                catch (Exception ex)
                {
                    Console.WriteLine($"[quest] objective registry unreadable: {ex.Message} -- fingerprints disabled");
                    return null;
                }
            }
        }
    }
}
