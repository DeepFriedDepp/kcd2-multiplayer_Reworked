<#
.SYNOPSIS
    WO-39 Phase 1 E2E: one synthetic peer against the REAL running stack
    (game + agent + relay). Two halves, both in one run:

      INBOUND (peer -> ghost): the peer spawns a ghost 2 m from the live
      player (position taken from the emit line in kcd.log and re-sent at
      10 Hz) and then plays the full combat sequence over the wire --
      draw, three swings, a block, sheathe. A human at the machine says
      whether the ghost visibly acted it out; this script can only prove
      the packets flowed.

      OUTBOUND (player -> wire): after the scripted sequence the peer
      stays connected and prints every CombatEventDown (0x2D) it
      receives. The human draws/swings/blocks for real; each input must
      arrive here as the right event byte.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-CombatVizE2E.ps1 -RelayPort 5273
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $RelayPort = 5273,
    [string] $KcdLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log',
    [int]    $ListenSeconds = 45
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')

$HANDSHAKE = 0x00; $POSITION = 0x01; $ACK_TYPE = 0xFF
$COMBAT_UP = 0x2C; $COMBAT_DOWN = 0x2D
$EVT_NAMES = @{ 0 = 'draw'; 1 = 'sheathe'; 2 = 'swing'; 3 = 'block' }

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

# The live player's position, from the newest v2 emit line the mod writes.
function Get-PlayerPos {
    $line = Get-Content $KcdLog -Tail 400 | Where-Object { $_ -match '\[KCD2-MP-DATA\] v2 ' } | Select-Object -Last 1
    if (-not $line) { return $null }
    $f = ($line -replace '.*\[KCD2-MP-DATA\] ', '') -split ' '
    # v2 <seq> <clock> <x> <y> <z> <rotZ> <flags> <health> <stamina>
    New-Object psobject -Property @{ X = [float]$f[3]; Y = [float]$f[4]; Z = [float]$f[5]; Rot = [float]$f[6] }
}

function Send-Position($stream, [float]$x, [float]$y, [float]$z, [float]$rot) {
    $p = New-Object byte[] 17
    [Array]::Copy([BitConverter]::GetBytes($x), 0, $p, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes($y), 0, $p, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes($z), 0, $p, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes($rot), 0, $p, 12, 4)
    $p[16] = 0
    Send-Packet $stream $POSITION $p
}

$pp = Get-PlayerPos
if (-not $pp) { throw "no [KCD2-MP-DATA] v2 line in $KcdLog -- is the game + emitter up?" }
Write-Host ("player at {0:F1},{1:F1},{2:F1} -- ghost will stand 2 m away" -f $pp.X, $pp.Y, $pp.Z)

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $RelayPort)
$s = $tcp.GetStream(); $s.ReadTimeout = 150
$nb = [System.Text.Encoding]::UTF8.GetBytes('wo39-combat-peer')
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $PROTOCOL_VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$s.ReadTimeout = 8000
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK_TYPE) { throw "handshake refused" }
Write-Host "connected as ghost id $([int]$ackPkt.Payload[0])"
$s.ReadTimeout = 100

# Timeline of the scripted inbound sequence (seconds from start). The long
# lead-in exists so a human can physically find the ghost first -- the first
# run of this script played its whole sequence to an unwatched patch of wheat.
$schedule = @(
    @{ At = 30; Evt = 0 },   # draw
    @{ At = 34; Evt = 2 },   # swing
    @{ At = 38; Evt = 2 },   # swing
    @{ At = 42; Evt = 3 },   # block
    @{ At = 46; Evt = 2 },   # swing
    @{ At = 50; Evt = 1 }    # sheathe
)
$sent = @{}
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$lastPos = [DateTime]::MinValue
$seqEnd = 52

Write-Host "`n--- FIND THE GHOST NOW (2 m east of you) -- sequence starts at 30s ---"
Write-Host "--- draw @30s, swings @34/38/46s, block @42s, sheathe @50s ---`n"

while ($sw.Elapsed.TotalSeconds -lt ($seqEnd + $ListenSeconds)) {
    # 10 Hz position keepalive, pinned 2 m from wherever the player NOW is.
    if (([DateTime]::UtcNow - $lastPos).TotalMilliseconds -ge 100) {
        $lastPos = [DateTime]::UtcNow
        $cur = Get-PlayerPos
        if ($cur) { $pp = $cur }
        Send-Position $s ($pp.X + 2.0) ($pp.Y) ($pp.Z) ($pp.Rot)
    }
    foreach ($step in $schedule) {
        if (-not $sent[$step.At] -and $sw.Elapsed.TotalSeconds -ge $step.At) {
            $sent[$step.At] = $true
            Send-Packet $s $COMBAT_UP ([byte[]]@([byte]$step.Evt))
            Write-Host ("[{0,5:F1}s] SENT {1}" -f $sw.Elapsed.TotalSeconds, $EVT_NAMES[$step.Evt])
        }
    }
    if ($sw.Elapsed.TotalSeconds -ge $seqEnd -and -not $listenBanner) {
        $listenBanner = $true
        Write-Host "`n--- sequence done. Now DRAW/SWING/BLOCK/SHEATHE for real; your inputs should print below ---`n"
    }
    $p = Read-Packet $s
    if ($p -and $p.Type -eq $COMBAT_DOWN -and $p.Payload.Length -eq 2) {
        Write-Host ("[{0,5:F1}s] RECEIVED combat event from ghost {1}: {2}" -f
            $sw.Elapsed.TotalSeconds, [int]$p.Payload[0], $EVT_NAMES[[int]$p.Payload[1]])
    }
}
$tcp.Close()
Write-Host "`ndone."
