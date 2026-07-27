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
    ///
    /// Bumped to 2 for the interaction layer (WO-2). A version mismatch is
    /// refused at handshake, so an old peer gets a clear error rather than
    /// silently ignoring session packets it does not understand.
    /// </summary>
    public const byte Version = 2;

    // C→S
    public const byte Handshake      = 0x00;
    public const byte Position       = 0x01;
    public const byte Ping           = 0x04;
    public const byte VoiceUp        = 0x07;
    public const byte Invite         = 0x0A;
    public const byte InviteResponse = 0x0C;
    public const byte SessionEventUp = 0x0E;
    public const byte SessionLeave   = 0x10;

    // S→C
    public const byte Ghost            = 0x02;
    public const byte Name             = 0x03;
    public const byte Pong             = 0x05;
    public const byte Disconnect       = 0x06;
    public const byte VoiceDown        = 0x08;
    public const byte VersionMismatch  = 0x09;
    public const byte InviteReceived   = 0x0B;
    public const byte SessionStart     = 0x0D;
    public const byte SessionEventDown = 0x0F;
    public const byte SessionEnd       = 0x11;
    public const byte Ack              = 0xFF;

    /// <summary>Exact Position (0x01) payload length.</summary>
    public const int PositionPayloadLen = 17;

    /// <summary>Exact Ghost (0x02) payload length.</summary>
    public const int GhostPayloadLen = 18;

    /// <summary>Exact voice frame length: 20 ms of 16 kHz mono 16-bit PCM.</summary>
    public const int VoiceFrameLen = 640;
}

/// <summary>What kind of interaction a session is running.</summary>
public enum InteractionKind : byte
{
    Dice = 0x01,
    Duel = 0x02,
}

/// <summary>
/// Which side of the session this agent is on. Interactions needing an
/// asymmetry — dice turn order, who strikes first — derive it from this.
/// </summary>
public enum SessionRole : byte
{
    Initiator = 0x00,
    Acceptor  = 0x01,
}

/// <summary>Why a session ended.</summary>
public enum SessionEndReason : byte
{
    Completed = 0x00,
    Declined = 0x01,
    Timeout = 0x02,
    PeerDisconnected = 0x03,
    Left = 0x04,
    TargetBusy = 0x05,
    TargetUnavailable = 0x06,
    ProtocolError = 0x07,
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
