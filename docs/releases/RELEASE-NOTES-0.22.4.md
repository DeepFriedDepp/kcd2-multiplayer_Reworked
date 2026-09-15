# KCD2-MP 0.22.4

The label for everything on `main` as of WO-97 (2026-09-15), packaged as
`KCDMP-Setup-0.22.4.exe`. Setup exe only — there is no DirectInstall ZIP for
this release and there will not be one again (retired in 0.22.0).

**This release contains a native change.** `KCDMP.dll` is *not* byte-identical
to the one shipped in 0.21.1 / 0.21.5 / 0.22.0 — the first native change since
0.21.1. Agent, relay, launcher and master server are republished as a matched
set. **Deploy all of it together**: a pak from this build with an older DLL, or
the reverse, is the mismatch trap WO-46 and WO-86 both record.

**Verification status, stated plainly.** The quest-fix audit that is the bulk of
this release is **code-verified, not live-verified** — it is a set of
*withdrawals*, so the thing being shipped is five fixes that no longer fire. The
native addition is a **read-only diagnostic** that ran live on the maintainer's
machine and resolved real nodes. Nothing in this release writes to the quest
graph. Synthetic: 160/160 on the WO-96 suite including the new WO-97 block.

---

## Changed: five shipped quest fixes withdrawn (WO-97)

0.22.0 shipped a table of 22 "narrow fixes" — single objectives a player who has
fallen behind can be granted through the game's own designer triggers. WO-96
classified a trigger as *clean* when its `OnTrigger` drove only that objective's
state node.

That bounded the **direct** effect and nothing else. The state transition itself
pulses its `On<State>` consumers, and those cross module-file boundaries. Walking
that chain per entry for the first time found **five of the 22 whose pulse chain
reaches `CutsceneHandler.EnqueueCutscene`**:

| quest | objective |
|---|---|
| The Prisoners of Trosky | escort Žižka, Kateřina and Bohuta to the end of the passage |
| The Magnificent Seven | help Kubenka in the fight |
| Meeting at Ratboř II | fetch the jug of wine |
| Exodus | hold out in front of the synagogue |
| The Italian Job | go to the Italian Court |

Cutscene start-time is a confirmed hard engine limit with no pre-fire warning, so
a "fix" that starts one is a worse bug wearing a fix's clothes. All five are
**removed** and named in a blocklist that refuses them even if an older peer, an
older pak or a typed console line asks for one. The generator carries the same
list, so regenerating the table cannot silently re-add them.

**Table is now 17 entries.** The other 17 were walked too and carry no cutscene,
teleport or missing-item hazard on the direction they fire.

**Two things 0.22.0's notes got wrong**, both corrected here:

* *The Hussite Rescue* ("get through the secret passage to Malešov") was named as
  the example of the cutscene hazard. It starts no cutscene — its only `Done`
  edge is a boolean port. It stays in the table.
* *Meeting at Ratboř I* ("get the document") was named as the example of a fix
  that grants the journal line without the item. The opposite is true: setting
  it Done **places the certificate on the player**, because the game's
  `AddQuestItem` node is a relocator driven by that very state. It is one of the
  safest entries in the table.

Neither was reachable from the census data; both needed the quest XML.

## Added: a read-only native window into the quest graph (WO-97)

New pipe command `0x08 ConceptProbe`, driven by `tools\Probe-ConceptRead.ps1`.
It resolves a dotted concept path through the engine's own
`C_ConceptManager::FindNode` and reports what it found. **It reads. It does not
write, and it cannot trigger anything.**

This is the first time the mod has reached into the quest concept tree natively.
It ran live and resolved real nodes at every depth, which settles three things
that were guesses for two work orders: the path separator is `.`, the first path
segment is the database name, and the concept manager has exactly two roots —
`Barbora` and `Haste`.

For players this changes nothing on its own. It is the instrument that a future
release would need before it could close a quest gap that no designer trigger
reaches — the "Hans never gave you the sacks" class of desync from the
2026-09-13 session.

## Carried from WO-96, unreleased until now

0.22.0 was cut at WO-94. WO-95 and WO-96 landed on `main` without a release, so
this build is the first to package them:

* **Story-divergence prompting and `WAITING_FOR_PEER`.** When two players'
  main-quest progress diverges, the player who is behind is told so by name and
  offered the catch-up, rather than the prompt appearing only if they happen to
  wander past a trigger. A player who is *ahead* sees a waiting row instead.
* **Per-quest story fingerprints read from the save file**, so a gap can be
  named ("they have an objective you do not: …") even where no fix exists —
  which is the common case: 604 of 626 main-quest objectives have no narrow
  trigger at all.
* **The 2026-09-13 two-player session, written up in full** (`docs/WO-95-findings.md`).

## Known limits

* The fix table covers **17 of 626** main-quest objectives. That is the honest
  ceiling of this approach, not a work in progress — most objectives simply have
  no designer trigger that grants them in isolation.
* Two of the 17 carry an `IsHidden` flag whose effect on
  `wh_concept_HasteTrigger` is undetermined; they may be inert rather than
  harmful. Unresolved, and cheap to settle in a live session.
* The divergence prompt's two-machine half is still **not live-verified** — it
  was synthetic-only in 0.22.0 and nothing in this release changed that.
* `ConceptProbe` requires the agent to be stopped (the DLL's pipe accepts one
  client). It is a diagnostic, not part of normal play.
