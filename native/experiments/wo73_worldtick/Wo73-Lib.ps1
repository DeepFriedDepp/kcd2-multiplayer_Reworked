# WO-73 experiment library -- NOT product code. Nothing here is installed or
# shipped; it exists to stand a KCD2 instance up (GPU or WARP), drive it over
# the Modding Tools REST console, and measure what it costs.
#
# Dot-source this:  . native\experiments\wo73_worldtick\Wo73-Lib.ps1
#
# Safety contract this file enforces, and why (see docs/WO-73-findings.md):
#   * r_HeadlessStartup, r_Width and r_Height are DUMPTODISK. A CLEAN shutdown
#     would persist them and force software rendering / a tiny resolution into
#     normal play on this machine. Every run is therefore HARD-KILLED, and
#     Assert-InstallClean re-checks the install afterwards.
#   * A loaded world can write autosaves. Backup-KcdSaves takes a hashed copy
#     of the whole profile before anything loads, and Assert-SavesUntouched
#     compares against it after.

# (no Set-StrictMode: dot-sourcing this would impose it on the caller session)

$script:Wo73 = [ordered]@{
    GameRoot  = 'D:\SteamLibrary\steamapps\common\KCD2Mod'
    Exe       = 'D:\SteamLibrary\steamapps\common\KCD2Mod\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe'
    Profile   = (Join-Path $env:USERPROFILE 'Saved Games\kingdomcome2')
    Injector  = (Join-Path $PSScriptRoot '..\..\build\KCDMP_LauncherInjector\KCDMP_LauncherInjector.exe')
    ProbeDll  = (Join-Path $PSScriptRoot '..\..\build\experiments\wo72_nullrenderer\WO72NullRenderer.dll')
    ApiBase   = 'http://localhost:1403'
}

function Get-Wo73Paths { $script:Wo73 }

# ------------------------------------------------------------------ REST

# The Modding Tools debug console over :1403. A bare command string is executed
# as a CONSOLE command; a '#' prefix makes it Lua. Both go through the same
# endpoint (WO-72 findings, "The debug surface works headless too").
function Invoke-KcdConsole {
    param(
        [Parameter(Mandatory)][string] $Command,
        [int] $TimeoutSec = 120
    )
    $enc = [uri]::EscapeDataString($Command)
    $url = "$($script:Wo73.ApiBase)/api/System/Console/ExecuteString?command=$enc"
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing
        return "OK $($r.StatusCode)"
    } catch {
        return "ERR $($_.Exception.Message)"
    }
}

function Invoke-KcdLua {
    param([Parameter(Mandatory)][string] $Lua, [int] $TimeoutSec = 120)
    Invoke-KcdConsole -Command "#$Lua" -TimeoutSec $TimeoutSec
}

# Read a scalar off the reflection API, stripping the XML wrapper. Returns the
# literal string 'ERR ...' on failure so callers can distinguish "no answer"
# from "answered 0" -- the whole WO turns on that difference.
function Get-KcdScalar {
    param([Parameter(Mandatory)][string] $Path, [int] $TimeoutSec = 60)
    $url = "$($script:Wo73.ApiBase)$Path"
    try {
        $r = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing
        $c = $r.Content
    } catch {
        return "ERR $($_.Exception.Message)"
    }
    if ($c -match '>([^<]*)<') { return $Matches[1] }
    return $c
}

function Test-KcdApiUp {
    $v = Get-KcdScalar -Path '/api/rpg/SoulList/SoulCount' -TimeoutSec 5
    return ($v -notmatch '^ERR')
}

# Poll until the debug API answers. Returns seconds elapsed, or $null on timeout.
function Wait-KcdApi {
    param([int] $TimeoutSec = 600, [datetime] $Since = (Get-Date))
    while (((Get-Date) - $Since).TotalSeconds -lt $TimeoutSec) {
        if (Test-KcdApiUp) { return [math]::Round(((Get-Date) - $Since).TotalSeconds, 1) }
        Start-Sleep -Milliseconds 500
    }
    return $null
}

# ------------------------------------------------------- world clock probe

# Two DIFFERENT clocks, and conflating them is what made WO-72's successor read
# a healthy instance as dead (shipped scriptbind docs, C_ScriptBindCalendar):
#
#   GetGameTime()        whole seconds since level start -- the SIMULATION tick.
#                        Advances 1:1 with real time whenever the sim runs.
#   GetWorldTime()       whole seconds of in-world time. Advances at
#                        GetWorldTimeRatio() (15x here) but ONLY while
#                        IsWorldTimePaused() is false -- and quests pause it,
#                        e.g. throughout a tutorial mission.
#
# So a frozen GetWorldTime with an advancing GetGameTime is a paused world
# CLOCK on a live world, not a failed load. Always read all three.
function Read-KcdCalendar {
    param([string] $Tag = 'cal', [int] $WaitSec = 180)
    $lua = 'System.LogAlways(string.format("[WO73][' + $Tag + '] gameTime=%s worldTime=%s day=%s hour=%s ratio=%s paused=%s",' +
           ' tostring(Calendar.GetGameTime()), tostring(Calendar.GetWorldTime()), tostring(Calendar.GetWorldDay()),' +
           ' tostring(Calendar.GetWorldHourOfDay()), tostring(Calendar.GetWorldTimeRatio()), tostring(Calendar.IsWorldTimePaused())))'
    Invoke-KcdLua -Lua $lua -TimeoutSec $WaitSec | Out-Null
    # Poll for the line rather than assuming it has landed. A struggling WARP
    # instance takes tens of seconds to service one REST call, and a fixed
    # short wait here silently returned $null -- which downstream arithmetic
    # turned into a confident "DEAD" verdict on a perfectly live instance.
    $line = $null
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        $line = Get-KcdLogTail -Pattern "\[WO73\]\[$Tag\] " -Last 1
        if ($line) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $line) { return $null }
    $o = [ordered]@{ Raw = $line; At = (Get-Date) }
    foreach ($k in 'gameTime','worldTime','day','hour','ratio','paused') {
        if ($line -match "$k=(\S+)") { $o[$k] = $Matches[1] } else { $o[$k] = $null }
    }
    [pscustomobject]$o
}

# kcd.log is held open by the game; read it share-mode or the read fails.
#
# Seek to the last $TailBytes rather than reading the file: on a struggling WARP
# instance the log grows by megabytes a minute (2959 `WaitForFence TIMED OUT`
# lines in one run), and a fixed line-count window silently pushed the probe's
# own output out of view -- which read as "the instance stopped answering" when
# it was answering fine.
function Get-KcdLogTail {
    param([string] $Pattern, [int] $Last = 20, [int] $TailBytes = 4MB)
    $path = Join-Path $script:Wo73.GameRoot 'kcd.log'
    if (-not (Test-Path $path)) { return @() }
    $fs = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read,
                          [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -gt $TailBytes) { [void]$fs.Seek(-$TailBytes, [IO.SeekOrigin]::End) }
        $sr   = New-Object IO.StreamReader($fs)
        $tail = $sr.ReadToEnd() -split "`r?`n"
    } finally { $fs.Dispose() }
    if ($Pattern) { $tail = @($tail | Where-Object { $_ -match $Pattern }) }
    if ($tail.Count -gt $Last) { return $tail[($tail.Count - $Last)..($tail.Count - 1)] }
    return $tail
}

# --------------------------------------------------------------- launching

function Start-KcdInstance {
    <#
    .SYNOPSIS Launch KingdomCome.exe, optionally injecting the WO-72 probe so
              early cvars land BEFORE renderer init.
    .DESCRIPTION EarlyCvars is the only mechanism that works: '+name value' on
              the command line is applied late in CSystem::Init, after the
              renderer has already read the value (WO-72 findings §1).
    #>
    param(
        [string]   $EarlyCvars = '',      # "r_HeadlessStartup=1,r_overrideDXGIAdapter=1"
        [string[]] $ExtraArgs  = @('-devmode', '-noCrashHandler')
    )
    $p = $script:Wo73
    if (Get-Process -Name KingdomCome -ErrorAction SilentlyContinue) {
        throw 'A KingdomCome.exe is already running. Hard-kill it first (Stop-KcdHard).'
    }

    # The probe reads its knobs with GetEnvironmentVariableA from INSIDE the
    # game process, which inherits our environment. So they must be set here,
    # before the child starts -- not passed to the injector.
    if ($EarlyCvars) {
        if (-not (Test-Path $p.ProbeDll)) { throw "probe DLL not built: $($p.ProbeDll)" }
        if (-not (Test-Path $p.Injector)) { throw "injector not built: $($p.Injector)" }
        $env:KCDMP_WO72_MODE        = 'warp'
        $env:KCDMP_WO72_EARLY_CVARS = $EarlyCvars
    } else {
        Remove-Item Env:KCDMP_WO72_MODE        -ErrorAction SilentlyContinue
        Remove-Item Env:KCDMP_WO72_EARLY_CVARS -ErrorAction SilentlyContinue
    }

    # The game mirrors its whole log to stdout. Inherited, that floods the
    # caller's transcript and buries the run report, so send it to a file --
    # a file, not a pipe, because nothing here drains a pipe and a full one
    # would block the game.
    $t0  = Get-Date
    $out = Join-Path $PSScriptRoot ('runs\stdout-{0}.log' -f $t0.ToString('yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
    $proc = Start-Process -FilePath $p.Exe -ArgumentList $ExtraArgs `
                          -WorkingDirectory $p.GameRoot `
                          -RedirectStandardOutput $out `
                          -RedirectStandardError "$out.err" -PassThru

    $injected = $false
    if ($EarlyCvars) {
        # Renderer init is ~12 s into CSystem::Init (bp_boot trace), and the
        # probe's cvar thread waits for gEnv->pConsole, so a sub-second
        # injection latency leaves ample slack. Retry: the process needs a
        # moment before CreateRemoteThread will take.
        for ($i = 0; $i -lt 40; $i++) {
            $injOut = & $p.Injector --pid $proc.Id --dll (Resolve-Path $p.ProbeDll).Path 2>&1
            if ($LASTEXITCODE -eq 0) { $injected = $true; break }
            Start-Sleep -Milliseconds 100
        }
        if (-not $injected) { throw "injection failed: $injOut" }
    }

    return [pscustomobject]@{
        Process   = $proc
        Pid       = $proc.Id
        StartedAt = $t0
        Injected  = $injected
        InjectSec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
    }
}

# --------------------------------------------------------------- measuring

function Measure-KcdCost {
    <#
    .SYNOPSIS Sample CPU-seconds and working set of the running instance.
    .DESCRIPTION Reports cores-equivalent as (delta CPU seconds / wall seconds),
              which is the number a VM is sized from. Threads and peak working
              set come along because they are free.
    #>
    param([int] $Seconds = 60, [string] $Label = '')
    $proc = Get-Process -Name KingdomCome -ErrorAction SilentlyContinue
    if (-not $proc) { throw 'no KingdomCome.exe running' }
    $cpu0 = $proc.TotalProcessorTime.TotalSeconds
    $w0   = Get-Date
    Start-Sleep -Seconds $Seconds
    $proc.Refresh()
    $cpu1 = $proc.TotalProcessorTime.TotalSeconds
    $wall = ((Get-Date) - $w0).TotalSeconds
    [pscustomobject]@{
        Label       = $Label
        WallSec     = [math]::Round($wall, 1)
        CpuSec      = [math]::Round($cpu1 - $cpu0, 1)
        Cores       = [math]::Round(($cpu1 - $cpu0) / $wall, 2)
        WorkingSetGB= [math]::Round($proc.WorkingSet64 / 1GB, 2)
        PeakWsGB    = [math]::Round($proc.PeakWorkingSet64 / 1GB, 2)
        Threads     = $proc.Threads.Count
        CpuSecTotal = [math]::Round($cpu1, 1)
    }
}

# ------------------------------------------------------------ safety rails

function Stop-KcdHard {
    <# Hard kill. Never let a run with DUMPTODISK cvars set exit cleanly. #>
    $p = Get-Process -Name KingdomCome -ErrorAction SilentlyContinue
    if ($p) { $p | Stop-Process -Force; Start-Sleep -Seconds 3 }
    return ($null -ne $p)
}

# A save lock taken at the MENU does not survive wh_sys_LoadGame -- observed:
# the lock was added, the load ran, and a checkpoint autosave still landed
# ("Quick-saving to ... immediately ignoring delay"). Take the lock AFTER the
# world is up, and read it back rather than trusting the call.
function Set-KcdSaveLock {
    param([string] $Name = 'WO73', [string] $Description = 'WO-73 headless experiment')
    Invoke-KcdConsole -Command 'wh_sys_DebugSaveLock 1' | Out-Null
    Invoke-KcdLua -Lua "Game.AddSaveLock(`"$Name`", `"$Description`")" | Out-Null
    Start-Sleep -Seconds 1
    $evidence = Get-KcdLogTail -Pattern "script save lock '$Name'|Save locks" -Last 5
    [pscustomobject]@{
        Applied  = [bool](@($evidence | Where-Object { $_ -match "Adding script save lock '$Name'" }).Count)
        Evidence = $evidence
    }
}

function Backup-KcdSaves {
    param([Parameter(Mandatory)][string] $Dest)
    $p = $script:Wo73
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Copy-Item (Join-Path $p.Profile 'saves')    (Join-Path $Dest 'saves')    -Recurse -Force
    Copy-Item (Join-Path $p.Profile 'profiles') (Join-Path $Dest 'profiles') -Recurse -Force
    Get-KcdSaveManifest | Set-Content (Join-Path $Dest 'MANIFEST-before.txt') -Encoding utf8
    return (Get-ChildItem $Dest -Recurse -File).Count
}

function Get-KcdSaveManifest {
    $p = $script:Wo73
    Get-ChildItem (Join-Path $p.Profile 'saves'), (Join-Path $p.Profile 'profiles') -Recurse -File |
        Sort-Object FullName |
        ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm MD5).Hash, $_.FullName }
}

function Assert-SavesUntouched {
    param([Parameter(Mandatory)][string] $BackupDir)
    $before = Get-Content (Join-Path $BackupDir 'MANIFEST-before.txt')
    $after  = Get-KcdSaveManifest
    $diff   = Compare-Object $before $after
    [pscustomobject]@{
        Clean   = (-not $diff)
        Changed = @($diff | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" })
    }
}

function Assert-InstallClean {
    <#
    .SYNOPSIS The DUMPTODISK check. system.cfg must be byte-identical and no
              user.cfg may have appeared.
    #>
    param([string] $ExpectedSystemCfgMd5)
    $p = $script:Wo73
    $sys = Join-Path $p.GameRoot 'system.cfg'
    $usr = Join-Path $p.GameRoot 'user.cfg'
    $md5 = (Get-FileHash $sys -Algorithm MD5).Hash
    [pscustomobject]@{
        SystemCfgMd5   = $md5
        SystemCfgMatch = ($md5 -eq $ExpectedSystemCfgMd5)
        UserCfgPresent = (Test-Path $usr)
        Clean          = (($md5 -eq $ExpectedSystemCfgMd5) -and -not (Test-Path $usr))
    }
}
