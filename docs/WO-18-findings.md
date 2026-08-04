# WO-18 — assessment of `Jefferson25625/kcd2-exports`

Investigated 2026-08-04. **Pure investigation. Nothing merged, ported or
vendored into this repo.**

## Licensing — read this before acting on anything below

`https://github.com/Jefferson25625/kcd2-exports`, single commit
`94861e2` (2026-08-01, author "J3fferson"), **no LICENSE file — confirmed by
direct check.** Same rule as marczukmichal's original repo: clone and study
freely, **adopt nothing without explicit permission from Jefferson25625.**
Several items below are worth asking for. None of them may be used until asked.

## What the repo actually contains

The brief described a `KcdMP.Client` / `KcdMP.GUI` / `KcdMP.Mod` / Server /
Master split with CefSharp, LiteNetLib and MessagePack, and test plans citing
611 tests. **None of that code is in the repo.**

| | Count |
|---|---|
| `.md` | 297 |
| `.hh` / `.h` / `.hpp` (mostly a vendored `webview` single-header tree) | 112 |
| `.cpp` | 30 |
| `.csv` | 14 |
| **`.cs` / `.csproj`** | **0** |

So the C# stack, the 611 tests, `RemoteConsoleClient.cs`, `RemoteConsoleBridge.cs`
and the LiteNetLib/MessagePack usage exist **only as prose**. The one real
codebase present is `KCDRewrite/` — a *newer, different* native C++ project
(§P2). Every claim about the C# generation below is assessed from documentation
alone, and is marked as such.

## Method

Their status lines were read literally. Where a claim was load-bearing for this
project, it was checked against **this machine's own game installs and, for P0,
against a live retail game process** — not taken from their prose.

---

# P0 — the retail HTTP API claim

**Verdict: split. The `:1403` reflection API claim is theoretical and, on the
evidence, wrong. The retail RemoteConsole claim is real, and I verified it here
— it is the single most valuable thing in the repo.**

## P0a — `:1403` in retail: theoretical, and independently disproved

`retail_http_api_feasibility.md` (2026-05-17) is exactly what it says on the
tin: a feasibility analysis, verdict *"WAHRSCHEINLICH JA — ~70-80%"*, ending
with a written but **never-executed** 4-step test procedure ("Test-Aufwand: ~2
Minuten"). No result is recorded anywhere in the repo. Their own
`retail_lua_api_availability.md`, written the *same day*, concludes *"wir
brauchen :1403 NICHT"* — they moved on rather than running it. **Never promoted
from theory.**

Their binary evidence is real but was misread. Checked here against
`D:\SteamLibrary\...\KingdomComeDeliverance2\Bin\Win64MasterMasterSteamPGO\WHGame.dll`:

| String | Retail | Meaning |
|---|---|---|
| `http_startserver` / `http_stopserver` / `http_password` | **present** | their finding, reproduced |
| `SimpleHttpServerListener.cpp`, `HTTP: server successfully started`, `methodCall`, `Authorization Failed`, `index.mhtml`, `/Libs/CryHttp` | **present** | CryAction's stock `SimpleHttpServer` |
| `/api/`, `menu.json`, `Received http GET request`, `ModuleHttpServerListenerManager.cpp`, `navmenu`, `menuFromJson`, `static/style.css`, `Updating methods is not implemented`, `Failed to create variant of type` | **all absent** | Warhorse's `/api/` reflection browser |

Those `/api/` strings live in **`Framework.dll`** in the Modding Tools build
(`wh::framework::C_ModuleHttpServerListenerManager`, source path
`code/game/framework/Http/ModuleHttpServerListenerManager.cpp`). Retail keeps
the *engine's* HTTP server and drops the *game's* reflection listener. The two
were conflated.

**Then I ran their test.** Launched retail (v1.5.6) with `-devmode`, connected
to RemoteConsole, sent `http_startserver`:

```
kcd.log:   HTTP: server successfully started
netstat:   TCP 0.0.0.0:80 LISTENING 4464      <- port 80, not 1403
GET /                            -> 400 Bad Request
GET /api?depth=0                 -> 400 Bad Request
GET /api/rpg/SoulList/PlayerSoul -> 400 Bad Request
GET /index.mhtml                 -> 404 Not Found
GET :1403/api?depth=0            -> connection refused
```

The command works. It starts CryAction's stock server on **port 80**, which
serves no `/api/` and has no static files. Their risk table rated "HTTP server
starts but endpoints 404" as *"Sehr unwahrscheinlich"*. That is what happened.

**This project's PROJECT-STATE §4 "Retail: no reflection REST API" is
CONFIRMED**, and now on better evidence than before — the old basis was a
single absent class-name string, which in a monolithic LTO build proves little
on its own. Thirteen distinctive strings and a live 400 do.

## P0b — RemoteConsole `:4600` on retail: REAL, verified here

This is the claim the brief did not foreground, and it is the one that matters.
`retail_remote_console_plan.md` asserts *"Verified: Port 4600 ist offen in
Retail"*. **Independently reproduced on this machine, 2026-08-04, retail 1.5.6:**

```
KingdomCome.exe -devmode
  TCP 0.0.0.0:4600 LISTENING
  log_EnableRemoteConsole = 1 [DUMPTODISK]        <- default ON
```

Their wire format is correct: `<ascii-digit type><utf8 payload><0x00>`, `'5'` =
ConsoleCommand outbound, `'1'` banner and `'6'` autocomplete inbound. Observed
verbatim.

**Console commands execute.** `version` → version block in `kcd.log`.
CVar reads work (`wh_sys_version = 1.5.6`, `http_password = password []`).

### The correction that matters — `#` Lua **does** work

`retail_remote_console_plan.md` states, under **Verified**:

> `#`-Prefix für Lua-Eval funktioniert **nicht** via RC — nur in In-Game-Console.

**That is wrong on 1.5.6.** Their whole `rc_rpc.lua` / `AddCCommand` /
`sv_servername`-hex-encoding architecture exists to work around a wall that
isn't there. Measured here:

```
5#System.LogAlways("KCDMP-PROBE-HASH")
  kcd.log: KCDMP-PROBE-HASH

5#System.LogAlways("[KCDMP-ENV] player="..tostring(player~=nil)..." ...)
  kcd.log: [KCDMP-ENV] player=false Game=true System=true Script=true UIAction=true

5#local t={} for i=1,40 do t[#t+1]=tostring(i*7) end System.LogAlways("[KCDMP-BATCH] "..table.concat(t,","))
  kcd.log: [KCDMP-BATCH] 7,14,21,...,280
```

- Arbitrary multi-statement Lua, loops, tables, concat — all execute.
- `Game`, `System`, `Script`, `UIAction` are live **at the main menu**, with no
  save loaded and no mod installed.
- Bare (non-`#`) Lua is rejected: `[Warning] Unknown command: System.LogAlways(...)`.
  The `#` prefix is what routes to the Lua VM — which is presumably how they
  concluded it didn't work.

### Round-trip latency, measured

RC send → `#…System.LogAlways` → line visible via `kcd.log` tail, n=8:

```
min 17 ms   avg 30.5 ms   max 42 ms
```

Compare this project's Modding-Tools `:1403` path: ~37 ms p50 warm, ~2.15 s
first call. **The retail RC path is as fast or faster, with no cold-start
penalty.**

Outbound is still log-tail only: no `'2'` LogMessage frames arrived even after
`log_Verbosity 4` + `log_WriteToFileVerbosity 4`. Their Phase-4 open question
gets a negative answer.

### What this would and would not buy this project

**Would.** This is a drop-in replacement for the inbound half of this project's
transport (`batched ExecuteString`), on **retail**, at equal latency, reachable
**from the main menu** — which `:1403` never was. The outbound half (log tail)
is unchanged and already works. That removes the separate 5 GB Modding Tools
Steam entry as an install requirement **for every Lua-layer feature**: presence,
ghosts, dice UI, interaction sessions, appearance broadcast.

**Would not.** The native plugin still needs Modding Tools. `KCDMP.dll` drives
the object model through the RTTR runtime **exported by name from
`CrySystem.dll`** — retail is monolithic and exports nothing, so shared combat
(`CombatSoul::TakeDamage`), the faction work and the whole reflection ABI have
no retail equivalent without hand-locating RTTR internals. **Retail support
would be a two-tier product: Lua features everywhere, shared combat on Modding
Tools only.** That is a product decision, not a technical one, and it is yours.

### Verified here vs. still unverified

| Claim | Status |
|---|---|
| Retail opens `:4600` with `-devmode` | **verified here**, 1.5.6 |
| RC executes console commands | **verified here** |
| RC executes arbitrary `#`-prefixed Lua | **verified here** (contradicts their doc) |
| Lua globals live at main menu, no mod | **verified here** |
| ~30 ms round trip via log tail | **measured here** |
| `:1403` reachable in retail | **disproved here** |
| `player` object usable in-world on retail | **not tested here** — needs a loaded save. Their `retail_lua_api_availability.md` documents it with concrete values (`GetWorldPos` → `121.148,2041.56,56.0592` etc.); plausible but unconfirmed by us |
| This project's `kdcmp.lua` pak loads on retail | **not tested.** Their `EngineFindings.md` §1 says mod Lua only initialises on retail with `-devmode` |
| RC works without `-devmode` | **not tested** |

**Security note, unprompted:** `:4600` binds `0.0.0.0`, not loopback, and
`http_startserver` bound port 80 on `0.0.0.0` too. Both are unauthenticated
remote-code-execution surfaces on the LAN by default. If this project ever ships
an RC-based path, say so in `LAUNCHING.md` and consider `rcon_password`.

---

# P1 — face / appearance

**Verdict: contradicts a closed finding. Real new capability, through a channel
this project never examined.**

This project's closed finding — hairstyle, face and beard are "not reflected
anywhere", `Soul.Archetype` exposes only `Id`/`Name`/`Gender`/`Race` — is about
the **reflection read surface**. It is still true and they agree with it
("Soul holds save-state, not visuals", live RE 2026-05-22). They found the lever
somewhere else entirely.

**The lever is the `guidSharedSoulId` spawn property.** Bind a `class="NPC"` /
`"NPC_Female"` entity to a real soul GUID at spawn and the engine builds the
whole distinct head + body + hair + beard automatically. Cross-checked against
shipping content (`npcTest_10.xml`, `BasicAITable.lua:16`), and **I confirmed
`guidSharedSoulId` appears in this machine's own shipped level data**
(`KCD2Mod\Data\Levels\kutnohorsko\...\dryingRack_cow\_common.lyr`). They ship a
curated 48-soul roster and hash a player name to a stable pick.

Two things raise my confidence in `AppearanceApi.md` specifically:

- It **retracts its own earlier table in place**: the 2026-05-22 claim that
  `hair`/`beard`/`bodyType` spawn props produce visible variation is marked
  *"WRONG"*, with the disproof (zero occurrences across a full pakdump) and the
  correct explanation (the engine was assigning a random default soul per
  respawn). That is this project's own methodology.
- `FaceMatrixTestPlan.md` records a *failure list* — Phase A: "7 Ausfälle: Pos
  4,5,11,12,14,15,16" — and an explicitly **unrecorded** result ("Armor:
  Ergebnis nicht erfasst (User-Neustart)"). Tests that were actually run look
  like this. Confident prose does not.

Second channel, weaker evidence: `entity:CreateSkinAttachment(slot, skin, mtl)`
+ `ForceCharacterUpdate` — render-level CA_SKIN attachment that bypasses the
retail cheat gate on inventory equips. **Verified by them for hair only**
(`KcdMP_SetGhostHair`); clothing and heads are a written-but-unrun test plan
(`CharSystemDecisionPlan.md`). Treat as promising, not proven.

Their honest limits, which this project should inherit rather than rediscover:
`Barber.Create()` returns nil for any non-player actor; STORM rules evaluate at
load only, never for runtime spawns; `player:LoadCharacter(0, cdf)` on the local
player crashes within seconds; female heads don't load on male skeletons via
STORM; `EquipClothingPreset` / `EquipInventoryItem` are **silent no-ops** on
non-player actors on retail (`master_master` cheat gate) — no error, no return,
no log line.

**Fit:** high. This project already ships appearance sync (WO-9, `0x1A`/`0x1B`)
that mirrors equipped items onto one hardcoded outfit. `guidSharedSoulId` would
give distinct *faces* per player, which WO-9 cannot do, and it is a spawn-time
property change in `KCD2MP_SpawnGhost` — not a new subsystem.

---

# P2 — networking: LiteNetLib + MessagePack vs. this project's stack

**Verdict: not comparable as posed — the premise is out of date. Their own
newest code moved *away* from LiteNetLib/MessagePack toward what this project
already does. Recommendation: adopt nothing.**

The LiteNetLib + MessagePack stack is the **older C# generation**, and none of
its code is in the repo. The shipped codebase, `KCDRewrite/`, is:

- **ENet** (`KCDCommon/enet.hpp`, vendored single-header) — reliable UDP with
  reliable/unreliable channels, `NetTransport::{Send,Broadcast}{Reliable,Unreliable}`.
- **Hand-rolled binary framing** — `Packets.hpp` declares 16 packet types and a
  matching `CreateXPacket` / `ReadXPacket` pair each, returning
  `std::vector<uint8_t>`. No MessagePack, no reflection-based serialization.

That is **structurally the same decision this project made** — an explicit
type-byte enum plus manual encode/decode — just C++/UDP instead of C#/TCP.

Their packet set: `C2S/S2CPlayerState`, `Welcome`, `PlayerJoin/Leave`,
`Snapshot`, `SetDisplayName`, `PlayerName`, `EntityTableSync`, `HostInfo`,
`DoorState{Request,Sync,Snapshot}`. **No damage, death or combat packets at
all.** This project's `0x12`–`0x15` have no counterpart there.

On the three questions asked:

- **What LiteNetLib/MessagePack would buy.** Genuinely: unreliable channels for
  position (this project sends 60 Hz-ish presence over reliable TCP, where a
  late packet is worse than a dropped one), and less hand-written framing.
  Genuinely *not*: NAT traversal — LiteNetLib does not do NAT punchthrough for
  you beyond an intro/relay pattern you would still have to run, and this
  project already has a master server and a relay. MessagePack would replace
  ~one file of straightforward code with a dependency and a schema-drift risk.
- **Is their networking live-verified at comparable depth?** No. The C# stack's
  evidence is a test-plan document citing counts (602/611) whose test code is
  not in the repo. The C++ stack has no test files at all. This project has
  `Test-Combat.ps1` 14/14, `Test-Sessions.ps1` 23/23, `Test-Dice.ps1` 10/10, the
  59/59 Farkle suite, and two real machine-to-machine E2E paths.
- **Recommendation: not worth the migration cost.** Not close. Migrating a
  transport that is live-tested across combat, dice, appearance and voice, to
  copy a design whose own authors have since replaced it, for a scope of 2–4
  friends, is a strict loss. *If* the position channel ever becomes a latency
  problem, the targeted fix is a second unreliable channel for presence — a
  contained change, not a stack swap.

One item worth stealing conceptually (not code): their `DoorSync.cpp` (45 KB)
implements door replication with host authority and a state-revision counter.
This project's `NATIVE-PLUGIN-findings.md` lists doors as "not reachable through
`ent`. Unverified whether they are reachable another way." They found another
way. Worth a look **if** doors ever become in-scope; they currently are not.

---

# P3 — combat / sync design

**Verdict: confirms the same wall, described differently. Their combat design
does not solve NPC aggro, and this project is ahead of it. But their scriptbind
catalog turns up a surface this project closed prematurely — see P4, which is
the real P3 finding.**

`combat-sync-design.md` is marked **"draft 2026-05-18"** and its shipped status
is settled by `SyncStates.md` (2026-05-25), which is an honest per-state
catalog: **`player_killed_npc` and `player_took_damage` are "scaffolded —
listener slot only, no sender yet."** NPC damage replication is not shipped in
their tree. This project's is, in both directions, with real NPC deaths.

Where they are ahead: the **presentation** layer. They have empirically-derived
hit-reaction anim tables split by damage and direction, an additive-vs-full-body
layer rule (`_add` suffix → layer 1), a death-anim fallback chain, and a
`AI.AISignal(0,1,"OnDead",entity)` call they claim is required for ragdoll
rather than a T-pose. That is exactly the class of empirical data this project's
own notes say to port rather than regenerate — **but none of it is marked
verified**; their verification matrix lists the reaction clip and the ragdoll as
"visual inspection", with no recorded result.

**On aggro specifically — they never addressed it.** No aggro doc, no stimulus
design, no faction-attach work. `AppearanceApi.md` does the *opposite*: ghosts
spawn with `bWH_Perceptor=false`, `bWH_PerceptibleObject=false` and
`EnableAI(false)` precisely to keep them **out** of the AI faction system. This
project's WO-15/WO-16 line — hostile faction attach plus a brained ghost
producing real spontaneous aggro — has no counterpart there. **Nothing in the
repo contradicts §4 "Aggro / stimulus injection".** Their `SpawnGhostFaction(…,
"Civilians")` is a spawn-property call, not the faction-tree write WO-15 fixed.

### One direct contradiction, worth testing

`combat-sync-design.md` §3 asserts:

> `actor:SetHealth(X)` is a no-op on the Retail player object.
> `soul:SetState("health", X)` is the only path that actually moves HP on both
> NPC and Player.

This project's closed finding is that **Lua** health writes are inert, based on
`actor:SetHealth` and `soul:DealDamage` — the two methods they also say don't
work. **`soul:SetState("health", …)` may never have been tested from Lua here.**
It is plausible that it works: the *reflected* `Soul::SetState(health, …)` is
verified working in `NATIVE-PLUGIN-findings.md`, and the Lua binding may route
to the same C++ method.

Their evidence is second-hand ("confirmed by `Docs/api_ext.lua` KCD2-Cheats
research"), so this is not settled either way. It is a ten-minute test with a
save loaded and it would either narrow or confirm a closed finding. **Highest-
value cheap test to come out of P3.**

---

# P4 — cheap wins

**Verdict: the CSVs are worth asking for. One of them produces the most
significant single correction in this whole assessment.**

## The scriptbind catalogs

| File | Rows | What it is |
|---|---|---|
| `KCDRewrite/Tools/retail-lua-closures.csv` | 4,043 | every live Lua global/scriptbind symbol, retail 1.5.5 |
| `KCDRewrite/Tools/retail-global.csv` | 4,043 | same, plus closure/descriptor/callback addresses |
| `kcdrewrite-global.csv` | 1,446 | same walk against the **Modding Tools** build (this project's build) |
| `retail-scriptbinds-1.5.5.csv` | 271 | retail namespace/function → callback RVA |
| `scriptbinds-crossmatch.csv` | 1,054 | Modding Tools ↔ retail join: 253 both, 18 retail-only, 783 Modding-Tools-only |

**Durable value is the symbol names.** Addresses are per-session heap pointers;
RVAs are 1.5.5-specific and the game here is 1.5.6. Do not treat any address in
these files as usable.

They complement, not replace, Warhorse's shipped 5,014-page scriptbind reference
— PROJECT-STATE already warns that those docs describe a source tree and list at
least one method (`System.DrawTriStrip`) this build does not register. **These
CSVs are the "confirm against what's actually registered" step, already done.**

### The correction: `AI.*` stimulus binds exist in this build

`scriptbinds-crossmatch.csv` lists, as **present in the Modding Tools build**:

```
AI.CreateStimulusEvent          AI.CreateStimulusEventInRange
AI.AddPersonallyHostile         AI.IsPersonallyHostile
AI.SetFactionOf                 AI.GetFactionOf
AI.SetFactionThreatMultiplier   AI.UpdateGlobalPerceptionScale
AI.Signal                       AI.UpdateTempTarget / AI.DropTarget
AI.AddAggressiveTarget          AI.SetAttentiontarget       (both builds)
XGenAIModule.SpawnPerceptibleVolume / IgnorePerception       (retail_only)
```

**Verified independently against this machine's own install** — string scan of
`D:\SteamLibrary\...\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL`:

```
CryAISystem.dll   CreateStimulusEvent, CreateStimulusEventInRange,
                  AddPersonallyHostile, SetFactionOf,
                  SetFactionThreatMultiplier, UpdateGlobalPerceptionScale,
                  AddAggressiveTarget, SetAttentiontarget
XGenAIModule.dll  SpawnPerceptibleVolume, IgnorePerception
```

`PROJECT-STATE.md` §4 says aggro/stimulus injection has **"No reachable
surface"**, listing `xgen` reflected, `XBehaviorModule`, XGenAIModule exports,
`SkirmishManager::DebugTriggerEvent` and "Lua `AI.*` — inert".

That conclusion is **too strong for the Lua row**. Checking this repo's own
record: `AI.CreateStimulusEvent` was probed **once**, and
`ARCHITECTURE-shared-world.md` says so plainly —

> the `CreateStimulusEvent` signature was *invented* rather than found, which
> the project's first rule explicitly forbids.

The supporting evidence was that a **zero-argument** call raised no error. That
is weak: it is equally consistent with a real binding that validates lazily.
The correct statement is *"probed once with a guessed signature; result
inconclusive"*, not *"no surface exists"*.

`AI.SetFactionOf` is the sharper miss. WO-15 spent a session on
`C_FactionBase::SetParent` — a crash, a diagnosed calling-convention bug, a
fix. A **Lua** faction-set binding is registered in this build and appears never
to have been tried.

**Recommended §4 amendment** (not applied this session — investigation only):
change "Aggro / stimulus injection — no reachable surface" to "no reachable
surface *on the reflection and native surfaces probed*", and add the Lua
`AI.*` stimulus/faction binds as **untested candidates** with the note that the
one prior probe used an invented signature.

### The signature problem has a clean solution — the Lua-closure walk

`native-rvas-1.5.5.md` documents a technique that removes the guesswork:

```
tostring(luaFn)  ->  "function: 0x<closure>"
closure  + 0x28  ->  descriptor
descriptor +0x28 ->  native C++ callback
descriptor +0x40 ->  null-terminated function-name string
```

They claim the struct layout is identical across Modding Tools and retail (only
the containing module differs), and that this is how all five CSVs were
produced. Two things this project wants:

1. **The real parameter shape of `AI.CreateStimulusEvent`**, recovered by
   disassembling its actual callback — replacing the invented signature that
   invalidated the only prior test.
2. **A patch-resilient way to recover a native address from a Lua name**, which
   is the same shape as `NATIVE-PLUGIN-findings.md`'s "The outbound problem"
   option 1 (recover `TakeDamage`'s address from the RTTR method wrapper). Their
   route is via the *Lua* binding rather than the RTTR one, so it is not a
   direct substitute — `TakeDamage` has no Lua binding — but the technique is
   worth understanding before more static decoding.

Standard caveat, and it is this project's own: **registered is not working.**
`System.DrawTriStrip`, `System.Draw2DLine` and `SkirmishManager::DebugTriggerEvent`
are all registered, callable, silent and inert. Treat every name above as a
candidate to test, never as a capability.

## `KingdomComeMCP` — what it actually is

It is Model Context Protocol, and it is not a documentation folder. An injected
DLL hosting an MCP server on `\\.\pipe\KingdomComeMCP`, plus
`Tools/KingdomComeMCP-stdio-proxy.ps1` to bridge that pipe to an MCP client's
stdio. It executes Lua by calling `CScriptSystem::BeginCallTable` /
`PushFuncParamAny` / `EndCall` directly through **hardcoded retail RVAs**
(`kRva_CScriptSystemUpdate = 0x03CB00` and friends).

The *idea* — expose the running game to an agent as MCP tools — is a genuinely
good workflow item and this project has the pieces for it already
(`\\.\pipe\kcdmp`, `KcdApi.ps1`). The *implementation* is the hardcoded-offset
approach `NATIVE-PLUGIN-findings.md` explicitly warns against, pinned to 1.5.5
while this machine runs 1.5.6. **Idea worth taking; code not worth taking.**

## `EngineFindings.md` — free traps

Short, written as a public findings/wishlist doc, mostly consistent with this
project's own experience. Three items are new traps this project would otherwise
pay for, and one directly threatens any RC-based transport:

- **Anonymous `SetTimer` closures scheduled from a RemoteConsole exec context
  never fire.** Named globals work. Silent — no error, the callback just never
  runs. This project's entire `InterpTick` chain is `Script.SetTimer`-driven,
  and `kcd2mp-lua-timer-liveness` already records that timer chains die
  silently while `*Running` flags stay true. **If the RC path is ever adopted,
  this is the first thing to design around.**
- Mods initialise **twice** per boot on retail — every mod needs a re-entry guard.
- Boot can hang with `FaderController.State = FadedIn`; their workaround is a
  `Game:QuickLoad()` right after init.
- PAKs must be zero-compression ZIPs, forward slashes, no `Data/` prefix inside;
  7-Zip-produced ZIPs are silently rejected.

---

# Recommendation — reach out to Jefferson25625

Worth asking permission for, in priority order:

1. **The retail RemoteConsole transport** (`retail_remote_console_plan.md`,
   `RemoteConsoleClient.cs`, `RemoteConsoleBridge.cs`, `rc_rpc.lua`). Highest
   value by a distance — it is the only path found to running this project's Lua
   layer on retail, and P0b verifies the mechanism works. Note when asking that
   `#`-prefixed Lua **does** work via RC on 1.5.6, which makes most of their
   `AddCCommand` + `sv_servername`-hex machinery unnecessary — so what is
   actually wanted is the wire codec and the tail-correlation logic, not the
   whole bridge. The C# is not in the public repo; it would have to be asked for
   separately.
2. **The five scriptbind CSVs**, as **reference documentation only**, with
   attribution. Cheapest and lowest-risk item here. They are extracted game
   data rather than authored code, which may make permission easier — but ask
   anyway; the extraction tooling is theirs.
3. **The `guidSharedSoulId` appearance approach** (`AppearanceApi.md`,
   `soul_roster.lua`). Real capability this project does not have. The mechanism
   is now independently confirmed present in shipped level data, so the *idea*
   is usable without their code; their curated 48-soul roster is the part worth
   asking for.
4. **The hit-reaction / death anim tables** (`combat-sync-design.md`) — small,
   empirical, and exactly the kind of data this project's own notes say to port
   rather than regenerate. Unverified by them; would need our own confirmation.

**Explicitly not worth asking for:** the LiteNetLib/MessagePack networking
(superseded by their own ENet rewrite, and worse-tested than what we have), the
`KingdomComeMCP` implementation (hardcoded 1.5.5 RVAs), and anything from
`retail_http_api_feasibility.md` (disproved above).

---

# Open — next tests, cheapest first

None of these need permission; they are our own tests against our own install.

1. **`soul:SetState("health", X)` from Lua**, on an NPC and on the player.
   Ten minutes with a save loaded. Either narrows or confirms
   `lua-writes-are-inert`. (P3)
2. **In-world retail Lua.** The game was at the main menu for P0b, so `player`
   was nil. Load a save on retail with `-devmode` and re-run the RC probe —
   confirms or refutes their `retail_lua_api_availability.md` table. Script is
   at `scratchpad/rc-probe.ps1`; it takes one command-line argument. (P0)
3. **Does `kdcmp.pak` load on retail?** Their `EngineFindings.md` §1 says mod
   Lua only initialises with `-devmode`. If it does, items 1–2 plus the RC
   channel are a complete retail Lua path. (P0)
4. **`AI.CreateStimulusEvent` with a recovered signature**, not an invented
   one — via the closure-walk technique, or by disassembling the
   `CryAISystem.dll` callback directly. Then `AI.SetFactionOf` and
   `AI.AddPersonallyHostile` against a ghost. (P4/§4)
5. **`entity:CreateSkinAttachment`** for clothing and heads, not just hair —
   their `CharSystemDecisionPlan.md` phases A–D are a ready-made test plan we
   can run ourselves without adopting anything. (P1)

Reproduction scripts from this session, kept out of the repo:
`scratchpad/rc-probe.ps1`, `scratchpad/rc-latency.ps1`.
