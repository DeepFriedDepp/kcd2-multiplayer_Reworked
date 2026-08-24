<#
.SYNOPSIS
    WO-48: exercises the relay half of the dropped-item sync layer
    (0x32/0x33 drop, 0x34/0x35 claim) with three synthetic peers. Needs NO
    game and NO agent -- a pure wire test against a relay this script starts
    itself, same harness as Test-TimeSkipRelay.ps1.

.DESCRIPTION
    Scenarios, in order, against one relay instance (ids assigned 1,2,3):

      I1  A broadcasts a drop        -> B and C receive ItemDropDown(src=A),
                                        payload verbatim; A receives nothing.
      I2  B claims the drop          -> ALL of A, B, C receive
                                        ItemClaimDown(claimer=B) -- the echo
                                        back to the claimant is load-bearing
                                        (it is the claim's confirmation).
      I3  the race: B and C claim    -> every peer sees B's echo FIRST and
          the same dropId, B's          C's second, in identical order --
          arriving first               relay arrival order is the arbiter,
                                        and clients resolve on the first.
      I4  malformed drop (short)     -> dropped by the relay, nothing
                                        forwarded, connection still healthy.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-ItemSyncRelay.ps1
#>
[CmdletBinding()]
param(
    [int] $TcpPort  = 7793,
    [int] $HttpPort = 5301
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION

$HANDSHAKE   = 0x00
$ACK_TYPE    = 0xFF
$ITEMDROP_UP    = 0x32
$ITEMDROP_DOWN  = 0x33
$ITEMCLAIM_UP   = 0x34
$ITEMCLAIM_DOWN = 0x35

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
    } catch [System.IO.IOException] { $null }
}

# ItemDropUp (0x32): [dropId:4][itemClass:16][amount:2][health:4f][x:4f][y:4f][z:4f]
function Send-ItemDrop($stream, [uint32]$dropId, [Guid]$itemClass, [int]$amount, [float]$health, [float]$x, [float]$y, [float]$z) {
    $payload = New-Object byte[] 38
    [Array]::Copy([BitConverter]::GetBytes($dropId), 0, $payload, 0, 4)
    [Array]::Copy($itemClass.ToByteArray(), 0, $payload, 4, 16)
    [Array]::Copy([BitConverter]::GetBytes([uint16]$amount), 0, $payload, 20, 2)
    [Array]::Copy([BitConverter]::GetBytes($health), 0, $payload, 22, 4)
    [Array]::Copy([BitConverter]::GetBytes($x), 0, $payload, 26, 4)
    [Array]::Copy([BitConverter]::GetBytes($y), 0, $payload, 30, 4)
    [Array]::Copy([BitConverter]::GetBytes($z), 0, $payload, 34, 4)
    Send-Packet $stream $ITEMDROP_UP $payload
}

function Send-ItemClaim($stream, [uint32]$dropId) {
    Send-Packet $stream $ITEMCLAIM_UP ([BitConverter]::GetBytes($dropId))
}

# Drain for ItemDropDown (0x33): [src:1][dropId:4][class:16][amount:2][health:4f][x/y/z:12]
function Drain-ItemDrops($stream, [int] $quietMs = 1200) {
    $stream.ReadTimeout = $quietMs
    $found = @()
    while ($true) {
        $p = Read-Packet $stream
        if ($null -eq $p) { break }
        if ($p.Type -eq $ITEMDROP_DOWN -and $p.Payload.Length -eq 39) {
            $classBytes = New-Object byte[] 16
            [Array]::Copy($p.Payload, 5, $classBytes, 0, 16)
            $found += New-Object psobject -Property @{
                Source = [int]$p.Payload[0]
                DropId = [BitConverter]::ToUInt32($p.Payload, 1)
                Class  = New-Object Guid (,$classBytes)
                Amount = [BitConverter]::ToUInt16($p.Payload, 21)
                Health = [BitConverter]::ToSingle($p.Payload, 23)
                X      = [BitConverter]::ToSingle($p.Payload, 27)
            }
        }
    }
    ,$found
}

# Drain for ItemClaimDown (0x35): [claimer:1][dropId:4]
function Drain-ItemClaims($stream, [int] $quietMs = 1200) {
    $stream.ReadTimeout = $quietMs
    $found = @()
    while ($true) {
        $p = Read-Packet $stream
        if ($null -eq $p) { break }
        if ($p.Type -eq $ITEMCLAIM_DOWN -and $p.Payload.Length -eq 5) {
            $found += New-Object psobject -Property @{
                Claimer = [int]$p.Payload[0]
                DropId  = [BitConverter]::ToUInt32($p.Payload, 1)
            }
        }
    }
    ,$found
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
    $peerA = Connect-Peer 'wo48-item-A'
    $peerB = Connect-Peer 'wo48-item-B'
    $peerC = Connect-Peer 'wo48-item-C'
    Write-Host "peers: A=id$($peerA.Id) B=id$($peerB.Id) C=id$($peerC.Id)"
    $null = Drain-ItemDrops $peerA.Stream 800; $null = Drain-ItemDrops $peerB.Stream 800; $null = Drain-ItemDrops $peerC.Stream 800

    $onion = [Guid]'4a6fa310-067a-404d-9813-bd1761d1c70d'

    Write-Host "`n--- I1: A broadcasts a drop ---"
    Send-ItemDrop $peerA.Stream 123456789 $onion 2 0.75 2350.5 2144.25 117.75
    $gotB = Drain-ItemDrops $peerB.Stream; $gotC = Drain-ItemDrops $peerC.Stream; $gotA = Drain-ItemDrops $peerA.Stream
    Check "B received the drop verbatim (src=A)" ($gotB.Count -eq 1 -and $gotB[0].Source -eq $peerA.Id -and $gotB[0].DropId -eq 123456789 -and $gotB[0].Class -eq $onion -and $gotB[0].Amount -eq 2 -and [Math]::Abs($gotB[0].Health - 0.75) -lt 0.001 -and [Math]::Abs($gotB[0].X - 2350.5) -lt 0.001) "got $($gotB | ConvertTo-Json -Compress)"
    Check "C received the drop (src=A)" ($gotC.Count -eq 1 -and $gotC[0].DropId -eq 123456789) "got $($gotC | ConvertTo-Json -Compress)"
    Check "A heard nothing back about its own drop" ($gotA.Count -eq 0) "got $($gotA.Count) pkt(s)"

    Write-Host "`n--- I2: B claims -> the echo reaches EVERYONE, claimant included ---"
    Send-ItemClaim $peerB.Stream 123456789
    $gotA = Drain-ItemClaims $peerA.Stream; $gotB = Drain-ItemClaims $peerB.Stream; $gotC = Drain-ItemClaims $peerC.Stream
    Check "A received claim (claimer=B)" ($gotA.Count -eq 1 -and $gotA[0].Claimer -eq $peerB.Id -and $gotA[0].DropId -eq 123456789) "got $($gotA | ConvertTo-Json -Compress)"
    Check "B received its OWN claim echo (the confirmation)" ($gotB.Count -eq 1 -and $gotB[0].Claimer -eq $peerB.Id) "got $($gotB | ConvertTo-Json -Compress)"
    Check "C received claim (claimer=B)" ($gotC.Count -eq 1 -and $gotC[0].Claimer -eq $peerB.Id) "got $($gotC | ConvertTo-Json -Compress)"

    Write-Host "`n--- I3: the race -- B and C claim the same drop, B first ---"
    Send-ItemDrop $peerA.Stream 987654321 $onion 1 1.0 100 200 10
    $null = Drain-ItemDrops $peerB.Stream 800; $null = Drain-ItemDrops $peerC.Stream 800
    Send-ItemClaim $peerB.Stream 987654321
    Start-Sleep -Milliseconds 150          # deterministic relay arrival order for the test
    Send-ItemClaim $peerC.Stream 987654321
    $gotA = Drain-ItemClaims $peerA.Stream; $gotB = Drain-ItemClaims $peerB.Stream; $gotC = Drain-ItemClaims $peerC.Stream
    Check "A saw B's echo first, C's second" ($gotA.Count -eq 2 -and $gotA[0].Claimer -eq $peerB.Id -and $gotA[1].Claimer -eq $peerC.Id) "got $($gotA | ConvertTo-Json -Compress)"
    Check "B (winner) saw its own echo first"  ($gotB.Count -eq 2 -and $gotB[0].Claimer -eq $peerB.Id) "got $($gotB | ConvertTo-Json -Compress)"
    Check "C (loser) saw B's echo first -- the rollback signal" ($gotC.Count -eq 2 -and $gotC[0].Claimer -eq $peerB.Id -and $gotC[1].Claimer -eq $peerC.Id) "got $($gotC | ConvertTo-Json -Compress)"

    Write-Host "`n--- I4: malformed (short) drop is not forwarded, connection survives ---"
    Send-Packet $peerA.Stream $ITEMDROP_UP ([byte[]]@(1,2,3,4))   # 4 bytes, not 38
    $gotB = Drain-ItemDrops $peerB.Stream
    Check "B received nothing for the short packet" ($gotB.Count -eq 0) "got $($gotB.Count) pkt(s)"
    Send-ItemDrop $peerA.Stream 555 $onion 1 1.0 1 2 3
    $gotB = Drain-ItemDrops $peerB.Stream
    Check "A's connection still relays a valid drop afterwards" ($gotB.Count -eq 1 -and $gotB[0].DropId -eq 555) "got $($gotB | ConvertTo-Json -Compress)"

    $peerA.Tcp.Close(); $peerB.Tcp.Close(); $peerC.Tcp.Close()
}
finally {
    if ($relay -and -not $relay.HasExited) { Stop-Process -Id $relay.Id -Force }
    Remove-Item Env:ASPNETCORE_URLS -ErrorAction SilentlyContinue
}

Write-Host "`n===== $script:Pass passed, $script:Fail failed ====="
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }
