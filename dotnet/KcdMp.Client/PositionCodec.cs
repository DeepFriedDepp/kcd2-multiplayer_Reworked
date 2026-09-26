using System.Buffers.Binary;

namespace KcdMp.Client;

/// <summary>
/// One decoded Ghost (0x02) payload. <see cref="State2"/> is the WO-121 v8
/// state block, set only when its flag and the length agree;
/// <see cref="BodyStateShort"/> is the bug case (flag set, no room for the
/// bytes) that a receiver must count, not read. <see cref="Body"/> is the
/// pre-v8 body state DERIVED from State2 for the legacy Lua gait path.
/// <see cref="SenderMs"/> is the sender's clock (WO-118 follow-up), 0 when the
/// packet carries none.
/// </summary>
public readonly record struct GhostSample(
    byte GhostId, float X, float Y, float Z, float RotZ, byte Flags, BodyState? Body, bool BodyStateShort,
    uint SenderMs = 0, BodyState2? State2 = null)
{
    public bool IsRiding => (Flags & Protocol.PositionFlagRiding) != 0;
    public bool IsStale  => (Flags & Protocol.PositionFlagStale) != 0;
}

/// <summary>
/// The agent's Position (0x01) encoder and Ghost (0x02) decoder, in one place.
///
/// WO-101: pulled out of GameBridge so the relay round-trip gate
/// (dotnet/KcdMp.Relay.Tests) sends and reads EXACTLY the bytes the shipped
/// agent does. Before this, the only code that built a Position packet was a
/// private method on a class that needs a live game, so no test ever put one
/// through the relay -- and 0.23.1 shipped with the relay dropping every
/// 22-byte packet (docs/WO-101-findings.md S0).
///
/// WO-121 (protocol v8): the tail is [BodyState2:12 if flag 0x10][senderMs:4
/// if flag 0x08]; the WO-100.5 0x04 block is superseded and never built.
///
/// Any change to the Position/Ghost shape goes here, and then through
/// RelayRoundTripTests before it ships. Every length must keep round-tripping.
/// </summary>
public static class PositionCodec
{
    /// <summary>
    /// Builds a complete Position packet (3-byte header included): 17 bytes,
    /// + 12 when <paramref name="state2"/> is set, + 4 when <paramref name="senderMs"/>
    /// is (17/21/29/33), each flag following its own condition so a flag and
    /// its bytes can never disagree. The sender ms goes after the state block.
    /// </summary>
    public static byte[] BuildPosition(float x, float y, float z, float rotZ,
                                       bool isRiding, bool stale, BodyState2? state2, uint? senderMs = null, bool hostClaim = false)
    {
        int payloadLen = Protocol.PositionPayloadLen
                       + (state2.HasValue ? Protocol.BodyState2Len : 0)
                       + (senderMs.HasValue ? Protocol.SenderMsLen : 0);
        var packet = new byte[3 + payloadLen];
        packet[0] = Protocol.Position;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payloadLen);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(3),  x);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(7),  y);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(11), z);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(15), rotZ);
        packet[19] = (byte)((isRiding ? Protocol.PositionFlagRiding : 0)
                          | (stale    ? Protocol.PositionFlagStale   : 0)
                          | (state2.HasValue ? Protocol.PositionFlagBodyState2 : 0)
                          | (senderMs.HasValue ? Protocol.PositionFlagSenderMs : 0)
                          | (hostClaim ? Protocol.PositionFlagHostClaim : 0));   // WO-127: read and cleared by the relay
        int o = 20;
        if (state2 is BodyState2 b)
        {
            b.Write(packet.AsSpan(o));
            o += Protocol.BodyState2Len;
        }
        if (senderMs is uint ms)
            BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(o), ms);
        return packet;
    }

    /// <summary>
    /// Decodes a Ghost payload of one of the exact lengths in
    /// <see cref="Protocol.IsGhostPayloadLen"/> (18/22/30/34); any other length
    /// is refused (false). Flag AND room gate each tail, never the flag alone.
    /// </summary>
    public static bool TryDecodeGhost(ReadOnlySpan<byte> payload, out GhostSample sample)
    {
        sample = default;
        if (!Protocol.IsGhostPayloadLen(payload.Length))
            return false;

        byte  ghostId = payload[0];
        float x       = BinaryPrimitives.ReadSingleLittleEndian(payload[1..]);
        float y       = BinaryPrimitives.ReadSingleLittleEndian(payload[5..]);
        float z       = BinaryPrimitives.ReadSingleLittleEndian(payload[9..]);
        float rotZ    = BinaryPrimitives.ReadSingleLittleEndian(payload[13..]);
        byte  flags   = payload[17];

        bool flagged = (flags & Protocol.PositionFlagBodyState2) != 0;
        int tail = payload.Length - Protocol.GhostPayloadLen;   // 0, 4, 12 or 16
        int o = Protocol.GhostPayloadLen;
        BodyState2? st2 = null;
        bool shortPacket = false;
        if (flagged && (tail == Protocol.BodyState2Len || tail == Protocol.BodyState2Len + Protocol.SenderMsLen))
        {
            st2 = BodyState2.Read(payload[o..]);
            o += Protocol.BodyState2Len;
        }
        else if (flagged)
        {
            shortPacket = true;
        }
        uint senderMs = 0;
        if ((flags & Protocol.PositionFlagSenderMs) != 0 && payload.Length - o == Protocol.SenderMsLen)
            senderMs = BinaryPrimitives.ReadUInt32LittleEndian(payload[o..]);

        BodyState? legacy = st2 is BodyState2 b2 ? b2.ToLegacy((flags & Protocol.PositionFlagRiding) != 0) : null;
        sample = new GhostSample(ghostId, x, y, z, rotZ, flags, legacy, shortPacket, senderMs, st2);
        return true;
    }
}
