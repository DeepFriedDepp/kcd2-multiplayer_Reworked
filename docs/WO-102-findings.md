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

---

## 2. Phase 2 — baseline the claim model (done before Phase 1; independent of it)

### 2.1 The 2026-09-17 figures, reproduced and corrected in place (observed)

The prompt's figures come from the host's `relay20260917.log`, which covers
the **whole day**: a solo 0.22.7 session (14:19–15:18), the 0.23.1 session
WO-101 diagnosed (19:24–19:45, in which the joiner reconnected and was
reassigned id 2 at 19:34), and the 0.23.2 session (20:16 onward). The mod
and agent logs in the bundles are the 0.23.2 session only. Both cuts:

| figure | prompt | whole day (what the prompt counted) | 0.23.2 session only (20:16→, log cut at bundle time 20:23) |
|---|---|---|---|
| `[CLAIM] granted` | 52, "every one to owner=1" | **52: 44 owner=1, 8 owner=2** — owner=2 is the joiner's reconnected id in the 19:34 window, not a third player | **22, all owner=1** |
| grants to owner=0 | 0 | **0** | **0** |
| releases | 27: 19 expiry, 8 disconnect | **27: 19 expiry, 8 disconnect** | 5, all expiry (the log ends mid-session) |
| held time (s) | min 9.0 / median 44.9 / max 171.9 | min **9.0**, median **47.4** (the 14th of 27; 44.9 is the 13th), max **171.9** | 18.3 / 65.9 / 171.9 (n=5) |
| `[WO66-REJECT]` denials | — | **0** | **0** |
| `[CLAIM] reassigned` / `CONTESTED` | — | **0** | **0** |

So: "zero to owner=0" **holds**, and the mechanism WO-98 §2 named holds
(code-verified again this session, `ClientHandler.RouteNpcState`: the damage
authority's packets never create claims). "Every one to owner=1" is wrong
only in that 8 of the day's 52 went to the same joiner under a second id.
"Claims expire mid-fight" holds: 19 of 27 releases are `reason=expiry` and
every expiry means the owner stopped refreshing for > 5 s (15 s if engaged)
while the name was still being sent by someone — with the relay muting the
authority's stream for that name until then.

Divergence figures (observed, mod logs, both machines):

| line | host | joiner |
|---|---|---|
| `MP-NPCFIGHT` lines / `MP-NPCDIVERGE` releases | 15 / 2 | 19 / 3 |
| `ttkc_man_20` | `n=8 mean_m=36.44 max_m=97.09`, released at 97.1 m | — |
| `ttkc_woman_6` | `n=56 mean_m=1.87 max_m=95.99` (never released: only 1 far hit inside the 30 s window) | — |
| `ttkc_horse_3` | `max_m=31.81`, released at 11.2 m | `max_m=20.92`, released at 10.1 m |
| `ttkc_man_5` | — | `max_m=34.98`, released at 35.0 m |
| `ttkc_woman_14` | — | `n=57 max_m=24.42`, released at 24.4 m |
| `ttkc_man_33` (not in the prompt) | — | `n=86 mean_m=1.13 max_m=86.10`, **not released** |
| `MP-NPCYIELD` lines | 19 | 20 |
| puppet starts / silence releases / tracking starts | 22 / 14 / 40 | 28 / 25 / 22 |

Every prompt figure reproduces; two were incomplete (`ttkc_woman_6` and
`ttkc_man_33` reached 96 m and 86 m without ever tripping the 3-hits-in-30-s
release, so the WO-90 net let the two worst divergences after `ttkc_man_20`
through).

Position cadence, for Phase 1's baseline (observed, agent `[pos]` lines,
which print only when the sample changed; 0.23.2 session):

| | host | joiner |
|---|---|---|
| samples | 3200 | 3376 |
| interval mean / p50 / p95 / max (ms) | 80.2 / 59 / 139 / 1849 | 74.9 / 58 / 127 / 1539 |
| min (ms) | 13 | 12 |

The mod emits at 20 ms; the agent sees a fresh sample every ~59 ms typical
with a p95 more than twice that. That spread is what Phase 1 measures
against, with proper per-path instrumentation instead of the console line.

### 2.2 What is instrumented now (code-verified, synthetic)

* **Relay.** `[CLAIM] muted npc= owner= authority= claimAgeSec=` — the
  damage authority's own stream for a claimed name being dropped, logged once
  per claim and counted per packet (`AuthorityMutedClaims`,
  `AuthorityMutedPackets` appended to `GET api/information/npc-claims`, both
  new record fields default 0). This is the event the prompt calls the
  "request" the relay never logged: the authority cannot ask, so its denied
  packets are its request. `[CLAIM] released … reason=expiry` gains
  `packets=` (owner refreshes accepted), `silentSec=` and `noticedBy=`;
  `reason=disconnect` gains `packets=`. Denials were already
  `[WO66-REJECT] stale-owner|speed|reserved-name`; grants and
  reassignments were already logged (WO-81). Nothing in the routing decision
  changed — the WO-66 invariant (a rejected packet mutates nothing) is intact
  because the new bookkeeping sits on the accepted paths only.
* **Agent.** `KCD2MP_ApplyNpcState` now receives the sending ghost id as an
  appended 8th argument (an older pak ignores it; an older agent leaves it
  `nil`).
* **Mod.** `MP-AUTHORITY npc= event=acquire|release|owner-change owner=
  via= held_s= model= [from=]` at every ownership transition: tracking start
  (`via=authority-default` / `via=claim`), drag claim, puppet start
  (`via=stream`), owner change mid-puppet (a claim moved at the relay),
  re-pin, and every release (`untrack`, `drag-idle`, `silence`, `diverge`,
  `yield`). Counters in `MP-SUMMARY-MOD` (`auth_acquire= auth_release=
  auth_owner_changes= auth_model=`). Format in `docs/WO-98-log-format.md`.
  Synthetic 31/31 (Phase 0 + Phase 2 scenarios g–l); the puppet-path suites
  unchanged: NpcSmooth 48/48, WO-84 72/72, WO-86 47/47, WO-90 70/70, WO-99
  39/39.

### 2.3 Wire compatibility (Phase 2)

No wire change. New relay log lines and two additive JSON fields on an
HTTP diagnostics endpoint. A 0.23.2 agent against this relay, or this agent
against a 0.23.2 relay, behaves as before.
