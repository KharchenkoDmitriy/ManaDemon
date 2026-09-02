#!/usr/bin/env bash
# Build a ready-to-copy release of ManaDemon.
#
#   ./release.sh                  -> dist/ManaDemon/  +  dist/ManaDemon-<version>.zip
#   ./release.sh /path/to/AddOns  -> also copies dist/ManaDemon into that folder
#   WOW_ADDONS=/path ./release.sh -> same, via environment variable
#
# The file list comes from ManaDemon.toc itself, so the release can never drift
# from what the game actually loads. Dev files (docs/, CLAUDE.md, .git, this
# script) are excluded by construction.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOC="$ROOT/ManaDemon.toc"
DIST="$ROOT/dist"
OUT="$DIST/ManaDemon"

[[ -f "$TOC" ]] || { echo "ERROR: ManaDemon.toc not found next to release.sh" >&2; exit 1; }

VERSION="$(sed -n 's/^## Version:[[:space:]]*//p' "$TOC" | tr -d '\r')"
[[ -n "$VERSION" ]] || { echo "ERROR: no '## Version:' line in ManaDemon.toc" >&2; exit 1; }

# Collect files: the .toc itself, every load entry in it, plus README.md.
files=("ManaDemon.toc" "README.md")
while IFS= read -r line; do
    line="${line%$'\r'}"                      # strip CR (the .toc may be CRLF)
    [[ -z "$line" || "$line" == \#* ]] && continue
    files+=("${line//\\//}")                  # .toc uses backslashes; use / on disk
done < "$TOC"

# Verify everything exists before touching dist/.
missing=0
for f in "${files[@]}"; do
    if [[ ! -f "$ROOT/$f" ]]; then
        echo "ERROR: $f is listed in the .toc but missing on disk" >&2
        missing=1
    fi
done
[[ $missing -eq 0 ]] || exit 1

rm -rf "$OUT"
mkdir -p "$OUT"
for f in "${files[@]}"; do
    mkdir -p "$OUT/$(dirname "$f")"
    cp "$ROOT/$f" "$OUT/$f"
done

echo "Built dist/ManaDemon (v$VERSION, ${#files[@]} files)."

# Zip (zip if available, python3 zipfile as fallback).
ZIP="$DIST/ManaDemon-$VERSION.zip"
rm -f "$ZIP"
if command -v zip >/dev/null 2>&1; then
    (cd "$DIST" && zip -qr "$(basename "$ZIP")" ManaDemon)
    echo "Built dist/ManaDemon-$VERSION.zip"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$DIST" "$ZIP" <<'PYEOF'
import os, sys, zipfile
dist, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for base, _, names in os.walk(os.path.join(dist, "ManaDemon")):
        for name in names:
            path = os.path.join(base, name)
            z.write(path, os.path.relpath(path, dist))
print("Built dist/" + os.path.basename(out))
PYEOF
else
    echo "NOTE: neither zip nor python3 found — skipped the zip archive."
fi

# Optional: copy into the game's AddOns folder.
TARGET="${1:-${WOW_ADDONS:-}}"
if [[ -n "$TARGET" ]]; then
    [[ -d "$TARGET" ]] || { echo "ERROR: AddOns folder not found: $TARGET" >&2; exit 1; }
    rm -rf "$TARGET/ManaDemon"
    cp -r "$OUT" "$TARGET/ManaDemon"
    echo "Installed into $TARGET/ManaDemon"
else
    echo "Copy dist/ManaDemon into your game's Interface/AddOns folder"
    echo "(or run: ./release.sh \"/mnt/c/Program Files (x86)/World of Warcraft/_anniversary_/Interface/AddOns\")"
fi
