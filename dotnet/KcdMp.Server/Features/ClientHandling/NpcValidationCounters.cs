namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// WO-66: running totals of NpcStateUp packets the relay rejected, one per
/// reason tag (matching the [WO66-REJECT] log lines). Served by
/// GET api/information/npc-validation. Speed includes non-finite positions;
/// Rotation is non-finite rotZ. All zero on a healthy wire.
/// </summary>
public record NpcValidationCounters(long Speed, long Rotation, long ReservedName, long StaleOwner);
