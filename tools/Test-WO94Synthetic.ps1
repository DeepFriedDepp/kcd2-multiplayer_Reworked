<#
.SYNOPSIS
    WO-94: synthetic test for Shared Quests -- the main-story readiness
    prompt: bounded registry, side-content exclusion, proximity detection,
    the prompt state machine, the reused F11/F12 keys, the catch-up hazard
    window and the not-responding path. No game, relay or agent needed.

.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO94Synthetic.lua). See that file's header for the scenario list
    and for what this deliberately does NOT prove.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO94Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO94Synthetic.lua') `
    -Title 'WO-94 synthetic Shared Quests test'
exit $LASTEXITCODE
