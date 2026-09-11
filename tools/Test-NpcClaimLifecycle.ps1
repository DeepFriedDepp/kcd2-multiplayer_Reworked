<#
.SYNOPSIS
    WO-81: exercises the relay's claim-lifecycle logging (grant/release/
    reassignment) and the contested-claim detector, plus confirms the new
    relay.log file this WO adds actually gets written. Pure wire + log-file
    test, same harness shape as Test-NpcClaimValidation.ps1 -- NO game and NO
    agent needed.

.DESCRIPTION
    Unlike the other Test-*Relay.ps1 scripts, this one launches the relay
    with -WorkingDirectory set to its own bin folder. That is deliberate: WO-81
    Phase 0 found that the OTHER scripts here (no -WorkingDirectory override)
    run the relay with NO appsettings.json loaded at all -- their CWD has none,
    so every setting silently falls back to the C# default, which happens to
    numerically match appsettings.json's own shipped values, so nobody ever
    noticed. That would hide exactly the two things this WO needs to prove:
    the Serilog File sink (only wired through appsettings.json) and the
    ContestedGapSeconds default. Running for real here also means --Urls must
    override appsettings.json's fixed "http://0.0.0.0:5273" explicitly, or
    this relay fights a real hosted one for that port.

    Peers: A connects first (lowest id = world/damage authority, passive
    receiver), B/C/D/E are non-authority claimants.

      T0  baseline        -> npc-claims counters all zero; relay.log exists
                             and contains this run's startup lines.
      T1  grant           -> B claims a fresh NPC; [CLAIM] granted line with
                             the right owner/position; grants counter = 1.
      T2  release/disconnect -> D claims, then disconnects; [CLAIM] released
                             reason=disconnect line; releases counter = 1.
      T3  contested (stale-owner path) -> B holds a claim, C's rival packet
                             is rejected AND flagged contested (the claim is
                             live by construction -- NpcClaimTimeoutSeconds
                             5s is always under the default 10s threshold);
                             distanceBetweenPlayers matches B/C's cached
                             Position packets (3-4-5 triangle -> 5.0).
      T4  reassignment, quick -> contested -- B's claim expires, C reclaims
                             right away; both a [CLAIM] reassigned line and a
                             [CLAIM-CONTESTED] line, same 5.0 distance.
      T5  reassignment, slow -> NOT contested -- same shape as T4 but C waits
                             past ContestedGapSeconds before reclaiming; a
                             reassigned line fires, no new contested line.
      T6  unknown distance  -> E, who never sent a Position packet, contests
                             B's claim; distanceBetweenPlayers=unknown.
      T7  config gate off   -> a second relay with ClaimLifecycleLogging=false
                             produces no [CLAIM] lines and all-zero counters
                             for the same grant that would otherwise log one.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-NpcClaimLifecycle.ps1
#>
[CmdletBinding()]
param(
    [int] $TcpPort  = 7796,
    [int] $HttpPort = 5304,
    [int] $TcpPort2  = 7797,
    [int] $HttpPort2 = 5305
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION, read from Protocol.cs

$HANDSHAKE     = 0x00
$ACK_TYPE      = 0xFF
$POSITION_UP   = 0x01
$NPCSTATE_UP   = 0x26
$NPCSTATE_DOWN = 0x27

$script:Pass = 0; $script:Fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    if ($ok) { $script:Pass++; Write-Host "  PASS $name" -ForegroundColor Green }
    else     { $script:Fail++; Write-Host "  FAIL $name  $detail" -ForegroundColor Red }
}

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
    } catch [System.IO.IOException] { $null }   # read timeout = nothing waiting
}

# Position (0x01): [x:4f][y:4f][z:4f][rotZ:4f][flags:1] -- WO-81 caches this
# per-session for the contested-claim detector's distance correlation.
function Send-Position($stream, [float]$x, [float]$y, [float]$z, [float]$rotZ = 0, [byte]$flags = 0) {
    $payload = New-Object byte[] 17
    [Array]::Copy([BitConverter]::GetBytes($x),    0, $payload, 0,  4)
    [Array]::Copy([BitConverter]::GetBytes($y),    0, $payload, 4,  4)
    [Array]::Copy([BitConverter]::GetBytes($z),    0, $payload, 8,  4)
    [Array]::Copy([BitConverter]::GetBytes($rotZ), 0, $payload, 12, 4)
    $payload[16] = $flags
    Send-Packet $stream $POSITION_UP $payload
}

# NpcStateUp (0x26): [nameLen:1][name][x:4f][y:4f][z:4f][rotZ:4f][health:4f][flags:1]
function Send-NpcState($stream, [string]$npcName, [float]$x, [float]$y, [float]$z, [float]$rotZ = 0, [byte]$flags = 1) {
    $nb = [System.Text.Encoding]::UTF8.GetBytes($npcName)
    $payload = New-Object byte[] (1 + $nb.Length + 21)
    $payload[0] = [byte]$nb.Length
    [Array]::Copy($nb, 0, $payload, 1, $nb.Length)
    $o = 1 + $nb.Length
    [Array]::Copy([BitConverter]::GetBytes($x),         0, $payload, $o,      4)
    [Array]::Copy([BitConverter]::GetBytes($y),         0, $payload, $o + 4,  4)
    [Array]::Copy([BitConverter]::GetBytes($z),         0, $payload, $o + 8,  4)
    [Array]::Copy([BitConverter]::GetBytes($rotZ),      0, $payload, $o + 12, 4)
    [Array]::Copy([BitConverter]::GetBytes([float]100), 0, $payload, $o + 16, 4)
    $payload[$o + 20] = $flags
    Send-Packet $stream $NPCSTATE_UP $payload
}

# Drain for NpcStateDown (0x27), same assign-then-filter idiom as WO-66's
# script (the T17 lesson: piping the comma-wrapped array straight into
# Where-Object hands the whole array as one item).
function Drain-NpcStates($stream, [int] $quietMs = 800) {
    $stream.ReadTimeout = $quietMs
    $found = @()
    while ($true) {
        $p = Read-Packet $stream
        if ($null -eq $p) { break }
        if ($p.Type -eq $NPCSTATE_DOWN -and $p.Payload.Length -ge 2) {
            $nameLen = [int]$p.Payload[1]
            $npcName = if ($nameLen -gt 0) { [System.Text.Encoding]::UTF8.GetString($p.Payload, 2, $nameLen) } else { '' }
            $found += New-Object psobject -Property @{ Source = [int]$p.Payload[0]; Name = $npcName }
        }
    }
    ,$found
}
function Drain-NpcStatesFor($stream, [string]$npcName, [int]$quietMs = 800) {
    $all = Drain-NpcStates $stream $quietMs
    ,@($all | Where-Object { $_.Name -eq $npcName })
}

function Connect-Peer([string]$name, [int]$port) {
    $tcp = New-Object System.Net.Sockets.TcpClient('localhost', $port)
    $s = $tcp.GetStream(); $s.ReadTimeout = 8000
    $nb = [System.Text.Encoding]::UTF8.GetBytes($name)
    $hs = New-Object byte[] (2 + $nb.Length)
    $hs[0] = $PROTOCOL_VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
    Send-Packet $s $HANDSHAKE $hs
    $ackPkt = Read-Packet $s
    if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK_TYPE) {
        $got = if ($null -eq $ackPkt) { '(null / timeout)' } else { "type=0x{0:X2} len={1}" -f $ackPkt.Type, $ackPkt.Payload.Length }
        throw "handshake refused for ${name}: $got"
    }
    New-Object psobject -Property @{ Tcp = $tcp; Stream = $s; Id = [int]$ackPkt.Payload[0]; Name = $name }
}

function Start-TestRelay([string]$exe, [string]$workDir, [int]$tcpPort, [int]$httpPort, [string[]]$extraArgs = @()) {
    $args = @("--port", "$tcpPort", "--Urls", "http://localhost:$httpPort") + $extraArgs
    $proc = Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $workDir -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds(15)
    $up = $false
    while (-not $up -and (Get-Date) -lt $deadline) {
        if ($proc.HasExited) { throw "relay exited during startup (port in use?)" }
        try { $probe = New-Object System.Net.Sockets.TcpClient('localhost', $tcpPort); $probe.Close(); $up = $true }
        catch { Start-Sleep -Milliseconds 400 }
    }
    if (-not $up) { throw "relay never opened tcp $tcpPort" }
    Start-Sleep -Milliseconds 500
    $proc
}

function Get-ClaimCounters([int]$port) {
    Invoke-RestMethod -Uri "http://localhost:$port/api/information/npc-claims" -TimeoutSec 5
}

function Get-RelayLogText([string]$workDir) {
    $f = Get-ChildItem (Join-Path $workDir 'relay*.log') -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($null -eq $f) { return '' }
    Get-Content $f.FullName -Raw
}

# ---- start a fresh relay of THIS build, WorkingDirectory = its own bin
# folder so appsettings.json (and therefore the WO-81 Serilog File sink and
# NpcClaimValidation defaults) actually load -- see the file header. ----
$serverExe = Join-Path $PSScriptRoot '..\dotnet\KcdMp.Server\bin\Debug\net8.0\KcdMpServer.exe'
if (-not (Test-Path $serverExe)) { throw "relay not built: $serverExe (run dotnet build first)" }
$serverDir = Split-Path $serverExe -Parent

# Clear any log noise from a previous run of this suite so this run's
# assertions read only fresh lines. Safe: this is the Debug build's own
# bin/ output directory, gitignored, never the real installed relay's log.
Remove-Item (Join-Path $serverDir 'relay*.log') -ErrorAction SilentlyContinue

Write-Host "starting relay: $serverExe (tcp $TcpPort, http $HttpPort, WorkingDirectory=$serverDir)"
$relay = Start-TestRelay $serverExe $serverDir $TcpPort $HttpPort

try {
    $peerA = Connect-Peer 'lc-auth-A' $TcpPort   # lowest id = world authority, passive receiver
    $peerB = Connect-Peer 'lc-B' $TcpPort
    $peerC = Connect-Peer 'lc-C' $TcpPort
    $peerD = Connect-Peer 'lc-D' $TcpPort
    $peerE = Connect-Peer 'lc-E' $TcpPort        # never sends Position -- the "unknown distance" case
    Write-Host "peers: A=id$($peerA.Id) B=id$($peerB.Id) C=id$($peerC.Id) D=id$($peerD.Id) E=id$($peerE.Id)"
    foreach ($p in @($peerA,$peerB,$peerC,$peerD,$peerE)) { $null = Drain-NpcStates $p.Stream 500 }

    Write-Host "`n--- T0: baseline -- counters zero, relay.log exists and has this run's startup lines ---"
    $c0 = Get-ClaimCounters $HttpPort
    Check "all four claim counters zero at startup" `
        ($c0.grants -eq 0 -and $c0.releases -eq 0 -and $c0.reassignments -eq 0 -and $c0.contested -eq 0) `
        "got $($c0 | ConvertTo-Json -Compress)"
    $log = Get-RelayLogText $serverDir
    Check "relay.log exists and captured this run's startup lines" `
        ($log -match [regex]::Escape("Listening on port $TcpPort")) "log length=$($log.Length)"

    # B and C get a known position each (a 3-4-5 triangle, distance 5.0) so
    # later contested lines can be checked against real arithmetic; E
    # deliberately never sends one.
    Send-Position $peerB.Stream 0 0 0
    Send-Position $peerC.Stream 3 4 0
    Start-Sleep -Milliseconds 300

    Write-Host "`n--- T1: grant -- fresh claim logs [CLAIM] granted, counted ---"
    Send-NpcState $peerB.Stream 'lc_npc_1' 10 20 0
    $null = Drain-NpcStatesFor $peerA.Stream 'lc_npc_1'
    Start-Sleep -Milliseconds 200
    $log = Get-RelayLogText $serverDir
    Check "[CLAIM] granted line for lc_npc_1" `
        ($log -match [regex]::Escape("[CLAIM] granted npc=lc_npc_1 owner=$($peerB.Id) pos=(10.0,20.0,0.0)")) $log
    $c1 = Get-ClaimCounters $HttpPort
    Check "grants counter = 1" ($c1.grants -eq 1) "got $($c1.grants)"

    Write-Host "`n--- T2: release via disconnect -- [CLAIM] released reason=disconnect, counted ---"
    Send-NpcState $peerD.Stream 'lc_npc_2' 1 2 3
    $null = Drain-NpcStatesFor $peerA.Stream 'lc_npc_2'
    Start-Sleep -Milliseconds 200
    $peerD.Tcp.Close()
    Start-Sleep -Milliseconds 500   # let TcpSocketService's disconnect continuation run
    $log = Get-RelayLogText $serverDir
    Check "[CLAIM] released reason=disconnect line for lc_npc_2" `
        ($log -match [regex]::Escape("[CLAIM] released npc=lc_npc_2 owner=$($peerD.Id) reason=disconnect")) $log
    $c2 = Get-ClaimCounters $HttpPort
    Check "releases counter = 1" ($c2.releases -eq 1) "got $($c2.releases)"

    Write-Host "`n--- T3: contested via the stale-owner-rejection path (B's live claim, C's rival probe) ---"
    Send-NpcState $peerB.Stream 'lc_npc_3' 50 60 0
    $null = Drain-NpcStatesFor $peerA.Stream 'lc_npc_3'
    Send-NpcState $peerC.Stream 'lc_npc_3' 51 60 0   # rejected: claim is live, and therefore contested
    $gotA = Drain-NpcStatesFor $peerA.Stream 'lc_npc_3'
    Check "C's rival packet was actually rejected (A saw nothing new)" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    $log = Get-RelayLogText $serverDir
    Check "[CLAIM-CONTESTED] line for lc_npc_3 with prevOwner=B newOwner=C" `
        ($log -match [regex]::Escape("[CLAIM-CONTESTED] npc=lc_npc_3 prevOwner=$($peerB.Id) newOwner=$($peerC.Id) gapSec=")) $log
    Check "distanceBetweenPlayers=5.0 (3-4-5 triangle) on the lc_npc_3 contested line" `
        ($log -match "npc=lc_npc_3 prevOwner=$($peerB.Id) newOwner=$($peerC.Id) gapSec=[\d.]+ distanceBetweenPlayers=5\.0") $log
    $c3 = Get-ClaimCounters $HttpPort
    Check "contested counter = 1" ($c3.contested -eq 1) "got $($c3.contested)"
    Check "contestedByNpc[lc_npc_3] = 1" ($c3.contestedByNpc.'lc_npc_3' -eq 1) "got $($c3.contestedByNpc | ConvertTo-Json -Compress)"

    Write-Host "`n--- T4: reassignment, quick -- B's claim expires, C reclaims right away -> reassigned + contested ---"
    Send-NpcState $peerB.Stream 'lc_npc_4' 70 80 0
    $null = Drain-NpcStatesFor $peerA.Stream 'lc_npc_4'
    Write-Host "  (waiting out NpcClaimTimeoutSeconds = 5s...)"
    Start-Sleep -Seconds 6
    Send-NpcState $peerC.Stream 'lc_npc_4' 71 80 0   # reclaim right after expiry: small gap
    $gotA = Drain-NpcStatesFor $peerA.Stream 'lc_npc_4'
    Check "C's reclaim granted after expiry (src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"
    $log = Get-RelayLogText $serverDir
    $reassignMatch = [regex]::Match($log, "\[CLAIM\] reassigned npc=lc_npc_4 prevOwner=$($peerB.Id) newOwner=$($peerC.Id) gapSec=([\d.]+)")
    Check "[CLAIM] reassigned line for lc_npc_4" $reassignMatch.Success $log
    if ($reassignMatch.Success) {
        # gapSec is measured from the released claim's own LastUtc (its last
        # accepted packet, i.e. the grant itself here -- B never refreshed
        # it), not from the lazy removal instant -- removal and reassignment
        # happen in the SAME RouteNpcState call for an expiry-driven
        # reassignment, so a "since removal" gap would always read ~0.0
        # regardless of the real wait (this is what caught that bug during
        # WO-81 development). Expect ~6-7s here: the 6s sleep above plus
        # connect/send overhead, comfortably under the 10s default threshold.
        $gap4 = [double]$reassignMatch.Groups[1].Value
        Check "lc_npc_4's reassignment gap reflects the real ~6s wait and clears under the 10s threshold" `
            ($gap4 -gt 5.0 -and $gap4 -lt 10.0) "got $gap4"
    }
    Check "[CLAIM-CONTESTED] line for lc_npc_4 (quick reassignment) with the 5.0 distance" `
        ($log -match "\[CLAIM-CONTESTED\] npc=lc_npc_4 prevOwner=$($peerB.Id) newOwner=$($peerC.Id) gapSec=[\d.]+ distanceBetweenPlayers=5\.0") $log
    $c4 = Get-ClaimCounters $HttpPort
    Check "reassignments counter = 1" ($c4.reassignments -eq 1) "got $($c4.reassignments)"
    Check "contested counter = 2 (T3 + T4)" ($c4.contested -eq 2) "got $($c4.contested)"

    Write-Host "`n--- T5: reassignment, slow -- same shape, but the gap clears the 10s default threshold -> NOT contested ---"
    Send-NpcState $peerB.Stream 'lc_npc_5' 90 100 0
    $null = Drain-NpcStatesFor $peerA.Stream 'lc_npc_5'
    Write-Host "  (waiting out the 5s expiry, then 12 more seconds past ContestedGapSeconds=10s...)"
    Start-Sleep -Seconds 17
    Send-NpcState $peerC.Stream 'lc_npc_5' 91 100 0
    $gotA = Drain-NpcStatesFor $peerA.Stream 'lc_npc_5'
    Check "C's slow reclaim still granted (src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"
    $log = Get-RelayLogText $serverDir
    $reassignMatch5 = [regex]::Match($log, "\[CLAIM\] reassigned npc=lc_npc_5 prevOwner=$($peerB.Id) newOwner=$($peerC.Id) gapSec=([\d.]+)")
    Check "[CLAIM] reassigned line for lc_npc_5" $reassignMatch5.Success $log
    if ($reassignMatch5.Success) {
        $gap5 = [double]$reassignMatch5.Groups[1].Value
        Check "lc_npc_5's reassignment gap cleared the 10s threshold" ($gap5 -gt 10.0) "got $gap5"
    }
    Check "NO [CLAIM-CONTESTED] line for lc_npc_5 (slow reassignment)" `
        ($log -notmatch "\[CLAIM-CONTESTED\] npc=lc_npc_5 ") $log
    $c5 = Get-ClaimCounters $HttpPort
    Check "reassignments counter = 2 (T4 + T5)" ($c5.reassignments -eq 2) "got $($c5.reassignments)"
    Check "contested counter still 2 (T5 did not add one)" ($c5.contested -eq 2) "got $($c5.contested)"

    Write-Host "`n--- T6: unknown distance -- E never sent a Position packet ---"
    Send-NpcState $peerB.Stream 'lc_npc_6' 200 200 0
    $null = Drain-NpcStatesFor $peerA.Stream 'lc_npc_6'
    Send-NpcState $peerE.Stream 'lc_npc_6' 201 200 0   # rejected + contested; E has no cached position
    $gotA = Drain-NpcStatesFor $peerA.Stream 'lc_npc_6'
    Check "E's rival packet was rejected" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    $log = Get-RelayLogText $serverDir
    Check "[CLAIM-CONTESTED] line for lc_npc_6 reports distanceBetweenPlayers=unknown" `
        ($log -match [regex]::Escape("[CLAIM-CONTESTED] npc=lc_npc_6 prevOwner=$($peerB.Id) newOwner=$($peerE.Id)") -and $log -match "npc=lc_npc_6.*distanceBetweenPlayers=unknown") $log
    $c6 = Get-ClaimCounters $HttpPort
    Check "contested counter = 3 (T3 + T4 + T6)" ($c6.contested -eq 3) "got $($c6.contested)"

    $peerA.Tcp.Close(); $peerB.Tcp.Close(); $peerC.Tcp.Close(); $peerE.Tcp.Close()
}
finally {
    if ($relay -and -not $relay.HasExited) {
        Stop-Process -Id $relay.Id -Force
        # Stop-Process -Force requests termination and returns; it does not
        # wait for the OS to actually tear the process down, so the Serilog
        # File sink's handle on relay*.log can still be open for a moment
        # after this call returns. Without waiting here, the Remove-Item
        # below can silently no-op against a locked file (SilentlyContinue),
        # leaving this relay's own [CLAIM] lines in place for T7 to trip
        # over -- a race, not a claim-logging defect (WO-82, reproduced).
        $relay.WaitForExit(3000) | Out-Null
    }
}

Write-Host "`n--- T7: config gate off -- ClaimLifecycleLogging=false produces no [CLAIM] lines, all-zero counters ---"
Remove-Item (Join-Path $serverDir 'relay*.log') -ErrorAction SilentlyContinue
$relay2 = Start-TestRelay $serverExe $serverDir $TcpPort2 $HttpPort2 @("--NpcClaimValidation:ClaimLifecycleLogging", "false")
try {
    $gPeerA = Connect-Peer 'lc-gate-auth-A' $TcpPort2
    $gPeerB = Connect-Peer 'lc-gate-B' $TcpPort2
    $null = Drain-NpcStates $gPeerA.Stream 500; $null = Drain-NpcStates $gPeerB.Stream 500
    Send-NpcState $gPeerB.Stream 'lc_gate_npc' 1 1 0
    $null = Drain-NpcStatesFor $gPeerA.Stream 'lc_gate_npc'
    Start-Sleep -Milliseconds 300
    $gLog = Get-RelayLogText $serverDir
    Check "no [CLAIM] line anywhere in the log with the gate off" ($gLog -notmatch "\[CLAIM\]") $gLog
    $gCounters = Get-ClaimCounters $HttpPort2
    Check "claim counters all zero with the gate off, despite a real grant" `
        ($gCounters.grants -eq 0 -and $gCounters.releases -eq 0 -and $gCounters.reassignments -eq 0 -and $gCounters.contested -eq 0) `
        "got $($gCounters | ConvertTo-Json -Compress)"
    $gPeerA.Tcp.Close(); $gPeerB.Tcp.Close()
}
finally {
    if ($relay2 -and -not $relay2.HasExited) { Stop-Process -Id $relay2.Id -Force }
}

Write-Host "`n===== $script:Pass passed, $script:Fail failed ====="
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
