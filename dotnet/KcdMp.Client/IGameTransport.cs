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
}
