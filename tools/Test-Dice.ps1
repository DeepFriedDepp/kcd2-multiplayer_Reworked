<#
.SYNOPSIS
    Exercises WO-5 dice (Farkle) against a running relay, relay only.

.DESCRIPTION
    Drives synthetic TCP clients straight at the relay, the same way
    Test-Sessions.ps1 does for the interaction layer. Dice is a session kind
    on top of that framework, so this script assumes Test-Sessions.ps1 is
    green and only exercises what dice adds: the DiceIntent/DiceState/
    DiceError/DiceEnd packets and the relay's own Farkle engine behind them.

    The debug seed override (Invite's dice config, byte 6-9) only works
    against a Debug relay build -- a Release build never reads those bytes
    (SessionManager.CreateDiceGame wraps it in #if DEBUG). Pass -ReleaseRelay
    when testing a published or installed relay: the two seeded-determinism
    checks are then reported as skipped instead of failing on a relay that
    was never going to honour the seed. Every other check applies to both.
    Start the relay first, e.g.
        dotnet run --project dotnet\KcdMp.Server -- --port 7778

    Covers: a seeded match reproduces the same result end to end (twice,
    same seed, same final scores), out-of-turn roll, an out-of-range keep
    mask, an explicit Forfeit intent, and mid-match disconnect.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Dice.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [switch] $ReleaseRelay
)

$ErrorActionPreference = 'Stop'

# Protocol constants, mirrored from Protocol.cs.
$P = @{
    Handshake = 0x00; Ack = 0xFF; VersionMismatch = 0x09
    Invite = 0x0A; InviteReceived = 0x0B; InviteResponse = 0x0C
    SessionStart = 0x0D; SessionEventUp = 0x0E; SessionEventDown = 0x0F
    SessionLeave = 0x10; SessionEnd = 0x11
    DiceIntent = 0x16; DiceState = 0x17; DiceError = 0x18; DiceEnd = 0x19
}
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION, read from Protocol.cs
$KIND_DICE = 0x01

$INTENT_ROLL = 0x00; $INTENT_KEEP = 0x01; $INTENT_BANK = 0x02; $INTENT_FORFEIT = 0x03
$REASON = @{ 0='Completed'; 1='Declined'; 2='Timeout'; 3='PeerDisconnected'; 4='Left'; 5='TargetBusy'; 6='TargetUnavailable'; 7='ProtocolError' }
$DICE_REJECT = @{ 1='NotYourTurn'; 2='WrongPhase'; 3='EmptyKeep'; 4='KeepIndexOutOfRange'; 5='InvalidKeepSelection'; 6='NothingToBank'; 7='GameAlreadyOver' }

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

# Skips presence traffic (ghost/name/pong) to find the next interaction or dice packet.
function Read-Relevant($stream) {
    for ($i = 0; $i -lt 200; $i++) {
        # Named $pkt, not $p: PowerShell variable names are case-insensitive,
        # so $p and the $P protocol-constants table are literally the same
        # slot in any scope that reads both. This bit Test-Sessions.ps1's
        # own $ack/$ACK the same way earlier in WO-2.
        $pkt = Read-Packet $stream
        if ($null -eq $pkt) { return $null }
        if ($pkt.Type -in @(0x0B, 0x0D, 0x0F, 0x11, 0x17, 0x18, 0x19)) { return $pkt }
    }
    return $null
}

function SessionId($payload) { return $payload[0] + ($payload[1] -shl 8) }

function Check([string] $What, [bool] $Ok, [string] $Detail = '') {
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $What) -ForegroundColor Green }
    else     { $script:fail++; Write-Host ("  FAIL  " + $What + $(if ($Detail) { " -- $Detail" })) -ForegroundColor Red }
}

# Dice config on Invite: [targetScore:2 LE][debugSeedOverride:4 LE][wagerAmount:4 LE, WO-33].
# debugSeedOverride is debug-relay-only; wagerAmount always applies.
function Invite-Dice($from, [int] $targetId, [int] $targetScore, [int] $seed, [int] $wager = 0) {
    $cfg = New-Object byte[] 10
    $cfg[0] = $targetScore -band 0xFF
    $cfg[1] = ($targetScore -shr 8) -band 0xFF
    $seedBytes = [BitConverter]::GetBytes([int] $seed)
    [Array]::Copy($seedBytes, 0, $cfg, 2, 4)
    [Array]::Copy([BitConverter]::GetBytes([int] $wager), 0, $cfg, 6, 4)

    $payload = New-Object byte[] (3 + $cfg.Length)
    $payload[0] = [byte] $targetId
    $payload[1] = $KIND_DICE
    $payload[2] = [byte] $cfg.Length
    [Array]::Copy($cfg, 0, $payload, 3, $cfg.Length)
    Send-Packet $from.Stream $P.Invite $payload
}

# WO-33: decode the wager riding on an InviteReceived's forwarded config, so
# the invitee can be tested seeing stakes before it answers. 0 if absent/short.
function Parse-InviteReceivedWager($payload) {
    if ($payload.Length -lt 5) { return 0 }
    $configLen = $payload[4]
    if ($configLen -lt 10 -or $payload.Length -lt 5 + $configLen) { return 0 }
    return [BitConverter]::ToInt32([byte[]] $payload[11..14], 0)
}

function Respond($who, [int] $sid, [bool] $accept) {
    Send-Packet $who.Stream $P.InviteResponse ([byte[]]@([byte]($sid -band 0xFF), [byte](($sid -shr 8) -band 0xFF), [byte]$(if ($accept) { 1 } else { 0 })))
}

function Send-DiceIntent($stream, [int] $sid, [byte] $intentType, [byte[]] $data) {
    if ($null -eq $data) { $data = @() }
    $payload = New-Object byte[] (3 + $data.Length)
    $payload[0] = $sid -band 0xFF
    $payload[1] = ($sid -shr 8) -band 0xFF
    $payload[2] = $intentType
    if ($data.Length) { [Array]::Copy($data, 0, $payload, 3, $data.Length) }
    Send-Packet $stream $P.DiceIntent $payload
}

function Parse-DiceState($payload) {
    $freeCount = $payload[20]
    $freeFaces = @(); for ($i = 0; $i -lt $freeCount; $i++) { $freeFaces += [int]$payload[21 + $i] }
    $o = 21 + $freeCount
    $keptCount = $payload[$o]
    $keptFaces = @(); for ($i = 0; $i -lt $keptCount; $i++) { $keptFaces += [int]$payload[$o + 1 + $i] }
    [pscustomobject]@{
        SessionId      = SessionId $payload
        CurrentRole    = [int] $payload[2]
        ScoreInitiator = [BitConverter]::ToInt32([byte[]] $payload[3..6], 0)
        ScoreAcceptor  = [BitConverter]::ToInt32([byte[]] $payload[7..10], 0)
        TurnTotal      = [BitConverter]::ToInt32([byte[]] $payload[11..14], 0)
        TargetScore    = [BitConverter]::ToInt32([byte[]] $payload[15..18], 0)
        Phase          = [int] $payload[19]
        FreeFaces      = $freeFaces
        KeptFaces      = $keptFaces
    }
}

function Parse-DiceEnd($payload) {
    [pscustomobject]@{
        SessionId      = SessionId $payload
        Outcome        = [int] $payload[2]
        ScoreInitiator = [BitConverter]::ToInt32([byte[]] $payload[3..6], 0)
        ScoreAcceptor  = [BitConverter]::ToInt32([byte[]] $payload[7..10], 0)
        # WO-33: optional trailing field, absent (0) on a pre-WO-33 relay.
        WagerAmount    = if ($payload.Length -ge 15) { [BitConverter]::ToInt32([byte[]] $payload[11..14], 0) } else { 0 }
    }
}

# Deterministic (not necessarily optimal) keep: the straight if the roll is
# exactly one, else every 1, every 5, and every face appearing 3+ times.
# Mirrors the greedy policy in KcdMp.Farkle.Tests/SeededReplayTests.cs.
function Get-GreedyKeepMask([int[]] $faces) {
    if ($faces.Count -in 5, 6) {
        $sorted = ($faces | Sort-Object) -join ','
        $isStraight = ($faces.Count -eq 6 -and $sorted -eq '1,2,3,4,5,6') -or
                      ($faces.Count -eq 5 -and ($sorted -eq '1,2,3,4,5' -or $sorted -eq '2,3,4,5,6'))
        if ($isStraight) { return (1 -shl $faces.Count) - 1 }
    }

    $counts = @{ 1 = 0; 2 = 0; 3 = 0; 4 = 0; 5 = 0; 6 = 0 }
    foreach ($f in $faces) { $counts[$f]++ }

    $mask = 0
    for ($i = 0; $i -lt $faces.Count; $i++) {
        $f = $faces[$i]
        if ($counts[$f] -ge 3 -or $f -eq 1 -or $f -eq 5) { $mask = $mask -bor (1 -shl $i) }
    }
    return $mask
}

# Plays a match to completion, always reading state from Alice's stream --
# both participants get an identical broadcast, so one stream is enough to
# know the state; only the acting side's stream is used to send.
function Invoke-DiceMatch($initiator, $acceptor, [int] $sid, [int] $bankThreshold = 300) {
    for ($step = 0; $step -lt 500; $step++) {
        $pkt = Read-Relevant $initiator.Stream
        if ($null -eq $pkt) { throw "match stalled: no DiceState/DiceEnd" }
        if ($pkt.Type -eq $P.DiceEnd) { return Parse-DiceEnd $pkt.Payload }
        if ($pkt.Type -ne $P.DiceState) { throw "unexpected packet 0x$($pkt.Type.ToString('X2')) while playing" }

        $state = Parse-DiceState $pkt.Payload
        $actor = if ($state.CurrentRole -eq 0) { $initiator } else { $acceptor }

        if ($state.Phase -eq 1) {
            $mask = Get-GreedyKeepMask $state.FreeFaces
            Send-DiceIntent $actor.Stream $sid $INTENT_KEEP ([byte[]]@([byte] $mask))
        } elseif ($state.TurnTotal -ge $bankThreshold) {
            Send-DiceIntent $actor.Stream $sid $INTENT_BANK $null
        } else {
            Send-DiceIntent $actor.Stream $sid $INTENT_ROLL $null
        }
    }
    throw "match did not terminate within 500 steps"
}

function Start-DiceSession($initiator, $acceptor, [int] $targetScore, [int] $seed) {
    Invite-Dice $initiator $acceptor.Id $targetScore $seed
    $inv = Read-Relevant $acceptor.Stream
    $sid = SessionId $inv.Payload
    Respond $acceptor $sid $true
    $null = Read-Relevant $initiator.Stream   # SessionStart
    $null = Read-Relevant $acceptor.Stream    # SessionStart
    return $sid
}

Write-Host "=== WO-5 dice (Farkle) tests ===" -ForegroundColor Cyan
try {
    $probe = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port); $probe.Close()
} catch {
    Write-Host "FAILED: no relay on ${RelayHost}:${Port}. Start it first." -ForegroundColor Red
    exit 1
}

# --- 1. a seeded match is reproducible end to end ---------------------------
Write-Host "`n1. seeded match reproduces the same result end to end"
$a1 = Connect-Client 'Alice1'; $b1 = Connect-Client 'Bob1'
$sid1 = Start-DiceSession $a1 $b1 500 424242
$endA = Invoke-DiceMatch $a1 $b1 $sid1
Write-Host "   run A: outcome=$($endA.Outcome) scores=$($endA.ScoreInitiator)/$($endA.ScoreAcceptor)"

$a2 = Connect-Client 'Alice2'; $b2 = Connect-Client 'Bob2'
$sid2 = Start-DiceSession $a2 $b2 500 424242
$endB = Invoke-DiceMatch $a2 $b2 $sid2
Write-Host "   run B: outcome=$($endB.Outcome) scores=$($endB.ScoreInitiator)/$($endB.ScoreAcceptor)"

# WO-74. SessionManager.CreateDiceGame reads the seed inside #if DEBUG and
# hands a Release build CryptoDiceRng instead, so these two assertions are
# structurally unpassable against any relay a player actually runs. Asserting
# them anyway made the first-ever run of this suite against an INSTALLED relay
# look like a dice regression; it is a suite that only fits a Debug build.
# -ReleaseRelay is explicit for the same reason -IncludeTimeout is in
# Test-Sessions: a Debug run must stay strict, or a real determinism
# regression would be skipped in silence.
if ($ReleaseRelay) {
    Write-Host "  SKIP  same seed -> same outcome        (Release relay: the seed override is #if DEBUG)" -ForegroundColor Yellow
    Write-Host "  SKIP  same seed -> same final scores   (Release relay: the seed override is #if DEBUG)" -ForegroundColor Yellow
} else {
    Check "same seed -> same outcome" ($endA.Outcome -eq $endB.Outcome) "A=$($endA.Outcome) B=$($endB.Outcome)"
    Check "same seed -> same final scores" ($endA.ScoreInitiator -eq $endB.ScoreInitiator -and $endA.ScoreAcceptor -eq $endB.ScoreAcceptor) `
        "A=$($endA.ScoreInitiator)/$($endA.ScoreAcceptor) B=$($endB.ScoreInitiator)/$($endB.ScoreAcceptor)"
}
Check "the winner reached the 500 target" (($endA.Outcome -eq 0 -and $endA.ScoreInitiator -ge 500) -or ($endA.Outcome -eq 1 -and $endA.ScoreAcceptor -ge 500))

foreach ($cl in @($a1, $b1, $a2, $b2)) { try { $cl.Tcp.Close() } catch { } }

# --- 2. out-of-turn roll is rejected -----------------------------------------
Write-Host "`n2. out-of-turn roll is rejected"
$c = Connect-Client 'Carol'; $d = Connect-Client 'Dave'
$sid = Start-DiceSession $c $d 4000 1
$st = Parse-DiceState (Read-Relevant $c.Stream).Payload   # initial DiceState, Carol's copy
$null = Read-Relevant $d.Stream                            # ... and Dave's identical copy
$notTurn = if ($st.CurrentRole -eq 0) { $d } else { $c }

Send-DiceIntent $notTurn.Stream $sid $INTENT_ROLL $null
$err = Read-Relevant $notTurn.Stream
Check "out-of-turn Roll gets DiceError" ($err -and $err.Type -eq $P.DiceError) "got type $($err.Type)"
Check "reason is NotYourTurn" ($err -and $err.Payload[2] -eq 1) "reason=$($DICE_REJECT[[int]$err.Payload[2]])"

# --- 3. an out-of-range keep mask is rejected --------------------------------
Write-Host "`n3. an out-of-range keep mask is rejected"
# WO-74: roll until somebody is actually holding dice to keep, taking the
# current player from the state each time rather than assuming the turn
# never moved. A roll that busts hands the turn straight over, and against
# a Release relay -- CSPRNG, no seed (#if DEBUG) -- that happens at random,
# so the Keep below landed out of turn and the relay answered NotYourTurn
# instead of KeepIndexOutOfRange. Observed against an installed 0.19.0
# relay. This is what the test always meant; the seed was doing the work.
$state = $st
$actor = $null
for ($attempt = 0; $attempt -lt 25; $attempt++) {
    $actor = if ($state.CurrentRole -eq 0) { $c } else { $d }
    Send-DiceIntent $actor.Stream $sid $INTENT_ROLL $null
    $state = Parse-DiceState (Read-Relevant $actor.Stream).Payload
    if ($state.Phase -eq 1) { break }      # 1 = DicePhase.AwaitingKeep
}
Check "a roll reached AwaitingKeep within 25 attempts" ($state.Phase -eq 1) "phase=$($state.Phase)"
$actor = if ($state.CurrentRole -eq 0) { $c } else { $d }

Send-DiceIntent $actor.Stream $sid $INTENT_KEEP ([byte[]]@(0x40))   # bit 6: never a valid die index (max 6 dice)
$err = Read-Relevant $actor.Stream
Check "out-of-range Keep mask gets DiceError" ($err -and $err.Type -eq $P.DiceError) "got type $($err.Type)"
Check "reason is KeepIndexOutOfRange" ($err -and $err.Payload[2] -eq 4) "reason=$($DICE_REJECT[[int]$err.Payload[2]])"

$c.Tcp.Close(); $d.Tcp.Close()

# --- 4. an explicit Forfeit ends the match immediately -----------------------
Write-Host "`n4. explicit Forfeit ends the match immediately"
$e = Connect-Client 'Erin'; $f = Connect-Client 'Frank'
$sid = Start-DiceSession $e $f 4000 2
$null = Read-Relevant $e.Stream   # initial DiceState

Send-DiceIntent $f.Stream $sid $INTENT_FORFEIT $null
$endE = Parse-DiceEnd (Read-Relevant $e.Stream).Payload
Check "the forfeiting player's opponent wins" ($endE.Outcome -eq 0) "outcome=$($endE.Outcome)"   # Erin=Initiator=role 0
$closeE = Read-Relevant $e.Stream
Check "session also ends (SessionEnd Completed)" ($closeE -and $closeE.Type -eq $P.SessionEnd -and $closeE.Payload[2] -eq 0) "got type $($closeE.Type)"

$e.Tcp.Close(); $f.Tcp.Close()

# --- 5. mid-match disconnect ends the session for the survivor --------------
Write-Host "`n5. mid-match disconnect"
$g = Connect-Client 'Gina'; $h = Connect-Client 'Hank'
$sid = Start-DiceSession $g $h 4000 3
$null = Read-Relevant $h.Stream   # initial DiceState

$g.Tcp.Close()   # Gina vanishes mid-match
$end = Read-Relevant $h.Stream
Check "Hank told PeerDisconnected" ($end -and $end.Type -eq $P.SessionEnd -and $end.Payload[2] -eq 3) "reason=$($REASON[[int]$end.Payload[2]])"

$h.Tcp.Close()

# --- 6. WO-33: wager rides InviteReceived and is echoed correctly on DiceEnd -
Write-Host "`n6. wager: visible before accept, applied correctly to each side on a clean win"
$i = Connect-Client 'Ivan'; $j = Connect-Client 'Jana'
Invite-Dice $i $j.Id 500 424242 250   # same seed as test 1 -> known outcome: Initiator wins, 1200/300
$invJ = Read-Relevant $j.Stream
$sidW = SessionId $invJ.Payload
Check "acceptor sees the wager before answering" ((Parse-InviteReceivedWager $invJ.Payload) -eq 250) `
    "got $(Parse-InviteReceivedWager $invJ.Payload)"

Respond $j $sidW $true
$null = Read-Relevant $i.Stream   # SessionStart
$null = Read-Relevant $j.Stream   # SessionStart
$endI = Invoke-DiceMatch $i $j $sidW
Check "winner's DiceEnd carries the agreed wager" ($endI.WagerAmount -eq 250) "got $($endI.WagerAmount)"
if ($ReleaseRelay) {
    # Which side wins is seed-dependent, and a Release relay ignores the
    # seed (#if DEBUG). The wager assertions either side of this one do
    # not depend on the outcome and stay strict.
    Write-Host "  SKIP  Ivan (initiator) won, as the seed predicts   (Release relay: the seed override is #if DEBUG)" -ForegroundColor Yellow
} else {
    Check "Ivan (initiator) won, as the seed predicts" ($endI.Outcome -eq 0) "outcome=$($endI.Outcome)"
}

$i.Tcp.Close(); $j.Tcp.Close()

# --- 7. WO-33: a wager configured but never reached -> no DiceEnd at all -----
Write-Host "`n7. wager: mid-match disconnect never produces a DiceEnd (nothing to apply, on either side)"
$k = Connect-Client 'Karel'; $l = Connect-Client 'Lada'
Invite-Dice $k $l.Id 4000 5 999   # a large wager, deliberately, to make a wrongly-applied debit obvious if this regresses
$invL = Read-Relevant $l.Stream
$sidW2 = SessionId $invL.Payload
Respond $l $sidW2 $true
$null = Read-Relevant $k.Stream; $null = Read-Relevant $l.Stream   # SessionStart x2
$null = Read-Relevant $k.Stream   # initial DiceState

$l.Tcp.Close()   # Lada vanishes mid-match, wager still nominally "at stake"
$end2 = Read-Relevant $k.Stream
Check "Karel gets SessionEnd, not a DiceEnd, for a disconnected wager match" `
    ($end2 -and $end2.Type -eq $P.SessionEnd -and $end2.Payload[2] -eq 3) "got type 0x$($end2.Type.ToString('X2'))"

$k.Tcp.Close()

Write-Host ""
Write-Host ("=== {0} passed, {1} failed ===" -f $script:pass, $script:fail) -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
exit $(if ($script:fail) { 1 } else { 0 })
