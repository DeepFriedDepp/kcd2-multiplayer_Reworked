using System.Buffers.Binary;
using System.Text;
using KcdMp.Wire;

namespace KcdMp.Client;

/// <summary>
/// The agent's NpcStateUp (0x26) encoder and NpcStateDown (0x27) decoder.
///
/// WO-102 Phase 6: pulled out of GameBridge so the relay round-trip gate
/// sends and reads EXACTLY the bytes the shipped agent does -- the WO-101
/// rule, applied to the first NpcState flag this WO adds
/// (<see cref="Protocol.NpcStateFlagResync"/>). Shape (unchanged since WO-32):
/// <code>
/// Up:   [nameLen:1][name:utf8][x:4f][y:4f][z:4f][rotZ:4f][health:4f][flags:1][seq:u16][senderMs:u32]
/// Down: [sourceGhostId:1] + Up verbatim
/// </code>
/// WO-110 R6 (protocol v7) appended seq and senderMs; see Protocol.NpcStateFixedTail.
/// </summary>
public static class NpcStateCodec
{
    /// <summary>One decoded NpcStateDown payload.</summary>
    public readonly record struct Down(byte SourceGhostId, string Name, float X, float Y, float Z, float RotZ, float Health, byte Flags, ushort Seq, uint SenderMs);

    /// <summary>Builds a complete NpcStateUp packet (3-byte header included). The name must already be validated.</summary>
    public static byte[] BuildUp(string npcName, float x, float y, float z, float rotZ, float health, byte flags, ushort seq = 0, uint senderMs = 0)
    {
        byte[] nameBytes = Encoding.UTF8.GetBytes(npcName);
        if (nameBytes.Length == 0 || nameBytes.Length > Protocol.MaxNpcNameLen)
            throw new ArgumentOutOfRangeException(nameof(npcName));
        int payloadLen = 1 + nameBytes.Length + Protocol.NpcStateFixedTail;
        var packet = new byte[3 + payloadLen];
        packet[0] = Protocol.NpcStateUp;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payloadLen);
        packet[3] = (byte)nameBytes.Length;
        nameBytes.CopyTo(packet, 4);
        int o = 4 + nameBytes.Length;
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(o), x);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(o + 4), y);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(o + 8), z);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(o + 12), rotZ);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(o + 16), health);
        packet[o + Protocol.NpcStateFlagsOffset] = flags;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(o + Protocol.NpcStateSeqOffset), seq);
        BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(o + Protocol.NpcStateSenderMsOffset), senderMs);
        return packet;
    }

    /// <summary>Decodes an NpcStateDown payload; false when the framing and the name length disagree.</summary>
    public static bool TryParseDown(ReadOnlySpan<byte> payload, out Down down)
    {
        down = default;
        if (payload.Length < 2 + 1 + Protocol.NpcStateFixedTail) return false;
        int nameLen = payload[1];
        if (nameLen == 0 || nameLen > Protocol.MaxNpcNameLen || payload.Length != 2 + nameLen + Protocol.NpcStateFixedTail) return false;
        string name = Encoding.UTF8.GetString(payload.Slice(2, nameLen));
        int o = 2 + nameLen;
        down = new Down(payload[0], name,
            BinaryPrimitives.ReadSingleLittleEndian(payload[o..]),
            BinaryPrimitives.ReadSingleLittleEndian(payload[(o + 4)..]),
            BinaryPrimitives.ReadSingleLittleEndian(payload[(o + 8)..]),
            BinaryPrimitives.ReadSingleLittleEndian(payload[(o + 12)..]),
            BinaryPrimitives.ReadSingleLittleEndian(payload[(o + 16)..]),
            payload[o + Protocol.NpcStateFlagsOffset],
            BinaryPrimitives.ReadUInt16LittleEndian(payload[(o + Protocol.NpcStateSeqOffset)..]),
            BinaryPrimitives.ReadUInt32LittleEndian(payload[(o + Protocol.NpcStateSenderMsOffset)..]));
        return true;
    }
}
