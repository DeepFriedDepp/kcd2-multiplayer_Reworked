<#
.SYNOPSIS
    WO-20 Phase 1 scratch probe: does `guidSharedSoulId` work as a spawn-time
    property on XGenAIModule.SpawnEntity, the way KCD2MP_SpawnGhost calls it?

.DESCRIPTION
    Not committed as a permanent test -- this is the throwaway probe used to
    settle the question live before wiring the real feature into kdcmp.lua.
    Spawns a standalone test entity (not through KCD2MP_SpawnGhost) bound to a
    real, live soul's SharedSoulGuid, then reads back what the engine did.
    Visual confirmation (does the spawned entity actually look like the donor)
    still needs a human looking at the screen -- this script only proves the
    property is accepted and the entity resolves to a soul.
#>
[CmdletBinding()]
param(
    [string] $ApiBase = 'http://localhost:1403',
    [string] $DonorSoulName = 'ttkc_woman_6',
    [string] $ClassName = 'NPC_Female',
    [string] $SpawnName = 'facetest1'
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KcdApi.ps1"

if (-not (Test-KcdApi)) { Write-Host 'FAILED: game not reachable on :1403' -ForegroundColor Red; exit 1 }

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null
}

$donorShared = Get-KcdValue "/api/rpg/SoulList/SoulsByName/$DonorSoulName/SharedSoulGuid"
$donorGuid   = Get-KcdValue "/api/rpg/SoulList/SoulsByName/$DonorSoulName/Guid"
Write-Host "Donor '$DonorSoulName': Guid=$donorGuid SharedSoulGuid=$donorShared"
if ($donorShared -match '^ERR') { Write-Host 'FAILED: could not resolve donor soul' -ForegroundColor Red; exit 1 }

$code = @"
local function P(k,v) System.LogAlways("[KCD2-MP-FACE] "..k.."="..tostring(v)) end
local ppos = player:GetWorldPos()
local ok, err = pcall(function()
  XGenAIModule.SpawnEntity{
    Name = "$SpawnName",
    ClassName = "$ClassName",
    Pos = {ppos.x+2, ppos.y, ppos.z},
    Properties = { esFaction = "Civilians", esModularBehaviorTree = "", guidSharedSoulId = "$donorShared" },
  }
end)
P("spawn.ok", ok)
P("spawn.err", tostring(err))
local e = System.GetEntityByName("$SpawnName")
P("entity.found", e ~= nil)
if e then
  P("entity.id", tostring(e.id))
  P("soul.name", e.soul and tostring(e.soul.name) or "NOSOUL")
end
"@
Lua $code
Start-Sleep -Milliseconds 1500

Write-Host "`nReadback via REST:"
Write-Host "  Name           : $(Get-KcdValue "/api/rpg/SoulList/SoulsByName/$SpawnName/Name")"
Write-Host "  Guid           : $(Get-KcdValue "/api/rpg/SoulList/SoulsByName/$SpawnName/Guid")"
Write-Host "  SharedSoulGuid : $(Get-KcdValue "/api/rpg/SoulList/SoulsByName/$SpawnName/SharedSoulGuid")"
Write-Host "`nLook at the game now -- does '$SpawnName' (spawned next to the player) visibly look like '$DonorSoulName', distinct from a generic ghost?" -ForegroundColor Yellow
Write-Host "Cleanup: run  Lua 'System.GetEntityByName(\"$SpawnName\"):Destroy()'  or  mp_remove_all" -ForegroundColor DarkGray
