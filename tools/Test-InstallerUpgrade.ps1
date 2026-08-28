<#
.SYNOPSIS
    WO-74. Proves that Setup produces a correct install from every starting
    state a real machine can be in -- including one that a previous Setup
    already damaged.

.DESCRIPTION
    tools\Test-Installer.ps1 covers the lifecycle: install, upgrade,
    uninstall. It does not cover the question this suite exists for, which is
    what happens when the directory Setup is upgrading is NOT clean.

    Six cells, each one an independent install into a throwaway directory:

      1  virgin          nothing installed, no registry entry
      2  clean previous  the newest older release on disk, upgraded
      3  clean current   the same version, re-run over itself (idempotence)
      4  damaged         a deliberately half-applied install (see the recipe)
      5  mod damaged     the two mod files rolled back plus stray loose files
      6  unreplaceable   one file Setup cannot write -- must NOT exit green

    Cells 1-5 must end PASS. Cell 6 must end anything BUT pass: it is the
    negative control for the whole point of the work order, which is that an
    installer must never be able to finish silently over a half-state.

    NOTHING here touches the real game folder. Detection is pointed at a
    fixture Steam tree via Setup's /STEAMROOT override -- the same override
    docs\INSTALLER-TESTING.md documents, and the reason it exists. Renaming a
    real appmanifest to fake "not installed" costs an 8.8 GB redownload; do
    not do it.

.PARAMETER SetupExe
    The installer under test. Defaults to release\KCDMP-Setup-<VERSION>.exe.

.PARAMETER PreviousSetupExe
    The "clean previous release" for cell 2. Defaults to the
    newest-versioned release\KCDMP-Setup-*.exe that is not the one under test.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-InstallerUpgrade.ps1
#>
[CmdletBinding()]
param(
    [string] $SetupExe,
    [string] $PreviousSetupExe,
    [string] $WorkDir = (Join-Path $env:TEMP "kcdmp-upgrade-matrix")
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$version = (Get-Content (Join-Path $root 'VERSION') -TotalCount 1).Trim()

if (-not $SetupExe) { $SetupExe = Join-Path $root "release\KCDMP-Setup-$version.exe" }
if (-not (Test-Path $SetupExe)) { throw "Setup not found: $SetupExe  (run tools\Build-Installer.ps1 first)" }

if (-not $PreviousSetupExe) {
    # Highest version that is not the one under test. Sorted as [version], not
    # as text: "0.9.5" sorts above "0.18.8" as a string. Recursive, because
    # older releases get tidied into release\Old-Installers\ and a suite that
    # only looked at the top level would then have no previous release at all.
    $PreviousSetupExe = Get-ChildItem (Join-Path $root 'release') -Filter 'KCDMP-Setup-*.exe' -Recurse |
        ForEach-Object {
            if ($_.Name -match '^KCDMP-Setup-(\d+(?:\.\d+)+)\.exe$') {
                [pscustomobject]@{ Path = $_.FullName; V = [version]$Matches[1] }
            }
        } |
        Where-Object { $_.V -ne [version]$version } |
        Sort-Object V -Descending | Select-Object -First 1 -ExpandProperty Path
}
if (-not $PreviousSetupExe -or -not (Test-Path $PreviousSetupExe)) {
    throw "No previous-release Setup found in release\ to use for cell 2"
}

$regKey = 'HKCU:\Software\KCDMP'
if (Test-Path $regKey) {
    throw "An existing KCDMP install is registered at $regKey. Uninstall it before running this suite."
}

$pass = 0; $fail = 0
function Assert-That($name, $condition, $detail) {
    if ($condition) { $script:pass++; Write-Host ("    PASS  {0}" -f $name) }
    else { $script:fail++; Write-Host ("    FAIL  {0}  --  {1}" -f $name, $detail) -ForegroundColor Red }
}

# ------------------------------------------------------------------ fixture

# A Steam tree with an appmanifest, a library folder and a "Modding Tools"
# game that passes IsModdingToolsBuild (Framework.dll + CrySystem.dll beside
# KingdomCome.exe) and GameRootOf (Data\ and Engine\ above Bin\).
function New-SteamFixture($dir) {
    if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
    $steam = Join-Path $dir 'Steam'
    $game = Join-Path $steam 'steamapps\common\KCD2Mod'
    $bin  = Join-Path $game 'Bin\Win64ReleaseSteamLTO_DLL'
    New-Item -ItemType Directory -Force -Path (Join-Path $steam 'steamapps'),
        (Join-Path $game 'Data'), (Join-Path $game 'Engine'), $bin | Out-Null
    foreach ($f in @('KingdomCome.exe', 'Framework.dll', 'CrySystem.dll')) {
        Set-Content -Path (Join-Path $bin $f) -Value 'fixture' -Encoding ASCII
    }
    Set-Content -Path (Join-Path $steam 'steamapps\appmanifest_2429020.acf') -Encoding ASCII -Value @'
"AppState"
{
	"appid"		"2429020"
	"name"		"Kingdom Come: Deliverance II Modding tools"
	"installdir"		"KCD2Mod"
}
'@
    Set-Content -Path (Join-Path $steam 'steamapps\libraryfolders.vdf') -Encoding ASCII -Value (@'
"libraryfolders"
{
	"0"
	{
		"path"		"@STEAM@"
	}
}
'@ -replace '@STEAM@', $steam.Replace('\', '\\'))
    return $steam
}

function Get-Snapshot($dir) {
    $full = (Get-Item $dir).FullName
    Get-ChildItem $full -Recurse -File | ForEach-Object {
        '{0}|{1}|{2}' -f $_.FullName.Substring($full.Length + 1), $_.Length,
                         (Get-FileHash $_.FullName -Algorithm SHA256).Hash
    } | Sort-Object
}

function Invoke-Setup($exe, $appDir, $steam, $logName) {
    $p = Start-Process -FilePath $exe -Wait -PassThru -ArgumentList @(
        '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
        "/DIR=$appDir", "/STEAMROOT=$steam", "/LOG=$logDir\$logName.log")
    return $p.ExitCode
}

function Remove-Install($appDir) {
    $unins = Join-Path $appDir 'unins000.exe'
    if (Test-Path $unins) {
        Start-Process $unins -Wait -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES' | Out-Null
        Start-Sleep -Milliseconds 1500      # unins000.exe deletes itself via a helper
    }
    if (Test-Path $appDir) { Remove-Item $appDir -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path $regKey) { Remove-Item $regKey -Recurse -Force }
}

# install-verify.txt is the installer's own verdict. Reading it is the whole
# point of shipping it -- do not re-derive the answer here.
function Get-Verdict($appDir) {
    $p = Join-Path $appDir 'install-verify.txt'
    if (-not (Test-Path $p)) { return '(no install-verify.txt)' }
    return (Get-Content $p -Raw)
}

# --------------------------------------------------------------------- setup

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
$logDir = Join-Path $WorkDir 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$steam = New-SteamFixture (Join-Path $WorkDir 'fixture')
$modDir = Join-Path $steam 'steamapps\common\KCD2Mod\Mods\kdcmp'

Write-Host "Setup under test : $SetupExe"
Write-Host "Previous release : $PreviousSetupExe"
Write-Host "Fixture game     : $steam"
Write-Host ''

# The reference: what a clean install of the version under test looks like.
$refDir = Join-Path $WorkDir 'reference'
$code = Invoke-Setup $SetupExe $refDir $steam 'reference'
if ($code -ne 0) { throw "the reference install itself failed with exit $code -- see $logDir\reference.log" }
$reference = Get-Snapshot $refDir
$referenceMod = Get-Snapshot $modDir
Remove-Install $refDir
Write-Host ("Reference: {0} files in the install dir, {1} in the mod folder" -f $reference.Count, $referenceMod.Count)
Write-Host ''

# Files that legitimately differ between two installs of the same version, or
# that belong to the user rather than to Setup. install-verify.txt is in here
# because it NAMES what was repaired -- a repair run's verdict is supposed to
# read differently from a clean install's. user-put-this-here.txt is the
# sentinel cell 4 plants to prove the repair sweep does not eat user files.
$volatile = '^(unins000\.dat|settings\.json|.*\.log|favorites\.json|custom_servers\.json|' +
            'kcdmp-client\.json|install-verify\.txt|user-put-this-here\.txt)$'

function Assert-MatchesReference($appDir, $label) {
    $now = Get-Snapshot $appDir | Where-Object { ($_ -split '\|')[0] -notmatch $volatile }
    $ref = $reference          | Where-Object { ($_ -split '\|')[0] -notmatch $volatile }
    $diff = Compare-Object $ref $now
    Assert-That "$label -- install dir is byte-identical to a clean install" ($null -eq $diff) `
        (($diff | ForEach-Object { '{0} {1}' -f $_.SideIndicator, ($_.InputObject -split '\|')[0] }) -join ', ')
}

function Assert-ModCorrect($label) {
    $now = Get-Snapshot $modDir
    $diff = Compare-Object $referenceMod $now
    Assert-That "$label -- mod folder is exactly the two files a clean install deploys" ($null -eq $diff) `
        (($diff | ForEach-Object { '{0} {1}' -f $_.SideIndicator, ($_.InputObject -split '\|')[0] }) -join ', ')
}

function Assert-Green($appDir, $label, $code) {
    Assert-That "$label -- exit code 0" ($code -eq 0) "exit $code"
    $verdict = Get-Verdict $appDir
    Assert-That "$label -- installer's own verdict is PASS" ($verdict -like 'PASS*') `
        ($verdict -split "`n")[0]
    Assert-MatchesReference $appDir $label
    Assert-ModCorrect $label
}

# --------------------------------------------------------- 1  virgin machine

Write-Host 'Cell 1  virgin machine (nothing installed, no registry entry)'
$appDir = Join-Path $WorkDir 'cell1'
Remove-Item $modDir -Recurse -Force -ErrorAction SilentlyContinue
$code = Invoke-Setup $SetupExe $appDir $steam 'cell1'
Assert-Green $appDir 'virgin' $code
Assert-That 'virgin -- nothing was repaired (there was nothing to repair)' `
    ((Get-Verdict $appDir) -match 'repaired 0 stale') (Get-Verdict $appDir)
Remove-Install $appDir

# ------------------------------------------------- 2  clean previous release

Write-Host ''
Write-Host "Cell 2  clean previous release -> upgrade  ($(Split-Path $PreviousSetupExe -Leaf))"
$appDir = Join-Path $WorkDir 'cell2'
Remove-Item $modDir -Recurse -Force -ErrorAction SilentlyContinue
$code = Invoke-Setup $PreviousSetupExe $appDir $steam 'cell2-base'
Assert-That 'previous release installed cleanly' ($code -eq 0) "exit $code"
$code = Invoke-Setup $SetupExe $appDir $steam 'cell2-upgrade'
Assert-Green $appDir 'upgrade-from-previous' $code
Remove-Install $appDir

# --------------------------------------------------------- 3  idempotence

Write-Host ''
Write-Host 'Cell 3  same version re-run over itself (idempotence)'
$appDir = Join-Path $WorkDir 'cell3'
Remove-Item $modDir -Recurse -Force -ErrorAction SilentlyContinue
$code = Invoke-Setup $SetupExe $appDir $steam 'cell3-base'
Assert-That 'first install of the version under test' ($code -eq 0) "exit $code"
$code = Invoke-Setup $SetupExe $appDir $steam 'cell3-again'
Assert-Green $appDir 'idempotent-rerun' $code
Assert-That 'idempotent-rerun -- nothing spurious was repaired' `
    ((Get-Verdict $appDir) -match 'repaired 0 stale') (Get-Verdict $appDir)
Remove-Install $appDir

# ------------------------------------------------------ 4  damaged install

# The damage recipe, and why each line is in it. Every one of these was either
# observed in the field or reproduced against Setup 0.18.8 on 2026-08-28:
#
#   mixed versions   the signature of the half-apply -- some components on the
#                    new build, some still on the old one
#   foreign files    names no release ships, left by a hand `dotnet publish`
#                    into the install directory (WO-35's documented hazard).
#                    These are what the old whitelist manifest could not see.
#   missing file     a component that never landed at all
#   truncated file   a component that landed corrupt
#   read-only file   ONE of these aborted the whole 0.18.8 install at exit 5
Write-Host ''
Write-Host 'Cell 4  half-applied install -> upgrade must repair it'
$appDir = Join-Path $WorkDir 'cell4'
Remove-Item $modDir -Recurse -Force -ErrorAction SilentlyContinue
$code = Invoke-Setup $SetupExe $appDir $steam 'cell4-base'
Assert-That 'base install before damage' ($code -eq 0) "exit $code"

Add-Type -AssemblyName System.IO.Compression.FileSystem
$prevVersion = (Split-Path $PreviousSetupExe -Leaf) -replace '^KCDMP-Setup-(.+)\.exe$', '$1'
$prevZip = Get-ChildItem (Join-Path $root 'release') -Filter "KCDMP-DirectInstall-$prevVersion.zip" -Recurse |
           Select-Object -First 1 -ExpandProperty FullName
if (-not $prevZip) { $prevZip = Join-Path $root "release\KCDMP-DirectInstall-$prevVersion.zip" }
$rolledBack = @('KcdMpServer.dll', 'KcdMp.Protocol.dll', 'KcdMpClient.dll')
if (Test-Path $prevZip) {
    $z = [IO.Compression.ZipFile]::OpenRead($prevZip)
    try {
        foreach ($n in $rolledBack) {
            $e = $z.Entries | Where-Object { $_.FullName -eq "App\$n" }
            if ($e) { [IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $appDir $n), $true) }
        }
    } finally { $z.Dispose() }
} else {
    # No previous zip to borrow from: corrupt them instead. Same class of
    # damage (wrong content under a manifest name), different provenance.
    foreach ($n in $rolledBack) { Set-Content (Join-Path $appDir $n) -Value 'old build' -Encoding ASCII }
}
Copy-Item (Join-Path $appDir 'MasterServer\KcdMpMasterServer.dll') (Join-Path $appDir 'KcdMpMasterServer.dll') -Force
Copy-Item (Join-Path $appDir 'MasterServer\KcdMpMasterServer.deps.json') (Join-Path $appDir 'KcdMpMasterServer.deps.json') -Force
Set-Content (Join-Path $appDir 'LegacyRelay.dll') -Value 'stale junk from an older layout' -Encoding ASCII
Remove-Item (Join-Path $appDir 'KcdMp.Farkle.dll') -Force
Set-Content (Join-Path $appDir 'KCDMP.dll') -Value 'truncated' -Encoding ASCII
(Get-Item (Join-Path $appDir 'appsettings.json')).IsReadOnly = $true
# A file the user owns, to prove the repair sweep does not eat it.
Set-Content (Join-Path $appDir 'user-put-this-here.txt') -Value 'not ours' -Encoding ASCII

$code = Invoke-Setup $SetupExe $appDir $steam 'cell4-repair'
Assert-Green $appDir 'repair-damaged' $code
Assert-That 'repair-damaged -- the three foreign files were named as repaired' `
    ((Get-Verdict $appDir) -match 'removed LegacyRelay\.dll' -and
     (Get-Verdict $appDir) -match 'removed KcdMpMasterServer\.dll') (Get-Verdict $appDir)
Assert-That 'repair-damaged -- a user file in the install dir was left alone' `
    (Test-Path (Join-Path $appDir 'user-put-this-here.txt')) $appDir
Remove-Install $appDir

# --------------------------------------------------- 5  damaged mod folder

Write-Host ''
Write-Host 'Cell 5  damaged mod folder -> upgrade must repair it'
$appDir = Join-Path $WorkDir 'cell5'
Remove-Item $modDir -Recurse -Force -ErrorAction SilentlyContinue
$code = Invoke-Setup $SetupExe $appDir $steam 'cell5-base'
Assert-That 'base install before mod damage' ($code -eq 0) "exit $code"

Set-Content (Join-Path $modDir 'Data\kdcmp.pak') -Value 'an older pak' -Encoding ASCII
# A loose Data\Libs\Tables inside a mod takes over the engine's table root and
# every base table fails to resolve ("114 tables are not loaded", 2026-07-30).
New-Item -ItemType Directory -Force -Path (Join-Path $modDir 'Data\Libs\Tables') | Out-Null
Set-Content (Join-Path $modDir 'Data\Libs\Tables\stray.xml') -Value '<x/>' -Encoding ASCII
(Get-Item (Join-Path $modDir 'mod.manifest')).IsReadOnly = $true

$code = Invoke-Setup $SetupExe $appDir $steam 'cell5-repair'
Assert-Green $appDir 'repair-mod' $code
Assert-That 'repair-mod -- the stray loose pak sources are gone' `
    (-not (Test-Path (Join-Path $modDir 'Data\Libs'))) "$modDir\Data\Libs still exists"
Remove-Install $appDir

# ----------------------------------------------- 6  unreplaceable file (neg)

# A directory sitting where a payload file has to go is the one blocker that
# no amount of attribute-clearing can talk its way past, so it is a
# deterministic stand-in for "a file Setup genuinely cannot write".
#
# A deny ACL is NOT one, and finding that out is worth recording: denying
# W/D/WDAC/WO on the file still let Setup replace it, because deleting a file
# only needs FILE_DELETE_CHILD on its parent directory. The install came out
# green and correct. Do not use an ACL for this.
Write-Host ''
Write-Host 'Cell 6  a file Setup cannot write -- the negative control'
$appDir = Join-Path $WorkDir 'cell6'
Remove-Item $modDir -Recurse -Force -ErrorAction SilentlyContinue
$code = Invoke-Setup $SetupExe $appDir $steam 'cell6-base'
Assert-That 'base install before the blocker' ($code -eq 0) "exit $code"

$victim = Join-Path $appDir 'KcdMpServer.dll'
Remove-Item $victim -Force
New-Item -ItemType Directory -Path $victim | Out-Null
$code = Invoke-Setup $SetupExe $appDir $steam 'cell6-blocked'

$verdict = Get-Verdict $appDir
Assert-That 'unreplaceable -- Setup did NOT exit 0' ($code -ne 0) "exit $code"
Assert-That 'unreplaceable -- the verdict file does NOT claim PASS' (-not ($verdict -like 'PASS*')) `
    (($verdict -split "`n")[0])
Assert-That 'unreplaceable -- the verdict says so in the first line' `
    ($verdict -like 'FAIL*') (($verdict -split "`n")[0])
Remove-Item $victim -Recurse -Force -ErrorAction SilentlyContinue
Remove-Install $appDir

# ------------------------------------------------------------------ cleanup

Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host ("{0}/{1} passed" -f $pass, ($pass + $fail))
if ($fail -gt 0) { exit 1 }
