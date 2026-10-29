# WAL 用例写作规约（CASE_WRITING_GUIDE）

> 所有 `cases/common/wal_*.sh` 必须遵守本规约。写之前先读：`conf/env.conf`、`lib/wal_ext.sh`、
> `cases/cases.tsv`（你要写的那一行）、`docs/DECISIONS.md`、`docs/req_sources/`（相关章节）。
> **范本**：已完成的 15 条脚本（尤其 `wal_smoke.sh`、`wal_recovery_kill9.sh`、`wal_compress_toggle.sh`）。

## 0. 铁律

1. **不要连集群跑用例**：99.80 上正在跑合并长回归，任何起停/清库都会报废它。
2. 允许（且应当）做的验证：把自己的脚本 `scp` 到 `root@192.168.99.80:/data/iotdb/autotest/wal_skill/cases/common/`
   然后 `bash -n <文件>`；**只允许 `bash -n`**，不要执行脚本、不要碰集群。
   注意本地 Windows 沙箱里 **bash 起不来**（命名管道被禁），所以语法检查只能在 99.80 上做。
3. **不要修改** `cases/cases.tsv`、`lib/*`、`tools/*`、`conf/*`、`docs/*`（这些由负责人维护）。
   你只写分配给你的 `cases/common/wal_*.sh`。

## 1. 骨架（逐字照抄，勿改顺序）

```bash
#!/bin/bash
# ============================================================================
# W-xx <用例名>（<模型/粒度>）
#   目标（cases/cases.tsv W-xx）：<一句话场景>
#   判据（FAIL 只来自数据面 / 场景有效性）：
#     1) 场景有效性（硬）：…
#     2) 数据面（硬）：…
#     3) 只 WARN：…
#   源码/文档依据：file:line 或 文件名#章节
#   ⚠️ 本脚本**未在集群实跑**（harness 阶段）。首轮 watch list：
#     ① … ② … ③ …
#   用法：bash cases/common/wal_xxx.sh [--consensus IoTConsensus|IoTConsensusV2]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_xxx_${DATA_CONSENSUS}"

DB=root.walxxx
…
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
```

## 2. 集群与配置

- 准备集群：`EXTRA_CONF="$WAL_EXTRA_DEFAULT,..." cmp_cluster_prepare`
  —— `EXTRA_CONF` **必须是单条命令的前缀环境变量**（先赋值再在别的命令里用 → 曾产生 34 个假 FAIL）。
  同名键重复会被 properties 里留下多行 ⇒ 需要覆盖默认键时，用 `sed`/函数**先摘掉** `$WAL_EXTRA_DEFAULT` 里的同名项再追加
  （范本：`wal_mode_disable_rejected.sh` 的 `waldis_strip_keys`）。
- 只重启不清理：`wal_restart_all`（= `cluster_stop` + `cluster_start`）。
- 单节点操作：`wal_kill9_dn <host>`（掉电）、`wal_stop_dn <host>`（正常停）、`wal_start_dn <host>`。
- 写/读数据：`cmp_make_tree_db`、`cmp_write_tree_batch`、`sq`/`sqt`、`scalar`、`wait_scalar_tree`。
- 指纹：`cmp_fp_tree "$DB"`、`cmp_fingerprint tree "select s1 from $DB.d1 order by time"`、`cmp_assert_same`。

## 3. WAL 观测（`lib/wal_ext.sh`，优先用权威指标）

| 用途 | 函数 |
| --- | --- |
| 目录/文件 | `wal_dir_roots` `wal_file_cnt` `wal_ckpt_cnt` `wal_dir_bytes` `wal_node_dirs` `wal_ls` `wal_magic_cnt` `wal_per_node` |
| 权威指标 | `wal_metric_file_cnt`（`file_count{name="wal"}`）、`wal_metric_file_bytes`（`file_size{name="wal"}`）、`wal_metric_queue_cur/_max`、`wal_metric_buffer <h> <name>`、`wal_metric_node_num`、`wal_metric_eff_ratio`、`wal_metric_snapshot_ram`、`wal_metric_flush_ram`、`wal_metric_flush_memtable_cnt`、`wal_metric_sum`、`wal_metric_exists`、`wal_metrics_dump` |
| 日志 | `wal_log_sum <pat>` `wal_log_tail <h>` `wal_install_err_pat` `wal_positive_evidence` `wal_check_logs` |
| 恢复 | `wal_wait_replay <db> [win]` |
| 阻写/内存 | `wal_blocked_writers <h>` `wal_heap_ratio <h>` `wal_oom_cnt` |
| 配置 | `wal_props_get <h> <k>`（配置文件值）、`wal_eff <h> <k>`/`cmp_eff_all`（**运行期生效值**）、`wal_set <k> <v>`（SET CONFIGURATION） |
| OBJECT | `wal_object_root <h>` `wal_object_cnt <h>` |

**判据优先级**：数据面（count/sum/指纹）> 权威指标 > 目录面 > 日志面。
日志面只作"子系统确实在动"的弱证据；`WALNode.java:466-470` 的文案是 **DEBUG 级、默认不落盘**，不可作判据。

## 4. 判定纪律

- **场景有效性硬断言**：WAL 文件数为 0、配置未生效、kill/重启没真发生、写入行数不足 ⇒ `fail "场景无效：…"`。
- **只 WARN**：耗时、压缩率、内存绝对值、指标缺失、文档口径矛盾处、V2 单副本不落盘。
- **不可构造**要写成"探测 → 判定 → 降级"三段式：探测能力 → 能构造就判 → 不能构造 `warn "不可构造（原因+证据）"` 并跳过。
- 阈值类断言**先读实际生效值**（`cmp_eff`），不写死（文档间 30M/10M、16M/32M 矛盾）。
- 负向用例必须有**对照相**（合法配置能正常起）才算场景成立。
- 关键事实速查：`wal_mode` 是 restart-only；`wal_threshold/throttle/compression/delete_period` 是 hot_reload；
  `dn_wal_dirs`/`wal_buffer_size_in_byte`/`max_wal_nodes_num`/`wal_buffer_queue_proportion` 是 restart-only；
  文件名 `_<versionId>-<startSearchIndex>-<statusCode>.wal`（statusCode∈{0,1}）；压缩=段级 LZ4、段 <32KB 不压。

## 5. 提交前自检清单

1. `bash -n`（在 99.80 上跑）通过；
2. `grep -n 'wal_mode=DISABLE'` 只在 `wal_mode_disable_rejected.sh` 里出现；
3. 无全角括号紧跟 `$`（`\$（`）；无硬编码 IP；库名 `root.wal*`；
4. 已 `cmp_case_init` + 结尾 `post_checks` + `cmp_case_finish`；调用 `wal_*` 前已 source `wal_ext.sh`；
5. 头注释含"未实跑 + watch list"；行数 200–450；UTF-8 无 BOM、LF。
