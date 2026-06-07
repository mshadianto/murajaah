#!/usr/bin/env bash
# bootstrap.sh — generate build artefacts from canonical sources.
# Run once after fresh clone, or whenever quran-uthmani.xml updates.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
XML="$REPO_ROOT/quran-uthmani.xml"
ASSET_DIR="$REPO_ROOT/murojaah_app/murojaah_app/assets"
DB_OUT="$ASSET_DIR/quran.db"
PIPELINE="$REPO_ROOT/murojaah_complete/murojaah_complete/data_pipeline"

if [ ! -f "$XML" ]; then
  echo "ERROR: $XML not found"; exit 1
fi

mkdir -p "$ASSET_DIR"

echo "→ Verifying Python normalizer parity..."
python -X utf8 "$PIPELINE/normalizer.py"

echo "→ Building quran.db from $XML..."
python -X utf8 "$PIPELINE/build_quran_db.py" "$XML" -o "$DB_OUT"

echo "✓ Bootstrap complete: $DB_OUT"
