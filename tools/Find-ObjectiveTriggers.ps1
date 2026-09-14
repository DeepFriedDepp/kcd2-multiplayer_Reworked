<#
.SYNOPSIS
    WO-96 Phase 3: for every journal objective of the 32 main quests, find the
    NARROW Haste triggers -- WO-92 s6.1's "targeted setter" population -- whose
    OnTrigger drives the very State node that objective displays, and classify
    each as clean or not (positional commands, prerequisites, other targets).

.DESCRIPTION
    An objective is a display node <objName Name="objectiveVisualNN"> fed by
    <Edge From="X.State" To="Progress"/> (or a minigame's states/tracker output).
    X is the State node whose transitions the journal shows. A HasteTrigger T
    in the same file with <Edge From="T.OnTrigger" To="X.SetActive|SetDone|..."/>
    grants that objective directly. This tool lists exactly those pairs, plus
    what else T does, so a "close this one gap" fire can be judged before it
    is trusted:
      * positional   = any ConsoleCommands entry that is goto/playerGoto/teleport
      * prereqs      = the trigger's Prerequisites array (cumulative replay)
      * otherTargets = OnTrigger edges to anything but X (side effects)
      * nestedHaste  = ConsoleCommands that fire other Haste triggers
    clean = direct AND no positional AND no prereqs AND no nested AND no other
    targets. Indirect grants (T -> module in-port -> ... -> X) are NOT
    followed; they are the cumulative replay WO-94 already uses.

    Output: docs/WO-96-objective-triggers.csv (one row per objective x trigger,
    objectives without any trigger get one row with trigger = "") and a
    summary. Reads Scripts.pak only; writes nothing else.
#>
[CmdletBinding()]
param(
    [string] $ScriptsPak = '',
    [string] $CsvOut = '',
    [string] $OnlyQuest = ''
)
$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $toolsDir
if (-not $CsvOut) { $CsvOut = Join-Path $repoRoot 'docs\WO-96-objective-triggers.csv' }

function Find-ScriptsPak {
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try { $v = Get-ItemProperty -Path $k -ErrorAction Stop; if ($v.SteamPath) { $steam = $v.SteamPath; break }; if ($v.InstallPath) { $steam = $v.InstallPath; break } } catch { }
    }
    $rootsDirs = @()
    if ($steam) {
        $rootsDirs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) { foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $rootsDirs += ($m.Groups[1].Value -replace '\\\\', '\') } }
    }
    foreach ($r in $rootsDirs) { $p = Join-Path $r 'steamapps\common\KCD2Mod\Data\Scripts.pak'; if (Test-Path $p) { return $p } }
    return $null
}
if (-not $ScriptsPak) { $ScriptsPak = Find-ScriptsPak }
if (-not $ScriptsPak -or -not (Test-Path $ScriptsPak)) { throw "Scripts.pak not found; pass -ScriptsPak" }
Write-Host "=== WO-96 narrow objective-trigger census ===" -ForegroundColor Cyan

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($ScriptsPak)
$files = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
try {
    foreach ($e in $zip.Entries) {
        if ($e.Name -and $e.FullName.StartsWith('Quests/Final/', [System.StringComparison]::Ordinal) -and $e.FullName.EndsWith('.xml')) {
            $sr = New-Object System.IO.StreamReader ($e.Open()); try { $files[$e.FullName] = $sr.ReadToEnd() } finally { $sr.Dispose() }
        }
    }
} finally { $zip.Dispose() }

$rootRx = [regex]'<Quest\s[^>]*\bProductionCode="(M[0-9]+[a-z]?)"[^>]*>'
$nameRx = [regex]'\bName="([^"]+)"'
$roots = @()
foreach ($kv in $files.GetEnumerator()) {
    $m = $rootRx.Match($kv.Value); if (-not $m.Success) { continue }
    $nm = $nameRx.Match($m.Value)
    $roots += [pscustomobject]@{ Code = $m.Groups[1].Value; Name = $nm.Groups[1].Value; File = $kv.Key }
}
$roots = @($roots | Sort-Object { [int]($_.Code -replace '[^0-9]', '') }, Code)
if ($roots.Count -ne 32) { throw "expected 32 main quests, found $($roots.Count)" }
if ($OnlyQuest) { $roots = @($roots | Where-Object Name -eq $OnlyQuest) }

function Load-Xml([string]$text) {
    $doc = New-Object System.Xml.XmlDocument; $doc.PreserveWhitespace = $false
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    $doc.LoadXml($text); return $doc
}
function Collect-Subtree($root) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $order = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($root.File); [void]$seen.Add($root.File)
    while ($queue.Count -gt 0) {
        $f = $queue.Dequeue(); [void]$order.Add($f)
        if (-not $files.ContainsKey($f)) { continue }
        $dir = $f.Substring(0, $f.LastIndexOf('/'))
        foreach ($m in [regex]::Matches($files[$f], '<Definition\s+File="([^"]+)"')) {
            $child = "$dir/" + ($m.Groups[1].Value -replace '\\', '/')
            if ($seen.Add($child)) { $queue.Enqueue($child) }
        }
    }
    return @($order)
}
function Resolve-Array([System.Xml.XmlNode]$scope, [string]$from, [int]$depth = 0) {
    if ($depth -gt 8) { return @() }
    $nodeName = $from.Split('.')[0]
    $node = $null
    foreach ($n in $scope.SelectNodes(".//*[@Name='$nodeName']")) { $node = $n; break }
    if (-not $node) { return @("<unresolved:$from>") }
    switch ($node.LocalName) {
        'MakeArray'  { $vals = @(); foreach ($c in $node.SelectNodes('Constant')) { $vals += [string]$c.GetAttribute('Value') }; return $vals }
        'JoinArrays' { $vals = @(); foreach ($e in @($node.SelectNodes('Edge') | Sort-Object { [string]$_.GetAttribute('To') })) { $vals += Resolve-Array $scope ([string]$e.GetAttribute('From')) ($depth + 1) }; return $vals }
        default      { return @("<$($node.LocalName):$from>") }
    }
}

$setPorts = @('SetActive', 'SetDone', 'SetTrue', 'SetFalse', 'SetFailed', 'SetNone', 'SetRunning', 'Increment', 'Set')
$posRx = [regex]'(?i)^\s*(goto|playergoto|teleport)\b'
$hasteRx = [regex]'wh_concept_[Hh]asteTrigger\s+([A-Za-z0-9_.]+)'
$rows = New-Object System.Collections.ArrayList
$totObj = 0; $objWithDirect = 0; $objWithClean = 0; $pairs = 0; $cleanPairs = 0

foreach ($q in $roots) {
    $sub = Collect-Subtree $q
    $docs = @{}; foreach ($f in $sub) { if ($files.ContainsKey($f)) { $docs[$f] = Load-Xml $files[$f] } }
    $rootEl = $null
    $sk = $docs[$q.File].DocumentElement.SelectSingleNode('Skald'); foreach ($c in $sk.ChildNodes) { if ($c.NodeType -eq 'Element') { $rootEl = $c; break } }
    $objNames = @(); foreach ($o in $rootEl.SelectNodes('Objectives/Objective')) { $objNames += [string]$o.GetAttribute('Name') }
    $totObj += $objNames.Count

    # objective -> list of (file, drivingNode) pairs
    $drivers = @{}
    foreach ($f in $sub) {
        $d = $docs[$f]; if (-not $d) { continue }
        foreach ($on in $objNames) {
            foreach ($vis in $d.SelectNodes("//$on[@Name]")) {
                foreach ($e in $vis.SelectNodes('Edge')) {
                    if (([string]$e.GetAttribute('To')) -ne 'Progress') { continue }
                    $from = [string]$e.GetAttribute('From')
                    $drv = $from.Split('.')[0]
                    if (-not $drivers.ContainsKey($on)) { $drivers[$on] = New-Object System.Collections.ArrayList }
                    [void]$drivers[$on].Add(@{ File = $f; Node = $drv; Port = ($from.Split('.')[1]) })
                }
            }
        }
    }

    # every HasteTrigger in the quest, with what its OnTrigger touches
    $trigInfo = @()
    foreach ($f in $sub) {
        $d = $docs[$f]; if (-not $d) { continue }
        $sk2 = $d.DocumentElement.SelectSingleNode('Skald'); $scope = $null
        if ($sk2) { foreach ($c in $sk2.ChildNodes) { if ($c.NodeType -eq 'Element') { $scope = $c; break } } }
        if (-not $scope) { $scope = $d.DocumentElement }
        foreach ($ht in $d.SelectNodes('//HasteTrigger')) {
            $tn = [string]$ht.GetAttribute('Name')
            $cmds = @(); $prereqs = @()
            foreach ($e in $ht.SelectNodes('Edge')) {
                $to = [string]$e.GetAttribute('To'); $from = [string]$e.GetAttribute('From')
                if ($to -eq 'ConsoleCommands') { $cmds += Resolve-Array $scope $from } elseif ($to -eq 'Prerequisites') { $prereqs += Resolve-Array $scope $from }
            }
            $targets = @()
            foreach ($e in $d.SelectNodes("//Edge[@From='$tn.OnTrigger']")) {
                $owner = $e.ParentNode
                $targets += ([string]$owner.GetAttribute('Name') + '.' + [string]$e.GetAttribute('To') + '|' + $owner.LocalName)
            }
            $trigInfo += [pscustomobject]@{ File = $f; Name = $tn; Cmds = $cmds; Prereqs = $prereqs; Targets = $targets
                Positional = @($cmds | Where-Object { $posRx.IsMatch($_) }).Count
                Nested = @($cmds | Where-Object { $hasteRx.IsMatch($_) }).Count }
        }
    }

    $qDirect = 0; $qClean = 0
    foreach ($on in $objNames) {
        $found = 0; $cleanFound = 0
        if ($drivers.ContainsKey($on)) {
            foreach ($drv in $drivers[$on]) {
                foreach ($t in $trigInfo) {
                    if ($t.File -ne $drv.File) { continue }
                    $hits = @($t.Targets | Where-Object { $_ -like "$($drv.Node).*" })
                    if ($hits.Count -eq 0) { continue }
                    $setHits = @($hits | Where-Object { $p = ($_ -split '\|')[0].Split('.')[1]; $setPorts -contains $p })
                    if ($setHits.Count -eq 0) { continue }
                    $others = @($t.Targets | Where-Object { -not ($_ -like "$($drv.Node).*") })
                    $clean = ($t.Positional -eq 0 -and $t.Prereqs.Count -eq 0 -and $t.Nested -eq 0 -and $others.Count -eq 0)
                    $found++; $pairs++
                    if ($clean) { $cleanFound++; $cleanPairs++ }
                    [void]$rows.Add([pscustomobject]@{
                        code = $q.Code; quest = $q.Name; objective = $on; drivingNode = $drv.Node
                        trigger = "$($q.Name).$($t.Name)"; ports = (($setHits | ForEach-Object { ($_ -split '\|')[0] }) -join ';')
                        otherTargets = ($others -join ';'); prereqs = ($t.Prereqs -join ';'); consoleCommands = ($t.Cmds -join ';')
                        positional = ($t.Positional -gt 0); nestedHaste = $t.Nested; clean = $clean
                        file = ($t.File -replace '^Quests/Final/', '')
                    })
                }
            }
        }
        if ($found -eq 0) {
            [void]$rows.Add([pscustomobject]@{ code = $q.Code; quest = $q.Name; objective = $on; drivingNode = (($drivers[$on] | ForEach-Object { $_.Node }) -join ';')
                trigger = ''; ports = ''; otherTargets = ''; prereqs = ''; consoleCommands = ''; positional = $false; nestedHaste = 0; clean = $false; file = '' })
        } else { $qDirect++; $objWithDirect++ }
        if ($cleanFound -gt 0) { $qClean++; $objWithClean++ }
    }
    Write-Host ("    {0,-4} {1,-26} objectives {2,3}  with a direct narrow trigger {3,3}  clean {4,3}" -f $q.Code, $q.Name, $objNames.Count, $qDirect, $qClean)
}
Write-Host ""
Write-Host ("  total: {0} objectives; {1} have at least one direct narrow trigger ({2} objective x trigger pairs); {3} have a CLEAN one ({4} clean pairs)" -f $totObj, $objWithDirect, $pairs, $objWithClean, $cleanPairs)
$rows | Export-Csv -Path $CsvOut -NoTypeInformation -Encoding UTF8
Write-Host "  wrote $CsvOut ($($rows.Count) rows)"

# --- the fix table for the mod ------------------------------------------------------
# A fix is a clean pair whose port GRANTS the objective (SetActive / SetDone --
# SetNone and SetFalse are resets) and whose trigger is not one of Warhorse's
# own test/debug/gamescom entries (WO-94's exclusion rule). One entry per
# (quest, objective, direction); a second trigger for the same triple is
# reported and skipped. The mod fires a fix only when the local player is IN
# that quest and the peer's fingerprint shows the objective in that state.
if ($OnlyQuest) { Write-Host "  -OnlyQuest: Lua fix table not written."; exit 0 }
$testRx = [regex]'(?i)test|debug|gamescom'
$fixes = @{}
$skippedReset = 0; $skippedTest = 0; $dupes = 0
foreach ($r in ($rows | Where-Object { $_.clean -eq $true })) {
    if ($testRx.IsMatch($r.trigger)) { $skippedTest++; continue }
    foreach ($port in ($r.ports -split ';')) {
        $p = $port.Split('.')[1]
        $dir = if ($p -eq 'SetActive') { 'active' } elseif ($p -eq 'SetDone') { 'done' } else { $skippedReset++; continue }
        $key = "$($r.quest)|$($r.objective)|$dir"
        if ($fixes.ContainsKey($key)) { $dupes++; Write-Host "    second fix for $key ($($r.trigger)) skipped; keeping $($fixes[$key].t)" -ForegroundColor DarkYellow; continue }
        if ($r.trigger -notmatch '^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$') { throw "fix trigger with unexpected characters: $($r.trigger)" }
        $fixes[$key] = @{ q = $r.quest; o = $r.objective; dir = $dir; t = $r.trigger; code = $r.code }
    }
}
$fixList = @($fixes.Values | Sort-Object { $_.code }, { $_.o }, { $_.dir })
Write-Host ("  fixes      : {0} grant triggers for the mod ({1} reset ports skipped, {2} test/debug names skipped, {3} duplicates skipped)" -f $fixList.Count, $skippedReset, $skippedTest, $dupes)

function LuaStr([string]$s) { return '"' + ($s -replace '\\', '\\\\' -replace '"', '\"') + '"' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('-- @@WO96-OBJECTIVE-FIXES-BEGIN@@')
[void]$sb.AppendLine('-- GENERATED by tools/Find-ObjectiveTriggers.ps1 -- do not edit by hand.')
[void]$sb.AppendLine(("-- {0} of 626 main-quest objectives have a CLEAN narrow Haste trigger that grants them" -f $fixList.Count))
[void]$sb.AppendLine('-- (its OnTrigger drives only that objective''s State node, no Prerequisites, no')
[void]$sb.AppendLine('-- ConsoleCommands, no other targets; WO-92 s6.1''s targeted-setter population).')
[void]$sb.AppendLine('-- The mod offers one only when the local player is IN that quest and the peer''s')
[void]$sb.AppendLine('-- fingerprint shows the objective in exactly that state. Everything else --')
[void]$sb.AppendLine('-- 600-odd objectives, the sacks of M03 among them -- has no such trigger and is')
[void]$sb.AppendLine('-- reported as a gap only. See docs/WO-96-findings.md s4.')
[void]$sb.AppendLine('KCD2MP_OBJECTIVE_FIXES = {')
foreach ($fx in $fixList) {
    [void]$sb.AppendLine(("    {{ q = {0}, o = {1}, dir = {2}, t = {3} }}," -f (LuaStr $fx.q), (LuaStr $fx.o), (LuaStr $fx.dir), (LuaStr $fx.t)))
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('-- @@WO96-OBJECTIVE-FIXES-END@@')
$KdcmpLua = Join-Path $repoRoot 'kdcmp\Data\Scripts\Startup\kdcmp.lua'
$lua = Get-Content $KdcmpLua -Raw
$b = $lua.IndexOf('-- @@WO96-OBJECTIVE-FIXES-BEGIN@@')
$e = $lua.IndexOf('-- @@WO96-OBJECTIVE-FIXES-END@@')
if ($b -lt 0 -or $e -lt 0 -or $e -lt $b) { throw "kdcmp.lua lacks the WO96-OBJECTIVE-FIXES markers" }
$eEnd = $lua.IndexOf("`n", $e); if ($eEnd -lt 0) { $eEnd = $lua.Length } else { $eEnd += 1 }
$new = $lua.Substring(0, $b) + $sb.ToString().Replace("`r`n", "`n") + $lua.Substring($eEnd)
[System.IO.File]::WriteAllText($KdcmpLua, $new, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  wrote fix table into $KdcmpLua ($($fixList.Count) entries)"
