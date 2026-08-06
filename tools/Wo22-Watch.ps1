<#
.SYNOPSIS
    WO-22 telemetry watcher for soul-backed test ghosts.

.DESCRIPTION
    Same shape as tools/Wo21-Watch.ps1, but samples entities by their raw
    entity name (these ghosts are spawned directly through
    XGenAIModule.SpawnEntity for testing, not registered in KCD2MP.ghosts),
    and adds a position delta so independent movement -- the thing a
    soul-backed, scheduler-linked ghost can do and a plain ghost cannot --
    is visible per sample rather than inferred afterwards.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Wo22-Watch.ps1 -Ghosts wo22F,wo22G -Samples 20 -IntervalSec 5
#>
[CmdletBinding()]
param(
    [string[]] $Ghosts = @('wo22F','wo22G'),
    [int] $Samples = 12,
    [int] $IntervalSec = 5
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
function Latest-Health([string] $n) {
    $rx = [regex]("\[WO22\] hp\.$n=([^\s]+)")
    $m = $null
    foreach ($line in (Get-Content $KcdLog -Tail 500)) { $x = $rx.Match($line); if ($x.Success) { $m = $x.Groups[1].Value } }
    if ($m) { return $m } else { return '?' }
}

$last = @{}
for ($s = 1; $s -le $Samples; $s++) {
    $idList = ($Ghosts | ForEach-Object { '"' + $_ + '"' }) -join ','
    Lua ('for _,n in ipairs({' + $idList + '}) do local e=System.GetEntityByName(n); local h="?"; if e and e.actor then pcall(function() h=string.format("%.1f", e.actor:GetHealth()) end) end System.LogAlways("[WO22] hp."..n.."="..h) end')
    Start-Sleep -Milliseconds 700

    $stamp = (Get-Date).ToString('HH:mm:ss')
    foreach ($n in $Ghosts) {
        $soul = Api "/api/rpg/SoulList/SoulsByName/$n`?depth=1&exclude=$SoulEx"
        if ($soul -match '^ERR') { "$stamp $n  ERR"; continue }
        $cs = Api "/api/rpg/SoulList/SoulsByName/$n/CombatSoul?depth=1"
        $buffs = Api "/api/rpg/SoulList/SoulsByName/$n/Buffs?depth=1"
        $blist = ([regex]'<string>([^<]+)</string>').Matches($buffs) | ForEach-Object { $_.Groups[1].Value }

        $pos = Attr $soul 'Position'
        $moved = ''
        if ($last.ContainsKey($n) -and $last[$n] -ne $pos) { $moved = 'MOVED' }
        $last[$n] = $pos

        "{0} {1,-6} hp={2,-6} dead={3,-5} unc={4,-5} atk={5,-3} melee={6,-5} {7,-5} pos={8} buffs=[{9}]" -f `
            $stamp, $n, (Latest-Health $n), (Attr $soul 'IsDead'), (Attr $soul 'IsUnconscious'),
            (Attr $cs 'AttackersCount'), (Attr $cs 'HasMeleeWeapon'), $moved, $pos, ($blist -join ',')
    }
    if ($s -lt $Samples) { Start-Sleep -Seconds $IntervalSec }
}
