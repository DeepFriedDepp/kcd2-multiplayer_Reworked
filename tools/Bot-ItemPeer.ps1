<#
.SYNOPSIS
    WO-48 one-machine E2E peer: a synthetic relay client that stands next to
    the real player (so the game spawns a ghost for it), logs every
    dropped-item packet it receives, and can drop one item of its own.

.DESCRIPTION
    The standing constraint: one machine, one copy of the game, no second
    human. This bot is the "player B" half of the WO-48 live tests:

      outbound: the human drops an item by hand -> the real agent detects it
                and puts ItemDropUp on the wire -> the relay forwards -> this
                bot logs "RECV drop ..." (proof the full sender path works
                against the real UI action).
      inbound:  with -DropAfterSec N, the bot sends one ItemDropUp at the
                player's position + offset -> the real agent materializes it
                in the human's world -> the human picks it up by hand -> the
                real agent claims -> this bot logs "RECV claim ..." (proof of
                the full receiver path plus the claim wire).

    Position is streamed at a fixed spot ~3 m from wherever the player was at
    startup, read from the debug REST API like Bot-WalkingGhost. The bot needs
    a ghost body in the human's world anyway -- the mod's materializer places
    items through a ghost's inventory/human.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Bot-ItemPeer.ps1 -Port 7778 -Seconds 180

.EXAMPLE
    # Also drop one onion 2 m from the player after 10 s
    powershell -ExecutionPolicy Bypass -File tools\Bot-ItemPeer.ps1 -Port 7778 -DropAfterSec 10
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port      = 7778,
    [string] $Name      = 'ItemBot',
    [int]    $Seconds   = 180,
    [int]    $RateHz    = 10,
    [string] $GameApi   = 'http://localhost:1403',

    # 0 = never drop; N = send one ItemDropUp N seconds after connecting.
    [double] $DropAfterSec = 0,
    # What to drop. Default: onion (any real ItemClass GUID works).
    [string] $DropClass  = '4a6fa310-067a-404d-9813-bd1761d1c70d',
    [int]    $DropAmount = 1,
    [double] $DropHealth = 0.9,
    # Where, relative to the player position read at startup.
    [double] $DropOffX = 2.0,
    [double] $DropOffY = 0.0,
    [uint32] $DropId   = 900001
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')

$T_HANDSHAKE      = 0x00
$T_POSITION       = 0x01
$T_ACK            = 0xFF
$T_ITEMDROP_UP    = 0x32
$T_ITEMDROP_DOWN  = 0x33
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

# --- player position from the debug REST API (Bot-WalkingGhost's read; the
# endpoint answers XML "<Vector>x,y,z</Vector>", so regex, not JSON) ---
$centre = $null
try {
    $c = (Invoke-WebRequest -Uri "$GameApi/api/rpg/SoulList/SoulsByName/Dude/Position" -UseBasicParsing -TimeoutSec 8).Content
    if ($c -match '>([-\d.]+),([-\d.]+),([-\d.]+)<') {
        $centre = [pscustomobject]@{ X = [double]$Matches[1]; Y = [double]$Matches[2]; Z = [double]$Matches[3] }
    }
} catch { }
if ($null -eq $centre) { throw "Could not read the player position from $GameApi -- is the game running with a save loaded?" }
Write-Host ("player at    : {0:F2}, {1:F2}, {2:F2}" -f $centre.X, $centre.Y, $centre.Z)
$botX = [float]($centre.X + 3.0); $botY = [float]($centre.Y + 1.0); $botZ = [float]$centre.Z

# --- connect ---
$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$stream = $tcp.GetStream(); $stream.ReadTimeout = 30
$nb = [System.Text.Encoding]::UTF8.GetBytes($Name)
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $PROTOCOL_VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
$stream.ReadTimeout = 8000
Send-Packet $stream $T_HANDSHAKE $hs
$ackPkt = Read-Packet $stream
if ($null -eq $ackPkt -or $ackPkt.Type -ne $T_ACK) { throw "handshake refused" }
Write-Host ("connected    : id={0} as '{1}'" -f [int]$ackPkt.Payload[0], $Name)
$stream.ReadTimeout = 30

# position payload: [x][y][z][rotZ][flags]
$posPayload = New-Object byte[] 17
[Array]::Copy([BitConverter]::GetBytes($botX), 0, $posPayload, 0, 4)
[Array]::Copy([BitConverter]::GetBytes($botY), 0, $posPayload, 4, 4)
[Array]::Copy([BitConverter]::GetBytes($botZ), 0, $posPayload, 8, 4)
[Array]::Copy([BitConverter]::GetBytes([float]0), 0, $posPayload, 12, 4)
$posPayload[16] = 0

$dropSent = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$tickMs = [int](1000 / $RateHz)
Write-Host "streaming position; logging item packets. Ctrl+C to stop."

while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
    Send-Packet $stream $T_POSITION $posPayload

    if (-not $dropSent -and $DropAfterSec -gt 0 -and $sw.Elapsed.TotalSeconds -ge $DropAfterSec) {
        $dropSent = $true
        $payload = New-Object byte[] 38
        [Array]::Copy([BitConverter]::GetBytes($DropId), 0, $payload, 0, 4)
        [Array]::Copy(([Guid]$DropClass).ToByteArray(), 0, $payload, 4, 16)
        [Array]::Copy([BitConverter]::GetBytes([uint16]$DropAmount), 0, $payload, 20, 2)
        [Array]::Copy([BitConverter]::GetBytes([float]$DropHealth), 0, $payload, 22, 4)
        [Array]::Copy([BitConverter]::GetBytes([float]($centre.X + $DropOffX)), 0, $payload, 26, 4)
        [Array]::Copy([BitConverter]::GetBytes([float]($centre.Y + $DropOffY)), 0, $payload, 30, 4)
        [Array]::Copy([BitConverter]::GetBytes([float]$centre.Z), 0, $payload, 34, 4)
        Send-Packet $stream $T_ITEMDROP_UP $payload
        Write-Host ("SENT drop    : dropId={0} class={1} x{2} at {3:F1},{4:F1},{5:F1}" -f `
            $DropId, $DropClass, $DropAmount, ($centre.X + $DropOffX), ($centre.Y + $DropOffY), $centre.Z)
    }

    # drain whatever the relay pushed since the last tick
    while ($true) {
        $p = Read-Packet $stream
        if ($null -eq $p) { break }
        if ($p.Type -eq $T_ITEMDROP_DOWN -and $p.Payload.Length -eq 39) {
            $classBytes = New-Object byte[] 16
            [Array]::Copy($p.Payload, 5, $classBytes, 0, 16)
            Write-Host ("RECV drop    : src={0} dropId={1} class={2} x{3} health={4:F3} at {5:F1},{6:F1},{7:F1}" -f `
                [int]$p.Payload[0], [BitConverter]::ToUInt32($p.Payload,1), (New-Object Guid (,$classBytes)),
                [BitConverter]::ToUInt16($p.Payload,21), [BitConverter]::ToSingle($p.Payload,23),
                [BitConverter]::ToSingle($p.Payload,27), [BitConverter]::ToSingle($p.Payload,31),
                [BitConverter]::ToSingle($p.Payload,35))
        }
        elseif ($p.Type -eq $T_ITEMCLAIM_DOWN -and $p.Payload.Length -eq 5) {
            Write-Host ("RECV claim   : claimer={0} dropId={1}" -f [int]$p.Payload[0], [BitConverter]::ToUInt32($p.Payload,1))
        }
    }

    Start-Sleep -Milliseconds $tickMs
}

$tcp.Close()
Write-Host "done."
