<#
.SYNOPSIS
    Exercises the WO-4 combat replication packets against a running relay.

.DESCRIPTION
    Drives synthetic TCP clients straight at the relay, so damage and death
    forwarding is tested without the game, the mod, the DLL or the agent in the
    way. When something breaks here it is the relay's fault and nothing else's.
    Same approach as Test-Sessions.ps1, and the same reason: there is one machine
    and one copy of the game, so the wire must be testable without either.

    Covers: damage forwarding with the correct source id and byte-exact payload,
    death forwarding, no echo back to the sender, malformed-length rejection,
    and protocol version enforcement.

    Start the relay first, e.g.
        dotnet run --project dotnet\KcdMp.Server -- --port 7778

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Combat.ps1
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
    DamageUp = 0x12; DamageDown = 0x13; DeathUp = 0x14; DeathDown = 0x15
}
$PROTOCOL_VERSION = 6
$SOUL_GUID_LEN = 16

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
# not get mistaken for the combat packet under test.
function Drain($client, [int] $ms = 300) {
    $client.Stream.ReadTimeout = $ms
    while ($true) { if ($null -eq (Read-Packet $client.Stream)) { break } }
    $client.Stream.ReadTimeout = 4000
}

function New-Guid16 { [byte[]]((1..16) | ForEach-Object { [byte](Get-Random -Minimum 0 -Maximum 256) }) }

function New-DamagePayload([byte[]] $guid, [float] $stamina, [float] $health, [byte] $flags) {
    $p = New-Object byte[] 25
    [Array]::Copy($guid, 0, $p, 0, 16)
    [Array]::Copy([BitConverter]::GetBytes($stamina), 0, $p, 16, 4)
    [Array]::Copy([BitConverter]::GetBytes($health),  0, $p, 20, 4)
    $p[24] = $flags
    $p
}

Write-Host "`n=== WO-4 combat replication, relay at ${RelayHost}:${Port} ===`n"

$a = Connect-Client 'attacker'
$b = Connect-Client 'observer'
if ($null -eq $a.Id -or $null -eq $b.Id) { throw "handshake failed (relay running? version $PROTOCOL_VERSION accepted?)" }
Write-Host "connected: attacker id=$($a.Id)  observer id=$($b.Id)`n"
Drain $a; Drain $b

# --- damage forwards, byte-exact, tagged with the sender ---------------------
$guid = New-Guid16
$dmg  = New-DamagePayload $guid 0.0 12.5 1
Send-Packet $a.Stream $P.DamageUp $dmg

$rx = Read-Packet $b.Stream
Check ($null -ne $rx -and $rx.Type -eq $P.DamageDown) "observer receives Damage (0x13)"
if ($rx -and $rx.Type -eq $P.DamageDown) {
    Check ($rx.Payload.Length -eq 26)      "downstream payload is 26 bytes"
    Check ($rx.Payload[0] -eq $a.Id)       "tagged with the attacker's ghost id"
    $sameGuid = $true
    for ($i = 0; $i -lt 16; $i++) { if ($rx.Payload[$i + 1] -ne $guid[$i]) { $sameGuid = $false } }
    Check $sameGuid                        "SharedSoulGuid survives byte-for-byte"
    $st = [BitConverter]::ToSingle($rx.Payload, 17)
    $hp = [BitConverter]::ToSingle($rx.Payload, 21)
    Check ($st -eq 0.0)                    "stamina damage preserved ($st)"
    Check ($hp -eq 12.5)                   "health damage preserved ($hp)"
    Check ($rx.Payload[25] -eq 1)          "flags preserved (suppressHitReaction)"
}

# --- the sender must NOT get its own hit back --------------------------------
$a.Stream.ReadTimeout = 600
$echo = Read-Packet $a.Stream
Check ($null -eq $echo -or $echo.Type -ne $P.DamageDown) "attacker does not receive its own damage back"
$a.Stream.ReadTimeout = 4000

# --- death forwards ----------------------------------------------------------
Send-Packet $a.Stream $P.DeathUp $guid
$rx = Read-Packet $b.Stream
Check ($null -ne $rx -and $rx.Type -eq $P.DeathDown) "observer receives Death (0x15)"
if ($rx -and $rx.Type -eq $P.DeathDown) {
    Check ($rx.Payload.Length -eq 17) "death payload is 17 bytes"
    Check ($rx.Payload[0] -eq $a.Id)  "death tagged with the attacker's ghost id"
}

# --- malformed lengths are dropped, not forwarded ----------------------------
# A short damage packet would otherwise be forwarded as garbage that the
# receiving client turns into a call into the game.
Send-Packet $a.Stream $P.DamageUp (New-Object byte[] 10)
$b.Stream.ReadTimeout = 600
$rx = Read-Packet $b.Stream
Check ($null -eq $rx) "short Damage payload is dropped, not forwarded"
$b.Stream.ReadTimeout = 4000

# the connection must still work afterwards
Send-Packet $a.Stream $P.DamageUp (New-DamagePayload $guid 1.0 2.0 0)
$rx = Read-Packet $b.Stream
Check ($null -ne $rx -and $rx.Type -eq $P.DamageDown) "stream still usable after a malformed packet"

# --- version negotiation still refuses old peers -----------------------------
$old = Connect-Client 'v2-agent' -Version 2
Check ($old.AckType -eq $P.VersionMismatch) "a v2 agent is refused rather than silently dropping hits"
$old.Tcp.Close()

$a.Tcp.Close(); $b.Tcp.Close()

Write-Host "`n--------------------------------------------"
Write-Host ("  passed: {0}   failed: {1}" -f $script:pass, $script:fail)
if ($script:fail -gt 0) { exit 1 }
