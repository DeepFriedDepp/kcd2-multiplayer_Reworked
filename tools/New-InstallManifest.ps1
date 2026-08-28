<#
.SYNOPSIS
    Write the v2 install manifest that both delivery routes verify against.

.DESCRIPTION
    One generator, called by tools\Build-Installer.ps1 and by
    tools\Build-DirectInstall.ps1, so the two cannot drift apart on format.

    Format -- <kind>|<relative path>|<size>|<sha256>:
      APP  a file in the install directory, relative to it
      MOD  a file in <ModdingTools>\Mods\kdcmp, relative to that folder

    APP is a CLOSED set. The installer and Apply.ps1 both delete any
    .dll/.exe/.pdb/.deps.json/.runtimeconfig.json in the install directory that
    is not listed here, because .NET loads by filename out of that folder and
    one foreign assembly is enough to stop the relay cold-starting (WO-69).

    ALWAYS generate this from the files that are actually about to ship, never
    from a copy made earlier. kdcmp.pak is NOT byte-deterministic -- two
    rebuilds from identical sources give the same size and a different sha256
    (observed 2026-08-28: A4343EF0 then 9C180836 for a 539,481-byte pak). A
    manifest written before a later rebuild describes a pak that no longer
    exists, and the verification it drives then fails on a perfectly good
    artifact.

.PARAMETER AppDir
    The directory whose contents become the APP entries.

.PARAMETER ModFiles
    Ordered pairs of <relative path> = <source file> for the MOD entries.

.PARAMETER OutFile
    Where to write the manifest. Normally <AppDir>\install-manifest.txt --
    it ships inside the payload so the post-install check needs no second
    source of truth.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string]    $AppDir,
    [Parameter(Mandatory = $true)] [hashtable] $ModFiles,
    [Parameter(Mandatory = $true)] [string]    $OutFile
)

$ErrorActionPreference = 'Stop'

# Never list a stale self: the manifest must not describe the file it is.
if (Test-Path $OutFile) { Remove-Item $OutFile -Force }

$appFull = (Get-Item $AppDir).FullName
$lines = @('# KCDMP install manifest v2 -- <kind>|<relative path>|<size>|<sha256>')
$lines += Get-ChildItem $appFull -Recurse -File | ForEach-Object {
    'APP|{0}|{1}|{2}' -f $_.FullName.Substring($appFull.Length + 1), $_.Length,
                         (Get-FileHash $_.FullName -Algorithm SHA256).Hash
}

# Ordered, so the manifest reads the same way every build. A hashtable does not
# preserve insertion order in Windows PowerShell 5.1.
foreach ($rel in ($ModFiles.Keys | Sort-Object)) {
    $src = $ModFiles[$rel]
    if (-not (Test-Path $src)) { throw "mod file missing, cannot manifest it: $src" }
    $lines += 'MOD|{0}|{1}|{2}' -f $rel, (Get-Item $src).Length,
                                   (Get-FileHash $src -Algorithm SHA256).Hash
}

Set-Content -Path $OutFile -Value $lines -Encoding ASCII
Write-Host "Install manifest: $($lines.Count - 1) entries (APP + MOD, size + sha256) -> $OutFile"
