# WO-42 progress

Worked 2026-08-21. Reverse-engineering only — **no mod code written, game never
launched, no process touched.** Deliverable is `docs/WO-42-findings.md`, written
to be implementable from without a disassembler.

## Setup

- Ghidra **12.1.3** found already installed at
  `C:\Users\Jonasty\Downloads\ghidra_12.1.3_PUBLIC_20260817\ghidra_12.1.3_PUBLIC`
  (the `native/ghidra_scripts/README.md` pipeline was written against 12.1.2 —
  same flags, works unchanged). Temurin JDK 21 on PATH.
- `dumpbin.exe` at
  `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\`.
- Gotcha for future sessions: Git Bash mangles `/nologo` into a path
  (`C:\Program Files\Git\nologo`) — run `dumpbin` from PowerShell, or drop the
  flag.
- Headless import + full auto-analysis (RTTI analyzer included):
  `AnimationModule.dll` **55 s**, `CombatModule.dll` a few minutes. Cheap enough
  to redo per patch.

## What was done, in order

| Phase | Result |
|---|---|
| 1 — version baseline | **MISMATCH, decisively.** Modding Tools `KingdomCome.exe` **1.5.5.0**, preset `kcd2_release_1_5_moddingtools_pc`, binaries `ReleaseSteamLTO_DLL` build `1166656_117` (2026-04-16), per-module DLLs. Retail **1.5.6.0**, preset `kcd2_release_1_5_game_pc`, `MasterMasterSteamPGO` build `1308617`, monolithic `WHGame.dll`. Different build number, different optimisation config, different link topology → every address re-derived from scratch. |
| 2.1 — `QueueAction` | `AnimationModule.dll` RVA **`0x20410`**; **slot [1] (+0x08)** of the `I_AnimationController` subobject at `C_AnimationController + 0x40`; `bool(void* this, IAction*, float in XMM2, bool in R9)`. Body read: forwards to `IActionController::Queue` at **vtable+0x98**. |
| 2.2 — `C_CombatActorActionAttack` | factory+ctor **`0x84D20`**, **sizeof `0xC0`** (the reference's `0xB0` is wrong here), dtor `0x44140`, `EnterImpl` `0x44300`, `Queue` `0x44AB0`. |
| 2.3 — the sync pair | SyncAttack factory `0x5BDB0`, ctor `0x53E00`, **sizeof `0xC0`**, `EnterImpl` `0x543D0`. SyncHit factory+ctor `0x88990`, **sizeof `0xD8`**, `EnterImpl` `0x55710`. **Pairing found and fully traced at `0x55430`**: attacker→hit at `SyncAttack+0xB0` (owning `_smart_ptr`), hit→attacker at `SyncHit+0xD0` (raw back-ref), and the hit action is registered on the **victim's own `C_ActionDirector`** (`victim+0x2E0`) via `C_ActionDirector::SetAction` rather than queued by the attacker. |
| 2.4 — helpers | `C_CombatActionHelperAttack` ctor `0x61470`, **sizeof `0x50`**; `C_CombatActionEarlyExitHelper` has **no ctor function** — 5 inline stores, **sizeof `0x18`**. `FillSyncHitInfo` `0x813F0`/`0x84470`. |
| 3 — construction sequence | **Delivered, and it did not stall.** Full annotated trace of `C_CombatActorActionSyncAttack::EnterImpl` (with `C_CombatActorAnimatedAction::Queue` inlined) — 11 numbered steps from the two entry guards through the `0x1A8` allocation, `C_CombatAnimAction` ctor arguments at register level, the refcounted assignment, both lifecycle delegates, and the queue call with `time = -1.0f`. Corroborated by two more instances of the identical idiom (Attack, SyncHit). Plus a **second, simpler, independently confirmed** sequence: the game's own `C_PlayAnim::Execute` test command (`AnimationModule.dll` `0x12EF20`). |

## The three things that mattered most

1. **The Modding Tools build keeps `__FUNCTION__` strings, source paths and
   RTTI.** Identification stopped being pattern-matching: a function containing
   the literal `"wh::animationmodule::C_AnimationController::QueueAction"` *is*
   that function. Every address in the findings doc is anchored that way and then
   its body was read. This is a permanently useful method for this project, not
   a one-off.
2. **The exports assumption in WO-40 Phase 1 is wrong** and is corrected in the
   findings. `AnimationModule.dll` exports 90 names, `CombatModule.dll` 63, and
   nearly all are `boost::optional<bool>` noise. `QueueAction` is not exported;
   no combat action class is exported. WO-43 must resolve by module base + RVA.
   §7.2 of the findings gives a verification recipe stronger than a byte
   signature (check the function's own `__FUNCTION__` string reference).
3. **`C_PlayAnim` / `wh::tests::PlayAnim` is a shipped, RTTR-registered test
   command that does the whole job** — resolve entity → get anim DB → parse
   `"FragmentId, tag1+tag2"` into `(fragmentID, TagState)` → build a
   `C_CallbackAction` → `QueueAction`. That is the cheapest rung on WO-43's
   ladder, and the engine already provides the fragment-name parser
   (`0x12DB00`), so no Mannequin IDs need computing by hand.

## Cross-references

- **Resolves WO-41's blocker.** `docs/WO-41-progress.md` stopped precisely at
  "means disassembling CombatModule.dll to re-derive the equivalents". Done.
  WO-41's version finding is independently reproduced here.
- **Supersedes WO-40 Phase 6's escalation note** on two points: the `[37]` slot
  for `GetActionController` is `+0x130` = slot `[38]` in this build, and the
  `GetProcAddress` hope does not hold.

## Constraint found that WO-43 must plan around

`C_CombatActionHelperAttack::FillSyncHitInfo` looks up Mannequin **ADB metadata
baked by `C_MannequineGenerator`**, keyed by a **16-byte asset GUID at
`C_CombatAnimAction + 0x84`** that the *engine* fills in (the constructor never
touches it). A hand-built anim action will queue and animate; a hand-built
*sync pair* only gets correct paired timing if the resolved fragment carries that
metadata. Otherwise the code logs "Meta data for asset is missing in the table"
and falls through with no hit info. Observed as a code path; unverified at
runtime.

## Artifacts checked in

- `docs/WO-42-libkcd2-reference.md` — the community claims, checked in verbatim
  as source material *before* verification, so the WO's measurements have
  something to be measured against. Marked "SOURCE MATERIAL, NOT FINDINGS".
- `docs/WO-42-findings.md` — the deliverable. Standalone reference: addresses,
  layouts, calling conventions, the pairing mechanism, both construction
  sequences, WO-43 implementation notes with a four-rung ladder, prologue bytes,
  and an explicit "where solid ground ends" section separating observed from
  inferred.
- `native/ghidra_scripts/DumpWo42Anchors.java` — needles → (string, referencing
  function, decompilation). The workhorse; reusable for any future class.
- `native/ghidra_scripts/DumpWo42Fns.java` — decompile addresses (+ optional
  callee depth).
- `native/ghidra_scripts/DumpWo42Asm.java` — raw disassembly with resolved
  string/symbol comments. **Use this, not the decompiler, for anything
  ABI-shaped** — the decompiler's "unknown calling convention" guesses dropped
  three of `C_CombatAnimAction`'s seven arguments and hid the `float` in XMM2.
- `native/ghidra_scripts/DumpWo42Callers.java` — callers of an address (this is
  what found the factories from the constructors, and the sizes from the
  factories).
- `native/ghidra_scripts/DumpWo42Vtbl.java` — vtable slots with resolved
  targets (this is what proved slot [1]).

## Not done, on purpose

- No mod code (WO-43).
- Game never launched; no live verification of anything.
- ~~`EntityModule.dll` not opened~~ — **superseded**: opened during the de-risk
  pass below. `C_Actor + 0x278` is **disproved** (the field is `+0x300`);
  `C_CombatActor + 0x3A8` (`m_pActionManager`) is still unverified, and is no
  longer on the critical path since `I_CombatActor + 0x490` reaches the anim
  action manager directly (§4.4).
- `wh::tests::PlayAnim` not probed over the RTTR/REST surface — recorded as a
  lead with its evidence, explicitly not a claim.

## De-risk assessment (run after the main deliverable, same session)

Both checks completed. Written up as §9 of `docs/WO-42-findings.md`.

- **Check 1 — the ADB metadata dependency: NOT a blocker.** It is
  `Libs/Tables/combat/combat_fragment_meta.xml` in `Tables.pak` (176 KB, 766
  entries), an ordinary Tables XML; the binary names the file in a developer
  warning string. **All 470 distinct `mn_fragment_guid` values in
  `combat_action_sync_attack.xml` are present in it, and all 470 carry a
  `CombatHitInfo`.** Rung 3 is not data-gated for any shipped attack.
- **Bigger payoff:** the attack/hit descriptors are themselves shipped, readable
  XML (470 / 876 / 221 rows), and every row carries `mn_fragment_id` + `mn_tags`
  — exactly the `'FragmentId, tag1+tag2'` format the engine's own parser accepts
  — plus per-row timings (`attack_time_to_hit`, `animation_duration`). Human
  actor class hash `1578932418`.
- **Check 2 — the entity → `I_CombatActor*` path: CLOSED, and it corrects
  WO-41.** `C_Actor::m_pCombatActor` is at **`+0x300`**, not the `+0x278` WO-41
  carried over from libKCD2. Better: **`C_Actor::GetOrCreateCombatActor` at
  EntityModule RVA `0x92260`** returns it and creates it if absent — no offset
  needed, and it handles the case a puppeted ghost is most likely to be in. The
  `I_CombatActor+0x2D8 ↔ C_Actor+0x300` round trip is confirmed from both
  modules independently (both reach the name via vtable `+0x490`).
- **Bonus:** `human:PlayAnim(fragment, tag)` was traced to its native floor —
  `C_ScriptBindHuman` vtable slot `+0x110` (RVA `0xB3D5C0`), whose entire payload
  is **one virtual call, `C_Actor` vtable `+0xE48`, taking two C strings**. With
  the real fragment/tag values from the tables, that is a shorter rung-1 route
  than replicating `C_PlayAnim::Execute`. Open: which concrete class's vtable
  `+0xE48` resolves to, and what the `actor->[+0x28]->vtbl[0x80]()` guard gates
  on.

`EntityModule.dll` (20 MB) imported into a third Ghidra project; auto-analysis
~9 minutes. PowerShell gotcha worth recording: a needle containing `-` plus `>`
(e.g. `"actor->GetAnimationController"`) is parsed as a redirection and silently
creates a file named after the fragment — quote differently or avoid `>` in
script arguments.
