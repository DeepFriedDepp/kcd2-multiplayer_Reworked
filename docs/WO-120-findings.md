# WO-120 findings: connect through Steam

Status: **Phase 0 gate NOT YET RUN.** The two-network test needs the
maintainer and a tester on two different internet connections; it is
arranged by the maintainer (runbook: `tools/wo120/README.md`). Nothing past
Phase 0 is built. Ranking below is provisional until the gate reports.

## Phase 0: ranking and verdict

**Verdict: (inconclusive), pending the two-network run.** No route counts
until two machines on two networks connect.

| rank | route | why this rank | evidence |
|---|---|---|---|
| 1 | **B-sockets**: `ISteamNetworkingSockets` P2P (Steam Datagram Relay) in the joiner's agent and the host's relay process | outside the game process (no DLL deploy, immune to game main-thread hangs); reliable ordered messages map 1:1 onto the stream the protocol speaks; direct-or-relayed chosen by Steam | exports present (code-verified); probe built; cross-network result pending |
| 2 | B-messages: `ISteamNetworkingMessages` | same SDR transport, but connectionless: we'd rebuild session open/close/timeouts on top | exports present (code-verified); probe tests it |
| 3 | B-legacy: `ISteamNetworking` P2P | deprecated by Valve; last-resort fallback | exports present (code-verified); probe tests it |
| 4 | A: inside KCD2's process, via the game's Steam session | same app id as B under 2429020, so **no ownership or terms advantage**; every relay byte would cross the DLL pipe; KCDMP.dll deploys are matched sets the coding shell can't do (WO-45); the game's main thread hangs during loads (WO-58); the host's relay is a separate process and still needs its own endpoint | reasoning from code (code-verified); not built |
| 5 | C: non-Steam relay hosted by the maintainer (e.g. beside the master server) | needs a public server and its bandwidth; not what this WO asked for | not pursued |

### 1. Two machines, two networks, no ports, no VPN

- (inconclusive) Not run. The probe does it end to end for all three APIs
  under three app ids; one command each side.
- Local runs on the maintainer's PC: `SteamAPI_IsSteamRunning=false` under
  all three app ids (observed). Steam's `ActiveProcess` key read `pid=0`,
  `ActiveUser=0` inside and outside the shell sandbox, with `steam.exe`
  running as the same Windows user (observed): Steam was up but not
  logged in. Nothing about Steam networking was exercised locally yet.

### 2. Ownership and terms (the maintainer decides)

Facts first:

- The game process runs under app **2429020** (KCD2 Modding Tools):
  `steam_appid.txt` at the Modding Tools root says so and the launcher
  starts the game from there (code-verified: `Home.razor.cs`, the install).
- Retail and Modding Tools ship the **same** `steam_api64.dll` (byte
  compare, observed). The mod binds to the player's own copy at runtime;
  **no Valve binary is redistributed** (code-verified: `SteamLibraryLocator`).
- `SteamAPI_Init` only succeeds for an app id the logged-in account owns or
  that is free to everyone (Steam's rule).

| app id | ownership | what's questionable |
|---|---|---|
| 2429020 Modding Tools | every player already runs it (the mod requires the MT build) | it's Warhorse's app id used by a third-party process. Steam already shows the player "playing" it, so the visible status doesn't change. SDR traffic is carried under Warhorse's app. Warhorse didn't sanction it; no rule we found forbids a player's own client doing it, and no permission exists either. |
| 480 Spacewar | free to every account | Valve's public **developer test** app. Mods use it widely, but that's not what it's for, and Valve can restrict it. The player's Steam status may read "Spacewar", which confuses non-technical testers and may hide the KCD2 status. |
| 1771300 retail KCD2 | every player owns it | same concern as 2429020. It also puts a second "game" on the account while the MT build runs, and could collide with a retail launch (`steam -applaunch 1771300`, WO-53). |
| a KCDMP app id of our own | Steam Direct fee + partner account + review | the clean route: our own app, our own rich presence, "Join game" support. Costs money and time. |

- Rich presence: a joiner can read a friend's keys only when both run the
  **same** app id (Steam's rule). Discovery ("friends currently hosting")
  therefore works only if both sides use one app id; the probe measures
  whether the host's marker is visible.

### 3. Throughput and latency

- (inconclusive) Pending. The probe's game phase carries the WO-109 §4.3
  budget at its top (NPC stream 20 Hz × 512 B = 10 KB/s), 20 Hz player
  state both ways, a 64 KB burst every 10 s, 10 Hz pings under load, then
  a 4 MB bulk transfer as a ceiling. It reports RTT percentiles, gaps in
  the 20 Hz stream (>100 ms, >250 ms, max), Steam's own ping/quality, and
  whether the path was relayed.

### 4. Semantics

- One connection, reliable ordered messages (`k_nSteamNetworkingSend_ReliableNoNagle`)
  = TCP's guarantee once read back as a byte stream (code-verified:
  `SteamConnectionStream`). The agent writes whole frames under one lock
  (`GameBridge.WritePacketAsync`), so a frame never straddles two writers;
  message boundaries are not load-bearing (the reader reassembles as from TCP).
- NoNagle matches the TCP path's `NoDelay` (WO-110 R6).
- Full send buffer → `k_EResultLimitExceeded` → the writer waits and retries,
  never drops: the TCP path blocks in the same place (code-verified).
- Peer gone → `Read` returns 0, which every existing loop already treats as
  end of stream; `ReadTimeout` is honoured like `NetworkStream`'s.

## Constraint found for Phase 1 (code-verified)

- Relay authority is keyed on the TCP peer being loopback:
  `ClientSession.IsLoopback` (`ClientSession.cs:88`), used by
  `ClientHandler.cs:229` (WO-110 R4: the relay-local client wins).
- So the cheap design (a Steam-to-loopback-TCP forwarder on the host) would
  make every Steam joiner look relay-local and **steal authority**. Steam
  clients must reach `ClientSession` as their own non-loopback session
  (a `Stream` in place of the `NetworkStream`), or a forwarder has to carry
  "not local" through explicitly.

## Privacy

- Steam's own debug strings name the peer (`steamid:…`) and can carry IP
  addresses. Every string the library surfaces goes through
  `SteamLogScrub` (SteamIDs, `[U:1:…]`, 15-20 digit numbers, IPv4/IPv6).
  Offline self-test: 100,000 random ids and addresses, 0 leaks (observed).
- The friend code is the host's account id plus a 3-bit check: 100,000/100,000
  round-trips; 90.3% of single-character typos rejected (observed, `--selftest`).
  It's shown on screen only, never written to a report or log.
