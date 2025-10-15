#!/usr/bin/env python3
"""
epss_empiricalsecurity_scores.py

Downloads and processes EPSS daily file similar to download_epss_daily.sh
Logs activity to /tmp/epss_scroes_download.log and performs tasks 1..8
as requested.
"""
from __future__ import annotations
import os
import sys
import shutil
import gzip
import time
import urllib.request
from datetime import datetime, date, timedelta

# Configuration
LOGFILE = "/tmp/epss_scroes_download.log"   # as requested
DOWNLOAD_TO = "/tmp/epss_empiricalsecurity"
BASE_URL = "https://epss.empiricalsecurity.com"

TODAY = date.today()
DATE_STR = TODAY.isoformat()
FILENAME = f"epss_scores-{DATE_STR}.csv.gz"
FINAL_GZ = os.path.join(DOWNLOAD_TO, FILENAME)
TMP_GZ = FINAL_GZ + ".part"
EXTRACTED_CSV = os.path.join(DOWNLOAD_TO, "epss_score.csv")    # task 5 filename
AGG_CSV = os.path.join(DOWNLOAD_TO, "epss_scores.csv")         # date-agnostic CSV

# Logging helpers
def _now_ts() -> str:
    return datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

def log(msg: str) -> None:
    line = f"[{_now_ts()}] {msg}\n"
    with open(LOGFILE, "a", encoding="utf-8") as f:
        f.write(line)

def fail(task_name: str, reason: str, code: int = 1) -> None:
    log(f"{task_name}: FAILED: {reason}")
    log(f"TERMINATED DURING {task_name}")
    sys.exit(code)

def safe_remove(path: str) -> None:
    try:
        if os.path.exists(path):
            os.remove(path)
    except Exception as e:
        log(f"warning: failed to remove {path}: {e}")

# Start
log("SCRIPT STARTED")

# Task 1: ensure folder exists
task = "TASK 1 - ensure download folder"
log(f"{task}: STARTED")
try:
    os.makedirs(DOWNLOAD_TO, exist_ok=True)
    log(f"{task}: OK - ensured {DOWNLOAD_TO} exists")
except Exception as e:
    fail(task, f"could not create/verify folder {DOWNLOAD_TO}: {e}")

# Task 2: remove previously downloaded older csv.gz files
task = "TASK 2 - remove old .csv.gz files"
log(f"{task}: STARTED")
try:
    removed_any = False
    for fn in os.listdir(DOWNLOAD_TO):
        if fn.endswith(".csv.gz"):
            path = os.path.join(DOWNLOAD_TO, fn)
            try:
                os.remove(path)
                removed_any = True
                log(f"{task}: removed {path}")
            except Exception as e:
                log(f"{task}: failed to remove {path}: {e}")
    if not removed_any:
        log(f"{task}: OK - no .csv.gz files found to remove")
    else:
        log(f"{task}: OK - removed existing .csv.gz files")
except Exception as e:
    fail(task, f"error scanning/removing .csv.gz files: {e}")

# Task 3: rotate existing epss_scores.csv -> epss_scores-YYYY-MM-DD.csv (use file mtime date)
task = "TASK 3 - rotate existing epss_scores.csv"
log(f"{task}: STARTED")
try:
    if os.path.exists(AGG_CSV):
        mtime = os.path.getmtime(AGG_CSV)
        file_date = datetime.utcfromtimestamp(mtime).date().isoformat()
        dest_name = f"epss_scores-{file_date}.csv"
        dest_path = os.path.join(DOWNLOAD_TO, dest_name)
        # avoid overwrite by suffixing if needed
        if os.path.exists(dest_path):
            i = 1
            while True:
                alt = os.path.join(DOWNLOAD_TO, f"epss_scores-{file_date}.{i}.csv")
                if not os.path.exists(alt):
                    dest_path = alt
                    break
                i += 1
        shutil.move(AGG_CSV, dest_path)
        log(f"{task}: OK - moved {AGG_CSV} -> {dest_path}")
    else:
        log(f"{task}: OK - {AGG_CSV} not present, nothing to rotate")
except Exception as e:
    fail(task, f"failed to rotate existing {AGG_CSV}: {e}")

# Task 4: download today's file
task = "TASK 4 - download today's .csv.gz"
log(f"{task}: STARTED - url={BASE_URL}/{FILENAME}")
url = f"{BASE_URL}/{FILENAME}"
try:
    req = urllib.request.Request(url, headers={"User-Agent": "epss-downloader/1.0"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        status = getattr(resp, "status", None)
        if status is not None and status >= 400:
            fail(task, f"HTTP error {status} when fetching {url}")
        expected_len = None
        cl = resp.getheader("Content-Length")
        if cl and cl.isdigit():
            expected_len = int(cl)
        bytes_written = 0
        with open(TMP_GZ, "wb") as out:
            chunk_size = 64 * 1024
            while True:
                chunk = resp.read(chunk_size)
                if not chunk:
                    break
                out.write(chunk)
                bytes_written += len(chunk)
    # verify completeness if Content-Length was provided
    if expected_len is not None and bytes_written != expected_len:
        safe_remove(TMP_GZ)
        fail(task, f"incomplete download: expected {expected_len} bytes, got {bytes_written}")
    # move tmp to final
    os.replace(TMP_GZ, FINAL_GZ)
    log(f"{task}: OK - downloaded {url} -> {FINAL_GZ} ({bytes_written} bytes)")
    log(f"{task}: sleeping 5s after download")
    time.sleep(5)
except SystemExit:
    raise
except Exception as e:
    safe_remove(TMP_GZ)
    fail(task, f"download failed: {e}")

# Task 5: extract the downloaded file csv.gz to csv file epss_score.csv
task = "TASK 5 - extract .csv.gz to epss_score.csv"
log(f"{task}: STARTED")
try:
    with gzip.open(FINAL_GZ, "rb") as gz_in:
        with open(EXTRACTED_CSV, "wb") as out_csv:
            shutil.copyfileobj(gz_in, out_csv)
    if not os.path.exists(EXTRACTED_CSV) or os.path.getsize(EXTRACTED_CSV) == 0:
        safe_remove(EXTRACTED_CSV)
        fail(task, "extracted csv is missing or empty")
    log(f"{task}: OK - extraction complete -> {EXTRACTED_CSV}")
except Exception as e:
    fail(task, f"extraction failed: {e}")

# Task 6: create date-agnostic CSV (remove lines starting with '#'), wait 5s
task = "TASK 6 - create date-agnostic CSV (remove metadata/comment lines)"
log(f"{task}: STARTED")
try:
    log(f"{task}: sleeping 5s before processing extracted CSV")
    time.sleep(5)
    tmp_agg = AGG_CSV + ".part"
    data_lines = []
    with open(EXTRACTED_CSV, "r", encoding="utf-8", errors="replace") as fin:
        for line in fin:
            if line.startswith("#"):
                continue
            data_lines.append(line.rstrip("\n"))
    if len(data_lines) == 0:
        safe_remove(tmp_agg)
        fail(task, "no data rows found after removing comment/metadata lines")
    # fixed header
    with open(tmp_agg, "w", encoding="utf-8") as fout:
        fout.write("cve,epss,percentile\n")
        # skip original header if it looks like a header
        start_idx = 1 if ("cve" in data_lines[0].lower()) else 0
        for line in data_lines[start_idx:]:
            fout.write(line + "\n")
    # validate
    final_lines = sum(1 for _ in open(tmp_agg, "r", encoding="utf-8"))
    if final_lines < 2:
        safe_remove(tmp_agg)
        fail(task, "final aggregated CSV contains no data rows (only header)")
    os.replace(tmp_agg, AGG_CSV)
    log(f"{task}: OK - created {AGG_CSV} (fixed header + values)")
    # remove the extracted intermediate CSV to save space
    try:
        safe_remove(EXTRACTED_CSV)
        log(f"{task}: OK - removed intermediate {EXTRACTED_CSV}")
    except Exception as e:
        log(f"{task}: warning: failed to remove intermediate {EXTRACTED_CSV}: {e}")
except SystemExit:
    raise
except Exception as e:
    fail(task, f"failed to create aggregated CSV: {e}")

# Task 7: remove the csv.gz file that was created while downloading
task = "TASK 7 - remove downloaded .csv.gz to save space"
log(f"{task}: STARTED")
try:
    if os.path.exists(FINAL_GZ):
        os.remove(FINAL_GZ)
        log(f"{task}: OK - removed {FINAL_GZ}")
    else:
        log(f"{task}: OK - {FINAL_GZ} not present, nothing to remove")
except Exception as e:
    fail(task, f"failed to remove {FINAL_GZ}: {e}")

# Task 8: keep only two files: epss_scores.csv and yesterday's epss_scores-YYYY-MM-DD.csv, remove older dated files
task = "TASK 8 - prune older dated epss_scores-YYYY-MM-DD.csv files"
log(f"{task}: STARTED")
try:
    yesterday = (TODAY - timedelta(days=1)).isoformat()
    keep_set = {f"epss_scores-{yesterday}.csv"}
    removed = []
    for fn in os.listdir(DOWNLOAD_TO):
        if fn == "epss_scores.csv":
            continue
        if fn.startswith("epss_scores-") and fn.endswith(".csv"):
            if fn in keep_set:
                log(f"{task}: keeping {fn}")
                continue
            path = os.path.join(DOWNLOAD_TO, fn)
            try:
                os.remove(path)
                removed.append(fn)
            except Exception as e:
                log(f"{task}: failed to remove {path}: {e}")
    if removed:
        log(f"{task}: OK - removed older dated files: {', '.join(removed)}")
    else:
        log(f"{task}: OK - no extra dated files to remove")
except Exception as e:
    fail(task, f"failed during pruning of dated files: {e}")

# Finished
log("SCRIPT FINISHED SUCCESSFULLY")
log(f"SCRIPT COMPLETED AT {_now_ts()}")
sys.exit(0)