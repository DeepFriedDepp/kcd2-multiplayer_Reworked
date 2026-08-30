-- KCD2 Multiplayer - generated module split from Startup/kdcmp.lua
-- Loaded in a fixed order by Scripts/Startup/kdcmp.lua.

local mp_log = KCD2MP.util.log
local tickAlive = KCD2MP.util.tickAlive

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


KCD2MP.modules.items = true
