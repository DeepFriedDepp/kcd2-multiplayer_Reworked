<#
.SYNOPSIS
    WO-21 Phase 0 -- dump every reachable spawn/entity property off a real,
    combat-capable NPC and off a mod-spawned ghost, and diff them.

.DESCRIPTION
    WO-16 found real NPCs, animals and the ghost all report the SAME
    esModularBehaviorTree ("IdleSeq"). Shipped game data explains why:
    Scripts/Entities/AI/Shared/BasicAITable.lua sets
    esModularBehaviorTree = "IdleSeq" as the CLASS DEFAULT for every AI entity.
    So the tree name is not, and never was, a differentiator.

    This probe looks for the thing that IS. Candidates, from
    Libs/Tables/ai/brain.xml + brain2subbrain.xml + subbrain*.xml:
      * the Warhorse "brain" (npc_basic -> npc_basic_scheduler +
        npc_basic_switch, vs npc_default -> default.xml = one Wait(-1) node)
      * sWH_AI_EntityCategory, aicharacter_character, esBehaviorSelectionTree
      * anything else present on a real NPC and absent on the ghost

    Read-only. No writes to any real NPC. The only mutation is spawning and
    removing a test ghost through the mod's own KCD2MP_SpawnGhost.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-WO21-Brain.ps1
#>
[CmdletBinding()]
param(
    [string] $ApiBase = 'http://localhost:1403',
    [string] $KcdLog  = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log',
    [string] $NpcName = ''      # leave empty to auto-pick the nearest real NPC
)

$ErrorActionPreference = 'Stop'
$TAG = 'WO21'

function Lua([string] $code) {
    # ExecuteString has a ~1716-2190 encoded-char ceiling (WO-16). Keep chunks small.
    $enc = [uri]::EscapeDataString('#' + $code)
    if ($enc.Length -gt 1700) { Write-Host "  WARN chunk $($enc.Length) encoded chars -- near the truncation ceiling" -ForegroundColor Yellow }
    try { Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null }
    catch { Write-Host "  (console call failed: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

$script:seen = @{}
function Read-New {
    $out = @()
    foreach ($line in (Get-Content $KcdLog)) {
        if ($line -notmatch "\[$TAG\]") { continue }
        $clean = ($line -replace ".*\[$TAG\] ", '')
        if ($script:seen.ContainsKey($clean)) { continue }
        $script:seen[$clean] = $true
        $out += $clean
    }
    return $out
}

Write-Host '=== WO-21 Phase 0: what actually differentiates a real NPC from a ghost ===' -ForegroundColor Cyan
try { Invoke-WebRequest -Uri "$ApiBase/api/rpg/Calendar?depth=1" -UseBasicParsing -TimeoutSec 6 | Out-Null }
catch { Write-Host 'FAILED: game not reachable on 1403 (launch via Modding Tools, load a save).' -ForegroundColor Red; exit 1 }
if (-not (Test-Path $KcdLog)) { Write-Host "FAILED: kcd.log not found at $KcdLog" -ForegroundColor Red; exit 1 }

# --- the dumper -------------------------------------------------------------
Lua @'
function WO21P(k,v) System.LogAlways("[WO21] "..tostring(k).."="..tostring(v)) end
function WO21D(tag,t,d)
  d = d or 0
  if type(t) ~= "table" then WO21P(tag, t) return end
  if d > 2 then WO21P(tag, "<deep>") return end
  for k,v in pairs(t) do
    if type(v) == "table" then WO21D(tag.."."..tostring(k), v, d+1)
    elseif type(v) ~= "function" and type(v) ~= "userdata" then WO21P(tag.."."..tostring(k), v) end
  end
end
'@
Start-Sleep -Milliseconds 400

# --- pick the subject NPC ---------------------------------------------------
Write-Host "`n1. picking a real combat-capable NPC" -ForegroundColor Cyan
if ($NpcName) {
    Lua "WO21_npc = System.GetEntityByName('$NpcName'); WO21P('npc.name', WO21_npc and WO21_npc:GetName() or 'NOT_FOUND')"
} else {
    Lua @'
local ents = System.GetEntitiesInSphere(player:GetWorldPos(), 60)
local best, bestd = nil, 1e9
local pp = player:GetWorldPos()
for i = 1, (ents and #ents or 0) do
  local e = ents[i]
  if e and e.actor and e.soul and e.human then
    local nm = tostring(e:GetName())
    if not string.find(nm, "kcd2mp") and not string.find(nm, "dummy") then
      local p = e:GetWorldPos()
      local dx,dy = p.x-pp.x, p.y-pp.y
      local d = dx*dx + dy*dy
      if d < bestd then best, bestd = e, d end
    end
  end
end
WO21_npc = best
WO21P("npc.name", best and best:GetName() or "NONE")
WO21P("npc.dist", best and math.sqrt(bestd) or -1)
'@
}
Start-Sleep -Milliseconds 1200
Read-New | ForEach-Object { "  $_" }

# --- dump the real NPC ------------------------------------------------------
Write-Host "`n2. real NPC: full property dump" -ForegroundColor Cyan
Lua 'local e=WO21_npc; if e then WO21P("npc.class", e.class) WO21D("npc.Prop", e.Properties) end'
Start-Sleep -Milliseconds 900
Lua 'local e=WO21_npc; if e then WO21D("npc.PropInst", e.PropertiesInstance) end'
Start-Sleep -Milliseconds 900
Lua @'
local e = WO21_npc
if e then
  for _,k in ipairs({"esModularBehaviorTree","esBehaviorSelectionTree","sWH_AI_EntityCategory",
                     "aicharacter_character","guidSharedSoulId","esFaction","esArchetype",
                     "esNavigationType","esVoice","esCommConfig"}) do
    WO21P("npc.key."..k, e.Properties and e.Properties[k])
  end
end
'@
Start-Sleep -Milliseconds 1200
Read-New | ForEach-Object { "  $_" }

# --- brain reads ------------------------------------------------------------
Write-Host "`n3. brain-layer reads (the Phase 0 hypothesis)" -ForegroundColor Cyan
Lua @'
local e = WO21_npc
if e then
  local ok,v = pcall(function() return e.actor:GetAIBrainId() end)
  WO21P("npc.GetAIBrainId", tostring(ok).." / "..tostring(v))
  local ok2,v2 = pcall(function() return XGenAIModule.GetBrainVariable(e.id, "consciousness") end)
  WO21P("npc.GetBrainVariable", tostring(ok2).." / "..tostring(v2))
  local ok3,v3 = pcall(function() return e.soul:GetArchetype() end)
  WO21P("npc.soul.GetArchetype", tostring(ok3).." / "..tostring(v3))
end
'@
Start-Sleep -Milliseconds 1200
Read-New | ForEach-Object { "  $_" }

# --- spawn a control ghost and dump it the same way -------------------------
Write-Host "`n4. control ghost: same dump (mod's own spawner, untouched)" -ForegroundColor Cyan
Lua 'local p=player:GetWorldPos(); KCD2MP_SpawnGhost("wo21p0", p.x+2, p.y+2, p.z, 0)'
Start-Sleep -Seconds 3
Lua 'local g=KCD2MP.ghosts["wo21p0"]; WO21_ghost = g and g.entity; WO21P("ghost.found", WO21_ghost ~= nil); if WO21_ghost then WO21P("ghost.class", WO21_ghost.class) WO21D("ghost.Prop", WO21_ghost.Properties) end'
Start-Sleep -Milliseconds 1200
Lua 'local e=WO21_ghost; if e then WO21D("ghost.PropInst", e.PropertiesInstance) end'
Start-Sleep -Milliseconds 900
Lua @'
local e = WO21_ghost
if e then
  local ok,v = pcall(function() return e.actor:GetAIBrainId() end)
  WO21P("ghost.GetAIBrainId", tostring(ok).." / "..tostring(v))
  local ok2,v2 = pcall(function() return XGenAIModule.GetBrainVariable(e.id, "consciousness") end)
  WO21P("ghost.GetBrainVariable", tostring(ok2).." / "..tostring(v2))
  local ok3,v3 = pcall(function() return e.soul:GetArchetype() end)
  WO21P("ghost.soul.GetArchetype", tostring(ok3).." / "..tostring(v3))
end
'@
Start-Sleep -Milliseconds 1500
Read-New | ForEach-Object { "  $_" }

Write-Host "`n5. leaving the ghost 'wo21p0' alive for follow-up phases." -ForegroundColor Green
Write-Host "   Remove it with:  #KCD2MP_RemoveGhost('wo21p0')" -ForegroundColor DarkGray
