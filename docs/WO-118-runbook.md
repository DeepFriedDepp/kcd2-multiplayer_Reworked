# WO-118 peer test — the one page for two people mid-session

**Both machines must run this build.** The relay refuses anything else, with a
clear message on both sides (`Relay runs KCD2-MP <x>, this machine runs <y>`).

**Before the session: copy the host's save to the joiner.** The host saves,
closes the game, and copies that save file from `<saves>\playline1\` to the same
folder on the joiner's machine; the joiner loads that copy. Both worlds then
start with the same NPCs in the same places. Do not paste save files or their
headers into chat or tickets.

**Before either machine relaunches the game: copy both `kcd.log` files.** Every
launch rotates `kcd.log` into `logbackups\`, which keeps one file.

**Keep the game window in front** on the joiner. KCD2 drops to ~26 fps when its
window is not focused, and at that rate the agent cannot feed a crowd of walking
NPCs (findings §3.10): puppets start to step and lag. Alt-tab briefly.

---

## What you should see on load (nothing typed)

kcd.log, shortly after `[KCD2-MP] === MOD INIT ===`:

```
[KCD2-MP] WO118-BUILD npc_native_write=on npc_detach=on native_stale_s=3.0 native_retry_s=10 -- per-frame native write at the frame hook (ground collider kept), …
```

`kcdmp-native.mirror.log` in the game folder (beside `kcd.log`; a copy of
`kcdmp-native.log`, which sits beside the DLL in `%LocalAppData%\KCDMP`), once
the launcher has injected the DLL:

```
WO118-NATIVE native_write=armed on=on senderclock=on setposrotscale=CryEntitySystem.dll+0x90AA0 living_setparams=CryPhysics.dll+0x9C900 recalc=0x21 …
```

`native_write=DISARMED` means the build's binaries did not match (a game
update): everything falls back to the old Lua path. Say so; nothing below about
smoothness applies then.

## Who is the authority

Both machines, after connecting: `MP-AUTHORITY-OWNER self_id=<n> authority=self|peer`.
Exactly one says `self` (the host: owns every NPC, never pauses them). The other
is the **joiner**: it renders puppets, and everything below is about the joiner.

## The one-line pass/fail

**Walk into a crowd together, on the joiner. Do walking NPCs stutter (stand,
dash)? Do NPCs the host pulled off a bench or a workstation slide back or
flicker? Does anything sink?**

* Smooth, no slide-back, no sinking → pass. Capture the logs anyway.
* Stutter → look at the joiner agent console's `MP-NPCWRITE-STATUS` line first
  (below), then run the A/B.

## The A/B and the toggles (joiner console, typed plainly)

| command | what |
|---|---|
| `mp_npc_native_write off` / `on` | **The A/B.** Off = the old 50 ms Lua write (the stutter should come back at once); on = the per-frame DLL write (default). |
| `mp_npc_detach off` / `on` | Free paused NPCs from their seat/workstation (default on). Off = the seat pulls the body between writes again: invisible while the native write is on (`MP-NPCPULL` shows it), a visible flicker on the legacy path. |
| `mp_preset_legacy` / `mp_preset_clean` | Every toggle back to the previous release / to this build's defaults. |
| `mp_npc_trace <entity> [seconds]` | Records one row per frame (position at the frame hook, what was written, position at render) to `kcdmp-trace-<entity>-<time>.csv` in the game folder. Entity names are in `kcdmp-native.mirror.log` (`MP-NPCBIND npc=<name>`) and in the ghost's case `kcd2mp_<id>`. |
| `mp_puppet_rate <ms>` | **Legacy path only** — does nothing while `mp_npc_native_write` is on. |

## The new log lines, and where

| file | line | meaning |
|---|---|---|
| `kcdmp-native.mirror.log` | `WO118-NATIVE native_write=armed\|DISARMED` | the writer's start verdict |
| | `MP-NPCBIND npc= result=ok … jitter_allow_ms=` / `result=refused reason=` | a puppet handed to the DLL (refusal `not-living` = no physics body, stays on Lua) |
| | `MP-NPCWRITE npc= event=drop reason=` | the DLL let a puppet go (silence, entity gone, unbound, toggle off, pipe closed) |
| | `MP-NPCPULL npc= mean_cm= … lag_frames= … jitter_allow_ms=` | every 10 s, only if the engine moved a puppet between our writes |
| | `MP-NPCWRITE-COST … tick_us_mean=` | the writer's own time per frame, every 10 s while anything is bound |
| | `MP-NPCTRACE` | trace started / written |
| `kcd.log` | `MP-DETACH npc= result=<before>-><after> changed=` | a puppet freed from its activity (or `skipped-dialog`) |
| | `MP-NPCWRITE npc= native=bound\|refused\|dropped` | the mod's side of each bind |
| | `MP-NPCWRITE native=healthy … (heartbeat)` | the DLL heartbeat came back after a > 3 s gap |
| agent console | `MP-NPCWRITE-STATUS armed= on= bound= writing= …` | every 10 s: how many puppets the DLL holds and writes |

`MP-NPCZ`, `MP-AUTHORITY-VIOLATION`, `MP-NPCFIGHT` now end in `path=legacy`:
they only measure the old Lua write.

## What to send back

Both `kcd.log`, both `kcdmp-native.mirror.log`, both agent consoles, `relay.log`, any
`kcdmp-trace-*.csv`, and the clock time of anything that looked wrong.
