using System.Buffers.Binary;

namespace KcdMp.Client;

/// <summary>
/// One decoded Ghost (0x02) payload. <see cref="Body"/> is set only when the
/// BODYSTATE flag and the length agree; <see cref="BodyStateShort"/> is the
/// bug case (flag set, no room for the five bytes) that a receiver must count,
/// not read. <see cref="SenderMs"/> is the sender's clock (WO-118 follow-up),
/// 0 when the packet carries none.
/// </summary>
public readonly record struct GhostSample(
    byte GhostId, float X, float Y, float Z, float RotZ, byte Flags, BodyState? Body, bool BodyStateShort,
    uint SenderMs = 0)
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
/// Any change to the Position/Ghost shape goes here, and then through
/// RelayRoundTripTests before it ships. Both lengths must keep round-tripping.
/// </summary>
public static class PositionCodec
{
    /// <summary>
    /// Builds a complete Position packet (3-byte header included): 17 bytes,
    /// + 5 when <paramref name="body"/> is set, + 4 when <paramref name="senderMs"/>
    /// is (17/21/22/26), each flag following its own condition so a flag and
    /// its bytes can never disagree. The sender ms goes after the body state.
    /// </summary>
    public static byte[] BuildPosition(float x, float y, float z, float rotZ,
                                       bool isRiding, bool stale, BodyState? body, uint? senderMs = null)
    {
        int payloadLen = Protocol.PositionPayloadLen
                       + (body.HasValue ? Protocol.BodyStateLen : 0)
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
                          | (body.HasValue ? Protocol.PositionFlagBodyState : 0)
                          | (senderMs.HasValue ? Protocol.PositionFlagSenderMs : 0));
        int o = 20;
        if (body is BodyState b)
        {
            packet[o]     = (byte)b.Pace;
            packet[o + 1] = (byte)b.Dir;
            packet[o + 2] = (byte)b.Stance;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(o + 3), b.AnimSpeedCenti);
            o += Protocol.BodyStateLen;
        }
        if (senderMs is uint ms)
            BinaryPrimitives.WriteUInt32LittleEndian(packet.AsSpan(o), ms);
        return packet;
    }

    /// <summary>
    /// Decodes a Ghost payload of one of the exact lengths in
    /// <see cref="Protocol.IsGhostPayloadLen"/> (18/22/23/27); any other length
    /// is refused (false). Flag AND room gate each tail, never the flag alone: a
    /// sender that sets the body bit but sends no room for it is a bug we must
    /// not read past the end of -- reported via <see cref="GhostSample.BodyStateShort"/>;
    /// a sender-ms bit without its four bytes simply yields no sender ms.
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

        bool flagged = (flags & Protocol.PositionFlagBodyState) != 0;
        int tail = payload.Length - Protocol.GhostPayloadLen;   // 0, 4, 5 or 9
        int o = Protocol.GhostPayloadLen;
        BodyState? body = null;
        bool shortPacket = false;
        if (flagged && (tail == Protocol.BodyStateLen || tail == Protocol.BodyStateLen + Protocol.SenderMsLen))
        {
            body = new BodyState(
                (BodyPace)payload[o], (BodyDir)payload[o + 1], (BodyStance)payload[o + 2],
                BinaryPrimitives.ReadUInt16LittleEndian(payload[(o + 3)..]));
            o += Protocol.BodyStateLen;
        }
        else if (flagged)
        {
            shortPacket = true;
        }
        uint senderMs = 0;
        if ((flags & Protocol.PositionFlagSenderMs) != 0 && payload.Length - o == Protocol.SenderMsLen)
            senderMs = BinaryPrimitives.ReadUInt32LittleEndian(payload[o..]);

        sample = new GhostSample(ghostId, x, y, z, rotZ, flags, body, shortPacket, senderMs);
        return true;
    }
}
