<#
.SYNOPSIS
  WO-73 -- stand a KCD2 instance up (GPU or WARP), load a save, prove the world
  ticks, and measure what it costs. Experiment code; nothing here is shipped.

.DESCRIPTION
  One invocation = one row of the cost table. The sequence is fixed so the rows
  are comparable:

     launch -> wait for :1403 -> wh_sys_LoadGame -> save-lock -> tick proof
            -> cost sample -> second tick read -> HARD KILL -> verify

  Three things this sequence encodes, each learned the hard way:

  * wh_sys_LoadGame <playline> <name> is the named-save load. It is a shipped,
    unflagged console command ("Loads save specified by playline number and file
    name"); the playline number is the on-disk directory index, so UI
    "Playline 2" is 1. WO-72 concluded no such entry point existed.
  * The tick proof reads GameTime AND WorldTime AND IsWorldTimePaused. World
    time is paused for the whole of a tutorial mission, so a save chosen at
    random can show a frozen clock on a perfectly live world.
  * The save lock is taken AFTER the load, because one taken at the menu does
    not survive it.

  The hard kill is not tidiness: r_HeadlessStartup, r_Width and r_Height are
  DUMPTODISK, and this machine is also the gaming machine.

.PARAMETER Config
  gpu        real GPU, native resolution   -- the control column
  warp       WARP software adapter, 1080p
  warp-small WARP with the render target forced tiny

.EXAMPLE
  .\Invoke-Wo73Run.ps1 -Config warp -BackupDir C:\tmp\wo73 -ExpectedSystemCfgMd5 <md5>
#>
[CmdletBinding()]
param(
    [ValidateSet('gpu', 'warp', 'warp-small')]
    [string] $Config = 'gpu',

    # On-disk playline directory index and save basename (no .whs).
    [int]    $Playline = 1,
    [string] $SaveName = 'exit',

    # Index of the "Microsoft Basic Render Driver" (WARP) adapter from kcd.log's
    # adapter enumeration. 1 on this box; on a GPU-less VM it should be 0 and
    # r_overrideDXGIAdapter becomes unnecessary.
    [int]    $WarpAdapterIndex = 1,

    [int]    $SmallWidth  = 320,
    [int]    $SmallHeight = 240,

    [int]    $SampleSeconds  = 90,
    [int]    $TickGapSeconds = 190,

    [Parameter(Mandatory)][string] $BackupDir,
    [Parameter(Mandatory)][string] $ExpectedSystemCfgMd5,

    [string] $OutDir = (Join-Path $PSScriptRoot 'runs'),

    # Exploratory second measurement: after the first cost sample, switch these
    # render features off at runtime and re-measure the SAME loaded world.
    # Added because shrinking r_Width/r_Height turned out to save almost
    # nothing (7.8 -> 7.62 cores for a 21x pixel reduction) -- back-buffer size
    # is not where a software rasteriser's time goes. Shadow maps, GI voxels,
    # vegetation and particles all have their own budgets independent of it.
    [string[]] $RenderOffCvars = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Wo73-Lib.ps1')

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
$report = Join-Path $OutDir "$Config-$stamp.txt"
function Say { param([string]$m)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m
    Write-Host $line; Add-Content -Path $report -Value $line -Encoding utf8 }

Say "=== WO-73 run: config=$Config playline=$Playline save=$SaveName"

# --------------------------------------------------------------- early cvars
# Only cvars the renderer reads during init have to be early, and the ONLY way
# to land those is the probe: '+name value' on the command line is applied late
# in CSystem::Init, after renderer init has already read them (WO-72 §1).
# Keeping the list minimal keeps the probe out of the GPU control column.
$cvars = @()
switch ($Config) {
    'warp'       { $cvars += @("r_HeadlessStartup=1", "r_overrideDXGIAdapter=$WarpAdapterIndex") }
    'warp-small' { $cvars += @("r_HeadlessStartup=1", "r_overrideDXGIAdapter=$WarpAdapterIndex",
                               "r_Width=$SmallWidth", "r_Height=$SmallHeight") }
}
$early = $cvars -join ','
Say "early cvars: $(if ($early) { $early } else { '(none -- no probe injected)' })"

# ------------------------------------------------------------------- launch
$inst = Start-KcdInstance -EarlyCvars $early
Say "pid $($inst.Pid), probe injected=$($inst.Injected) after $($inst.InjectSec)s"

$bootSec = Wait-KcdApi -TimeoutSec 1800 -Since $inst.StartedAt
if (-not $bootSec) { Say 'FAIL: debug API never answered'; Stop-KcdHard | Out-Null; return }
$p = Get-Process -Name KingdomCome
$bootCpu = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1)
Say "BOOT: api up after ${bootSec}s wall, $bootCpu CPU-s, $([math]::Round($p.WorkingSet64/1GB,2)) GB, $($p.Threads.Count) threads"

# wh_ui_PauseGameOnFocusLoss defaults true. Set for every config so the rows are
# comparable. NOTE: it was NOT what froze the clock in testing -- the world-time
# pause survived both this cvar and window focus -- but leaving it default would
# reintroduce a second variable.
Invoke-KcdConsole -Command 'wh_ui_PauseGameOnFocusLoss 0' | Out-Null

$cal0 = Read-KcdCalendar -Tag 'menu'
Say "menu: $($cal0.Raw)"

# --------------------------------------------------------------------- load
Say "issuing: wh_sys_LoadGame $Playline $SaveName"
$t0 = Get-Date
Invoke-KcdConsole -Command "wh_sys_LoadGame $Playline $SaveName" | Out-Null

$loadSec = $null
while (((Get-Date) - $t0).TotalSeconds -lt 1800) {
    Start-Sleep -Seconds 10
    if (-not (Get-Process -Name KingdomCome -ErrorAction SilentlyContinue)) { Say 'PROCESS DIED during load'; return }
    $c = Read-KcdCalendar -Tag 'load'
    # A non-zero worldTime alone is NOT the loaded world: mid-load the instance
    # reports worldTime=118800 with ratio=0 and gameTime=0, and an earlier
    # version of this check accepted that transient and reported a load time
    # 2x too fast. The world is up only when the clock is actually configured
    # AND the sim counter has started.
    if ($c -and $c.worldTime -and $c.worldTime -ne '0' -and
        $c.ratio -and $c.ratio -ne '0' -and $c.gameTime -and $c.gameTime -ne '0') {
        $loadSec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); break
    }
}
if (-not $loadSec) { Say 'FAIL: load produced no world clock within 1800s'; Stop-KcdHard | Out-Null; return }
$p.Refresh()
$loadCpu = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1)
Say "LOAD: world up after ${loadSec}s wall; cumulative $loadCpu CPU-s ($([math]::Round($loadCpu - $bootCpu,1)) CPU-s for the load itself)"

# ------------------------------------------------------------ save protection
$lock = Set-KcdSaveLock
Say "save lock applied=$($lock.Applied)"

# ------------------------------------------------------- sanity anchors
$souls = Get-KcdScalar -Path '/api/rpg/SoulList/SoulCount'
Invoke-KcdLua -Lua 'System.LogAlways("[WO73][SAN] entities=" .. tostring(#System.GetEntities()))' | Out-Null
Start-Sleep -Seconds 1
Say "sanity: souls=$souls  $(Get-KcdLogTail -Pattern '\[WO73\]\[SAN\]' -Last 1)"

# ---------------------------------------------------------------- tick proof
$a = Read-KcdCalendar -Tag 'tickA'
Say "TICK-A: $($a.Raw)"

$cost = Measure-KcdCost -Seconds $SampleSeconds -Label "$Config-loaded-idle"
Say ("COST: {0} cores, {1} GB WS (peak {2}), {3} threads  [{4} CPU-s / {5} s wall]" -f `
     $cost.Cores, $cost.WorkingSetGB, $cost.PeakWsGB, $cost.Threads, $cost.CpuSec, $cost.WallSec)

$remaining = $TickGapSeconds - $SampleSeconds
if ($remaining -gt 0) { Start-Sleep -Seconds $remaining }
$b = Read-KcdCalendar -Tag 'tickB'
Say "TICK-B: $($b.Raw)"

# Guard the arithmetic: a missing reading is "no data", never "DEAD". An
# earlier version subtracted $null and reported a live instance as dead.
if (-not $a -or -not $b) {
    Say 'TICK VERDICT: NO DATA -- one of the two calendar reads did not return. Not a verdict.'
} else {
    $gapSec = [math]::Round(($b.At - $a.At).TotalSeconds, 1)
    $dWorld = [double]$b.worldTime - [double]$a.worldTime
    $dGame  = [double]$b.gameTime  - [double]$a.gameTime
    Say ("TICK VERDICT: worldTime +{0} over {1} real-s; gameTime +{2} ({3}x real time); paused={4} -> {5}" -f `
         $dWorld, $gapSec, $dGame, [math]::Round($dGame / [math]::Max($gapSec,1), 3), $b.paused,
         $(if ($dWorld -gt 0) { 'WORLD CLOCK ADVANCING' }
           elseif ($dGame -gt 0) { 'SIM LIVE BUT WORLD CLOCK PAUSED' }
           else { 'NOT ADVANCING' }))
}

# ------------------------------------- exploratory: render features off
if ($RenderOffCvars.Count) {
    Say "applying render-off cvars: $($RenderOffCvars -join ' ')"
    foreach ($c in $RenderOffCvars) { Invoke-KcdConsole -Command $c | Out-Null }
    Start-Sleep -Seconds 20
    $x = Read-KcdCalendar -Tag 'tickC'
    Say "TICK-C (features off): $($x.Raw)"
    $cost2 = Measure-KcdCost -Seconds $SampleSeconds -Label "$Config-featuresoff"
    Say ("COST (features off): {0} cores, {1} GB WS, {2} threads  [{3} CPU-s / {4} s wall]" -f `
         $cost2.Cores, $cost2.WorkingSetGB, $cost2.Threads, $cost2.CpuSec, $cost2.WallSec)
    $y = Read-KcdCalendar -Tag 'tickD'
    Say "TICK-D (features off): $($y.Raw)"
    $gap2 = [math]::Round(($y.At - $x.At).TotalSeconds, 1)
    $dg2  = [double]$y.gameTime - [double]$x.gameTime
    Say ("RATE (features off): gameTime +{0} over {1} real-s = {2}x real time" -f `
         $dg2, $gap2, [math]::Round($dg2 / [math]::Max($gap2,1), 3))
}

# ------------------------------------------------------------------ teardown
Say 'HARD KILL (DUMPTODISK discipline)'
Stop-KcdHard | Out-Null
$ic = Assert-InstallClean -ExpectedSystemCfgMd5 $ExpectedSystemCfgMd5
Say "install clean=$($ic.Clean) (system.cfg match=$($ic.SystemCfgMatch), user.cfg present=$($ic.UserCfgPresent))"
$sv = Assert-SavesUntouched -BackupDir $BackupDir
Say "saves untouched=$($sv.Clean)"
if (-not $sv.Clean) { $sv.Changed | ForEach-Object { Say "  CHANGED: $_" } }

Say "report: $report"
