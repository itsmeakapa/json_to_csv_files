#!/bin/bash
# Download all NVD CPE data using curl and save to nist_cpes.json
# Paginates through the API and appends each raw JSON page to the output file.

API_URL="https://services.nvd.nist.gov/rest/json/cpes/2.0"
RESULTS_PER_PAGE=2000
# Set TEST_MODE=1 to only download the first page and run post-processing (for quick local testing)
TEST_MODE=${TEST_MODE:-0}
# Set SKIP_API_VALIDATION=1 to skip the API key validation step (useful for local testing without valid key)
SKIP_API_VALIDATION=${SKIP_API_VALIDATION:-0}

# By default we send the API key header if API_KEY is non-empty and SKIP_API_VALIDATION is not set.
USE_API_HEADER=1
if [ -z "$API_KEY" ] || [ "$SKIP_API_VALIDATION" -eq 1 ]; then
    USE_API_HEADER=0
fi
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

    # Validate API key on first iteration before proceeding (skip if SKIP_API_VALIDATION=1)
    if [ $FIRST -eq 1 ] && [ "$USE_API_HEADER" -eq 1 ]; then
        echo "Validating API key..."
        HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "apiKey: $API_KEY" "$API_URL?startIndex=0&resultsPerPage=1")
        if [ "$HTTP_STATUS" -ne 200 ]; then
            echo "API key validation failed (HTTP $HTTP_STATUS). Update API_KEY in the script or set SKIP_API_VALIDATION=1 for testing." >&2
            exit 1
        fi
    elif [ $FIRST -eq 1 ] && [ "$USE_API_HEADER" -eq 0 ]; then
        echo "Skipping API key validation (SKIP_API_VALIDATION=$SKIP_API_VALIDATION). Proceeding without API header."
    fi

    if [ "$USE_API_HEADER" -eq 1 ]; then
        curl -s -H "apiKey: $API_KEY" "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    else
        curl -s "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    fi
    # Record this request time
    REQUEST_TIMES+=("$(date +%s)")

    if [ $FIRST -eq 1 ]; then
        TOTAL_RESULTS=$(jq '.totalResults' "$TMPFILE")
        FIRST=0
    fi
    cat "$TMPFILE" >> "$OUTFILE"
    # If running in TEST_MODE, only fetch the first page then break to run post-processing
    if [ "$TEST_MODE" -eq 1 ]; then
        echo "TEST_MODE=1: fetched first page only; exiting download loop for post-processing."
        break
    fi
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

# Now split combined JSON pages into individual events, one per line, numbered using jq if available
TXT_OUT="nist_cpes_${TS}.txt"
> "$TXT_OUT"

if command -v jq >/dev/null 2>&1; then
    # Attempt to extract each item under .result.cpes or .cpes or similar structures
    # We'll try common paths; if the file is raw concatenated API pages, we'll process each page
    COUNT=0
    # Use jq to extract .products[] and wrap as {"cpe":...} per line
    jq -c '.products[] | {cpe: .cpe}' "$OUTFILE" | nl -ba -w1 -s' ' > "$TXT_OUT"
    COUNT=$(wc -l < "$TXT_OUT" | tr -d ' ')
    echo "Wrote $COUNT events to $TXT_OUT (jq)"
else
    echo "jq not found; cannot split JSON cleanly. Install jq and rerun to generate $TXT_OUT." >&2
fi

# Sleep 10 seconds after writing
sleep 10
