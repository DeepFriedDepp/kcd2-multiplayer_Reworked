# WO-127: the 0.29.9 test build

Session 2026-09-25/26. Solo, one machine, Modding Tools build 1.5.5. One
installer carrying everything on `main` (WO-122–125, dormant behind the host's
`mp_shared_world`) plus Steam as an optional connection, plain connection
errors with a Test connection button, and the leash recorder for WO-128.
Progress, method and side effects: `docs/WO-127-progress.md`. Tester page:
`docs/TEST-0.29.9.md`. Runbook: `docs/WO-124-first-shared-world-runbook.md`.

Evidence marks: (observed) / (code-verified) / (synthetic) / (inconclusive).
Still **protocol v9, no new message type** (next free type byte stays 0x58).
`VERSION` = `0.29.9` (the maintainer's string). No GitHub Release.

---

## 0. Answer first

| # | item | result | evidence |
|---|---|---|---|
| 0 | why WO-120 read "Steam not logged in" | `SteamAPI_IsSteamRunning` only reads `HKCU\…\ActiveProcess\pid`; the current Steam client leaves it (and `ActiveUser`) at 0 while logged on. Not the sandbox, not the hive. `SteamAPI_InitFlat` works | observed |
| 0 | `SteamProbe check`, three app ids | 2429020, 480, 1771300: init OK, relay network + certificate ready in 3.7–4.5 s, listen OK, rich presence set + read back | observed |
| 1 | relay listens on Steam beside TCP | "Also allow Steam" → `SteamRelayService`; ready in ~5 s under 2429020 **with the game running** under the same app id | observed |
| 1 | Steam peer never "local" | a Steam session is a non-loopback `ClientSession`; the host's own agent keeps rule 1 even when the Steam peer connected first | synthetic (relay test over a non-loopback stream) |
| 1 | host is the authority whatever the order | Position flag 0x40 HOST CLAIM; a claimant wins. Real game as host, a peer connected **first** (id 0): `MP-AUTHORITY-OWNER id=1 reason=declared-host` | observed |
| 1 | WO-124 carry-forward (remote relay: first to connect wins) | closed by the same rule | synthetic (relay test, two non-loopback peers) |
| 1 | app id mismatch | the code carries the app (`ABCD-EFG` = 2429020, `-S` = 480, `-R` = 1771300); a mismatch is a plain message before Steam starts | observed + synthetic |
| 1 | falls back cleanly | full agent → a code nobody hosts: "Couldn't connect through Steam: no route to the host within 20 seconds. Try the host's address instead." at 20 s, no hang, retries; direct path unaffected | observed |
| 1 | Steam logs | every Steam string through `SteamLogScrub`; steam_api's own stderr SteamID print silenced during init; 0 SteamIDs in agent.log / relay.log | observed |
| 2 | plain errors | 16 kinds, one sentence + one next step each; refused / wrong address / host-not-running / own code / app mismatch / no route seen live | observed + synthetic |
| 2 | Test connection | reachable, same version, host connected, 2 ms round trip (direct); never becomes a session | observed |
| 2 | mixed build | joiner: "The host runs version X and you run Y…"; host's launcher: "A player tried to join with version X…" | synthetic (relay test) |
| 3 | leash recorder | host + joiner CSVs, every listed signal but two (§3.3); hidden/active agree with Lua 10/10; brain state live-verified with a pause | observed |
| 3 | cost | trace on: **4.1–4.3 ms main-thread per sample, once a second → 155–166 µs/frame** at the background-limited ~26 fps (≈70 µs/frame at 60 fps). Trace off: nothing runs | observed / code-verified |
| 4 | gates | see §5 | |
| 4 | cross-network Steam | not run (the test session is the gate) | (inconclusive) |

---

## 1. Phase 0: the Steam reading

* `HKCU\Software\Valve\Steam\ActiveProcess` read `pid=0 ActiveUser=0` both
  inside and outside the shell sandbox, from `HKCU` and from
  `HKEY_USERS\<sid>` directly, while `steam.exe` ran as this Windows user and
  Steam's own `connection_log.txt` said `Logged On`. (observed)
* `SteamAPI_IsSteamRunning` checks that pid, so it answered false.
  `SteamAPI_InitFlat` connects to the running client regardless and answered
  OK under all three app ids, from the sandboxed shell too. (observed)
* Fix: `SteamSession.TryStart` no longer gates on `IsSteamRunning`; InitFlat's
  result decides, the registry hint is kept as log detail
  (`IsSteamRunning=0 (registry hint) but InitFlat=OK`). WO-120's
  "SteamNotRunning" reading was this gate, not the account.
* `SteamProbe check` (this machine, Steam logged on):

| app | init | network ready | relay / cert | listen | rich presence |
|---|---|---|---|---|---|
| 2429020 | OK | 4.5 s | current / current | OK | set, read back |
| 480 | OK | 3.7 s | current / current | OK | set, read back |
| 1771300 | OK | 3.9 s | current / current | OK | set, read back |

* A P2P connect to one's own account is refused by Steam (`ConnectP2P`
  returns an invalid handle). One machine can reach "waiting for a peer",
  never a connection. (observed)
* steam_api64.dll prints `Caching Steam ID: <id>` to the process's stderr when
  it initialises. The relay's and agent's logs never had it (their loggers
  don't read native stderr), but a redirected stderr did (observed). Now
  stderr points at NUL while the DLL loads and initialises; the lines are
  gone (observed).

## 2. Phase 1: Steam as a connection path

### 2.1 Shape

* **Relay**: `ClientSession` takes a `RelayConnection` (a `Stream`, a log
  label, "loopback", "tcp"/"steam") instead of a `TcpClient`. The TCP path is
  byte-for-byte the old one. `SteamRelayService` (config `Steam:Enabled`,
  `Steam:AppId`, `Steam:GameExe`; launcher args `--steam true --steam-app N
  --steam-game <exe>`) starts Steam, waits for the relay network, listens on
  virtual port 7778, sets rich presence `kcdmp=host;<release>`, and hands each
  connection to the same session lifecycle as TCP (`ClientSessionRunner`,
  moved out of `TcpSocketService` unchanged). Steam failing never stops the
  TCP listener. (code-verified; observed ready in ~5 s)
* **Agent**: `RelayConnector` returns a `Stream` for either path; the rest of
  the agent is unchanged (`NetworkStream` → `Stream` in the signatures).
  `--steam <code> --steam-app <id> [--steam-game <exe>]`. Steam route limit
  20 s. Same frames, same protocol v9. (code-verified; synthetic: frames over
  a message stream split at arbitrary points)
* **Launcher**: Host window: "Also allow Steam" (default on, restarts the
  relay when flipped, locked while a game is launched), the code in large
  type, Steam's state in words, the Steam app. Status bar: JOIN THROUGH
  STEAM (code box, FIND FRIENDS, TEST CONNECTION, JOIN). Settings: the Steam
  app (advanced; 2429020 default, 480, 1771300). The launcher never loads
  Steam itself: the agent runs as a one-shot helper (`--steam-friends`,
  `--test-connection`), whose stderr is discarded. (code-verified; the window
  itself not looked at)
* **Join codes**: WO-120's 7-character friend code for 2429020; one extra
  letter for the other app ids (`-S` 480, `-R` 1771300) so a mismatch is
  caught before any Steam call. Own code → "That's this computer's own Steam
  code." (observed)
* **Friends who are hosting**: `--steam-friends` lists friends under the same
  app id whose rich presence says `host;…`, with a code built from their id.
  Ran live (0 hosting friends here). Only works when both use the same app id
  (Steam's rule). (observed; with a hosting friend: inconclusive)

### 2.2 Authority (the rule, recorded)

1. A ready client whose latest Position carries **HOST CLAIM (0x40)** is the
   authority, whatever order people connected in. The agent claims when the
   launcher started the relay for it (`--hosting`), or when `mp_shared_world`
   is on and its game is in a world of its own (latched, so a reload never
   drops it; cleared when the toggle goes off or it becomes a joiner). A
   joiner waits at the main menu, so it never claims.
2. Several claimants (two players each in their own world with the toggle
   on): rules 3 and 4 among them.
3. Exactly one loopback client (the relay host's own agent over TCP). **A
   Steam session is never loopback.**
4. Lowest ready id.

The relay clears 0x40 before the Ghost fan-out (receivers see exactly what
they saw before) and logs `MP-HOST-CLAIM` / `MP-AUTHORITY-OWNER
reason=declared-host`. Observed: real game as host connected second, took
authority from an earlier peer; synthetic WO-125 host (claims) + real joiner
(loopback both): `declared-host`. Relay tests: a Steam-shaped non-loopback
session connected first never takes authority from the loopback host; with
no loopback client, the claimant wins over the first-connected peer and the
authority goes back when the claim drops.

### 2.3 Fallback

* No Steam DLL / Steam not running / not logged in / init refused / bad code /
  own code / app mismatch / no route within 20 s → one plain line, Steam form:
  "Couldn't connect through Steam: <reason>. Try the host's address instead."
  (observed: no route, own code, app mismatch, bad code)
* The agent keeps retrying a no-route (the host may still be starting) and
  stops for a bad code, own code, app mismatch or a refused app; either way it
  stays up so the launcher can read why. The launcher offers **CONNECT BY
  ADDRESS** in the same message and restarts only the agent (the game and its
  injected DLL stay). (code-verified; the button itself not clicked)

## 3. Phase 2: plain errors, Test connection, mixed builds

* `ConnectionTrouble` + `PlainConnectionError` (in `KcdMp.Protocol`, shared by
  launcher and agent): refused, timed out, wrong address, host not running,
  version mismatch, protocol mismatch, app id mismatch, Steam not running,
  Steam not logged in, Steam unavailable, no route, bad code, own code, full,
  lost, unknown. One sentence + one next step each; a test asserts no
  exception-speak reaches the text. (synthetic)
* The agent publishes `GET /connection-status` (state, via, kind, message,
  next) for its whole lifetime (the IPC server now starts before the first
  connect); the raw detail goes to agent.log as `MP-CONN fail … detail="…"`
  (Steam text scrubbed). The launcher shows one line at the bottom of its
  window and no exception text in any message box. (observed JSON; code-verified UI)
* **Test connection**: a Handshake whose release field is
  `?connection-test`. Every relay since WO-110 R9 answers a release it doesn't
  run with 0x3D and closes, so a test never becomes a session (no id, no Name,
  no ghost). A 0.29.9 relay appends `\0ready=N;host=0|1` and logs `[test]`.
  Observed: direct, relay up with no host agent → "The host's multiplayer is
  running, but their game isn't connected yet."; with the host connected →
  "reachable … same version (0.29.9). Round trip 2 ms." (observed)
* **Mixed builds**: the relay still refuses a different release (0.28.3 rule);
  the joiner reads "The host runs version 0.28.3 and you run 0.29.9. Both
  players need the same version…"; the relay remembers the last refused
  release and the host's launcher (loopback-only `GET api/local/status`) shows
  "A player tried to join with version 0.28.3; you run 0.29.9…". (synthetic:
  relay test; the host-side banner not seen)

## 4. Phase 3: the leash recorder

### 4.1 What it writes

`mp_leash_trace on|off` (default off; the tester page turns it on at the host).
Once a second, CSV under `leash\` beside `agent.log`, rotated at 50 MB, carried
by the launcher's Report a bug bundle (newest 8).

* **Host** (`leash-host-<utc>.csv`): a `summary` row — both avatar positions,
  their distance, fps, per player town / interior / riding / fight / dialogue
  / cutscene / menu, NPC count, sample µs, entities walked — and one `npc` row
  per NPC within 200 m of either player: WUID, name, horse, position, distance
  to host and joiner, exists (0 = gone since the last second), hidden, active,
  physics present, `phys_awake` (non-living bodies only), `phys_sim` (living),
  living, flying, speed, brain state + reason mask, moved in the last second,
  in our NPC stream this second, driven, stream age.
* **Joiner** (`leash-joiner-<utc>.csv`): one `copy` row per NPC within 200 m:
  WUID, name, position, distance, exists, age of the host's last update
  (agent receipt) and the native stream age, suspended (brain state > 0),
  brain state + mask, driven, hidden, active, `phys_sim`, moved.
* Game coordinates and authored NPC names only; players are "host" and the
  joiner's relay id. Empty cell = unknown.

### 4.2 Where each signal comes from

| signal | source | evidence |
|---|---|---|
| hidden / active | `CEntity +0x08` bit 4 / bit 0 — what `CScriptBind_Entity::IsHidden`/`IsActive` read inline (disassembled from CryEntitySystem.dll this WO) | observed: 10/10 match Lua `IsHidden`/`IsActive` |
| brain suspended (ours / the game's) | WUID → AIObjectManager → the game's exported `ai_cast<C_IntelligentObject>` → state `+0x128`, reason mask `+0x129` (WO-107) | observed: `wh_ai_PauseNPC` → state 2, mask **0x08**; resume → 0 / 00. **Our pause's context bit is 0x08**; other bits are the game's own suspensions |
| physics present / living / flying / speed | `GetPhysics`; `pe_status_living` (vel, bFlying) | observed: a walking NPC 1.26–1.36 m/s |
| physics "awake" | `pe_status_awake` for non-living bodies. **For living entities it is always 0** (CryEngine's base `IsAwake` returns 0 and `CLivingEntity` doesn't override it; a walking NPC 5 m away read 0) | observed |
| physics simulated (living) | `pe_player_dynamics.bActive` via `GetParams` (vtable 0x28, between the verified `SetParams` 0x20 and `GetStatus` 0x30) | observed: values only 0/1; every visible active NPC 1; some hidden ones 0 — semantics beyond that (inconclusive) |
| moved in the last second | position delta > 5 cm vs the previous sample (agent) | synthetic + observed |
| in our NPC stream this second | the host agent's NpcState sends | code-verified; this session's host streamed none (no real joiner) |
| driven / stream age | npc_drive's per-name stream and bound puppets | code-verified (no host stream reached a joiner in this session) |
| town | the game's settlement / crime-district area labels (`in_settlement`) | observed (0 at the test spot) |
| interior | `I3DEngine::GetVisAreaFromPos != null`, the call `CScriptBind_System::IsPointIndoors` makes (disassembled from CryScriptSystem.dll: gEnv+0x08, vtable +0x528) | observed 0 outdoors; indoors (inconclusive: not visited) |
| AI proxy updating | no separate cheap flag found; the brain state is the closest | (inconclusive) |
| character animation LOD | no cheap read found this WO | (inconclusive) |

### 4.3 First look at the data (not the WO-128 analysis)

At a roadside caravan spot, 200 m: 34–40 NPCs out of ~36,700 walked entities;
**about 80 % hidden** (hidden=1, active=0), and **hidden NPCs keep moving**
(~40 % of hidden rows moved in the last second): hidden means "not drawn or
updated as an entity", not "stopped". Brain state 0 for all of them. (observed)

### 4.4 Cost

| | value | evidence |
|---|---|---|
| trace off | no timer, no pipe request, no per-frame work (the only additions on hot paths are `if (_leashOn)` checks in the agent) | code-verified |
| trace on, per sample (main thread) | mean 4.1–4.3 ms, max 5.3–7.8 ms (three 60 s windows) | observed |
| trace on, per frame (amortised) | 155–166 µs at ~26 fps | observed |

* The game ran at ~26 fps throughout: its background limiter (the window was
  not in front). I did not bring it forward (see progress, "Decisions"). At
  60 fps the same sample amortises to ≈70 µs/frame — inside the 0.2 ms target
  either way.
* The sample is one 4 ms hitch a second, almost all of it the full entity walk
  (36.7k entities; the existing native NPC scan does the same walk every 2 s).
  Fine for a test session; worth splitting across frames before it is ever
  on by default. (observed)
* ~6.6 KB/s on the host → a 50 MB file every ~2 h.

## 5. Gates

Relay 48 (6 new), client 325 (34 new: codes, error mapping, host-claim bit,
synthetic Steam stream, recorder format, rotation), Farkle 59, 24 Lua suites
(WO-127: 17), both static Lua checks, native build, launcher, synthpeer,
avatarpeer builds: green. Installer: see progress.

## 6. Carry-forwards

1. **Cross-network Steam** (inconclusive) — the WO-128 session runs WO-120's
   probe on both machines first (tester page step 2).
2. The launcher's new windows (Host Steam section, Join through Steam, Test
   connection, the fallback message) were checked as JSON/helper output only.
3. `phys_sim` semantics beyond "0/1, visible walkers 1"; indoor `interior=1`
   not visited.
4. The 4 ms per-sample hitch (split the walk across frames if the recorder is
   ever kept on).
5. Rich presence from the relay process while the game runs under the same
   app id: set and read back on this machine; what a friend's list shows is
   for the test session.
6. Final default app id: the maintainer, after WO-128.
