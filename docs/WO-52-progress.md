# WO-52 progress

## 2026-08-25 (Fable 5) — CryEngine multiplayer heritage investigation

Investigation only. No code, no `VERSION`, no installer, no adoption of any
external source. Deliverable: `docs/WO-52-findings.md`.

### Phase 1 — the real answer

**Verdict: real, linked, running CryEngine multiplayer netcode is present —
and it is wired to nothing this project needs.**

- `CryNetwork.dll` (1,146,880 bytes) ships in the Modding Tools build. No
  binary statically imports it; `CrySystem.dll` loads it dynamically
  (`InitNetwork`, the only binary containing the string `CryNetwork.dll`).
- `KCD2Mod/kcd.log` from an ordinary singleplayer session **observes** the
  full init: module load, socket-IO manager bind, LAN IP resolution,
  `[Network Version]: DEBUG PURE CLIENT`, 2180 Kb live, then `Lobby
  initialization`. Later in the same log: `IContextEstablishTask
  'InitActionMap.ClientActor'` — CryAction's context-establishment pipeline
  runs in singleplayer.
- Ghidra 12.1.3 headless (scripts committed: `native/ghidra_scripts/
  DumpWo52NetEvidence.java`, `DumpWo52ServerSide.java`) resolves **3,428
  functions**. Every net class string traces to a referencing function.
  Vftable/RTTI counts: `CServerContextView` 11/47, `CClientContextView` 10/42,
  `CNetChannel` 17/77, `CNetContext` 14/62, `CNetContextState` 11/55,
  `CNetNub` 6/22, `CNetwork` 3/11, `CCTPEndpoint` 3/11.
- **The server half is NOT compiled out.** `PURE CLIENT` in the banner looked
  like it might mean that; `CServerContextView::vftable @ 1800d6880` with 47
  RTTI symbols says otherwise. What the banner literal denotes is
  inconclusive; the class being real is observed.
- Full replication surface is real code: 32-aspect matrix
  (`UpdateAspect0..31`, `PartialAspect0..31`, `SetAspectProfile0..31` on both
  views), RMI (reliable ordered/unordered, unreliable ordered, attachment),
  bind/unbind/reconfigure/SetAuthority, authenticate/nickname/state machine,
  breakage replication, LAN query listener, CTP endpoint, network thread.
  `CNetContextState::FetchAndPropogateChangesFromGame` = `FUN_18003bfa0`,
  2082 bytes, 16 callees; `PropogateChangesToGame` = `FUN_18003cc50`, 2041
  bytes. `CreateNetwork` exported, RVA 0x5C280, 234 bytes, 5 callees.
  52 distinct `net_*` cvars.
- Warhorse **compiles it from source** — leaked paths
  `d:\buildagent\work\7ffb7f119a855ecb\code\CryEngine\CryNetwork\…` covering
  ContextView.cpp, PerformBreakage.cpp, NewMessageQueue.cpp,
  LanQueryListener.cpp, SocketIOManagerSelect.cpp, SimpleHttpServer.cpp.
- `CryAction.dll` retains the game-side layer's RTTI (`CGameContext`,
  `CGameServerNub`, `CGameClientNub`, `CGameServerChannel`,
  `CGameClientChannel`, `CActionGame`, `CScriptRMI`), the self-identifying
  `CCryAction::StartGameContext`/`EndGameContext`, the source path
  `…\CryAction\Network\CET_LevelLoading.cpp`, and the registered console
  commands `connect` / `connect_repeatedly` / `disconnect` / `map` / `unload`
  with `sv_bind` / `sv_port` / `sv_maxplayers` / `cl_serveraddr` /
  `sv_gamerules` / `rcon_password`. **Read-but-unrendered — none executed;
  runtime reachability unverified.**
- Retail is the same in kind: `WHGame.dll` (89 MB) carries
  `.?AVCServerContextView@@`, `.?AVCNetChannel@@`, `.?AVCGameContext@@`,
  `.?AVCGameServerNub@@` — statically linked.
- Crysis-3 leftovers extend beyond scripts: `GameRulesMPDamageHandling`,
  `GameRules::ProcessLocalHit`, `GetSpawnLocation`, `ResetReviveCycleTime`.
  `Scripts.pak` ships only `GameRules/SinglePlayer.{lua,xml}` +
  `GameRulesUtils.lua`; the XML is Crysis-3 modular gamerules format with a
  Warhorse "Modules want to be switched with SP versions at some point"
  comment. `SinglePlayer` is the only gamerules name in the binary.
- **The decisive negative.** CryNetwork replicates
  `IGameObjectExtension::NetSerialize` aspects. A sweep of every DLL for
  `?NetSerialize@` returns exactly **two** classes game-wide:
  `wh::playermodule::C_Battlement` and `wh::playermodule::C_StoneThrowingPile`
  — siege props. RTTI sweep of `CGameObjectExtensionHelper<…>` registrations:
  `EntityModule` has 21 (holes, waypoints, cutscene holders, locks, puddles),
  `PlayerModule` 3, `XGenAIModule` 2, **`RPGModule` zero**. Actors, souls,
  NPCs and the player are not CryEngine game objects at all — Warhorse built
  them on the RTTR-reflected model documented in `NATIVE-PLUGIN-findings.md`,
  outside the system CryNetwork replicates.

**Consequence: WO-51's conclusion stands**, now with a mechanism. The engine
does still contain multi-player replication machinery; it just has no handle
on any entity this project syncs. Recommendation in the findings doc: do not
pursue reactivating CryNetwork. Using it would mean hand-writing aspect
serializers for every entity class against a headerless binary, and would
still leave both WO-51 blockers (unsuppressed puppet brain, proximity-gated AI
simulation) untouched — to replace a transport that already works.

**Side-lead worth keeping:** `CryNetwork.dll` is 3,428 functions of
symbol-rich, RTTI-labelled, already-in-process networking (reliable ordered
channels, message queue, LAN discovery, exported `CreateNetwork`). If a future
WO wants a native in-process transport instead of the external relay, this is
a real candidate — independent of whether anything is replicated through it.
Inconclusive as a plan; nothing was invoked.

### Phase 2 — O3DE / Lumberyard

- Licensing confirmed: **Apache-2.0 OR MIT**, licensee's choice
  (`LICENSE.txt`). Most permissive of anything in this WO.
- CryNetwork lineage: essentially none survives. Lumberyard deleted
  `NetContext.cpp`/`ContextView.cpp` and kept only a GridMate shim behind
  CryEngine's `INetwork`; O3DE retired GridMate too (`RETIRED_CODE.md`) for
  AzNetworking + Multiplayer Gem. Third-generation rewrite, not a descendant
  — useless as a decode key for KCD2's binary.
- Relevancy algorithm (`ServerToClientReplicationWindow.cpp`): 500 m sphere
  around each connection's controlled entity via the visibility octree,
  inverse-square-distance priority, 512-candidate track cap with
  lowest-priority eviction, send set throttled 128–256 and dropped to the
  minimum above 0.25 packet loss, own player + hierarchy pinned at 1.0 as
  `Autonomous`, plus an always-relevant bypass set.
- Roles (`MultiplayerTypes.h`): Authority / Autonomous / Server / Client,
  compile-time enforced, **exactly one Authority per entity, always on a
  server**.
- **Honest assessment: less applicable than hoped.** Replication windows
  filter what is *sent*, never what is *simulated* — O3DE's answer to
  full-fidelity AI for many players is one authoritative simulation running
  everything, with per-connection view windows on top. O3DE has no built-in AI
  system at all (Recast gem for nav, proprietary Kythera for behaviour, issue
  #2043 open). There is no AI-LOD mechanism to borrow; the architecture
  designs this project's problem away rather than solving it.
- What does transfer, both to the streaming half only, and both as *ideas*
  needing no adoption: (1) the relevancy recipe — distance-priority ordering,
  hard caps with eviction, loss-adaptive send throttling, always-relevant
  escape hatch — is a better template than the current flat ≤5-NPC / 30 m /
  50 ms stream; (2) Authority/Autonomous/Client is useful vocabulary for
  per-NPC ownership, and its one-Authority-per-entity invariant names exactly
  what this project cannot enforce.

### Phase 3 — wider CryEngine family, prioritized

**Worth asking permission to use / study**

1. `github.com/MergHQ/CRYENGINE` (`release`, ~5.x) — full public
   `CryNetwork/Context/` (NetContext, NetContextState, Server/ClientContextView)
   and `CryAction/Network/` (GameContext, GameServerNub, GameClientNub,
   GameServerChannel). The exact classes Phase 1's Ghidra output names; the
   closest legally-readable relative of KCD2's compiled DLL. Official
   CRYTEK repo was removed May 2022; forks survive (2,079 of them).
   **License caution:** CRYENGINE terms forbid redistributing/sublicensing
   engine code and combining it with other engines. Read-only reference at
   most; ask the user before even reading; adopt nothing regardless. Filed as
   a standing asset — Phase 1's verdict makes it much less urgent.
2. `github.com/crymp-net/client-server` (CryMP, active Aug 2026) — custom
   client EXE reimplementing CrySystem/CryAction/CryGame/etc. but **not**
   CryNetwork; still drives the original `CryNetwork.dll` from outside, i.e.
   exactly this project's position. **No license file.** Org also hosts
   `gamespy-emulator` (GPLv2).

**Interesting but not worth pursuing**

- `MikeCrossley/Crysis-Co-op` — the closest conceptual prior art: makes the
  engine believe it is in singleplayer on the server so AI systems load, then
  reverts to MP state and networks AI over stock netcode. Dead 2018, no
  license, SDK-derived. Nothing to attach to here — Crysis actors *are*
  GameObject extensions with real `NetSerialize`; KCD2's are not.
- `ccomrade/c1-launcher` — 480 stars, active. Native launcher + in-memory DLL
  patching (technique class already independently implemented here); its
  renderer-less dedicated-server bootstrap is the only new angle, and only
  matters if Phase 1's verdict is revisited.
- KCD1 multiplayer mod (2018) — RE + Lua injection, players synced but only
  horses rendered, no repo ever published, project vanished. The route this
  project already surpassed. **Notable: no public record of anyone ever
  reactivating CryNetwork in KCD1 or KCD2 — this session appears to be the
  first look.**

**Nothing new found**

- Warface: public RE targets the XMPP lobby / master server, not in-game
  netcode (Mail.ru heavily customised, nothing published). Not applicable.
- MWLL (licensed SDK, no source), Hunt / Miscreated / Wolcen (no public RE
  communities with reusable material). Not applicable.

### Housekeeping

- New: `docs/WO-52-findings.md`, `docs/WO-52-progress.md`,
  `native/ghidra_scripts/DumpWo52NetEvidence.java`,
  `native/ghidra_scripts/DumpWo52ServerSide.java`.
- Game was not running this session — nothing was invoked at runtime. Every
  "what it would take" statement is a plan, not a result.
- No external source fetched into the repo, read as source, or adopted.
