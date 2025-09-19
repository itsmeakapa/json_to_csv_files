import requests
import time
import csv
import json

def fetch_cves():
    url = "https://services.nvd.nist.gov/rest/json/cves/2.0"
    all_vulns = []
    start_index = 0
    results_per_page = 2000
    total_results = None
    first = True
    while True:
        params = {
            "startIndex": start_index,
            "resultsPerPage": results_per_page
        }
        response = requests.get(url, params=params)
        time.sleep(6)  # Respect NVD API rate limit for unauthenticated users
        if response.status_code == 200:
            data = response.json()
            if first:
                total_results = data.get("totalResults", 0)
                first = False
            vulns = data.get("vulnerabilities", [])
            if not vulns:
                break
            all_vulns.extend(vulns)
            start_index += results_per_page
            if len(all_vulns) >= total_results:
                break
        else:
            print("Failed to fetch CVEs at index", start_index, ":", response.status_code)
            break
    # Save all vulnerabilities to nist_cves.json
    with open("nist_cves.json", "w", encoding="utf-8") as f:
        json.dump({"vulnerabilities": all_vulns}, f, ensure_ascii=False)
    return bool(all_vulns)

def flatten_cve(cve):
    flat = {}
    def _flatten(obj, prefix=""):
        if isinstance(obj, dict):
            for k, v in obj.items():
                _flatten(v, f"{prefix}{k}_")
        elif isinstance(obj, list):
            flat[prefix[:-1]] = json.dumps(obj, ensure_ascii=False)
        else:
            flat[prefix[:-1]] = obj
    _flatten(cve, "cve_")
    return flat

def write_to_csv(cve_data):
    cves = cve_data.get("vulnerabilities", [])
    rows = []
    headers = set()
    for item in cves:
        cve = item.get("cve", {})
        flat = flatten_cve(cve)
        rows.append(flat)
        headers.update(flat.keys())
    headers = sorted(headers)
    with open("cves.csv", "w", newline="", encoding="utf-8") as csvfile:
        writer = csv.DictWriter(csvfile, fieldnames=headers)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)

def main():
    if fetch_cves():
        with open("nist_cves.json", "r", encoding="utf-8") as f:
            data = json.load(f)
        # Write each CVE event as a single line JSON in a .txt file
        with open("cve_events.txt", "w", encoding="utf-8") as txtfile:
            for item in data.get("vulnerabilities", []):
                # Each item is a dict with a 'cve' key
                txtfile.write(json.dumps(item) + "\n")
        print("Wrote CVE events to cve_events.txt")
        # Optionally, write to CSV as well
        write_to_csv(data)

if __name__ == "__main__":
    main()
