# DNS Compare Daemon Mode Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a continuous monitoring daemon mode to dns_compare.sh that runs detection rounds at configurable intervals and tracks DNS record changes over time.

**Architecture:** Wrap the existing single-run domain iteration loop in a `while` loop controlled by a `DAEMON_MODE` flag. Each round saves a JSON snapshot of results, compares against the previous round's snapshot to detect changes, and writes cumulative logs with fixed filenames instead of per-round timestamped files.

**Tech Stack:** Bash 3.2+, dig, awk, sed (no new dependencies)

## Global Constraints

- No new external dependencies (no jq, no python for snapshot I/O)
- Full backward compatibility: single-run mode behavior unchanged
- Snapshot is valid JSON but parseable with bash tools only
- Signal handlers must complete current round before exit (no mid-query interruption)
- Daemon mode uses fixed filenames for output; single-run mode keeps timestamped names

---

### Task 1: New CLI arguments, daemon variables, and signal handler

**Files:**
- Modify: `dns_compare.sh` (lines 944-950: variable declarations; lines 952-983: argument parsing; lines 906-937: help text)

**Interfaces:**
- Consumes: existing argument parsing structure (`while [[ $# -gt 0 ]]`)
- Produces: `DAEMON_MODE`, `DAEMON_INTERVAL`, `DAEMON_MAX_ITER`, `DAEMON_RUNNING`, `CHANGE_LOG_FILE` variables; `daemon_cleanup()` function

- [ ] **Step 1: Add daemon variables after existing variable declarations (around line 950)**

Add these after the existing `ENABLE_GEOIP=true` line:

```bash
# Daemon mode variables
DAEMON_MODE=false
DAEMON_INTERVAL=60
DAEMON_MAX_ITER=0
DAEMON_RUNNING=true
CHANGE_LOG_FILE=""
SNAPSHOT_FILE="dns_latest_snapshot.json"
```

- [ ] **Step 2: Add new argument options to the case statement (around line 972)**

Add these cases inside the existing `while [[ $# -gt 0 ]]; do` block:

```bash
        --daemon) DAEMON_MODE=true; shift ;;
        --interval) DAEMON_INTERVAL="$2"; shift 2 ;;
        --max-iterations) DAEMON_MAX_ITER="$2"; shift 2 ;;
        --change-log) CHANGE_LOG_FILE="$2"; shift 2 ;;
```

- [ ] **Step 3: Update `show_help()` to document new options**

Add these lines to the help text, before the `Examples:` section:

```
Daemon Mode Options:
  --daemon               Run in continuous monitoring mode (does not exit)
  --interval SECONDS     Time between detection rounds (default: 60)
  --max-iterations N     Maximum rounds before exit (0 = infinite, default: 0)
  --change-log FILE      Change log output path (default: dns_changes.log)
```

- [ ] **Step 4: Add signal handler function before the main section (around line 940)**

```bash
# ====================================================
# Daemon mode helpers
# ====================================================

daemon_cleanup() {
    log "${YELLOW}Daemon mode: shutting down gracefully...${NC}"
    DAEMON_RUNNING=false
}

# Register signal handlers for graceful shutdown
trap daemon_cleanup SIGTERM SIGINT
```

- [ ] **Step 5: Set default change log filename after argument parsing**

After the argument parsing block (after the `done` at ~line 983), add:

```bash
if [ "$DAEMON_MODE" = "true" ] && [ -z "$CHANGE_LOG_FILE" ]; then
    CHANGE_LOG_FILE="dns_changes.log"
fi
```

- [ ] **Step 6: Test that the new arguments are accepted**

```bash
cd /Users/zhangyiming/dns_compare_pkg
bash dns_compare.sh --help | grep -A 5 "Daemon Mode"
bash -n dns_compare.sh && echo "Syntax OK"
```

Expected: Shows the 4 new daemon options in help text, syntax OK.

- [ ] **Step 7: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: add daemon mode CLI arguments and signal handler"
```

---

### Task 2: Snapshot I/O functions (save and load)

**Files:**
- Modify: `dns_compare.sh` (add new functions after daemon_cleanup, in the "Daemon mode helpers" section)

**Interfaces:**
- Consumes: `SNAPSHOT_FILE` variable, results from each round
- Produces: `init_snapshot_round()`, `save_snapshot_record()`, `finalize_snapshot()`, `load_snapshot_value()` functions used by Tasks 3 and 4

**Snapshot JSON format:**
```json
{"timestamp":"2026-06-23T21:33:32","records":{"example.com@A@114":"1.2.3.4","example.com@A@Google":"5.6.7.8"}}
```

- [ ] **Step 1: Implement snapshot functions**

Add after `daemon_cleanup()` and the `trap` line:

```bash
# Snapshot: append one record to a temp file, then finalize as JSON at round end
_SNAP_TMPFILE=""

init_snapshot_round() {
    _SNAP_TMPFILE=$(mktemp "${SNAPSHOT_FILE}.XXXXXX.tmp")
}

save_snapshot_record() {
    local key="$1" value="$2"
    # Sanitize value for JSON: escape backslashes, quotes, and control chars
    value=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/ /g' | tr -d '\n\r' | head -c 500)
    echo "${key}=${value}" >> "$_SNAP_TMPFILE"
}

finalize_snapshot() {
    local timestamp="$1"
    [ -z "$_SNAP_TMPFILE" ] && [ ! -f "$_SNAP_TMPFILE" ] && return 1

    # Build JSON from temp file
    {
        echo "{\"timestamp\":\"${timestamp}\",\"records\":{"
        local first=true
        while IFS='=' read -r key value; do
            [ -z "$key" ] && continue
            if [ "$first" = "true" ]; then
                first=false
            else
                echo ","
            fi
            printf '"%s":"%s"' "$key" "$value"
        done < "$_SNAP_TMPFILE"
        echo "}}"
    } > "${SNAPSHOT_FILE}.new"
    mv "${SNAPSHOT_FILE}.new" "$SNAPSHOT_FILE"
    rm -f "$_SNAP_TMPFILE"
    _SNAP_TMPFILE=""
}

# Load a single key from snapshot; prints value to stdout, returns 1 if not found
load_snapshot_value() {
    local key="$1"
    [ ! -f "$SNAPSHOT_FILE" ] && return 1
    grep -o "\"${key}\":\"[^\"]*\"" "$SNAPSHOT_FILE" 2>/dev/null | sed "s/\"${key}\":\"//; s/\"$//" | head -1
    [ ${PIPESTATUS[0]} -eq 0 ] && return 0 || return 1
}
```

- [ ] **Step 2: Syntax check**

```bash
bash -n dns_compare.sh && echo "Syntax OK" || echo "Syntax ERROR"
```

Expected: "Syntax OK"

- [ ] **Step 3: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: add snapshot I/O functions for daemon mode"
```

---

### Task 3: Change detection (compare with previous snapshot)

**Files:**
- Modify: `dns_compare.sh` (add new function after snapshot I/O in "Daemon mode helpers" section)

**Interfaces:**
- Consumes: `load_snapshot_value()` from Task 2, `SNAPSHOT_FILE`, `CHANGE_LOG_FILE`
- Produces: `compare_with_snapshot()` function called from the main loop

- [ ] **Step 1: Implement compare_with_snapshot function**

Add after `load_snapshot_value()`:

```bash
# Compare current round results against previous snapshot; writes changes to change log
# Usage: compare_with_snapshot domain record_type dns_server current_status current_raw
compare_with_snapshot() {
    local domain="$1" record_type="$2" dns_server="$3" status="$4" raw="$5"
    local key="${domain}@${record_type}@${dns_server}"

    local prev_value
    prev_value=$(load_snapshot_value "$key")
    local load_rc=$?

    # If no previous snapshot or key not found, skip (first round or new domain)
    [ $load_rc -ne 0 ] && [ -z "$prev_value" ] && return 0

    # Determine current display value
    local curr_value="$raw"
    [ "$status" = "ERROR" ] && curr_value="ERROR"
    [ "$status" = "NO_RECORD" ] && curr_value="NO_RECORD"

    # No change
    [ "$prev_value" = "$curr_value" ] && return 0

    # Classify change
    local change_type=""
    local change_desc=""

    if [ "$prev_value" = "NO_RECORD" ] || [ -z "$prev_value" ]; then
        [ "$status" != "NO_RECORD" ] && [ "$status" != "ERROR" ] && change_type="NEW"
    elif [ "$prev_value" != "ERROR" ] && [ "$curr_value" = "ERROR" ]; then
        change_type="ERROR"
        change_desc="${prev_value} -> query failed"
    elif [ "$curr_value" = "NO_RECORD" ]; then
        change_type="GONE"
        change_desc="${prev_value} -> NO_RECORD"
    else
        change_type="CHANGE"
        change_desc="${prev_value} -> ${curr_value}"
    fi

    [ -z "$change_type" ] && return 0

    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local msg="[${ts}] ${change_type} ${domain} (${record_type}) via ${dns_server}: ${change_desc}"
    echo "$msg" >> "$CHANGE_LOG_FILE"
    log "${YELLOW}  ${msg}${NC}"
}
```

- [ ] **Step 2: Syntax check**

```bash
bash -n dns_compare.sh && echo "Syntax OK"
```

- [ ] **Step 3: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: add change detection against snapshot for daemon mode"
```

---

### Task 4: Daemon mode main loop wrapper

**Files:**
- Modify: `dns_compare.sh` (lines 1016-1225: main execution section)

**Interfaces:**
- Consumes: all existing functions + `DAEMON_MODE`, `DAEMON_INTERVAL`, `DAEMON_MAX_ITER`, `DAEMON_RUNNING`, snapshot functions from Tasks 1-3
- Produces: the daemon loop that wraps the existing domain iteration

- [ ] **Step 1: Extract the main loop into `run_one_round()` function**

The current code from the header banner (line ~1016, `clear` + `echo "====..."`) through the final statistics and Prometheus write (line ~1222) needs to be wrapped in a function.

Add this function **before** the existing main execution code (after line ~1014):

```bash
run_one_round() {
    local round_num="$1"
    log "${CYAN}========== Round $round_num $(date '+%Y-%m-%d %H:%M:%S') ==========${NC}"

    # Initialize output files (daemon mode uses fixed names)
    if [ "$DAEMON_MODE" = "true" ]; then
        init_daemon_output_files
    fi

    # Initialize snapshot temp file for this round
    if [ "$DAEMON_MODE" = "true" ]; then
        init_snapshot_round
    fi

    # Initialize log files
    if [ "$DAEMON_MODE" = "true" ] && [ "$round_num" -gt 1 ]; then
        echo "\n--- Round $round_num ---" >> "$LOG_FILE"
    else
        echo "Multi-DNS Comparison Test v8.0 - $(date)" > "$LOG_FILE"
        [ -n "$DOMAIN_FILE" ] && echo "Domain file: $DOMAIN_FILE" >> "$LOG_FILE"
        [ ${#CMD_DOMAINS[@]} -gt 0 ] && echo "Command-line domains:" >> "$LOG_FILE"
        for i in "${!CMD_DOMAINS[@]}"; do
            echo "  - ${CMD_DOMAINS[$i]} (${CMD_TYPES[$i]})" >> "$LOG_FILE"
        done
        echo "Max CNAME depth: $MAX_CNAME_DEPTH" >> "$LOG_FILE"
        echo "CNAME comparison: Chain structure only (final IP ignored)" >> "$LOG_FILE"
        echo "IP Geolocation: $ENABLE_GEOIP (display only)" >> "$LOG_FILE"
        echo "========================================" >> "$LOG_FILE"
    fi

    echo "DNS Difference Log - $(date)" > "$DIFF_LOG_FILE"
    echo "This file records all DNS resolution discrepancies" >> "$DIFF_LOG_FILE"
    echo "Note: For CNAME records, differences are based on chain structure" >> "$DIFF_LOG_FILE"
    echo "========================================" >> "$DIFF_LOG_FILE"

    echo "DNS Error Log - $(date)" > "$ERROR_LOG_FILE"
    echo "This file records all DNS query errors and failures" >> "$ERROR_LOG_FILE"
    echo "========================================" >> "$ERROR_LOG_FILE"

    if [ "$ENABLE_GEOIP" = "true" ]; then
        echo "DNS GeoIP Log - $(date)" > "$GEOIP_LOG_FILE"
        echo "This file records IP geolocation lookups" >> "$GEOIP_LOG_FILE"
        echo "========================================" >> "$GEOIP_LOG_FILE"
    fi

    # Initialize counters
    total=${#DOMAIN_ORDER[@]}
    current=0
    diff_cnt=0
    err_cnt=0
    no_record_cnt=0

    # Main domain iteration loop
    for ((didx=0; didx<${#DOMAIN_ORDER[@]}; didx++)); do
        domain="${DOMAIN_ORDER[$didx]}"
        type="${DOMAIN_CONFIG_ARR[$didx]}"
        cat="${DOMAIN_CATEGORY_ARR[$didx]}"

        log "\n${BLUE}[$((++current))/$total] Testing domain: $domain ($type) — ${#dns_names[@]} DNS servers${NC}"
        results=()
        has_err=0
        has_no=0
        for i in "${!dns_names[@]}"; do
            name="${dns_names[$i]}"
            ip="${dns_ips[$i]}"
            [ $VERBOSE -eq 1 ] && log -n "  Querying $name... "
            res=$(resolve_domain "$domain" "$ip" "$name" "$type")
            [ $VERBOSE -eq 1 ] && log "done"
            [[ "$res" == *"ERROR"* ]] && has_err=1
            [[ "$res" == *"NO_RECORD"* ]] && has_no=1
            results+=("$res")

            # Daemon mode: save to snapshot and detect changes
            if [ "$DAEMON_MODE" = "true" ]; then
                local status=$(echo "$res" | cut -d'|' -f4)
                local raw=$(echo "$res" | cut -d'|' -f6)
                save_snapshot_record "${domain}@${type}@${name}" "$raw"
                compare_with_snapshot "$domain" "$type" "$name" "$status" "$raw"
            fi

            if [ $i -lt $((${#dns_names[@]} - 1)) ]; then
                if [ $VERBOSE -eq 1 ]; then
                    wait_with_countdown $QUERY_DELAY "Query delay"
                else
                    echo -ne "${YELLOW}  Wait ${QUERY_DELAY}s...${NC}\r"
                    sleep $QUERY_DELAY
                    echo -e "${GREEN}  Done${NC}"
                fi
            fi
        done
        display_results "$domain" "$type" "$cat" "${results[@]}"
        diff=$?
        [ $diff -eq 1 ] && ((diff_cnt++))
        [ $has_err -eq 1 ] && ((err_cnt++))
        [ $has_no -eq 1 ] && ((no_record_cnt++))
        write_to_csv "$domain" "$type" "${results[@]}"
        emit_dns_prometheus "$domain" "$type" "$cat" "$diff" "${results[@]}"
        if [ $current -lt $total ]; then
            if [ $VERBOSE -eq 1 ]; then
                wait_with_countdown $DOMAIN_DELAY "Domain delay"
            else
                echo -ne "${YELLOW}Wait ${DOMAIN_DELAY}s...${NC}\r"
                sleep $DOMAIN_DELAY
                echo -e "${GREEN}Done${NC}"
            fi
        fi
    done

    log "\n${GREEN}════════════════════════════════════════════════════════════${NC}"
    log "${GREEN}Round $round_num completed!${NC}"
    log "${PURPLE}════════════════════════════════════════════════════════════${NC}"

    log "\n${CYAN}Statistics:${NC}"
    log "  Total domains tested: $total"
    log "  ${BOLD_YELLOW}Domains with differences: $diff_cnt${NC}"
    log "  ${YELLOW}Domains with no records: $no_record_cnt${NC}"
    log "  ${BOLD_RED}Domains with errors: $err_cnt${NC}"
    log "  Consistent resolutions: $((total - diff_cnt))"

    if [ $diff_cnt -gt 0 ]; then
        log "\n${BOLD_YELLOW}⚠ Differences were detected in $diff_cnt domain(s)${NC}"
        log "${BOLD_YELLOW}  Check the difference log for details: $DIFF_LOG_FILE${NC}"
    fi
    if [ $no_record_cnt -gt 0 ]; then
        log "\n${YELLOW}ℹ No records found for $no_record_cnt domain(s)${NC}"
    fi
    if [ $err_cnt -gt 0 ]; then
        log "\n${BOLD_RED}✗ Errors occurred in $err_cnt domain(s)${NC}"
        log "${BOLD_RED}  Check the error log for details: $ERROR_LOG_FILE${NC}"
    fi

    # Finalize snapshot for this round
    if [ "$DAEMON_MODE" = "true" ]; then
        finalize_snapshot "$(date '+%Y-%m-%dT%H:%M:%S')"
        if [ "$round_num" -eq 1 ] && [ -f "$SNAPSHOT_FILE" ]; then
            log "${CYAN}Initial snapshot established${NC}"
        fi
    fi

    # Write Prometheus summary metrics
    run_ts=$(date +%s)
    write_prometheus_final "$total" "$diff_cnt" "$err_cnt" "$no_record_cnt" "$run_ts"
}
```

- [ ] **Step 2: Replace the existing main execution with a call to run_one_round**

After all the setup code (variable declarations, argument parsing, dependency checks, domain parsing, DNS server parsing, header echo — everything up to line ~1117 where `total=${#DOMAIN_ORDER[@]}` starts), replace from that point to the end of the file with:

```bash
# ---- Single-run mode ----
if [ "$DAEMON_MODE" = "false" ]; then
    run_one_round 1

# ---- Daemon mode ----
else
    log "${GREEN}Daemon mode: running every ${DAEMON_INTERVAL}s${NC}"
    [ "$DAEMON_MAX_ITER" -gt 0 ] && log "Max iterations: $DAEMON_MAX_ITER" || log "Max iterations: infinite"

    round_num=0
    while [ "$DAEMON_RUNNING" = "true" ]; do
        ((round_num++))
        [ "$DAEMON_MAX_ITER" -gt 0 ] && [ "$round_num" -ge "$DAEMON_MAX_ITER" ] && {
            log "${GREEN}Daemon mode: max iterations ($DAEMON_MAX_ITER) reached, exiting${NC}"
            DAEMON_RUNNING=false
            break
        }

        run_one_round "$round_num"

        if [ "$DAEMON_RUNNING" = "true" ]; then
            log "${CYAN}Sleeping ${DAEMON_INTERVAL}s until next round...${NC}"
            sleep "$DAEMON_INTERVAL"
        fi
    done

    log "${YELLOW}Daemon mode: total rounds completed: $round_num${NC}"
fi
```

- [ ] **Step 3: Syntax check**

```bash
bash -n dns_compare.sh && echo "Syntax OK" || echo "Syntax ERROR"
```

- [ ] **Step 4: Manual smoke test — single-run mode (backward compatibility)**

```bash
cd /Users/zhangyiming/dns_compare_pkg
timeout 60 bash dns_compare.sh -d www.example.com -t A 2>&1 | tail -10
```

Expected: Script runs one round, outputs results for www.example.com, exits normally.

- [ ] **Step 5: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: wrap main loop with daemon mode while-loop and run_one_round function"
```

---

### Task 5: Fixed-filename output files for daemon mode

**Files:**
- Modify: `dns_compare.sh` (add `init_daemon_output_files` function in "Daemon mode helpers" section)

**Interfaces:**
- Consumes: `DAEMON_MODE` flag, existing file variable names
- Produces: `init_daemon_output_files()` that sets fixed filenames for daemon mode

- [ ] **Step 1: Implement init_daemon_output_files function**

Add in the "Daemon mode helpers" section (after `compare_with_snapshot`):

```bash
# In daemon mode, use fixed filenames instead of per-round timestamped files
init_daemon_output_files() {
    LOG_FILE="dns_daemon.log"
    DIFF_LOG_FILE="dns_differences.log"
    ERROR_LOG_FILE="dns_errors.log"
    SUMMARY_FILE="dns_summary.txt"

    if [ "$ENABLE_GEOIP" = "true" ]; then
        GEOIP_LOG_FILE="dns_geoip.log"
    fi

    A_REPORT_FILE="dns_a_report.csv"
    CNAME_REPORT_FILE="dns_cname_report.csv"
    MX_REPORT_FILE="dns_mx_report.csv"
    SOA_REPORT_FILE="dns_soa_report.csv"
    TXT_REPORT_FILE="dns_txt_report.csv"

    # Truncate report files for fresh round (overwrite mode)
    if [ "$ENABLE_GEOIP" = "true" ]; then
        echo "Domain,DNS Name,DNS IP,Result (IP[COUNTRY])" > "$A_REPORT_FILE"
        echo "Domain,DNS Name,DNS IP,Result (CNAME Chain with IP[COUNTRY])" > "$CNAME_REPORT_FILE"
    else
        echo "Domain,DNS Name,DNS IP,Result" > "$A_REPORT_FILE"
        echo "Domain,DNS Name,DNS IP,Result (CNAME Chain)" > "$CNAME_REPORT_FILE"
    fi
    echo "Domain,DNS Name,DNS IP,Result" > "$MX_REPORT_FILE"
    echo "Domain,DNS Name,DNS IP,Result (SOA record - full line from AUTHORITY)" > "$SOA_REPORT_FILE"
    echo "Domain,DNS Name,DNS IP,Result (TXT record)" > "$TXT_REPORT_FILE"

    # Change log: append-only, init header on first creation
    [ ! -f "$CHANGE_LOG_FILE" ] && echo "DNS Change Log - Continuous Monitoring" > "$CHANGE_LOG_FILE"

    # Differences log: append-only
    [ ! -f "$DIFF_LOG_FILE" ] && echo "DNS Differences - Continuous Monitoring" > "$DIFF_LOG_FILE"

    # Error log: rotate by date
    ERROR_LOG_FILE="dns_errors_$(date +%Y%m%d).log"
}
```

- [ ] **Step 2: Syntax check**

```bash
bash -n dns_compare.sh && echo "Syntax OK"
```

- [ ] **Step 3: Manual test — verify fixed filenames in daemon mode**

```bash
cd /Users/zhangyiming/dns_compare_pkg
# Clean any leftover files
rm -f dns_a_report.csv dns_changes.log dns_differences.log dns_latest_snapshot.json dns_daemon.log

timeout 30 bash dns_compare.sh --daemon --max-iterations 2 --interval 5 -d www.example.com -t A >/dev/null 2>&1

# Check that fixed-name files exist
ls -la dns_a_report.csv dns_changes.log dns_differences.log dns_latest_snapshot.json dns_daemon.log dns_summary.txt 2>&1
```

Expected: All six files exist. `dns_latest_snapshot.json` contains valid JSON with a "timestamp" and "records" key.

- [ ] **Step 4: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: add fixed-filename output files for daemon mode"
```

---

### Task 6: systemd service file

**Files:**
- Create: `dns_compare.service` (in project root)

- [ ] **Step 1: Create the systemd service file**

Create `dns_compare.service` in `/Users/zhangyiming/dns_compare_pkg/`:

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
# Graceful shutdown timeout (must exceed max round duration)
TimeoutStopSec=120

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Commit**

```bash
git add dns_compare.service
git commit -m "feat: add systemd service file for daemon mode"
```

---

### Task 7: Update README with daemon mode documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add daemon mode section to README.md**

Add a new section after the existing usage/quick start section:

```markdown
## Daemon Mode (Continuous Monitoring)

Run the script as a persistent monitoring service with configurable detection intervals:

```bash
# Interactive daemon mode (foreground)
./dns_compare.sh --daemon --interval 30 -f domains.json

# Limit to N rounds
./dns_compare.sh --daemon --interval 60 --max-iterations 10 -f domains.json

# Custom change log path
./dns_compare.sh --daemon --interval 30 --change-log /var/log/dns-changes.log -f domains.json
```

### Daemon Mode Output Files

In daemon mode, output files use fixed names (overwritten each round):

| File | Description |
|------|-------------|
| `dns_latest_snapshot.json` | Current DNS state snapshot |
| `dns_changes.log` | Cumulative change log (append-only) |
| `dns_differences.log` | Cumulative differences log (append-only) |
| `dns_a_report.csv` | Latest round A record report |
| `dns_daemon.log` | Main daemon log |

### systemd Service

For production deployment, use the included systemd service:

```bash
sudo cp dns_compare.service /etc/systemd/system/
# Edit ExecStart and WorkingDirectory in the service file to match your paths
sudo systemctl daemon-reload
sudo systemctl enable --now dns-compare

# View logs
journalctl -u dns-compare -f
systemctl status dns-compare
```
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: add daemon mode documentation to README"
```
