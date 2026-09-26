# Testing 0.29.9 (both players)

One page for the host and the partner. About an hour. Play normally; nothing
here needs to be forced. If something goes wrong, note the time and carry on
or stop, then send what section 6 lists.

## 1. Install

* Both of you: run `KCDMP-Setup-0.29.9.exe` (the maintainer sends it; it is
  not on GitHub).
* Open the launcher. The bottom bar must say **v 0.29.9** on both computers.
  A different number on either side and nothing will connect (the launcher
  says so in plain words).

## 2. Five minutes first: the Steam test (both of you)

This answers "can Steam connect our two computers?" before we rely on it.

* Steam running and logged in (online, not offline mode), and the two
  accounts are Steam friends.
* Run `KcdMpSteamProbe.exe` (the maintainer sends it too).
  * **Host:** type `1`, Enter. A code like `ABCD-EFG` appears. Send it to your
    partner (Discord, Steam chat). Leave the window open.
  * **Partner:** type `2`, Enter, type the code, Enter.
* Wait until both windows say **Finished** (5–10 minutes). While it runs,
  look at your Steam friends list and write down what it says the other person
  is playing, with the time.
* **Keep both report files** (`wo120-probe-….txt`, the window names them).
  They contain measurements only: no names, no Steam IDs, no addresses.

## 3. Connect

**Host:** launcher → **HOST GAME**. Leave **Also allow Steam** ticked. After a
few seconds the window shows **your code** in big letters and "Steam: ready".
Read the code to your partner. Then **START GAME**, load your save, and click
**CONNECT** once you can move.

**Partner:** launcher → **JOIN THROUGH STEAM** (bottom bar).

1. Type the host's code (or click **FIND FRIENDS** and pick the host).
2. Click **TEST CONNECTION** first. It should say the host is reachable and
   runs the same version, with a round-trip time.
3. Click **JOIN**, then follow the launcher as usual.

**If Steam fails**, the launcher says why in one sentence and offers the
host's address right there: type it (`address:port`) and click **CONNECT BY
ADDRESS**. No restart needed. The old way (Add Server, then **TEST
CONNECTION**, then **JOIN SERVER**) still works exactly as before.

Both computers must use the same **Steam app** setting (Settings, bottom).
Leave it on the default unless the maintainer says otherwise.

## 4. Host: turn the recorder on, then the shared world

In the game console (`~`), on the **host** only:

```
mp_leash_trace on
```

You should read `WO127-LEASH trace=on`. It writes a small file once a second
for the whole session. Then follow the shared-world steps in
`WO-124-first-shared-world-runbook.md` (from "Start it").

## 5. Play normally

Ride, go into towns and houses, wander apart (far apart) and come back
together. Talk to people, trade, whatever you'd normally do. Nothing forced,
no need to hurry. Please do **not** attack townsfolk.

When you finish: host, `mp_leash_trace off` (or just quit; the file is kept).

## 6. What to send afterwards (both of you, before starting the game again)

* The launcher's **REPORT BUG** button makes one zip with the logs and the
  recorder files. Or collect by hand:
  * `kcd.log` from the Modding Tools folder (the next launch overwrites it);
  * `agent.log`, and the `leash` folder, beside `KcdMpClient.exe`;
  * the host: the relay's `relay*.log`.
* Both Steam probe report files from step 2.
* The friends-list notes from step 2, and the times of anything odd.
* **Never send save files**, and not the `KCDMP\henry` folder either.
