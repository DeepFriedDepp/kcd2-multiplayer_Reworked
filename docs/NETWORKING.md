# How multiplayer actually connects

This is the FAQ answer, written plainly. If you just want to play with a
friend, read "Quick answer" and stop there.

## Quick answer

- **Same house / same Wi-Fi:** nothing to configure. Host, click Host Game,
  give your friend the LAN address the launcher shows you. Done.
- **Different houses:** install a free VPN app like
  [Tailscale](https://tailscale.com) on both PCs (a couple of minutes each,
  no router settings). Host uses the address Tailscale gives them instead of
  a LAN address. This is the option we recommend for a small group of
  friends — no port forwarding, no exposed public server.
- **You'd rather not install a VPN:** the host forwards a port on their
  router instead (see below). More setup, works without installing anything
  on either machine beyond the mod itself.

## What's actually happening

The relay (`KcdMpServer.exe`) is a plain TCP server. Whoever runs it is
"hosting" — everyone else's game (via the agent, `KcdMpClient.exe`) opens a
TCP connection to that one address and port. There's no matchmaking magic:
if a device can reach the host's `IP:port`, it can join. If it can't, it
can't. This is the same "one host, others connect" model as SPT/FIKA.

You do **not** need a public/dedicated server. For 2-4 friends, the host's
own PC running the relay is enough — that's what "Host Game" in the launcher
does.

## Host vs. Join, in the launcher

- **Host** — click "HOST GAME". The launcher starts a relay on your machine
  (default port `7778`) and shows you every address this PC can be reached
  at (your LAN IP, and a VPN adapter's IP if you have one running). Give one
  of those addresses + the port to your friend. Then click "START GAME" to
  launch KCD2 and join your own relay.
- **Join** — either pick a server from the list (only populated if a master
  server is configured and reachable — see below), or click "ADD SERVER" and
  type in the address your host gave you, then "JOIN SERVER".

## LAN play

If you're both on the same Wi-Fi/router, use the LAN address the host's
launcher shows (something like `192.168.1.x`). No port forwarding, no VPN,
nothing else to configure. This is the easiest case and needs no further
reading.

## Playing over the internet: VPN overlay (recommended)

Install [Tailscale](https://tailscale.com) (or ZeroTier, Radmin VPN, or
Hamachi — any of them work the same way) on both PCs and sign in with the
same account/network. Each PC gets a private IP that behaves like it's on
the same LAN, without either of you exposing anything to the public
internet or touching your router. The host gives their friend the VPN
adapter's IP instead of the LAN one — the launcher's Host screen shows both
if you have a VPN client running, so just pick the right one.

This is the default recommendation for a small friend group: it's the
lowest-effort option that doesn't require router access, and it doesn't put
a port on the open internet.

## Playing over the internet: port forwarding (no VPN)

If you'd rather not install anything extra:

1. On the host's router, forward **TCP port 7778** (or whatever port you set
   in the launcher's Host settings) to the host PC's LAN IP.
2. The friend needs the host's **public IP** (search "what is my ip" from
   the host's machine, or check the router's status page), not the LAN one.
3. Windows Firewall may prompt the first time the relay starts — allow it on
   at least Private networks.

This exposes port 7778 to the whole internet for as long as the relay is
running. That's an acceptable risk for a plain TCP game relay among friends,
but it is a real port open to the internet — turn off port forwarding when
you're not playing if that matters to you. The VPN option above avoids this
entirely.

## What to tell someone joining you

Exactly one thing: **the address and port**, e.g. `100.64.12.3:7778`
(Tailscale) or `86.23.199.4:7778` (port-forwarded). They type that into
"Add Server" in their launcher, or straight into the Join box, and click
Join.

## If it's not connecting

- Confirm the relay is actually running (the host's launcher shows "Host
  Game" as active, or check for a `KcdMpServer.exe` process).
- Confirm both people are using the **same port** — the one the host's
  launcher displayed.
- If port-forwarding: re-check the forwarded port matches the relay's port,
  and that the address given out is the host's *public* IP, not their LAN
  IP (only works for LAN players).
- If using a VPN overlay: confirm both machines show as connected/online in
  the VPN app itself before blaming the mod.
- Windows Firewall blocking `KcdMpServer.exe` or `KcdMpClient.exe` on first
  run is the most common single cause of "it just doesn't connect" — allow
  both through the firewall prompt (or add them manually under Windows
  Defender Firewall → Allowed apps).
