# Session prompt — WO-36: what it costs to be near another player

Paste everything below the rule into a fresh session, working directory
`C:\Users\Jonasty\Documents\KCD2_MP`. Prefix commits `WO-36:`.

Written at the end of WO-34, which found this and could not close it.
Revised after WO-32, which changed the terrain this WO walks on. Four
carry-overs, applied below, not optional reading:

1. **NPC sync now exists and is ON by default** (`0x26`/`0x27`, WO-32). Up to
   5 hand-placed NPCs within 30 m of the session's world authority (WO-28's
   Rule 2 holder — in practice the host) are position/animation/health-driven
   in everyone else's world. Two consequences for this WO: (a) crime
   measurements on a non-authority machine must be taken with `mp_npc_sync
   off` (or as the authority) unless the sync interaction is what's being
   tested, because a puppeted guard's position is externally driven; (b) the
   per-machine crime asymmetry (Phase 1) is now *visible* — a synced guard can
   be seen chasing a criminal that does not exist in the observer's world.
   WO-32 shipped that as a stated simplification, not an answer; this WO is
   where the answer gets decided.
2. **A brand-new, untested question WO-32 created — added to Phase 1:** while
   an NPC is being puppeted (its position stream winning against its AI), can
   it still act as a crime participant in the *local* world — witness a crime,
   respond as a guard, initiate an arrest? WO-32 observed that pure position
   driving contacts nothing (no crime buffs, dialogue intact after release,
   nearby NPCs indifferent) but never committed a crime in front of a
   puppeted NPC. A guard that goes blind while synced would be a real
   gameplay hole on every non-authority machine, silently.
3. **Verify the environment before trusting any wire-adjacent result.** WO-32
   lost a full E2E run to a stale relay from `%LocalAppData%\KCDMP` silently
   skipping unknown packet types — check `Get-Process KcdMpServer,KcdMpClient
   | Select-Object Path` matches the repo build before believing anything
   crosses the wire. Related: the assistant's sandbox redirects
   `%LocalAppData%`, so anything involving the installed app (installs,
   Verify-Install.ps1) is the human's to run, not the session's.
4. **The live-testing discipline that worked in WO-32, kept:** a positive
   control in the same session (WO-34's rule, applied to a real NPC pair in
   WO-32), verification against engine-resolved state only, and — new —
   `tools/Test-NpcSyncE2E.ps1` as the template for a synthetic-peer test that
   needs the peer to *hold authority* (its Phase 3 documents the
   agent-restart trick that moves the role).

Facts WO-32 established that this WO can lean on: a real hand-placed NPC
needs no AI suppression to be externally driven (a 50 ms stream wins), and
stopping the stream is a complete release — the engine restores the NPC's
schedule within ~3 s with no crime/faction/dialogue side effects observed.
`ttkc_man_16` (varlet, civilian crime role, clean faction ancestry, no quest
references) is a pre-vetted test NPC with `ttkc_man_10` as its control; the
vetting method is in WO-32-findings Phase 0. `KCD2MP.npcPuppets` /
`KCD2MP.npcTracked` are the live sync tables; `mp_npc_sync on|off` is the
toggle (authority side only). VERSION is `0.11.8` as of WO-32 — and as
always, no session touches it unasked (`docs/VERSIONING.md`).

---

This is the follow-up WO-34 explicitly did not do. WO-34 fixed the *reported*
symptoms — five hostile bandit souls in the face roster, and a corpse that slid
around tracking a live player. While auditing why, it found something bigger and
left it alone deliberately: **every ghost, including every corrected one, is a
full participant in KCD2's crime and reputation systems, and nobody has ever
evaluated what that costs.**

Nothing here is known-broken. That is exactly why it needs a real look — it is a
cost that lands silently, on a real save, and the only reason we know it exists
is that one tester happened to get pilloried.

This touches crime, reputation, arrest, wanted status, social class and the
`soul_vip_class` protection tier — mostly systems this project has read but
never *exercised*. Genuine unfamiliar-territory probing. Audited afterward.
Every claim needs real evidence — **observed / read-but-unrendered /
inconclusive**, never rounded up. Terse: no restating this prompt, no recap
paragraphs, bullet facts, ask only when blocked.

## Read first

1. `docs/WO-34-findings.md` — the whole thing, but especially §1 (the systems
   audit), §5 (what the arrest actually was, and the human's answer about
   reload-clears-crime), and §7 (the four things left open, which this WO is
   items 1 and 2 of).
2. `docs/WO-25-findings.md` Phase 3 — the `soul_vip_class_id` protection tiers,
   live-verified to intercept lethal damage, and the human's recorded decision
   on ordinary NPC killability. That decision is the precedent this WO has to
   argue with or accept.
3. `docs/WO-22-brain-lead.md`, the paragraph beginning *"A shipped ghost is a
   `Civilians`-faction NPC standing in a settlement"* — this whole class of
   problem was predicted there and not followed up for twelve work orders.

## The facts WO-34 established, so you do not re-derive them

Read from the shipped `Tables.pak` / `English_xml.pak`, extracted from
`D:\SteamLibrary\steamapps\common\KingdomComeDeliverance2\Data\`:

- `Libs/Tables/rpg/crime.xml` applies to a ghost in full: `pickpocket` 550
  groschen / 2 days jail, `theft` 500/3, `assault` 1500/5, `murder` 20000/**7**,
  `corpseViolation` 2000/5, `aggression` 750/1. Several carry
  `scalingWithSocialClass="true"`.
- `reputation_change.xml` routes crime penalties at
  `reputation_change_target_id=14` = *faction + nearbyfactions + superfaction*
  (`crime_murder_reported` = **-1.5**, `crime_theft_reported` = -0.15). A ghost
  inherits the donor soul's real `factionName`, so the penalty lands on a real
  settlement.
- All 43 remaining roster souls carry `soul_vip_class_id="0"` — no protection of
  any kind.
- The displayed NPC label comes from **`FactionNode.UIName`**, not from
  `social_class`. Do not repeat WO-34's wrong turn there.
- `AI.GetFactionOf` **does not exist** in this build.
  `entity.Properties.esFaction = "Civilians"` plus
  `AI.ChangeParameter(..., AIPARAM_FACTION, "Civilians")` reads back as
  Civilians and does nothing — the soul row wins.

Tooling that already exists and works: `tools/wo34-probe.ps1` (one-shot Lua
chunk → tagged log lines), `tools/KcdApi.ps1` (bounded RTTR reflection client),
`tools/Lua-Driver.ps1`.

## Phase 0 — measure the cost before arguing about it

Everything in WO-34 §1.1–1.2 is **read from tables, not observed in play**. That
distinction is the whole point of this phase. A table row saying `fine="20000"`
is not proof that killing a ghost fines anybody anything.

For each of these, get a real before/after reading from the running game:

1. **Pickpocket another player's ghost.** Does it open the real pickpocketing
   minigame? Does a witness register? Does a bounty appear? How much?
2. **Assault one** — unarmed, in a settlement, in front of guards. Bounty,
   witness count, wanted state.
3. **Kill one.** Bounty, reputation delta against the settlement whose faction
   the ghost inherited, and whether the body creates a `corpse` crime event that
   other NPCs later find.
4. **Loot the corpse.** `corpseViolation` is 2000/5 on paper. Does it fire?
5. **The control that matters most:** do all four against a *real, hand-placed
   NPC of the same faction* and compare. If the numbers match, ghosts are
   ordinary NPCs and this is purely a design question. If they differ, something
   about a runtime-spawned soul behaves differently and that is a finding.

Reputation is readable — WO-22 read a ghost's `FactionNode.Log` and found the
donor's full inherited reputation entries. Find the player-side equivalent and
read it before and after, rather than inferring from a notification.

**Do not run this on a save you care about.** Take a backup first and say in the
findings which save was used and whether it was restored. WO-25 got a blanket
"this save is disposable" for `playline2`; do not assume that still holds —
**ask.**

## Phase 1 — the asymmetry nobody has looked at

Crime state is **per-machine**. Player A's bounty exists only in A's world; B's
guards never heard of it. That was stated in WO-34 §5.2 and never tested.

Determine, with real evidence:

- If A commits a crime against B's ghost in A's world, does *anything* reach B?
- B's real Henry is untouched — but is B's *ghost in A's world* now flagged, and
  does that flag survive B reconnecting (a fresh spawn) or A reloading?
- The one that actually bites: **can one player give another a bounty they
  cannot see and cannot clear?** If A murders someone in front of B's ghost, is
  B implicated? Vanilla has witness and accomplice logic; whether a ghost can be
  a witness *for* or an accomplice *to* a crime is completely unknown.
- **New since WO-32 — the puppeted-guard question** (carry-over 2 above):
  commit a crime in front of an NPC while it is actively being driven by the
  sync stream, on a non-authority machine. Does it witness? Does a puppeted
  guard respond, or is it blind for as long as the stream runs? Test both
  during the drive and immediately after release, against the same NPC
  unpuppeted as the control. If puppeted NPCs are blind, say plainly what
  that means for the default-on setting: every synced guard near the
  authority is a non-guard in everyone else's world.

This phase is the strongest candidate for a genuinely new bug rather than a
design question. Weight it accordingly.

## Phase 2 — the roster's remaining data-quality question

WO-34 removed the five hostile souls and deliberately left two things:

- **Three `trosecko_settlements_trosky_nobility_lordsAndLadies` souls.** Crimes
  against them scale up (`scalingWithSocialClass="true"`), so those players are
  more expensive to hit than others. Measure the actual difference — if it is
  large, three players in a roster of 43 are carrying a hidden penalty for
  everyone around them.
- **Four `_soldiers_guards` / `_soldiers_militia` souls.** These carry
  `soul_crime_role_id=2` = `soldier`, and `soul_crime_role.xml`'s own comment
  says *"Only socialClasses that are authority figures are supposed to have
  this; affects wanted icon."* Find out what that actually does when the
  authority figure is another player's ghost.

Neither is hostile, so neither is urgent. Both are the same category of mistake
as the bandits — souls picked for how they look, with gameplay properties nobody
read.

## Phase 3 — present options, do not choose

This is a product decision and the session does not make it. Present real
findings and let the human decide. Likely shape of the options, but derive them
from what you actually measure rather than from this list:

- **Leave it entirely.** Consistent with WO-25's recorded decision — players get
  the same freedom they have solo, consequences included. Cheapest, and possibly
  correct.
- **Curate the roster harder.** Pick souls whose social class carries the lowest
  crime/reputation weight, making ghosts cheap to be near. Data-only, no engine
  dependency, same shape as WO-34's fix.
- **Protect ghosts natively.** `soul_vip_class_id` is live-verified (WO-25) to
  intercept real lethal damage. If it can be set on a runtime-spawned soul —
  **unknown, and worth one real experiment** — a tier like `attack_protection`
  or `pickpocket protection` would make ghosts non-targets without any custom
  code. Note the tension with WO-25's decision immediately: the same flag that
  stops griefing also stops the kill-all-NPCs freedom the human explicitly
  wanted, so scope it to ghosts only or not at all.
- **Warn instead of prevent.** Surface a one-time in-game warning the first time
  a player draws on or steals from another player's ghost. Cheap, preserves
  freedom, and matches the human's stated instinct that emergent chaos is fine
  as long as it is not a trap.

Whatever the options turn out to be, present them **sync-aware**: WO-32 made
NPC positions shared while crime state stayed per-machine, and the human
should decide those two facts together, not separately — "whose crime state
wins when the NPCs are shared" is the same product decision as "what does
mistreating a ghost cost", seen from the other side.

## What this session does NOT do

- **No unilateral product decision.** Phase 3 presents; the human chooses.
- **No `VERSION` change and no release build** — `docs/VERSIONING.md`.
- **Do not re-fix the roster's hostility.** WO-34 did that and verified it; if
  you find a hostile soul still in there, that is a WO-34 regression and should
  be said loudly, not quietly patched.
- **Do not build a custom crime-suppression system on spec.** If the answer is
  "prevent it", the mechanism is the *next* WO's problem, after the human has
  chosen. WO-25's Phase 4 stopped exactly here and was right to.

## Definition of done

- `docs/WO-36-findings.md`: Phase 0's measured costs with real before/after
  numbers and the real-NPC control; Phase 1's asymmetry answered or explicitly
  marked inconclusive; Phase 2's two roster questions measured; Phase 3's
  options presented with the human's recorded decision if reached.
- `docs/WO-36-progress.md` appended.
- If Phase 1 turns up a real bug — a bounty a player cannot see or clear — that
  is a bug fix, not a design question, and should be fixed and verified in this
  session or scoped precisely for the next one.
- Any save used for destructive testing named, and its backup/restore state
  stated.

## How I want you to work

1. Measure before arguing. A table row is not a consequence.
2. Always run the real-NPC control. "Ghosts cost X" means nothing without
   "and a real NPC costs Y".
3. Phase 1 before Phase 2 if time is short — it is the one that might be a bug.
4. Terse.
