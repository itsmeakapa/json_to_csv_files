#!/usr/bin/env bash
set -euo pipefail

# download_epss_daily.sh
# Downloads EPSS daily file epss_scores-YYYY-MM-DD.csv.gz from
# https://epss.empiricalsecurity.com/ and extracts it to a .csv file.
#
# Usage:
#   ./download_epss_daily.sh            # downloads today's file
#   ./download_epss_daily.sh 2025-10-03 # download a specific date
#
# Environment variables (optional):
#   EPSS_DOWNLOAD_DIR  - directory to store downloads (default: ./epss)
#   EPSS_KEEP_DAYS     - how many days to keep (default: 14). Set 0 to keep all.

# By default download yesterday's file (the EPSS provider usually publishes the previous day's file)
DATE=${1:-$(date -d 'yesterday' +%F)}
EPSS_DOWNLOAD_DIR=${EPSS_DOWNLOAD_DIR:-"./epss"}
EPSS_KEEP_DAYS=${EPSS_KEEP_DAYS:-14}
# When KEEP_ONLY_LATEST=1, remove all other epss_scores-YYYY-MM-DD.csv* files and keep only the
# requested date's .csv.gz and .csv. Default: 1 (keep only latest).
KEEP_ONLY_LATEST=${KEEP_ONLY_LATEST:-1}

BASE_URL="https://epss.empiricalsecurity.com"
FILENAME="epss_scores-${DATE}.csv.gz"
OUTDIR="$EPSS_DOWNLOAD_DIR"
TMPFILE="$OUTDIR/${FILENAME}.part"
FINALFILE="$OUTDIR/${FILENAME}"
CSVFILE="$OUTDIR/epss_scores-${DATE}.csv"

mkdir -p "$OUTDIR"

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting EPSS download for date=$DATE"

URL="$BASE_URL/$FILENAME"

# Download with curl -> temp file, then move into place. Retries and timeouts set.
if command -v curl >/dev/null 2>&1; then
    echo "Downloading $URL -> $TMPFILE"
    if curl -fSL --retry 3 --retry-delay 5 --connect-timeout 10 -o "$TMPFILE" "$URL"; then
        mv -f "$TMPFILE" "$FINALFILE"
        echo "Downloaded: $FINALFILE"
    else
        echo "Failed to download $URL" >&2
        rm -f "$TMPFILE" || true
        exit 2
    fi
else
    echo "curl not found; cannot download $URL" >&2
    exit 3
fi

# Extract to CSV. Prefer gunzip/zcat; fallback to python gzip streaming.
echo "Extracting $FINALFILE -> $CSVFILE"
if command -v gunzip >/dev/null 2>&1; then
    gunzip -c "$FINALFILE" > "$CSVFILE"
elif command -v zcat >/dev/null 2>&1; then
    zcat "$FINALFILE" > "$CSVFILE"
else
    # Python fallback (streaming) to avoid loading entire file into memory
    if command -v python3 >/dev/null 2>&1; then
        python3 - <<PY
import gzip, shutil
with gzip.open(r"$FINALFILE", 'rb') as f_in:
    with open(r"$CSVFILE", 'wb') as f_out:
        shutil.copyfileobj(f_in, f_out)
PY
    else
        echo "No available tool to extract gzip (need gunzip/zcat/python3)" >&2
        exit 4
    fi

fi

echo "Extraction complete: $CSVFILE"

# By default keep only the latest requested files (the .csv.gz and .csv for $DATE).
if [ "$KEEP_ONLY_LATEST" -eq 1 ]; then
    echo "KEEP_ONLY_LATEST=1: removing other epss_scores files in $OUTDIR"
    # Remove any epss_scores files that don't match the current DATE
    find "$OUTDIR" -maxdepth 1 -type f \( -name 'epss_scores-*.csv.gz' -o -name 'epss_scores-*.csv' \) ! -name "epss_scores-${DATE}.csv.gz" ! -name "epss_scores-${DATE}.csv" -print -exec rm -f {} \;
else
    # Optional: prune old files older than EPSS_KEEP_DAYS if KEEP_ONLY_LATEST not set
    if [ "$EPSS_KEEP_DAYS" -ge 1 ]; then
        echo "Pruning files older than $EPSS_KEEP_DAYS days in $OUTDIR"
        find "$OUTDIR" -maxdepth 1 -type f \( -name 'epss_scores-*.csv.gz' -o -name 'epss_scores-*.csv' \) -mtime +$EPSS_KEEP_DAYS -print -exec rm -f {} \;
    fi
fi

echo "EPSS download job completed for date=$DATE"

# Create a date-agnostic copy without leading metadata/comment lines
echo "Waiting 5s before creating epss_scores.csv (remove metadata/comment lines)"
sleep 5
AGGFILE="$OUTDIR/epss_scores.csv"
TMP_AGG="$OUTDIR/epss_scores.csv.part"

# Filter out lines starting with '#' (metadata/comment). Write to a temp file then validate.
grep -v '^#' "$CSVFILE" > "$TMP_AGG"

# Basic validation: ensure there is at least one data row after filtering
DATA_COUNT=$(wc -l < "$TMP_AGG" | tr -d ' ' || echo 0)
if [ "$DATA_COUNT" -lt 1 ]; then
    echo "No data rows found in $TMP_AGG; aborting creation of $AGGFILE" >&2
    rm -f "$TMP_AGG"
else
    # Create final file with fixed header and append data rows (skip original header)
    TMP_FINAL="$OUTDIR/epss_scores.csv.part2"
    echo 'cve,epss,percentile' > "$TMP_FINAL"
    # Append everything except the first line of TMP_AGG (which was the original header)
    tail -n +2 "$TMP_AGG" >> "$TMP_FINAL"
    # Validate the final file has more than just the header
    FINAL_LINES=$(wc -l < "$TMP_FINAL" | tr -d ' ')
    if [ "$FINAL_LINES" -lt 2 ]; then
        echo "Final aggregated file $TMP_FINAL contains no data rows; aborting" >&2
        rm -f "$TMP_AGG" "$TMP_FINAL"
    else
        mv -f "$TMP_FINAL" "$AGGFILE"
        rm -f "$TMP_AGG"
        echo "Created $AGGFILE (fixed header + values)"
    fi
fi

exit 0
