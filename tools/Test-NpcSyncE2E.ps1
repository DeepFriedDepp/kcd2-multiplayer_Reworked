<#
.SYNOPSIS
    WO-32 end-to-end: NPC sync -- synthetic peer <-> relay <-> agent <-> game,
    with the real NPC's engine-resolved position read back at every step.

.DESCRIPTION
    Same harness shape as tools/Test-PlayerVitalsE2E.ps1. Three phases:

      Phase 1  EMIT side. The real agent (world authority) relays the mod's
               npc_state events as NpcStateUp (0x26); this peer receives them
               as NpcStateDown (0x27) and checks the payload against the same
               NPC's actual position read out of the running game.

      Phase 2  AUTHORITY guard. This peer, while NOT the authority, sends an
               NpcStateUp naming the test NPC at a displaced position. The
               relay must drop it: no puppet appears, the NPC does not move.

      Phase 3  APPLY side -- the load-bearing half. Requires ONE MANUAL STEP:
               the operator restarts their agent while this peer stays
               connected, so the peer's lower... (higher up-time, lower
               remaining id? no:) -- so the reconnected agent takes a HIGHER
               relay id and this peer becomes the lowest-id ready client, i.e.
               the world authority (confirmed by receiving CombatRole=1).
               The peer then streams NpcStateUp for the test NPC and the test
               asserts the REAL NPC in the running game tracks the stream,
               then releases it and asserts the engine takes the NPC back.

    Every positional claim is read back from the entity itself via the game
    console (WO-34 discipline: a write reporting success proves nothing).

    Needs: relay running (this build), agent running and connected (this
    build), game running via Modding Tools with a save loaded and the WO-32
    pak installed. No native DLL required.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-NpcSyncE2E.ps1
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $PeerName = 'wo32-npc-peer',
    [string] $NpcName = 'ttkc_man_16',
    [string] $KcdLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log',
    [switch] $SkipPhase3
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$HANDSHAKE = 0x00; $ACKTYPE = 0xFF; $POSITION = 0x01
$NPC_STATE_UP = 0x26; $NPC_STATE_DOWN = 0x27; $COMBAT_ROLE = 0x25
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

# Unlike the other E2E scripts' Drain, this one carries a HARD cap: the ghost
# position stream never goes quiet while the local player is moving, so a
# quiet-window-only drain can hang forever (observed: it did).
function Drain($stream, [int] $quietMs = 600, [int] $maxMs = 8000) {
    $out = @(); $deadline = (Get-Date).AddMilliseconds($quietMs)
    $hardStop = (Get-Date).AddMilliseconds($maxMs)
    while ((Get-Date) -lt $deadline -and (Get-Date) -lt $hardStop) {
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

# Runs a chunk that logs "[WO32E] <key>=<value>" and returns the newest value.
function LuaRead([string] $key, [string] $chunk, [int] $waitMs = 900) {
    Lua $chunk
    Start-Sleep -Milliseconds $waitMs
    $rx = [regex]("\[WO32E\] " + [regex]::Escape($key) + "=(\S+)")
    $hit = $null
    foreach ($line in (Get-Content $KcdLog -Tail 400)) { $m = $rx.Match($line); if ($m.Success) { $hit = $m.Groups[1].Value } }
    return $hit
}

# Reads the test NPC's real, engine-resolved position (WO-34 discipline).
function Get-NpcPos {
    $v = LuaRead 'npos' ('local e=System.GetEntityByName("' + $NpcName + '"); if e then local p=e:GetWorldPos(); System.LogAlways(string.format("[WO32E] npos=%.3f,%.3f,%.3f",p.x,p.y,p.z)) else System.LogAlways("[WO32E] npos=GONE") end')
    if ($null -eq $v -or $v -eq 'GONE') { return $null }
    $parts = $v -split ','
    return @{ X = [float]$parts[0]; Y = [float]$parts[1]; Z = [float]$parts[2] }
}

function New-Float([float] $v) { [BitConverter]::GetBytes($v) }

function Send-NpcState($stream, [string] $name, [float] $x, [float] $y, [float] $z, [float] $rot, [float] $hp, [byte] $flags = 0) {
    $nb = [System.Text.Encoding]::UTF8.GetBytes($name)
    $p = New-Object byte[] (1 + $nb.Length + 21)
    $p[0] = [byte]$nb.Length
    [Array]::Copy($nb, 0, $p, 1, $nb.Length)
    $o = 1 + $nb.Length
    [Array]::Copy((New-Float $x),   0, $p, $o,      4)
    [Array]::Copy((New-Float $y),   0, $p, $o + 4,  4)
    [Array]::Copy((New-Float $z),   0, $p, $o + 8,  4)
    [Array]::Copy((New-Float $rot), 0, $p, $o + 12, 4)
    [Array]::Copy((New-Float $hp),  0, $p, $o + 16, 4)
    $p[$o + 20] = $flags
    Send-Packet $stream $NPC_STATE_UP $p
}

function Parse-NpcStateDown([byte[]] $payload) {
    # [sourceGhostId:1][nameLen:1][name][x][y][z][rot][hp][flags]
    $nameLen = [int]$payload[1]
    $name = [System.Text.Encoding]::UTF8.GetString($payload, 2, $nameLen)
    $o = 2 + $nameLen
    New-Object psobject -Property @{
        Source = [int]$payload[0]; Name = $name
        X = [BitConverter]::ToSingle($payload, $o);      Y = [BitConverter]::ToSingle($payload, $o + 4)
        Z = [BitConverter]::ToSingle($payload, $o + 8);  Rot = [BitConverter]::ToSingle($payload, $o + 12)
        Hp = [BitConverter]::ToSingle($payload, $o + 16); Flags = [int]$payload[$o + 20]
    }
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
Write-Host "peer connected as ghost id $myId"

# A position makes this peer 'ready' so the relay will route to it, and spawns
# its ghost far from the test NPC so the ghost cannot physically interfere.
$pos = New-Object byte[] 17
[Array]::Copy((New-Float 2400.0), 0, $pos, 0, 4)
[Array]::Copy((New-Float 2140.0), 0, $pos, 4, 4)
[Array]::Copy((New-Float 112.0),  0, $pos, 8, 4)
[Array]::Copy((New-Float 0.0),    0, $pos, 12, 4)
Send-Packet $s $POSITION $pos
Start-Sleep -Seconds 2

try {
    Write-Host ""
    Write-Host "--- Phase 1: emit side (agent is authority, mod streams real NPCs out) ---" -ForegroundColor Cyan

    Lua 'KCD2MP_EnableNpcSync("on")'
    Start-Sleep -Seconds 1
    $pk = Drain $s 6000
    $npcPk = @($pk | Where-Object { $_.Type -eq $NPC_STATE_DOWN } | ForEach-Object { Parse-NpcStateDown $_.Payload })

    Check "peer received NpcStateDown packets" ($npcPk.Count -gt 0) "got $($pk.Count) packets total, 0 of type 0x27"
    if ($npcPk.Count -gt 0) {
        $badName = @($npcPk | Where-Object { $_.Name -notmatch '^[A-Za-z0-9_]+$' })
        Check "every streamed name is a plain authored name" ($badName.Count -eq 0) "bad: $($badName[0].Name)"

        $names = @($npcPk | ForEach-Object { $_.Name } | Sort-Object -Unique)
        Write-Host "  streamed NPCs: $($names -join ', ')"
        # Distinct names over the whole drain legitimately exceed the cap when
        # NPCs walk in and out of the radius between rescans -- the invariant
        # is the CONCURRENT tracked count, read from the mod itself.
        $tcount = LuaRead 'tcount' ('local n=0; for _ in pairs(KCD2MP.npcTracked) do n=n+1 end; System.LogAlways("[WO32E] tcount="..n)')
        Check "concurrent tracked set respects the WO-32 cap (<=5)" ($null -ne $tcount -and [int]$tcount -le 5) "KCD2MP.npcTracked count = $tcount ($($names.Count) distinct names over the drain window)"

        # The stream must match the real NPC's engine-resolved position: take
        # the NEWEST packet from the drain and read that NPC's real position
        # immediately after. The NPC may be WALKING (schedule), so the
        # tolerance is sized for walking speed times the ~1-2s harness gap,
        # not for a stationary target.
        $probe = $npcPk[-1]
        $real = LuaRead 'ppos' ('local e=System.GetEntityByName("' + $probe.Name + '"); if e then local p=e:GetWorldPos(); System.LogAlways(string.format("[WO32E] ppos=%.3f,%.3f,%.3f",p.x,p.y,p.z)) else System.LogAlways("[WO32E] ppos=GONE") end')
        if ($null -ne $real -and $real -ne 'GONE') {
            $rp = $real -split ','
            $dx = [Math]::Abs([float]$rp[0] - $probe.X); $dy = [Math]::Abs([float]$rp[1] - $probe.Y)
            Check "streamed position matches the real NPC's engine position (<=3m, walking tolerance)" ($dx -le 3.0 -and $dy -le 3.0) "packet=$($probe.X),$($probe.Y) real=$($rp[0]),$($rp[1]) name=$($probe.Name)"
        } else {
            Check "streamed NPC exists in this world" $false "$($probe.Name) not found"
        }
    }

    Lua 'KCD2MP_EnableNpcSync("off")'
    Start-Sleep -Milliseconds 500
    Drain $s 800 | Out-Null

    Write-Host ""
    Write-Host "--- Phase 2: authority guard (peer is NOT authority, its NpcStateUp must be dropped) ---" -ForegroundColor Cyan

    $before = Get-NpcPos
    Check "test NPC '$NpcName' is loaded" ($null -ne $before) "cannot run the guard without it"
    if ($null -ne $before) {
        Send-NpcState $s $NpcName ($before.X + 3.0) $before.Y $before.Z 0.0 100.0
        Start-Sleep -Seconds 2
        $after = Get-NpcPos
        $moved = [Math]::Abs($after.X - $before.X) -gt 0.5 -or [Math]::Abs($after.Y - $before.Y) -gt 0.5
        Check "relay dropped the non-authority NpcStateUp (NPC did not move)" (-not $moved) "before=$($before.X),$($before.Y) after=$($after.X),$($after.Y)"
        $pup = LuaRead 'pup' ('local n=0; for _ in pairs(KCD2MP.npcPuppets) do n=n+1 end; System.LogAlways("[WO32E] pup="..n)')
        Check "no puppet was created" ($pup -eq '0') "npcPuppets count = $pup"
    }

    if ($SkipPhase3) {
        Write-Host ""; Write-Host "Phase 3 skipped by switch." -ForegroundColor Yellow
    } else {
        Write-Host ""
        Write-Host "--- Phase 3: apply side (peer becomes authority and drives the real NPC) ---" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  MANUAL STEP: restart your agent (KcdMpClient) NOW, leaving this window open." -ForegroundColor Yellow
        Write-Host "  The reconnected agent takes a higher relay id, which makes this peer the" -ForegroundColor Yellow
        Write-Host "  lowest-id ready client -- i.e. the world authority. Waiting up to 120s..." -ForegroundColor Yellow

        # Authority confirmation comes from the relay itself: CombatRole=1
        # arrives when the connection set changes. Polled rather than prompted
        # so the test can also run from a non-interactive shell.
        $isAuth = $false
        $seenTypes = @{}
        $deadline = (Get-Date).AddSeconds(120)
        while (-not $isAuth -and (Get-Date) -lt $deadline) {
            foreach ($pk in (Drain $s 1500)) {
                $seenTypes[('0x{0:X2}' -f $pk.Type)] = $true
                if ($pk.Type -eq $COMBAT_ROLE -and [int]$pk.Payload[0] -eq 1) { $isAuth = $true }
            }
        }
        Check "relay granted this peer world authority (CombatRole=1)" $isAuth "not observed within 120s; packet types seen while waiting: $(($seenTypes.Keys | Sort-Object) -join ', ')"

        if ($isAuth) {
            # The agent that just restarted needs several seconds to reconnect
            # and start its receive loop -- packets sent before that reach
            # nobody. Its resumed Ghost (0x02) stream to this peer is the
            # signal it is back and receiving.
            $agentBack = $false
            $ghostDeadline = (Get-Date).AddSeconds(30)
            while (-not $agentBack -and (Get-Date) -lt $ghostDeadline) {
                if (@(Drain $s 1000 2000 | Where-Object { $_.Type -eq 0x02 }).Count -gt 0) { $agentBack = $true }
            }
            Check "agent reconnected and is streaming again (Ghost packets resumed)" $agentBack "no Ghost packet within 30s of the role change"

            $anchor = Get-NpcPos
            Check "test NPC still loaded for the drive" ($null -ne $anchor)
            if ($null -ne $anchor) {
                Write-Host "  anchor: $($anchor.X), $($anchor.Y), $($anchor.Z) -- driving +4m east over 8s at 4Hz"
                for ($i = 1; $i -le 32; $i++) {
                    Send-NpcState $s $NpcName ($anchor.X + $i * 0.125) $anchor.Y $anchor.Z 1.5708 100.0
                    Start-Sleep -Milliseconds 250
                    if ($i -eq 16) {
                        $mid = Get-NpcPos
                        Check "real NPC is tracking the stream mid-drive (moved >1m east)" ($null -ne $mid -and ($mid.X - $anchor.X) -gt 1.0) "mid=$($mid.X) anchor=$($anchor.X)"
                    }
                }
                $end = Get-NpcPos
                Check "real NPC reached the driven region (moved >2.5m east)" ($null -ne $end -and ($end.X - $anchor.X) -gt 2.5) "end=$($end.X) anchor=$($anchor.X)"

                $pup2 = LuaRead 'pup2' ('local n=0; for _ in pairs(KCD2MP.npcPuppets) do n=n+1 end; System.LogAlways("[WO32E] pup2="..n)')
                Check "exactly one puppet active during the drive" ($pup2 -eq '1') "npcPuppets count = $pup2"

                Write-Host "  stream stopped -- waiting for release (releaseS + margin)"
                Start-Sleep -Seconds 6
                $pup3 = LuaRead 'pup3' ('local n=0; for _ in pairs(KCD2MP.npcPuppets) do n=n+1 end; System.LogAlways("[WO32E] pup3="..n)')
                Check "puppet released after the stream went silent" ($pup3 -eq '0') "npcPuppets count = $pup3"

                Start-Sleep -Seconds 4
                $restored = Get-NpcPos
                $backDx = [Math]::Abs($restored.X - $anchor.X); $backDy = [Math]::Abs($restored.Y - $anchor.Y)
                Check "engine took the NPC back toward its own schedule (within 1.5m of anchor)" ($backDx -le 1.5 -and $backDy -le 1.5) "restored=$($restored.X),$($restored.Y) anchor=$($anchor.X),$($anchor.Y) -- an NPC mid-schedule-walk can legitimately fail this; check by eye"
            }
        }
    }
}
finally {
    try { Lua 'KCD2MP_EnableNpcSync("off")' } catch {}
    $tcp.Close()
}

Write-Host ""
Write-Host ("=" * 60)
Write-Host "PASS $script:pass  FAIL $script:fail" -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
if ($script:fail -gt 0) { exit 1 }
