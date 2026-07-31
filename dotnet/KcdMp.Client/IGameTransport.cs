namespace KcdMp.Client;

/// <summary>
/// One sample of local player state. Whatever the transport, this is the unit
/// the sync loop actually needs per tick.
/// </summary>
/// <param name="X">World X.</param>
/// <param name="Y">World Y.</param>
/// <param name="Z">World Z.</param>
/// <param name="RotZ">Yaw in radians.</param>
/// <param name="IsRiding">True while mounted.</param>
public readonly record struct PlayerState(float X, float Y, float Z, float RotZ, bool IsRiding);

/// <summary>
/// The channel between the agent and its local game instance.
///
/// This exists so the rest of the agent does not care *how* it talks to the
/// game. Today the only implementation is <see cref="HttpGameTransport"/>,
/// which pays one HTTP round trip per call against the debug API on
/// localhost:1403 -- the constraint WO-1 exists to remove.
///
/// The shape is deliberately intent-based rather than mechanism-based:
/// <see cref="ReadPlayerStateAsync"/> asks for a whole state sample rather
/// than exposing "read position" and "read a CVar" separately. The HTTP
/// implementation happens to need up to three round trips to answer it; a
/// push-based transport (log tail or file mailbox) answers the same call from
/// its most recent frame with no round trip at all. Callers see one method
/// either way, so swapping the transport does not ripple outwards.
/// </summary>
public interface IGameTransport : IAsyncDisposable
{
    /// <summary>Short name for logs and benchmark output.</summary>
    string Name { get; }

    /// <summary>
    /// Round trips needed to answer one <see cref="ReadPlayerStateAsync"/>.
    /// Zero means the transport is push-based and reads from cached state.
    /// Reported by the benchmark so a comparison shows *why* one is faster.
    /// </summary>
    int RoundTripsPerStateRead { get; }

    /// <summary>True once the game is running with a save loaded.</summary>
    Task<bool> IsGameReadyAsync(CancellationToken ct = default);

    /// <summary>
    /// Reads the local player's position, yaw and mount state, or null if the
    /// game is mid-load or otherwise not answering.
    /// </summary>
    Task<PlayerState?> ReadPlayerStateAsync(CancellationToken ct = default);

    /// <summary>
    /// Runs a Lua statement in the game. Fire-and-forget: no value comes back.
    /// A batching transport may buffer this until <see cref="FlushAsync"/>.
    /// </summary>
    Task ExecuteAsync(string lua, CancellationToken ct = default);

    /// <summary>
    /// Sends anything buffered by <see cref="ExecuteAsync"/>. A no-op for
    /// transports that send immediately, so callers can always call it.
    /// </summary>
    Task FlushAsync(CancellationToken ct = default);

    /// <summary>
    /// The local player's currently-equipped item classes (WO-9), read via the
    /// reflection debug API's <c>EquipmentManager.EquippedArmorsByClassId</c>
    /// -- NOT the Lua clothing-preset binding, which only reports the preset a
    /// soul was spawned with and goes blank the moment the player re-equips
    /// anything by hand. Empty (not null) if the game is not answering.
    /// </summary>
    Task<Guid[]> ReadEquippedItemClassesAsync(CancellationToken ct = default);

    /// <summary>
    /// Reads a named ghost soul's own equipped item classes back. Used to
    /// verify an apply actually took -- a fault-free EquipItem invoke is not
    /// a successful one, the same trap the native reflection ABI has
    /// everywhere else -- never to drive the outbound diff, which is
    /// tracked client-side instead.
    /// </summary>
    Task<Guid[]> ReadGhostEquippedItemClassesAsync(string ghostSoulName, CancellationToken ct = default);

    /// <summary>
    /// Equips one item class onto a named ghost soul (e.g. "kcd2mp_5"), via
    /// the same native <c>EquipmentManager.EquipItem</c> reflection call
    /// proven in WO-9 Phase 0 to render visually -- unlike the Lua
    /// <c>actor:EquipInventoryItem</c> binding, which does not.
    /// </summary>
    /// <param name="createIfMissing">
    /// True the first time this item class is applied to this ghost: it has
    /// no instance of that class in its inventory yet, so one must be created
    /// via <c>Inventory.CreateItems</c> first. False on every later
    /// application of the same class to the same ghost, since the created
    /// instance is still sitting in its inventory, just unequipped -- calling
    /// CreateItems again would pile up duplicates for no reason.
    /// </param>
    Task EquipItemOnGhostAsync(string ghostSoulName, Guid itemClass, bool createIfMissing, CancellationToken ct = default);

    /// <summary>Unequips one item class from a named ghost soul.</summary>
    Task UnequipItemOnGhostAsync(string ghostSoulName, Guid itemClass, CancellationToken ct = default);
}
