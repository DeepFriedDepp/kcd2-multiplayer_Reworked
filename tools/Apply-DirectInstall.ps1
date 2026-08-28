<#
.SYNOPSIS
    Apply a KCDMP DirectInstall zip, and prove it landed. Ships inside the zip
    as Apply.ps1.

.DESCRIPTION
    The DirectInstall zip is the update-only route: "unpack it over the top".
    That instruction is also, word for word, how an install ends up half
    applied -- Explorer merges the folders, skips or fails on whatever is in
    use, and says nothing. Setup.exe grew a process gate and a post-install
    verification in WO-32 and WO-74; this route had neither, which made it the
    remaining way to reach the exact state WO-74 exists to fix.

    So this script does what Setup does, in the same order and against the
    same manifest that ships inside App\:

      1. refuse to run while the launcher, agent, relay, master server or the
         game is running -- those hold the files being replaced;
      2. copy App\ over the install directory and Mod\ over the mod folder,
         clearing read-only first (one read-only file aborted a whole 0.18.8
         install; see installer\KCDMP.iss);
      3. remove any .dll/.exe/.pdb/.deps.json/.runtimeconfig.json in the
         install directory that this release does not ship -- a foreign
         assembly there is enough to stop the relay cold-starting (WO-69);
      4. verify every component by sha256 and write install-verify.txt;
      5. exit NON-ZERO and say which components failed if any did.

    Config, saves and logs are never touched: settings.json, favorites.json,
    custom_servers.json and anything else that is not a managed extension stay
    exactly as they are.

.PARAMETER AppDir
    Install directory. Defaults to the one the registry records, then to
    %LocalAppData%\KCDMP (DefaultDirName in installer\KCDMP.iss).

.PARAMETER ModDir
    The mod folder inside the Modding Tools install. Defaults to the registry's
    record. Required if there is no registry entry to read it from.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File Apply.ps1
#>
[CmdletBinding()]
param(
    [string] $AppDir,
    [string] $ModDir,
    [string] $Source = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$reg = 'HKCU:\Software\KCDMP'
if (-not $AppDir) {
    $AppDir = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).InstallDir
    if (-not $AppDir) { $AppDir = Join-Path $env:LOCALAPPDATA 'KCDMP' }
}
if (-not $ModDir) {
    $ModDir = (Get-ItemProperty $reg -ErrorAction SilentlyContinue).ModsPath
}
if (-not $ModDir) {
    throw "Cannot tell where the mod goes: no HKCU\Software\KCDMP\ModsPath. Run the full Setup.exe once, or pass -ModDir <ModdingTools>\Mods\kdcmp."
}

$appSrc = Join-Path $Source 'App'
$modSrc = Join-Path $Source 'Mod'
foreach ($d in @($appSrc, $modSrc)) {
    if (-not (Test-Path $d)) { throw "This does not look like a DirectInstall zip: $d is missing" }
}
$manifestSrc = Join-Path $appSrc 'install-manifest.txt'
if (-not (Test-Path $manifestSrc)) {
    throw "No install-manifest.txt in App\ -- this zip predates WO-74 and cannot be verified. Use Setup.exe instead."
}

# ------------------------------------------------------- 1  process gate

# Same list as installer\KCDMP.iss's FirstInstallBlocker, and for the same
# reason: these hold open exactly the files about to be replaced. The game is
# on the list because KCDMP.dll is loaded into it.
$blockers = @('KCDMP_launcher', 'KcdMpClient', 'KcdMpServer', 'KcdMpMasterServer', 'KingdomCome')
$running = Get-Process -ErrorAction SilentlyContinue | Where-Object { $blockers -contains $_.ProcessName }
if ($running) {
    Write-Host 'These are running and hold the files this update replaces:' -ForegroundColor Yellow
    $running | ForEach-Object { Write-Host ("  pid {0,-7} {1}" -f $_.Id, $_.ProcessName) }
    throw 'Close the launcher, the agent, the relay, the master server and the game, then run this again. Applying over running programs is how an update half-applies.'
}

Write-Host "Install directory : $AppDir"
Write-Host "Mod folder        : $ModDir"
Write-Host ''

# --------------------------------------------------------------- 2  copy

# Stamped before anything is written, so an apply that dies half way can never
# leave a previous run's PASS behind as the record of what happened.
$verifyPath = Join-Path $AppDir 'install-verify.txt'
New-Item -ItemType Directory -Force -Path $AppDir, $ModDir, (Join-Path $ModDir 'Data') | Out-Null
Set-Content $verifyPath -Encoding ASCII -Value @(
    'FAIL  update in progress -- Apply.ps1 has not finished',
    '  If this line is still here, the update stopped before it could verify anything.')

function Copy-Tree($from, $to) {
    $fromFull = (Get-Item $from).FullName
    foreach ($f in Get-ChildItem $fromFull -Recurse -File) {
        $rel = $f.FullName.Substring($fromFull.Length + 1)
        $dest = Join-Path $to $rel
        $destDir = Split-Path $dest -Parent
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
        if (Test-Path $dest) { (Get-Item $dest).IsReadOnly = $false }
        Copy-Item $f.FullName $dest -Force
    }
}
Write-Host 'Copying App\ ...'
Copy-Tree $appSrc $AppDir
Write-Host 'Copying Mod\ ...'
Copy-Tree $modSrc $ModDir

# --------------------------------------------------------------- 3  sweep

$manifest = @(Get-Content (Join-Path $AppDir 'install-manifest.txt') |
    ForEach-Object { $_.Trim() } |
    Where-Object { $_ -ne '' -and -not $_.StartsWith('#') } |
    ForEach-Object { , ($_ -split '\|') } |
    Where-Object { $_.Count -ge 4 })

$appRel = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($e in $manifest) { if ($e[0] -eq 'APP') { [void]$appRel.Add($e[1]) } }

$appFull = (Get-Item $AppDir).FullName
$removed = @()
foreach ($f in Get-ChildItem $appFull -Recurse -File) {
    if ($f.Name -like 'unins*') { continue }
    $managed = ($f.Extension -in '.dll', '.exe', '.pdb') -or
               ($f.Name -like '*.deps.json') -or ($f.Name -like '*.runtimeconfig.json')
    if (-not $managed) { continue }
    $rel = $f.FullName.Substring($appFull.Length + 1)
    if ($appRel.Contains($rel)) { continue }
    $f.IsReadOnly = $false
    Remove-Item $f.FullName -Force
    $removed += $rel
}
# Loose pak sources inside the mod folder take over the engine's table root and
# make every base table fail to resolve ("114 tables are not loaded").
#
# The empty directories go too, not just the files in them. The engine mounts
# the DIRECTORY -- an emptied Data\Libs\Tables is no safer than a full one, and
# a files-only sweep leaves exactly that behind. installer\KCDMP.iss's
# PruneModFolder deletes stray directories outright for the same reason.
$modFull = (Get-Item $ModDir).FullName
foreach ($stray in Get-ChildItem $modFull -Recurse -File -ErrorAction SilentlyContinue) {
    $rel = $stray.FullName.Substring($modFull.Length + 1)
    if ($rel -ne 'mod.manifest' -and $rel -ne 'Data\kdcmp.pak') {
        $stray.IsReadOnly = $false
        Remove-Item $stray.FullName -Force
        $removed += "mod: $rel"
    }
}
# Deepest first, so a nested tree collapses in one pass. Only 'Data' survives,
# and only because kdcmp.pak lives in it.
foreach ($dir in (Get-ChildItem $modFull -Recurse -Directory -ErrorAction SilentlyContinue |
                  Sort-Object { $_.FullName.Length } -Descending)) {
    $rel = $dir.FullName.Substring($modFull.Length + 1)
    if ($rel -eq 'Data') { continue }
    if ((Get-ChildItem $dir.FullName -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item $dir.FullName -Force
        $removed += "mod: $rel\"
    }
}

# ------------------------------------------------------------- 4  verify

$failures = @()
foreach ($e in $manifest) {
    $base = if ($e[0] -eq 'MOD') { $ModDir } else { $AppDir }
    $full = Join-Path $base $e[1]
    $label = if ($e[0] -eq 'MOD') { "game mod: $($e[1])" } else { $e[1] }
    if (-not (Test-Path $full)) { $failures += "$label  (missing)"; continue }
    $item = Get-Item $full
    if ($item.Length -ne [int64]$e[2]) {
        $failures += ("{0}  ({1} bytes, expected {2})" -f $label, $item.Length, $e[2]); continue
    }
    if ((Get-FileHash $full -Algorithm SHA256).Hash -ne $e[3]) {
        $failures += "$label  (wrong content -- sha256 differs)"
    }
}

$verdict = @()
if ($failures.Count -eq 0) {
    $verdict += "PASS  $($manifest.Count) component(s) verified by sha256 against the install manifest"
} else {
    $verdict += "FAIL  $($failures.Count) component(s) did not install correctly:"
    $verdict += $failures | ForEach-Object { "  $_" }
}
$verdict += "applied by Apply.ps1   repaired $($removed.Count) stale file(s) that no release ships"
$verdict += $removed | ForEach-Object { "  removed $_" }
Set-Content $verifyPath -Value $verdict -Encoding ASCII

$verdict | ForEach-Object { Write-Host $_ -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Red' }) }

if ($failures.Count -gt 0) {
    Write-Host ''
    Write-Host 'THIS UPDATE IS NOT COMPLETE. Close everything KCDMP and run this again.' -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host 'Update applied and verified.' -ForegroundColor Green
