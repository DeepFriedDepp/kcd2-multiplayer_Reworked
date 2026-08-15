<#
.SYNOPSIS
    A scripted dice opponent, so real keybinds can be tested without a second human.

.DESCRIPTION
    WO-6's keybinds (R cast, 1-6 mark, hold F bank, hold X yield) have never
    fired against a real, open match -- only against mp_dice_demo, which is
    deliberately input-inert. Testing them for real needs an actual session,
    which needs a second player, and there is one PC and one copy of the game
    here.

    A second real KcdMp.Client.exe does not work for this: it blocks in
    WaitForGameAsync until it finds a real running game (see
    HttpGameTransport.IsGameReadyAsync), and running a second one against the
    SAME game would mean two processes pushing Lua into one Lua VM -- both
    would stomp the same KCD2MP.ghosts / KCD2MP.dice / KCD2MP.invite globals.

    So this speaks the relay wire protocol directly, the same way
    Test-Dice.ps1 does (this reuses its Connect-Client/Send-Packet/Read-Packet/
    Parse-DiceState/Get-GreedyKeepMask exactly) -- but as a long-running
    opponent instead of a fixed test:

      1. Connects to the relay as a plain ghost, no game attached.
      2. Reads the real player's position from the game's debug API (KcdApi.ps1)
         and sends ONE Position packet a few metres to the side of it, so a
         ghost spawns next to the player -- KCD2MP_InviteNearest has no max
         range, so exact placement does not matter, but standing right next to
         the player is least confusing on screen.
      3. Waits for a dice invite (send it in game with `mp_dice`, the verified
         fallback -- the invite keybind itself is a separate, still-unverified
         guess and not what this is testing).
      4. Auto-accepts, then plays its own turns with the same greedy policy
         Test-Dice.ps1 uses, with a short human-feeling pause -- while YOUR
         turns are driven entirely by whatever you press in the real game.
      5. Reports every DiceState/DiceError/DiceEnd to the console so you can
         see what the relay actually did versus what you pressed.
      6. Loops back to waiting for the next invite after a match ends, so one
         run covers as many attempts as needed.

.EXAMPLE
    dotnet run --project dotnet\KcdMp.Server -- --port 7778      # separate window
    dotnet run --project dotnet\KcdMp.Client -- --host localhost --no-voice   # separate window, bridges the real game
    powershell -ExecutionPolicy Bypass -File tools\Bot-DiceOpponent.ps1       # this script, a third window

.EXAMPLE
    # WO-33: bot invites the human with a wager, so F9/F11/F12 (invite/accept/
    # decline) and the wager money application can be tested without a real
    # second player pressing anything to start it.
    powershell -ExecutionPolicy Bypass -File tools\Bot-DiceOpponent.ps1 -AutoInviteWager 50
#>
[CmdletBinding()]
param(
    [string] $RelayHost      = 'localhost',
    [int]    $Port           = 7778,
    [string] $Name           = 'TestBot',
    [double] $OffsetX        = 2.0,
    [int]    $BankThreshold  = 300,
    [int]    $MoveDelayMs    = 1200,
    # WO-33: if set, this bot INITIATES instead of only waiting to be invited
    # -- sends an Invite to the first other ghost it sees announced (via a
    # Name packet), with this many groschen staked, so the human's side of
    # invite/accept/decline (F9/F11/F12) can be tested without a real second
    # player having to press anything to start it. 0 = wait passively, the
    # original behaviour.
    [int]    $AutoInviteWager = 0
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\KcdApi.ps1"

# Protocol constants, mirrored from Protocol.cs (same table as Test-Dice.ps1).
$P = @{
    Handshake = 0x00; Name = 0x03; Ack = 0xFF; VersionMismatch = 0x09
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

function Connect-Client([string] $ClientName) {
    $c = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
    $s = $c.GetStream()
    $s.ReadTimeout = 10000
    $nb = [System.Text.Encoding]::UTF8.GetBytes($ClientName)
    $payload = New-Object byte[] (2 + $nb.Length)
    $payload[0] = $PROTOCOL_VERSION
    $payload[1] = [byte]$nb.Length
    [Array]::Copy($nb, 0, $payload, 2, $nb.Length)
    Send-Packet $s $P.Handshake $payload
    $ack = Read-Packet $s
    if ($null -eq $ack -or $ack.Type -ne $P.Ack) { throw "handshake failed for $ClientName (got $($ack.Type))" }
    [pscustomobject]@{ Name = $ClientName; Tcp = $c; Stream = $s; Id = $ack.Payload[0] }
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

# Unlike Test-Dice.ps1's version, this returns $null on ANY read failure
# (header or payload) -- this script runs unattended for minutes at a time
# between events, so a bare ReadTimeout must not throw the script down.
function Read-Packet($stream) {
    try {
        $hdr = New-Object byte[] 3
        $got = 0
        while ($got -lt 3) {
            $n = $stream.Read($hdr, $got, 3 - $got)
            if ($n -le 0) { return $null }
            $got += $n
        }
        $len = $hdr[1] + ($hdr[2] -shl 8)
        $payload = New-Object byte[] $len
        $got = 0
        while ($got -lt $len) {
            $n = $stream.Read($payload, $got, $len - $got)
            if ($n -le 0) { return $null }
            $got += $n
        }
        return [pscustomobject]@{ Type = $hdr[0]; Payload = $payload }
    } catch {
        return $null
    }
}

function SessionId($payload) { return $payload[0] + ($payload[1] -shl 8) }

function Respond($who, [int] $sid, [bool] $accept) {
    Send-Packet $who.Stream $P.InviteResponse ([byte[]]@([byte]($sid -band 0xFF), [byte](($sid -shr 8) -band 0xFF), [byte]$(if ($accept) { 1 } else { 0 })))
}

# WO-33: dice config is [targetScore:2 LE][debugSeedOverride:4 LE][wagerAmount:4 LE].
# Fixed offsets, same as the real client -- see Protocol.cs.
function Invite-DiceWithWager($from, [int] $targetGhostId, [int] $wager) {
    $cfg = New-Object byte[] 10
    $ts = [BitConverter]::GetBytes([uint16] 4000)   # Protocol.DefaultDiceTargetScore
    [Array]::Copy($ts, 0, $cfg, 0, 2)
    [Array]::Copy([BitConverter]::GetBytes([int] $wager), 0, $cfg, 6, 4)

    $payload = New-Object byte[] (3 + $cfg.Length)
    $payload[0] = [byte] $targetGhostId
    $payload[1] = $KIND_DICE
    $payload[2] = [byte] $cfg.Length
    [Array]::Copy($cfg, 0, $payload, 3, $cfg.Length)
    Send-Packet $from.Stream $P.Invite $payload
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

function Send-Position($stream, [double]$x, [double]$y, [double]$z, [double]$rotZ, [bool]$riding) {
    $payload = New-Object byte[] 17
    [Array]::Copy([BitConverter]::GetBytes([float]$x),    0, $payload, 0,  4)
    [Array]::Copy([BitConverter]::GetBytes([float]$y),    0, $payload, 4,  4)
    [Array]::Copy([BitConverter]::GetBytes([float]$z),    0, $payload, 8,  4)
    [Array]::Copy([BitConverter]::GetBytes([float]$rotZ), 0, $payload, 12, 4)
    $payload[16] = if ($riding) { 1 } else { 0 }
    Send-Packet $stream 0x01 $payload   # Protocol.Position
}

# Bounds-checked, matching Test-Dice.ps1/DiceClient.cs -- the original version
# here had none at all and crashed (ArgumentOutOfRangeException in ToInt32)
# the first time this script ever ran a long real match against a real human,
# something none of its earlier short bot-vs-bot runs had exercised. Returns
# $null on anything malformed/short rather than throwing, so one bad packet
# does not kill an otherwise-fine long-running session.
function Parse-DiceState($payload) {
    if ($payload.Length -lt 21) { return $null }
    $freeCount = $payload[20]
    if ($payload.Length -lt 21 + $freeCount + 1) { return $null }
    $freeFaces = @(); for ($i = 0; $i -lt $freeCount; $i++) { $freeFaces += [int]$payload[21 + $i] }
    $o = 21 + $freeCount
    $keptCount = $payload[$o]
    if ($payload.Length -lt $o + 1 + $keptCount) { return $null }
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
        # WO-33: optional trailing field -- absent on a pre-WO-33 relay.
        WagerAmount    = if ($payload.Length -ge 15) { [BitConverter]::ToInt32([byte[]] $payload[11..14], 0) } else { 0 }
    }
}

# Same deterministic (not necessarily optimal) policy as Test-Dice.ps1 /
# SeededReplayTests.cs: the straight if the roll is exactly one, else every
# 1, every 5, and every face appearing 3+ times.
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

Write-Host "=== Dice bot opponent (WO-6 keybind verification) ===" -ForegroundColor Cyan

# Place the ghost next to the real player rather than at the origin, purely
# so it is not confusing on screen -- KCD2MP_InviteNearest has no max range,
# so this is a courtesy, not a requirement.
$botX = 0.0; $botY = 0.0; $botZ = 0.0
try {
    $xml = Invoke-KcdApi -Path "/api/rpg/SoulList/PlayerSoul?depth=1" -MaxBytes 8192
    if ($xml -match 'Position="([^"]+)"') {
        $parts = $Matches[1] -split ','
        $botX = [double]$parts[0] + $OffsetX
        $botY = [double]$parts[1]
        $botZ = [double]$parts[2]
        Write-Host "Read player position from the game API; placing the ghost $OffsetX m to the side."
    } else {
        Write-Host "Could not parse player position from the game API; using 0,0,0." -ForegroundColor Yellow
    }
} catch {
    Write-Host "Game API unreachable ($($_.Exception.Message)); using 0,0,0. The ghost will still work -- KCD2MP_InviteNearest has no range limit -- it just won't be next to you." -ForegroundColor Yellow
}

Write-Host "Connecting to relay ${RelayHost}:${Port} as '$Name'..."
$bot = Connect-Client $Name
Write-Host "Connected. Assigned ghost id = $($bot.Id)"

Send-Position $bot.Stream $botX $botY $botZ 0.0 $false
Write-Host ("Ghost sent at {0:F1},{1:F1},{2:F1}." -f $botX, $botY, $botZ)
if ($AutoInviteWager -gt 0) {
    Write-Host "AutoInviteWager=${AutoInviteWager}: this bot will invite the first other ghost it sees, staking $AutoInviteWager groschen."
    Write-Host "In game: watch for the prompt, then press F11 to accept or F12 to decline."
} else {
    Write-Host "In game: run 'mp_dice' (or press F9 near a table, or 'mp_invite dice') to challenge this bot."
}
Write-Host "Then play YOUR turns with the real keybinds: F2/F4-F9 mark/cast, hold F11 bank, hold F12 yield."
Write-Host "Ctrl+C to stop.`n"

$currentSid = $null
$myRole = 1        # default: acceptor, the original behaviour. Corrected at SessionStart.
$invited = $false  # AutoInviteWager: has this bot already sent its one invite?
while ($true) {
    $pkt = Read-Packet $bot.Stream
    if ($null -eq $pkt) {
        if (-not $bot.Tcp.Connected) { Write-Host "Disconnected from relay." -ForegroundColor Red; break }
        continue   # just a read timeout while nothing happened -- keep waiting
    }

    # WO-33: fire the one auto-invite as soon as some other ghost announces a
    # name -- Name (0x03) is broadcast for every connected client, including
    # ones already present before this bot joined.
    if ($AutoInviteWager -gt 0 -and -not $invited -and $pkt.Type -eq $P.Name -and $pkt.Payload.Length -ge 1) {
        $targetId = $pkt.Payload[0]
        if ($targetId -ne $bot.Id) {
            Write-Host "Inviting ghost $targetId to dice, wager=$AutoInviteWager..." -ForegroundColor Cyan
            Invite-DiceWithWager $bot $targetId $AutoInviteWager
            $invited = $true
        }
    }

    switch ($pkt.Type) {
        $P.InviteReceived {
            $sid    = SessionId $pkt.Payload
            $fromId = $pkt.Payload[2]
            $kind   = $pkt.Payload[3]
            if ($kind -ne $KIND_DICE) {
                Write-Host "Ignoring non-dice invite (kind=$kind) from ghost $fromId, declining."
                Respond $bot $sid $false
                continue
            }
            Write-Host "Invite received from ghost $fromId (session $sid). Accepting..." -ForegroundColor Green
            Start-Sleep -Milliseconds 500
            Respond $bot $sid $true
            $currentSid = $sid
        }
        $P.SessionStart {
            # payload: [sessionId:2][peerGhostId:1][kind:1][role:1] -- role is
            # OUR role (0 Initiator, 1 Acceptor), which flips when this bot is
            # the one that sent the invite (AutoInviteWager).
            $myRole = [int] $pkt.Payload[4]
            Write-Host ("Session started. This bot is {0}." -f $(if ($myRole -eq 0) { "Initiator" } else { "Acceptor" })) -ForegroundColor Green
        }
        $P.DiceState {
            $st = Parse-DiceState $pkt.Payload
            if ($null -eq $st) { Write-Host "  (dropped malformed DiceState)" -ForegroundColor Yellow; continue }
            $whoTurn = if ($st.CurrentRole -eq $myRole) { "bot" } else { "YOU" }
            Write-Host ("  state: init={0} acc={1} turn={2} phase={3} free=[{4}] kept=[{5}]  -- {6}'s turn" -f `
                $st.ScoreInitiator, $st.ScoreAcceptor, $st.TurnTotal, $st.Phase, ($st.FreeFaces -join ','), ($st.KeptFaces -join ','), $whoTurn)

            if ($st.CurrentRole -eq $myRole) {
                Start-Sleep -Milliseconds $MoveDelayMs
                if ($st.Phase -eq 1) {
                    $mask = Get-GreedyKeepMask $st.FreeFaces
                    Write-Host "  bot: keep mask=$mask" -ForegroundColor DarkCyan
                    Send-DiceIntent $bot.Stream $st.SessionId $INTENT_KEEP ([byte[]]@([byte]$mask))
                } elseif ($st.TurnTotal -ge $BankThreshold) {
                    Write-Host "  bot: bank" -ForegroundColor DarkCyan
                    Send-DiceIntent $bot.Stream $st.SessionId $INTENT_BANK $null
                } else {
                    Write-Host "  bot: roll" -ForegroundColor DarkCyan
                    Send-DiceIntent $bot.Stream $st.SessionId $INTENT_ROLL $null
                }
            }
        }
        $P.DiceError {
            $reason = [int]$pkt.Payload[2]
            Write-Host ("  bot's own intent was rejected: {0}" -f $DICE_REJECT[$reason]) -ForegroundColor Yellow
        }
        $P.DiceEnd {
            $end = Parse-DiceEnd $pkt.Payload
            $initiatorIsBot = ($myRole -eq 0)
            $outcome = if ($end.Outcome -eq 0) {
                if ($initiatorIsBot) { "bot (initiator) won" } else { "YOU (initiator) won" }
            } else {
                if ($initiatorIsBot) { "YOU (acceptor) won" } else { "bot (acceptor) won" }
            }
            Write-Host ("=== Match ended: {0}  (scores {1}/{2}, wager {3}) ===" -f $outcome, $end.ScoreInitiator, $end.ScoreAcceptor, $end.WagerAmount) -ForegroundColor Magenta
            $currentSid = $null
            Write-Host "`nWaiting for the next invite...`n"
        }
        $P.SessionEnd {
            if ($null -ne $currentSid) {
                $reason = $REASON[[int]$pkt.Payload[2]]
                Write-Host "Session ended: $reason" -ForegroundColor Yellow
                $currentSid = $null
                Write-Host "`nWaiting for the next invite...`n"
            }
        }
        default { }   # Ghost/Name/Pong/etc -- not interesting here
    }
}
