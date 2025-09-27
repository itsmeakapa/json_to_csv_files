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

# Test options: set TEST_MODE=1 to only fetch first page; set SKIP_API_VALIDATION=1 to skip validation (useful for local tests)
TEST_MODE=${TEST_MODE:-0}
SKIP_API_VALIDATION=${SKIP_API_VALIDATION:-0}

# Determine whether to use the API header
USE_API_HEADER=1
if [ -z "$API_KEY" ] || [ "$SKIP_API_VALIDATION" -eq 1 ]; then
    USE_API_HEADER=0
fi

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

# Validate API key with a small test request (skip if SKIP_API_VALIDATION=1)
if [ "$USE_API_HEADER" -eq 1 ]; then
    echo "Validating API key..."
    HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "apiKey: $API_KEY" "$API_URL?startIndex=0&resultsPerPage=1")
    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "API key validation failed (HTTP $HTTP_STATUS). Please update API_KEY in the script or set SKIP_API_VALIDATION=1 for testing." >&2
        exit 1
    fi
else
    echo "Skipping API key validation (SKIP_API_VALIDATION=$SKIP_API_VALIDATION). Proceeding without API header."
fi

while [ $START_INDEX -lt $TOTAL_RESULTS ]
do
    enforce_rate_limit

    # Perform request (conditionally include API key header)
    if [ "$USE_API_HEADER" -eq 1 ]; then
        curl -s -H "apiKey: $API_KEY" "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    else
        curl -s "$API_URL?startIndex=$START_INDEX&resultsPerPage=$RESULTS_PER_PAGE" -o "$TMPFILE"
    fi
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

    # If running in TEST_MODE, only fetch the first page then break to run post-processing
    if [ "$TEST_MODE" -eq 1 ]; then
        echo "TEST_MODE=1: fetched first page only; exiting download loop for post-processing."
        break
    fi

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

# Wait a short moment before processing (configurable)
SLEEP_AFTER_DOWNLOAD=${SLEEP_AFTER_DOWNLOAD:-0}
if [ "$SLEEP_AFTER_DOWNLOAD" -gt 0 ]; then
    sleep "$SLEEP_AFTER_DOWNLOAD"
fi

# Post-process concatenated pages into one-event-per-line numbered TXT file.
TXT_OUT="nist_cves_${TS}.txt"
> "$TXT_OUT"

if command -v jq >/dev/null 2>&1; then
    echo "Using jq to extract .vulnerabilities[] and wrap as {\"cve\":...} per line..."
    jq -c '.vulnerabilities[] | {cve: .cve}' "$OUTFILE" | nl -ba -w1 -s' ' > "$TXT_OUT"
    COUNT=$(wc -l < "$TXT_OUT" | tr -d ' ')
    echo "Wrote $COUNT events to $TXT_OUT (jq)"
else
    # Fallback: use perl if available
    if command -v perl >/dev/null 2>&1; then
        echo "jq not found; using perl to split events on exact marker..."
        perl -0777 -ne '
            my $s = $_;
            $s =~ s/\s+/ /gs;
            my @parts = split(/(?=\{"cve\":\{"id\":)/, $s);
            my $n = 0;
            for my $p (@parts) {
                $p =~ s/^\s+|\s+$//g;
                next unless $p =~ /^\{"cve\":/;
                $n++;
                print $n, " ", $p, "\n";
            }
        ' "$OUTFILE" >> "$TXT_OUT"
        COUNT=$(wc -l < "$TXT_OUT" | tr -d ' ')
        echo "Wrote $COUNT events to $TXT_OUT (perl)"
    else
        echo "Neither jq nor perl found; using awk fallback (less robust)."
        awk '
            BEGIN { RS = ""; ORS = "" }
            { gsub(/\n/," ", $0); s = $0; split(s, a, /\{"cve":\{/);
              idx = 0;
              for (i = 2; i <= length(a); i++) {
                part = a[i];
                part = "{\"cve\":{" part;
                sub(/^\s+/, "", part); sub(/\s+$/, "", part);
                idx++;
                print idx " " part "\n";
              }
            }
        ' "$OUTFILE" >> "$TXT_OUT"
        COUNT=$(wc -l < "$TXT_OUT" | tr -d ' ')
        echo "Wrote $COUNT events to $TXT_OUT (awk fallback)"
    fi
fi

# Optional sleep after writing
SLEEP_AFTER_WRITE=${SLEEP_AFTER_WRITE:-0}
if [ "$SLEEP_AFTER_WRITE" -gt 0 ]; then
    sleep "$SLEEP_AFTER_WRITE"
fi
