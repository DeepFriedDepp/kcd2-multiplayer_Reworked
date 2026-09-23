# WO-111 — progress: what ran, what did not, what blocked it

Session 2026-09-23, solo. Findings: `docs/WO-111-death-respawn.md`.
**No code shipped. No pak rebuilt. No installer. No VERSION bump. Nothing
ran two-player.** Paths: `<install>`, `<saves>`, `<scratch>` (the session
scratchpad, not committed).

## 1. What ran

| phase | status | note |
|---|---|---|
| read-first docs | done | WO-107, WO-110 §3.3 (whole doc), NATIVE-PLUGIN, WO-86, WO-105 §2/§8/§11/§12/§16/§18/§19, DLL `main_thread`, `pipe_server.h`, `rttr_abi` damage/death/sampler, `dice_hook`, Lua vitals/fake-death/ghost-death, agent 0x23 path |
| 0 — what we have | done | findings §1 |
| 1 — vanilla defeats | **partial** | 2 rows observed (unconscious faint; guard frisk, unplanned), 8 rows data- or code-verified, none of fistfight / surrender / arrest run live (each needs a human at the controls or a live attacker). Findings §2 |
| 2 — death path | **done to `Gameplay ended`** | 9 steps with RVAs; the 0x36 → `EndGameplay` handler and the script-timer switch not traced. Findings §3 |
| 3 — candidates | done | 7 routes scored on all six criteria; the lazy clamp shown, not assumed. Findings §4 |
| 4 — respawn | done (design + primitives) | primitives observed except fade, disengage, wound bleeding, native teleport. Findings §5 |
| 5 — gravesite | done (design + container) | `StashCorpse` spawn, move, save/reload observed; loot UI and model not. Findings §6 |
| 6 — multiplayer | done (design) | findings §7 |
| docs | done | this file + findings |

## 2. Live probes (solo, throwaway save)

Launch: Steam up; `<install>` `KingdomCome.exe` started directly (console
API up after ~25 s); `wh_sys_LoadGame 1 quicksave023` (the WO-108 throwaway);
**fresh throwaway written at once: `quicksave025`** (`wh_sys_TestSaveGame`).
`quicksave024` was not used. kcd.log and `logbackups/kcd.log` copied to
`<scratch>` before launch; kcd.log copied again before and after the vanilla
death and at the end. No DLL injected, no agent: REST (`:1403`, RTTR) and
the console stood in for the native calls. The game was quit with
`System.Quit()` at the end.

| # | probe | result |
|---|---|---|
| T1 | `death_protection_cutscene` + `TakeDamage(Health=500)` | hp 54.8 → **1.0**, not dead, not unconscious, no `Soul died`; red vignette, no Game Over (screenshot); fresh `Script.SetTimer` fired |
| T2 | `bleeding` buff alone | nothing (it is the controller; no wound) |
| T2b/c | `test_bleeding`, hp set to 3 | ~0.42 hp/s → **1.0**, held 18 s still bleeding; timer fired |
| T3 | `HealBleeding(1000, -1/0)` on a buff bleed | no effect; `RemoveAllBuffsByGuid(test_bleeding)` → stopped |
| T4 | lifted 45 m | **hovered** at +45 m (a written Z holds until disturbed); after an impulse fell, hp 100 → **1.0** |
| T5 | `deadly_poison` | ~2.8 hp/s → **1.0**, held; removed by GUID |
| T6 | hunger 0 | starving, ~0.05 hp/s → **1.0**, held |
| T7 | swap to `player_immortalityOnly_nonPersistent`, add `unconscious_nonpersistend` | vanilla faint: `SkipTime.gfx`, `special_skiptime_fainting`, `AfterSkipTime`; awake again within ~2 s real time |
| T7b/c | re-apply the unconscious buff | no effect twice; a guard frisk dialogue had started and `Calendar.IsWorldTimePaused()` read true |
| T8 | immortality only + `TakeDamage(500)` | **1.0, not unconscious** — the immortal knock-out is on the weapon-hit path only |
| T9 | teleport 25 m, restore hp/stamina | worked; stamina clamps to its max 126.67 |
| G1–G3 | spawn `StashCorpse`, move an item | entity with inventory; `AddItem(wuid)` moved the belt out of the player (27 → 26) |
| — | frisk dialogue | `wh_dlg_ForcedDecision 1` → "Decision with id '1' is not found"; CVars reset; escaped by reloading `quicksave025` (clock running again) |
| P1–P3 | grave + 2 items → `quicksave026` → reload | grave back with both items; inside the save's compressed stream; `interactive=true`, unlocked |
| V | no guard, `TakeDamage(500)` | `Soul died 'Dude' (DR_ScriptedHit)`, GAME OVER "murdered under unforeseen circumstances"; 250 ms Lua tick ran 13 more times over 3.0 s, stopped at `Gameplay ended` |
| V2 | RTTR `Soul.Revive`, `actor:Revive(false)` | `will not be revived: it is not revivable`; still dead. Both executed after `Gameplay ended` (REST latency); a new `Script.SetTimer` never fired |
| R2 | `wh_sys_LoadGame 1 quicksave026` from the Game Over screen | clean reload in ~12 s |
| E2E | guard + bleed + poison + lethal → respawn batch | downed at 1.0 → grave, 5 items, teleport 31.6 m, clear, `remove_injuries` in **2.0 ms** → hp 100, guard kept, timer alive |
| C0–C2 | `wh_rpg_AddBuffDebug` forms | first argument is a soul name (`soul … does not exist` otherwise); no form added the buff |

## 3. Static work

* Ghidra 12.1.3 headless, Java post-scripts (PyGhidra is unavailable here —
  WO-107's note holds). Fresh full analysis of `RPGModule.dll` (8.5 min),
  `PlayerModule.dll`, `WHGame.dll`, `Framework.dll`, `GUIModule.dll` (2–4.5 min
  each, run three at a time); `XGenAIModule.dll` reused read-only from the
  WO-107 project. Batch-file argument parsing eats `%` in script arguments —
  search needles must not contain `%s`.
* One combined tool script (`WO111Tool.java`, in `<scratch>`, not committed):
  string anchors → containing function → decompile, with every caller and
  callee **self-identified by the literals it references**, plus callers,
  raw disassembly, vtable dumps and a **displacement scan** (instructions
  touching `+0x<n>]`). The displacement scan is what proved
  `SetSoulState` is the only float reader of `ImmortalHealthMin` and found
  the weapon-hit knock-out selector (`[params + 0x86C + 4·i]`).
* Data: `Tables.pak` (`game_over`, `game_over_type`, `skiptime`,
  `skiptime_type`, `buff`, `rpg_param`, `soul_vip_class`), `Scripts.pak`
  (behaviour trees for unconscious/surrender/mercy/frisk/sleepwalking, the
  brawl quest, `CombatTest_startup.lua`), `IPL_GameData.pak` (UI elements).
* The Warhorse scriptbind docs (`Tools/modding/docs/script_bind`) for the
  soul and inventory binds; cross-checked live with `type()` because the
  docs list `Inventory.RemoveItem`, which this build does not register.

## 4. Decisions taken

* **Buff for probes: `death_protection_cutscene`**, because no script
  touches its GUID (a quest could not interfere mid-probe) and it is
  non-persistent (nothing written into saves). The design recommends the
  same, or a mod-owned row.
* **REST/Lua as stand-ins for native calls in probes.** The brief forbids
  shipped Lua, not probe Lua. Each stand-in's native reach is stated in the
  findings (§4, §5.2), and the native call path is marked code-verified or
  not traced.
* **No DLL build.** A probe DLL (vtable hook of `C_GameOver::Start`) would
  have been code; C2's value was settled by the observed refusal to revive
  plus code, without it.
* **Stopped hunting a real weapon blow.** No console lever makes an NPC
  attack the player; the knock-out and floor path for a blow was closed
  statically instead (`0x52FBE0` → `0x70F6B0` refuses under `upr`).
* **No more screenshots once the desktop was in use.** One capture late in
  the session showed the desktop instead of the game; it was deleted from
  `<scratch>` and nothing from it is used.

## 5. Not done, inconclusive, stated plainly

* **Two-player: everything.**
* Phase 1 live rows: open-world fistfight loss, surrender, arrest, scripted
  knock-outs, exhaustion faint, drunk blackout — not run.
* A **real weapon blow** under the guard — code-verified only.
* **Horse** deaths (fall, collision) — inferred through the same writer.
* Why Lua timers stop **below** `EndGameplay` (timer manager paused, reset,
  or not updated) — not found.
* The 0x36 message handler → `EndGameplay` — by log order only.
* Whether the DLL's main-thread tick runs between `Gameplay ended` and the
  next `Gameplay started`: the previous session's sampler shows ~10 s gaps
  that line up with reloads, but a sampler refusing during a load looks the
  same. The design does not depend on it: it acts ≥ 3 s before `EndGameplay`.
* `imm=0` (`not_immortal`) combined with `imm=1` — unknown.
* `upr` against a directly applied unconscious buff (quest, alcohol) — not
  tested.
* Wound bleeding (from a real hit) and `HealBleeding` on it; effect of
  `remove_injuries` on real injuries.
* Fade (`C_FaderController`), `wh_rpg_ExcludePlayerFromTargeting`, the stock
  `goto` command, the native inventory move, `hangoverSpot` enumeration — not
  driven.
* `StashCorpse`: loot UI, model, cold-relaunch persistence.
* The size of the faint's time skip; the cause of the guard frisk.

## 6. Left in place

* `<saves>/playline1/quicksave025.whs` (fresh throwaway) and
  `quicksave026.whs` (throwaway with a test `StashCorpse` holding a
  gambeson and boots). Both safe to delete. Nothing else in `<saves>` was
  written.
* Ghidra projects and all probe logs in `<scratch>` only.
