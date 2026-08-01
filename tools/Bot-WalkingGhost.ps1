<#
.SYNOPSIS
    Connects a synthetic peer to the relay that walks a slow circle around the
    real player, so a human can watch a remote ghost actually move.

.DESCRIPTION
    Built for WO-13's before/after check: the bug is that every other player's
    ghost freezes on YOUR screen while YOU have a menu open, because
    Script.SetTimer -- which schedules KCD2MP_InterpTick -- is frozen for the
    duration of a local menu (WO-12 s0.3). A frozen ghost and a ghost whose
    peer simply stopped walking look identical, so reproducing the bug needs a
    peer that is provably still moving. Hence a bot rather than a second human.

    This drives the relay directly over TCP, the same synthetic-peer approach
    as Test-Combat.ps1 / Test-Pause.ps1 and for the same reason: one machine,
    one copy of the game.

    The orbit centre is read live from the debug REST API, so the ghost circles
    wherever the player actually is. Radius is deliberately small and the
    ghost is placed at the player's own Z -- this is for looking at, not for
    pathfinding.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Bot-WalkingGhost.ps1 -Port 7779

.EXAMPLE
    # Faster orbit, wider circle, run for two minutes
    powershell -ExecutionPolicy Bypass -File tools\Bot-WalkingGhost.ps1 -Radius 6 -PeriodSec 8 -Seconds 120
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port      = 7779,
    [string] $Name      = 'WalkerBot',
    [double] $Radius    = 4.0,
    [double] $PeriodSec = 12.0,
    [int]    $Seconds   = 120,
    [int]    $RateHz    = 10,
    [string] $GameApi   = 'http://localhost:1403',

    # Simulates the bot's player opening a menu, for WO-13 Phase 2's "[in menu]"
    # indicator: at -MenuAtSec it sends PauseUp(entered) and stops walking (a
    # player in a menu cannot move -- WO-12 s0.3), then -MenuForSec later sends
    # PauseUp(exited) and carries on. Zero disables it.
    [double] $MenuAtSec  = 0,
    [double] $MenuForSec = 15
)

$ErrorActionPreference = 'Stop'

$PROTOCOL_VERSION = 6
$T_HANDSHAKE = 0x00
$T_POSITION  = 0x01
$T_PAUSEUP   = 0x1C
$T_ACK       = 0xFF
$STATE_ENTERED = 1
$STATE_EXITED  = 0

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = New-Object byte[] 3
    $head[0] = $type
    $head[1] = [byte]($payload.Length -band 0xFF)
    $head[2] = [byte](($payload.Length -shr 8) -band 0xFF)
    $stream.Write($head, 0, 3)
    if ($payload.Length -gt 0) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Get-PlayerPos {
    try {
        $c = (Invoke-WebRequest -Uri "$GameApi/api/rpg/SoulList/SoulsByName/Dude/Position" `
                                -TimeoutSec 8 -UseBasicParsing).Content
        if ($c -match '>([-\d.]+),([-\d.]+),([-\d.]+)<') {
            return [pscustomobject]@{
                X = [double]$Matches[1]; Y = [double]$Matches[2]; Z = [double]$Matches[3]
            }
        }
    } catch { }
    return $null
}

$centre = Get-PlayerPos
if (-not $centre) {
    throw "Could not read the player position from $GameApi -- is the game running with a save loaded?"
}
Write-Host ("orbit centre : {0:F2}, {1:F2}, {2:F2}" -f $centre.X, $centre.Y, $centre.Z)

$client = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$stream = $client.GetStream()
$stream.ReadTimeout = 5000

$nb = [System.Text.Encoding]::UTF8.GetBytes($Name)
$hp = New-Object byte[] (2 + $nb.Length)
$hp[0] = [byte]$PROTOCOL_VERSION
$hp[1] = [byte]$nb.Length
[Array]::Copy($nb, 0, $hp, 2, $nb.Length)
Send-Packet $stream $T_HANDSHAKE $hp

# Drain the Ack so the assigned ghost id can be reported -- purely informational,
# but it is the one cheap confirmation that the relay accepted the handshake
# rather than silently dropping a version mismatch.
try {
    $head = New-Object byte[] 3
    if ($stream.Read($head, 0, 3) -eq 3) {
        $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
        $body = New-Object byte[] $len
        if ($len -gt 0) { [void]$stream.Read($body, 0, $len) }
        if ($head[0] -eq $T_ACK -and $len -ge 1) {
            Write-Host "relay assigned ghost id $($body[0])"
        } else {
            Write-Host "unexpected first packet: type=0x$('{0:X2}' -f $head[0])" -ForegroundColor Yellow
        }
    }
} catch { Write-Host "no Ack read (continuing)" -ForegroundColor Yellow }

Write-Host "walking for ${Seconds}s at ${RateHz} Hz -- Ctrl+C to stop early`n"

$sw       = [Diagnostics.Stopwatch]::StartNew()
$delayMs  = [int](1000 / $RateHz)
$sent     = 0
$lastNote = 0.0
$menuOn   = $false
$menuDone = $false
# Angle the bot was standing at when it "opened its menu", so it resumes the
# orbit from where it stopped rather than teleporting to where it would have
# been had it kept walking.
$frozenTheta = 0.0
$menuElapsed = 0.0

try {
    while ($sw.Elapsed.TotalSeconds -lt $Seconds -and $client.Connected) {
        $t = $sw.Elapsed.TotalSeconds

        if ($MenuAtSec -gt 0 -and -not $menuDone) {
            if (-not $menuOn -and $t -ge $MenuAtSec) {
                $menuOn = $true
                $frozenTheta = 2.0 * [Math]::PI * (($t - $menuElapsed) / $PeriodSec)
                Send-Packet $stream $T_PAUSEUP @([byte]$STATE_ENTERED)
                Write-Host "  -> PauseUp(entered): bot is 'in a menu' and has stopped walking" -ForegroundColor Cyan
            }
            elseif ($menuOn -and $t -ge ($MenuAtSec + $MenuForSec)) {
                $menuOn = $false
                $menuDone = $true
                $menuElapsed = $MenuForSec
                Send-Packet $stream $T_PAUSEUP @([byte]$STATE_EXITED)
                Write-Host "  -> PauseUp(exited): bot is walking again" -ForegroundColor Cyan
            }
        }

        $theta = if ($menuOn) { $frozenTheta }
                 else { 2.0 * [Math]::PI * (($t - $menuElapsed) / $PeriodSec) }

        $x = $centre.X + $Radius * [Math]::Cos($theta)
        $y = $centre.Y + $Radius * [Math]::Sin($theta)
        $z = $centre.Z
        # Face along the tangent so the ghost looks like it is walking its
        # circle rather than moon-walking around it.
        $rot = [double]($theta + [Math]::PI / 2.0)

        $payload = New-Object byte[] 17
        [Array]::Copy([BitConverter]::GetBytes([single]$x),   0, $payload,  0, 4)
        [Array]::Copy([BitConverter]::GetBytes([single]$y),   0, $payload,  4, 4)
        [Array]::Copy([BitConverter]::GetBytes([single]$z),   0, $payload,  8, 4)
        [Array]::Copy([BitConverter]::GetBytes([single]$rot), 0, $payload, 12, 4)
        $payload[16] = 0   # flags: not riding

        Send-Packet $stream $T_POSITION $payload
        $sent++

        if ($t - $lastNote -ge 5.0) {
            $lastNote = $t
            Write-Host ("  t={0,5:F1}s  sent={1,5}  pos={2:F2},{3:F2}" -f $t, $sent, $x, $y)
        }
        Start-Sleep -Milliseconds $delayMs
    }
}
finally {
    Write-Host "`nsent $sent position packets in $([math]::Round($sw.Elapsed.TotalSeconds,1))s"
    try { $stream.Close() } catch { }
    try { $client.Close() } catch { }
    Write-Host "disconnected -- the ghost should now despawn"
}
