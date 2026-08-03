<#
.SYNOPSIS
    End-to-end reactive aggro: synthetic peer -> relay -> agent -> DLL -> game.

.DESCRIPTION
    The one piece of WO-17 that isn't exercised by Test-Aggro.ps1 (which drives
    the DLL pipe directly): GameBridge's own DamageDown handler actually
    deciding to call SetFactionHostileAsync. A synthetic peer joins the relay,
    sends a Position so the agent spawns a real local ghost for it, then sends
    a Damage packet attributing a hit to a real nearby NPC -- standing in for
    "the peer's ghost just attacked something" exactly the way GameBridge sees
    it from a real second player.

    Needs: relay running, the real agent (KcdMpClient.exe) running and
    connected, game running via Modding Tools with KCDMP.dll injected, and
    mp_enable_aggro already turned on (this script does not flip it, so a
    negative result is unambiguous -- if it were still off, nothing here would
    fire, which would look identical to a real failure).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-AggroE2E.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $SoulName = 'ttkc_man_32',
    [float]  $Health = 3.0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$VERSION    = 6
$HANDSHAKE  = 0x00
$POSITION   = 0x01
$DAMAGE_UP  = 0x12
$ACK        = 0xFF

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3); if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Read-Packet($stream) {
    $head = New-Object byte[] 3; $got = 0
    while ($got -lt 3) { $n = $stream.Read($head, $got, 3 - $got); if ($n -le 0) { return $null }; $got += $n }
    $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
    $body = New-Object byte[] ([Math]::Max($len,1)); $got = 0
    while ($got -lt $len) { $n = $stream.Read($body, $got, $len - $got); if ($n -le 0) { return $null }; $got += $n }
    New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body }
}

function ConvertTo-WireGuid([string] $text) {
    $h = ($text -replace '-', '')
    $b = [byte[]]@(0..15 | ForEach-Object { [Convert]::ToByte($h.Substring($_ * 2, 2), 16) })
    [byte[]]@($b[3],$b[2],$b[1],$b[0], $b[5],$b[4], $b[7],$b[6]) + $b[8..15]
}

if (-not (Test-KcdApi)) { throw "debug API not answering" }
$soulPath = "/api/rpg/SoulList/SoulsByName/$([uri]::EscapeDataString($SoulName))"
$guidText = Get-KcdValue "$soulPath/Guid"
if ($guidText -match '^ERR') { throw "target soul '$SoulName' not found" }
$before = Get-KcdValue "$soulPath/GetState?State=health"
Write-Host "target NPC : $SoulName  guid=$guidText  health=$before"

# Spawn near the real player so the ghost lands somewhere loaded/visible.
$playerPos = Get-KcdValue "/api/rpg/SoulList/PlayerSoul/Position"
$parts = $playerPos -split ','
$px = [float]$parts[0]; $py = [float]$parts[1]; $pz = [float]$parts[2]
Write-Host "spawning synthetic peer's ghost near player: $px,$py,$pz"

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$s = $tcp.GetStream(); $s.ReadTimeout = 8000
$nb = [System.Text.Encoding]::UTF8.GetBytes('synthetic-aggro-peer')
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK) { throw "handshake refused (type $($ackPkt.Type))" }
$peerId = $ackPkt.Payload[0]
Write-Host "1. peer connected to relay as ghost id $peerId"

# Position: [x:4f][y:4f][z:4f][rotZ:4f][flags:1]
$posPayload = New-Object byte[] 17
[Array]::Copy([BitConverter]::GetBytes($px), 0, $posPayload, 0, 4)
[Array]::Copy([BitConverter]::GetBytes($py), 0, $posPayload, 4, 4)
[Array]::Copy([BitConverter]::GetBytes($pz), 0, $posPayload, 8, 4)
[Array]::Copy([BitConverter]::GetBytes([float]0.0), 0, $posPayload, 12, 4)
$posPayload[16] = 0
Send-Packet $s $POSITION $posPayload
Write-Host "2. sent Position -> agent should spawn ghost 'kcd2mp_$peerId'"

Write-Host "   waiting up to 10s for the ghost to become a real soul..."
$ghostSoulPath = "/api/rpg/SoulList/SoulsByName/kcd2mp_$peerId"
$ghostGuid = $null
$deadline = (Get-Date).AddSeconds(10)
while (-not $ghostGuid -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $g = Get-KcdValue "$ghostSoulPath/Guid"
    if ($g -notmatch '^ERR') { $ghostGuid = $g }
}
if (-not $ghostGuid) { throw "ghost never became a real soul -- is the agent running and connected?" }
Write-Host "   ghost soul ready: guid=$ghostGuid"

$wire = ConvertTo-WireGuid $guidText
$p = New-Object byte[] 25
[Array]::Copy($wire,0,$p,0,16)
[Array]::Copy([BitConverter]::GetBytes([float]0.0),0,$p,16,4)
[Array]::Copy([BitConverter]::GetBytes([float]$Health),0,$p,20,4)
$p[24] = 1
Send-Packet $s $DAMAGE_UP $p
Write-Host "3. sent Damage (peer's ghost hit $SoulName for $Health) -- this is the 'ghost commits violence' moment"

Write-Host "   waiting up to 10s for the reactive attach..."
$attached = $false
$deadline = (Get-Date).AddSeconds(10)
while (-not $attached -and (Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    $parentName = Get-KcdValue "$ghostSoulPath/FactionNode/Parent/Name"
    if ($parentName -eq 'trosecko_enemies_bandits_prepadeniAmbushers_group1') { $attached = $true }
}

$after = Get-KcdValue "$soulPath/GetState?State=health"
$damageApplied = [double]$after -lt [double]$before
Write-Host "   NPC health: $before -> $after  (damage applied: $damageApplied)"
Write-Host "   ghost FactionNode/Parent/Name: $(Get-KcdValue "$ghostSoulPath/FactionNode/Parent/Name")"

Write-Host ""
if ($damageApplied -and $attached) {
    Write-Host "PASS - synthetic peer's damage crossed the relay, applied to the NPC, and triggered the reactive aggro attach on the peer's ghost" -ForegroundColor Green
} elseif ($damageApplied -and -not $attached) {
    Write-Host "PARTIAL - damage applied, but the ghost was never attached to the hostile faction (aggro off? GameBridge trigger not firing?)" -ForegroundColor Yellow
} else {
    Write-Host "FAIL - damage never applied (agent/DLL/relay chain broken)" -ForegroundColor Red
}

$tcp.Close()
