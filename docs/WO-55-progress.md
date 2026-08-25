# WO-55 — progress

## 2026-08-25

- Traced the join-address rejection to exactly one function:
  `NetService.ValidateIpAddr` (`IPAddress.TryParse`) — UI layer only. Verified
  by reading every hop that the connect path below it is a plain string down to
  `TcpClient.ConnectAsync(string, int)`, which resolves DNS natively; no
  networking code needed changing.
- Replaced it with `ValidateServerAddress` (`Uri.CheckHostName`): hostnames,
  IPv4, and IPv6 all accepted; garbage still rejected. Updated the Add Server
  modal (label, placeholder, trim) and both ping guards.
- Found and fixed a secondary trap that would have re-blocked the field test:
  the launch gate trusted ICMP ping alone. Added `CanConnectTcpAsync` and made
  `IsServerReachableAsync` fall back to a real TCP probe of the relay port.
- Live-verified end to end: real relay on 7900, real unmodified agent pointed
  at the genuine public-DNS name `127.0.0.1.nip.io` →
  `Connected! Assigned id=1 (protocol v6)`, session held 1500+ ticks.
  Also verified the human's actual DDNS name resolves to a real A record and
  passes the new validator (name and address withheld — it is the user's home
  IP); no connection was attempted to it (no relay known to be listening there).
- Builds green (launcher + KcdMp.sln), Farkle tests 59/59.
- Remaining for the next real session: drive the launcher UI itself with a
  hostname (Add Server → Launch), which this shell cannot do.

Full detail: docs/WO-55-findings.md.
