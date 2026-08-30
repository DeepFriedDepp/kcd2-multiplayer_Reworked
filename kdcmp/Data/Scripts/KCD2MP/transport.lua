-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log
local tickAlive = KCD2MP.util.tickAlive

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
    local nowClock = os.clock()

    -- WO-59 Thread D: a frame-rate floor signal, so the next "FPS dropped"
    -- report comes with numbers in the bundle instead of testimony.
    -- Script.SetTimer fires on frames, so each tick's actual delay is
    -- max(emitIntervalMs, frame time): while the game runs faster than
    -- 1000/emitIntervalMs fps the average delta sits at the interval, and
    -- when it runs slower the average delta IS the frame time (15 fps ==
    -- ~67 ms deltas at the 20 ms interval). Logged every 15 s only while
    -- degraded (avg > 2x interval, i.e. below ~25 fps -- quiet on a
    -- healthy-but-modest 30 fps rig), plus one baseline line per 60 s.
    local prev = KCD2MP._emitAliveAt
    if prev then
        local dtMs = (nowClock - prev) * 1000
        local st = KCD2MP._tickStat
        if not st then st = { n = 0, sum = 0, max = 0, winStart = nowClock, baseAt = nowClock }; KCD2MP._tickStat = st end
        st.n, st.sum = st.n + 1, st.sum + dtMs
        if dtMs > st.max then st.max = dtMs end
        if (nowClock - st.winStart) >= 15 and st.n > 0 then
            local avg = st.sum / st.n
            local degraded = avg > KCD2MP.emitIntervalMs * 2.0
            if degraded or (nowClock - st.baseAt) >= 60 then
                System.LogAlways(string.format(
                    "[KCD2-MP] tickstat avg=%.1fms max=%.1fms n=%d interval=%dms%s",
                    avg, st.max, st.n, KCD2MP.emitIntervalMs,
                    degraded and string.format(" DEGRADED (~%.0f fps floor)", 1000 / avg) or ""))
                st.baseAt = nowClock
            end
            st.n, st.sum, st.max, st.winStart = 0, 0, 0, nowClock
        end
    end
    KCD2MP._emitAliveAt = nowClock

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


KCD2MP.modules.transport = true
