<#
.SYNOPSIS
    Install / upgrade / uninstall lifecycle test for KCDMP-Setup-<version>.exe.

.DESCRIPTION
    Runs the real installer unattended into a temp directory and asserts what
    it actually did: files deployed, mod deployed into the detected game,
    settings.json pre-seeded with the detected game path, shortcuts created
    with the right working directory, Add/Remove Programs entry stamped with
    the version -- then that an upgrade preserves settings.json, and that a
    silent uninstall removes everything it owns and nothing it does not.

    NOT a substitute for an interactive run: /VERYSILENT skips every wizard
    page, so the Modding-Tools gate page, the WebView2 download and the
    replace-an-existing-mod prompt are not exercised here. See
    docs/INSTALLER-TESTING.md.

    This one does touch the real game folder: it deploys the mod to whatever
    the installer detects, and restores the previous state afterwards.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-Installer.ps1
#>
param(
    [string]$SetupExe,
    [string]$WorkDir = (Join-Path $env:TEMP "kcdmp-installer-test")
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent

if (-not $SetupExe) {
    $version = (Get-Content (Join-Path $root "VERSION") -TotalCount 1).Trim()
    $SetupExe = Join-Path $root "release\KCDMP-Setup-$version.exe"
}
if (-not (Test-Path $SetupExe)) {
    throw "Setup not found: $SetupExe  (run tools\Build-Installer.ps1 first)"
}

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

function Invoke-Setup($arguments) {
    $p = Start-Process -FilePath $SetupExe -ArgumentList $arguments -Wait -PassThru
    return $p.ExitCode
}

$appDir = Join-Path $WorkDir "app"
$logDir = Join-Path $WorkDir "logs"
$desktopLnk = Join-Path ([Environment]::GetFolderPath("Desktop")) "KCD2 Multiplayer.lnk"
$startMenuDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\KCD2 Multiplayer"
$regKey = "HKCU:\Software\KCDMP"

if (Test-Path $regKey) {
    throw "An existing KCDMP install is registered at $regKey. Uninstall it before running this test."
}

if (Test-Path $WorkDir) { Remove-Item $WorkDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

# WO-32 follow-up: the header always promised "restores the previous state
# afterwards" but the cleanup below simply deleted the mod folder -- so every
# run of this suite silently uninstalled the dev machine's real mod deployment
# (observed for real: the freshly-installed 0.11.8 pak vanished after a 41/41
# pass). Snapshot whatever mod deployment exists before the first install so
# cleanup can put it back instead of just deleting.
$modBackup = $null
$preModsPath = $null
foreach ($lib in @("D:\SteamLibrary\steamapps\common\KCD2Mod", "C:\Program Files (x86)\Steam\steamapps\common\KCD2Mod")) {
    if (Test-Path (Join-Path $lib "Mods\kdcmp")) { $preModsPath = Join-Path $lib "Mods\kdcmp"; break }
}
if ($preModsPath) {
    $modBackup = Join-Path $WorkDir "mod-backup"
    Copy-Item $preModsPath $modBackup -Recurse -Force
    Write-Host "Snapshotted existing mod deployment: $preModsPath"
}

Write-Host "Setup under test: $SetupExe"
Write-Host ""

# ---------------------------------------------------------------- install

Write-Host "Fresh install"
$code = Invoke-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=$appDir", "/LOG=$logDir\install.log")
Assert-That "installer exit code 0" ($code -eq 0) "exit $code -- see $logDir\install.log"

foreach ($f in @("KCDMP_launcher.exe", "KcdMpClient.exe", "KcdMpServer.exe", "KCDMP.dll",
                 "KCDMP_LauncherInjector.exe", "unins000.exe")) {
    Assert-That "deployed $f" (Test-Path (Join-Path $appDir $f)) $appDir
}
# The launcher resolves relative DllPath/AgentPath/RelayPath against its own
# directory, so these have to be siblings, not tucked into a subfolder.
Assert-That "self-contained runtime present" (Test-Path (Join-Path $appDir "hostfxr.dll")) $appDir

$modsPath = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).ModsPath
$gamePath = (Get-ItemProperty $regKey -ErrorAction SilentlyContinue).GamePath
Assert-That "registry records the game path" ($gamePath -and (Test-Path $gamePath)) $gamePath
Assert-That "registry records the mod path" ($modsPath -and (Test-Path $modsPath)) $modsPath

if ($gamePath) {
    $gameDir = Split-Path $gamePath -Parent
    Assert-That "detected game passes the discriminator" `
        ((Test-Path "$gameDir\Framework.dll") -and (Test-Path "$gameDir\CrySystem.dll")) $gameDir
}
if ($modsPath) {
    Assert-That "mod folder is named kdcmp under Mods" ($modsPath -like "*\Mods\kdcmp") $modsPath
    foreach ($rel in @("mod.manifest", "Data\kdcmp.pak")) {
        Assert-That "mod file $rel" (Test-Path (Join-Path $modsPath $rel)) $modsPath
    }

    # The deployment is exactly two files and this is not a style preference.
    # kdcmp\Data\ also holds the pak's sources; deploying those loose as well
    # gives the mod a Data\Libs\Tables directory, which takes over the engine's
    # table root and makes every base table fail to resolve. The game then dies
    # at startup with "114 tables are not loaded" and nothing points at us.
    # Happened for real on 2026-07-30, hence an explicit test.
    $deployed = (Get-ChildItem $modsPath -Recurse -File | ForEach-Object {
        $_.FullName.Substring($modsPath.Length + 1)
    } | Sort-Object) -join ' | '
    Assert-That "mod deployment is exactly mod.manifest + Data\kdcmp.pak" `
        ($deployed -eq 'Data\kdcmp.pak | mod.manifest') $deployed
    foreach ($forbidden in @("Data\Libs", "Data\Scripts")) {
        Assert-That "pak sources NOT deployed loose: $forbidden" `
            (-not (Test-Path (Join-Path $modsPath $forbidden))) "$modsPath\$forbidden exists"
    }
}

$settingsPath = Join-Path $appDir "settings.json"
Assert-That "settings.json seeded" (Test-Path $settingsPath) $appDir
if (Test-Path $settingsPath) {
    $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
    Assert-That "seeded GamePath parses as JSON and matches the detected exe" `
        ($settings.GamePath -eq $gamePath) "$($settings.GamePath) vs $gamePath"
    Assert-That "seeded GamePath exists on disk" ($settings.GamePath -and (Test-Path $settings.GamePath)) $settings.GamePath
}

Assert-That "desktop shortcut created" (Test-Path $desktopLnk) $desktopLnk
Assert-That "start menu folder created" (Test-Path $startMenuDir) $startMenuDir
if (Test-Path $desktopLnk) {
    # settings.json is a bare relative filename in the launcher, so it lands
    # in the process's working directory -- the shortcut has to point there.
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($desktopLnk)
    Assert-That "shortcut targets the launcher" ($lnk.TargetPath -eq (Join-Path $appDir "KCDMP_launcher.exe")) $lnk.TargetPath
    Assert-That "shortcut working directory is the install dir" ($lnk.WorkingDirectory -eq $appDir) $lnk.WorkingDirectory
}

$version = (Get-Content (Join-Path $root "VERSION") -TotalCount 1).Trim()
$arp = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall" |
       ForEach-Object { Get-ItemProperty $_.PSPath } |
       Where-Object { $_.DisplayName -eq "KCD2 Multiplayer" }
Assert-That "registered in Add/Remove Programs" ($null -ne $arp) "no matching DisplayName"
if ($arp) {
    Assert-That "Add/Remove version is $version" ($arp.DisplayVersion -eq $version) $arp.DisplayVersion
    Assert-That "Add/Remove uninstall string points at the install" `
        ($arp.UninstallString -like "*$appDir*") $arp.UninstallString
}

# ---------------------------------------------------------------- upgrade

Write-Host ""
Write-Host "Upgrade over the existing install"

# A setting the user could plausibly have changed. If the upgrade rewrites
# settings.json, this disappears.
$edited = '{"GamePath":' + (ConvertTo-Json $gamePath) + ',"HostPort":9999,"VoiceChatEnabled":false}'
Set-Content -Path $settingsPath -Value $edited -Encoding utf8
$sentinel = Join-Path $appDir "user-put-this-here.txt"
Set-Content -Path $sentinel -Value "not ours" -Encoding utf8

$code = Invoke-Setup @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=$appDir", "/LOG=$logDir\upgrade.log")
Assert-That "upgrade exit code 0" ($code -eq 0) "exit $code -- see $logDir\upgrade.log"

$after = Get-Content $settingsPath -Raw | ConvertFrom-Json
Assert-That "upgrade preserved a customised HostPort" ($after.HostPort -eq 9999) $after.HostPort
Assert-That "upgrade preserved VoiceChatEnabled=false" ($after.VoiceChatEnabled -eq $false) $after.VoiceChatEnabled
Assert-That "upgrade preserved GamePath" ($after.GamePath -eq $gamePath) $after.GamePath
Assert-That "upgrade left unrelated files alone" (Test-Path $sentinel) $sentinel
Assert-That "upgrade re-deployed the launcher" (Test-Path (Join-Path $appDir "KCDMP_launcher.exe")) $appDir
Assert-That "upgrade re-deployed the mod" (Test-Path (Join-Path $modsPath "mod.manifest")) $modsPath

# -------------------------------------------------------------- uninstall

Write-Host ""
Write-Host "Silent uninstall"
$unins = Join-Path $appDir "unins000.exe"
$p = Start-Process $unins -ArgumentList "/VERYSILENT", "/SUPPRESSMSGBOXES", "/LOG=$logDir\uninstall.log" -Wait -PassThru
Assert-That "uninstaller exit code 0" ($p.ExitCode -eq 0) "exit $($p.ExitCode)"

Start-Sleep -Milliseconds 1500   # unins000.exe deletes itself via a helper
Assert-That "install directory removed" (-not (Test-Path $appDir)) $appDir
Assert-That "desktop shortcut removed" (-not (Test-Path $desktopLnk)) $desktopLnk
Assert-That "start menu folder removed" (-not (Test-Path $startMenuDir)) $startMenuDir
Assert-That "HKCU\Software\KCDMP removed" (-not (Test-Path $regKey)) $regKey

$arpAfter = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall" |
            ForEach-Object { Get-ItemProperty $_.PSPath } |
            Where-Object { $_.DisplayName -eq "KCD2 Multiplayer" }
Assert-That "Add/Remove entry removed" ($null -eq $arpAfter) "still listed"

# The mod sits inside someone else's game folder and is flagged
# uninsneveruninstall precisely so it is only removed by answering the
# uninstaller's question -- which /VERYSILENT never asks.
Assert-That "unattended uninstall left the mod in place" (Test-Path (Join-Path $modsPath "mod.manifest")) $modsPath

# ---------------------------------------------------------------- cleanup

if ($modsPath -and (Test-Path $modsPath)) {
    Remove-Item $modsPath -Recurse -Force
    Write-Host ""
    Write-Host "Cleaned up test mod deployment at $modsPath"
}
if ($modBackup -and (Test-Path $modBackup) -and $preModsPath) {
    Copy-Item $modBackup $preModsPath -Recurse -Force
    Write-Host "Restored the pre-test mod deployment at $preModsPath"
}

Write-Host ""
Write-Host ("{0}/{1} passed" -f $pass, ($pass + $fail))
if ($fail -gt 0) { exit 1 }
