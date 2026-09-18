# WO-101 — progress

Session 2026-09-17, hands-off (no live game, no DLL deploy, no maintainer).
Findings: `docs/WO-101-findings.md`. Release: `KCDMP-Setup-0.23.2.exe`.

## What landed

| phase | state | evidence |
|---|---|---|
| 0 — locate the drop | **done** — `ClientSession.cs:555`, the relay's exact-length Position gate | (code-verified), confirmed against both 09-17 bundles (observed) |
| 1 — fix + audit | **done** — relay takes 17 \| 22, forwards the tail; only pair with the defect | (code-verified), relay builds green |
| 2 — the gate | **done** — `dotnet/KcdMp.Relay.Tests`, 10/10, wired into `Build-Installer.ps1`; fails 2/10 on the 0.23.1 relay | (synthetic) |
| 3 — loose ends | **done** — Discord NRE benign (null is in Discord's reply); unequip 404 = pre-existing spawn race | (observed) + (code-verified) |
| end gate | **`KCDMP-Setup-0.23.2.exe` built from a fresh clone** | — |

## Commits (all on `origin main`)

1. `9c3742c` Phase 0 — findings only.
2. `78f4043` Phase 1 — relay fix + length-gate audit.
3. `eeb8018` Phase 2 — round-trip gate, `Program.CreateApp`, `PositionCodec`, build-script hook.
4. `b50f22f` Phase 3 — Discord comment corrected, findings §3.
5. `eb4b8dc` VERSION 0.23.2, badge, release notes.
6. this commit — progress doc, findings §4.

## Code

* `dotnet/KcdMp.Server/Features/ClientHandling/ClientSession.cs` — Position
  gate accepts both lengths; `EnqueueGhost(..., byte[] tail)`.
* `dotnet/KcdMp.Server/Features/Tcp/TcpBroadcastService.cs` — `Broadcast`
  carries the tail (echo mode too).
* `dotnet/KcdMp.Server/Program.cs` — `public static WebApplication CreateApp(args)`;
  `Main` is now two lines that call it.
* `dotnet/KcdMp.Client/PositionCodec.cs` — new: `BuildPosition`,
  `TryDecodeGhost`, `GhostSample`. `GameBridge.SendPositionAsync` and the Ghost
  receive branch call it; behaviour unchanged (127/127).
* `dotnet/KcdMp.Relay.Tests/` — new project, in `KcdMp.sln`.
* `tools/Build-Installer.ps1` — runs the gate before `Publish-Release.ps1`;
  aborts the build on failure.
* `dotnet/KcdMp.Client/DiscordPresence.cs` — comment only.

No Lua change. No native change. Wire format unchanged.

## End gate — built

* Pushed to `origin main` first (`eb4b8dc`); built from a **fresh `--depth 1`
  clone** of upstream at that commit, not the working tree.
* `VERSION` → `0.23.2` (maintainer-specified). README badge updated.
  `docs/releases/RELEASE-NOTES-0.23.2.md` leads with "do not use 0.23.1".
* Inside the clone the build ran, in order: pak rebuild (726,724 bytes),
  **relay round-trip gate 10/10**, four publishes, native build, ISCC.
* `KCDMP-Setup-0.23.2.exe`, **100,537,299 bytes**,
  sha256 `723A8D90F5B9C56DEC3962CFE922996DE0C0BC5AD59D9E1B013C2B3A2066A1EA`.
  Copied to `release/`. **Setup exe only** — DirectInstall is retired (WO-94).
* **Privacy re-verified (WO-98 §0), both encodings.** The whole publish
  output — **1024 files** — grepped for the build machine's username,
  `C:\Users`, the repo folder name, the scratchpad session id, the temp path,
  the clone path and the maintainer's mail domain, in **UTF-8 and UTF-16LE**.
  **Zero first-party hits.** The same six NAudio DLLs as WO-98 / WO-100.5
  carry their own author's `C:\Users` path (UTF-8) — third-party, not ours.
* **Shipped pak verified.** Opened `kdcmp.pak` from the clone:
  `Scripts/Startup/kdcmp.lua` sha256
  `d8cffa792b804d9757c9e10cf3f135b2594b2183805868ad15e1c3a9653976ef` ==
  the repo's `kdcmp/Data/Scripts/Startup/kdcmp.lua`, byte for byte; the
  WO-100.5 markers (`ghostNoAi`, `bodyAnimTag`, `MP-GHOSTCORR`,
  `mp_anim_legacy_on`, `bodyPaceName`) are present (13 lines). No Lua changed
  this WO, so the committed pak was not rebuilt; the shipped one is the
  installer build's own rebuild from the same source.
* `KCDMP.dll` in the clone has a different sha256 from the working tree's —
  `git diff d663f15 -- native` is empty, so it is the MSVC timestamp, same
  source as 0.23.1.
* **Matched set:** both machines on 0.23.2, including whoever runs the relay
  (the fix is in the relay).

## Not verified

* **No two-machine session on 0.23.2.** Everything here is (code-verified)
  or (synthetic) except the field diagnosis. The next field session starts by
  having two players walk in sight of each other and reading
  `MP-SUMMARY section=position` / `section=ghost` — `ghost_stale_in` should be
  a small fraction of packets, not 100 %.
* Body-state animation on the receiving ghost (WO-100.5 Phase 2) has still
  never been seen live; 0.23.2 is the first build where the bytes can arrive.

## Deviations

| deviation | taken or dropped |
|---|---|
| Extracted `PositionCodec` from `GameBridge` (a refactor in a hotfix) | **taken.** The gate has to send the bytes the shipped agent sends; a copy of the encoder in the test would prove nothing about the agent |
| Added `Program.CreateApp` and made `Program` public | **taken.** Hosting the real relay in-process needs its DI graph; duplicating it would drift |
| Wired the gate into `Build-Installer.ps1` | **taken.** "Standing gate" in a comment only is a suggestion; in the build script it is a gate |
| Discord NRE: no code fix | **taken.** Benign; the only newer NuGet package is deprecated. Comment corrected instead |
| Did not rebuild the committed pak | **taken.** No Lua change; the shipped pak is verified against the repo Lua anyway |

## Still unfixed, not this WO

* `Test-WO99Synthetic.ps1` always exits 2 (never sets `OUT`).
* The byte-wide relay player id still wraps (WO-75).
* The appearance-before-spawn race (§3.2): 1 harmless 404 per session.
* `NpcDamageUp` / `WeatherUp` do not truncate the name they send (§1.2 note).
