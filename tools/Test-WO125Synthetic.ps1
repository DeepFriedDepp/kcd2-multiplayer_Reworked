<#
.SYNOPSIS
    WO-125: synthetic test for the Lua half of continuity (per-world Henry files):
    mp_join_henry auto|fresh|playlineN/file as the first-join answer, the
    snapshot QuickSave, the live Henry test, mp_henry_reset and mp_henry_files.
    No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO125Synthetic.lua. The flow itself is live-tested -- see
    docs/WO-125-findings.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO125Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO125Synthetic.lua') `
    -Title 'WO-125 synthetic continuity Lua test'
exit $LASTEXITCODE
