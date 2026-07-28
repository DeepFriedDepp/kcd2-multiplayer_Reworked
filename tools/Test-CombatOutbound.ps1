<#
.SYNOPSIS
    Verifies the outbound half: a hit in our game reaches a peer over the relay.

.DESCRIPTION
    A synthetic peer joins the relay and listens. An NPC near the player is then
    damaged by a route the DLL did not cause, standing in for the player landing
    a blow. The DLL's sampler should notice, the agent should broadcast it, and
    the peer should receive a Damage (0x13) packet naming the same soul.

    Needs: relay, agent, and game with KCDMP.dll injected, all running.
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $SoulName = 'ttkc_man_32',
    [float]  $Health = 9.0
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

function Read-Packet($stream) {
    $head = New-Object byte[] 3; $got = 0
    while ($got -lt 3) { $n = $stream.Read($head, $got, 3 - $got); if ($n -le 0) { return $null }; $got += $n }
    $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
    $body = New-Object byte[] ([Math]::Max($len, 1)); $got = 0
    while ($got -lt $len) { $n = $stream.Read($body, $got, $len - $got); if ($n -le 0) { return $null }; $got += $n }
    New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body; Len = $len }
}

if (-not (Test-KcdApi)) { throw "debug API not answering" }
$soulPath = "/api/rpg/SoulList/SoulsByName/$([uri]::EscapeDataString($SoulName))"
$guidText = Get-KcdValue "$soulPath/Guid"
$before   = Get-KcdValue "$soulPath/GetState?State=health"
Write-Host "target : $SoulName  guid=$guidText  health=$before"

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$stream = $tcp.GetStream(); $stream.ReadTimeout = 10000
$nb = [Text.Encoding]::UTF8.GetBytes('listening-peer')
$hs = New-Object byte[] (2 + $nb.Length); $hs[0] = 3; $hs[1] = [byte]$nb.Length
[Array]::Copy($nb, 0, $hs, 2, $nb.Length)
$stream.Write(([byte[]]@(0x00, ($hs.Length -band 0xFF), 0)), 0, 3)
$stream.Write($hs, 0, $hs.Length); $stream.Flush()
$ackPkt = Read-Packet $stream
if ($null -eq $ackPkt -or $ackPkt.Type -ne 0xFF) { throw "handshake refused" }
Write-Host "peer joined as ghost id $($ackPkt.Payload[0]); listening..."

# Stand in for the player landing a blow.
$null = Get-KcdValue "$soulPath/CombatSoul/TakeDamage?Stamina=0&Health=$Health"
Write-Host "dealt $Health damage locally"

$found = $false
$deadline = (Get-Date).AddSeconds(8)
while (-not $found -and (Get-Date) -lt $deadline) {
    $pkt = Read-Packet $stream
    if ($null -eq $pkt) { break }
    if ($pkt.Type -eq 0x13 -and $pkt.Len -eq 26) {
        $g  = [Guid]::new($pkt.Payload[1..16])
        $hp = [BitConverter]::ToSingle($pkt.Payload, 21)
        Write-Host ("PEER RECEIVED Damage: from ghost {0}, soul {1}, health {2}" -f $pkt.Payload[0], $g, $hp)
        $found = $true
    }
}

$after = Get-KcdValue "$soulPath/GetState?State=health"
Write-Host "local npc health: $before -> $after"
if ($found) { Write-Host "`nPASS - our hit crossed the relay to a peer" -ForegroundColor Green }
else        { Write-Host "`nFAIL - peer saw no Damage packet" -ForegroundColor Red }
$tcp.Close()
