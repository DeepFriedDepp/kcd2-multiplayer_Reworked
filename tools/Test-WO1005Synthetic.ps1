<#
.SYNOPSIS
    WO-100.5: synthetic test for the Phase 2 continuous body-state channel and
    the Phase 0 ghost class / NoAI toggles. No game, relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO1005Synthetic.lua). See that file's header for the scenario list
    and for what this deliberately does NOT prove.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO1005Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO1005Synthetic.lua') `
    -Title 'WO-100.5 synthetic body-state / ghost-class test'
exit $LASTEXITCODE
