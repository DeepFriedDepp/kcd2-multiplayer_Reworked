<#
.SYNOPSIS
    WO-110 Phase 0.2 static check: kdcmp.lua's main chunk must stay well under
    Lua 5.1's 200-local-per-function cap (LUAI_MAXVARS).

.DESCRIPTION
    Static/lexical -- greps kdcmp.lua directly, no game, relay or agent.

    The whole mod is ONE main chunk. Stock Lua 5.1 refuses to compile a
    function with more than 200 active locals ("too many local variables"),
    and the in-game interpreter is stock 5.1. MoonSharp -- which every
    Test-*Synthetic.ps1 suite runs the file under -- does NOT enforce that
    cap, so no synthetic suite can ever see the failure: the mod would compile
    green in every gate and then fail to load in the game with nothing but a
    parser error in kcd.log (docs/WO-109-audit.md s5.1).

    WO-109 counted 180 top-level locals; WO-110 folded 60 of them into four
    namespace tables (ANIMS / SCRATCH / ACTS / TUNE) to reach 124. This check
    fails above 170 -- headroom of 30 below the cliff, so a WO can add a
    handful of locals without tripping it while a drift back toward the cap
    is caught before a pak is built. Prefer adding fields to an existing
    namespace table over new top-level locals.

    Counted exactly as WO-109 did: every column-0 `local <name>` /
    `local a, b = ...` / `local function <name>` declaration in the file.
    Locals inside functions and do-blocks are not main-chunk locals and are
    not counted.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO110LuaLocals.ps1
#>
[CmdletBinding()]
param(
    [string] $LuaPath,
    [int] $MaxLocals = 170
)

if (-not $LuaPath) {
    $root = $PSScriptRoot
    if (-not $root) { $root = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $LuaPath = Join-Path $root '..\kdcmp\Data\Scripts\Startup\kdcmp.lua'
}

$ErrorActionPreference = 'Stop'

$script:pass = 0
$script:fail = 0
function Ok([string] $m)  { $script:pass++; Write-Host "  PASS  $m" -ForegroundColor Green }
function Bad([string] $m) { $script:fail++; Write-Host "  FAIL  $m" -ForegroundColor Red }
function Check([bool] $cond, [string] $m) { if ($cond) { Ok $m } else { Bad $m } }

if (-not (Test-Path $LuaPath)) { throw "kdcmp.lua not found at $LuaPath" }
$lines = Get-Content $LuaPath

Write-Host "`n=== WO-110 Phase 0.2: main-chunk local count, $LuaPath ===`n"

$count = 0
$names = New-Object System.Collections.Generic.List[string]
foreach ($l in $lines) {
    if ($l -match '^local\s+function\s+([A-Za-z_]\w*)') {
        $count++; $names.Add($Matches[1]); continue
    }
    if ($l -match '^local\s+([^=]+?)\s*(=|$)') {
        foreach ($n in ($Matches[1] -split ',')) {
            $n = $n.Trim()
            if ($n -match '^[A-Za-z_]\w*$') { $count++; $names.Add($n) }
        }
    }
}

Check ($count -gt 50) "counted $count main-chunk locals (sanity: the file is the real mod, not a stub)"
Check ($count -le $MaxLocals) "main-chunk local count $count <= $MaxLocals (Lua 5.1 LUAI_MAXVARS is 200; MoonSharp does not enforce it)"
if ($count -gt $MaxLocals) {
    Write-Host "    Fold new top-level locals into an existing namespace table (ANIMS / SCRATCH / ACTS / TUNE) or KCD2MP." -ForegroundColor Yellow
}

# The four WO-110 namespace tables must exist -- a well-meaning cleanup that
# unfolds them would put the count straight back on the cliff's edge.
foreach ($ns in @('ANIMS', 'SCRATCH', 'ACTS', 'TUNE')) {
    Check (($lines | Where-Object { $_ -match "^local $ns = \{\}" }).Count -eq 1) "namespace table 'local $ns = {}' is declared exactly once"
}

Write-Host "`n--------------------------------------------"
Write-Host "  passed: $script:pass   failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
