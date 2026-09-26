# Testing 0.30.0 (both players)

One page for the host and the partner. About an hour. Play normally; nothing
here needs to be forced. If something goes wrong, note the time and carry on
or stop, then send what section 7 lists.

0.30.0 fixes what the first shared-world session (0.29.9) found. Section 5
lists what should now look different; that is the part to watch.

## 1. Install

* Both of you: run `KCDMP-Setup-0.30.0.exe` (the maintainer sends it; it is
  not on GitHub). **Both** computers need it: 0.29.9 and 0.30.0 refuse each
  other.
* Open the launcher. The bottom bar must say **v 0.30.0** on both computers.
  A different number on either side and nothing will connect (the launcher
  says so in plain words).

## 2. The Steam test (only if you did not send its reports last time)

Skip this if both of you already sent the two `wo120-probe-….txt` files after
the 0.29.9 session.

* Steam running and logged in (online, not offline mode), and the two
  accounts are Steam friends.
* Run `KcdMpSteamProbe.exe` (the maintainer sends it too).
  * **Host:** type `1`, Enter. A code like `ABCD-EFG` appears. Send it to your
    partner (Discord, Steam chat). Leave the window open.
  * **Partner:** type `2`, Enter, type the code, Enter.
* Wait until both windows say **Finished** (5–10 minutes). While it runs,
  look at your Steam friends list and write down what it says the other person
  is playing, with the time.
* **Keep both report files** (the window names them). They contain
  measurements only: no names, no Steam IDs, no addresses.

## 3. Connect

**Host:** launcher → **HOST GAME**. Leave **Also allow Steam** ticked. After a
few seconds the window shows **your code** in big letters and "Steam: ready".
Read the code to your partner. Then **START GAME**, load your save, and click
**CONNECT** once you can move.

**Partner:** launcher → **JOIN THROUGH STEAM** (bottom bar).

1. Type the host's code (or click **FIND FRIENDS** and pick the host).
2. Click **TEST CONNECTION** first. It should say the host is reachable and
   runs the same version, with a round-trip time.
3. Click **JOIN**, then follow the launcher as usual. The line at the bottom
   says "Connecting to your host..." and **clears** once you are connected
   (in 0.29.9 it stayed there all session).

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
for the whole session. The shared world is **on by default** in 0.30.0, so
`mp_shared_world on` is no longer needed. Then follow the shared-world steps
in `WO-124-first-shared-world-runbook.md` (from "Start it").

**Partner:** the first time in a world, the launcher window now shows two
buttons, **Bring my character** and **Start fresh**. Click one. Nothing is
typed in the game for the join any more.

**Host:** while your partner joins, your screen now says which step it is on
and for how long, e.g. "Anna is loading your world... 34 s", with a small
ladder under it (`[x] save [x] send [>] load 34 s [ ] ready`). If it sits on
one step for minutes, note the step and the seconds.

## 5. What should look different now

Watch for these; note the time of anything that still looks like 0.29.9.

* **The other player walks, runs and sprints with moving legs**, on both
  screens, and crouches, jumps and turns like a person. In 0.29.9 the figure
  slid along the ground with its legs still.
* **NPCs walking near the partner** move their legs on the partner's screen
  too (0.29.9: they slid).
* **Swings**: swing at each other (friendly fire is on) and, once, at an NPC
  away from town. The other screen must show your swing on your figure. This
  is the one fix that could not be tried with a real mouse click before
  release, so it matters most. If it does not show, say which weapon and when.
* **The partner dying leaves a grave** with their things where they died, and
  they wake up somewhere else (0.29.9 made no grave for the partner).
* **Wander apart** (a few hundred metres): the NPCs around the partner keep
  moving normally on the partner's screen.
* Players standing on a slope or stairs: if either of you sees the other one
  **sunk into the ground** to the knees or more, note where (the village or
  road) and the time.

## 6. Play normally

Ride, go into towns and houses, wander apart (far apart) and come back
together. Talk to people, trade, whatever you'd normally do. Nothing forced,
no need to hurry. Please do **not** attack townsfolk (one NPC away from town
for the swing check in section 5 is fine).

When you finish: host, `mp_leash_trace off` (or just quit; the file is kept).

## 7. What to send afterwards (both of you, before starting the game again)

* The launcher's **REPORT BUG** button makes one zip with the logs and the
  recorder files. Or collect by hand:
  * `kcd.log` from the Modding Tools folder (the next launch overwrites it);
  * `kcdmp-native.log` from the same folder;
  * `agent.log`, and the `leash` folder, beside `KcdMpClient.exe`;
  * the launcher's `app*.log`;
  * the host: the relay's `relay*.log`.
* The Steam probe report files, if you ran section 2.
* The times of anything odd, and what you saw.
* **Never send save files**, and not the `KCDMP\henry` folder either.
