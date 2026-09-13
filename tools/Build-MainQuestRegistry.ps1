<#
.SYNOPSIS
    WO-94: builds the bounded main-quest beat registry (M01-M51, base game
    only) from the quest XML corpus in the Modding Tools' Scripts.pak, and
    writes it into kdcmp.lua between two markers plus a reviewable CSV.

.DESCRIPTION
    The registry is what "Shared Quests" detects proximity against and what a
    "Yes" fires through wh_concept_HasteTrigger. It is deliberately finite:

      * exactly the <Quest> elements under Quests/Final whose ProductionCode
        is M<nn> -- 32 in the shipped pak (docs/WO-92-findings.md s6.1) --
        and nothing else. Side quests (S*), activities (A*), events (E*) and
        every dlc*-prefixed file are excluded by construction: they never
        carry an M code. Nothing in this script or in the Lua it emits knows
        how to add a quest at runtime.
      * within those 32, every <HasteTrigger> reachable by following the
        quest root's <Definition File=.../> references. Each is written to
        the CSV; only the subset that is BOTH positioned AND cumulative is
        emitted to Lua as a fireable beat (see -Why below).

    Path grammar (WO-92 s6.1, code-verified there): "<questName>.<triggerName>",
    intermediate modules flattening away unless they declare
    HasteNamespace="true". Every path this script emits is cross-checked
    against the paths Warhorse themselves authored inside the same quest
    files ("wh_concept_hasteTrigger <path>" console strings): a computed set
    that fails to contain an authored path aborts the build. Triggers inside
    a HasteNamespace module are never emitted to Lua -- no main-quest
    namespaced path is authored anywhere in the corpus, so the grammar for
    them is unverifiable here; they are counted in the CSV instead.

    Position resolution -- where a beat "is", for proximity:
      The planner runs a trigger's Prerequisites first, then its own
      ConsoleCommands, one string at a time. This script walks the same order
      (prerequisite paths and nested "wh_concept_hasteTrigger" commands
      recursively, same quest only) and takes the LAST player relocation it
      meets: "goto X Y Z ...", "playerGoto <level> X Y Z ..." (a fixed point)
      or "goto <entity>" / "playerGoto <entity>" (a named level entity,
      resolved live by the mod via System.GetEntityByName). A trigger with no
      relocation anywhere on its plan has no position and cannot be
      approached; it stays in the CSV with posKind=none.

    -Why only cumulative triggers are fireable:
      A cumulative trigger (one with Prerequisites, or one whose commands
      fire other triggers) is Warhorse's own "set the world up for this
      point" entry -- the thing a catch-up jump actually wants. A bare single
      setter fired at a player who is far behind sets one state with none of
      its predecessors; a bare teleport just moves them. Both are excluded
      from the fireable set and counted.

    Output:
      kdcmp.lua: the block between
        -- @@WO94-MAINQUEST-REGISTRY-BEGIN@@ and -- @@WO94-MAINQUEST-REGISTRY-END@@
      is replaced wholesale. The block is committed; the game, the tests and
      the agent never need Scripts.pak.
      docs/WO-94-mainquest-registry.csv: every trigger of the 32 quests, one
      row each, for review.

.PARAMETER ScriptsPak
    Path to the Modding Tools' Data\Scripts.pak. Auto-detected through the
    Steam library folders (app 2429020, installdir KCD2Mod) when omitted.
.PARAMETER NoWrite
    Compute and report only; touch neither kdcmp.lua nor the CSV.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Build-MainQuestRegistry.ps1
#>
[CmdletBinding()]
param(
    [string] $ScriptsPak = '',
    [string] $KdcmpLua = '',
    [string] $CsvOut = '',
    [switch] $NoWrite
)

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $toolsDir
if (-not $KdcmpLua) { $KdcmpLua = Join-Path $repoRoot 'kdcmp\Data\Scripts\Startup\kdcmp.lua' }
if (-not $CsvOut)   { $CsvOut   = Join-Path $repoRoot 'docs\WO-94-mainquest-registry.csv' }

# --- locate Scripts.pak -------------------------------------------------------
function Find-ScriptsPak {
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.SteamPath)   { $steam = $v.SteamPath;   break }
            if ($v.InstallPath) { $steam = $v.InstallPath; break }
        } catch { }
    }
    $roots = @()
    if ($steam) {
        $roots += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $roots += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($r in $roots) {
        $p = Join-Path $r 'steamapps\common\KCD2Mod\Data\Scripts.pak'
        if (Test-Path $p) { return $p }
    }
    return $null
}
if (-not $ScriptsPak) { $ScriptsPak = Find-ScriptsPak }
if (-not $ScriptsPak -or -not (Test-Path $ScriptsPak)) { throw "Scripts.pak not found; pass -ScriptsPak" }

$pakHash = (Get-FileHash -Algorithm SHA256 $ScriptsPak).Hash.ToLowerInvariant()
Write-Host "=== WO-94 main-quest registry build ===" -ForegroundColor Cyan
Write-Host "  Scripts.pak : $ScriptsPak"
Write-Host "  sha256      : $pakHash"

# --- read Quests/Final/* into memory -------------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($ScriptsPak)
# Ordinal keys: quest names are case-sensitive identifiers.
$files = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([System.StringComparer]::Ordinal)
try {
    foreach ($e in $zip.Entries) {
        if ($e.Name -and $e.FullName.StartsWith('Quests/Final/', [System.StringComparison]::Ordinal) -and $e.FullName.EndsWith('.xml')) {
            $sr = New-Object System.IO.StreamReader ($e.Open())
            try { $files[$e.FullName] = $sr.ReadToEnd() } finally { $sr.Dispose() }
        }
    }
} finally { $zip.Dispose() }
Write-Host ("  quest xml   : {0} files under Quests/Final" -f $files.Count)

# --- find the 32 M-coded quest roots -------------------------------------------
$rootRx = [regex]'<Quest\s[^>]*\bProductionCode="(M[0-9]+[a-z]?)"[^>]*>'
$nameRx = [regex]'\bName="([^"]+)"'
$roots = @()
foreach ($kv in $files.GetEnumerator()) {
    $m = $rootRx.Match($kv.Value)
    if (-not $m.Success) { continue }
    $nm = $nameRx.Match($m.Value)
    if (-not $nm.Success) { throw "M-coded <Quest> without a Name in $($kv.Key)" }
    $dir = $kv.Key.Substring(0, $kv.Key.LastIndexOf('/'))
    $level = ($dir -split '/')[-1]          # Quests/Final/Barbora/<level>/<quest>.xml
    if ($level -notin @('trosecko', 'kutnohorsko')) { throw "unexpected level folder '$level' for $($kv.Key)" }
    $roots += [pscustomobject]@{ Code = $m.Groups[1].Value; Name = $nm.Groups[1].Value; File = $kv.Key; Dir = $dir; Level = $level }
}
$roots = @($roots | Sort-Object { [int]($_.Code -replace '[^0-9]', '') }, Code)
Write-Host ("  main quests : {0} M-coded <Quest> roots" -f $roots.Count)
if ($roots.Count -ne 32) { throw "expected exactly 32 main quests (M01-M51), found $($roots.Count)" }
$dlc = @($roots | Where-Object { $_.File -match '(?i)dlc' })
if ($dlc.Count -gt 0) { throw "a DLC-prefixed file carries an M code: $($dlc.File -join ', ')" }

# --- parse helpers -------------------------------------------------------------
function Load-Xml([string]$text) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $false
    # strip a UTF-8 BOM if the pak entry carries one
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    $doc.LoadXml($text)
    return $doc
}

# Follow <Definition File="..."/> from a root, relative to each file's folder.
function Collect-Subtree($root) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $order = New-Object System.Collections.ArrayList
    $parent = @{}
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($root.File); [void]$seen.Add($root.File)
    while ($queue.Count -gt 0) {
        $f = $queue.Dequeue()
        [void]$order.Add($f)
        if (-not $files.ContainsKey($f)) { Write-Warning "definition not in pak: $f"; continue }
        $dir = $f.Substring(0, $f.LastIndexOf('/'))
        foreach ($m in [regex]::Matches($files[$f], '<Definition\s+File="([^"]+)"')) {
            $rel = $m.Groups[1].Value -replace '\\', '/'
            $child = "$dir/$rel"
            if ($seen.Add($child)) { $parent[$child] = $f; $queue.Enqueue($child) }
        }
    }
    return @{ Files = @($order); Parent = $parent }
}

# The definition element of a file: the first element child of <Skald>.
function Get-DefinitionRoot([System.Xml.XmlDocument]$doc) {
    $skald = $doc.DocumentElement.SelectSingleNode('Skald')
    if (-not $skald) { return $null }
    foreach ($c in $skald.ChildNodes) { if ($c.NodeType -eq 'Element') { return $c } }
    return $null
}

# Resolve "<node>.<port>" edges into a flat string list. MakeArray -> its
# Constants in document order; JoinArrays -> its inputs A, B, ... in order.
# Anything else is recorded as unresolved.
function Resolve-Array([System.Xml.XmlNode]$scope, [string]$from, [ref]$unresolved, [int]$depth = 0) {
    if ($depth -gt 8) { return @() }
    $nodeName = $from.Split('.')[0]
    $node = $null
    foreach ($n in $scope.SelectNodes(".//*[@Name='$nodeName']")) { $node = $n; break }
    if (-not $node) { $unresolved.Value += "missing:$from"; return @() }
    switch ($node.LocalName) {
        'MakeArray' {
            $vals = @()
            foreach ($c in $node.SelectNodes('Constant')) { $vals += [string]$c.GetAttribute('Value') }
            return $vals
        }
        'JoinArrays' {
            $vals = @()
            $edges = @($node.SelectNodes('Edge') | Sort-Object { [string]$_.GetAttribute('To') })
            foreach ($e in $edges) { $vals += Resolve-Array $scope ([string]$e.GetAttribute('From')) $unresolved ($depth + 1) }
            return $vals
        }
        default { $unresolved.Value += "$($node.LocalName):$from"; return @() }
    }
}

# --- walk every main quest -----------------------------------------------------
$allTriggers = New-Object System.Collections.ArrayList   # every HasteTrigger of the 32 quests
$byPath = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([System.StringComparer]::Ordinal)
$authored = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
$authoredRx = [regex]'wh_concept_[Hh]asteTrigger\s+([A-Za-z0-9_.]+)'
$questSummaries = @()

foreach ($q in $roots) {
    $sub = Collect-Subtree $q
    $docs = @{}
    foreach ($f in $sub.Files) { if ($files.ContainsKey($f)) { $docs[$f] = Load-Xml $files[$f] } }

    # namespace chain per file: walk parents; a file contributes its definition
    # root's Name when that root declares HasteNamespace="true"
    $nsOfFile = @{}
    foreach ($f in $sub.Files) {
        $chain = @()
        $cur = $f
        while ($cur -and $cur -ne $q.File) {
            $d = $docs[$cur]
            if ($d) {
                $def = Get-DefinitionRoot $d
                if ($def -and ([string]$def.GetAttribute('HasteNamespace')) -eq 'true') { $chain = @([string]$def.GetAttribute('Name')) + $chain }
            }
            $cur = $sub.Parent[$cur]
        }
        $nsOfFile[$f] = $chain
    }

    $qTriggers = @()
    foreach ($f in $sub.Files) {
        $d = $docs[$f]
        if (-not $d) { continue }
        foreach ($m in $authoredRx.Matches($files[$f])) { [void]$authored.Add($m.Groups[1].Value) }
        $def = Get-DefinitionRoot $d
        $scope = if ($def) { $def } else { $d.DocumentElement }
        foreach ($ht in $d.SelectNodes('//HasteTrigger')) {
            $tname = [string]$ht.GetAttribute('Name')
            # in-file namespace ancestors (an enclosing element with HasteNamespace="true")
            $inner = @()
            $anc = $ht.ParentNode
            while ($anc -and $anc.NodeType -eq 'Element') {
                if (([string]$anc.GetAttribute('HasteNamespace')) -eq 'true' -and $anc -ne $def) { $inner = @([string]$anc.GetAttribute('Name')) + $inner }
                $anc = $anc.ParentNode
            }
            $ns = @($nsOfFile[$f]) + $inner
            $path = (@($q.Name) + $ns + @($tname)) -join '.'
            $unres = @()
            $cmds = @(); $prereqs = @()
            foreach ($e in $ht.SelectNodes('Edge')) {
                $to = [string]$e.GetAttribute('To'); $from = [string]$e.GetAttribute('From')
                if ($to -eq 'ConsoleCommands') { $cmds    += Resolve-Array $scope $from ([ref]$unres) }
                elseif ($to -eq 'Prerequisites') { $prereqs += Resolve-Array $scope $from ([ref]$unres) }
            }
            # is <trigger>.OnTrigger consumed anywhere in this file?
            $drives = $d.SelectNodes("//Edge[@From='$tname.OnTrigger']").Count -gt 0
            $t = [pscustomobject]@{
                Code = $q.Code; Quest = $q.Name; Level = $q.Level; File = $f; Trigger = $tname; Path = $path
                Ns = ($ns.Count -gt 0); Cmds = $cmds; Prereqs = $prereqs; Unresolved = $unres; DrivesState = $drives
                PosKind = 'none'; X = $null; Y = $null; Z = $null; Entity = ''; PosLevel = ''; PosSrc = ''
                Cumulative = $false; NestedTriggers = 0
            }
            $qTriggers += $t
            if ($byPath.ContainsKey($path)) { Write-Warning "duplicate path $path ($f vs $($byPath[$path].File))" } else { $byPath[$path] = $t }
        }
    }

    # cumulative = has prerequisites, or fires other triggers from its commands
    foreach ($t in $qTriggers) {
        $nested = 0
        foreach ($c in $t.Cmds) { if ($authoredRx.IsMatch($c)) { $nested++ } }
        $t.NestedTriggers = $nested
        $t.Cumulative = ($t.Prereqs.Count -gt 0) -or ($nested -gt 0)
    }

    $questSummaries += [pscustomobject]@{ Code = $q.Code; Name = $q.Name; Level = $q.Level; Files = $sub.Files.Count; Triggers = $qTriggers.Count; Root = $q.File }
    foreach ($t in $qTriggers) { [void]$allTriggers.Add($t) }
}

# --- position resolution (planner order: prerequisites, then own commands) -----
$gotoXyzRx   = [regex]'^\s*goto\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)'
$gotoEntRx   = [regex]'^\s*goto\s+([A-Za-z_][A-Za-z0-9_]*)\s*$'
$pgXyzRx     = [regex]'^\s*[Pp]layer[Gg]oto\s+([A-Za-z_][A-Za-z0-9_]*)\s+(-?[0-9.]+)\s+(-?[0-9.]+)\s+(-?[0-9.]+)'
$pgEntRx     = [regex]'^\s*[Pp]layer[Gg]oto\s+([A-Za-z_][A-Za-z0-9_]*)\s*$'
$inv = [System.Globalization.CultureInfo]::InvariantCulture

function Walk-Plan($t, [System.Collections.Generic.HashSet[string]]$visiting, [ref]$last, [bool]$isOwn) {
    if (-not $visiting.Add($t.Path)) { return }   # cycle guard
    foreach ($p in $t.Prereqs) {
        if ($byPath.ContainsKey($p) -and $byPath[$p].Quest -eq $t.Quest) { Walk-Plan $byPath[$p] $visiting $last $false }
    }
    foreach ($c in $t.Cmds) {
        $am = $authoredRx.Match($c)
        if ($am.Success) {
            $p = $am.Groups[1].Value
            if ($byPath.ContainsKey($p) -and $byPath[$p].Quest -eq $t.Quest) { Walk-Plan $byPath[$p] $visiting $last $false }
            continue
        }
        $m = $gotoXyzRx.Match($c)
        if ($m.Success) {
            $last.Value = @{ Kind = 'xyz'; X = [double]::Parse($m.Groups[1].Value, $inv); Y = [double]::Parse($m.Groups[2].Value, $inv); Z = [double]::Parse($m.Groups[3].Value, $inv); Level = ''; Own = $isOwn }
            continue
        }
        $m = $pgXyzRx.Match($c)
        if ($m.Success) {
            $last.Value = @{ Kind = 'xyz'; X = [double]::Parse($m.Groups[2].Value, $inv); Y = [double]::Parse($m.Groups[3].Value, $inv); Z = [double]::Parse($m.Groups[4].Value, $inv); Level = $m.Groups[1].Value.ToLowerInvariant(); Own = $isOwn }
            continue
        }
        $m = $gotoEntRx.Match($c)
        if ($m.Success) { $last.Value = @{ Kind = 'ent'; Entity = $m.Groups[1].Value; Own = $isOwn }; continue }
        $m = $pgEntRx.Match($c)
        if ($m.Success) { $last.Value = @{ Kind = 'ent'; Entity = $m.Groups[1].Value; Own = $isOwn }; continue }
    }
}

foreach ($t in $allTriggers) {
    $last = $null
    $visiting = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    Walk-Plan $t $visiting ([ref]$last) $true
    if ($last) {
        $t.PosKind = $last.Kind
        $t.PosSrc = if ($last.Own) { 'own' } else { 'chain' }
        if ($last.Kind -eq 'xyz') { $t.X = $last.X; $t.Y = $last.Y; $t.Z = $last.Z; $t.PosLevel = $last.Level } else { $t.Entity = $last.Entity }
    }
}

# --- cross-check against authored paths ------------------------------------------
$questNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
foreach ($q in $roots) { [void]$questNames.Add($q.Name) }
$authoredMain = @($authored | Where-Object { $questNames.Contains($_.Split('.')[0]) })
# An authored string can be stale (Warhorse's own debug arrays reference
# triggers that were since renamed or moved to another quest -- nine such in
# the shipped pak). The grammar check therefore asks: for every authored path
# whose TRIGGER NAME exists in the NAMED quest, is the computed path identical?
# A trigger that exists in that quest under a different computed path is a
# grammar failure and aborts; a name absent from that quest is reported as
# stale and ignored.
$matched = 0; $stale = @(); $grammarFail = @()
foreach ($ap in $authoredMain) {
    if ($byPath.ContainsKey($ap)) { $matched++; continue }
    $qn = $ap.Split('.')[0]; $tn = $ap.Split('.')[-1]
    $sameName = @($allTriggers | Where-Object { $_.Quest -eq $qn -and $_.Trigger -eq $tn })
    if ($sameName.Count -gt 0) { $grammarFail += "$ap (computed: $($sameName.Path -join ', '))" } else { $stale += $ap }
}
Write-Host ("  authored    : {0} distinct 'wh_concept_hasteTrigger <path>' strings inside the 32 quests; {1} name a main quest: {2} match the computed set exactly, {3} are stale (no such trigger in that quest), {4} grammar mismatches" -f $authored.Count, $authoredMain.Count, $matched, $stale.Count, $grammarFail.Count)
foreach ($x in $stale) { Write-Host "    stale authored path (target not in that quest): $x" -ForegroundColor DarkYellow }
if ($grammarFail.Count -gt 0) {
    $grammarFail | ForEach-Object { Write-Host "    GRAMMAR MISMATCH $_" -ForegroundColor Red }
    throw "path grammar cross-check failed"
}
if ($matched -eq 0) { throw "no authored path matched -- the grammar was not validated at all" }

# --- select the fireable beats -----------------------------------------------------
$positioned = @($allTriggers | Where-Object { $_.PosKind -ne 'none' })
# Warhorse's own test/debug entries (names carrying test, debug or gamescom)
# are cumulative and positioned too, but they exist for QA and trade shows,
# not for a player's story. Excluded from the fireable set, counted.
$testRx = [regex]'(?i)test|debug|gamescom'
$testOnly   = @($positioned | Where-Object { $_.Cumulative -and -not $_.Ns -and $testRx.IsMatch($_.Trigger) })
$fireable   = @($positioned | Where-Object { $_.Cumulative -and -not $_.Ns -and -not $testRx.IsMatch($_.Trigger) })
Write-Host ("  test/debug  : {0} positioned+cumulative triggers excluded by name: {1}" -f $testOnly.Count, (($testOnly | ForEach-Object { $_.Path }) -join ', '))
$wrongLevel = @($fireable | Where-Object { $_.PosLevel -and $_.PosLevel -ne $_.Level })
Write-Host ("  triggers    : {0} total; {1} positioned ({2} xyz, {3} entity); {4} cumulative; {5} namespaced; {6} fireable (positioned AND cumulative AND not namespaced)" -f `
    $allTriggers.Count, $positioned.Count, @($positioned | Where-Object PosKind -eq 'xyz').Count, @($positioned | Where-Object PosKind -eq 'ent').Count, `
    @($allTriggers | Where-Object Cumulative).Count, @($allTriggers | Where-Object Ns).Count, $fireable.Count)
if ($wrongLevel.Count -gt 0) { $wrongLevel | ForEach-Object { Write-Host "    LEVEL MISMATCH $($_.Path): playerGoto says $($_.PosLevel), quest folder says $($_.Level)" -ForegroundColor Yellow } }
$maxPath = ($allTriggers | ForEach-Object { $_.Path.Length } | Measure-Object -Maximum).Maximum
Write-Host ("  longest path: {0} chars (wire limit 128)" -f $maxPath)
if ($maxPath -gt 120) { throw "a path exceeds the 0x37 text budget" }
foreach ($t in $allTriggers) { if ($t.Path -notmatch '^[A-Za-z0-9_.]+$') { throw "path with unexpected characters: $($t.Path)" } }

Write-Host ""
Write-Host "  per quest (code name level: triggers / positioned / fireable):"
foreach ($qs in $questSummaries) {
    $qt = @($allTriggers | Where-Object Quest -eq $qs.Name)
    $qp = @($qt | Where-Object { $_.PosKind -ne 'none' }).Count
    $qf = @($fireable | Where-Object Quest -eq $qs.Name).Count
    Write-Host ("    {0,-4} {1,-26} {2,-11} {3,3} / {4,3} / {5,3}" -f $qs.Code, $qs.Name, $qs.Level, $qt.Count, $qp, $qf)
}

if ($NoWrite) { Write-Host "`n-NoWrite: nothing written." -ForegroundColor Yellow; exit 0 }

# --- CSV -------------------------------------------------------------------------
$rows = foreach ($t in $allTriggers) {
    [pscustomobject]@{
        code = $t.Code; quest = $t.Quest; level = $t.Level; path = $t.Path; trigger = $t.Trigger
        namespaced = $t.Ns; cumulative = $t.Cumulative; drivesState = $t.DrivesState
        prereqs = $t.Prereqs.Count; ownCmds = $t.Cmds.Count; nestedTriggers = $t.NestedTriggers
        posKind = $t.PosKind; posSrc = $t.PosSrc
        x = if ($t.X -ne $null) { $t.X.ToString('0.00', $inv) } else { '' }
        y = if ($t.Y -ne $null) { $t.Y.ToString('0.00', $inv) } else { '' }
        z = if ($t.Z -ne $null) { $t.Z.ToString('0.00', $inv) } else { '' }
        entity = $t.Entity; posLevel = $t.PosLevel
        fireable = ($t.PosKind -ne 'none' -and $t.Cumulative -and -not $t.Ns -and -not $testRx.IsMatch($t.Trigger))
        unresolvedArrays = ($t.Unresolved -join ';')
        file = ($t.File -replace '^Quests/Final/', '')
    }
}
$rows | Export-Csv -Path $CsvOut -NoTypeInformation -Encoding UTF8
Write-Host "`n  wrote $CsvOut ($($rows.Count) rows)"

# --- Lua block -------------------------------------------------------------------
function LuaStr([string]$s) { return '"' + ($s -replace '\\', '\\\\' -replace '"', '\"') + '"' }
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('-- @@WO94-MAINQUEST-REGISTRY-BEGIN@@')
[void]$sb.AppendLine('-- GENERATED by tools/Build-MainQuestRegistry.ps1 -- do not edit by hand.')
[void]$sb.AppendLine("-- Source: Quests/Final in Scripts.pak sha256 $pakHash")
[void]$sb.AppendLine(("-- {0} main quests (M01-M51, base game only), {1} Haste triggers, {2} positioned, {3} fireable." -f $roots.Count, $allTriggers.Count, $positioned.Count, $fireable.Count))
[void]$sb.AppendLine('-- A beat is fireable when it is positioned (proximity can see it) AND cumulative')
[void]$sb.AppendLine('-- AND not one of Warhorse''s own test/debug/gamescom entries')
[void]$sb.AppendLine('-- (it has Prerequisites or fires other triggers -- a real "set the world up for')
[void]$sb.AppendLine('-- this point" entry, not a lone setter or a bare teleport). See docs/WO-94-findings.md.')
[void]$sb.AppendLine('-- Fields: t = trigger name (fire as "<name>.<t>"); x,y,z = fixed point; e = level')
[void]$sb.AppendLine('-- entity resolved live; src = own|chain (where on the plan the position came from).')
[void]$sb.AppendLine('KCD2MP_MAINQUESTS = {')
foreach ($qs in $questSummaries) {
    $qf = @($fireable | Where-Object Quest -eq $qs.Name)
    [void]$sb.Append(("    {{ code = {0}, name = {1}, level = {2}, triggers = {3}, beats = {{" -f (LuaStr $qs.Code), (LuaStr $qs.Name), (LuaStr $qs.Level), $qs.Triggers))
    if ($qf.Count -eq 0) { [void]$sb.AppendLine(' } },'); continue }
    [void]$sb.AppendLine('')
    foreach ($t in $qf) {
        if ($t.PosKind -eq 'xyz') {
            [void]$sb.AppendLine(("        {{ t = {0}, x = {1}, y = {2}, z = {3}, src = {4} }}," -f (LuaStr $t.Trigger), $t.X.ToString('0.00', $inv), $t.Y.ToString('0.00', $inv), $t.Z.ToString('0.00', $inv), (LuaStr $t.PosSrc)))
        } else {
            [void]$sb.AppendLine(("        {{ t = {0}, e = {1}, src = {2} }}," -f (LuaStr $t.Trigger), (LuaStr $t.Entity), (LuaStr $t.PosSrc)))
        }
    }
    [void]$sb.AppendLine('    } },')
}
[void]$sb.AppendLine('}')
[void]$sb.AppendLine('-- @@WO94-MAINQUEST-REGISTRY-END@@')

$lua = Get-Content $KdcmpLua -Raw
$b = $lua.IndexOf('-- @@WO94-MAINQUEST-REGISTRY-BEGIN@@')
$e = $lua.IndexOf('-- @@WO94-MAINQUEST-REGISTRY-END@@')
if ($b -lt 0 -or $e -lt 0 -or $e -lt $b) { throw "kdcmp.lua lacks the registry markers" }
$eEnd = $lua.IndexOf("`n", $e)
if ($eEnd -lt 0) { $eEnd = $lua.Length } else { $eEnd += 1 }
$new = $lua.Substring(0, $b) + $sb.ToString().Replace("`r`n", "`n") + $lua.Substring($eEnd)
[System.IO.File]::WriteAllText($KdcmpLua, $new, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  wrote registry block into $KdcmpLua ($($fireable.Count) fireable beats)"
