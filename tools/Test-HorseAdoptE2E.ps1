<#
.SYNOPSIS
    WO-39 Phase 4: horse-adoption live test with one synthetic peer against
    the real running stack. Exercises, in order, the four live-gated WO-38
    Phase 5 behaviours on a REAL world horse:
      1. adoption + ForceMount (HorseInfoUp names the horse, riding flag set)
      2. stream-vs-horse-AI (the mounted pair is driven 15 m away and back)
      3. gait selection (a slow leg, then a fast leg)
      4. release on dismount (empty HorseInfoUp, riding flag cleared)
    A human at the machine reports what actually rendered.

.EXAMPLE
    powershell -File tools\Test-HorseAdoptE2E.ps1 -RelayPort 7778 -HorseName ttkc_horse_3 -X 2311.8 -Y 1967.7 -Z 98.3
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $RelayPort = 7778,
    [Parameter(Mandatory=$true)][string] $HorseName,
    [Parameter(Mandatory=$true)][float] $X,
    [Parameter(Mandatory=$true)][float] $Y,
    [Parameter(Mandatory=$true)][float] $Z
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')

$HANDSHAKE = 0x00; $POSITION = 0x01; $ACK_TYPE = 0xFF; $HORSE_UP = 0x2A

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3); if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Send-Position($stream, [float]$x, [float]$y, [float]$z, [bool]$riding) {
    $p = New-Object byte[] 17
    [Array]::Copy([BitConverter]::GetBytes($x), 0, $p, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes($y), 0, $p, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes($z), 0, $p, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([float]0), 0, $p, 12, 4)
    $p[16] = if ($riding) { 1 } else { 0 }
    Send-Packet $stream $POSITION $p
}

function Send-HorseInfo($stream, [string]$name) {
    $nb = [System.Text.Encoding]::UTF8.GetBytes($name)
    $payload = New-Object byte[] (1 + $nb.Length)
    $payload[0] = [byte]$nb.Length
    if ($nb.Length) { [Array]::Copy($nb, 0, $payload, 1, $nb.Length) }
    Send-Packet $stream $HORSE_UP $payload
}

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $RelayPort)
$s = $tcp.GetStream(); $s.ReadTimeout = 8000
$nb = [System.Text.Encoding]::UTF8.GetBytes('wo39-horse-peer')
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $PROTOCOL_VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$head = New-Object byte[] 3; $got = 0
while ($got -lt 3) { $n = $s.Read($head, $got, 3 - $got); if ($n -le 0) { throw "relay closed" }; $got += $n }
if ($head[0] -ne $ACK_TYPE) { throw "handshake refused" }
$ackLen = [int]$head[1]; $ack = New-Object byte[] $ackLen; $null = $s.Read($ack, 0, $ackLen)
Write-Host "connected as ghost id $([int]$ack[0])"

# Phase A (0-8s): ghost on foot beside the horse.
# Phase B (8s): identity + riding -> adoption + ForceMount.
# Phase C (8-20s): mounted, stationary. Human inspects.
# Phase D (20-44s): slow leg out 15 m (walk gait), fast leg back (gallop gait).
# Phase E (44s): dismount + release. Ghost back on foot beside the horse.
# Phase F (44-60s): hold so the human can inspect the released horse.
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$saidB = $false; $saidD = $false; $saidE = $false
Write-Host "A: ghost on foot beside $HorseName"
while ($sw.Elapsed.TotalSeconds -lt 60) {
    $t = $sw.Elapsed.TotalSeconds
    $gx = $X + 1.5; $gy = $Y; $riding = $false
    if ($t -ge 8 -and $t -lt 44) {
        $riding = $true
        if (-not $saidB) { $saidB = $true; Send-HorseInfo $s $HorseName; Write-Host "B/C: identity '$HorseName' + riding -> WATCH THE MOUNT" }
        $gx = $X; $gy = $Y
        if ($t -ge 20 -and $t -lt 32) {
            if (-not $saidD) { $saidD = $true; Write-Host "D: slow leg out (walk gait expected)" }
            $frac = ($t - 20) / 12.0
            $gx = $X + 15.0 * $frac
        } elseif ($t -ge 32 -and $t -lt 44) {
            $frac = ($t - 32) / 6.0   # twice the speed on the way back
            if ($frac -gt 1) { $frac = 1 }
            $gx = $X + 15.0 * (1 - $frac)
        }
    } elseif ($t -ge 44) {
        if (-not $saidE) { $saidE = $true; Send-HorseInfo $s ''; Write-Host "E/F: dismounted + released -- inspect the horse (own AI back? interactable?)" }
    }
    Send-Position $s $gx $gy $Z $riding
    Start-Sleep -Milliseconds 100
}
$tcp.Close()
Write-Host "done."
