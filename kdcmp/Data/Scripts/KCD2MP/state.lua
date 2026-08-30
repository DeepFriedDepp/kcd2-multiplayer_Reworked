-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

-- WO-50: release default is the debug HUD (build/memory/FPS corner block)
-- OFF. This is a mod-side CVar override, reasserted on every mod load,
-- not an engine config file -- it does not touch the base game's own
-- system.cfg/autoexec.cfg, and survives whatever CryEngine or the Modding
-- Tools build shipped as ITS default (observed live as r_DisplayInfo=3).
-- Deliberately unrelated to the ping/network indicator, which is the
-- mod's own System.DrawText call elsewhere in this file and is not an
-- engine overlay at all -- toggling this never touches it.
-- `mp_debug_hud on|off` flips it live without a rebuild, same pattern as
-- mp_dice_gate below.
KCD2MP.debugHud = false
if not KCD2MP.debugHud then
    System.SetCVar("r_DisplayInfo", "0")
end
KCD2MP.running = false
KCD2MP.interpRunning = false
KCD2MP.tickCount = 0
KCD2MP.ghosts = {}
KCD2MP.ghostNames = {}          -- id → steam name (received via 0x03 Name packet from server)
KCD2MP.ghostInMenu = {}         -- id → true while that player has a menu open (WO-13, set by agent on 0x1D)

-- ===== Shared player combat (WO-28) =====
-- id → {h, s, flags, at}  the OWNER's own authoritative health/stamina, set by
-- the agent from a PlayerStateDown (0x20). Rendered, never computed here: a
-- player's health is authoritative on that player's own machine, and that is
-- the only rule about it that cannot produce a disagreement which fails to
-- self-correct (docs/WO-26-shared-combat-design.md s3, Rule 1).
KCD2MP.ghostHealth = {}
KCD2MP.ghostDead = {}           -- id → true after a PlayerDeathDown (0x24); idempotent

-- Flow B damage sensor. id → last sampled LOCAL health of that ghost entity in
-- THIS world, and a one-shot skip flag set whenever an inbound authoritative
-- value is written over it. Only ever populated while KCD2MP.hitSensorOn.
KCD2MP.ghostHpSeen = {}
KCD2MP.ghostHpSkip = {}

-- Rule 2: only ONE client's NPC simulation may generate NPC→player hits, or N
-- peers produce N independent damage streams for one conceptual fight and the
-- damage multiplies by N. The relay designates that client and the agent sets
-- this from a CombatRole (0x25) packet. Off until told otherwise -- a client
-- that has not been told it holds authority must never assume it does.
KCD2MP.hitSensorOn = false
KCD2MP.labelCache = {}          -- id → {x,y,z,size,name}  updated by interp, drawn by render loop
KCD2MP.labelRunning = false
KCD2MP.horseGhosts = {}         -- id → {entity, entityId, isWorldHorse, worldName} horse per player
KCD2MP.ghostHorseName = {}      -- id → authored name of the horse that player is riding (WO-38 Phase 5, via 0x2B); "" / absent = unknown
KCD2MP._mountedHorseName = nil  -- authored name of the horse the LOCAL player is on (riding check, Method 0)
KCD2MP.horseAdoptEnabled = true -- WO-40 Phase 0: mp_horse_adopt on|off -- field escape hatch for the mount-crash suspect (off = proxy horses only)
-- WO-40 Phase 9: ghosts are stimulus-deaf BY DEFAULT now. The chain that
-- earned this: WO-38 recommended it (a ghost has no player behind its
-- reactions; every stimulus response is noise), WO-39 live-verified
-- AI.SetIgnorant is targeting-safe (an ignorant ghost stays hittable and
-- still fights back when attacked -- damage response is not a stimulus), and
-- the 2026-08-18 footage showed the cost of leaving it off: a pickpocketed
-- ghost's brain drew a sword and stayed PERSISTENTLY hostile to the other
-- player while its owner sat in a menu. mp_ghost_ignorant off restores the
-- old behaviour.
KCD2MP.ghostsIgnorant = true
-- WO-65: ghost civic isolation (default on). What it actually does on THIS
-- build is the dialog half only -- RestrictDialog + InterruptDialogs, both
-- live-verified 2026-08-27. The script-context half (the real crime fix) has
-- no Lua-reachable setter here; see KCD2MP_ApplyGhostIsolation.
KCD2MP.ghostIsolate = true
KCD2MP._horseInfoSentName = nil -- last horse_info payload actually emitted (change gate)
KCD2MP._horseInfoSentAt = 0     -- for the 30s re-emit while mounted (late joiners)
KCD2MP.workingClass = "AnimObject"
KCD2MP.playerSneaking = false   -- set by OnAction hook when sneak key pressed
KCD2MP.isRiding = false         -- updated each interp tick (player on horse detection)
KCD2MP.logActions = false       -- set true only to discover action names (floods log)

-- ===== Combat visibility (WO-39 Phase 1) =====
-- The WO-38 Phase 4 gap: nothing combat-shaped was ever shared, so a fighting
-- player's ghost stood motionless with arms down. Outbound: the local weapon
-- drawn/sheathed state (polled from Human.IsWeaponDrawn) and swing/block
-- inputs (OnAction hook) ride the event line as "combat <word>"; the agent
-- puts them on the wire as CombatEventUp (0x2C). Inbound: KCD2MP_GhostCombat
-- applies them to the ghost -- DrawWeapon/HolsterWeapon plus one-shot
-- animations. Cosmetic only: no damage flows through this path.
KCD2MP.weaponDrawn = false      -- local player's last polled drawn state
KCD2MP._weaponPollAt = 0        -- last IsWeaponDrawn poll (throttled to 5 Hz)
KCD2MP._weaponEmitAt = 0        -- last "combat draw" emission (30s heartbeat while drawn)
KCD2MP._weaponReadOk = nil      -- nil=not probed, false=IsWeaponDrawn unavailable, true=working
KCD2MP.ghostWeaponDrawn = {}    -- id → true while that peer reports weapon drawn
KCD2MP._lastSwingEmit = 0       -- rate limit for swing event emission
KCD2MP._blockHeld = false       -- edge detector: 'block' only ever fires hold/release

-- WO-17: opt-in, off by default, decided locally per player -- see
-- KCD2MP_EnableAggro. Persists for the session (a plain Lua global survives
-- until the mod restarts); never auto-enabled, never negotiated with a peer.
KCD2MP.aggroEnabled = false


KCD2MP.modules.state = true
