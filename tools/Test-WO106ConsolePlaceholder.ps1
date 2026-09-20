<#
.SYNOPSIS
    WO-106 Phase 1 static check: the AddCCommand placeholder case bug (docs/
    WO-105-contradictions.md entry 1) cannot silently return.

.DESCRIPTION
    Static/lexical, not a live probe -- greps kdcmp.lua directly, no game or
    relay involved. Two assertions:

      1. No System.AddCCommand(...) call anywhere in the file contains the
         uppercase placeholder "%LINE". AddCCommand's placeholder lookup is a
         case-sensitive strstr (docs/WO-105-cryengine-reference.md S3.1/17.1
         via contradictions entry 1) -- "%LINE" matches nothing, silently,
         and produces exactly the "Too many arguments" / literal-placeholder
         pair this project spent a whole WO chasing under the wrong theory.
         A grep assertion is legitimate here: the bug WAS a case error, so a
         case assertion catches its return.

      2. Every command registered with a "%line", "%1"/"%2".../"%%" argument
         placeholder names a Lua function that is actually defined in the
         file -- i.e. the argument has somewhere to go. Catches a command
         wired to a typo'd or removed handler name.

    Run after any edit to the "Register Console Commands" block.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO106ConsolePlaceholder.ps1
#>
[CmdletBinding()]
param(
    [string] $LuaPath
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

Write-Host "`n=== WO-106 Phase 1: console placeholder case check, $LuaPath ===`n"

# --- 1. no uppercase %LINE inside any AddCCommand call ----------------------
$ccLines = $lines | Where-Object { $_ -match 'System\.AddCCommand\(' }
Check ($ccLines.Count -gt 0) "found $($ccLines.Count) System.AddCCommand(...) registrations to check"

$badCase = $ccLines | Where-Object { $_ -cmatch '%LINE' }
Check ($badCase.Count -eq 0) "no AddCCommand template contains uppercase %LINE"
if ($badCase.Count -gt 0) {
    $badCase | ForEach-Object { Write-Host "    offending: $($_.Trim())" -ForegroundColor Yellow }
}

# --- 2. every %line/%1/%%-taking command names a function that exists -------
$funcNames = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($l in $lines) {
    if ($l -match 'function\s+(\w+)\s*\(') { [void]$funcNames.Add($Matches[1]) }
}
Check ($funcNames.Count -gt 100) "collected $($funcNames.Count) Lua function definitions from the file"

$argTaking = $ccLines | Where-Object { $_ -match '%line|%1|%2|%%' }
Check ($argTaking.Count -gt 0) "found $($argTaking.Count) argument-taking command registrations"

$missingHandler = @()
foreach ($l in $argTaking) {
    if ($l -match "AddCCommand\(\s*""([^""]+)""\s*,\s*'([A-Za-z0-9_]+)\(") {
        $cmd = $Matches[1]; $fn = $Matches[2]
        if (-not $funcNames.Contains($fn)) { $missingHandler += "$cmd -> $fn" }
    }
}
Check ($missingHandler.Count -eq 0) "every argument-taking command's Lua handler is defined in the file"
if ($missingHandler.Count -gt 0) {
    $missingHandler | ForEach-Object { Write-Host "    missing handler: $_" -ForegroundColor Yellow }
}

Write-Host "`n--------------------------------------------"
Write-Host "  passed: $script:pass   failed: $script:fail"
if ($script:fail -gt 0) { exit 1 }
