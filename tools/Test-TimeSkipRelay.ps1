<#
.SYNOPSIS
    WO-38 Phase 1: exercises the relay's one-active-skip arbitration for the
    time-skip sync layer (0x28/0x29) with three synthetic peers. Needs NO game
    and NO agent -- this is a pure wire test against a relay this script
    starts itself, so it can run on a machine where KCD2 is not even up.

.DESCRIPTION
    Scenarios, in order, against one relay instance (ids are assigned 1,2,3):

      T1  A starts a skip           -> B and C receive TimeSkipDown(start,src=A);
                                       A receives nothing back.
      T2  B starts while A's active -> nobody receives anything (B is joined,
                                       deterministically, by relay arrival order).
      T3  A finishes (t=100000)     -> B and C receive phase=done (announced).
      T4  B finishes (t=100300)     -> A and C receive phase=done-quiet: B was
                                       joined, so the session converges up to
                                       B's overshoot with NO second toast.
      T5  C sends a bare done       -> A and B receive phase=done (announced):
          (t=200000, nothing active)   the fast-travel clock-jump shape.
      T6  A starts twice            -> B receives exactly ONE start (duplicate
                                       start markers for one skip are absorbed).
      T7  B joins T6's skip, then A -> B's later done still goes out as
          (the owner) disconnects      done-quiet: grace membership survives
          and B finishes (t=300000)    the owner vanishing mid-skip.

    This validates exactly the rules docs/WO-38-source-report.md Section F's
    fix demands: first-come ownership, join-not-race, deterministic by relay
    arrival order, single notification per user-visible skip.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-TimeSkipRelay.ps1
#>
[CmdletBinding()]
param(
    [int] $TcpPort  = 7791,
    [int] $HttpPort = 5299
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION, read from Protocol.cs

$HANDSHAKE     = 0x00
$ACK_TYPE      = 0xFF   # NOT named $ACK: a local $ack would shadow it (PS vars are case-insensitive)
$TIMESKIP_UP   = 0x28
$TIMESKIP_DOWN = 0x29
$PHASE_START = 0; $PHASE_DONE = 1; $PHASE_QUIET = 2
$KIND_SLEEP  = 0; $KIND_WAIT  = 1

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

# Reads until the stream goes quiet, returning only TimeSkipDown packets as
# parsed objects. Everything else the relay chatters (Name, CombatRole,
# ReleaseVersion, Disconnect, Ghost) is drained and ignored.
function Drain-TimeSkips($stream, [int] $quietMs = 1200) {
    $stream.ReadTimeout = $quietMs
    $found = @()
    while ($true) {
        $p = Read-Packet $stream
        if ($null -eq $p) { break }
        if ($p.Type -eq $TIMESKIP_DOWN -and $p.Payload.Length -eq 7) {
            $found += New-Object psobject -Property @{
                Source    = [int]$p.Payload[0]
                Phase     = [int]$p.Payload[1]
                Kind      = [int]$p.Payload[2]
                WorldTime = [BitConverter]::ToUInt32($p.Payload, 3)
            }
        }
    }
    ,$found
}

function Send-TimeSkip($stream, [int]$phase, [int]$kind, [uint32]$worldTime) {
    $payload = New-Object byte[] 6
    $payload[0] = [byte]$phase; $payload[1] = [byte]$kind
    [Array]::Copy([BitConverter]::GetBytes($worldTime), 0, $payload, 2, 4)
    Send-Packet $stream $TIMESKIP_UP $payload
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
# Wait for the TCP listener rather than sleeping a guessed amount.
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
    $peerA = Connect-Peer 'wo38-skip-A'
    $peerB = Connect-Peer 'wo38-skip-B'
    $peerC = Connect-Peer 'wo38-skip-C'
    Write-Host "peers: A=id$($peerA.Id) B=id$($peerB.Id) C=id$($peerC.Id)"
    # settle the join chatter (Names, CombatRole...) out of every buffer
    $null = Drain-TimeSkips $peerA.Stream 800; $null = Drain-TimeSkips $peerB.Stream 800; $null = Drain-TimeSkips $peerC.Stream 800

    Write-Host "`n--- T1: A starts a skip ---"
    Send-TimeSkip $peerA.Stream $PHASE_START $KIND_SLEEP 0
    $gotB = Drain-TimeSkips $peerB.Stream; $gotC = Drain-TimeSkips $peerC.Stream; $gotA = Drain-TimeSkips $peerA.Stream
    Check "B received the start (src=A)" ($gotB.Count -eq 1 -and $gotB[0].Phase -eq $PHASE_START -and $gotB[0].Source -eq $peerA.Id) "got $($gotB | ConvertTo-Json -Compress)"
    Check "C received the start (src=A)" ($gotC.Count -eq 1 -and $gotC[0].Phase -eq $PHASE_START -and $gotC[0].Source -eq $peerA.Id) "got $($gotC | ConvertTo-Json -Compress)"
    Check "A heard nothing back about its own skip" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"

    Write-Host "`n--- T2: B starts while A's skip is active (join, not race) ---"
    Send-TimeSkip $peerB.Stream $PHASE_START $KIND_SLEEP 0
    $gotA = Drain-TimeSkips $peerA.Stream; $gotC = Drain-TimeSkips $peerC.Stream
    Check "A received nothing (B was joined, not broadcast)" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"
    Check "C received nothing (B was joined, not broadcast)" ($gotC.Count -eq 0) "got $($gotC.Count) pkt(s)"

    Write-Host "`n--- T3: A (owner) finishes at t=100000 ---"
    Send-TimeSkip $peerA.Stream $PHASE_DONE $KIND_SLEEP 100000
    $gotB = Drain-TimeSkips $peerB.Stream; $gotC = Drain-TimeSkips $peerC.Stream
    Check "B received announced done t=100000" ($gotB.Count -eq 1 -and $gotB[0].Phase -eq $PHASE_DONE -and $gotB[0].WorldTime -eq 100000 -and $gotB[0].Source -eq $peerA.Id) "got $($gotB | ConvertTo-Json -Compress)"
    Check "C received announced done t=100000" ($gotC.Count -eq 1 -and $gotC[0].Phase -eq $PHASE_DONE -and $gotC[0].WorldTime -eq 100000) "got $($gotC | ConvertTo-Json -Compress)"

    Write-Host "`n--- T4: B (joined) finishes at t=100300 -> quiet convergence, no second toast ---"
    Send-TimeSkip $peerB.Stream $PHASE_DONE $KIND_SLEEP 100300
    $gotA = Drain-TimeSkips $peerA.Stream; $gotC = Drain-TimeSkips $peerC.Stream
    Check "A received done-QUIET t=100300" ($gotA.Count -eq 1 -and $gotA[0].Phase -eq $PHASE_QUIET -and $gotA[0].WorldTime -eq 100300 -and $gotA[0].Source -eq $peerB.Id) "got $($gotA | ConvertTo-Json -Compress)"
    Check "C received done-QUIET t=100300" ($gotC.Count -eq 1 -and $gotC[0].Phase -eq $PHASE_QUIET -and $gotC[0].WorldTime -eq 100300) "got $($gotC | ConvertTo-Json -Compress)"

    Write-Host "`n--- T5: C sends a bare done (the fast-travel clock-jump shape) ---"
    Send-TimeSkip $peerC.Stream $PHASE_DONE $KIND_WAIT 200000
    $gotA = Drain-TimeSkips $peerA.Stream; $gotB = Drain-TimeSkips $peerB.Stream
    Check "A received ANNOUNCED done t=200000 (instant skip)" ($gotA.Count -eq 1 -and $gotA[0].Phase -eq $PHASE_DONE -and $gotA[0].WorldTime -eq 200000 -and $gotA[0].Source -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"
    Check "B received ANNOUNCED done t=200000 (instant skip)" ($gotB.Count -eq 1 -and $gotB[0].Phase -eq $PHASE_DONE -and $gotB[0].WorldTime -eq 200000) "got $($gotB | ConvertTo-Json -Compress)"

    Write-Host "`n--- T6: duplicate start markers from the owner are absorbed ---"
    Send-TimeSkip $peerA.Stream $PHASE_START $KIND_SLEEP 0
    Send-TimeSkip $peerA.Stream $PHASE_START $KIND_SLEEP 0
    $gotB = Drain-TimeSkips $peerB.Stream
    Check "B received exactly one start" ($gotB.Count -eq 1 -and $gotB[0].Phase -eq $PHASE_START) "got $($gotB.Count) pkt(s)"
    $null = Drain-TimeSkips $peerC.Stream   # clear C too

    Write-Host "`n--- T7: owner disconnects mid-skip; a joined player's done still goes out quiet ---"
    Send-TimeSkip $peerB.Stream $PHASE_START $KIND_SLEEP 0      # B joins A's active skip
    Start-Sleep -Milliseconds 300
    $peerA.Tcp.Close()                                          # the owner vanishes
    Start-Sleep -Milliseconds 800
    $null = Drain-TimeSkips $peerB.Stream 800; $null = Drain-TimeSkips $peerC.Stream 800   # absorb Disconnect chatter
    Send-TimeSkip $peerB.Stream $PHASE_DONE $KIND_SLEEP 300000
    $gotC = Drain-TimeSkips $peerC.Stream
    Check "C received done-QUIET t=300000 (grace survives owner disconnect)" ($gotC.Count -eq 1 -and $gotC[0].Phase -eq $PHASE_QUIET -and $gotC[0].WorldTime -eq 300000 -and $gotC[0].Source -eq $peerB.Id) "got $($gotC | ConvertTo-Json -Compress)"

    $peerB.Tcp.Close(); $peerC.Tcp.Close()
}
finally {
    if ($relay -and -not $relay.HasExited) { Stop-Process -Id $relay.Id -Force }
    Remove-Item Env:ASPNETCORE_URLS -ErrorAction SilentlyContinue
}

Write-Host "`n===== $script:Pass passed, $script:Fail failed ====="
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }

