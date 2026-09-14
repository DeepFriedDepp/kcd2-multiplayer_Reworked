<#
.SYNOPSIS
    WO-95: synthetic test for the NPC packet-cadence instrument -- moving
    packets and idle heartbeats are measured apart, so the cadence number a
    jitter work order tunes against means what it says.

.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO95Synthetic.lua). See that file's header for the scenario list,
    the field evidence that prompted it, and what this deliberately does NOT
    prove.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO95Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO95Synthetic.lua') `
    -Title 'WO-95 synthetic NPC packet-cadence test'
exit $LASTEXITCODE
