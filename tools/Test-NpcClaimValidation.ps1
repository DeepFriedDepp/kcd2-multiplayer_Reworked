<#
.SYNOPSIS
    WO-66: exercises the relay's NPC claim-update validation gates (speed,
    rotation, reserved-name, stale-owner) and the splice-back audit with
    synthetic peers against a relay this script starts itself. Needs NO game
    and NO agent -- pure wire test, same harness shape as Test-TimeSkipRelay.

.DESCRIPTION
    Peers: A connects first (lowest id = world/damage authority, passive
    receiver here), B and C are non-authority claimants.

      V1  speed gate      -> legit movement accepted; teleport-class jump
                             rejected; the claim is RETAINED (C cannot take
                             it); a subsequent sane update flows again.
      V2  rotation        -> NaN rotZ rejected; NaN position rejected
                             (counted under speed); a large-but-finite rotZ
                             is accepted as-is (scalar yaw: "borderline
                             unnormalized" means finite, receivers wrap).
      V3  reserved name   -> a claim for "kcd2mp_*" is refused; a normal
                             claim right after is unaffected.
      V4  stale owner     -> simple: B's claim expires, C reclaims, B's late
                             packet is rejected and C's stream is unaffected.
                             Hold variant: same around the 15 s engaged hold
                             -- B's late packet arriving INSIDE C's hold
                             window after the reassign is rejected.
      V5  splice-back     -> a crafted rival packet (ENGAGED bit + teleport
                             position) moves neither ownership nor the hold;
                             rejected owner packets never refresh a claim
                             (garbage-only claim expires on schedule and the
                             next packet re-seeds -- the documented
                             self-heal for a genuine teleport).
      V6  counters        -> GET api/information/npc-validation matches the
                             exact per-reason tallies the tests produced.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-NpcClaimValidation.ps1
#>
[CmdletBinding()]
param(
    [int] $TcpPort  = 7793,
    [int] $HttpPort = 5301
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION, read from Protocol.cs

$HANDSHAKE     = 0x00
$ACK_TYPE      = 0xFF
$NPCSTATE_UP   = 0x26
$NPCSTATE_DOWN = 0x27
$ENGAGED_FLAGS = [byte]0x24   # drawn (0x04) + ENGAGED (0x20), the WO-60 test value

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

# NpcStateUp (0x26): [nameLen:1][name][x:4f][y:4f][z:4f][rotZ:4f][health:4f][flags:1]
# Full float control incl. NaN/Inf via [float]::NaN etc.
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

# Drain for NpcStateDown (0x27): [sourceGhostId:1][nameLen:1][name][fixed tail 21]
function Drain-NpcStates($stream, [int] $quietMs = 1200) {
    $stream.ReadTimeout = $quietMs
    $found = @()
    while ($true) {
        $p = Read-Packet $stream
        if ($null -eq $p) { break }
        if ($p.Type -eq $NPCSTATE_DOWN -and $p.Payload.Length -ge 2) {
            $nameLen = [int]$p.Payload[1]
            $npcName = if ($nameLen -gt 0) { [System.Text.Encoding]::UTF8.GetString($p.Payload, 2, $nameLen) } else { '' }
            $o = 2 + $nameLen
            $found += New-Object psobject -Property @{
                Source = [int]$p.Payload[0]
                Name   = $npcName
                X      = [BitConverter]::ToSingle($p.Payload, $o)
                RotZ   = [BitConverter]::ToSingle($p.Payload, $o + 12)
            }
        }
    }
    ,$found
}

# Assign-then-filter on purpose (the T17 lesson: piping the comma-wrapped
# array straight into Where-Object hands the whole array as one item).
function Drain-NpcStatesFor($stream, [string]$npcName, [int]$quietMs = 1200) {
    $all = Drain-NpcStates $stream $quietMs
    ,@($all | Where-Object { $_.Name -eq $npcName })
}

function Get-RejectCounters {
    Invoke-RestMethod -Uri "http://localhost:$HttpPort/api/information/npc-validation" -TimeoutSec 5
}

function Connect-Peer([string]$name) {
    $tcp = New-Object System.Net.Sockets.TcpClient('localhost', $TcpPort)
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

# ---- start a fresh relay of THIS build ----
$serverExe = Join-Path $PSScriptRoot '..\dotnet\KcdMp.Server\bin\Debug\net8.0\KcdMpServer.exe'
if (-not (Test-Path $serverExe)) { throw "relay not built: $serverExe (run dotnet build first)" }
Write-Host "starting relay: $serverExe (tcp $TcpPort, http $HttpPort)"
$env:ASPNETCORE_URLS = "http://localhost:$HttpPort"
$relay = Start-Process -FilePath $serverExe -ArgumentList "--port", "$TcpPort" -PassThru -WindowStyle Hidden
$deadline = (Get-Date).AddSeconds(15)
$up = $false
while (-not $up -and (Get-Date) -lt $deadline) {
    if ($relay.HasExited) { throw "relay exited during startup (port in use?)" }
    try { $probe = New-Object System.Net.Sockets.TcpClient('localhost', $TcpPort); $probe.Close(); $up = $true }
    catch { Start-Sleep -Milliseconds 400 }
}
if (-not $up) { throw "relay never opened tcp $TcpPort" }
Start-Sleep -Milliseconds 500

try {
    $peerA = Connect-Peer 'wo66-auth-A'     # lowest id = world authority, passive receiver
    $peerB = Connect-Peer 'wo66-claim-B'
    $peerC = Connect-Peer 'wo66-claim-C'
    Write-Host "peers: A=id$($peerA.Id) B=id$($peerB.Id) C=id$($peerC.Id)"
    $null = Drain-NpcStates $peerA.Stream 800; $null = Drain-NpcStates $peerB.Stream 800; $null = Drain-NpcStates $peerC.Stream 800

    Write-Host "`n--- V0: counters start at zero ---"
    $c0 = Get-RejectCounters
    Check "all four counters zero at startup" ($c0.speed -eq 0 -and $c0.rotation -eq 0 -and $c0.reservedName -eq 0 -and $c0.staleOwner -eq 0) "got $($c0 | ConvertTo-Json -Compress)"

    Write-Host "`n--- V1: speed gate -- legit accepted, teleport rejected, claim retained, sane resumes ---"
    Send-NpcState $peerB.Stream 'wo66_npc_1' 100 200 10           # B claims: seeds the baseline
    Start-Sleep -Milliseconds 200
    Send-NpcState $peerB.Stream 'wo66_npc_1' 105 200 10           # 5 m in ~200 ms: allowed
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_1'
    Check "seed + legitimate 5m move both broadcast (2 pkts, src=B)" ($gotA.Count -eq 2 -and @($gotA.Source | Sort-Object -Unique).Count -eq 1 -and $gotA[0].Source -eq $peerB.Id) "got $($gotA | ConvertTo-Json -Compress)"
    Send-NpcState $peerB.Stream 'wo66_npc_1' 900 200 10           # ~795 m jump: teleport-class
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_1'
    Check "teleport-class jump dropped (A received nothing)" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Send-NpcState $peerC.Stream 'wo66_npc_1' 300 400 10           # rival probes: claim must be RETAINED
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_1'
    Check "rejection did not release the claim (C's takeover dropped)" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Send-NpcState $peerB.Stream 'wo66_npc_1' 106 200 10           # sane again, near the last ACCEPTED pos
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_1'
    Check "holder's subsequent sane update accepted (src=B)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerB.Id) "got $($gotA | ConvertTo-Json -Compress)"

    Write-Host "`n--- V2: rotation -- NaN rotZ rejected; NaN position rejected; finite-but-large rotZ accepted ---"
    Send-NpcState $peerB.Stream 'wo66_npc_2' 100 200 10 ([float]::NaN)
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_2'
    Check "NaN rotZ dropped (A received nothing)" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Send-NpcState $peerB.Stream 'wo66_npc_2' ([float]::PositiveInfinity) 200 10 0
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_2'
    Check "Inf position dropped (A received nothing)" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Send-NpcState $peerB.Stream 'wo66_npc_2' 100 200 10 ([float]100.0)   # finite drift-class yaw: accept as-is
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_2'
    Check "finite-but-unwrapped rotZ=100 accepted verbatim" ($gotA.Count -eq 1 -and [Math]::Abs($gotA[0].RotZ - 100) -lt 0.01) "got $($gotA | ConvertTo-Json -Compress)"

    Write-Host "`n--- V3: reserved name -- kcd2mp_* claim refused, normal claim unaffected ---"
    Send-NpcState $peerC.Stream 'kcd2mp_7' 100 200 10             # a ghost's spawn name
    $gotA = Drain-NpcStatesFor $peerA.Stream 'kcd2mp_7'
    Check "claim for 'kcd2mp_7' refused (A received nothing)" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Send-NpcState $peerC.Stream 'wo66_npc_3' 100 200 10
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_3'
    Check "normal claim right after is unaffected (src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"

    Write-Host "`n--- V4a: stale owner, simple -- B expires, C reclaims, B's late packet rejected ---"
    Send-NpcState $peerB.Stream 'wo66_npc_4' 100 200 10           # B claims, never engaged
    $null = Drain-NpcStates $peerA.Stream 800
    Write-Host "  (waiting out NpcClaimTimeoutSeconds = 5s...)"
    Start-Sleep -Seconds 6
    Send-NpcState $peerC.Stream 'wo66_npc_4' 120 200 10           # C reclaims after expiry
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_4'
    Check "C's reclaim granted after expiry (src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"
    Send-NpcState $peerB.Stream 'wo66_npc_4' 101 200 10           # former owner's LATE packet
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_4'
    Check "former owner B's late packet rejected" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Send-NpcState $peerC.Stream 'wo66_npc_4' 121 200 10           # new holder's stream unaffected
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_4'
    Check "new holder C's stream unaffected (src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"

    Write-Host "`n--- V4b: stale owner around the ENGAGED hold -- late packet inside the new holder's hold window ---"
    Send-NpcState $peerB.Stream 'wo66_npc_5' 100 200 10 0 $ENGAGED_FLAGS   # B claims, ENGAGED (hold armed)
    $null = Drain-NpcStates $peerA.Stream 800
    Write-Host "  (waiting out the 15s engaged hold + 5s silence...)"
    Start-Sleep -Seconds 16
    Send-NpcState $peerC.Stream 'wo66_npc_5' 130 200 10 0 $ENGAGED_FLAGS   # reassign: C claims, ENGAGED
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_5'
    Check "C's engaged claim granted after B's hold decayed (src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"
    Send-NpcState $peerB.Stream 'wo66_npc_5' 101 200 10 0 $ENGAGED_FLAGS   # B's late packet INSIDE C's hold
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_5'
    Check "B's late engaged packet inside C's hold window rejected" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"

    Write-Host "`n--- V5a: splice-back -- crafted ENGAGED+teleport rival packet moves neither ownership nor hold ---"
    Send-NpcState $peerB.Stream 'wo66_npc_5' 9000 9000 10 0 $ENGAGED_FLAGS # rival garbage with authority-state ambitions
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_5'
    Check "crafted rival packet dropped" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Send-NpcState $peerC.Stream 'wo66_npc_5' 131 200 10 0 $ENGAGED_FLAGS   # owner still C, stream still flows
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_5'
    Check "ownership unchanged: C still streams (src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"

    Write-Host "`n--- V5b: rejected packets never refresh a claim -- garbage-only claim expires on schedule, then re-seeds ---"
    Send-NpcState $peerB.Stream 'wo66_npc_6' 100 200 10           # B claims (seed, accepted)
    $null = Drain-NpcStates $peerA.Stream 800
    for ($i = 1; $i -le 4; $i++) {                                # ~3.6 s of pure garbage, each rejected
        # 900 ms, not 1 s: all four must land INSIDE the 5 s expiry window
        # measured from the seed (a rejected packet must not refresh it), with
        # margin for send overhead on a slow machine.
        Start-Sleep -Milliseconds 900
        Send-NpcState $peerB.Stream 'wo66_npc_6' 100000 200 10    # ~100 km east
    }
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_6' 800
    Check "all 4 garbage refreshes dropped" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Write-Host "  (waiting for the un-refreshed claim to expire...)"
    Start-Sleep -Seconds 3                                        # ~7s since the SEED: expiry ran despite the garbage
    Send-NpcState $peerC.Stream 'wo66_npc_6' 140 200 10           # C can claim: garbage never refreshed B's claim
    $gotA = Drain-NpcStatesFor $peerA.Stream 'wo66_npc_6'
    Check "garbage never refreshed the claim (C's reclaim granted, src=C)" ($gotA.Count -eq 1 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"

    Write-Host "`n--- V6: rejection counters match the exact tallies ---"
    # speed: V1 teleport(1) + V2 Inf position(1) + V5b garbage(4)         = 6
    # rotation: V2 NaN rotZ                                               = 1
    # reserved-name: V3 kcd2mp_7                                          = 1
    # stale-owner: V1 C-probe(1) + V4a B-late(1) + V4b B-late(1) + V5a(1) = 4
    $c1 = Get-RejectCounters
    Check "speed counter = 6"         ($c1.speed -eq 6)        "got $($c1.speed)"
    Check "rotation counter = 1"      ($c1.rotation -eq 1)     "got $($c1.rotation)"
    Check "reserved-name counter = 1" ($c1.reservedName -eq 1) "got $($c1.reservedName)"
    Check "stale-owner counter = 4"   ($c1.staleOwner -eq 4)   "got $($c1.staleOwner)"

    $peerA.Tcp.Close(); $peerB.Tcp.Close(); $peerC.Tcp.Close()
}
finally {
    if ($relay -and -not $relay.HasExited) { Stop-Process -Id $relay.Id -Force }
    Remove-Item Env:ASPNETCORE_URLS -ErrorAction SilentlyContinue
}

Write-Host "`n===== $script:Pass passed, $script:Fail failed ====="
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
