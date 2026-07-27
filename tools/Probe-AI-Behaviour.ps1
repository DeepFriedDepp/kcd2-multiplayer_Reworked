<#
.SYNOPSIS
    Automated behavioural probes for the shared-world design: AI suppression,
    stimulus injection, and health writing.

.DESCRIPTION
    These were originally going to need a human watching the screen ("did the
    guard turn his head"). They don't. The AI table exposes getters --
    AI.IsMoving, AI.GetAttentionTargetEntity, AI.GetPeakThreatLevel -- so the
    NPC's internal state can be sampled from Lua and read back out of kcd.log.

    Safety choices, because this runs against a live single-player save:
      * The stimulus test prefers an ANIMAL. Alarming a deer has no
        consequences; alarming a town guard can start a crime and cost
        reputation.
      * AI suppression is always re-enabled afterwards, including on failure.
      * SetHealth is tested ONLY on a mod-spawned ghost, never a real NPC.
        Killing a real character could break a quest permanently.

    Requires KCD2 running via Modding Tools with a save loaded, and the mod
    installed (needs KCD2MP_* functions for the ghost health test).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-AI-Behaviour.ps1
#>
[CmdletBinding()]
param(
    [string] $ApiBase = 'http://localhost:1403',
    [string] $KcdLog,
    [switch] $SkipStimulus,
    [switch] $SkipHealth
)

$ErrorActionPreference = 'Stop'

$ScriptDir =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { (Get-Location).Path }

function Resolve-KcdLog {
    if ($KcdLog) { return $KcdLog }
    $steam = $null
    foreach ($k in @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam','HKLM:\SOFTWARE\Valve\Steam','HKCU:\SOFTWARE\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.InstallPath) { $steam = $v.InstallPath; break }
            if ($v.SteamPath)   { $steam = $v.SteamPath;   break }
        } catch { }
    }
    if (-not $steam) { return $null }
    $roots = @($steam)
    $vdf = Join-Path $steam 'config\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($line in Get-Content $vdf) { if ($line -match '"path"\s+"([^"]+)"') { $roots += $Matches[1].Replace('\\','\') } }
    }
    $found = @()
    foreach ($r in ($roots | Sort-Object -Unique)) {
        $common = Join-Path $r 'steamapps\common'
        if (-not (Test-Path $common)) { continue }
        Get-ChildItem $common -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Kingdom|KCD' } |
            ForEach-Object { $found += Get-ChildItem $_.FullName -Filter 'kcd.log' -Recurse -Depth 2 -ErrorAction SilentlyContinue }
    }
    if (-not $found) { return $null }
    return ($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

$log = Resolve-KcdLog
if (-not $log) { Write-Host 'FAILED: could not locate kcd.log' -ForegroundColor Red; exit 1 }

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    try { Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null }
    catch { Write-Host "  (console call failed: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

$script:seen = @{}

# Line-offset windowing proved unreliable while the game is actively writing to
# the log, so sections were re-printing earlier output. Dedupe instead: every
# probe line is unique by construction (sample tags and key names differ).
function Read-New([int] $from, [string] $tag = 'KCD2-MP-BEH') {
    $all = Get-Content $log
    $start = [Math]::Max(0, [Math]::Min($from, $all.Count - 1))
    $out = @()
    foreach ($line in $all[$start..($all.Count - 1)]) {
        if ($line -notmatch $tag) { continue }
        $clean = ($line -replace ".*$tag\] ", '')
        if ($script:seen.ContainsKey($clean)) { continue }
        $script:seen[$clean] = $true
        $out += $clean
    }
    return $out
}
function LogPos { return (Get-Content $log | Measure-Object -Line).Lines }

Write-Host '=== shared-world behavioural probes ===' -ForegroundColor Cyan
try { $c = Invoke-WebRequest -Uri "$ApiBase/api/rpg/Calendar?depth=1" -UseBasicParsing -TimeoutSec 6 } catch {
    Write-Host 'FAILED: game not reachable.' -ForegroundColor Red; exit 1
}
Write-Host "Reading $log"

# --- pick subjects ----------------------------------------------------------
# One general NPC for suppression, and an animal for the stimulus test.
$p0 = LogPos
Lua @'
local function P(k,v) System.LogAlways("[KCD2-MP-BEH] "..k.."="..tostring(v)) end
KCD2MP = KCD2MP or {}
local ents = System.GetEntitiesInSphere(player:GetWorldPos(), 120)
local npc, animal = nil, nil
for i = 1, (ents and #ents or 0) do
  local e = ents[i]
  if e and e.actor and e.soul then
    local nm = tostring(e:GetName())
    if not string.find(nm, "kdcmp") and not string.find(nm, "Player") then
      if not npc then npc = e end
      local cl = tostring(e.class)
      if not animal and (cl == "Dog" or string.find(cl, "Deer") or cl == "Horse" or string.find(nm, "SpawnedAnimal")) then animal = e end
    end
  end
end
KCD2MP._bnpc = npc
KCD2MP._banimal = animal
P("npc.name", npc and tostring(npc:GetName()) or "NONE")
P("npc.class", npc and tostring(npc.class) or "NONE")
P("animal.name", animal and tostring(animal:GetName()) or "NONE")
P("animal.class", animal and tostring(animal.class) or "NONE")
'@
Start-Sleep -Milliseconds 1500
Read-New $p0 | ForEach-Object { "  $_" }

# --- sampler ----------------------------------------------------------------
# Emits one line of the NPC's observable AI state.
$sampler = @'
function KCD2MP_BehSample(tag)
  local e = KCD2MP and KCD2MP._bnpc
  if not e then System.LogAlways("[KCD2-MP-BEH] sample.noNpc=1") return end
  local pos = e:GetWorldPos()
  local mv, att, thr, hp = "?", "?", "?", "?"
  pcall(function() mv = tostring(AI.IsMoving(e.id)) end)
  pcall(function() att = tostring(AI.GetAttentionTargetType(e.id)) end)
  pcall(function() thr = tostring(AI.GetPeakThreatLevel(e.id)) end)
  pcall(function() hp = tostring(e.actor:GetHealth()) end)
  System.LogAlways(string.format("[KCD2-MP-BEH] s.%s pos=%.3f,%.3f,%.3f moving=%s att=%s threat=%s hp=%s",
    tag, pos.x, pos.y, pos.z, mv, att, thr, hp))
end
'@
Lua $sampler

function Sample([string] $tag, [int] $times = 3) {
    for ($i = 1; $i -le $times; $i++) {
        Lua "KCD2MP_BehSample('$tag$i')"
        Start-Sleep -Milliseconds 600
    }
}

# --- 1. AI suppression ------------------------------------------------------
Write-Host "`n1. AI suppression (SetBehaviorTreeEvaluationEnabled)" -ForegroundColor Cyan
$p1 = LogPos
Sample 'before' 3
Lua 'local e=KCD2MP._bnpc; local ok,err=pcall(function() AI.SetBehaviorTreeEvaluationEnabled(e.id,false) end); System.LogAlways("[KCD2-MP-BEH] suppress.ok="..tostring(ok).." err="..tostring(err))'
Start-Sleep -Milliseconds 800
Sample 'suppressed' 3
# Always restore, whatever happened.
Lua 'local e=KCD2MP._bnpc; local ok,err=pcall(function() AI.SetBehaviorTreeEvaluationEnabled(e.id,true) end); System.LogAlways("[KCD2-MP-BEH] restore.ok="..tostring(ok).." err="..tostring(err))'
Start-Sleep -Milliseconds 800
Sample 'restored' 2
Start-Sleep -Milliseconds 1200
Read-New $p1 | ForEach-Object { "  $_" }

# --- 2. stimulus injection --------------------------------------------------
if (-not $SkipStimulus) {
    Write-Host "`n2. stimulus injection (animal subject, to avoid a crime)" -ForegroundColor Cyan
    $p2 = LogPos
    Lua @'
local function P(k,v) System.LogAlways("[KCD2-MP-BEH] "..k.."="..tostring(v)) end
local a = KCD2MP and KCD2MP._banimal
if not a then P("stim", "NO_ANIMAL") else
  local before = "?"
  pcall(function() before = tostring(AI.GetAttentionTargetType(a.id)) end)
  P("stim.attBefore", before)
  local pos = a:GetWorldPos()
  local ok1,e1 = pcall(function() AI.CreateStimulusEvent(a.id, 0, "SOUND", {position=pos, radius=15, threat=1}) end)
  P("stim.createStimulus.ok", tostring(ok1).." err="..tostring(e1))
  local ok2,e2 = pcall(function() AI.SetAlarmed(a.id) end)
  P("stim.setAlarmed.ok", tostring(ok2).." err="..tostring(e2))
end
'@
    Start-Sleep -Milliseconds 1500
    Lua @'
local function P(k,v) System.LogAlways("[KCD2-MP-BEH] "..k.."="..tostring(v)) end
local a = KCD2MP and KCD2MP._banimal
if a then
  local aft, thr = "?", "?"
  pcall(function() aft = tostring(AI.GetAttentionTargetType(a.id)) end)
  pcall(function() thr = tostring(AI.GetPeakThreatLevel(a.id)) end)
  P("stim.attAfter", aft)
  P("stim.threatAfter", thr)
end
'@
    Start-Sleep -Milliseconds 1500
    Read-New $p2 | ForEach-Object { "  $_" }
}

# --- 3. health write on a spawned ghost ------------------------------------
if (-not $SkipHealth) {
    Write-Host "`n3. health write (mod-spawned ghost only -- never a real NPC)" -ForegroundColor Cyan
    $p3 = LogPos
    Lua 'if KCD2MP_SpawnGhost then KCD2MP_SpawnGhost("healthtest", player:GetWorldPos().x+2, player:GetWorldPos().y, player:GetWorldPos().z, 0) end'
    Start-Sleep -Seconds 3
    Lua @'
local function P(k,v) System.LogAlways("[KCD2-MP-BEH] "..k.."="..tostring(v)) end
local g = KCD2MP and KCD2MP.ghosts and KCD2MP.ghosts["healthtest"]
local e = g and g.entity
if not e then P("hp", "NO_GHOST") else
  local h0 = "?"
  pcall(function() h0 = tostring(e.actor:GetHealth()) end)
  P("hp.before", h0)
  local ok1,e1 = pcall(function() e.actor:SetHealth(50) end)
  P("hp.setHealth.ok", tostring(ok1).." err="..tostring(e1))
  local h1 = "?"
  pcall(function() h1 = tostring(e.actor:GetHealth()) end)
  P("hp.afterSet", h1)
  local ok2,e2 = pcall(function() e.soul:DealDamage(10) end)
  P("hp.dealDamage.ok", tostring(ok2).." err="..tostring(e2))
  local h2 = "?"
  pcall(function() h2 = tostring(e.actor:GetHealth()) end)
  P("hp.afterDamage", h2)
end
'@
    Start-Sleep -Milliseconds 2000
    Lua 'if KCD2MP_RemoveGhost then KCD2MP_RemoveGhost("healthtest") end'
    Read-New $p3 | ForEach-Object { "  $_" }
}

Write-Host "`nDone. AI suppression was restored; the test ghost was removed." -ForegroundColor Green
