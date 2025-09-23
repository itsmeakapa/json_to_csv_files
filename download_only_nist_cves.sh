#!/bin/bash
# Download all NVD CVE data using curl and save to a timestamped JSON file
# Accepts API key via env var NVD_API_KEY or first argument
# Uses a rolling-window rate limiter: default 49 requests per 30 seconds for authenticated users

API_URL="https://services.nvd.nist.gov/rest/json/cves/2.0"
RESULTS_PER_PAGE=2000
START_INDEX=0
TOTAL_RESULTS=1
FIRST=1
TMPFILE="tmp_cves.json"

# Static API key: update this value when your token expires
API_KEY="ladj-ioj3-45sl-nrns4983"

# Temporary output file while downloading; will be renamed to include timestamp when complete
OUT_TMP="nist_cves_download_tmp.json"

TS=$(date +"%Y-%m-%d_%H-%M-%S")
OUTFILE="nist_cves_${TS}.json"

# Rate limit parameters for authenticated usage
RATE_LIMIT_COUNT=49
RATE_LIMIT_WINDOW=30
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
        # Purge again
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

# Overwrite temp output file
> "$OUT_TMP"

# Validate API key with a small test request
echo "Validating API key..."
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "apiKey: $API_KEY" "$API_URL?startIndex=0&resultsPerPage=1")
if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "API key validation failed (HTTP $HTTP_STATUS). Please update API_KEY in the script." >&2
    exit 1
fi

while [ $START_INDEX -lt $TOTAL_RESULTS ]
do
    enforce_rate_limit

    # Perform request with API key header
    curl -s -H "apiKey: $API_KEY" "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    REQUEST_TIMES+=("$(date +%s)")

    if [ $FIRST -eq 1 ]; then
        if command -v jq >/dev/null 2>&1; then
            TOTAL_RESULTS=$(jq '.totalResults' "$TMPFILE")
        else
            # Try to extract totalResults with grep/awk as fallback
            TOTAL_RESULTS=$(grep -o '"totalResults"[[:space:]]*:[[:space:]]*[0-9]*' "$TMPFILE" | head -1 | awk -F: '{print $2}' | tr -d ' ')
        fi
        FIRST=0
    fi

    cat "$TMPFILE" >> "$OUT_TMP"

    # Progress output
    if [ -n "$TOTAL_RESULTS" ] && [ "$TOTAL_RESULTS" -gt 0 ]; then
        total_pages=$(( (TOTAL_RESULTS + RESULTS_PER_PAGE - 1) / RESULTS_PER_PAGE ))
        current_page=$(( START_INDEX / RESULTS_PER_PAGE + 1 ))
        echo "Downloaded page ${current_page}/${total_pages} (startIndex=${START_INDEX})"
    else
        echo "Downloaded page startIndex=$START_INDEX"
    fi

    START_INDEX=$((START_INDEX + RESULTS_PER_PAGE))
done

rm -f "$TMPFILE"

# Rename temp output to timestamped final filename
mv "$OUT_TMP" "$OUTFILE"
echo "Downloaded all CVEs to $OUTFILE (raw paged JSONs concatenated)"
