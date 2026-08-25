# WO-55 — The launcher must accept a hostname, not just a literal IPv4 address

**Date:** 2026-08-25
**Result: FIXED and live-verified — a real DNS hostname was resolved and a real TCP
connection to a real listening relay was watched succeed end to end** (details and
exact evidence grading in "Evidence" below).

## Why this existed

A real two-human session attempt (the single most important pending activity per
WO-51/WO-54) fell through because the joining player's working Dynamic DNS
hostname was rejected by the launcher's Add Server form. Their name was never
even tried — it was refused at string validation.

## Where the IPv4-only assumption lived — exactly one function

`NetService.ValidateIpAddr` (`KCDMP_launcher/Models/NetService.cs`) used
`IPAddress.TryParse`, which accepts only literal IPv4/IPv6 notation and rejects
every hostname. It choked the launcher at two points:

1. **`AddServerModal.ValidateInput`** — the observed failure. A hostname could
   not be saved as a server entry at all; the error even said
   "Invalid IP address."
2. **`SendPingServer` / `SendPingServerAsync` guards** — even if a hostname had
   somehow reached the list, its ping would have been skipped (`-1`), and
   `Home.razor.cs`'s launch gate `IsServerReachable` treats `Ping < 0` as
   unreachable → "Server is unreachable. Cannot launch."

## How deep the assumption went: **UI layer only** (verified by reading every hop)

The path below the validation is a plain string all the way down and already
resolves DNS natively:

- `Home.razor.cs` `ConnectToGame` passes the address as text:
  `--host {pendingServer.Ip}`.
- `ClientConfig.ServerHost` is a `string` (doc comment even says "Host or IP").
- The actual connect, `GameBridge.ConnectAndRunAsync`, calls
  `TcpClient.ConnectAsync(config.ServerHost, config.ServerPort)` — the
  `(string, int)` overload, which performs standard DNS resolution.
- `Ping.SendPingAsync(string)` also accepts hostnames natively — only the
  validation guard in front of it refused them.
- `FormatHost` (IPv6 URL bracketing) passes non-parseable strings through
  unchanged, which is correct for hostnames in URLs.
- No `IPAddress` object ever crosses the launcher→agent boundary.

So no networking code needed changing. One validation function and one
launch-gate weakness (below) did.

## Secondary trap found while tracing: the launch gate trusted ICMP alone

`IsServerReachable` required a successful ping. Home routers — exactly where a
Dynamic DNS name points — commonly drop WAN ICMP while forwarding the relay's
TCP port fine. With only the validation fixed, the field failure would have
recurred at the next gate with "Server is unreachable. Cannot launch."

## What was changed

All in the launcher; the agent needed nothing.

1. **`NetService.ValidateIpAddr` → `ValidateServerAddress`**
   (`KCDMP_launcher/Models/NetService.cs`): accepts anything
   `Uri.CheckHostName` classifies as `Dns`, `IPv4`, or `IPv6` — the framework's
   own syntax check for the host position. Whether a name resolves is DNS's job
   at connect time, same as any standard client. Error text updated to name
   hostnames. Both ping guards updated.
2. **`NetService.CanConnectTcpAsync`** (new): a real TCP connect probe to the
   relay port — the same operation the agent performs moments later, so it is
   the truthful reachability test.
3. **`Home.razor.cs` `IsServerReachable` → `IsServerReachableAsync`**: a ping
   time still passes immediately; a failed ping now falls back to the TCP probe
   instead of refusing to launch.
4. **`AddServerModal.razor`**: label is now "Address (hostname or IP)",
   placeholder shows a DDNS example, and the input is trimmed before use — the
   address is later placed unquoted into the agent's command line, so stray
   pasted whitespace must never reach it.

Literal IPv4 and IPv6 addresses are still accepted (additive change;
`Uri.CheckHostName` classifies them as `IPv4`/`IPv6`).

## Evidence

Graded per claim:

- **Observed — real DNS resolution of the human's actual DDNS name.**
  `Resolve-DnsName <the user's real DDNS name> -DnsOnly` returned a real A
  record (name and address withheld from this public repo — it is the user's
  home IP). The name that was rejected in the field is real and resolvable.
- **Observed — the new validator's classification, with the real name.**
  `Uri.CheckHostName` (the new gate's core): the user's real DDNS name → `Dns`,
  `127.0.0.1.nip.io` → `Dns`, `192.168.1.10` → `IPv4`, `::1` → `IPv6`,
  `"not a host!!"` and `""` → `Unknown` (rejected).
- **Observed — a real hostname-based connection, watched succeed end to end.**
  A freshly built relay (`KcdMpServer.exe --port 7900`) was started, and the
  real, unmodified agent binary (`KcdMpClient.exe --host 127.0.0.1.nip.io
  --port 7900 ...`, the exact connect path the launcher drives) was pointed at
  the hostname. `127.0.0.1.nip.io` is a genuine public-DNS name (A record
  observed above, resolves to 127.0.0.1). Agent output:

  ```
  Server   : 127.0.0.1.nip.io:7900
  ...
  Connecting to relay server 127.0.0.1.nip.io:7900...
  Connected! Assigned id=1 (protocol v6)
  ...
  [ping] 1 ms
  [ping] 0 ms   (session held live for 1500+ ticks before teardown)
  ```

  The assigned id only comes from the relay's handshake Ack, so this is a
  completed DNS→TCP→protocol round trip, not just a socket open. (The game's
  REST API was stubbed to get the agent past its wait-for-save phase; the
  relay, the agent, and the connect path itself were all real. The user's own
  installed relay was already live on 7778 and was deliberately left untouched.)
- **Read but not rendered — the launcher's own new code paths.**
  `ValidateServerAddress` and `CanConnectTcpAsync` compile and their cores
  (`Uri.CheckHostName`, `TcpClient.ConnectAsync(string, int[, ct])`) were each
  exercised live as above, but the launcher UI itself was not driven this
  session (no game/launcher run from this shell — AppData sandbox redirection).
  The Add Server → Launch flow with a hostname should be confirmed in the next
  real session.
- **Not tested — a connection to the DDNS name itself.** No relay is known to
  be listening behind it right now; only DNS resolution was verified. Nothing
  more was sent to it.
- **Correction (same day):** the user named a slightly different DDNS name as
  the one they will actually use. Verified equally: resolves to the same real
  address and `Uri.CheckHostName` → `Dns`, so it passes the new gate the same
  way. (Both names and the address are deliberately not recorded here.)

## Suites

`dotnet build` launcher: 0 errors. `dotnet build` KcdMp.sln: 0 errors.
`dotnet test` KcdMp.Farkle.Tests: 59/59 passed. (All warnings pre-existing.)
