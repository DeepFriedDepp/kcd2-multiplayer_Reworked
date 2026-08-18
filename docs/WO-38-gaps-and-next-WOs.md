# What WO-38 did NOT do — the honest gap list, grouped into buildable WOs

Written 2026-08-18 at the human's request, to sequence several solo-buildable
releases before the next real two-human test round. Ordering inside each tier
is by (visible impact to a tester) × (confidence it can be verified without a
second human).

---

## Tier 1 — big visible features WO-38 explicitly did not build

### A. Combat visibility (the Phase 4 gap) — the largest quality item on the list
WO-38 *determined* the cause (nothing combat-shaped has ever been emitted —
the observing player faithfully sees "standing with arms down") and built only
the death pose. NOT done: any sharing of combat state. A "shared combat
visuals" WO needs:
- weapon drawn/sheathed on the wire (Human.DrawWeapon exists, WO-23 — apply
  side plausible today);
- a swing/attack event channel driving combat animations on the ghost
  (research: which combat anims play via StartAnimation vs locked behind
  Mannequin — the probe pattern from WO-38 applies);
- possibly block/stagger/hit reactions.
Solo-verifiable to a good level: synthetic peer + eyeballing the ghost while
the real player fights. This is the single most tester-visible gap left.

### B. Map markers (Phase 8, feature NOT delivered)
Both documented routes are dead on this build (`GameRules` and `Map` are nil;
AddMinimapEntity unregistered — probed live). NOT done: the actual feature.
A dedicated research WO: enumerate the map UI's UIAction surface
(`UIAction.CallFunction` targets beyond "hud" — the map panel's element name,
its exposed functions), with the launcher-side map as the declared fallback if
the panel is closed. Solo-verifiable end to end (marker either renders or it
does not).

### C. Per-entity authority migration (the Phase 6 design call, still undecided)
Today exactly one client's world dictates ALL NPC state. Consequences WO-38
documented but did not change:
- a non-authority player's corpse-drag syncs to nobody;
- a non-authority player's kills/knockouts exist only locally unless the 0x12
  damage path reproduces them (see F);
- NPC sync stops mattering when the authority's world is paused/unloaded.
The WO: design + build per-entity (or per-interaction) authority handoff —
"the player acting on a body owns that body's stream while acting on it."
Real race questions; the relay's TimeSkip arbitration (first-come, grace
windows) is the in-house precedent shape. Wire-testable solo with synthetic
peers, exactly like Test-TimeSkipRelay.

---

## Tier 2 — investigations WO-38 opened that a solo session can close

### D. The forge bug — confirm or kill the hypothesis, then fix on evidence
NOT done: any fix, and the hypothesis (environmental damage to the ghost
standing in the forge, relayed by attribution-blind Flow B) is unconfirmed.
Solo session: stand a synthetic-peer ghost at a lit forge, watch its health
and `[playerhit]` traffic. If confirmed, the fix discussion has real options
(suppress Flow B while the owner is in a crafting minigame — kcd.log marker
detection, the WO-11 pattern; or a damage-rate sanity cap). One machine
suffices for the confirm; two humans only for the regression pass.

### E. The stuck-barks fix (Phase 7 shipped only the A/B probe)
NOT done: the actual fix. The `mp_ghost_ignorant` A/B needs real combat near
a ghost — solo-doable (spawn ghost, aggro an NPC onto it per WO-26 mechanics,
listen). If SetIgnorant passes both edges (barks stop AND ghost stays
targetable), a follow-up WO makes stimulus-deafness the spawn default —
which the human must approve as a behaviour change.

### F. Knockout/death replication correctness (surfaced in Phase 6, untouched)
The report showed PB knocking an NPC out while PA's copy stayed "alive and
well" — the 0x12 damage path replicates health/stamina numbers, but nobody
has ever verified a replicated stamina hit reproduces UNCONSCIOUSNESS, nor
that a replicated kill reproduces death cleanly on the other machine. Solo
session: synthetic peer sends the exact 0x12 a knockout produces; read
IsUnconscious on the local copy. If it does not reproduce, that is a real
sync gap needing its own flow (0x26 flags bit 1 already tells receivers, but
telling is not the same as the state existing).

### G. Clothing: the shirt/pants source gap (Phase 7, hypothesis unprobed)
One read settles it: equip shirt/pants, read `EquippedArmorsByClassId`, and
if absent walk `EquipmentManager`'s siblings for the third map. Ten minutes
with the game up. If a third map exists, the fix is one more source map on
the poll (the WO-10 weapons precedent, near-zero risk). Was simply not
reachable in WO-38's game-less main session and got deprioritised during the
live battery.

### H. Skip-kind detection, second route (Phase 1's one soft spot)
kcd.log is a confirmed dead end (real diff). NOT tried: detecting the bed
interaction itself — player position/stance during the skip, proximity to a
Bed-class entity at skip start, or savegame-creation as a bed signal. Small,
self-contained, pure polish ("slept till" vs "passed time to").

---

## Tier 3 — pre-existing debts WO-38 surfaced but deliberately did not touch

- **I. Launcher: two silent sub-second crashes** (PlayerA.log, 33 boot lines
  then death, no exception) — unexplained, unowned.
- **J. Launcher: render amplification + log noise** — every state change
  triple-renders the full modal tree (~80% of both testers' logs); the
  31-identical-stack-traces pattern wants a log-once guard and error backoff.
- **K. Tester diagnostics bundle** — WO-38's biggest process lesson: the only
  logs testers sent contained zero game telemetry. A "collect logs" button in
  the launcher (kcd.log + agent console + app.log, zipped) would make every
  future report actionable. Small, high leverage before the next round.
- **L. Crime/reputation cross-machine model** — WO-34 §5's open question,
  WO-32's guard-chasing-nobody seam. Needs a design WO of its own.
- **M. "Players are fully Henry"** — the WO-25 deferral (appearance +
  faction independent of donor souls). Long-horizon.
- **N. NPC sync scale** — 5 NPCs/30 m is still the measured bound; a town
  needs the client-side cost measured (WO-32's stated ceiling).
- **O. Dialogue during an active NPC drive / fighting NPCs under the stream**
  — WO-32's own open items, still unobserved.

## Two-human-only items (cannot be pulled forward, listed for completeness)

The Phase 2 phasing re-test with genuinely converged clocks; horse adoption
across two real installs (incl. whether player horses carry stable authored
names); real-fast-travel jump reporting on a long trip; the forge regression
pass after D; smoothness eyeballing under a real human's movement; the
whole tester checklist.

## Suggested release sequencing (several releases before humans, per the human)

1. **Release n+1 (quick wins):** G (clothing source) + E (barks A/B → fix if
   clean) + H (skip kind) + K (diagnostics bundle). All solo-verifiable,
   all directly answer tester-reported annoyances.
2. **Release n+2 (combat visibility):** A alone — it is big enough to be its
   own release and its own WO.
3. **Release n+3 (authority + bodies):** C + F + D's fix if the hypothesis
   confirmed. One coherent theme: "what you do to a body is what everyone
   sees."
4. **Then** the human test round, with B (map markers) slotted wherever its
   research lands.
