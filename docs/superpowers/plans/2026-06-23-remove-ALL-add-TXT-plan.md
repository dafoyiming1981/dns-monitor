# Remove ALL / Add TXT Record Type — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the `ALL` record type from `dns_compare.sh` v7.18 and add `TXT` record comparison with automatic categorization (SPF/DMARC/DKIM/OTHER).

**Architecture:** In-place modification of the existing script. `ALL` case branches are deleted across resolve, display, CSV, Prometheus, and summary functions. A new `resolve_txt_record()` + `categorize_txt()` pair is added following the existing `resolve_<type>()` pattern. The `-t` flag requires explicit type — no default `ALL`.

**Tech Stack:** Bash 3.2+, dig, sed, awk, grep, python3 (YAML/JSON parsing)

## Global Constraints

- Version: v7.18 → bump to v8.0 in header and banner
- DNS_SERVERS: unchanged (114, Ali, Google, Tencent, Cloudflare)
- Query timeout/retries: `QUERY_TIMEOUT=5`, `QUERY_RETRIES=2`
- Output file naming: `dns_<name>_$(date +%Y%m%d_%H%M%S).<ext>`
- ALL must not appear anywhere in the codebase after changes
- Valid record types everywhere: `A|CNAME|MX|SOA|TXT`
- TXT categorization by prefix: `v=spf1`→SPF, `v=DMARC1`→DMARC, `v=DKIM1` or `k=rsa`/`k=ed25519`→DKIM, else→OTHER
- Prometheus metrics: no new metric names, reuse existing ones with `record_type="TXT"`
- Follow existing code patterns (pipe-delimited return format: `status|query_time|raw|display|error`)

---

### Task 1: Add TXT record resolution and categorization functions

**Files:**
- Modify: `dns_compare.sh` (in `dns_compare_pkg/`)

**Interfaces:**
- New function `categorize_txt()`: takes a TXT string, returns category label (SPF/DMARC/DKIM/OTHER)
- New function `resolve_txt_record()`: follows `resolve_mx_record()` pattern, returns `status|query_time|raw|display|error`
- New `"TXT"` case in `resolve_domain()` (around line ~483 area after SOA case is added)

- [ ] **Step 1: Add `categorize_txt()` helper function**

Insert after the `resolve_soa_record()` function (before `resolve_domain()`, around line 480):

```bash
# TXT record categorizer
# Classifies TXT strings by known prefix patterns
# Usage: categorize_txt "txt_string"
# Returns: category label (SPF, DMARC, DKIM, OTHER)
categorize_txt() {
    local txt="$1"
    # Strip leading/trailing whitespace and quotes
    txt=$(echo "$txt" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')
    case "$txt" in
        v=spf1*) echo "SPF" ;;
        v=DMARC1*) echo "DMARC" ;;
        v=DKIM1*|k=rsa*|k=ed25519*) echo "DKIM" ;;
        *) echo "OTHER" ;;
    esac
}
```

- [ ] **Step 2: Add `resolve_txt_record()` function**

Insert after `categorize_txt()`, before `resolve_domain()`:

```bash
resolve_txt_record() {
    local domain="$1" dns_ip="$2" dns_name="$3"
    local result=$(dig @"$dns_ip" "$domain" TXT +time="$QUERY_TIMEOUT" +tries="$QUERY_RETRIES" +stats 2>&1)
    local exit_code=$?
    local qtime=$(echo "$result" | grep "Query time:" | awk '{print $4}')
    # Extract all TXT strings from ANSWER SECTION
    local txt_lines=$(echo "$result" | grep -E '^[a-zA-Z0-9].*[[:space:]]TXT[[:space:]]' | sed 's/^[^"]*"\(.*\)"/\1/' | sed 's/"[[:space:]]*"/ /g')
    local status="SUCCESS"
    local err=""
    if [ $exit_code -ne 0 ]; then
        status="ERROR"; err="DNS query failed"
        echo "$result" | grep -q "connection timed out" && err="Connection timeout"
        echo "$result" | grep -q "no servers could be reached" && err="DNS server unreachable"
    elif [ -z "$qtime" ]; then
        status="ERROR"; err="No response"
    elif [ -z "$txt_lines" ]; then
        status="NO_RECORD"; err="No TXT record"
    fi
    [ -z "$qtime" ] && qtime="N/A"
    [ -z "$txt_lines" ] && txt_lines="N/A"
    # Format display: number each TXT entry with its category
    local display=""
    local idx=0
    while IFS= read -r txt; do
        [ -z "$txt" ] && continue
        local cat=$(categorize_txt "$txt")
        if [ -n "$display" ]; then
            display="${display}; TXT[${idx}][${cat}]:${txt}"
        else
            display="TXT[${idx}][${cat}]:${txt}"
        fi
        ((idx++))
    done <<< "$txt_lines"
    [ -z "$display" ] && display="N/A"
    echo "$status|$qtime|$txt_lines|$display|$err"
}
```

- [ ] **Step 3: Add `"TXT"` case to `resolve_domain()`**

In the `resolve_domain()` function's case statement, add after the `"SOA"` case (before the closing `esac`):

```bash
        "TXT")
            local r=$(resolve_txt_record "$domain" "$dns_ip" "$dns_name")
            local s=$(echo "$r" | cut -d'|' -f1)
            local t=$(echo "$r" | cut -d'|' -f2)
            local raw=$(echo "$r" | cut -d'|' -f3)
            local disp=$(echo "$r" | cut -d'|' -f4)
            local e=$(echo "$r" | cut -d'|' -f5)
            echo "$dns_name|$dns_ip|TXT|$s|$t|$raw|$disp|$e"
            ;;
```

- [ ] **Step 4: Quick smoke test**

```bash
cd dns_compare_pkg
bash -n dns_compare.sh && echo "Syntax OK"
./dns_compare.sh -d google.com -t TXT --no-geoip 2>&1 | head -30
```

Expected: Script runs, shows TXT records for google.com with categories. No bash syntax errors.

- [ ] **Step 5: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: add TXT record resolution with SPF/DMARC/DKIM/OTHER auto-categorization"
```

---

### Task 2: Remove ALL from resolve_domain and display logic

**Files:**
- Modify: `dns_compare.sh`

**Interfaces:**
- `resolve_domain()`: `"ALL"` case removed (lines ~520-546)
- `display_results()`: ALL branches removed, simplified to single-type display
- `get_record_type_name()`: ALL case removed

- [ ] **Step 1: Delete `"ALL"` case from `resolve_domain()`**

Remove the `"ALL"` case block in `resolve_domain()` (the entire case from `"ALL")` through the closing `;;`):

```bash
# DELETE THIS ENTIRE BLOCK:
        "ALL")
            local a=$(resolve_a_record "$domain" "$dns_ip" "$dns_name")
            local a_s=$(echo "$a" | cut -d'|' -f1)
            ... (through line 545)
            echo "$dns_name|$dns_ip|ALL|A:$a_s:$a_t:$a_raw:$a_disp:$a_e|CNAME:..."
            ;;
```

- [ ] **Step 2: Simplify `display_results()` — remove ALL branches**

Replace the entire `display_results()` function with a simplified single-type version:

```bash
display_results() {
    local domain="$1" record_type="$2" category="$3"
    shift 3
    local results=("$@")
    local baseline=""
    local has_differences=0

    # Collect baseline from first DNS server
    for r in "${results[@]}"; do
        local rt=$(echo "$r" | cut -d'|' -f3)
        [ "$rt" != "$record_type" ] && continue
        local status=$(echo "$r" | cut -d'|' -f4)
        local raw=$(echo "$r" | cut -d'|' -f6)
        [ -z "$baseline" ] && [ "$status" = "SUCCESS" ] && baseline="$raw"
        [ "$rt" = "CNAME" ] && [ -z "$baseline" ] && [ "$status" = "SUCCESS" ] && baseline=$(extract_chain_only "$raw")
        break
    done

    log "\n${PURPLE}────────────────────────────────────────────────────────────${NC}"
    log "${CYAN}▶ Domain: $domain${NC}"
    log "${CYAN}  Category: $category | Record Type: $(get_record_type_name "$record_type")${NC}"
    if [ "$ENABLE_GEOIP" = "true" ]; then
        log "${CYAN}  IP Geolocation: Enabled (IP[COUNTRY] format)${NC}"
    fi
    log "${PURPLE}────────────────────────────────────────────────────────────${NC}"

    local count=${#results[@]}
    local idx=0
    for r in "${results[@]}"; do
        local dns_name=$(echo "$r" | cut -d'|' -f1)
        local dns_ip=$(echo "$r" | cut -d'|' -f2)
        local rt=$(echo "$r" | cut -d'|' -f3)
        local status=$(echo "$r" | cut -d'|' -f4)
        local time_val=$(echo "$r" | cut -d'|' -f5)
        local raw=$(echo "$r" | cut -d'|' -f6)
        local display=$(echo "$r" | cut -d'|' -f7)
        local err=$(echo "$r" | cut -d'|' -f8)

        local is_diff=0
        if [ "$status" = "SUCCESS" ] && [ -n "$baseline" ]; then
            local compare_val="$raw"
            [ "$rt" = "CNAME" ] && compare_val=$(extract_chain_only "$raw")
            [ "$compare_val" != "$baseline" ] && is_diff=1
        fi

        local connector="├─"
        [ $((idx + 1)) -eq $count ] && connector="└─"

        if [ "$status" = "SUCCESS" ]; then
            if [ $is_diff -eq 1 ]; then
                printf "  ${BOLD_YELLOW}%-12s (%-15s) : %-10s | %s${NC}\n" "$dns_name" "$dns_ip" "$time_val" "$display"
                has_differences=1
            else
                printf "  ${GREEN}%-12s (%-15s) : %-10s | %s${NC}\n" "$dns_name" "$dns_ip" "$time_val" "$display"
            fi
        elif [ "$status" = "NO_RECORD" ]; then
            printf "  ${YELLOW}%-12s (%-15s) : %-10s | %s [No record found]${NC}\n" "$dns_name" "$dns_ip" "$time_val" "N/A"
        else
            printf "  ${BOLD_RED}%-12s (%-15s) : %-10s | %s [ERROR: %s]${NC}\n" "$dns_name" "$dns_ip" "$time_val" "N/A" "$err"
            log_error "$err" "$domain" "$dns_name" "$dns_ip" "$rt"
        fi
        ((idx++))
    done

    if [ "$record_type" = "TXT" ] && [ -z "$baseline" ]; then
        log "\n  ${YELLOW}No TXT records found for this domain${NC}"
    fi

    if [ $has_differences -eq 1 ]; then
        local ts=$(date '+%Y-%m-%d %H:%M:%S')
        log "${BOLD_YELLOW}  ⚠ DNS resolution differences detected for this domain!${NC}"
        log_difference "\n[$ts] DIFFERENCE | Domain: $domain | Record Type: $(get_record_type_name "$record_type")"
        echo "$domain: DIFFERENCES FOUND" >> "$SUMMARY_FILE"
    else
        log "${GREEN}  ✓ All DNS results consistent${NC}"
        echo "$domain: consistent" >> "$SUMMARY_FILE"
    fi
    return $has_differences
}
```

- [ ] **Step 3: Remove `get_record_type_name()` ALL case**

```bash
# In get_record_type_name(), delete this line:
        ALL) echo "All Record Types";;
```

- [ ] **Step 4: Quick smoke test**

```bash
cd dns_compare_pkg
bash -n dns_compare.sh && echo "Syntax OK"
./dns_compare.sh -d google.com -t A --no-geoip 2>&1 | head -20
```

- [ ] **Step 5: Commit**

```bash
git add dns_compare.sh
git commit -m "refactor: remove ALL record type from resolve and display logic"
```

---

### Task 3: Remove ALL from CSV, Prometheus, and Summary functions

**Files:**
- Modify: `dns_compare.sh`

**Interfaces:**
- `write_to_csv()`: Remove ALL branch, add TXT case
- `emit_dns_prometheus()`: Remove ALL blocks, single-type only
- `write_prometheus_final()`: Remove ALL block in baseline comparison

- [ ] **Step 1: Simplify `write_to_csv()`**

Replace the function:

```bash
write_to_csv() {
    local domain="$1" record_type="$2"
    shift 2
    local results=("$@")
    for r in "${results[@]}"; do
        local dns_name=$(echo "$r" | cut -d'|' -f1)
        local dns_ip=$(echo "$r" | cut -d'|' -f2)
        local rt=$(echo "$r" | cut -d'|' -f3)
        [ "$rt" != "$record_type" ] && continue
        local disp=$(echo "$r" | cut -d'|' -f7)
        case "$rt" in
            "A")    echo "$domain,$dns_name,$dns_ip,$disp" >> "$A_REPORT_FILE" ;;
            "CNAME") echo "$domain,$dns_name,$dns_ip,$disp" >> "$CNAME_REPORT_FILE" ;;
            "MX")   echo "$domain,$dns_name,$dns_ip,$disp" >> "$MX_REPORT_FILE" ;;
            "SOA")  echo "$domain,$dns_name,$dns_ip,$disp" >> "$SOA_REPORT_FILE" ;;
            "TXT")  echo "$domain,$dns_name,$dns_ip,$disp" >> "$TXT_REPORT_FILE" ;;
        esac
    done
}
```

- [ ] **Step 2: Simplify `emit_dns_prometheus()`**

Remove the `if [ "$rt" = "ALL" ]; then ... else ... fi` wrapper. The timestamp section becomes:

```bash
    for r in "${results[@]}"; do
        local dns_name=$(echo "$r" | cut -d'|' -f1)
        local rt=$(echo "$r" | cut -d'|' -f3)
        local now_ts=$(date '+%s')
        PROM_TIMESTAMP_LINES+=("dns_query_last_test_timestamp{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\"} $now_ts")
    done
```

The metrics emission section keeps only the non-ALL branch (the `else` content from lines 933-972).

- [ ] **Step 3: Simplify `write_prometheus_final()`**

In the baseline comparison loop, replace the ALL-specific parsing with:

```bash
        while IFS= read -r r; do
            [ -z "$r" ] && continue
            local dns_name=$(echo "$r" | cut -d'|' -f1)
            local status=$(echo "$r" | cut -d'|' -f4)
            local raw=$(echo "$r" | cut -d'|' -f6)
            srv_values+=("STATUS:${status}|RAW:${raw}")
        done < "$tmp_file"
```

- [ ] **Step 4: Quick smoke test**

```bash
cd dns_compare_pkg
bash -n dns_compare.sh && echo "Syntax OK"
```

- [ ] **Step 5: Commit**

```bash
git add dns_compare.sh
git commit -m "refactor: remove ALL from CSV, Prometheus, and summary functions"
```

---

### Task 4: Update config parsers, validators, defaults, and version

**Files:**
- Modify: `dns_compare.sh`

- [ ] **Step 1: Update JSON/YAML parser (Python embedded)**

In `parse_json_yaml_file()`:

```python
# OLD line 137:
    rtype = item.get('type', 'ALL').strip().upper()
# NEW:
    rtype = item.get('type', 'A').strip().upper()

# OLD lines 139-140:
    if rtype not in ('A', 'CNAME', 'MX', 'SOA', 'ALL'):
        rtype = 'ALL'
# NEW:
    if rtype not in ('A', 'CNAME', 'MX', 'SOA', 'TXT'):
        rtype = 'A'
```

- [ ] **Step 2: Update text config parser**

Line 226: `local current_record_type="ALL"` → `local current_record_type="A"`

Lines 236-237:
```bash
# OLD:
                A|CNAME|MX|SOA|ALL) log ...
                *) ... current_record_type="ALL" ;;
# NEW:
                A|CNAME|MX|SOA|TXT) log ...
                *) ... current_record_type="A" ;;
```

Line 243: `current_record_type="ALL"` → `current_record_type="A"`

- [ ] **Step 3: Update `add_single_domain()` validator**

Line 273: `A|CNAME|MX|SOA|ALL` → `A|CNAME|MX|SOA|TXT`

- [ ] **Step 4: Remove default CURRENT_TYPE, add validation**

Line 1153: `CURRENT_TYPE="ALL"` → `CURRENT_TYPE=""`

After the argument parsing loop (after line 1187), add:

```bash
# Validate that all CMD_TYPES are set (no empty types)
for ct in "${CMD_TYPES[@]}"; do
    [ -z "$ct" ] && { echo -e "${RED}Error: must specify record type with -t (A/CNAME/MX/SOA/TXT)${NC}"; show_help; exit 1; }
done
```

- [ ] **Step 5: Update help text**

Line 1120: `(A, CNAME, MX, SOA, ALL)` → `(A, CNAME, MX, SOA, TXT)`

Lines 1130-1135, replace Record Types section:

```
Record Types:
  A      - IPv4 Address records (with country codes if geoip enabled)
  CNAME  - Canonical Name records (shows full chain)
  MX     - Mail Exchange records
  SOA    - Start of Authority records (shows full AUTHORITY SECTION line)
  TXT    - Text records (auto-categorized: SPF/DMARC/DKIM/OTHER)
```

- [ ] **Step 6: Update version to v8.0**

Line 4: `# Multi-DNS comparison test script v7.18` → `# Multi-DNS comparison test script v8.0`

Add after line 4:
```bash
# - Removed ALL record type
# - Added TXT record support with auto-categorization
```

Line ~1112 (show_help): `v7.18` → `v8.0`
Line ~1217 (banner): `v7.18` → `v8.0`
Line ~1218 (subtitle): `(SOA from AUTHORITY SECTION, GeoIP display)` → `(SOA from AUTHORITY SECTION, TXT auto-categorization, GeoIP display)`
Lines ~1250, 1261, 1266 (log headers): `v7.18` → `v8.0`

- [ ] **Step 7: Quick smoke test**

```bash
cd dns_compare_pkg
bash -n dns_compare.sh && echo "Syntax OK"
./dns_compare.sh -d google.com 2>&1 | head -5  # Should error: must specify -t
./dns_compare.sh -d google.com -t A --no-geoip 2>&1 | head -10
./dns_compare.sh -d google.com -t TXT --no-geoip 2>&1 | head -20
```

- [ ] **Step 8: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: update parsers/defaults to remove ALL, add TXT; bump to v8.0"
```

---

### Task 5: Add TXT report file support

**Files:**
- Modify: `dns_compare.sh`

- [ ] **Step 1: Add TXT_REPORT_FILE variable**

After line 44 (SOA_REPORT_FILE):

```bash
TXT_REPORT_FILE="dns_txt_report_$(date +%Y%m%d_%H%M%S).csv"
```

- [ ] **Step 2: Add TXT CSV header**

After line 1285 (SOA_REPORT_FILE header init):

```bash
echo "Domain,DNS Name,DNS IP,TXT Category,TXT Value" > "$TXT_REPORT_FILE"
```

- [ ] **Step 3: Add to output listing**

After the SOA record report log line (~1431):

```bash
log "  TXT record report: $TXT_REPORT_FILE"
```

- [ ] **Step 4: Smoke test**

```bash
cd dns_compare_pkg
bash -n dns_compare.sh && echo "Syntax OK"
```

- [ ] **Step 5: Commit**

```bash
git add dns_compare.sh
git commit -m "feat: add TXT report CSV file support"
```

---

### Task 6: Update README and example files

**Files:**
- Modify: `README.md`
- Modify: `examples/domains.yaml`
- Modify: `examples/domains.json`
- Modify: `examples/domains.txt`

- [ ] **Step 1: Update README.md**

- Title line 1: `v7.18` → `v8.0`
- Feature list line 22: remove "ALL 模式", add "TXT 记录（自动分类：SPF/DMARC/DKIM/OTHER）"
- CLI params table line 83: `A/CNAME/MX/SOA/ALL` → `A/CNAME/MX/SOA/TXT`
- Quick start: add `./dns_compare.sh -d google.com -t TXT` example
- YAML example header comment: `A, CNAME, MX, SOA, ALL` → `A, CNAME, MX, SOA, TXT`
- Add TXT example in YAML section:
  ```yaml
  - domain: google.com
    type: TXT
    category: txt_spf
  ```
- Text config format: add `[txt_spf:TXT]` example
- Output file table: add `dns_txt_report_*.csv`

- [ ] **Step 2: Update domains.yaml**

Header comment: `A, CNAME, MX, SOA, ALL` → `A, CNAME, MX, SOA, TXT`

Add at end of domains list:
```yaml
  - domain: google.com
    type: TXT
    category: txt_spf
```

- [ ] **Step 3: Update domains.json**

Add to domains array:
```json
{"domain": "google.com", "type": "TXT", "category": "txt_spf"}
```

- [ ] **Step 4: Update domains.txt**

Add at end:
```
[txt_spf:TXT]
google.com
```

- [ ] **Step 5: Verify no ALL in examples**

```bash
grep -rn "ALL" examples/ README.md
```

Expected: No matches for ALL as record type.

- [ ] **Step 6: Commit**

```bash
git add README.md examples/
git commit -m "docs: update README and examples for v8.0 (remove ALL, add TXT)"
```

---

### Task 7: Update Grafana dashboard and alert rules

**Files:**
- Modify: `grafana_dashboard.json`
- Modify: `alert_rules/dns_compare_rules.yml`

- [ ] **Step 1: Add TXT panel to Grafana dashboard**

After the last existing row in `grafana_dashboard.json` (after the "Domain Details" row), insert a new row with a TXT Record Comparison Table panel:

```json
{
  "collapsed": false,
  "gridPos": { "h": 1, "w": 24, "x": 0, "y": <next-y> },
  "id": 2000,
  "title": "TXT Record Analysis",
  "type": "row"
},
{
  "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
  "fieldConfig": {
    "defaults": {
      "color": { "mode": "thresholds" },
      "custom": {
        "align": "auto",
        "cellOptions": { "type": "auto" },
        "inspect": false
      },
      "thresholds": { "mode": "absolute", "steps": [{ "color": "green", "value": null }, { "color": "red", "value": 80 }] }
    },
    "overrides": []
  },
  "gridPos": { "h": 10, "w": 24, "x": 0, "y": <next-y+1> },
  "id": 2001,
  "options": { "cellHeight": "sm", "footer": { "show": true }, "frameIndex": 0, "showHeader": true },
  "targets": [
    {
      "datasource": { "type": "prometheus", "uid": "${DS_PROMETHEUS}" },
      "expr": "dns_query_duration_ms{record_type=\"TXT\"}",
      "format": "table",
      "instant": true,
      "legendFormat": "",
      "refId": "A"
    }
  ],
  "title": "TXT Record Comparison",
  "transformations": [
    { "id": "organize", "options": { "excludeByName": { "Time": true, "__name__": true, "job": true, "instance": true }, "indexByName": {}, "renameByName": {} } }
  ],
  "type": "table"
}
```

Adjust `"y"` positions to follow the last existing panel's y coordinate.

- [ ] **Step 2: Verify JSON validity**

```bash
python3 -c "import json; json.load(open('grafana_dashboard.json'))" && echo "JSON OK"
```

- [ ] **Step 3: Update alert rules**

In `alert_rules/dns_compare_rules.yml`, the existing `DNSResolutionDifference` rule already covers TXT via `record_type` label. Update the annotation to mention TXT:

```yaml
# In DNSResolutionDifference annotations.description:
description: >
  DNS服务器 {{ $labels.server }} 对 {{ $labels.domain }}
  的 {{ $labels.record_type }} 记录（含 TXT 自动分类）解析结果与基线不一致。
  请检查 DNS 配置和 GSLB 调度策略。
```

- [ ] **Step 4: Commit**

```bash
git add grafana_dashboard.json alert_rules/
git commit -m "feat: add TXT panel to Grafana, update alert annotations"
```

---

### Task 8: Final integration test

**Files:**
- All modified files

- [ ] **Step 1: Full syntax/format check**

```bash
bash -n dns_compare.sh && echo "Bash Syntax OK"
python3 -c "import json; json.load(open('grafana_dashboard.json'))" && echo "JSON OK"
python3 -c "import yaml; yaml.safe_load(open('examples/domains.yaml'))" && echo "YAML OK"
python3 -c "import json; json.load(open('examples/domains.json'))" && echo "JSON OK"
```

- [ ] **Step 2: Functional test — TXT records**

```bash
./dns_compare.sh -d google.com -t TXT --no-geoip 2>&1
```

Expected: Shows TXT records with SPF/DMARC/DKIM/OTHER categories.

- [ ] **Step 3: Functional test — A records**

```bash
./dns_compare.sh -d google.com -t A --no-geoip 2>&1
```

Expected: Shows A records. No ALL references.

- [ ] **Step 4: Verify no ALL remains**

```bash
grep -n "ALL" dns_compare.sh README.md examples/domains.*
```

Expected: No matches.

- [ ] **Step 5: Functional test — missing type error**

```bash
./dns_compare.sh -d google.com 2>&1
```

Expected: `Error: must specify record type with -t (A/CNAME/MX/SOA/TXT)`

- [ ] **Step 6: Final commit**

```bash
git add -A
git commit -m "chore: final v8.0 integration test and cleanup"
```
