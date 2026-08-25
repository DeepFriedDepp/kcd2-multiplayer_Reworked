# WO-52 — does this engine's own multiplayer heritage still exist inside the game?

Worked 2026-08-25 (Fable 5). Investigation only — no code, no VERSION change,
no adoption of any external source. Evidence tiers used throughout:
**observed** (I ran it and saw the result), **read-but-unrendered** (present in
a file/binary I inspected, but its runtime behaviour was not exercised),
**inconclusive**. Never rounded up.

Scope note for the record: this examines a licensed copy of the game's own
shipped files under the project's standing interoperability-research premise,
plus publicly available related engine sources. Nothing external was adopted.

---

## Gate 1 — the headline verdict

> **Real, linked, initialised CryEngine multiplayer netcode IS present in
> KCD2 — the whole of it, client half and server half — and it is loaded into
> the process at every single startup. But it is wired to nothing this project
> cares about.** The replication architecture it implements moves data via
> `IGameObjectExtension::NetSerialize` aspects, and in KCD2 **exactly two
> classes in the entire game implement `NetSerialize`, both of them siege
> props.** No actor, no soul, no NPC, and not the player are CryEngine game
> objects at all.

So the honest answer to the WO's question is a **third thing**, not one of the
three offered options:

- Not "nothing found beyond script-level leftovers" — this is far more than the
  `Game03`/`Nanosuit` script boilerplate. It is a complete, compiled,
  self-identifying, *running* networking subsystem.
- Not "found but confirmed dead/stripped" — it is not stripped, and it is not
  unreachable. `CryNetwork.dll` is `LoadLibrary`'d and initialised on every
  launch (observed in the game's own log).
- **It is alive and it is empty.** A working transport with no cargo bindings
  for the entities that matter.

### What this means for WO-51's conclusion

WO-51 concluded that AI simulation is gated to proximity around one local
player and that no engine mechanism exists for multiple simultaneous players.
**That conclusion survives this investigation, for a reason WO-51 did not
have.** The engine-level machinery for multi-player entity replication really
is still here — but it replicates CryEngine `GameObject` extensions, and
Warhorse rebuilt actors/souls/NPCs on their own RTTR-reflected object model
(`wh::rpgmodule::CombatSoul` and friends, per `NATIVE-PLUGIN-findings.md`)
*outside* that system. Reactivating CryNetwork would not hand this project NPC
replication; it would hand it an empty pipe plus the job of writing every
aspect serializer for entity classes that were never designed to have one.

---

## Phase 1 — the evidence, in order

### 1. `CryNetwork.dll` ships and is loaded every launch — **observed**

The Modding Tools build ships `CryNetwork.dll`, 1,146,880 bytes, in
`Bin/Win64ReleaseSteamLTO_DLL/` alongside the other engine modules.

No binary statically imports it — checked the import tables of
`KingdomCome.exe`, `CryAction.dll`, `CrySystem.dll`, `CryEntitySystem.dll`,
`CryAISystem.dll`, `Framework.dll`, `WHGame.dll`, `EntityModule.dll` with
`dumpbin /DEPENDENTS`; `CryNetwork` appears in none of them. It is loaded
**dynamically**, the normal CryEngine module pattern: the only binary
containing the literal string `CryNetwork.dll` is `CrySystem.dll`, which also
contains `InitNetwork` and `Error creating Network`.

The game's own log (`KCD2Mod/kcd.log`, from a normal singleplayer session)
records it happening — **observed**:

```
Network initialization
Initializing CryNetwork...
Loading module CryNetwork.dll ...
Loading module CryNetwork.dll DONE
Initializing module CryNetwork ...
[net] Socket IO management: External [LobbyIDAddr], Internal [iocp]
network hostname: DESKTOP-043JIFV
  ip:192.168.1.89
[Network Version]: DEBUG PURE CLIENT
Initializing module CryNetwork done, MemUsage=2180Kb
Lobby initialization
```

It binds a socket-IO manager, resolves the host's name and LAN IP, reports
2.1 MB of live allocation, and is followed by a `Lobby initialization` line.
This is not a stub that fails and moves on.

Also observed in the same log, much later, during ordinary level load:

```
IContextEstablishTask 'InitActionMap.ClientActor': userId for user 0 is 'Jonasty'
```

`IContextEstablishTask` is CryAction's **context-establishment pipeline** — the
sequenced task list a CryEngine client/server runs to bring a game context up.
Singleplayer in this engine really does go through the netcode's own
establishment machinery.

### 2. The netcode is fully linked, not orphan strings — **observed** (Ghidra)

The project's proven identification method (a function containing its own
`__FUNCTION__`-style string, plus RTTI-labelled vftables) was applied via
Ghidra 12.1.3 headless. Scripts committed: `native/ghidra_scripts/
DumpWo52NetEvidence.java`, `DumpWo52ServerSide.java`.

`CryNetwork.dll` analyses to **3,428 functions**. Every net class string
resolves to a *referencing function*, not to dead data:

| Class | vftables | RTTI syms | Sample |
|---|---|---|---|
| `CServerContextView` | 11 | 47 | `CServerContextView::vftable @ 1800d6880` |
| `CClientContextView` | 10 | 42 | `…CClassJob<void,CClientContextView>::vftable @ 1800d3330` |
| `CNetChannel` | 17 | 77 | `CWorkQueue::CAtSyncItem<CNetChannel>::vftable @ 1800d6598` |
| `CNetContext` | 14 | 62 | — |
| `CNetContextState` | 11 | 55 | — |
| `CNetNub` | 6 | 22 | — |
| `CNetwork` | 3 | 11 | `CNetwork::vftable @ 1800dfe30` |
| `CEngineModule_CryNetwork` | 3 | 20 | `CEngineModule_CryNetwork::vftable @ 1800db878` |
| `CCTPEndpoint` | 3 | 11 | `CCTPEndpoint::CMessageSender::vftable @ 1800df958` |

**The server half is present.** `[Network Version]: DEBUG PURE CLIENT` in the
banner initially looked like it might mean server code was compiled out; it
does not — `CServerContextView` has 11 vftables and 47 RTTI symbols, more than
the client class. (What the banner literal actually denotes was not determined;
it is a single baked string. **Inconclusive** on its meaning, **observed** on
the class being real regardless.)

The full replication surface resolves to real functions with real bodies:

- Both context views implement the complete **32-aspect** matrix —
  `UpdateAspect0..31`, `PartialAspect0..31`, `SetAspectProfile0..31`, each its
  own function (e.g. `CServerContextView:UpdateAspect0` ← `FUN_180005980`).
- Object lifecycle: `BeginBindObject`, `BeginBindStaticObject`,
  `BeginBindPredictedObject`, `BeginUnbindObject`, `UnbindPredictedObject`,
  `ReconfigureObject`, `RemoveStaticObject`, `SetAuthority`.
- RMI: `RMI_ReliableOrdered`, `RMI_ReliableUnordered`, `RMI_UnreliableOrdered`,
  `RMI_Attachment` — on both views.
- Session: `AuthenticateChallenge`/`AuthenticateResponse`,
  `ClientEstablishedContext`, `SetNickname`, `ChangeState`, `FinishState`,
  `ForceNextState`, `UpdatePhysicsTime`.
- The game↔network bridge, with substantial bodies:
  `CNetContextState::FetchAndPropogateChangesFromGame` (`FUN_18003bfa0`, 2082
  bytes, 16 callees), `CNetContextState::PropogateChangesToGame`
  (`FUN_18003cc50`, 2041 bytes, 15 callees), `CNetContextState::UpdateAspectData`
  (`FUN_1800414e0`, 886 bytes), `CNetContext::SyncWithGame` (`FUN_1800384f0`,
  685 bytes).
- Breakage replication (`CBreakagePlayback`, `PerformBreak`,
  `DeclareBrokenProduct`), LAN discovery (`CLanQueryListener`), address
  resolution, the CTP protocol endpoint, a network thread.

`CreateNetwork` is exported by name (ordinal 48, RVA `0x5C280`) and is a real
234-byte function with 5 callees. The DLL exports 50 names total; the other 49
are boost `optional<bool>` template instantiations plus
`CryModuleGetMemoryInfo` and `ModuleInitISystem`.

**52 distinct `net_*` cvars** are present, including
`net_breakage_sync_entities`, `net_dump_object_state`,
`net_enable_voice_chat`, `net_dedi_scheduler_server_port`,
`net_lan_scanport_first`, `net_channelstats`, `net_enable_tfrc`.

Source paths leaked in the binary confirm Warhorse compiles this **from
source in their own build tree** — `d:\buildagent\work\7ffb7f119a855ecb\code\
CryEngine\CryNetwork\...` covering `Context\ContextView.cpp`,
`Context\PerformBreakage.cpp`, `Protocol\NewMessageQueue.cpp`,
`Services\CryLAN\LanQueryListener.cpp`, `Socket\SocketIOManagerSelect.cpp`,
`Http\SimpleHttpServer.cpp`, `Network.cpp`, `NetLog.cpp`. This is not a
prebuilt blob inherited and forgotten; it goes through their build agent.

### 3. The game-side layer in `CryAction` is present too — **read-but-unrendered**

`CryAction.dll` carries RTTI type descriptors for the full CryEngine
multiplayer game layer: `.?AVCGameContext@@`, `.?AVCGameServerNub@@`,
`.?AVCGameClientNub@@`, `.?AVCGameServerChannel@@`, `.?AVCGameClientChannel@@`,
`.?AVCActionGame@@`, `.?AVCScriptRMI@@`, `.?AVCGameObject@@`.

Self-identifying function strings `CCryAction::StartGameContext` and
`CCryAction::EndGameContext` are present, as is the source path
`…\code\CryEngine\CryAction\Network\CET_LevelLoading.cpp` and the runtime
error strings `No game rules`, `Cannot find rules %s in network class
registry`, `OnClient: No channel id`, alongside the callback names
`OnClientConnect` / `OnClientEnteredGame`.

The console commands are registered with their original help text —
`connect` ("Start a client and connect to a server"), `disconnect`,
`connect_repeatedly` ("Start a client and attempt to connect repeatedly to a
server") with `connect_repeatedly_num_attempts` /
`connect_repeatedly_time_between_attempts`, `map` ("Load a map"), `unload`,
plus `sv_bind`, `sv_port`, `sv_maxplayers`, `cl_serveraddr`, `sv_gamerules`,
`rcon_password`. **Read-but-unrendered** — the game was not running this
session, so none of these was executed. Their runtime reachability is
*unverified*, and the project's own rule applies: a string is not a working
command.

`sv_gamerules` **is** live: the log shows `singleplayer.cfg` (extracted from
`Engine/Engine.pak`, `Config/singleplayer.cfg`) setting `sv_gamerules=
SinglePlayer` at level load, alongside `ai_CompatibilityMode=crysis2` and a
commented-out `-- g_multiplayerDefault=0`. **Observed** in the log; the cfg
file itself read directly.

Retail is not different in kind. The monolithic `WHGame.dll`
(`Win64MasterMasterSteamPGO`, 89 MB) contains the same RTTI descriptors —
`.?AVCGameContext@@`, `.?AVCGameServerNub@@`, `.?AVCNetChannel@@`,
`.?AVCServerContextView@@` — with the same 130 `CClientContextView` / 90
`CServerContextView` string counts as the Modding Tools `CryNetwork.dll`. The
netcode is statically linked into the retail build too.

### 4. The Crysis-3 gamerules skeleton is still here — **read-but-unrendered**

Extending the known script-level leftovers: `WHGame.dll` retains
`GameRulesMPDamageHandling` (a literal Crysis 3 SDK class name) plus
`GameRules::ProcessLocalHit`, `ProcessQueuedLocalHits`, `GetSpawnLocation`,
`ResetReviveCycleTime`, `ResetGameStartTimer`, `SendAISignal`, `OnCollision`.

`Data/Scripts.pak` ships exactly three gamerules files:
`GameRules/SinglePlayer.lua` (header: a Crytek copyright, 2001-2004),
`GameRules/SinglePlayer.xml`, `GameRules/GameRulesUtils.lua`. The XML is the
Crysis-3 modular gamerules format, with a Warhorse comment left in:

```xml
<Mode name='SinglePlayer'>
  <!-- Modules want to be switched with SP versions at some point -->
  <StatsRecording class="StandardStatsRecording" />
  <Spawning class='SpawningBase' teamGame='1' teamSpawnsType='None' isHQSpawningCompatible='0' />
  <DamageHandling class='SPDamageHandling' > … </DamageHandling>
</Mode>
```

`SinglePlayer` is the **only** gamerules name in the binary — no
`InstantAction`, `TeamInstantAction`, `DeathMatch`, `PowerStruggle`,
`CaptureTheFlag`. The MP *modes* are gone; the MP *framework that would host
them* is not.

### 5. The decisive negative: nothing in the game is replicable — **observed**

CryNetwork's replication is aspect-based: an entity participates only if it has
a CryEngine `GameObject` with an `IGameObjectExtension` implementing
`NetSerialize(TSerialize, EEntityAspects, uint8, int)`. Aspects are then bound
via `BeginBindObject` and streamed by the context views.

Sweeping **every DLL** in the Modding Tools build for `?NetSerialize@` mangled
symbols returns, in total:

```
PlayerModule.dll:  ?NetSerialize@C_Battlement@playermodule@wh@@…
                   ?NetSerialize@C_StoneThrowingPile@playermodule@wh@@…
WHGame.dll:        (the same two, re-exported)
```

**Two classes. A castle battlement and a pile of throwable siege stones.**
Nothing else in the game — no actor, no soul, no NPC, no player, no horse, no
item — implements `NetSerialize` anywhere.

The reason is architectural, and it is visible in RTTI. The classes registered
as `CGameObjectExtensionHelper<…>` in the game modules are:

- `EntityModule`: `C_Hole`, `C_AnimObject`, `CProjectile`, `C_CatHolder`,
  `C_CatWaypoint`, `C_LedgeObject`, `C_LevelHolder`, `C_RandomEvent`,
  `C_WaterPuddle`, `C_RuntimePrefabAutoPhase`, `C_AlchemyTable`,
  `C_CutsceneData`, `C_PlayerWeapon`, `C_RandomEventPlace`, `C_LockBase`,
  `C_CarryItemPile`, `C_InteractiveObjectEx`, `C_DisappearingObject`,
  `C_TagPointWithScript`, `C_CutsceneHolder`, `C_DialogueHolder`
- `PlayerModule`: `C_Battlement`, `C_Smithery`, `C_StoneThrowingPile`
- `XGenAIModule`: `C_AreaUnionExtension`, `C_LinkableObjectExtension`
- `RPGModule`: **none**

Props, holders, waypoints, cutscene markers. `RPGModule` — the module that owns
`CombatSoul`, the object this project has spent WO-22 through WO-49 driving —
contains **zero** GameObject extensions. `CryEntitySystem.dll` contains no
network entity/proxy strings at all.

Warhorse kept the engine's networking subsystem and built the entire actor,
soul, NPC and player object model *outside* the system it replicates. The
netcode has no handle on anything this project needs to sync.

### 6. What a follow-up would have to do, and how it compares

If someone wanted to use this anyway, the work is:

1. **Bring a game context up.** `connect` / `sv_gamerules` / `map` exist as
   registered commands (read-but-unrendered). Whether the establishment task
   list completes for a second peer against a Warhorse level is entirely
   unverified. `SinglePlayer.xml`'s `Spawning class='SpawningBase'` and
   `Cannot find rules %s in network class registry` suggest a gamerules network
   class must resolve; whether `SinglePlayer` is registered as one is unknown.
2. **Write the missing half of the game.** Every entity to be replicated needs
   a CryEngine `GameObject`, an `IGameObjectExtension`, and a hand-written
   `NetSerialize` covering its aspects — for `CombatSoul`-backed NPCs that
   means bridging from RTTR-reflected properties into aspect serialization,
   per entity class, by hand, against a binary with no headers.
3. **Reconcile with the brain.** Even with replication working, the receiving
   client's NPC brain still runs (WO-49) and the engine still only simulates AI
   near the local player (WO-51). CryNetwork solves *transport and object
   binding*. It does not solve either of the two problems that actually block
   this project.

Compared to what already ships: WO-32's 50 ms NPC stream, WO-45–49's native
swing invocation, and the 0x12/0x30 name-addressed damage path already move
the state this project needs, over a transport that is understood, debuggable,
and version-stable. CryNetwork would replace a working transport with a
better-engineered one — and then demand the entity-binding work that is the
actual hard part, on top of the AI problems it does not touch.

**Recommendation: do not pursue reactivating CryNetwork.** Not because it is
dead — it is emphatically alive — but because the part of it that is alive is
the part this project already has, and the part this project lacks is the part
Warhorse never built.

**Genuinely valuable side-finding**, and the one thing here worth acting on:
`CryNetwork.dll` is a compiled, symbol-rich, RTTI-labelled CryEngine module
that is **already in the process at every launch**. If a future WO wants a
native transport, message queue, LAN discovery, or reliable-ordered channel
inside the game process rather than over the current external relay, this DLL
is 3,428 functions of exactly that, exported `CreateNetwork` included — usable
independently of whether anything is replicated through it. That is
**inconclusive as a plan** (nothing was invoked this session) but it is a real,
specific lead, and it is cheaper than the entity-binding work above.

---

## Phase 2 — Amazon Lumberyard / O3DE

Researched via web sources; every claim below traces to a URL. Nothing was
adopted or copied.

### Licensing — confirmed

O3DE is **Apache-2.0 OR MIT at the licensee's option** — confirmed verbatim in
[`LICENSE.txt`](https://github.com/o3de/o3de/blob/development/LICENSE.txt).
Reading and reuse are both permitted (third-party components, e.g. Qt/LGPLv3,
keep their own terms). This is the most permissive licensing situation of
anything examined in this WO.

### CryNetwork lineage — essentially none survives

Lumberyard **gutted CryNetwork's internals but kept its API surface**:
[`dev/Code/CryEngine/CryNetwork/`](https://github.com/aws/lumberyard/tree/master/dev/Code/CryEngine/CryNetwork)
has no `NetContext.cpp` and no `ContextView.cpp` — only `CryNetwork.cpp` and a
`GridMate/` subfolder.
[`NetworkGridMate.h`](https://github.com/aws/lumberyard/blob/master/dev/Code/CryEngine/CryNetwork/GridMate/NetworkGridMate.h)
implements CryEngine's `INetwork` over GridMate replicas, retaining
aspect-shaped hooks (`ChangedAspects(NetworkAspectType)`, legacy
`InvokeRMI`/`InvokeScriptRMI`, `typedef GridMate::Network CNetwork`) purely as
a compatibility shim. O3DE then retired even that: GridMate is listed in
[`RETIRED_CODE.md`](https://github.com/o3de/o3de/blob/development/RETIRED_CODE.md)
as replaced by AzNetworking + the Multiplayer Gem.

So the lineage is CryNetwork → GridMate → AzNetworking, and **O3DE's networking
carries approximately zero CryNetwork architecture**. It is a third-generation
rewrite, not a descendant. Useful as architecture, useless as a decode key for
KCD2's binary.

### How O3DE answers the multi-player relevancy problem

`NetBindComponent` makes an entity network-aware; roles are compile-time
enforced
([`MultiplayerTypes.h`](https://github.com/o3de/o3de/blob/development/Gems/Multiplayer/Code/Include/Multiplayer/MultiplayerTypes.h)):
`Authority` (full write, server, exactly one per entity), `Autonomous` (client,
predicts locally, gets corrected), `Server` (read-only proxy on another
server), `Client` (strictly read-only).

Per-connection relevancy is computed in
[`ServerToClientReplicationWindow.cpp`](https://github.com/o3de/o3de/blob/development/Gems/Multiplayer/Code/Source/ReplicationWindows/ServerToClientReplicationWindow.cpp):

1. A sphere of `sv_ClientAwarenessRadius` (default **500 m**) around that
   connection's controlled entity, queried against the visibility octree.
2. Priority is inverse-square distance: `1.0f / gatherDistanceSquared`.
3. Caps: `sv_MaxEntitiesToTrackReplication` 512 candidates (lowest priority
   evicted), send set throttled between `sv_MinEntitiesToReplicate` 128 and
   `sv_MaxEntitiesToReplicate` 256, dropping to the minimum when packet loss
   exceeds `sv_BadConnectionThreshold` (0.25).
4. The connection's own player entity and its hierarchy children bypass all of
   it, pinned at priority 1.0 with role `Autonomous`.
5. `INetworkEntityManager` keeps an "always relevant" set that bypasses
   relevancy entirely (the API docs warn it can cause bandwidth problems).

### Does anything here inform this project? Partly — and the honest answer is "less than hoped"

**The load-bearing point: replication windows filter what is *sent*, never what
is *simulated*.** An entity outside every client's window keeps ticking on the
server. O3DE's answer to "full-fidelity AI for multiple players in a large
world" is not an AI-relevancy system at all — it is **one authoritative
simulation that runs everything, with per-connection view windows on top**.
O3DE has no built-in AI/behaviour system whatsoever (navigation comes from the
Recast Navigation Gem, behaviour trees from the proprietary Kythera gem or
community gems; [issue #2043](https://github.com/o3de/o3de/issues/2043) is an
open request for non-proprietary AI features). There is no AI-LOD mechanism to
borrow, because the architecture removes the need for one by assumption.

KCD2 cannot make that assumption: each peer runs a full retail game that
simulates AI near its own player and cannot be demoted to read-only. **O3DE
designed this project's problem away rather than solving it**, which means it
offers no answer to WO-51's core finding.

Two things do transfer, both to the *streaming* half rather than the authority
half:

1. **The relevancy recipe is a better template than a flat stream.** Sphere
   around each peer's player, inverse-square-distance priority ordering, a hard
   candidate cap with lowest-priority eviction, a send cap that *shrinks under
   measured packet loss*, and an explicit always-relevant escape hatch. This
   project currently tracks ≤5 NPCs within 30 m of the authority's own player
   at a flat 50 ms (WO-51, `kdcmp.lua:1917`). Distance-priority ordering and
   loss-adaptive throttling are cheap, well-proven refinements — and they are
   *ideas*, requiring no code adoption and therefore no licensing question.
2. **The role vocabulary is worth borrowing for clarity.**
   Authority / Autonomous / Client maps cleanly onto owning peer / local player
   / remote puppet, and O3DE's insistence that Authority is unique per entity
   names precisely the invariant this project cannot enforce.

Everything else is interesting but inapplicable.

---

## Phase 3 — the wider CryEngine family

Researched via web sources. Triage below. Nothing adopted; anything marked
"worth asking" is a request for the user to decide, not a decision.

### Worth asking permission to use / study

**1. `github.com/MergHQ/CRYENGINE` — full public CryNetwork + CryAction source.
Highest-value finding of Phases 2–3.**

The official `CRYTEK/CRYENGINE` repo was removed in May 2022 (5.7 LTS is now
behind a cryengine.com account), but complete public forks survive. This fork
(`release` branch, ~CryEngine 5.x/2016, 2,079 forks, pushed 2024) was confirmed
to contain:

- `Code/CryEngine/CryNetwork/Context/` — `NetContext.cpp/h`,
  `NetContextState.cpp/h`, `ServerContextView.cpp/h`, `ClientContextView.cpp/h`,
  `ContextView.cpp/h`
- `Code/CryEngine/CryAction/Network/` — `GameContext.cpp`, `GameServerNub.cpp`,
  `GameClientNub.cpp`, `GameServerChannel.cpp`

These are **the exact classes named in Phase 1's Ghidra output**. CryEngine 5.0
was a renumbered continuation of 3.8, and KCD's Warhorse fork branched from
~3.8, so this is the closest legally-readable relative of the compiled DLL in
`Bin/`. As a **decode key** it would turn Ghidra's `FUN_18003bfa0` into
`CNetContextState::FetchAndPropogateChangesFromGame` with known struct layouts
and call order — the same leverage the RTTR export table gave WO-6.

**Licensing caution, and it is a real one.** The CRYENGINE License Agreement
(cryengine.com/ce-terms) prohibits redistributing or sublicensing engine code
and prohibits combining CRYENGINE code with other engines. It does not address
modding third-party CryEngine games. **Reading it as a reference is one thing;
copying any of it into this repo is not permitted.** Recommendation: if a
future WO does deeper CryNetwork archaeology, ask the user before *reading*,
and treat "adopt nothing" as absolute regardless of the answer.

Given Phase 1's verdict, this matters much less than it would have if the
netcode had turned out usable. Filed as a standing asset, not a next step.

**2. `github.com/crymp-net/client-server` (CryMP) — the closest living analogue
to this project.**

Active (pushed Aug 2026), crymp.org. Ships custom `CryMP-Client32/64.exe` that
replaces the Crysis executables and reimplements CrySystem, CryAction, CryGame,
CryScriptSystem, Cry3DEngine, CryPhysics, CrySoundSystem and the launcher —
but **notably has not reimplemented CryNetwork**; they still drive the
original `CryNetwork.dll` from outside. That is exactly the position this
project would be in. **No license file in the repo.** The same org hosts
`gamespy-emulator` (GPLv2 — the master-server layer Crysis-era CryNetwork
expects) and `master-server-v2`.

Worth studying for how a custom host process boots retail CryEngine DLLs and
drives stock netcode (connect flow, server browser, RMI usage). Worth asking
before anything more than reading, because the license is unstated.

### Interesting but not worth pursuing

**`github.com/MikeCrossley/Crysis-Co-op`** — the closest conceptual prior art
to "reactivate the engine's own netcode in a singleplayer campaign". Its
documented trick: because the game disables AI in MP, the mod **makes the
engine believe it is in singleplayer on the server, loads the AI systems, then
reverts to the MP state**, and networks AI over the stock netcode. Dead since
2018, 20 stars, no license, necessarily SDK-derived. Conceptually striking, and
it is the mirror image of this project's problem (they had MP and needed AI; we
have AI and need MP) — but it applies to a game whose actors *are* GameObject
extensions with real `NetSerialize` implementations. Phase 1 shows KCD2's are
not, so the trick has nothing to attach to. Reference only.

**`github.com/ccomrade/c1-launcher`** — 480 stars, active Jan 2026. Open-source
replacement EXEs for Crysis/Wars/Warhead: reimplements the engine-init path,
applies in-memory patches to engine DLLs, and includes a headless/dedicated
server launcher. The technique class (native launcher, in-memory patching) is
**already known and independently implemented** by this project. Its
dedicated-server bootstrap — bringing a CryEngine server up with no renderer —
is the only genuinely new angle, and it is only interesting if Phase 1's
verdict is ever revisited.

**KCD1 multiplayer mod (2018)** — the only direct prior art on this game
family. A small team used reverse engineering plus Lua injection, got players
into each other's sessions, but **only horses rendered; player models were
invisible and dismounting did not work**. No repo was ever published; the
project vanished. This is the route this project already started on and
surpassed, and there is no evidence anyone touched native netcode. Notable
conclusion: **no one has ever reactivated CryNetwork in KCD1 or KCD2** — as far
as public record goes, this session's Phase 1 is the first look.

### Nothing new found

**Warface** — the public reverse-engineering work (Levak's gist,
`IvanyGames/IgEmulator`, `highattack30/warface-emulator`) targets the
out-of-game **XMPP lobby and master server**, not in-game CryEngine netcode,
which Mail.ru heavily customised and which nobody has published on. Not
applicable.

**MechWarrior: Living Legends** — alive and Microsoft-sanctioned, but built on
the licensed SDK with no public source; it merely consumes c1-launcher
binaries. **Hunt: Showdown / Miscreated / Wolcen** — no public RE communities
with reusable netcode material; searches surfaced match-data scrapers and
closed cheat-development, nothing usable. Not applicable.

---

## Evidence status summary

| Claim | Tier |
|---|---|
| `CryNetwork.dll` ships in Modding Tools build, 1.15 MB | observed |
| It is dynamically loaded and initialised every launch | observed (kcd.log) |
| It binds sockets, resolves LAN IP, allocates 2.1 MB | observed (kcd.log) |
| `IContextEstablishTask` runs during singleplayer level load | observed (kcd.log) |
| 3,428 functions; client + server context views fully linked with vftables/RTTI | observed (Ghidra) |
| 32-aspect matrix, RMI, bind/unbind, authority, game↔net bridge all real functions | observed (Ghidra) |
| `CreateNetwork` exported, 234 bytes, 5 callees | observed (Ghidra) |
| Netcode compiled from source in Warhorse's build tree | observed (leaked paths) |
| CryAction retains `CGameContext`/`CGameServerNub`/`CScriptRMI` RTTI | read-but-unrendered |
| `connect`/`map`/`sv_port`/`sv_maxplayers` registered as console commands | read-but-unrendered |
| Those commands actually work at runtime | **unverified** |
| `sv_gamerules=SinglePlayer` set from `singleplayer.cfg` at level load | observed (kcd.log + extracted cfg) |
| Retail `WHGame.dll` contains the same netcode statically linked | read-but-unrendered |
| Only `C_Battlement` and `C_StoneThrowingPile` implement `NetSerialize` | observed (full-binary sweep) |
| `RPGModule` has zero GameObject extensions | observed (RTTI sweep) |
| `GameRulesMPDamageHandling` + Crysis-3 gamerules XML present | read-but-unrendered |
| O3DE licensing, relevancy algorithm, role model, GridMate lineage | read (web, cited) |
| CRYENGINE fork contains matching CryNetwork/CryAction source | read (web, cited) — not opened as source |
| CryMP / Crysis Co-op / c1-launcher / KCD1 findings | read (web, cited) |

## What was not done

- Nothing was invoked at runtime — the game was not running this session, so no
  console command, no `CreateNetwork` call, no context establishment was
  exercised. Every "it would take" statement above is a plan, not a result.
- No external source was fetched into this repo, read as source, or adopted.
- No `VERSION`, installer, or shipping code change.
