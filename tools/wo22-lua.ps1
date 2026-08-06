<#
.SYNOPSIS  WO-22 scratch driver: send a Lua chunk over ExecuteString, read [WO22] lines back.
.EXAMPLE   . tools\wo22-lua.ps1 ; Reset-Seen ; Lua 'W("hi")' ; Show
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
        if ($line -notmatch '\[WO22\]') { continue }
        $clean = ($line -replace '.*\[WO22\] ', '')
        if ($script:seen.ContainsKey($clean)) { continue }
        $script:seen[$clean] = $true
        "  $clean"
    }
}

# Mark everything already in the log as seen, so Show() only prints new lines.
function Reset-Seen {
    foreach ($line in (Get-Content $KcdLog)) {
        if ($line -match '\[WO22\]') { $script:seen[($line -replace '.*\[WO22\] ', '')] = $true }
    }
}
