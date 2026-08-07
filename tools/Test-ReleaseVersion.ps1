<#
.SYNOPSIS
    Exercises the WO-19 release-version handshake layer against a running relay.

.DESCRIPTION
    Same approach as Test-Combat.ps1 and Test-Sessions.ps1: synthetic TCP
    clients straight at the relay, no game/agent involved. Covers:
      - two clients that both declare a release version broadcast it to each
        other via ReleaseVersion (0x1E), and it round-trips exactly;
      - a client with NO trailing release-version field (the old, pre-WO-19
        handshake shape) is accepted normally and never triggers a
        ReleaseVersion packet about itself;
      - a late joiner is replayed the release version of an existing peer
        (mirrors SendAllNamesTo for Name);
      - the existing protocol-version hard refusal (Test-Combat.ps1's own
        "v2 agent is refused" case) is unaffected by any of this -- re-checked
        here too since this session touched the same handshake parse path.

    Start the relay first, e.g.
        dotnet run --project dotnet\KcdMp.Server -- --port 7778

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-ReleaseVersion.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778
)

$ErrorActionPreference = 'Stop'

$P = @{ Handshake = 0x00; Ack = 0xFF; VersionMismatch = 0x09; ReleaseVersion = 0x1E }
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION, read from Protocol.cs

$script:pass = 0
$script:fail = 0
function Ok([string] $m)  { $script:pass++; Write-Host "  PASS  $m" -ForegroundColor Green }
function Bad([string] $m) { $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }
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

# $ReleaseVersion = $null reproduces the exact pre-WO-19 handshake shape
# (no trailing field at all), not just an empty string -- an old build never
# writes the extra bytes, it doesn't write a zero-length one.
function Connect-Client([string] $Name, [string] $ReleaseVersion = $null, [int] $Version = $PROTOCOL_VERSION) {
    $c = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
    $s = $c.GetStream()
    $s.ReadTimeout = 4000
    $nb = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $rvb = if ($ReleaseVersion) { [System.Text.Encoding]::UTF8.GetBytes($ReleaseVersion) } else { @() }
    $payload = New-Object byte[] (2 + $nb.Length + $rvb.Length)
    $payload[0] = [byte]$Version
    $payload[1] = [byte]$nb.Length
    [Array]::Copy($nb, 0, $payload, 2, $nb.Length)
    if ($rvb.Length -gt 0) { [Array]::Copy($rvb, 0, $payload, 2 + $nb.Length, $rvb.Length) }
    Send-Packet $s $P.Handshake $payload
    $ack = Read-Packet $s
    [pscustomobject]@{ Name = $Name; Tcp = $c; Stream = $s
                       Id = $(if ($ack -and $ack.Type -eq $P.Ack) { $ack.Payload[0] } else { $null })
                       AckType = $(if ($ack) { $ack.Type } else { $null }) }
}

function Read-ReleaseVersionFor($client, [byte] $ghostId, [int] $ms = 1000) {
    $client.Stream.ReadTimeout = $ms
    $deadline = (Get-Date).AddMilliseconds($ms)
    while ((Get-Date) -lt $deadline) {
        $pkt = Read-Packet $client.Stream
        if ($null -eq $pkt) { break }
        if ($pkt.Type -eq $P.ReleaseVersion -and $pkt.Payload[0] -eq $ghostId) {
            $client.Stream.ReadTimeout = 4000
            return [System.Text.Encoding]::UTF8.GetString($pkt.Payload, 1, $pkt.Payload.Length - 1)
        }
    }
    $client.Stream.ReadTimeout = 4000
    return $null
}

Write-Host "`n=== WO-19 release-version handshake layer, relay at ${RelayHost}:${Port} ===`n"

# --- 1. two clients that both declare a version see each other's ------------
$a = Connect-Client 'alice' '0.9.5'
$b = Connect-Client 'bob'   '0.9.4'
if ($null -eq $a.Id -or $null -eq $b.Id) { throw "handshake failed (relay running? version $PROTOCOL_VERSION accepted?)" }
Write-Host "1. alice(0.9.5) id=$($a.Id)  bob(0.9.4) id=$($b.Id)"

$bobSeesAlice = Read-ReleaseVersionFor $b $a.Id
Check ($bobSeesAlice -eq '0.9.5') "bob receives alice's release version (0.9.5)"

$aliceSeesBob = Read-ReleaseVersionFor $a $b.Id
Check ($aliceSeesBob -eq '0.9.4') "alice receives bob's release version (0.9.4)"

$a.Tcp.Close(); $b.Tcp.Close()

# --- 2. a client with no trailing field at all (old-build shape) is fine ----
Write-Host "`n2. old-style handshake (no release-version field)"
$old = Connect-Client 'oldbuild' $null
$new = Connect-Client 'newbuild' '0.9.5'
Check ($null -ne $old.Id -and $old.AckType -eq $P.Ack) "old-shape handshake is still accepted"

$newSeesOld = Read-ReleaseVersionFor $new $old.Id -ms 800
Check ($null -eq $newSeesOld) "no ReleaseVersion packet is ever sent about the old-shape client"

$old.Tcp.Close(); $new.Tcp.Close()

# --- 3. a late joiner is replayed an existing peer's release version --------
Write-Host "`n3. late joiner replay"
$first = Connect-Client 'first' '0.9.3'
Start-Sleep -Milliseconds 200
$second = Connect-Client 'second' '0.9.3'
$secondSeesFirst = Read-ReleaseVersionFor $second $first.Id
Check ($secondSeesFirst -eq '0.9.3') "late joiner is replayed the existing peer's release version"

$first.Tcp.Close(); $second.Tcp.Close()

# --- 4. the existing protocol-version hard refusal is unaffected ------------
Write-Host "`n4. protocol-version hard refusal (unchanged by any of the above)"
$badProto = Connect-Client 'badproto' '0.9.5' -Version ($PROTOCOL_VERSION + 1)
Check ($badProto.AckType -eq $P.VersionMismatch) "a wire-protocol mismatch is still refused, hard, regardless of release version"
$badProto.Tcp.Close()

Write-Host "`n--------------------------------------------"
Write-Host "  passed: $script:pass   failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
