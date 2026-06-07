# bootstrap.ps1 — generate build artefacts from canonical sources.
# Run once after fresh clone, or whenever quran-uthmani.xml updates.

$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path "$PSScriptRoot\..").Path
$Xml      = Join-Path $RepoRoot "quran-uthmani.xml"
$AssetDir = Join-Path $RepoRoot "murojaah_app\murojaah_app\assets"
$DbOut    = Join-Path $AssetDir "quran.db"
$Pipeline = Join-Path $RepoRoot "murojaah_complete\murojaah_complete\data_pipeline"

if (-not (Test-Path $Xml)) {
  Write-Error "ERROR: $Xml not found"; exit 1
}

if (-not (Test-Path $AssetDir)) { New-Item -ItemType Directory -Path $AssetDir | Out-Null }

Write-Host "-> Verifying Python normalizer parity..."
python -X utf8 (Join-Path $Pipeline "normalizer.py")

Write-Host "-> Building quran.db from $Xml..."
python -X utf8 (Join-Path $Pipeline "build_quran_db.py") $Xml -o $DbOut

Write-Host "OK Bootstrap complete: $DbOut"
