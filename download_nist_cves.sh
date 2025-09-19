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

# Start the output file
printf '{"vulnerabilities":[' > "$OUTFILE"

while [ $START_INDEX -lt $TOTAL_RESULTS ]
do
    # Download a page
    curl -s "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    # Get totalResults from the first page
    if [ $FIRST -eq 1 ]; then
        TOTAL_RESULTS=$(jq '.totalResults' "$TMPFILE")
        FIRST=0
    fi
    # Extract vulnerabilities array, remove [ and ]
    VULNS=$(jq -c '.vulnerabilities[]' "$TMPFILE")
    COUNT=0
    for V in $VULNS; do
        if [ $START_INDEX -eq 0 ] && [ $COUNT -eq 0 ]; then
            printf '\n%s' "$V" >> "$OUTFILE"
        else
            printf ',\n%s' "$V" >> "$OUTFILE"
        fi
        COUNT=$((COUNT+1))
    done
    START_INDEX=$((START_INDEX + RESULTS_PER_PAGE))
    sleep 6
    # Stop if no vulnerabilities found
    if [ $COUNT -eq 0 ]; then
        break
    fi
done

printf '\n]}' >> "$OUTFILE"
rm -f "$TMPFILE"
echo "Downloaded all CVEs to $OUTFILE"
