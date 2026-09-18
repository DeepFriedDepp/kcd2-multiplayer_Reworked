# KCD2-MP 0.23.2 — hotfix

Packaged as `KCDMP-Setup-0.23.2.exe`. Setup exe only; there is no DirectInstall
ZIP (retired in 0.22.0).

---

## ⚠ DO NOT USE 0.23.1. BOTH MACHINES MUST RUN 0.23.2

**0.23.1 is unusable in a two-player session: players cannot see each other
move.** A peer becomes visible only while your own game is paused, then
teleports when you unpause. Symmetric on both machines. First real two-player
session on 0.23.1 (2026-09-17) hit it immediately.

Nothing was wrong with the game, the DLL, or the network. See "What was
wrong" below.

The matched-set rule stands: **agent, pak, `KCDMP.dll` and relay all from
0.23.2, on both machines.** Whoever runs the relay must be on 0.23.2 — the fix
is in the relay.

---

## What was wrong (docs/WO-101-findings.md)

0.23.1 added five optional body-state bytes to the position packet, behind a
flag bit, so a peer's ghost could animate from real Mannequin state instead of
inferring it. The agent that sent it and the agent that received it both
understood the new 22-byte packet. **The relay between them did not.** Its
position gate compared the length against the old constant (17) and silently
skipped anything else — no log line, no counter. Every live position sample
from a 0.23.1 agent carried a body and was 22 bytes, so every one was dropped.

The only position packet the relay still passed was the 2-second "stale
heartbeat" the agent sends while your game is paused — that one has no body
and is still 17 bytes. Hence: visible only while paused.

Field numbers from the session: host sent 1580 position samples and received
17 ghost updates; joiner sent 370 and received 8; every received update was
stale-flagged.

## What is fixed

* **The relay accepts both position lengths (17 and 22) and forwards the
  body-state bytes verbatim** in the ghost packet (18 or 23 bytes). Wire
  format unchanged; the body-state feature is kept, not reverted.
* Every other length gate on the path was audited. Only this one pair had the
  defect. The action channel (`0x3B`/`0x3C`) and the combat-event pair were
  already consistent end to end.

## What is new: the relay round-trip gate

`dotnet/KcdMp.Relay.Tests` hosts the real relay in-process, connects two real
TCP peers, and proves a 22-byte position, a 17-byte position, a stale
heartbeat, both action-channel lengths and both combat-event lengths cross it
with every field intact. **`tools/Build-Installer.ps1` runs it before it
publishes anything.** Run against the 0.23.1 relay code, it fails exactly the
two body-state cases — this build would not have shipped.

This exists because 0.23.1's 111 synthetic tests all passed and none of them
opened a socket to the relay. Codec unit tests do not prove a packet crosses
the wire.

## Also in this build

* The agent's startup `NullReferenceException` lines from `DiscordRPC.Assets.Merge`
  are **benign**: the library merges Discord's own reply, which carries no
  small image, and catches the throw on its own thread. Presence works; only
  the "presence ack" log line is lost. The code comment that claimed otherwise
  is corrected. No fix exists short of forking the library (the only newer
  NuGet release is deprecated).
* The burst of `[appearance] unequip … 404` lines after a peer connects is a
  long-standing 1-per-session spawn race; on 0.23.1 it repeated for two
  minutes because the ghost never spawned. Goes away with the fix. Left alone.

## Not changed

* `kdcmp.pak` — no Lua change this release. The shipped pak is rebuilt from
  the same source by the installer build and verified to carry the 0.23.1 Lua.
* `KCDMP.dll` — rebuilt by the fresh-clone build from unchanged source
  (MSVC timestamps differ; source is identical to 0.23.1).

## Verification status

| item | status |
|---|---|
| relay accepts 22-byte position and forwards body state | (synthetic) 10/10 loopback through the real relay |
| gate fails on the 0.23.1 relay code | (synthetic) 2 of 10 fail, exactly the body-state cases |
| agent unit tests after the codec extraction | (synthetic) 127/127 |
| two machines on 0.23.2 seeing each other move | **not run** — hands-off session. Next field session starts there |
