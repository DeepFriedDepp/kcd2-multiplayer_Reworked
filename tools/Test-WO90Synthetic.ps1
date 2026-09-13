<#
.SYNOPSIS
    WO-90: synthetic test for the never-synced entity-name exclusion -- the
    engine's per-conversation stand-ins ("DialogTwin_*") and this mod's own
    ghost bodies ("kcd2mp_*") must never enter NPC sync in any role. No game,
    relay or agent needed.

.DESCRIPTION
    Same driver as Test-NpcSmoothSynthetic.ps1 (the real kdcmp.lua under
    MoonSharp, engine stubbed, fake clock); different scenario file
    (Test-WO90Synthetic.lua).

    Scenarios:
      (a) the rescan tracks an ordinary world NPC standing beside a
          conversation stand-in and a ghost body, and tracks only the
          ordinary one; as damage authority only it reaches the wire
      (b) the same in the proximity-claim role (WO-60 "npc_claim") -- the
          role that actually claimed the twins in the field
      (c) the drag sensor claims a downed ordinary body but never a downed
          stand-in
      (d) the inbound apply refuses both families whatever the sender
          believes: no puppet, no position write, no animation, one log line
          per name; an ordinary name is unaffected
      (e) the prefix test at its edges: a name that merely CONTAINS the token
          survives; the bare prefix does not

    What this does NOT prove: that removing conversation stand-ins from sync
    fixes what the two players actually saw. See docs/WO-90-findings.md for
    what a live two-player session still has to answer.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Test-WO90Synthetic.ps1
#>
[CmdletBinding()]
param(
    [string] $KdcmpLua = '',
    [string] $MoonSharpVersion = '2.0.0.0'
)

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& (Join-Path $toolsDir 'Test-NpcSmoothSynthetic.ps1') `
    -KdcmpLua $KdcmpLua -MoonSharpVersion $MoonSharpVersion `
    -Scenario (Join-Path $toolsDir 'Test-WO90Synthetic.lua') `
    -Title 'WO-90 synthetic never-synced entity-name test'
exit $LASTEXITCODE
