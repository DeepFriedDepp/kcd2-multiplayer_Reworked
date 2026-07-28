# Bounded client for the KCD2 debug REST API (Modding Tools build, localhost:1403).
#
# Dot-source this: . tools\KcdApi.ps1
#
# Why bounded: the API is a reflection browser, and a container read without
# ?depth= serialises the whole object graph. GET /api/rpg/SoulList/SoulsByName
# with no depth returned 658 MB. Every read here is capped and aborts the stream.

$script:KcdApiBase = "http://localhost:1403"

function Invoke-KcdApi {
    <#
    .SYNOPSIS Read an API path, never accepting more than MaxBytes.
    .EXAMPLE  Invoke-KcdApi -Path "/api/rpg?info"
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [int]$MaxBytes = 262144,
        [int]$TimeoutSec = 60
    )
    $req = [Net.HttpWebRequest]::Create("$($script:KcdApiBase)$Path")
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    try {
        $resp = $req.GetResponse()
    } catch [Net.WebException] {
        $r = $_.Exception.Response
        if ($r) {
            $sr = New-Object IO.StreamReader($r.GetResponseStream())
            return "ERR $([int]$r.StatusCode) $($sr.ReadToEnd())"
        }
        return "ERR $($_.Exception.Message)"
    }
    $stream = $resp.GetResponseStream()
    $buf = New-Object byte[] 65536
    $ms  = New-Object IO.MemoryStream
    $total = 0
    while ($total -lt $MaxBytes) {
        $n = $stream.Read($buf, 0, [Math]::Min($buf.Length, $MaxBytes - $total))
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $total += $n
    }
    $stream.Close(); $resp.Close()
    [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Get-KcdValue {
    <#
    .SYNOPSIS Read a scalar, stripping the XML wrapper element.
    .DESCRIPTION Returns '(empty)' for a void method invocation, which is what a
                 successful SetState/TakeDamage looks like. A void return is NOT
                 evidence the call did anything -- read the state back.
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $c = Invoke-KcdApi -Path $Path -MaxBytes 8192
    if ($c -match '^ERR') { return $c }
    if ($c -match '>([^<]*)<') { return $Matches[1] }
    return '(empty)'
}

function Test-KcdApi {
    <#  .SYNOPSIS True if the game is up and the debug API answers.  #>
    $v = Get-KcdValue "/api/rpg/SoulList/SoulCount"
    return ($v -notmatch '^ERR')
}

function Get-KcdSoulSnapshot {
    <#
    .SYNOPSIS One-round-trip presence snapshot of every loaded soul.
    .DESCRIPTION Name, both GUIDs and position for all souls, with the heavy
                 subtrees excluded. Roughly 4 s and >20 MB on a loaded save, so
                 this is a reconciliation tool, not a per-frame read.
    #>
    param([int]$MaxBytes = 20000000)
    $exclude = "DerivedStatsByName,Buffs,Roles,StaticData,PersistentData,Archetype," +
               "Inventory,CombatSoul,CompanionManager,EquipmentManager,FactionNode," +
               "SoulClass,SocialClass,StormDebug"
    $xml = Invoke-KcdApi -Path "/api/rpg/SoulList/SoulsByName?depth=1&exclude=$exclude" -MaxBytes $MaxBytes
    $rx = [regex]'Name="([^"]+)" Guid="([^"]+)" SharedSoulGuid="([^"]+)" Position="([^"]+)"'
    foreach ($m in $rx.Matches($xml)) {
        [pscustomobject]@{
            Name           = $m.Groups[1].Value
            Guid           = $m.Groups[2].Value
            SharedSoulGuid = $m.Groups[3].Value
            Position       = $m.Groups[4].Value
        }
    }
}
