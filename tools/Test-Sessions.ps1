<#
.SYNOPSIS
    Exercises the WO-2 interaction session state machine against a running relay.

.DESCRIPTION
    Drives synthetic TCP clients straight at the relay, so the session logic is
    tested without the game, the mod, or the agent in the way. When something
    breaks here it is the relay's fault and nothing else's.

    Covers: accept, decline, event relay, deliberate leave, busy rejection,
    self-invite, unknown target, mid-session disconnect, and (optionally) the
    unanswered-invite timeout.

    Start the relay first, e.g.
        dotnet run --project dotnet\KcdMp.Server -- --port 7778

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Sessions.ps1

.EXAMPLE
    # Also wait out the 30 s invite timeout
    powershell -ExecutionPolicy Bypass -File tools\Test-Sessions.ps1 -IncludeTimeout
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [switch] $IncludeTimeout
)

$ErrorActionPreference = 'Stop'

# Protocol constants, mirrored from Protocol.cs.
$P = @{
    Handshake = 0x00; Ack = 0xFF; VersionMismatch = 0x09
    Invite = 0x0A; InviteReceived = 0x0B; InviteResponse = 0x0C
    SessionStart = 0x0D; SessionEventUp = 0x0E; SessionEventDown = 0x0F
    SessionLeave = 0x10; SessionEnd = 0x11
}
$PROTOCOL_VERSION = 4
$KIND_DICE = 0x01
$REASON = @{ 0='Completed'; 1='Declined'; 2='Timeout'; 3='PeerDisconnected'; 4='Left'; 5='TargetBusy'; 6='TargetUnavailable'; 7='ProtocolError' }
$TYPENAME = @{ 0x0B='InviteReceived'; 0x0D='SessionStart'; 0x0F='SessionEvent'; 0x11='SessionEnd'; 0xFF='Ack' }

$script:pass = 0
$script:fail = 0

function Connect-Client([string] $Name) {
    $c = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
    $s = $c.GetStream()
    $s.ReadTimeout = 4000
    $nb = [System.Text.Encoding]::UTF8.GetBytes($Name)
    $payload = New-Object byte[] (2 + $nb.Length)
    $payload[0] = $PROTOCOL_VERSION
    $payload[1] = [byte]$nb.Length
    [Array]::Copy($nb, 0, $payload, 2, $nb.Length)
    Send-Packet $s $P.Handshake $payload
    $ack = Read-Packet $s
    if ($null -eq $ack -or $ack.Type -ne $P.Ack) { throw "handshake failed for $Name (got $($ack.Type))" }
    [pscustomobject]@{ Name = $Name; Tcp = $c; Stream = $s; Id = $ack.Payload[0] }
}

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $pkt = New-Object byte[] (3 + $payload.Length)
    $pkt[0] = $type
    $pkt[1] = [byte]($payload.Length -band 0xFF)
    $pkt[2] = [byte](($payload.Length -shr 8) -band 0xFF)
    if ($payload.Length) { [Array]::Copy($payload, 0, $pkt, 3, $payload.Length) }
    $stream.Write($pkt, 0, $pkt.Length)
    $stream.Flush()
}

function Read-Packet($stream) {
    $hdr = New-Object byte[] 3
    $got = 0
    try {
        while ($got -lt 3) {
            $n = $stream.Read($hdr, $got, 3 - $got)
            if ($n -le 0) { return $null }
            $got += $n
        }
    } catch { return $null }
    $len = $hdr[1] + ($hdr[2] -shl 8)
    $payload = New-Object byte[] $len
    $got = 0
    while ($got -lt $len) {
        $n = $stream.Read($payload, $got, $len - $got)
        if ($n -le 0) { return $null }
        $got += $n
    }
    [pscustomobject]@{ Type = $hdr[0]; Payload = $payload }
}

# Skips presence traffic (ghost/name/pong) to find the next interaction packet.
function Read-Interaction($stream) {
    for ($i = 0; $i -lt 40; $i++) {
        $p = Read-Packet $stream
        if ($null -eq $p) { return $null }
        if ($p.Type -in @(0x0B, 0x0D, 0x0F, 0x11)) { return $p }
    }
    return $null
}

function SessionId($payload) { return $payload[0] + ($payload[1] -shl 8) }

function Check([string] $What, [bool] $Ok, [string] $Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Detail) { " -- $Detail" })) -ForegroundColor Red }
}

function Invite($from, $targetId, $kind = $KIND_DICE) {
    Send-Packet $from.Stream $P.Invite ([byte[]]@([byte]$targetId, [byte]$kind))
}
function Respond($who, [int] $sid, [bool] $accept) {
    Send-Packet $who.Stream $P.InviteResponse ([byte[]]@([byte]($sid -band 0xFF), [byte](($sid -shr 8) -band 0xFF), [byte]$(if ($accept) { 1 } else { 0 })))
}
function Leave($who, [int] $sid, [byte] $reason) {
    Send-Packet $who.Stream $P.SessionLeave ([byte[]]@([byte]($sid -band 0xFF), [byte](($sid -shr 8) -band 0xFF), $reason))
}

Write-Host "=== WO-2 session state machine tests ===" -ForegroundColor Cyan
try {
    $probe = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port); $probe.Close()
} catch {
    Write-Host "FAILED: no relay on ${RelayHost}:${Port}. Start it first." -ForegroundColor Red
    exit 1
}

# --- 1. accept, event relay, leave ------------------------------------------
Write-Host "`n1. accept -> event -> leave"
$a = Connect-Client 'Alice'
$b = Connect-Client 'Bob'
Write-Host "   Alice id=$($a.Id)  Bob id=$($b.Id)"

Invite $a $b.Id
$inv = Read-Interaction $b.Stream
Check "Bob receives InviteReceived" ($null -ne $inv -and $inv.Type -eq $P.InviteReceived) "got type $($inv.Type)"
$sid = if ($inv) { SessionId $inv.Payload } else { 0 }
Check "invite names Alice as sender" ($inv -and $inv.Payload[2] -eq $a.Id) "payload from=$($inv.Payload[2])"
Check "invite carries kind=Dice" ($inv -and $inv.Payload[3] -eq $KIND_DICE)
Check "session id is non-zero" ($sid -ne 0) "sid=$sid"

Respond $b $sid $true
$sa = Read-Interaction $a.Stream
$sb = Read-Interaction $b.Stream
Check "Alice gets SessionStart" ($sa -and $sa.Type -eq $P.SessionStart)
Check "Bob gets SessionStart"   ($sb -and $sb.Type -eq $P.SessionStart)
Check "Alice role=Initiator(0)" ($sa -and $sa.Payload[4] -eq 0) "role=$($sa.Payload[4])"
Check "Bob role=Acceptor(1)"    ($sb -and $sb.Payload[4] -eq 1) "role=$($sb.Payload[4])"
Check "Alice sees Bob as peer"  ($sa -and $sa.Payload[2] -eq $b.Id)
Check "Bob sees Alice as peer"  ($sb -and $sb.Payload[2] -eq $a.Id)

# opaque payload round trip
$body = [byte[]]@([byte]($sid -band 0xFF), [byte](($sid -shr 8) -band 0xFF), 0x42, 0x43, 0x44)
Send-Packet $a.Stream $P.SessionEventUp $body
$ev = Read-Interaction $b.Stream
Check "Bob receives SessionEvent" ($ev -and $ev.Type -eq $P.SessionEventDown)
Check "event tagged with Alice's id" ($ev -and $ev.Payload[2] -eq $a.Id)
Check "event payload arrives intact" ($ev -and $ev.Payload.Length -eq 6 -and $ev.Payload[3] -eq 0x42 -and $ev.Payload[5] -eq 0x44) "len=$($ev.Payload.Length)"

Leave $a $sid 0
$ea = Read-Interaction $a.Stream
$eb = Read-Interaction $b.Stream
Check "Alice gets SessionEnd(Completed)" ($ea -and $ea.Type -eq $P.SessionEnd -and $ea.Payload[2] -eq 0) "reason=$($REASON[[int]$ea.Payload[2]])"
Check "Bob gets SessionEnd(Completed)"   ($eb -and $eb.Type -eq $P.SessionEnd -and $eb.Payload[2] -eq 0)

# --- 2. decline --------------------------------------------------------------
Write-Host "`n2. decline"
Invite $a $b.Id
$inv = Read-Interaction $b.Stream
$sid = SessionId $inv.Payload
Respond $b $sid $false
$ea = Read-Interaction $a.Stream
$eb = Read-Interaction $b.Stream
Check "Alice gets SessionEnd(Declined)" ($ea -and $ea.Payload[2] -eq 1) "reason=$($REASON[[int]$ea.Payload[2]])"
Check "Bob gets SessionEnd(Declined)"   ($eb -and $eb.Payload[2] -eq 1)

# --- 3. busy ----------------------------------------------------------------
Write-Host "`n3. busy target"
Invite $a $b.Id                    # leaves a pending invite
$null = Read-Interaction $b.Stream
$c = Connect-Client 'Carol'
Invite $c $b.Id                    # Bob already tied up
$ec = Read-Interaction $c.Stream
Check "Carol refused with TargetBusy" ($ec -and $ec.Type -eq $P.SessionEnd -and $ec.Payload[2] -eq 5) "reason=$($REASON[[int]$ec.Payload[2]])"

# clear the pending invite so later cases start clean
$pending = $sid
Invite $c $a.Id
$ec2 = Read-Interaction $c.Stream
Check "inviting a busy Alice also refused" ($ec2 -and $ec2.Payload[2] -eq 5)

# --- 4. bad targets ---------------------------------------------------------
Write-Host "`n4. invalid targets"
Invite $c $c.Id
$e = Read-Interaction $c.Stream
Check "self-invite refused (TargetUnavailable)" ($e -and $e.Payload[2] -eq 6) "reason=$($REASON[[int]$e.Payload[2]])"
Invite $c 250
$e = Read-Interaction $c.Stream
Check "unknown target refused (TargetUnavailable)" ($e -and $e.Payload[2] -eq 6)

# --- 5. mid-session disconnect ---------------------------------------------
Write-Host "`n5. disconnect mid-session"
$d = Connect-Client 'Dave'
$e2 = Connect-Client 'Erin'
Invite $d $e2.Id
$inv = Read-Interaction $e2.Stream
$sid = SessionId $inv.Payload
Respond $e2 $sid $true
$null = Read-Interaction $d.Stream
$null = Read-Interaction $e2.Stream
$d.Tcp.Close()                     # Dave vanishes
$end = Read-Interaction $e2.Stream
Check "Erin told PeerDisconnected" ($end -and $end.Type -eq $P.SessionEnd -and $end.Payload[2] -eq 3) "reason=$($REASON[[int]$end.Payload[2]])"

# --- 6. invite timeout (optional) -------------------------------------------
if ($IncludeTimeout) {
    Write-Host "`n6. unanswered invite expires (waiting ~34 s)"
    $f = Connect-Client 'Frank'
    $g = Connect-Client 'Grace'
    Invite $f $g.Id
    $null = Read-Interaction $g.Stream
    $f.Stream.ReadTimeout = 40000
    $end = Read-Interaction $f.Stream
    Check "Frank gets SessionEnd(Timeout)" ($end -and $end.Payload[2] -eq 2) "reason=$($REASON[[int]$end.Payload[2]])"
    $f.Tcp.Close(); $g.Tcp.Close()
} else {
    Write-Host "`n6. invite timeout: skipped (pass -IncludeTimeout)" -ForegroundColor DarkGray
}

foreach ($cl in @($a, $b, $c, $e2)) { try { $cl.Tcp.Close() } catch { } }

Write-Host ""
Write-Host ("=== {0} passed, {1} failed ===" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
