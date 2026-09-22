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

# --- 1b. WO-110 R2: no template may QUOTE the placeholder --------------------
# The engine substitutes %line with the typed argument ALREADY QUOTED (WO-106
# s1.1 observed `PROBE line=["hello world"]`), so 'f("%line")' expands to
# f(""x"") -- a Lua syntax error on every argument, for every argument-taking
# command, from 0.26.3 until WO-110 (docs/WO-109-audit.md R2, confirmed live
# 2026-09-22). The correct template is 'f(%line)': with an argument it runs
# f("x"), bare it runs f() with arg nil. The original WO-106 check above only
# looked at the case of the placeholder, so this shipped for two releases.
$badQuote = $ccLines | Where-Object { $_ -match '["'']%line["'']' -or $_ -match '["'']%1["'']' -or $_ -match '["'']%2["'']' }
Check ($badQuote.Count -eq 0) "no AddCCommand template wraps %line/%1/%2 in quotes (the engine inserts the argument already quoted)"
if ($badQuote.Count -gt 0) {
    $badQuote | ForEach-Object { Write-Host "    offending: $($_.Trim())" -ForegroundColor Yellow }
}

# --- 1c. WO-110 R2: a placeholder must be the ONLY thing between its parens --
# 'f(%line, "x")' is a syntax error when typed bare (f(, "x")); a fixed second
# argument has to be a default inside the handler instead.
$badExtra = $ccLines | Where-Object { $_ -match '%line\s*,' -or $_ -match ',\s*%line' }
Check ($badExtra.Count -eq 0) "no AddCCommand template combines %line with another argument (bare invocation would be a syntax error)"
if ($badExtra.Count -gt 0) {
    $badExtra | ForEach-Object { Write-Host "    offending: $($_.Trim())" -ForegroundColor Yellow }
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
