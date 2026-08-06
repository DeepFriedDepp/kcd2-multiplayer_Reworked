<#
.SYNOPSIS
    WO-26 telemetry watcher: soul-backed ghost reactivity under real attack.

.DESCRIPTION
    Extends tools/Wo22-Watch.ps1 with the readings WO-26 actually needs:
    the AI engagement state (AttentionTargetType / PeakThreatLevel /
    AttentionTargetEntity name), the player's own health (so a ghost hitting
    back is visible), and a per-sample position delta in metres rather than a
    MOVED flag, because "fled" and "shuffled" are different results.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Wo26-Watch.ps1 -Ghosts wo26A -Samples 24 -IntervalSec 3
#>
[CmdletBinding()]
param(
    [string[]] $Ghosts = @('wo26A'),
    [int] $Samples = 20,
    [int] $IntervalSec = 3
)

$ApiBase = 'http://localhost:1403'
$KcdLog  = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log'
$SoulEx  = 'DerivedStatsByName,Inventory,EquipmentManager,CompanionManager,StaticData,PersistentData,StormDebug,SoulClass,SocialClass,Archetype,FactionNode,CombatSoul,Buffs,Roles'

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    try { Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { }
}
function Api([string] $path) {
    try { return (Invoke-WebRequest -Uri ($ApiBase + $path) -UseBasicParsing -TimeoutSec 15).Content } catch { return 'ERR' }
}
function Attr([string] $xml, [string] $name) {
    if ($xml -match ('{0}="([^"]*)"' -f $name)) { return $Matches[1] }
    return '?'
}
function Tagged([string] $key) {
    $rx = [regex]("\[WO26\] $key=([^\s]+)")
    $m = $null
    foreach ($line in (Get-Content $KcdLog -Tail 400)) { $x = $rx.Match($line); if ($x.Success) { $m = $x.Groups[1].Value } }
    if ($m) { return $m } else { return '?' }
}

$last = @{}
for ($s = 1; $s -le $Samples; $s++) {
    $idList = ($Ghosts | ForEach-Object { '"' + $_ + '"' }) -join ','
    # One chunk: per-ghost health + AI engagement triple, plus the player's own health.
    Lua ('for _,n in ipairs({' + $idList + '}) do local e=System.GetEntityByName(n); local h,at,pt,ae="?","?","?","?"; if e then if e.actor then pcall(function() h=string.format("%.1f",e.actor:GetHealth()) end) end pcall(function() at=tostring(AI.GetAttentionTargetType(e.id)) end) pcall(function() pt=tostring(AI.GetPeakThreatLevel(e.id)) end) pcall(function() local t=AI.GetAttentionTargetEntity(e.id); if t then ae=t:GetName() end end) end System.LogAlways("[WO26] hp."..n.."="..h) System.LogAlways("[WO26] att."..n.."="..at) System.LogAlways("[WO26] thr."..n.."="..pt) System.LogAlways("[WO26] tgt."..n.."="..ae) end System.LogAlways("[WO26] php="..tostring(player.actor:GetHealth()))')
    Start-Sleep -Milliseconds 900

    $stamp = (Get-Date).ToString('HH:mm:ss')
    $php   = Tagged 'php'
    foreach ($n in $Ghosts) {
        $soul = Api "/api/rpg/SoulList/SoulsByName/$n`?depth=1&exclude=$SoulEx"
        if ($soul -match '^ERR') { "$stamp $n  ERR (gone?)"; continue }
        $cs    = Api "/api/rpg/SoulList/SoulsByName/$n/CombatSoul?depth=1"
        $buffs = Api "/api/rpg/SoulList/SoulsByName/$n/Buffs?depth=1"
        $blist = ([regex]'<string>([^<]+)</string>').Matches($buffs) | ForEach-Object { $_.Groups[1].Value }

        $pos = Attr $soul 'Position'
        $d = ''
        if ($last.ContainsKey($n) -and $last[$n] -ne $pos -and $pos -ne '?') {
            $a = $last[$n] -split ','; $b = $pos -split ','
            if ($a.Count -eq 3 -and $b.Count -eq 3) {
                $d = 'd={0:N2}m' -f [Math]::Sqrt(([double]$b[0]-[double]$a[0]) * ([double]$b[0]-[double]$a[0]) + ([double]$b[1]-[double]$a[1]) * ([double]$b[1]-[double]$a[1]))
            }
        }
        $last[$n] = $pos

        "{0} {1,-6} hp={2,-6} php={3,-5} dead={4,-5} unc={5,-5} atk={6,-3} melee={7,-5} att={8,-3} thr={9,-6} tgt={10,-10} {11,-9} pos={12} buffs=[{13}]" -f `
            $stamp, $n, (Tagged "hp.$n"), $php, (Attr $soul 'IsDead'), (Attr $soul 'IsUnconscious'),
            (Attr $cs 'AttackersCount'), (Attr $cs 'HasMeleeWeapon'),
            (Tagged "att.$n"), (Tagged "thr.$n"), (Tagged "tgt.$n"), $d, $pos, ($blist -join ',')
    }
    if ($s -lt $Samples) { Start-Sleep -Seconds $IntervalSec }
}
