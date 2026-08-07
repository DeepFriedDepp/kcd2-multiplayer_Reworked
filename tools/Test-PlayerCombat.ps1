<#
.SYNOPSIS
    WO-28 relay-level tests for the shared player combat layer (0x1F-0x25):
    continuous player health, NPC->player hits, player death, and the
    damage-authority role that gates them.

.DESCRIPTION
    Relay only -- no game, no agent, no DLL. Synthetic TCP peers speak the wire
    protocol directly, the same shape as tools/Test-Combat.ps1, so every routing
    and gating rule is checked without needing a second machine.

    What this can and cannot prove, stated plainly:

      CAN   the relay broadcasts PlayerStateUp to peers and not to the sender;
            it ROUTES PlayerHitUp to exactly the named player and nobody else;
            it DROPS a PlayerHitUp from a client that does not hold damage
            authority; it assigns the role to the lowest-id ready client and
            moves it when that client leaves; death broadcasts and is
            idempotent on the wire.

      CANNOT that an NPC hitting a ghost in one player's world actually hurts
            the other player in theirs. That crosses two real games and is
            covered by Test-PlayerVitalsE2E.ps1 (one real game) and, for the
            genuinely cross-machine step, by nothing available here -- see
            docs/WO-28-findings.md, which marks it unverified rather than
            quietly implying otherwise.

    Runs against an isolated relay on its own port by default so a live session
    on 7778 is never touched.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-PlayerCombat.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7781,
    # Empty means "start one myself on $Port and stop it afterwards".
    [string] $RelayExe = ''
)

$ErrorActionPreference = 'Stop'

$HANDSHAKE = 0x00; $ACK = 0xFF; $POSITION = 0x01
$PLAYER_STATE_UP = 0x1F; $PLAYER_STATE_DOWN = 0x20
$PLAYER_HIT_UP   = 0x21; $PLAYER_HIT_DOWN   = 0x22
$PLAYER_DEATH_UP = 0x23; $PLAYER_DEATH_DOWN = 0x24
$COMBAT_ROLE     = 0x25
$VERSION = 6

$script:pass = 0; $script:fail = 0
function Check([string] $name, [bool] $ok, [string] $detail = '') {
    if ($ok) { $script:pass++; Write-Host "  PASS  $name" -ForegroundColor Green }
    else     { $script:fail++; Write-Host "  FAIL  $name  $detail" -ForegroundColor Red }
}

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3); if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Read-Packet($stream) {
    $head = New-Object byte[] 3; $got = 0
    while ($got -lt 3) {
        try { $n = $stream.Read($head, $got, 3 - $got) } catch { return $null }
        if ($n -le 0) { return $null }; $got += $n
    }
    $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
    $body = New-Object byte[] ([Math]::Max($len,1)); $got = 0
    while ($got -lt $len) {
        try { $n = $stream.Read($body, $got, $len - $got) } catch { return $null }
        if ($n -le 0) { return $null }; $got += $n
    }
    New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body; Len = $len }
}

# Drains everything currently queued, up to a short quiet period. Returns the
# packets as an array so a test can assert on both presence AND absence.
function Drain($peer, [int] $quietMs = 700) {
    $out = @()
    $deadline = (Get-Date).AddMilliseconds($quietMs)
    while ((Get-Date) -lt $deadline) {
        if ($peer.Stream.DataAvailable) {
            $p = Read-Packet $peer.Stream
            if ($null -eq $p) { break }
            $out += $p
            $deadline = (Get-Date).AddMilliseconds($quietMs)
        } else { Start-Sleep -Milliseconds 25 }
    }
    return ,$out
}

function Connect-Peer([string] $name) {
    $tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
    $s = $tcp.GetStream(); $s.ReadTimeout = 3000
    $nb = [System.Text.Encoding]::UTF8.GetBytes($name)
    $hs = New-Object byte[] (2 + $nb.Length)
    $hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
    Send-Packet $s $HANDSHAKE $hs
    # NOT $ack: PowerShell variables are case-insensitive, so $ack would shadow
    # the $ACK constant above and every handshake would "fail" against itself.
    # This exact trap is recorded in docs/PROJECT-STATE.md s5 and it cost time
    # here too.
    $ackPkt = Read-Packet $s
    if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK) { throw "handshake refused for '$name' (type $($ackPkt.Type))" }
    New-Object psobject -Property @{ Tcp = $tcp; Stream = $s; Id = [int]$ackPkt.Payload[0]; Name = $name }
}

function New-Float([float] $v) { [BitConverter]::GetBytes($v) }

# --- relay under test ---------------------------------------------------------
$relayProc = $null
if (-not $RelayExe) {
    $candidates = @(
        (Join-Path $PSScriptRoot '..\dotnet\KcdMp.Server\bin\Debug\net8.0\KcdMpServer.exe'),
        (Join-Path $PSScriptRoot '..\dotnet\KcdMp.Server\bin\Release\net8.0\KcdMpServer.exe')
    )
    $RelayExe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $RelayExe) { throw "no built KcdMpServer.exe found -- run: dotnet build dotnet\KcdMp.Server\KcdMp.Server.csproj" }
}
Write-Host "starting an isolated relay on port $Port so a live session is untouched..."
$relayProc = Start-Process -FilePath $RelayExe -ArgumentList "--port $Port" -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2
if ($relayProc.HasExited) { throw "the relay exited immediately (port $Port already in use?)" }

try {
    Write-Host ""
    Write-Host "--- damage authority (0x25) ---" -ForegroundColor Cyan

    $a = Connect-Peer 'wo28-a'
    $aPkts = Drain $a
    $aRole = @($aPkts | Where-Object { $_.Type -eq $COMBAT_ROLE })
    Check "first client is told it holds damage authority" `
        ($aRole.Count -ge 1 -and $aRole[-1].Payload[0] -eq 1) `
        "got $($aRole.Count) CombatRole packet(s), last=$(if($aRole.Count){$aRole[-1].Payload[0]}else{'none'})"

    $b = Connect-Peer 'wo28-b'
    $bPkts = Drain $b
    $bRole = @($bPkts | Where-Object { $_.Type -eq $COMBAT_ROLE })
    Check "second client is told it does NOT hold damage authority" `
        ($bRole.Count -ge 1 -and $bRole[-1].Payload[0] -eq 0) `
        "last=$(if($bRole.Count){$bRole[-1].Payload[0]}else{'none'})"

    $aPkts2 = Drain $a
    $aRole2 = @($aPkts2 | Where-Object { $_.Type -eq $COMBAT_ROLE })
    Check "the holder is re-told it still holds the role when someone joins" `
        ($aRole2.Count -ge 1 -and $aRole2[-1].Payload[0] -eq 1) `
        "the current answer is broadcast to everyone, so nobody can hold a stale yes"

    $c = Connect-Peer 'wo28-c'
    [void](Drain $c); [void](Drain $a); [void](Drain $b)

    Write-Host ""
    Write-Host "--- Flow A: continuous player health (0x1F -> 0x20) ---" -ForegroundColor Cyan

    $vitals = New-Object byte[] 9
    [Array]::Copy((New-Float 73.5), 0, $vitals, 0, 4)
    [Array]::Copy((New-Float 41.25), 0, $vitals, 4, 4)
    $vitals[8] = 0x01   # unconscious
    Send-Packet $b.Stream $PLAYER_STATE_UP $vitals

    $aGot = Drain $a; $cGot = Drain $c; $bGot = Drain $b
    $aState = @($aGot | Where-Object { $_.Type -eq $PLAYER_STATE_DOWN })
    $cState = @($cGot | Where-Object { $_.Type -eq $PLAYER_STATE_DOWN })
    $bState = @($bGot | Where-Object { $_.Type -eq $PLAYER_STATE_DOWN })

    Check "PlayerStateUp reaches every other peer" ($aState.Count -eq 1 -and $cState.Count -eq 1) `
        "a=$($aState.Count) c=$($cState.Count)"
    Check "PlayerStateUp is NOT echoed to its sender" ($bState.Count -eq 0) "b=$($bState.Count)"

    if ($aState.Count -eq 1) {
        $p = $aState[0].Payload
        $gotId = [int]$p[0]
        $gotH  = [BitConverter]::ToSingle($p, 1)
        $gotS  = [BitConverter]::ToSingle($p, 5)
        $gotF  = [int]$p[9]
        Check "PlayerStateDown carries the right ghostId, health, stamina and flags" `
            ($gotId -eq $b.Id -and [Math]::Abs($gotH - 73.5) -lt 0.01 -and [Math]::Abs($gotS - 41.25) -lt 0.01 -and $gotF -eq 1) `
            "id=$gotId h=$gotH s=$gotS f=$gotF (expected id=$($b.Id) h=73.5 s=41.25 f=1)"
        Check "PlayerStateDown is exactly 10 bytes" ($aState[0].Len -eq 10) "len=$($aState[0].Len)"
    }

    # A malformed length must not be forwarded AND must not desync the stream.
    Send-Packet $b.Stream $PLAYER_STATE_UP (New-Object byte[] 5)
    $aGotBad = Drain $a
    Check "a short PlayerStateUp is dropped, not forwarded" `
        (@($aGotBad | Where-Object { $_.Type -eq $PLAYER_STATE_DOWN }).Count -eq 0)

    Send-Packet $b.Stream $PLAYER_STATE_UP $vitals
    $aGot2 = Drain $a
    Check "the connection still works after a malformed packet" `
        (@($aGot2 | Where-Object { $_.Type -eq $PLAYER_STATE_DOWN }).Count -eq 1)

    Write-Host ""
    Write-Host "--- Flow B: NPC hits a player (0x21 -> 0x22), and its guards ---" -ForegroundColor Cyan

    # 'a' holds authority. It reports that the ghost for 'c' lost 12.5 health.
    $hit = New-Object byte[] 10
    $hit[0] = [byte]$c.Id
    [Array]::Copy((New-Float 12.5), 0, $hit, 1, 4)
    [Array]::Copy((New-Float 3.0),  0, $hit, 5, 4)
    $hit[9] = 0
    Send-Packet $a.Stream $PLAYER_HIT_UP $hit

    $cGot2 = Drain $c; $bGot2 = Drain $b; $aGot3 = Drain $a
    $cHit = @($cGot2 | Where-Object { $_.Type -eq $PLAYER_HIT_DOWN })
    $bHit = @($bGot2 | Where-Object { $_.Type -eq $PLAYER_HIT_DOWN })
    $aHit = @($aGot3 | Where-Object { $_.Type -eq $PLAYER_HIT_DOWN })

    Check "the authority's PlayerHitUp reaches the player it names" ($cHit.Count -eq 1) "c=$($cHit.Count)"
    Check "it reaches NOBODY else (routed, not broadcast)" ($bHit.Count -eq 0 -and $aHit.Count -eq 0) `
        "b=$($bHit.Count) a=$($aHit.Count)"
    if ($cHit.Count -eq 1) {
        $p = $cHit[0].Payload
        Check "PlayerHitDown drops the targetGhostId and keeps the loss amounts" `
            ($cHit[0].Len -eq 9 -and [Math]::Abs([BitConverter]::ToSingle($p,0) - 12.5) -lt 0.01 -and [Math]::Abs([BitConverter]::ToSingle($p,4) - 3.0) -lt 0.01) `
            "len=$($cHit[0].Len) h=$([BitConverter]::ToSingle($p,0)) s=$([BitConverter]::ToSingle($p,4))"
    }

    # GUARD 1, the one that matters most: a non-holder must not be able to
    # inject NPC damage into anyone's game.
    $hit2 = New-Object byte[] 10
    $hit2[0] = [byte]$c.Id
    [Array]::Copy((New-Float 99.0), 0, $hit2, 1, 4)
    [Array]::Copy((New-Float 0.0),  0, $hit2, 5, 4)
    Send-Packet $b.Stream $PLAYER_HIT_UP $hit2
    $cGot3 = Drain $c
    Check "a PlayerHitUp from a NON-authority is dropped by the relay" `
        (@($cGot3 | Where-Object { $_.Type -eq $PLAYER_HIT_DOWN }).Count -eq 0) `
        "this is Rule 2: without it, N peers produce N damage streams for one fight"

    # Self-targeting: the sender's own game already applied it.
    $hitSelf = New-Object byte[] 10
    $hitSelf[0] = [byte]$a.Id
    [Array]::Copy((New-Float 5.0), 0, $hitSelf, 1, 4)
    Send-Packet $a.Stream $PLAYER_HIT_UP $hitSelf
    $aGot4 = Drain $a
    Check "a PlayerHitUp aimed at the sender itself is dropped" `
        (@($aGot4 | Where-Object { $_.Type -eq $PLAYER_HIT_DOWN }).Count -eq 0)

    # Unknown target: a race against a disconnect, not an error.
    $hitGhost = New-Object byte[] 10
    $hitGhost[0] = 200
    [Array]::Copy((New-Float 5.0), 0, $hitGhost, 1, 4)
    Send-Packet $a.Stream $PLAYER_HIT_UP $hitGhost
    [void](Drain $b); [void](Drain $c)
    Send-Packet $a.Stream $PLAYER_HIT_UP $hit
    $cGot4 = Drain $c
    Check "a hit for a departed player is dropped and the relay keeps working" `
        (@($cGot4 | Where-Object { $_.Type -eq $PLAYER_HIT_DOWN }).Count -eq 1)

    Write-Host ""
    Write-Host "--- Flow C: player death (0x23 -> 0x24) ---" -ForegroundColor Cyan

    Send-Packet $c.Stream $PLAYER_DEATH_UP @()
    $aGot5 = Drain $a; $bGot5 = Drain $b; $cGot5 = Drain $c
    $aDeath = @($aGot5 | Where-Object { $_.Type -eq $PLAYER_DEATH_DOWN })
    $bDeath = @($bGot5 | Where-Object { $_.Type -eq $PLAYER_DEATH_DOWN })
    $cDeath = @($cGot5 | Where-Object { $_.Type -eq $PLAYER_DEATH_DOWN })

    Check "PlayerDeathUp reaches every other peer" ($aDeath.Count -eq 1 -and $bDeath.Count -eq 1) `
        "a=$($aDeath.Count) b=$($bDeath.Count)"
    Check "PlayerDeathUp is not echoed to the player who died" ($cDeath.Count -eq 0) "c=$($cDeath.Count)"
    if ($aDeath.Count -eq 1) {
        Check "PlayerDeathDown names who died, in one byte" `
            ($aDeath[0].Len -eq 1 -and [int]$aDeath[0].Payload[0] -eq $c.Id) `
            "len=$($aDeath[0].Len) id=$([int]$aDeath[0].Payload[0]) expected $($c.Id)"
    }

    Send-Packet $c.Stream $PLAYER_DEATH_UP @()
    Send-Packet $c.Stream $PLAYER_DEATH_UP @()
    $aGot6 = Drain $a
    Check "a repeated death is forwarded, for the receiver to treat as idempotent" `
        (@($aGot6 | Where-Object { $_.Type -eq $PLAYER_DEATH_DOWN }).Count -eq 2) `
        "the relay is stateless by design -- idempotency is the receiver's job, exactly as for 0x15"

    Write-Host ""
    Write-Host "--- the role moves when its holder leaves ---" -ForegroundColor Cyan

    $a.Tcp.Close()
    Start-Sleep -Milliseconds 1200
    $bGot7 = Drain $b
    $bRole2 = @($bGot7 | Where-Object { $_.Type -eq $COMBAT_ROLE })
    Check "damage authority moves to the next-lowest id when the holder disconnects" `
        ($bRole2.Count -ge 1 -and $bRole2[-1].Payload[0] -eq 1) `
        "last=$(if($bRole2.Count){$bRole2[-1].Payload[0]}else{'none'}) -- otherwise NPC combat would silently stop mattering for everyone"

    $hit3 = New-Object byte[] 10
    $hit3[0] = [byte]$c.Id
    [Array]::Copy((New-Float 7.0), 0, $hit3, 1, 4)
    Send-Packet $b.Stream $PLAYER_HIT_UP $hit3
    $cGot6 = Drain $c
    Check "the NEW authority's hits are now accepted" `
        (@($cGot6 | Where-Object { $_.Type -eq $PLAYER_HIT_DOWN }).Count -eq 1)

    $b.Tcp.Close(); $c.Tcp.Close()
}
finally {
    if ($relayProc -and -not $relayProc.HasExited) {
        Stop-Process -Id $relayProc.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "$script:pass passed, $script:fail failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
