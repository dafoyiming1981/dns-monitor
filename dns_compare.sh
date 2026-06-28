#!/bin/bash

# ====================================================
# Multi-DNS comparison test script v8.0
# - Removed ALL record type
# - Added TXT record support with auto-categorization
# Usage: ./dns_compare.sh [options] [domain list file]
# ====================================================

# Configuration - Modify according to your needs
# ----------------------------------------------------
DEFAULT_DOMAIN_FILE="domains.txt"
QUERY_DELAY=2
DOMAIN_DELAY=3
QUERY_RETRIES=2
QUERY_TIMEOUT=5
MAX_CNAME_DEPTH=10
ENABLE_GEOIP=true
LOCAL_GEOIP_CSV="IP2LOCATION-LITE-DB1.CSV"
# Prometheus textfile collector directory (empty = disabled)
# node_exporter must be configured with --collector.textfile.directory pointing here
PROMETHEUS_TEXTFILE_DIR="/run/textfile_collector"
# ----------------------------------------------------

DNS_SERVERS="
114@114.114.114.114
Ali@223.5.5.5
Google@8.8.8.8
Tencent@119.29.29.29
Cloudflare@1.1.1.1
"

LOG_FILE="dns_run.log"
SUMMARY_FILE="dns_run.log"  # differences/errors appended to main log
RESULTS_CSV="dns_results.csv"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
BOLD_RED='\033[1;31m'
BOLD_YELLOW='\033[1;33m'
BOLD_GREEN='\033[1;32m'
BOLD_CYAN='\033[1;36m'
NC='\033[0m'

# ====================================================
# Logging functions
# ====================================================

log() { echo -e "$1" | tee -a "$LOG_FILE"; }
log_difference() { echo -e "[DIFF] $1" | tee -a "$LOG_FILE"; }
log_error() {
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    local domain="${2:-unknown}"
    local dns_name="${3:-unknown}"
    local dns_ip="${4:-unknown}"
    local record_type="${5:-unknown}"
    local errmsg="$1"
    echo -e "[ERROR] [$ts] Domain: $domain | DNS: $dns_name ($dns_ip) | Type: $record_type | Error: $errmsg" | tee -a "$LOG_FILE"
}
log_geoip() { [ "$ENABLE_GEOIP" = "true" ] && echo -e "[GEOIP] $1" | tee -a "$LOG_FILE"; }

# ====================================================
# Dependency check
# ====================================================

check_dependencies() {
    local deps=("dig" "awk" "grep" "cut" "sed")
    local missing=()
    for cmd in "${deps[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        echo -e "${RED}Error: Missing required commands: ${missing[*]}${NC}"
        exit 1
    fi
}

# ====================================================
# JSON/YAML domain file parser
# ====================================================

parse_json_yaml_file() {
    local file="$1"
    [ ! -f "$file" ] && echo -e "${RED}Error: File does not exist: $file${NC}" >&2 && return 1
    log "${BLUE}Parsing JSON/YAML domain file: $file${NC}"

    # Use python3 to parse and output tab-separated: domain\ttype\tcategory
    local parsed
    parsed=$(python3 -c "
import json, sys, os
filepath = '$file'
ext = os.path.splitext(filepath)[1].lower()
try:
    if ext in ('.json',):
        with open(filepath) as f:
            data = json.load(f)
    elif ext in ('.yaml', '.yml'):
        import yaml
        with open(filepath) as f:
            data = yaml.safe_load(f)
    else:
        # Try JSON first, fall back to YAML
        try:
            with open(filepath) as f:
                data = json.load(f)
        except:
            import yaml
            with open(filepath) as f:
                data = yaml.safe_load(f)
except Exception as e:
    print(f'Error: Failed to parse {filepath}: {e}', file=sys.stderr)
    sys.exit(1)

items = data.get('domains', [])
if not items:
    print('Error: No domains found in file', file=sys.stderr)
    sys.exit(1)

for item in items:
    domain = item.get('domain', '').strip()
    rtype = item.get('type', 'A').strip().upper()
    category = item.get('category', 'default').strip()
    if rtype not in ('A', 'CNAME', 'MX', 'SOA', 'TXT'):
        rtype = 'A'
    stability_dns = item.get('stability_dns_servers', [])
    stability_dns_str = '|'.join(stability_dns) if stability_dns else ''
    if domain:
        print(f'{domain}\t{rtype}\t{category}\t{stability_dns_str}')
" 2>&1) || { log "${RED}Error parsing JSON/YAML: $parsed${NC}"; return 1; }

    local idx=0
    while IFS=$'\t' read -r domain rtype category stability_dns; do
        [ -z "$domain" ] && continue
        DOMAIN_ORDER[$idx]="$domain"
        DOMAIN_CONFIG_ARR[$idx]="$rtype"
        DOMAIN_CATEGORY_ARR[$idx]="$category"
        DOMAIN_STABILITY_DNS_ARR[$idx]="$stability_dns"
        ((idx++))
    done <<< "$parsed"

    log "  Total domains parsed: $idx"
    if [ $idx -gt 0 ]; then
        log "\n${CYAN}Domain Configuration Summary:${NC}"
        local current_cat=""
        for ((i=0; i<idx; i++)); do
            local cat="${DOMAIN_CATEGORY_ARR[$i]}"
            local rectype="${DOMAIN_CONFIG_ARR[$i]}"
            [ "$cat" != "$current_cat" ] && current_cat="$cat" && log "  ${PURPLE}[$cat]${NC} (Record Type: $rectype)"
            log "    - ${DOMAIN_ORDER[$i]}"
        done
    fi
    return 0
}

# ====================================================
# GeoIP helpers
# ====================================================

ip_to_int() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    echo $((a * 256**3 + b * 256**2 + c * 256 + d))
}

get_ip_country() {
    local ip="$1"
    local country=""
    [ -z "$ip" ] || [ "$ip" = "N/A" ] || [ "$ip" = "no A record" ] || [[ "$ip" != *"."* ]] && echo "" && return
    local first_ip=$(echo "$ip" | awk '{print $1}')
    [ -n "${IP_COUNTRY_CACHE[$first_ip]}" ] && echo "${IP_COUNTRY_CACHE[$first_ip]}" && return
    if [ -f "$LOCAL_GEOIP_CSV" ]; then
        local ip_int=$(ip_to_int "$first_ip")
        country=$(awk -F, -v ip="$ip_int" '
            function clean(s) { gsub(/^"|"$/, "", s); return s }
            { if (clean($1)+0 <= ip && ip <= clean($2)+0) { print clean($3); exit } }
        ' "$LOCAL_GEOIP_CSV" 2>/dev/null)
        [ -z "$country" ] && country="??"
    else
        country="??"
    fi
    IP_COUNTRY_CACHE["$first_ip"]="$country"
    echo "$country"
}

# ====================================================
# Domain file parsing
# ====================================================

# Parallel index arrays for domain config (works on bash 3.x and 4+)
DOMAIN_ORDER=()
DOMAIN_CONFIG_ARR=()
DOMAIN_CATEGORY_ARR=()
DOMAIN_STABILITY_DNS_ARR=()

parse_domain_file() {
    local file="$1"
    [ ! -f "$file" ] && echo -e "${RED}Error: Domain list file does not exist: $file${NC}" >&2 && return 1
    # Detect JSON/YAML by extension
    case "$file" in
        *.json|*.yml|*.yaml)
            parse_json_yaml_file "$file"
            return $?
            ;;
    esac
    log "${BLUE}Parsing domain list file: $file${NC}"
    local current_category="default"
    local current_record_type="A"
    local domain_count=0
    local idx=0
    while IFS= read -r line || [ -n "$line" ]; do
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -z "$line" ] && continue
        if [[ "$line" =~ ^\[([^:]+):([^]]+)\]$ ]]; then
            current_category="${BASH_REMATCH[1]}"
            current_record_type="${BASH_REMATCH[2]}"
            case "$current_record_type" in
                A|CNAME|MX|SOA|TXT) log "  Category: $current_category (Record Type: $current_record_type)" ;;
                *) echo -e "${YELLOW}Warning: Invalid record type '$current_record_type', using A${NC}"; current_record_type="A" ;;
            esac
            continue
        fi
        if [[ "$line" =~ ^\[([^]]+)\]$ ]]; then
            current_category="${BASH_REMATCH[1]}"
            [ -z "$current_record_type" ] && current_record_type="A"
            log "  Category: $current_category (Record Type: $current_record_type)"
            continue
        fi
        [[ "$line" =~ ^# ]] && continue
        DOMAIN_ORDER[$idx]="$line"
        DOMAIN_CONFIG_ARR[$idx]="$current_record_type"
        DOMAIN_CATEGORY_ARR[$idx]="$current_category"
        ((idx++))
        ((domain_count++))
    done < "$file"
    log "  Total domains parsed: $domain_count"
    if [ $domain_count -gt 0 ]; then
        log "\n${CYAN}Domain Configuration Summary:${NC}"
        local current_cat=""
        for ((i=0; i<idx; i++)); do
            local cat="${DOMAIN_CATEGORY_ARR[$i]}"
            local rectype="${DOMAIN_CONFIG_ARR[$i]}"
            [ "$cat" != "$current_cat" ] && current_cat="$cat" && log "  ${PURPLE}[$cat]${NC} (Record Type: $rectype)"
            log "    - ${DOMAIN_ORDER[$i]}"
        done
    fi
    return 0
}

CMD_DOMAIN=""
CMD_TYPE=""

add_single_domain() {
    local domain="$1"
    local record_type="$2"
    case "$record_type" in A|CNAME|MX|SOA|TXT) ;; *) echo -e "${RED}Error: Invalid record type '$record_type'${NC}" >&2; return 1 ;; esac
    local idx=${#DOMAIN_ORDER[@]}
    DOMAIN_ORDER[$idx]="$domain"
    DOMAIN_CONFIG_ARR[$idx]="$record_type"
    DOMAIN_CATEGORY_ARR[$idx]="command-line"
    CMD_DOMAIN="$domain"
    CMD_TYPE="$record_type"
    log "${BLUE}Added single domain: $domain (Record Type: $record_type)${NC}"
    return 0
}

get_record_type_name() {
    case "$1" in
        A) echo "A Record";;
        CNAME) echo "CNAME Record";;
        MX) echo "MX Record";;
        SOA) echo "SOA Record";;
        TXT) echo "TXT Record";;
        *) echo "Unknown";;
    esac
}

# ====================================================
# CNAME chain helpers
# ====================================================

extract_chain_only() {
    local cname_display="$1"
    [[ "$cname_display" == *" = "* ]] && echo "${cname_display%% = *}" || echo "$cname_display"
}

resolve_cname_chain() {
    local domain="$1" dns_ip="$2" depth="$3" chain_output="$4"
    [ -z "$depth" ] && depth=0
    [ -z "$chain_output" ] && chain_output="$domain"
    [ $depth -ge $MAX_CNAME_DEPTH ] && echo "ERROR|MAX_DEPTH|$chain_output|Maximum CNAME chain depth exceeded" && return 1
    local result=$(dig @"$dns_ip" "$domain" CNAME +time="$QUERY_TIMEOUT" +tries="$QUERY_RETRIES" +stats 2>&1)
    local exit_code=$?
    local qtime=$(echo "$result" | grep "Query time:" | awk '{print $4}')
    [ -z "$qtime" ] && qtime="N/A" || qtime="${qtime}ms"
    local target=$(echo "$result" | grep -E '^[a-zA-Z0-9].*[[:space:]]CNAME[[:space:]]' | awk '{print $5}' | head -1)
    if [ $exit_code -ne 0 ]; then
        local err="DNS query failed (exit code: $exit_code)"
        echo "$result" | grep -q "connection timed out" && err="Connection timeout"
        echo "$result" | grep -q "no servers could be reached" && err="DNS server unreachable"
        echo "ERROR|$qtime|$chain_output|$err"
        return 1
    fi
    if [ -z "$target" ]; then
        local a_res=$(dig @"$dns_ip" "$domain" A +time="$QUERY_TIMEOUT" +tries="$QUERY_RETRIES" +stats 2>&1)
        local ips=$(echo "$a_res" | grep -E '^[a-zA-Z0-9].*[[:space:]]A[[:space:]]' | awk '{print $5}' | sort -u | tr '\n' ' ')
        if [ -n "$ips" ]; then
            echo "A_RECORD|$qtime|$chain_output|$ips"
            return 0
        else
            echo "NO_RECORD|$qtime|$chain_output|No A or CNAME record found"
            return 1
        fi
    fi
    local new_chain="$chain_output -> $target"
    local next_result=$(resolve_cname_chain "$target" "$dns_ip" $((depth+1)) "$new_chain")
    local next_status=$(echo "$next_result" | cut -d'|' -f1)
    local next_time=$(echo "$next_result" | cut -d'|' -f2)
    local next_chain=$(echo "$next_result" | cut -d'|' -f3)
    local next_data=$(echo "$next_result" | cut -d'|' -f4)
    echo "$next_status|$qtime|$next_chain|$next_data"
}

# ====================================================
# Resolution functions (return raw + display)
# ====================================================

resolve_a_record() {
    local domain="$1" dns_ip="$2" dns_name="$3"
    local result=$(dig @"$dns_ip" "$domain" A +time="$QUERY_TIMEOUT" +tries="$QUERY_RETRIES" +stats 2>&1)
    local exit_code=$?
    local qtime=$(echo "$result" | grep "Query time:" | awk '{print $4}')
    local ips=$(echo "$result" | grep -E '^[a-zA-Z0-9].*[[:space:]]A[[:space:]]' | awk '{print $5}' | sort -u | tr '\n' ' ')
    local status="SUCCESS"
    local err=""
    if [ $exit_code -ne 0 ]; then
        status="ERROR"; err="DNS query failed"
        echo "$result" | grep -q "connection timed out" && err="Connection timeout"
        echo "$result" | grep -q "no servers could be reached" && err="DNS server unreachable"
    elif [ -z "$qtime" ]; then
        status="ERROR"; err="No response"
    elif [ -z "$ips" ]; then
        status="NO_RECORD"; err="No A record"
    fi
    [ -z "$qtime" ] && qtime="N/A"
    [ -z "$ips" ] && ips="N/A"
    local raw="$ips"
    local display="$ips"
    if [ "$ENABLE_GEOIP" = "true" ] && [ "$status" = "SUCCESS" ] && [ "$ips" != "N/A" ]; then
        local ip_array=($ips)
        local formatted=()
        for ip in "${ip_array[@]}"; do
            local country=$(get_ip_country "$ip")
            if [ -n "$country" ] && [ "$country" != "??" ]; then
                formatted+=("${ip}[${country}]")
            else
                formatted+=("$ip")
            fi
        done
        display=$(IFS=' '; echo "${formatted[*]}")
    fi
    echo "$status|$qtime|$raw|$display|$err"
}

resolve_cname_record() {
    local domain="$1" dns_ip="$2" dns_name="$3"
    local cname_result=$(resolve_cname_chain "$domain" "$dns_ip" 0 "")
    local status=$(echo "$cname_result" | cut -d'|' -f1)
    local qtime=$(echo "$cname_result" | cut -d'|' -f2)
    local chain=$(echo "$cname_result" | cut -d'|' -f3)
    local final=$(echo "$cname_result" | cut -d'|' -f4)
    local err=""
    local raw=""
    local display=""
    case "$status" in
        "A_RECORD")
            status="SUCCESS"
            raw="$final"
            display="$final"
            if [ "$ENABLE_GEOIP" = "true" ] && [ -n "$final" ] && [ "$final" != " " ]; then
                local country=$(get_ip_country "$final")
                if [ -n "$country" ] && [ "$country" != "??" ]; then
                    display="${final}[${country}]"
                fi
            fi
            if [ -n "$chain" ] && [ "$chain" != " " ] && [ "$chain" != "$domain" ]; then
                display="$chain = $display"
                raw="$chain = $raw"
            fi
            ;;
        "NO_RECORD")
            status="NO_RECORD"
            err="No CNAME or A record found"
            raw=""
            display="NO RECORD"
            ;;
        "ERROR")
            status="ERROR"
            err="$final"
            raw=""
            display="ERROR"
            ;;
    esac
    [ -z "$qtime" ] && qtime="N/A"
    echo "$status|$qtime|$raw|$display|$err"
}

resolve_mx_record() {
    local domain="$1" dns_ip="$2" dns_name="$3"
    local result=$(dig @"$dns_ip" "$domain" MX +time="$QUERY_TIMEOUT" +tries="$QUERY_RETRIES" +stats 2>&1)
    local exit_code=$?
    local qtime=$(echo "$result" | grep "Query time:" | awk '{print $4}')
    local mx=$(echo "$result" | grep -E '^[a-zA-Z0-9].*[[:space:]]MX[[:space:]]' | awk '{print $5, $6}' | sort -n | tr '\n' '; ')
    local status="SUCCESS"
    local err=""
    if [ $exit_code -ne 0 ]; then
        status="ERROR"; err="DNS query failed"
        echo "$result" | grep -q "connection timed out" && err="Connection timeout"
        echo "$result" | grep -q "no servers could be reached" && err="DNS server unreachable"
    elif [ -z "$qtime" ]; then
        status="ERROR"; err="No response"
    elif [ -z "$mx" ]; then
        status="NO_RECORD"; err="No MX record"
    fi
    [ -z "$qtime" ] && qtime="N/A"
    [ -z "$mx" ] && mx="N/A"
    echo "$status|$qtime|$mx|$mx|$err"
}

# 🔧 FIXED: SOA record extraction from AUTHORITY SECTION
resolve_soa_record() {
    local domain="$1" dns_ip="$2" dns_name="$3"
    # Get AUTHORITY SECTION only
    local authority=$(dig @"$dns_ip" "$domain" SOA +time="$QUERY_TIMEOUT" +tries="$QUERY_RETRIES" +noall +authority 2>&1)
    local exit_code=$?
    # Get stats separately for query time
    local stats=$(dig @"$dns_ip" "$domain" SOA +time="$QUERY_TIMEOUT" +tries="$QUERY_RETRIES" +stats 2>&1)
    local qtime=$(echo "$stats" | grep "Query time:" | awk '{print $4}')

    # Extract SOA line: ignore comment lines (starting with ;) and empty lines, take first line containing "SOA"
    local soa_line=$(echo "$authority" | grep -v '^;' | grep -v '^$' | grep "SOA" | head -1)

    local status="SUCCESS"
    local err=""
    if [ $exit_code -ne 0 ]; then
        status="ERROR"; err="DNS query failed"
        echo "$stats" | grep -q "connection timed out" && err="Connection timeout"
        echo "$stats" | grep -q "no servers could be reached" && err="DNS server unreachable"
    elif [ -z "$qtime" ]; then
        status="ERROR"; err="No response"
    elif [ -z "$soa_line" ]; then
        status="NO_RECORD"; err="No SOA record in AUTHORITY section"
    fi

    [ -z "$qtime" ] && qtime="N/A"
    [ -z "$soa_line" ] && soa_line="N/A"

    local raw="$soa_line"
    local display="$soa_line"
    echo "$status|$qtime|$raw|$display|$err"
}

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

resolve_domain() {
    local domain="$1" dns_ip="$2" dns_name="$3" type="$4"
    case "$type" in
        "A")
            local r=$(resolve_a_record "$domain" "$dns_ip" "$dns_name")
            local s=$(echo "$r" | cut -d'|' -f1)
            local t=$(echo "$r" | cut -d'|' -f2)
            local raw=$(echo "$r" | cut -d'|' -f3)
            local disp=$(echo "$r" | cut -d'|' -f4)
            local e=$(echo "$r" | cut -d'|' -f5)
            echo "$dns_name|$dns_ip|A|$s|$t|$raw|$disp|$e"
            ;;
        "CNAME")
            local r=$(resolve_cname_record "$domain" "$dns_ip" "$dns_name")
            local s=$(echo "$r" | cut -d'|' -f1)
            local t=$(echo "$r" | cut -d'|' -f2)
            local raw=$(echo "$r" | cut -d'|' -f3)
            local disp=$(echo "$r" | cut -d'|' -f4)
            local e=$(echo "$r" | cut -d'|' -f5)
            echo "$dns_name|$dns_ip|CNAME|$s|$t|$raw|$disp|$e"
            ;;
        "MX")
            local r=$(resolve_mx_record "$domain" "$dns_ip" "$dns_name")
            local s=$(echo "$r" | cut -d'|' -f1)
            local t=$(echo "$r" | cut -d'|' -f2)
            local raw=$(echo "$r" | cut -d'|' -f3)
            local disp=$(echo "$r" | cut -d'|' -f4)
            local e=$(echo "$r" | cut -d'|' -f5)
            echo "$dns_name|$dns_ip|MX|$s|$t|$raw|$disp|$e"
            ;;
        "SOA")
            local r=$(resolve_soa_record "$domain" "$dns_ip" "$dns_name")
            local s=$(echo "$r" | cut -d'|' -f1)
            local t=$(echo "$r" | cut -d'|' -f2)
            local raw=$(echo "$r" | cut -d'|' -f3)
            local disp=$(echo "$r" | cut -d'|' -f4)
            local e=$(echo "$r" | cut -d'|' -f5)
            echo "$dns_name|$dns_ip|SOA|$s|$t|$raw|$disp|$e"
            ;;
        "TXT")
            local r=$(resolve_txt_record "$domain" "$dns_ip" "$dns_name")
            local s=$(echo "$r" | cut -d'|' -f1)
            local t=$(echo "$r" | cut -d'|' -f2)
            local raw=$(echo "$r" | cut -d'|' -f3)
            local disp=$(echo "$r" | cut -d'|' -f4)
            local e=$(echo "$r" | cut -d'|' -f5)
            echo "$dns_name|$dns_ip|TXT|$s|$t|$raw|$disp|$e"
            ;;
    esac
}

# ====================================================
# Display function (with SOA support)
# ====================================================

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
        [ "$rt" = "CNAME" ] && [ "$status" = "SUCCESS" ] && baseline=$(extract_chain_only "$raw")
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

# ====================================================
# CSV writing (with SOA)
# ====================================================

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
        echo "$domain,$dns_name,$dns_ip,$rt,$disp" >> "$RESULTS_CSV"
    done
}

# ====================================================
# Prometheus metrics (textfile collector)
# ====================================================

# Temporary accumulators for prometheus metrics
PROM_METRICS_FILE=""
PROM_SUMMARY_FILE=""

init_prometheus() {
    if [ -z "$PROMETHEUS_TEXTFILE_DIR" ]; then
        return
    fi
    mkdir -p "$PROMETHEUS_TEXTFILE_DIR" 2>/dev/null || {
        log "${YELLOW}Warning: Cannot create Prometheus textfile directory: $PROMETHEUS_TEXTFILE_DIR${NC}"
        PROMETHEUS_TEXTFILE_DIR=""
        return
    }
    PROM_METRICS_FILE=$(mktemp "${PROMETHEUS_TEXTFILE_DIR}/dns_metrics.XXXXXX.tmp")
    PROM_SUMMARY_FILE=$(mktemp "${PROMETHEUS_TEXTFILE_DIR}/dns_summary.XXXXXX.tmp")
    # Accumulators for grouped prometheus output
    PROM_DURATION_LINES=()
    PROM_ERROR_LINES=()
    PROM_SUCCESS_LINES=()
    PROM_NODATA_LINES=()
    PROM_TIMESTAMP_LINES=()
    PROM_DOMAIN_LIST=()
    PROM_RAW_TMP=()
    # Change detection metrics accumulators (daemon mode)
    PROM_CHANGE_LINES=()
    PROM_CHANGE_TYPE_COUNTS=()
    PROM_CHANGE_COUNT_CHANGE=0
    PROM_CHANGE_COUNT_NEW=0
    PROM_CHANGE_COUNT_GONE=0
    PROM_CHANGE_COUNT_ERR=0
    # MX stability metrics accumulators
    PROM_MX_STABILITY_LINES=()
}

emit_dns_prometheus() {
    local domain="$1" record_type="$2" category="$3" has_diff="$4"
    shift 4
    local results=("$@")
    [ -z "$PROM_METRICS_FILE" ] && return
    [ -z "$category" ] && category="default"

    # Store all results per domain for baseline comparison at final write time
    local tmp_file=$(mktemp "${PROMETHEUS_TEXTFILE_DIR}/.dns_domain_XXXXXX")
    for r in "${results[@]}"; do
        echo "$r" >> "$tmp_file"
    done
    PROM_RAW_TMP+=("$tmp_file")
    local idx=${#PROM_DOMAIN_LIST[@]}
    eval "PROM_DOMAIN_${idx}=\"$domain\""
    eval "PROM_RTYPE_${idx}=\"$record_type\""
    eval "PROM_CATEGORY_${idx}=\"$category\""
    PROM_DOMAIN_LIST+=("$domain")

    # Record per-domain/server last-test timestamp
    for r in "${results[@]}"; do
        local dns_name=$(echo "$r" | cut -d'|' -f1)
        local rt=$(echo "$r" | cut -d'|' -f3)
        local now_ts=$(date '+%s')
        PROM_TIMESTAMP_LINES+=("dns_query_last_test_timestamp{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\"} $now_ts")
    done

    for r in "${results[@]}"; do
        local dns_name=$(echo "$r" | cut -d'|' -f1)
        local dns_ip=$(echo "$r" | cut -d'|' -f2)
        local rt=$(echo "$r" | cut -d'|' -f3)

        local status=$(echo "$r" | cut -d'|' -f4)
        local time_val=$(echo "$r" | cut -d'|' -f5)
        local t_ms=$(echo "$time_val" | sed 's/ms//')
        local raw=$(echo "$r" | cut -d'|' -f6)
        # Extract country_code: A record uses raw IP; CNAME extracts first IP from final node
        local country_code="N/A"
        if [ "$ENABLE_GEOIP" = "true" ]; then
            if [ "$rt" = "A" ]; then
                local first_ip=$(echo "$raw" | awk '{print $1}')
                country_code=$(get_ip_country "$first_ip")
                [ -z "$country_code" ] && country_code="N/A"
            elif [ "$rt" = "CNAME" ]; then
                local cname_ip="$raw"
                [[ "$cname_ip" == *" = "* ]] && cname_ip="${cname_ip##* = }"
                local first_ip=$(echo "$cname_ip" | awk '{print $1}')
                country_code=$(get_ip_country "$first_ip")
                [ -z "$country_code" ] && country_code="N/A"
            fi
        fi
        case "$status" in
            SUCCESS)
                PROM_DURATION_LINES+=("dns_query_duration_ms{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",country_code=\"$country_code\"} $t_ms")
                PROM_ERROR_LINES+=("dns_query_error{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",error_type=\"\"} 0")
                PROM_SUCCESS_LINES+=("dns_query_success{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",country_code=\"$country_code\"} 1")
                PROM_NODATA_LINES+=("dns_query_nodata{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",country_code=\"$country_code\"} 0")
                ;;
            ERROR)
                local err_msg=$(echo "$r" | cut -d'|' -f8 | sed 's/"/\\"/g; s/	/ /g' | tr -d '\n\r' | head -c 100)
                PROM_ERROR_LINES+=("dns_query_error{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",country_code=\"$country_code\",error_type=\"$err_msg\"} 1")
                PROM_NODATA_LINES+=("dns_query_nodata{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",country_code=\"$country_code\"} 0")
                ;;
            NO_RECORD)
                PROM_NODATA_LINES+=("dns_query_nodata{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",country_code=\"$country_code\"} 1")
                PROM_ERROR_LINES+=("dns_query_error{domain=\"$domain\",server=\"$dns_name\",record_type=\"$rt\",category=\"$category\",country_code=\"$country_code\",error_type=\"\"} 0")
                ;;
        esac
    done
}

write_prometheus_final() {
    local total=$1 diff_cnt=$2 err_cnt=$3 no_record_cnt=$4 run_ts=$5
    if [ -z "$PROM_METRICS_FILE" ]; then
        return
    fi

    # Compute per-server differences against baseline (first DNS server)
    local diff_lines=()
    for ((i=0; i<${#PROM_DOMAIN_LIST[@]}; i++)); do
        eval "local domain=\"\$PROM_DOMAIN_${i}\""
        eval "local record_type=\"\$PROM_RTYPE_${i}\""
        eval "local category=\"\$PROM_CATEGORY_${i:-default}\""
        local tmp_file="${PROM_RAW_TMP[$i]}"
        [ ! -f "$tmp_file" ] && continue

        local baseline_value=""
        local -a srv_values=()
        local -a srv_names=()
        local first=1

        while IFS= read -r r; do
            [ -z "$r" ] && continue
            local dns_name=$(echo "$r" | cut -d'|' -f1)
            srv_names+=("$dns_name")

            local status=$(echo "$r" | cut -d'|' -f4)
            local raw=$(echo "$r" | cut -d'|' -f6)
            srv_values+=("STATUS:${status}|RAW:${raw}")
        done < "$tmp_file"

        # First server is baseline
        baseline_value="${srv_values[0]}"

        for ((j=0; j<${#srv_names[@]}; j++)); do
            if [ "${srv_values[$j]}" = "$baseline_value" ]; then
                diff_lines+=("dns_query_difference{domain=\"$domain\",server=\"${srv_names[$j]}\",record_type=\"$record_type\",category=\"$category\"} 0")
            else
                diff_lines+=("dns_query_difference{domain=\"$domain\",server=\"${srv_names[$j]}\",record_type=\"$record_type\",category=\"$category\"} 1")
            fi
        done
    done

    # Group metrics by name with HELP/TYPE headers
    {
        echo "# HELP dns_query_duration_ms DNS query response time in milliseconds"
        echo "# TYPE dns_query_duration_ms gauge"
        printf '%s\n' "${PROM_DURATION_LINES[@]}"
        echo ""
        echo "# HELP dns_query_error DNS query error status (1=error, 0=ok)"
        echo "# TYPE dns_query_error gauge"
        printf '%s\n' "${PROM_ERROR_LINES[@]}"
        echo ""
        echo "# HELP dns_query_success DNS query success status (1=success, 0=failed)"
        echo "# TYPE dns_query_success gauge"
        printf '%s\n' "${PROM_SUCCESS_LINES[@]}"
        echo ""
        echo "# HELP dns_query_nodata DNS query no-data status (1=no record, 0=has data)"
        echo "# TYPE dns_query_nodata gauge"
        printf '%s\n' "${PROM_NODATA_LINES[@]}"
        echo ""
        echo "# HELP dns_query_difference DNS resolution difference vs baseline server (1=different, 0=consistent)"
        echo "# TYPE dns_query_difference gauge"
        printf '%s\n' "${diff_lines[@]}"
        echo ""
        echo "# HELP dns_query_last_test_timestamp Unix timestamp of last test for this domain/server/type"
        echo "# TYPE dns_query_last_test_timestamp gauge"
        printf '%s\n' "${PROM_TIMESTAMP_LINES[@]}"
        echo ""
        echo "# HELP dns_change_detected DNS resolution change detected compared to previous round"
        echo "# TYPE dns_change_detected gauge"
        if [ ${#PROM_CHANGE_LINES[@]} -gt 0 ]; then
            printf '%s\n' "${PROM_CHANGE_LINES[@]}"
        else
            echo "dns_change_detected{domain=\"none\",server=\"none\",record_type=\"none\",category=\"none\",change_type=\"none\"} 0"
        fi
        if [ ${#PROM_MX_STABILITY_LINES[@]} -gt 0 ]; then
            echo ""
            echo "# HELP dns_mx_stability MX record stability test result distribution"
            echo "# TYPE dns_mx_stability gauge"
            printf '%s\n' "${PROM_MX_STABILITY_LINES[@]}"
        fi
    } > "$PROM_METRICS_FILE" 2>/dev/null

    # Summary metrics
    if [ -n "$PROM_SUMMARY_FILE" ]; then
        {
            echo "# HELP dns_test_domains_total Total domains tested in last run"
            echo "# TYPE dns_test_domains_total gauge"
            echo "dns_test_domains_total $total"
            echo ""
            echo "# HELP dns_test_differences_total Domains with DNS resolution differences"
            echo "# TYPE dns_test_differences_total gauge"
            echo "dns_test_differences_total $diff_cnt"
            echo ""
            echo "# HELP dns_test_errors_total Domains with query errors"
            echo "# TYPE dns_test_errors_total gauge"
            echo "dns_test_errors_total $err_cnt"
            echo ""
            echo "# HELP dns_test_nodata_total Domains with no record found"
            echo "# TYPE dns_test_nodata_total gauge"
            echo "dns_test_nodata_total $no_record_cnt"
            echo ""
            echo "# HELP dns_test_last_run_timestamp Unix timestamp of last test run"
            echo "# TYPE dns_test_last_run_timestamp gauge"
            echo "dns_test_last_run_timestamp $run_ts"
            echo ""
            echo "# HELP dns_changes_total DNS resolution changes detected since last round"
            echo "# TYPE dns_changes_total gauge"
            echo "dns_changes_total{change_type=\"change\"} ${PROM_CHANGE_COUNT_CHANGE:-0}"
            echo "dns_changes_total{change_type=\"new\"} ${PROM_CHANGE_COUNT_NEW:-0}"
            echo "dns_changes_total{change_type=\"gone\"} ${PROM_CHANGE_COUNT_GONE:-0}"
            echo "dns_changes_total{change_type=\"error\"} ${PROM_CHANGE_COUNT_ERR:-0}"
        } > "$PROM_SUMMARY_FILE" 2>/dev/null
    fi

    # Atomically replace target files
    local final_file="${PROMETHEUS_TEXTFILE_DIR}/dns_compare.prom"
    local final_summary="${PROMETHEUS_TEXTFILE_DIR}/dns_summary.prom"
    mv "$PROM_METRICS_FILE" "$final_file" 2>/dev/null
    mv "$PROM_SUMMARY_FILE" "$final_summary" 2>/dev/null
    log "${CYAN}Prometheus metrics written to: $final_file${NC}"
}

wait_with_countdown() {
    local sec=$1 msg=$2
    [ $sec -le 0 ] && return
    echo -ne "${YELLOW}  $msg: ${sec}s...${NC}\r"
    for ((i=sec; i>0; i--)); do
        echo -ne "${YELLOW}  $msg: $i seconds remaining...${NC}\r"
        sleep 1
    done
    echo -e "${GREEN}  $msg: completed${NC}\033[K"
}

# ====================================================
# Help
# ====================================================

show_help() {
    cat << EOF
Multi-DNS Comparison Test v8.0

Usage: $0 [options] [domain list file]

Options:
  -h, --help               Show this help message
  -f, --file FILE          Specify domain list file (default: domains.txt)
  -d, --domain DOMAIN      Specify a single domain to test
  -t, --type TYPE          Set record type for subsequent domains (A, CNAME, MX, SOA, TXT)
  -o, --output DIR         Specify output directory
  -v, --verbose            Show detailed output
  --geoip                  Enable IP geolocation (default: enabled)
  --no-geoip               Disable IP geolocation
  --geoip-db FILE          Specify local GeoIP CSV database file
  --delay SECONDS          Set delay between queries (default: $QUERY_DELAY)
  --domain-delay SECONDS   Set delay between domains (default: $DOMAIN_DELAY)
  --prom-dir DIR           Enable Prometheus textfile collector output directory
  --stability-test COUNT   Run MX stability test: query each DNS server COUNT times and show result distribution
  --mx-stability N         Daemon mode: per-round lightweight MX stability check (N queries per MX domain)

Record Types:
  A      - IPv4 Address records (with country codes if geoip enabled)
  CNAME  - Canonical Name records (shows full chain)
  MX     - Mail Exchange records
  SOA    - Start of Authority records (shows full AUTHORITY SECTION line)
  TXT    - Text records (auto-categorized: SPF/DMARC/DKIM/OTHER)

Daemon Mode Options:
  --daemon               Run in continuous monitoring mode (does not exit)
  --interval SECONDS     Time between detection rounds (default: 60)
  --max-iterations N     Maximum rounds before exit (0 = infinite, default: 0)
  --change-log FILE      Change log output path (default: dns_changes.log)

Examples:
  $0 -d google.com -t A
  $0 -d example.com -t SOA
  $0 --no-geoip -d google.com -t A
EOF
}

# ====================================================
# Daemon mode helpers
# ====================================================

daemon_cleanup() {
    log "${YELLOW}Daemon mode: shutting down gracefully...${NC}"
    DAEMON_RUNNING=false
}

# Register signal handlers for graceful shutdown
trap daemon_cleanup SIGTERM SIGINT

# ====================================================
# Snapshot I/O functions
# ====================================================

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
    local escaped_key
    escaped_key=$(echo "$key" | sed 's/[.[\*^$()+?{|]/\\&/g')
    local result
    result=$(grep -o "\"${escaped_key}\":\"[^\"]*\"" "$SNAPSHOT_FILE" 2>/dev/null | sed "s/\"${escaped_key}\":\"//; s/\"$//" | head -1)
    if [ -n "$result" ]; then
        echo "$result"
        return 0
    fi
    return 1
}

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

    if [ "$prev_value" = "NO_RECORD" ] || [ -z "$prev_value" ] || [ "$prev_value" = "N/A" ]; then
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

    # Emit Prometheus change detection metrics
    if [ -n "$PROM_METRICS_FILE" ]; then
        local safe_desc=$(echo "$change_desc" | sed 's/"/\\"/g; s/	/ /g' | tr -d '\n\r' | head -c 200)
        PROM_CHANGE_LINES+=("dns_change_detected{domain=\"$domain\",server=\"$dns_server\",record_type=\"$record_type\",change_type=\"$change_type\",description=\"$safe_desc\"} 1")
        case "$change_type" in
            CHANGE) PROM_CHANGE_COUNT_CHANGE=$(( ${PROM_CHANGE_COUNT_CHANGE:-0} + 1 )) ;;
            NEW)    PROM_CHANGE_COUNT_NEW=$(( ${PROM_CHANGE_COUNT_NEW:-0} + 1 )) ;;
            GONE)   PROM_CHANGE_COUNT_GONE=$(( ${PROM_CHANGE_COUNT_GONE:-0} + 1 )) ;;
            ERROR)  PROM_CHANGE_COUNT_ERR=$(( ${PROM_CHANGE_COUNT_ERR:-0} + 1 )) ;;
        esac
    fi
}

# In daemon mode, initialize output files for each round.
# Truncates CSV each round; log is always appended.
init_daemon_output_files() {
    LOG_FILE="dns_daemon.log"
    echo "domain,dns_name,dns_ip,record_type,result" > "$RESULTS_CSV"
}

# Executes one complete round of DNS comparisons across all domains
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

    # Initialize counters
    total=${#DOMAIN_ORDER[@]}
    current=0
    diff_cnt=0
    err_cnt=0
    no_record_cnt=0
    PROM_CHANGE_COUNT_CHANGE=0
    PROM_CHANGE_COUNT_NEW=0
    PROM_CHANGE_COUNT_GONE=0
    PROM_CHANGE_COUNT_ERR=0
    PROM_CHANGE_LINES=()
    PROM_MX_STABILITY_LINES=()

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

    # Daemon mode: optional lightweight MX stability check per round
    if [ "$DAEMON_MODE" = "true" ] && [ "$MX_STABILITY_COUNT" -gt 0 ]; then
        for ((didx=0; didx<${#DOMAIN_ORDER[@]}; didx++)); do
            local d="${DOMAIN_ORDER[$didx]}"
            local t="${DOMAIN_CONFIG_ARR[$didx]}"
            if [ "$t" = "MX" ]; then
                local custom_dns="${DOMAIN_STABILITY_DNS_ARR[$didx]}"
                log "${CYAN}  MX stability check ($MX_STABILITY_COUNT queries) for $d${NC}"
                run_stability_test "$d" "$MX_STABILITY_COUNT" "$custom_dns"
            fi
        done
    fi

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
        log "\n${BOLD_YELLOW} Differences were detected in $diff_cnt domain(s)${NC}"
    fi
    if [ $no_record_cnt -gt 0 ]; then
        log "\n No records found for $no_record_cnt domain(s)${NC}"
    fi
    if [ $err_cnt -gt 0 ]; then
        log "\n Errors occurred in $err_cnt domain(s) (see [ERROR] tags in log)${NC}"
    fi

    if [ "$ENABLE_GEOIP" = "true" ]; then
        log "\n${CYAN}IP Geolocation Statistics:${NC}"
        log "  Unique IPs resolved: ${#IP_COUNTRY_CACHE[@]}"
    fi

    log "\n${CYAN}Statistics by Category:${NC}"
    declare -a cat_names=()
    declare -a cat_counts=()
    for ((i=0; i<${#DOMAIN_ORDER[@]}; i++)); do
        c="${DOMAIN_CATEGORY_ARR[$i]}"
        found=0
        for ((j=0; j<${#cat_names[@]}; j++)); do
            [ "${cat_names[$j]}" = "$c" ] && ((cat_counts[$j]++)) && found=1 && break
        done
        [ $found -eq 0 ] && cat_names+=("$c") && cat_counts+=(1)
    done
    for ((j=0; j<${#cat_names[@]}; j++)); do
        log "  ${PURPLE}${cat_names[$j]}:${NC} ${cat_counts[$j]} domains"
    done

    log "\n${GREEN}Output files:${NC}"
    if [ "$DAEMON_MODE" = "true" ]; then
        log "  Log: $LOG_FILE"
        log "  Change log: $CHANGE_LOG_FILE"
        log "  Results: $RESULTS_CSV"
        log "  Snapshot: $SNAPSHOT_FILE"
    else
        log "  Log: $LOG_FILE"
        log "  Results: $RESULTS_CSV"
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

# ====================================================
# Main
# ====================================================

DOMAIN_FILE=""
VERBOSE=0
OUTPUT_DIR="."
CMD_DOMAINS=()
CMD_TYPES=()
CURRENT_TYPE=""
ENABLE_GEOIP=true

# Daemon mode variables
DAEMON_MODE=false
DAEMON_INTERVAL=60
DAEMON_MAX_ITER=0
DAEMON_RUNNING=true
CHANGE_LOG_FILE=""
SNAPSHOT_FILE="dns_latest_snapshot.json"

# Stability test variables
STABILITY_TEST_COUNT=0
MX_STABILITY_COUNT=0

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) show_help; exit 0 ;;
        -f|--file) DOMAIN_FILE="$2"; shift 2 ;;
        -d|--domain) CMD_DOMAINS+=("$2"); CMD_TYPES+=("$CURRENT_TYPE"); shift 2 ;;
        -t|--type)
            CURRENT_TYPE="$2"
            # Also retroactively update the type of the last added command-line domain
            if [ ${#CMD_TYPES[@]} -gt 0 ]; then
                CMD_TYPES[$(( ${#CMD_TYPES[@]} - 1 ))]="$CURRENT_TYPE"
            fi
            shift 2
            ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -v|--verbose) VERBOSE=1; shift ;;
        --geoip) ENABLE_GEOIP=true; shift ;;
        --no-geoip) ENABLE_GEOIP=false; shift ;;
        --geoip-db) LOCAL_GEOIP_CSV="$2"; shift 2 ;;
        --delay) QUERY_DELAY="$2"; shift 2 ;;
        --domain-delay) DOMAIN_DELAY="$2"; shift 2 ;;
        --prom-dir) PROMETHEUS_TEXTFILE_DIR="$2"; shift 2 ;;
        --daemon) DAEMON_MODE=true; shift ;;
        --interval) DAEMON_INTERVAL="$2"; shift 2 ;;
        --max-iterations) DAEMON_MAX_ITER="$2"; shift 2 ;;
        --change-log) CHANGE_LOG_FILE="$2"; shift 2 ;;
        --stability-test) STABILITY_TEST_COUNT="$2"; shift 2 ;;
        --mx-stability) MX_STABILITY_COUNT="$2"; shift 2 ;;
        -*)
            echo -e "${RED}Error: Unknown option $1${NC}"
            show_help
            exit 1
            ;;
        *)
            [ -z "$DOMAIN_FILE" ] && DOMAIN_FILE="$1" || { echo -e "${RED}Multiple files${NC}"; exit 1; }
            shift
            ;;
    esac
done

if [ "$DAEMON_MODE" = "true" ] && [ -z "$CHANGE_LOG_FILE" ]; then
    CHANGE_LOG_FILE="dns_changes.log"
fi

[ -z "$DOMAIN_FILE" ] && [ ${#CMD_DOMAINS[@]} -eq 0 ] && DOMAIN_FILE="$DEFAULT_DOMAIN_FILE"

# Validate that all CMD_TYPES are set (no empty types)
for ct in "${CMD_TYPES[@]}"; do
    [ -z "$ct" ] && { echo -e "${RED}Error: must specify record type with -t (A/CNAME/MX/SOA/TXT)${NC}"; show_help; exit 1; }
done

check_dependencies

# IP_COUNTRY_CACHE uses associative array on bash 4+, regular variable on older versions
if [ "${BASH_VERSINFO[0]}" -ge 4 ] 2>/dev/null; then
    declare -A IP_COUNTRY_CACHE
else
    IP_COUNTRY_CACHE=""
fi
declare -a DOMAIN_ORDER

[ "$OUTPUT_DIR" != "." ] && mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" 2>/dev/null

[ -n "$DOMAIN_FILE" ] && parse_domain_file "$DOMAIN_FILE"
for i in "${!CMD_DOMAINS[@]}"; do
    add_single_domain "${CMD_DOMAINS[$i]}" "${CMD_TYPES[$i]}"
done

[ ${#DOMAIN_ORDER[@]} -eq 0 ] && { echo -e "${RED}No domains specified${NC}"; show_help; exit 1; }

[ "$ENABLE_GEOIP" = "true" ] && [ ! -f "$LOCAL_GEOIP_CSV" ] && { echo -e "${YELLOW}GeoIP DB not found, disabled${NC}"; ENABLE_GEOIP=false; }

# Initialize Prometheus textfile collector
init_prometheus

# Parse DNS servers
declare -a dns_names dns_ips
while IFS='@' read -r name ip; do
    [ -n "$name" ] && [ -n "$ip" ] && dns_names+=("$name") && dns_ips+=("$ip")
done <<< "$DNS_SERVERS"

# Initialize consolidated CSV (daemon mode re-inits per round)
echo "domain,dns_name,dns_ip,record_type,result" > "$RESULTS_CSV"

log "${YELLOW}Test Configuration:${NC}"
[ -n "$DOMAIN_FILE" ] && log "  Domain file: $DOMAIN_FILE"
[ ${#CMD_DOMAINS[@]} -gt 0 ] && log "  Command-line domains: ${#CMD_DOMAINS[@]}"
log "  DNS servers: ${#dns_names[@]} total"
for i in "${!dns_names[@]}"; do
    log "    ${dns_names[$i]} (${dns_ips[$i]})"
done
log "  Query delay: ${QUERY_DELAY}s between queries"
log "  Domain delay: ${DOMAIN_DELAY}s between domains"
log "  Query timeout: ${QUERY_TIMEOUT}s"
log "  Query retries: ${QUERY_RETRIES}"
log "  Max CNAME depth: ${MAX_CNAME_DEPTH}"
log "  CNAME comparison: Chain structure only (final IP ignored)"
log "  IP Geolocation: $([ "$ENABLE_GEOIP" = "true" ] && echo "ENABLED (IP[COUNTRY] format, 不影响比较)" || echo "DISABLED")"
log "========================================"

# ====================================================
# MX Stability Test
# ====================================================

# Run stability test: query each DNS server COUNT times for the given domain's MX records
# Output: result distribution table per DNS server
# Optional 3rd param: pipe-separated custom DNS list (name@ip|name@ip). Overrides global DNS_SERVERS.
run_stability_test() {
    local domain="$1" count="$2" custom_dns="${3:-}"

    # If custom DNS servers provided, temporarily swap dns_names/dns_ips
    local -a orig_names=() orig_ips=()
    if [ -n "$custom_dns" ]; then
        orig_names=("${dns_names[@]}")
        orig_ips=("${dns_ips[@]}")
        dns_names=()
        dns_ips=()
        local IFS_SAVE="$IFS"
        IFS='|'
        for entry in $custom_dns; do
            local n="${entry%%@*}"
            local ip="${entry#*@}"
            [ -n "$n" ] && [ -n "$ip" ] && dns_names+=("$n") && dns_ips+=("$ip")
        done
        IFS="$IFS_SAVE"
        log "${YELLOW}MX Stability Test: ${domain} @ ${#dns_names[@]} custom DNS servers, ${count} queries each${NC}"
    else
        log "${YELLOW}MX Stability Test: ${domain} @ ${#dns_names[@]} DNS servers, ${count} queries each${NC}"
    fi
    log "============================================================"

    # Per-server result counters
    declare -a srv_total=()
    declare -a srv_mx_ok=()
    declare -a srv_no_mx=()
    declare -a srv_servfail=()
    declare -a srv_empty=()
    declare -a srv_other=()

    for ((s=0; s<${#dns_names[@]}; s++)); do
        srv_total[$s]=0
        srv_mx_ok[$s]=0
        srv_no_mx[$s]=0
        srv_servfail[$s]=0
        srv_empty[$s]=0
        srv_other[$s]=0
    done

    # For each query round, query all servers sequentially
    for ((q=1; q<=count; q++)); do
        for ((s=0; s<${#dns_names[@]}; s++)); do
            local name="${dns_names[$s]}"
            local ip="${dns_ips[$s]}"
            ((srv_total[$s]++))

            local output=$(dig @"$ip" "$domain" MX +time="$QUERY_TIMEOUT" +tries=1 +noall +answer +stats 2>/dev/null)

            if [ -z "$output" ]; then
                ((srv_empty[$s]++))
            elif echo "$output" | grep -q "SERVFAIL"; then
                ((srv_servfail[$s]++))
            elif echo "$output" | grep -qi "IN.*MX"; then
                ((srv_mx_ok[$s]++))
            elif echo "$output" | grep -q "NOERROR"; then
                ((srv_no_mx[$s]++))
            else
                ((srv_other[$s]++))
            fi
        done
    done

    # Print header
    printf "\n${BLUE}%-12s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s${NC}\n" \
        "DNS Server" "MX_OK" "NO_MX" "SERVFAIL" "EMPTY" "OTHER" "Total"

    printf "${BLUE}%-12s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s ${BLUE}%10s${NC}\n" \
        "------------" "----------" "----------" "----------" "----------" "----------" "----------"

    # Print per-server results
    for ((s=0; s<${#dns_names[@]}; s++)); do
        local name="${dns_names[$s]}"
        local mx_ok="${srv_mx_ok[$s]}"
        local no_mx="${srv_no_mx[$s]}"
        local servfail="${srv_servfail[$s]}"
        local empty="${srv_empty[$s]}"
        local other="${srv_other[$s]}"
        local total="${srv_total[$s]}"

        # Color-code: all MX_OK = green, any issue = yellow/red
        local color="$GREEN"
        [ "$servfail" -gt 0 ] || [ "$empty" -gt 0 ] && color="$RED"
        [ "$no_mx" -gt 0 ] || [ "$other" -gt 0 ] && [ "$color" = "$GREEN" ] && color="$YELLOW"

        printf "${color}%-12s ${NC}%10d ${NC}%10d ${NC}%10d ${NC}%10d ${NC}%10d ${NC}%10d${NC}\n" \
            "$name" "$mx_ok" "$no_mx" "$servfail" "$empty" "$other" "$total"
    done

    # Calculate and print summary
    local total_ok=0 total_fail=0
    for ((s=0; s<${#dns_names[@]}; s++)); do
        total_ok=$((total_ok + ${srv_mx_ok[$s]} + ${srv_no_mx[$s]}))
        total_fail=$((total_fail + ${srv_servfail[$s]} + ${srv_empty[$s]} + ${srv_other[$s]}))
    done
    local grand_total=$((total_ok + total_fail))
    local ok_pct=0
    [ "$grand_total" -gt 0 ] && ok_pct=$((total_ok * 100 / grand_total))

    log "\n${GREEN}Summary: $ok_pct% success ($total_ok/$grand_total) across all servers${NC}"
    [ "$total_fail" -gt 0 ] && log "${RED}Failures: $total_fail/$grand_total${NC}"

    # Emit Prometheus MX stability metrics
    if [ -n "$PROM_METRICS_FILE" ]; then
        for ((s=0; s<${#dns_names[@]}; s++)); do
            local name="${dns_names[$s]}"
            PROM_MX_STABILITY_LINES+=("dns_mx_stability{domain=\"$domain\",server=\"$name\",result_type=\"mx_ok\"} ${srv_mx_ok[$s]}")
            PROM_MX_STABILITY_LINES+=("dns_mx_stability{domain=\"$domain\",server=\"$name\",result_type=\"no_mx\"} ${srv_no_mx[$s]}")
            PROM_MX_STABILITY_LINES+=("dns_mx_stability{domain=\"$domain\",server=\"$name\",result_type=\"servfail\"} ${srv_servfail[$s]}")
            PROM_MX_STABILITY_LINES+=("dns_mx_stability{domain=\"$domain\",server=\"$name\",result_type=\"empty\"} ${srv_empty[$s]}")
            PROM_MX_STABILITY_LINES+=("dns_mx_stability{domain=\"$domain\",server=\"$name\",result_type=\"other\"} ${srv_other[$s]}")
            PROM_MX_STABILITY_LINES+=("dns_mx_stability{domain=\"$domain\",server=\"$name\",result_type=\"success_pct\"} $ok_pct")
            PROM_MX_STABILITY_LINES+=("dns_mx_stability{domain=\"$domain\",server=\"$name\",result_type=\"total_queries\"} ${srv_total[$s]}")
        done
    fi

    # Restore original DNS servers if custom were used
    if [ ${#orig_names[@]} -gt 0 ]; then
        dns_names=("${orig_names[@]}")
        dns_ips=("${orig_ips[@]}")
    fi
}

# ---- Stability Test Gate ----
if [ "$STABILITY_TEST_COUNT" -gt 0 ]; then
    # Use first command-line domain or default to the first domain in DOMAIN_ORDER
    if [ ${#CMD_DOMAINS[@]} -gt 0 ]; then
        STABILITY_DOMAIN="${CMD_DOMAINS[0]}"
        # Check if this domain has custom stability DNS servers in DOMAIN_ORDER
        STABILITY_CUSTOM_DNS=""
        for ((sd=0; sd<${#DOMAIN_ORDER[@]}; sd++)); do
            if [ "${DOMAIN_ORDER[$sd]}" = "$STABILITY_DOMAIN" ] && [ -n "${DOMAIN_STABILITY_DNS_ARR[$sd]}" ]; then
                STABILITY_CUSTOM_DNS="${DOMAIN_STABILITY_DNS_ARR[$sd]}"
                break
            fi
        done
    elif [ ${#DOMAIN_ORDER[@]} -gt 0 ]; then
        STABILITY_DOMAIN="${DOMAIN_ORDER[0]}"
        STABILITY_CUSTOM_DNS="${DOMAIN_STABILITY_DNS_ARR[0]}"
    else
        echo -e "${RED}No domain specified for stability test. Use -d or -f to specify.${NC}"
        exit 1
    fi
    run_stability_test "$STABILITY_DOMAIN" "$STABILITY_TEST_COUNT" "$STABILITY_CUSTOM_DNS"
    exit 0
fi

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
