using KcdMp.Server.Features.ClientHandling;

namespace KcdMp.Server.Features.Tcp;

/// <summary>
/// Service class that handles TCP broadcasts.
///
/// No lock of its own: <see cref="ClientHandler.GetClients"/> already returns a
/// snapshot taken under the handler's lock, which is the only shared state here.
/// </summary>
public class TcpBroadcastService
{
    private readonly bool _echo;
    private readonly ClientHandler _clientHandler;

    public TcpBroadcastService(IConfiguration configuration, ClientHandler clientHandler)
    {
        _echo = configuration.GetValue<bool>("Echo");
        _clientHandler = clientHandler;
    }

	/// <summary>
	/// Broadcasts a position update from <paramref name="source"/> to all other ready clients.
    /// In echo mode also reflects the position back to the sender as ghost id=0.
    /// </summary>
    public void Broadcast(ClientSession source, float x, float y, float z, float rotZ, byte flags)
    {
        foreach (var target in Others(source))
            target.EnqueueGhost(source.Id, x, y, z, rotZ, flags);

        if (_echo)
        {
            // Place echo ghost 1 m to the right of the player's facing direction
            float sideX = (float)Math.Cos(rotZ);
            float sideY = -(float)Math.Sin(rotZ);
            source.EnqueueGhost(0, x + sideX, y + sideY, z, rotZ, flags);
        }
    }

    /// <summary>
    /// Sends a Name (0x03) packet about <paramref name="source"/> to all other ready clients.
    /// </summary>
    public void BroadcastName(ClientSession source)
    {
        if (source.Name is null) return;

        foreach (var target in Others(source))
            target.EnqueueName(source.Id, source.Name);
    }

    /// <summary>
    /// Relays a Voice (0x08) frame from <paramref name="source"/> to all other ready clients.
    /// </summary>
    public void BroadcastVoice(ClientSession source, byte[] pcm)
    {
        foreach (var target in Others(source))
            target.EnqueueVoice(source.Id, pcm);
    }

    /// <summary>
    /// Broadcasts a Disconnect (0x06) packet to all remaining clients so they can remove the ghost.
    /// </summary>
    public void BroadcastDisconnect(ClientSession disconnected)
    {
        foreach (var target in _clientHandler.GetClients().Where(c => c.IsReady))
            target.EnqueueDisconnect(disconnected.Id);
    }

    /// <summary>
    /// Sends Name (0x03) packets of all currently ready clients to <paramref name="newClient"/>.
    /// </summary>
    public void SendAllNamesTo(ClientSession newClient)
    {
        foreach (var c in Others(newClient))
            newClient.EnqueueName(c.Id, c.Name!);
    }

    /// <summary>All ready clients except <paramref name="self"/>.</summary>
    private ClientSession[] Others(ClientSession self) =>
        [.. _clientHandler.GetClients().Where(c => c != self && c.IsReady)];
}
