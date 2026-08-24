-- KCD2 Multiplayer - Mod Init Script
System.LogAlways("[KCD2-MP] === MOD INIT ===")

KCD2MP = {}
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

-- ===== Debug Logger =====
-- Messages are queued in KCD2MP.debugLog (max 50).
-- Server polls KCD2MP_PopLog() via evalLua and prints to its console.
KCD2MP.debugLog = {}
local MP_LOG_MAX = 50

local function mp_log(msg)
    local entry = string.format("[%.2f] %s", os.clock(), msg)
    table.insert(KCD2MP.debugLog, entry)
    if #KCD2MP.debugLog > MP_LOG_MAX then
        table.remove(KCD2MP.debugLog, 1)
    end
    System.LogAlways("[KCD2-MP] " .. msg)
end

-- Server calls this via evalLua to dequeue one message at a time
function KCD2MP_PopLog()
    if #KCD2MP.debugLog > 0 then
        return table.remove(KCD2MP.debugLog, 1)
    end
    return ""
end

mp_log("MOD INIT")

-- ===== Math Helpers =====

local function lerpVal(a, b, t)
    return a + (b - a) * t
end

-- Shortest-path angle lerp (radians), handles -pi/pi wrap
local function lerpAngle(a, b, t)
    local diff = b - a
    local twopi = math.pi * 2
    diff = diff - math.floor((diff + math.pi) / twopi) * twopi
    return a + diff * t
end

local function clamp(v, lo, hi)
    if v < lo then return lo elseif v > hi then return hi end
    return v
end

-- ===== Ping Display =====
-- Called by C# every ~2s after Pong. Stored for render loop to draw via DrawLabel.
-- Game.ShowNotification adds unwanted "@" decorators so we use DrawLabel instead.
function KCD2MP_ShowPing(ms)
    KCD2MP.ping = ms
    KCD2MP.pingText = string.format("Ping: %d ms", ms)
end

-- ===== Player Position =====

function KCD2MP_GetPos()
    if player then
        local pos = player:GetWorldPos()
        if pos then
            System.LogAlways(string.format("[KCD2-MP] pos: x=%.1f y=%.1f z=%.1f", pos.x, pos.y, pos.z))
            return pos
        end
    else
        System.LogAlways("[KCD2-MP] player is nil")
    end
    return nil
end

-- ===== Outbound State Emitter (WO-1) =====
-- The game has no push channel, so the agent used to poll: one HTTP call for
-- position plus two more to stuff yaw and mount state through the sv_servername
-- CVar and read it back. Measured at ~128 ms for one full sample, capping the
-- sync loop at 7.8 samples/s.
--
-- System.LogAlways costs ~20 us per line and kcd.log is readable by an external
-- tailer roughly 45 ms later, so the game can simply push instead. This emits
-- one line per tick; KcdMpClient tails the log. Three round trips become zero
-- and the rate becomes whatever this timer runs at.
--
-- Line format, space separated, fixed field count:
--   [KCD2-MP-DATA] v2 <seq> <clock> <x> <y> <z> <rotZ> <flags> <health> <stamina>
--
--   seq    monotonic, so the tailer can spot drops and reordering
--   clock  os.clock() at emit, so the agent can age the sample
--   flags  bit0 riding, bit1 sneaking, bit2 dead, bit3 unconscious   (2 and 3 are v2)
--
-- The version token is first so the parser can reject anything it does not
-- understand rather than misread it. Bump it on any field change.
--
-- WO-28 Flow A raised this v1 -> v2, appending health and stamina. WO-26
-- Phase 3 measured why: the line carried position, rotation and two booleans,
-- so when a test ghost was killed the player it represented kept playing at
-- full health and no peer had any way to know otherwise.
--
-- The agent parses BOTH versions (LogTailGameTransport). The pak and the agent
-- are separately installed and update independently, so a new agent reading an
-- old pak's v1 lines is an ordinary state, not a broken one: it degrades to
-- "health unknown" rather than rejecting every line.
--
-- Death rides here as a flag bit rather than as its own event line because the
-- emitter already runs at ~50 Hz and this costs nothing. It is still the
-- *dying player's own client* that declares the death on the wire (Protocol
-- 0x23) -- a peer never infers it from the health field reaching zero.
KCD2MP.emitRunning = false
KCD2MP.emitSeq = 0
KCD2MP.emitIntervalMs = 20

local EMIT_VERSION = "v2"

-- -1 = "no reading available", never a fake zero. Mirrors Protocol.UnknownStat
-- on the agent side; a receiver must be able to tell "this build cannot read
-- stamina" from "that player is exhausted".
local STAT_UNKNOWN = -1

-- Every binding below was enumerated and read live against the running game
-- (2026-08-07) rather than guessed, because the obvious names are wrong here:
--
--   player.actor:GetHealth()          -> 100        (also used by WO-26)
--   player.soul:GetState("stamina")   -> 126.667
--   player.actor:IsDead()             -> false
--   player.actor:IsUnconscious()      -> present on the actor metatable
--
-- and, confirmed NOT to exist on this build, so nothing should reach for them
-- again: player.actor:GetStamina, player.soul:IsDead, player.soul:IsUnconscious,
-- player:IsDead, player.human:IsDead, and GetState("dead"/"unconscious") --
-- the last two return nil rather than erroring, which is the more dangerous
-- shape: a pcall around them succeeds and yields a falsey "not dead" that was
-- never actually measured.
--
-- Reads the local player's own health/stamina/liveness. Every read is pcall'd
-- individually: a binding that disappears in a future patch must degrade one
-- field, not blank the whole state line and stop position sync with it.
function KCD2MP_ReadSelfVitals()
    local health, stamina = STAT_UNKNOWN, STAT_UNKNOWN
    local dead, unconscious = false, false
    if not player then return health, stamina, dead, unconscious end

    if player.actor then
        pcall(function() health = player.actor:GetHealth() end)
        -- Death is read, never derived from health reaching zero: KCD2 has a
        -- real unconscious state distinct from death (WO-22's A1 was an
        -- unending unconsciousness that the knockdown had registered
        -- correctly), so "health is 0" and "dead" are genuinely different
        -- facts and only one of them should make peers see a death.
        pcall(function() dead = player.actor:IsDead() and true or false end)
        pcall(function() unconscious = player.actor:IsUnconscious() and true or false end)
    end

    if player.soul then
        pcall(function()
            local v = player.soul:GetState("stamina")
            if type(v) == "number" then stamina = v end
        end)
    end

    -- Test override (mp_fake_death). Deliberately applied last and only ever
    -- forces "dead" ON: Gate 2 needs a death that peers can observe end to end,
    -- and the only alternative is asking a human to actually die on a real
    -- save. It can never mask a REAL death into looking alive, which is the
    -- one direction that would be dangerous to have in shipped code.
    if KCD2MP.fakeDeadUntil and os.clock() < KCD2MP.fakeDeadUntil then
        dead = true
    end

    return health, stamina, dead, unconscious
end

-- Reports this player as dead for `secs` seconds (default 20), so Flow C can be
-- observed end to end without a real death and a real save reload. Local only:
-- it changes what this client says about itself, which is exactly the thing
-- Rule 1 makes authoritative, so peers react to it identically to a real death.
function KCD2MP_FakeDeath(secs)
    local n = tonumber(secs) or 20
    KCD2MP.fakeDeadUntil = os.clock() + n
    mp_log(string.format("FAKE_DEATH reporting dead for %.0fs", n))
    KCD2MP_ShowInteractionMsg(string.format("Reporting death for %ds (test)", n))
end

-- Builds and writes one state line. Returns false when the player is not in a
-- state worth reporting (no world, mid-load).
function KCD2MP_EmitState()
    if not player then return false end

    local pos = nil
    pcall(function() pos = player:GetWorldPos() end)
    if not pos then return false end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local rotZ = ang and ang.z or 0

    local health, stamina, dead, unconscious = KCD2MP_ReadSelfVitals()

    local flags = 0
    if KCD2MP.isRiding      then flags = flags + 1 end
    if KCD2MP.playerSneaking then flags = flags + 2 end
    if dead                 then flags = flags + 4 end
    if unconscious          then flags = flags + 8 end

    KCD2MP.emitSeq = KCD2MP.emitSeq + 1
    System.LogAlways(string.format("[KCD2-MP-DATA] %s %d %.3f %.3f %.3f %.3f %.4f %d %.2f %.2f",
        EMIT_VERSION, KCD2MP.emitSeq, os.clock(), pos.x, pos.y, pos.z, rotZ, flags, health, stamina))
    return true
end

-- Every *Running flag in this file means "we intended this loop to run", NOT
-- "this loop is running". A save load destroys every pending Script.SetTimer
-- while leaving the globals set, so the flag stays true over a dead chain --
-- and because the Start* functions below early-return on the flag, nothing
-- could ever restart it. Observed live (WO-13): after a save load,
-- emitRunning and interpRunning both read true with ZERO heartbeats and zero
-- emitted frames for as long as you care to wait, and every remote player's
-- ghost stands frozen.
--
-- So each loop stamps a heartbeat, and the Start* functions treat a stale
-- stamp as "not actually running" and restart regardless of the flag.
local TICK_ALIVE_WINDOW = 1.0   -- seconds; all three loops run far faster

local function tickAlive(flag, stamp)
    return flag and stamp and (os.clock() - stamp) < TICK_ALIVE_WINDOW
end

-- WO-39 Phase 1, outbound drawn-state half. Rides the emit tick but is
-- throttled to 5 Hz -- a draw/sheathe is a once-in-a-while transition, not a
-- position stream. Human.IsWeaponDrawn() is documented ("return true if human
-- have any weapon set active"); if this build does not actually register it,
-- the read degrades to "drawn-state sync disabled", logged once, and nothing
-- else in the emitter is touched -- the same per-field degradation discipline
-- as KCD2MP_ReadSelfVitals.
function KCD2MP_PollWeaponDrawn()
    if not (player and player.human) then return end
    if KCD2MP._weaponReadOk == false then return end
    local now = os.clock()
    if now - (KCD2MP._weaponPollAt or 0) < 0.2 then return end
    KCD2MP._weaponPollAt = now

    local drawn = nil
    pcall(function()
        if player.human.IsWeaponDrawn then
            drawn = player.human:IsWeaponDrawn() and true or false
        end
    end)
    if drawn == nil then
        KCD2MP._weaponReadOk = false
        mp_log("CombatViz: Human.IsWeaponDrawn unavailable -- drawn-state sync disabled")
        return
    end
    if KCD2MP._weaponReadOk == nil then
        KCD2MP._weaponReadOk = true
        mp_log("CombatViz: IsWeaponDrawn readable, initial=" .. tostring(drawn))
        -- Prime without emitting: a peer's ghost starts sheathed, so only a
        -- drawn initial state is worth announcing.
        KCD2MP.weaponDrawn = drawn
        if drawn then
            KCD2MP._weaponEmitAt = now
            KCD2MP_EmitEvent("combat", "draw")
        end
        return
    end

    if drawn ~= KCD2MP.weaponDrawn then
        KCD2MP.weaponDrawn = drawn
        KCD2MP._weaponEmitAt = now
        KCD2MP_EmitEvent("combat", drawn and "draw" or "sheathe")
    elseif drawn and now - (KCD2MP._weaponEmitAt or 0) >= 30 then
        -- Heartbeat while drawn, so a late joiner converges (the relay is
        -- stateless and replays nothing). Sheathed is the default state and
        -- needs no heartbeat.
        KCD2MP._weaponEmitAt = now
        KCD2MP_EmitEvent("combat", "draw")
    end
end

-- WO-39 Phase 8: skip-kind detection, second route. kcd.log was a confirmed
-- dead end (WO-38 diffed a real bed sleep against a real wait at verbosity 4
-- -- nothing distinguishes them). The bed interaction itself is detectable
-- instead: a usable bed presents a BedTrigger-class entity (observed live,
-- 1.1 m from a player standing at a tavern bed), so "was the player at a bed
-- when the skip started" answers sleep-vs-wait. Polled at 1 Hz on the emit
-- tick; transitions ride the event line so the agent always holds the latest
-- value before any skip marker can arrive.
KCD2MP.bedNear = false
KCD2MP._bedPollAt = 0

function KCD2MP_PollBedNear()
    local now = os.clock()
    if now - (KCD2MP._bedPollAt or 0) < 1.0 then return end
    KCD2MP._bedPollAt = now
    if not player then return end
    local near = false
    pcall(function()
        local pp = player:GetWorldPos()
        local ents = System.GetEntitiesInSphere(pp, 3) or {}
        for _, e in ipairs(ents) do
            if tostring(e.class or "") == "BedTrigger" then near = true; break end
        end
    end)
    if near ~= KCD2MP.bedNear then
        KCD2MP.bedNear = near
        KCD2MP_EmitEvent("bed_near", near and "1" or "0")
    end
end

function KCD2MP_EmitTick()
    if not KCD2MP.emitRunning then return end
    Script.SetTimer(KCD2MP.emitIntervalMs, KCD2MP_EmitTick)  -- reschedule FIRST: a Lua error must not kill the stream
    KCD2MP._emitAliveAt = os.clock()

    local ok, err = pcall(KCD2MP_EmitState)
    if not ok then
        -- Report once rather than every tick; at 50 Hz a hot error would bury the log.
        if not KCD2MP._emitErrLogged then
            KCD2MP._emitErrLogged = true
            System.LogAlways("[KCD2-MP] EmitTick error: " .. tostring(err))
        end
    end
    pcall(KCD2MP_PollWeaponDrawn)   -- WO-39: throttled internally to 5 Hz
    pcall(KCD2MP_PollBedNear)       -- WO-39 Phase 8: throttled internally to 1 Hz
end

-- intervalMs is optional; the agent passes its configured rate.
function KCD2MP_StartEmitter(intervalMs)
    if intervalMs and intervalMs >= 5 then KCD2MP.emitIntervalMs = intervalMs end
    if tickAlive(KCD2MP.emitRunning, KCD2MP._emitAliveAt) then return end
    KCD2MP.emitRunning = true
    KCD2MP._emitAliveAt = os.clock()   -- prime it: the first tick is one interval away
    KCD2MP._emitErrLogged = false
    System.LogAlways("[KCD2-MP] State emitter started (" .. KCD2MP.emitIntervalMs .. "ms)")
    Script.SetTimer(KCD2MP.emitIntervalMs, KCD2MP_EmitTick)
end

function KCD2MP_StopEmitter()
    KCD2MP.emitRunning = false
    System.LogAlways("[KCD2-MP] State emitter stopped after " .. KCD2MP.emitSeq .. " lines")
end

-- Legacy name, kept because the 500 ms KCD2MP_Tick calls it. Delegates so there
-- is only ever one [KCD2-MP-DATA] format for the tailer to parse.
function KCD2MP_WritePos()
    return KCD2MP_EmitState()
end

-- ===== Outbound Events (WO-2) =====
-- A second line type on the same log channel, for discrete things the player
-- did rather than continuous state. Accepting an invite has to travel game →
-- agent, and the log tail is the only outbound path (no sockets, no io), so it
-- rides here instead of resurrecting the sv_servername CVar hack.
--
--   [KCD2-MP-EVT] v1 <seq> <name> <arg>
--
-- Sequence numbers are separate from the state stream so a dropped position
-- frame cannot be mistaken for a dropped event.
KCD2MP.evtSeq = 0

function KCD2MP_EmitEvent(name, arg)
    KCD2MP.evtSeq = KCD2MP.evtSeq + 1
    System.LogAlways(string.format("[KCD2-MP-EVT] v1 %d %s %s",
        KCD2MP.evtSeq, tostring(name), tostring(arg or "")))
end

-- ===== Interaction Prompt UI (WO-2) =====
-- Drawn from the existing 8 ms label loop via System.DrawText. Game.ShowNotification
-- was already rejected for injecting '@' decorators, and DrawLabel is world-space,
-- so screen-space DrawText is the right tool for a prompt.
KCD2MP.invite = nil            -- {sid, who, kind, shownAt}
KCD2MP.interactionMsg = nil    -- {text, shownAt}
KCD2MP.diceTurn = nil          -- {text} -- optional glanceable hint; the launcher window is the real dice UI

local INVITE_TIMEOUT   = 30    -- matches the relay's invite expiry
local MSG_TIMEOUT      = 5

-- Called by the agent when a peer invites this player. wager (WO-33) is
-- groschen at stake, 0 for none -- shown in the prompt so the player knows
-- what's riding on it before answering, and checked against player.inventory:GetMoney()
-- in KCD2MP_AcceptInvite before an accept is actually sent.
function KCD2MP_ShowInvite(sid, who, kind, wager)
    KCD2MP.invite = { sid = sid, who = tostring(who), kind = tostring(kind),
                       wager = tonumber(wager) or 0, shownAt = os.clock() }
    mp_log("INVITE from " .. tostring(who) .. " (" .. tostring(kind) .. ") session " .. tostring(sid)
        .. " wager=" .. tostring(KCD2MP.invite.wager))
end

function KCD2MP_HideInvite()
    KCD2MP.invite = nil
end

-- Transient feedback: "Declined", "PeerDisconnected", and so on.
function KCD2MP_ShowInteractionMsg(text)
    KCD2MP.interactionMsg = { text = tostring(text), shownAt = os.clock() }
end

function KCD2MP_AcceptInvite()
    if not KCD2MP.invite then
        mp_log("No invite to accept")
        return false
    end

    -- WO-33: refuse locally, before the match ever starts, rather than
    -- discovering mid-game that a loss can't actually be paid. RemoveMoney
    -- itself already refuses to go negative (per the shipped scriptbind docs),
    -- but that's a safety net, not a substitute for telling the player why.
    local wager = KCD2MP.invite.wager or 0
    if wager > 0 then
        local ok, have = pcall(function() return player.inventory:GetMoney() end)
        if not ok or not have or have < wager then
            mp_log("Cannot accept: wager " .. tostring(wager) .. " exceeds balance "
                .. tostring(ok and have or "?"))
            KCD2MP_ShowInteractionMsg("Not enough groschen for that wager")
            return false
        end
    end

    KCD2MP_EmitEvent("invite_accept", KCD2MP.invite.sid)
    KCD2MP_HideInvite()
    KCD2MP_ShowInteractionMsg("Accepted")
    return true
end

function KCD2MP_DeclineInvite()
    if not KCD2MP.invite then return false end
    KCD2MP_EmitEvent("invite_decline", KCD2MP.invite.sid)
    KCD2MP_HideInvite()
    KCD2MP_ShowInteractionMsg("Declined")
    return true
end

-- WO-9: honest floor for appearance sync. The agent normally polls
-- EquipmentManager.EquippedArmorsByClassId itself (no Lua involved in
-- detection at all -- that read goes straight over the debug REST API), but
-- a player who wants to force it right now rather than wait for the poll or
-- the heartbeat can run this. Same event-channel pattern as invite_accept.
function KCD2MP_SyncAppearance()
    KCD2MP_EmitEvent("appearance_sync", "")
    mp_log("Requested immediate appearance resync")
    KCD2MP_ShowInteractionMsg("Appearance resync requested")
end

-- WO-11: honest floor for pause detection, same idea as KCD2MP_SyncAppearance
-- above. The agent watches kcd.log itself for the menu/inventory/skip-time
-- markers that were confirmed live (docs/WO-11-findings.md) -- no Lua
-- involved in detection there either -- but a tutorial popup and photo mode
-- were never confirmed to emit one, so this lets a player declare "I'm
-- effectively unavailable" by hand regardless of the reason. Toggles: this
-- side has no way to know whether the agent currently considers us paused,
-- so it just flips a manual flag and lets GameBridge OR it with automatic
-- detection.
function KCD2MP_SlowTime()
    KCD2MP_EmitEvent("slow_time_toggle", "")
    mp_log("Requested manual slow-time toggle")
end

-- ===== Time-skip sync (WO-38 Phase 1) =====
-- Day/night synchronisation. Calendar.SetWorldTime is the one Lua world
-- mutation ever verified working in this project (ARCHITECTURE-shared-world.md:
-- +3600 moved the clock exactly one hour, live), and its own scriptbind doc
-- says "Must not be set backwards" -- so every apply here is forward-only.
-- Detection of the local player's own skips lives agent-side (the kcd.log
-- AfterSkipTime markers, WO-11); Lua only answers "what time is it" and
-- applies/announces a peer's resolved skip.

-- A world day is 86,400 world-seconds. Consistent with the live WO-era
-- observation: worldTime 388805 % 86400 = 43205 s = 12.0014 h, matching the
-- hour 12.0015 read in the same probe.
local WORLD_DAY_SECONDS = 86400

-- Called by the agent (skip end, plus a ~10 s poll for the clock-jump
-- watcher). Rides the ordinary event channel.
function KCD2MP_ReportWorldTime()
    local ok, t = pcall(function() return Calendar.GetWorldTime() end)
    if ok and t then
        KCD2MP_EmitEvent("time_now", tostring(math.floor(t)))
    else
        mp_log("ReportWorldTime: Calendar.GetWorldTime unavailable")
    end
end

-- "8:00 AM" from a worldTime in seconds-from-level-start.
function KCD2MP_FormatWorldTime(t)
    local secOfDay = t % WORLD_DAY_SECONDS
    local h = math.floor(secOfDay / 3600)
    local m = math.floor((secOfDay % 3600) / 60)
    local ampm = (h >= 12) and "PM" or "AM"
    local h12 = h % 12
    if h12 == 0 then h12 = 12 end
    return string.format("%d:%02d %s", h12, m, ampm)
end

-- Called by the agent when a peer's skip resolves. who = their display name,
-- kind = Protocol.TimeSkipKind* (0 = bed sleep), target = their resulting
-- worldTime, quiet = apply without announcing (a joined skip's own result).
function KCD2MP_ApplyTimeSkip(who, kind, target, quiet)
    target = tonumber(target)
    if not target then return end
    local ok, cur = pcall(function() return Calendar.GetWorldTime() end)
    if not ok or not cur then
        mp_log("ApplyTimeSkip: Calendar.GetWorldTime unavailable")
        return
    end
    if target > cur then
        local ok2, err = pcall(function() Calendar.SetWorldTime(target) end)
        mp_log(string.format("ApplyTimeSkip: %d -> %d (%s)", cur, target,
            ok2 and "written" or ("FAILED " .. tostring(err))))
    else
        -- Forward-only: already at or past the target (e.g. our own skip
        -- overshot a peer's). Keep our clock; divergence is bounded by the
        -- overshoot, never by hours.
        mp_log(string.format("ApplyTimeSkip: already at %d >= %d, keeping our clock", cur, target))
    end
    if not quiet then
        local verb = (tonumber(kind) == 0) and " slept till " or " passed time to "
        KCD2MP_ShowNativeToast(tostring(who) .. verb .. KCD2MP_FormatWorldTime(target))
    end
end

-- ===== Weather sync (WO-40 Phase 3) =====
-- EnvironmentModule.BlendTimeOfDay(profile, blendDuration, force) is the
-- officially documented weather write (Warhorse's own perf scripts and the
-- debug weather quest use it). There is NO current-profile read, so the
-- session's weather is arbitrated agent-side (damage-authority holder picks
-- and broadcasts); this is just the apply.
function KCD2MP_ApplyWeather(profile, blend)
    profile = tostring(profile or "")
    if profile == "" then return end
    local b = tonumber(blend) or 30
    local ok, err = false, nil
    if EnvironmentModule and EnvironmentModule.BlendTimeOfDay then
        ok, err = pcall(function()
            EnvironmentModule.BlendTimeOfDay(profile, b, true)
        end)
        -- WO-40 live battery: a blend<=1 is a SNAP request (late-join
        -- convergence); ForceImmediateWeatherUpdate is what actually applies
        -- it at once (rain 0 -> 0.82 within seconds, live-verified), while
        -- longer blends complete on their own (rain decayed to ~0 over ~60 s
        -- under blend=30, also live-verified).
        if ok and b <= 1 then
            pcall(function() EnvironmentModule.ForceImmediateWeatherUpdate() end)
            pcall(function() EnvironmentModule.RebuildClouds() end)
        end
    else
        err = "EnvironmentModule.BlendTimeOfDay not registered"
    end
    mp_log("ApplyWeather '" .. profile .. "' blend=" .. tostring(b)
        .. (ok and " (blending)" or (" FAILED: " .. tostring(err))))
end

-- Probe/manual override: mp_weather <profile> sets a profile locally (not
-- broadcast -- this is a probe, not a sync source); bare mp_weather reports
-- the one readable weather value (rain intensity).
function KCD2MP_WeatherCmd(arg)
    local s = tostring(arg or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" or s == "%LINE" then
        local ok, rain = pcall(function() return EnvironmentModule.GetRainIntensity() end)
        mp_log("Weather: GetRainIntensity=" .. (ok and tostring(rain) or "unavailable")
            .. " (no current-profile read exists on this surface)")
        return
    end
    KCD2MP_ApplyWeather(s, 5)
end

-- The game's own HUD info text -- native KCD2 font, centered, the same
-- surface the dice overlay's say() uses (live-verified there). The user's
-- explicit direction on seeing the DrawText toast live: "I want it in the
-- middle of the screen using the standard KCD2 font... it looks janky being
-- in the top left and is not immersive." DrawText remains the fallback if
-- the UIAction path ever fails.
function KCD2MP_ShowNativeToast(text)
    local ok = pcall(function()
        UIAction.CallFunction("hud", -1, "ShowInfoText", tostring(text), 10, 5000, true)
    end)
    if not ok then
        KCD2MP_ShowInteractionMsg(text)
    end
end

-- Superseded by the WO-6 dice overlay below, which draws the whole match. Kept
-- as a one-liner so an older agent build talking to a newer pak still puts
-- something on screen instead of erroring.
function KCD2MP_ShowDiceTurn(text)
    if text == nil or text == "" then
        KCD2MP.diceTurn = nil
    else
        KCD2MP.diceTurn = { text = tostring(text) }
    end
end

-- Invites the nearest ghost. Lua picks the target because it already has both
-- the player's position and every ghost's; the agent only knows relay ids.
-- kindStr is "dice" or "duel". wagerAmount (WO-33) is dice-only groschen,
-- ignored for any other kind.
function KCD2MP_InviteNearest(kindStr, wagerAmount)
    kindStr = tostring(kindStr or ""):gsub("%s+", "")
    if kindStr == "" then kindStr = "dice" end
    wagerAmount = tonumber(wagerAmount) or 0

    local ppos = player and player:GetWorldPos()
    if not ppos then return false end

    local bestId, bestD = nil, nil
    for id, g in pairs(KCD2MP.ghosts or {}) do
        if g and g.entity then
            local ok, gp = pcall(function() return g.entity:GetWorldPos() end)
            if ok and gp then
                local d = (gp.x - ppos.x)^2 + (gp.y - ppos.y)^2 + (gp.z - ppos.z)^2
                if not bestD or d < bestD then bestD, bestId = d, id end
            end
        end
    end

    if not bestId then
        mp_log("No other player nearby to invite")
        KCD2MP_ShowInteractionMsg("No player nearby")
        return false
    end

    local payload = tostring(bestId) .. " " .. kindStr
    if kindStr == "dice" then payload = payload .. " " .. tostring(math.floor(wagerAmount)) end

    mp_log("Inviting ghost " .. tostring(bestId) .. " to " .. kindStr
        .. (kindStr == "dice" and (" wager=" .. tostring(wagerAmount)) or ""))
    KCD2MP_EmitEvent("invite_send", payload)
    KCD2MP_ShowInteractionMsg(wagerAmount > 0 and ("Invite sent (wager " .. wagerAmount .. ")") or "Invite sent")
    return true
end

-- Draws the prompt and any transient message. Called from the label loop, which
-- already runs at 8 ms so text does not flicker between frames.
function KCD2MP_DrawInteractionUI()
    local inv = KCD2MP.invite
    if inv then
        if os.clock() - inv.shownAt > INVITE_TIMEOUT then
            KCD2MP.invite = nil
        else
            local left = math.ceil(INVITE_TIMEOUT - (os.clock() - inv.shownAt))
            local stake = (inv.wager and inv.wager > 0) and ("  for " .. inv.wager .. " groschen") or ""
            System.DrawText(10, 60, inv.who .. " invites you to " .. inv.kind .. stake .. "  (" .. left .. "s)", 2)
            System.DrawText(10, 84, "F11 accept / F12 decline  (or mp_accept / mp_decline)", 1.6)
        end
    end

    local msg = KCD2MP.interactionMsg
    if msg then
        if os.clock() - msg.shownAt > MSG_TIMEOUT then
            KCD2MP.interactionMsg = nil
        else
            System.DrawText(10, 110, msg.text, 1.6)
        end
    end

    if KCD2MP.diceTurn then
        System.DrawText(10, 134, KCD2MP.diceTurn.text, 1.6)
    end
end

-- ============================================================================
-- ===== Dice overlay (WO-6) ==================================================
-- ============================================================================
--
-- The in-game UI for a PvP Farkle match. Replaces the launcher window
-- (KCDMP_launcher/DiceWindow.razor), which is retired -- see docs/WO-6-*.md.
--
-- Renders ONLY what the relay sent. No score, no roll and no turn order is ever
-- computed here; the agent pushes a full DiceState snapshot and this draws it.
-- Same rule DiceClient.cs follows on the C# side.
--
-- The board is HTML pushed into the game's own tutorial panel via
-- UIAction.CallFunction("hud", -1, "ShowTutorial", ...) -- a gilded gothic
-- frame around illuminated parchment, rendered by the game. We supply the
-- markup; Warhorse supplies the art.
--
-- Art direction, palette and the state model are in docs/WO-6-overlay-design.md;
-- what can and cannot be rendered, with the evidence, is in
-- docs/WO-6-visual-capability.md. Read both before changing anything here --
-- most of the obvious ideas have already been tried against the real game and
-- do not work.

KCD2MP.dice = {
    open      = false,

    -- --- how it renders, all established against the real game --------------
    --
    -- The board is an HTML page pushed into the game's own tutorial panel
    -- (hud.ShowTutorial): a gilded gothic frame around illuminated parchment,
    -- rendered by the game itself.
    --
    -- This is the SECOND renderer. The first drew its own panel with
    -- System.Draw2DLine and it rendered NOTHING -- that call is registered,
    -- callable, returns cleanly, and r_enableAuxGeom is already 1, but no line
    -- ever reaches the screen. Only System.DrawText works in screen space, and
    -- plain text was the whole complaint. See docs/WO-6-visual-capability.md
    -- for the full evidence; do not reintroduce Draw2DLine here.
    -- Element id. ShowTutorial QUEUES rather than replaces, so every update is
    -- HideTutorial(id) then ShowTutorial(id, ...); pushing twice without the
    -- hide leaves the second push waiting behind the first. Found the hard way.
    panelId   = "kcd2mp_dice",
    -- The parchment panel IS the whole live board (score, dice, marks) --
    -- see KCD2MP_DiceRender and scheduleRender for how pushes are kept rare
    -- enough not to flicker: immediate on relay-driven state (open, a new
    -- DiceState, error, end), debounced on local rapid-fire input (marking).
    usePanel  = true,
    -- Marks/roll pushes ride the same debounce window so a burst of presses
    -- coalesces into one push instead of one each. See scheduleRender.
    renderDebounceMs = 250,
    -- Safety net, not the intended lifetime: every state change re-pushes, so
    -- the board is normally refreshed long before this expires. Was 120000 (2
    -- minutes) -- too short in practice: a live match hit a real stretch with
    -- no new relay-driven state (the seated-R bug meant no roll was ever sent),
    -- and the card visibly vanished mid-match while the session was still very
    -- much alive on the relay. 30 minutes is generous enough not to intrude on
    -- a legitimately slow human turn while still self-clearing eventually if
    -- this code ever truly stops refreshing. mp_dice_close/mp_dice_flush are
    -- the manual escape hatches if it's ever stuck sooner than that.
    panelMs   = 1800000,

    -- Glyphs VERIFIED renderable in this panel's font library. Everything else
    -- tried came back a tofu box: the Unicode die faces, every box-drawing
    -- character, and all geometric shapes including U+25CF. Worse, a plain
    -- ASCII '|' renders as NOTHING AT ALL -- hence the broken bar.
    pip       = "\226\128\162",   -- U+2022 BULLET
    rule      = "\226\128\148",   -- U+2014 EM DASH
    turnMark  = "\194\187",       -- U+00BB
    sep       = "\194\166",       -- U+00A6 BROKEN BAR
    leader    = "\194\183",       -- U+00B7 MIDDLE DOT

    -- Faces the panel's font library exposes (Libs/UI/fontconfig.xml).
    faceTitle = "DisplayFont",    -- Kingdom Come Display
    faceHand  = "Manuscript",     -- Warhorse Manuscript, a real blackletter hand
    faceBody  = "LightFont",

    -- Transient announcements that suit a line rather than the board.
    -- hud.ShowInfoText is confirmed rendering. hud.ShowDiceScore is confirmed
    -- INERT outside the native minigame, so it is not used at all.
    native    = { modal = false, infotext = true, sting = false },

    -- WO-33: groschen staked on the NEXT invite this client sends, set via
    -- mp_dice_wager. Purely local until it rides the Invite config -- the
    -- relay never computes or holds it, only echoes it back on DiceEnd so
    -- each client can apply it to its own Inventory. 0 = no stake.
    wagerAmount = 0,

    -- --- authoritative state, straight off the wire -------------------------
    role      = 0,             -- OUR SessionRole: 0 initiator, 1 acceptor
    turnRole  = 0,             -- whose turn it is
    target    = 4000,
    phase     = 0,             -- DicePhase: 0 AwaitingRoll, 1 AwaitingKeep
    scores    = { [0] = 0, [1] = 0 },
    turnTotal = 0,
    free      = {},            -- faces still on the board
    kept      = {},            -- faces set aside this turn
    peer      = "opponent",

    -- --- local, non-authoritative -------------------------------------------
    sel       = {},            -- which free dice the player has marked
    hold      = nil,           -- {action, t0} for hold-to-confirm
    outcome   = nil,           -- nil | "win" | "lose"
    err       = nil,           -- {text} from a DiceError
}

local D = KCD2MP.dice

-- Palette, as HTML colours against the panel's parchment. Pulled to KCD2's own
-- register: iron-gall ink, faded ink, candle gold, dried blood.
local COL = {
    ink   = "#2a2018",
    dim   = "#7a6a4f",
    gold  = "#c8a13c",
    -- Was #e8c25c -- too close to the parchment's own lightness to read at a
    -- glance (the live turn total, selected-die marks). Darkened for contrast;
    -- still reads as gold, just no longer washes out against the paper.
    bright= "#96691a",
    blood = "#8a1f14",
    -- Close to the parchment itself -- an "unlit" pip slot. First guess, not
    -- colour-picked from the real texture (no tooling for that); confirm
    -- against a live screenshot and adjust if it reads as too visible or too
    -- invisible.
    faint = "#c9b98f",
}

-- ===== html helpers =========================================================

local NBSP = "&nbsp;"

local function fnt(s, colour, size, face)
    local a = ""
    if face   then a = a .. " face='" .. face .. "'" end
    if size   then a = a .. " size='" .. tostring(size) .. "'" end
    if colour then a = a .. " color='" .. colour .. "'" end
    return "<font" .. a .. ">" .. s .. "</font>"
end

local function rep(s, n)
    local out = ""
    for _ = 1, (n or 0) do out = out .. s end
    return out
end

-- "2 500" -- thousands separated the way a tally board would.
local function groschen(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out, c = "", 0
    for i = #s, 1, -1 do
        out = s:sub(i, i) .. out
        c = c + 1
        if c % 3 == 0 and i > 1 then out = NBSP .. out end
    end
    return out
end

-- 9, not 13: at 13 the rule wrapped onto a second line and the board grew a
-- row of orphaned dashes after every divider. The panel is narrower than it
-- looks, and its font is proportional, so this is measured against the real
-- thing rather than calculated.
local function ruleLine()
    return fnt(rep(D.rule, 9), COL.dim)
end

-- A name/score row with leader dots between. The panel's font is PROPORTIONAL
-- (verified: "1234567890" and "ABCDEFGHIJ" end at different widths), so the
-- dots cannot align a column exactly -- but leaders are precisely the device
-- that makes an approximate right edge read as intentional.
-- `score` is a NUMBER here, not pre-formatted markup. It used to take the
-- groschen() output and size the leaders with #score -- but that string contains
-- "&nbsp;" entities, so a 4-digit score counted as 10+ characters and the
-- leaders collapsed to the minimum on every row.
local function tallyRow(mark, name, score, colour)
    local digits = #tostring(math.floor(tonumber(score) or 0))
    local budget = 20 - #name - digits
    if budget < 2 then budget = 2 end
    return fnt(mark .. " " .. name .. " " .. rep(D.leader, budget)
               .. " " .. groschen(score), colour)
end

-- ===== dice =================================================================

-- Which of the 3x3 cells carry a pip, per face. Built from BULLET and
-- non-breaking space only: every row of every die uses the same two characters
-- in the same slots, which is what makes the grid line up vertically despite
-- the proportional font (verified in game with a 5 and a 2 side by side).
--
-- NOT the Unicode die faces U+2680..2685 -- those are tofu in this font, as are
-- all box-drawing and geometric shapes. Bullet is what survives.
local PIPCELLS = {
    [1] = { {0,0,0}, {0,1,0}, {0,0,0} },
    [2] = { {1,0,0}, {0,0,0}, {0,0,1} },
    [3] = { {1,0,0}, {0,1,0}, {0,0,1} },
    [4] = { {1,0,1}, {0,0,0}, {1,0,1} },
    [5] = { {1,0,1}, {0,1,0}, {1,0,1} },
    [6] = { {1,0,1}, {1,0,1}, {1,0,1} },
}

-- Three lines of HTML rendering a row of dice side by side.
-- faces: array of 1..6. colours: parallel array of hex, or nil for ink.
--
-- Every cell renders D.pip -- never NBSP. An "unlit" cell is a bullet coloured
-- COL.faint instead of blank space, so every die's row is always exactly three
-- BULLET glyphs wide, whatever the face. Blank space (NBSP) does not render at
-- the same width as a bullet in this proportional font, so a die's rendered
-- width used to depend on how many pips it had (a 1 much narrower than a 6),
-- which is what made the index row drift out from under its die -- no fixed
-- gap can compensate for a per-die width that keeps changing.
--
-- A thin divider (D.sep, the broken bar already proven renderable in the
-- action strip) between dice reads as an actual boundary between two dice,
-- rather than blank space that six 2-character F-key labels (F2..F8) no
-- longer had room for anyway -- fixed a line-wrap the wide all-NBSP gap
-- caused once labels stopped being a single digit.
local GAP = NBSP .. D.sep .. NBSP

local function diceRows(faces, colours)
    local out = { "", "", "" }
    for r = 1, 3 do
        for i, f in ipairs(faces) do
            local cells = PIPCELLS[f] or PIPCELLS[1]
            local dieColour = (colours and colours[i]) or COL.ink
            local s = ""
            for c = 1, 3 do
                local lit = cells[r][c] == 1
                s = s .. fnt(D.pip, lit and dieColour or COL.faint)
            end
            out[r] = out[r] .. s
            if i < #faces then out[r] = out[r] .. GAP end
        end
    end
    return out
end

-- A row under the dice naming the key that marks each one, so the player never
-- has to remember an arbitrary mapping. Shows the real key rather than a plain
-- 1..6 die index now that marking has real keybinds (WO-6) -- the mapping is
-- F2, F4-F8 (F3/F1/F10 are engine debug toggles, skipped), not a clean range,
-- so spelling it out here matters more than it used to. mp_dice_mark still
-- takes the die's POSITION (1-6, left to right), for the console fallback.
--
-- sel (optional) marks a die as selected: its label goes in brackets and gold,
-- matching the gold pips diceRows already gives a selected die above it. No
-- circle/X glyph is used -- the capability doc's verified-renderable set has
-- none (every geometric shape tried came back tofu) -- but '[' ']' are proven
-- safe, they are already used by the action-strip key() labels below.
local DICE_MARK_KEYS = { "F2", "F4", "F5", "F6", "F7", "F8" }

local function indexRow(n, sel)
    local s = ""
    for i = 1, n do
        local marked = sel and sel[i]
        local keyLabel = DICE_MARK_KEYS[i] or tostring(i)
        local label = marked and ("[" .. keyLabel .. "]") or (NBSP .. keyLabel .. NBSP)
        s = s .. fnt(label, marked and COL.bright or COL.dim, 12)
        if i < n then s = s .. GAP end
    end
    return s
end

-- Sizes trimmed from 18/14 -- this panel stacks a lot of rows (title, tally,
-- three pip rows, index row, set-aside, hand total, rules, action strip) and
-- the line spacing scales with font size, so shaving a couple of points off
-- the busiest block buys back real vertical room.
local function diceBlock(faces, colours, numbered, sel)
    if #faces == 0 then
        return fnt(NBSP .. D.leader .. " none " .. D.leader, COL.dim, 16)
    end
    local r = diceRows(faces, colours)
    local h = fnt(r[1] .. "<br/>" .. r[2] .. "<br/>" .. r[3], nil, 15)
    if numbered then h = h .. "<br/>" .. indexRow(#faces, sel) end
    return h
end

-- ===== the board ============================================================

local function buildHtml()
    local mine   = (D.turnRole == D.role) and (D.outcome == nil)
    local myCol  = mine and COL.gold or COL.ink
    local opCol  = (not mine and D.outcome == nil) and COL.gold or COL.ink

    local title = "The Wager"
    if D.outcome == "win"  then title = "Thine!" end
    if D.outcome == "lose" then title = D.peer .. " takes it" end

    local h = fnt(title, (D.outcome == "win") and COL.bright or COL.gold, 26, D.faceTitle)
              .. "<br/>" .. ruleLine() .. "<br/>"

    -- score slip: opponent above, us below, target underneath
    h = h .. tallyRow(mine and NBSP or D.turnMark, D.peer, D.scores[1 - D.role], opCol) .. "<br/>"
    h = h .. tallyRow(mine and D.turnMark or NBSP, "Thou",  D.scores[D.role],     myCol) .. "<br/>"
    h = h .. "<p align='right'>" .. fnt("of " .. groschen(D.target), COL.dim, 16) .. "</p>"

    if D.outcome then
        h = h .. ruleLine() .. "<br/>"
        h = h .. fnt("The wager is settled.", COL.dim, 18) .. "<br/>"
        h = h .. fnt("mp_dice_close", COL.dim, 16)
        return h
    end

    h = h .. ruleLine() .. "<br/>"

    -- the board: free dice, marked ones in bright gold so a pending keep is
    -- obviously reversible before it is sent. No tumble/reveal animation --
    -- a fresh roll just appears with its real faces, per the human's own call
    -- once the panel replaced DrawText: nothing fancy needed for a reroll.
    local faces, cols = {}, {}
    for i, f in ipairs(D.free) do
        faces[i] = f
        cols[i]  = D.sel[i] and COL.bright or COL.ink
    end
    h = h .. fnt("On the board", COL.dim, 16) .. "<br/>"
    h = h .. diceBlock(faces, cols, true, D.sel) .. "<br/>"

    -- set aside, in gold: these are locked in and scoring. Not numbered --
    -- there is no command that takes a set-aside die's index, so numbering them
    -- would only invite a keystroke that does nothing.
    local kf, kc = {}, {}
    for i, f in ipairs(D.kept) do kf[i] = f; kc[i] = COL.gold end
    h = h .. fnt("Set aside", COL.dim, 16) .. "<br/>"
    h = h .. diceBlock(kf, kc, false) .. "<br/>"

    h = h .. fnt("This hand ", COL.dim, 18)
          .. fnt(groschen(D.turnTotal), (D.turnTotal > 0) and COL.bright or COL.dim, 20) .. "<br/>"
    h = h .. ruleLine() .. "<br/>"

    -- The action strip shows REAL keys. It briefly listed console commands
    -- instead, because the keybinds at that point were unverified guesses and
    -- advertising dead keys reads as broken. The names behind these were
    -- captured from a live game (see DICE_CONFIRM_ACTIONS), so they can be
    -- shown honestly now. The mp_dice_* commands still work and are the
    -- fallback if a key is rebound.
    if D.err then
        h = h .. fnt(D.err.text, COL.blood, 18) .. "<br/>"
    end

    local function key(k, label, hot)
        return fnt("[" .. k .. "] ", hot and COL.gold or COL.dim, 16)
            .. fnt(label, hot and COL.ink or COL.dim, 16)
    end

    if mine then
        if D.phase == 1 then
            h = h .. fnt("key below", COL.gold, 16) .. fnt(" to mark, then ", COL.dim, 16)
                  .. key("F9", "set aside", true) .. "<br/>"
            h = h .. key("U", "clear marks", false) .. "<br/>"
        else
            h = h .. key("F9", "cast", true) .. "<br/>"
        end
        h = h .. key("hold F11", "bank", true) .. fnt("  " .. D.sep .. "  ", COL.dim, 16)
              .. key("hold F12", "yield", false)
    else
        h = h .. fnt(D.peer .. " is casting" .. D.leader .. D.leader .. D.leader, COL.dim, 18)
    end

    return h
end

-- ===== pushing it ===========================================================

-- ShowTutorial is a NOTIFICATION QUEUE, not a panel you can update in place.
-- Two rounds of learning here, both from watching the real thing:
--
--   1. Pushing an update without hiding leaves it waiting BEHIND the current
--      entry, so the board silently stops tracking the match.
--   2. HideTutorial(id) only dismisses the entry being DISPLAYED -- it advances
--      the queue rather than clearing it. Sixteen pushes across one demo match
--      therefore left sixteen queued entries, each asking for a long duration,
--      and the game cycled through them: fade out, fade in, next. On screen that
--      reads as the board flickering and looping forever, long after the match
--      has ended.
--
-- So every push flushes the WHOLE queue first. HideAllTutorials is a blunt
-- instrument -- it will also drop a genuine game tutorial that happens to be
-- showing -- which is accepted only because this runs solely during a PvP dice
-- match the player deliberately started.
--
-- panelMs is a safety net, not the intended lifetime: if this code ever stops
-- refreshing (agent dies, script error), the board expires by itself instead of
-- sitting on screen forever.
-- MEASURED, not assumed: a demo match pushes the panel 24 times in 30 seconds,
-- roughly one every 1.25 s. Each push is HideAllTutorials + ShowTutorial and the
-- panel replays its full fade-out/fade-in every time. That is the "flickering
-- horribly" -- not a loop, and not something queue management can fix.
--
-- ShowTutorial is a NOTIFICATION CARD. There is no in-place text update, so
-- rapid repeated pushes flicker -- but not EVERY push is rapid. A relay-driven
-- DiceState (a roll/keep/bank result) is naturally paced by however long a
-- turn takes; the thing that actually flickered was pushing once per LOCAL
-- mark press too, which can happen several times a second while choosing a
-- keep. So the fix is not "never push the panel", it's "don't push once per
-- keystroke": KCD2MP_DiceRender still pushes immediately for state that's
-- already paced (open, DiceState, DiceError, end); scheduleRender below is
-- what marking uses instead, coalescing a burst of presses into one push.
function KCD2MP_DiceRender()
    if not D.open then return end
    if not D.usePanel then return end
    local ok, html = pcall(buildHtml)
    if not ok then
        mp_log("DICE render error: " .. tostring(html))
        return
    end
    KCD2MP_DiceFlush()
    pcall(function()
        UIAction.CallFunction("hud", -1, "ShowTutorial",
            D.panelId, html, D.panelMs, false, 9, 0, false, "")
    end)
end

-- Coalesces bursty local input (marking dice) into one push instead of one
-- per press. Leading-edge: the first call after a quiet period schedules a
-- render renderDebounceMs later; any calls that land inside that window are
-- no-ops, because by the time the scheduled render actually runs it reads
-- whatever D.sel etc. looks like THEN -- which already includes them, since
-- Lua here is single-threaded and D.sel was mutated synchronously by the
-- caller before scheduleRender was ever called.
local renderScheduled = false
local function scheduleRender()
    if renderScheduled then return end
    renderScheduled = true
    Script.SetTimer(D.renderDebounceMs or 250, function()
        renderScheduled = false
        KCD2MP_DiceRender()
    end)
end

-- Drops every queued and displayed tutorial. Also exposed as mp_dice_flush, so
-- a stuck or flickering panel is always one command away from being cleared.
function KCD2MP_DiceFlush()
    pcall(function() UIAction.CallFunction("hud", -1, "HideAllTutorials") end)
    pcall(function() UIAction.CallFunction("hud", -1, "HideCurrentTutorial") end)
    pcall(function() UIAction.CallFunction("hud", -1, "HideTutorial", D.panelId) end)
end

local function say(text)
    if not D.native.infotext then return end
    pcall(function()
        UIAction.CallFunction("hud", -1, "ShowInfoText", text, 10, 2200, true)
    end)
end
KCD2MP_DiceSay = say

-- Hold-to-confirm needs a light tick, and only while a key is actually held.
local function holdTick()
    if not D.hold then return end
    Script.SetTimer(100, holdTick)
    KCD2MP_DiceHoldTick()
end
KCD2MP_DiceHoldPump = holdTick

-- ===== inbound: called by the agent =========================================

-- Opens the board. role is OUR SessionRole (0 initiator, 1 acceptor).
function KCD2MP_DiceOpen(role, peer, target)
    D.role      = tonumber(role) or 0
    D.peer      = tostring(peer or "opponent")
    D.target    = tonumber(target) or 4000
    D.scores    = { [0] = 0, [1] = 0 }
    D.turnTotal = 0
    D.free, D.kept, D.sel = {}, {}, {}
    D.outcome, D.err, D.hold = nil, nil, nil
    D.open = true
    KCD2MP_DiceRender()      -- the parchment card announcing the match
    mp_log("DICE overlay open vs " .. D.peer .. " to " .. tostring(D.target))
end

function KCD2MP_DiceClose()
    D.open, D.hold = false, nil
    -- Flush rather than hide one entry: anything still queued would otherwise
    -- keep surfacing after the match is over. Runs even if the board was already
    -- closed, so mp_dice_close doubles as "clear whatever is stuck on screen".
    KCD2MP_DiceFlush()
    mp_log("DICE overlay closed")
end

-- A full authoritative snapshot. freeCsv/keptCsv/bustedCsv are comma-separated
-- faces ("3,1,5,6"); empty string means none. Never a delta -- the relay
-- always sends the whole board, so this can replace state wholesale without
-- reconciling. bustedCsv is the roll that just busted (added after WO-5
-- shipped): FreeDice is already cleared by the time a bust reaches the wire,
-- so this is the only place the actual rolled faces ever appear.
function KCD2MP_DiceState(turnRole, s0, s1, turnTotal, target, phase, freeCsv, keptCsv, bustedCsv)
    local function parse(csv)
        local t = {}
        for m in tostring(csv or ""):gmatch("[^,]+") do
            local n = tonumber(m)
            if n then t[#t + 1] = n end
        end
        return t
    end

    -- A snapshot arriving with no board open means the agent connected mid-
    -- session, or SessionStarted was missed. Open FIRST -- KCD2MP_DiceOpen
    -- clears scores, dice and animation state, so opening after applying the
    -- snapshot would wipe the very state this call is delivering.
    if not D.open then KCD2MP_DiceOpen(D.role, D.peer, tonumber(target) or D.target) end

    local prevTurn = D.turnRole

    D.turnRole  = tonumber(turnRole) or 0
    D.scores[0] = tonumber(s0) or 0
    D.scores[1] = tonumber(s1) or 0
    D.turnTotal = tonumber(turnTotal) or 0
    D.target    = tonumber(target) or D.target
    D.phase     = tonumber(phase) or 0
    D.free      = parse(freeCsv)
    D.kept      = parse(keptCsv)
    D.sel       = {}          -- a new snapshot always clears a pending mark

    local bustedFaces = parse(bustedCsv)

    if D.turnRole ~= prevTurn then
        local mine = (D.turnRole == D.role)

        -- Used to be inferred from whether the score moved -- the relay did
        -- not label its snapshots at all. Now it does (bustedFaces), so this
        -- reads real state instead of guessing from a side effect of it.
        local busted = #bustedFaces > 0

        -- The turn hand-off and the bust are the two moments that want to
        -- punch, and a line across the middle of the screen punches harder
        -- than a change inside the panel. This is what ShowInfoText is for.
        if busted then
            local rolled = table.concat(bustedFaces, ", ")
            say((prevTurn == D.role) and ("Bust! Rolled " .. rolled .. " -- nothing scored.")
                                      or (D.peer .. " busts on " .. rolled .. "."))
        else
            say(mine and "Thy cast." or (D.peer .. " casts."))
        end
    end

    D.err = nil

    -- Immediate, not debounced: this is a relay-confirmed result, already
    -- paced by however long the turn took -- it is local rapid-fire input
    -- (marking) that needs coalescing, not this.
    KCD2MP_DiceRender()
end

-- The relay rejected an intent. State did not change; the board says why.
function KCD2MP_DiceError(reason)
    D.err = { text = tostring(reason or "not allowed") }
    KCD2MP_DiceRender()
end

-- outcome: "win" or "lose". wager (WO-33) is the agreed groschen stake,
-- echoed by the relay on the wire DiceEnd packet itself -- see Protocol.cs.
-- Applied here, once, to THIS client's own Inventory only: winner gains,
-- loser loses, never a write into the peer's save. This function is reached
-- only for a match that ran to a clean conclusion -- a mid-match disconnect
-- fires KCD2MP_DiceClose via SessionEnded instead (GameBridge.cs), never
-- this, so a dropped connection can never move money on either side.
function KCD2MP_DiceEnd(outcome, s0, s1, wager)
    D.scores[0] = tonumber(s0) or D.scores[0]
    D.scores[1] = tonumber(s1) or D.scores[1]
    D.outcome   = tostring(outcome or "lose")
    D.sel, D.hold, D.err = {}, nil, nil

    -- Live-checked this session (WO-33): the "Inventory" scriptbind the
    -- vendor docs describe as a global table does not exist in this sandbox
    -- at all. What IS real: player.inventory:GetMoney()/RemoveMoney(n) are
    -- genuine entity-scoped methods, confirmed with a controlled before/after
    -- read (7.9 -> 5.9 groschen for RemoveMoney(2)). There is no AddMoney
    -- anywhere reachable, on this object or via RTTR reflection. The win
    -- side instead uses ItemUtils.AddMoneyToInventory(who, amount), a real
    -- function the shipped game's own Scripts/Utils/ItemUtils.lua defines --
    -- money is a stackable item (guid 5ef63059-...) under the hood, and this
    -- is Warhorse's own sanctioned way to hand someone more of it, built on
    -- ItemManager.CreateItem + entity.inventory:AddItem, both independently
    -- proven elsewhere in this project (docs/kcd2_lua_api.md).
    wager = tonumber(wager) or 0
    if wager > 0 then
        local ok, err
        if D.outcome == "win" then
            ok, err = pcall(function() ItemUtils.AddMoneyToInventory(player, wager) end)
        else
            ok, err = pcall(function() player.inventory:RemoveMoney(wager) end)
        end
        mp_log("DICE wager " .. wager .. " " .. (D.outcome == "win" and "added" or "removed")
            .. " ok=" .. tostring(ok) .. " err=" .. tostring(err))
    end

    say((D.outcome == "win") and ("The wager is thine." .. (wager > 0 and (" +" .. wager .. " groschen.") or ""))
                              or (D.peer .. " takes the pot." .. (wager > 0 and (" -" .. wager .. " groschen.") or "")))
    KCD2MP_DiceRender()
    mp_log("DICE match ended: " .. D.outcome .. " wager=" .. wager)
end

-- ===== demo: review the board without a second player =======================
--
-- One machine, one copy of the game and no second human is the standing
-- constraint on this project, so the visuals would otherwise be unreviewable
-- until a second PC exists. This drives the board through a scripted match with
-- fabricated snapshots -- every moment the design specifies, in order, so the
-- look and the motion can actually be judged.
--
-- It calls the SAME entry points the agent calls and fabricates nothing the
-- relay would not send. It is a view of the presentation layer only: it sends
-- no intents, touches no session, and cannot affect a real match.
--
--   mp_dice_demo

local DEMO = {
    -- {delay after previous step (s), what to do}
    {0.0, function() KCD2MP_DiceOpen(0, "Dicer Filip", 2500) end},
    {0.8, function() KCD2MP_DiceState(0, 0,    0,   0, 2500, 0, "",            "") end},
    {1.2, function() KCD2MP_DiceState(0, 0,    0,   0, 2500, 1, "1,5,3,6,2,4", "") end},
    {2.2, function() KCD2MP_DiceState(0, 0,    0, 100, 2500, 0, "5,3,6,2,4",   "1") end},
    {1.6, function() KCD2MP_DiceState(0, 0,    0, 100, 2500, 1, "2,5,4,1,6",   "1") end},
    {1.8, function() KCD2MP_DiceState(0, 0,    0, 250, 2500, 0, "2,4,6",       "1,5,1") end},
    {1.6, function() KCD2MP_DiceState(0, 0,    0, 250, 2500, 1, "3,3,2",       "1,5,1") end},
    -- bust: turn passes and our banked score did NOT move. bustedCsv fabricates
    -- what the roll was -- 2,3,4,6 has no 1, no 5 and no triple, a real bust.
    {2.0, function() KCD2MP_DiceState(1, 0,    0,   0, 2500, 0, "",            "", "2,3,4,6") end},
    {2.4, function() KCD2MP_DiceState(1, 0,    0, 450, 2500, 1, "4,4,4,2",     "5,5") end},
    -- opponent banks: their score moves, so no bust sting
    {2.0, function() KCD2MP_DiceState(0, 0,  450,   0, 2500, 0, "",            "") end},
    {2.0, function() KCD2MP_DiceState(0, 0,  450,   0, 2500, 1, "1,1,1,4,2,6", "") end},
    {2.2, function() KCD2MP_DiceState(0, 0,  450,1000, 2500, 0, "4,2,6",       "1,1,1") end},
    -- a rejected intent
    {1.6, function() KCD2MP_DiceError("those dice score nothing") end},
    -- and a win
    {2.6, function() KCD2MP_DiceState(0, 2550, 450, 0, 2500, 0, "", "") end},
    {0.4, function() KCD2MP_DiceEnd("win", 2550, 450) end},
    {6.0, function() KCD2MP_DiceClose() end},
}

KCD2MP._demoStep = 0

local function demoTick()
    KCD2MP._demoStep = KCD2MP._demoStep + 1
    local s = DEMO[KCD2MP._demoStep]
    if not s then return end
    pcall(s[2])
    local nxt = DEMO[KCD2MP._demoStep + 1]
    if nxt then Script.SetTimer(math.floor(nxt[1] * 1000), demoTick) end
end

function KCD2MP_DiceDemo()
    KCD2MP._demoStep = 0
    mp_log("DICE demo: scripted match, ~30s")
    demoTick()
    return true
end

-- ===== outbound: player intents =============================================
--
-- Every one of these only EMITS. The relay decides whether it was legal, and
-- the answer arrives as the next snapshot or as a DiceError.

-- anyTime: forfeit is legal whenever the match is live -- conceding only on
-- your own turn would mean being unable to walk away from an opponent who has
-- stopped playing.
local function intent(s, anyTime)
    if not D.open then
        KCD2MP_ShowInteractionMsg("No dice match")
        return false
    end
    if D.outcome then return false end
    if not anyTime and D.turnRole ~= D.role then
        D.err = { text = "not thy turn", t0 = os.clock() }
        return false
    end
    KCD2MP_EmitEvent("dice_intent", s)
    return true
end

-- Marks or unmarks a die for the next Keep. Local only, freely reversible --
-- nothing leaves the machine until the player confirms.
function KCD2MP_DiceMark(i)
    i = tonumber(i)
    if not D.open or not i or not D.free[i] then return false end
    if D.turnRole ~= D.role then
        D.err = { text = "not thy turn" }
        scheduleRender()
        return false
    end
    if D.sel[i] then D.sel[i] = nil else D.sel[i] = true end
    D.err = nil
    -- Debounced, not immediate: marking can fire several times a second while
    -- choosing a keep, and pushing the panel once per press is the flicker
    -- this design already fixed once.
    scheduleRender()
    return true
end

-- Clears every pending mark without touching the roll itself, so a player who
-- marked, say, two 5s and then noticed a third can start over on the SAME
-- free dice instead of committing a suboptimal keep. Purely local, like
-- marking itself -- nothing is sent to the relay until KCD2MP_DiceConfirm.
function KCD2MP_DiceUnmarkAll()
    if not D.open or D.phase ~= 1 then return false end
    D.sel = {}
    D.err = nil
    scheduleRender()
    return true
end

-- The primary action, and it does double duty by phase: cast when the relay is
-- waiting for a roll, set aside the marked dice when it is waiting for a keep.
function KCD2MP_DiceConfirm()
    if not D.open then return false end
    if D.phase == 1 then
        local mask = 0
        for i = 1, 6 do if D.sel[i] then mask = mask + 2 ^ (i - 1) end end
        if mask == 0 then
            D.err = { text = "mark thy dice first" }
            KCD2MP_DiceRender()
            return false
        end
        return intent("keep " .. tostring(math.floor(mask)))
    end
    return intent("roll")
end

function KCD2MP_DiceBank()    return intent("bank")          end
function KCD2MP_DiceForfeit() return intent("forfeit", true) end

-- Hold-to-confirm. Bank and forfeit are irreversible, so they are deliberately
-- not on a single press: begin on key-down, fire only if the key survives long
-- enough, cancel on key-up. Pumped by its own short-lived timer, which only
-- runs while a key is actually down.
function KCD2MP_DiceHoldBegin(action)
    if not D.open or D.outcome then return end
    if D.hold then return end
    D.hold = { action = action, t0 = os.clock() }
    KCD2MP_DiceHoldPump()
end

function KCD2MP_DiceHoldEnd()
    D.hold = nil
end

function KCD2MP_DiceHoldTick()
    if not D.hold then return end
    local need = (D.hold.action == "forfeit") and 1.2 or 0.6
    if os.clock() - D.hold.t0 >= need then
        local a = D.hold.action
        D.hold = nil
        if a == "forfeit" then KCD2MP_DiceForfeit() else KCD2MP_DiceBank() end
    end
end

-- ===== dice tables (WO-6 C1) ================================================
--
-- Real tables only -- this mod's dice UI must never appear anywhere a player
-- happens to be standing.
--
-- "DiceInteractor" is not a guess. Scripts.pak ships Entities/DiceInteractor.ent
-- registering that class against Scripts/Entities/WH/Minigames/DiceInteractor.lua,
-- the script that puts the "@ui_hud_play_dice" action on a dice board
-- (objects/manmade/task_specific_props/entertainment/games/dice/dice_board.cgf).
--
-- UNVERIFIED until Probe-Visual.ps1's `dicetable` block is run at a real tavern
-- table: whether world-placed tables are actually instances of this class.
-- If they are not, set KCD2MP.dice.tableClass = nil to fall back to a plain
-- proximity check between the two players -- honest, flagged, and not the
-- default.
-- WO-6 revision: the strict "must be at a DiceInteractor" gate is correct for
-- shipping but hostile to testing, because every dice table in the world is
-- already occupied by an NPC and we cannot drive the native minigame anyway.
-- So the gate is now a list of accepted classes plus a switch.
--
--   requireTable = false  -- test mode, invite anywhere (DEFAULT for now)
--   requireTable = true   -- shipping behaviour, must be at an accepted table
--
-- `mp_dice_gate on|off` flips it live, and `mp_dice_scan` lists the entity
-- classes actually around the player so a generic table's real class name can be
-- ADDED to tableClasses from evidence rather than guessed at.
KCD2MP.dice.tableClasses = { "DiceInteractor" }
KCD2MP.dice.tableClass   = "DiceInteractor"   -- kept: first entry, back-compat
KCD2MP.dice.tableRadius  = 4.0
KCD2MP.dice.requireTable = false

-- Returns entity, distance -- or nil plus a reason. Searches every class in
-- KCD2MP.dice.tableClasses and returns the nearest hit across all of them.
function KCD2MP_NearestDiceTable(radius)
    radius = tonumber(radius) or KCD2MP.dice.tableRadius
    local classes = KCD2MP.dice.tableClasses
    if not classes or #classes == 0 then return nil, "table detection disabled" end
    local ppos = player and player:GetWorldPos()
    if not ppos then return nil, "no player position" end

    local best, bestD = nil, nil
    for _, cls in ipairs(classes) do
        local ok, list = pcall(System.GetEntitiesInSphereByClass, ppos, radius, cls)
        if ok and list then
            for _, e in ipairs(list) do
                local ok2, ep = pcall(function() return e:GetWorldPos() end)
                if ok2 and ep then
                    local d = math.sqrt((ep.x - ppos.x) ^ 2 + (ep.y - ppos.y) ^ 2 + (ep.z - ppos.z) ^ 2)
                    if not bestD or d < bestD then best, bestD = e, d end
                end
            end
        end
    end
    if not best then return nil, "no table within " .. tostring(radius) .. "m" end
    return best, bestD
end

-- Lists every entity near the player with its class, so a generic table's real
-- class name can be read off the log and ADDED to tableClasses. Evidence, not a
-- guess -- the same discipline that produced DiceInteractor in the first place.
function KCD2MP_ScanTables(radiusStr)
    local radius = tonumber(tostring(radiusStr or ""):match("%d+%.?%d*") or "") or 6.0
    local ppos = player and player:GetWorldPos()
    if not ppos then mp_log("SCAN: no player position"); return false end
    local ok, list = pcall(System.GetEntitiesInSphere, ppos, radius)
    if not ok or not list then mp_log("SCAN: query failed"); return false end
    mp_log(string.format("SCAN: %d entities within %.1fm", #list, radius))
    local seen = {}
    for _, e in ipairs(list) do
        local ok2 = pcall(function()
            local cls = e.class or "?"
            local nm  = tostring(e:GetName())
            local ep  = e:GetWorldPos()
            local d   = math.sqrt((ep.x-ppos.x)^2 + (ep.y-ppos.y)^2 + (ep.z-ppos.z)^2)
            -- one line per entity, but collapse identical classes past the third
            seen[cls] = (seen[cls] or 0) + 1
            if seen[cls] <= 3 then
                mp_log(string.format("SCAN  %-22s %-34s %.1fm", tostring(cls), nm, d))
            end
        end)
    end
    return true
end

-- ===== seats at ordinary tables (WO-6 revision) =============================
--
-- Found by scanning entity classes around a real seated player, not guessed.
-- Every tavern seat carries three linked entities, all within ~1.5 m:
--
--   ActionTrigger      sitActionTrigger[Table/table_oneSides_tavern1:...:Bench/...]
--   StanceSmartObject  smartObject2[Table/table_oneSides_tavern1:...:Bench/...]
--   SmartObjectHolder  smartObject[Table/table_oneSides_tavern1_<guid>]
--
-- sitActionTrigger is the useful one. It exists only at a seat attached to a
-- table, its position is a stable anchor to teleport the other player to, and
-- its NAME encodes the table -- so two players can be checked for being at the
-- SAME table rather than merely both sitting somewhere.
--
-- Note this detects "at a seat", not "currently seated": player:GetStance() is
-- not available in this build (returned nil when probed), so there is no direct
-- read of the sitting state. Proximity to the trigger is the proxy, and it is
-- honest to call it that.
KCD2MP.dice.seatRadius = 1.6

-- Pulls "Table/table_oneSides_tavern1" out of a sitActionTrigger's name, so the
-- same table can be recognised from either player's seat.
function KCD2MP_TableIdFromName(name)
    if not name then return nil end
    return (tostring(name):match("%[(Table[/%.][%w_]+)"))
end

-- Returns entity, distance, tableId -- or nil plus a reason.
function KCD2MP_NearestSeat(radius)
    radius = tonumber(radius) or KCD2MP.dice.seatRadius
    local ppos = player and player:GetWorldPos()
    if not ppos then return nil, "no player position" end
    local ok, list = pcall(System.GetEntitiesInSphereByClass, ppos, radius, "ActionTrigger")
    if not ok or not list then return nil, "entity query failed" end

    local best, bestD, bestName = nil, nil, nil
    for _, e in ipairs(list) do
        local ok2, nm = pcall(function() return tostring(e:GetName()) end)
        if ok2 and nm and nm:find("^sitActionTrigger") then
            local ok3, ep = pcall(function() return e:GetWorldPos() end)
            if ok3 and ep then
                local d = math.sqrt((ep.x-ppos.x)^2 + (ep.y-ppos.y)^2 + (ep.z-ppos.z)^2)
                if not bestD or d < bestD then best, bestD, bestName = e, d, nm end
            end
        end
    end
    if not best then return nil, "no seat within " .. tostring(radius) .. "m" end
    return best, bestD, KCD2MP_TableIdFromName(bestName)
end

function KCD2MP_IsAtSeat(radius)
    return (KCD2MP_NearestSeat(radius)) ~= nil
end

-- Reports the seat under the player: distance, table id, and the anchor position
-- the other player would be teleported to.
function KCD2MP_ReportSeat()
    local e, d, tid = KCD2MP_NearestSeat(6.0)
    if not e then
        mp_log("SEAT: none within 6m (" .. tostring(d) .. ")")
        KCD2MP_ShowInteractionMsg("No seat nearby")
        return false
    end
    local p = e:GetWorldPos()
    mp_log(string.format("SEAT: %.2fm table=%s anchor=%.2f,%.2f,%.2f",
        d, tostring(tid), p.x, p.y, p.z))
    KCD2MP_ShowInteractionMsg(string.format("Seat %.1fm  %s", d, tostring(tid)))
    return true
end

-- Flip the shipping gate on or off without a rebuild.
function KCD2MP_DiceGate(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.dice.requireTable = true
    elseif s:find("off") then KCD2MP.dice.requireTable = false end
    mp_log("DICE table gate = " .. tostring(KCD2MP.dice.requireTable))
    return true
end

function KCD2MP_IsAtDiceTable(radius)
    local e = KCD2MP_NearestDiceTable(radius)
    return e ~= nil
end

-- Verification helper for the C1 claim above. Run it standing at a real tavern
-- dice table, then again well away from one -- the away run is the negative
-- control that makes the at-table run mean anything.
function KCD2MP_ReportDiceTable()
    local e, d = KCD2MP_NearestDiceTable(25.0)
    if not e then
        mp_log("DICE TABLE: none within 25m (" .. tostring(d) .. ")")
        KCD2MP_ShowInteractionMsg("No dice table within 25m")
        return false
    end
    local ok, nm = pcall(function() return e:GetName() end)
    mp_log(string.format("DICE TABLE: '%s' at %.2fm", ok and tostring(nm) or "?", d))
    KCD2MP_ShowInteractionMsg(string.format("Dice table %.1fm away", d))
    return true
end

-- The gate the dice invite goes through. NPC dice games are untouched by any of
-- this: they never call into KCD2MP, and this only ever emits our own invite
-- event to our own agent.
-- The gate is now "at a seat attached to any table", per the design call that
-- every real dice table is NPC-occupied and the native minigame is unreachable
-- anyway. A dice-specific DiceInteractor still counts, so nothing is lost.
--
-- The seat's table id rides along on the invite: it is what lets the acceptor be
-- placed at the SAME table rather than merely at some table of their own.
-- WO-33: mp_dice_wager <amount>. Purely local -- takes effect on the NEXT
-- mp_dice/F9 invite this client sends, and does nothing to any invite already
-- pending. A negative or unparsable amount is treated as 0 (no wager) rather
-- than faulting; groschen are whole numbers here, so this floors.
function KCD2MP_SetDiceWager(line)
    local n = tonumber(tostring(line or ""):match("%-?%d+")) or 0
    KCD2MP.dice.wagerAmount = math.max(0, math.floor(n))
    KCD2MP_ShowInteractionMsg("Dice wager set to " .. KCD2MP.dice.wagerAmount)
    mp_log("Dice wager set to " .. KCD2MP.dice.wagerAmount)
end

function KCD2MP_InviteDiceAtTable()
    -- WO-33: check our OWN balance before sending, not after the peer accepts.
    -- RemoveMoney at DiceEnd would refuse anyway if this were skipped, but a
    -- match that couldn't have been paid for should never start.
    local wager = KCD2MP.dice.wagerAmount or 0
    if wager > 0 then
        local ok, have = pcall(function() return player.inventory:GetMoney() end)
        if not ok or not have or have < wager then
            KCD2MP_ShowInteractionMsg("Not enough groschen for that wager")
            mp_log("Refusing dice invite: wager " .. tostring(wager) .. " exceeds balance "
                .. tostring(ok and have or "?"))
            return false
        end
    end

    local seat, d, tid = KCD2MP_NearestSeat()
    if not seat and KCD2MP.dice.requireTable then
        -- fall back to a real dice table before refusing
        local e = KCD2MP_NearestDiceTable()
        if not e then
            KCD2MP_ShowInteractionMsg("Sit at a table first (" .. tostring(d) .. ")")
            return false
        end
    end
    if seat then
        local p = seat:GetWorldPos()
        KCD2MP.dice.seat = { tableId = tid, x = p.x, y = p.y, z = p.z }
        mp_log(string.format("DICE invite from seat table=%s anchor=%.2f,%.2f,%.2f",
            tostring(tid), p.x, p.y, p.z))
    else
        KCD2MP.dice.seat = nil
    end
    return KCD2MP_InviteNearest("dice", wager)
end

-- ===== Ghost NPC Spawn =====

-- WO-17: mp_enable_aggro on|off. Opt-in, off by default, decided locally on
-- this client only -- it does not need the other player's agreement, the
-- same way dice needed a session invite/accept but this does not, because it
-- only changes how THIS player's world treats an incoming ghost. The agent
-- hears about this via the same log-tail event channel invite_accept already
-- uses (KCD2MP_EmitEvent) -- it, not Lua, is what actually decides when to
-- attach a ghost to the hostile faction, since that write only exists in
-- native code.
--
-- WO-27: this is a single live flag (GameBridge._aggroEnabled), checked at
-- hit-time for every ghost, not baked in per-ghost at spawn -- flipping it
-- takes effect on the very next hit for every ghost already in the world, no
-- respawn or reconnect needed. Reactive combat itself (a ghost defending
-- itself, joining a nearby fight) is unconditional and always on regardless
-- of this toggle (WO-26); what this toggle adds is a ~20s native hostile-
-- faction attach so nearby NPCs recognize the ghost as an enemy generally,
-- not just whoever it's already fighting (WO-27's live A/B test).
function KCD2MP_EnableAggro(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.aggroEnabled = true
    elseif s:find("off") then KCD2MP.aggroEnabled = false
    else
        mp_log("mp_enable_aggro: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    KCD2MP_EmitEvent("aggro_toggle", KCD2MP.aggroEnabled and "on" or "off")
    mp_log("AGGRO " .. (KCD2MP.aggroEnabled and "ENABLED" or "disabled") ..
           " -- affects ghosts spawned from now on")
    KCD2MP_ShowInteractionMsg("Aggro: " .. (KCD2MP.aggroEnabled and "ON" or "OFF"))
    return true
end

-- ===== NPC sync (WO-32) =====
--
-- One player's world dictating what nearby hand-placed NPCs are doing in
-- everyone's world. Built on WO-32's live findings, all observed on a real
-- NPC (ttkc_man_16), not a ghost:
--
--   * A single external SetWorldPos LANDS but the engine restores the NPC to
--     its byte-identical schedule anchor within ~1.5 s. One write is nothing.
--   * A continuous 50 ms write stream WINS completely -- the NPC tracked an
--     external drive across metres with no AI suppression of any kind, while
--     dialogue, crime state and nearby NPCs stayed completely undisturbed.
--   * When the stream stops, the engine restores the NPC to its own schedule
--     by itself (back on anchor within 3 s, talkable, no side effects). So
--     "release" is simply: stop writing.
--   * StartAnimation works on a real NPC exactly as on a ghost, and without
--     it the NPC slides in whatever pose its current activity holds.
--
-- Emitting side (the Rule 2 world authority only): a slow tick tracks up to
-- npcSync.maxTracked NPCs within npcSync.radius of the player and emits an
-- npc_state event line per NPC on movement, on a health change, or on a slow
-- heartbeat. Runtime-spawned entities (ghosts, horses) are excluded -- this
-- layer moves EXISTING authored NPCs, it never creates or names one.
--
-- Receiving side: KCD2MP_ApplyNpcState targets a puppet entry; a 50 ms tick
-- (same cadence family as the ghost interp) lerps the local copy of that NPC
-- toward the stream and drives a walk/run animation from the rendered speed.
-- A puppet that stops receiving packets for releaseS seconds is dropped and
-- the engine takes the NPC back -- that is the whole restore path, verified
-- live before this was built.
KCD2MP.npcSync = {
    enabled    = true,    -- mp_npc_sync on|off. ON by default (human's WO-32
                          -- decision: "if it is off by default then nobody is
                          -- ever going to know how to enable it"). Turn OFF
                          -- with `mp_npc_sync off` in the console -- only
                          -- meaningful on the session's world authority, since
                          -- only that client emits. Non-authority clients are
                          -- unaffected either way: the relay drops NpcStateUp
                          -- from them regardless.
    radius     = 30,      -- metres around the local player (WO-32 Phase 0 bound)
    maxTracked = 5,       -- hard cap on synced NPCs (WO-32 Phase 0/2 bound)
    emitMs     = 250,     -- per-NPC emit cadence (4 Hz) -- position lerp on the
                          -- receiver smooths the gaps, same as ghost interp
    scanMs     = 2000,    -- how often the tracked set is rebuilt
    moveEps    = 0.05,    -- metres; below this nothing is emitted
    heartbeatS = 2.0,     -- unconditional resend so a late joiner converges
    releaseS   = 3.0,     -- receiver: packet age at which a puppet is released
}
KCD2MP.npcSyncRunning  = false
KCD2MP._npcSyncAliveAt = nil
KCD2MP.npcTracked      = {}   -- name -> {lastX,lastY,lastZ,lastRot,lastHp,lastSentAt}
KCD2MP._npcScanAt      = 0

KCD2MP.npcPuppets        = {} -- name -> {tx,ty,tz,tr,hp,dead,cx,cy,cz,cr,lastPacketAt,animTag}
KCD2MP.npcPuppetRunning  = false
KCD2MP._npcPuppetAliveAt = nil

-- Per-entity authority migration (WO-39 Phase 2). A NON-authority player
-- physically manipulating a downed body (dragging/carrying) claims that
-- body's stream by emitting state for it -- the relay's per-entity table
-- (first claim wins, TimeSkip shape) arbitrates and mutes the global
-- authority's stream for that entity while the claim is fresh.
KCD2MP.dragWatch = {}   -- name -> {x,y,z}   last sampled position of a nearby downed body
KCD2MP.dragging  = {}   -- name -> os.clock() of the last observed local move (claim window)
KCD2MP._dragScanAt = 0

-- WO-40 Phase 5: dump every puppet's tug-of-war evidence -- how often the
-- entity was found away from where we wrote it, and the clustered positions
-- it kept being found at. Distinct clusters = distinct competing writers.
function KCD2MP_NpcFightReport()
    local n = 0
    for name, p in pairs(KCD2MP.npcPuppets or {}) do
        n = n + 1
        local attrs = ""
        for i, a in ipairs(p.attr or {}) do
            attrs = attrs .. string.format(" [%d] %.1f,%.1f n=%d", i, a.x, a.y, a.n)
        end
        mp_log(string.format("NPC-FIGHT %s fights=%d target=%.1f,%.1f attractors:%s",
            name, p.fightN or 0, p.tx or 0, p.ty or 0, attrs == "" and " none" or attrs))
    end
    if n == 0 then mp_log("NPC-FIGHT no active puppets") end
end

-- WO-40 Phase 0: field escape hatch for the ghost-mount crash suspect. Off
-- means every ghost mount uses the spawned proxy horse, never a real one.
function KCD2MP_SetHorseAdopt(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.horseAdoptEnabled = true
    elseif s:find("off") then KCD2MP.horseAdoptEnabled = false
    else
        mp_log("mp_horse_adopt: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("HorseAdopt " .. (KCD2MP.horseAdoptEnabled and "ENABLED" or "disabled -- proxy horses only"))
    KCD2MP_ShowInteractionMsg("Horse adoption: " .. (KCD2MP.horseAdoptEnabled and "ON" or "OFF"))
    return true
end

function KCD2MP_EnableNpcSync(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.npcSync.enabled = true
    elseif s:find("off") then
        KCD2MP.npcSync.enabled = false
        KCD2MP.npcTracked = {}   -- drop bookkeeping so re-enabling starts fresh
    else
        mp_log("mp_npc_sync: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    if KCD2MP.npcSync.enabled then KCD2MP_StartNpcSync() end
    mp_log("NPC-SYNC " .. (KCD2MP.npcSync.enabled and "ENABLED" or "disabled")
        .. " radius=" .. KCD2MP.npcSync.radius .. "m max=" .. KCD2MP.npcSync.maxTracked)
    KCD2MP_ShowInteractionMsg("NPC sync: " .. (KCD2MP.npcSync.enabled and "ON" or "OFF"))
    return true
end

-- Is this entity one of ours (a ghost or a ghost's horse)? Checked by
-- reference against the registries, NOT by name -- KCD2MP_ApplyGhostName
-- renames ghost entities to the player's nick (WO-26), so a name prefix
-- test would miss every renamed ghost.
local function mp_is_mod_entity(e)
    for _, g in pairs(KCD2MP.ghosts) do
        if g.entity == e then return true end
    end
    for _, h in pairs(KCD2MP.horseGhosts or {}) do
        if h.entity == e then return true end
    end
    return false
end

-- Rebuild the tracked set: the maxTracked nearest live human NPCs within
-- radius. Names not re-selected simply age out of KCD2MP.npcTracked (their
-- entries are dropped so a re-entering NPC re-heartbeats immediately).
local function mp_npc_rescan()
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end

    local found = {}
    local ents = System.GetEntitiesInSphere(pp, KCD2MP.npcSync.radius) or {}
    for _, e in ipairs(ents) do
        local cls = e.class
        -- WO-38 Phase 5: Horse-class entities travel on the same channel --
        -- an idle horse both worlds have (authored name) converges exactly
        -- like a wandering NPC, which is what makes a peer's unmounted horse
        -- visible in the right place BEFORE anyone mounts it. The horse the
        -- local player is riding is excluded: its position is already implied
        -- by our own position stream, and receivers drive their copy through
        -- the ghost-mount path -- streaming it here too would double-drive.
        local isHorse = (cls == "Horse")
        local isHuman = (cls == "NPC" or cls == "NPC_Female")
        if (isHuman or isHorse) and not mp_is_mod_entity(e)
           and not (isHorse and KCD2MP._mountedHorseName and e:GetName() == KCD2MP._mountedHorseName)
           and not KCD2MP.npcPuppets[e:GetName() or ""] then
            local name = e:GetName()
            -- Only plain authored names travel: they are the cross-client
            -- key, and anything else (spaces, renames) could not be looked
            -- up on the other side anyway.
            if name and string.find(name, "^[%w_]+$") then
                local ep = e:GetWorldPos()
                local dx, dy = ep.x - pp.x, ep.y - pp.y
                table.insert(found, { name = name, e = e, d2 = dx*dx + dy*dy })
            end
        end
    end
    table.sort(found, function(a, b) return a.d2 < b.d2 end)

    local keep = {}
    for i = 1, math.min(#found, KCD2MP.npcSync.maxTracked) do
        local name = found[i].name
        keep[name] = true
        if not KCD2MP.npcTracked[name] then
            KCD2MP.npcTracked[name] = {}
            mp_log("NPC-SYNC tracking " .. name)
        end
    end
    for name in pairs(KCD2MP.npcTracked) do
        if not keep[name] then
            KCD2MP.npcTracked[name] = nil
            mp_log("NPC-SYNC untracking " .. name)
        end
    end
end

-- WO-39 Phase 2: the non-authority half of NPC sync. Watches downed
-- hand-placed humans near the player; a downed body that MOVES while the
-- player stands next to it is being manipulated locally (a dead body does
-- not move by itself -- the only other mover is the inbound puppet stream,
-- which is recognised and excluded below). While the manipulation is fresh,
-- its state is emitted as npc_drag lines -- which is how the entity is
-- claimed; the relay arbitrates first-come and mutes the authority's stream
-- for it. Nothing is sent for bodies nobody is touching.
local DRAG_RADIUS   = 6.0   -- metres: bodies this close to the player are watched
local DRAG_MIN_MOVE = 0.3   -- metres between samples that count as manipulation
local DRAG_TAIL_S   = 3.0   -- emit tail after the last observed move
local DRAG_SCAN_MS  = 500   -- watch-scan cadence (emission runs every tick)

local function mp_drag_sensor()
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end
    local now = os.clock()

    if (now - (KCD2MP._dragScanAt or 0)) * 1000 >= DRAG_SCAN_MS then
        KCD2MP._dragScanAt = now
        local ents = System.GetEntitiesInSphere(pp, DRAG_RADIUS) or {}
        local seen = {}
        for _, e in ipairs(ents) do
            local cls = e.class
            if (cls == "NPC" or cls == "NPC_Female") and not mp_is_mod_entity(e) then
                local name = e:GetName()
                if name and string.find(name, "^[%w_]+$") then
                    local dead, ko = false, false
                    if e.actor then
                        pcall(function() dead = e.actor:IsDead() == true end)
                        pcall(function() ko = e.actor:IsUnconscious() == true end)
                    end
                    if dead or ko then
                        seen[name] = true
                        local p = e:GetWorldPos()
                        local w = KCD2MP.dragWatch[name]
                        if w then
                            local dx, dy, dz = p.x - w.x, p.y - w.y, p.z - w.z
                            if (dx*dx + dy*dy + dz*dz) > DRAG_MIN_MOVE * DRAG_MIN_MOVE then
                                -- A move that lands on the inbound stream's
                                -- target was the puppet body-follow, not us.
                                local pup = KCD2MP.npcPuppets[name]
                                local streamMove = false
                                if pup and pup.tx then
                                    local sx, sy = p.x - pup.tx, p.y - pup.ty
                                    streamMove = (sx*sx + sy*sy) < 0.25
                                end
                                if not streamMove then
                                    if not KCD2MP.dragging[name] then
                                        mp_log("NPC-DRAG claiming " .. name .. " (local manipulation)")
                                    end
                                    KCD2MP.dragging[name] = now
                                end
                            end
                        end
                        KCD2MP.dragWatch[name] = { x = p.x, y = p.y, z = p.z }
                    end
                end
            end
        end
        for name in pairs(KCD2MP.dragWatch) do
            if not seen[name] then KCD2MP.dragWatch[name] = nil end
        end
    end

    for name, lastMove in pairs(KCD2MP.dragging) do
        if now - lastMove > DRAG_TAIL_S then
            KCD2MP.dragging[name] = nil
            mp_log("NPC-DRAG released " .. name .. " (idle " .. DRAG_TAIL_S .. "s)")
        else
            pcall(function()
                local e = System.GetEntityByName(name)
                if not e then return end
                local p = e:GetWorldPos()
                local rot = 0
                pcall(function() rot = e:GetWorldAngles().z or 0 end)
                local hp, dead, ko = -1, false, false
                if e.actor then
                    pcall(function() hp = e.actor:GetHealth() or -1 end)
                    pcall(function() dead = e.actor:IsDead() == true end)
                    pcall(function() ko = e.actor:IsUnconscious() == true end)
                end
                -- WO-40 Phase 7: a downed body moving while glued to the
                -- player (<1.5 m) is being CARRIED, not dragged along the
                -- ground -- a third state (footage: "phases upward onto
                -- shoulders"). Bit 4 tells receivers to follow smoothly
                -- instead of teleport-stepping per half metre.
                local carried = false
                if player then
                    local pp2 = nil
                    pcall(function() pp2 = player:GetWorldPos() end)
                    if pp2 then
                        local cdx, cdy = p.x - pp2.x, p.y - pp2.y
                        carried = (cdx * cdx + cdy * cdy) < 2.25
                    end
                end
                local flags = (dead and 1 or 0) + (ko and 2 or 0) + (carried and 16 or 0)
                KCD2MP_EmitEvent("npc_drag", string.format("%s %.3f %.3f %.3f %.4f %.1f %d",
                    name, p.x, p.y, p.z, rot, hp, flags))
            end)
        end
    end
end

function KCD2MP_NpcSyncTick()
    if not KCD2MP.npcSyncRunning then return end
    Script.SetTimer(KCD2MP.npcSync.emitMs, KCD2MP_NpcSyncTick)  -- reschedule FIRST
    KCD2MP._npcSyncAliveAt = os.clock()

    -- Gate at tick time, not start time: mp_npc_sync can flip and authority
    -- can migrate mid-session, and both must take effect without a restart.
    if not KCD2MP.npcSync.enabled then return end
    if not KCD2MP.hitSensorOn then
        -- WO-39 Phase 2: a non-authority still watches for bodies its own
        -- player is dragging -- that is the one NPC state it may emit.
        pcall(mp_drag_sensor)
        return
    end

    local now = os.clock()
    if (now - (KCD2MP._npcScanAt or 0)) * 1000 >= KCD2MP.npcSync.scanMs then
        KCD2MP._npcScanAt = now
        pcall(mp_npc_rescan)
    end

    -- WO-40 Phase 6: an NPC's real swings are invisible to Lua, but the one
    -- moment that matters most -- the NPC landing a hit on THIS player -- is
    -- visible as our own health dropping. That edge, attributed to a nearby
    -- weapon-drawn tracked NPC, becomes a swing cue on the observers' side.
    local playerHit, ppos = false, nil
    if player then
        pcall(function() ppos = player:GetWorldPos() end)
        if player.actor then
            local ph = nil
            pcall(function() ph = player.actor:GetHealth() end)
            if ph then
                if KCD2MP._npcSyncPrevPlayerHp and ph < KCD2MP._npcSyncPrevPlayerHp - 0.5 then
                    playerHit = true
                end
                KCD2MP._npcSyncPrevPlayerHp = ph
            end
        end
    end

    for name, t in pairs(KCD2MP.npcTracked) do
        pcall(function()
            local e = System.GetEntityByName(name)
            if not e then KCD2MP.npcTracked[name] = nil; return end
            local p = e:GetWorldPos()
            local rot = 0
            pcall(function() rot = e:GetWorldAngles().z or 0 end)
            local hp, dead, ko = -1, false, false
            if e.actor then
                pcall(function() hp = e.actor:GetHealth() or -1 end)
                pcall(function() dead = e.actor:IsDead() == true end)
                -- WO-38 Phase 6: knockout is a real state distinct from death
                -- and travels as its own flag bit, so a receiver can freeze
                -- its copy of a knocked-out NPC instead of walking it.
                pcall(function() ko = e.actor:IsUnconscious() == true end)
            end

            -- WO-40 Phase 6: the NPC's weapon state travels as flag bit 2 so
            -- an observer's copy fights in a guard stance instead of standing
            -- with arms down (the footage's "the NPC itself does nothing").
            local drawn = false
            pcall(function() drawn = e.human and e.human:IsWeaponDrawn() == true end)
            local swingCue = false
            if playerHit and drawn and ppos then
                local sx, sy = p.x - ppos.x, p.y - ppos.y
                if sx * sx + sy * sy <= 16.0 then swingCue = true end
            end

            local moved = not t.lastX
                or math.abs(p.x - t.lastX) > KCD2MP.npcSync.moveEps
                or math.abs(p.y - t.lastY) > KCD2MP.npcSync.moveEps
                or math.abs(p.z - t.lastZ) > KCD2MP.npcSync.moveEps
            local hpChanged = t.lastHp and hp >= 0 and math.abs(hp - t.lastHp) > 0.5
            local heartbeat = not t.lastSentAt or (now - t.lastSentAt) >= KCD2MP.npcSync.heartbeatS

            local koChanged = (ko ~= (t.sentKo or false))
            local drawnChanged = (drawn ~= (t.sentDrawn or false))
            if moved or hpChanged or heartbeat or koChanged or drawnChanged or swingCue
               or (dead and not t.sentDead) then
                local flags = (dead and 1 or 0) + (ko and 2 or 0)
                    + (drawn and 4 or 0) + (swingCue and 8 or 0)
                KCD2MP_EmitEvent("npc_state", string.format("%s %.3f %.3f %.3f %.4f %.1f %d",
                    name, p.x, p.y, p.z, rot, hp, flags))
                t.lastX, t.lastY, t.lastZ, t.lastRot = p.x, p.y, p.z, rot
                t.lastHp, t.lastSentAt, t.sentDead, t.sentKo = hp, now, dead, ko
                t.sentDrawn = drawn
            end
        end)
    end
end

function KCD2MP_StartNpcSync()
    if tickAlive(KCD2MP.npcSyncRunning, KCD2MP._npcSyncAliveAt) then return end
    KCD2MP.npcSyncRunning = true
    KCD2MP._npcSyncAliveAt = os.clock()
    mp_log("NPC-SYNC emit tick started (" .. KCD2MP.npcSync.emitMs .. "ms)")
    Script.SetTimer(KCD2MP.npcSync.emitMs, KCD2MP_NpcSyncTick)
end

-- Receiving side. Called by the agent for each NpcStateDown (0x27). Never
-- spawns anything: an NPC not loaded in this world is simply not ours to move.
function KCD2MP_ApplyNpcState(name, x, y, z, rot, hp, flags)
    local e = System.GetEntityByName(name)
    if not e then return end

    -- WO-38 Phase 5: a horse currently adopted as some ghost's mount is owned
    -- by the ghost-mount driver -- a puppet stream for the same entity would
    -- be a second writer fighting it every tick.
    for _, hd in pairs(KCD2MP.horseGhosts or {}) do
        if hd.isWorldHorse and hd.worldName == name then return end
    end

    local p = KCD2MP.npcPuppets[name]
    if not p then
        local cur = e:GetWorldPos()
        p = { cx = cur.x, cy = cur.y, cz = cur.z, cr = rot, animTag = "idle" }
        KCD2MP.npcPuppets[name] = p
        mp_log("NPC-SYNC puppet start " .. name)
    end
    p.tx, p.ty, p.tz, p.tr = x, y, z, rot
    p.hp = hp
    local f = tonumber(flags) or 0
    local wasKo = p.ko
    p.dead  = (math.floor(f) % 2) == 1          -- bit 0
    p.ko    = (math.floor(f / 2) % 2) == 1      -- bit 1 (WO-38 Phase 6: knocked out in the authority's world)
    p.drawn = (math.floor(f / 4) % 2) == 1      -- bit 2 (WO-40 Phase 6: weapon out in the authority's world)
    local swingCue = (math.floor(f / 8) % 2) == 1  -- bit 3 (WO-40 Phase 6: it just landed a hit there)
    p.carried = (math.floor(f / 16) % 2) == 1   -- bit 4 (WO-40 Phase 7: a player is carrying this body)
    p.lastPacketAt = os.clock()
    if swingCue and not p.dead and not p.ko then
        p.swingCuePending = true
    end
    -- WO-40 Phase 6: a knockout happening next to a player's ghost is almost
    -- always that player's takedown (the footage's choke rendered as a brief
    -- shield-block on the observer's screen). Play the paired master/victim
    -- takedown clips: victim on the NPC, master on the closest ghost within
    -- arm's reach. Names are probed (findAnim); none-found degrades to the
    -- existing freeze behaviour. Only a WITNESSED transition cues -- a body
    -- that is already KO on its first packet (late join) just freezes.
    if p.ko and wasKo == false and p.everPacket then
        pcall(function() KCD2MP_NpcTakedownCue(name, e, x, y, z) end)
    end
    p.everPacket = true
    KCD2MP_StartNpcPuppet()
end

function KCD2MP_NpcPuppetTick(arg)
    if not KCD2MP.npcPuppetRunning then return end
    -- WO-40 Phase 2: same pump pattern as KCD2MP_InterpTick. A menu suspends
    -- Script.SetTimer (WO-12/13), which froze every NPC puppet for the paused
    -- player -- the WO-13 ghost fix was never applied to this second tick.
    -- The agent's menu pump now calls this with arg="ext": no reschedule, no
    -- alive-stamp (a pumped call must not make a dead chain look healthy).
    if arg ~= "ext" then
        Script.SetTimer(50, KCD2MP_NpcPuppetTick)  -- reschedule FIRST
        KCD2MP._npcPuppetAliveAt = os.clock()
    end

    local now = os.clock()
    local any = false
    for name, p in pairs(KCD2MP.npcPuppets) do
        pcall(function()
            -- Release on silence: the engine restores the NPC to its own
            -- schedule the moment we stop writing (observed live, WO-32).
            if (now - (p.lastPacketAt or 0)) > KCD2MP.npcSync.releaseS then
                KCD2MP.npcPuppets[name] = nil
                mp_log("NPC-SYNC release " .. name .. " (stream silent)")
                return
            end
            any = true

            local e = System.GetEntityByName(name)
            if not e then return end

            -- WO-34's corpse lesson, applied on both death sources: if the
            -- authority says dead, or this world's copy died locally, stop
            -- driving -- a corpse must not be dragged around. WO-38 Phase 6
            -- extends the same rule to unconsciousness on both sources: a
            -- knocked-out NPC kept walking under the stream (Section G).
            local locallyDead, locallyKo = false, false
            if e.actor then
                pcall(function() locallyDead = e.actor:IsDead() == true end)
                pcall(function() locallyKo = e.actor:IsUnconscious() == true end)
            end
            -- WO-40 Phase 6: the authority's weapon state, applied on the
            -- transition (the same DrawWeapon/HolsterWeapon calls the ghost
            -- path live-verified in WO-39).
            if (p.drawn or false) ~= (p.appliedDrawn or false) then
                p.appliedDrawn = p.drawn or false
                if e.human then
                    if p.drawn then pcall(function() e.human:DrawWeapon() end)
                    else pcall(function() e.human:HolsterWeapon() end) end
                end
                mp_log("NPC-SYNC " .. name .. (p.drawn and " drew weapon" or " sheathed weapon"))
            end

            if p.dead or p.ko or locallyDead or locallyKo then
                -- WO-38 Phase 6, the drag gap: on THIS channel the stream is
                -- the body's actual location in the authority's world (unlike
                -- the ghost stream, which is a live player's position -- that
                -- one must stay frozen, WO-34). So a body is allowed to
                -- FOLLOW a meaningful stream move -- the authority dragging a
                -- corpse -- as a one-shot placement, no animation, no per-tick
                -- lerp fighting the local ragdoll. Small jitter stays frozen.
                -- WO-40 Phase 7: a CARRIED body follows the stream smoothly
                -- every tick (a body on someone's shoulders moves like they
                -- do), instead of the half-metre teleport steps that read as
                -- "phases upward onto shoulders" in the footage. Dragged/
                -- static bodies keep the one-shot placement -- a per-tick
                -- lerp would fight the local ragdoll for no reason.
                if p.carried then
                    local cdx2 = (p.tx or p.cx) - p.cx
                    local cdy2 = (p.ty or p.cy) - p.cy
                    if cdx2 * cdx2 + cdy2 * cdy2 > 25.0 then
                        p.cx, p.cy, p.cz = p.tx, p.ty, p.tz
                    else
                        p.cx = p.cx + cdx2 * 0.5
                        p.cy = p.cy + cdy2 * 0.5
                        p.cz = p.tz or p.cz
                    end
                    pcall(function() e:SetWorldPos({x = p.cx, y = p.cy, z = p.cz}) end)
                    if p.animTag ~= "carried" then
                        p.animTag = "carried"
                        mp_log("NPC-SYNC body carried-follow " .. name)
                    end
                    return
                end
                local bx = p.dragX or p.cx
                local by = p.dragY or p.cy
                local ddx = (p.tx or bx) - bx
                local ddy = (p.ty or by) - by
                if (ddx*ddx + ddy*ddy) > 0.25 then
                    p.dragX, p.dragY = p.tx, p.ty
                    pcall(function() e:SetWorldPos({x = p.tx, y = p.ty, z = p.tz or p.cz}) end)
                    mp_log(string.format("NPC-SYNC body follow %s -> %.1f,%.1f", name, p.tx, p.ty))
                end
                return
            end

            -- WO-40 Phase 6: swing cue, and the one-shot pin. Per-tick
            -- SetWorldPos + anim restarts stomp one-shots before a frame
            -- renders (WO-39's ghost lesson) -- while a cue plays, this
            -- puppet gets no writes at all; the lerp catches up after.
            if p.swingCuePending then
                p.swingCuePending = nil
                pcall(function() KCD2MP_PuppetSwingCue(name, p, e) end)
            end
            if (p.oneShotUntil or 0) > now then return end

            -- WO-40 Phase 5 diagnostic: measure the tug-of-war instead of
            -- guessing. If the entity is found away from where we last wrote
            -- it, something else moved it -- count it, and cluster WHERE it
            -- was found so a live session can answer "how many competing
            -- attractors does this NPC have" (the footage's wagon worker
            -- phased between THREE points, not the documented two).
            if p.lastWroteX then
                local ap = nil
                pcall(function() ap = e:GetWorldPos() end)
                if ap then
                    local fx, fy = ap.x - p.lastWroteX, ap.y - p.lastWroteY
                    if (fx*fx + fy*fy) > 0.5625 then
                        p.fightN = (p.fightN or 0) + 1
                        p.attr = p.attr or {}
                        local matched = false
                        for _, a in ipairs(p.attr) do
                            local ax, ay = ap.x - a.x, ap.y - a.y
                            if (ax*ax + ay*ay) < 1.0 then a.n = a.n + 1; matched = true; break end
                        end
                        if not matched and #p.attr < 6 then
                            p.attr[#p.attr + 1] = { x = ap.x, y = ap.y, n = 1 }
                        end
                    end
                end
            end

            -- Same teleport-vs-lerp shape as the ghost interp: snap on a big
            -- gap, smooth otherwise.
            local dx, dy = (p.tx or p.cx) - p.cx, (p.ty or p.cy) - p.cy
            if dx*dx + dy*dy > 25.0 then
                p.cx, p.cy, p.cz, p.cr = p.tx, p.ty, p.tz, p.tr
            else
                p.cx = p.cx + dx * 0.5
                p.cy = p.cy + dy * 0.5
                p.cz = p.tz or p.cz
                p.cr = p.tr or p.cr
            end

            e:SetWorldPos({x = p.cx, y = p.cy, z = p.cz})
            p.lastWroteX, p.lastWroteY = p.cx, p.cy
            pcall(function() e:SetWorldAngles({x = 0, y = 0, z = p.cr}) end)

            -- Animation from rendered speed, exactly the ghost thresholds.
            -- Without this the NPC slides in its current activity pose
            -- (observed live: a seated NPC slid sitting).
            --
            -- WO-38 Phase 5: a Horse-class puppet gets horse gaits, not
            -- humanoid locomotion. These three names were confirmed present
            -- on real KCD2 horse entities by the mp_scan_horse probes (see
            -- the HORSE_ENTITY_* candidate lists' comments).
            local spd = math.sqrt(dx*dx + dy*dy) * 0.5 / 0.050
            local tag, anim
            if tostring(e.class or "") == "Horse" then
                if     spd >= 4.0 then tag, anim = "gallop", "relaxed_gallop"
                elseif spd >= 0.3 then tag, anim = "walk",   "relaxed_walk"
                else                    tag, anim = "idle",   "relaxed_idle" end
            else
                if     spd >= 5.5 then tag, anim = "sprint", "3d_relaxed_sprint_turn_strafe"
                elseif spd >= 3.0 then tag, anim = "run",    "3d_relaxed_run_turn_strafe"
                elseif spd >= 0.3 then tag, anim = "walk",   "3d_relaxed_walk_turn_strafe"
                else                    tag, anim = "idle",   "relaxed_idle_both" end
                -- WO-40 Phase 6: a weapon-out NPC idles in the combat guard
                -- (human-confirmed correct read on ghosts, WO-39), so a
                -- fighting NPC reads as fighting instead of standing.
                if tag == "idle" and p.drawn then
                    local cIdle = nil
                    pcall(function() cIdle = KCD2MP_CombatIdleFor(e) end)
                    if cIdle then tag, anim = "combatidle", cIdle end
                end
            end
            -- WO-40 Phase 5: restart the looped locomotion only on a tag
            -- change, with a 1 s keep-alive refresh -- not every 50 ms tick.
            -- Restarting a loop 20x/sec is pure animation-system churn (the
            -- WO-39 stomping mechanism, applied to a second code path), and
            -- the joiner's global animation collapse followed the session's
            -- heaviest per-frame load. External stops recover within 1 s.
            if p.animTag ~= tag or (now - (p.animRefreshAt or 0)) > 1.0 then
                p.animRefreshAt = now
                pcall(function() e:StartAnimation(0, anim, 0, 0.15, 1.0, true) end)
                if p.animTag ~= tag then
                    p.animTag = tag
                    mp_log(string.format("NPC-SYNC anim %s -> %s spd=%.2f", name, tag, spd))
                end
            end
        end)
    end

    -- Nothing left to drive: let the chain die. A future packet restarts it.
    if not any then
        local empty = true
        for _ in pairs(KCD2MP.npcPuppets) do empty = false; break end
        if empty then
            KCD2MP.npcPuppetRunning = false
            mp_log("NPC-SYNC puppet tick stopped (no puppets)")
        end
    end
end

function KCD2MP_StartNpcPuppet()
    if tickAlive(KCD2MP.npcPuppetRunning, KCD2MP._npcPuppetAliveAt) then return end
    KCD2MP.npcPuppetRunning = true
    KCD2MP._npcPuppetAliveAt = os.clock()
    mp_log("NPC-SYNC puppet tick started (50ms)")
    Script.SetTimer(50, KCD2MP_NpcPuppetTick)
end

-- WO-27: verified entity removal.
--
-- System.RemoveEntity has been observed returning without error while the
-- entity is still alive and still in the world -- seen in WO-25 and again in
-- WO-26, where it took four passes to clear three ghosts. A single call is
-- therefore not evidence of removal, so this reads the entity back and
-- retries, and reports what actually happened rather than that the call did
-- not throw.
--
-- Two lookups, both by keys that survive the entity's lifetime: the entity id
-- captured at spawn, and the SPAWN name ("kcd2mp_<id>") -- which is also the
-- key the RPG SoulList files the ghost's soul under. The display name is
-- deliberately not used: it is not a key anything can be looked up by.
local function mp_remove_entity_verified(entityId, spawnName, label)
    local function alive()
        local e = nil
        if entityId then pcall(function() e = System.GetEntity(entityId) end) end
        if (not e) and spawnName then
            pcall(function() e = System.GetEntityByName(spawnName) end)
        end
        return e
    end

    for pass = 1, 4 do
        local e = alive()
        if not e then
            if pass > 1 then
                mp_log(string.format("RemoveEntity %s gone after %d pass(es)", tostring(label), pass - 1))
            end
            return true
        end
        pcall(function() System.RemoveEntity(e.id or entityId) end)
    end

    local e = alive()
    if e then
        mp_log(string.format("RemoveEntity %s STILL ALIVE after 4 passes (entityId=%s name=%s)",
            tostring(label), tostring(entityId), tostring(spawnName)))
        return false
    end
    return true
end

-- WO-27: how many ghost entities actually exist right now, counted from the
-- world rather than from KCD2MP.ghosts. The bookkeeping table is exactly what
-- the leak got wrong, so a count taken from it would agree with itself and
-- prove nothing. Returns registered, live, and the list of live spawn names.
function KCD2MP_GhostAudit()
    local registered, live, names = 0, 0, {}

    for gid, g in pairs(KCD2MP.ghosts) do
        registered = registered + 1
        local e = nil
        if g.entityId then pcall(function() e = System.GetEntity(g.entityId) end) end
        if e then
            live = live + 1
            table.insert(names, "kcd2mp_" .. tostring(gid))
        end
    end

    -- Orphans: an entity still in the world under a spawn name that no longer
    -- has a KCD2MP.ghosts row. This is the shape the leak actually took.
    for probe = 0, 32 do
        if not KCD2MP.ghosts[tostring(probe)] and not KCD2MP.ghosts[probe] then
            local e = nil
            pcall(function() e = System.GetEntityByName("kcd2mp_" .. probe) end)
            if e then
                live = live + 1
                table.insert(names, "kcd2mp_" .. probe .. " (ORPHAN)")
            end
        end
    end

    mp_log(string.format("GhostAudit registered=%d live=%d [%s]",
        registered, live, table.concat(names, ", ")))
    return registered, live
end

-- WO-27: which player a ghost belongs to, as a key that survives a reconnect.
--
-- The connection id does NOT: the relay hands out a fresh byte per connection,
-- so the same human coming back is a different id, and the old id's row is
-- never touched again. That is the whole leak -- WO-26 found three registered
-- ghosts (ids 1, 2, 3) that were all one player, all wearing the same Steam
-- nick, two of them orphaned.
--
-- The Steam nick is the only stable identity that reaches Lua: it arrives in
-- the 0x03 Name packet at handshake time, before the first Position packet
-- (docs/WO-20-faces.md), and it is already what KCD2MP_PickFaceForPlayer keys
-- the face roster on. When it has NOT arrived, this falls back to
-- "Player<id>", which is per-connection and so cannot dedupe -- an honest
-- limit, not a silent one: two nameless reconnects will still leak, and the
-- fallback is logged at spawn.
local function mp_ghost_identity(id)
    return KCD2MP.ghostNames[id]
end

-- Removes any ghost belonging to the same player under a DIFFERENT connection
-- id. Called before a spawn, so a reconnect replaces its predecessor instead
-- of orphaning it.
function KCD2MP_RemoveStaleGhostsForPlayer(identity, keepId)
    if not identity then return 0 end
    local doomed = {}
    for gid, g in pairs(KCD2MP.ghosts) do
        if gid ~= keepId and g.identity == identity then
            table.insert(doomed, gid)
        end
    end
    for _, gid in ipairs(doomed) do
        mp_log(string.format("Reconnect: '%s' returned as id=%s -- removing stale ghost id=%s",
            tostring(identity), tostring(keepId), tostring(gid)))
        KCD2MP_RemoveGhost(gid)
    end
    return #doomed
end

function KCD2MP_SpawnGhost(id, x, y, z, rotZ)
    if KCD2MP.ghosts[id] then
        KCD2MP_RemoveGhost(id)
    end

    -- WO-27: same player, new connection id. Must run BEFORE the spawn, so
    -- there is never a moment with two ghosts for one person.
    local identity = mp_ghost_identity(id)
    if identity then
        KCD2MP_RemoveStaleGhostsForPlayer(identity, id)
    else
        mp_log("SpawnGhost id=" .. tostring(id) ..
               " has no Steam nick yet -- reconnect dedupe cannot run for this spawn")
    end

    local pos = {x=x, y=y, z=z}
    local name = "kcd2mp_" .. id

    System.LogAlways(string.format("[KCD2-MP] Spawning ghost '%s' at %.1f,%.1f,%.1f", id, x, y, z))

    -- WO-20: deterministic real face. Keyed on the Steam name if it has
    -- already arrived (KCD2MP_SetGhostName runs at Handshake time on the
    -- server, before any Position packet -- see docs/WO-20-faces.md -- so in
    -- practice it almost always has), falling back to the same "Player<id>"
    -- string the nameplate itself falls back to so a spawn is never blocked
    -- waiting on the name.
    local faceKey = identity or ("Player" .. tostring(id))
    local facePick = KCD2MP_PickFaceForPlayer(faceKey)

    -- WO-27: an entity may still be standing under this exact spawn name with
    -- no KCD2MP.ghosts row behind it -- after a save load, after the mod
    -- reinitialised, or after a RemoveEntity that silently did nothing.
    -- Spawning over it would leave the old one in the world untracked, which
    -- is the other half of how WO-26 found three ghosts for one player.
    local preexisting = nil
    pcall(function() preexisting = System.GetEntityByName(name) end)
    if preexisting then
        mp_log("SpawnGhost: untracked entity already named " .. name .. " -- removing it first")
        mp_remove_entity_verified(preexisting.id, name, name)
    end

    -- WO-22: SharedSoulGuid is a TOP-LEVEL parameter of SpawnEntity's table, not
    -- something nested under Properties. Warhorse's own shipped scriptbind doc
    -- (C_ScriptBindXGenAIModule__SpawnEntity) gives a flat table -- Name,
    -- SharedSoulGuid, SoulArchetypeName, ClassName, Pos, Rot, NoAI,
    -- SchedulerProxyName, ... -- with no Properties key in it at all.
    --
    -- Passing it nested, as this did until WO-22, binds NO soul: the spawned
    -- ghost's SharedSoulGuid reads back all-zeroes and it gets an arbitrary
    -- engine-generated appearance. That is why every ghost was brainless --
    -- a Warhorse brain is a column on the soul row (brain_id in
    -- Libs/Tables/rpg/soul__*.xml), so no soul means no brain.
    --
    -- Passed correctly, the ghost gets the roster soul's real face, faction
    -- identity, reputation log and combat level -- and, verified live, it
    -- RECOVERS from being knocked unconscious (<=54s and <=26s over two
    -- cycles) where a brainless ghost stayed down forever. That is A1 from
    -- WO-16-release-candidate.md, fixed. See docs/WO-22-brain-lead.md.
    --
    -- SchedulerProxyName is deliberately NOT passed. It is what would make the
    -- ghost pick its own activities and walk off under its own power, which
    -- fights KCD2MP_InterpTick's position stream. It is not needed for the
    -- recovery fix -- the soul alone buys that -- so a ghost spawned this way
    -- stays byte-stationary, exactly as before. ForceMount is unaffected
    -- (re-tested against a real horse on this exact shape).
    --
    -- esModularBehaviorTree is gone rather than emptied: WO-21 proved it is
    -- inert and that "IdleSeq" names no tree anywhere in the shipped game
    -- data. It was never a live variable, so the aggro toggle's switch on it
    -- was a no-op. A soul-backed ghost's reactive combat (self-defense,
    -- joining nearby fights) comes from the engine's own AI/soul/brain
    -- system once SharedSoulGuid is bound here, and is always on regardless
    -- of the aggro toggle (WO-26). The toggle's own effect is a separate,
    -- additive native hostile-faction attach applied at hit-time, not at
    -- spawn (WO-27) -- see KCD2MP_EnableAggro above.
    local entity = nil
    pcall(function()
        XGenAIModule.SpawnEntity{
            Name           = name,
            ClassName      = facePick.className,
            Pos            = {x, y, z},
            SharedSoulGuid = facePick.guid,
        }
        entity = System.GetEntityByName(name)
    end)
    if not entity then
        System.LogAlways("[KCD2-MP] XGenAI spawn failed, fallback System.SpawnEntity")
        local ok2, e2 = pcall(System.SpawnEntity, {
            class = facePick.className, position = pos, name = name,
            properties = { esFaction = "Civilians", guidSharedSoulId = facePick.guid },
        })
        if ok2 then entity = e2 end
    end
    System.LogAlways(string.format("[KCD2-MP] face pick for '%s': key=%s class=%s soul=%s guid=%s",
        id, faceKey, facePick.className, facePick.soulName, facePick.guid))

    if not entity then
        System.LogAlways("[KCD2-MP] SpawnEntity failed for ghost id=" .. tostring(id))
        return nil
    end

    -- Set faction via AI system (XGenAIModule ignores Properties.esFaction at spawn time)
    pcall(function()
        entity.Properties.esFaction = "Civilians"
        AI.ChangeParameter(entity.id, AIPARAM_FACTION, "Civilians")
    end)

    System.LogAlways("[KCD2-MP] Spawned entityId=" .. tostring(entity.id))

    -- Apply white/red armor preset (ClothingPreset first, then WeaponPreset + visor).
    --
    -- WO-20: white_red's item list is entirely male mesh variants ("_m0X").
    -- Confirmed live: an NPC_Female entity fault-freely accepts the preset
    -- call (pcall ok=true, no error) but nothing renders and
    -- EquippedArmorsByClassId reads back EMPTY afterwards -- not just missing
    -- the preset items, but stripped of the soul's own authored default
    -- outfit too, leaving her in the bare base layer. A plain NPC_Female
    -- spawned with NO preset call keeps her own default outfit fine (also
    -- confirmed live). So the preset call is actively destructive on a
    -- female-classed ghost, not merely ineffective -- skip it for her and
    -- let the soul's own authored outfit stand. The male path is unchanged.
    if facePick.className ~= "NPC_Female" then
        local p = KCD2MP.armorPresets.white_red
        pcall(function() entity.actor:EquipClothingPreset(p.preset) end)
        pcall(function() entity.actor:EquipWeaponPreset(p.weapons) end)
    end
    local ghostName = name
    Script.SetTimer(800, function()
        pcall(function() System.ExecuteCommand("closeVisorOn " .. ghostName) end)
    end)

    -- WO-17: human:DrawWeapon() is a real, visually-confirmed native mutation
    -- (unlike EquipWeaponPreset, which is cosmetic-only, WO-9). WO-17's own
    -- claim that it never flips CombatSoul.HasMeleeWeapon was disproved by
    -- WO-21: on a male ghost with a real equipped weapon item, this call does
    -- flip HasMeleeWeapon=true, and WO-22/23 confirmed it holds true for
    -- soul-backed, brained ghosts. On a female ghost (no weapon item to draw)
    -- the flag correctly stays false -- that is the item being absent, not a
    -- broken call. Whether a ghost actually lands a blow is a separate,
    -- emergent AI-brain decision (morale, odds, context) that this call does
    -- not control either way (WO-22/23: every hostile ghost tested so far
    -- chose to flee rather than fight, being outnumbered).
    if KCD2MP.aggroEnabled then
        Script.SetTimer(1000, function()
            local g = KCD2MP.ghosts[id]
            if g and g.entity and g.entity.human then
                pcall(function() g.entity.human:DrawWeapon() end)
            end
        end)
    end

    local r = rotZ or 0

    -- Interpolation state: buffer with prev packet (A) and target packet (B)
    -- alpha: 0 = at A, 1 = at B, >1 = dead reckoning beyond B
    -- alphaStep: how much alpha advances per 50ms tick (= 50ms / packetInterval)
    --   default assumes 200ms server tick -> step = 0.25 (reaches B in 4 ticks)
    local istate = {
        -- Previous packet (lerp source)
        px = x, py = y, pz = z, pr = r,
        -- Target packet (lerp destination)
        tx = x, ty = y, tz = z, tr = r,
        -- Current rendered position
        cx = x, cy = y, cz = z, cr = r,
        -- Interpolation progress
        alpha = 1.0,
        alphaStep = 0.25,
        -- Dead reckoning velocity (units/sec), computed from last two packets
        vx = 0, vy = 0, vz = 0,
        -- Last ACTUAL packet position (separate from tx/ty which DR extends)
        lastPacketX = x, lastPacketY = y,
        -- Ticks since last server packet (for dead reckoning timeout)
        ticksSincePacket = 0,
        -- Packet arrival count (for logging)
        packetCount = 0,
        -- Animation state
        animTag = "idle",     -- "idle"/"walk"/"run" - current animation state
        smoothedSpeed = 0,
        prevCx = x, prevCy = y,
        speedDropTicks = 0,   -- consecutive ticks with low speed after high speed
        -- WO-40 Phase 0: crash guard -- ForceMount must never race a fresh
        -- spawn's soul/equip initialization (host crash #2 died exactly at
        -- spawn+400ms mount). Mount waits until the ghost is >=3 s old.
        spawnedAtClock = os.clock(),
    }

    KCD2MP.ghosts[id] = {
        entity = entity,
        entityId = entity.id,
        istate = istate,
        facePick = facePick,
        faceKey = faceKey,
        -- WO-27: nil until the Steam nick has arrived. Refreshed by
        -- KCD2MP_SetGhostName if the name turns up after the spawn, so a late
        -- name still arms the reconnect dedupe for the NEXT reconnect.
        identity = identity,
        spawnName = name,
    }

    -- WO-46: report the ghost's raw CryEngine entity id to the agent, which
    -- feeds it to the native swing path (the DLL addresses actors by this id,
    -- not by name or guid). entity.id is a userdata whose tostring prints the
    -- id as zero-padded hex -- the ONLY faithful numeric form this sandbox
    -- can produce, since its 32-bit-float numbers lose integer precision
    -- above 2^24 (WO-20/WO-40). Re-emitted naturally on every respawn because
    -- all spawns funnel through here, so the agent's cache self-heals after
    -- a save reload rebuilds the ghost bodies.
    local hexid = string.match(tostring(entity.id), "(%x+)%s*$")
    if hexid then
        KCD2MP_EmitEvent("ghostid", tostring(id) .. " " .. hexid)
    else
        mp_log("SpawnGhost: could not extract entity id hex from " .. tostring(entity.id)
               .. " -- native swings unavailable for ghost " .. tostring(id))
    end

    -- WO-38 Phase 7: if the stimulus-deafness A/B toggle is on, new spawns
    -- get it too, or a reconnect would silently undo the experiment mid-test.
    if KCD2MP.ghostsIgnorant then
        pcall(function() AI.SetIgnorant(entity.id, 1) end)
    end

    -- Schedule name apply after entity fully inits (soul may not be ready at spawn time).
    -- Uses Steam nick if already received via 0x03, else fallback "Player<id>".
    local captId = id
    Script.SetTimer(1500, function()
        local displayName = KCD2MP.ghostNames[captId] or ("Player" .. captId)
        KCD2MP_ApplyGhostName(captId, displayName)
    end)

    -- Auto-start interp loop as soon as we have a ghost to move
    KCD2MP_StartInterp()

    return entity
end

-- ===== Ghost Name (Steam nick above head) =====

-- Actually applies name to a ready entity. Logs before/after to diagnose soul.name write.
function KCD2MP_ApplyGhostName(id, name)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then
        mp_log("ApplyName id=" .. id .. " no entity")
        return
    end
    local e = ghost.entity

    -- Read current soul.name before assignment (to see what the default is)
    local before = nil
    pcall(function() before = e.soul and e.soul.name end)

    -- Attempt 1: soul.name = plain string (KCD2 shows this in NPC nameplates)
    local ok1 = pcall(function() e.soul.name = name end)
    -- Attempt 2: soul.sName (alternative field name seen in some CryEngine versions)
    local ok2 = pcall(function() e.soul.sName = name end)

    -- WO-27: `e:SetName(name)` USED to be attempt 3 here, and is deliberately
    -- gone. It renamed the entity away from "kcd2mp_<id>" -- the name it was
    -- spawned under and, critically, the key the RPG SoulList continues to
    -- file its soul under. Confirmed live in WO-26: after the rename,
    -- SoulsByName/Player91 404s while SoulsByName/kcd2mp_91 resolves. So the
    -- rename made every by-name lookup -- ours and the agent's -- miss the
    -- entity it was trying to find, including the ones that clean it up.
    --
    -- Nothing wanted it. The nameplate a player actually sees is drawn by this
    -- mod from KCD2MP.ghostNames (see KCD2MP_InterpTick's labelCache write),
    -- and the game's own NPC nameplate reads soul.name, which attempt 1 sets.

    -- Read back to verify assignment succeeded
    local after = nil
    pcall(function() after = e.soul and e.soul.name end)

    mp_log(string.format("ApplyName id=%s name=%s ok1=%s ok2=%s before=%s after=%s",
        id, name, tostring(ok1), tostring(ok2), tostring(before), tostring(after)))
end

-- Store name; if ghost already exists apply with short delay, else applied at spawn (1.5s).
function KCD2MP_SetGhostName(id, name)
    KCD2MP.ghostNames[id] = name
    local ghost = KCD2MP.ghosts[id]
    -- WO-27: a ghost that spawned before its nick arrived has identity=nil and
    -- could not be deduped. Backfill it now, and sweep any older ghost that
    -- turns out to belong to this same player, so the leak is closed even in
    -- the race where the Position packet beat the Name packet.
    if ghost then
        ghost.identity = name
        KCD2MP_RemoveStaleGhostsForPlayer(name, id)
    end
    if ghost and ghost.entity then
        -- Ghost already alive when name packet arrives — apply after 300ms
        local captId = id
        local captName = name
        Script.SetTimer(300, function()
            KCD2MP_ApplyGhostName(captId, captName)
        end)
    end
    -- No ghost yet: name stored in ghostNames, applied at spawn (1.5s delay there)
end

-- ===== Horse Ghost Spawn / Remove =====

-- WO-38 Phase 5. Called by the agent from a HorseInfoDown (0x2B): the
-- authored name of the horse that player is riding, "" for dismounted or
-- unknown. Stored for the next mount; if that ghost is ALREADY riding a
-- spawned proxy and the named world horse exists here, the proxy is swapped
-- out for the real horse -- the identity packet and the riding flag race on
-- two different channels, so late arrival is the normal case, not an error.
function KCD2MP_SetGhostHorse(id, name)
    id = tostring(id)
    name = tostring(name or "")
    KCD2MP.ghostHorseName[id] = name
    mp_log("GHOST_HORSE id=" .. id .. " name='" .. name .. "'")

    local hd = KCD2MP.horseGhosts[id]
    local ghost = KCD2MP.ghosts[id]
    if name ~= "" and hd and not hd.isWorldHorse and ghost and ghost.istate
       and ghost.istate.isRiding then
        local world = nil
        pcall(function() world = System.GetEntityByName(name) end)
        if world and tostring(world.class or "") == "Horse" then
            mp_log("GHOST_HORSE swapping proxy for world horse '" .. name .. "' id=" .. id)
            if ghost.istate.nativeMounted then
                pcall(function() ghost.entity.human:ForceDismount() end)
                ghost.istate.nativeMounted = false
            end
            KCD2MP_RemoveHorse(id)
            local wp = nil
            pcall(function() wp = ghost.entity:GetWorldPos() end)
            KCD2MP_SpawnHorse(id, wp and wp.x or 0, wp and wp.y or 0, wp and wp.z or 0,
                ghost.istate.tr or 0)
        end
    end
end

function KCD2MP_SpawnHorse(id, x, y, z, rotZ)
    if KCD2MP.horseGhosts[id] then
        KCD2MP_RemoveHorse(id)
    end

    -- WO-38 Phase 5: if we know WHICH horse that player mounted and this
    -- world has the same-named entity, adopt it instead of spawning the
    -- generic proxy. Right look (Section D's grey-horse report was the
    -- proxy's default appearance), and a real horse the local player can
    -- still interact with. Position is driven exactly like a proxy while
    -- ridden; on dismount the entry is dropped and the engine takes the
    -- horse back (the WO-32 release principle -- verified on human NPCs,
    -- horse behaviour is live-gated).
    local wantName = KCD2MP.ghostHorseName[id]
    -- WO-40 Phase 0: both real host crashes (19:25:05 / 20:23:54 in the
    -- 2026-08-18 bundles) landed within ~1.5 s of an inbound ghost mount.
    -- Two guards, both cheap:
    --   1. never adopt the horse the LOCAL player is riding -- ForceMounting
    --      a second rider onto an occupied horse was never tested and is the
    --      strongest suspect for crash #1 (PA was galloping when PB's mount
    --      flip arrived);
    --   2. adoption can be turned off entirely (mp_horse_adopt off) so field
    --      testers can separate "adoption crashes" from everything else.
    if wantName and wantName ~= "" and KCD2MP.horseAdoptEnabled == false then
        mp_log("HorseAdopt: disabled (mp_horse_adopt off); proxy for id=" .. id)
        wantName = nil
    end
    if wantName and wantName ~= "" and KCD2MP._mountedHorseName == wantName then
        mp_log("HorseAdopt: '" .. wantName .. "' is the LOCAL player's own mount -- proxy instead (crash guard) id=" .. id)
        wantName = nil
    end
    if wantName and wantName ~= "" then
        local world = nil
        pcall(function() world = System.GetEntityByName(wantName) end)
        if world and tostring(world.class or "") == "Horse" then
            KCD2MP.horseGhosts[id] = {
                entity = world,
                entityId = world.id,
                isWorldHorse = true,
                worldName = wantName,
            }
            mp_log("HorseAdopt OK id=" .. id .. " world horse '" .. wantName .. "'")
            Script.SetTimer(400, function()
                KCD2MP_MountNPCOnHorse(id)
            end)
            return world
        end
        mp_log("HorseAdopt: '" .. tostring(wantName) .. "' not loaded here; falling back to proxy id=" .. id)
    end

    local pos = {x=x, y=y, z=z}
    local horseName = "kcd2mp_horse_" .. id

    -- Use System.SpawnEntity only (XGenAIModule is async → creates orphan second entity)
    local horse = nil
    local ok2, h2 = pcall(System.SpawnEntity, {
        class = "Horse", position = {x=x, y=y, z=z},
        name = horseName, properties = { esFaction = "Civilians" },
    })
    if ok2 and h2 then horse = h2 end

    if not horse then
        mp_log("HorseSpawn FAILED id=" .. id)
        return nil
    end

    pcall(function() horse:SetWorldAngles({x=0, y=0, z=rotZ or 0}) end)
    pcall(function() horse:SetMountableByPlayer(false) end)
    -- Set faction directly. Do NOT use CryAction.RegisterWithAI - that gives the horse an
    -- AI object which fights against our SetWorldPos calls every tick.
    pcall(function() AI.ChangeParameter(horse.id, AIPARAM_FACTION, "Civilians") end)

    KCD2MP.horseGhosts[id] = {
        entity = horse,
        entityId = horse.id,
    }

    mp_log("HorseSpawn OK id=" .. id .. " entityId=" .. tostring(horse.id))

    Script.SetTimer(400, function()
        KCD2MP_MountNPCOnHorse(id)
    end)

    return horse
end

function KCD2MP_MountNPCOnHorse(id)
    local ghost     = KCD2MP.ghosts[id]
    local horseData = KCD2MP.horseGhosts[id]
    if not ghost or not ghost.entity or not horseData or not horseData.entity then
        mp_log("MountNPCOnHorse: missing entity id=" .. id)
        return
    end

    local horse = horseData.entity
    local human = ghost.entity.human
    mp_log(string.format("MountNPCOnHorse id=%s hasHuman=%s", id, tostring(human ~= nil)))

    if not human then
        local captId = id
        Script.SetTimer(1000, function() KCD2MP_MountNPCOnHorse(captId) end)
        return
    end

    -- WO-40 Phase 0 crash guard: a ghost younger than 3 s is still settling
    -- (soul attach, inbound appearance equips). Host crash #2 (2026-08-18
    -- 20:23:54) died exactly at fresh-spawn + 400 ms ForceMount. Defer.
    local age = os.clock() - (ghost.istate and ghost.istate.spawnedAtClock or 0)
    if ghost.istate and ghost.istate.spawnedAtClock and age < 3.0 then
        local captId = id
        mp_log(string.format("MountNPCOnHorse: ghost %s is %.1fs old -- deferring mount (crash guard)", id, age))
        Script.SetTimer(1500, function() KCD2MP_MountNPCOnHorse(captId) end)
        return
    end

    -- WO-40 Phase 0 crash guard: re-check occupancy at mount time too -- the
    -- local player may have mounted this horse during the timer delay.
    if horseData.isWorldHorse and horseData.worldName
       and KCD2MP._mountedHorseName == horseData.worldName then
        mp_log("MountNPCOnHorse: '" .. horseData.worldName .. "' now occupied by the LOCAL player -- swapping to proxy id=" .. id)
        KCD2MP.horseGhosts[id] = nil
        local wp = ghost.istate
        KCD2MP_SpawnHorse(id, wp and wp.tx or 0, wp and wp.ty or 0, wp and wp.tz or 0, wp and wp.tr or 0)
        return
    end

    local ok1 = pcall(function() human:ForceMount(horse.id) end)
    mp_log("ForceMount ok=" .. tostring(ok1) .. " id=" .. id)
    if not ok1 then return end

    -- Verify mount after short delay; if confirmed, try to suppress scheduler errors
    local captId = id
    Script.SetTimer(300, function()
        local g2 = KCD2MP.ghosts[captId]
        if not g2 then return end
        local mounted = false
        pcall(function() mounted = g2.entity.human and g2.entity.human:IsMounted() end)
        mp_log("IsMounted=" .. tostring(mounted) .. " id=" .. captId)
        if not mounted then return end

        g2.istate.nativeMounted = true
        mp_log("NATIVE MOUNT SUCCESS id=" .. captId)

        -- === OPTION C: suppress "No valid scheduler behavior while occupying stance" ===
        -- Try 1: send OnHorseMounted signal so scheduler updates its state
        local s1 = pcall(function() AI.Signal(SIGNALFILTER_SENDER, 1, "OnHorseMounted", g2.entity.id) end)
        -- Try 2: disable AI entirely so scheduler stops fighting the mount
        local s2 = pcall(function() g2.entity:EnableAI(false) end)
        -- Try 3: AI.AutoDisable keeps AI alive but prevents auto-sleep cycles
        local s3 = pcall(function() AI.AutoDisable(g2.entity.id, 0) end)
        -- Try 4: generic OnMount signal
        local s4 = pcall(function() AI.Signal(0, 1, "OnMount", g2.entity.id) end)
        mp_log(string.format("OptionC signals id=%s s1=%s s2=%s s3=%s s4=%s",
            captId, tostring(s1), tostring(s2), tostring(s3), tostring(s4)))
    end)
end

function KCD2MP_RemoveHorse(id)
    local horseData = KCD2MP.horseGhosts[id]
    if not horseData then return end
    if horseData.isWorldHorse then
        -- WO-38 Phase 5: an adopted world horse is REAL local content --
        -- never removed, just released. The engine restores its own
        -- behaviour once position writes stop (WO-32's release principle).
        KCD2MP.horseGhosts[id] = nil
        mp_log("ReleaseWorldHorse id=" .. id .. " '" .. tostring(horseData.worldName) .. "'")
        return
    end
    if horseData.entityId then
        pcall(function() System.RemoveEntity(horseData.entityId) end)
    end
    KCD2MP.horseGhosts[id] = nil
    mp_log("RemoveHorse id=" .. id)
end

-- ===== Ghost Update (called by server each packet) =====

function KCD2MP_UpdateGhost(id, x, y, z, rotZ, isRiding)
    local ghost = KCD2MP.ghosts[id]

    -- Spawn if doesn't exist yet, then fall through to process isRiding on same call.
    if not ghost or not ghost.entity then
        KCD2MP_SpawnGhost(id, x, y, z, rotZ)
        ghost = KCD2MP.ghosts[id]
        if not ghost or not ghost.entity then return end  -- spawn failed
    end

    local istate = ghost.istate
    if not istate then return end

    local r = rotZ or istate.tr

    -- Velocity from actual packet positions (for dead reckoning).
    -- Use real elapsed time between packets instead of fixed SERVER_INTERVAL
    -- (echo mode sends every ~10ms, not 50ms, so fixed interval gave 5x underestimate).
    local ddx = x - (istate.lastPacketX or x)
    local ddy = y - (istate.lastPacketY or y)
    local ddz = z - (istate.lastPacketZ or z)
    local now = os.clock()
    local dt = now - (istate.lastPacketTime or now)
    istate.lastPacketTime = now
    istate.lastPacketDt = dt
    -- WO-38 Phase 3: packets arrive in BURSTS, not on a clean cadence -- the
    -- agent batches ExecuteString and flushes per tick (WO-30 measured that
    -- channel at 60-130 ms warm), so several UpdateGhost calls often land
    -- microseconds apart. The old code set raw velocity to 0 for every
    -- burst packet (dt < 5 ms), halving the smoothed velocity each time and
    -- making the dead-reckoning estimate oscillate between 0 and real --
    -- one direct cause of the reported rubber-banding. A burst packet now
    -- leaves the velocity estimate alone instead of dragging it to zero.
    if dt > 0.005 and dt < 1.0 then
        istate.vx = lerpVal(istate.vx or 0, ddx / dt, 0.5)
        istate.vy = lerpVal(istate.vy or 0, ddy / dt, 0.5)
        -- Vertical rate, for jump detection (WO-38 Section A: a jumping
        -- player read as a stationary vertical teleport because animation
        -- selection only ever saw horizontal speed).
        istate.vz = lerpVal(istate.vz or 0, ddz / dt, 0.5)
    elseif dt >= 1.0 then
        istate.vx, istate.vy, istate.vz = 0, 0, 0
    end
    istate.lastPacketX = x
    istate.lastPacketY = y
    istate.lastPacketZ = z

    -- Log large target jumps; reset velocity on teleport/fast-travel
    -- Jump detection: XY only — Z changes from terrain must NOT reset velocity
    local jumpDist = math.sqrt(ddx*ddx + ddy*ddy)
    if jumpDist > 5.0 then
        istate.vx = 0
        istate.vy = 0
        mp_log(string.format("JUMP id=%s xyDist=%.2f vx/vy reset", id, jumpDist))
    elseif jumpDist > 2.0 then
        mp_log(string.format("JUMP id=%s xyDist=%.2f", id, jumpDist))
    end

    istate.tx = x
    istate.ty = y
    istate.tz = z
    istate.tr = r
    istate.ticksSincePacket = 0
    istate.packetCount = istate.packetCount + 1

    -- Horse riding sync
    local riding = (isRiding == true)
    local wasRiding = (istate.isRiding == true)
    istate.isRiding = riding

    if riding and not wasRiding then
        -- Player just mounted a horse: spawn horse ghost
        mp_log("Riding START id=" .. id)
        KCD2MP_SpawnHorse(id, x, y, z, r)
    elseif not riding and wasRiding then
        -- Player dismounted: remove horse ghost, restore walk animation
        mp_log("Riding STOP id=" .. id)
        -- Dismount if natively mounted
        if istate.nativeMounted then
            pcall(function() ghost.entity.human:ForceDismount() end)
            istate.nativeMounted = false
        end
        KCD2MP_RemoveHorse(id)
        istate.animTag = "idle"  -- force animation reset
    end

    if istate.packetCount % 40 == 1 then
        local spd = math.sqrt(raw_vx*raw_vx + raw_vy*raw_vy)
        mp_log(string.format("pkt#%d id=%s pos=%.1f,%.1f,%.1f spd=%.1f riding=%s",
            istate.packetCount, id, x, y, z, spd, tostring(riding)))
    end
end

-- ===== Exchange: read local player state + apply ghost from other player =====
-- Returns CSV "x,y,z,rotZ,stance"  (stance: "s"=stand, "c"=crouch/sneak)
-- gstance: other player's stance to apply to ghost
function KCD2MP_Exchange(ghost_id, gx, gy, gz, gr, gstance)
    -- Apply incoming ghost state
    if ghost_id and gx then
        KCD2MP_UpdateGhost(ghost_id, gx, gy, gz, gr, gstance)
    end
    -- Read and return local player state
    if not player then return "" end
    local pos = player:GetWorldPos()
    if not pos then return "" end
    local rot = 0
    pcall(function()
        local ang = player:GetWorldAngles()
        if ang then rot = ang.z or 0 end
    end)
    -- Stance: use OnAction-tracked flag (most reliable in KCD2)
    -- Fallback to engine API in case action hook missed something
    local stance = "s"
    if KCD2MP.playerSneaking then
        stance = "c"
    else
        pcall(function()
            local s = player:GetStance()
            if s == 2 or s == 3 then stance = "c" end
        end)
        if stance == "s" then
            pcall(function()
                if player.actor and player.actor.bSneaking then stance = "c" end
            end)
        end
    end
    return string.format("%.3f,%.3f,%.3f,%.4f,%s", pos.x, pos.y, pos.z, rot, stance)
end

-- Auto-start interp tick (safe to call multiple times)
function KCD2MP_StartInterp()
    -- Liveness, not the flag -- see the comment on tickAlive. A save load
    -- leaves interpRunning true over a dead timer chain, and the old
    -- flag-only guard here made that permanent: every remote ghost frozen for
    -- the rest of the session with no way to recover short of restarting the
    -- game.
    if not tickAlive(KCD2MP.interpRunning, KCD2MP._interpAliveAt) then
        KCD2MP.interpRunning = true
        KCD2MP._interpAliveAt = os.clock()
        System.LogAlways("[KCD2-MP] Interp tick started (20ms)")
        Script.SetTimer(20, KCD2MP_InterpTick)
    end
    -- Start label render loop if not already running (8ms < 16.7ms frame = no flicker)
    if not tickAlive(KCD2MP.labelRunning, KCD2MP._labelAliveAt) then
        KCD2MP.labelRunning = true
        KCD2MP._labelAliveAt = os.clock()
        System.LogAlways("[KCD2-MP] Label render loop started (8ms)")
        Script.SetTimer(8, KCD2MP_LabelTick)
    end
end

-- Update horse positions at 8ms to avoid 20ms stutter (physics fights SetWorldPos less).
--
-- Split out of KCD2MP_LabelTick for WO-13's external pump. InterpTick only
-- computes horseData.render*; this is what actually applies it, so a pump that
-- drove InterpTick alone would leave a mounted ghost's horse standing still
-- while the rider slid along on top of it.
function KCD2MP_ApplyHorseTransforms()
    for id, horseData in pairs(KCD2MP.horseGhosts) do
        if horseData.entity and horseData.renderX then
            pcall(function()
                horseData.entity:SetWorldPos({x=horseData.renderX, y=horseData.renderY, z=horseData.renderZ})
                horseData.entity:SetWorldAngles({x=0, y=0, z=horseData.renderR})
            end)
        end
    end
end

-- WO-13: driven by the agent over ExecuteString while a LOCAL menu has focus.
-- Script.SetTimer -- which schedules every tick in this file -- is frozen for
-- the whole duration of a local menu (WO-12 s0.3), so without this the other
-- players' ghosts stand still on your own screen while you are the one in the
-- inventory. ExecuteString-driven Lua keeps executing throughout (WO-12 s0.4),
-- which is the whole reason this works.
--
-- Deliberately does NOT pump KCD2MP_LabelTick's drawing half. DrawLabel and
-- DrawText are immediate-mode -- one frame per call -- so pumping them would
-- draw a nameplate on some frames and not others, i.e. strobe rather than
-- render. Measured pump rate live is 35-86 Hz against a 60 fps frame, which
-- is fast enough for motion to look continuous but is NOT frame-locked, so
-- the strobing is real. Labels therefore stay hidden for the duration of the
-- menu -- exactly what already happens today. This fix is about ghost bodies
-- moving, not about labels.
function KCD2MP_InterpPump()
    KCD2MP_InterpTick("ext")
    KCD2MP_ApplyHorseTransforms()
    -- WO-40 Phase 2: pump the NPC puppet tick too, at its own 50 ms cadence
    -- (the pump loop runs at 40-70 Hz; the puppet tick's lerp/speed math
    -- assumes 50 ms, and per-tick StartAnimation restarts get worse, not
    -- better, when run faster -- WO-39's stomping lesson).
    local nowP = os.clock()
    if KCD2MP.npcPuppetRunning and (nowP - (KCD2MP._npcPuppetPumpAt or 0)) >= 0.045 then
        KCD2MP._npcPuppetPumpAt = nowP
        KCD2MP_NpcPuppetTick("ext")
    end
end

-- WO-13 Phase 2. Called by the agent when a PauseDown (0x1D) says a peer
-- entered or left a menu. Ghost ids are strings on this side (they key
-- KCD2MP.ghosts), so the caller must pass the same form it uses everywhere
-- else; tostring here rather than trusting that.
function KCD2MP_SetGhostMenuState(id, inMenu)
    id = tostring(id)
    KCD2MP.ghostInMenu[id] = inMenu and true or nil
    mp_log("GHOST_MENU id=" .. id .. " inMenu=" .. tostring(inMenu and true or false))
end

-- ===== Shared player combat (WO-28) =====

-- Flow A receiver. Called by the agent from a PlayerStateDown (0x20): this is
-- the owner's own authoritative health, so it is stored and rendered, never
-- reconciled against whatever this world's local copy of that ghost thinks.
--
-- It deliberately does NOT write the ghost entity's own health. Lua health
-- writes are inert in this sandbox (docs/PROJECT-STATE.md s2), and the ghost's
-- local health is a separate, local fact -- worlds are not shared, and the
-- honest deliverable is that every peer can SEE the right number, not that two
-- simulations are made to agree. What players actually read is the nameplate,
-- which this drives.
--
-- It does, however, reset the Flow B sensor baseline and skip one sample. That
-- is guard 2 from the design doc: an externally-written health shows up as a
-- delta on the next sample and would otherwise be re-reported as a fresh hit,
-- echoing forever. Implemented here rather than at the write site so it holds
-- whether or not a health write ever lands.
function KCD2MP_SetGhostHealth(id, health, stamina, flags)
    id = tostring(id)
    KCD2MP.ghostHealth[id] = {
        h = tonumber(health) or -1,
        s = tonumber(stamina) or -1,
        flags = tonumber(flags) or 0,
        at = os.clock(),
    }
    KCD2MP.ghostHpSkip[id] = true
end

-- Flow C receiver. Called by the agent from a PlayerDeathDown (0x24).
-- Idempotent: a repeat for an already-dead player changes nothing, which is
-- the contract Protocol 0x24 states.
--
-- The ghost entity is deliberately left standing. That player is reloading
-- their own most recent save and will be back in the world within seconds to a
-- minute; removing and respawning the entity would cost a full spawn cycle
-- (and, before WO-27's dedupe fix, was exactly how duplicates appeared). The
-- nameplate says what happened instead, and the ordinary position stream moves
-- the ghost to wherever their save point put them once their game is back.
-- Death-pose candidates (WO-38 Phase 4). The WO-28 design leaves a dead
-- player's ghost standing (cheap recovery for a player back in seconds), and
-- the real two-player test read that as a bug: "his body stands there as if
-- alive... no animation of the body falling". The [dead - reloading] tag
-- rides the nameplate, which is distance-scaled -- a body-level cue is
-- needed too. Same probe-on-first-use pattern as the jump list: none of
-- these names is confirmed on this build; a wrong candidate can never play,
-- and none-found keeps today's standing body.
local DEATH_ANIMS = {
    "relaxed_death", "death", "3d_death", "dead_pose",
    "relaxed_lie_pose", "lie_pose", "lying_idle", "3d_lying_idle",
    "relaxed_knockdown", "knockdown", "ko_pose", "unconscious_pose",
}
KCD2MP._deathAnim = nil   -- nil=not probed, false=none found, string=found

function KCD2MP_SetGhostDead(id, dead)
    id = tostring(id)
    local was = KCD2MP.ghostDead[id] and true or false
    local now = dead and true or false
    KCD2MP.ghostDead[id] = now or nil
    if was ~= now then
        mp_log("GHOST_DEATH id=" .. id .. " dead=" .. tostring(now))
        -- WO-38 Phase 4: on the owner dying, put the standing body into a
        -- fall/lie pose once. mp_ghost_is_corpse freezes all locomotion
        -- driving while dead, so a one-shot here is not overwritten; on the
        -- owner coming back the ordinary animation path resumes by itself.
        if now then
            local ghost = KCD2MP.ghosts[id]
            if ghost and ghost.entity then
                if KCD2MP._deathAnim == nil then
                    local found = nil
                    for _, nm in ipairs(DEATH_ANIMS) do
                        local len = 0
                        pcall(function() len = ghost.entity:GetAnimationLength(0, nm) or 0 end)
                        if len > 0 then found = nm; break end
                    end
                    KCD2MP._deathAnim = found or false
                    mp_log("DeathAnim: " .. tostring(KCD2MP._deathAnim))
                end
                if KCD2MP._deathAnim then
                    pcall(function() ghost.entity:StartAnimation(0, KCD2MP._deathAnim, 0, 0.2, 1.0, false) end)
                end
            end
        end
    end
end

-- Rule 2 gate, set by the agent from a CombatRole (0x25) packet. When off, the
-- per-ghost health sampling in KCD2MP_InterpTick does not run at all -- the
-- cost is skipped as well as the send, and a client that was never told it
-- holds authority cannot generate a hit by accident.
function KCD2MP_SetHitSensor(on)
    local now = on and true or false
    if KCD2MP.hitSensorOn ~= now then
        mp_log("HIT_SENSOR " .. (now and "on (this client holds NPC damage authority)" or "off"))
    end
    KCD2MP.hitSensorOn = now
    if not now then
        KCD2MP.ghostHpSeen = {}
        KCD2MP.ghostHpSkip = {}
    end
end

-- Reports everything this WO added, in one place, so a live check needs one
-- command rather than a hand-written Lua chunk. Logs rather than returns: the
-- console swallows return values.
function KCD2MP_ReportVitals()
    local h, s, d, u = KCD2MP_ReadSelfVitals()
    System.LogAlways(string.format(
        "[KCD2-MP] VITALS self health=%.1f stamina=%.1f dead=%s unconscious=%s emitter=%s hitSensor=%s",
        h, s, tostring(d), tostring(u), EMIT_VERSION, tostring(KCD2MP.hitSensorOn)))
    for id, ghost in pairs(KCD2MP.ghosts) do
        local hs = KCD2MP.ghostHealth[id]
        local localHp = "?"
        if ghost and ghost.entity and ghost.entity.actor then
            pcall(function() localHp = string.format("%.1f", ghost.entity.actor:GetHealth()) end)
        end
        System.LogAlways(string.format(
            "[KCD2-MP] VITALS ghost %s name=%s owner_health=%s owner_stamina=%s dead=%s local_health=%s seen=%s",
            tostring(id), tostring(KCD2MP.ghostNames[id] or "?"),
            hs and string.format("%.1f", hs.h) or "none",
            hs and string.format("%.1f", hs.s) or "none",
            tostring(KCD2MP.ghostDead[id] and true or false), localHp,
            KCD2MP.ghostHpSeen[id] and string.format("%.1f", KCD2MP.ghostHpSeen[id]) or "none"))
    end
end

-- WO-34 issue D. Is this ghost a body rather than a stand-in right now?
--
-- Two independent ways it happens, and the reported one is the second:
--
--   1. The OWNER died and their client sent 0x23, so every peer got 0x24 and
--      set KCD2MP.ghostDead. The entity here is untouched and still standing
--      (KCD2MP_SetGhostDead deliberately leaves it), but it no longer stands
--      for anybody who is playing.
--   2. An NPC killed the ghost in THIS world. No packet is involved at all --
--      worlds are not shared (docs/WO-26-shared-combat-design.md s2), so the
--      owner may be alive and well and completely unaware. Nothing in the mod
--      had ever looked at the ghost entity's own death state, which is why
--      this case went unnoticed through WO-28.
--
-- The IsDead() read is per-ghost per-20ms-tick, which is the same cadence and
-- the same object sampleGhostHealth already calls GetHealth() on, so it adds
-- one native call to a path that was already making one. pcall'd and treated
-- as "not dead" on failure: guessing a ghost is dead would freeze a live
-- player in place, which is far worse than a corpse that slides for one more
-- reconcile cycle.
function mp_ghost_is_corpse(id, ghost)
    if KCD2MP.ghostDead[id] then return true end
    -- WO-38 Phase 6: the owner reporting themselves unconscious (0x1F/0x20
    -- flags bit 0) is also a body -- they are lying in their own world, so a
    -- position stream that keeps arriving is stale-by-definition and driving
    -- walk animation onto their slumped stand-in is the same walking-corpse
    -- shape WO-34 fixed for death.
    local gh = KCD2MP.ghostHealth[id]
    if gh and gh.flags and (math.floor(gh.flags) % 2) == 1 then return true end
    if not (ghost and ghost.entity and ghost.entity.actor) then return false end
    local dead = false
    pcall(function() dead = ghost.entity.actor:IsDead() and true or false end)
    if dead then return true end
    -- WO-38 Phase 6: an NPC knocked this ghost out in THIS world. KCD2's
    -- unconsciousness is a real state distinct from death (the original A1
    -- lesson), and an unconscious body must freeze for exactly the same
    -- reason a dead one does. Same read WO-28's self-vitals already proved
    -- (actor:IsUnconscious), same pcall discipline: on failure assume
    -- conscious, because wrongly freezing a live player is the worse error.
    local ko = false
    pcall(function() ko = ghost.entity.actor:IsUnconscious() and true or false end)
    return ko
end

-- Smallest health drop worth reporting as a hit. Below this it is sampling
-- noise or regeneration rounding, not a blow.
local HIT_MIN_DELTA = 0.05

-- Flow B sensor, called once per ghost per interp tick.
--
-- Guards, in the order docs/WO-26-shared-combat-design.md s4 lists them by how
-- easily they are got wrong:
--   1. host-only -- KCD2MP.hitSensorOn, checked by the caller and again here.
--   2. a delta caused by an inbound authoritative write is not a hit --
--      KCD2MP_SetGhostHealth sets ghostHpSkip, consumed below.
--   3. only NEGATIVE deltas are hits. Regeneration is not a hit.
local function sampleGhostHealth(id, ghost)
    if not KCD2MP.hitSensorOn then return end
    if not (ghost and ghost.entity and ghost.entity.actor) then return end

    local hp = nil
    pcall(function() hp = ghost.entity.actor:GetHealth() end)
    if type(hp) ~= "number" then return end

    local prev = KCD2MP.ghostHpSeen[id]
    KCD2MP.ghostHpSeen[id] = hp

    -- Guard 2: one sample is swallowed after an external write, then the
    -- baseline is simply whatever we just read. Note this consumes the flag
    -- even on the first-ever sample, which is correct -- there is no prior
    -- value to have lost.
    if KCD2MP.ghostHpSkip[id] then
        KCD2MP.ghostHpSkip[id] = nil
        return
    end
    if prev == nil then return end   -- first sample only primes the baseline

    local delta = prev - hp          -- positive = lost health
    if delta < HIT_MIN_DELTA then return end   -- guard 3: covers 0 and negatives

    -- Reported as a loss amount, matching CombatSoul::TakeDamage's own argument
    -- semantics on the other end. Stamina is not sampled: there is no confirmed
    -- Lua stamina binding (see probeStaminaReader), and inventing one here would
    -- make a receiver drain a real player's stamina on a guess.
    KCD2MP_EmitEvent("ghost_hit", string.format("%s %.2f", tostring(id), delta))
end

function KCD2MP_LabelTick()
    if not KCD2MP.labelRunning then return end
    Script.SetTimer(8, KCD2MP_LabelTick)
    KCD2MP._labelAliveAt = os.clock()
    KCD2MP_ApplyHorseTransforms()
    for id, lbl in pairs(KCD2MP.labelCache) do
        if lbl.size > 0 then
            pcall(function()
                System.DrawLabel({x=lbl.x, y=lbl.y, z=lbl.z}, lbl.size, lbl.name, 1, 1, 0, 1)
            end)
        end
    end
    -- Draw ping in top-left corner using 2D screen-space DrawText(x, y, text, size).
    if KCD2MP.pingText then
        pcall(function()
            System.DrawText(10, 10, KCD2MP.pingText, 2)
        end)
    end

    -- Interaction prompt (WO-2) shares this loop rather than adding a timer.
    pcall(KCD2MP_DrawInteractionUI)

    -- NOTE: the dice board deliberately does NOT ride this loop. This loop only
    -- starts when the agent connects and calls KCD2MP_StartInterp, so hanging
    -- the board off it meant the board silently never rendered with no agent
    -- running -- verified: labelRunning=false while diceOpen=true. The board is
    -- pushed into the game's own UI on state change instead, so it needs no
    -- per-frame loop at all.
end

-- ===== Animation Update =====

-- Sneak animation candidates (probed on first use, result cached).
local SNEAK_WALK_ANIMS = {
    "3d_sneak_walk_turn_strafe",
    "3d_sneaking_walk_turn_strafe",
    "3d_stealth_walk_turn_strafe",
    "3d_crouch_walk_turn_strafe",
}
local SNEAK_IDLE_ANIMS = {
    "sneak_idle_both",
    "sneaking_idle_both",
    "stealth_idle_both",
    "crouch_idle_both",
}
KCD2MP._sneakWalkAnim = nil
KCD2MP._sneakIdleAnim = nil

-- Jump animation candidates (WO-38 Phase 3, Section A). Same probe-on-first-
-- use pattern as every other list here: findAnim keeps the first name the
-- entity actually has (GetAnimationLength > 0), so unverified candidates
-- cost one probe each, once, and a wrong guess can never play. If none probe
-- out, the ghost keeps its locomotion animation while airborne (legs keep
-- moving), which is still strictly better than the reported stiff teleport.
--
-- WO-40 Phase 8: the list is now led by REAL clip names read from
-- Animations.pak's male.animevents this session (plain one-shot .caf files,
-- the class that renders via StartAnimation -- not the 1d_jump_* blendspaces,
-- which never render). The old WO-38 guesses stay as a tail.
local JUMP_ANIMS = {
    "relaxed_jump_idle",                 -- full in-place jump (Animations.pak, WO-40)
    "relaxed_run_jump_rleg_start",       -- moving jump, start half
    "relaxed_jump_start",                -- start half (pairs with land)
    "relaxed_walk_jump_lleg_start",
    "3d_relaxed_jump", "3d_jump", "relaxed_jump", "jump",
    "3d_relaxed_jump_turn_strafe", "jump_both", "relaxed_jump_both",
    "3d_relaxed_run_jump", "run_jump", "walk_jump",
}
KCD2MP._jumpAnim = nil   -- nil=not probed yet, false=probed and none found, string=found

-- WO-40 Phase 8: fence-vault candidates -- the same real-clip sweep. The
-- game's own JumpOver Mannequin fragment plays exactly
-- relaxed_jump_over_obstacle_idle_high (read from kcd_male_database.adb).
-- Same probe pattern; used by the airborne branch when the arc looks like a
-- vault (low vertical speed but a z step up), live-tuning deferred -- for
-- now the list rides behind mp_combat_frag-style manual probing and the
-- jump branch's fallback ordering.
local VAULT_ANIMS = {
    "relaxed_jump_over_obstacle_idle_low",
    "relaxed_jump_over_obstacle_idle_high",
    "relaxed_jump_over_obstacle_lleg_walk_low",
    "relaxed_jump_over_obstacle_lleg_run_low",
}
KCD2MP._vaultAnim = nil

-- Riding animation candidates (probed on first use, result cached).
-- false = probed but none found (avoid re-probing every tick).
local RIDING_IDLE_ANIMS = {
    -- Confirmed working on KCD2 NPC class:
    "horse_idle",
    -- Simple names
    "riding_idle", "riding_idle_both", "horse_riding_idle",
    "mounted_idle", "horseback_idle", "cavalry_idle",
    -- 3d_ prefix (confirmed KCD2 convention)
    "3d_riding_idle", "3d_riding_idle_both",
    "3d_horse_idle", "3d_horse_idle_both",
    "3d_horseback_idle", "3d_mounted_idle",
    "3d_relaxed_horse_idle", "3d_relaxed_horse_idle_both",
    "3d_relaxed_riding_idle", "3d_relaxed_riding_idle_both",
    -- relaxed_ prefix (confirmed KCD2 convention)
    "relaxed_riding_idle", "relaxed_riding_idle_both",
    "relaxed_horse_idle", "relaxed_horse_idle_both",
    -- wagon / sit (seated pose that might work)
    "wagon_idle", "wagon_idle_both", "wagon_ride_idle",
    "sit_idle", "sit_idle_both", "3d_sit_idle",
    "seated_idle", "seated_idle_both",
    -- combat horse
    "combat_horse_idle", "combat_horse_idle_both",
    "3d_combat_horse_idle", "3d_combat_horse_idle_both",
    -- act / mm prefix
    "act_horse_idle", "mm_horse_idle",
    -- npc specific
    "npc_horse_idle", "npc_riding_idle",
}
local RIDING_GALLOP_ANIMS = {
    -- Based on confirmed idle pattern: 1d_idle_slope_relaxed_idle_rider_01
    "1d_gallop_slope_relaxed_gallop_rider_01",
    "1d_canter_slope_relaxed_canter_rider_01",
    "1d_trot_slope_relaxed_trot_rider_01",
    "1d_walk_slope_relaxed_walk_rider_01",
    -- Other candidates
    "horse_gallop", "horse_run", "horse_trot", "horse_canter",
    "riding_gallop", "riding_gallop_both",
    "3d_riding_gallop", "3d_horse_gallop",
    "relaxed_horse_run", "combat_horse_run", "mounted_gallop",
}
KCD2MP._ridingIdleAnim  = nil   -- nil=not probed yet, false=not found, string=found
KCD2MP._ridingGallopAnim = nil

-- Horse entity animation candidates (Horse class entity, not NPC riding).
local HORSE_ENTITY_IDLE_ANIMS = {
    -- Confirmed present on KCD2 horse entities (from mp_scan_horse on real game horse):
    "relaxed_idle",
    -- Other candidates:
    "idle", "stand", "horse_idle", "animal_idle",
    "idle_loop", "horse_idle_loop", "stand_loop",
    "loco_idle", "act_idle", "mm_idle",
    "walk_idle", "stand_idle",
    "horse_stand", "horse_stand_idle", "horse_rest",
}
-- Separate walk vs gallop so we don't accidentally use relaxed_walk for full gallop.
local HORSE_ENTITY_WALK_ANIMS = {
    "relaxed_walk", "relaxed_trot",
    "horse_walk", "horse_trot", "walk", "trot",
}
local HORSE_ENTITY_GALLOP_ANIMS = {
    -- Fastest gaits first — confirmed on KCD2 horse entities:
    "relaxed_gallop", "relaxed_canter", "relaxed_run",
    -- Other candidates:
    "gallop", "canter", "run",
    "horse_gallop", "horse_canter", "horse_run",
    "horse_loco_gallop", "horse_loco_run",
    "animal_gallop", "animal_run",
    "loco_gallop", "loco_run",
}
KCD2MP._horseEntityIdleAnim   = nil  -- nil=not probed, false=not found, string=found
KCD2MP._horseEntityWalkAnim   = nil
KCD2MP._horseEntityGallopAnim = nil

local function findAnim(entity, candidates)
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = entity:GetAnimationLength(0, name) or 0 end)
        if len > 0 then return name end
    end
    return nil
end

-- ===== Combat visibility, inbound half (WO-39 Phase 1) =====
--
-- Swing/block one-shot candidates, LIVE-TUNED 2026-08-18 against the real
-- Mannequin databases (kcd_male_combat_database.adb + _generated.adb,
-- extracted from Animations.pak) and eyeball-verified on a live ghost.
-- What that session established, so nobody re-walks it:
--   - REAL full swings are 1d- blendspaces (parametric by attack angle).
--     StartAnimation "starts" them (returns true) but they never render,
--     and the plain "natk_slash_*_upper" clips are upper-guard partials
--     that read as blocking. Swings are Mannequin-locked on this build.
--   - Human.PlayAnim(fragment, tags) executes fault-free and renders
--     NOTHING for FreeAttack/CombatAttack/CombatHit/FreeBlock on a ghost.
--   - What DOES render correctly via StartAnimation: guard idles, the
--     dz "blk" block reactions, hit "flinch" reactions, and guard
--     TRANSITIONS. Naming decode: lg/rg = left/right guard (rg raises the
--     sword arm and reads correctly; lg raises the EMPTY left arm and
--     reads like phantom-shield blocking), sz = distance zone, az/dz =
--     attack/defense zone.
-- The swing cue therefore is a fast right-to-left guard transition -- a
-- big lateral sword move, human-confirmed "usable" as an attack read at a
-- few metres -- played at SWING_ANIM_SPEED. Not a true swing; the honest
-- reachable ceiling this build gives us.
local COMBAT_SWING_ANIMS = {
    "combat_rg_sz1_idle_to_lg_sz0_idle_lngsw",   -- CONFIRMED live 2026-08-18
    "combat_rg_sz1_idle_to_rg_sz5_idle_lngsw",   -- confirmed exists; second choice
}
local SWING_ANIM_SPEED = 1.6   -- the transition reads as a strike at this rate
local COMBAT_BLOCK_ANIMS = {
    "combat_rg_sz1_dz0_blk_slash_lngsw",         -- CONFIRMED live 2026-08-18
    "combat_free_blk_lngsw_player_over",         -- exists; long hold, worse read
}
-- Weapon-ready idle for a ghost whose owner has their weapon drawn, so the
-- drawn state reads at a glance even between swings. Right guard: the
-- sword arm is the raised one.
local COMBAT_IDLE_ANIMS = {
    "combat_rg_sz1_idle_lngsw_player",           -- CONFIRMED live 2026-08-18
    "combat_lg_sz0_idle_lngsw_player",           -- exists; reads shield-y (left guard)
}
KCD2MP._swingAnim = nil        -- nil=not probed, false=none found, string=found
KCD2MP._blockAnim = nil
KCD2MP._combatIdleAnim = nil

-- Mannequin escape hatch: Human.PlayAnim(fragmentName, tags) is documented
-- and may reach the real combat fragments that raw StartAnimation cannot.
-- Fragment names cannot be probed by GetAnimationLength, so this route stays
-- OFF until a live session finds a working name and sets it here (or via
-- mp_combat_frag). When set, it is tried before the CAF one-shot.
KCD2MP.combatSwingFragment = nil   -- e.g. "MeleeAttack"
KCD2MP.combatSwingFragTags = ""

-- WO-43: every prior live attempt on this route (WO-39 empty tags, WO-40
-- generic tags like "lngsw") used GUESSED fragment/tag data, never a real
-- shipped Mannequin row. docs/WO-42-findings.md §9.2 extracted real rows
-- straight from Tables.pak; this is one, verbatim, for a human/human sync
-- attack (not invented -- do not substitute a guessed tag string here):
--   mp_combat_frag CombatAttackSyncGen l_halberd+r_halberd+clinch1+eZ1+aZ2+attack_special+oppMale
-- Untried before WO-43. If this still renders nothing on a real ghost in a
-- real fight, that is evidence against "the tags were just wrong" and for
-- the guard/gate explanation combat_playanim.cpp's native probe checks.

-- WO-40 Phase 6: paired takedown cue on a puppet KO transition. Called from
-- KCD2MP_ApplyNpcState (defined earlier; Lua resolves this global at call
-- time, after the whole file has loaded). Clip names come from the
-- Animations.pak sweep (plain .caf clips, the class that renders via
-- StartAnimation) -- probed with findAnim, none-found degrades to the
-- existing KO freeze.
local TAKEDOWN_MASTER_ANIMS = {
    "stealth_kill_hand_stand_success_start_m",   -- choke-out, perpetrator half
    "combat_takedown_back_nw_nw_m",              -- unarmed takedown, perpetrator
}
local TAKEDOWN_VICTIM_ANIMS = {
    "stealth_kill_hand_stand_success_start_s",   -- choke-out, victim half
    "combat_takedown_back_nw_nw_s",              -- unarmed takedown, victim
}
KCD2MP._takedownMasterAnim = nil   -- nil=not probed, false=none, string=found
KCD2MP._takedownVictimAnim = nil

function KCD2MP_NpcTakedownCue(name, e, x, y, z)
    local p = KCD2MP.npcPuppets[name]
    -- Victim half on the NPC itself.
    if KCD2MP._takedownVictimAnim == nil then
        KCD2MP._takedownVictimAnim = findAnim(e, TAKEDOWN_VICTIM_ANIMS) or false
        mp_log("TakedownVictimAnim: " .. tostring(KCD2MP._takedownVictimAnim))
    end
    if KCD2MP._takedownVictimAnim then
        local len = 0
        pcall(function() len = e:GetAnimationLength(0, KCD2MP._takedownVictimAnim) or 0 end)
        pcall(function() e:StartAnimation(0, KCD2MP._takedownVictimAnim, 0, 0.1, 1.0, false) end)
        if p then p.oneShotUntil = os.clock() + math.min(len > 0 and len or 1.2, 2.5) end
    end
    -- Master half on the nearest ghost within arm's reach.
    local best, bestD2 = nil, 6.25
    for _, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            local gp = nil
            pcall(function() gp = g.entity:GetWorldPos() end)
            if gp then
                local gdx, gdy = gp.x - x, gp.y - y
                local d2 = gdx * gdx + gdy * gdy
                if d2 < bestD2 then best, bestD2 = g, d2 end
            end
        end
    end
    if best then
        if KCD2MP._takedownMasterAnim == nil then
            KCD2MP._takedownMasterAnim = findAnim(best.entity, TAKEDOWN_MASTER_ANIMS) or false
            mp_log("TakedownMasterAnim: " .. tostring(KCD2MP._takedownMasterAnim))
        end
        if KCD2MP._takedownMasterAnim then
            local len = 0
            pcall(function() len = best.entity:GetAnimationLength(0, KCD2MP._takedownMasterAnim) or 0 end)
            pcall(function() best.entity:StartAnimation(0, KCD2MP._takedownMasterAnim, 0, 0.1, 1.0, false) end)
            if best.istate then
                best.istate.oneShotUntil = os.clock() + math.min(len > 0 and len or 1.2, 2.5)
            end
        end
    end
    mp_log(string.format("NPC-SYNC takedown cue %s (victim=%s master=%s ghost=%s)",
        name, tostring(KCD2MP._takedownVictimAnim), tostring(KCD2MP._takedownMasterAnim),
        best and "yes" or "none-near"))
end

-- WO-40 Phase 6: the puppet-side swing cue -- same clip, speed and one-shot
-- window as the ghost swing cue, applied to an NPC puppet.
function KCD2MP_PuppetSwingCue(name, p, e)
    if KCD2MP._swingAnim == nil then
        KCD2MP._swingAnim = findAnim(e, COMBAT_SWING_ANIMS) or false
        mp_log("SwingAnim: " .. tostring(KCD2MP._swingAnim))
    end
    if not KCD2MP._swingAnim then return end
    local len = 0
    pcall(function() len = e:GetAnimationLength(0, KCD2MP._swingAnim) or 0 end)
    pcall(function() e:StartAnimation(0, KCD2MP._swingAnim, 0, 0.08, SWING_ANIM_SPEED, false) end)
    local dur = (len > 0 and len or 0.8) / SWING_ANIM_SPEED
    p.oneShotUntil = os.clock() + math.min(dur, 1.5)
    p.animTag = "swing"   -- locomotion re-asserts itself after the window
    mp_log("NPC-SYNC swing cue " .. name)
end

-- WO-40 Phase 6: probe-once accessor for the weapon-ready guard idle, shared
-- with the ghost path's cache.
function KCD2MP_CombatIdleFor(e)
    if KCD2MP._combatIdleAnim == nil then
        KCD2MP._combatIdleAnim = findAnim(e, COMBAT_IDLE_ANIMS) or false
        mp_log("CombatIdleAnim: " .. tostring(KCD2MP._combatIdleAnim))
    end
    return KCD2MP._combatIdleAnim or nil
end

-- Applies one peer combat event to that peer's ghost. evt matches Protocol's
-- combat event bytes: 0=drawn, 1=sheathed, 2=swing, 3=block. Unknown values
-- are ignored, so a newer peer can emit events this build has no name for.
-- Everything here is cosmetic; no health is touched on any path.
function KCD2MP_GhostCombat(id, evt)
    id = tostring(id)
    evt = tonumber(evt)
    if evt == nil then return end
    local ghost = KCD2MP.ghosts[id]
    if not (ghost and ghost.entity) then return end

    if evt == 0 or evt == 1 then
        local wantDrawn = (evt == 0)
        local isDrawn = KCD2MP.ghostWeaponDrawn[id] and true or false
        if isDrawn == wantDrawn then return end   -- heartbeat re-emits land here
        KCD2MP.ghostWeaponDrawn[id] = wantDrawn or nil
        if ghost.entity.human then
            if wantDrawn then
                -- Confirmed live (WO-16/17): draws the ghost's real equipped
                -- weapon item, when the appearance layer has given it one.
                pcall(function() ghost.entity.human:DrawWeapon() end)
            else
                pcall(function() ghost.entity.human:HolsterWeapon() end)
            end
        end
        mp_log("CombatViz: ghost " .. id .. (wantDrawn and " drew weapon" or " sheathed weapon"))
        return
    end

    if evt == 2 or evt == 3 then
        -- Mannequin route first, when a live session has configured it.
        if evt == 2 and KCD2MP.combatSwingFragment and ghost.entity.human then
            local ok = pcall(function()
                ghost.entity.human:PlayAnim(KCD2MP.combatSwingFragment, KCD2MP.combatSwingFragTags or "")
            end)
            if ok then
                if ghost.istate then ghost.istate.oneShotUntil = os.clock() + 1.0 end
                return
            end
        end

        local anim
        if evt == 2 then
            if KCD2MP._swingAnim == nil then
                KCD2MP._swingAnim = findAnim(ghost.entity, COMBAT_SWING_ANIMS) or false
                mp_log("SwingAnim: " .. tostring(KCD2MP._swingAnim))
            end
            anim = KCD2MP._swingAnim
        else
            if KCD2MP._blockAnim == nil then
                KCD2MP._blockAnim = findAnim(ghost.entity, COMBAT_BLOCK_ANIMS) or false
                mp_log("BlockAnim: " .. tostring(KCD2MP._blockAnim))
            end
            anim = KCD2MP._blockAnim
        end
        if not anim then return end

        -- Swings play fast (the guard transition reads as a strike at 1.6x,
        -- confirmed live); blocks at natural speed. The one-shot window is
        -- the played duration, so the speed divides the length.
        local speed = (evt == 2) and SWING_ANIM_SPEED or 1.0
        local len = 0
        pcall(function() len = ghost.entity:GetAnimationLength(0, anim) or 0 end)
        pcall(function() ghost.entity:StartAnimation(0, anim, 0, 0.08, speed, false) end)
        -- Hold the one-shot: KCD2MP_UpdateAnimation restarts locomotion every
        -- tick and would stomp this on the very next one (confirmed live:
        -- one-shots were invisible until the loop was suppressed). Capped so
        -- a bad length can never freeze the ghost for long. istate always
        -- exists on a spawned ghost; a half-spawned one has no loop to fight.
        if ghost.istate then
            local dur = (len > 0 and len or 0.8) / speed
            ghost.istate.oneShotUntil = os.clock() + math.min(dur, 1.5)
        end
    end
end

-- Local eyeball test: play a combat event on every ghost in this world with
-- no wire involved (mp_ghost_combat <0|1|2|3>). The apply path is identical
-- to a real inbound packet.
-- WO-46: the Lua half of a NATIVE swing. The agent queues the real Mannequin
-- combat action through the DLL (a full swing, WO-45); this only holds the
-- one-shot window so KCD2MP_UpdateAnimation's per-tick locomotion restart
-- does not fight the playing action on a moving ghost. No clip is started
-- here -- the native action owns the render.
function KCD2MP_GhostNativeSwingHold(id)
    local ghost = KCD2MP.ghosts[tostring(id)]
    if ghost and ghost.istate then
        ghost.istate.oneShotUntil = os.clock() + 0.9
    end
end

-- WO-47: draw a SPECIFIC inventory item into the ghost's hands, for weapon
-- classes DrawWeapon() ignores (equip_slot="Oversized": halberds/polearms).
-- Live-verified this session: EquipItem reports a polearm equipped but never
-- attaches the model, DrawWeapon() draws the sidearm instead, and
-- human:DrawFromInventory(item, 0, true) is the one call that puts the
-- polearm in hand. ORDER MATTERS (live-observed): DrawFromInventory AFTER a
-- DrawWeapon()-style draw suppressed native swing rendering entirely;
-- called INSTEAD of it, swings render. The agent routes a draw event here
-- (rather than KCD2MP_GhostCombat) when its weapon catalog says the ghost's
-- synced main-hand weapon is Oversized.
function KCD2MP_GhostDrawItem(id, classGuid)
    id = tostring(id)
    local ghost = KCD2MP.ghosts[id]
    if not (ghost and ghost.entity and ghost.entity.human and ghost.entity.inventory) then return end
    if KCD2MP.ghostWeaponDrawn[id] then return end   -- heartbeat re-emits land here
    local drew = false
    pcall(function()
        local it = ghost.entity.inventory:FindItem(tostring(classGuid))
        if it then
            ghost.entity.human:DrawFromInventory(it, 0, true)
            drew = true
        end
    end)
    if drew then
        KCD2MP.ghostWeaponDrawn[id] = true
        mp_log("CombatViz: ghost " .. id .. " drew oversized item from inventory")
    else
        -- Item not in the ghost's inventory (appearance apply still in
        -- flight): fall back to the plain draw so the state flag and any
        -- sidearm still behave as before.
        KCD2MP_GhostCombat(id, 0)
    end
end

function KCD2MP_GhostCombatAll(arg)
    local evt = tonumber(arg)
    if evt == nil then
        System.LogAlways("[KCD2-MP] usage: mp_ghost_combat 0=draw 1=sheathe 2=swing 3=block")
        return
    end
    local n = 0
    for id in pairs(KCD2MP.ghosts) do
        KCD2MP_GhostCombat(id, evt)
        n = n + 1
    end
    System.LogAlways("[KCD2-MP] GhostCombatAll evt=" .. evt .. " applied to " .. n .. " ghost(s)")
end

-- One-command probe for the live session: registration checks on the Human
-- binds this layer calls, plus every combat anim candidate that exists on a
-- ghost (all hits, not just the first -- the lists get tuned from this).
function KCD2MP_CombatProbe()
    System.LogAlways("[KCD2-MP] === COMBAT VIZ PROBE ===")
    if player and player.human then
        System.LogAlways("[KCD2-MP] player.human.IsWeaponDrawn=" .. tostring(type(player.human.IsWeaponDrawn)))
        System.LogAlways("[KCD2-MP] player.human.DrawWeapon="    .. tostring(type(player.human.DrawWeapon)))
        System.LogAlways("[KCD2-MP] player.human.HolsterWeapon=" .. tostring(type(player.human.HolsterWeapon)))
        System.LogAlways("[KCD2-MP] player.human.PlayAnim="      .. tostring(type(player.human.PlayAnim)))
        local d = "?"
        pcall(function() d = tostring(player.human:IsWeaponDrawn()) end)
        System.LogAlways("[KCD2-MP] IsWeaponDrawn() now=" .. d)
    else
        System.LogAlways("[KCD2-MP] player.human is nil")
    end
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do if g.entity then ghost = g; break end end
    if not ghost then
        System.LogAlways("[KCD2-MP] no ghost to probe anims on (spawn one first)")
        return
    end
    local lists = { SWING = COMBAT_SWING_ANIMS, BLOCK = COMBAT_BLOCK_ANIMS, CIDLE = COMBAT_IDLE_ANIMS,
                    JUMP = JUMP_ANIMS, VAULT = VAULT_ANIMS,
                    TDWN_M = TAKEDOWN_MASTER_ANIMS, TDWN_S = TAKEDOWN_VICTIM_ANIMS }
    for label, list in pairs(lists) do
        local hits = {}
        for _, nm in ipairs(list) do
            local len = 0
            pcall(function() len = ghost.entity:GetAnimationLength(0, nm) or 0 end)
            if len > 0 then hits[#hits + 1] = string.format("%s=%.2f", nm, len) end
        end
        System.LogAlways("[KCD2-MP] " .. label .. ": " .. (#hits > 0 and table.concat(hits, ", ") or "none"))
    end
    System.LogAlways("[KCD2-MP] ghost.human=" .. tostring(ghost.entity.human ~= nil)
        .. " HolsterWeapon=" .. tostring(ghost.entity.human and type(ghost.entity.human.HolsterWeapon) or "n/a")
        .. " PlayAnim=" .. tostring(ghost.entity.human and type(ghost.entity.human.PlayAnim) or "n/a"))
    System.LogAlways("[KCD2-MP] === END ===")
end

-- mp_entity_id [name] (WO-43): print the raw CryEngine entity id for a named
-- entity, or every current ghost's id if no name is given. This is the value
-- kcdmp-playanim.txt's first line needs for the arbitrary-actor case of the
-- native PlayAnim diagnostic in combat_playanim.cpp -- that file cannot look
-- an entity up by name itself, only by this numeric id.
function KCD2MP_ReportEntityId(name)
    name = tostring(name or "")
    if name ~= "" then
        local e = System.GetEntityByName(name)
        System.LogAlways("[KCD2-MP] " .. name .. " id=" .. tostring(e and e.id or "not found"))
        return
    end
    local n = 0
    for id, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            System.LogAlways("[KCD2-MP] ghost " .. tostring(id) .. " (" ..
                tostring(g.spawnName or ("kcd2mp_" .. tostring(id))) .. ") id=" .. tostring(g.entity.id))
            n = n + 1
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no spawned ghosts to report") end
end

-- Hysteresis thresholds (m/s).
-- Different enter/exit speeds prevent oscillation when speed hovers at a boundary.
-- Enter: must EXCEED this speed to switch INTO this state.
-- Exit:  must DROP BELOW this speed to switch OUT of this state (go lower).
local ANIM_UP   = { walk=1.0, run=2.5, sprint=4.0 }
local ANIM_DOWN = { walk=0.4, run=1.8, sprint=3.2 }

local function calcAnimTag(speed, cur, stance)
    if stance == "c" then
        return speed > 0.3 and "sneak_walk" or "sneak_idle"
    end
    -- Start from current tag and check if we cross hysteresis bands.
    local t = cur or "idle"
    if t == "sprint" then
        if speed < ANIM_DOWN.sprint then t = "run"   else return "sprint" end
    end
    if t == "run" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed <  ANIM_DOWN.run   then t = "walk"  else return "run" end
    end
    if t == "walk" then
        if     speed >= ANIM_UP.sprint  then return "sprint"
        elseif speed >= ANIM_UP.run     then return "run"
        elseif speed <  ANIM_DOWN.walk  then return "idle" else return "walk" end
    end
    -- idle / sneak states
    if     speed >= ANIM_UP.sprint then return "sprint"
    elseif speed >= ANIM_UP.run    then return "run"
    elseif speed >= ANIM_UP.walk   then return "walk"
    else                                 return "idle" end
end

function KCD2MP_UpdateAnimation(id, ghost)
    local istate = ghost.istate

    -- WO-39: a one-shot combat animation (swing/block) is mid-play. This
    -- function restarts locomotion every tick, which would stomp it on the
    -- next tick -- so hold off until the one-shot's window expires. Checked
    -- before everything else, jump included: a swing beats an air-frame.
    if istate.oneShotUntil then
        if os.clock() < istate.oneShotUntil then return end
        istate.oneShotUntil = nil
    end

    local speed = istate.smoothedSpeed or 0
    local stance = istate.stance or "s"

    -- Sanity: can't be sneaking at running speeds (auto-clears bad toggle state)
    if stance == "c" and speed > 4.0 then stance = "s" end
    local wantTag = calcAnimTag(speed, istate.animTag, stance)

    -- WO-38 Phase 3 (Section A): a jump used to render as a stationary
    -- vertical teleport, because this function only ever saw horizontal
    -- speed. While the interp tick reports the ghost airborne, play a jump
    -- animation if this build has one; if the probe finds none, fall through
    -- to the ordinary locomotion tag rather than freezing.
    if istate.isAirborne and stance ~= "c" then
        -- WO-40 live battery: the MotionJump Mannequin fragment RENDERS via
        -- Human.PlayAnim on a ghost (eyeball-confirmed 2026-08-20 -- the
        -- first fragment ever seen rendering; combat fragments stay locked).
        -- It is the game's own jump, with proc layers a raw clip lacks, so
        -- it goes first: once per airborne episode, not per tick.
        if not istate.jumpFragPlayed and ghost.entity.human then
            istate.jumpFragPlayed = true
            local okJ = pcall(function() ghost.entity.human:PlayAnim("MotionJump", "") end)
            if okJ then
                istate.oneShotUntil = os.clock() + 0.9
                if istate.animTag ~= "jump" then
                    mp_log(string.format("Anim: %s %s->jump (MotionJump fragment)", id, istate.animTag or "?"))
                    istate.animTag = "jump"
                end
                return
            end
        end
        if istate.animTag == "jump" then return end  -- fragment already playing
        if KCD2MP._jumpAnim == nil then
            KCD2MP._jumpAnim = findAnim(ghost.entity, JUMP_ANIMS) or false
            mp_log("JumpAnim: " .. tostring(KCD2MP._jumpAnim))
        end
        if KCD2MP._jumpAnim then
            pcall(function() ghost.entity:StartAnimation(0, KCD2MP._jumpAnim, 0, 0.1, 1.0, false) end)
            if istate.animTag ~= "jump" then
                mp_log(string.format("Anim: %s %s->jump vz-driven", id, istate.animTag or "?"))
                istate.animTag = "jump"
            end
            return
        end
    elseif istate.jumpFragPlayed then
        istate.jumpFragPlayed = nil   -- re-arm for the next airborne episode
    end

    local animName
    if wantTag == "sneak_walk" then
        if not KCD2MP._sneakWalkAnim then
            KCD2MP._sneakWalkAnim = findAnim(ghost.entity, SNEAK_WALK_ANIMS)
                                    or "3d_relaxed_walk_turn_strafe"
            mp_log("SneakWalkAnim: " .. KCD2MP._sneakWalkAnim)
        end
        animName = KCD2MP._sneakWalkAnim
    elseif wantTag == "sneak_idle" then
        if not KCD2MP._sneakIdleAnim then
            KCD2MP._sneakIdleAnim = findAnim(ghost.entity, SNEAK_IDLE_ANIMS)
                                    or "relaxed_idle_both"
            mp_log("SneakIdleAnim: " .. KCD2MP._sneakIdleAnim)
        end
        animName = KCD2MP._sneakIdleAnim
    else
        local anims = {
            sprint = "3d_relaxed_sprint_turn_strafe",
            run    = "3d_relaxed_run_turn_strafe",
            walk   = "3d_relaxed_walk_turn_strafe",
            idle   = "relaxed_idle_both",
        }
        animName = anims[wantTag]
        -- WO-39: a ghost whose owner has their weapon drawn idles in a
        -- weapon-ready stance when this build has one, so the drawn state
        -- reads at a glance between swings. Probe-on-first-use like every
        -- other list; none-found keeps the relaxed idle.
        if wantTag == "idle" and KCD2MP.ghostWeaponDrawn[id] then
            if KCD2MP._combatIdleAnim == nil then
                KCD2MP._combatIdleAnim = findAnim(ghost.entity, COMBAT_IDLE_ANIMS) or false
                mp_log("CombatIdleAnim: " .. tostring(KCD2MP._combatIdleAnim))
            end
            if KCD2MP._combatIdleAnim then animName = KCD2MP._combatIdleAnim end
        end
    end

    -- Call StartAnimation every tick to override Mannequin's idle.
    -- blend=0.15s: short enough to react quickly, long enough to not look choppy.
    pcall(function() ghost.entity:StartAnimation(0, animName, 0, 0.15, 1.0, true) end)

    -- Log only when tag actually changes
    if istate.animTag ~= wantTag then
        mp_log(string.format("Anim: %s %s->%s spd=%.2f", id, istate.animTag or "?", wantTag, speed))
        istate.animTag = wantTag
    end
end

-- ===== Interpolation Tick (20ms) =====

-- Floor detection: physics raycast hits real geometry (roads, rocks, bridges).
-- Falls back to terrain elevation if raycast unavailable.
local function getFloorZ(x, y, curZ)
    local floorZ = nil
    local reliable = false

    -- Physics raycast: origin 2m above ghost, ray goes 12m DOWN.
    -- Direction vector magnitude = ray length in CryEngine: {z=-12} = 12m downward.
    -- This covers range [curZ+2 .. curZ-10] - hits bridges, stairs, terrain.
    -- Flags 15 = ent_terrain(1)|ent_static(2)|ent_rigid(4)|ent_sleeping_rigid(8)
    pcall(function()
        local hits = Physics.RayWorldIntersection(
            {x=x, y=y, z=curZ + 2.0},
            {x=0,  y=0, z=-12},
            15,
            1
        )
        if hits and hits[1] then
            local h = hits[1]

            -- Log raycast field layout once (helps identify correct field name)
            if not KCD2MP._rayFmtLogged then
                KCD2MP._rayFmtLogged = true
                local parts = {}
                for k, v in pairs(h) do
                    if type(v) == "number" then
                        parts[#parts+1] = k .. "=" .. string.format("%.2f", v)
                    elseif type(v) == "table" then
                        parts[#parts+1] = k .. "={z=" .. tostring(v.z) .. "}"
                    end
                end
                mp_log("RAY_FORMAT: " .. table.concat(parts, " "))
            end

            -- CryEngine may return hit point as h.pt, h.pos, or h.point
            local hz = nil
            if     h.pt    then hz = h.pt.z
            elseif h.pos   then hz = h.pos.z
            elseif h.point then hz = h.point.z
            end
            -- Accept hits within 10m below current position
            if hz and hz > curZ - 10.0 then
                floorZ   = hz
                reliable = true
            end
        end
    end)

    -- Fallback to terrain mesh (underestimates height on bridges/platforms)
    if not floorZ then
        pcall(function()
            local gz = Terrain.GetElevation(x, y)
            if gz then floorZ = gz end
        end)
    end

    return floorZ, reliable
end

-- `arg` is the timer id when this fires from Script.SetTimer, and the string
-- "ext" when the agent pumps it in through ExecuteString while a local menu
-- has focus (WO-13). Compared against the sentinel rather than tested for
-- truthiness, because a real timer id is truthy too.
--
-- A pumped call must NOT reschedule. Script.SetTimer is frozen for the whole
-- duration of a local menu (WO-12 s0.3), so every timer queued by a pumped
-- call would still be pending when the menu closes and fire as one burst.
function KCD2MP_InterpTick(arg)
    if not KCD2MP.interpRunning then return end
    if arg ~= "ext" then
        Script.SetTimer(20, KCD2MP_InterpTick)  -- reschedule FIRST: crash-safe, tick never stops
        -- Only a scheduled fire counts as the chain being alive. A pumped call
        -- must not stamp this, or the pump would make a dead chain look
        -- healthy and stop KCD2MP_StartInterp from ever rebuilding it.
        KCD2MP._interpAliveAt = os.clock()
    end

    -- Heartbeat: confirm tick is alive (every ~5s = 250 * 20ms)
    KCD2MP._tickN = (KCD2MP._tickN or 0) + 1
    if KCD2MP._tickN % 250 == 0 then
        local gc = 0; for _ in pairs(KCD2MP.ghosts) do gc = gc + 1 end
        mp_log("TICK_ALIVE #" .. KCD2MP._tickN .. " ghosts=" .. gc)
    end

    -- Fetch player position once per tick for label distance calculations.
    local _playerPos = nil
    if player then pcall(function() _playerPos = player:GetWorldPos() end) end

    for id, ghost in pairs(KCD2MP.ghosts) do
        local _ok, _err = pcall(function()  -- catch any crash, keep tick alive
        local istate = ghost.istate
        if istate and ghost.entity then
            istate.ticksSincePacket = istate.ticksSincePacket + 1

            -- If ghost drifted very far from target (>5m), teleport directly.
            -- Prevents STEP_CAP from locking ghost hundreds of meters away.
            local distSq = (istate.tx-istate.cx)*(istate.tx-istate.cx)
                         + (istate.ty-istate.cy)*(istate.ty-istate.cy)
                         + (istate.tz-istate.cz)*(istate.tz-istate.cz)
            if distSq > 25.0 then
                mp_log(string.format("TELEPORT id=%s dist=%.1f", id, math.sqrt(distSq)))
                istate.cx = istate.tx
                istate.cy = istate.ty
                istate.cz = istate.tz
                istate.cr = istate.tr
            end

            -- Non-destructive DR: project render target forward WITHOUT touching istate.tx/ty.
            -- istate.tx/ty stays = last received packet. When next packet arrives it's
            -- simply overwritten - no snap-back rubber-band.
            -- DR just makes the ghost look ahead of the last-known position while waiting
            -- for the next packet, keeping movement smooth at sprint speeds.
            --
            -- WO-38 Phase 3 (Section A, the "two steps forward, one step
            -- back"): the old projection reverted to the bare last-packet
            -- position the moment the gap exceeded DR_MAX ticks -- and gaps
            -- exceed it constantly, because delivery is bursty (the
            -- ExecuteString channel runs 60-130 ms warm, WO-30). Every such
            -- revert moved the render target BACKWARD by the projected
            -- amount, which the 0.5 lerp then faithfully rendered as a
            -- visible step back. The projection now HOLDS at the DR_MAX
            -- point instead of reverting; the next real packet simply
            -- overwrites it.
            local renderX = istate.tx or istate.cx
            local renderY = istate.ty or istate.cy
            local DR_MAX = 3  -- 3 * 20ms = 60ms lookahead (covers 50ms packet gap)
            local ticks = istate.ticksSincePacket or 0
            if ticks >= 1 then
                local vx = istate.vx or 0
                local vy = istate.vy or 0
                if math.sqrt(vx*vx + vy*vy) > 0.5 then
                    local proj = math.min(ticks, DR_MAX)
                    renderX = renderX + vx * (proj * 0.020)
                    renderY = renderY + vy * (proj * 0.020)
                end
            end

            -- Smooth ghost toward render target (DR-extended, never snaps back).
            --
            -- WO-38 Phase 3: corrections AGAINST the direction of travel are
            -- damped harder than corrections along it. A backward correction
            -- is almost always a stale/regressed target (burst jitter, DR
            -- overshoot), not the player actually moonwalking -- rendering it
            -- at full strength is the visible rubber-band. Forward and
            -- sideways corrections keep the responsive factor.
            local factor = 0.5
            local dxT = renderX - istate.cx
            local dyT = renderY - istate.cy
            local vxS = istate.vx or 0
            local vyS = istate.vy or 0
            if (vxS*vxS + vyS*vyS) > 0.25 and (dxT*vxS + dyT*vyS) < 0 then
                factor = 0.15
            end
            local prevCx = istate.cx
            local prevCy = istate.cy
            local nx = lerpVal(istate.cx, renderX, factor)
            local ny = lerpVal(istate.cy, renderY, factor)
            local nz = istate.tz or istate.cz   -- Z tracks packet directly, no lerp (avoids sinking into rocks)

            istate.cx = nx
            istate.cy = ny
            istate.cz = nz
            istate.cr = lerpAngle(istate.cr, istate.tr, factor)

            local x = istate.cx
            local y = istate.cy
            local z = istate.cz
            local r = istate.cr

            -- WO-38 Phase 3 (Section A jump): airborne detection from the
            -- packet stream's vertical rate. While airborne, the snap-DOWN
            -- below must not fire -- a jump arc peaks well under its 2 m
            -- window, so the snap was flattening the whole arc back onto the
            -- floor. Held briefly past the last upward motion so the falling
            -- half of the arc isn't snapped either.
            local nowClock = os.clock()
            if (istate.vz or 0) > 1.2 and not istate.isRiding then
                istate.airborneUntil = nowClock + 0.6
            end
            local airborne = (istate.airborneUntil or 0) > nowClock

            -- Floor snap: correct ghost Z against raycast floor.
            -- Snap-UP: underground up to 10m (handles slopes, slight embedding).
            -- Snap-DOWN: hovering up to 2m (hover fix; >2m cap prevents snapping off bridges).
            -- Skip floor snap when riding: horse engine handles terrain, NPC follows horse.
            local sz = z
            if not istate.isRiding then
                local floorZ, reliable = getFloorZ(x, y, z)
                if floorZ then
                    local diff = sz - floorZ
                    if diff < -0.05 and diff > -10.0 then
                        -- Underground up to 10m: snap up to floor
                        sz = floorZ
                        istate.cz = floorZ
                    elseif diff > 0.05 and diff < 2.0 and not airborne then
                        -- Hovering up to 2m above floor: snap down
                        sz = floorZ
                    end
                end
            end
            istate.isAirborne = airborne

            -- When nativeMounted, the engine links NPC to horse - skip manual NPC SetWorldPos.
            -- We only update horse position; rider follows automatically.
            --
            -- WO-34 issue D: a corpse must not be dragged. Position sync is an
            -- always-on channel, entirely separate from the 0x23/0x24 death
            -- notification, so until now a ghost that had died -- either
            -- because its owner died, or because an NPC killed it in THIS
            -- world -- kept having SetWorldPos written onto it every 20 ms and
            -- slid around the map tracking a live player. Reported from a real
            -- two-player session: "once the NPC killed his stand in the dead
            -- body moved around where he did."
            --
            -- Frozen means: stop writing position and stop driving animation,
            -- but keep the nameplate -- moved onto the body's ACTUAL world
            -- position, not the incoming stream's, or the label would fly off
            -- and leave a nameless corpse behind (the WO-28 Q3 failure shape).
            -- istate keeps integrating normally underneath, so when the ghost
            -- is recycled it starts from the current stream position.
            local ok = true
            local frozen = mp_ghost_is_corpse(id, ghost)
            -- WO-39: a one-shot combat animation (swing/block) pins the ghost
            -- for its duration (<= 1.5 s). Confirmed live: the per-tick
            -- SetWorldPos writes interrupt a one-shot before a single frame
            -- of it renders -- swings played to a stationary unstreamed ghost
            -- and never to a streamed one -- and the z floor-snap fighting
            -- the clip's root motion was the reported up/down phasing during
            -- blocks. istate keeps integrating underneath, exactly like the
            -- frozen case, so the ghost catches up the moment the window ends.
            local oneShot = istate.oneShotUntil and os.clock() < istate.oneShotUntil
            if frozen then
                local wp = nil
                pcall(function() wp = ghost.entity:GetWorldPos() end)
                if wp then x, y, sz = wp.x, wp.y, wp.z end
            elseif oneShot then
                -- no position/angle writes; the one-shot owns the body
            elseif not istate.nativeMounted then
                local _, err = pcall(function()
                    ghost.entity:SetWorldPos({x=x, y=y, z=sz})
                    ghost.entity:SetWorldAngles({x=0, y=0, z=r})
                end)
                if err then
                    System.LogAlways("[KCD2-MP] InterpTick err '" .. id .. "': " .. tostring(err))
                    ghost.entity = nil
                    ok = false
                end
            end
            if ok then
                -- Speed from rendered XY movement this tick
                local movedDx = nx - prevCx
                local movedDy = ny - prevCy
                local rendSpeed = math.sqrt(movedDx*movedDx + movedDy*movedDy) / 0.020
                istate.smoothedSpeed = lerpVal(istate.smoothedSpeed or 0, rendSpeed, 0.4)

                if frozen then
                    -- WO-34 issue D: no animation on a corpse. Driving walk/run
                    -- onto a dead actor is what made the reported body look
                    -- like it was walking around rather than lying where it
                    -- fell. The horse half is skipped for the same reason.
                elseif istate.isRiding then
                    -- One-time riding diagnostic when interp tick first sees this ghost riding.
                    -- (% 50 == 1 never fires: interp=20ms, packets=10ms → only even counts seen)
                    if not istate._rideFirstTick then
                        istate._rideFirstTick = true
                        local hd = KCD2MP.horseGhosts[id]
                        local hasAI = false
                        pcall(function() hasAI = hd and hd.entity and hd.entity.AI ~= nil end)
                        mp_log(string.format("RIDE_FIRST id=%s hasHorse=%s hasAI=%s",
                            id, tostring(hd ~= nil), tostring(hasAI)))
                    end
                    -- Probe valid riding animations once (on first ghost that is riding).
                    if KCD2MP._ridingIdleAnim == nil then
                        KCD2MP._ridingIdleAnim = findAnim(ghost.entity, RIDING_IDLE_ANIMS) or false
                        mp_log("RideIdleAnim: " .. tostring(KCD2MP._ridingIdleAnim))
                    end
                    if KCD2MP._ridingGallopAnim == nil then
                        KCD2MP._ridingGallopAnim = findAnim(ghost.entity, RIDING_GALLOP_ANIMS) or false
                        mp_log("RideGallopAnim: " .. tostring(KCD2MP._ridingGallopAnim))
                    end

                    -- Engine sync auto-assigns idle rider anim at ForceMount time.
                    -- For gallop we must set it explicitly — engine does NOT auto-update.
                    -- ridingFallback: engine failed to mount, set all anims manually.
                    local isGallop = rendSpeed > 3.0
                    if istate.nativeMounted then
                        -- Only override for gallop; leave idle to engine sync system.
                        if isGallop and KCD2MP._ridingGallopAnim then
                            pcall(function()
                                ghost.entity:StartAnimation(0, KCD2MP._ridingGallopAnim, 0, 0.3, 1.0, true)
                            end)
                        end
                    else
                        local rideAnim = (isGallop and KCD2MP._ridingGallopAnim)
                                      or KCD2MP._ridingIdleAnim
                        if rideAnim then
                            pcall(function()
                                ghost.entity:StartAnimation(0, rideAnim, 0, 0.3, 1.0, true)
                            end)
                        end
                    end

                    -- Horse entity origin = ground level (~1.5m below rider/saddle).
                    -- getFloorZ from sz can hit the horse's own physics body (rigid) and return
                    -- a Z close to sz, putting the horse on top of the NPC ghost.
                    -- Fix: use sz-1.5 as default; only accept raycast if it finds ground
                    -- at least 0.5m below saddle (rules out horse/player body hits).
                    local horseGroundZ = sz - 1.5
                    local hFloorZ, _ = getFloorZ(x, y, sz)
                    if hFloorZ and (sz - hFloorZ) >= 0.5 then
                        horseGroundZ = hFloorZ
                    end
                    local horseData = KCD2MP.horseGhosts[id]
                    if horseData and horseData.entity then
                        local dt = 0.020
                        local vx = (x - (horseData.lastX or x)) / dt
                        local vy = (y - (horseData.lastY or y)) / dt
                        local spd = math.sqrt(vx*vx + vy*vy)
                        horseData.lastX = x
                        horseData.lastY = y

                        -- Smooth horse Z and rotation to remove raycast noise / snap artifacts
                        if not horseData.smoothZ then horseData.smoothZ = horseGroundZ end
                        horseData.smoothZ = lerpVal(horseData.smoothZ, horseGroundZ, 0.25)
                        if not horseData.smoothR then horseData.smoothR = r end
                        horseData.smoothR = lerpAngle(horseData.smoothR, r, 0.35)
                        local hz = horseData.smoothZ
                        local hr = horseData.smoothR

                        -- Probe horse entity animations once.
                        if KCD2MP._horseEntityIdleAnim == nil then
                            KCD2MP._horseEntityIdleAnim = findAnim(horseData.entity, HORSE_ENTITY_IDLE_ANIMS) or false
                            mp_log("HorseEntityIdleAnim: " .. tostring(KCD2MP._horseEntityIdleAnim))
                        end
                        if KCD2MP._horseEntityWalkAnim == nil then
                            KCD2MP._horseEntityWalkAnim = findAnim(horseData.entity, HORSE_ENTITY_WALK_ANIMS) or false
                            mp_log("HorseEntityWalkAnim: " .. tostring(KCD2MP._horseEntityWalkAnim))
                        end
                        if KCD2MP._horseEntityGallopAnim == nil then
                            KCD2MP._horseEntityGallopAnim = findAnim(horseData.entity, HORSE_ENTITY_GALLOP_ANIMS) or false
                            mp_log("HorseEntityGallopAnim: " .. tostring(KCD2MP._horseEntityGallopAnim))
                        end

                        -- Store render target for 8ms render loop (avoids 20ms stutter).
                        horseData.renderX = x
                        horseData.renderY = y
                        horseData.renderZ = hz
                        horseData.renderR = hr

                        -- Play horse entity animation based on speed.
                        -- relaxed_idle → engine sync assigns matching rider idle.
                        -- relaxed_gallop → we explicitly set rider gallop above.
                        local horseAnim
                        if spd > 3.0 then
                            horseAnim = KCD2MP._horseEntityGallopAnim or KCD2MP._horseEntityWalkAnim
                        elseif spd > 0.5 then
                            horseAnim = KCD2MP._horseEntityWalkAnim or KCD2MP._horseEntityGallopAnim
                        else
                            horseAnim = KCD2MP._horseEntityIdleAnim
                        end
                        if horseAnim then
                            pcall(function()
                                horseData.entity:StartAnimation(0, horseAnim, 0, 0.2, 1.0, true)
                            end)
                        end
                    end
                    -- NPC ghost Z = sz = packet player Z = saddle height (correct).
                    -- Already set above in the nativeMounted block. No extra offset needed.
                else
                    KCD2MP_UpdateAnimation(id, ghost)
                end

                -- Update label cache for the render loop (runs at 8ms to avoid flicker).
                -- When riding: sz = saddle height, head ~1.3m above saddle.
                -- When on foot: sz = feet, head ~1.8m above feet.
                local displayName = KCD2MP.ghostNames[id] or ("Player" .. tostring(id))
                -- WO-13 Phase 2: a player in a menu is standing perfectly still
                -- and not responding, which reads as broken. Say so instead.
                -- No pose work needed -- KCD2MP_UpdateAnimation already settles
                -- a stationary ghost into its idle animation on its own.
                if KCD2MP.ghostInMenu[id] then
                    displayName = displayName .. " [in menu]"
                end
                -- WO-28 Flow C, before health: a dead player's remaining
                -- number is stale by definition, so saying "dead" and a health
                -- figure at once would be two answers to one question.
                if KCD2MP.ghostDead[id] then
                    displayName = displayName .. " [dead - reloading]"
                else
                    -- WO-28 Flow A. This is the owner's own authoritative
                    -- health, not this world's local copy of the ghost --
                    -- see KCD2MP_SetGhostHealth.
                    local hs = KCD2MP.ghostHealth[id]
                    if hs and hs.h and hs.h >= 0 then
                        displayName = string.format("%s  %d HP", displayName, math.floor(hs.h + 0.5))
                        if hs.s and hs.s >= 0 then
                            displayName = string.format("%s / %d ST", displayName, math.floor(hs.s + 0.5))
                        end
                    end
                end
                -- WO-28 Flow B: sample this ghost's LOCAL health for
                -- NPC-inflicted damage. No-op unless this client holds
                -- NPC→player damage authority.
                sampleGhostHealth(id, ghost)
                local labelZ = sz + (istate.isRiding and 1.1 or 1.8)
                local labelSize = 0  -- 0 = hidden (too far)
                if _playerPos then
                    local dx = x - _playerPos.x
                    local dy = y - _playerPos.y
                    local dz = labelZ - _playerPos.z
                    local dist = math.sqrt(dx*dx + dy*dy + dz*dz)
                    if dist <= 60.0 then
                        labelSize = math.max(0.3, math.min(2.0, 10.0 / math.max(dist, 1.0)))
                    end
                end
                KCD2MP.labelCache[id] = {x=x, y=y, z=labelZ, size=labelSize, name=displayName}
            end
        end
        end)  -- end pcall for ghost update
        if not _ok then
            mp_log("InterpTick ERR id=" .. tostring(id) .. ": " .. tostring(_err))
        end
    end

    -- Update local player riding state every 5 ticks (~100ms)
    if KCD2MP._ridingCheckTick == nil then KCD2MP._ridingCheckTick = 0 end
    KCD2MP._ridingCheckTick = KCD2MP._ridingCheckTick + 1
    if KCD2MP._ridingCheckTick >= 5 then
        KCD2MP._ridingCheckTick = 0
        if player then
            local riding = false
            local mountName = nil
            -- Method 0: Find "Horse" class entity within 2.5m of player.
            -- When riding, horse origin is ~1.5m below saddle (player pos).
            -- Exclude our own ghost horses (kcd2mp_horse_*) to avoid false positives.
            pcall(function()
                local pos = player:GetWorldPos()
                if pos then
                    local ents = System.GetEntitiesInSphere(pos, 2.5)
                    if ents then
                        for _, e in ipairs(ents) do
                            local ec = "?"
                            local en = ""
                            pcall(function() ec = tostring(e.class or "?") end)
                            pcall(function() en = tostring(e:GetName() or "") end)
                            if ec == "Horse" and not en:find("kcd2mp_horse_") then
                                -- Require player to be >1.0m ABOVE horse pivot.
                                -- Horse entity pivot is at ground level; when mounted,
                                -- player Z = saddle height (~1.5m above ground).
                                -- Filters false positives when merely standing next to horse.
                                local horsePos = nil
                                pcall(function() horsePos = e:GetWorldPos() end)
                                if horsePos and (pos.z - horsePos.z) > 1.0 then
                                    riding = true
                                    -- WO-38 Phase 5: this IS the mounted horse.
                                    -- Only a plain authored name travels -- it is
                                    -- the cross-client key (same rule as NPC sync);
                                    -- a generated per-save name stays local and the
                                    -- receiver keeps its proxy fallback.
                                    if en ~= "" and string.find(en, "^[%w_]+$") then
                                        mountName = en
                                    end
                                end
                            end
                        end
                    end
                end
            end)
            -- Method 1: KCD2 human:IsRiding() (returns nil in v1.5, kept as fallback)
            if not riding then
                pcall(function()
                    if player.human then
                        local r = player.human:IsRiding()
                        if r then riding = true end
                    end
                end)
            end
            -- Method 2: CryEngine linked parent
            if not riding then
                pcall(function()
                    local p = player:GetLinkedParent()
                    if p then riding = true end
                end)
            end
            KCD2MP.isRiding = riding

            -- WO-38 Phase 5: broadcast which horse we are on, by authored
            -- name, on change plus a slow re-emit while mounted (late
            -- joiners; the relay replays nothing). "-" = dismounted or a
            -- mount whose identity could not be read (methods 1/2 detect
            -- riding without identifying the horse).
            if not riding then mountName = nil end
            KCD2MP._mountedHorseName = mountName
            local wire = mountName or "-"
            local nowC = os.clock()
            if wire ~= KCD2MP._horseInfoSentName
               or (mountName and (nowC - (KCD2MP._horseInfoSentAt or 0)) > 30) then
                KCD2MP._horseInfoSentName = wire
                KCD2MP._horseInfoSentAt = nowC
                KCD2MP_EmitEvent("horse_info", wire)
            end
        end
    end

end

-- ===== Main Tick (500ms) - position reporting =====

function KCD2MP_Tick()
    KCD2MP.tickCount = KCD2MP.tickCount + 1
    local ok, err = pcall(function()
        KCD2MP_WritePos()

        if KCD2MP.tickCount % 20 == 0 then
            local ghostCount = 0
            for _ in pairs(KCD2MP.ghosts) do ghostCount = ghostCount + 1 end
            System.LogAlways(string.format("[KCD2-MP] tick=%d ghosts=%d",
                KCD2MP.tickCount, ghostCount))
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Tick error: " .. tostring(err))
    end
    if KCD2MP.running then
        Script.SetTimer(500, KCD2MP_Tick)
    end
end

-- ===== Ghost reconciliation after a save load (WO-28 Phase 0) =====
--
-- Measured live, 2026-08-07: loading a save destroys every ghost ENTITY in the
-- world, but KCD2MP.ghosts keeps holding the entity table it was given at spawn
-- time. That table stays non-nil -- it is a Lua value, and nothing about the
-- world unload reaches in and clears it -- so KCD2MP_UpdateGhost's own
-- "spawn if missing" test (`if not ghost or not ghost.entity`) reads as
-- "present" forever and the ghost is never respawned.
--
-- What that looks like in game, in the human's own words while it was
-- happening: *"the ghost is invisible for me but I can see its nametag
-- continuing in the same path"* -- because istate keeps taking position
-- packets and KCD2MP_InterpTick keeps writing labelCache from it, with no
-- body under the label. It never recovers on its own.
--
-- The check has to be a real world lookup by spawn name (never the display
-- name -- WO-26 established that is not a key anything resolves by), which is
-- too expensive for the 20 ms interp path. So the agent calls this on a slow
-- cadence instead, the same shape as WO-13's KCD2MP_StartInterp re-arm.
--
-- Deliberately drops only the bookkeeping rather than calling
-- KCD2MP_RemoveGhost: there is no entity left to remove, the display name and
-- menu/health/death tags are all still correct for that player, and the very
-- next position packet respawns the body through the ordinary path.
function KCD2MP_ReconcileGhosts()
    local fixed = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost and ghost.entity then
            local spawnName = ghost.spawnName or ("kcd2mp_" .. tostring(id))
            local live = nil
            pcall(function() live = System.GetEntityByName(spawnName) end)
            -- WO-34 issue D, the other half of the freeze. A ghost an NPC
            -- killed in THIS world is a corpse for good -- death is a one-way
            -- transition (WO-25 Phase 3: SetState health writes do not reverse
            -- IsDead) -- so freezing alone would leave its owner permanently
            -- invisible here while they carry on playing. Recycled through the
            -- same path a save-load-destroyed entity takes: drop the
            -- bookkeeping, let the next position packet spawn a fresh body.
            --
            -- Only the ENTITY being dead triggers this. A ghost whose OWNER
            -- died (KCD2MP.ghostDead, tagged "[dead - reloading]") is still a
            -- perfectly good standing body and must NOT be recycled -- WO-28
            -- chose to leave it exactly so a player back in seconds does not
            -- cost a full spawn cycle, and that reasoning is unchanged.
            local corpse = false
            if live and live.actor then
                pcall(function() corpse = live.actor:IsDead() and true or false end)
            end
            if live and corpse then
                mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                       "' is DEAD in this world -- removing the body so a fresh ghost respawns")
                -- Remove the corpse rather than abandoning it. An untracked
                -- body is what WO-27 spent a session cleaning up, and this one
                -- is also a real lootable/grabbable object that another player
                -- can commit corpseViolation on (docs/WO-34-findings.md).
                mp_remove_entity_verified(ghost.entityId, spawnName, "ghost corpse " .. tostring(id))
                live = nil
            end
            if not live then
                if not corpse then
                    mp_log("RECONCILE id=" .. tostring(id) .. " entity '" .. spawnName ..
                           "' is gone from the world (save load?) -- clearing so it respawns")
                end
                -- The horse half is destroyed by the same unload and tracked
                -- separately, so it has to be dropped too or a remounting
                -- ghost would sit on a horse that no longer exists.
                KCD2MP.horseGhosts[id] = nil
                KCD2MP.ghosts[id] = nil
                KCD2MP.labelCache[id] = nil
                -- The Flow B baseline belonged to the destroyed entity. A
                -- fresh one starts at full health, so keeping it would read as
                -- a large positive delta -- harmless (guard 3 drops it) but
                -- meaningless, and clearing it is what makes that certain.
                KCD2MP.ghostHpSeen[id] = nil
                KCD2MP.ghostHpSkip[id] = nil
                fixed = fixed + 1
            end
        end
    end
    if fixed > 0 then
        System.LogAlways("[KCD2-MP] Reconcile: " .. fixed .. " ghost(s) had lost their entity; will respawn")
    end
    return fixed
end

-- ===== Ghost Remove =====

function KCD2MP_RemoveGhost(id)
    local ghost = KCD2MP.ghosts[id]
    if not ghost then return end
    -- Remove horse ghost first (if riding)
    KCD2MP_RemoveHorse(id)
    -- WO-27: was a single unchecked System.RemoveEntity. It returns without
    -- error while leaving the entity standing, which is how orphans survived
    -- every "removal" the mod thought it had done. Look the entity up by the
    -- spawn name -- NOT the display name, which since WO-26 is known not to be
    -- a key anything resolves by (and which this mod no longer sets).
    local spawnName = ghost.spawnName or ("kcd2mp_" .. tostring(id))
    if ghost.entityId or spawnName then
        mp_remove_entity_verified(ghost.entityId, spawnName, "ghost " .. tostring(id))
    end
    KCD2MP.ghosts[id] = nil
    KCD2MP.labelCache[id] = nil
    -- A player who disconnects while in a menu must not leave a stale
    -- "[in menu]" tag behind for whoever next reuses this ghost id (WO-13).
    KCD2MP.ghostInMenu[id] = nil
    -- Same reasoning for every WO-28 per-ghost fact: relay ids are reassigned
    -- per connection, so a leftover health figure, death tag or sampler
    -- baseline would be attributed to whoever next gets this id. The sampler
    -- baseline especially -- a stale one would read as an enormous first
    -- delta and fire a fake hit at the new occupant.
    KCD2MP.ghostHealth[id] = nil
    KCD2MP.ghostDead[id] = nil
    KCD2MP.ghostHpSeen[id] = nil
    KCD2MP.ghostHpSkip[id] = nil
    -- WO-39: same id-reuse reasoning -- a stale drawn flag would make whoever
    -- next gets this id spawn weapon-ready for no reason.
    KCD2MP.ghostWeaponDrawn[id] = nil
    System.LogAlways("[KCD2-MP] Removed ghost: " .. id)
    -- Reset riding anim probes: if they were cached while NPC was ForceMount'd they may be
    -- wrong (false). Re-probe on next riding ghost (free NPC → correct results).
    KCD2MP._ridingIdleAnim = nil
    KCD2MP._ridingGallopAnim = nil
end

function KCD2MP_RemoveAllGhosts()
    local count = 0
    for id, _ in pairs(KCD2MP.ghosts) do
        KCD2MP_RemoveGhost(id)
        count = count + 1
    end
    -- Clean up any orphaned horse ghosts
    for id, _ in pairs(KCD2MP.horseGhosts) do
        KCD2MP_RemoveHorse(id)
    end
    System.LogAlways("[KCD2-MP] Removed " .. count .. " ghosts")
end

-- ===== Start / Stop =====

function KCD2MP_Start()
    if KCD2MP.running then
        System.LogAlways("[KCD2-MP] Already running")
        return
    end
    KCD2MP.running = true
    KCD2MP.tickCount = 0
    System.LogAlways("[KCD2-MP] Starting (pos tick=500ms, interp tick=50ms)")
    Script.SetTimer(500, KCD2MP_Tick)
    KCD2MP_StartInterp()
end

function KCD2MP_Stop()
    KCD2MP.running = false
    KCD2MP.interpRunning = false
    KCD2MP.labelRunning = false
    KCD2MP.labelCache = {}
    KCD2MP_RemoveAllGhosts()
    System.LogAlways("[KCD2-MP] Stopped")
end

-- ===== Test / Inspect =====

function KCD2MP_SpawnTest()
    if not player then return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    local ox, oy = 3, 0
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end

    KCD2MP_SpawnGhost("test_ghost", pos.x + ox, pos.y + oy, pos.z, ang and ang.z or 0)
end

function KCD2MP_InspectGhost()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost. Run mp_spawn_test first.")
        return
    end

    local ent = ghost.entity
    local istate = ghost.istate
    System.LogAlways("[KCD2-MP] === GHOST INSPECT ===")
    pcall(function() System.LogAlways("[KCD2-MP] name=" .. tostring(ent:GetName())) end)
    pcall(function() System.LogAlways("[KCD2-MP] class=" .. tostring(ent.class)) end)
    if istate then
        System.LogAlways(string.format("[KCD2-MP] interp: alpha=%.3f step=%.3f ticksSince=%d packets=%d",
            istate.alpha, istate.alphaStep, istate.ticksSincePacket, istate.packetCount))
        System.LogAlways(string.format("[KCD2-MP] prev=%.1f,%.1f,%.1f  target=%.1f,%.1f,%.1f  cur=%.1f,%.1f,%.1f",
            istate.px, istate.py, istate.pz,
            istate.tx, istate.ty, istate.tz,
            istate.cx, istate.cy, istate.cz))
        System.LogAlways(string.format("[KCD2-MP] velocity=%.2f,%.2f,%.2f u/s",
            istate.vx, istate.vy, istate.vz))
    end
    pcall(function()
        local pos = ent:GetWorldPos()
        System.LogAlways(string.format("[KCD2-MP] entity pos=%.2f,%.2f,%.2f", pos.x, pos.y, pos.z))
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Discovery helpers (unchanged) =====

function KCD2MP_FindNPCs()
    System.LogAlways("[KCD2-MP] === FINDING HUMAN NPCs ===")
    if not player then return end

    local ppos = player:GetWorldPos()

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 100)
        if not ents then return end

        local npcCount = 0
        for _, ent in ipairs(ents) do
            local hasChar = false
            pcall(function() hasChar = ent:IsSlotCharacter(0) end)

            if hasChar then
                local isHuman = false
                pcall(function()
                    if ent.soul or ent.human or ent.actor then isHuman = true end
                end)

                if isHuman then
                    local name = "?"
                    local eclass = "?"
                    pcall(function() name = ent:GetName() end)
                    pcall(function() eclass = ent.class or "?" end)

                    npcCount = npcCount + 1
                    System.LogAlways(string.format("[KCD2-MP] NPC: name=%s class=%s",
                        tostring(name), tostring(eclass)))

                    if npcCount >= 10 then
                        System.LogAlways("[KCD2-MP] ... (first 10 only)")
                        break
                    end
                end
            end
        end

        System.LogAlways("[KCD2-MP] Found " .. npcCount .. " human NPCs within 100m")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] FindNPCs error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Animation Discovery =====

-- Probe animation names - only GetAnimationLength > 0 is reliable
function KCD2MP_ProbeAnims()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeAnims: no ghost.")
        return
    end
    local ent = ghost.entity

    -- Full CryEngine path variants (no extension) + short names
    local candidates = {
        -- Short names
        "idle", "run", "walk", "sprint", "jog",
        "Idle", "Run", "Walk", "Sprint",
        -- Full path guesses (KCD2 convention)
        "animations/humans/male/locomotion/run_loop",
        "animations/humans/male/locomotion/walk_loop",
        "animations/humans/male/locomotion/idle_loop",
        "animations/humans/male/locomotion/run_fwd",
        "animations/humans/male/locomotion/walk_fwd",
        "animations/humans/male/locomotion/sprint_loop",
        "animations/humans/male/locomotion/run",
        "animations/humans/male/locomotion/walk",
        "animations/humans/male/locomotion/idle",
        -- KCD1-style paths
        "animations/characters/humans/male/locomotion/run_loop",
        "animations/characters/humans/male/locomotion/walk_loop",
        "animations/characters/humans/male/locomotion/idle_loop",
        -- Assets subfolder
        "animations/assets/humans/locomotion/run_loop",
        "animations/assets/humans/locomotion/walk_loop",
        -- Mannequin fragment names
        "MotionIdle", "MotionRun", "MotionWalk",
        "LocomotionIdle", "LocomotionRun", "LocomotionWalk",
        "Locomotion", "locomotion",
    }

    System.LogAlways("[KCD2-MP] === PROBING ANIMS ON GHOST ===")
    for _, name in ipairs(candidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] HIT: '%s' len=%.3f", name, len))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Real Horse Scanner =====
-- Scans a real KCD2 horse NPC within 20m to discover animation names, AI methods,
-- horse.horse component API, rider linkage, etc. Helps calibrate ghost horse behavior.
function KCD2MP_ScanNearbyHorse()
    if not player then
        System.LogAlways("[KCD2-MP] ScanHorse: no player")
        return
    end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === SCAN NEARBY HORSE ===")

    local ents = nil
    pcall(function() ents = System.GetEntitiesInSphere(ppos, 20) end)
    if not ents then
        System.LogAlways("[KCD2-MP] GetEntitiesInSphere failed")
        return
    end

    local animCandidates = {
        "idle","walk","trot","canter","gallop","run","stand",
        "idle_loop","walk_loop","trot_loop","canter_loop","gallop_loop","run_loop",
        "horse_idle","horse_walk","horse_trot","horse_canter","horse_gallop","horse_run",
        "horse_idle_loop","horse_walk_loop","horse_trot_loop","horse_gallop_loop",
        "horse_stand","horse_stand_idle","horse_rest",
        "horse_loco_idle","horse_loco_walk","horse_loco_trot","horse_loco_gallop",
        "animal_idle","animal_walk","animal_trot","animal_gallop","animal_run",
        "loco_idle","loco_walk","loco_run","loco_gallop","loco_trot",
        "act_idle","act_walk","act_run","act_gallop","act_trot",
        "mm_idle","mm_walk","mm_run","mm_gallop",
        "3d_idle","3d_walk","3d_run","3d_gallop","3d_trot",
        "relaxed_idle","relaxed_walk","relaxed_run",
        "stand_idle","stand_loop","rest_idle",
    }

    local found = 0
    for _, e in ipairs(ents) do
        local ec = "?"
        local en = ""
        pcall(function() ec = tostring(e.class or "?") end)
        pcall(function() en = tostring(e:GetName() or "") end)

        if ec == "Horse" and not en:find("kcd2mp_horse_") then
            found = found + 1
            System.LogAlways(string.format("[KCD2-MP] HORSE: name=%s id=%s", en, tostring(e.id)))

            -- Character file path (tells us the skeleton / animation set)
            pcall(function()
                local cf = e:GetCharacterFileName(0)
                System.LogAlways("[KCD2-MP] CharFile[0]: " .. tostring(cf))
            end)
            pcall(function()
                local cf = e:GetCharacterFileName(1)
                System.LogAlways("[KCD2-MP] CharFile[1]: " .. tostring(cf))
            end)

            -- Animation probe: slot 0 and slot 1
            local hits0, hits1 = {}, {}
            for _, nm in ipairs(animCandidates) do
                local l0 = 0; pcall(function() l0 = e:GetAnimationLength(0, nm) or 0 end)
                if l0 > 0 then hits0[#hits0+1] = nm .. "=" .. string.format("%.2f", l0) end
                local l1 = 0; pcall(function() l1 = e:GetAnimationLength(1, nm) or 0 end)
                if l1 > 0 then hits1[#hits1+1] = nm .. "=" .. string.format("%.2f", l1) end
            end
            System.LogAlways("[KCD2-MP] AnimSlot0: " .. (#hits0>0 and table.concat(hits0,", ") or "none"))
            System.LogAlways("[KCD2-MP] AnimSlot1: " .. (#hits1>0 and table.concat(hits1,", ") or "none"))

            -- horse.horse component
            local hc = nil; pcall(function() hc = e.horse end)
            if hc then
                local fns = {}
                pcall(function()
                    for k, v in pairs(hc) do
                        if type(v) == "function" then fns[#fns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] horse.horse fns: " .. table.concat(fns, ", "))
                pcall(function() System.LogAlways("[KCD2-MP] HasRider: " .. tostring(e.horse:HasRider())) end)
                pcall(function() System.LogAlways("[KCD2-MP] IsMountable: " .. tostring(e.horse:IsMountable())) end)
            else
                System.LogAlways("[KCD2-MP] horse.horse = nil")
            end

            -- AI component methods
            local hasAI = false; pcall(function() hasAI = e.AI ~= nil end)
            System.LogAlways("[KCD2-MP] hasAI: " .. tostring(hasAI))
            if hasAI then
                local aiFns = {}
                pcall(function()
                    for k, v in pairs(e.AI) do
                        if type(v) == "function" then aiFns[#aiFns+1] = k end
                    end
                end)
                System.LogAlways("[KCD2-MP] AI fns: " .. table.concat(aiFns, ", "))
            end

            -- human / actor / soul
            pcall(function() System.LogAlways("[KCD2-MP] has human: " .. tostring(e.human ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has actor: " .. tostring(e.actor ~= nil)) end)
            pcall(function() System.LogAlways("[KCD2-MP] has soul: " .. tostring(e.soul ~= nil)) end)

            -- Properties
            pcall(function()
                if e.Properties then
                    local props = {}
                    for k, v in pairs(e.Properties) do
                        if type(v) ~= "table" then props[#props+1] = k .. "=" .. tostring(v) end
                    end
                    System.LogAlways("[KCD2-MP] Props: " .. table.concat(props, " | "))
                end
            end)

            if found >= 2 then break end
        end
    end

    if found == 0 then
        System.LogAlways("[KCD2-MP] No real horses within 20m (try within 20m of a horse NPC)")
    end
    System.LogAlways("[KCD2-MP] === END SCAN ===")
end

-- Find nearby HUMAN NPC and get their character model path, then copy to ghost
function KCD2MP_CopyNPCModel()
    if not player then return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HUMAN NPC + COPY MODEL ===")

    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] No ghost entity! Run server first.")
        return
    end

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 50)
        if not ents then return end

        local humanCount = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                -- Must have soul or human (real human NPC, not horse/door/chest)
                local isHuman = false
                pcall(function()
                    isHuman = (ent.soul ~= nil) or (ent.human ~= nil)
                end)
                if not isHuman then
                    -- Also accept NPCs with actor table
                    pcall(function()
                        if ent.actor and ent.actor.__this then isHuman = true end
                    end)
                end

                if isHuman then
                    local ename = "?"
                    pcall(function() ename = ent:GetName() end)
                    local eclass = "?"
                    pcall(function() eclass = ent.class or "?" end)
                    System.LogAlways(string.format("[KCD2-MP] HUMAN NPC: %s (class=%s)", ename, eclass))
                    humanCount = humanCount + 1

                    -- Try to get character filename
                    local cdfPath = nil
                    pcall(function()
                        local ch = ent:GetCharacter(0)
                        if ch then
                            cdfPath = ch:GetFilePath()
                            System.LogAlways("[KCD2-MP]   GetCharacter(0):GetFilePath() = " .. tostring(cdfPath))
                        end
                    end)
                    pcall(function()
                        local fn = ent:GetCharacterFileName(0)
                        System.LogAlways("[KCD2-MP]   GetCharacterFileName(0) = " .. tostring(fn))
                        if fn and not cdfPath then cdfPath = fn end
                    end)
                    -- Check Properties for model path
                    pcall(function()
                        if ent.Properties then
                            for k, v in pairs(ent.Properties) do
                                if type(v) == "string" and #v > 3 then
                                    if k:lower():find("model") or k:lower():find("cdf") or
                                       k:lower():find("file") or k:lower():find("char") then
                                        System.LogAlways("[KCD2-MP]   Props." .. k .. " = " .. v)
                                        if not cdfPath then cdfPath = v end
                                    end
                                end
                            end
                        end
                    end)

                    -- Probe animations on this NPC
                    local animCandidates = {
                        "idle", "run", "walk", "sprint", "jog",
                        "Idle", "Run", "Walk", "Sprint",
                        "run_loop", "walk_loop", "idle_loop", "sprint_loop",
                        "run_fwd", "walk_fwd", "run01", "walk01", "idle01",
                        "mm_run_fwd", "mm_walk_fwd", "mm_idle",
                        "loco_run", "loco_walk", "loco_idle",
                        "act_run", "act_walk", "act_idle",
                    }
                    for _, aname in ipairs(animCandidates) do
                        local len = 0
                        pcall(function() len = ent:GetAnimationLength(0, aname) or 0 end)
                        if len > 0 then
                            System.LogAlways(string.format("[KCD2-MP]   ANIM HIT '%s' len=%.3f", aname, len))
                        end
                    end

                    -- If we found a CDF, try loading it onto ghost
                    if cdfPath and cdfPath ~= "" then
                        System.LogAlways("[KCD2-MP]   Loading CDF onto ghost: " .. cdfPath)
                        local loadOk, loadErr = pcall(function()
                            ghost.entity:LoadCharacter(0, cdfPath)
                        end)
                        System.LogAlways("[KCD2-MP]   LoadCharacter result: " .. tostring(loadOk) .. " " .. tostring(loadErr))

                        if loadOk then
                            -- Now probe ghost again
                            System.LogAlways("[KCD2-MP]   Re-probing ghost after CDF load:")
                            for _, aname in ipairs(animCandidates) do
                                local len = 0
                                pcall(function() len = ghost.entity:GetAnimationLength(0, aname) or 0 end)
                                if len > 0 then
                                    System.LogAlways(string.format("[KCD2-MP]   GHOST HIT '%s' len=%.3f", aname, len))
                                end
                            end
                        end
                    end

                    if humanCount >= 3 then break end
                end
            end
        end
        System.LogAlways("[KCD2-MP] Found " .. humanCount .. " human NPCs")
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] Error: " .. tostring(err))
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test AI.SetForcedNavigation on ghost (try to drive locomotion animation via AI)
function KCD2MP_TestAINav()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] TestAINav: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] TestAINav: sending velocity {1,0,0} to entityId=" .. tostring(eid))

    -- Try passing velocity vector (tell AI it's moving forward)
    local ok1, e1 = pcall(function() AI.SetForcedNavigation(eid, {x=3, y=0, z=0}) end)
    System.LogAlways("[KCD2-MP]   SetForcedNavigation: " .. tostring(ok1) .. " " .. tostring(e1))

    local ok2, e2 = pcall(function() AI.SetSpeed(eid, 3) end)
    System.LogAlways("[KCD2-MP]   SetSpeed(3): " .. tostring(ok2) .. " " .. tostring(e2))

    local ok3, e3 = pcall(function() AI.Signal(0, 1, "OnMoveForward", eid) end)
    System.LogAlways("[KCD2-MP]   Signal OnMoveForward: " .. tostring(ok3) .. " " .. tostring(e3))
end

-- Deep scan: recursively list up to 3 levels, log files with .caf/.adb
function KCD2MP_ScanAnims()
    System.LogAlways("[KCD2-MP] === DEEP ANIM SCAN ===")

    local function scanDir(path, depth)
        local entries = nil
        pcall(function() entries = System.ScanDirectory(path) end)
        if not entries then return end
        for _, name in ipairs(entries) do
            local full = path .. "/" .. name
            -- Log CAF/ADB files immediately
            if name:find("%.caf$") or name:find("%.CAF$") then
                System.LogAlways("[KCD2-MP] CAF: " .. full)
            elseif name:find("%.adb$") or name:find("%.ADB$") then
                System.LogAlways("[KCD2-MP] ADB: " .. full)
            elseif depth < 3 then
                -- Recurse into subdirectory
                scanDir(full, depth + 1)
            end
        end
    end

    -- Scan humans animation tree
    scanDir("Animations/humans", 1)
    scanDir("Animations/assets", 1)
    scanDir("Animations/Mannequin/adb", 1)

    System.LogAlways("[KCD2-MP] === END DEEP SCAN ===")
end

-- Try AI.SetForcedNavigation to drive locomotion animation
-- dirX, dirY = movement direction (unit vector), speed = 0 to stop
function KCD2MP_SetGhostMovement(id, dirX, dirY, speed)
    local ghost = KCD2MP.ghosts[id]
    if not ghost or not ghost.entity then return end

    local eid = ghost.entityId
    if speed > 0 then
        -- Tell AI the entity is moving in this direction at this speed
        pcall(function() AI.SetSpeed(eid, speed) end)
        pcall(function()
            AI.SetForcedNavigation(eid, {x=dirX, y=dirY, z=0})
        end)
    else
        pcall(function() AI.SetForcedNavigation(eid, {x=0, y=0, z=0}) end)
        pcall(function() AI.SetSpeed(eid, 0) end)
    end
end

-- Read Mannequin ADB via CryEngine XML loader (reads from PAK)
function KCD2MP_ReadADB()
    System.LogAlways("[KCD2-MP] === READ ADB ===")

    local adbPaths = {
        "Animations/Mannequin/ADB/kcd_male_database.adb",
        "Animations/Mannequin/adb/kcd_male_database.adb",
        "animations/mannequin/adb/kcd_male_database.adb",
    }

    -- Try CryEngine XML loader (reads files from PAK virtual filesystem)
    for _, path in ipairs(adbPaths) do
        local node = nil
        local ok, err = pcall(function()
            node = System.LoadXMLFile(path)
        end)
        System.LogAlways("[KCD2-MP] LoadXMLFile(" .. path .. "): ok=" .. tostring(ok) .. " node=" .. tostring(node) .. " err=" .. tostring(err))
        if ok and node then
            System.LogAlways("[KCD2-MP] XML loaded! Walking nodes...")
            -- Walk XML tree looking for Fragment names
            local function walkNode(n, depth)
                if depth > 4 then return end
                local tag = ""
                local name = ""
                pcall(function() tag = n:getTag() end)
                pcall(function() name = n:getAttr("name") end)
                if name and name ~= "" then
                    System.LogAlways("[KCD2-MP] " .. string.rep("  ", depth) .. tag .. " name='" .. name .. "'")
                end
                local count = 0
                pcall(function() count = n:getChildCount() end)
                for i = 0, count - 1 do
                    local child = nil
                    pcall(function() child = n:getChild(i) end)
                    if child then walkNode(child, depth + 1) end
                end
            end
            walkNode(node, 0)
            System.LogAlways("[KCD2-MP] === END ===")
            return
        end
    end

    -- Fallback: ScanDirectory
    System.LogAlways("[KCD2-MP] LoadXMLFile failed for all paths. Scanning directories...")
    local dirs = {
        "Animations/Mannequin/ADB",
        "Animations/Mannequin/adb",
        "Animations/Mannequin/adb/adb",
    }
    for _, d in ipairs(dirs) do
        local entries = nil
        pcall(function() entries = System.ScanDirectory(d) end)
        if entries and #entries > 0 then
            System.LogAlways("[KCD2-MP] " .. d .. " -> " .. #entries .. " entries:")
            for i, e in ipairs(entries) do
                System.LogAlways("[KCD2-MP]   " .. e)
                if i > 30 then break end
            end
        else
            System.LogAlways("[KCD2-MP] " .. d .. " -> empty/nil")
        end
    end

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Probe Mannequin animation tags on ghost via AI.SetAnimationTag
-- Tags drive which Mannequin fragments play (including locomotion)
function KCD2MP_ProbeAnimTags()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost then
        System.LogAlways("[KCD2-MP] ProbeAnimTags: no ghost")
        return
    end
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === PROBE ANIM TAGS ===")
    System.LogAlways("[KCD2-MP] entityId=" .. tostring(eid))

    -- Common Mannequin tag names for locomotion
    local tags = {
        "Moving", "moving", "Run", "run", "Walk", "walk",
        "Sprint", "sprint", "Locomotion", "locomotion",
        "Alert", "alert", "Relaxed", "relaxed",
        "InCombat", "Combat", "Idle", "idle",
        "Forward", "forward", "MoveForward",
        "Jogging", "Running", "Walking",
    }

    System.LogAlways("[KCD2-MP] Trying AI.SetAnimationTag:")
    for _, tag in ipairs(tags) do
        local ok, err = pcall(function()
            AI.SetAnimationTag(eid, tag)
        end)
        -- Log only errors or interesting results
        if not ok then
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' ERROR: " .. tostring(err))
        else
            System.LogAlways("[KCD2-MP]   tag='" .. tag .. "' OK")
        end
    end

    -- Also try clearing tags
    pcall(function() AI.SetAnimationTag(eid, "") end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- Test the real animation names from ADB analysis
function KCD2MP_TestRunAnim()
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] TestRunAnim: no ghost")
        return
    end
    local ent = ghost.entity
    local eid = ghost.entityId
    System.LogAlways("[KCD2-MP] === TEST REAL ANIM NAMES ===")

    local names = {
        "3d_relaxed_run_turn_strafe",
        "3d_relaxed_walk_turn_strafe",
        "relaxed_idle_both",
        "3d_armored_walk_turn_strafe",
        "3d_wounded_run_turn_strafe",
    }
    for _, name in ipairs(names) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        local started = false
        pcall(function() started = ent:StartAnimation(0, name) end)
        System.LogAlways(string.format("[KCD2-MP] '%s': len=%.3f started=%s",
            name, len, tostring(started)))
    end

    -- Also try AI tag "run"
    System.LogAlways("[KCD2-MP] Setting AI tag 'run'...")
    pcall(function() AI.SetAnimationTag(eid, "run") end)
    pcall(function() AI.SetSpeed(eid, 4) end)

    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Terrain Debug =====

function KCD2MP_TerrainCheck()
    if not player then System.LogAlways("[KCD2-MP] TerrainCheck: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    local ok, gz = pcall(function() return Terrain.GetElevation(pos.x, pos.y) end)
    System.LogAlways(string.format("[KCD2-MP] TerrainCheck: player pos=%.2f,%.2f,%.2f | Terrain.GetElevation=ok=%s gz=%s",
        pos.x, pos.y, pos.z, tostring(ok), tostring(gz)))

    -- Check ghost position vs terrain
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local gpos = nil
            pcall(function() gpos = ghost.entity:GetWorldPos() end)
            local tgz = nil
            if gpos then
                pcall(function() tgz = Terrain.GetElevation(gpos.x, gpos.y) end)
                System.LogAlways(string.format("[KCD2-MP] Ghost '%s': entity z=%.2f | terrain z=%s | diff=%s",
                    id, gpos.z, tostring(tgz), tgz and string.format("%.2f", gpos.z - tgz) or "?"))
            end
        end
    end
end

-- ===== Stance Probe =====

function KCD2MP_ProbeStance()
    if not player then System.LogAlways("[KCD2-MP] ProbeStance: no player"); return end
    System.LogAlways("[KCD2-MP] === STANCE PROBE ===")
    local s1, s2, s3 = nil, nil, nil
    local ok1 = pcall(function() s1 = player:GetStance() end)
    System.LogAlways("[KCD2-MP] GetStance() ok=" .. tostring(ok1) .. " val=" .. tostring(s1))
    local ok2 = pcall(function()
        if player.actor then
            s2 = player.actor.bSneaking
            System.LogAlways("[KCD2-MP] actor.bSneaking=" .. tostring(s2))
        else
            System.LogAlways("[KCD2-MP] actor=nil")
        end
    end)
    System.LogAlways("[KCD2-MP] === END ===")
end

-- ===== Spawn NPC with custom armor =====

-- Preset table (name -> {items, preset})
KCD2MP.armorPresets = {
    ghost = {
        items  = "00b7ed62-a7bd-4269-acfa-8d852366579b,10ff6d35-8c14-4871-8656-bdc3476d8b12",
        preset = "dc000001-0000-0000-0000-000000000000",
    },
    -- White/Red: LegsBrigandine04 + LegsPadded01 + knackersGloves + GambesonLong01
    -- + Brigandine10 + ArmPlate04 + CoifMail01 + BascinetVisor05 + BootsKnee03
    -- weapon: kkut_menhart preset (sermiry_longSwordMenhart)
    white_red = {
        items  = "a8b22da0-e42e-4d79-abe7-52e6eebad6eb"  -- LegsBrigandine04_m04_A5 (spodnie)
              .. ",cc1adb78-fa5a-45c9-be7b-b7b50e182cb3"  -- LegsPadded01_m02_C3 (nogawice)
              .. ",36a701ed-2144-452a-b113-385efba2c0d1"  -- rasuvUcen_knackersGloves
              .. ",46b051c4-d4e2-4f3a-8b88-e3f64dae4618"  -- GambesonLong01_m03_C3 (przeszywanica)
              .. ",1aadf1e5-c37b-41c3-bc65-354187022c91"  -- Brigandine10_m09_A5 (plate armor)
              .. ",a5322fcd-27b4-4f4e-bfbf-49c519c74c74"  -- ArmPlate04_m08_A5 (naramienniki)
              .. ",cfc1fd72-dbb7-49a4-8713-6acf215a72be"  -- CoifMail01_m02_C2 (coif mail)
              .. ",b6fe59ec-c854-402a-848e-a77f55661c19"  -- BascinetVisor05_m04_C4 (bascinet)
              .. ",a06cfbf0-3d59-4003-89d4-69a82eb735af", -- BootsKnee03_m01_C (buty)
        preset  = "dc000003-0000-0000-0000-000000000000",
        weapons = "af2dd849-92a4-4081-9955-0afcb861fcd5", -- kkut_menhart (sermiry_longSwordMenhart)
    },
    -- LegsPadded01(pikowane) + GambesonShort01 + CoifMail02 + MailShort01
    -- + Cuirass07 + ArmPlate04 + Gauntlets08 + LegsPlate03 + BascinetVisor04
    -- + longSwordDuel (inventory only) - no boots
    knight = {
        items  = "078e439b-1a5b-40ca-b009-d4abf6fcf810"  -- LegsPadded01_m07_C3 (pikowane)
              .. ",00b7ed62-a7bd-4269-acfa-8d852366579b"  -- GambesonShort01_m04_D2
              .. ",0b383bf7-a67b-4caa-9db8-501ed8d6aa9f"  -- CoifMail02_mPrague_B3
              .. ",0364c89d-ac13-44ef-94d5-22b4047e7a26"  -- MailShort01_m03_C4
              .. ",a8723887-ac6e-45a0-a6a4-0cf905716b6d"  -- Brigandine05_m04_C3 (silesian body)
              .. ",dcc178b9-ed1c-41c4-b2e7-ebda930e8af9"  -- BrigandineArm05_m11_B4 (silesian)
              .. ",2dd6ea92-4024-4113-97ed-6a23f19b39d9"  -- Gauntlets08_m01_B4
              .. ",1972ac07-f8e1-41f0-9fb4-cf115b0088ec"  -- LegsPlate03_m03_A5
              .. ",96841ac9-4cdc-41e7-a84e-d212389a0d71"  -- BascinetVisorScaring_m01_closed
              .. ",00cca9e3-8ef2-46db-8cbf-86ec51930919", -- longSwordDuel (inventory)
        preset = "dc000002-0000-0000-0000-000000000000",
    },
}

-- ===== WO-20 — deterministic face roster (guidSharedSoulId) =====
--
-- The appearance lever -- binding a spawned NPC's guidSharedSoulId spawn
-- property to a real soul's SharedSoulGuid, which makes the engine build a
-- full distinct head+body+hair+beard automatically -- is Jefferson25625's
-- find (AppearanceApi.md, github.com/DeepFriedDepp/kcd2-exports fork, used
-- with permission). Confirmed live against this project's own build
-- (docs/WO-20-faces.md), not trusted from their doc.
--
-- Their own soul_roster.lua (the actual 48-soul GUID list) was never
-- committed to the repo -- prose only, same pattern WO-18 found for their
-- whole C# stack. So this roster is our own: real, hand-placed souls pulled
-- live from this save's own SoulsByName and spread across settlements for
-- visual variety. SharedSoulGuid is the authored, cross-session-stable key
-- (NATIVE-PLUGIN-findings.md), so these values hold regardless of which save
-- or session picks them.
--
-- WO-34: it was 48 (24 male, 24 female) and it is now 43 (19 male, 24
-- female). Five of the male entries were NOT commoners -- tbuk_man_5,
-- tkop_man_1, tkop_man_2, tzda_man_6 and tzda_man_9 were bandits, and are
-- gone. Read off the shipped tables, not inferred:
--
--   soul__tkop.xml   factionName = trosecko_enemies_bandits_campKopanina
--                    social_class_id = 38  voice_group_name = Bandits
--   social_class.xml 38 -> social_class_name "bandit", soul_crime_role_id 3
--   soul_crime_role  3  -> "renegade"
--   FactionTree.xml  ancestor trosecko_enemies carries Labels="publicEnemy"
--                    and reputation="-1" toward every trosecko settlement,
--                    outskirt, miller and ally faction
--   text_ui_soul.xml soul_ui_name_ruffian -> "Ruffian"
--
-- Until WO-22 this was harmless: the GUID was passed nested under Properties
-- and bound no soul at all, so the roster was decorative and the faction
-- never applied. WO-22 made SharedSoulGuid a real top-level parameter, which
-- turned five of these slots into genuinely hostile public enemies. Live
-- two-player report (WO-34): players hostile to each other on sight, one
-- attacked by ambient NPCs, bandit combat barks, and a corpse labelled
-- "Ruffian". KCD2MP_SpawnGhost's AI.ChangeParameter(..., "Civilians")
-- override does not defeat the soul row.
--
-- Removing rather than replacing takes the male #list from 24 to 19, and
-- KCD2MP_PickFaceForPlayer's modulus is over #list, so EVERY male player's
-- face changes with this build, not only the five. Accepted deliberately
-- (see docs/WO-34-findings.md); appearance stability across a version was
-- already broken once by WO-22 for the same underlying reason.
KCD2MP.faceRoster = {
    male = {
        {"tneb_man_11",  "43b076df-4be8-f9d9-e2e4-dd5cafd0db96"},
        {"tneb_man_18",  "4a5baae4-2667-2892-178d-b47b10e562b3"},
        {"tpod_man_1",   "4e628918-2a38-c1ea-c786-2424123506ae"},
        {"tpod_man_5",   "4f45df7c-4667-77a0-a415-d03b0cd1e293"},
        {"tsem_man_21",  "4072c96a-3bb5-f744-078c-8ef89203a49c"},
        {"tsem_man_22",  "46356c7b-ab60-1377-e8e4-514c8a8dcfbb"},
        {"tsla_man_2",   "4166b913-6b12-1965-cbb6-509a49250ba6"},
        {"ttac_man_8",   "fd1af8c5-c500-4add-b0b6-6c0505fe80c2"},
        {"ttac_man_9",   "69dfede7-a999-43dd-9dfa-5bf0c5aefe01"},
        {"ttkc_man_26",  "cfa65480-f361-4cf8-80c5-1900b7846bc8"},
        {"ttkc_man_3",   "4b4c6520-21a6-6125-d814-564837f165a2"},
        {"ttro_man_30",  "40fd3055-48be-a9f5-de48-0b882695cca5"},
        {"ttro_man_59",  "7e4881d6-ffb7-416f-bbbe-49bc622747b2"},
        {"tvez_man_20",  "2f825ed0-1d9b-4df0-ad90-d6e2b136ce04"},
        {"tvez_man_21",  "4badc882-824c-407e-b823-059fa3e5df5b"},
        {"tvid_man_3",   "48ea5c5c-fcbb-6a90-be4d-8b7f7ad6a4ac"},
        {"tvid_man_7",   "6947a43f-30eb-49bd-9997-44396f01fcba"},
        {"tzel_man_10",  "8158f557-018e-4016-95a4-024bb060bd18"},
        {"tzel_man_7",   "271ac033-a516-4928-b1f7-825bc57c46e3"},
    },
    female = {
        {"prepadeni_woman_1", "f9eeaaef-b0f7-437d-b5cc-043121267e87"},
        {"tpod_woman_3",      "cbea36af-a25c-4aa0-8ae4-d6b5a2fcc3f3"},
        {"tsem_woman_12",     "46ec6bf1-3bac-85d6-8ee7-f90b1b25a4a8"},
        {"tsem_woman_8",      "456dc2bd-1ede-2372-7ee7-fed064e80ea8"},
        {"tsem_woman_9",      "4187a4bf-c27a-dd4b-c348-7bec934968ad"},
        {"tsla_woman_1",      "4e9bdbd4-885f-b50b-3940-d9ff9a000382"},
        {"ttac_woman_3",      "48de9403-4fa6-32c3-7dd7-007ef5dc1489"},
        {"ttac_woman_4",      "49daaf6f-5119-420a-b7c6-33825b912bb3"},
        {"ttac_woman_7",      "ddf4ac93-d15d-4728-8083-16cf46f68444"},
        {"ttkc_woman_17",     "f9a94c81-d804-44ab-9d0e-9c4decefbcd0"},
        {"ttkc_woman_6",      "4763a986-8361-a712-61d9-bf6dd706ddb6"},
        {"ttkc_woman_9",      "7ac037fe-60ca-4212-a39f-0093cff270ba"},
        {"ttro_woman_10",     "ab87afbe-498c-42c3-ab3e-bef003b273be"},
        {"ttro_woman_11",     "1b21ebf4-0ccd-450e-b182-8703a01c6ff8"},
        {"ttro_woman_12",     "7759e6b2-6a88-4f30-a28f-bee35104370b"},
        {"tvez_woman_2",      "488e80ea-f98d-d0e1-8dc7-4359d4701b8d"},
        {"tvez_woman_3",      "00ec8c08-21d3-4f65-8c84-cf28958f0cde"},
        {"tvez_woman_5",      "9349eb0d-91e3-4f48-94bd-6ef73370036e"},
        {"tvid_woman_1",      "4bb85c62-b0f9-c430-27e5-2ecfd254df90"},
        {"tzda_woman_1",      "450fc04c-4a9d-a6c9-0af0-dc60678c39a9"},
        {"tzda_woman_4",      "e9cca65b-2a67-4b12-b892-673ffbcb61dc"},
        {"tzel_woman_1",      "4b80b89a-45f3-8861-ecc7-b67cc7c6f185"},
        {"tzel_woman_2",      "45032153-51cb-db4a-9ea0-69431518519a"},
        {"tzel_woman_3",      "499b3100-8025-ece1-c741-ef13d59db783"},
    },
}

-- djb2-style string hash. Pure +/*/% arithmetic, deliberately no bitwise
-- ops -- this mod's sandbox is stripped Lua 5.1, which has no bit library.
--
-- WO-20 correction, found live: this engine's embedded Lua uses 32-bit
-- FLOAT numbers, not doubles -- confirmed by probing KCD2MP_HashString with
-- a %2147483647 modulus (the obvious choice) and watching tostring(h) print
-- in scientific notation ("1.93453e+08") with the low digits already gone,
-- which then made "h % 2" parity flip unpredictably and sent every test
-- name to the same roster slot (or an out-of-range one). Float32 is only
-- exact for integers up to 2^24 (~16.7M), so every intermediate value here
-- is kept under a 65521 modulus (largest prime below 2^16) -- h*33 then
-- tops out around 2.16M, safely inside the exact range.
function KCD2MP_HashString(s)
    local h = 5381 % 65521
    for i = 1, #s do
        h = (h * 33 + string.byte(s, i)) % 65521
    end
    return h
end

-- Deterministic per-player face pick: same name key -> same soul, every
-- time, in this or any future session. Gender and the individual soul are
-- both derived from the same hash so one name always resolves to one look.
function KCD2MP_PickFaceForPlayer(nameKey)
    local h = KCD2MP_HashString(tostring(nameKey or ""))
    local isFemale = (h % 2) == 0
    local list = isFemale and KCD2MP.faceRoster.female or KCD2MP.faceRoster.male
    local idx = (math.floor(h / 2) % #list) + 1
    local pick = list[idx]
    return { className = isFemale and "NPC_Female" or "NPC", soulName = pick[1], guid = pick[2] }
end

-- Split "a,b,c" -> {"a","b","c"}, trims whitespace
local function splitCSV(s)
    local parts = {}
    for part in string.gmatch(s, "[^,]+") do
        local trimmed = part:match("^%s*(.-)%s*$")
        if trimmed and #trimmed > 0 then
            parts[#parts + 1] = trimmed
        end
    end
    return parts
end

-- Spawn NPC in front of player, add items to inventory, optionally equip via ClothingPreset.
-- items_csv    : comma-separated item GUIDs (inventory)
-- preset_guid  : ClothingPreset GUID for visual equip (must exist in clothing_preset__kdcmp.xml)
-- weapon_preset: WeaponPreset GUID (from weapon_preset.xml) - equips weapon in hand slot
function KCD2MP_SpawnArmoredNPC(items_csv, preset_guid, weapon_preset)
    if not player then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: no player")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Spawn 3m in front of player
    local ox, oy = 3, 0
    local ang = nil
    pcall(function() ang = player:GetWorldAngles() end)
    if ang then
        ox = math.sin(ang.z) * 3
        oy = math.cos(ang.z) * 3
    end
    local spawnPos = {x = pos.x + ox, y = pos.y + oy, z = pos.z}

    KCD2MP.spawnCount = (KCD2MP.spawnCount or 0) + 1
    local npcName = "kcd2mp_npc_" .. KCD2MP.spawnCount

    System.LogAlways(string.format("[KCD2-MP] SpawnArmoredNPC '%s' at %.1f,%.1f,%.1f",
        npcName, spawnPos.x, spawnPos.y, spawnPos.z))

    local npc = nil
    local ok1, e1 = pcall(function()
        npc = System.SpawnEntity({class="NPC", name=npcName, position=spawnPos})
    end)
    if not ok1 or not npc then
        System.LogAlways("[KCD2-MP] SpawnArmoredNPC: SpawnEntity failed: " .. tostring(e1))
        return
    end
    System.LogAlways("[KCD2-MP] SpawnArmoredNPC: entityId=" .. tostring(npc.id))

    -- Visually equip via ClothingPreset FIRST (may reset inventory state)
    if preset_guid and preset_guid ~= "" then
        local ok2, e2 = pcall(function()
            npc.actor:EquipClothingPreset(preset_guid)
        end)
        System.LogAlways("[KCD2-MP] EquipClothingPreset " .. preset_guid
            .. ": ok=" .. tostring(ok2)
            .. (ok2 and "" or (" err=" .. tostring(e2))))
    end

    -- Add items to inventory AFTER preset (so preset cannot wipe them)
    local guids = (items_csv and items_csv ~= "") and splitCSV(items_csv) or {}
    System.LogAlways("[KCD2-MP] Adding " .. #guids .. " items to inventory")
    for i, guid in ipairs(guids) do
        local ok, e = pcall(function()
            local item = ItemManager.CreateItem(guid, 1, 1)
            npc.inventory:AddItem(item)
        end)
        System.LogAlways(string.format("[KCD2-MP]   item[%d] %s: ok=%s%s",
            i, guid, tostring(ok), ok and "" or (" err=" .. tostring(e))))
    end

    -- Equip weapon via WeaponPreset (visual + inventory, works for swords/shields)
    if weapon_preset and weapon_preset ~= "" then
        local ok3, e3 = pcall(function()
            npc.actor:EquipWeaponPreset(weapon_preset)
        end)
        System.LogAlways("[KCD2-MP] EquipWeaponPreset " .. weapon_preset
            .. ": ok=" .. tostring(ok3)
            .. (ok3 and "" or (" err=" .. tostring(e3))))

        -- Close visor after short delay using native console command
        -- pattern from VIA mod: closeVisorOn <entityName>
        local npcNameRef = npcName
        Script.SetTimer(800, function()
            pcall(function()
                System.ExecuteCommand("closeVisorOn " .. npcNameRef)
                System.LogAlways("[KCD2-MP] closeVisorOn " .. npcNameRef)
            end)
        end)
    end

    mp_log(string.format("SpawnArmoredNPC '%s' items=%d preset=%s weapons=%s",
        npcName, #guids, tostring(preset_guid or "none"), tostring(weapon_preset or "none")))
end

-- Spawn white/red armored NPC (uses XML preset dc000003 + weapon preset kkut_menhart)
function KCD2MP_SpawnWhiteRed()
    local p = KCD2MP.armorPresets.white_red
    KCD2MP_SpawnArmoredNPC(p.items, p.preset, p.weapons)
end

-- Spawn fully armored knight (all 6 pieces, uses XML preset dc000002)
function KCD2MP_SpawnKnight()
    local p = KCD2MP.armorPresets.knight
    KCD2MP_SpawnArmoredNPC(p.items, p.preset)
end

-- ===== Horse Diagnostics =====

-- Runs in MOD context (has access to Terrain, player, etc).
-- Writes result to sv_servername so probe_riding.ps1 can read it.
function KCD2MP_DiagRideDetect()
    if not player then
        System.SetCVar("sv_servername", "player=nil")
        return
    end
    local pos = player:GetWorldPos()
    if not pos then
        System.SetCVar("sv_servername", "GetWorldPos=nil")
        return
    end

    -- Find entities within 6m - list all classes to identify the horse
    local classes = {}
    pcall(function()
        local ents = System.GetEntitiesInSphere(pos, 6.0)
        if ents then
            for _, e in ipairs(ents) do
                if e ~= player then
                    local ec = "?"
                    local ep = nil
                    pcall(function() ec = tostring(e.class or "?") end)
                    if ec == "?" then pcall(function() ec = tostring(e:GetClass()) end) end
                    pcall(function() ep = e:GetWorldPos() end)
                    local d = ep and math.sqrt((ep.x-pos.x)^2+(ep.y-pos.y)^2+(ep.z-pos.z)^2) or 99
                    if d < 6 then
                        classes[#classes+1] = string.format("%s:%.1f", ec, d)
                    end
                end
            end
        end
    end)

    local clStr = table.concat(classes, " | ")
    if clStr == "" then clStr = "none" end
    -- Trim to fit CVar (max ~200 chars)
    if #clStr > 180 then clStr = clStr:sub(1,180) end
    System.SetCVar("sv_servername", clStr)
end

-- Probe ALL riding anim candidates on any ghost currently in riding state.
-- Shows which names have GetAnimationLength > 0.
-- Also tries to get current player animation name (for when player is on horse).
function KCD2MP_ProbeRidingAnims()
    -- Find first riding ghost
    local ghost = nil
    for _, g in pairs(KCD2MP.ghosts) do
        if g.istate and g.istate.isRiding then ghost = g; break end
    end
    -- Fall back to any ghost
    if not ghost then
        for _, g in pairs(KCD2MP.ghosts) do ghost = g; break end
    end
    if not ghost or not ghost.entity then
        System.LogAlways("[KCD2-MP] ProbeRidingAnims: no ghost. Spawn one first.")
        return
    end

    System.LogAlways("[KCD2-MP] === PROBE RIDING ANIMS ===")
    local ent = ghost.entity
    local allCandidates = {}
    for _, v in ipairs(RIDING_IDLE_ANIMS)   do allCandidates[#allCandidates+1] = v end
    for _, v in ipairs(RIDING_GALLOP_ANIMS) do allCandidates[#allCandidates+1] = v end
    -- Extra patterns
    local extras = {
        "horse", "Horse", "riding", "Riding", "mounted", "Mounted",
        "3d_horse", "3d_riding", "3d_mounted",
        "horse_walk", "horse_run", "horse_idle", "horse_gallop",
        "act_horse", "act_riding", "act_mounted",
        "loco_horse", "loco_riding",
    }
    for _, v in ipairs(extras) do allCandidates[#allCandidates+1] = v end

    local hits = 0
    for _, name in ipairs(allCandidates) do
        local len = 0
        pcall(function() len = ent:GetAnimationLength(0, name) or 0 end)
        if len > 0 then
            System.LogAlways(string.format("[KCD2-MP] RIDING HIT: '%s' len=%.3f", name, len))
            hits = hits + 1
        end
    end
    System.LogAlways(string.format("[KCD2-MP] Riding anims found: %d / %d tested", hits, #allCandidates))

    -- Also try to read the current animation name from player (if riding a horse right now)
    local ok, an = pcall(function()
        if player then
            local n = nil
            pcall(function() n = player:GetCurrentAnimationName(0) end)
            return n
        end
    end)
    System.LogAlways("[KCD2-MP] Player current anim: " .. tostring(an) .. " (useful if player is on horse)")
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Find horse/animal entities near player and log their class names
function KCD2MP_FindHorses()
    if not player then System.LogAlways("[KCD2-MP] FindHorses: no player"); return end
    local ppos = player:GetWorldPos()
    System.LogAlways("[KCD2-MP] === FIND HORSES ===")

    local ok, err = pcall(function()
        local ents = System.GetEntitiesInSphere(ppos, 60)
        if not ents then System.LogAlways("[KCD2-MP] GetEntitiesInSphere returned nil"); return end

        local count = 0
        for _, ent in ipairs(ents) do
            if ent ~= player then
                local eclass = "?"
                local ename  = "?"
                pcall(function() eclass = tostring(ent.class or "?") end)
                pcall(function() ename  = tostring(ent:GetName()) end)

                -- Log anything that looks like it could be a horse or animal
                local lc = eclass:lower()
                local ln = ename:lower()
                if lc:find("horse") or lc:find("animal") or lc:find("mount") or lc:find("creature")
                   or ln:find("horse") or ln:find("roach") or ln:find("pebbles") or ln:find("animal")
                then
                    local pos = nil
                    pcall(function() pos = ent:GetWorldPos() end)
                    local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or -1
                    System.LogAlways(string.format("[KCD2-MP] HORSE? class='%s' name='%s' dist=%.1fm",
                        eclass, ename, dist))
                    count = count + 1
                end
            end
        end

        -- Also just log ALL entity classes within 15m (to catch horses with unexpected class names)
        System.LogAlways("[KCD2-MP] --- All entities within 15m ---")
        for _, ent in ipairs(ents) do
            local eclass = "?"
            local ename  = "?"
            pcall(function() eclass = tostring(ent.class or "?") end)
            pcall(function() ename  = tostring(ent:GetName()) end)
            local pos = nil
            pcall(function() pos = ent:GetWorldPos() end)
            local dist = pos and math.sqrt((pos.x-ppos.x)^2+(pos.y-ppos.y)^2) or 99
            if dist < 15 then
                System.LogAlways(string.format("[KCD2-MP]   class='%s' name='%s' dist=%.1fm",
                    eclass, ename, dist))
            end
        end
        System.LogAlways(string.format("[KCD2-MP] Horse-like entities found: %d", count))
    end)
    if not ok then System.LogAlways("[KCD2-MP] FindHorses error: " .. tostring(err)) end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Force-spawn a horse using several class name guesses to find what works in KCD2
function KCD2MP_SpawnHorseTest()
    if not player then System.LogAlways("[KCD2-MP] SpawnHorseTest: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    -- Offset 4m to the right of player
    local spawnPos = {x = pos.x + 4, y = pos.y, z = pos.z}

    local classes = {
        "Horse", "Animal", "HorseAnimal", "horse", "animal",
        "kcd_horse", "RPGHorse", "CreatureAnimal", "Creature",
    }

    System.LogAlways("[KCD2-MP] === SPAWN HORSE TEST ===")
    for _, cls in ipairs(classes) do
        local ok, ent = pcall(System.SpawnEntity, {
            class    = cls,
            position = spawnPos,
            name     = "kcd2mp_horsetest_" .. cls,
        })
        if ok and ent then
            System.LogAlways(string.format("[KCD2-MP] SUCCESS class='%s' entityId=%s", cls, tostring(ent.id)))
            -- Don't remove it - let user see which one appears in-game
        else
            System.LogAlways(string.format("[KCD2-MP] FAIL class='%s' err=%s", cls, tostring(ent)))
        end
    end
    System.LogAlways("[KCD2-MP] === END ===")
end

-- Log current riding detection state for the local player
function KCD2MP_RidingState()
    System.LogAlways("[KCD2-MP] === RIDING STATE ===")
    System.LogAlways("[KCD2-MP] KCD2MP.isRiding = " .. tostring(KCD2MP.isRiding))

    if not player then System.LogAlways("[KCD2-MP] player=nil"); return end

    -- Test method 1: human:IsRiding
    local ok1, r1 = pcall(function()
        if player.human then
            return player.human:IsRiding()
        end
        return "human=nil"
    end)
    System.LogAlways("[KCD2-MP] human:IsRiding() ok=" .. tostring(ok1) .. " val=" .. tostring(r1))

    -- Test method 2: GetLinkedParent
    local ok2, r2 = pcall(function() return player:GetLinkedParent() end)
    System.LogAlways("[KCD2-MP] GetLinkedParent() ok=" .. tostring(ok2) .. " val=" .. tostring(r2))

    -- Test method 3: soul state
    local ok3, r3 = pcall(function()
        if player.soul then return player.soul.bRiding end
        return "soul=nil"
    end)
    System.LogAlways("[KCD2-MP] soul.bRiding ok=" .. tostring(ok3) .. " val=" .. tostring(r3))

    -- Test method 4: actor mount
    local ok4, r4 = pcall(function()
        if player.actor then return player.actor:GetMount() end
        return "actor=nil"
    end)
    System.LogAlways("[KCD2-MP] actor:GetMount() ok=" .. tostring(ok4) .. " val=" .. tostring(r4))

    System.LogAlways("[KCD2-MP] === END ===")
end

function KCD2MP_GhostState()
    System.LogAlways("[KCD2-MP] === GHOST STATE ===")
    local count = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        count = count + 1
        local istate = ghost.istate or {}
        local horseData = KCD2MP.horseGhosts[id]
        System.LogAlways(string.format(
            "[KCD2-MP] Ghost id=%s isRiding=%s nativeMounted=%s ridingFallback=%s hasHorse=%s",
            tostring(id),
            tostring(istate.isRiding),
            tostring(istate.nativeMounted),
            tostring(istate.ridingFallback),
            tostring(horseData ~= nil)
        ))
        -- Check if NPC has .human and if IsMounted works
        if ghost.entity then
            local ok, mounted = pcall(function() return ghost.human and ghost.human:IsMounted() end)
            System.LogAlways("[KCD2-MP]   IsMounted ok=" .. tostring(ok) .. " val=" .. tostring(mounted))
            -- Check if horse entity exists
            if horseData and horseData.entity then
                local ok2, hasRider = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:HasRider()
                end)
                local ok3, isMountable = pcall(function()
                    return horseData.entity.horse and horseData.entity.horse:IsMountable()
                end)
                System.LogAlways("[KCD2-MP]   horse.HasRider ok=" .. tostring(ok2) .. " val=" .. tostring(hasRider))
                System.LogAlways("[KCD2-MP]   horse.IsMountable ok=" .. tostring(ok3) .. " val=" .. tostring(isMountable))
            end
        end
    end
    System.LogAlways("[KCD2-MP] Total ghosts=" .. count .. " horseGhosts=" .. (function()
        local n=0; for _ in pairs(KCD2MP.horseGhosts) do n=n+1 end; return n
    end)())
end

-- ===== WO-38 Phase 7: ghost stimulus-deafness probe =====
-- Section B.1: a ghost's soul-assigned voice set fires real combat-distress
-- barks ("HELP! GET ME OUT OF HERE") that never stop -- plausibly because the
-- distress behaviour wants the body to flee and the interp tick pins it in
-- place, so the state never resolves. AI.SetIgnorant(entityId, 0|1) is
-- REGISTERED on this build (WO-32 s1f: "ignore system signals, visual and
-- sound stimuli") and is the obvious lever -- but it might also stop the
-- ghost being a valid combat TARGET, which would silently regress the
-- always-on reactive combat WO-26/27 shipped. So it ships as a toggle for a
-- live A/B, not as a default: turn it on, start a fight near a ghost, and
-- check (a) the barks stop and (b) NPCs still attack the ghost.
-- Usage: mp_ghost_ignorant on|off
function KCD2MP_SetGhostsIgnorant(arg)
    local s = tostring(arg or ""):lower()
    local on
    if s:find("on") then on = 1
    elseif s:find("off") then on = 0
    else
        System.LogAlways("[KCD2-MP] mp_ghost_ignorant: expected on|off")
        return
    end
    KCD2MP.ghostsIgnorant = (on == 1)
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            local ok, err = pcall(function() AI.SetIgnorant(ghost.entity.id, on) end)
            System.LogAlways(string.format("[KCD2-MP] SetIgnorant(%s, %d) ok=%s err=%s",
                tostring(id), on, tostring(ok), tostring(err)))
            n = n + 1
        end
    end
    System.LogAlways("[KCD2-MP] mp_ghost_ignorant " .. s .. " applied to " .. n .. " ghost(s)"
        .. " -- new spawns " .. (KCD2MP.ghostsIgnorant and "WILL" or "will NOT") .. " get it")
end

-- ===== WO-40 Phase 9: hostility remediation + faction-bind probe =====
-- The footage's pickpocket incident left PB's ghost persistently hostile to
-- PA (aggro indicator + forced combat stance long after). Ignorant-by-default
-- prevents NEW incidents; this clears an already-aggroed ghost, and reports
-- the registration state of the per-pair hostility binds the retail-1.5 dump
-- says exist (AI.GetFactionOf was previously dismissed on a guessed
-- signature -- project memory corrected this WO).
function KCD2MP_GhostCalm()
    System.LogAlways("[KCD2-MP] AI.GetFactionOf="            .. tostring(AI and type(AI.GetFactionOf)))
    System.LogAlways("[KCD2-MP] AI.SetFactionOf="            .. tostring(AI and type(AI.SetFactionOf)))
    System.LogAlways("[KCD2-MP] AI.AddPersonallyHostile="    .. tostring(AI and type(AI.AddPersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.RemovePersonallyHostile=" .. tostring(AI and type(AI.RemovePersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.IsPersonallyHostile="     .. tostring(AI and type(AI.IsPersonallyHostile)))
    System.LogAlways("[KCD2-MP] AI.ResetPersonallyHostiles=" .. tostring(AI and type(AI.ResetPersonallyHostiles)))
    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            n = n + 1
            if AI and type(AI.IsPersonallyHostile) == "function" and player then
                local ok, hostile = pcall(function() return AI.IsPersonallyHostile(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s IsPersonallyHostile(player) ok=%s -> %s",
                    tostring(id), tostring(ok), tostring(hostile)))
            end
            -- Live-verified 2026-08-20: the engine's own parameter-check
            -- error revealed the real signature -- ResetPersonallyHostiles
            -- (entityID, hostileID), two args like Remove. Both called
            -- pairwise against the local player.
            if AI and type(AI.ResetPersonallyHostiles) == "function" and player then
                local ok, err = pcall(function() return AI.ResetPersonallyHostiles(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s ResetPersonallyHostiles(player) ok=%s err=%s",
                    tostring(id), tostring(ok), tostring(err)))
            end
            if AI and type(AI.RemovePersonallyHostile) == "function" and player then
                local ok, err = pcall(function() return AI.RemovePersonallyHostile(ghost.entity.id, player.id) end)
                System.LogAlways(string.format("[KCD2-MP] ghost %s RemovePersonallyHostile(player) ok=%s err=%s",
                    tostring(id), tostring(ok), tostring(err)))
            end
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no ghosts to calm") end
end

-- ===== WO-38 Phase 8: map marker probe =====
-- The shipped scriptbind docs document GameRules.AddMinimapEntity(entityId,
-- type, lifetime) / RemoveMinimapEntity(entityId) -- exactly the shape a
-- "show connected players on the map" feature needs, because each ghost is
-- already a real local entity whose position the mod keeps synced; marking
-- the ENTITY means the map marker moves for free. But this is a Crysis-era
-- GameRules bind against KCD2's custom Warhorse map UI, and this project has
-- already met documented-but-unregistered binds (Actor.SetAIBrainId, WO-32)
-- and registered-but-inert ones (most AI writes). So the feature ships as a
-- PROBE first: run `mp_map_marker <type>` live with a ghost present, open
-- the map, and see. If a type value renders, wiring it into SpawnGhost is a
-- three-line follow-up.
-- Usage: mp_map_marker <typeInt>   (tries that icon type on every ghost)
--        mp_map_marker sweep       (tries types 0..15, one per ghost re-add)
function KCD2MP_ProbeMapMarker(arg)
    local hasBind = (GameRules ~= nil) and (type(GameRules.AddMinimapEntity) == "function")
    System.LogAlways("[KCD2-MP] MapMarker probe: GameRules.AddMinimapEntity registered=" .. tostring(hasBind))
    if not hasBind then return end

    local types = {}
    if tostring(arg or ""):lower() == "sweep" then
        for t = 0, 15 do types[#types+1] = t end
    else
        types[1] = tonumber(arg) or 1
    end

    local n = 0
    for id, ghost in pairs(KCD2MP.ghosts) do
        if ghost.entity then
            for _, t in ipairs(types) do
                local ok, err = pcall(function()
                    GameRules.AddMinimapEntity(ghost.entity.id, t, 0)
                end)
                System.LogAlways(string.format("[KCD2-MP] MapMarker ghost=%s type=%d ok=%s err=%s",
                    tostring(id), t, tostring(ok), tostring(err)))
            end
            n = n + 1
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] MapMarker probe: no ghosts to mark -- connect a peer first") end
end

-- Test spawning entities via XGenAIModule with various class names.
-- Safe: each class wrapped in pcall, entity removed after 10s.
-- Usage: mp_test_xgen <ClassName>  (default: NullAI)
function KCD2MP_TestXGenSpawn(className)
    if not player then System.LogAlways("[KCD2-MP] TestXGenSpawn: no player"); return end
    local pos = player:GetWorldPos()
    if not pos then return end

    className = (className and className ~= "") and className or "NullAI"
    local testName = "kcd2mp_xgen_test"
    System.LogAlways("[KCD2-MP] TestXGenSpawn: trying ClassName=" .. className)

    -- Remove previous test entity if exists
    pcall(function()
        local old = System.GetEntityByName(testName)
        if old then System.RemoveEntity(old.id) end
    end)

    -- Try XGenAIModule.SpawnEntity
    local ok, err = pcall(function()
        local eid = XGenAIModule.SpawnEntity{
            Name      = testName,
            ClassName = className,
            Pos       = {pos.x + 2, pos.y, pos.z},
            Properties = { esFaction = "Civilians" },
        }
        System.LogAlways("[KCD2-MP] TestXGenSpawn: XGenAI returned eid=" .. tostring(eid))
        local ent = System.GetEntityByName(testName)
        if ent then
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity found id=" .. tostring(ent.id)
                .. " class=" .. tostring(ent.class))
            -- Check human/actor/horse sub-objects
            local hasSoul   = pcall(function() return ent.soul end)
            local hasHuman  = pcall(function() return ent.human end)
            local isMounted = pcall(function() return ent.human and ent.human:IsMounted() end)
            System.LogAlways("[KCD2-MP] TestXGenSpawn: hasSoul=" .. tostring(hasSoul)
                .. " hasHuman=" .. tostring(hasHuman)
                .. " IsMounted=" .. tostring(isMounted))
            -- Remove after 10s
            local eid2 = ent.id
            Script.SetTimer(10000, function()
                pcall(function() System.RemoveEntity(eid2) end)
                System.LogAlways("[KCD2-MP] TestXGenSpawn: removed test entity")
            end)
        else
            System.LogAlways("[KCD2-MP] TestXGenSpawn: entity NOT found by name after spawn")
        end
    end)
    if not ok then
        System.LogAlways("[KCD2-MP] TestXGenSpawn: CRASHED/ERROR: " .. tostring(err))
    end
end

-- ===== Dropped-item sync (WO-48) =====
--
-- A player deliberately drops an item; peers see it appear, and whoever picks
-- it up first gets it -- for everyone. TRANSACTIONAL (the time-skip shape):
-- a drop broadcasts once, sits inert, and resolves on the first claim the
-- relay echoes back. No continuous stream, no authority to hand off. Chests
-- and NPC pockets are deliberately NOT synced (independent loot pools).
--
-- The reachable surface, all live-verified in WO-48 Phase 1:
--   detect:      new PickableItem entity near the player (GetEntitiesInSphere)
--                + that class's inventory count DECREASED since last tick --
--                both halves required, which is what filters out world items
--                streaming in and NPCs dropping things nearby.
--   identity:    Properties.sItemClassId (the WO-9 ItemClass GUID) + nAmount
--                + fHealth read straight off the ground entity. The dropId
--                itself is minted by the agent (random uint32) and handled as
--                a STRING here -- this Lua's floats corrupt integers > 2^24.
--   spawn:       inventory:CreateItem on a ghost + ghost.human:PlaceItem to a
--                throwaway anchor entity at the drop position. Placing while
--                the player was 60 m away dropped the item through unstreamed
--                ground (observed: z -217), so pending drops only materialize
--                inside materializeRadius.
--   pickup:      the tracked ground entity vanishing WITHOUT this mod having
--                removed it = something in this world took it. Removal by the
--                mod flags removedByUs first (the damage layer's loop-
--                prevention idiom, local state, never on the wire).
KCD2MP.itemSync = {
    enabled           = true,  -- mp_item_sync on|off (the mp_npc_sync default-on precedent)
    scanMs            = 750,   -- one tick: detector + materializer + watcher
    dropRadius        = 8,     -- metres: new-pickable detection around the player
    materializeRadius = 70,    -- metres: spawn a pending drop only this near
    watchRadius       = 80,    -- metres: existence checks only trusted this near
    maxTracked        = 32,    -- hard cap on live tracked drops
}
KCD2MP.itemSyncRunning  = false
KCD2MP._itemSyncAliveAt = nil
KCD2MP._itemRestartSweep = false
-- dropIdStr -> {cls, amount, health, x, y, z, src, mine, state, entName,
--               wuid, removedByUs, pendingRemove, placeTries}
-- state machine: pending -> placing -> ground -> resolved | claimed_local -> resolved
KCD2MP.itemDrops     = {}
KCD2MP._itemSeen     = {}   -- tostring(entity.id) -> true, pickables accounted for
KCD2MP._itemInvCounts = nil -- classGuidStr -> total amount, from last tick

local function mp_item_inv_counts()
    local counts = nil
    pcall(function()
        local t = player.inventory:GetInventoryTable()
        local c = {}
        for i = 1, #t do
            local it = ItemManager.GetItem(t[i])
            if it and it.class then c[it.class] = (c[it.class] or 0) + (it.amount or 1) end
        end
        counts = c
    end)
    return counts
end

local function mp_item_tracked_count()
    local n = 0
    for _, d in pairs(KCD2MP.itemDrops) do
        if d.state ~= "resolved" then n = n + 1 end
    end
    return n
end

-- Reload discriminator for the restart sweep. Any timer gap > 1 s lands in
-- KCD2MP_StartItemSync's restart path, but a menu gap and a save load need
-- opposite handling: a menu leaves the world intact (and the player can drop
-- items from the inventory screen DURING it, which must still be detected on
-- resume), while a reload replaces every runtime entity and rewinds the
-- inventory (which would fake both halves of the detector's gate). A healthy
-- ghost entity proves no reload happened; a stale one proves it did. With no
-- ghost to judge by, assume menu -- with no peers connected a wrong guess
-- has nobody to mislead.
local function mp_item_world_reloaded()
    for _, g in pairs(KCD2MP.ghosts or {}) do
        if g.entity then
            local alive = false
            pcall(function() alive = System.GetEntityByName(g.entity:GetName()) ~= nil end)
            return not alive
        end
    end
    return false
end

local function mp_item_detect(pp)
    local counts = mp_item_inv_counts()
    local prev = KCD2MP._itemInvCounts
    if counts then KCD2MP._itemInvCounts = counts end
    local ents = System.GetEntitiesInSphere(pp, KCD2MP.itemSync.dropRadius) or {}
    for _, e in ipairs(ents) do
        if e.class == "PickableItem" then
            local key = tostring(e.id)
            if not KCD2MP._itemSeen[key] then
                KCD2MP._itemSeen[key] = true
                -- prev == nil is the baseline tick (fresh start or post-reload
                -- resweep): account for everything, emit for nothing.
                if prev and counts and mp_item_tracked_count() < KCD2MP.itemSync.maxTracked then
                    local cls, amt, hp, nm
                    pcall(function()
                        cls = e.Properties and e.Properties.sItemClassId
                        amt = (e.Properties and e.Properties.nAmount) or 1
                        hp  = (e.Properties and e.Properties.fHealth) or 1
                        nm  = e:GetName()
                    end)
                    if cls and nm and nm ~= "" and (prev[cls] or 0) > (counts[cls] or 0) then
                        local ok, ep = pcall(function() return e:GetWorldPos() end)
                        if ok and ep then
                            KCD2MP_EmitEvent("item_drop", string.format("%s %d %.4f %.3f %.3f %.3f %s",
                                cls, amt, hp, ep.x, ep.y, ep.z, nm))
                            mp_log("ITEM-SYNC local drop detected: " .. cls .. " x" .. amt .. " (" .. nm .. ")")
                        end
                    end
                end
            end
        end
    end
end

-- The agent minted a dropId for the drop this world just detected; from here
-- the local ground entity is tracked so its pickup (by us or by a peer's
-- claim) resolves like any other synced drop.
function KCD2MP_ItemDropRegistered(dropId, entName)
    local key = tostring(dropId)
    if KCD2MP.itemDrops[key] then return end
    local d = { mine = true, state = "ground", entName = tostring(entName) }
    pcall(function()
        local e = System.GetEntityByName(d.entName)
        if e then
            local p = e:GetWorldPos()
            d.x, d.y, d.z = p.x, p.y, p.z
            d.cls    = e.Properties and e.Properties.sItemClassId
            d.amount = (e.Properties and e.Properties.nAmount) or 1
            d.wuid   = e.item and e.item:GetId() or nil
        end
    end)
    KCD2MP.itemDrops[key] = d
    mp_log("ITEM-SYNC drop " .. key .. " registered -> " .. d.entName)
end

-- A peer dropped an item (ItemDropDown via the agent). Held pending until the
-- local player is near enough to materialize it safely. Heartbeats repeat
-- this call for late joiners; the dropId dedupe makes them free.
function KCD2MP_ItemDropAdd(dropId, cls, amount, health, x, y, z, srcGhostId)
    local key = tostring(dropId)
    if KCD2MP.itemDrops[key] then return end
    if mp_item_tracked_count() >= KCD2MP.itemSync.maxTracked then return end
    cls = tostring(cls or "")
    if not cls:match("^[0-9a-fA-F%-]+$") then return end
    KCD2MP.itemDrops[key] = {
        cls = cls, amount = tonumber(amount) or 1, health = tonumber(health) or 1,
        x = tonumber(x), y = tonumber(y), z = tonumber(z),
        src = tostring(srcGhostId), mine = false, state = "pending",
    }
    mp_log("ITEM-SYNC drop " .. key .. " pending: " .. cls .. " x" .. tostring(amount))
end

-- Spawn one pending drop: throwaway PickableItem shell as the position
-- anchor, the item created in a ghost's inventory (never the player's -- a
-- failure must not leave a stray item where a save could keep it), placed by
-- that ghost's human. The engine mints the real bound pickup entity; it is
-- located on the NEXT tick because entity creation and removal were both
-- observed to be deferred by a frame.
local function mp_item_spawn(key, d)
    local g = KCD2MP.ghosts[d.src] or KCD2MP.ghosts[tonumber(d.src) or -1]
    local ge = g and g.entity
    if not (ge and ge.inventory and ge.human) then
        for _, g2 in pairs(KCD2MP.ghosts) do
            if g2.entity and g2.entity.inventory and g2.entity.human then ge = g2.entity break end
        end
    end
    if not (ge and ge.inventory and ge.human) then
        if not d.warnedNoGhost then
            d.warnedNoGhost = true
            mp_log("ITEM-SYNC drop " .. key .. " waiting: no ghost entity to place through")
        end
        return
    end

    local anchorName = "kcd2mp_ianchor_" .. key
    local anchor = nil
    pcall(function()
        System.SpawnEntity{ class = "PickableItem", name = anchorName,
                            position = {x = d.x, y = d.y, z = d.z}, properties = {} }
        anchor = System.GetEntityByName(anchorName)
    end)
    if not anchor then return end
    KCD2MP._itemSeen[tostring(anchor.id)] = true

    -- Snapshot the pickables already at the drop spot BEFORE placing: the
    -- finalize pass identifies the engine-minted entity as "matching class,
    -- not in this snapshot". It cannot use the detector's seen-set for that
    -- -- the detector runs first in the same tick and will have marked the
    -- new entity seen before finalize ever looks (found live: every
    -- materialize failed with 'placed entity never appeared').
    d.preIds = {}
    pcall(function()
        local pre = System.GetEntitiesInSphere({x = d.x, y = d.y, z = d.z}, 3) or {}
        for _, e in ipairs(pre) do d.preIds[tostring(e.id)] = true end
    end)

    local created = nil
    pcall(function()
        local before = {}
        local bt = ge.inventory:GetInventoryTable()
        for i = 1, #bt do before[tostring(bt[i])] = true end
        ge.inventory:CreateItem(d.cls, d.health, d.amount)
        local at = ge.inventory:GetInventoryTable()
        for i = 1, #at do
            if not before[tostring(at[i])] then created = at[i] end
        end
    end)
    if not created then
        pcall(function() System.RemoveEntity(anchor.id) end)
        d.state = "resolved"
        mp_log("ITEM-SYNC drop " .. key .. " FAILED: CreateItem bound nothing for " .. d.cls)
        return
    end

    local okPlace = false
    pcall(function() ge.human:PlaceItem(created, anchor.id, false); okPlace = true end)
    if not okPlace then
        pcall(function() ge.inventory:DeleteItem(created, d.amount) end)
        pcall(function() System.RemoveEntity(anchor.id) end)
        d.state = "resolved"
        mp_log("ITEM-SYNC drop " .. key .. " FAILED: PlaceItem errored")
        return
    end
    d.anchorName = anchorName
    d.placeTries = 0
    d.state = "placing"
end

-- Second half of the spawn, one tick later: find the entity the engine
-- minted (same class, at the anchor, not yet accounted for), adopt it, and
-- only then discard the anchor.
local function mp_item_finalize(key, d)
    local placed = nil
    pcall(function()
        local ents = System.GetEntitiesInSphere({x = d.x, y = d.y, z = d.z}, 3) or {}
        for _, e in ipairs(ents) do
            if e.class == "PickableItem"
               and e.Properties and e.Properties.sItemClassId == d.cls
               and e:GetName() ~= d.anchorName
               and not (d.preIds and d.preIds[tostring(e.id)]) then
                placed = e
                break
            end
        end
    end)
    if placed then
        KCD2MP._itemSeen[tostring(placed.id)] = true
        d.entName = placed:GetName()
        pcall(function() d.wuid = placed.item and placed.item:GetId() or nil end)
        pcall(function()
            local a = System.GetEntityByName(d.anchorName)
            if a then System.RemoveEntity(a.id) end
        end)
        if d.pendingRemove then
            -- claimed while mid-spawn: it was never really here
            d.removedByUs = true
            pcall(function() System.RemoveEntity(placed.id) end)
            d.state = "resolved"
        else
            d.state = "ground"
            mp_log("ITEM-SYNC drop " .. key .. " materialized -> " .. d.entName)
        end
        return
    end
    d.placeTries = (d.placeTries or 0) + 1
    if d.placeTries >= 4 then
        pcall(function()
            local a = System.GetEntityByName(d.anchorName)
            if a then System.RemoveEntity(a.id) end
        end)
        d.state = "resolved"
        mp_log("ITEM-SYNC drop " .. key .. " FAILED: placed entity never appeared")
    end
end

local function mp_item_materialize(pp)
    local r2 = KCD2MP.itemSync.materializeRadius * KCD2MP.itemSync.materializeRadius
    for key, d in pairs(KCD2MP.itemDrops) do
        if d.state == "placing" then
            mp_item_finalize(key, d)
        elseif d.state == "pending" and not d.pendingRemove and d.x then
            local dx, dy = d.x - pp.x, d.y - pp.y
            if dx * dx + dy * dy <= r2 then mp_item_spawn(key, d) end
        end
    end
end

local function mp_item_watch(pp)
    local r2 = KCD2MP.itemSync.watchRadius * KCD2MP.itemSync.watchRadius
    for key, d in pairs(KCD2MP.itemDrops) do
        if d.state == "ground" and not d.removedByUs and d.entName then
            local dx, dy = (d.x or pp.x) - pp.x, (d.y or pp.y) - pp.y
            if dx * dx + dy * dy <= r2 then
                local e = System.GetEntityByName(d.entName)
                if not e then
                    d.state = "claimed_local"
                    KCD2MP_EmitEvent("item_claim", key)
                    mp_log("ITEM-SYNC drop " .. key .. " taken locally -> claim sent")
                end
            end
        end
    end
end

-- The relay's claim echo (ItemClaimDown via the agent) -- the ONLY thing that
-- resolves a drop, including our own pickups. First echo wins; repeats and
-- unknown dropIds fall through the guards.
function KCD2MP_ItemDropClaimed(dropId, claimer, isMine)
    local key = tostring(dropId)
    local d = KCD2MP.itemDrops[key]
    if not d or d.state == "resolved" then return end

    if d.state == "claimed_local" then
        if isMine then
            d.state = "resolved"   -- confirmed: the item stays picked up
        else
            -- lost the race: the pickup that landed here must be undone
            d.state = "resolved"
            if d.wuid then
                local ok = pcall(function() player.inventory:DeleteItem(d.wuid, d.amount or 1) end)
                mp_log("ITEM-SYNC drop " .. key .. " lost race, rollback ok=" .. tostring(ok))
            end
            pcall(function() KCD2MP_ShowInteractionMsg("Too slow -- someone already took that") end)
        end
        return
    end

    if d.state == "placing" then
        d.pendingRemove = true   -- mp_item_finalize removes it once it appears
        return
    end

    -- pending (never spawned here) or ground (still lying here): remove ours
    d.removedByUs = true
    if d.entName then
        pcall(function()
            local e = System.GetEntityByName(d.entName)
            if e then System.RemoveEntity(e.id) end
        end)
    end
    d.state = "resolved"
end

function KCD2MP_ItemSyncTick()
    if not KCD2MP.itemSyncRunning then return end
    Script.SetTimer(KCD2MP.itemSync.scanMs, KCD2MP_ItemSyncTick)  -- reschedule FIRST
    KCD2MP._itemSyncAliveAt = os.clock()
    if not KCD2MP.itemSync.enabled then return end
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end

    if KCD2MP._itemRestartSweep then
        KCD2MP._itemRestartSweep = false
        if mp_item_world_reloaded() then
            -- A save load replaced every runtime entity and rewound the
            -- inventory. Re-baseline the detector (or the rewound counts +
            -- new entity ids would fake a drop), and resweep the tracked set:
            -- our own vanished drop means the reload returned it to this
            -- world's save state -- claim it back so peers converge on that.
            -- A vanished materialized copy just needs re-materializing.
            KCD2MP._itemInvCounts = nil
            KCD2MP._itemSeen = {}
            for key, d in pairs(KCD2MP.itemDrops) do
                if (d.state == "ground" or d.state == "placing") and d.entName then
                    local e = System.GetEntityByName(d.entName)
                    if e then
                        KCD2MP._itemSeen[tostring(e.id)] = true
                    elseif d.mine then
                        d.state = "claimed_local"
                        KCD2MP_EmitEvent("item_claim", key)
                        mp_log("ITEM-SYNC drop " .. key .. " reclaimed after reload")
                    else
                        d.entName, d.wuid, d.anchorName = nil, nil, nil
                        d.state = "pending"
                        mp_log("ITEM-SYNC drop " .. key .. " back to pending after reload")
                    end
                end
            end
            mp_log("ITEM-SYNC restart sweep: reload detected, re-baselined")
        end
        -- else: a menu/pause gap -- the world is intact, prev counts are
        -- still valid, and a drop made INSIDE the inventory screen is about
        -- to be detected by the ordinary tick below.
    end

    pcall(mp_item_detect, pp)
    pcall(mp_item_materialize, pp)
    pcall(mp_item_watch, pp)
end

function KCD2MP_StartItemSync()
    if tickAlive(KCD2MP.itemSyncRunning, KCD2MP._itemSyncAliveAt) then return end
    KCD2MP.itemSyncRunning = true
    KCD2MP._itemSyncAliveAt = os.clock()
    KCD2MP._itemRestartSweep = true
    mp_log("ITEM-SYNC tick started (" .. KCD2MP.itemSync.scanMs .. "ms)")
    Script.SetTimer(KCD2MP.itemSync.scanMs, KCD2MP_ItemSyncTick)
end

function KCD2MP_EnableItemSync(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.itemSync.enabled = true
    elseif s:find("off") then KCD2MP.itemSync.enabled = false
    else
        mp_log("mp_item_sync: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    if KCD2MP.itemSync.enabled then
        KCD2MP._itemInvCounts = nil   -- re-baseline; stale counts would fake a drop
        KCD2MP_StartItemSync()
    end
    mp_log("ITEM-SYNC " .. (KCD2MP.itemSync.enabled and "ENABLED" or "disabled"))
    pcall(function() KCD2MP_ShowInteractionMsg("Item sync: " .. (KCD2MP.itemSync.enabled and "ON" or "OFF")) end)
    return true
end

-- ===== Register Console Commands =====

local ok, err = pcall(function()
    System.AddCCommand("mp_pos",         "KCD2MP_GetPos()",         "Get player position")
    System.AddCCommand("mp_start",       "KCD2MP_Start()",          "Start MP sync")
    System.AddCCommand("mp_stop",        "KCD2MP_Stop()",           "Stop MP sync")
    System.AddCCommand("mp_spawn_test",  "KCD2MP_SpawnTest()",      "Spawn test ghost")
    System.AddCCommand("mp_remove_all",  "KCD2MP_RemoveAllGhosts()","Remove all ghosts")
    System.AddCCommand("mp_inspect",     "KCD2MP_InspectGhost()",   "Inspect ghost interp state")
    System.AddCCommand("mp_find_npcs",   "KCD2MP_FindNPCs()",       "Find nearby human NPCs")
    System.AddCCommand("mp_map_marker",  'KCD2MP_ProbeMapMarker("%LINE")', "WO-38: probe GameRules.AddMinimapEntity on ghosts (arg: type int, or 'sweep')")
    System.AddCCommand("mp_ghost_ignorant", 'KCD2MP_SetGhostsIgnorant("%LINE")', "WO-38/40: AI.SetIgnorant on all ghosts -- DEFAULT ON since WO-40 (pickpocket aggro): on|off")
    System.AddCCommand("mp_ghost_calm",  "KCD2MP_GhostCalm()", "WO-40: probe faction/hostility binds and clear per-pair hostility on every ghost")
    System.AddCCommand("mp_probe_anims",   "KCD2MP_ProbeAnims()",    "Probe anim names on ghost (GetAnimationLength)")
    System.AddCCommand("mp_copy_npc",     "KCD2MP_CopyNPCModel()",  "Find human NPC, copy CDF to ghost, probe anims")
    System.AddCCommand("mp_scan_anims",   "KCD2MP_ScanAnims()",     "Scan animation directories")
    System.AddCCommand("mp_test_ai_nav",  "KCD2MP_TestAINav()",     "Test AI.SetForcedNavigation on ghost")
    System.AddCCommand("mp_read_adb",     "KCD2MP_ReadADB()",       "Read kcd_male_database.adb via CryEngine XML loader")
    System.AddCCommand("mp_probe_tags",   "KCD2MP_ProbeAnimTags()", "Probe Mannequin animation tags on ghost")
    System.AddCCommand("mp_test_run",     "KCD2MP_TestRunAnim()",   "Test 3d_relaxed_run_turn_strafe on ghost")
    System.AddCCommand("mp_terrain",      "KCD2MP_TerrainCheck()",  "Check player/ghost vs terrain height")
    System.AddCCommand("mp_probe_stance", "KCD2MP_ProbeStance()",   "Log player stance value (for crouch detection calibration)")
    System.AddCCommand("mp_sneak_on",     "KCD2MP.playerSneaking=true;System.LogAlways('[KCD2-MP] SNEAK ON (manual)')",  "Force ghost into sneak mode")
    System.AddCCommand("mp_sneak_off",    "KCD2MP.playerSneaking=false;System.LogAlways('[KCD2-MP] SNEAK OFF (manual)')", "Force ghost out of sneak mode")
    -- mp_spawn_armor <guid1,guid2,...>  -- inventory only (no visual unless preset given as 2nd arg)
    System.AddCCommand("mp_spawn_armor",  'KCD2MP_SpawnArmoredNPC("%LINE")',  "Spawn NPC with items: mp_spawn_armor guid1,guid2,...")
    System.AddCCommand("mp_spawn_knight",    "KCD2MP_SpawnKnight()",    "Spawn fully armored knight (BascinetVisor04+Cuirass07+Gauntlets08+LegsPlate03+MailLong01)")
    System.AddCCommand("mp_spawn_white_red", "KCD2MP_SpawnWhiteRed()", "Spawn white/red armored NPC (Brigandine10+BascinetVisor05+sword)")
    System.AddCCommand("mp_scan_horse",      "KCD2MP_ScanNearbyHorse()", "Scan real horse NPC within 20m: anims, AI fns, horse.horse API")
    System.AddCCommand("mp_find_horses",     "KCD2MP_FindHorses()",     "Find horse entities near player - shows class names")
    System.AddCCommand("mp_spawn_horse_test","KCD2MP_SpawnHorseTest()", "Force-spawn a horse at player position (class probe)")
    System.AddCCommand("mp_riding_state",    "KCD2MP_RidingState()",    "Log current riding detection state")
    System.AddCCommand("mp_emit_on",         "KCD2MP_StartEmitter()",   "Start [KCD2-MP-DATA] state emitter (WO-1 log transport)")
    System.AddCCommand("mp_emit_off",        "KCD2MP_StopEmitter()",    "Stop the state emitter")
    System.AddCCommand("mp_emit_once",       "KCD2MP_EmitState()",      "Emit a single state line")
    System.AddCCommand("mp_accept",          "KCD2MP_AcceptInvite()",   "Accept a pending interaction invite")
    System.AddCCommand("mp_decline",         "KCD2MP_DeclineInvite()",  "Decline a pending interaction invite")
    System.AddCCommand("mp_sync_appearance", "KCD2MP_SyncAppearance()", "Force an immediate appearance resync to peers (WO-9)")
    System.AddCCommand("mp_slow_time",       "KCD2MP_SlowTime()",       "Toggle manually broadcasting a paused/unavailable state to peers (WO-11 fallback)")
    System.AddCCommand("mp_invite",          'KCD2MP_InviteNearest("%LINE")', "Invite the nearest player: mp_invite dice|duel")
    System.AddCCommand("mp_ghost_state",     "KCD2MP_GhostState()",     "Dump all ghost riding/mount state")
    System.AddCCommand("mp_horse_adopt",     'KCD2MP_SetHorseAdopt("%LINE")', "WO-40: adopt real world horses for ghosts (default on). off = proxy horses only -- use if the game crashes when a peer mounts")
    System.AddCCommand("mp_weather",         'KCD2MP_WeatherCmd("%LINE")', "WO-40: bare = report rain intensity; mp_weather <profile> = blend to a time_of_day profile locally (probe, not broadcast)")
    System.AddCCommand("mp_enable_aggro",    'KCD2MP_EnableAggro("%LINE")', "WO-17: opt-in NPC aggro on ghosts, this client only: mp_enable_aggro on|off")

    -- NPC sync (WO-32)
    System.AddCCommand("mp_npc_sync",    'KCD2MP_EnableNpcSync("%LINE")', "WO-32: stream nearby NPCs to peers (world authority only): mp_npc_sync on|off")

    -- Dropped-item sync (WO-48)
    System.AddCCommand("mp_item_sync",   'KCD2MP_EnableItemSync("%LINE")', "WO-48: share deliberately dropped items with peers: mp_item_sync on|off")
    System.AddCCommand("mp_npc_fight",   "KCD2MP_NpcFightReport()", "WO-40: dump per-puppet tug-of-war counts and competing attractor positions")

    -- Shared player combat (WO-28)
    System.AddCCommand("mp_vitals",      "KCD2MP_ReportVitals()",   "WO-28: report this player's health/stamina/death and every ghost's known health")
    System.AddCCommand("mp_fake_death",  'KCD2MP_FakeDeath("%LINE")', "WO-28: report yourself dead for N seconds (default 20) so peers can be observed reacting -- test only")
    System.AddCCommand("mp_reconcile",   "KCD2MP_ReconcileGhosts()", "WO-28: respawn any ghost whose entity was destroyed by a save load")

    -- Dice overlay (WO-6). These console commands are the SUPPORTED path: the
    -- keybinds below them are unverified action-name guesses, exactly as WO-2's
    -- accept/decline were. Everything here is reachable without a working key.
    System.AddCCommand("mp_dice",        "KCD2MP_InviteDiceAtTable()", "Challenge the nearest player to dice -- only at a real dice table")
    System.AddCCommand("mp_dice_wager",  'KCD2MP_SetDiceWager("%LINE")', "WO-33: set groschen staked on the next dice invite this client sends (0 = none)")
    System.AddCCommand("mp_dice_cast",   "KCD2MP_DiceConfirm()",       "Cast, or set aside the marked dice (depends on phase)")
    System.AddCCommand("mp_dice_mark",   'KCD2MP_DiceMark("%LINE")',   "Mark/unmark a die on the board: mp_dice_mark 1..6")
    System.AddCCommand("mp_dice_unmark_all", "KCD2MP_DiceUnmarkAll()", "Clear every pending mark without rerolling")
    System.AddCCommand("mp_dice_bank",   "KCD2MP_DiceBank()",          "Bank this hand and end thy turn")
    System.AddCCommand("mp_dice_yield",  "KCD2MP_DiceForfeit()",       "Yield the match")
    System.AddCCommand("mp_dice_close",  "KCD2MP_DiceClose()",         "Dismiss the dice board")
    System.AddCCommand("mp_dice_table",  "KCD2MP_ReportDiceTable()",   "Report the nearest dice table, for verifying table detection")
    System.AddCCommand("mp_dice_redraw", "KCD2MP_DiceRender()",        "Force the board to re-push (use if it ever goes stale)")
    System.AddCCommand("mp_dice_flush",  "KCD2MP_DiceFlush()",         "Clear every queued/shown tutorial panel -- fixes a stuck or flickering board")
    System.AddCCommand("mp_dice_scan",   'KCD2MP_ScanTables("%LINE")', "List nearby entity classes, to find a table's real class: mp_dice_scan 6")
    System.AddCCommand("mp_dice_seat",   "KCD2MP_ReportSeat()",        "Report the seat under you: distance, table id, teleport anchor")
    System.AddCCommand("mp_dice_gate",   'KCD2MP_DiceGate("%LINE")',   "Require a real table for mp_dice: mp_dice_gate on|off (default off for testing)")
    System.AddCCommand("mp_dice_demo",   "KCD2MP_DiceDemo()",          "Open the board with fake state, to review the visuals without a second player")
    System.AddCCommand("mp_combat_probe", "KCD2MP_CombatProbe()", "WO-39: registration + anim-candidate probe for combat visibility (needs a ghost for the anim half)")
    System.AddCCommand("mp_ghost_combat", 'KCD2MP_GhostCombatAll("%LINE")', "WO-39: play a combat event on every local ghost, no wire: mp_ghost_combat 0=draw 1=sheathe 2=swing 3=block")
    System.AddCCommand("mp_log_actions", 'KCD2MP_LogActions("%LINE")', "Log every OnAction name (floods log -- for discovering action names): mp_log_actions on|off")
    System.AddCCommand("mp_combat_frag", 'KCD2MP_SetCombatFragment("%LINE")', "WO-39: set the Mannequin fragment tried for swings (empty to clear): mp_combat_frag <name> [tags]")
    System.AddCCommand("mp_entity_id", 'KCD2MP_ReportEntityId("%LINE")', "WO-43: print an entity's raw id by name, or every ghost's id with no argument")
    System.AddCCommand("mp_anim_tag",    'KCD2MP_AnimTagCmd("%LINE")', "WO-40: probe AI.Set/ClearAnimationTag on every ghost: mp_anim_tag set|clear <tag>")
    System.AddCCommand("mp_test_xgen_nullai", 'KCD2MP_TestXGenSpawn("NullAI")', "Test XGenAIModule.SpawnEntity ClassName=NullAI")
    System.AddCCommand("mp_test_xgen_npc",    'KCD2MP_TestXGenSpawn("NPC")',    "Test XGenAIModule.SpawnEntity ClassName=NPC")
    System.AddCCommand("mp_test_xgen_horse",  'KCD2MP_TestXGenSpawn("Horse")',  "Test XGenAIModule.SpawnEntity ClassName=Horse")
    System.LogAlways("[KCD2-MP] Commands OK")
end)
if not ok then
    System.LogAlways("[KCD2-MP] Command error: " .. tostring(err))
end

-- mp_log_actions on|off (WO-39). The KCD2MP.logActions global existed since
-- WO-6 but had no console command -- discovering action names needed a
-- hand-typed Lua chunk. The live combat-input probe made it a first-class
-- command.
function KCD2MP_LogActions(arg)
    local on = tostring(arg or ""):lower()
    KCD2MP.logActions = (on == "on" or on == "true" or on == "1")
    System.LogAlways("[KCD2-MP] logActions=" .. tostring(KCD2MP.logActions))
end

-- mp_anim_tag set|clear <tag> (WO-40 Phase 6): probe AI.SetAnimationTag /
-- ClearAnimationTag (documented in the retail-1.5 dump, never tried here) on
-- every ghost. Mannequin tags select fragment variants -- potentially the
-- clean lever for stance/combat variants that raw StartAnimation cannot pick.
function KCD2MP_AnimTagCmd(line)
    line = tostring(line or "")
    local op, tag = line:match("^(%S+)%s+(%S+)$")
    if not op or not tag then
        System.LogAlways("[KCD2-MP] usage: mp_anim_tag set|clear <tag>  (applies to every ghost)")
        System.LogAlways("[KCD2-MP] AI.SetAnimationTag=" .. tostring(AI and type(AI.SetAnimationTag) or "no AI")
            .. " AI.ClearAnimationTag=" .. tostring(AI and type(AI.ClearAnimationTag) or "no AI"))
        return
    end
    local n = 0
    for id, g in pairs(KCD2MP.ghosts) do
        if g.entity then
            n = n + 1
            local ok, err
            if op == "set" then
                ok, err = pcall(function() return AI.SetAnimationTag(g.entity.id, tag) end)
            else
                ok, err = pcall(function() return AI.ClearAnimationTag(g.entity.id, tag) end)
            end
            System.LogAlways(string.format("[KCD2-MP] %s AnimationTag('%s') ghost %s ok=%s err=%s",
                op, tag, tostring(id), tostring(ok), tostring(err)))
        end
    end
    if n == 0 then System.LogAlways("[KCD2-MP] no ghosts to tag") end
end

-- mp_combat_frag <name> [tags] (WO-39): configure the Mannequin fragment the
-- swing apply path tries before the CAF one-shot. Live-tuning tool -- once a
-- session finds a working fragment, it gets hardcoded as the default.
function KCD2MP_SetCombatFragment(line)
    line = tostring(line or "")
    local name, tags = line:match("^(%S+)%s*(.*)$")
    KCD2MP.combatSwingFragment = (name ~= "" and name) or nil
    KCD2MP.combatSwingFragTags = tags or ""
    System.LogAlways("[KCD2-MP] combatSwingFragment=" .. tostring(KCD2MP.combatSwingFragment)
        .. " tags='" .. tostring(KCD2MP.combatSwingFragTags) .. "'")
end

-- ===== Sneak action handler (shared, installed by both hook paths) =====

-- Toggle-style sneak actions (each press flips state).
-- NOTE: chat_init_with_focus is NOT sneak – it's the focus/chat key (triggered by Tab/V).
-- Stance is detected via player:GetStance() polling in KCD2MP_Exchange (reliable fallback).
local SNEAK_TOGGLE_ACTIONS = {
    sneak_toggle=true, toggle_sneak=true,
}
-- Hold-style sneak: pressed=on, released=off (other games/bindings)
local SNEAK_HOLD_ACTIONS = {
    sneak=true, stealth=true, crouch=true,
    wh_sneak=true, wh_stealth=true,
    action_sneak=true, action_stealth=true,
    sneaking=true, stealth_mode=true,
}

-- Analog axis actions - ignore completely, they flood the log
local AXIS_ACTIONS = {
    combat_zone_mouse_x=true, combat_zone_mouse_y=true,
    mouse_x=true, mouse_y=true, look_lx=true, look_ly=true,
    move_lx=true, move_ly=true,
}

-- Combat visibility (WO-39 Phase 1): the local player's own attack/block
-- inputs, mirrored to peers as cosmetic one-shots on this player's ghost.
-- CONFIRMED by the mp_log_actions live pass 2026-08-18: real melee swings
-- fire 'attack_primary_mouse' press/release, one pair per swing; blocking
-- fires 'block' with activation 'hold' (spammed per frame while held) and
-- 'release' -- NEVER 'press', which is why the handler below edge-detects
-- the first hold. 'attack_abort' also fires on releases; deliberately not
-- listed (it is the abort, not the swing). The unconfirmed non-mouse
-- variants stay for gamepad input, same harmless-if-never-fires idiom as
-- the dialog_answerN guesses above.
local COMBAT_SWING_ACTIONS = {
    attack_primary_mouse=true,                        -- CONFIRMED live
    attack_secondary_mouse=true,                      -- same family (stab)
    attack_primary=true, attack_secondary=true,       -- gamepad guesses
}
local COMBAT_BLOCK_ACTIONS = {
    block=true,                                       -- CONFIRMED live (hold/release)
    combat_block=true, wh_block=true,                 -- gamepad guesses
}

-- Accept/decline keybinds (WO-2, real binds added WO-33).
--
-- dialog_answer1/2 etc. below are UNVERIFIED GUESSES, kept only because
-- removing them costs nothing and they might someday turn out real. The
-- actual primary path, added WO-33, reuses kcd2mp_dice_bank (F11) /
-- kcd2mp_dice_yield (F12) -- keys already live-verified safe and wired
-- end-to-end for in-match bank/yield (WO-6 comment block in
-- keybindSuperactions.xml). Reusing them costs zero new key-testing risk:
-- outside an active match (KCD2MP.dice.open false) these two actions are
-- never consumed by the dice-board block below, so they fall through here
-- unclaimed. mp_accept / mp_decline remain the documented console fallback.
local ACCEPT_ACTIONS  = { ["dialog_answer1"] = true, ["confirm"] = true, ["ui_accept"] = true,
                           ["kcd2mp_dice_bank"] = true }
local DECLINE_ACTIONS = { ["dialog_answer2"] = true, ["cancel"] = true, ["ui_cancel"] = true,
                           ["kcd2mp_dice_yield"] = true }

-- Dice-invite keybind (WO-5, real bind added WO-33). dialog_answer3/4 are the
-- same kind of unverified guess as above, kept harmlessly. The real primary
-- path reuses kcd2mp_dice_cast (F9) -- same reasoning as accept/decline: F9
-- is already proven safe and unclaimed outside an active match, since the
-- dice-board block below only consumes it (as "confirm/cast") when
-- KCD2MP.dice.open is true and returns early. KCD2MP_InviteDiceAtTable
-- itself refuses unless a DiceInteractor entity is actually in range, so a
-- spurious F9 press elsewhere in the world is a no-op, not an unwanted
-- invite. mp_invite dice remains the documented console fallback.
local DICE_INVITE_ACTIONS = { ["dialog_answer3"] = true, ["dialog_answer4"] = true,
                               ["kcd2mp_dice_cast"] = true }

-- Dice overlay keys (WO-6).
--
-- Second design. The first tried R/F/X/1-6 -- keys the game's OWN action map
-- already binds to something (toggle_torch, knock_out, call, action_qam_N) --
-- on the reasoning that our OnAction hook runs alongside the game's handler
-- and cannot consume input, so the key's normal side effect had to be
-- tolerable. Two things broke that plan in real play:
--   1. 1-6 also fires action_qam_N's WEAPON/food slot select, not just a
--      cosmetic toggle -- a live match drew a sword mid-game.
--   2. R (toggle_torch) turned out unreliable while seated -- exactly the
--      position this feature is for.
--
-- keybindSuperactions.xml (Libs/Config/, shipped in this mod's own pak) is
-- the actual fix: it is a plain, moddable XML action-map config, not
-- hardcoded, and a key can carry MULTIPLE named actions across different
-- `map=` contexts simultaneously. So instead of reusing an existing action
-- and hoping its side effect is harmless, this ships brand-new action names
-- (kcd2mp_dice_mark_1..6, kcd2mp_dice_cast, kcd2mp_dice_bank,
-- kcd2mp_dice_yield) on physical keys confirmed to have NOTHING else bound
-- to them anywhere in the file, so there is no side effect to tolerate at
-- all. map="interaction" was chosen because it was directly observed still
-- firing (use/talk/trigger_use) immediately after sitting down, unlike
-- "sitting"-shadowed actions.
--
-- Keys: F2, F4, F5, F6, F7, F8 mark dice 1-6 (see DICE_MARK_KEYS in the
-- panel code); F9 casts/sets aside; hold F11 banks; hold F12 yields; U
-- clears every pending mark without rerolling (KCD2MP_DiceUnmarkAll).
--
-- Four traps paid for finding these, none visible from this file alone:
--   1. Numpad 1-6 checked clean here (nothing else in this XML claims them)
--      but wasn't -- action_qam_N's weapon_slot_N sibling lives under
--      apse_qam_slots, which turned out to stay active during ordinary
--      play, not just with a menu open. Adding our own action to a key
--      never suppresses whatever else is already bound there.
--   2. The Numpad operator keys (*, +, -) and F1/F3/F10 are bound to
--      engine-level debug toggles (photo mode, flight mode, AI/animation
--      debug draw) entirely OUTSIDE this XML -- invisible to any check of
--      this file's contents. Numpad / is worse: it CRASHED the game.
--   3. H is also "clean" by this file's contents and is not safe either --
--      it opens a Modding Tools debug menu, same invisible-to-this-file
--      shape as trap 2. Every key actually used below was pressed live,
--      one at a time, and watched for anything happening at all -- that is
--      the only real proof; this file's contents are not enough on their
--      own, and neither is "nothing obviously bad happened" (Numpad 1-6).
--   4. Numpad . is a DIFFERENT kind of failure: not dangerous, just a dead
--      binding. "np_decimal" is not a control name this engine's action-map
--      recognises at all, so the whole entry silently never registers --
--      no crash, no debug menu, just nothing, indistinguishable at a glance
--      from a key that works but has nothing to do yet. Moved to U, which
--      is both unclaimed AND confirmed to actually fire once wired up.
--
-- Bank/yield tried U/Y briefly (to leave F11/F12 free for a future
-- invite-accept/decline bind) -- U/Y worked, but simplicity won: back on
-- F11/F12, which were already proven end-to-end, and U repurposed for
-- cancel instead of adding a fifth key family to the set.
--
-- All of these are gated on KCD2MP.dice.open, so none can fire outside a
-- match. The mp_dice_* console commands remain and always work.
local DICE_CONFIRM_ACTIONS = { ["kcd2mp_dice_cast"]  = true, ["toggle_torch"] = true }
local DICE_BANK_ACTIONS    = { ["kcd2mp_dice_bank"]  = true, ["knock_out"]    = true }  -- held
local DICE_YIELD_ACTIONS   = { ["kcd2mp_dice_yield"] = true, ["call"]         = true }  -- held
local DICE_CANCEL_ACTIONS  = { ["kcd2mp_dice_cancel"] = true }

-- Marking a die. kcd2mp_dice_mark_N's trailing digit is the die index, which
-- lines up with the numbered row drawn under the dice.
local function diceMarkIndex(action)
    local n = action:match("^kcd2mp_dice_mark_(%d)$")
    if n then
        local i = tonumber(n)
        if i and i >= 1 and i <= 6 then return i end
    end
    return nil
end

local function handleAction(action, activation, value)
    if AXIS_ACTIONS[action] then return end
    if KCD2MP.logActions then
        mp_log(string.format("ACT '%s' a=%s", tostring(action), tostring(activation)))
    end

    -- Only consume these while a prompt is actually up, so they never interfere
    -- with normal dialogue or menus.
    if KCD2MP.invite and activation == "press" then
        if ACCEPT_ACTIONS[action] then
            pcall(KCD2MP_AcceptInvite)
            return
        end
        if DECLINE_ACTIONS[action] then
            pcall(KCD2MP_DeclineInvite)
            return
        end
    end

    -- Dice overlay keys (WO-6). Checked BEFORE the invite key below, and every
    -- branch is gated on the board actually being open, so none of this can
    -- interfere with normal play -- or with an NPC dice game, which never opens
    -- this board.
    if KCD2MP.dice and KCD2MP.dice.open then
        if activation == "press" then
            local mark = diceMarkIndex(action)
            if mark then pcall(KCD2MP_DiceMark, mark); return end
            if DICE_CONFIRM_ACTIONS[action] then pcall(KCD2MP_DiceConfirm); return end
            if DICE_CANCEL_ACTIONS[action] then pcall(KCD2MP_DiceUnmarkAll); return end
            -- Bank and yield are irreversible, so they are hold-to-confirm:
            -- start the timer on press, and only KCD2MP_DiceHoldTick fires them.
            if DICE_BANK_ACTIONS[action]  then pcall(KCD2MP_DiceHoldBegin, "bank");    return end
            if DICE_YIELD_ACTIONS[action] then pcall(KCD2MP_DiceHoldBegin, "forfeit"); return end
        elseif activation == "release" then
            if DICE_BANK_ACTIONS[action] or DICE_YIELD_ACTIONS[action] then
                pcall(KCD2MP_DiceHoldEnd)
                return
            end
        end
    end

    -- Challenge the nearest player to dice (WO-5, gated to a real table in
    -- WO-6). Unlike accept/decline this has no KCD2MP.invite-style gate to
    -- check first -- see the comment on DICE_INVITE_ACTIONS above for why
    -- that's an accepted risk here. KCD2MP_InviteDiceAtTable refuses unless a
    -- DiceInteractor entity is actually in range, so a spurious press is now a
    -- no-op rather than an unwanted invite.
    if DICE_INVITE_ACTIONS[action] and activation == "press" then
        pcall(KCD2MP_InviteDiceAtTable)
        return
    end

    -- Combat visibility (WO-39): mirror attack/block inputs to peers.
    -- Deliberately NO return -- this hook must never consume combat input;
    -- the game's own handler already ran (we are chained after it), and a
    -- swing that also triggered something else must keep doing so.
    if COMBAT_SWING_ACTIONS[action] then
        if activation == "press" or activation == 1 then
            local now = os.clock()
            if now - (KCD2MP._lastSwingEmit or 0) >= 0.15 then
                KCD2MP._lastSwingEmit = now
                KCD2MP_EmitEvent("combat", "swing")
            end
        end
    elseif COMBAT_BLOCK_ACTIONS[action] then
        -- 'block' never fires 'press' on this build -- only a per-frame
        -- 'hold' stream and a 'release' (confirmed live). Edge-detect the
        -- first hold so one raise of the guard is one event, not sixty.
        local held = (activation == "press" or activation == "hold"
                      or activation == 1 or activation == 2)
        if held and not KCD2MP._blockHeld then
            KCD2MP._blockHeld = true
            -- WO-40 Phase 6 (the choke miscue): the 'block' action also fires
            -- during weaponless grabs -- the footage's choke-out rendered as
            -- a phantom shield-block on the observer's screen. A block cue
            -- with no weapon out is never a real guard; drop it. Real
            -- unarmed blocking is rare and reads fine as nothing.
            if KCD2MP.weaponDrawn then
                KCD2MP_EmitEvent("combat", "block")
            end
        elseif activation == "release" then
            KCD2MP._blockHeld = false
        end
    end

    -- Toggle-style: each press of C flips sneak on/off
    if SNEAK_TOGGLE_ACTIONS[action] and activation == "press" then
        KCD2MP.playerSneaking = not KCD2MP.playerSneaking
        mp_log("SNEAK=" .. tostring(KCD2MP.playerSneaking) .. " toggle via '" .. action .. "'")
        return
    end

    -- Hold-style: press = on, release = off
    if SNEAK_HOLD_ACTIONS[action] then
        local pressed = (activation == "press" or activation == "hold"
                         or activation == 1 or activation == 2)
        if pressed ~= KCD2MP.playerSneaking then
            KCD2MP.playerSneaking = pressed
            mp_log("SNEAK=" .. tostring(pressed) .. " hold via '" .. action .. "'")
            KCD2MP.logActions = false
        end
    end
end

-- ===== Player hook =====

local ok2, err2 = pcall(function()
    if not (Player and Player.Client) then return end

    -- OnInit: fires when save is loaded
    local origOnInit = Player.Client.OnInit
    Player.Client.OnInit = function(self)
        if origOnInit then origOnInit(self) end
        System.LogAlways("[KCD2-MP] Player loaded!")
        KCD2MP_GetPos()

        -- Re-install OnAction hooks here (after player fully initialized).
        -- Player.Client.OnAction may be reset during game load; re-hooking in OnInit
        -- ensures our handler is always active.
        local origCA = Player.Client.OnAction
        Player.Client.OnAction = function(s, action, activation, value)
            if origCA then pcall(origCA, s, action, activation, value) end
            handleAction(action, activation, value)
        end
        System.LogAlways("[KCD2-MP] Client.OnAction hooked")
    end

    -- Also hook at mod-init time (catches actions before first save load)
    local origCA0 = Player.Client.OnAction
    Player.Client.OnAction = function(self, action, activation, value)
        if origCA0 then pcall(origCA0, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    -- Also try Player.OnAction (non-Client path, some CryEngine versions use this)
    local origPA = Player.OnAction
    Player.OnAction = function(self, action, activation, value)
        if origPA then pcall(origPA, self, action, activation, value) end
        handleAction(action, activation, value)
    end

    System.LogAlways("[KCD2-MP] Player hooks OK (OnInit + OnAction x2)")
end)
if not ok2 then
    System.LogAlways("[KCD2-MP] Hook error: " .. tostring(err2))
end



