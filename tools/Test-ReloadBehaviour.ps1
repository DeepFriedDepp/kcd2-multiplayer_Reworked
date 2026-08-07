<#
.SYNOPSIS
    WO-28 Phase 0: what actually happens to the connection and the mod's own
    Lua state when a player reloads a save mid-session.

.DESCRIPTION
    Flow C (player death) is designed around "the player who died reloads their
    own most recent save." Whether that reload is disruptive is genuinely
    untested, and there is a known prior bug in the same territory
    (docs/WO-13-findings.md: a save load destroys every pending
    Script.SetTimer while the *Running flags stay true, which permanently
    froze every ghost until the WO-13 liveness fix). So this settles it by
    observation before Flow C is built on an assumption.

    Runs one synthetic peer against the real relay and the real agent, and
    records a one-second-resolution timeline of four independent things while
    the human reloads a save by hand:

      wire (peer side)  Ghost (0x02) packets arriving for the human's own
                        ghost id, and any Disconnect (0x06) for it. This is
                        the answer to "does the reloading player's agent stay
                        connected" -- the relay broadcasts a Disconnect only
                        when that agent's TCP socket actually drops.
      wire (peer out)   the peer keeps sending Position at ~10 Hz on a slow
                        circle, so "the ghost froze" cannot be confused with
                        "the peer stopped walking" (same trick as
                        Bot-WalkingGhost.ps1).
      lua state         KCD2MP.ghosts count, the three tick heartbeats
                        (_interpAliveAt / _emitAliveAt / _labelAliveAt) and
                        their *Running flags -- the exact pair WO-13 found
                        disagreeing after a reload.
      world             whether the peer's own ghost entity kcd2mp_<id> is
                        still standing, read from the world by name rather
                        than from the mod's bookkeeping agreeing with itself.

    Needs: relay running, the human's agent running and connected to it, game
    running via Modding Tools with a save loaded. No native DLL required.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-ReloadBehaviour.ps1 -Seconds 240
#>
[CmdletBinding()]
param(
    [string] $RelayHost = 'localhost',
    [int]    $Port = 7778,
    [string] $PeerName = 'wo28-reload-peer',
    # Long enough to cover: baseline, the human opening the menu, the reload
    # itself, and a good while after the world is back.
    [int]    $Seconds = 240,
    [double] $CircleRadius = 4.0,
    [string] $KcdLog = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log',
    [string] $OutCsv = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'KcdApi.ps1')

$HANDSHAKE = 0x00; $ACK = 0xFF; $POSITION = 0x01
$GHOST = 0x02; $NAME = 0x03; $DISCONNECT = 0x06
$VERSION = 6   # matches Protocol.Version; the relay refuses any mismatch

function Send-Packet($stream, [byte] $type, [byte[]] $payload) {
    if ($null -eq $payload) { $payload = @() }
    $head = [byte[]]@($type, ($payload.Length -band 0xFF), (($payload.Length -shr 8) -band 0xFF))
    $stream.Write($head, 0, 3); if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
    $stream.Flush()
}

function Read-Packet($stream) {
    $head = New-Object byte[] 3; $got = 0
    while ($got -lt 3) { $n = $stream.Read($head, $got, 3 - $got); if ($n -le 0) { return $null }; $got += $n }
    $len = [int]$head[1] -bor ([int]$head[2] -shl 8)
    $body = New-Object byte[] ([Math]::Max($len,1)); $got = 0
    while ($got -lt $len) { $n = $stream.Read($body, $got, $len - $got); if ($n -le 0) { return $null }; $got += $n }
    New-Object psobject -Property @{ Type = [int]$head[0]; Payload = $body }
}

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    try { Invoke-WebRequest -Uri "http://localhost:1403/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 5 | Out-Null; return $true }
    catch { return $false }
}

# Newest [WO28] line in the log, or $null. Read from the tail only: kcd.log is
# multi-megabyte and the emitter writes to it continuously.
function Latest-Wo28Line {
    try {
        $hit = $null
        foreach ($line in (Get-Content $KcdLog -Tail 600 -ErrorAction Stop)) {
            if ($line -match '\[WO28\] (.*)$') { $hit = $Matches[1] }
        }
        return $hit
    } catch { return $null }
}

if (-not (Test-KcdApi)) { throw "debug API not answering -- is the game running via the Modding Tools build with a save loaded?" }

# Anchor the peer's circle on the human's real position so the ghost is
# actually visible to them; exact placement is irrelevant to the measurement,
# but a ghost the human can see turns this from a pure instrument reading into
# one an eyewitness can corroborate.
#
# Read from the emitter's own newest kcd.log line rather than the REST API:
# /api/rpg/SoulList/PlayerSoul returns an empty <Soul/> at every depth tried,
# and the emit line carries x/y/z at ~50 Hz for free.
$px = 2345.0; $py = 2081.0; $pz = 110.7
$anchored = $false
try {
    foreach ($line in (Get-Content $KcdLog -Tail 400 -ErrorAction Stop)) {
        if ($line -match '\[KCD2-MP-DATA\] v\d+ \S+ \S+ (\S+) (\S+) (\S+) ') {
            $px = [double]$Matches[1]; $py = [double]$Matches[2]; $pz = [double]$Matches[3]
            $anchored = $true
        }
    }
} catch { }
if ($anchored) { Write-Host "anchoring on the live player position: $px, $py, $pz" }
else { Write-Host "no emit line found -- falling back to $px, $py, $pz" -ForegroundColor DarkYellow }

$tcp = New-Object System.Net.Sockets.TcpClient($RelayHost, $Port)
$s = $tcp.GetStream(); $s.ReadTimeout = 2000
$nb = [System.Text.Encoding]::UTF8.GetBytes($PeerName)
$hs = New-Object byte[] (2 + $nb.Length)
$hs[0] = $VERSION; $hs[1] = [byte]$nb.Length; [Array]::Copy($nb,0,$hs,2,$nb.Length)
Send-Packet $s $HANDSHAKE $hs
$ackPkt = Read-Packet $s
if ($null -eq $ackPkt -or $ackPkt.Type -ne $ACK) { throw "handshake refused (type $($ackPkt.Type)) -- relay and this script on the same protocol version?" }
$myId = [int]$ackPkt.Payload[0]
Write-Host "peer connected to relay as ghost id $myId (my ghost entity will be kcd2mp_$myId)"

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " WO-28 Phase 0 -- save reload behaviour" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host " Recording for $Seconds s. While this runs:"
Write-Host "   1. let it settle ~20 s so a baseline is on record"
Write-Host "   2. open the game's own menu and LOAD YOUR MOST RECENT SAVE"
Write-Host "      (the game's menu, not any mod command)"
Write-Host "   3. once you're back in the world, play normally and let the"
Write-Host "      rest of the window run out"
Write-Host " Say out loud / note roughly when you clicked Load -- the timeline"
Write-Host " below stamps everything, so it can be correlated afterwards."
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  t     peerGhosts  lastPeerGhost  ghosts  interpAge  emitAge  labelAge  running   myGhostEnt  api  notes"

$rows = New-Object System.Collections.ArrayList
$startTicks = [Diagnostics.Stopwatch]::StartNew()
$lastGhostFromHumanAt = $null
$ghostsThisSecond = 0
$knownNames = @{}
$events = New-Object System.Collections.ArrayList
$lastWo28 = $null
$modInitBaseline = 0
try { $modInitBaseline = ((Get-Content $KcdLog -Tail 4000 -ErrorAction Stop) | Select-String -SimpleMatch 'MOD INIT').Count } catch { }

$tick = 0
while ($startTicks.Elapsed.TotalSeconds -lt $Seconds) {
    $tick++
    $t = $startTicks.Elapsed.TotalSeconds

    # --- outbound: keep walking so a frozen ghost is unambiguous ---
    $ang = ($t / 8.0) * 2 * [Math]::PI
    $x = $px + $CircleRadius * [Math]::Cos($ang)
    $y = $py + $CircleRadius * [Math]::Sin($ang)
    $posPayload = New-Object byte[] 17
    [Array]::Copy([BitConverter]::GetBytes([float]$x), 0, $posPayload, 0, 4)
    [Array]::Copy([BitConverter]::GetBytes([float]$y), 0, $posPayload, 4, 4)
    [Array]::Copy([BitConverter]::GetBytes([float]$pz), 0, $posPayload, 8, 4)
    [Array]::Copy([BitConverter]::GetBytes([float]($ang + [Math]::PI/2)), 0, $posPayload, 12, 4)
    $posPayload[16] = 0
    try { Send-Packet $s $POSITION $posPayload }
    catch {
        [void]$events.Add("t=$([Math]::Round($t,1)) PEER SEND FAILED: $($_.Exception.Message)")
        break
    }

    # --- inbound: drain whatever the relay has for us without blocking ---
    while ($s.DataAvailable) {
        $p = Read-Packet $s
        if ($null -eq $p) { [void]$events.Add("t=$([Math]::Round($t,1)) PEER SOCKET CLOSED BY RELAY"); break }
        switch ($p.Type) {
            $GHOST {
                $gid = [int]$p.Payload[0]
                $ghostsThisSecond++
                $lastGhostFromHumanAt = $t
            }
            $NAME {
                $gid = [int]$p.Payload[0]
                $gname = [Text.Encoding]::UTF8.GetString($p.Payload, 1, $p.Payload.Length - 1)
                if (-not $knownNames.ContainsKey($gid)) {
                    [void]$events.Add("t=$([Math]::Round($t,1)) NAME id=$gid '$gname'  <- a peer (re)joined the relay")
                }
                $knownNames[$gid] = $gname
            }
            $DISCONNECT {
                $gid = [int]$p.Payload[0]
                [void]$events.Add("t=$([Math]::Round($t,1)) DISCONNECT id=$gid ('$($knownNames[$gid])')  <- that agent's socket dropped")
            }
        }
    }

    # --- once a second: sample the game side ---
    if ($tick % 10 -eq 0) {
        $luaOk = Lua ('local n=0 for _ in pairs(KCD2MP.ghosts) do n=n+1 end ' +
            'local function age(v) if not v then return "nil" end return string.format("%.2f", os.clock()-v) end ' +
            'local e=System.GetEntityByName("kcd2mp_' + $myId + '") ' +
            'System.LogAlways("[WO28] g="..n.." ia="..age(KCD2MP._interpAliveAt)..' +
            '" ea="..age(KCD2MP._emitAliveAt).." la="..age(KCD2MP._labelAliveAt)..' +
            '" ir="..tostring(KCD2MP.interpRunning and 1 or 0)..tostring(KCD2MP.emitRunning and 1 or 0)..tostring(KCD2MP.labelRunning and 1 or 0)..' +
            '" me="..tostring(e and 1 or 0).." c="..string.format("%.1f", os.clock()))')

        Start-Sleep -Milliseconds 250
        $line = Latest-Wo28Line
        $fresh = ($null -ne $line -and $line -ne $lastWo28)
        $lastWo28 = $line

        $g = '?'; $ia = '?'; $ea = '?'; $la = '?'; $run = '?'; $me = '?'
        if ($line) {
            if ($line -match 'g=(\S+)')  { $g = $Matches[1] }
            if ($line -match 'ia=(\S+)') { $ia = $Matches[1] }
            if ($line -match 'ea=(\S+)') { $ea = $Matches[1] }
            if ($line -match 'la=(\S+)') { $la = $Matches[1] }
            if ($line -match 'ir=(\S+)') { $run = $Matches[1] }
            if ($line -match 'me=(\S+)') { $me = $Matches[1] }
        }

        $gap = if ($null -eq $lastGhostFromHumanAt) { '-' } else { '{0:N1}s' -f ($t - $lastGhostFromHumanAt) }
        $note = ''
        if (-not $luaOk) { $note = 'LUA CALL FAILED (game busy/loading?)' }
        elseif (-not $fresh) { $note = 'stale [WO28] line (Lua not executing?)' }

        $row = [pscustomobject]@{
            t = [Math]::Round($t,1); peerGhosts = $ghostsThisSecond; lastPeerGhost = $gap
            ghosts = $g; interpAge = $ia; emitAge = $ea; labelAge = $la
            running = $run; myGhostEnt = $me; api = $(if ($luaOk) {'ok'} else {'ERR'}); notes = $note
        }
        [void]$rows.Add($row)
        $colour = if ($note) { 'Yellow' } else { 'Gray' }
        Write-Host ("  {0,-5} {1,-11} {2,-14} {3,-7} {4,-10} {5,-8} {6,-9} {7,-9} {8,-11} {9,-4} {10}" -f `
            $row.t, $row.peerGhosts, $row.lastPeerGhost, $row.ghosts, $row.interpAge, $row.emitAge,
            $row.labelAge, $row.running, $row.myGhostEnt, $row.api, $row.notes) -ForegroundColor $colour
        $ghostsThisSecond = 0
    }

    Start-Sleep -Milliseconds 100
}

Write-Host ""
Write-Host "--- wire events (peer's own view of the relay) ---" -ForegroundColor Cyan
if ($events.Count -eq 0) { Write-Host "  (none -- no peer ever joined or dropped during the window)" }
else { foreach ($e in $events) { Write-Host "  $e" } }

$modInitAfter = 0
try { $modInitAfter = ((Get-Content $KcdLog -Tail 8000 -ErrorAction Stop) | Select-String -SimpleMatch 'MOD INIT').Count } catch { }
Write-Host ""
Write-Host "--- mod re-initialisation ---" -ForegroundColor Cyan
Write-Host "  'MOD INIT' lines in the log tail: baseline $modInitBaseline -> $modInitAfter"
Write-Host "  (an increase means kdcmp.lua ran its startup again after the reload;"
Write-Host "   no increase means the mod's Lua state was never torn down and rebuilt)"

if ($OutCsv) {
    $rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "timeline written to $OutCsv"
}

$tcp.Close()
Write-Host ""
Write-Host "peer disconnected. Read the timeline above against when you clicked Load." -ForegroundColor Cyan
