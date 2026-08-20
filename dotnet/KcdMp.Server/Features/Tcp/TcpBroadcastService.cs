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
    /// Relays a PlayerStateUp (0x1F) to all other ready clients as a
    /// PlayerStateDown (0x20) (WO-28 Flow A). Idempotent at the receiver like
    /// Appearance -- it is current state, not an event, so a duplicate or a
    /// stale resend is harmless.
    /// </summary>
    public void BroadcastPlayerState(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueuePlayerState(source.Id, body);
    }

    /// <summary>
    /// Relays an NpcStateUp (0x26) from the world authority to all other ready
    /// clients as an NpcStateDown (0x27) (WO-32). Idempotent at the receiver:
    /// it is current state, not an event -- a duplicate simply re-targets the
    /// receiver's interp toward the same position. The caller has already
    /// verified the sender holds Rule 2's authority.
    /// </summary>
    public void BroadcastNpcState(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueNpcState(source.Id, body);
    }

    /// <summary>
    /// Relays a TimeSkipUp (0x28) from <paramref name="source"/> to all other
    /// ready clients as a TimeSkipDown (0x29) (WO-38 Phase 1). The caller has
    /// already applied the one-active-skip routing rules -- by the time a
    /// packet reaches here it is meant for everyone else, and the initiator
    /// deliberately never hears their own skip back (their own game already
    /// showed them the sleep/wait UI).
    /// </summary>
    public void BroadcastTimeSkip(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueTimeSkip(source.Id, body);
    }

    /// <summary>
    /// Relays a HorseInfoUp (0x2A) from <paramref name="source"/> to all other
    /// ready clients as a HorseInfoDown (0x2B) (WO-38 Phase 5). Idempotent at
    /// the receiver like Appearance: it is current state, not an event.
    /// </summary>
    public void BroadcastHorseInfo(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueHorseInfo(source.Id, body);
    }

    /// <summary>
    /// Relays a CombatEventUp (0x2C) from <paramref name="source"/> to all
    /// other ready clients as a CombatEventDown (0x2D) (WO-39 Phase 1).
    /// Cosmetic on every receiver, so no authority gate -- same reasoning as
    /// HorseInfo: a fact about the sender, not about the shared world.
    /// </summary>
    public void BroadcastCombatEvent(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueCombatEvent(source.Id, body);
    }

    /// <summary>
    /// Relays a WeatherUp (0x2E) from <paramref name="source"/> to all other
    /// ready clients as a WeatherDown (0x2F) (WO-40 Phase 3). Cosmetic and
    /// idempotent at the receiver (applied only on profile change), so no
    /// authority gate -- only the arbiter sends by convention.
    /// </summary>
    public void BroadcastWeather(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueWeather(source.Id, body);
    }

    /// <summary>
    /// Relays an NpcDamageUp (0x30) from <paramref name="source"/> to all
    /// other ready clients as an NpcDamageDown (0x31) (WO-40 Phase 5).
    /// Name-addressed damage -- same no-gate reasoning as 0x12: any client
    /// reports damage it observed in its own world.
    /// </summary>
    public void BroadcastNpcDamage(ClientSession source, byte[] body)
    {
        foreach (var target in Others(source))
            target.EnqueueNpcDamage(source.Id, body);
    }

    /// <summary>
    /// Routes a PlayerHitUp (0x21) to the single player it names, as a
    /// PlayerHitDown (0x22) (WO-28 Flow B).
    ///
    /// **Not a broadcast.** This is a hit taken by one specific player, and
    /// only their own client may act on it (Rule 1: a player's health is
    /// authoritative on their own machine). Everyone else learns about it the
    /// ordinary way, from that player's next Flow A broadcast.
    ///
    /// A hit naming an unknown or departed id is dropped silently: the sender
    /// sampled a ghost that has since disconnected, which is a race, not an
    /// error. A hit a client aims at itself is dropped too -- its own game
    /// already applied it.
    /// </summary>
    public void RoutePlayerHit(ClientSession source, byte[] body)
    {
        byte targetId = body[0];
        if (targetId == source.Id) return;

        foreach (var target in _clientHandler.GetClients())
            if (target.IsReady && target.Id == targetId)
            {
                target.EnqueuePlayerHit(body);
                return;
            }
    }

    /// <summary>
    /// Relays a PlayerDeathUp (0x23) to all other ready clients as a
    /// PlayerDeathDown (0x24) (WO-28 Flow C). Idempotent at the receiver.
    /// </summary>
    public void BroadcastPlayerDeath(ClientSession source)
    {
        foreach (var target in Others(source))
            target.EnqueuePlayerDeath(source.Id);
    }

    /// <summary>
    /// Tells every ready client whether it currently holds Rule 2's NPC→player
    /// damage authority (0x25, WO-28).
    ///
    /// Called whenever the connection set changes -- a join or a disconnect can
    /// both move the role. Sent unconditionally to everyone rather than only to
    /// the two clients whose answer changed: it is one byte on a rare event,
    /// and "tell everyone the current answer" cannot leave a client holding a
    /// stale yes, which is the failure that would actually hurt (two authorities
    /// at once is exactly the N-damage-streams problem the role exists to stop).
    /// </summary>
    public void BroadcastCombatRole()
    {
        var authority = _clientHandler.DamageAuthority;
        foreach (var target in _clientHandler.GetClients().Where(c => c.IsReady))
            target.EnqueueCombatRole(ReferenceEquals(target, authority));
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
