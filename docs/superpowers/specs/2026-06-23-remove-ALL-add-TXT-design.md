# Design: Remove ALL Record Type, Add TXT Support

**Date:** 2026-06-23
**Status:** Draft — pending review

## 1. Goal

Remove the `ALL` record type from `dns_compare.sh` v7.18 and add `TXT` record comparison support. The user must explicitly specify a record type with `-t`; there is no default `ALL` behavior.

## 2. Scope

8 files modified:
- `dns_compare.sh` (core logic)
- `README.md` (documentation)
- `examples/domains.yaml` (YAML example)
- `examples/domains.json` (JSON example)
- `examples/domains.txt` (text example)
- `examples/dns_compare.crontab` (cron example)
- `grafana_dashboard.json` (Grafana panel)
- `alert_rules/dns_compare_rules.yml` (alert rules)

## 3. ALL Removal

### 3.1 Resolve function

Delete the `"ALL"` case in `resolve_domain()` (lines ~520-546). This branch queries A+CNAME+MX+SOA in a single call and packs the result into a compound string. No equivalent compound behavior is needed — each type is now queried individually.

### 3.2 Display / Prometheus / Summary functions

Remove all `if [ "$rt" = "ALL" ]` branching and compound-result expansion in:
- `display_results()` — no longer iterate over sub-types
- `prometheus_metrics()` — no longer emit per-sub-type metrics
- `write_summary()` — no longer aggregate across sub-types

### 3.3 Config parsers

- JSON/YAML parser (L139): valid type list changes from `(A, CNAME, MX, SOA, ALL)` to `(A, CNAME, MX, SOA, TXT)`. Unrecognized types default to `A` (was `ALL`).
- Text config parser (L236): case statement removes `ALL`; unrecognized types default to `A`.

### 3.4 Default behavior

- `-t` flag: **no default value**. If neither `-t` nor a type in the config file is provided, error:
  `Error: must specify record type with -t (A/CNAME/MX/SOA/TXT)`
- YAML/JSON config `type` field: defaults to `A` when omitted (was `ALL`).
- Help text (`--help`): remove ALL from the list of supported types.

### 3.5 `get_record_type_name()`

Remove `ALL) echo "All Record Types";;` case.

## 4. TXT Record Support

### 4.1 `resolve_txt_record()` function

New function, following the existing pattern (`resolve_a_record`, `resolve_mx_record`, etc.):

```
Input: domain, dns_ip, dns_name
Query: dig @<dns_ip> <domain> TXT +time=<timeout> +tries=<retries> +stats
Output: status|query_time|raw_display|display|error
```

- Collects all TXT strings from the ANSWER SECTION.
- Numbers each TXT entry: `TXT[0]`, `TXT[1]`, ...
- Status values: `OK`, `NO_RECORD`, `ERROR`.

### 4.2 TXT categorizer

Function `categorize_txt()` classifies TXT strings by first-token prefix:

| Prefix pattern | Category |
|---------------|----------|
| `v=spf1` | SPF |
| `v=DMARC1` | DMARC |
| `v=DKIM1` or `k=rsa` / `k=ed25519` | DKIM |
| none of the above | OTHER |

### 4.3 `resolve_domain()` — add TXT case

New `"TXT"` case in the `resolve_domain()` case statement. Calls `resolve_txt_record()` for each TXT entry and returns the categorized result.

### 4.4 Display

TXT records display grouped by category:

```
  TXT Records:
    [SPF]     114: v=spf1 include:_spf.google.com ~all
    [SPF]     Ali: v=spf1 include:_spf.google.com ~all          ✓ 一致
    [DKIM]    114: v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUA...
    [DKIM]     Ali: v=DKIM1; k=rsa; p=MIGfMA0GCSqGSIb3DQEBAQUA...  ✓ 一致
    [OTHER] 114: google-site-verification=abc123
    [OTHER]   Ali: google-site-verification=xyz789                 ✗ 差异
```

Comparison: baseline DNS (first server) TXT values per category, compare against each remaining server.

### 4.5 Report file

New `dns_txt_report_$(date +%Y%m%d_%H%M%S).csv`:

```csv
domain,category,txt_type,dns_server,txt_value,status,match
example.com,mail,SPF,114.114.114.114,"v=spf1 include:_spf.google.com ~all",OK,baseline
example.com,mail,SPF,8.8.8.8,"v=spf1 include:_spf.google.com ~all",OK,match
```

### 4.6 Prometheus output

`dns_compare.prom` emits `record_type="TXT"` metrics alongside existing types. No new metric names — reuse `dns_query_duration_ms`, `dns_query_error`, `dns_query_nodata`, `dns_query_difference`, `dns_query_result`.

### 4.7 Grafana dashboard

Add one new panel: **TXT Record Comparison** (Table view). Shows domain, category (SPF/DMARC/DKIM/OTHER), server, value (truncated to 80 chars in display), and difference status. Existing A/CNAME/MX/SOA panels unchanged.

### 4.8 Alert rules

No new alert rules needed — existing `DNSResolutionDifference` rule (`dns_query_difference == 1`) already covers TXT. Add TXT to the rule's annotation to show TXT-specific context.

## 5. Validation list

All case statements and arrays that validate record types must be updated to:
`A|CNAME|MX|SOA|TXT`

Locations:
- `parse_json_yaml_file()` Python validator (L139)
- Text config parser case (L236)
- `add_domain()` validator (L273)
- `get_record_type_name()` (L286)
- `resolve_domain()` case (L483)
- Help text (L1120, L1135)
- `CMD_TYPE` default (L1153)
