using System.Buffers.Binary;
using System.IO;

namespace KcdMp.Wire;

// ---------------------------------------------------------------------------
// WO-122 -- shared-world foundations (docs/WO-122-findings.md).
//
// C→S  0x46  WorldSavedUp:   [seq:u32][senderUnixMs:i64][kind:u8][playline:u8][idx:u16][md5:16]   (32)
// S→C  0x47  WorldSavedDown: [sourceGhostId:1] + the Up body verbatim                              (33)
//
// The host's game wrote a save of the world (any type: the mod's scheduled
// autosave, a sleep, a quest save, the menu). The host's agent sees the file
// land in the saves folder, verifies it (the MD5 footer and the framing) and
// announces it. seq counts this agent's announcements; senderUnixMs is the
// host agent's UTC clock when the file verified; (kind, playline, idx) name
// the file (autosave042 in playline1 = kind 1, playline 1, idx 42); md5 is
// the save's own footer MD5, a content id the joiner's Henry snapshot pairs
// with (the next WOs). The relay forwards it only from the damage authority
// (the host): a joiner's save is not the world. Additive, exact length; it
// shipped without a Protocol.Version bump and rides along with WO-123's bump
// to v9 (ProtocolWo123.cs).
// ---------------------------------------------------------------------------

public static partial class Protocol
{
    public const byte WorldSavedUp   = 0x46;   // WO-122
    public const byte WorldSavedDown = 0x47;   // WO-122

    /// <summary>Exact WorldSavedUp (0x46) payload.</summary>
    public const int WorldSavedUpPayloadLen = 4 + 8 + 1 + 1 + 2 + 16;
    /// <summary>Exact WorldSavedDown (0x47) payload: sourceGhostId + the Up body.</summary>
    public const int WorldSavedDownPayloadLen = 1 + WorldSavedUpPayloadLen;

    // Save kinds on the wire -- OUR append-only ordinals keyed on the file
    // name the engine writes (Framework format strings), never the engine's
    // own E_SaveGameType index.
    public const byte SaveKindUnknown = 0, SaveKindAuto = 1, SaveKindQuick = 2, SaveKindManual = 3,
                      SaveKindPermanent = 4, SaveKindCrucial = 5, SaveKindExit = 6;

    /// <summary>
    /// WO-125: a WorldSaved whose kind has this bit is not a new save but one
    /// entry of the host's current BRANCH (the save it loaded and every save
    /// since), replayed oldest first right before a WorldOffer: SenderUnixMs
    /// is the entry's position (0 starts a new list) and Seq the number of
    /// entries in the replay. Same type, same exact length, no version bump;
    /// a WO-122..124 receiver only logs it.
    /// </summary>
    public const byte SaveKindBranchFlag = 0x80;

    public static string SaveKindName(byte k) => (byte)(k & 0x7F) switch
    {
        SaveKindAuto => "autosave", SaveKindQuick => "quicksave", SaveKindManual => "save",
        SaveKindPermanent => "permanent", SaveKindCrucial => "crucialdecision", SaveKindExit => "exit",
        _ => "unknown",
    };
}

/// <summary>WO-122: one world save, as announced by the host.</summary>
public readonly record struct WorldSaved(uint Seq, long SenderUnixMs, byte Kind, byte Playline, ushort Idx, byte[] Md5)
{
    /// <summary>The file name the engine gave it (autosave042.whs, exit.whs).</summary>
    public string FileName => (Kind & 0x7F) == Protocol.SaveKindExit ? "exit.whs" : $"{Protocol.SaveKindName(Kind)}{Idx:D3}.whs";

    /// <summary>WO-125: a branch-replay entry (<see cref="Protocol.SaveKindBranchFlag"/>), not a new save.</summary>
    public bool IsBranchEntry => (Kind & Protocol.SaveKindBranchFlag) != 0;

    public byte[] Encode()
    {
        if (Md5.Length != 16) throw new ArgumentException("md5 is 16 bytes");
        var b = new byte[Protocol.WorldSavedUpPayloadLen];
        BinaryPrimitives.WriteUInt32LittleEndian(b, Seq);
        BinaryPrimitives.WriteInt64LittleEndian(b.AsSpan(4), SenderUnixMs);
        b[12] = Kind;
        b[13] = Playline;
        BinaryPrimitives.WriteUInt16LittleEndian(b.AsSpan(14), Idx);
        Md5.CopyTo(b, 16);
        return b;
    }

    /// <summary>Decode an Up body (32 bytes) or, with <paramref name="down"/>, a Down body (33, source id first).</summary>
    public static WorldSaved? TryDecode(ReadOnlySpan<byte> p, bool down, out byte sourceId)
    {
        sourceId = 0;
        if (p.Length != (down ? Protocol.WorldSavedDownPayloadLen : Protocol.WorldSavedUpPayloadLen)) return null;
        if (down) { sourceId = p[0]; p = p[1..]; }
        return new WorldSaved(BinaryPrimitives.ReadUInt32LittleEndian(p), BinaryPrimitives.ReadInt64LittleEndian(p[4..]),
                              p[12], p[13], BinaryPrimitives.ReadUInt16LittleEndian(p[14..]), p.Slice(16, 16).ToArray());
    }

    /// <summary>
    /// (kind, playline, idx) from a save's path, by the engine's own naming
    /// (<c>.../playline1/autosave042.whs</c>). Null for anything else,
    /// including the mod's transient <c>mpworld*</c> files.
    /// </summary>
    public static (byte Kind, byte Playline, ushort Idx)? ParsePath(string path)
    {
        string file = Path.GetFileName(path).ToLowerInvariant();
        string? dir = Path.GetFileName(Path.GetDirectoryName(path) ?? "")?.ToLowerInvariant();
        if (dir is null || !dir.StartsWith("playline", StringComparison.Ordinal) || dir.Length < 9 || dir.Length > 11
            || !dir.AsSpan(8).ToString().All(char.IsAsciiDigit) || !byte.TryParse(dir.AsSpan(8), out byte pl)) return null;
        if (file == "exit.whs") return (Protocol.SaveKindExit, pl, 0);
        foreach (var (prefix, kind) in new[] { ("autosave", Protocol.SaveKindAuto), ("quicksave", Protocol.SaveKindQuick),
                                               ("crucialdecision", Protocol.SaveKindCrucial), ("permanent", Protocol.SaveKindPermanent),
                                               ("save", Protocol.SaveKindManual) })
        {
            if (!file.StartsWith(prefix, StringComparison.Ordinal) || !file.EndsWith(".whs", StringComparison.Ordinal)) continue;
            var num = file.AsSpan(prefix.Length, file.Length - prefix.Length - 4);
            if (num.Length == 3 && char.IsAsciiDigit(num[0]) && char.IsAsciiDigit(num[1]) && char.IsAsciiDigit(num[2]))
                return (kind, pl, (ushort)((num[0] - '0') * 100 + (num[1] - '0') * 10 + (num[2] - '0')));
        }
        return null;
    }
}
