<#
.SYNOPSIS
    WO-6 A2: runs the visual-capability probes against a running KCD2 and reports
    what this mod can actually draw.

.DESCRIPTION
    Sends each block of probe_visual.lua through the game's debug console
    endpoint, then reads the [KCD2-MP-PROBE] answers back out of kcd.log. Same
    harness as Probe-Transport.ps1 -- no pak rebuild, no game restart, nothing
    persisted.

    Two kinds of block, and they are handled differently:

      * inventory blocks  answer themselves into the log.
      * VISUAL blocks     put something on screen. No script can grade those.
                          The run pauses on each one (-DwellSec, default 12) and
                          prints exactly what to look for. WATCH THE GAME during
                          the pause and note what you saw -- that report is the
                          actual result of this probe.

    Read-only and non-destructive: every game call is inside a Lua pcall, the
    draw loop self-terminates after 25 s, and the run always finishes with the
    cleanup block. Nothing touches game mode, fader, vignette or any CVar.

    ALT-TAB WARNING: the game must have focus for you to see anything, but the
    console endpoint is HTTP, so this script can drive it from a second monitor
    or a second machine. If you only have one screen, run with -DwellSec 20 and
    alt-tab back to the game as soon as each block is sent.

.PARAMETER Only
    Run just these blocks (by name), e.g. -Only reset,drawloop,drawtext_shapes.
    reset/drawloop are prepended automatically when a visual block needs them.

.PARAMETER Cleanup
    Run only the cleanup block and exit. Use this if a probe left something on
    screen or a modal will not close.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-Visual.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Probe-Visual.ps1 -Cleanup
#>
[CmdletBinding()]
param(
    [string]   $ApiBase = 'http://localhost:1403',
    [string]   $LuaFile,
    [string]   $KcdLog,
    [string[]] $Only,
    [switch]   $Cleanup,
    [int]      $DwellSec = 12,
    [int]      $SettleMs = 1500
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not reliably populated inside param() defaults on PS 5.1.
$ScriptDir =
    if ($PSScriptRoot) { $PSScriptRoot }
    elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
    else { (Get-Location).Path }

if (-not $LuaFile) { $LuaFile = Join-Path $ScriptDir 'probe_visual.lua' }

# Blocks that draw. Everything else answers into the log on its own.
$VisualBlocks = @{
    'drawtext_shapes'   = 'FOUR lines of text, top-left area. A = the call kdcmp.lua uses today; B = amber; C = should be the medieval quill hand (AlexanderQuill); D = green. REPORT: do B/C/D differ from A in colour and shape, and is C calligraphic?'
    'drawtext_space'    = 'FIVE text markers. One at top-left, then a RIGHT and a BOTTOM marker for each candidate coordinate space. REPORT: which pair sits near the screen edges -- the ones labelled 800x600, or the ones labelled 1920x1080? (The other pair will be off screen entirely.) This decides every coordinate in the overlay.'
    'draw2dline_space'  = 'Up to two rectangles. RED = pixel coords, GREEN = 0..1 coords. REPORT: which one appeared (possibly both, possibly neither).'
    'draw2dline_alpha'  = 'FOUR horizontal amber rules. REPORT: do they visibly fade from solid to nearly invisible, or are they all the same?'
    'flash_infotext'    = 'A line of text centre-screen, in the GAME''s own style. REPORT: did it appear, and did it look native (not our debug text)?'
    'flash_notification'= 'A corner notification in the game''s style. REPORT: appeared or not.'
    'flash_dicescore'   = 'THE BIG ONE: the game''s real dice scoreboard, showing target 2500, player 1234/600, opponent 987/350. REPORT: did the native panel appear, and are those numbers on it?'
    'flash_diceselector'= 'Two dice-selection highlights and a dice cursor, lower-middle of the screen. REPORT: did any of them draw, and roughly where?'
    'flash_tutorial'    = 'The tutorial parchment box, text "Wagers / Jonas stakes 40 groschen". REPORT: did it appear, and was the text STYLED (gold, bold) or did raw <font> tags show as literal text?'
    'flash_skillcheck'  = 'A skill-check success flourish. REPORT: appeared or not, and whether it animated.'
    'flash_modal_open'  = 'A native yes/no modal asking you to accept a dice challenge. ANSWER IT in game -- the reply should show up below as vis.modal.event. REPORT: did it open, and did answering register?'
}

function Resolve-KcdLog {
    if ($KcdLog) { return $KcdLog }

    # Same discovery path the agent and Probe-Transport.ps1 use: Steam install
    # dir, then every library root in libraryfolders.vdf.
    $steam = $null
    foreach ($k in @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKCU:\SOFTWARE\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.InstallPath) { $steam = $v.InstallPath; break }
            if ($v.SteamPath)   { $steam = $v.SteamPath;   break }
        } catch { }
    }
    if (-not $steam) { return $null }

    $roots = @($steam)
    $vdf = Join-Path $steam 'config\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($line in Get-Content $vdf) {
            if ($line -match '"path"\s+"([^"]+)"') { $roots += $Matches[1].Replace('\\', '\') }
        }
    }
    # The Modding Tools entry is a separate install with its own kcd.log, and it
    # is the one that gets launched for modding -- take the most recent.
    $found = @()
    foreach ($r in ($roots | Sort-Object -Unique)) {
        $common = Join-Path $r 'steamapps\common'
        if (-not (Test-Path $common)) { continue }
        Get-ChildItem $common -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match 'Kingdom|KCD' } |
            ForEach-Object {
                $found += Get-ChildItem $_.FullName -Filter 'kcd.log' -Recurse -Depth 2 -ErrorAction SilentlyContinue
            }
    }
    if ($found.Count -eq 0) { return $null }
    return ($found | Sort-Object LastWriteTime -Descending | Select-Object -First 1).FullName
}

function Invoke-Lua([string] $Lua) {
    # EscapeDataString, not UrlEncode: percent-encodes spaces rather than
    # turning them into '+', matching what the agent already sends successfully.
    $encoded = [uri]::EscapeDataString('#' + $Lua)
    Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$encoded" `
        -UseBasicParsing -TimeoutSec 15 | Out-Null
}

# --- preflight -------------------------------------------------------------

Write-Host '=== KCD2-MP WO-6 visual capability probe (A2) ===' -ForegroundColor Cyan

try {
    $cal = Invoke-WebRequest -Uri "$ApiBase/api/rpg/Calendar?depth=1" -UseBasicParsing -TimeoutSec 6
} catch {
    Write-Host "FAILED: no debug API at $ApiBase" -ForegroundColor Red
    Write-Host '  Launch KCD2 through the KCD2 Modding Tools entry and load a save.'
    exit 1
}
if ($cal.Content -notmatch 'GameTime="([^"]+)"' -or [double]$Matches[1] -le 0) {
    Write-Host 'FAILED: game is reachable but no save is loaded (GameTime = 0).' -ForegroundColor Red
    Write-Host '  These probes need an in-world context. Load a save and re-run.'
    exit 1
}
Write-Host "Game reachable at $ApiBase, save loaded." -ForegroundColor Green

$logPath = Resolve-KcdLog
if (-not $logPath) {
    Write-Host 'FAILED: could not locate kcd.log. Pass -KcdLog <path>.' -ForegroundColor Red
    exit 1
}
Write-Host "Reading results from $logPath"

if (-not (Test-Path $LuaFile)) {
    Write-Host "FAILED: probe source not found at $LuaFile" -ForegroundColor Red
    exit 1
}

# Only look at lines produced from here on, so repeat runs don't show stale hits.
$startLine = (Get-Content $logPath -ErrorAction SilentlyContinue | Measure-Object -Line).Lines

# --- split the Lua into blocks ---------------------------------------------

$blocks = [ordered]@{}
$name = $null
$buf = New-Object System.Collections.Generic.List[string]
foreach ($line in Get-Content $LuaFile) {
    if ($line -match '^--@@BLOCK\s+(\S+)') {
        if ($name) { $blocks[$name] = ($buf -join "`n") }
        $name = $Matches[1]
        $buf.Clear()
    } elseif ($name) {
        $buf.Add($line)
    }
}
if ($name) { $blocks[$name] = ($buf -join "`n") }

# --- choose which blocks to send -------------------------------------------

$order = @($blocks.Keys)

if ($Cleanup) {
    $order = @('cleanup')
} elseif ($Only) {
    # Invoked as `powershell -File ... -Only a,b,c`, every argument arrives as a
    # single raw string, so a comma-separated list binds as ONE element rather
    # than an array. Re-split so both that form and a normal in-session call
    # behave the same.
    $Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ -ne '' })

    $sel = New-Object System.Collections.Generic.List[string]
    # Several blocks hang state off the KCD2MPVIS namespace, and the drawn ones
    # additionally need the render loop -- pull those in rather than failing
    # confusingly on a nil global.
    $sel.Add('reset')
    $needsLoop = $false
    foreach ($o in $Only) { if ($o -like 'draw*' -and $o -ne 'drawloop') { $needsLoop = $true } }
    if ($needsLoop) { $sel.Add('drawloop') }
    foreach ($o in $Only) {
        if (-not $blocks.Contains($o)) {
            Write-Host "FAILED: no block named '$o'. Known: $($order -join ', ')" -ForegroundColor Red
            exit 1
        }
        if (-not $sel.Contains($o)) { $sel.Add($o) }
    }
    $order = $sel.ToArray()
}

Write-Host ("Sending {0} blocks: {1}" -f $order.Count, ($order -join ', '))
if (-not $Cleanup) {
    Write-Host ''
    Write-Host 'VISUAL blocks pause for you to LOOK AT THE GAME. Alt-tab back to it now.' -ForegroundColor Yellow
    Write-Host ("Each visual block holds for {0}s. Write down what you see." -f $DwellSec) -ForegroundColor Yellow
    Start-Sleep -Seconds 3
}

# --- send ------------------------------------------------------------------

foreach ($k in $order) {
    $isVisual = $VisualBlocks.ContainsKey($k)
    if ($isVisual) {
        Write-Host ''
        Write-Host "--- VISUAL: $k ---" -ForegroundColor Magenta
        Write-Host ("    LOOK FOR: " + $VisualBlocks[$k]) -ForegroundColor Magenta
    } else {
        Write-Host "  -> $k" -NoNewline
    }

    try {
        Invoke-Lua $blocks[$k]
        if (-not $isVisual) { Write-Host '  sent' -ForegroundColor Green }
    } catch {
        Write-Host "  FAILED to send: $($_.Exception.Message)" -ForegroundColor Red
        continue
    }

    if ($isVisual) {
        for ($s = $DwellSec; $s -gt 0; $s--) {
            Write-Host ("`r    watching... {0,2}s " -f $s) -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
        Write-Host "`r    done.        "
    } else {
        Start-Sleep -Milliseconds 250
    }
}

# The draw loop self-terminates after 25 s, but a run that ends early would
# otherwise leave native panels up -- always finish clean.
if (-not $Cleanup -and $order -notcontains 'cleanup') {
    try { Invoke-Lua $blocks['cleanup'] } catch { }
}

Write-Host ''
Write-Host "Waiting ${SettleMs}ms for the log to flush..."
Start-Sleep -Milliseconds $SettleMs

# --- collect ---------------------------------------------------------------

$all = Get-Content $logPath
$fresh = if ($all.Count -gt $startLine) { $all[$startLine..($all.Count - 1)] } else { @() }
$hits = $fresh | Where-Object { $_ -match '\[KCD2-MP-PROBE\]' }

if (-not $hits) {
    Write-Host ''
    Write-Host 'No probe output found in kcd.log.' -ForegroundColor Yellow
    Write-Host 'Either the console rejected the chunks, or LogAlways is not reaching this log.'
    exit 2
}

Write-Host ''
Write-Host "=== PROGRAMMATIC FINDINGS ($($hits.Count) lines) ===" -ForegroundColor Cyan
$hits | ForEach-Object { if ($_ -match '\[KCD2-MP-PROBE\]\s*(.+)$') { '  ' + $Matches[1] } }

Write-Host ''
Write-Host '=== REMINDER ===' -ForegroundColor Cyan
Write-Host '  A Flash call logging =true means it did not THROW. It does NOT mean'
Write-Host '  anything appeared. Only your own description of the screen decides that.'

$outFile = Join-Path $ScriptDir 'probe-visual-results.txt'
$hits | Set-Content -Path $outFile -Encoding utf8
Write-Host ''
Write-Host "Written to $outFile" -ForegroundColor Green
Write-Host 'Paste that file back into the session ALONG WITH what you saw on screen.' -ForegroundColor Green
