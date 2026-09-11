<#
.SYNOPSIS
    WO-77: synthetic stream test for the NPC puppet renderer -- no game, relay
    or agent needed.

.DESCRIPTION
    Runs the REAL kdcmp.lua under MoonSharp (a pure-.NET Lua interpreter,
    pulled from NuGet on first use) with the engine stubbed out and os.clock
    replaced by a fake clock, then pushes known sample sequences through
    KCD2MP_ApplyNpcState and KCD2MP_NpcPuppetTick and asserts on what the
    puppet entity was told to render. Scenarios (Test-NpcSmoothSynthetic.lua):

      (a) continuous interpolation between samples at constant speed
      (b) hold-at-newest with no overshoot past the last real point
      (c) a doubled/leaked update chain renders the same position as one
          chain (the WO-69 D3 structural proof, synthetic)
      (d) the derived interpolation DELAY tracks emitMs (Step 2)
      (e) jittered arrivals: monotonic, never past newest, no anim churn
      (f) a packet after a moved-gated silence: DELAY-long move, no crawl
      (g) >5 m teleport snaps; (h) yaw wraps the short way
      (i) mp_npc_smooth off restores the pre-WO-77 lerp; on renders again
      (j) WO-78: the per-packet restart caller (KCD2MP_ApplyNpcState ->
          StartNpcPuppet) during a timer suspension arms one probe and
          starts no new chain; a real death restarts exactly once;
          mp_npc_chainfix defaults on

    The same driver runs the ghost scenarios when given -Scenario; see
    Test-GhostInterpSynthetic.ps1.

    What this does NOT prove: how the puppet looks or feels to a human
    watching real combat, and whether WO-60's claim system holds under real
    two-player pressure. Both stay open until a field session.

    Needs: the .NET SDK (for the one-time NuGet restore of MoonSharp) and
    Windows PowerShell 5.1 or later.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-NpcSmoothSynthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0',
    # WO-78: the scenario file to splice kdcmp.lua into. Defaults to this
    # script's own puppet scenarios; Test-GhostInterpSynthetic.ps1 passes the
    # ghost interp scenarios through the same driver.
    [string] $Scenario = '',
    [string] $Title = 'WO-77 synthetic NPC-smooth test'
)

$ErrorActionPreference = 'Stop'
# $PSScriptRoot is not populated while param defaults are evaluated in
# Windows PowerShell 5.1, so resolve the default here.
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $KdcmpLua) { $KdcmpLua = Join-Path $toolsDir '..\kdcmp\Data\Scripts\Startup\kdcmp.lua' }
if (-not $Scenario) { $Scenario = Join-Path $toolsDir 'Test-NpcSmoothSynthetic.lua' }

# --- locate (or restore) MoonSharp -------------------------------------------
$pkgRoot = Join-Path $env:USERPROFILE '.nuget\packages\moonsharp'
function Find-MoonSharpDll {
    if (-not (Test-Path $pkgRoot)) { return $null }
    $cands = Get-ChildItem $pkgRoot -Directory | ForEach-Object {
        Join-Path $_.FullName 'lib\net40-client\MoonSharp.Interpreter.dll'
    } | Where-Object { Test-Path $_ }
    if ($cands) { return ($cands | Select-Object -First 1) }
    return $null
}
$dll = Find-MoonSharpDll
if (-not $dll) {
    Write-Host "MoonSharp not in the NuGet cache; restoring $MoonSharpVersion once..." -ForegroundColor Yellow
    $dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $dotnet) {
        $alt = Join-Path $env:USERPROFILE '.dotnet-sdk8\dotnet.exe'
        if (Test-Path $alt) { $dotnet = $alt } else { throw "dotnet SDK not found; cannot restore MoonSharp" }
    } else { $dotnet = $dotnet.Source }
    $tmp = Join-Path $env:TEMP ("wo77-moonsharp-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup>
  <ItemGroup><PackageReference Include="MoonSharp" Version="$MoonSharpVersion" /></ItemGroup>
</Project>
"@ | Set-Content -Encoding utf8 (Join-Path $tmp 'restore.csproj')
    & $dotnet restore (Join-Path $tmp 'restore.csproj') | Out-Null
    Remove-Item -Recurse -Force $tmp
    $dll = Find-MoonSharpDll
    if (-not $dll) { throw "MoonSharp restore did not produce lib\net40-client\MoonSharp.Interpreter.dll under $pkgRoot" }
}
Add-Type -Path $dll

# --- splice the real kdcmp.lua into the scenario file ------------------------
if (-not (Test-Path $KdcmpLua)) { throw "kdcmp.lua not found: $KdcmpLua" }
if (-not (Test-Path $Scenario)) { throw "scenario file not found: $Scenario" }
$scenarioText = Get-Content $Scenario -Raw
$marker = '-- @@KDCMP@@'
if ($scenarioText.IndexOf($marker) -lt 0) { throw "scenario file lacks the $marker splice marker" }
$parts = $scenarioText -split [regex]::Escape($marker), 2
$mod = Get-Content $KdcmpLua -Raw
$code = $parts[0] + "`n" + $mod + "`n" + $parts[1]

Write-Host $Title
Write-Host "  scenario  : $((Resolve-Path $Scenario).Path)"
Write-Host "  kdcmp.lua : $((Resolve-Path $KdcmpLua).Path)"
Write-Host "  MoonSharp : $dll"
Write-Host ""

$lua = New-Object MoonSharp.Interpreter.Script
try {
    $null = $lua.DoString($code)
} catch [MoonSharp.Interpreter.SyntaxErrorException] {
    Write-Host "LUA SYNTAX ERROR: $($_.Exception.DecoratedMessage)" -ForegroundColor Red; exit 3
} catch [MoonSharp.Interpreter.ScriptRuntimeException] {
    Write-Host "LUA RUNTIME ERROR: $($_.Exception.DecoratedMessage)" -ForegroundColor Red; exit 2
} catch {
    if ($_.Exception.InnerException -and $_.Exception.InnerException.PSObject.Properties['DecoratedMessage']) {
        Write-Host "LUA ERROR: $($_.Exception.InnerException.DecoratedMessage)" -ForegroundColor Red
    } else { Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red }
    exit 2
}

$out = $lua.Globals.Get('OUT')
if ($out.Type -ne [MoonSharp.Interpreter.DataType]::String) { Write-Host "scenario produced no OUT" -ForegroundColor Red; exit 2 }
$pass = 0; $fail = 0
foreach ($line in ($out.String -split "`n")) {
    if ($line -like 'PASS*') { $pass++; Write-Host "  $line" -ForegroundColor Green }
    elseif ($line -like 'FAIL*') { $fail++; Write-Host "  $line" -ForegroundColor Red }
    else { Write-Host "  $line" -ForegroundColor DarkGray }
}
Write-Host ""
Write-Host ("RESULT: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor ($(if ($fail -eq 0) { 'Green' } else { 'Red' }))
if ($fail -gt 0) { exit 1 }
exit 0
