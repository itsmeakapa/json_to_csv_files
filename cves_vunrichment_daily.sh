#!/usr/bin/env bash
set -euo pipefail

# cves_vunrichment_daily.sh
# Exports the 'cves' folder from the CVEProject cvelistV5 trunk using svn
# Default operation: export yesterday's state into ./cves_downloads/latest
#
# Usage:
#   ./cves_vunrichment_daily.sh
#   ./cves_vunrichment_daily.sh --no-svn-fallback  # fail if svn not available

DEST_DIR=${DEST_DIR:-"./cves_vulnrichment"}
KEEP_ONLY_LATEST=${KEEP_ONLY_LATEST:-1}
SVN_URL="https://github.com/CVEProject/cvelistV5/trunk/cves"
DATE=$(date -u +%F)
TMP_DIR="${DEST_DIR}/cves_tmp_$(date +%s)"
DATED_DIR="${DEST_DIR}/cves_${DATE}"
FINAL_LINK="${DEST_DIR}/cves_latest"

mkdir -p "$DEST_DIR"

echo "Starting export from $SVN_URL"

if command -v svn >/dev/null 2>&1; then
    echo "Using svn to export..."
    rm -rf "$TMP_DIR"
    svn export --force "$SVN_URL" "$TMP_DIR"
    echo "Exported to $TMP_DIR"
else
    echo "svn not found. Attempting git sparse-checkout fallback..."
    if command -v git >/dev/null 2>&1; then
        GIT_TMP="$DEST_DIR/cvelistV5_tmp_$(date +%s)"
        rm -rf "$GIT_TMP"
        git clone --depth 1 --filter=blob:none --sparse https://github.com/CVEProject/cvelistV5.git "$GIT_TMP"
        pushd "$GIT_TMP" >/dev/null
        git sparse-checkout set cves
        popd >/dev/null
        mv "$GIT_TMP/cves" "$TMP_DIR"
        rm -rf "$GIT_TMP"
    else
        echo "Neither svn nor git available. Cannot fetch repository." >&2
        exit 1
    fi
fi

# Atomically move into dated directory then update symlink
rm -rf "$DATED_DIR" "$FINAL_LINK.part" || true
mv "$TMP_DIR" "$DATED_DIR"
ln -sfn "$DATED_DIR" "$FINAL_LINK.part"
mv -T "$FINAL_LINK.part" "$FINAL_LINK"
echo "CVE cves folder exported into $DATED_DIR (symlinked as $FINAL_LINK)"

if [ "$KEEP_ONLY_LATEST" -eq 1 ]; then
    # Remove any older dated directories other than the current one
    for d in "$DEST_DIR"/cves_*; do
        # If glob didn't match, skip
        [ -e "$d" ] || continue
        # Skip the current dated dir
        if [ "$d" = "$DATED_DIR" ]; then
            continue
        fi
        # Only remove directories named cves_YYYY-MM-DD
        if [ -d "$d" ]; then
            rm -rf "$d"
        fi
    done
fi

echo "Done."

exit 0
