<#
.SYNOPSIS  WO-25 scratch driver: send a Lua chunk over ExecuteString, read [WO25] lines back.
.EXAMPLE   . tools\wo25-lua.ps1 ; Reset-Seen ; Lua 'W("hi")' ; Show
#>
$ApiBase = 'http://localhost:1403'
$KcdLog  = 'D:\SteamLibrary\steamapps\common\KCD2Mod\kcd.log'
$script:seen = @{}

function Lua([string] $code) {
    $enc = [uri]::EscapeDataString('#' + $code)
    if ($enc.Length -gt 1700) { Write-Host "  WARN chunk $($enc.Length) encoded chars (ceiling ~1716)" -ForegroundColor Yellow }
    try { Invoke-WebRequest -Uri "$ApiBase/api/System/Console/ExecuteString?command=$enc" -UseBasicParsing -TimeoutSec 15 | Out-Null }
    catch { Write-Host "  (console call failed: $($_.Exception.Message))" -ForegroundColor DarkYellow }
}

function Show([int] $waitMs = 1200) {
    Start-Sleep -Milliseconds $waitMs
    foreach ($line in (Get-Content $KcdLog)) {
        if ($line -notmatch '\[WO25\]') { continue }
        $clean = ($line -replace '.*\[WO25\] ', '')
        if ($script:seen.ContainsKey($clean)) { continue }
        $script:seen[$clean] = $true
        "  $clean"
    }
}

function Reset-Seen {
    foreach ($line in (Get-Content $KcdLog)) {
        if ($line -match '\[WO25\]') { $script:seen[($line -replace '.*\[WO25\] ', '')] = $true }
    }
}

function Api([string] $path) {
    try { return (Invoke-WebRequest -Uri ($ApiBase + $path) -UseBasicParsing -TimeoutSec 15).Content } catch { return 'ERR' }
}

function Init-W {
    Lua 'function W(s) System.LogAlways("[WO25] " .. tostring(s)) end'
}
