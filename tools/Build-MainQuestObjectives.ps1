<#
.SYNOPSIS
    WO-96: generate the main-quest OBJECTIVE registry -- for each of the 32
    main quests (M01-M51), every journal objective with its English title,
    its marker key and the path(s) of its display node inside the engine's
    ConceptState save tree -- as an embedded JSON resource for the agent
    (dotnet/KcdMp.Client/mainquest-objectives.json) and a review CSV
    (docs/WO-96-mainquest-objectives.csv).

.DESCRIPTION
    Why the save tree: every quest objective is a display view over a State
    node (WO-92 s4). The engine serialises the concept graph's node state
    into every .whs save as an XML tree (WO-92 s7 item 3), and an objective
    appears there as `_<objectiveVisualNN>/Logs/<StateName UpdateTime=.../>`
    under its module chain -- confirmed on the 2026-09-13 host's autosave009
    (docs/WO-96-findings.md s3). The agent reads the newest save after each
    questNameOverride marker and builds a per-quest fingerprint indexed by
    THIS registry; both machines must run the same registry, so the file
    carries an identity hash and the agent refuses to compare across a
    mismatch.

    Discovery reuses WO-94's method exactly (Build-MainQuestRegistry.ps1):
    the 32 <Quest ProductionCode="M.."> roots under Quests/Final, their
    <Definition File> subtree, English titles from Localization\English_xml.pak.

    The display-node path is the chain of module INSTANCE names (each node's
    Name attribute, which already carries the _1 suffix a duplicated instance
    gets) from the quest root down to the `<objectiveName Name="objectiveVisualNN">`
    element. objectiveVisual names repeat across modules (svatba reuses
    objectiveVisual5 three times), so the chain is the identity, not the name.
    An objective can be displayed by more than one node; all are kept.

.PARAMETER ScriptsPak
    Path to the Modding Tools' Data\Scripts.pak. Auto-detected when omitted.
.PARAMETER NoWrite
    Compute and report only.
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\Build-MainQuestObjectives.ps1
#>
[CmdletBinding()]
param(
    [string] $ScriptsPak = '',
    [string] $LocalizationPak = '',
    [string] $JsonOut = '',
    [string] $CsvOut = '',
    [switch] $NoWrite
)

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $toolsDir
if (-not $JsonOut) { $JsonOut = Join-Path $repoRoot 'dotnet\KcdMp.Client\mainquest-objectives.json' }
if (-not $CsvOut)  { $CsvOut  = Join-Path $repoRoot 'docs\WO-96-mainquest-objectives.csv' }

function Find-ScriptsPak {
    $steam = $null
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        try {
            $v = Get-ItemProperty -Path $k -ErrorAction Stop
            if ($v.SteamPath)   { $steam = $v.SteamPath;   break }
            if ($v.InstallPath) { $steam = $v.InstallPath; break }
        } catch { }
    }
    $rootsDirs = @()
    if ($steam) {
        $rootsDirs += $steam
        $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $rootsDirs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    foreach ($r in $rootsDirs) {
        $p = Join-Path $r 'steamapps\common\KCD2Mod\Data\Scripts.pak'
        if (Test-Path $p) { return $p }
    }
    return $null
}
if (-not $ScriptsPak) { $ScriptsPak = Find-ScriptsPak }
if (-not $ScriptsPak -or -not (Test-Path $ScriptsPak)) { throw "Scripts.pak not found; pass -ScriptsPak" }
$pakHash = (Get-FileHash -Algorithm SHA256 $ScriptsPak).Hash.ToLowerInvariant()
if (-not $LocalizationPak) {
    $cand = Join-Path (Split-Path -Parent (Split-Path -Parent $ScriptsPak)) 'Localization\English_xml.pak'
    if (Test-Path $cand) { $LocalizationPak = $cand }
}
Write-Host "=== WO-96 main-quest objective registry build ===" -ForegroundColor Cyan
Write-Host "  Scripts.pak : $ScriptsPak"
Write-Host "  sha256      : $pakHash"

# --- read Quests/Final/* --------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead($ScriptsPak)
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

# --- the 32 roots (WO-94's rule) -------------------------------------------------
$rootRx = [regex]'<Quest\s[^>]*\bProductionCode="(M[0-9]+[a-z]?)"[^>]*>'
$nameRx = [regex]'\bName="([^"]+)"'
$roots = @()
foreach ($kv in $files.GetEnumerator()) {
    $m = $rootRx.Match($kv.Value)
    if (-not $m.Success) { continue }
    $nm = $nameRx.Match($m.Value)
    $dir = $kv.Key.Substring(0, $kv.Key.LastIndexOf('/'))
    $level = ($dir -split '/')[-1]
    if ($level -notin @('trosecko', 'kutnohorsko')) { throw "unexpected level folder '$level' for $($kv.Key)" }
    $qk = [regex]::Match($kv.Value, 'qname_[A-Za-z0-9_]+')
    if (-not $qk.Success) { throw "M-coded root without a qname_ literal: $($kv.Key)" }
    $qstem = ($qk.Value -replace '^qname_', '')
    if ($qstem -match '_[A-Za-z0-9]{4}$') { $qstem = $qstem.Substring(0, $qstem.Length - 5) }
    $qstem = $qstem.Trim('_').ToLowerInvariant()
    $roots += [pscustomobject]@{ Code = $m.Groups[1].Value; Name = $nm.Groups[1].Value; File = $kv.Key; Dir = $dir; Level = $level; QKey = $qk.Value; Key = $qstem; Title = '' }
}
$roots = @($roots | Sort-Object { [int]($_.Code -replace '[^0-9]', '') }, Code)
if ($roots.Count -ne 32) { throw "expected exactly 32 main quests, found $($roots.Count)" }

# --- English strings (quest titles AND objective titles live in text_ui_quest.xml) ---
$english = @{}
if ($LocalizationPak -and (Test-Path $LocalizationPak)) {
    $lz = [System.IO.Compression.ZipFile]::OpenRead($LocalizationPak)
    try {
        $le = $lz.Entries | Where-Object { $_.FullName -match 'text_ui_quest\.xml$' } | Select-Object -First 1
        if ($le) {
            $sr = New-Object System.IO.StreamReader ($le.Open())
            try { $lx = $sr.ReadToEnd() } finally { $sr.Dispose() }
            foreach ($rm in [regex]::Matches($lx, '<Row>(.*?)</Row>', 'Singleline')) {
                $cells = @([regex]::Matches($rm.Groups[1].Value, '<Cell>(.*?)</Cell>', 'Singleline') | ForEach-Object { $_.Groups[1].Value })
                if ($cells.Count -ge 2) { $english[$cells[0]] = [System.Net.WebUtility]::HtmlDecode($cells[$cells.Count - 1]) }
            }
            Write-Host ("  english     : {0} rows from {1}" -f $english.Count, $LocalizationPak)
        }
    } finally { $lz.Dispose() }
} else { Write-Host "  english     : English_xml.pak not found; labels will be the internal names" -ForegroundColor Yellow }
foreach ($q in $roots) { if ($english.ContainsKey($q.QKey)) { $q.Title = $english[$q.QKey] } }

# --- helpers --------------------------------------------------------------------
function Load-Xml([string]$text) {
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $false
    if ($text.Length -gt 0 -and [int]$text[0] -eq 0xFEFF) { $text = $text.Substring(1) }
    $doc.LoadXml($text)
    return $doc
}
function Collect-Subtree($root) {
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $order = New-Object System.Collections.ArrayList
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($root.File); [void]$seen.Add($root.File)
    while ($queue.Count -gt 0) {
        $f = $queue.Dequeue()
        [void]$order.Add($f)
        if (-not $files.ContainsKey($f)) { Write-Warning "definition not in pak: $f"; continue }
        $dir = $f.Substring(0, $f.LastIndexOf('/'))
        foreach ($m in [regex]::Matches($files[$f], '<Definition\s+File="([^"]+)"')) {
            $child = "$dir/" + ($m.Groups[1].Value -replace '\\', '/')
            if ($seen.Add($child)) { $queue.Enqueue($child) }
        }
    }
    return @($order)
}
function Get-DefinitionRoot([System.Xml.XmlDocument]$doc) {
    $skald = $doc.DocumentElement.SelectSingleNode('Skald')
    if (-not $skald) { return $null }
    foreach ($c in $skald.ChildNodes) { if ($c.NodeType -eq 'Element') { return $c } }
    return $null
}

# --- walk every quest ---------------------------------------------------------------
$questsOut = New-Object System.Collections.ArrayList
$rows = New-Object System.Collections.ArrayList
$totalObj = 0; $totalWithNode = 0; $totalNodes = 0; $totalTitled = 0; $maxPaths = 0

foreach ($q in $roots) {
    $sub = Collect-Subtree $q
    $docs = @{}
    foreach ($f in $sub) { if ($files.ContainsKey($f)) { $docs[$f] = Load-Xml $files[$f] } }
    # Type resolution is PER FILE: a node <foo Name="x"> inside file F is an
    # instance of the definition F declares with <Definition File="…/foo.xml">.
    # A global type map is wrong here -- socky.xml (the quest) and
    # socky/socky.xml (a sub-module) are both named "socky", and ten more
    # socky types are defined twice at different depths; resolving globally
    # made the quest root instantiate itself (socky.socky.socky…).
    $defOfFile = @{}          # file -> definition element
    $declared  = @{}          # file -> @{ typeName -> child file }
    foreach ($f in $sub) {
        $d = $docs[$f]; if (-not $d) { continue }
        $def = Get-DefinitionRoot $d
        if ($def) { $defOfFile[$f] = $def }
        $dir = $f.Substring(0, $f.LastIndexOf('/'))
        $map = @{}
        foreach ($m in [regex]::Matches($files[$f], '<Definition\s+File="([^"]+)"')) {
            $child = "$dir/" + ($m.Groups[1].Value -replace '\\', '/')
            if ($docs.ContainsKey($child) -and $defOfFile.ContainsKey($child) -or ($docs.ContainsKey($child) -and (Get-DefinitionRoot $docs[$child]))) {
                $cd = if ($defOfFile.ContainsKey($child)) { $defOfFile[$child] } else { Get-DefinitionRoot $docs[$child] }
                if ($cd) { $defOfFile[$child] = $cd; $map[[string]$cd.GetAttribute('Name')] = $child }
            }
        }
        $declared[$f] = $map
    }
    $rootDoc = $docs[$q.File]
    $questEl = Get-DefinitionRoot $rootDoc
    if (-not $questEl -or $questEl.LocalName -ne 'Quest') { throw "root definition of $($q.Name) is not <Quest>" }

    # objectives, in document order
    $objectives = New-Object System.Collections.ArrayList
    $objIndex = @{}
    foreach ($o in $questEl.SelectNodes('Objectives/Objective')) {
        $on = [string]$o.GetAttribute('Name')
        if (-not $on -or $objIndex.ContainsKey($on)) { continue }
        $ln = $o.SelectSingleNode('LocalizedName')
        $sn = if ($ln) { [string]$ln.GetAttribute('StringName') } else { '' }
        $cz = if ($ln) { [string]$ln.GetAttribute('Text') } else { '' }
        $en = if ($sn -and $english.ContainsKey($sn)) { $english[$sn] } else { '' }
        $rec = [pscustomobject]@{
            n = $on; k = $sn; t = $en; cz = $cz
            type = [string]$o.GetAttribute('TypeT')
            optional = (([string]$o.GetAttribute('IsOptional')) -eq 'true')
            paths = New-Object System.Collections.ArrayList
        }
        [void]$objectives.Add($rec); $objIndex[$on] = $rec
    }

    # instance walk: quest root Nodes -> submodule instances -> objective display nodes
    $visited = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    function Walk-Instances([string]$file, [string]$path, [int]$depth) {
        if ($depth -gt 24) { Write-Warning "instance chain deeper than 24 at $path"; return }
        $el = $defOfFile[$file]
        if (-not $el) { return }
        $nodes = $el.SelectSingleNode('Nodes')
        if (-not $nodes) { return }
        $local = $declared[$file]
        foreach ($c in $nodes.ChildNodes) {
            if ($c.NodeType -ne 'Element') { continue }
            $tag = $c.LocalName
            $nm = [string]$c.GetAttribute('Name')
            if (-not $nm) { continue }
            $p = if ($path) { "$path.$nm" } else { $nm }
            if ($objIndex.ContainsKey($tag)) {
                if (-not $objIndex[$tag].paths.Contains($p)) { [void]$objIndex[$tag].paths.Add($p) }
                continue
            }
            # library modules (Namespace="utils.…") live outside the quest and carry no objectives
            if ($c.HasAttribute('Namespace')) { continue }
            if ($local -and $local.ContainsKey($tag)) {
                $childFile = $local[$tag]
                if ($visited.Add("$childFile|$p")) { Walk-Instances $childFile $p ($depth + 1) }
            }
        }
    }
    Walk-Instances $q.File '' 0

    $withNode = @($objectives | Where-Object { $_.paths.Count -gt 0 }).Count
    $nodes = ($objectives | ForEach-Object { $_.paths.Count } | Measure-Object -Sum).Sum
    $titled = @($objectives | Where-Object { $_.t }).Count
    $mp = ($objectives | ForEach-Object { $_.paths.Count } | Measure-Object -Maximum).Maximum
    if ($mp -gt $maxPaths) { $maxPaths = $mp }
    $totalObj += $objectives.Count; $totalWithNode += $withNode; $totalNodes += $nodes; $totalTitled += $titled
    Write-Host ("    {0,-4} {1,-26} {2,-11} objectives {3,3}  with display node {4,3}  nodes {5,3}  titled {6,3}" -f $q.Code, $q.Name, $q.Level, $objectives.Count, $withNode, $nodes, $titled)

    [void]$questsOut.Add([ordered]@{
        code = $q.Code; name = $q.Name; key = $q.Key; level = $q.Level; title = $q.Title
        objectives = @($objectives | ForEach-Object { [ordered]@{ n = $_.n; k = $_.k; t = $_.t; optional = $_.optional; paths = @($_.paths) } })
    })
    $i = 0
    foreach ($o in $objectives) {
        [void]$rows.Add([pscustomobject]@{
            code = $q.Code; quest = $q.Name; markerKey = $q.Key; index = $i; objective = $o.n; type = $o.type; optional = $o.optional
            stringName = $o.k; english = $o.t; czech = $o.cz; displayNodes = $o.paths.Count; paths = ($o.paths -join ';')
        })
        $i++
    }
}

# --- identity: what both agents must agree on to compare fingerprints -------------
$canon = New-Object System.Text.StringBuilder
foreach ($qo in $questsOut) {
    [void]$canon.Append($qo.code).Append('|').Append($qo.name).Append('|').Append($qo.key).Append('|').Append($qo.level).Append("`n")
    foreach ($o in $qo.objectives) { [void]$canon.Append('  ').Append($o.n).Append('|').Append(($o.paths -join ',')).Append("`n") }
}
$sha = [System.Security.Cryptography.SHA256]::Create()
$idBytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon.ToString()))
$regId = (($idBytes[0..5] | ForEach-Object { $_.ToString('x2') }) -join '')
Write-Host ""
Write-Host ("  total       : {0} objectives in 32 quests; {1} have a display node ({2} nodes, max {3} per objective); {4} English-titled; registry id {5}" -f $totalObj, $totalWithNode, $totalNodes, $maxPaths, $totalTitled, $regId)
$maxObj = ($questsOut | ForEach-Object { $_.objectives.Count } | Measure-Object -Maximum).Maximum
Write-Host ("  largest     : {0} objectives in one quest -> {1} fingerprint bytes at 2 bits each (wire text budget 128)" -f $maxObj, [math]::Ceiling($maxObj * 2 / 8))
if ($maxObj -gt 200) { throw "a quest has more objectives than the fingerprint can carry" }

if ($NoWrite) { Write-Host "`n-NoWrite: nothing written." -ForegroundColor Yellow; exit 0 }

$out = [ordered]@{
    id = $regId
    pak = $pakHash
    note = 'GENERATED by tools/Build-MainQuestObjectives.ps1 (WO-96) -- do not edit by hand. Both agents must carry the same id to compare story fingerprints.'
    quests = @($questsOut)
}
$json = $out | ConvertTo-Json -Depth 6 -Compress:$false
[System.IO.File]::WriteAllText($JsonOut, $json, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  wrote $JsonOut"
$rows | Export-Csv -Path $CsvOut -NoTypeInformation -Encoding UTF8
Write-Host "  wrote $CsvOut ($($rows.Count) rows)"
