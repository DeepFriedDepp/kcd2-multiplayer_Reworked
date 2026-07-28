<#
.SYNOPSIS
    End-to-end combat replication: synthetic peer -> relay -> agent -> DLL -> game.

.DESCRIPTION
    Plays the part of a second player without needing one. A synthetic TCP
    client handshakes with the relay as protocol v3 and sends a Damage packet
    naming a real SharedSoulGuid; the running agent receives it, pushes it down
    the pipe to KCDMP.dll, and the DLL applies it on the game thread. The effect
    is then verified through the debug REST API.

    Needs: relay running, agent running and connected, game running via Modding
    Tools with KCDMP.dll injected.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-CombatE2E.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $SoulName = 'ttkc_man_32',
    [float]  $Health = 6.0,
    [switch] $Kill
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$HANDSHAKE = 0x00; $ACK = 0xFF; $DAMAGE_UP = 0x12; $DEATH_UP = 0x14
$VERSION = 3

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

# Text form -> the game's in-memory byte order (first three fields reversed).
function ConvertTo-WireGuid([string] $text) {
    $h = ($text -replace '-', '')
    $b = [byte[]]@(0..15 | ForEach-Object { [Convert]::ToByte($h.Substring($_ * 2, 2), 16) })
    [byte[]]@($b[3],$b[2],$b[1],$b[0], $b[5],$b[4], $b[7],$b[6]) + $b[8..15]
}

if (-not (Test-KcdApi)) { throw "debug API not answering" }
$soulPath = "/api/rpg/SoulList/SoulsByName/$([uri]::EscapeDataString($SoulName))"
$guidText = Get-KcdValue "$soulPath/Guid"
if ($guidText -match '^ERR') { throw "soul '$SoulName' not found" }
$before = Get-KcdValue "$soulPath/GetState?State=health"
Write-Host "target : $SoulName  guid=$guidText  health=$before"

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$s = $tcp.GetStream(); $s.ReadTimeout = 5000
$nb = [System.Text.Encoding]::UTF8.GetBytes('synthetic-peer')
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK) { throw "handshake refused (type $($ackPkt.Type)) - relay and agent on the same build?" }
Write-Host "peer connected to relay as ghost id $($ackPkt.Payload[0])"

$wire = ConvertTo-WireGuid $guidText
if ($Kill) {
    Send-Packet $s $DEATH_UP $wire
    Write-Host "sent Death for $SoulName"
} else {
    $p = New-Object byte[] 25
    [Array]::Copy($wire,0,$p,0,16)
    [Array]::Copy([BitConverter]::GetBytes([float]0.0),0,$p,16,4)
    [Array]::Copy([BitConverter]::GetBytes([float]$Health),0,$p,20,4)
    $p[24] = 1
    Send-Packet $s $DAMAGE_UP $p
    Write-Host "sent Damage health=$Health for $SoulName"
}

Start-Sleep -Seconds 2
$after = Get-KcdValue "$soulPath/GetState?State=health"
$dead  = Get-KcdValue "$soulPath/IsDead"
Write-Host "health : $before -> $after   IsDead=$dead"

if (([double]$after -lt [double]$before) -or ($dead -eq 'true')) {
    Write-Host "`nPASS - a remote player's hit crossed the relay and landed in the game" -ForegroundColor Green
} else {
    Write-Host "`nFAIL - no effect (agent connected? DLL injected? soul loaded?)" -ForegroundColor Red
}
$tcp.Close()
