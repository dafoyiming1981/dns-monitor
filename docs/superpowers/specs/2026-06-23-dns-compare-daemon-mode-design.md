# DNS Compare Daemon Mode Design

**Date:** 2026-06-23
**Status:** Draft
**Target:** `dns_compare.sh` (Multi-DNS Comparison Test v8.0)

## Problem

The current `dns_compare.sh` is a single-run script. Each execution queries all configured domains against all DNS servers, outputs reports, and exits. Typical execution interval via cron is ~5 minutes, meaning any DNS changes occurring between runs (CDN failovers, GSLB switches, TTL expirations) are completely invisible.

The Prometheus metrics (`dns_query_difference`) are gauges that only reflect the latest snapshot, providing no historical change timeline.

## Solution

Add a `--daemon` mode that keeps the script running continuously with configurable detection intervals (seconds-level granularity), while maintaining full backward compatibility with the existing single-run behavior.

---

## Architecture

### Core Loop

```
while [ daemon_running ]; do
    Query all domains against all DNS servers
    Compare results across DNS servers (existing logic)
    If previous snapshot exists: compare current vs previous → write change log
    Save current results as snapshot
    sleep $INTERVAL
end
```

### Signal Handling

- `SIGTERM` / `SIGINT`: Set `daemon_running=false`, complete current round gracefully, then exit
- Do NOT interrupt in-flight DNS queries on signal receipt
- Write final statistics to log on exit

### New CLI Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--daemon` | off | Enable daemon mode (script does not exit) |
| `--interval SECONDS` | 60 | Seconds between detection rounds |
| `--change-log FILE` | auto-named | Change log output path. Auto-naming: `dns_changes_YYYYMMDD_HHMMSS.log` in working directory |
| `--max-iterations N` | 0 (infinite) | Max rounds before exit, 0 = infinite loop |

All existing parameters (`--file`, `--domain`, `--type`, `--prom-dir`, etc.) remain functional in daemon mode.

---

## Snapshot Design

### File: `dns_latest_snapshot.json`

```json
{
  "timestamp": "2026-06-23T21:33:32",
  "records": {
    "b2enew.bankofchina.com@A@114": "124.74.250.120",
    "b2enew.bankofchina.com@A@Google": "112.64.122.120",
    "ica.mydesk.morganstanley.com@CNAME@Google": "ica-eu -> ica-tk",
    "morganstanley.com@MX@114": "mx1,mx2,mx3,mx4"
  }
}
```

**Key format:** `{domain}@{record_type}@{dns_server}`
**Value:** The resolved result (IP addresses, CNAME chain, MX list, SOA line, TXT content)
**Special values:** `ERROR` (query failed), `NO_RECORD` (NXDOMAIN/empty response)

### Snapshot lifecycle

1. First round: skip change detection, write initial snapshot
2. Subsequent rounds: compare current results against snapshot, detect changes, overwrite snapshot
3. Corrupted snapshot: log warning, skip comparison, rebuild snapshot

---

## Change Detection Logic

### Change types

| Type | Condition | Example |
|------|-----------|---------|
| `CHANGE` | Previous value exists, current value differs | IP: `1.2.3.4` → `1.2.3.5` |
| `NEW` | Previous = `NO_RECORD`/absent, current has value | Previously no A record, now resolves |
| `GONE` | Previous had value, current = `NO_RECORD`/`ERROR` | Previously resolved, now NXDOMAIN |
| `ERROR` | Previous OK, current = `ERROR` | Query timeout this round |

### Change log format

File: `dns_changes_YYYYMMDD_HHMMSS.log`

```
[2026-06-23 21:33:32] CHANGE b2enew.bankofchina.com (A) via Google: 112.64.122.120 -> 112.64.122.121
[2026-06-23 21:33:32] CHANGE ica.mydesk.morganstanley.com (CNAME) via Google: chain changed (ica-eu -> ica-tk)
[2026-06-23 21:33:32] NEW api.bankofchina.com (A) via Cloudflare: previously no record, now resolved
[2026-06-23 21:33:32] GONE old.example.com (A) via 114: previously 10.0.0.1, now NO_RECORD
```

### Comparison algorithm

```
For each domain+record_type in current round:
    For each DNS server:
        current_key = "{domain}@{record_type}@{server}"
        current_value = resolved_result
        previous_value = snapshot.records[current_key]

        if previous_value not exists: continue  (first round)
        if previous_value == current_value: continue  (no change)
        else: log change with type (CHANGE/NEW/GONE/ERROR)
```

---

## New Output Files

### Daemon mode: fixed filenames (overwritten each round)

In daemon mode, output files use **fixed names** to avoid accumulating thousands of timestamped files:

| File | Purpose |
|------|---------|
| `dns_latest_snapshot.json` | Current state snapshot |
| `dns_changes.log` | Cumulative change detection log (all rounds, append-only) |
| `dns_differences.log` | Cumulative difference log across DNS servers (append-only) |
| `dns_a_report.csv` / `dns_cname_report.csv` / `dns_mx_report.csv` / `dns_soa_report.csv` / `dns_txt_report.csv` | Latest round report data (overwritten) |
| `dns_errors.log` | Error log (rotated by date: `dns_errors_YYYYMMDD.log`) |

### Single-run mode: timestamped filenames (existing behavior)

When NOT in daemon mode, all output files keep their current timestamped naming. No behavioral change for backward compatibility.

---

## systemd Integration

### Service file: `/etc/systemd/system/dns-compare.service`

```ini
[Unit]
Description=DNS Multi-Server Comparison Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/dns-compare
ExecStart=/opt/dns-compare/dns_compare.sh --daemon --interval 30 --prom-dir /run/textfile_collector
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
# Graceful shutdown timeout
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

### Usage

```bash
# Install
sudo cp dns_compare.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable dns-compare
sudo systemctl start dns-compare

# View logs
journalctl -u dns-compare -f

# Check status
systemctl status dns-compare
```

---

## Implementation Details

### Modified sections in dns_compare.sh

1. **Argument parsing** (~line 952): Add `--daemon`, `--interval`, `--change-log`, `--max-iterations`
2. **Main loop** (~line 1118): Wrap existing domain iteration in a `while` loop controlled by `DAEMON_MODE` flag
3. **After `display_results`** (~line 1146): Add snapshot comparison logic before or alongside existing diff detection
4. **End of each round**: Save snapshot, handle `--interval` sleep, check for signal/stop flag
5. **New functions**:
   - `save_snapshot()` — write current round results to JSON snapshot
   - `load_snapshot()` — read previous snapshot
   - `compare_with_snapshot()` — detect changes, write change log
   - `daemon_cleanup()` — signal handler, graceful exit

### Snapshot I/O (no jq dependency)

Snapshot read/write uses bash + awk/sed to avoid external JSON parser dependencies. Format is simple enough to parse with `grep`/`awk`.

### Resource management

- Single snapshot file (overwritten)
- Change logs accumulate (no automatic rotation — left to logrotate)
- No additional memory growth: only per-round arrays are used

---

## Edge Cases

| Scenario | Behavior |
|----------|----------|
| No previous snapshot | Skip change detection, write initial snapshot |
| Corrupted snapshot | Log warning, skip comparison, rebuild |
| Disk full | Degrade gracefully (no snapshot, log warning) |
| Kill (SIGKILL) | Next start treats existing snapshot as potentially stale, logs notice |
| Domain list changes between rounds | New domains start without previous comparison; removed domains simply stop appearing |
