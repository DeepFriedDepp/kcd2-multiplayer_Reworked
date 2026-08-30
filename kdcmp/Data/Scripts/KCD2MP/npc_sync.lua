-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log
local lerpAngle = KCD2MP.util.lerpAngle
local tickAlive = KCD2MP.util.tickAlive

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
                          -- with `mp_npc_sync off` in the console. Since
                          -- WO-60 a non-authority emits too (proximity
                          -- claims, see KCD2MP.npcProx), so this master
                          -- switch gates every role's NPC emission.
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

-- WO-69: chain identity for the two NPC-sync Script.SetTimer chains.
--
-- `tickAlive` calls a chain dead when its heartbeat is older than 1.0 s, and a
-- menu SUSPENDS Script.SetTimer (WO-12/13) -- so a menu open longer than a
-- second makes a live-but-frozen chain look dead, Start* launches a second
-- one, and when the menu closes BOTH resume. Nothing in the code could ever
-- notice: a chain had no identity, so a stale one was indistinguishable from
-- the real one. The field bundle shows 114 `puppet tick started` against 39
-- `stopped`, in runs of up to nine consecutive starts.
--
-- N concurrent chains apply the position lerp N times per 50 ms, which turns
-- the intended decay into a near-instant snap followed by a wait for the next
-- 4 Hz packet -- i.e. this AMPLIFIES the WO-69 D1 jitter rather than competing
-- with it.
--
-- Deliberately observe-only by default: WO-69's own rule is that the leak is
-- SUSPECTED until a log line shows two chains alive at once. `mp_npc_chainfix
-- on` flips the stale chain from "log and keep running" to "log and exit", so
-- the same build both proves the leak and fixes it without a second deploy.
-- The EMIT chain is deliberately left un-instrumented here. The field bundle
-- shows the same duplication shape on the send side (22,019 npc_claim lines in
-- 368 bursts, ~15x, with byte-identical coordinates repeated inside one frame),
-- but this is a one-machine session: a send-side change could not be observed,
-- only asserted. It goes to WO-70 with the evidence rather than shipping
-- unverified. Same mechanism, same fix shape, different burden of proof.
KCD2MP.npcPuppetGen   = 0
KCD2MP.npcChainFix    = false  -- mp_npc_chainfix on|off
KCD2MP._chainLeakSeen = {}     -- "puppet" -> true, so the line logs once per chain kind

-- WO-69: measured inbound packet cadence. Before this there was NO per-packet
-- record anywhere in the mod, so every cadence number in the WO-69 diagnosis
-- except the emitter's own `emitMs = 250` was a proxy inferred from
-- animation-tag transitions. WO-70 cannot tune a dead-reckoning layer against
-- a cadence nobody has measured. Summarised on a 5 s cadence rather than
-- logged per packet -- a per-packet line at 4 Hz x N puppets is exactly the
-- log volume that changed what it was measuring in WO-39.
KCD2MP.npcPacketStats = { n = 0, sum = 0, min = 1e9, max = 0, dumpAt = 0 }

KCD2MP.npcPuppets        = {} -- name -> {tx,ty,tz,tr,hp,dead,cx,cy,cz,cr,lastPacketAt,animTag}
KCD2MP.npcOversized      = {} -- name -> item class GUID whose draw must go through DrawFromInventory (WO-49)
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

-- WO-60: proximity-based NPC authority. With this on, a NON-authority also
-- runs the rescan/emit loop around its OWN player and claims nearby NPCs
-- through the relay's existing per-entity table (first claim wins, refresh
-- by packet, expiry on silence -- the drag sensor's mechanism, generalized).
-- NPCs someone else is already streaming are puppets here and are excluded
-- by the rescan, so claims only ever target entities nobody is driving.
-- This is the fix for WO-51 §1.4's radius-gap and engagement-asymmetry rows:
-- an NPC fighting the non-authority player, previously invisible to sync
-- because it was far from the host, is now streamed by the machine actually
-- next to it -- the one simulating it at full fidelity.
--
-- mp_npc_proximity off is the FIELD ROLLBACK: it restores the old host-only
-- tracking exactly (non-authority emits nothing but drag claims; standing
-- relay claims expire within seconds and the host's stream resumes).
KCD2MP.npcProx = {
    enabled = true,   -- mp_npc_proximity on|off (mp_npc_sync default-on precedent)
}

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

-- WO-60: the proximity-authority rollback toggle. Off = the pre-WO-60
-- host-only tracking model, exactly: a non-authority's tracked set is
-- dropped on the spot so its claim stream stops within one tick, its relay
-- claims expire on silence, and the host's default stream resumes. The
-- authority's own behaviour never depended on this flag, so flipping it
-- there changes nothing -- no hybrid state exists to get stuck in.
function KCD2MP_EnableNpcProximity(arg)
    local s = tostring(arg or ""):lower()
    if s:find("on") then KCD2MP.npcProx.enabled = true
    elseif s:find("off") then
        KCD2MP.npcProx.enabled = false
        if not KCD2MP.hitSensorOn then
            KCD2MP.npcTracked = {}   -- stop the claim stream immediately
        end
    else
        mp_log("mp_npc_proximity: expected 'on' or 'off', got '" .. tostring(arg) .. "'")
        return false
    end
    mp_log("NPC-PROX " .. (KCD2MP.npcProx.enabled
        and "ENABLED (non-authority claims NPCs near its own player)"
        or "disabled (host-only tracking, pre-WO-60 behaviour)"))
    KCD2MP_ShowInteractionMsg("NPC proximity authority: " .. (KCD2MP.npcProx.enabled and "ON" or "OFF"))
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
--
-- WO-59 Thread A: hysteresis. The old single-radius rescan was a documented
-- ~5 s oscillator (WO-38 findings, "boundary flapping"): an NPC near the
-- 30 m edge was tracked/untracked every 2 s rescan, and each untrack let
-- the receiver's engine yank the puppet back to its own schedule position
-- before the re-track snapped it away again -- jitter with no combat and no
-- restart needed. Two asymmetries fix it: (1) an ALREADY-tracked NPC stays
-- eligible out to 1.5x radius, so crossing the enter-edge back and forth
-- cannot untrack it; (2) when more candidates exist than maxTracked slots,
-- already-tracked NPCs win near-ties (an 8 m bonus), so the tracked set
-- stops churning as ranks 5 and 6 swap places.
local NPC_TRACK_EXIT_FACTOR  = 1.5   -- tracked NPCs stay eligible to radius*this
local NPC_TRACK_STICKY_BONUS = 8.0   -- metres subtracted from a tracked NPC's rank distance
-- WO-60: an NPC with its weapon out within this range of the local player is
-- ENGAGED -- the emit carries flag bit 32, which arms the relay's anti-flap
-- hold on that entity's claim. 12 m covers a melee fight's footwork without
-- holding claims on every armed guard the player merely walks past.
local NPC_ENGAGE_RANGE_SQ    = 12.0 * 12.0
local function mp_npc_rescan()
    if not player then return end
    local pp = nil
    pcall(function() pp = player:GetWorldPos() end)
    if not pp then return end

    local found = {}
    local enterRadius = KCD2MP.npcSync.radius
    local exitRadius  = enterRadius * NPC_TRACK_EXIT_FACTOR
    local ents = System.GetEntitiesInSphere(pp, exitRadius) or {}
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
                local d = math.sqrt(dx*dx + dy*dy)
                local tracked = KCD2MP.npcTracked[name] ~= nil
                -- New NPCs must be inside the enter radius; tracked ones
                -- survive out to the exit radius (the sphere query bound).
                if tracked or d <= enterRadius then
                    table.insert(found, { name = name, e = e,
                        rank = tracked and (d - NPC_TRACK_STICKY_BONUS) or d })
                end
            end
        end
    end
    table.sort(found, function(a, b) return a.rank < b.rank end)

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
    local isAuthority = KCD2MP.hitSensorOn
    if not isAuthority then
        -- WO-39 Phase 2: a non-authority always watches for bodies its own
        -- player is dragging, proximity toggle or no.
        pcall(mp_drag_sensor)
        -- WO-60: with proximity authority on and a peer actually present,
        -- fall through and run the SAME rescan/emit loop around this
        -- player -- emitted as npc_claim, which claims each NPC through the
        -- relay's per-entity table. NPCs someone else already streams are
        -- puppets here and never enter the rescan, so this only picks up
        -- entities nobody is driving (the radius-gap NPCs). Turning
        -- mp_npc_proximity off restores the pre-WO-60 return right here.
        if not KCD2MP.npcProx.enabled then return end
        local anyGhost = false
        for _ in pairs(KCD2MP.ghosts) do anyGhost = true; break end
        if not anyGhost then return end
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
            -- WO-60: the drag sensor already emits (and claims) this body on
            -- its own channel -- don't double-stream it from here too.
            if not isAuthority and KCD2MP.dragging[name] then return end
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

            -- WO-60: engagement -- a live NPC with its weapon out right next
            -- to this player is being fought here. Travels as flag bit 32;
            -- on a claim it arms the relay's hold so the claim cannot flap
            -- to another sender through a brief packet gap mid-fight.
            local engaged = false
            if drawn and not dead and not ko and ppos then
                local gx, gy = p.x - ppos.x, p.y - ppos.y
                engaged = (gx * gx + gy * gy) <= NPC_ENGAGE_RANGE_SQ
            end

            local moved = not t.lastX
                or math.abs(p.x - t.lastX) > KCD2MP.npcSync.moveEps
                or math.abs(p.y - t.lastY) > KCD2MP.npcSync.moveEps
                or math.abs(p.z - t.lastZ) > KCD2MP.npcSync.moveEps
            local hpChanged = t.lastHp and hp >= 0 and math.abs(hp - t.lastHp) > 0.5
            local heartbeat = not t.lastSentAt or (now - t.lastSentAt) >= KCD2MP.npcSync.heartbeatS

            local koChanged = (ko ~= (t.sentKo or false))
            local drawnChanged = (drawn ~= (t.sentDrawn or false))
            local engagedChanged = (engaged ~= (t.sentEngaged or false))
            if moved or hpChanged or heartbeat or koChanged or drawnChanged or swingCue
               or engagedChanged or (dead and not t.sentDead) then
                local flags = (dead and 1 or 0) + (ko and 2 or 0)
                    + (drawn and 4 or 0) + (swingCue and 8 or 0)
                    + (engaged and 32 or 0)
                -- npc_state rides the authority's default stream; npc_claim
                -- (WO-60) is the same payload sent down the asClaim path, so
                -- the agent's authority gate lets it through and sending it
                -- IS the claim.
                KCD2MP_EmitEvent(isAuthority and "npc_state" or "npc_claim",
                    string.format("%s %.3f %.3f %.3f %.4f %.1f %d",
                    name, p.x, p.y, p.z, rot, hp, flags))
                t.lastX, t.lastY, t.lastZ, t.lastRot = p.x, p.y, p.z, rot
                t.lastHp, t.lastSentAt, t.sentDead, t.sentKo = hp, now, dead, ko
                t.sentDrawn = drawn
                t.sentEngaged = engaged
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
        -- WO-49: report this world's copy's entity id so the agent can
        -- address it on the native swing path. Same tostring-hex idiom as
        -- SpawnGhost's ghostid emit -- a decimal path would corrupt ids
        -- above 2^24 in this float32 sandbox.
        local hexid = string.match(tostring(e.id), "(%x+)%s*$")
        if hexid then KCD2MP_EmitEvent("npcid", name .. " " .. hexid) end
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
    -- WO-69: measure the real inbound cadence (see KCD2MP.npcPacketStats).
    -- Read the PREVIOUS stamp before overwriting it. Intervals above 5 s are
    -- dropped rather than averaged in: they are a puppet resuming after a
    -- release, a save load or a menu, not a stream cadence, and a handful of
    -- them would drag the mean far off the thing being measured.
    local nowPkt = os.clock()
    if p.lastPacketAt then
        local dtMs = (nowPkt - p.lastPacketAt) * 1000
        if dtMs > 0 and dtMs < 5000 then
            local s = KCD2MP.npcPacketStats
            s.n   = s.n + 1
            s.sum = s.sum + dtMs
            if dtMs < s.min then s.min = dtMs end
            if dtMs > s.max then s.max = dtMs end
        end
    end
    p.lastPacketAt = nowPkt
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

-- WO-49: draw the puppet's weapon, routing an Oversized main-hand through
-- DrawFromInventory INSTEAD of DrawWeapon (WO-47's polearm lesson + ordering
-- trap). Shared by the drawn-transition apply and the brain-fought-back
-- re-assert below.
local function mp_npc_draw(name, e)
    local og, drew = (KCD2MP.npcOversized or {})[name], false
    if og and e.inventory then
        pcall(function()
            local it = e.inventory:FindItem(tostring(og))
            if it then
                e.human:DrawFromInventory(it, 0, true)
                drew = true
            end
        end)
    end
    if not drew then pcall(function() e.human:DrawWeapon() end) end
end

function KCD2MP_NpcPuppetTick(arg, gen)
    if not KCD2MP.npcPuppetRunning then return end
    -- WO-69: chain identity. `gen` is nil for the external menu pump (which
    -- never reschedules and so cannot be a leaked chain) and for any legacy
    -- bare reschedule; only a generation-stamped chain is checked.
    if gen ~= nil and gen ~= KCD2MP.npcPuppetGen then
        if not KCD2MP._chainLeakSeen.puppet then
            KCD2MP._chainLeakSeen.puppet = true
            mp_log(string.format(
                "NPC-SYNC CHAIN LEAK CONFIRMED: puppet chain gen=%s is still running while gen=%s"
                .. " is current -- two chains were writing the same puppets%s",
                tostring(gen), tostring(KCD2MP.npcPuppetGen),
                KCD2MP.npcChainFix and " (stale chain exiting now)"
                                    or " (observe-only; `mp_npc_chainfix on` to stop it)"))
        end
        -- The fix, gated: a stale chain stops rescheduling and dies here.
        if KCD2MP.npcChainFix then return end
    end
    -- WO-40 Phase 2: same pump pattern as KCD2MP_InterpTick. A menu suspends
    -- Script.SetTimer (WO-12/13), which froze every NPC puppet for the paused
    -- player -- the WO-13 ghost fix was never applied to this second tick.
    -- The agent's menu pump now calls this with arg="ext": no reschedule, no
    -- alive-stamp (a pumped call must not make a dead chain look healthy).
    if arg ~= "ext" then
        Script.SetTimer(50, function() KCD2MP_NpcPuppetTick(nil, gen) end)  -- reschedule FIRST
        KCD2MP._npcPuppetAliveAt = os.clock()
    end

    local now = os.clock()

    -- WO-69: dump the measured inbound cadence every 5 s. This is the number
    -- WO-70 needs and the one nothing has ever recorded.
    local st = KCD2MP.npcPacketStats
    if st.n > 0 and (now - (st.dumpAt or 0)) >= 5.0 then
        st.dumpAt = now
        mp_log(string.format(
            "NPC-SYNC packet cadence: n=%d mean=%.0fms min=%.0fms max=%.0fms (emitter is %dms; apply tick is 50ms)",
            st.n, st.sum / st.n, st.min, st.max, KCD2MP.npcSync.emitMs or 250))
        st.n, st.sum, st.min, st.max = 0, 0, 1e9, 0
    end
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
                    if p.drawn then mp_npc_draw(name, e)
                    else pcall(function() e.human:HolsterWeapon() end) end
                end
                p.drawnCheckAt = now   -- give the draw/holster time before the re-assert below judges it
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

            -- WO-49 live-gate fix (observed): the NPC's own unsuppressed
            -- brain can re-holster on its own schedule -- two swings in,
            -- the puppet sheathed, went back to its wall lean, and cue 3
            -- rendered bare-handed. The transition gate above never fires
            -- again (p.appliedDrawn still matches p.drawn), so re-assert
            -- the STREAMED drawn state against the entity's REAL state,
            -- throttled, only for live non-held puppets (returns above).
            if e.human and (now - (p.drawnCheckAt or 0)) >= 1.5 then
                p.drawnCheckAt = now
                local actual = nil
                pcall(function() actual = e.human:IsWeaponDrawn() == true end)
                if actual ~= nil and actual ~= (p.drawn or false) then
                    if p.drawn then mp_npc_draw(name, e)
                    else pcall(function() e.human:HolsterWeapon() end) end
                    mp_log("NPC-SYNC " .. name .. " re-asserted "
                        .. (p.drawn and "drawn" or "sheathed") .. " (local brain fought back)")
                end
            end

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
                    -- WO-69: the threshold was 0.5625 m^2 = 0.75 m of drift in
                    -- one 50 ms tick = 15 m/s. Nothing short of a teleport
                    -- moves that fast, so this counter was blind to every
                    -- realistic brain contention and its lifetime count of
                    -- zero meant nothing. 0.0025 m^2 = 5 cm/tick = 1 m/s,
                    -- which is walking pace and the scale D2 would actually
                    -- act at. It also LOGS now, throttled: the count alone
                    -- only ever printed from the manual mp_npc_fight command,
                    -- which no field session has ever run.
                    if (fx*fx + fy*fy) > 0.0025 then
                        p.fightN = (p.fightN or 0) + 1
                        if (now - (p.fightLogAt or 0)) >= 5.0 then
                            p.fightLogAt = now
                            mp_log(string.format(
                                "NPC-FIGHT %s displaced %.2fm from our last write in one tick (n=%d) -- something else is moving it",
                                name, math.sqrt(fx*fx + fy*fy), p.fightN))
                        end
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
                -- WO-69: yaw was a HARD SNAP (`p.cr = p.tr or p.cr`) while
                -- position was lerped -- so a puppet's body slid smoothly
                -- while its facing jumped 4x/sec to whatever the last packet
                -- said. That is a jitter source entirely independent of the
                -- position stream, and no amount of position smoothing would
                -- have fixed it. lerpAngle is the ghost path's own
                -- shortest-path helper (file-top local, in scope here --
                -- unlike getFloorZ, which is declared AFTER this tick and
                -- would bind to a nil global).
                --
                -- Position smoothing is deliberately NOT changed in this work
                -- order: it is WO-70's, behind the WO-63 ordering gate
                -- (live-verify WO-60 first). Yaw is safe to land now because
                -- it smooths ROTATION, so it cannot mask the position
                -- snap-between-attractors that WO-60's footage has to show.
                if p.tr then p.cr = lerpAngle(p.cr or p.tr, p.tr, 0.5) end
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
    -- WO-69: every start claims a new generation. Any chain still running
    -- under an older one is, by definition, a leaked chain -- and now says so.
    KCD2MP.npcPuppetGen = (KCD2MP.npcPuppetGen or 0) + 1
    local myGen = KCD2MP.npcPuppetGen
    mp_log("NPC-SYNC puppet tick started (50ms) gen=" .. tostring(myGen))
    Script.SetTimer(50, function() KCD2MP_NpcPuppetTick(nil, myGen) end)
end

-- WO-69: `mp_npc_chainfix on|off`. Off (default) = a leaked chain is logged
-- and left running, so the leak can be OBSERVED before it is fixed. On = the
-- stale chain exits. Deliberately a toggle rather than a hardcoded fix: it
-- makes the before/after a live A/B on one build instead of two deploys, and
-- leaves a rollback if stopping a chain turns out to stop the wrong one.
function KCD2MP_SetNpcChainFix(arg)
    local s = tostring(arg or ""):lower()
    if s == "on" or s == "1" or s == "true" then
        KCD2MP.npcChainFix = true
    elseif s == "off" or s == "0" or s == "false" then
        KCD2MP.npcChainFix = false
    end
    mp_log("mp_npc_chainfix = " .. tostring(KCD2MP.npcChainFix)
           .. " (leak seen so far: puppet=" .. tostring(KCD2MP._chainLeakSeen.puppet and true or false) .. ")")
end


KCD2MP.modules.npc_sync = true
