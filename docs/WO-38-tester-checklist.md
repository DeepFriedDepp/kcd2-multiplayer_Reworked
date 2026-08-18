# KCD2 Multiplayer — Two-Player Test Checklist (updated for the WO-39 / 0.13.6 round)

For two real people on two real machines. No technical knowledge needed —
just play, watch, and write down what actually happened next to each item.
Where an item says "Player A", that's whoever is HOSTING; "Player B" is
whoever joined.

**Before you start (5 minutes, do not skip):**

- [ ] On BOTH machines, run `Verify-Install.ps1` (it's in the install folder)
      and confirm it says PASS. One round back, one machine was silently
      running a half-installed mix of old and new files, and several "bugs"
      may have been that. If it fails, re-run Setup with everything closed.
      *What happened:* ______
- [ ] Save your games first. This round pushes on sleeping, fighting and
      knocking people out.
- [ ] When you're done: in the launcher, open REPORT A BUG and press
      **COLLECT LOGS** on BOTH machines. It puts one zip on your Desktop
      with everything we need. Send those two zips back — that's it, no
      hunting for files this time.

---

## 1. Combat visibility (NEW this round — the headline)

- [ ] Player B draws their weapon while A watches B's stand-in. Does A see
      the weapon come OUT (a real sword in hand), and does the stand-in
      settle into a fighting stance (sword arm up) instead of standing
      relaxed?
      *What happened:* ______
- [ ] B sheathes the weapon. Does it visibly go away on A's screen, stance
      back to relaxed?
      *What happened:* ______
- [ ] B swings at the air a few times, spaced out. Does A see a quick
      aggressive sword movement for each swing? (Honesty note: it's a fast
      guard-swap cue, not a full authentic swing — the real swing animations
      are locked away by the engine. "I could tell he was attacking" is a
      pass; "identical to real combat" is not expected.)
      *What happened:* ______
- [ ] B holds a block. Does A see a block?
      *What happened:* ______
- [ ] B fights a REAL NPC for half a minute. Watching from A: can you
      roughly follow the fight (weapon out, movement, attack cues), rather
      than last round's "standing with arms down"?
      *What happened:* ______
- [ ] While one player fights an NPC the other can also see: does the NPC
      itself behave sanely on BOTH screens during the fight? (This one has
      never been observed with two humans — anything you see is new data.)
      *What happened:* ______

## 2. Dragging bodies (NEW: now works for BOTH players)

- [ ] Player B (the JOINER) knocks an NPC out or kills one, then drags the
      body a good distance while A watches. Does the body end up in the new
      spot on A's screen too? (Last round this only worked for the host —
      it's supposed to work for everyone now.)
      *What happened:* ______
- [ ] Same test the other way round (A drags, B watches).
      *What happened:* ______
- [ ] Both of you grab-drag near the SAME body within a second or two of
      each other. Does anything go visibly insane (body teleporting between
      two spots)? First-come should win quietly.
      *What happened:* ______

## 3. Knockouts and kills crossing over (IMPORTANT experiment)

- [ ] Player B knocks an NPC unconscious while A watches THE SAME NPC. On
      A's screen: does that NPC actually go down within a few seconds?
      If it stays "alive and well" for A, that confirms a specific bug we
      suspect (an ID mismatch between installs) — please note the NPC's
      name/description and roughly when.
      *What happened:* ______
- [ ] Same with a kill: B kills an NPC, does it die on A's screen too?
      *What happened:* ______

## 4. Sleeping and time of day

- [ ] Both stand somewhere safe. Player B sleeps in a bed for ~8 hours.
      **Does Player A's time of day change to match** (sky, light, clock on
      the map screen)? It should catch up within a few seconds of B waking.
      *What happened:* ______
- [ ] Did a message appear on **A's** screen — and does it now say B
      **"slept till"** (bed) with a time like "8:00 AM"? (B should NOT see
      any such message.)
      *What happened:* ______
- [ ] Player B uses the "wait" function (not a bed). Does A's message now
      say **"passed time to"** instead of "slept till"? (New this round —
      the game now knows the difference.)
      *What happened:* ______
- [ ] Player B fast travels somewhere far. When B arrives, does A's clock
      catch up (within ~30 seconds), with a "passed time" message on A's
      screen?
      *What happened:* ______
- [ ] After each of these: does anything feel BROKEN for the player whose
      clock was moved — hunger/energy suddenly different, a quest timer
      jumping, anything weird mid-conversation? Write down anything at all.
      *What happened:* ______

## 5. NPC flickering (the "teleporting 10,000 times a second" bug)

- [ ] AFTER doing section 4 (so your clocks match): both of you watch the
      same wandering villager from a few meters apart. Does he still flicker
      / teleport between two spots for either of you? (Solo testing this
      round could NOT reproduce it with a driven NPC — your converged-clock
      observation is the missing half.)
      *What happened:* ______
- [ ] If you still see it: note WHO saw it (host or joiner), what time of day
      each of you had, and whether either of you had recently reconnected.
      *What happened:* ______

## 6. How the other player moves and jumps

- [ ] Watch the other player walk, run, and sprint. Is it smoother than two
      rounds ago — specifically, do they still do the "two steps forward,
      one step back" rubber-band thing?
      *What happened:* ______
- [ ] Have them JUMP a few times while you watch. Do you now see something
      jump-like (or at least their legs still moving), rather than a stiff
      statue rising into the air?
      *What happened:* ______
- [ ] NEW: while a stand-in plays a combat move (swing/block), it briefly
      plants in place on purpose. Does that read okay, or does it look like
      lag? Honest opinion wanted.
      *What happened:* ______

## 7. Death poses

- [ ] One player dies in combat (sorry). On the OTHER player's screen: does
      the body now FALL / lie down instead of standing there like a statue?
      Is there a "[dead - reloading]" label if you walk up close?
      *What happened:* ______

## 8. Horses

- [ ] Player B walks up to a horse that BOTH of you can see, and mounts it.
      Does B now ride THAT horse on A's screen — same horse, same colour —
      instead of a new gray one appearing? (Confirmed working solo this
      round; two-install confirmation still wanted.)
      *What happened:* ______
- [ ] B rides around, then dismounts. Does the horse stay in the world on
      A's screen, and can A walk up and interact with it (pet it, mount it)?
      *What happened:* ______
- [ ] KNOWN ISSUE, please just describe rather than report as new: while B
      rides, A may see the horse slide without leg animations, wobble
      side-to-side, or dip into the ground. How bad is it on a scale of
      "noticeable" to "unwatchable"?
      *What happened:* ______
- [ ] Does B's horse show up for A standing in roughly the right place even
      BEFORE anyone mounts it?
      *What happened:* ______

## 9. The screaming bug ("HELP! GET ME OUT OF HERE")

- [ ] Solo testing could NOT reproduce the endless yelling this round (it
      stopped by itself). If you DO hear a stand-in stuck yelling on loop:
      on the machine where you hear it, open the console (~ key) and type
      `mp_ghost_ignorant on` — does it stop? Do NPCs still fight the
      stand-in afterwards? (Both answers matter.)
      *What happened:* ______

## 10. Clothes changing

- [ ] One player changes their FULL outfit — including a plain shirt and
      plain pants (those were the reported gap; solo testing this round
      showed them syncing and rendering fine, so if they DON'T cross for
      you, note it loudly). Does the other player see the whole new outfit
      within ~30 seconds? Which pieces are missing, if any?
      *What happened:* ______

## 11. The forge bug (still unconfirmed — this observation decides it)

- [ ] Recreate the original forge moment: Player B starts smithing at a
      forge; Player A walks up close and just stands there. Does B take
      damage? If yes: does it also happen when A stays far away? And does
      B's stand-in (on A's screen) look like it's standing IN the fire or
      on the anvil? A screenshot from A's machine of where B's stand-in is
      standing would be gold.
      *What happened:* ______

## 12. Player markers on the map (experiment, unchanged)

- [ ] On either machine, with the other player connected, open the console
      and type: `mp_map_marker sweep`
      Then open your map. Do you see ANY new icon on it (anywhere)? Whatever
      you see or don't see, write it down.
      *What happened:* ______

---

**Anything else weird:** write it here, with roughly when it happened, so we
can find it in the log zips you send back.

______
