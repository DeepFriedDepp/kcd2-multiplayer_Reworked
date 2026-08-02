# WO-15 progress — siege aggro investigation

2026-08-02. Read `docs/WO-15-findings.md` for the actual evidence and
conclusions; this is the session log.

## What happened, in order

1. Read the three required docs (`NATIVE-PLUGIN-findings.md`,
   `WO-6-native-dice-findings.md`, `ARCHITECTURE-shared-world.md`) plus
   `PROJECT-STATE.md` and `LAUNCHING.md` for current state.
2. **Phase 0.1 (logistics).** No mission-jump/level-load command exists
   anywhere checked (launcher, RTTR reflection, CryEngine Lua scriptbind
   docs). Two existing save playlines were present but neither was
   confirmed near the siege. Asked the human directly rather than assuming
   — per the WO's own instruction not to force a replay unprompted. Human
   chose a full intro replay.
3. Human replayed the intro to the siege (`zoufalaObranaZaBohutu` quest).
   Confirmed live via a direct question that AI-vs-AI combat and
   player-vs-AI combat were both genuinely happening before trusting any
   probe result.
4. Ran 0.2–0.5 against the live game (see findings doc for full evidence).
   The siege's scripted sequence ended mid-session (the nearby-entity scan
   went from 130+ `zoufalaObranaZaBohutu_*` souls to a completely different
   `prepadeni_*` cast in one sample) — the battle window is not indefinitely
   long.
5. **A reload got back in.** `Saved Games\kingdomcome2\saves\playline2\
   permanent002.whs` (a permanent-save checkpoint, not an autosave) dropped
   the human back into the same battle, at an earlier point (mostly
   full-health NPCs, only a handful of pre-existing casualties vs. the first
   visit's mid-fight state). This is the answer to "how to get back in"
   for a future session — see below.
6. Completed 0.2, 0.3, 0.4 (via a substitute measurement — see findings
   doc), and 0.5 against the reloaded session. Closed out; no Phase 1 work
   attempted, no code changes to combat/aggro/faction handling.

## Answer to 0.1, for a future session

**Load `Saved Games\kingdomcome2\saves\playline2\permanent002.whs` directly.**
It is a story-checkpoint save (not an autosave), sitting at or very near the
start of the `zoufalaObranaZaBohutu` siege battle. This avoids replaying the
intro from scratch. Whether it is the *exact* battle start wasn't pinned down
precisely — the reload showed the fight already having a handful of
casualties — but it is repeatable and got back into live AI-vs-AI combat
within seconds of loading, with no cutscene or dialogue to sit through first.

`playline2\permanent001.whs` is presumably an earlier checkpoint (character
creation or similar) — not needed for this purpose.

The battle sequence does end on its own (observed once, mid-session, when the
`zoufalaObranaZaBohutu_*` roster was replaced by a `prepadeni_*` — ambush
scene — cast in a single sampling round). A future session should expect a
bounded window per load, not an indefinitely-farmable state, and should
front-load whatever it needs to test rather than assuming it can iterate
slowly.

## Tools used, all ad hoc this session (not committed as reusable scripts)

Every probe was a one-off `Invoke-WebRequest`/`curl` call against
`localhost:1403`, following the existing pattern in `tools/KcdApi.ps1` and
`tools/Probe-AI-Behaviour.ps1` (bounded reads, `?depth=`, `?info` for
reflection metadata). Nothing new was added to `tools/` — the WO's scope was
investigation, not tooling, and every probe here was specific to
`SkirmishManager`/`CombatSoul` rather than general-purpose. If a future
session wants to re-run this kind of check routinely, a
`Probe-Skirmish.ps1` following the same shape as `Probe-AI-Behaviour.ps1`
would be the natural place, but that's new work, not this session's.

## Addendum: SetParent fix and live test, same session

After the findings above, the human explicitly asked to revisit the
permanently-off-limits faction write — fix the ownership bug rather than
leave it disabled, and test it experimentally. Reloaded to a town save (not
back into the siege) for a lower-stakes test environment.

**Ghidra pipeline reused, new scripts added:**
`native/ghidra_scripts/DumpFactionSharedPtr.java` (decompiles
`SetParent`/`GetFaction`/`GetRelation` in `RPGModule.dll`) and
`DumpSharedPtrHelpers.java` (decompiles `SetParent`'s two anonymous call
targets by address, once their names came back as `FUN_xxx`). Same headless
process as WO-6: `analyzeHeadless.bat <proj> <name> -import <dll>
-analysisTimeoutPerFile 1800`, then `-process <dll> -noanalysis -scriptPath
native/ghidra_scripts -postScript <script>.java`.

**Root cause found and fixed** — see `docs/WO-15-findings.md`'s addendum for
the full disassembly evidence and the fix itself
(`native/KCDMP/rttr_abi.cpp`, `probe_faction()`). Summary: `SetParent`
destroys whatever `shared_ptr` it receives, as the ABI requires for a by-value
parameter; the original code hand it the reflected `Variant`'s own storage
instead of a separate temporary, so the same reference got destroyed twice.
Fixed by reading the property a second time (an already-proven operation)
rather than hand-rolling a refcount increment.

**Live-tested successfully**, verified over a 4-minute window, not just an
immediate read-back:

- `System.SpawnEntity` (raw engine call, not the mod's `KCD2MP_SpawnGhost` —
  no mod pak loaded this session) gave a fully disposable test soul,
  `wo15test`.
- `FactionManager::GetRelation("animal_wild", "player")` (a reflected
  method taking two plain strings, confirmed callable over HTTP) found a
  real, live, loaded hostile donor without needing to attack any NPC: the wild
  hare `SpawnedAnimal_Hare_A8873FA2_0`.
- The fixed `SetParent` call ran with no fault. Ghost's `FactionNode/Parent`
  and the donor's own `FactionNode/Parent` both held `animal_wild` unchanged
  at +0s, +60s, and +4min; `animal_wild`'s `NumMembers` held steady at 66
  throughout; the debug API and game process stayed healthy the whole time.
- The `GetFaction`-by-name path (tried first, since a fault there is
  SEH-caught and harmless) still faults on its `string` argument — a real,
  separate, still-open bug, not pursued further.
- No aggro was observed on the human's own visual check — expected, since
  `wo15test` almost certainly lacks a working behaviour tree (logged `"RPG
  NOT GENERATED VIA SCRIPT"` at spawn). This tests a different ingredient than
  the one just fixed; see the findings doc for the precise reasoning.

**Build note:** `native/Build-Native.ps1` handles a locked, currently-injected
`KCDMP.dll` by parking it automatically. Re-triggering `probe_faction()`
against an already-running injected DLL needs a **fresh copy at a new path**
(e.g. `native/build/KCDMP_wo15_donor/`) — Windows `LoadLibrary` on an
already-loaded path just bumps the refcount and does not re-run `DllMain`.
This project already had this convention (`KCDMP_retry`, `KCDMP_retry2`, …
folders from earlier sessions); this session added `KCDMP_wo15_donor`.

**Not committed as reusable tooling:** `kcdmp-faction.txt` was written by
hand for this one test (ghost GUID + donor GUID, or ghost GUID + faction
name) and lives in the gitignored `native/build/` tree. `probe_faction()`
itself is re-wired into `dllmain.cpp`'s startup sequence, gated on that file's
presence, so it is inert unless someone deliberately creates it.

## What a follow-up session could do next, if there's appetite

Per the findings doc, the general aggro-injection question remains closed.
The one thing this session left genuinely open is `HasCombatHistoryWithSoul`,
which needs an in-process native call (same escalation already recommended
for `TakeDamage` attribution) rather than the HTTP reflection browser, because
its `I_Soul*` parameter hits the same transport wall as `TakeDamage`'s
`Attacker`. That is real, bounded follow-up work, not a new open-ended
investigation — but it was not attempted here, consistent with this WO's
scope (reflection-only, no native code changes).
