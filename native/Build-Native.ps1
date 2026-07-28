<#
.SYNOPSIS
    Configure and build the native plugin and injector with the VS Build Tools
    toolchain, which is not on PATH.

.DESCRIPTION
    Mirrors the .NET side's situation: the toolchain is installed but invisible
    to a bare shell, so this script locates it via vswhere rather than assuming
    a version number. Output lands in native\build\.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File native\Build-Native.ps1
#>
param(
    [ValidateSet("Debug","Release")][string]$Config = "Release",
    [switch]$Clean
)

$ErrorActionPreference = "Stop"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere not found -- is VS Build Tools installed?" }

$vsRoot = & $vswhere -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw "No VS installation with the x64 C++ toolset found." }

$cmake = Join-Path $vsRoot "Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
$ninja = Join-Path $vsRoot "Common7\IDE\CommonExtensions\Microsoft\CMake\Ninja\ninja.exe"
$vcvars = Join-Path $vsRoot "VC\Auxiliary\Build\vcvars64.bat"
foreach ($p in @($cmake, $ninja, $vcvars)) {
    if (-not (Test-Path $p)) { throw "missing component: $p" }
}

$src   = $PSScriptRoot
$build = Join-Path $src "build"
if ($Clean -and (Test-Path $build)) { Remove-Item $build -Recurse -Force }

# A KCDMP.dll currently injected into a running game holds its own file open, so
# the linker fails with LNK1104. Windows does allow *renaming* a loaded module,
# which frees the name without disturbing the game. Same trap as rebuilding the
# pak with the game running, and it will happen on nearly every iteration.
$locked = Join-Path $build "KCDMP\KCDMP.dll"
if (Test-Path $locked) {
    try {
        [IO.File]::Open($locked, 'Open', 'ReadWrite', 'None').Dispose()
    } catch {
        $parked = "$locked.inuse-$(Get-Date -Format yyyyMMdd-HHmmss)"
        Rename-Item $locked $parked
        Write-Warning "KCDMP.dll was loaded in a running process; parked as $(Split-Path $parked -Leaf)."
    }
}
# Sweep parked copies whose holder has since exited.
Get-ChildItem (Join-Path $build "KCDMP") -Filter "KCDMP.dll.inuse-*" -ErrorAction SilentlyContinue |
    ForEach-Object { try { Remove-Item $_.FullName -Force -ErrorAction Stop } catch {} }

# cl.exe needs the environment vcvars64 sets (INCLUDE, LIB, PATH). Configuring
# and building from one cmd invocation keeps that environment alive across both
# steps; setting it from PowerShell and hoping it persists does not work.
$cmd = @(
    # 2>&1 as well as >nul: vcvars64.bat shells out to vswhere.exe for optional
    # components, and when it is not on PATH it writes a harmless "not
    # recognized" line to stderr. PowerShell surfaces that as a NativeCommand
    # error record on an otherwise clean build, which is worse than useless.
    "call `"$vcvars`" >nul 2>&1",
    "`"$cmake`" -S `"$src`" -B `"$build`" -G Ninja -DCMAKE_MAKE_PROGRAM=`"$ninja`" -DCMAKE_BUILD_TYPE=$Config",
    "`"$cmake`" --build `"$build`" --config $Config"
) -join " && "

cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw "build failed with exit code $LASTEXITCODE" }

Write-Output "`nartifacts:"
Get-ChildItem $build -Recurse -Include "KCDMP.dll","KCDMP_LauncherInjector.exe" |
    ForEach-Object { "  {0}  ({1:N0} bytes)" -f $_.FullName, $_.Length }
