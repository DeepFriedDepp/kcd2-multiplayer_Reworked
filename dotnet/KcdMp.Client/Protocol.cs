namespace KcdMp.Client;

/// <summary>
/// The relay wire protocol, as seen from the agent.
///
/// Framing (every packet):  [type:1][payloadLen:2 LE][payload:N]
/// Floats are little-endian IEEE-754.
///
/// C→S  0x00  Handshake:  [version:1][nameLen:1][name:UTF-8]
/// C→S  0x01  Position:   [x:4f][y:4f][z:4f][rotZ:4f][flags:1]  (17 bytes)
///                          flags bit 0: isRiding
/// C→S  0x04  Ping:       [timestamp:8 LE int64]
/// C→S  0x07  Voice:      [pcm:640]  (16 kHz mono 16-bit, 20 ms frame)
/// S→C  0x02  Ghost:      [ghostId:1][x:4f][y:4f][z:4f][rotZ:4f][flags:1]  (18 bytes)
/// S→C  0x03  Name:       [ghostId:1][name:UTF-8]
/// S→C  0x05  Pong:       [timestamp:8 LE int64]  (echo of Ping)
/// S→C  0x06  Disconnect: [ghostId:1]
/// S→C  0x08  Voice:      [sourceId:1][pcm:640]
/// S→C  0x09  VersionMismatch: [serverVersion:1]
/// S→C  0xFF  Ack:        [assignedId:1]
///
/// Free type bytes for new features: 0x0A and up.
///
/// NOTE: this file is duplicated as dotnet/KcdMp.Server/Protocol.cs. The two
/// projects share no assembly, so the constants are mirrored by hand — change
/// both together. Extracting a shared KcdMp.Protocol project is a separate
/// work order.
/// </summary>
public static class Protocol
{
    /// <summary>
    /// Protocol version, negotiated in the Handshake. Must match the relay's.
    /// </summary>
    public const byte Version = 1;

    // C→S
    public const byte Handshake = 0x00;
    public const byte Position  = 0x01;
    public const byte Ping      = 0x04;
    public const byte VoiceUp   = 0x07;

    // S→C
    public const byte Ghost           = 0x02;
    public const byte Name            = 0x03;
    public const byte Pong            = 0x05;
    public const byte Disconnect      = 0x06;
    public const byte VoiceDown       = 0x08;
    public const byte VersionMismatch = 0x09;
    public const byte Ack             = 0xFF;

    /// <summary>Exact Position (0x01) payload length.</summary>
    public const int PositionPayloadLen = 17;

    /// <summary>Exact Ghost (0x02) payload length.</summary>
    public const int GhostPayloadLen = 18;

    /// <summary>Exact voice frame length: 20 ms of 16 kHz mono 16-bit PCM.</summary>
    public const int VoiceFrameLen = 640;
}

/// <summary>
/// Thrown when the relay rejects our protocol version. Fatal: retrying cannot
/// help, so <see cref="GameBridge.RunAsync"/> stops instead of reconnecting.
/// </summary>
public sealed class ProtocolVersionMismatchException(byte serverVersion) : Exception(
    $"Relay speaks protocol v{serverVersion}, this agent speaks v{Protocol.Version}. " +
    "Update both the agent and the relay to the same build.")
{
    public byte ServerVersion { get; } = serverVersion;
}
