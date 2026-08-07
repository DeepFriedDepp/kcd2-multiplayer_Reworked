<#
.SYNOPSIS
    Exercises the WO-11 pause-mitigation relay packets against a running relay.

.DESCRIPTION
    Drives synthetic TCP clients straight at the relay, same approach as
    Test-Combat.ps1 and for the same reason: there is one machine and one copy
    of the game, so the wire must be testable without either.

    Covers: PauseUp forwarding tagged with the sender's ghost id, both state
    transitions (entered/exited), no echo back to the sender, and
    malformed-length rejection.

    This only exercises the relay side, which is unchanged since WO-11: the
    relay still just forwards the packet, tagged with the sender's ghost id.

    What a RECEIVER does with it changed in WO-13. WO-11 had every receiver
    slow its own t_scale while any peer was paused; that is retired and must
    not come back (it penalises a whole session for one person's menu). The
    packet is now a pure presence signal -- the peer's ghost gets an
    "[in menu]" nameplate tag. Both the detection (kcd.log marker tailing) and
    that response are client-side with no relay involvement; see
    docs/WO-13-findings.md and GameBridge.cs's ApplyPeerPauseAsync for how
    they were verified live.

    Start the relay first, e.g.
        dotnet run --project dotnet\KcdMp.Server -- --port 7778

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Pause.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778
)

$ErrorActionPreference = 'Stop'

# Protocol constants, mirrored from Protocol.cs.
$P = @{
    Handshake = 0x00; Ack = 0xFF; VersionMismatch = 0x09
    PauseUp = 0x1C; PauseDown = 0x1D
}
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION, read from Protocol.cs
$STATE_ENTERED = 1
$STATE_EXITED  = 0

$script:pass = 0
$script:fail = 0

function Ok([string] $m)   { $script:pass++; Write-Host "  PASS  $m" -ForegroundColor Green }
function Bad([string] $m)  { $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Check([bool] $cond, [string] $m) { if ($cond) { Ok $m } else { Bad $m } }

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

function Read-Packet($stream) {
    try {
        $head = New-Object byte[] 3
        $got = 0
        while ($got -lt 3) {
            $n = $stream.Read($head, $got, 3 - $got)
            if ($n -le 0) { return $null }
            $got += $n
        }
        $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
        $body = New-Object byte[] $len
        $got = 0
        while ($got -lt $len) {
            $n = $stream.Read($body, $got, $len - $got)
            if ($n -le 0) { return $null }
            $got += $n
        }
        [pscustomobject]@{ Type = $head[0]; Payload = $body }
    } catch { $null }
}

function Connect-Client([string] $Name, [int] $Version = $PROTOCOL_VERSION) {
    $c = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
    $s = $c.GetStream()
    $s.ReadTimeout = 4000
    $nb = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $payload = New-Object byte[] (2 + $nb.Length)
    $payload[0] = [byte]$Version
    $payload[1] = [byte]$nb.Length
    [Array]::Copy($nb, 0, $payload, 2, $nb.Length)
    Send-Packet $s $P.Handshake $payload
    $ack = Read-Packet $s
    [pscustomobject]@{ Name = $Name; Tcp = $c; Stream = $s
                       Id = $(if ($ack -and $ack.Type -eq $P.Ack) { $ack.Payload[0] } else { $null })
                       AckType = $(if ($ack) { $ack.Type } else { $null }) }
}

# Drain packets the presence layer sends on join (Name, Ghost, ...) so they do
# not get mistaken for the pause packet under test.
function Drain($client, [int] $ms = 300) {
    $client.Stream.ReadTimeout = $ms
    while ($true) { if ($null -eq (Read-Packet $client.Stream)) { break } }
    $client.Stream.ReadTimeout = 4000
}

Write-Host "`n=== WO-11 pause mitigation, relay at ${RelayHost}:${Port} ===`n"

$a = Connect-Client 'pauser'
$b = Connect-Client 'observer'
if ($null -eq $a.Id -or $null -eq $b.Id) { throw "handshake failed (relay running? version $PROTOCOL_VERSION accepted?)" }
Write-Host "connected: pauser id=$($a.Id)  observer id=$($b.Id)`n"
Drain $a; Drain $b

# --- entering a pause forwards, tagged with the sender ------------------------
Send-Packet $a.Stream $P.PauseUp ([byte[]]@($STATE_ENTERED))
$rx = Read-Packet $b.Stream
Check ($null -ne $rx -and $rx.Type -eq $P.PauseDown) "observer receives PauseDown (0x1D) on enter"
if ($rx -and $rx.Type -eq $P.PauseDown) {
    Check ($rx.Payload.Length -eq 2)          "downstream payload is 2 bytes"
    Check ($rx.Payload[0] -eq $a.Id)          "tagged with the pauser's ghost id"
    Check ($rx.Payload[1] -eq $STATE_ENTERED) "state byte preserved (entered)"
}

# --- the sender must NOT get its own pause state back --------------------------
$a.Stream.ReadTimeout = 600
$echo = Read-Packet $a.Stream
Check ($null -eq $echo -or $echo.Type -ne $P.PauseDown) "pauser does not receive its own state back"
$a.Stream.ReadTimeout = 4000

# --- exiting the pause forwards too --------------------------------------------
Send-Packet $a.Stream $P.PauseUp ([byte[]]@($STATE_EXITED))
$rx = Read-Packet $b.Stream
Check ($null -ne $rx -and $rx.Type -eq $P.PauseDown) "observer receives PauseDown (0x1D) on exit"
if ($rx -and $rx.Type -eq $P.PauseDown) {
    Check ($rx.Payload[1] -eq $STATE_EXITED) "state byte preserved (exited)"
}

# --- malformed lengths are dropped, not forwarded ------------------------------
# A short PauseUp would otherwise be forwarded as garbage the receiving client
# reads as a state byte off the end of the buffer.
Send-Packet $a.Stream $P.PauseUp (New-Object byte[] 0)
$b.Stream.ReadTimeout = 600
$rx = Read-Packet $b.Stream
Check ($null -eq $rx) "zero-length PauseUp payload is dropped, not forwarded"
$b.Stream.ReadTimeout = 4000

# the connection must still work afterwards
Send-Packet $a.Stream $P.PauseUp ([byte[]]@($STATE_ENTERED))
$rx = Read-Packet $b.Stream
Check ($null -ne $rx -and $rx.Type -eq $P.PauseDown) "stream still usable after a malformed packet"

# --- version negotiation still refuses old peers -------------------------------
$old = Connect-Client 'v5-agent' -Version 5
Check ($old.AckType -eq $P.VersionMismatch) "a pre-WO-11 agent is refused rather than silently dropping pause state"
$old.Tcp.Close()

$a.Tcp.Close(); $b.Tcp.Close()

Write-Host "`n--------------------------------------------"
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
