-- WO-118 live-test helpers (tools/wo118). Load with: python live.py luaf lua/wo118.lua
-- Every result is a [WO118...] line in kcd.log. Plans come out in SynthPeer's plan syntax.
--   WO118_Plan(name, dist, speed)        line plan from the NPC's spot along a clear direction
--   WO118_PlanHold(name, dist)           hold plan dist m off the NPC's spot
--   WO118_PlanTimed(name)                1 m / 3 m holds, then a walk-away (Phase 3 activity runs)
--   WO118_PlanMany(r, n, dist, speed)    line plans for the n nearest live NPCs within r m
--   WO118_SlopeFind(name, L, n, speed, R) smoothest path with the most rise within R m (path + geo + prof)
--   WO118_Flat(R, span)                  flattest circle of radius R within span m
function WO118_Floor(x, y, z)
  local fz = nil
  pcall(function()
    local hits = Physics.RayWorldIntersection({x=x, y=y, z=z + 2.0}, {x=0, y=0, z=-6}, 15, 1)
    if hits and hits[1] then local h = hits[1]; local pt = h.pt or h.pos or h.point; if pt then fz = pt.z end end
  end)
  return fz
end
function WO118_Clear(e, p, dx, dy, dist)
  for _, h in ipairs({ 0.4, 1.1 }) do
    local ok = false
    pcall(function() ok = Physics.RayTraceCheck({x=p.x, y=p.y, z=p.z+h}, {x=p.x+dx*(dist+0.45), y=p.y+dy*(dist+0.45), z=p.z+h}, e.id, player.id) end)
    if not ok then return false end
  end
  return true
end
function WO118_Prof(p, dx, dy, dist, n)
  local zs, lo, hi = {}, 1e9, -1e9
  for k = 0, n do
    local t = dist * k / n
    local fz = WO118_Floor(p.x + dx * t, p.y + dy * t, p.z)
    zs[#zs + 1] = fz and string.format('%.2f', fz) or 'nil'
    if fz then lo = math.min(lo, fz); hi = math.max(hi, fz) end
  end
  return hi - lo, table.concat(zs, ',')
end
function WO118_Free(name, dist, n)
  local e = System.GetEntityByName(name)
  if not e then return end
  local p = e:GetWorldPos()
  local rep = {}
  for i = 0, 15 do
    local a = i * math.pi / 8
    local dx, dy = math.cos(a), math.sin(a)
    if WO118_Clear(e, p, dx, dy, dist) then
      local dz, zs = WO118_Prof(p, dx, dy, dist, n)
      rep[#rep + 1] = string.format('%d:(%.3f,%.3f) dz=%.2f z=[%s]', i, dx, dy, dz, zs)
    end
  end
  System.LogAlways(string.format('[WO118FREE] %s at %.2f,%.2f,%.2f dist=%.1f clear: %s', name, p.x, p.y, p.z, dist, table.concat(rep, ' | ')))
end
function WO118_Dir(e, p, dist)
  for i = 0, 15 do
    local a = i * math.pi / 8
    local dx, dy = math.cos(a), math.sin(a)
    if WO118_Clear(e, p, dx, dy, dist) then return dx, dy, i end
  end
  return nil
end
function WO118_Plan(name, dist, speed)
  local e = System.GetEntityByName(name)
  if not e then System.LogAlways('[WO118PLAN] missing ' .. tostring(name)); return end
  local p = e:GetWorldPos()
  local dx, dy = WO118_Dir(e, p, dist)
  if not dx then System.LogAlways('[WO118PLAN] none ' .. name); return end
  System.LogAlways(string.format('[WO118PLAN] line %s %.3f %.3f %.3f %.4f %.4f %.1f %.2f pingpong', name, p.x, p.y, p.z, dx, dy, dist, speed))
end
function WO118_PlanHold(name, dist)
  local e = System.GetEntityByName(name)
  if not e then System.LogAlways('[WO118PLAN] missing ' .. tostring(name)); return end
  local p = e:GetWorldPos()
  local dx, dy = WO118_Dir(e, p, dist)
  if not dx then System.LogAlways('[WO118PLAN] none ' .. name); return end
  local ang = e:GetWorldAngles()
  System.LogAlways(string.format('[WO118PLAN] hold %s %.3f %.3f %.3f %.3f', name, p.x + dx * dist, p.y + dy * dist, p.z, ang.z))
end
function WO118_BestDir(e, p)
  for _, L in ipairs({ 30, 20, 12, 6, 3 }) do
    for i = 0, 15 do
      local a = i * math.pi / 8
      local dx, dy = math.cos(a), math.sin(a)
      if WO118_Clear(e, p, dx, dy, L) then return dx, dy, L end
    end
  end
  return nil
end
function WO118_PlanTimed(name, t0)
  local e = System.GetEntityByName(name)
  if not e then System.LogAlways('[WO118PLAN] missing ' .. tostring(name)); return end
  local p = e:GetWorldPos()
  local dx, dy, L = WO118_BestDir(e, p)
  if not dx then System.LogAlways('[WO118PLAN] none ' .. name); return end
  local st = '?'
  pcall(function() st = tostring(e.actor:GetCurrentAnimationState()) end)
  local yaw = e:GetWorldAngles().z
  local tw = L / 1.4
  System.LogAlways(string.format('[WO118PLAN] timed %s %.3f 0 %.3f %.3f %.3f 25 %.3f %.3f %.3f 27 %.3f %.3f %.3f 50 %.3f %.3f %.3f %.1f %.3f %.3f %.3f #spot=%.2f,%.2f act=%s L=%.0f',
    name, yaw, p.x + dx, p.y + dy, p.z, p.x + dx, p.y + dy, p.z, p.x + 3 * dx, p.y + 3 * dy, p.z,
    p.x + 3 * dx, p.y + 3 * dy, p.z, 50 + tw, p.x + L * dx, p.y + L * dy, p.z, p.x, p.y, st, L))
end
function WO118_PlanMany(r, maxN, dist, speed)
  local p = player:GetWorldPos()
  local rows = {}
  for _, e in ipairs(System.GetEntitiesInSphere(p, r) or {}) do
    if (e.class == 'NPC' or e.class == 'NPC_Female') and not string.find(e:GetName(), 'kcd2mp_', 1, true) then
      local alive = true
      pcall(function() if e.actor:GetHealth() <= 0 then alive = false end end)
      local wp = e:GetWorldPos()
      if alive then rows[#rows + 1] = { e = e, d = (wp.x - p.x) ^ 2 + (wp.y - p.y) ^ 2 } end
    end
  end
  table.sort(rows, function(a, b) return a.d < b.d end)
  local n = 0
  for _, row in ipairs(rows) do
    if n >= maxN then break end
    local wp = row.e:GetWorldPos()
    local dx, dy = WO118_Dir(row.e, wp, dist)
    if dx then
      n = n + 1
      System.LogAlways(string.format('[WO118MANY] line %s %.3f %.3f %.3f %.4f %.4f %.1f %.2f pingpong', row.e:GetName(), wp.x, wp.y, wp.z, dx, dy, dist, speed))
    end
  end
  System.LogAlways(string.format('[WO118MANY] n=%d of %d r=%d', n, #rows, r))
end
function WO118_Fz(x, y, z)
  local fz = nil
  pcall(function()
    local hits = Physics.RayWorldIntersection({x=x, y=y, z=z + 4.0}, {x=0, y=0, z=-10}, 0x107, 1)
    if hits and hits[1] then local h = hits[1]; local pt = h.pt or h.pos or h.point; if pt then fz = pt.z end end
  end)
  return fz
end
function WO118_SlopeEmit(name, speed, bx, by, dx, dy, L, n, pz, rise)
  local pts, prof = {}, {}
  for k = 0, n do
    local t = L * k / n
    local x, y = bx + dx * t, by + dy * t
    pts[#pts + 1] = string.format('%.3f %.3f %.3f', x, y, WO118_Fz(x, y, pz) or pz)
  end
  for k = 0, 4 * n do
    local t = L * k / (4 * n)
    prof[#prof + 1] = string.format('%.3f', WO118_Fz(bx + dx * t, by + dy * t, pz) or -1)
  end
  System.LogAlways(string.format('[WO118SLOPE] path %s %.2f %s', name, speed, table.concat(pts, ' ')))
  System.LogAlways(string.format('[WO118SLOPE] geo x0=%.3f y0=%.3f ux=%.4f uy=%.4f L=%.1f rise=%.2f', bx, by, dx, dy, L, rise))
  System.LogAlways('[WO118SLOPE] prof ' .. table.concat(prof, ','))
end
function WO118_Slope(name, L, n, speed, R)
  local p = player:GetWorldPos()
  local best, bx, by, bdx, bdy = -1
  for j = 0, 7 do
    local b = j * math.pi / 4
    local ox, oy = p.x + math.cos(b) * (R or 0), p.y + math.sin(b) * (R or 0)
    local oz = WO118_Fz(ox, oy, p.z)
    for i = 0, 15 do
      local a = i * math.pi / 8
      local dx, dy = math.cos(a), math.sin(a)
      local fz = WO118_Fz(ox + dx * L, oy + dy * L, p.z)
      if oz and fz and math.abs(fz - oz) > best then best, bx, by, bdx, bdy = math.abs(fz - oz), ox, oy, dx, dy end
    end
  end
  if not bdx then System.LogAlways('[WO118SLOPE] none') return end
  WO118_SlopeEmit(name, speed, bx, by, bdx, bdy, L, n, p.z, best)
end
function WO118_ProfOk(ox, oy, dx, dy, L, pz)
  local prev, z0, zmax, zmin = nil, nil, -1e9, 1e9
  for k = 0, L do
    local fz = WO118_Fz(ox + dx * k, oy + dy * k, pz)
    if not fz then return nil end
    if prev and math.abs(fz - prev) > 0.45 then return nil end
    z0 = z0 or fz
    prev = fz
    if fz > zmax then zmax = fz end
    if fz < zmin then zmin = fz end
  end
  return zmax - zmin, z0
end
function WO118_SlopeFind(name, L, n, speed, Rmax)
  local p = player:GetWorldPos()
  local best, bx, by, bdx, bdy = 0
  for rr = 6, Rmax, 6 do
    for j = 0, 11 do
      local b = j * math.pi / 6
      local ox, oy = p.x + math.cos(b) * rr, p.y + math.sin(b) * rr
      for i = 0, 7 do
        local a = i * math.pi / 4
        local dx, dy = math.cos(a), math.sin(a)
        local rise = WO118_ProfOk(ox, oy, dx, dy, L, p.z)
        if rise and rise > best then best, bx, by, bdx, bdy = rise, ox, oy, dx, dy end
      end
    end
  end
  if not bdx then System.LogAlways('[WO118SLOPE] none') return end
  WO118_SlopeEmit(name, speed, bx, by, bdx, bdy, L, n, p.z, best)
end
function WO118_FlatAt(cx, cy, pz, R)
  local lo, hi, sum = 1e9, -1e9, 0
  for i = 0, 11 do
    local a = i * math.pi / 6
    local z = WO118_Fz(cx + R * math.cos(a), cy + R * math.sin(a), pz)
    if not z then return nil end
    lo = math.min(lo, z); hi = math.max(hi, z); sum = sum + z
  end
  return hi - lo, sum / 12
end
function WO118_Flat(R, span)
  local p = player:GetWorldPos()
  local best, bx, by, bz = 1e9
  for ix = -span, span, 2 do
    for iy = -span, span, 2 do
      local d = math.sqrt(ix * ix + iy * iy)
      if d >= 3 then
        local r, z = WO118_FlatAt(p.x + ix, p.y + iy, p.z, R)
        if r and r < best then best, bx, by, bz = r, p.x + ix, p.y + iy, z end
      end
    end
  end
  System.LogAlways(string.format('[WO118FLAT] best range=%.3f at %.2f,%.2f z=%.3f', best, bx or 0, by or 0, bz or 0))
end
