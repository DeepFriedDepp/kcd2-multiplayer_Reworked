<#
.SYNOPSIS  Scratch driver: send a Lua chunk over ExecuteString, read tagged log lines back.
.DESCRIPTION
    Consolidates the six near-identical woNN-lua.ps1 drivers (WO-21, 22, 24,
    25, 26, 27 each carried their own copy of this file, differing only in
    the hardcoded [WONN] tag) into one parameterized tool.
.EXAMPLE   . tools\Lua-Driver.ps1 -Tag WO30 ; Lua 'W("hi")' ; Show
#>
param(
    [Parameter(Mandatory = $true)][string] $Tag
)

$ApiBase = 'http://localhost:1403'
$KcdLog  = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log'
$script:Tag  = $Tag
$script:seen = @{}

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    if ($enc.Length -gt 1700) { Write-Host "  WARN chunk $($enc.Length) encoded chars (ceiling ~1716)" -ForegroundColor Yellow }
    try { Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null }
    catch { Write-Host "  (console call failed: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

function Show([int] $waitMs = 1200) {
    Start-Sleep -Milliseconds $waitMs
    $prefix = "[$script:Tag]"
    foreach ($line in (Get-Content $KcdLog)) {
        if ($line -notmatch [regex]::Escape($prefix)) { continue }
        $clean = ($line -replace ".*$([regex]::Escape($prefix)) ", '')
        if ($script:seen.ContainsKey($clean)) { continue }
        $script:seen[$clean] = $true
        "  $clean"
    }
}

# Mark everything already in the log as seen, so Show() only prints new lines.
function Reset-Seen {
    $prefix = "[$script:Tag]"
    foreach ($line in (Get-Content $KcdLog)) {
        if ($line -match [regex]::Escape($prefix)) { $script:seen[($line -replace ".*$([regex]::Escape($prefix)) ", '')] = $true }
    }
}

function Api([string] $path) {
    try { return (Invoke-WebRequest -Uri ($ApiBase + $path) -UseBasicParsing -TimeoutSec 15).Content } catch { return 'ERR' }
}

function Init-W {
    Lua "function W(s) System.LogAlways(""[$script:Tag] "" .. tostring(s)) end"
}
