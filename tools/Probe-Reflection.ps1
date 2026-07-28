<#
.SYNOPSIS
    Re-runnable capability probe for the RTTR reflection surface exposed by the
    KCD2 debug REST API. Worth re-running after any game patch.

.DESCRIPTION
    Read-only by default. Three modes:

      (default)   introspect the reflected surface and read live values
      -Snapshot   dump every soul's identity to CSV, for the restart diff that
                  settles which key is stable across processes
      -AllowWrites  run the mutation ladder: stamina, then player health, then
                  TakeDamage on the player. All reversible; restores as it goes.
                  Does NOT touch any NPC.

    Every write is verified by reading the value back. A void return from a
    reflected method is not evidence of anything -- that lesson is why the Lua
    investigation cost as much as it did.

.EXAMPLE
    . tools\Probe-Reflection.ps1
.EXAMPLE
    tools\Probe-Reflection.ps1 -Snapshot -OutFile tools\soul-identity-run2.csv
.EXAMPLE
    tools\Probe-Reflection.ps1 -AllowWrites
#>
param(
    [switch]$Snapshot,
    [switch]$AllowWrites,
    [string]$OutFile = "tools\soul-identity-run2.csv"
)

. (Join-Path $PSScriptRoot "KcdApi.ps1")

$player = "/api/rpg/SoulList/PlayerSoul"

if (-not (Test-KcdApi)) {
    Write-Error "Debug API not answering on localhost:1403. Launch KCD2 via the KCD2 Modding Tools Steam entry and load a save."
    exit 1
}

Write-Output "=== reflected surface ==="
Write-Output ("souls loaded      : " + (Get-KcdValue "/api/rpg/SoulList/SoulCount"))
Write-Output ("player name       : " + (Get-KcdValue "$player/Name"))
Write-Output ("player guid       : " + (Get-KcdValue "$player/Guid"))
Write-Output ("player shared guid: " + (Get-KcdValue "$player/SharedSoulGuid"))
Write-Output ("player position   : " + (Get-KcdValue "$player/Position"))

Write-Output "`n=== live state reads (method invocation over HTTP) ==="
foreach ($state in @("health","stamina","exhaust","hunger")) {
    Write-Output ("{0,-10}: {1}" -f $state, (Get-KcdValue "$player/GetState?State=$state"))
}

Write-Output "`n=== round-trip cost ==="
$times = @()
for ($i = 0; $i -lt 12; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Get-KcdValue "$player/GetState?State=health"
    $sw.Stop()
    $times += $sw.Elapsed.TotalMilliseconds
}
$s = $times | Sort-Object
Write-Output ("invoke n=12: min={0:N1} p50={1:N1} max={2:N1} ms  (first call after connect is ~2 s, retry rather than conclude the game is absent)" -f $s[0], $s[6], $s[11])

if ($Snapshot) {
    Write-Output "`n=== identity snapshot ==="
    $rows = Get-KcdSoulSnapshot
    $rows | Export-Csv -NoTypeInformation -Path $OutFile -Encoding UTF8
    $same = ($rows | Where-Object { $_.Guid -eq $_.SharedSoulGuid }).Count
    Write-Output ("captured {0} souls -> {1}" -f $rows.Count, $OutFile)
    Write-Output ("Guid == SharedSoulGuid for {0} of {1}" -f $same, $rows.Count)
    Write-Output "To settle identity: restart the game, load the SAME save, re-run with -Snapshot"
    Write-Output "to a second file, then diff. Whatever survives the restart is the candidate"
    Write-Output "cross-client key; whatever does not is disqualified."
}

if ($AllowWrites) {
    Write-Output "`n=== mutation ladder (player only, reversible) ==="

    $before = [double](Get-KcdValue "$player/GetState?State=stamina")
    $null = Get-KcdValue "$player/SetState?State=stamina&Value=60"
    $after = Get-KcdValue "$player/GetState?State=stamina"
    Write-Output ("stamina  {0} -> set 60 -> {1}   [{2}]" -f $before, $after, $(if ([double]$after -lt $before) { "WRITE WORKS" } else { "INERT" }))

    $h0 = [double](Get-KcdValue "$player/GetState?State=health")
    $null = Get-KcdValue "$player/SetState?State=health&Value=95"
    $h1 = Get-KcdValue "$player/GetState?State=health"
    $null = Get-KcdValue "$player/SetState?State=health&Value=$h0"
    $h2 = Get-KcdValue "$player/GetState?State=health"
    Write-Output ("health   {0} -> set 95 -> {1} -> restored {2}   [{3}]" -f $h0, $h1, $h2, $(if ([double]$h1 -ne $h0) { "WRITE WORKS" } else { "INERT" }))

    $d0 = [double](Get-KcdValue "$player/GetState?State=health")
    $null = Get-KcdValue "$player/CombatSoul/TakeDamage?Stamina=0&Health=5&SuppressHitReaction=true"
    $d1 = Get-KcdValue "$player/GetState?State=health"
    $null = Get-KcdValue "$player/SetState?State=health&Value=$d0"
    Write-Output ("TakeDamage 5: {0} -> {1} -> restored   [{2}]" -f $d0, $d1, $(if ([double]$d1 -lt $d0) { "COMBAT PATH WORKS" } else { "INERT" }))

    Write-Output "`nNot testable over HTTP: the Attacker parameter. RTTR has no string -> I_Soul*"
    Write-Output "converter, so attribution needs an in-process caller passing a real pointer."
}
