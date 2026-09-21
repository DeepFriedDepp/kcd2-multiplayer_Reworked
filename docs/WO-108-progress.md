# WO-108 — progress: what ran, what did not, what blocked it

Session 2026-09-21, solo. Findings: `docs/WO-108-findings.md`. Inventory:
`docs/WO-108-toggle-inventory.md`. Runbook: `docs/WO-108-peer-test-runbook.md`.
Release notes: `docs/releases/RELEASE-NOTES-0.26.4.md`.
**Nothing in this WO ran two-player. Nothing was deleted.**

## 1. What ran

| phase | status | note |
|---|---|---|
| 0 — save-reload hazard (gating) | **passed** | three load paths incl. cold relaunch, bit gone every time (observed). Default flip proceeded |
| 0.5 — bulk suppression (maintainer's mid-session request) | **done** | 46 NPCs, one batch, 30 s hold, no hitch, bulk resume (observed) |
| 1.1 — toggle inventory | **done** | 60+ rows, every one with a status; 4 `unresolved`, 3 flipped |
| 1.2 — NPC wire inventory | **done** | on-the-wire table + the not-on-the-wire complement (code-verified); one row (inconclusive) |
| 2.1 — trigger audit | **done** | already blanket + joiner-only; no rewiring needed (code-verified; two-machine confirmation is the peer test) |
| 2.2 — suspend-set invariant | **done** | not-a-puppet and authority guards, gap detector (synthetic + observed) |
| 2.3 — defaults | **done** | 3 flips, each cited; the rest `=` |
| 2.4 — presets | **done** | `mp_preset_clean` / `mp_preset_legacy`, 16 logged values each (observed) |
| 3.1 — identity logs | **done** | name + WUID + entity id + exec verdict on every MP-PAUSE line (observed solo; cross-machine inconclusive) |
| 3.2 — `paused=` | **done** | replaced by `pause_issued=` + `pause_exec=`; engine state stated as unreadable from Lua |
| 3.3 — relax tag | **done (synthetic)** | heuristic implemented and unit-tested; could not be provoked live (§3 below) |
| 3.4 — belt-and-braces resume | **done** | table in findings §5.4; `mp_resume_all` observed |
| 3.5 — dwell | **done** | `mp_resume_dwell`, default 10 s, observed to the second |
| 4 — runbook | **done** | written from the wire inventory; "gliding" corrected to "mannequin legs" |
| 5 — smoke, 7 items | **7/7 ran live** | item 3's relax half is synthetic-only (nothing live to tag) |
| end gate | see §4 | |

### Method notes

* Live probing used the WO-106 §2 transport unchanged. Forward slashes for
  every Windows path handed to Lua (`loadfile` of a scratch driver was the
  live-test vehicle for both the bulk test and the smoke run — the WO-48
  section-injection trick, no pak rebuild needed for probes).
* Phase 0's persistence probe was **behavioural + the engine's own error
  line**: `Node status inconsistency. Can't update suspended node!` fires
  for a suspended NPC on this build and is greppable per name; its count
  after a load (0 every time) is engine state, not Lua. The
  `wh_ai_ResumeNPC` reply the prompt asked to check does not reach
  `kcd.log` at verbosity 4 and was dropped as a criterion.
* Save/load from the console: `wh_sys_TestSaveGame` writes a genuine
  QuickSave; `wh_sys_TestLoadGame` and `wh_sys_LoadGame 1 <name>` both took
  the "Quick-loading … ignoring delay" path (0.4–0.6 s). The cold relaunch
  was `System.Quit()` (gone in 3 s) + `KingdomCome.exe` started directly
  (API up in ~20 s) + `wh_sys_LoadGame` from the main menu.
* The Bash tool's heredoc breaks on apostrophes in this harness; documents
  went through the Write tool and the Lua/C#/test edits through one Python
  script asserting every old string occurs exactly once.
* Synthetic runs: the new `Test-WO108Synthetic.ps1` 87/87; WO-102 196/196
  and WO-104 92/92 after their default assertions were updated to 0.26.4;
  WO-77 48, WO-84 72, WO-86 47, WO-94 101, WO-95 32, WO-96 160, WO-98 50,
  WO-99 39, WO-100.5 33, ghost-interp 35 — all green, unchanged.
  `Test-WO90Synthetic.ps1` fails one assertion identically against HEAD's
  Lua (pre-existing, not touched).

## 2. Phase 0 detail — decisions taken

* The maintainer's game was running with the launcher stack up
  (launcher, master server, relay, agent). Phase 0 requires a quit and
  relaunch; the prompt authorises it in a throwaway save. A quicksave was
  written first so nothing in the live session was lost, then the same save
  (`quicksave023`, both subjects paused inside it) served all three load
  tests. **The maintainer's `saves/playline1/quicksave023.whs` is that
  throwaway save** — safe to delete.
* The relaunch from the shell does **not** re-inject `KCDMP.dll` and the
  agent (`KcdMpClient.exe`) did not survive the second quit. The game left
  running at the end of the session is a plain Modding Tools instance with
  the 0.26.4 pak loaded and the throwaway save active; **relaunch through
  the launcher before any peer session.**
* Log verbosity: `log_Verbosity` / `log_WriteToFileVerbosity` were set to 4
  to look for the resume reply; the original values were not captured
  before the change (the first probe used a bind that does not exist here).
  WO-11/12/18 record 4 as the standing value for this install, so they were
  left at 4.

## 3. Not done / inconclusive, stated plainly

* **Two-player: everything.** The lever's effect on jitter, whether both
  machines suspend the same body, the joiner-only claim under a real relay,
  locomotion loops on a suspended body under a live stream. This is what
  the build is for.
* **The relax tag tagged nothing real.** Holding a paused puppet 3 m and
  10 m off its anchor under a 100 ms stream produced zero contention
  violations — the writes won outright (consistent with WO-107 §4's 38 Hz
  result). The heuristic is unit-tested and marked as a heuristic in code;
  whether WO-104's 148 `dist_m≈0.4` contentions would have been tagged is
  (inconclusive). It discards nothing: tagged lines still log with
  `anchor_m`/`cos`.
* **UI-driven load** (Continue / load-slot menu) not exercised; all three
  loads went through console loaders.
* **`GetCurAnimation()` returned nil** on the smoke subjects, so whether
  the receiver's locomotion loop actually plays on a suspended body was not
  readable; WO-107 §5's "visibly idle-animating" stands as the only
  evidence.
* **Engine-side pause state** is not readable from Lua; `pause_exec` is
  the console call's pcall verdict. A native read is a DLL follow-up.
* **The reload re-assert** (`event=reassert`) is synthetic-only; the
  chain-dead stamp it keys on is set in `chainMayStart`'s confirmed-dead
  branch (code-verified) but no in-process load was run with live puppets
  after the pak rebuild.
* The prompt's "resume-all-on-load sweep" branch was not built because
  Phase 0 took the other branch; `mp_resume_all` exists regardless.

## 4. End gate

Version `0.26.4` confirmed by the maintainer when asked (not assumed).
`rollback/0.26.3` tagged at `0c5e4d2` — the WO-107 commit, which is
docs-only on top of the 0.26.3 build, so it is the last commit with 0.26.3
code and VERSION — and pushed. `VERSION`, README badge, release notes and
the rebuilt tracked pak committed as `d54bff5` and pushed to `origin main`
**before** the build.

Built from a **fresh clone of origin/main at `d54bff5`** (not the working
tree) with `tools\Build-Installer.ps1`:

* **First run failed its own release gate**: the relay round-trip gate
  reported `Combat_event_round_trips_in_both_lengths(len: 1)` FAIL (12/13).
  Nothing in this WO touches the relay, the protocol or that packet; the
  test binds a random free port and the failing assertion is a read
  timeout on the first theory row, and the 7.5 GB game process was running
  beside the build. The same test passed 13/13 twice in the working tree
  immediately after. **Classified as a load-induced timing flake
  (observed once, not reproduced); the gate was not bypassed** — the whole
  build was re-run.
* **Second run: every gate green** — relay round-trip 13/13, agent unit
  tests 170/170, WO-102 synthetic 196/196, WO-104 synthetic 92/92, native
  plugin + injector rebuilt from source (no cached artifacts in a fresh
  clone), four self-contained publishes, ISCC compiled.
* `KCDMP-Setup-0.26.4.exe`: **100,584,166 bytes, SHA256
  `444c98b8e8f751650ede00d3accee1707e044738db424e64b2bff9342e33daf1`**
  (computed in this session's shell; the maintainer should re-verify
  independently, per the standing rule). Copied to `release\` in the
  working tree. **Not published as a GitHub Release** — not asked.

Pak content check (the WO-106 trap): `Scripts/Startup/kdcmp.lua` extracted
from the **built** `kdcmp.pak` (857,580 bytes — the size and sha256 the
install manifest records) carries every marker of this session
(`WO108-BUILD`, `MP-PAUSE-GAP`, `KCD2MP_ApplyPreset`,
`KCD2MP_ResumeAllPaused`, `authorityPause = true`, replica `enabled =
false`, `npcYield … enabled = false`, `resumeDwellS = 10.0`,
`mp_wo102_relax_shaped`, `pause_issued=`) and is **identical to the
working-tree Lua modulo line endings**. Line endings, stated because the
byte sizes differ: the repo blob and the working tree are LF; this
machine's `core.autocrlf=true` (no `.gitattributes`) checks the clone out
CRLF, so every fresh-clone release pak on this machine has been CRLF Lua
(0.26.3's 834 KB pak included) while a working-tree build is LF (844 KB).
Lua 5.1 accepts both; the smoke run (§1) ran the LF working-tree build,
the installer ships the CRLF clone build. Same source, byte-verified with
`diff --strip-trailing-cr`.

Privacy sweep, UTF-8 **and** UTF-16LE, all 1,024 files in `release\`
including the Setup exe: **zero** occurrences of the maintainer's username
or real hostname. Two hits examined and cleared: `KCDMP_launcher.dll`
contains `duckdns` — the WO-55 UI placeholder text `myserver.duckdns.org`,
generic, in the source since 0.26.0; the six third-party `NAudio*.dll`
carry their upstream author's `C:\Users\<naudio author>\…` build path (a
NuGet package's own PDB path, present in every prior release, not this
project's). PathMap still applies: no first-party binary carries a
`C:\Users` path.

## 5. Session hygiene

* Every NPC touched was resumed: Phase 0 subjects by the loads themselves
  (and `wh_ai_ResumeNPC` on the control), the 46 bulk subjects by the bulk
  resume, the smoke subjects by dwell / gap / `mp_resume_all`
  (`auth_paused_now=0`, `pause_pending=0` at the end).
  `ttkc_woman_10` was left ~10 m off her path by the last hold stream and
  had resumed walking.
* Smoke driver restored `hitSensorOn` to its prior value (false, no agent).
* `quicksave023.whs` (throwaway, paused NPCs inside) left in place.
* Scratch files (bulk driver, smoke driver, patch script, fresh clone) are
  in the session scratchpad, not the repo.
