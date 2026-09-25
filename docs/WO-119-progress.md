# WO-119 — progress: what ran, what did not, what blocked it

Session 2026-09-24, solo, unattended. Findings: `docs/WO-119-action-fidelity.md`.
**No shipped code. No pak rebuilt. No installer. No VERSION bump. Nothing ran
two-player.** Paths: `<install>`, `<saves>`, `<scratch>` (the session
scratchpad, not committed).

## 1. What ran

| phase | status | note |
|---|---|---|
| read-first docs | done | WO-116 (whole), WO-118 findings (whole), WO-100, WO-100.5 (whole), WO-42 §4–§5/§9.2, WO-47 §6, WO-40 §7–§8, NATIVE-PLUGIN attribution notes, WO-23 item 4; memory notes for WO-43/44/45/46/47/49/99/107/111/113/120 |
| 0 — the avatar's body | **done, partly** | current body vs `NoAI` vs `SuspendedAI`: AI object, brain state, perception signs, skirmish targeting, attacked by a hostile NPC, brain competition. Not done: guards in a restricted area, step-around (safety rules / no world NPCs) |
| 1 — hits carry an attacker | **done except fight-back** | four sinks mapped and each fired live; history and skirmish targeting work; fight-back not observed with spawned test souls |
| 2 — action map | done | every row in findings §3; combat by me, EntityModule and RPG/WHGame static passes by two background sub-agents, then verified live where marked |
| 3 — live probes | **done except the avatar's bow** | directional attack, block as state, jump, crouch, bow (Henry), velocity, takedown, carry |
| 4 — design | done | findings §5 (wire, v8) and §6 (three WOs) |
| docs | done | this file + findings |

## 2. Live sessions (solo, throwaway save)

Launch: Steam running; `<install>\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe`
started directly; REST console up in ~40 s. `kcd.log` and
`logbackups/kcd.log` copied to `<scratch>` before the first launch and
`kcd.log` again before each relaunch and at the end.

Setup each session: `wh_sys_LoadGame 1 quicksave033` (WO-118's throwaway) →
`death_protection_cutscene` added to Henry (`HasBuffDebug` read back true) →
`Calendar.SetWorldTimeRatio(1)` → **fresh throwaway `quicksave034` written
once** (`wh_sys_TestSaveGame`, 09:30) → later sessions load `quicksave034`.
Henry teleported to an empty meadow ~140 m from Troskowitz (a script found
the spot with no actor within 70 m). Daytime throughout (09:30–09:50 game
time). The forbidden saves (024/026/028/031/032) were not touched.
`mp_spawn_armor` was not used. No townsperson was attacked; the only combat
targets were the test bodies spawned for this WO.

| session | what |
|---|---|
| 1 | probe v1–v9 (each rebuild needed a new DLL name and, as it turned out, a new frame-hook site): Henry's attack/zone/block capture; avatar zone write; combat mode + "No main action"; cosmetic per-zone swings; director dumps; the guard-termination trace |
| 2 | probe v10–v16 (runtime hooks): guard-request flag holds combat mode; attack-factory branch trace; Henry's descriptor → forced row on the avatar; friendly-fire hits (hitType 10 via XGenAI); `hitReaction`, `DealDamage` with attacker, history writer, skirmish |
| 3 | probe v17–v18: bodies side by side (ghost / `NoAI` / `SuspendedAI`), skirmish with override 1, attributed `HitTarget`, velocity → gait, crouch, jump, takedown, carry, bow (Henry + avatar), block in combat mode |

Frame rate from the probe's per-30-s frame-hook counts: 73–94 fps in every
window; the game window was brought to the front before each measurement.

## 3. Static work

* Ghidra 12.1.3 headless, read-only, on the projects earlier WOs analysed
  (CombatModule/CryAction/AnimationModule from WO-100; EntityModule;
  RPGModule/WHGame/PlayerModule/Framework from WO-111; XGenAIModule from
  WO-107). WO-116's tool script extended with two modes: `vtdec` (dump a
  class's vftable and decompile each target) and `syms`.
* Two background sub-agents ran static passes in parallel on separate
  projects (EntityModule: ranged, locomotion tags, crouch, jump, ladders,
  carrying, hit reception; RPGModule/WHGame: the hit → damage → history →
  skirmish → brain chain). Their reports were read in full; every claim used
  in the findings is either marked code-verified from their decompilations or
  was re-checked live.
* Shipped data read: `Tables.pak` combat tables (`combat_action_attack`,
  `…_block`, `…_type`, `combat_guard_type`, `combat_input_class`), soul
  tables (autotest souls), item tables (a bow and arrows);
  `IPL_GameData.pak` action maps and default key binds; Warhorse's scriptbind
  docs.

## 4. The probe DLL (research only)

* One `.cpp` in `<scratch>`, built with the VS Build Tools toolchain,
  injected with `KCDMP_LauncherInjector --pid --dll`. 18 builds (new file
  name each). Never shipped, copied into the repository or installed.
* Entry hooks with WO-116's register-preserving thunk; every target
  prologue-verified (a mismatch disables it). From v10: **runtime hooks** (a
  `hook <name> <module> <rva> <len> <bytes> <flags>` command, patch lengths
  chosen by capstone from the DLL file), filters to watched actors, a raw
  stack scan, and hit-struct dumps.
* A command file polled every 100 ms; commands ran **on the main thread** at
  a frame hook and called the engine functions named in the findings on any
  actor resolved by entity name.
* Lesson recorded: each build must own a distinct frame-hook site (a second
  patch of an already patched prologue is refused); v5+ picked the first free
  site from a list; after six builds the list ran out and the game was
  restarted with a consolidated build.

## 5. Decisions taken

* **Synthetic input for Henry, native calls and shipped Lua for remote
  bodies.** `SimulateOnAction` did nothing; SendInput scan codes worked.
* **Avatar = the mod's own ghost spawn** (`KCD2MP_SpawnGhost` with fake ids),
  driven by `KCD2MP_UpdateGhost` from a Lua timer — the real body without a
  relay/agent. KCDMP.dll not loaded (so the isolation contexts were absent;
  stated in the findings).
* **Victims were spawned test souls**, never townsfolk; Warhorse's own
  autotest souls (`test_soldier_ai`, `test_cuman_ai`) for combat-capable
  victims, with `wh_rpg_ExcludePlayerFromTargeting 1` while they existed.
* **Stopped the real-attack-action route** after the forced row entered and
  showed nothing; the cosmetic route is what the build needs anyway (look
  separate from outcome).
* **Did not chase fight-back further** with spawned souls; it needs a world
  NPC (maintainer list).

## 6. Not done, inconclusive, stated plainly

* **Two-player: everything.**
* A victim NPC fighting the avatar after a synthetic attributed hit.
* Guards reacting to an avatar in a restricted area; NPCs stepping around it.
* A clean Henry → avatar weapon collision solo (only brain-driven hitType-10
  hits were produced).
* The avatar with a bow in hand (so its draw/release calls faulted).
* The crouch pose on screen, and a visible difference between guard zones.
* `combat_EnableAutomation`'s native call on a ghost (mapped, not fired).
* Melee `hitReaction` values from a vanilla hit.
* The null-cause tolerance of skipping the `+0x150` CombatHit slot.

## 7. Side effects on the machine (disclosed)

* **Save written**: `<saves>/playline1/quicksave034` (throwaway, 09:30,
  written right after `SetWorldTimeRatio(1)`). Safe to delete. Nothing else
  in `<saves>` was written; nothing was saved after the tests (Henry's bow,
  the test bodies and their fights exist in no save).
* **Test bodies** (ghosts 7/8, `wo119_noai`, `wo119_susp`, `wo119_victim`,
  `wo119_soldier`, `wo119_soldier2`) were removed at the end of each session;
  no world NPC was suspended, moved or damaged.
* **CVar** `wh_rpg_ExcludePlayerFromTargeting` set to 1 during the soldier
  tests and back to 0 before quitting (not persisted: set from the console).
* `kcd.log` rotated three times (three launches); copies in `<scratch>`.
* The probe DLLs, their logs, the Ghidra outputs, the sub-agent reports and
  every script stay in `<scratch>` only.
* The game was quit with `System.Quit()` at the end of each session; nothing
  was left running.
