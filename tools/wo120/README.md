# WO-120 Phase 0: the Steam connection test

One question: can Steam connect two computers on **two different internet
connections** (two homes, or one home and a phone hotspot) with no port
forwarding and no VPN? A test on one network doesn't count.

## What you need

- Two computers, each on its **own** internet connection.
- Steam running and **logged in** on both, and the two accounts are
  **Steam friends**.
- KCD2 and the KCD2 Modding Tools installed on both (the test borrows the
  game's own Steam file; nothing else gets installed).
- `KcdMpSteamProbe.exe` on both. The maintainer builds it (below) and sends
  it over. It's one file, needs no install, and changes nothing on the PC.

## Running it (about 5-10 minutes)

1. **Host:** double-click `KcdMpSteamProbe.exe`, type `1`, press Enter. A
   code like `ABCD-EFG` appears. Send it to your friend (Discord, Steam
   chat, whatever). Leave the window open.
2. **Joiner:** double-click `KcdMpSteamProbe.exe`, type `2`, press Enter,
   type the code, press Enter.
3. Wait. It tests three ways of connecting, each under three Steam "games"
   (see below), one after the other. Both windows say **Finished** at the end.
4. Both of you send the maintainer the `wo120-probe-….txt` file the window
   names. It has measurements only: no names, no Steam IDs, no addresses.
   The code is shown on screen and never written to the file.

While it runs, **look at your Steam friends list** and note what it says
each of you is playing (for example "Kingdom Come: Deliverance II Modding
tools", or "Spacewar"). Write that down with the time. Only a person can
see this, and it's one of the questions.

If you have time, run it a second time with the game running on both PCs
(started through the multiplayer launcher as usual). Afterwards, check the
game still shows as running in Steam.

## What it tests

For each app id: Steam **2429020** (the Modding Tools, which the game itself
runs as), **480** (Valve's public test app "Spacewar") and **1771300**
(retail KCD2):

| step | what |
|---|---|
| start | can this process use Steam under that app id; are Valve's relays and our certificate ready |
| friends | does the joiner see the host playing under that app id, and the host's "I'm hosting" marker (numbers only) |
| sockets | `ISteamNetworkingSockets` P2P: connect time, direct or relayed, idle ping, then 60 s of game-shaped traffic both ways (player state 20 Hz, NPC stream 10 KB/s, a 64 KB burst every 10 s, pings), every frame checked for order and content, gaps in the 20 Hz stream, then a 4 MB transfer |
| messages | `ISteamNetworkingMessages`: 50 reliable pings |
| legacy | old `ISteamNetworking` P2P: 50 reliable pings |

## For the maintainer

Build (writes one file under `release/wo120-probe/`, git-ignored; never
upload it to GitHub):

```
dotnet publish tools/wo120/SteamProbe -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true -p:DebugType=none -o release/wo120-probe
```

Other modes: `KcdMpSteamProbe.exe check` (this PC only), `host`,
`join <code>`, `--apps 2429020`, `--seconds 120`, `--api sockets`,
`--selftest` (offline: friend-code and log-scrubber checks).

Before committing anything from a report, read it: the probe scrubs Steam's
own debug text for `steamid:`, 15-20 digit numbers and IP addresses, but a
human check is the last line.
