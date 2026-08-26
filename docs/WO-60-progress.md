# WO-60 — progress

## 2026-08-26 — full session

Built WO-59 Thread A's design verdict: per-NPC proximity authority via the
existing claim mechanism. Trigger: today's real two-human retest reproduced
the same jitter/one-sided-combat symptoms with WO-59's hysteresis and clock
sync already shipped (no logs captured — the persistence itself is the
signal, recorded as such, not rounded up).

**Phase 1 (new emitter)**: the non-authority now runs the same
rescan/emit loop as the authority around its own player, emitting
`npc_claim` down the drag sensor's asClaim path — sending is the claim,
relay unchanged in shape. Puppet exclusion in the rescan means claims only
ever target NPCs nobody is streaming; the loser of any race self-heals into
a puppet within one scan cycle. Bonus closed by construction: swing cues now
emit for NPCs fighting the non-authority (the WO-51 asymmetry row).

**Phase 2 (the hold — the real design work)**: engagement travels as flag
bit 32 (NPC drawn + alive + within 12 m of the emitting player, emitted
immediately on change); the relay's claim record gained `EngagedUtc`; a
claim expires only when silence > 5 s AND last engagement > 15 s
(`NpcClaimEngagedHoldSeconds`). While held, neither the authority nor a
rival claimant can take the entity, and dropped rival packets touch nothing
— so a menu-pause packet gap mid-fight can no longer snap an NPC between
two diverged simulations. Cost accepted deliberately: a silent holder
leaves the NPC on local autonomy (receiver puppet-release at 3 s) for up to
15 s instead of 5. Un-engaged (drag) claims keep WO-39's 5 s behaviour
bit-for-bit.

**Phase 3 (rollback)**: `mp_npc_proximity on|off`, default on, mp_npc_sync
pattern. Off clears the non-authority's tracked set on the spot and gates
the fall-through, restoring pre-WO-60 host-only tracking through the relay's
ordinary expiry path — no relay toggle needed (no engaged claims arriving =
WO-39 behaviour, proven by the unchanged T10–T14 passes and T20).

**Phase 4 (tests)**: Test-TimeSkipRelay extended T17–T20 — sustained
two-claimant pressure (holder never moves, 9/9 packets single-source),
hold survives 6 s holder silence against both a rival and the authority,
hold decays after 15 s genuine quiet, un-engaged claims keep plain expiry.
Suite 35/35 against a live relay; Test-ItemSyncRelay 11/11; Farkle 59/59;
both solutions build clean. No game ran this session: Lua half
code-verified only, pak not rebuilt, no VERSION change. Harness lesson
recorded: never pipe a comma-wrapped drain result straight into
Where-Object.

Full detail: docs/WO-60-findings.md.
