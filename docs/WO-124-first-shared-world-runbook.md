# The first shared-world session (two machines)

For the maintainer (the **host**) and one partner (the **joiner**). About 20
minutes. What it proves: the partner's own character arrives in your world
and plays there. Background: `docs/WO-124-findings.md`.

## Before you start

* Both machines on a build of `main` at `fbc890e` or later (WO-124 made no
  installer: build one with `tools\Build-Installer.ps1` when you decide to).
* The **partner** has a save of their own (any playthrough). The game brings
  their **newest** save's character. To pick another one, before joining, in
  the console (`~`): `mp_join_henry playline2/save021` (their playline/file).
* The host is in the world in **daytime**, somewhere quiet, not in a fight,
  dialogue or cutscene. **Make a save of your own first** (it is your world).
* Host starts first: the host's launcher **Host** (relay on this machine).

## Start it

1. **Host**: launcher → Host → Launch. Load your save. Console (`~`):
   `mp_shared_world on`. You should read `WO122-TOGGLE shared_world=on`.
2. **Joiner**: launcher → Join (host's address) → Launch. **Stay at the main
   menu.** Do not press Continue.
3. Wait. Nothing to click on either side.

## What each screen should say

| when | host | joiner (launcher banner) |
|---|---|---|
| joiner connects | — | "Waiting for your host..." |
| host busy (fight, dialogue, loading) | nothing | "Your host is busy, you'll join in a moment." |
| host pauses | "<partner> is joining... [bar] N%" — world frozen, keys dead | "Your host is saving the world..." then "Receiving the world... N%" |
| joiner prepares | same | "Preparing your character..." |
| joiner loads (about 50-60 s, loading screen) | "<partner> is loading the world..." | "Loading your host's world..." |
| in | world resumes by itself | "In your host's world." + in game: "Co-op: you are in your host's world." |

The joiner arrives **3 m beside the host**, with their own character (money,
items, skills), in the host's world (time, NPCs, quests).

## Try

* Walk together; talk to an NPC; a fist fight with each other (friendly fire
  is on); one of you rides a horse and gets off (the partner's avatar must
  come off it, WO-124 6a).
* Joiner: the pause menu's **Save & Quit** is greyed out. That is correct:
  only the host saves this world. (Try Save Game too and note what it does.)
* Host: `mp_world_save` writes a world save (an autosave in your playline).

## Expected not to work yet

* **The joiner's progress is not kept.** When they quit, the launcher says
  "Your progress in shared worlds isn't saved yet." Their own saves are
  untouched; next time, Continue loads their own game. (WO-125)
* **No "back to the main menu"** in KCD2. If the host leaves, or a check
  fails, the joiner is told and their **own** newest save loads.
* Rejoining starts again from the joiner's newest own save.
* A host reload does not take the joiner along (WO-125).
* Already in a world when connecting? The joiner is told to quit, restart and
  wait at the main menu.

## If it goes wrong

* Host stuck frozen: console `mp_join_cancel` (the world resumes at once). It
  also resumes by itself after 180 s.
* Joiner stuck on the loading screen for more than 3 minutes: quit the game;
  the host resumes by itself.
* Anything else: note the time, carry on or stop, and capture (below).

## Capture afterwards (both machines, before relaunching the game)

* `kcd.log` from the Modding Tools folder (the next launch overwrites it).
* The agent log (`agent.log` beside `KcdMpClient.exe`) and
  `kcdmp-native.mirror.log` (Modding Tools folder).
* The host: the relay's log, if the launcher kept one.
* Screenshots of anything odd.
* Do **not** send save files around (every save names the machine's account);
  the joiner's received world is deleted by itself.

Lines worth grepping: `MP-JOIN`, `MP-SAVELOCK`, `MP-JOINPLACE`, `MP-DISMOUNT`,
`WO124-`, `Game load failed`.
