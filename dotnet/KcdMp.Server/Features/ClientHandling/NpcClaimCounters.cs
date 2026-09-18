namespace KcdMp.Server.Features.ClientHandling;

/// <summary>
/// WO-81: running totals of NPC claim-lifecycle events, one per [CLAIM] /
/// [CLAIM-CONTESTED] log line. Served by GET api/information/npc-claims.
/// Grants/Releases/Reassignments happen routinely; Contested is the rare,
/// diagnostic signal this WO exists to surface, so it alone also gets a
/// per-NPC breakdown (ContestedByNpc). All zero/empty on a healthy wire with
/// no active claim contention.
/// </summary>
public record NpcClaimCounters(
	long Grants,
	long Releases,
	long Reassignments,
	long Contested,
	IReadOnlyDictionary<string, long> ContestedByNpc,
	// WO-102 Phase 2: claims that muted the damage authority's own stream
	// for their name at least once (the authority's implicit request being
	// denied -- the relay never logged this before), and the muted packets.
	long AuthorityMutedClaims = 0,
	long AuthorityMutedPackets = 0);
