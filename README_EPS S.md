EPSS daily download

This workspace includes `download_epss_daily.sh` which downloads the daily EPSS file from
`https://epss.empiricalsecurity.com/epss_scores-YYYY-MM-DD.csv.gz` and extracts it to CSV.

By default the script downloads yesterday's file (the provider usually publishes the previous day's file):

```
./download_epss_daily.sh            # downloads yesterday's file
./download_epss_daily.sh 2025-10-03 # download a specific date
```

Cron example (UTC 00:30):

```
30 0 * * * cd /path/to/json_to_csv_files && /path/to/json_to_csv_files/download_epss_daily.sh >> /var/log/epss_download.log 2>&1
```

Environment variables:
- `EPSS_DOWNLOAD_DIR` - directory to store downloads (default: ./epss)
- `EPSS_KEEP_DAYS` - how many days to keep (default: 14)
- `KEEP_ONLY_LATEST` - when 1 (default) keep only latest .csv.gz and .csv; set 0 to keep history

Security note: the script fetches files from the public EPSS endpoint and writes them to disk. Validate your environment and storage policies if needed.
