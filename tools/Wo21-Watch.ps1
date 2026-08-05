<#
.SYNOPSIS
    WO-21 A1 reproduction watcher: one telemetry line per ghost per sample.

.DESCRIPTION
    Samples the two paired test ghosts (wo21A = esModularBehaviorTree "",
    wo21B = "IdleSeq") through the debug REST API while a real NPC fights
    them, looking for WO-17 A1's signature: real injuries and health loss,
    IsDead/IsUnconscious staying false, and whether the ghost ever gets
    back up.

    Roles is deliberately NOT sampled. WO-17 read RANENY_NA_ZEMI_MUZ
    ("wounded on the ground") out of the Roles list as evidence of a floored
    state -- but Roles is a static catalogue of every dialogue/animation role
    the soul's archetype can ever play. A freshly spawned ghost that has
    never been touched already lists RANENY_NA_ZEMI_ZENA. It carries no state.

    Health is read through Lua (actor:GetHealth) because Soul does not
    reflect a health attribute.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Wo21-Watch.ps1 -Samples 12 -IntervalSec 5
#>
[CmdletBinding()]
param(
    [string[]] $Ghosts = @('wo21A','wo21B'),
    [int] $Samples = 8,
    [int] $IntervalSec = 5
)

. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$ApiBase = 'http://localhost:1403'
$KcdLog  = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log'
$SoulEx  = 'DerivedStatsByName,Inventory,EquipmentManager,CompanionManager,StaticData,PersistentData,StormDebug,SoulClass,SocialClass,Archetype,FactionNode,CombatSoul,Buffs,Roles'

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    try { Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { }
}
function Attr([string] $xml, [string] $name) {
    if ($xml -match ('{0}="([^"]*)"' -f $name)) { return $Matches[1] }
    return '?'
}
function Latest-Health([string] $id) {
    $rx = [regex]("\[WO21\] hp\.$id=([^\s]+)")
    $m = $null
    foreach ($line in (Get-Content $KcdLog -Tail 400)) { $x = $rx.Match($line); if ($x.Success) { $m = $x.Groups[1].Value } }
    if ($m) { return $m } else { return '?' }
}

for ($s = 1; $s -le $Samples; $s++) {
    # ask the game for both ghosts' health in one console call, then read the log
    $idList = ($Ghosts | ForEach-Object { '"' + $_ + '"' }) -join ','
    Lua ('for _,i in ipairs({' + $idList + '}) do local g=KCD2MP.ghosts[i]; local h="?"; if g and g.entity and g.entity.actor then pcall(function() h=string.format("%.1f", g.entity.actor:GetHealth()) end) end System.LogAlways("[WO21] hp."..i.."="..h) end')
    Start-Sleep -Milliseconds 700

    $stamp = (Get-Date).ToString('HH:mm:ss')
    foreach ($id in $Ghosts) {
        $g = "kcd2mp_$id"
        $soul = Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$g`?depth=1&exclude=$SoulEx" -MaxBytes 30000
        if ($soul -match '^ERR') { "$stamp $g  ERR"; continue }
        $cs = Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$g/CombatSoul?depth=1" -MaxBytes 20000
        $buffs = Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName/$g/Buffs?depth=1" -MaxBytes 30000
        $blist = ([regex]'<string>([^<]+)</string>').Matches($buffs) | ForEach-Object { $_.Groups[1].Value }

        "{0} {1,-6} hp={2,-6} dead={3,-5} unc={4,-5} bleed={5,-5} atk={6,-3} melee={7,-5} pos={8} buffs=[{9}]" -f `
            $stamp, $id, (Latest-Health $id), (Attr $soul 'IsDead'), (Attr $soul 'IsUnconscious'),
            (Attr $soul 'IsBleeding'), (Attr $cs 'AttackersCount'), (Attr $cs 'HasMeleeWeapon'),
            (Attr $soul 'Position'), ($blist -join ',')
    }
    if ($s -lt $Samples) { Start-Sleep -Seconds $IntervalSec }
}
