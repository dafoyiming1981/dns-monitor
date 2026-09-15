# DNS 多服务器对比测试工具 (Multi-DNS Comparison Test v8.2)

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
- **多记录类型支持** — A、CNAME、MX、SOA、TXT 记录（TXT 简化对比：记录数量 + SPF 存在性检测）
- **差异检测** — 以第一台查询成功的 DNS 为基线，逐一对比其他 DNS 的返回结果
- **TLD Trace 参考检查** — 通过 `dig +trace`（root→TLD→权威）获取未经递归缓存的权威路径解析结果，仅展示/记录，不参与对比
- **CNAME 链解析** — 递归跟踪 CNAME 链（最多 10 层）
- **Prometheus 指标输出** — 支持 textfile collector 模式，自动写入 `.prom` 文件
- **彩色终端输出** — 绿色=一致，黄色=差异，红色=错误
- **IP 地理位置识别**（可选） — 支持本地 IP2Location CSV 数据库

### 支持的 DNS 服务器

| 名称 | IP |
|------|-----|
| SHG | 10.143.10.5 |
| BJV | 10.144.10.5 |
| 114 | 114.114.114.114 |
| Ali | 223.5.5.5 |
| Cloudflare | 1.1.1.1 |

> 可在脚本顶部 `DNS_SERVERS` 变量中自行增删改。

### TLD Trace（独立参考检查）

v8.2 起 TLD 服务器不再参与常规对比，改为独立的 **TLD Trace 检查**：对每个监控域名执行 `dig +trace`，从 root 服务器开始沿委派链（root → TLD → 权威）逐级查询，得到**未经任何递归解析器缓存**的权威结果。

- **仅参考，不对比**：结果单独一行青色显示（`TRACE (root→TLD→auth)`），不计入差异/错误统计
- **网络要求**：监控主机需要能出站访问 root/TLD/权威服务器的 UDP 53 端口
- **自动降级**：每轮开始探测一次 root 服务器，不可达则本轮自动跳过 trace（避免每个域名单独等待超时）
- **并行模式**：trace 与其他 DNS 查询并发执行，不增加每轮总耗时
- 开关：配置项 `ENABLE_TLD_TRACE` 或命令行 `--trace` / `--no-trace`

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
| `--trace` | 启用 TLD Trace 参考检查（dig +trace，仅记录不对比；root 不可达时自动跳过） | 开启 |
| `--no-trace` | 关闭 TLD Trace 参考检查 | - |
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
| `dns_run.log` | 完整运行日志，包含所有查询结果、差异（`[DIFF]` 标签）、错误（`[ERROR]` 标签）和 GeoIP 信息（`[GEOIP]` 标签） |
| `dns_results.csv` | 合并 CSV 报告，包含所有记录类型（A/CNAME/MX/SOA/TXT），列：`domain,dns_name,dns_ip,record_type,result` |

### Prometheus 输出文件（启用 --prom-dir 时）

| 文件名 | 说明 |
|--------|------|
| `dns_compare.prom` | 查询指标（延迟、错误、无记录、差异、变化检测、MX 稳定性） |
| `dns_summary.prom` | 汇总指标（总数、差异数、错误数、时间戳） |

> v8.0 已将原先的 12 个分离日志/CSV 文件合并为 2 个文件，大幅减少磁盘占用。`dns_query_result` 指标已恢复（用于 dashboard 展示解析结果）。v8.1 起 TXT 记录的 result label 为记录数量（如 `result="3"`），并附带 `has_spf="true|false"` label，不再输出完整 TXT 内容，避免了高基数膨胀问题。

---

## 6. Prometheus 集成

### 6.1 指标说明

| 指标名 | 类型 | 标签 | 说明 |
|--------|------|------|------|
| `dns_query_duration_ms` | gauge | domain, server, record_type, category, country_code | 查询延迟（毫秒），A/CNAME 记录时 country_code 为 IP 所属国家代码，其他记录类型时为 N/A |
| `dns_query_error` | gauge | domain, server, record_type, category, country_code, error_type | 查询错误（1=失败, 0=正常），失败时 error_type 为错误信息 |
| `dns_query_success` | gauge | domain, server, record_type, category, country_code | 查询成功状态（1=成功, 0=失败） |
| `dns_query_nodata` | gauge | domain, server, record_type, category, country_code | 无数据（1=无记录, 0=有数据） |
| `dns_query_result` | gauge | domain, server, record_type, category, result, country_code, has_spf(仅TXT) | 解析结果：A=IP、CNAME=链、MX=列表、TXT=记录数量；TXT 记录附带 `has_spf` label 表示是否存在 SPF（v=spf1）记录 |
| `dns_query_difference` | gauge | domain, server, record_type, category | 与基线差异（1=不一致, 0=一致）；TXT 记录数量或 SPF 存在性不同即为差异 |
| `dns_query_last_test_timestamp` | gauge | domain, server, record_type, category | 该域名/服务器/记录类型的上次测试时间戳 |
| `dns_test_domains_total` | gauge | 无 | 本次测试域名总数 |
| `dns_test_differences_total` | gauge | 无 | 有差异的域名数 |
| `dns_test_errors_total` | gauge | 无 | 有错误的域名数 |
| `dns_test_nodata_total` | gauge | 无 | 无记录的域名数 |
| `dns_test_last_run_timestamp` | gauge | 无 | 上次测试时间戳 |
| `dns_change_detected` | gauge | domain, server, record_type, change_type, description | 变化检测（daemon 模式，值为 1），change_type=CHANGE/NEW/GONE/ERROR |
| `dns_changes_total` | gauge | change_type | 本轮变化总数（daemon 模式），按类型分组：change/new/gone/error |
| `dns_mx_stability` | gauge | domain, server, result_type | MX 稳定性测试结果，result_type=mx_ok/no_mx/servfail/empty/other/success_pct/total_queries |
| `dns_trace_result` | gauge | domain, record_type, category, result | TLD Trace 权威路径解析结果（仅参考，不参与对比；TXT 为 count+spf 摘要，其他类型记录原始 rdata） |
| `dns_trace_error` | gauge | domain, record_type, category, error_type | TLD Trace 失败（1=失败, 0=正常），不影响 dns_test_errors_total 统计 |
| `dns_trace_duration_ms` | gauge | domain, record_type, category | TLD Trace 总耗时（毫秒，含 root→TLD→权威全部往返） |

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
# 查询某域名的所有解析延迟
dns_query_duration_ms{domain="example.com"}

# 查看查询错误
dns_query_error{error_type!=""} == 1

# 查看查询失败的具体错误类型
dns_query_error{domain="example.com"} == 1

# 差异检测（任何不一致的 DNS 服务器）
dns_query_difference == 1

# 无记录检测
dns_query_nodata == 1

# 变化检测（daemon 模式）
dns_change_detected{change_type="change"}

# 测试运行时间间隔
time() - dns_test_last_run_timestamp

# MX 稳定性成功率
dns_mx_stability{result_type="success_pct"}
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
curl http://localhost:9100/metrics | grep dns_

# 应该能看到以下指标：
# dns_query_duration_ms    - 查询延迟
# dns_query_error          - 查询错误
# dns_query_success        - 查询成功
# dns_query_nodata         - 无记录
# dns_query_difference     - 解析差异
# dns_test_domains_total   - 测试域名总数
# dns_changes_total        - 变化检测统计
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
| `dns_daemon.log` | 主守护进程日志（包含所有查询、差异 `[DIFF]`、错误 `[ERROR]`） |
| `dns_changes.log` | 累积变化日志（只追加，记录值变化/新增/消失/错误） |
| `dns_results.csv` | 最新一轮解析结果 CSV（每轮覆盖） |
| `dns_latest_snapshot.json` | 当前 DNS 状态快照（用于变化检测对比） |

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

# 每 30 分钟清理 7 天前的旧日志和临时 prom 文件
*/30 * * * * root find /var/log/ -name "dns_*.log" -mtime +7 -delete 2>/dev/null
*/30 * * * * root find /run/textfile_collector/ -name ".dns_domain_*.tmp" -mmin +10 -delete 2>/dev/null
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

单次运行模式：输出到 `dns_run.log` 和 `dns_results.csv`（固定文件名，每轮覆盖）。

守护进程模式：输出到 `dns_daemon.log`（追加）和 `dns_changes.log`（追加），文件会持续增长。建议：

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

# 3. 检查输出文件
ls -la dns_run.log dns_results.csv

# 4. 检查 prom 文件
ls -la /run/textfile_collector/dns_*.prom
cat /run/textfile_collector/dns_compare.prom

# 5. 检查 cron 日志
grep dns_compare /var/log/cron

# 6. 检查 node_exporter 是否采集
curl -s http://localhost:9100/metrics | grep dns_

# 7. 查看差异和错误
grep '\[DIFF\]' dns_run.log | tail -20
grep '\[ERROR\]' dns_run.log | tail -20
```

### 10.5 常见问题

| 问题 | 原因 | 解决方法 |
|------|------|----------|
| `No domains specified` | 域名文件路径错误或格式错误 | 检查文件路径和 YAML/JSON 语法 |
| `dig command not found` | 未安装 bind-utils | `yum install -y bind-utils` |
| Prometheus 无指标 | textfile collector 未启用或路径不匹配 | 检查 node_exporter 启动参数 |
| 域名解析慢 | `--delay` 值过大 | 适当减小 `--delay` 和 `--domain-delay` |
