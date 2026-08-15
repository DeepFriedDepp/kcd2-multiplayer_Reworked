<#
.SYNOPSIS  WO-34 live probe helper: run a Lua chunk, print the [WO34] lines it logs.
.DESCRIPTION
    Self-contained wrapper around tools\Lua-Driver.ps1 so each probe can be a
    single non-interactive invocation (the PowerShell tool does not keep shell
    state between calls).

    Reads back only lines newer than the mark file, so repeated runs do not
    re-print the whole log.
.EXAMPLE
    powershell -File tools\wo34-probe.ps1 -Code 'W(tostring(KCD2MP.aggroEnabled))'
.EXAMPLE
    powershell -File tools\wo34-probe.ps1 -File probe.lua -WaitMs 3000
#>
[CmdletBinding()]
param(
    [string] $Code,
    [string] $File,
    [int]    $WaitMs = 1500,
    [switch] $NoInit
)

$ErrorActionPreference = 'Stop'
$ApiBase = 'http://localhost:1403'
$KcdLog  = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log'

if ($File) { $Code = Get-Content -Raw $File }
if (-not $Code) { throw 'give -Code or -File' }

function Send-Lua([string] $chunk) {
    # ExecuteString takes one line; the '#' prefix is what makes the console
    # treat it as Lua rather than a CVar (docs/WO-18-findings.md P0).
    $one = ($chunk -split "`r?`n" | ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('--') }) -join ' '
    $enc = [uri]::EscapeDataString('#' + $one)
    if ($enc.Length -gt 1700) {
        Write-Host "  WARN chunk is $($enc.Length) encoded chars (ceiling ~1716)" -ForegroundColor Yellow
    }
    try {
        Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" `
            -UseBasicParsing -TimeoutSec 20 | Out-Null
    } catch {
        Write-Host "  (console call failed: $($_.Exception.Message))" -ForegroundColor DarkYellow
    }
}

# Where the log ended before this probe, so only new [WO34] lines are printed.
$before = (Get-Item $KcdLog).Length

if (-not $NoInit) {
    Send-Lua 'function W(s) System.LogAlways("[WO34] " .. tostring(s)) end'
    Start-Sleep -Milliseconds 250
}

Send-Lua $Code
Start-Sleep -Milliseconds $WaitMs

$fs = [IO.File]::Open($KcdLog, 'Open', 'Read', 'ReadWrite')
$fs.Seek($before, 'Begin') | Out-Null
$sr = New-Object IO.StreamReader($fs)
$tail = $sr.ReadToEnd()
$sr.Close(); $fs.Close()

# 'Invalid anim ref' floods this build's log continuously (hundreds of lines a
# second, from ordinary NPC facial animation) and is unrelated to anything here.
$hits = $tail -split "`r?`n" |
    Where-Object { $_ -match '\[WO34\]|Script Error|\[Warning\] Validator' } |
    Where-Object { $_ -notmatch 'Invalid anim ref|Unable to find config for thread' }
if ($hits) { $hits | ForEach-Object { "  " + ($_ -replace '^.*\[WO34\] ', '') } }
else { "  (no [WO34] output)" }
