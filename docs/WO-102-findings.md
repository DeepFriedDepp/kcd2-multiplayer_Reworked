# WO-102 — host-authoritative NPCs

Session 2026-09-18. Modding Tools build 1.5.5.0 (`ReleaseSteamLTO_DLL`), the
binaries every native RVA in this repo keys to. Working tree at `4d720cf`
(0.23.2) when the session opened.

Evidence marks, strict: **(observed)** = a log or a screen; **(code-verified)**
= read out of source, a binary or a shipped data file; **(synthetic)** = a
test harness, no game; **(inconclusive)** = exactly that. Nothing is rounded up.

Field-log source for every 2026-09-17 figure: the maintainer's HOST and
JOINER bundles (`agent.log`, `kcd.log`, `kcdmp-native.log`, host
`relay20260917.log`), read in this session. No identifying detail from them
is reproduced here.

---

## 0. Phase 0 — toggles and revertability

### 0.1 The toggle set

| toggle | console (argless pair) | agent flag | mod field | session default | phase |
|---|---|---|---|---|---|
| host NPC authority | `mp_authority_host_on` / `_off` | `--authority-host` / `--no-authority-host` (`HostAuthorityEnabled`) | `KCD2MP.wo102.authorityHost` | **off** | 4 |
| native position | `mp_pos_native_on` / `_off` | `--pos-native` / `--no-pos-native` (`NativePositionEnabled`) | `KCD2MP.wo102.posNative` | **off** | 1 |
| status | `mp_wo102_status` | — | — | — | 0 |

Mechanics (code-verified, synthetic 15/15 in `tools/Test-WO102Synthetic.ps1`):

* One setter, `KCD2MP_Wo102Set(name, on, source)`. A console flip logs
  `WO102-TOGGLE name= state= was= source=console` and emits **one**
  `wo102_toggle <name> on|off` event line; the agent's `OnGameEvent` mirrors
  it into `_hostAuthority` / `_posNative` (volatile, read at tick time).
* The agent pushes its configured defaults into the mod at connect with
  `source="agent"`, which mirrors the flag and emits nothing back (no echo
  loop). So the **shipped default lives in `ClientConfig`**, the mod's own
  `false` is only what an older agent leaves behind — i.e. 0.23.2 behaviour.
* Argless by construction: the console drops arguments from Lua-registered
  commands on this build (WO-94, live). The synthetic test asserts no
  `%LINE` in any WO-102 command body.
* `MP-SUMMARY section=wo102 authority_host= pos_native= authority=` is
  printed with every session summary so a field bundle states which model
  it ran under.

### 0.2 With every toggle off the build is 0.23.2

Phase 0 adds no behaviour behind either toggle; the flags exist, are logged
and are mirrored, and nothing reads them yet. The synthetic test pins the
0.23.2 defaults the later phases must not disturb: `npcSync.enabled`,
`npcProx.enabled`, `npcDiverge`, `npcYield.enabled` all `true`.

### 0.3 Wire compatibility with 0.23.2 (stated per phase, revised as phases land)

* **Phase 0:** no wire change. The toggle travels on the kcd.log event
  channel (game → agent, same machine). A 0.23.2 / new-build pair behaves
  exactly as 0.23.2 / 0.23.2.
* Later phases update this list in place.

### 0.4 One commit per phase

`git revert <sha>` of any one phase commit undoes that phase alone. No phase
relies on an earlier one being irreversible; a reverted Phase 0 would take
the toggle *plumbing* with it, so later phases fall back to their flags'
compile-time `false`.
