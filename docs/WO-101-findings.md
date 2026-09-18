# WO-101 — 0.23.1 position regression (hotfix)

Session 2026-09-17. Scope: locate where V2-length Position packets stop,
fix forward, gate it, ship 0.23.2. Evidence marks: (observed) = field bundles
of 2026-09-17, (code-verified) = read in source at `d663f15`,
(synthetic) = loopback / unit test.

## 0. Where the drop is

### 0.1 Verdict

**`dotnet/KcdMp.Server/Features/ClientHandling/ClientSession.cs:555`,
`ClientSession.RunAsync`, the Position fall-through gate:**

```csharp
if (type != Protocol.Position || payloadLen != Protocol.PositionPayloadLen)
{   // Skip unknown/malformed packet
```

`PositionPayloadLen` is 17. A WO-100.5 live sample is 22
(`PositionPayloadLenV2`). The relay reads the 22 bytes into `skip` and
`continue`s. No log line, no counter. (code-verified)

Second, latent defect on the same hop: even past that gate the relay
forwards only what it parsed — `TcpBroadcastService.Broadcast(x,y,z,rotZ,flags)`
→ `ClientSession.EnqueueGhost` builds a fixed 18-byte Ghost
(`ClientSession.cs:595-604`). The five body-state bytes had no path through
the relay at all. (code-verified)

### 0.2 The two send paths, named exactly

Both live in `GameBridge.cs`'s tick loop and both call `SendPositionAsync`
(`GameBridge.cs:5298`):

| path | call | `body` arg | flags | payload len |
|---|---|---|---|---|
| live sample | `GameBridge.cs:1731` | `local?.Body` — set whenever the DLL answered the 0x09 read | `0x04` set | **22** |
| stale heartbeat | `GameBridge.cs:1690` | omitted → `null` | `0x02` set, `0x04` clear | **17** |

The only difference is the `body` argument. `SendPositionAsync` derives the
length from it (`GameBridge.cs:5306`) and the flag bit from it
(`:5316`). Field order is identical. (code-verified)

`MP-ANIM section=outbound reads=1703 refused=0 unknown_tags=0 disabled=0`
(observed, host) means every live tick had a body → every live packet was 22
bytes → every live packet hit the gate above. The heartbeat is the only
17-byte sender left, so it is the only thing that arrived.

### 0.3 Relay hypothesis: confirmed, not refuted

The prompt's inference was right. Additional confirmation that the relay is the
one hop that never learned V2: `git log -S CombatEventUpPayloadLenV2` shows
WO-99 Phase 4 taught `ClientSession.cs:424` to take
`CombatEventUpPayloadLen || CombatEventUpPayloadLenV2` and forward the body
verbatim; WO-100.5 touched the relay only for `0x3B`→`0x3C`
(`0283621`) and never revisited the Position gate. (code-verified)

### 0.4 Receive side, ruled out as the drop

`GameBridge.cs:3711-3712` accepts `GhostPayloadLen || GhostPayloadLenV2` and
decodes the tail only when the flag AND the V2 length agree
(`:3728-3739`). A 23-byte Ghost would have been applied. It was never sent.
(code-verified)

Peer mod apply: `KCD2MP_UpdateGhost(id,x,y,z,rotZ,isRiding,bPace,bDir,bStance,bSpeedCenti)`
(`kdcmp.lua:4811`) takes the extras; the agent appends them only when it
decoded a body (`GameBridge.cs:4383-4389`). Not a length check. (code-verified)

Lua emitter → agent: the `[KCD2-MP-DATA] v2` log line carries no body state
and has no bearing on packet length; the body comes from the DLL pipe
(`ReadLocalBodyStateAsync`). (code-verified)

### 0.5 Field evidence (observed, HOST (2) / JOINER2 bundles, 19:37–19:43)

| | host | joiner |
|---|---|---|
| `[pos]` moved lines (samples sent that changed) | 1580 | 370 |
| `[ghost N]` lines (updates received) | 17 | 8 |
| `MP-SUMMARY section=position` | `stale_out=8 ghost_stale_in=8` | — |

* Every one of the joiner's 8 receives is 60–70 ms after a host
  `[pos] mod emitter silent` line; the 2 s repeats carry identical
  coordinates. The host's 17 receives start at `19:41:43.020`, the instant the
  joiner's own emitter first went silent (`19:41:43.049` joiner clock).
* `ghost_stale_in=8` of 8: **100 % of what arrived was STALE-flagged**.
  Nothing with `0x04` ever arrived.
* Relay log for the session: 115 lines, 0 error/warn/drop lines. The gate
  has no log line to emit.
* Joiner's ghost entity on the host did not exist until `19:41:43` — 2 min
  3 s after the joiner connected — which is what §3.2 below hangs on.

### 0.6 Why 111 synthetic tests did not see it

The 33 Lua checks and the 16+ agent unit tests exercise codec and inbox logic
in one process. No test opens a socket to the relay. The one place the length
is compared against a single constant is the one place no test reaches.

## 1. The fix, and the audit

### 1.1 Fix (code-verified, relay builds green)

`ClientSession.cs` Position gate: `payloadLen == 17 || payloadLen == 22`;
the read buffer is `PositionPayloadLenV2` and reads `payloadLen` bytes; the
bytes after the flags byte (0 or 5) are handed to
`TcpBroadcastService.Broadcast(..., tail)` → `EnqueueGhost(..., tail)`, which
appends them verbatim after the Ghost flags byte. Ghost is therefore 18 or 23
and nothing else. The relay does not interpret the tail — same discipline as
the CombatEvent v2 `[sid:2]`. Echo mode carries the tail too.

Wire format unchanged. No client change needed for the fix itself.

### 1.2 Audit — every length gate on the path (code-verified)

**Multi-length pairs (the defect class):**

| pair | client sends | relay accepts | relay forwards | client accepts |
|---|---|---|---|---|
| Position 0x01 / Ghost 0x02 | 17 or 22 | **was 17 only → now 17 \| 22** | **was fixed 18 → now 18 \| 23** | 18 \| 23 (`GameBridge.cs:3711`) |
| CombatEventUp 0x2C / Down 0x2D | 3 (V2 always) | 1 \| 3 (`ClientSession.cs:424`) | verbatim + src | 2 \| 4 (`GameBridge.cs:4276`) |

Only one pair had the defect.

**Action channel 0x3B / 0x3C:** client `ActionOutbox.Build` emits
`9 + payload.Length` with `packet[11] = payload.Length`
(`ActionChannel.cs:65-71`); relay accepts `9 ≤ len ≤ 73` and requires
`body[8] == len - 9` (`ClientSession.cs:445-451`); `body[8]` is `packet[11]`.
Consistent. Client `ActionInbox.Accept` requires `≥ 10` then `≥ 10 + len`
(`ActionChannel.cs:140-149`). Relay forwards verbatim + 1 src byte. Consistent.

**Variable-length, self-describing** — relay checks a range and that the
embedded length agrees with the frame; client Down gate is the same range + 1:
AppearanceUp (`1 + n*16`, n ≤ 32), NpcStateUp / NpcDamageUp
(`nameLen` vs `MaxNpcNameLen`), HorseInfoUp, WeatherUp, StoryBeatUp. All
consistent. (Send-side note, not this WO: NpcDamageUp and WeatherUp do not
truncate the name they send; the relay would drop a > 64 / > 48-byte name.
Both names come from the engine's own authored identifiers and NpcStateUp
guards the same names at `GameBridge.cs:3544`. Pre-existing, no field
evidence, left alone.)

**Fixed-length** — relay `==` one constant, client sends the same constant,
relay Down is `1 + Up` built from `upstreamBody.Length`, client gate is the
`Down` constant: Ping 8, ClockSyncUp 8, VoiceUp 640, DamageUp, DeathUp,
PauseUp, PlayerStateUp, PlayerHitUp (Down is re-shaped to
`PlayerHitDownPayloadLen`, both constants), TimeSkipUp, ItemDropUp,
ItemClaimUp, PlayerDeathUp (0 → Down 1). All consistent.

**Relay forward vs receive:** every `Enqueue*Down` copies `upstreamBody`
verbatim behind a source byte; none re-derives a length from a constant. The
Position/Ghost pair was the single exception — it re-encoded from parsed
fields with a hard-coded `new byte[18]` — and that is now gone.

## 2. The gate that would have caught it

`dotnet/KcdMp.Relay.Tests/RelayRoundTripTests.cs` — **a standing pre-ship
gate**, run by `tools/Build-Installer.ps1` before it publishes anything. Its
header comment states the rule: any packet-shape change gains a case here and
passes, in both lengths, before a build ships.

* Hosts the **real relay** in-process: `Program.CreateApp(args)` (new, same DI
  graph `Main` runs) on free loopback TCP + HTTP ports; real `TcpClient` peers
  speak the real handshake and read the Ack.
* Sends with the **shipped agent code**: `PositionCodec.BuildPosition` (new
  file, extracted from `GameBridge.SendPositionAsync`, which now calls it) and
  `ActionOutbox.Build`. Decodes with the shipped agent code:
  `PositionCodec.TryDecodeGhost` (extracted from the Ghost receive branch,
  which now calls it) and `ActionInbox.Accept`.
* Cases (10, all (synthetic)):
  * V2 Position with body state → Ghost of 23 bytes, all five body bytes
    equal, sender id, coords, flags.
  * 17-byte Position → Ghost of 18 bytes, body null, flags intact — **the
    negative**: mixed-version degradation still works.
  * STALE heartbeat → flag survives.
  * 20-byte Position → dropped, framing survives, exactly one Ghost for the
    valid packet behind it.
  * Sender never receives its own Ghost.
  * Action `0x3B`→`0x3C` with a 4-byte payload → `ActionInbox` accepts,
    payload equal, source id equal; header-only action (the other valid
    length) → accepted; a lying `len` byte → dropped.
  * CombatEvent 1 and 3 bytes → both forwarded verbatim.
* **Proof it bites:** with `ClientSession.cs` + `TcpBroadcastService.cs`
  checked out at `d663f15` (the 0.23.1 relay) and everything else current,
  the gate fails exactly `V2_position_with_body_state_arrives_intact` and
  `Sender_does_not_receive_its_own_ghost` (both send V2) and passes the eight
  old-length cases — the field symptom, reproduced on loopback. (synthetic)
* Agent unit tests after the codec extraction: 127/127. (synthetic)

Not proven here, by construction: that the live agent's `body` is non-null in
the field (the DLL read) — but §0.5's `MP-ANIM reads=1703 refused=0` already
shows that (observed).

## 3. Two loose ends from the same bundle

### 3.1 Startup `NullReferenceException`s — benign, mechanism corrected

`ERR : Unhandled Exception while processing event: System.NullReferenceException`
at `DiscordRPC.Assets.Merge(Assets other)` ← `RichPresence.Merge` ←
`DiscordRpcClient.ProcessMessage` ← `RpcConnection.EnqueueMessage`. (observed:
2×–4× per agent run in every bundle, 09-16 and 09-17, host and joiner; always
~1–2 s after a `[discord] SetPresence` line.)

* The message text is DiscordRPC's own catch-and-log on its read thread. The
  exception never reaches our code; `IsInitialized` stays true and the later
  `SetPresence` calls at `19:41:43` and `19:42:27` went out. (observed)
* WO-50's workaround (`SmallImageKey = ""`) null-guards **our** side. The null
  is in **Discord's reply**: the ack echoes the presence back with no
  `small_image`, the library merges the reply into ours, and
  `other._smallimagekey.StartsWith(...)` is called on the reply's null. So the
  workaround cannot work, and the only consequence is that
  `OnPresenceUpdate` never fires — `[discord] presence ack` appears **0** times
  in every bundle. (code-verified against the WO-50 source read; observed)
* No fix available without a code fork: the upstream null guard is on
  `master`; the only NuGet version newer than 1.6.1.70 is 1.143.0, which is
  **deprecated and unlisted** ("critical bugs", 2020). Not upgrading a
  dependency blind in a hotfix. The misleading comment in `DiscordPresence.cs`
  is corrected; the `""` is kept because it is harmless.

**Verdict: benign.** Cost = one lost log line per presence update.

### 3.2 `[appearance] unequip … failed: 404` — long-standing race, amplified by §0

* The call is `GET …/SoulsByName/kcd2mp_1/EquipmentManager/UnequipItem`
  (`HttpGameTransport.cs:313-318`); 404 = the game has no soul named
  `kcd2mp_1` **yet**. The ghost entity is spawned by the first
  `KCD2MP_UpdateGhost` (`kdcmp.lua:4815`), i.e. by the first **Ghost packet**.
  The Appearance packet arrives at connect, before that. (code-verified)
* Working session 09-16 (HOST bundle): first `[ghost 1]` at `19:13:44.808`,
  the single unequip 404 at `19:13:44.834` — 26 ms later, the spawn
  `ExecuteString` not yet landed. **1** failure, then the 30 s appearance
  heartbeat succeeded. JOINER.prev: 1. (observed)
* 09-17 (HOST (2)): joiner connected `19:39:40.110`, first `[ghost 1]`
  `19:41:43.020` — **2 min 3 s** with no ghost entity because §0 dropped every
  live Position. All 10 preset-item unequips 404'd at once, then again on each
  30 s heartbeat: **50** in the log. After the ghost finally spawned:
  `[appearance] ghost 1: 9 item(s) still not applied, retrying`. (observed)

**Verdict: long-standing (1 per session when positions flow), not a
regression; the 09-17 volume is §0's consequence and goes away with §1. Left
alone, as instructed.**
