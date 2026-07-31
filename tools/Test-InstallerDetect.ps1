<#
.SYNOPSIS
    Tests the installer's Steam/Modding-Tools detection against synthetic
    fixtures and against this machine's real Steam library.

.DESCRIPTION
    Builds a fixture tree of fake Steam libraries (multi-library, missing app,
    malformed vdf, retail-instead-of-modding-tools, ...), compiles
    installer\tests\SteamDetectProbe.iss -- which #includes the installer's
    own installer\SteamDetect.iss, so this exercises the shipping code rather
    than a copy of it -- runs it against each fixture, and asserts the result.

    No game and no Steam interaction required. Safe to run any time: nothing
    outside the temp fixture tree is written.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-InstallerDetect.ps1
#>
param(
    [string]$WorkDir = (Join-Path $env:TEMP "kcdmp-detect-fixtures")
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

$pass = 0
$fail = 0
function Assert-That($name, $condition, $detail) {
    if ($condition) {
        $script:pass++
        Write-Host ("  PASS  {0}" -f $name)
    } else {
        $script:fail++
        Write-Host ("  FAIL  {0}  --  {1}" -f $name, $detail) -ForegroundColor Red
    }
}

function Get-Iscc {
    $onPath = Get-Command ISCC.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    foreach ($candidate in @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )) {
        if (Test-Path $candidate) { return $candidate }
    }
    throw "Inno Setup 6 not found. Install it with: winget install --id JRSoftware.InnoSetup"
}

# --- fixtures ------------------------------------------------------------
#
# Real Steam metadata, only smaller: libraryfolders.vdf and appmanifest are
# both the same flat "key" "value" text format, tab-indented, with path
# separators doubled.

function New-Dir($path) { New-Item -ItemType Directory -Force -Path $path | Out-Null }
function New-EmptyFile($path) {
    New-Dir (Split-Path $path -Parent)
    Set-Content -Path $path -Value "" -Encoding ascii
}

function New-LibraryFoldersVdf($steamRoot, $paths) {
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('"libraryfolders"')
    [void]$sb.AppendLine('{')
    for ($i = 0; $i -lt $paths.Count; $i++) {
        $escaped = $paths[$i] -replace '\\', '\\'
        [void]$sb.AppendLine("`t`"$i`"")
        [void]$sb.AppendLine("`t{")
        [void]$sb.AppendLine("`t`t`"path`"`t`t`"$escaped`"")
        [void]$sb.AppendLine("`t`t`"label`"`t`t`"`"")
        [void]$sb.AppendLine("`t}")
    }
    [void]$sb.AppendLine('}')
    New-Dir "$steamRoot\steamapps"
    Set-Content -Path "$steamRoot\steamapps\libraryfolders.vdf" -Value $sb.ToString() -Encoding ascii
}

function New-AppManifest($library, $installDir) {
    New-Dir "$library\steamapps"
    $text = @"
"AppState"
{
	"appid"		"2429020"
	"name"		"Kingdom Come: Deliverance II Modding tools"
	"installdir"		"$installDir"
}
"@
    Set-Content -Path "$library\steamapps\appmanifest_2429020.acf" -Value $text -Encoding ascii
}

# A Modding Tools layout: the two DLLs the plugin needs beside the exe, and
# the Data/Engine pair that identifies the install root.
function New-ModdingToolsLayout($library, $installDir) {
    $base = "$library\steamapps\common\$installDir"
    New-Dir "$base\Data"
    New-Dir "$base\Engine"
    New-EmptyFile "$base\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe"
    New-EmptyFile "$base\Bin\Win64ReleaseSteamLTO_DLL\Framework.dll"
    New-EmptyFile "$base\Bin\Win64ReleaseSteamLTO_DLL\CrySystem.dll"
    New-EmptyFile "$base\Bin\Win64ReleaseSteamLTO_DLL\WHGame.dll"
    return $base
}

# Retail: same exe name, same WHGame.dll, monolithic -- no Framework/CrySystem.
function New-RetailLayout($library, $installDir) {
    $base = "$library\steamapps\common\$installDir"
    New-Dir "$base\Data"
    New-Dir "$base\Engine"
    New-EmptyFile "$base\Bin\Win64MasterMasterSteamPGO\KingdomCome.exe"
    New-EmptyFile "$base\Bin\Win64MasterMasterSteamPGO\WHGame.dll"
}

Write-Host "Building fixtures in $WorkDir ..."
if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Dir $WorkDir

# multi-library: app lives in the second library, not the Steam root.
New-Dir "$WorkDir\multi\Steam\steamapps"
New-LibraryFoldersVdf "$WorkDir\multi\Steam" @("$WorkDir\multi\Steam", "$WorkDir\multi\Lib2")
New-AppManifest "$WorkDir\multi\Lib2" "KCD2Mod"
$multiBase = New-ModdingToolsLayout "$WorkDir\multi\Lib2" "KCD2Mod"

# app in the Steam root library itself.
New-Dir "$WorkDir\rootlib\Steam\steamapps"
New-LibraryFoldersVdf "$WorkDir\rootlib\Steam" @("$WorkDir\rootlib\Steam")
New-AppManifest "$WorkDir\rootlib\Steam" "KCD2Mod"
New-ModdingToolsLayout "$WorkDir\rootlib\Steam" "KCD2Mod" | Out-Null

# two real libraries, neither holding the app.
New-Dir "$WorkDir\missing\Steam\steamapps"
New-Dir "$WorkDir\missing\Lib2\steamapps"
New-LibraryFoldersVdf "$WorkDir\missing\Steam" @("$WorkDir\missing\Steam", "$WorkDir\missing\Lib2")

# malformed vdf, app present in the root library: parsing must degrade to
# "just the Steam root" instead of failing outright.
New-Dir "$WorkDir\malformed\Steam\steamapps"
Set-Content -Path "$WorkDir\malformed\Steam\steamapps\libraryfolders.vdf" `
    -Value "{{{ this is not a vdf `" `" `"path`" oops" -Encoding ascii
New-AppManifest "$WorkDir\malformed\Steam" "KCD2Mod"
New-ModdingToolsLayout "$WorkDir\malformed\Steam" "KCD2Mod" | Out-Null

# no vdf at all (very old Steam installs).
New-Dir "$WorkDir\novdf\Steam\steamapps"
New-AppManifest "$WorkDir\novdf\Steam" "KCD2Mod"
New-ModdingToolsLayout "$WorkDir\novdf\Steam" "KCD2Mod" | Out-Null

# manifest names an app whose files are gone.
New-Dir "$WorkDir\ghost\Steam\steamapps"
New-LibraryFoldersVdf "$WorkDir\ghost\Steam" @("$WorkDir\ghost\Steam")
New-AppManifest "$WorkDir\ghost\Steam" "KCD2Mod"

# the discriminator's whole point: a manifest pointing at a retail layout.
New-Dir "$WorkDir\retail\Steam\steamapps"
New-LibraryFoldersVdf "$WorkDir\retail\Steam" @("$WorkDir\retail\Steam")
New-AppManifest "$WorkDir\retail\Steam" "KCD2Mod"
New-RetailLayout "$WorkDir\retail\Steam" "KCD2Mod"

# a library on a drive that is not currently connected.
New-Dir "$WorkDir\offline\Steam\steamapps"
New-LibraryFoldersVdf "$WorkDir\offline\Steam" @("$WorkDir\offline\Steam", "Z:\NoSuchSteamLibrary")

# --- probe ---------------------------------------------------------------

$iscc = Get-Iscc
$probeIss = Join-Path $root "installer\tests\SteamDetectProbe.iss"
$probeExe = Join-Path $root "installer\tests\SteamDetectProbe.exe"
$probeLog = Join-Path $WorkDir "probe.log"

Write-Host "Compiling $probeIss ..."
& $iscc /Q $probeIss
if ($LASTEXITCODE -ne 0) { throw "probe compile failed" }

Write-Host "Running probe ..."
Start-Process $probeExe -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/LOG=$probeLog", "/FIXTURES=$WorkDir" -Wait
if (-not (Test-Path $probeLog)) { throw "probe produced no log at $probeLog" }

$results = @{}
foreach ($line in Get-Content $probeLog) {
    if ($line -match 'RESULT\s+(\S+)\s+\|\s*(.*)$') {
        $results[$Matches[1]] = $Matches[2].Trim()
    }
}

function Get-Field($caseName, $field) {
    if (-not $results.ContainsKey($caseName)) { return "<case missing>" }
    foreach ($part in $results[$caseName] -split '\|') {
        $kv = $part.Trim()
        if ($kv -like "$field=*") { return $kv.Substring($field.Length + 1) }
    }
    return "<field missing>"
}

Write-Host ""
Write-Host "Steam detection"

Assert-That "multi-library: both libraries seen" ((Get-Field multi-library libs) -eq "2") (Get-Field multi-library libs)
Assert-That "multi-library: app found in second library" ((Get-Field multi-library found) -eq "1") $results["multi-library"]
Assert-That "multi-library: exe is the fixture's exe" `
    ((Get-Field multi-library exe) -eq "$multiBase\Bin\Win64ReleaseSteamLTO_DLL\KingdomCome.exe") (Get-Field multi-library exe)

Assert-That "app in the root library is found" ((Get-Field app-in-root-library found) -eq "1") $results["app-in-root-library"]
Assert-That "no app anywhere: not found" ((Get-Field missing-app found) -eq "0") $results["missing-app"]
Assert-That "missing-app still enumerated both libraries" ((Get-Field missing-app libs) -eq "2") (Get-Field missing-app libs)

Assert-That "malformed vdf degrades to the Steam root" ((Get-Field malformed-vdf libs) -eq "1") (Get-Field malformed-vdf libs)
Assert-That "malformed vdf still finds a root-library app" ((Get-Field malformed-vdf found) -eq "1") $results["malformed-vdf"]
Assert-That "no vdf at all still finds a root-library app" ((Get-Field no-vdf-at-all found) -eq "1") $results["no-vdf-at-all"]

Assert-That "manifest without files is rejected" ((Get-Field manifest-but-no-files found) -eq "0") $results["manifest-but-no-files"]
Assert-That "retail layout is rejected by the discriminator" ((Get-Field retail-not-modding-tools found) -eq "0") $results["retail-not-modding-tools"]
Assert-That "disconnected library is skipped" ((Get-Field offline-library libs) -eq "1") (Get-Field offline-library libs)
Assert-That "empty Steam path finds nothing" ((Get-Field empty-steam-path found) -eq "0") $results["empty-steam-path"]

Write-Host ""
Write-Host "Parsing"
Assert-That "quoted key token" ((Get-Field quotedtoken a) -eq "path") (Get-Field quotedtoken a)
Assert-That "quoted value token, unescaped" ((Get-Field quotedtoken b) -eq "D:\SteamLibrary") (Get-Field quotedtoken b)
Assert-That "line without quotes yields empty" ((Get-Field quotedtoken missing) -eq "[]") (Get-Field quotedtoken missing)
Assert-That "install root derived from exe path" ((Get-Field gameroot value) -eq $multiBase) (Get-Field gameroot value)

Write-Host ""
Write-Host "This machine"
$realSteam = Get-Field real-steam-path value
$realExe = Get-Field real-machine exe
Assert-That "Steam located from the registry" ($realSteam -ne "" -and (Test-Path $realSteam)) $realSteam
Assert-That "Modding Tools found on this machine" ((Get-Field real-machine found) -eq "1") $results["real-machine"]
Assert-That "detected exe exists" ($realExe -ne "" -and (Test-Path $realExe)) $realExe
if ($realExe -ne "" -and (Test-Path $realExe)) {
    $dir = Split-Path $realExe -Parent
    Assert-That "detected exe passes the discriminator" `
        ((Test-Path "$dir\Framework.dll") -and (Test-Path "$dir\CrySystem.dll")) $dir
}

Write-Host ""
Write-Host ("{0}/{1} passed" -f $pass, ($pass + $fail))
if ($fail -gt 0) { exit 1 }
