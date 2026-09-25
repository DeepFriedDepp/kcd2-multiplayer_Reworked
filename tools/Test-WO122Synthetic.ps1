<#
.SYNOPSIS
    WO-122: synthetic test for the Lua half of the shared-world foundations --
    owner death (ships on), the joiner's host-only save lock, the host's world
    save request, the toggles, presets and the WO122-BUILD marker. No game,
    relay or agent needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO122Synthetic.lua. The engine's side (a save refused under the lock,
    a real NPC killed) is live-tested -- see docs/WO-122-findings.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO122Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO122Synthetic.lua') `
    -Title 'WO-122 synthetic shared-world Lua test'
exit $LASTEXITCODE
