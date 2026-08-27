# WO-67 — progress

## Session 1 (2026-08-27)

- Shallow-cloned `F02K/libKCD2` @ `c3dff5f` and
  `F02K/Address-Library-For-KCSE` @ `0294d82` (both exactly the commits
  KCD2Online pins as submodules, confirmed via `git ls-tree`), plus
  `DeepFriedDepp/KCD2Online_forked` @ `5777c15` (same pin as WO-64), all into
  the session scratchpad, read-only.
- Identified both installed builds on disk: Modding Tools
  (`Bin\Win64ReleaseSteamLTO_DLL`, 45 DLLs, WHGame.dll is a 4.5 MB stub,
  `whdlversions.json` Assembly:null, lineage `1166656_117`/2026-04) and retail
  (`Win64MasterMasterSteamPGO\WHGame.dll` 89 MB, Assembly.Id 15693, lineage
  `1308617_856`/2026-06). Hashed retail WHGame.dll: MD5 `170A55FE…43E5` ==
  libKCD2's recorded target exactly.
- Read the discriminator from their code (`REL/Module.cpp`,
  `REL/IDDatabase.cpp`): table file = `kcd_addresslib_<dist>_<key>.bin`, key =
  `<Branch.Name>-<Assembly.Id>` from `whdlversions.json`; the library is a
  Steam↔GOG↔Epic cross-distribution diff of ONE retail build
  (`release_1_5-15693`), 1.39M unnamed ids, monolith-only
  (`Module::FILENAME = L"WHGame.dll"`).
- Three-offset diff resolved as "our build absent / structurally out of
  scope"; the checkable-both-ways datum (`m_pCombatActor` +0x278 retail vs
  +0x300 ours, WO-42) proves real layout drift between the two builds.
- License check from the actual repos: libKCD2 claims GPLv3 in README but
  ships no LICENSE file; the Address Library has no license at all and its
  diff tool is third-party-copyrighted. Neither is vendorable into GPLv3.
- Phase 2 coverage map written: WO-68 script contexts = nothing in either
  vendor repo (KCD2Online's isolation is the Lua surface WO-65 proved absent
  here); WO-69 = five retail-verified vtable/bit hypotheses to confirm cheaply
  on our build; soul display-name = contested even retail-side (+0x3E8 theirs
  vs m_name +0x40 libKCD2), verify-first.
- Wrote `docs/WO-67-findings.md` ending in an explicit **Don't adopt**
  (reference-only) verdict, with the tooling-fallback experiment scoped but
  not run (IDA-gated), and the retail+KCSE migration world recorded as the
  only "adopt" path.
- No product code changes, no VERSION change, nothing committed to the
  evaluated repos.
