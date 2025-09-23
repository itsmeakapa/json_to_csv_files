#!/bin/bash
# Download all NVD CPE data using curl and save to nist_cpes.json
# Paginates through the API and appends each raw JSON page to the output file.

API_URL="https://services.nvd.nist.gov/rest/json/cpes/2.0"
RESULTS_PER_PAGE=2000
# Static API key (update when token expires)
API_KEY="ladj-ioj3-45sl-nrns4983"

# Rate limit parameters for authenticated usage
RATE_LIMIT_COUNT=49
RATE_LIMIT_WINDOW=30
START_INDEX=0
TOTAL_RESULTS=1
FIRST=1
TS=$(date +"%Y-%m-%d_%H-%M-%S")
OUTFILE="nist_cpes_${TS}.json"
TMPFILE="tmp_cpes.json"

# Overwrite output file
> "$OUTFILE"

REQUEST_TIMES=()

enforce_rate_limit() {
    local now
    now=$(date +%s)
    # Purge timestamps older than RATE_LIMIT_WINDOW seconds
    local recent=()
    for t in "${REQUEST_TIMES[@]}"; do
        if (( now - t < RATE_LIMIT_WINDOW )); then
            recent+=("$t")
        fi
    done
    REQUEST_TIMES=("${recent[@]}")

    if (( ${#REQUEST_TIMES[@]} >= RATE_LIMIT_COUNT )); then
        local oldest=${REQUEST_TIMES[0]}
        local wait=$((oldest + RATE_LIMIT_WINDOW - now))
        if (( wait > 0 )); then
            echo "Rate limit reached ($RATE_LIMIT_COUNT requests/${RATE_LIMIT_WINDOW}s). Sleeping $wait seconds..."
            sleep $wait
        fi
        # Purge again after sleeping
        now=$(date +%s)
        recent=()
        for t in "${REQUEST_TIMES[@]}"; do
            if (( now - t < RATE_LIMIT_WINDOW )); then
                recent+=("$t")
            fi
        done
        REQUEST_TIMES=("${recent[@]}")
    fi
}

while [ $START_INDEX -lt $TOTAL_RESULTS ]
do
    # Enforce rate limit
    enforce_rate_limit

    # Validate API key on first iteration before proceeding
    if [ $FIRST -eq 1 ]; then
        echo "Validating API key..."
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "apiKey: $API_KEY" "$API_URL?startIndex=0&resultsPerPage=1")
        if [ "$HTTP_STATUS" -ne 200 ]; then
            echo "API key validation failed (HTTP $HTTP_STATUS). Update API_KEY in the script." >&2
            exit 1
        fi
    fi

    curl -s -H "apiKey: $API_KEY" "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    # Record this request time
    REQUEST_TIMES+=("$(date +%s)")

    if [ $FIRST -eq 1 ]; then
        TOTAL_RESULTS=$(jq '.totalResults' "$TMPFILE")
        FIRST=0
    fi
    cat "$TMPFILE" >> "$OUTFILE"
    # Calculate progress: how many pages expected
    if [ "$TOTAL_RESULTS" -gt 0 ]; then
        total_pages=$(( (TOTAL_RESULTS + RESULTS_PER_PAGE - 1) / RESULTS_PER_PAGE ))
        current_page=$(( START_INDEX / RESULTS_PER_PAGE + 1 ))
        echo "Downloaded page ${current_page}/${total_pages} (startIndex=${START_INDEX})"
    else
        echo "Downloaded page startIndex=$START_INDEX (totalResults=$TOTAL_RESULTS)"
    fi
    START_INDEX=$((START_INDEX + RESULTS_PER_PAGE))
done

rm -f "$TMPFILE"
echo "Downloaded all CPEs to $OUTFILE (raw paged JSONs concatenated)"

# Wait 10 seconds before processing
sleep 10

# Now split combined JSON pages into individual events, one per line, numbered
TXT_OUT="nist_cpes_${TS}.txt"
> "$TXT_OUT"

if command -v jq >/dev/null 2>&1; then
    # Attempt to extract each item under .result.cpes or .cpes or similar structures
    # We'll try common paths; if the file is raw concatenated API pages, we'll process each page
    COUNT=0
    # Use jq to stream through file; first try .cpes
    jq -c '.cpes[]?' "$OUTFILE" | while IFS= read -r item; do
        COUNT=$((COUNT+1))
        printf '%d %s\n' "$COUNT" "$item" >> "$TXT_OUT"
    done
    # If nothing was written, try .result.cpes
    if [ "$COUNT" -eq 0 ]; then
        jq -c '.result.cpes[]?' "$OUTFILE" | while IFS= read -r item; do
            COUNT=$((COUNT+1))
            printf '%d %s\n' "$COUNT" "$item" >> "$TXT_OUT"
        done
    fi
    # If still zero, attempt to extract any occurrences of objects that start with {"cpe":
    if [ "$COUNT" -eq 0 ]; then
        # Grep for occurrences and split using awk between markers
        awk 'BEGIN{RS="{"; ORS=""} /\"cpe\":/ {print "{"$0"\n"}' "$OUTFILE" | nl -ba -w1 -s' ' > "$TXT_OUT"
        COUNT=$(wc -l < "$TXT_OUT" | tr -d ' ')
    fi
    echo "Wrote $COUNT events to $TXT_OUT"
else
    echo "jq not found; cannot split JSON cleanly. Install jq and rerun to generate $TXT_OUT." >&2
fi

# Sleep 10 seconds after writing
sleep 10
