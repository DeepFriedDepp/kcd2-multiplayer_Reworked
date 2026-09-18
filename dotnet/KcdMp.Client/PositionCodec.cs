using System.Buffers.Binary;

namespace KcdMp.Client;

/// <summary>
/// One decoded Ghost (0x02) payload. <see cref="Body"/> is set only when the
/// BODYSTATE flag and the V2 length agree; <see cref="BodyStateShort"/> is the
/// bug case (flag set, 18-byte packet) that a receiver must count, not read.
/// </summary>
public readonly record struct GhostSample(
    byte GhostId, float X, float Y, float Z, float RotZ, byte Flags, BodyState? Body, bool BodyStateShort)
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
    /// Builds a complete Position packet (3-byte header included). 17-byte
    /// payload when <paramref name="body"/> is null, 22 when it is not, with the
    /// BODYSTATE flag following the same condition -- the two can never disagree.
    /// </summary>
    public static byte[] BuildPosition(float x, float y, float z, float rotZ,
                                       bool isRiding, bool stale, BodyState? body)
    {
        int payloadLen = body.HasValue ? Protocol.PositionPayloadLenV2 : Protocol.PositionPayloadLen;
        var packet = new byte[3 + payloadLen];
        packet[0] = Protocol.Position;
        BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(1), (ushort)payloadLen);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(3),  x);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(7),  y);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(11), z);
        BinaryPrimitives.WriteSingleLittleEndian(packet.AsSpan(15), rotZ);
        packet[19] = (byte)((isRiding ? Protocol.PositionFlagRiding : 0)
                          | (stale    ? Protocol.PositionFlagStale   : 0)
                          | (body.HasValue ? Protocol.PositionFlagBodyState : 0));
        if (body is BodyState b)
        {
            packet[20] = (byte)b.Pace;
            packet[21] = (byte)b.Dir;
            packet[22] = (byte)b.Stance;
            BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(23), b.AnimSpeedCenti);
        }
        return packet;
    }

    /// <summary>
    /// Decodes a Ghost payload of exactly <see cref="Protocol.GhostPayloadLen"/>
    /// or <see cref="Protocol.GhostPayloadLenV2"/> bytes; any other length is
    /// refused (false). Both conditions gate the body, not just the flag: a
    /// sender that sets the bit but sends a short packet is a bug we must not
    /// read past the end of -- it is reported via <see cref="GhostSample.BodyStateShort"/>.
    /// </summary>
    public static bool TryDecodeGhost(ReadOnlySpan<byte> payload, out GhostSample sample)
    {
        sample = default;
        if (payload.Length != Protocol.GhostPayloadLen && payload.Length != Protocol.GhostPayloadLenV2)
            return false;

        byte  ghostId = payload[0];
        float x       = BinaryPrimitives.ReadSingleLittleEndian(payload[1..]);
        float y       = BinaryPrimitives.ReadSingleLittleEndian(payload[5..]);
        float z       = BinaryPrimitives.ReadSingleLittleEndian(payload[9..]);
        float rotZ    = BinaryPrimitives.ReadSingleLittleEndian(payload[13..]);
        byte  flags   = payload[17];

        bool flagged = (flags & Protocol.PositionFlagBodyState) != 0;
        BodyState? body = null;
        bool shortPacket = false;
        if (flagged && payload.Length == Protocol.GhostPayloadLenV2)
        {
            body = new BodyState(
                (BodyPace)payload[18], (BodyDir)payload[19], (BodyStance)payload[20],
                BinaryPrimitives.ReadUInt16LittleEndian(payload[21..]));
        }
        else if (flagged)
        {
            shortPacket = true;
        }

        sample = new GhostSample(ghostId, x, y, z, rotZ, flags, body, shortPacket);
        return true;
    }
}
