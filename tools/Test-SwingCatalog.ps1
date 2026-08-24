# Test-SwingCatalog.ps1 -- WO-47 offline check of the per-weapon swing catalog.
#
# Runs `KcdMpClient.exe --dump-swing-catalog` against the real installed
# Tables.pak and asserts the mapping chain holds:
#   - the WO-46 live-proven longsword row is exactly what class 4 resolves to,
#   - the one-handed classes (sword/sabre/axe/mace/hunting sword) resolve to
#     real group-tagged rows,
#   - known ItemClass GUIDs resolve to the right weapon class, including
#     through an ItemAlias redirect.
#
# Needs the game INSTALLED, not running. Exits 0 on pass, 1 on fail.

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

$env:DOTNET_ROOT = "$env:USERPROFILE\.dotnet-sdk8"
$env:PATH = "$env:DOTNET_ROOT;$env:PATH"

Write-Host "building KcdMp.Client..."
dotnet build "$repo\dotnet\KcdMp.Client\KcdMp.Client.csproj" -v q --nologo | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL - build failed"; exit 1 }

$exe = "$repo\dotnet\KcdMp.Client\bin\Debug\net8.0\KcdMpClient.exe"
$out = & $exe --dump-swing-catalog `
    204c1852-dd30-42ae-9317-bc3123a3e301 `
    b867dd0e-1bfe-40e9-b114-4b126a3ff1b0 `
    2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { Write-Host "FAIL - dump exited $LASTEXITCODE"; Write-Host $out; exit 1 }

$failures = @()
function Assert-Contains([string]$needle, [string]$label) {
    # .Contains, not -like: the needles carry [plain]/[shield] which -like
    # would parse as wildcard character classes.
    if (-not $script:out.Contains($needle)) { $script:failures += $label }
}

# The exact row WO-45/46 live-verified must be class 4's first-choice output.
Assert-Contains 'class 4 (longsword) [plain]: FreeAttack, l_longsword+r_longsword+freeGuard+endFreeGuard+slash+attack_heavy' 'longsword slash row (WO-46 proven spec)'
Assert-Contains 'class 4 (longsword) [plain]: FreeAttack, l_longsword+r_longsword+freeGuard+endFreeGuard+stab+attack_heavy' 'longsword stab row'

# One-handed classes ride the shipped group rows.
Assert-Contains 'class 5 (mace) [plain]: FreeAttack, freeGuard+endFreeGuard+slash+attack_heavy+r_bluntWeapon' 'mace slash row (bluntWeapon group)'
Assert-Contains 'class 3 (axe) [plain]: FreeAttack, freeGuard+endFreeGuard+slash+attack_heavy+r_bluntWeapon' 'axe slash row (bluntWeapon group)'
Assert-Contains 'class 1 (sword) [plain]: FreeAttack, freeGuard+endFreeGuard+slash+attack_heavy+r_shortSwords' 'sword slash row (shortSwords group)'
Assert-Contains 'class 2 (sabre) [plain]: FreeAttack, freeGuard+endFreeGuard+stab+attack_heavy+r_shortSwords' 'sabre stab row (shortSwords group)'
Assert-Contains 'class 16 (hunting_sword) [plain]: FreeAttack, freeGuard+endFreeGuard+slash+attack_heavy+r_shortSwords' 'hunting sword slash row'
Assert-Contains 'class 1 (sword) [shield]: FreeAttack, l_shield+freeGuard+endFreeGuard+slash+attack_heavy+r_swords' 'sword+shield row (swords group)'
Assert-Contains 'class 7 (halberd) [plain]: FreeAttack, l_halberd+r_halberd+freeGuard+endFreeGuard+slash+attack_heavy' 'halberd slash row'

# ItemClass GUID -> weapon class, direct and through an ItemAlias.
Assert-Contains 'item 204c1852-dd30-42ae-9317-bc3123a3e301 -> class 4 (longsword)' 'ghost preset longsword GUID resolves to class 4'
Assert-Contains 'item b867dd0e-1bfe-40e9-b114-4b126a3ff1b0 -> class 16 (hunting_sword)' 'hunting-sword ItemAlias resolves through SourceItemId to class 16'

if ($failures.Count -gt 0) {
    Write-Host "FAIL - $($failures.Count) assertion(s):"
    $failures | ForEach-Object { Write-Host "  - $_" }
    Write-Host "--- dump output ---"
    Write-Host $out
    exit 1
}
Write-Host "PASS - swing catalog resolves all checked weapon classes from the shipped tables"
exit 0
