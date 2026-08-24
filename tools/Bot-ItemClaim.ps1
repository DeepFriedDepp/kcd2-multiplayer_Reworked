<#
.SYNOPSIS
    WO-48 one-shot: connect a synthetic peer, send one ItemClaimUp for a given
    dropId, print every ItemClaimDown echo for a few seconds, disconnect.
    The "another player grabbed it first" half of the race, with one human.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Bot-ItemClaim.ps1 -Port 7778 -DropId 123456789
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port      = 7778,
    [string] $Name      = 'ClaimBot',
    [Parameter(Mandatory = $true)][uint32] $DropId,
    [int]    $ListenSec = 6
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')

$T_HANDSHAKE      = 0x00
$T_ACK            = 0xFF
$T_ITEMCLAIM_UP   = 0x34
$T_ITEMCLAIM_DOWN = 0x35

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3); if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Read-Packet($stream) {
    try {
        $head = New-Object byte[] 3; $got = 0
        while ($got -lt 3) { $n = $stream.Read($head, $got, 3 - $got); if ($n -le 0) { return $null }; $got += $n }
        $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
        $body = New-Object byte[] ([Math]::Max($len,1)); $got = 0
        while ($got -lt $len) { $n = $stream.Read($body, $got, $len - $got); if ($n -le 0) { return $null }; $got += $n }
        New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body }
    } catch [System.IO.IOException] { $null }
}

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$stream = $tcp.GetStream(); $stream.ReadTimeout = 8000
$nb = [System.Text.Encoding]::UTF8.GetBytes($Name)
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $PROTOCOL_VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $stream $T_HANDSHAKE $hs
$ackPkt = Read-Packet $stream
if ($null -eq $ackPkt -or $ackPkt.Type -ne $T_ACK) { throw "handshake refused" }
Write-Host ("connected id={0} as '{1}'" -f [int]$ackPkt.Payload[0], $Name)

Send-Packet $stream $T_ITEMCLAIM_UP ([BitConverter]::GetBytes($DropId))
Write-Host ("SENT claim   : dropId={0}" -f $DropId)

$stream.ReadTimeout = 400
$deadline = (Get-Date).AddSeconds($ListenSec)
while ((Get-Date) -lt $deadline) {
    $p = Read-Packet $stream
    if ($null -eq $p) { continue }
    if ($p.Type -eq $T_ITEMCLAIM_DOWN -and $p.Payload.Length -eq 5) {
        Write-Host ("RECV claim   : claimer={0} dropId={1}" -f [int]$p.Payload[0], [BitConverter]::ToUInt32($p.Payload,1))
    }
}
$tcp.Close()
Write-Host "done."
