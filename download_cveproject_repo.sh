#!/usr/bin/env bash
set -euo pipefail

# download_cveproject_repo.sh
# Clones the CVEProject/CVEProject repository into a dated folder named
# cve_vulnrichment_YYYY-MM-DD (UTC date). By default performs a shallow clone
# (depth=1) to save time and space. Set FULL_CLONE=1 to perform a full clone.

DEST_BASE=${DEST_BASE:-"./cve_vulnrichment"}
TARGET_DIR="$DEST_BASE/cves"
TMP_DIR="${DEST_BASE}/cves_tmp_$(date +%s)"
SVN_EXPORT_URL=${SVN_EXPORT_URL:-"https://github.com/CVEProject/cvelistV5/trunk/cves"}

mkdir -p "$DEST_BASE"

echo "Fetching 'cves' folder from cvelistV5 into $TARGET_DIR"

# Try svn export of the specific folder first (no .git metadata)
if command -v svn >/dev/null 2>&1; then
    echo "Using svn export from $SVN_EXPORT_URL -> $TMP_DIR"
    rm -rf "$TMP_DIR"
    svn export --force "$SVN_EXPORT_URL" "$TMP_DIR"
    echo "Exported to $TMP_DIR"
else
    # Fallback to git sparse-checkout (requires git 2.25+)
    echo "svn not found; using git sparse-checkout fallback"
    if ! command -v git >/dev/null 2>&1; then
        echo "Neither svn nor git available. Cannot fetch 'cves' folder." >&2
        exit 2
    fi
    GIT_TMP="$DEST_BASE/cvelistV5_tmp_$(date +%s)"
    rm -rf "$GIT_TMP" "$TMP_DIR"
    git clone --depth 1 --filter=blob:none --sparse https://github.com/CVEProject/cvelistV5.git "$GIT_TMP"
    pushd "$GIT_TMP" >/dev/null
    git sparse-checkout set cves
    popd >/dev/null
    mv "$GIT_TMP/cves" "$TMP_DIR"
    rm -rf "$GIT_TMP"
    echo "Sparse checkout placed cves into $TMP_DIR"
fi

# Atomically move into final location (use .part then move into place)
rm -rf "$TARGET_DIR.part" || true
rm -rf "$TARGET_DIR" || true
mv "$TMP_DIR" "$TARGET_DIR.part"
mv -T "$TARGET_DIR.part" "$TARGET_DIR"
echo "'cves' folder is now available at $TARGET_DIR"

echo "Done."

# Wait briefly to let any file operations settle
echo "Sleeping 5s before creating events file..."
sleep 5

# Create one-line-per-json events file named cve_vulnrichment-YYYY-MM-DD.txt
DATE=$(date -u +%F)
EVENTS_OUT="$DEST_BASE/cve_vulnrichment-${DATE}.txt"
EVENTS_OUT_PART="$EVENTS_OUT.part"

if [ ! -d "$TARGET_DIR" ]; then
        echo "Expected folder $TARGET_DIR not found; skipping events file creation." >&2
        exit 0
fi

echo "Creating events file: $EVENTS_OUT"
rm -f "$EVENTS_OUT_PART"

if command -v jq >/dev/null 2>&1; then
    # Use a safe while-read loop to handle arbitrary filenames
    find "$TARGET_DIR" -type f -name '*.json' -print0 | while IFS= read -r -d '' file; do
        jq -c . "$file" >> "$EVENTS_OUT_PART" || echo "Warning: failed to process $file" >&2
    done
else
    find "$TARGET_DIR" -type f -name '*.json' -print0 | while IFS= read -r -d '' file; do
        python3 -c 'import sys, json; print(json.dumps(json.load(open(sys.argv[1]))))' "$file" >> "$EVENTS_OUT_PART" || echo "Warning: failed to process $file" >&2
    done
fi

mv "$EVENTS_OUT_PART" "$EVENTS_OUT"

COUNT=$(wc -l < "$EVENTS_OUT" || true)
echo "Wrote $COUNT events to $EVENTS_OUT"

exit 0
