<#
.SYNOPSIS
    WO-27 Gate 2: reconnect a synthetic peer under the SAME identity multiple
    times WITHOUT closing the prior TCP connection first, and confirm exactly
    one ghost exists for that identity after each reconnect -- counted from
    the live entity list via the API, not assumed from KCD2MP.ghosts agreeing
    with itself.

.DESCRIPTION
    Deliberately does NOT close each connection before opening the next one.
    A clean disconnect already triggers KCD2MP_RemoveGhost via the relay's
    Disconnect broadcast -- that path was never broken. The bug this proves
    fixed is the harder case: the OLD connection is still technically open
    (a crash, a dropped connection the relay hasn't noticed yet) when a NEW
    connection for the same player arrives. The pre-spawn identity dedupe
    (KCD2MP_RemoveStaleGhostsForPlayer, called from KCD2MP_SpawnGhost) is what
    is supposed to catch that.

    Needs: relay running, the real agent (KcdMpClient.exe) running and
    connected, game running via Modding Tools with KCDMP.dll injected.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-GhostReconnect.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $PeerName = 'wo27-reconnect-peer',
    [int]    $Reconnects = 4
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$VERSION    = 6
$HANDSHAKE  = 0x00
$POSITION   = 0x01
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

if (-not (Test-KcdApi)) { throw "debug API not answering" }

$playerPos = Get-KcdValue "/api/rpg/SoulList/PlayerSoul/Position"
$parts = $playerPos -split ','
$px = [float]$parts[0]; $py = [float]$parts[1]; $pz = [float]$parts[2]
Write-Host "player at: $px,$py,$pz"
Write-Host "peer identity: '$PeerName'  (same name every reconnect -- that is the whole test)"
Write-Host ""

$sockets = New-Object System.Collections.Generic.List[object]
$ghostIds = New-Object System.Collections.Generic.List[int]

for ($i = 1; $i -le $Reconnects; $i++) {
    Write-Host "--- reconnect $i of $Reconnects ---"

    $tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
    $s = $tcp.GetStream(); $s.ReadTimeout = 8000
    $sockets.Add($tcp)  # deliberately kept open -- not closed between reconnects

    $nb = [System.Text.Encoding]::UTF8.GetBytes($PeerName)
    $hs = New-Object byte[] (2 + $nb.Length)
    $hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
    Send-Packet $s $HANDSHAKE $hs
    $ackPkt = Read-Packet $s
    if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK) { throw "handshake refused (type $($ackPkt.Type))" }
    $peerId = $ackPkt.Payload[0]
    $ghostIds.Add($peerId)
    Write-Host "  connected as ghost id $peerId (connection kept open, not disconnected)"

    $posPayload = New-Object byte[] 17
    [Array]::Copy([BitConverter]::GetBytes($px), 0, $posPayload, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes($py), 0, $posPayload, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes($pz), 0, $posPayload, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([float]0.0), 0, $posPayload, 12, 4)
    $posPayload[16] = 0
    Send-Packet $s $POSITION $posPayload

    $ghostSoulPath = "/api/rpg/SoulList/SoulsByName/kcd2mp_$peerId"
    $ghostGuid = $null
    $deadline = (Get-Date).AddSeconds(10)
    while (-not $ghostGuid -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $g = Get-KcdValue "$ghostSoulPath/Guid"
        if ($g -notmatch '^ERR') { $ghostGuid = $g }
    }
    if (-not $ghostGuid) { throw "ghost never became a real soul for connection $peerId" }
    Write-Host "  ghost soul ready: kcd2mp_$peerId guid=$ghostGuid"

    # Give the identity dedupe a moment to run and the async removal to land.
    Start-Sleep -Seconds 2

    Write-Host "  checking every PRIOR connection id for this identity is gone:"
    $liveCount = 0
    foreach ($oldId in $ghostIds) {
        $g = Get-KcdValue "/api/rpg/SoulList/SoulsByName/kcd2mp_$oldId/Guid"
        $alive = ($g -notmatch '^ERR')
        if ($alive) { $liveCount++ }
        $tag = if ($oldId -eq $peerId) { "(current)" } else { "(should be gone)" }
        Write-Host "    kcd2mp_$oldId $tag -> $(if ($alive) {'ALIVE'} else {'gone'})"
    }

    if ($liveCount -eq 1) {
        Write-Host "  PASS -- exactly 1 live ghost for '$PeerName' after reconnect $i" -ForegroundColor Green
    } else {
        Write-Host "  FAIL -- $liveCount live ghosts for '$PeerName' after reconnect $i" -ForegroundColor Red
    }
    Write-Host ""
}

Write-Host "=== final state ==="
$finalLive = 0
foreach ($id in $ghostIds) {
    $g = Get-KcdValue "/api/rpg/SoulList/SoulsByName/kcd2mp_$id/Guid"
    if ($g -notmatch '^ERR') { $finalLive++; Write-Host "  kcd2mp_$id : ALIVE" }
}
Write-Host "total live ghosts for '$PeerName' across $Reconnects reconnects: $finalLive"
if ($finalLive -eq 1) {
    Write-Host "GATE 2: PASS" -ForegroundColor Green
} else {
    Write-Host "GATE 2: FAIL" -ForegroundColor Red
}

Write-Host ""
Write-Host "cleaning up: closing all $($sockets.Count) sockets..."
foreach ($tcp in $sockets) { try { $tcp.Close() } catch {} }
