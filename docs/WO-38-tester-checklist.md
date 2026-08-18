# KCD2 Multiplayer — Two-Player Test Checklist (WO-38 round)

For two real people on two real machines. No technical knowledge needed —
just play, watch, and write down what actually happened next to each item.
Where an item says "Player A", that's whoever is HOSTING; "Player B" is
whoever joined.

**Before you start (5 minutes, do not skip):**

- [ ] On BOTH machines, run `Verify-Install.ps1` (it's in the install folder)
      and confirm it says PASS. Last round, one machine was silently running
      a half-installed mix of old and new files, and several "bugs" may have
      been that. If it fails, re-run Setup with everything closed.
      *What happened:* ______
- [ ] Save your games first. This round pushes on sleeping, fighting and
      knocking people out.
- [ ] When you're done, please send back these files from BOTH machines —
      last round's launcher logs contained no game information at all, and
      these are the ones that do:
      - `kcd.log` from the game folder
      - the black agent console window's text (right-click its title bar →
        Edit → Select All, then Enter, and paste into a text file)
      - the launcher's `app.log`, same as last time

---

## 1. Sleeping and time of day (NEW — this is the big one)

- [ ] Both stand somewhere safe. Player B sleeps in a bed for ~8 hours.
      **Does Player A's time of day change to match** (sky, light, clock on
      the map screen)? It should catch up within a few seconds of B waking.
      *What happened:* ______
- [ ] Did a message appear on **A's** screen saying B passed time / slept,
      with a time like "8:00 AM"? (B should NOT see any such message — B has
      their own normal sleep screen.)
      *What happened:* ______
- [ ] Now both of you sleep at nearly the same time (B starts a few seconds
      after A). When you both wake: **is it the same time of day for both?**
      Do it twice. It should come out the same way both times.
      *What happened:* ______
- [ ] Player B uses the "wait" function (not a bed) — same checks as above.
      *What happened:* ______
- [ ] Player B fast travels somewhere far. When B arrives, does A's clock
      catch up (within ~30 seconds), with a "passed time" message on A's
      screen?
      *What happened:* ______
- [ ] After each of these: does anything feel BROKEN for the player whose
      clock was moved — hunger/energy suddenly different, a quest timer
      jumping, anything weird mid-conversation? Write down anything at all.
      *What happened:* ______

## 2. NPC flickering (the "teleporting 10,000 times a second" bug)

- [ ] AFTER doing section 1 (so your clocks match): both of you watch the
      same wandering villager from a few meters apart. Does he still flicker
      / teleport between two spots for either of you? This bug was suspected
      to be caused by your clocks being hours apart — with clocks synced it
      should be gone or much rarer.
      *What happened:* ______
- [ ] If you still see it: note WHO saw it (host or joiner), what time of day
      each of you had, and whether either of you had recently reconnected.
      *What happened:* ______

## 3. How the other player moves and jumps

- [ ] Watch the other player walk, run, and sprint. Is it smoother than last
      time — specifically, do they still do the "two steps forward, one step
      back" rubber-band thing?
      *What happened:* ______
- [ ] Have them JUMP a few times while you watch. Do you now see something
      jump-like (or at least their legs still moving), rather than a stiff
      statue rising into the air?
      *What happened:* ______

## 4. Death, knockouts, and dragging bodies

- [ ] One player dies in combat (sorry). On the OTHER player's screen: does
      the body now FALL / lie down instead of standing there like a statue?
      Is there a "[dead - reloading]" label if you walk up close?
      *What happened:* ______
- [ ] Player B knocks an NPC unconscious while A watches. On B's screen the
      NPC should stay down — NOT keep walking around half-buried in the
      ground like last time. What does A see?
      *What happened:* ______
- [ ] The HOST (Player A) kills an NPC, then drags the body a good distance
      while B watches. Does the body end up in the new spot for B too?
      (Note: if the JOINER does the dragging, it will NOT sync yet — that's
      a known limitation this round, not a bug to report.)
      *What happened:* ______

## 5. Horses

- [ ] Player B walks up to a horse that BOTH of you can see, and mounts it.
      Does B now ride THAT horse on A's screen — same horse, same colour —
      instead of a new gray one appearing?
      *What happened:* ______
- [ ] B rides around, then dismounts. Does the horse stay in the world on
      A's screen, and can A walk up and interact with it (pet it, mount it)?
      *What happened:* ______
- [ ] Does B's horse show up for A standing in roughly the right place even
      BEFORE anyone mounts it?
      *What happened:* ______
- [ ] If a wrong/gray horse still appears: whose horse was it (a wild one, a
      player-owned one, a stable one)? That detail matters a lot.
      *What happened:* ______

## 6. Combat visibility (expectation check — not fixed this round)

- [ ] When one player fights an NPC, the other will still NOT see swings and
      combat moves — that needs a whole new feature and is on the list. What
      you SHOULD check: does the fighting player at least move around
      (footwork) on your screen rather than standing totally frozen?
      *What happened:* ______

## 7. The screaming bug ("HELP! GET ME OUT OF HERE")

- [ ] Get one player's stand-in attacked so the yelling starts. Then, on the
      machine where you HEAR the yelling, open the console (~ key) and type:
      `mp_ghost_ignorant on`
      Does the yelling stop within a few seconds?
      *What happened:* ______
- [ ] IMPORTANT second half: with that still on, start another fight near
      the stand-in. Do NPCs still attack it like before? (If they now ignore
      it completely, write that down — it means this fix trades one problem
      for another and we need to know.)
      *What happened:* ______

## 8. Player markers on the map (experiment)

- [ ] On either machine, with the other player connected, open the console
      and type: `mp_map_marker sweep`
      Then open your map. Do you see ANY new icon on it (anywhere)? Try
      zooming around. Whatever you see or don't see, write it down — this
      is a yes/no experiment that decides how this feature gets built.
      *What happened:* ______

## 9. Clothes changing

- [ ] One player changes their FULL outfit — specifically including a plain
      shirt and plain pants (those were the ones that never showed up last
      time). Does the other player see the whole new outfit within ~30
      seconds? Which pieces are missing, if any?
      *What happened:* ______

## 10. The forge bug

- [ ] Recreate last round's forge moment: Player B starts smithing at a
      forge; Player A walks up close and just stands there. Does B take
      damage? If yes: does it also happen when A stays far away? And does
      B's stand-in (on A's screen) look like it's standing IN the fire or
      on the anvil? A screenshot from A's machine of where B's stand-in is
      standing would be gold.
      *What happened:* ______

---

**Anything else weird:** write it here, with roughly when it happened, so we
can find it in the logs you send back.

______
