# KCD2 MP Footage Findings — Document 2

Initially, animations are significantly improved. Players who are running
actually run now, rather than taking 2 steps forward and one step back and
stuttering. Animation wise, when someone sleeps, the person sleeping just
stands. There is no animation for it. I wonder if there is a way to pull
and extract animation data to map onto the other players who are not the
host.

It seems that the host is the one with very few issues. Occasionally
Player B gets the NPC stuttering tug-of-war bug, but Player A has never
observed it.

Time syncing works when someone sleeps or waits, and is observed by both
Player A and B, syncing the new times for both. It also correctly
displays the notification in the center screen that
`<player slept till xxx PM>`.

Jumping animations are still not synced, it still looks as if the player,
whether it is PA or PB, just vertically changes positions, rather than
showing the arms moving and legs crouching slightly as the jump occurs.
The same thing occurs when a player hops a fence. On the player's screen,
they put their hand on the fence and leap over it, but on the observer's
screen they just walk through the fence or go directly upwards over it.

Player B sees wandering NPCs sometimes with broken animations, looking as
if they are phasing forward rather than actually walking. When Player B
knocks out an NPC and picks him up, nothing happens for the observer, PA.
The NPC continues walking. The NPC phases upwards as if jumping for a
moment, and then continues walking on PA's screen. On PB's screen, the
NPC phases into the ground like before. Then the NPC syncs for PB, but is
again walking but is on the ground as if knocked out. When Player B picks
up the body, it again phases upwards onto PB's shoulders for a moment and
then goes back to walking. It seems like additional tug of war is
happening.

Player B attacked a guard that was synced for both players, and PA
observed. PB talked to the guard to get out of the situation, but for PA
the guard did not ever stop to talk and just continued walking, breaking
the sync. When PB left the conversation, it synced for PB that the guard
was now near the observer, PA. PA took his weapon and began fighting,
while PB observed. PA was phasing aggressively into the ground whilst
fighting, and to PB, the guard was not doing any attack animations of any
kind. It looked as if 2 NPCs were standing and facing each other, while to
PA, he was in active combat, doing things like swinging, stabbing,
blocking, parrying etc.

At this point, PA was killed and was forced to reload a save. When PA
reverted to a save, PA was observing the world at daytime. However, this
time never synced over to PB, so PB was now in nighttime, which caused
more NPC tug-of-war issues.

PA and PB then, during different times of the day (PA on day, PB on
night) began fighting an NPC. Again, the NPC once aggroed did not perform
any animations at all whatsoever, and for PB, was standing still facing
PA. The moment that PB jumped into the fight, the NPC looked as if he was
laying down halfway phased through the ground, while PA continued to
fight a real attacking NPC.

Horses now work as expected. It does not spawn in a new horse or anything
of the sort. As known from the previous WO, the animations for players
observed riding a horse could certainly be improved.

The NPC brain that a player occupies also reacts like a normal NPC, which
is not acceptable. For example, PA is observing PB at the forge. PB
inhabits a "Woodcutter Foreman" soul. PA pickpockets PB and gets caught.
PB goes into his menu, but on PA's screen, PB draws his sword and starts
yelling at PA to go away. Now that PB's soul is aggroed on PA, anytime
they are around each other the little bunny indicator states that PA is
being aggroed on, and when close enough, PA is forced into the fighting
stance as if he is being attacked.

Both players fast travel to the same place from roughly the same distance
at the same time. For PB, once he arrives, he gets a notice that PA
advanced time to a specific time and date — assumed related to the time
syncing, as expected. When PA and PB arrive, they walk to the same spot,
where for PA there is a dead bandit body lying in the street that is not
observable by PB. Additionally, PB then fast travels away and back to the
same spot, which seems to break animation for PB walking as PA observes.
PB now does the 2-steps-forward-one-step-back jittery animation again.

PA and PB walk up to a guard standing at a gate. For PA, there is only the
one guard, but for PB, there are 2 guards phased into each other. Likely a
tug-of-war of a different shape — rather than deciding who syncs what,
PB's game seems to have synced both: whatever would have been there for
his world, AND whatever PA is seeing. They then walk up to a hired hand
working on a wagon. For PA, the wagon worker is doing his normal
animations, while for PB, he is phasing horrifically, similar to the
tug-of-war issue, moving between 3 points seemingly thousands of times
per second. At this point, no NPCs for PB have any animation at all.
Wandering NPCs are standing in place, scooting forward, almost as if
T-posing in classic "broken video game animation" fashion, while for PA
everything is normal.

Weather is not synced at all. For PA and PB it is different — for PA it
is sunny, for PB it is foggy. This likely also affects NPC syncing, since
NPCs behave differently depending on weather, so this needs to sync too.

Another observed instance of NPC combat: PB observes as PA walks up
behind an NPC. PA chokes the NPC out and she falls to the ground. For PB,
it looks as if PA holds up a shield for a brief moment. The NPC then
looks as if she is sitting down for a moment, while on PA's screen the
NPC is now falling to the ground. Once the NPC hits the ground on PA's
screen, the NPC then walks away normally on PB's screen.

PA and PB both reload completely different saves at the same time. This
causes major NPC syncing issues for PB immediately — the same tug-of-war
phasing issue as before.

Both players talk to the same NPC at the same time. This does not seem
to cause any major issues aside from already-existing NPC sync issues.
For PA, there are no NPCs walking behind him, but for PB, there are
observable NPCs walking behind — both while in the same dialogue windows.

PB pauses his game and an NPC in the distance freezes, but for PA, who is
not paused, the world continues on. This likely also causes major NPC
sync issues, because whenever someone pauses their game or opens the
inventory, the world stops for them. Then when unpausing or exiting the
inventory, there is a gap in what players around the world have been
doing for each person in the meantime.
