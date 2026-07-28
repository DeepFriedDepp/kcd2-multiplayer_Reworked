using KcdMp.Wire;

namespace KcdMp.Client;

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
