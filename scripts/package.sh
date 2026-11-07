#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(sed -n 's/^## Version:[[:space:]]*//p' OpenMargin.toc | head -n1)"
VERSION="${VERSION:-0.0.0}"
STAGE="$ROOT/dist/stage"
OUT="$ROOT/dist/OpenMargin-${VERSION}.zip"

rm -rf "$ROOT/dist"
mkdir -p "$STAGE/OpenMargin"

cp OpenMargin.toc ./*.lua README.md LICENSE "$STAGE/OpenMargin/"

if command -v zip >/dev/null 2>&1; then
	(cd "$STAGE" && zip -q -r "$OUT" OpenMargin)
else
	python3 - "$STAGE" "$OUT" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, _, files in os.walk(stage):
        for name in files:
            path = os.path.join(root, name)
            archive.write(path, os.path.relpath(path, stage))
PY
fi

echo "Built $OUT"
