#!/bin/bash
# Download all NVD CVE data using curl and save to nist_cves.json
# This script paginates through the API, respecting the 6 second rate limit for unauthenticated requests.

API_URL="https://services.nvd.nist.gov/rest/json/cves/2.0"
RESULTS_PER_PAGE=2000
START_INDEX=0
TOTAL_RESULTS=1
FIRST=1
OUTFILE="nist_cves.json"
TMPFILE="tmp_cves.json"

printf '\n]}' >> "$OUTFILE"
# Overwrite output file
> "$OUTFILE"

while [ $START_INDEX -lt $TOTAL_RESULTS ]
do
    curl -s "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    if [ $FIRST -eq 1 ]; then
        TOTAL_RESULTS=$(jq '.totalResults' "$TMPFILE")
        FIRST=0
    fi
    cat "$TMPFILE" >> "$OUTFILE"
    START_INDEX=$((START_INDEX + RESULTS_PER_PAGE))
    sleep 6
done

rm -f "$TMPFILE"
echo "Downloaded all CVEs to $OUTFILE (raw paged JSONs concatenated)"
