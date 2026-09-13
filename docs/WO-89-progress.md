# WO-89 progress

Read `docs/WO-89-findings.md` first — it carries the evidence. This file is
the state-of-play.

## Status

| Item | State |
|---|---|
| Phase 0 — ground truth | **Done.** `main` confirmed at WO-88's head, nothing else landed since WO-85. No native/protocol commit exists after WO-85's build — confirmed by ranged `git log`, not assumed. |
| Phase 1 — version | **Done.** `0.21.5`, stated explicitly by the user at session start. |
| Phase 1 — native DLL | **Confirmed unneeded.** sha256-identical to WO-85's build, both before this session's build ran and in the shipped manifest afterward. |
| Phase 1 — build | **Done.** Pak rebuilt, agent/relay/launcher/master-server republished, `KCDMP-Setup-0.21.5.exe` (95.8 MB) + `KCDMP-DirectInstall-0.21.5.zip` (130 MB) built. `dotnet build KCD2-MP.sln`: 0 errors, 8 warnings (unchanged set). |
| Phase 1 — install matrix | **Done, 97/97.** Fixture-based (real `%LocalAppData%` is sandbox-redirected from this shell): Detect 21/21, Upgrade 33/33 (incl. a real upgrade from the 0.21.1 Setup exe), full lifecycle 43/43. |
| Phase 2 — regression suite | **Done, 436/436.** All 12 carried-forward suites plus the new `KcdMp.Client.Tests` (21/21). Nothing needed fixing. |
| Phase 3 — smoke pass | **Skipped, stated why.** No game process, no listener on 1403/4600, at any point this session. |
| Phase 4 — release notes | **Done.** `docs/releases/RELEASE-NOTES-0.21.5.md`; `docs/VERSIONING.md` row added. |

**533 checks total this session (436 regression + 97 install matrix), 0
failures.**

## What changed

| File | Change |
|---|---|
| `VERSION` | `0.21.1` → `0.21.5` |
| `README.md` | main badge + link updated to `0.21.5` |
| `docs/VERSIONING.md` | new `0.21.5` / WO-89 row |
| `kdcmp/Data/kdcmp.pak` | rebuilt from unchanged sources (ships `mp_probe_dialog`) |
| `tools/Verify-Install.ps1` | 3 new markers for WO-88's agent/pak changes (findings §7) |
| `docs/releases/RELEASE-NOTES-0.21.5.md` | new |
| `docs/WO-89-findings.md`, this file | new |

Not changed: any `.cs`, `.lua`, or `native/` source. This was a packaging
session for WO-88's already-written, already-tested code.

## Deploy note

Matched set as usual: `KCDMP-Setup-0.21.5.exe` (full install, game/launcher/
agent/relay closed first) or `KCDMP-DirectInstall-0.21.5.zip` via
`Apply.ps1` over an existing install. Run `tools\Verify-Install.ps1`
afterward and confirm agreement.

Both players need `0.21.5` for the new periodic clock-share to help — an
older peer still announces at connect and applies forward-only (today's
behavior, not worse). The death-tag and appearance fixes are local to
whichever machine is updated and help regardless of the peer's version.

## For the next session

Everything WO-88's own progress doc already named is still open and now
also gated on this build actually shipping:

1. Die and reload with a peer connected; confirm the death tag does not
   flicker, the peer's outfit re-applies after your reload, and the clock
   converges within ~10-20 s (or re-sends until it does).
2. Watch the periodic quiet clock announce (~once a minute) hold both
   peers' clocks in sync without either side reloading or skipping.
3. Run `mp_probe_dialog` outside and inside a real conversation; record its
   four `type=`/`ok=`/`val=` lines for the next session that might use it.
4. Not this session's job, named so nobody expects it: dialogue-related NPC
   jitter is unaddressed. If seen, check the affected NPC's `NPC-SYNC packet
   cadence` on the watcher — heartbeat-only cadence means WO-63/64
   territory, not this build.
