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
    /// Relays a Damage (0x13) event from <paramref name="source"/> to all other
    /// ready clients.
    ///
    /// Deliberately not echoed back to the sender even in echo mode, unlike
    /// Ghost: the sender's game has already applied the hit locally, and
    /// returning it would apply the same damage twice.
    /// </summary>
    public void BroadcastDamage(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueDamage(source.Id, body);
    }

    /// <summary>
    /// Relays a Death (0x15) event from <paramref name="source"/> to all other
    /// ready clients. Idempotent at the receiver, so a duplicate is harmless.
    /// </summary>
    public void BroadcastDeath(ClientSession source, byte[] soulGuid)
    {
        foreach (var target in Others(source))
            target.EnqueueDeath(source.Id, soulGuid);
    }

    /// <summary>
    /// Relays an Appearance (0x1B) update from <paramref name="source"/> to
    /// all other ready clients. Idempotent at the receiver like Damage/Death:
    /// it is a diff against last-applied state, not an event, so a duplicate
    /// or a stale resend is harmless.
    /// </summary>
    public void BroadcastAppearance(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueAppearance(source.Id, body);
    }

    /// <summary>
    /// Relays a PauseUp (0x1C) transition from <paramref name="source"/> to
    /// all other ready clients (WO-11). Idempotent at the receiver like
    /// Appearance: it is current state, not a one-shot event, so a duplicate
    /// or a stale resend is harmless -- the receiver tracks which peers are
    /// currently reporting paused and only acts on the set becoming
    /// empty/non-empty, not on each individual packet.
    /// </summary>
    public void BroadcastPause(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueuePause(source.Id, body);
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

    /// <summary>
    /// Sends a ReleaseVersion (0x1E, WO-19) packet about <paramref name="source"/>
    /// to all other ready clients -- mirrors <see cref="BroadcastName"/>. A
    /// no-op when the source's Handshake carried no release version.
    /// </summary>
    public void BroadcastReleaseVersion(ClientSession source)
    {
        if (source.ReleaseVersion is null) return;

        foreach (var target in Others(source))
            target.EnqueueReleaseVersion(source.Id, source.ReleaseVersion);
    }

    /// <summary>
    /// Sends ReleaseVersion (0x1E) packets of all currently ready clients that
    /// have one to <paramref name="newClient"/> -- mirrors <see cref="SendAllNamesTo"/>.
    /// </summary>
    public void SendAllReleaseVersionsTo(ClientSession newClient)
    {
        foreach (var c in Others(newClient))
            if (c.ReleaseVersion is not null)
                newClient.EnqueueReleaseVersion(c.Id, c.ReleaseVersion);
    }

    /// <summary>All ready clients except <paramref name="self"/>.</summary>
    private ClientSession[] Others(ClientSession self) =>
        [.. _clientHandler.GetClients().Where(c => c != self && c.IsReady)];
}
