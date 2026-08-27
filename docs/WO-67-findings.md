# WO-67 — libKCD2 + Address Library: cheap typed offsets, or not for our build?

Evaluation only. No product code changes, no live session. Evidence labels used
throughout: **observed** (read from a binary/file on this machine this session),
**code-verified** (read from the vendor repo's source, not executed),
**read-but-unrendered** (a vendor claim we read but did not check against a binary),
**inconclusive**.

Reference pins (shallow clones, this session, read-only):

| Repo | Commit | Note |
|---|---|---|
| `F02K/libKCD2` | `c3dff5fe09e0c64f64bbb4553cb3e60e4a8adc73` | == KCD2Online's submodule gitlink (observed via `git ls-tree`) |
| `F02K/Address-Library-For-KCSE` | `0294d829acc68867c8df2e6bbc5770e415161cc4` | == KCD2Online's `vendor/` gitlink (observed) |
| `DeepFriedDepp/KCD2Online_forked` | `5777c1544816a8932142a1e4ecd60a0fbf2f8154` | same pin as WO-64 |

## Verdict up front: **Don't adopt** (as a dependency). Keep both repos as reference-only.

The entire library — every `REL::ID`, every vtable table, every `.bin` — keys
exclusively to the **retail `WHGame.dll` monolith**. Our mod's native layer runs
against the **Modding Tools split-DLL build**, a different compilation artifact
with no monolith. The mismatch is structural, not a missing table row: there is
nothing their tooling could be pointed at that would emit a table for our
binaries in its designed mode. On top of that, one field offset we can check
both ways (`C_Actor::m_pCombatActor`) **provably differs** between the two
builds, so even copied typed headers would be unsafe without per-member
re-verification — which is the hand work they were supposed to replace. And
neither repo is licensed in a state we could vendor into a GPLv3 tree today.

What survives: libKCD2 is an excellent **semantic map** (names, signatures,
call-graph shape, vtable-slot hypotheses, bit semantics) that makes our own
hand disassembly cheaper — WO-69 in particular starts with four concrete,
disasm-verified-on-retail slot hypotheses instead of zero. Details in Phase 2.

---

## Phase 0 — acquisition, build identity, discriminator, licenses

### Our installed builds (observed on disk)

**Modding Tools install** (what our mod runs on): `D:\SteamLibrary\steamapps\common\KCD2Mod`,
binaries in `Bin\Win64ReleaseSteamLTO_DLL\` — 45 DLLs. Key module identities:

| DLL | Size (bytes) | FileVersion |
|---|---|---|
| WHGame.dll | 4,509,184 | (none) — a thin stub, not the monolith |
| EntityModule.dll | 20,977,664 | (none) |
| CombatModule.dll | 8,928,768 | (none) |
| AnimationModule.dll | 2,145,792 | (none) |
| RPGModule.dll | 19,132,928 | (none) |
| Framework.dll | 4,531,712 | (none) |
| CrySystem.dll | 6,849,024 | 1,0,0,1 |

`whdlversions.json` (observed): Preset `kcd2_release_1_5_moddingtools_pc`
(Id 194), Branch `release_1_5`, **`Assembly: null`**, binary configuration
`BinReleaseSteamLTO` versionId `…ReleaseSteamLTO_DLL_1166656_117`
(CreationTime 2026-04-16). `system.cfg`: `wh_sys_version = "1.5.5"`.

**Retail install** (NOT what our mod runs on): `…\KingdomComeDeliverance2`,
`Bin\Win64MasterMasterSteamPGO\WHGame.dll` — 89,180,672 bytes, no version
resource. `whdlversions.json`: **`Assembly.Id = 15693`**, Branch `release_1_5`,
`BinMasterMasterSteamPGO` versionId `…MasterMasterSteamPGO_1308617_856`.
`system.cfg`: `wh_sys_version = "1.5.6"`.

**MD5 of our retail WHGame.dll = `170A55FE1EF804B4A9AC6FBF9F6843E5` (observed),
which equals the target md5 libKCD2 records in
`include/Offsets/vtables/IEntity.h` exactly.** So the vendor stack is live for
the retail binary on this machine — hash-level match, not just key match. It is
simply not the binary our native layer targets. (This also confirms
KCD2Online's recorded pin "`WHGame 1308617_856`" is this same retail Steam
MasterMasterSteamPGO build; `GameMenuInfo` is "15693".)

### The library's build discriminator (code-verified from their source)

- `REL::Module` (libKCD2 `src/REL/Module.cpp`) hard-binds to
  `FILENAME = L"WHGame.dll"` — one module, the monolith. Distribution is
  detected from which store DLL WHGame.dll imports (`steam_api64.dll` /
  `Galaxy64.dll` / EOS).
- `REL::IDDatabase::load()` (`src/REL/IDDatabase.cpp:107`) selects the table
  file `kcd_addresslib_<dist>_<key>.bin` from `<game_root>\KCSE\addresslib\`,
  where `key` = `build_code()` — scraped from `whdlversions.json` as
  `<Branch.Name>-<Assembly.Id>` (e.g. `release_1_5-15693`) — falling back to
  `release()` = `wh_sys_version` from `system.cfg`. The `.bin` carries a
  `KASL` magic, format version, distribution id (checked against the detected
  one), and a sorted id→offset array.
- The shipped KCD2 bins (observed in the repo):
  `kcd_addresslib_{steam,gog,epic}_release_1_5-15693.bin` — **one build**,
  three distributions. There are no other KCD2 builds in the tables.
- **What the table actually is** (code-verified from `build_library.py` and
  `summary.txt`): a cross-*distribution* diff — Steam↔GOG↔Epic function/var/
  vtable matching over the SAME game version — not a cross-*patch* library.
  1,388,086 ids; the id registry's `name` column is almost entirely empty
  (names live in libKCD2's headers, not the table).
- Scraper artifact worth recording (code-verified, not executed): on OUR
  Modding Tools `whdlversions.json`, `Assembly` is `null`, and their minimal
  scraper (`json_number_after(j, "\"Assembly\"", "\"Id\"")`) would find the
  next `"Id"` after the anchor — `Preset.Id` — yielding key
  `release_1_5-194`, a nonsense key for which no bin exists. So even
  mechanically, KCSE on the Modding Tools install fails at table selection.

### Licenses (read from the actual repos, per WO discipline)

| Repo | License file | README claim | Verdict vs our GPLv3 |
|---|---|---|---|
| libKCD2 | **none tracked** (`git ls-files` has zero license hits; `LICENSE` path 404s) | README §License says "[GPLv3](LICENSE)" — the link target does not exist | Intent is GPLv3 (compatible), but the grant is legally incomplete. **Reference-only until upstream adds the file.** Another docs-vs-repo discrepancy in this ecosystem (WO-64 logged four). |
| Address-Library-For-KCSE | **none anywhere** | no README at all | All-rights-reserved by default. `src/Properties/AssemblyInfo.cs` says "Copyright © WZT 2020" (the IDADiffCalculator is a port of meh321's Skyrim-lineage tool; `IDAExport.py` says so in its header). **Not vendorable; not committable under `tools/`.** Local, private use as reference only. |
| KCD2Online (context) | MIT (established WO-64) | — | compatible, unchanged |

The license state alone kills "vendor submodule" and "copied pinned headers"
adoption today, independent of the technical findings.

---

## Phase 1 — the three-offset diff

Our values, cited to their derivation docs (all hand-derived on the Modding
Tools module DLLs — that is the binary set the mod injects into):

| # | Function | Our value (module RVA) | Derived in | The library's answer for our build |
|---|---|---|---|---|
| 1 | `QueueAction` | `AnimationModule.dll+0x20410`, slot [1] of `I_AnimationController` sub-object at `C_AnimationController+0x40` | `docs/WO-42-progress.md` §2.1; WO-42-findings | **absent** — no `QueueAction` anywhere in libKCD2 (grep over include+src: zero hits); no AL table exists for AnimationModule.dll |
| 2 | `C_Player::PlayAnim` | `EntityModule.dll+0xAE17A0` = C_Player vtbl slot [457]/+0xE48 | `docs/WO-44-findings.md` §1 (decompiled); observed live WO-43 §4 | **absent** — "PlayAnim" appears in libKCD2 only as a Lua scriptbind comment (`C_ScriptBindHuman.h`), not as the native function; no table for EntityModule.dll |
| 3 | `C_Actor::GetOrCreateCombatActor` | `EntityModule.dll+0x92260` (companion `InitCombatActor` `0x92310`, `__FUNCTION__`-anchored) | `docs/WO-42-findings.md` §9.5, `docs/WO-44-findings.md` | **absent for our build; carried for retail** — `include/entitymodule/C_Actor.h` records it non-virtual at retail VA `0x18072DC90` (RVA `0x72DC90`) |

**Outcome: the second path — our build is absent from the tables.** And more
strongly than "absent": the tables are keyed to a binary (the retail monolith)
that our process never loads. A numeric three-way diff is a category error;
there is no row to disagree with. The only comparable object is #3, where both
sides independently derived the same function on *different* binaries — which
produced the most valuable datum of the WO:

### The `m_pCombatActor` divergence — why typed headers don't transfer

- **libKCD2, retail WHGame.dll 1.5.6** (`include/entitymodule/C_Actor.h:153`,
  code-verified; they mark it VERIFIED from the `GetOrCreateCombatActor`
  disasm, `this[79]`): `m_pCombatActor` at **`C_Actor+0x278`**, sizeof(C_Actor)
  = 0x9C0, static_asserted.
- **Ours, Modding Tools EntityModule.dll** (`docs/WO-42-findings.md` §9.5,
  observed — reconstructed from the actual decompile of `0x92260`, corroborated
  by the `__FUNCTION__`-anchored `InitCombatActor`): the field is
  **`C_Actor+0x300`**. WO-42 explicitly tested and rejected `+0x278` (WO-41
  had imported it as a libKCD2 structural claim): "using it would have
  dereferenced garbage."

Per the WO discipline we re-checked our derivation first: it is observed on our
binary, twice-anchored, and was validated in the field by every native combat
WO since (WO-45–49 all run through `GetOrCreateCombatActor`). Their `+0x278` is
equally well evidenced on theirs. **Both are right — the C_Actor layout itself
differs between the retail MasterMasterSteamPGO build and our
ReleaseSteamLTO_DLL build** (which are also different source snapshots:
assembly lineage `1308617`/June 2026 vs `1166656`/April 2026, observed in the
two whdlversions.json files — so compile-config and source-drift explanations
both remain open; inconclusive which). The consequence is the same either way:
**libKCD2 field offsets and RVAs are hypotheses on our build, never facts.**

---

## Phase 2 — coverage map for the queued native WOs

Legend: **ours** = usable for our Modding Tools build as-is; **retail** =
carried and evidenced for retail WHGame.dll 1.5.6 only (portable to us as a
verify-first hypothesis); **none** = not present in either vendor repo.

| Target | Coverage | Evidence |
|---|---|---|
| **WO-68: script-context layer** — `SetEntityScriptContext`, `StaticDataScriptContext`, `E_ScriptContextSideEffect`, any context/preset applier, soul-side reach | **none** | grep over all of libKCD2 include+src: zero hits for every one of these names. The rpgmodule header set (300+ files) has no script-context type at all. KCD2Online's own civic isolation is **Lua-only** (`Contexts.SetPersistentOption`, `soul:HasScriptContext` — `native_remote_avatar_backend.cpp:180,1264–1277`, code-verified), i.e. exactly the surface WO-65 proved absent on our build. |
| WO-68 sub-item: `switch_unresponsive` preset applier | **none** | zero hits in both repos. No native preset-apply shortcut exists to adopt; WO-68's "one call instead of seven" hope is dead in vendor code. |
| **WO-69: `IEntity` vtable — `Activate` slot** | **retail** | `include/Offsets/vtables/IEntity.h` (code-verified): `Activate(bool)` = slot **[52] / +0x1A0**, "VERIFIED by engine call sites and offline VTable audit", against retail WHGame.dll md5 `170a55fe…` — the same file our retail install carries (observed hash match). |
| WO-69: rest of the observer-adoption surface | **retail** | Their save/restore path (`native_entity_backend.cpp:542–594,1556–1571,1939`, code-verified) uses exactly four more primitives, all in the same vtable file: `IsActive` [53]/+0x1A8 (`(byte@+0x08)&1`), `Hide` [63]/+0x1F8, `IsHidden` [64]/+0x200 (`(dword@+0x08>>4)&1`); plus `SSystemGlobalEnvironment::GetInstance()->pEntitySystem` and `wh::game::S_GameContext::GetActorById` for lookup. Saved state is just `{IsHidden(), IsActive()}` restored on teardown. WO-69 therefore starts from **five concrete slot/bit hypotheses**, not raw disassembly — but each must be verified on our EntityModule/CrySystem first (interfuscator shuffles vtable order per build — libKCD2's own README warning — and the C_Actor divergence above proves layout drift between these two builds is real). Cheap to verify: our module DLLs keep RTTI + `__FUNCTION__` strings (WO-42), and a WO-43-style runtime probe can confirm a slot in minutes. |
| **Nameplates (opportunistic): C_Soul display-name CryString** | **retail, contested** | Two vendor answers for the *same* retail binary: KCD2Online reads a CryString at **`C_Soul+0x3E8`** ("Soul.GetNameStringId()", `native_remote_avatar_backend.cpp:36–39`, code-verified). libKCD2's fully static-asserted `C_Soul` (sizeof 0xD20) puts `m_name` (init `"<not-initialized-soul>"`) at **+0x40**, and +0x3E8 falls inside `S_SoulRegistry m_registry` (+0x340–0x498) which libKCD2 itself marks UNCONFIRMED. Not necessarily a contradiction (name-string-id vs display name may be two fields), but unresolved even retail-side. **Stays a verify-first item on our build**, with both candidates recorded. Read-but-unrendered on our binary. |

Bonus carried-retail items noticed in passing (recorded, unverified on ours):
`C_CombatSoul::DealDamage` vtbl [27] retail VA `0x180EE031C` with full
`S_DealDamageParams`; `C_CombatActor::SetOpponent`; the
`SMultiplayerLocomotionRequest`/`RequestLocomotion` surface on `C_Actor` —
someone upstream is clearly thinking about MP-shaped locomotion injection.

---

## Phase 3 — verdict and what the queued WOs budget

**Don't adopt** — neither as submodule, nor as copied pinned headers, nor as
runtime table:

1. **Wrong binary, structurally.** Every address artifact keys to the retail
   WHGame.dll monolith (`REL::Module::FILENAME`, code-verified). Our native
   layer injects into the Modding Tools split-DLL build; its WHGame.dll is a
   4.5 MB stub and its `whdlversions.json` cannot even produce a valid table
   key (`Assembly: null` → scraper yields a nonsense key; code-verified).
2. **Proven layout drift.** `m_pCombatActor` +0x278 (retail, their disasm) vs
   +0x300 (ours, WO-42 observed) — the one offset checkable both ways differs.
   Typed headers on our build are hypotheses requiring the same per-member
   verification they were meant to replace.
3. **Licensing blocks vendoring anyway.** libKCD2: GPLv3 claimed, no license
   file present. AL: no license, third-party-copyright tooling. Nothing lands
   in our GPLv3 tree.

**Adopt-tooling-only fallback: assessed, not viable as shipped, not run**
(running was out of scope by prompt). Their generation pipeline is
IDA 9.x + Class Informer per binary → `IDAExport.py` → `IDADiffCalculator.exe`
(6+ GB RAM, ~1 h per pair) → `build_library.py`. It diffs two *builds of the
same binary*; the generation we would actually want is retail-WHGame ↔ each MT
module DLL, to transfer libKCD2's 1.39M-id knowledge onto our binaries —
plausible in principle (the matcher takes arbitrary export pairs) but unproven
for monolith↔module splits and PGO↔LTO compile-config noise, and blocked here
on IDA (our toolchain is Ghidra; the export format is IDA-scripted). If a
future WO wants this experiment, it needs: IDA access, one steam↔steam
control diff, then WHGame↔EntityModule with our known offsets (`0x92260`,
`0xAE17A0`) as ground-truth match probes. Scoped; nothing committed under
`tools/` (license forbids redistribution regardless).

**What WO-68 budgets:** raw disassembly of our `RPGModule.dll` (19.1 MB), as
before — vendor code contributes nothing on script contexts (zero native
surface in both repos; theirs is the Lua API our build lacks). The one cost
reduction available: libKCD2's rpgmodule header corpus as a naming/shape map
while reading.

**What WO-69 budgets:** hand verification, not hand discovery — five concrete
retail-verified hypotheses (Activate [52]/+0x1A0, IsActive [53]/bit0@+0x08,
Hide [63]/+0x1F8, IsHidden [64]/bit4@+0x08, plus the save/restore recipe
`{IsHidden,IsActive}` on adopt / restore on teardown) to confirm on our
CEntity via RTTI + a WO-43-style runtime probe. Expect hours, not sessions.

**One strategic note, recorded not recommended:** the retail binary on this
machine hash-matches the vendor stack exactly, and retail + `-devmode` already
gives us RemoteConsole (WO-18). If the project ever migrated its native layer
to retail+KCSE, the entire typed library would become live at observed-hash
fidelity on day one. That is a topology decision far beyond this WO (our whole
transport, deploy, and injection stack is Modding-Tools-shaped), but it is the
only world in which "adopt" flips to yes.
