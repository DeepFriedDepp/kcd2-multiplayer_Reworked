<#
.SYNOPSIS
    WO-110: synthetic test for the 0.26.5 fixes' Lua half -- the chunked native
    scan push and its cap, the streaming-radius door, Z interpolation and the
    MP-NPCZ telemetry, the save-load bookkeeping resets, the two presets and
    the WO110-BUILD marker. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO110Synthetic.lua. See that file's header for the scenario list and
    for what this deliberately does NOT prove (anything about the engine, and
    anything two-player).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO110Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO110Synthetic.lua') `
    -Title 'WO-110 synthetic 0.26.5 test'
exit $LASTEXITCODE
