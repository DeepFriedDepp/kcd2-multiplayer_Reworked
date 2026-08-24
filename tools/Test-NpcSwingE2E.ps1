<#
.SYNOPSIS  WO-49 live E2E: a puppeted NPC's swing cue renders as a REAL native swing.
.DESCRIPTION
    One-human test, modeled on Test-NpcSyncE2E.ps1's Phase 3 (authority claim)
    and Test-WeaponSwingE2E.ps1 (native swing over the wire, WO-47).

    This synthetic peer becomes the world authority (manual agent restart,
    same as Test-NpcSyncE2E), then streams NpcStateUp for a real world NPC
    near the human observer: weapon-drawn heartbeats first, then three
    swing-cue packets (flags bit 3). The human's client receives them as
    NpcStateDown; the WO-49 agent path resolves the LOCAL copy's entity id
    (npcid emit) and equipped weapon (SoulsByName REST) and queues a real
    Mannequin swing through the DLL pipe -- the same ghost_swing mechanism
    WO-45/46/47 live-verified on player ghosts.

    Automated checks: puppet start + npcid emit in kcd.log, SWING lines with
    the matching entity id in the native mirror log. The render quality
    verdict is the human's.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-NpcSwingE2E.ps1 -NpcName ttkc_man_16
#>
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $PeerName = 'wo49-npc-swing-peer',
    [string] $NpcName = '',   # empty = auto-pick the nearest living human NPC
    [string] $KcdLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log',
    [string] $NativeLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcdmp-native.mirror.log',
    [int]    $Swings = 3
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$HANDSHAKE = 0x00; $ACKTYPE = 0xFF; $POSITION = 0x01
$NPC_STATE_UP = 0x26; $COMBAT_ROLE = 0x25
. (Join-Path $PSScriptRoot 'ProtocolVersion.ps1')
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

function LuaRead([string] $key, [string] $chunk, [int] $waitMs = 900) {
    Lua $chunk
    Start-Sleep -Milliseconds $waitMs
    $rx = [regex]("\[WO49E\] " + [regex]::Escape($key) + "=(\S+)")
    $hit = $null
    foreach ($line in (Get-Content $KcdLog -Tail 400)) { $m = $rx.Match($line); if ($m.Success) { $hit = $m.Groups[1].Value } }
    return $hit
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

if (-not (Test-KcdApi)) { throw "debug API not answering -- game running with a save loaded?" }

# ---- pick / verify the test NPC ------------------------------------------
if ($NpcName -eq '') {
    $NpcName = LuaRead 'pick' ('local pl=player; ' +
        'local pp=pl and pl:GetWorldPos(); local best,bd=nil,1e9; ' +
        'if pp then for _,e in ipairs(System.GetEntitiesInSphere(pp,25) or {}) do ' +
        'local nm=e:GetName() or ""; ' +
        'if e.human and e.actor and e~=pl and not string.find(nm,"kcd2mp") and not e.actor:IsDead() then ' +
        'local q=e:GetWorldPos(); local dx,dy=q.x-pp.x,q.y-pp.y; local d=dx*dx+dy*dy; ' +
        'if d<bd then best,bd=nm,d end end end end; ' +
        'System.LogAlways("[WO49E] pick="..tostring(best))')
    if ($null -eq $NpcName -or $NpcName -eq 'nil') { throw "no living human NPC within 25m of the player -- stand near one (a guard is ideal) or pass -NpcName" }
    Write-Host "auto-picked test NPC: $NpcName"
}
$anchorV = LuaRead 'npos' ('local e=System.GetEntityByName("' + $NpcName + '"); if e then local p=e:GetWorldPos(); System.LogAlways(string.format("[WO49E] npos=%.3f,%.3f,%.3f",p.x,p.y,p.z)) else System.LogAlways("[WO49E] npos=GONE") end')
if ($null -eq $anchorV -or $anchorV -eq 'GONE') { throw "test NPC '$NpcName' not loaded" }
$ap = $anchorV -split ','
$anchor = @{ X = [float]$ap[0]; Y = [float]$ap[1]; Z = [float]$ap[2] }
Write-Host "anchor: $($anchor.X), $($anchor.Y), $($anchor.Z)"

# Baselines so the checks below only count NEW lines.
$kcdBase = (Get-Content $KcdLog -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
$natBase = (Get-Content $NativeLog -ErrorAction SilentlyContinue | Measure-Object -Line).Lines

# ---- connect as the synthetic authority ----------------------------------
$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$s = $tcp.GetStream(); $s.ReadTimeout = 3000
$nb = [System.Text.Encoding]::UTF8.GetBytes($PeerName)
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACKTYPE) { throw "handshake refused -- is the relay on this build?" }
Write-Host "peer connected as ghost id $([int]$ackPkt.Payload[0])"

# Ready + ghost far from the action.
$pos = New-Object byte[] 17
[Array]::Copy((New-Float 2400.0), 0, $pos, 0, 4)
[Array]::Copy((New-Float 2140.0), 0, $pos, 4, 4)
[Array]::Copy((New-Float 112.0),  0, $pos, 8, 4)
[Array]::Copy((New-Float 0.0),    0, $pos, 12, 4)
Send-Packet $s $POSITION $pos
Start-Sleep -Seconds 2

try {
    Write-Host ""
    Write-Host "  MANUAL STEP: restart your agent (KcdMpClient) NOW, leaving this window open." -ForegroundColor Yellow
    Write-Host "  That makes this peer the lowest-id ready client = world authority. Waiting up to 120s..." -ForegroundColor Yellow
    $isAuth = $false
    $deadline = (Get-Date).AddSeconds(120)
    while (-not $isAuth -and (Get-Date) -lt $deadline) {
        foreach ($pk in (Drain $s 1500)) {
            if ($pk.Type -eq $COMBAT_ROLE -and [int]$pk.Payload[0] -eq 1) { $isAuth = $true }
        }
    }
    Check "relay granted this peer world authority (CombatRole=1)" $isAuth "not observed within 120s"
    if (-not $isAuth) { throw "cannot drive the NPC without authority" }

    $agentBack = $false
    $ghostDeadline = (Get-Date).AddSeconds(30)
    while (-not $agentBack -and (Get-Date) -lt $ghostDeadline) {
        if (@(Drain $s 1000 2000 | Where-Object { $_.Type -eq 0x02 }).Count -gt 0) { $agentBack = $true }
    }
    Check "agent reconnected (Ghost packets resumed)" $agentBack

    # ---- phase A: drawn heartbeats -> puppet start + npcid + equipped read ----
    Write-Host ""
    Write-Host "--- Phase A: weapon-drawn stream (puppet start, npcid emit, equipped read) ---" -ForegroundColor Cyan
    for ($i = 0; $i -lt 24; $i++) {   # 6 s at 4 Hz, flags=4 (drawn)
        Send-NpcState $s $NpcName $anchor.X $anchor.Y $anchor.Z 0.0 100.0 4
        Start-Sleep -Milliseconds 250
    }
    $newKcd = Get-Content $KcdLog | Select-Object -Skip $kcdBase
    Check "puppet started for $NpcName" (@($newKcd | Where-Object { $_ -match "NPC-SYNC puppet start $([regex]::Escape($NpcName))" }).Count -gt 0)
    $npcidLine = @($newKcd | Where-Object { $_ -match "\[KCD2-MP-EVT\] v1 \d+ npcid $([regex]::Escape($NpcName)) ([0-9A-Fa-f]+)" })
    Check "npcid emitted for $NpcName" ($npcidLine.Count -gt 0)
    $npcEntityDec = $null
    if ($npcidLine.Count -gt 0 -and $npcidLine[0] -match "npcid \S+ ([0-9A-Fa-f]+)") {
        $npcEntityDec = [Convert]::ToUInt64($Matches[1], 16)
        Write-Host "  npc entity id: 0x$($Matches[1]) = $npcEntityDec"
    }
    Check "puppet drew its weapon" (@($newKcd | Where-Object { $_ -match "NPC-SYNC $([regex]::Escape($NpcName)) drew weapon" }).Count -gt 0)

    # ---- phase B: swing cues -> native SWING lines ----------------------------
    Write-Host ""
    Write-Host "--- Phase B: $Swings swing cues, 4 s apart -- WATCH THE NPC NOW ---" -ForegroundColor Cyan
    for ($sw = 1; $sw -le $Swings; $sw++) {
        Send-NpcState $s $NpcName $anchor.X $anchor.Y $anchor.Z 0.0 100.0 12   # drawn + swing cue
        Write-Host "  swing cue $sw sent"
        for ($i = 0; $i -lt 16; $i++) {   # 4 s of drawn heartbeats between cues
            Send-NpcState $s $NpcName $anchor.X $anchor.Y $anchor.Z 0.0 100.0 4
            Start-Sleep -Milliseconds 250
        }
    }
    Start-Sleep -Seconds 1
    $newNat = @()
    if (Test-Path $NativeLog) { $newNat = Get-Content $NativeLog | Select-Object -Skip $natBase }
    $swingLines = @($newNat | Where-Object { $_ -match "SWING: entity=(\d+) queued" })
    Check "native SWING lines appeared ($($swingLines.Count)/$Swings)" ($swingLines.Count -ge $Swings) "got $($swingLines.Count)"
    if ($null -ne $npcEntityDec) {
        $matched = @($swingLines | Where-Object { $_ -match "SWING: entity=$npcEntityDec\b" })
        Check "SWING entity id matches the npcid ($npcEntityDec)" ($matched.Count -ge $Swings) "matched $($matched.Count) of $($swingLines.Count)"
    }
    $fellBack = @((Get-Content $KcdLog | Select-Object -Skip $kcdBase) | Where-Object { $_ -match "NPC-SYNC swing cue $([regex]::Escape($NpcName))" })
    Check "old Lua guard-flick cue did NOT run (native owned the render)" ($fellBack.Count -eq 0) "cue ran $($fellBack.Count) time(s) -- native path fell back"

    # ---- wind down -------------------------------------------------------------
    for ($i = 0; $i -lt 8; $i++) {   # sheathe + let the stream go quiet
        Send-NpcState $s $NpcName $anchor.X $anchor.Y $anchor.Z 0.0 100.0 0
        Start-Sleep -Milliseconds 250
    }
    Write-Host ""
    Write-Host "HUMAN VERDICT NEEDED: did $NpcName perform $Swings real, complete swings" -ForegroundColor Yellow
    Write-Host "(weapon in hand, full attack motion -- WO-47 player-ghost quality)?" -ForegroundColor Yellow
}
finally {
    $tcp.Close()
}

Write-Host ""
Write-Host "$script:pass passed, $script:fail failed"
if ($script:fail -gt 0) { exit 1 }
