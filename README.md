# DNS 多服务器对比测试工具 (Multi-DNS Comparison Test v8.0)

## 目录

- [1. 功能概述](#1-功能概述)
- [2. 快速开始](#2-快速开始)
- [3. 命令行参数](#3-命令行参数)
- [4. 域名配置格式](#4-域名配置格式)
- [5. 输出文件说明](#5-输出文件说明)
- [6. Prometheus 集成](#6-prometheus-集成)
- [7. 告警规则配置](#7-告警规则配置)
- [8. RHEL 8 部署指南](#8-rhel-8-部署指南)
- [9. 守护进程模式（持续监控）](#9-守护进程模式持续监控)
- [10. 定时任务配置](#10-定时任务配置)
- [11. 运维维护](#11-运维维护)

---

## 1. 功能概述

本脚本用于同时对多个 DNS 服务器进行域名解析查询，对比返回结果是否一致。主要功能：

- **多 DNS 并行对比** — 同时对 5 个 DNS 服务器（114、阿里、Google、腾讯、Cloudflare）发起查询
- **多记录类型支持** — A、CNAME、MX、SOA、TXT 记录（TXT 自动分类：SPF/DMARC/DKIM/OTHER）
- **差异检测** — 以第一台 DNS 为基线，逐一对比其他 DNS 的返回结果
- **CNAME 链解析** — 递归跟踪 CNAME 链（最多 10 层）
- **Prometheus 指标输出** — 支持 textfile collector 模式，自动写入 `.prom` 文件
- **彩色终端输出** — 绿色=一致，黄色=差异，红色=错误
- **IP 地理位置识别**（可选） — 支持本地 IP2Location CSV 数据库

### 支持的 DNS 服务器

| 名称 | IP |
|------|-----|
| 114 | 114.114.114.114 |
| Ali | 223.5.5.5 |
| Google | 8.8.8.8 |
| Tencent | 119.29.29.29 |
| Cloudflare | 1.1.1.1 |

> 可在脚本顶部 `DNS_SERVERS` 变量中自行增删改。

---

## 2. 快速开始

### 手动测试单个域名

```bash
# 测试 A 记录
./dns_compare.sh -d example.com -t A

# 测试 CNAME 记录
./dns_compare.sh -d ica.mydesk.morganstanley.com -t CNAME

# 测试 MX 记录
./dns_compare.sh -d morganstanley.com -t MX

# 测试 TXT 记录
./dns_compare.sh -d google.com -t TXT

# 关闭 GeoIP 加速测试
./dns_compare.sh -d example.com -t A --no-geoip
```

### 批量测试（使用域名配置文件）

```bash
# 使用 YAML 配置
./dns_compare.sh -f domains.yaml --prom-dir /run/textfile_collector/ --no-geoip

# 使用 JSON 配置
./dns_compare.sh -f domains.json --prom-dir /run/textfile_collector/ --no-geoip

# 使用传统文本配置
./dns_compare.sh -f domains.txt --prom-dir /run/textfile_collector/ --no-geoip
```

---

## 3. 命令行参数

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `-f, --file FILE` | 指定域名列表文件 | `domains.txt` |
| `-d, --domain DOMAIN` | 指定单个域名 | - |
| `-t, --type TYPE` | 设置记录类型（A/CNAME/MX/SOA/TXT） | `A` |
| `-o, --output DIR` | 指定输出目录 | `.` |
| `-v, --verbose` | 显示详细输出 | 关闭 |
| `--geoip` | 启用 IP 地理位置 | 开启 |
| `--no-geoip` | 关闭 IP 地理位置 | - |
| `--geoip-db FILE` | 指定本地 GeoIP CSV 数据库 | `IP2LOCATION-LITE-DB1.CSV` |
| `--delay SECONDS` | 设置查询间延迟 | `2` |
| `--domain-delay SECONDS` | 设置域名间延迟 | `3` |
| `--prom-dir DIR` | 启用 Prometheus textfile collector 输出 | 默认禁用 |
| `--stability-test COUNT` | 运行 MX 稳定性测试：每个 DNS 服务器查询 COUNT 次 | 默认禁用 |
| `--mx-stability N` | Daemon 模式：每轮对 MX 域名额外查 N 次（轻量稳定性检查） | 默认禁用 |
| `-h, --help` | 显示帮助信息 | - |

---

## 4. 域名配置格式

### 4.1 YAML 格式（推荐）

```yaml
domains:
  - domain: b2enew.bankofchina.com
    type: A
    category: bank_core

  - domain: morganstanley.com
    type: MX
    category: mail_ms

  - domain: ica.mydesk.morganstanley.com
    type: CNAME
    category: cdn_ica

  - domain: google.com
    type: TXT
    category: txt_spf
```

- `domain` — 必填，要测试的域名
- `type` — 可选，记录类型：`A`、`CNAME`、`MX`、`SOA`、`TXT`，默认 `A`
- `category` — 可选，分组标签，用于终端显示和 Prometheus 统计
- `stability_dns_servers` — 可选，MX 稳定性测试使用的自定义 DNS 服务器列表（格式 `name@ip`），覆盖全局 `DNS_SERVERS`

### 自定义 DNS 服务器示例

```yaml
  - domain: morganstanley.com
    type: MX
    category: mail_ms
    stability_dns_servers:
      - "114@114.114.114.114"
      - "Ali@223.5.5.5"
      - "InternalDNS@10.0.0.1"
```

仅对 `morganstanley.com` 的 MX 稳定性测试使用这三个 DNS 服务器，正常比较仍用全局列表。

### 4.2 JSON 格式

```json
{
  "domains": [
    {"domain": "b2enew.bankofchina.com", "type": "A", "category": "bank_core"},
    {"domain": "morganstanley.com", "type": "MX", "category": "mail_ms"},
    {"domain": "google.com", "type": "TXT", "category": "txt_spf"}
  ]
}
```

### 4.3 传统文本格式

```
[bank_core:A]
b2enew.bankofchina.com
api.bankofchina.com

[mail_ms:MX]
morganstanley.com

[cdn_ica:CNAME]
ica.mydesk.morganstanley.com

[txt_spf:TXT]
google.com
```

脚本通过文件扩展名（`.yaml`/`.yml`/`.json`）自动识别格式，传统文本格式通过 `[分类:类型]` 语法解析。

---

## 5. 输出文件说明

每次运行生成以下文件：

| 文件名 | 说明 |
|--------|------|
| `dns_test_*.log` | 完整日志，包含所有查询结果和配置信息 |
| `dns_differences_*.log` | 差异日志，记录所有 DNS 解析差异 |
| `dns_errors_*.log` | 错误日志，记录查询失败信息 |
| `dns_geoip_*.log` | GeoIP 日志（启用时） |
| `dns_summary_*.txt` | 汇总报告，记录每个域名的一致性状态 |
| `dns_a_report_*.csv` | A 记录 CSV 报告 |
| `dns_cname_report_*.csv` | CNAME 记录 CSV 报告 |
| `dns_mx_report_*.csv` | MX 记录 CSV 报告 |
| `dns_soa_report_*.csv` | SOA 记录 CSV 报告 |
| `dns_txt_report_*.csv` | TXT 记录 CSV 报告（含 SPF/DMARC/DKIM/OTHER 分类） |

### Prometheus 输出文件（启用 --prom-dir 时）

| 文件名 | 说明 |
|--------|------|
| `dns_compare.prom` | 查询指标（延迟、错误、无记录、差异、解析结果值） |
| `dns_summary.prom` | 汇总指标（总数、差异数、错误数、时间戳） |

---

## 6. Prometheus 集成

### 6.1 指标说明

| 指标名 | 类型 | 标签 | 说明 |
|--------|------|------|------|
| `dns_query_duration_ms` | gauge | domain, server, record_type, result, duration_ms, country_code | 值为 1，A 记录时 country_code 为 IP 所属国家代码，其他记录类型时为 N/A |
| `dns_query_error` | gauge | domain, server, record_type, result, duration_ms, country_code | 查询错误（1=失败, 0=正常），失败时 result="ERROR" |
| `dns_query_nodata` | gauge | domain, server, record_type, result, duration_ms, country_code | 无数据（1=无记录, 0=有数据），无记录时 result="NO_RECORD" |
| `dns_query_difference` | gauge | domain, server, record_type | 与基线差异（1=不一致, 0=一致） |
| `dns_test_domains_total` | gauge | 无 | 本次测试域名总数 |
| `dns_test_differences_total` | gauge | 无 | 有差异的域名数 |
| `dns_test_errors_total` | gauge | 无 | 有错误的域名数 |
| `dns_test_nodata_total` | gauge | 无 | 无记录的域名数 |
| `dns_test_last_run_timestamp` | gauge | 无 | 上次测试时间戳 |
| `dns_change_detected` | gauge | domain, server, record_type, change_type, description | 变化检测（daemon 模式，值为 1），change_type=CHANGE/NEW/GONE/ERROR |
| `dns_changes_total` | gauge | change_type | 本轮变化总数（daemon 模式），按类型分组：change/new/gone/error |
| `dns_mx_stability` | gauge | domain, server, result_type | MX 稳定性测试结果，result_type=mx_ok/no_mx/servfail/empty/other/success_pct/total_queries |

### 6.2 差异检测逻辑

`dns_query_difference` 以 **第一台 DNS 服务器** 作为基线，逐一对比其他服务器：

```
基线 DNS (114) → dns_query_difference = 0 (始终一致，因为是基线本身)
其他 DNS      → dns_query_difference = 1 (不一致) 或 0 (一致)
```

### 6.3 配置 node_exporter

确保 node_exporter 启动参数包含：

```bash
node_exporter --collector.textfile.directory=/run/textfile_collector/
```

### 6.4 Grafana Dashboard

项目提供完整的 Grafana Dashboard JSON（`grafana_dashboard.json`），包含以下面板：

| 区域 | 面板 | 说明 |
|------|------|------|
| Overview | Total Domains / Differences / Errors / Last Test Age | 测试运行状态概览 |
| Change Detection | Total Changes / Value Changed / New / Gone | 本轮变化统计（daemon 模式） |
| Change Detection | Change Event Log | 变化事件表格，显示 domain/server/类型/描述 |
| Change Detection | Value Changes Over Time | 值变化时间线（State Timeline） |
| Change Detection | New/Gone/Error Over Time | 新增/消失/错误事件时间线 |
| Change Detection | Top 10 Most Changed Domains | 最频繁变化的域名排行 |
| Difference Matrix | Difference Details | 各 DNS 服务器与基线的一致性 |
| Latency Analysis | Avg Latency / Per-Domain Latency | 查询延迟分析 |
| Errors & No Record | 错误/无记录表格 | 当前报错和缺失记录 |
| Domain Details | Resolution Results / Timestamps | 域名解析详情 |
| MX Stability | Success Rate by Server | MX 记录成功率仪表盘（按 DNS 服务器） |
| MX Stability | OK vs Fail Over Time | 成功/失败状态时间线 |
| MX Stability | Detail Table | MX 稳定性结果明细表（按 result_type） |
| TXT Record Analysis | TXT Record Comparison | TXT 记录对比 |

导入方式：Grafana → Import → 上传 `grafana_dashboard.json` 文件。

### 6.5 Grafana 查询示例

```promql
# Grafana Table 视图：使用 dns_query_duration_ms 作为数据源
# 显示列：domain, server, record_type, result, duration_ms（全部为标签）
dns_query_duration_ms{domain="example.com"}

# 查看查询错误
dns_query_error{result="ERROR"} == 1

# 差异检测（任何不一致的 DNS 服务器）
dns_query_difference{server!=""} == 1

# 变化检测（daemon 模式）
dns_change_detected{change_type="change"}

# 测试运行时间间隔
time() - dns_test_last_run_timestamp
```

---

## 7. 告警规则配置

告警规则文件位于 `alert_rules/dns_compare_rules.yml`，包含以下规则：

| 告警名 | 级别 | 条件 | 说明 |
|--------|------|------|------|
| DNSResolutionDifference | warning | `dns_query_difference == 1` for 5m | DNS 解析结果与基线不一致 |
| DNSQueryError | critical | `dns_query_error == 1` for 2m | DNS 查询失败 |
| DNSNoRecordFound | warning | `dns_query_nodata == 1` for 5m | 无对应记录 |
| DNSHighLatency | info | `dns_query_duration_ms > 500` for 5m | 查询延迟过高 |
| DNSRecordGone | critical | `dns_change_detected{change_type="gone"} == 1` for 5m | DNS 记录消失（daemon 模式） |
| DNSRecordChanged | info | `dns_change_detected{change_type="change"} == 1` for 2m | DNS 记录值变化（daemon 模式） |
| DNSTestRunStale | warning | 超过 3 分钟未运行 | 测试任务异常（daemon 模式） |

### 集成到 Prometheus

在 Prometheus 配置中添加：

```yaml
rule_files:
  - "alert_rules/dns_compare_rules.yml"
```

---

## 8. RHEL 8 部署指南

### 8.1 安装依赖

```bash
# DNS 查询工具
yum install -y bind-utils

# Python3（YAML/JSON 解析）
yum install -y python3
pip3 install pyyaml

# node_exporter（如果尚未安装）
# 确保启用 textfile collector
```

### 8.2 部署脚本

```bash
# 创建目录
mkdir -p /usr/local/bin/dns-compare
mkdir -p /etc/dns_compare
mkdir -p /run/textfile_collector
mkdir -p /var/log/dns-compare

# 复制脚本和配置
cp dns_compare.sh /usr/local/bin/dns-compare/dns_compare.sh
chmod +x /usr/local/bin/dns-compare/dns_compare.sh
cp examples/domains.yaml /etc/dns_compare/domains.yaml

# 设置 textfile collector 目录权限
# 如果使用 systemd 运行 node_exporter：
chown -R node_exporter:node_exporter /run/textfile_collector
```

### 8.3 验证安装

```bash
# 手动执行一次测试
/usr/local/bin/dns-compare/dns_compare.sh \
  -f /etc/dns_compare/domains.yaml \
  --prom-dir /run/textfile_collector/ \
  --no-geoip

# 检查 prom 文件是否正确生成
ls -la /run/textfile_collector/dns_*.prom
cat /run/textfile_collector/dns_compare.prom
```

### 8.4 检查 node_exporter 是否采集

```bash
# 访问 node_exporter 的 metrics 端点
curl http://localhost:9100/metrics | grep dns_query

# 应该能看到 dns_query_* 指标
```

---

## 9. 守护进程模式（持续监控）

以守护进程模式持续运行，可配置检测间隔（秒级），并自动追踪 DNS 记录变化：

```bash
# 前台守护进程模式，每 30 秒一轮
./dns_compare.sh --daemon --interval 30 -f domains.json

# 限制最多运行 N 轮
./dns_compare.sh --daemon --interval 60 --max-iterations 10 -f domains.json

# 自定义变化日志路径
./dns_compare.sh --daemon --interval 30 --change-log /var/log/dns-changes.log -f domains.json
```

### 守护进程模式输出文件

守护进程模式下使用固定文件名（每轮覆盖），避免产生大量时间戳文件：

| 文件 | 说明 |
|------|------|
| `dns_latest_snapshot.json` | 当前 DNS 状态快照 |
| `dns_changes.log` | 累积变化日志（只追加） |
| `dns_differences.log` | 累积差异日志（只追加） |
| `dns_a_report.csv` | 最新一轮 A 记录报告 |
| `dns_daemon.log` | 主守护进程日志 |

### systemd 服务

生产部署使用 systemd 管理服务（项目根目录包含 `dns_compare.service`）：

```bash
sudo cp dns_compare.service /etc/systemd/system/
# 编辑 ExecStart 和 WorkingDirectory 匹配你的实际路径
sudo systemctl daemon-reload
sudo systemctl enable --now dns-compare

# 查看日志
journalctl -u dns-compare -f
systemctl status dns-compare
```

---

## 10. 定时任务配置

### 9.1 使用 crontab

编辑 `/etc/cron.d/dns_compare`：

```bash
# 每 5 分钟执行一次
*/5 * * * * root /usr/local/bin/dns-compare/dns_compare.sh -f /etc/dns_compare/domains.yaml --prom-dir /run/textfile_collector/ --no-geoip >> /var/log/dns_compare.log 2>&1

# 每 30 分钟清理 7 天前的旧日志
*/30 * * * * root find /var/log/ -name "dns_test_*.log" -mtime +7 -delete 2>/dev/null
*/30 * * * * root find /var/log/ -name "dns_*.log" -mtime +7 -delete 2>/dev/null
```

### 9.2 启用 crontab

```bash
# 确保 crond 服务运行
systemctl enable --now crond

# 验证 cron 任务
crontab -l
# 或检查 /etc/cron.d/ 目录
ls -la /etc/cron.d/
```

---

## 10. 运维维护

### 10.1 日志管理

日志文件按时间戳命名，定期增长。建议：

- 配置 logrotate 自动轮转
- 使用 crontab 定时清理 7 天以上旧日志（见上文）

### 10.2 更新 DNS 服务器列表

编辑脚本顶部 `DNS_SERVERS` 变量：

```bash
DNS_SERVERS="
114@114.114.114.114
Ali@223.5.5.5
Google@8.8.8.8
Tencent@119.29.29.29
Cloudflare@1.1.1.1
CustomDNS@x.x.x.x    # 添加自定义 DNS
"
```

### 10.3 更新域名列表

编辑 `/etc/dns_compare/domains.yaml`，添加/删除/修改域名后，下次 cron 执行自动生效。

### 10.4 故障排查

```bash
# 1. 检查脚本是否可执行
ls -la /usr/local/bin/dns-compare/dns_compare.sh

# 2. 手动执行查看输出
/usr/local/bin/dns-compare/dns_compare.sh -f /etc/dns_compare/domains.yaml --no-geoip

# 3. 检查 prom 文件
ls -la /run/textfile_collector/dns_*.prom

# 4. 检查 cron 日志
grep dns_compare /var/log/cron

# 5. 检查 node_exporter 是否采集
curl -s http://localhost:9100/metrics | grep dns_query_difference
```

### 10.5 常见问题

| 问题 | 原因 | 解决方法 |
|------|------|----------|
| `No domains specified` | 域名文件路径错误或格式错误 | 检查文件路径和 YAML/JSON 语法 |
| `dig command not found` | 未安装 bind-utils | `yum install -y bind-utils` |
| Prometheus 无指标 | textfile collector 未启用或路径不匹配 | 检查 node_exporter 启动参数 |
| 域名解析慢 | `--delay` 值过大 | 适当减小 `--delay` 和 `--domain-delay` |
