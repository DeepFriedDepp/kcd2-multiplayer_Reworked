<#
.SYNOPSIS
    WO-28 end-to-end: shared player health, death, and the Flow B damage
    sensor's three guards -- synthetic peer -> relay -> agent -> game.

.DESCRIPTION
    Same shape as tools/Test-AppearanceE2E.ps1: one synthetic TCP peer plays a
    second player against the REAL relay and the REAL agent, and every claim is
    read back out of the running game rather than inferred from the packet
    having been sent.

    Covers, in order:

      Flow A   a peer's PlayerStateUp (0x1F) becomes that ghost's rendered
               health in this world, read back from KCD2MP.ghostHealth and from
               the nameplate string the player actually sees.
      v1/v2    the emitter now writes v2 lines WITH health -- and a v1 line
               injected into kcd.log is still parsed by the agent, proven by
               the position in it coming back around the relay as a Ghost
               packet. A mixed-version session degrades, it does not break.
      Flow C   a peer's PlayerDeathUp (0x23) tags that ghost dead, is
               idempotent on repeat, and clears when that peer's vitals start
               arriving again -- which is what the end of a save reload looks
               like from here.
      Flow B   the three guards, each isolated:
                 1. host-only     -- no hit is reported while this client does
                                     not hold damage authority
                 2. echo-suppress -- a delta caused by an inbound authoritative
                                     write is not reported as a hit
                 3. sign          -- only NEGATIVE health deltas are hits;
                                     regeneration is not

    The Flow B guards are driven by writing the sampler's own baseline
    (KCD2MP.ghostHpSeen) rather than by having a real NPC hit a real ghost.
    That is deliberate and its limits are stated plainly: it exercises the
    decision logic exactly, and does NOT prove an NPC hit in one player's world
    reaches the other player's health in theirs. That last step crosses two
    real games and is marked unverified in docs/WO-28-findings.md.

    Needs: relay running, agent running and connected, game running via Modding
    Tools with a save loaded. No native DLL required for anything here.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-PlayerVitalsE2E.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $PeerName = 'wo28-vitals-peer',
    [string] $KcdLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$HANDSHAKE = 0x00; $ACKTYPE = 0xFF; $POSITION = 0x01; $GHOST = 0x02
$PLAYER_STATE_UP = 0x1F; $PLAYER_DEATH_UP = 0x23
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')   # $PROTOCOL_VERSION, read from Protocol.cs
$VERSION = $PROTOCOL_VERSION

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
    while ($got -lt 3) { try { $n = $stream.Read($head, $got, 3-$got) } catch { return $null }; if ($n -le 0) { return $null }; $got += $n }
    $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
    $body = New-Object byte[] ([Math]::Max($len,1)); $got = 0
    while ($got -lt $len) { try { $n = $stream.Read($body, $got, $len-$got) } catch { return $null }; if ($n -le 0) { return $null }; $got += $n }
    New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body; Len = $len }
}

function Drain($stream, [int] $quietMs = 600) {
    $out = @(); $deadline = (Get-Date).AddMilliseconds($quietMs)
    while ((Get-Date) -lt $deadline) {
        if ($stream.DataAvailable) {
            $p = Read-Packet $stream; if ($null -eq $p) { break }
            $out += $p; $deadline = (Get-Date).AddMilliseconds($quietMs)
        } else { Start-Sleep -Milliseconds 20 }
    }
    return ,$out
}

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    if ($enc.Length -gt 1700) { Write-Host "  WARN chunk $($enc.Length) encoded chars (ceiling ~1716)" -ForegroundColor Yellow }
    try { Invoke-WebRequest -Uri "http://localhost:1403/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null }
    catch { Write-Host "  (console call failed: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

# Runs a chunk that logs "[WO28E] <key>=<value>" and returns the newest value
# for that key. Reading back out of the running game is the point -- a Lua call
# returning without error proves nothing about what it did.
function LuaRead([string] $key, [string] $chunk, [int] $waitMs = 900) {
    Lua $chunk
    Start-Sleep -Milliseconds $waitMs
    $rx = [regex]("\[WO28E\] " + [regex]::Escape($key) + "=(\S+)")
    $hit = $null
    foreach ($line in (Get-Content $KcdLog -Tail 400)) { $m = $rx.Match($line); if ($m.Success) { $hit = $m.Groups[1].Value } }
    return $hit
}

function New-Float([float] $v) { [BitConverter]::GetBytes($v) }

function Send-Vitals($stream, [float] $health, [float] $stamina, [byte] $flags = 0) {
    $p = New-Object byte[] 9
    [Array]::Copy((New-Float $health), 0, $p, 0, 4)
    [Array]::Copy((New-Float $stamina), 0, $p, 4, 4)
    $p[8] = $flags
    Send-Packet $stream $PLAYER_STATE_UP $p
}

# Count of ghost_hit events currently in the log tail, so a test can assert on
# the DELTA rather than on an absolute that other activity could move.
function Get-GhostHitCount {
    return ((Get-Content $KcdLog -Tail 800) | Select-String -SimpleMatch 'ghost_hit').Count
}

if (-not (Test-KcdApi)) { throw "debug API not answering -- game running via Modding Tools with a save loaded?" }

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$s = $tcp.GetStream(); $s.ReadTimeout = 3000
$nb = [System.Text.Encoding]::UTF8.GetBytes($PeerName)
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACKTYPE) { throw "handshake refused (type $($ackPkt.Type)) -- is the relay on this build?" }
$myId = [int]$ackPkt.Payload[0]
Write-Host "peer connected as ghost id $myId (its entity will be kcd2mp_$myId)"

try {
    # A ghost has to exist before anything can be rendered on it.
    $pos = New-Object byte[] 17
    [Array]::Copy((New-Float 2345.0), 0, $pos, 0, 4)
    [Array]::Copy((New-Float 2081.0), 0, $pos, 4, 4)
    [Array]::Copy((New-Float 110.7),  0, $pos, 8, 4)
    [Array]::Copy((New-Float 0.0),    0, $pos, 12, 4)
    Send-Packet $s $POSITION $pos
    Write-Host "sent Position -> the agent should spawn kcd2mp_$myId"
    Start-Sleep -Seconds 3

    Write-Host ""
    Write-Host "--- emitter is on v2 and carries health ---" -ForegroundColor Cyan

    $emitLine = $null
    foreach ($line in (Get-Content $KcdLog -Tail 600)) { if ($line -match '\[KCD2-MP-DATA\] (v\d+) (.*)$') { $emitLine = $Matches[0] } }
    Check "the mod is emitting v2 state lines" ($null -ne $emitLine -and $emitLine -match '\[KCD2-MP-DATA\] v2 ') `
        "newest line: $emitLine"
    if ($emitLine -match '\[KCD2-MP-DATA\] v2 (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+) (\S+)') {
        $emHealth = [double]$Matches[8]
        Check "the v2 line carries a real health reading" ($emHealth -gt 0) "health field = $emHealth"
    } else {
        Check "the v2 line carries a real health reading" $false "could not parse a v2 line at all"
    }

    Write-Host ""
    Write-Host "--- Flow A: a peer's health renders on its ghost ---" -ForegroundColor Cyan

    Send-Vitals $s 42.5 33.0 0
    Start-Sleep -Seconds 2
    $gotH = LuaRead 'aH' ('local v=KCD2MP.ghostHealth["' + $myId + '"] System.LogAlways("[WO28E] aH="..(v and string.format("%.1f",v.h) or "none"))')
    $gotS = LuaRead 'aS' ('local v=KCD2MP.ghostHealth["' + $myId + '"] System.LogAlways("[WO28E] aS="..(v and string.format("%.1f",v.s) or "none"))')
    Check "the ghost's stored health is the value the peer sent" ($gotH -eq '42.5') "read back '$gotH', expected 42.5"
    Check "the ghost's stored stamina is the value the peer sent" ($gotS -eq '33.0') "read back '$gotS', expected 33.0"

    # The nameplate is what a player actually sees, so assert on that string and
    # not only on the table behind it.
    $label = LuaRead 'aL' ('local l=KCD2MP.labelCache["' + $myId + '"] System.LogAlways("[WO28E] aL="..(l and string.gsub(l.name," ","_") or "none"))')
    Check "the rendered nameplate shows the health" ($null -ne $label -and $label -match '43_HP|42_HP') `
        "nameplate reads '$label'"

    Send-Vitals $s 88.0 90.0 0
    Start-Sleep -Seconds 2
    $gotH2 = LuaRead 'aH2' ('local v=KCD2MP.ghostHealth["' + $myId + '"] System.LogAlways("[WO28E] aH2="..(v and string.format("%.1f",v.h) or "none"))')
    Check "a later value replaces the earlier one" ($gotH2 -eq '88.0') "read back '$gotH2', expected 88.0"

    Write-Host ""
    Write-Host "--- v1 compatibility: an old pak's line still parses ---" -ForegroundColor Cyan

    # Deterministic rather than racing the live emitter: stop it, inject one v1
    # line with an unmistakable position, and see whether the agent parsed it --
    # proven by that position coming back to this peer as a Ghost packet.
    Lua 'KCD2MP_StopEmitter()'
    Start-Sleep -Milliseconds 800
    [void](Drain $s 500)
    Lua 'System.LogAlways("[KCD2-MP-DATA] v1 999001 1.000 1234.500 5678.250 99.000 0.7500 0")'
    Start-Sleep -Seconds 2
    $pkts = Drain $s 900
    $v1Ghost = @($pkts | Where-Object {
        $_.Type -eq $GHOST -and [Math]::Abs([BitConverter]::ToSingle($_.Payload,1) - 1234.5) -lt 0.05
    })
    Check "a v1 emit line is still parsed and its position reaches peers" ($v1Ghost.Count -ge 1) `
        "got $($v1Ghost.Count) Ghost packet(s) at x=1234.5 -- a mixed-version session must degrade, not break"

    Lua "KCD2MP_StartEmitter(20)"
    Start-Sleep -Seconds 2
    $emitBack = $null
    foreach ($line in (Get-Content $KcdLog -Tail 200)) { if ($line -match '\[KCD2-MP-DATA\] v2 ') { $emitBack = $line } }
    Check "the v2 emitter restarts cleanly afterwards" ($null -ne $emitBack)

    Write-Host ""
    Write-Host "--- Flow C: a peer's death ---" -ForegroundColor Cyan

    Send-Packet $s $PLAYER_DEATH_UP @()
    Start-Sleep -Seconds 2
    $dead1 = LuaRead 'cD' ('System.LogAlways("[WO28E] cD="..tostring(KCD2MP.ghostDead["' + $myId + '"] and true or false))')
    Check "the ghost is tagged dead" ($dead1 -eq 'true') "read back '$dead1'"

    $labelDead = LuaRead 'cL' ('local l=KCD2MP.labelCache["' + $myId + '"] System.LogAlways("[WO28E] cL="..(l and string.gsub(l.name," ","_") or "none"))')
    Check "the nameplate says so, and drops the now-stale health figure" `
        ($null -ne $labelDead -and $labelDead -match 'dead' -and $labelDead -notmatch 'HP') `
        "nameplate reads '$labelDead'"

    Send-Packet $s $PLAYER_DEATH_UP @()
    Send-Packet $s $PLAYER_DEATH_UP @()
    Start-Sleep -Seconds 2
    $dead2 = LuaRead 'cD2' ('System.LogAlways("[WO28E] cD2="..tostring(KCD2MP.ghostDead["' + $myId + '"] and true or false))')
    Check "a repeated death changes nothing (idempotent)" ($dead2 -eq 'true') "read back '$dead2'"

    # The peer's game is back: vitals start arriving again, which is exactly
    # what the end of a save reload looks like from this side.
    Send-Vitals $s 100.0 100.0 0
    Start-Sleep -Seconds 2
    $dead3 = LuaRead 'cD3' ('System.LogAlways("[WO28E] cD3="..tostring(KCD2MP.ghostDead["' + $myId + '"] and true or false))')
    Check "the death tag clears once that player's vitals arrive again" ($dead3 -eq 'false') "read back '$dead3'"

    Write-Host ""
    Write-Host "--- Flow B guards, each isolated ---" -ForegroundColor Cyan

    $sensorState = LuaRead 'bS' 'System.LogAlways("[WO28E] bS="..tostring(KCD2MP.hitSensorOn))'
    Write-Host "  (this client's damage authority, as granted by the relay: $sensorState)"

    # GUARD 1 -- host-only. Force the sensor off and give it a large drop to find.
    Lua 'KCD2MP_SetHitSensor(false)'
    Start-Sleep -Milliseconds 600
    $before1 = Get-GhostHitCount
    Lua ('KCD2MP.ghostHpSeen["' + $myId + '"]=200')
    Start-Sleep -Seconds 2
    $after1 = Get-GhostHitCount
    Check "GUARD 1 host-only: no hit is reported while this client lacks authority" `
        ($after1 -eq $before1) "ghost_hit count $before1 -> $after1"

    # GUARD 3 -- sign. Sensor ON, baseline BELOW current health, so the delta is
    # positive (regeneration).
    Lua 'KCD2MP_SetHitSensor(true)'
    Start-Sleep -Milliseconds 600
    Lua ('KCD2MP.ghostHpSeen["' + $myId + '"]=nil KCD2MP.ghostHpSkip["' + $myId + '"]=nil')
    Start-Sleep -Seconds 1
    $before3 = Get-GhostHitCount
    Lua ('KCD2MP.ghostHpSeen["' + $myId + '"]=1 KCD2MP.ghostHpSkip["' + $myId + '"]=nil')
    Start-Sleep -Seconds 2
    $after3 = Get-GhostHitCount
    Check "GUARD 3 sign: a POSITIVE delta (regeneration) is not a hit" `
        ($after3 -eq $before3) "ghost_hit count $before3 -> $after3"

    # GUARD 2 -- echo suppression. Baseline set high (a big apparent drop) AND
    # the skip flag set, exactly as an inbound authoritative write leaves it.
    $before2 = Get-GhostHitCount
    Lua ('KCD2MP.ghostHpSeen["' + $myId + '"]=200 KCD2MP.ghostHpSkip["' + $myId + '"]=true')
    Start-Sleep -Seconds 2
    $after2 = Get-GhostHitCount
    Check "GUARD 2 echo: a drop caused by an inbound authoritative write is not a hit" `
        ($after2 -eq $before2) "ghost_hit count $before2 -> $after2"

    # And the same write path really does set that flag, rather than the test
    # having set it by hand and proved nothing about production code.
    $skipSet = LuaRead 'bK' ('KCD2MP.ghostHpSkip["' + $myId + '"]=nil KCD2MP_SetGhostHealth("' + $myId + '",55,55,0) System.LogAlways("[WO28E] bK="..tostring(KCD2MP.ghostHpSkip["' + $myId + '"] and true or false))' ) 400
    Check "the inbound-write path is what sets the skip flag" ($skipSet -eq 'true') "read back '$skipSet'"

    # POSITIVE CONTROL -- with the sensor on, no skip pending, and a genuine
    # negative delta, a hit IS reported. Without this the three guards above
    # could all be passing because nothing ever fires.
    $before4 = Get-GhostHitCount
    Lua ('KCD2MP.ghostHpSkip["' + $myId + '"]=nil KCD2MP.ghostHpSeen["' + $myId + '"]=200')
    Start-Sleep -Seconds 3
    $after4 = Get-GhostHitCount
    Check "POSITIVE CONTROL: a genuine negative delta IS reported as a hit" `
        ($after4 -gt $before4) "ghost_hit count $before4 -> $after4 -- if this fails, the three guards above prove nothing"

    Lua 'KCD2MP_SetHitSensor(false)'
}
finally {
    $tcp.Close()
    Start-Sleep -Seconds 2
    Write-Host ""
    Write-Host "peer disconnected -- the agent should have removed kcd2mp_$myId"
}

Write-Host ""
Write-Host "$script:pass passed, $script:fail failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
