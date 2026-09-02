#!/usr/bin/env bash
# Build a ready-to-copy release of ManaDemon from the main checkout or any
# git worktree, into the TOP-LEVEL dist/ grouped by source:
#
#   dist/<name>/ManaDemon/                 <name> = "main" or the worktree folder
#   dist/<name>/ManaDemon-<version>.zip
#
#   ./release.sh                     build the checkout this script lives in
#   ./release.sh --menu              pick the source interactively (make release)
#   ./release.sh --src NAME|DIR      build a named worktree ("main", "feedback-round-3")
#                                    or any directory containing ManaDemon.toc
#   ./release.sh --list              show the available sources
#   ./release.sh --out DIR           override the output folder
#   ./release.sh --install DIR       also copy ManaDemon/ into that AddOns folder
#   ./release.sh /path/to/AddOns     same (legacy positional form); WOW_ADDONS env too
#
# The file list comes from ManaDemon.toc itself, so the release can never drift
# from what the game actually loads. Dev files (docs/, CLAUDE.md, Makefile,
# .git, this script) are excluded by construction.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Repo root = the main checkout, even when run from inside a worktree.
if COMMON="$(git -C "$HERE" rev-parse --git-common-dir 2>/dev/null)"; then
    [[ "$COMMON" = /* ]] || COMMON="$HERE/$COMMON"
    ROOT="$(cd "$COMMON/.." && pwd)"
else
    ROOT="$HERE"
fi

# name<TAB>path<TAB>branch, main checkout first.
list_sources() {
    if git -C "$ROOT" worktree list --porcelain >/dev/null 2>&1; then
        local path="" branch=""
        while IFS= read -r line; do
            case "$line" in
                "worktree "*) path="${line#worktree }" ;;
                "branch "*)   branch="${line#branch refs/heads/}" ;;
                "")
                    if [[ -n "$path" ]]; then
                        local name="$(basename "$path")"
                        [[ "$path" == "$ROOT" ]] && name="main"
                        printf '%s\t%s\t%s\n' "$name" "$path" "${branch:-detached}"
                    fi
                    path="" branch=""
                    ;;
            esac
        done < <(git -C "$ROOT" worktree list --porcelain; echo)
    else
        printf 'main\t%s\t-\n' "$ROOT"
    fi
}

resolve_source() {
    local want="$1"
    if [[ -d "$want" && -f "$want/ManaDemon.toc" ]]; then
        cd "$want" && pwd
        return
    fi
    while IFS=$'\t' read -r name path _; do
        if [[ "$name" == "$want" ]]; then echo "$path"; return; fi
    done < <(list_sources)
    echo "ERROR: unknown source '$want' (try --list)" >&2
    exit 1
}

version_of() {
    sed -n 's/^## Version:[[:space:]]*//p' "$1/ManaDemon.toc" 2>/dev/null | tr -d '\r'
}

show_sources() {
    local i=0
    while IFS=$'\t' read -r name path branch; do
        i=$((i + 1))
        printf '  %d) %-22s v%-7s %s  (%s)\n' "$i" "$name" "$(version_of "$path")" "$branch" "$path"
    done < <(list_sources)
}

menu() {
    echo "Build a release from:" >&2
    show_sources >&2
    local choice
    read -rp "Choice [1]: " choice
    choice="${choice:-1}"
    local i=0
    while IFS=$'\t' read -r name path _; do
        i=$((i + 1))
        if [[ "$choice" == "$i" || "$choice" == "$name" ]]; then echo "$path"; return; fi
    done < <(list_sources)
    resolve_source "$choice"
}

SRC="" OUT="" TARGET="${WOW_ADDONS:-}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)      SRC="$2"; shift 2 ;;
        --out)      OUT="$2"; shift 2 ;;
        --install)  TARGET="$2"; shift 2 ;;
        --menu)     SRC="$(menu)"; shift ;;
        --list)     show_sources; exit 0 ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *)          TARGET="$1"; shift ;;
    esac
done

if [[ -z "$SRC" ]]; then
    SRC="$HERE"
else
    SRC="$(resolve_source "$SRC")"
fi
TOC="$SRC/ManaDemon.toc"
[[ -f "$TOC" ]] || { echo "ERROR: ManaDemon.toc not found in $SRC" >&2; exit 1; }

NAME="$(basename "$SRC")"
[[ "$SRC" == "$ROOT" ]] && NAME="main"
[[ -n "$OUT" ]] || OUT="$ROOT/dist/$NAME"
PKG="$OUT/ManaDemon"

VERSION="$(version_of "$SRC")"
[[ -n "$VERSION" ]] || { echo "ERROR: no '## Version:' line in ManaDemon.toc" >&2; exit 1; }

# Collect files: the .toc itself, every load entry in it, plus README.md.
files=("ManaDemon.toc" "README.md")
while IFS= read -r line; do
    line="${line%$'\r'}"                      # strip CR (the .toc may be CRLF)
    [[ -z "$line" || "$line" == \#* ]] && continue
    files+=("${line//\\//}")                  # .toc uses backslashes; use / on disk
done < "$TOC"

# Verify everything exists before touching the output.
missing=0
for f in "${files[@]}"; do
    if [[ ! -f "$SRC/$f" ]]; then
        echo "ERROR: $f is listed in the .toc but missing on disk" >&2
        missing=1
    fi
done
[[ $missing -eq 0 ]] || exit 1

rm -rf "$PKG"
mkdir -p "$PKG"
for f in "${files[@]}"; do
    mkdir -p "$PKG/$(dirname "$f")"
    cp "$SRC/$f" "$PKG/$f"
done

REL="${OUT#$ROOT/}"
echo "Built $REL/ManaDemon (v$VERSION, ${#files[@]} files) from $NAME."

# Zip (zip if available, python3 zipfile as fallback).
ZIP="$OUT/ManaDemon-$VERSION.zip"
rm -f "$ZIP"
if command -v zip >/dev/null 2>&1; then
    (cd "$OUT" && zip -qr "$(basename "$ZIP")" ManaDemon)
    echo "Built $REL/ManaDemon-$VERSION.zip"
elif command -v python3 >/dev/null 2>&1; then
    python3 - "$OUT" "$ZIP" "$REL" <<'PYEOF'
import os, sys, zipfile
out_dir, out, rel = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for base, _, names in os.walk(os.path.join(out_dir, "ManaDemon")):
        for name in names:
            path = os.path.join(base, name)
            z.write(path, os.path.relpath(path, out_dir))
print("Built " + rel + "/" + os.path.basename(out))
PYEOF
else
    echo "NOTE: neither zip nor python3 found — skipped the zip archive."
fi

# Optional: copy into the game's AddOns folder.
if [[ -n "$TARGET" ]]; then
    [[ -d "$TARGET" ]] || { echo "ERROR: AddOns folder not found: $TARGET" >&2; exit 1; }
    rm -rf "$TARGET/ManaDemon"
    cp -r "$PKG" "$TARGET/ManaDemon"
    echo "Installed into $TARGET/ManaDemon"
else
    echo "Copy $REL/ManaDemon into your game's Interface/AddOns folder"
    echo "(or: make install WOW_ADDONS=\"/mnt/c/Program Files (x86)/World of Warcraft/_anniversary_/Interface/AddOns\")"
fi
