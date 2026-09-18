<#
.SYNOPSIS  WO-100.5 Phase 0 -- the NPC_NAI live burst, driven from the coding shell.
.DESCRIPTION
    Spawns TWO bodies side by side in front of the player through the same
    shape the ghost path uses (XGenAIModule.SpawnEntity with a roster
    SharedSoulGuid): one NPC_NAI and one ordinary NPC. Everything the WO asks
    is then a comparison inside one scene:

      item 1  perception  -- do other NPCs react to either body? The decisive
                            test is committing a crime against each one in
                            front of a guard: WO-68 established a ghost is a
                            full crime victim, so if bWH_PerceptibleObject
                            being absent matters, hitting the NAI body
                            produces no witness reaction and hitting the NPC
                            body does.
      item 2  situations  -- grep kcd.log for "for situations" and
                            behaviour-tree role errors, per body name.
      item 3  faction     -- both carry a soul guid, so neither should spam
                            "does not have a faction" (WO-100 S10.6).
      item 4  plumbing    -- class, soul and model are read BACK off the
                            spawned entity, not assumed from the request.

    Read-only apart from the two spawns. Remove them with -Cleanup.

.EXAMPLE  powershell -File tools\Probe-Wo1005-Nai.ps1
.EXAMPLE  powershell -File tools\Probe-Wo1005-Nai.ps1 -Cleanup
#>
param(
    [switch] $Cleanup,
    [string] $ApiBase = 'http://localhost:1403',
    [string] $KcdLog  = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log'
)

$ErrorActionPreference = 'Stop'
$Tag = 'WO1005'

# The deterministic male commoner whose guid is checked into kdcmp.lua as
# KCD2MP.faceFallback (ttkc_man_26, varlet, crime role 1). WO-69 read it back
# live from a running build; WO-83 chose it precisely because it is NOT an
# authority soul. Hardcoded here so this probe needs no mod pak loaded.
$SoulGuid = 'cfa65480-f361-4cf8-80c5-1900b7846bc8'

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    if ($enc.Length -gt 1700) { Write-Host "  WARN chunk $($enc.Length) encoded chars (ceiling ~1716)" -ForegroundColor Yellow }
    try { Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null }
    catch { Write-Host "  console call failed: $($_.Exception.Message)" -ForegroundColor Red; throw }
}

$script:seen = @{}
function Reset-Seen {
    if (-not (Test-Path $KcdLog)) { return }
    foreach ($line in (Get-Content $KcdLog)) { if ($line -match "\[$Tag\]") { $script:seen[$line] = $true } }
}
function Show([int] $waitMs = 1500) {
    Start-Sleep -Milliseconds $waitMs
    foreach ($line in (Get-Content $KcdLog)) {
        if ($line -notmatch "\[$Tag\]") { continue }
        if ($script:seen.ContainsKey($line)) { continue }
        $script:seen[$line] = $true
        '  ' + ($line -replace ".*\[$Tag\] ", '')
    }
}

# --- reachability ----------------------------------------------------------
try { $null = Invoke-WebRequest -Uri "$ApiBase/api/rpg/Calendar?depth=1" -UseBasicParsing -TimeoutSec 5 }
catch { Write-Host 'The debug API on 1403 is not answering -- is the Modding Tools game running with a save loaded?' -ForegroundColor Red; exit 1 }

Reset-Seen
Lua "function W(s) System.LogAlways(""[$Tag] "" .. tostring(s)) end"

if ($Cleanup) {
    Lua @'
for _,n in ipairs({"wo1005_nai","wo1005_npc"}) do
 local e=System.GetEntityByName(n)
 if e then System.RemoveEntity(e.id); W("removed "..n) else W("absent "..n) end
end
'@
    Show | ForEach-Object { $_ }
    Write-Host 'cleanup done' -ForegroundColor Green
    exit 0
}

Write-Host '== spawning the pair ==' -ForegroundColor Cyan
# Chunk kept small: the ExecuteString ceiling is ~1716 encoded characters.
Lua @"
KP=function(n,c)
 local p=player:GetWorldPos(); local a=player:GetWorldAngles()
 local fx,fy=math.sin(a.z),math.cos(a.z)
 local sx,sy=math.cos(a.z),-math.sin(a.z)
 local o=(n=='wo1005_nai') and 1.5 or -1.5
 local e=System.GetEntityByName(n); if e then System.RemoveEntity(e.id) end
 pcall(function() XGenAIModule.SpawnEntity{Name=n,ClassName=c,Pos={p.x+fx*4+sx*o,p.y+fy*4+sy*o,p.z},SharedSoulGuid='$SoulGuid'} end)
 return System.GetEntityByName(n)
end
"@
Lua @'
RP=function(n)
 local e=System.GetEntityByName(n)
 if not e then W(n..": SPAWN FAILED"); return end
 local cls,soul,cdf,act,hum=nil,nil,nil,nil,nil
 pcall(function() cls=e.class end)
 pcall(function() soul=e.soul and e.soul:GetSharedSoulGuid() end)
 pcall(function() cdf=e:GetCharacterFileName(0) end)
 pcall(function() act=(e.actor~=nil) end)
 pcall(function() hum=(e.human~=nil) end)
 W(string.format("%s id=%s class=%s actor=%s human=%s soul=%s model=%s",
   n,tostring(e.id),tostring(cls),tostring(act),tostring(hum),tostring(soul),tostring(cdf)))
end
'@
Lua "KP('wo1005_nai','NPC_NAI'); KP('wo1005_npc','NPC'); RP('wo1005_nai'); RP('wo1005_npc')"
Show 2500 | ForEach-Object { Write-Host $_ }

Write-Host ''
Write-Host '== kcd.log, last 400 lines, for the two probe names ==' -ForegroundColor Cyan
$tail = Get-Content $KcdLog -Tail 400
foreach ($pat in @('wo1005_nai', 'wo1005_npc')) {
    $hits = $tail | Where-Object { $_ -match $pat -and $_ -notmatch "\[$Tag\]" }
    Write-Host ("  {0,-12} {1} engine line(s)" -f $pat, $hits.Count) -ForegroundColor Yellow
    $hits | Select-Object -Last 8 | ForEach-Object { Write-Host "    $_" }
}
Write-Host ''
Write-Host '== situation / behaviour-tree / faction lines in the same tail ==' -ForegroundColor Cyan
$tail | Where-Object { $_ -match 'for situations|does not have a faction|behavior tree|behaviour tree|role holder' } |
    Select-Object -Last 15 | ForEach-Object { Write-Host "    $_" }
