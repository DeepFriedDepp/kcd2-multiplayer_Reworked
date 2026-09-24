<#
.SYNOPSIS
    WO-118: synthetic test for the Lua half of the native per-frame puppet
    write -- the bind policy, the heartbeat fallback, holds, the activity
    detach, the presets and mp_npc_trace. No game, relay, agent or DLL needed.
.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); scenario file
    Test-WO118Synthetic.lua. The native writer itself is exercised live, not
    here -- see docs/WO-118-progress.md.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO118Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO118Synthetic.lua') `
    -Title 'WO-118 synthetic native-write / detach test'
exit $LASTEXITCODE
