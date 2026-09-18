using System.Buffers.Binary;

namespace KcdMp.Client;

/// <summary>
/// WO-102.5 Phase 2: one batched native NPC scan over the DLL pipe (command
/// 0x0B, reply 0x87). Replaces the enumerate+read half of Lua's
/// mp_npc_rescan -- see native/KCDMP/npc_scan.h for how each field is read
/// and native/KCDMP/pipe_server.h for the wire shape.
/// </summary>
public readonly record struct NpcScanEntry(string Name, float X, float Y, float Z, float Yaw, bool IsHorse);

/// <summary>
/// Why the DLL refused a scan. Mirrors <c>kcdmp::npcscan::Refuse</c> in
/// <c>native/KCDMP/npc_scan.h</c> by number; append-only.
/// </summary>
public enum NpcScanRefuse : byte
{
    Ok = 0,
    /// <summary>CryScriptSystem.dll / CryEntitySystem.dll not loaded.</summary>
    ModuleMissing = 1,
    /// <summary>gEnv/pEntitySystem candidate failed the iterator+vptr gate.</summary>
    GEnvUnmapped = 2,
    /// <summary>GetClassRegistry/FindClass did not resolve NPC/NPC_Female/Horse.</summary>
    ClassRegistryUnmapped = 3,
    /// <summary>A memory read or virtual call faulted (SEH).</summary>
    ReadFaulted = 4,
    /// <summary>The DLL is older than this agent and does not know the command (agent-side classification of "no answer").</summary>
    Unknown = 255,
}

public readonly record struct NpcScanResult(
    bool Truncated, uint TotalWalked, uint NameRejects, IReadOnlyList<NpcScanEntry> Entries);

/// <summary>
/// The 0x87 reply body:
/// <code>
/// [ok:1][seq:1][refuse:1][truncated:1][totalWalked:4 LE][nameRejects:4 LE][count:2 LE]
/// { [nameLen:1][name:N][x:4f][y:4f][z:4f][yaw:4f][isHorse:1] }*count
/// </code>
/// </summary>
public static class NpcScanCodec
{
    public const int HeaderLen = 14;

    public static bool TryParse(ReadOnlySpan<byte> body, out NpcScanResult result, out NpcScanRefuse refuse)
    {
        result = default;
        refuse = NpcScanRefuse.Unknown;
        if (body.Length < 3) return false;
        refuse = (NpcScanRefuse)body[2];
        if (body[0] != 1) return false;
        if (body.Length < HeaderLen) { refuse = NpcScanRefuse.Unknown; return false; }

        bool truncated = body[3] != 0;
        uint totalWalked = BinaryPrimitives.ReadUInt32LittleEndian(body[4..]);
        uint nameRejects = BinaryPrimitives.ReadUInt32LittleEndian(body[8..]);
        ushort count = BinaryPrimitives.ReadUInt16LittleEndian(body[12..]);

        var entries = new List<NpcScanEntry>(count);
        int o = HeaderLen;
        for (int i = 0; i < count; i++)
        {
            if (o >= body.Length) return false;
            byte nameLen = body[o]; o += 1;
            if (o + nameLen + 17 > body.Length) return false;
            string name = System.Text.Encoding.ASCII.GetString(body.Slice(o, nameLen)); o += nameLen;
            float x = BinaryPrimitives.ReadSingleLittleEndian(body[o..]); o += 4;
            float y = BinaryPrimitives.ReadSingleLittleEndian(body[o..]); o += 4;
            float z = BinaryPrimitives.ReadSingleLittleEndian(body[o..]); o += 4;
            float yaw = BinaryPrimitives.ReadSingleLittleEndian(body[o..]); o += 4;
            bool isHorse = body[o] != 0; o += 1;
            entries.Add(new NpcScanEntry(name, x, y, z, yaw, isHorse));
        }
        result = new NpcScanResult(truncated, totalWalked, nameRejects, entries);
        refuse = NpcScanRefuse.Ok;
        return true;
    }
}
