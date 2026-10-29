# SKILL：元数据 DDL 自动化测试（TimechoDB 2.0.12.1）

面向**使用者与维护者**的操作手册。入门请先看 `README.md`，
被测版本支持的 DDL 全清单见 `docs/DDL_INVENTORY.md`，实测结论见 `docs/RESULTS.md`。

---

## 1. 什么时候用这个 skill

- 新版本回归：确认"元数据 DDL + 元数据读接口"没有退化（`bash tools/run_all.sh --set all`）。
- 新特性验收：新加了元数据相关语法/接口时，先 `bash tools/probe_ddl.sh` 看它是否真支持，
  再照第 4 节加用例。
- 定位缺陷：某条 DDL 的元数据"看起来不对"时，用 `SKIP_LIFECYCLE=1` 跑对应用例并读
  `results/<用例>_<runid>.out`，里面每条断言都有实际值。

---

## 2. harness API（`lib/common.sh`）

### 2.1 环境与生命周期

| 函数 | 作用 |
| --- | --- |
| `md_load_env [env文件]` | 读 `conf/env.conf`，派生 `DB_DIR/CN_DB_DIR/CLI/QDN`，拆分 `CN[]/DN[]` |
| `md_parse_args "$@"` | 支持 `--consensus`、`--framework`、`--env`、`--keep-data`、`--skip-lifecycle` |
| `md_cluster_prepare` | 停 → 清 → 写配置 → 启动；`SKIP_LIFECYCLE=1` 且集群在跑时直接复用 |
| `cluster_stop / cluster_clean / cluster_write_conf / cluster_start` | 分步操作 |
| `kill_stale_nodes` | 启动前清残留 JVM（避免 Raft 文件锁冲突） |
| `wait_cn_port` / `wait_cluster_ready [秒]` | CN 端口监听 / 全体 Running |
| `restart_missing_nodes` | 补起"激活窗口"里注册被拒而退出的 DN |

### 2.2 用例脚手架

```bash
md_case_init <用例名>      # 建 results/<名>_<runid>.out 与 artifact 目录，初始化 fail_flag
md_case_finish [方言] [一致性查询SQL]
#   → 收尾三件套：sync lag 归零 → 副本一致性（逐个停 DN 比对）→ CN/DN 日志异常分析
#   → 失败自动打包日志；非套件模式关闭集群；写 results/test_result.csv
```

### 2.3 SQL 会话

| 函数 | 说明 |
| --- | --- |
| `sq "<sql>"` / `sqt "<sql>"` | 树/表方言，连 `QDN` |
| `sq_node <节点> <sql>` / `sqt_node` | 指定节点 |
| `sq_as <用户> <口令> <sql>` | **以指定用户身份**执行（权限用例验证"授了权限真的能用 / 没授就 803"） |
| `sql_on <节点> <方言> <sql>` | 方言：`tree` / `table` / `tsess` / `tblsess` |
| `sql_multi <方言> "USE db;;SHOW TABLES;"` | **同一会话**执行多条（`;;` 分隔）；表模型的 `USE` 必须用它 |

### 2.4 元数据判据工具（本 skill 的核心）

| 函数 | 说明 |
| --- | --- |
| `md_rows <输出>` | 归一化成**排序后的行集合**（去表头、压空白、去空行） |
| `md_digest <方言> <sql> [节点]` | 查询并归一化 |
| `md_names <输出>` | 取第 1 列去重集合（`SHOW DATABASES`/`SHOW TIMESERIES` 等） |
| `md_names_of <列号> <输出>` | 取第 n 列去重集合（如 `LIST USER` 的用户名在第 2 列） |
| `md_col <列号>` / `md_last_col` / `scalar` | 取列 / 取末列 / 取首格 |
| `md_count <集合>` | 集合行数 |
| `md_snapshot <方言> "名字::SQL" …` | 把多条查询结果拼成可 diff 的快照（`MD-C01` 用它做重启前后 md5 比对） |
| `assert_set_eq / assert_set_is / assert_set_has / assert_set_lacks` | 集合断言（**先排序再比**，与顺序无关） |
| `assert_ok / assert_error <标签> <输出> [错误码或正则]` | DDL 成败与错误码断言 |
| `assert_eq / assert_ne / assert_ge / assert_contains / assert_not_contains` | 通用断言 |
| `pass / fail / warn / note / log` | `fail` 计入 `fail_flag`；`warn` 只记进 `v_warnMessage`（写进 CSV 的 message 列） |

### 2.5 清理助手

`drop_tree_db`（先卸模板再删库）、`drop_tree_dbs`、`drop_templates`、`drop_table_dbs`、`q_tree`、`q_table`
—— 全部容忍"本来就不存在"。

### 2.6 集群层面的检查

| 函数 | 说明 |
| --- | --- |
| `sync_lag_scan` / `check_sync_lag` | 抓各 DN `http://<dn>:9092/metrics` 的 `syncLag`，要求全部为 0 |
| `consistency_check <sql> [方言]` | 全部在线各副本比一次 + 逐个停 DN 再比；`MD_LIGHT_CHECKS=1` 可只做在线比对 |
| `check_logs` | 扫 CN/DN 日志的常见异常与元数据异常（已排除幂等提示与"停 DN 引发的 leader 转移动"噪声） |
| `post_checks <sql> [方言]` | 上面三件套 |

---

## 3. 写一条新用例的模板

```bash
#!/bin/bash
# MD-Xnn <标题>：<覆盖点>；判据：<怎么算过>
set -uo pipefail
MD_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$MD_SKILL_DIR/lib/common.sh"
md_load_env
md_parse_args "$@"

DB="root.${MD_PREFIX}_xnn"            # 库名带 MD_PREFIX，避免与其它 skill 冲突
md_case_init "md_xnn"                 # 用例名要和 cases.tsv 的脚本名对应
md_cluster_prepare                    # SKIP_LIFECYCLE=1 时自动复用集群

log "--- 清理历史对象 ---"
drop_tree_db "$DB"

log "=== 1) 正向：DDL 写入后 SHOW 必须如实反映 ==="
assert_ok "建库" "$(sq "CREATE DATABASE $DB;")"
assert_set_has "SHOW DATABASES 含新库" "$(md_names "$(sq 'SHOW DATABASES;')")" "$DB"

log "=== 2) 计数自洽 ==="
assert_eq "COUNT == SHOW 行数" \
  "$(scalar "$(sq 'COUNT DATABASES;')")" "$(md_count "$(md_rows "$(sq 'SHOW DATABASES;')")")"

log "=== 3) 失败路径：必须报错，且错误码固定 ==="
assert_error "重复建库 501" "$(sq "CREATE DATABASE $DB;")" '501'

log "--- 清理 ---"
drop_tree_db "$DB"

md_case_finish tree 'SHOW DATABASES;'   # 收尾三件套（一致性查询要选"稳定"的）
```

然后在 `cases/cases.tsv` 加一行：

```
MD-Xnn	<set>	<tree|table>	<tree|table|common>/md_xnn.sh	reuse	<标题>
```

最后：`bash tools/selftest.sh`（会检查语法、用例矩阵一致性、跨用例重名库）。

---

## 4. 判定与断言的经验规则

1. **元数据用例的判据首选"集合"**：`assert_set_is/assert_set_has/assert_set_lacks`，
   而不是 `grep 输出里有没有某个词`——后者会被表头、回显、相似名字骗过。
2. **写错误断言时给错误码**（`'501'`、`'700'`…）：只断言"报错了"会漏掉"报错但原因不对"。
   错误码从 `docs/DDL_PROBE_RESULT*.tsv` 里查，或先跑一次把实际码填回去。
3. **计数类断言要和列表交叉验证**（`COUNT TIMESERIES` vs `SHOW TIMESERIES` 行数）。
4. **一致性查询必须是"稳定"的元数据查询**：`SHOW DATABASES`/`SHOW TIMESERIES` 可以；
   `SHOW CLUSTER`（含节点在线状态）、`SHOW QUERIES`（含当前时间/查询 id）**不行**。
5. **"未支持"也是判据**：产品当前不支持的语法/语句，用 `assert_error … '700'/'701'` 钉住，
   这样将来支持了会立刻被发现（`MD-T05`）。
6. 只有"产品行为与预期不一致但**可能是有意设计**"时才用 `warn`（会写进 CSV 的 message 列，
   方便汇总时人工确认），不要用它掩盖真正的失败。
7. **CLI 输出解析别自己写 grep**：一律走 `table_rows` / `md_rows` / `md_names` / `md_col`。
   它们已经处理了"表头重复出现"（见第 6 节第 8 条）与 `+---+` 分隔行。

---

## 5. UDF / Trigger 用例（需要真实 jar）

元数据不只是库表时序，**用户自定义对象（UDF / Trigger）也是元数据**，而且必须带真实 jar 才测得动。

- 源码与构建脚本在 `assets/udf/`：`src/mdskill/MdUdtf.java`（值 ×2，支持 `factor` 属性）、
  `MdUdtfErr.java`（故意抛异常）、`MdTrigger.java`（把 onCreate/restore/onDrop/fire 写进 marker 文件）。
- 构建/分发（**用服务端自己的 jar 做 classpath，不需要 maven**）：
  ```bash
  bash assets/udf/build_and_deploy.sh      # 编译 → /data/iotdb/udf_md/mdskill.jar → 分发到各节点
  ```
  `USING URI 'file:///data/iotdb/udf_md/mdskill.jar'` 要求**每个节点**都有这个文件，所以统一路径。
- 触发器"真的被触发"怎么判：`MdTrigger` 往 marker 文件追加事件行，用例用 ssh 跨节点统计
  （`grep -c ' fire'`）。实测要点：
  - `onCreate`/`onDrop` 在**所有节点**都被调用；`fire` 只在**执行写入的那个节点**发生
  - stateless 触发器重启后**会被恢复且继续 fire**，但**不会收到 `restore()`**（源码里只有 stateful 才调）
  - **设备级裸路径 `ON root.db.d1` 不会触发**（`d1.s1` / `d1.*` / `d1.**` / `db.**` 都会）——已在用例里记为观察
- UDF 判定：`SHOW FUNCTIONS` 的类型列是 `external UDTF`（内置是 `built-in UDTF`），
  再跑一次 `SELECT <函数>(...)` 断言**数值结果**（别只断言"没报错"）。

---

## 6. 排障

| 症状 | 先看哪里 |
| --- | --- |
| 用例 rc=0 但没有 RESULT 行 | `results/<用例>_<runid>.out` 末尾；runner 找的是含 `RESULT (PASS\|FAIL)` 的行 |
| 集群起不来 | `results/cluster_prepare_*.out`；预期能看到 `清理残留 JVM` → `ConfigNode 端口已监听` → `集群就绪: 6/6` |
| 出现 `Cluster is unactivated now` | DN 抢在激活窗口内注册；`cluster_start` 会补起，若持续出现把 `MD_ACTIVATION_SETTLE_SEC` 调大 |
| 出现 `OverlappingFileLockException` | 残留 JVM 占着 Raft 锁；`kill_stale_nodes` 应已处理，手动可 `pkill -9 -f com.timecho.iotdb` |
| 日志检查报"异常" | `results/artifact_*/logs/*.tgz`；先确认是不是"停 DN 引发的 leader 转移"（已被 BENIGN 排除） |
| 想只看某条用例 | `bash tools/run_all.sh --only MD-T01 --no-prepare`（集群在跑时） |
| `SHOW` 出来的行数比 `COUNT` 多 1（或一批的整数倍） | **CLI 在结果超过一批（实测 1000 行/批）时会重复打印表头**；`table_rows` 已处理，别再自己 grep |

### 判定纪律：先说"代码这样写"，再说"这是不是 bug"

**踩过的坑（2026-10-10）**：触发器 `ON <设备>` 不触发，我读源码发现
`PatternTreeMap.searchOverlapped` 的终端分支没有收集设备节点自身的值，又有
`searchDeviceOverlapped:267` 的 `addAll(node.getValues())` 作"不一致"佐证，于是判成疑似缺陷并写了修复建议。
**结论是错的**——产品文档《06-流计算-触发器》（`docs/refs/`）明确"被注册有触发器的**序列**才会被侦听"，
设备节点本身没有序列，所以不触发是设计如此；而 `searchDeviceOverlapped` 服务的是**设备级**用途
（`getDeviceOverlapped`，当时只被单测使用），不能拿来类比。

规矩：
1. 源码/实测只能回答"**行为是什么**"；"**应该是怎样**"必须去查**产品文档、设计说明、需求/工单**。
2. 找不到文档依据时，措辞用"与直觉不符，待确认"，**不要**写"根因/建议修法/疑似缺陷"。
3. 行为确认符合预期后，把它改成**硬断言**（而不是留着 WARN）——这样行为一旦变化就会 FAIL。

### 已经踩过、值得记住的 harness 坑

1. **成功的 DDL 也会打印 `Msg: The statement is executed successfully.`** → 报错判定要排除它；
   `SHOW PIPES` 的结果表里含 `Exception` 字样，表格行不参与报错判定。
2. **`local a=… b=$(( … a … ))` 同行引用**在 `set -u` 下 unbound（函数静默返回空值）→ 拆成两条 `local`；
   `selftest` 有静态检查。
3. **runner 的 stdin 会被 CLI 抢读** → `mapfile` 读入用例矩阵 + 子进程 `</dev/null`。
4. **集群启动两个环境坑**：DN 在"未激活"窗口注册被拒会直接退出（要 CN 先起、等激活、再起 DN、补起）；
   残留 JVM 占着 Raft 锁会让新 CN `OverlappingFileLockException`（启动前 `kill_stale_nodes`）。
5. **判断 CN 就绪不能用 `show cluster`**（CLI 连的是 DN 的 RPC 端口）→ 看 CN 内部端口是否监听。
6. **一致性校验不能用 `SHOW CLUSTER`**（随节点在线状态变化）；逐 DN 停机引发的
   `Failed to CHANGE_REGION_LEADER` / `RatisRequestFailedException: transferLeader` 属测试动作噪声（已入 BENIGN）。
7. **`INSERT INTO <序列>(timestamp, value) VALUES(...)` 在时序已存在时报 506/507**；
   树模型批量写入用设备级形式 `INSERT INTO <设备>(timestamp, s1, s2) VALUES(...)`。
8. **CLI 结果超过一批（1000 行）会重复表头** → `table_rows` 按"表头原文"整行剔除；
   `selftest` 有"多批次表头"回归用例。
9. **日志检查必须"只看本用例新增的行"**：CN/DN 日志跨用例累积，整文件扫描会把上一条用例的行
   算到下一条头上（踩过：MD-U01 停/重启集群产生的 `Execute FragmentInstance … failed` 让 MD-S01 无端 FAIL）。
   现在 `md_cluster_prepare` 结束时会调 `md_log_mark` 记录每个日志文件的行数基线，`check_logs` 只扫之后的新增行。
10. **用例自己故意制造的错误日志要显式排除**：`export MD_LOG_BENIGN_EXTRA='…'`（只对该用例生效）。
   MD-U01 就靠它排除 `MDSKILL_UDF_BOOM` / `MDSKILL_TRIGGER_REJECT` / `Failed to load class` 等预期内的报错。
11. **"查询片段失败"不等于"元数据失败"**：`MD_ERR_PAT` 里的 `SchemaRegion[…] failed` 必须让失败描述紧跟 region id，
    否则 `Execute FragmentInstance in ConsensusGroup SchemaRegion[7] failed.`（停/重启节点时在飞查询的正常现象）
    也会被算成元数据异常。

---

## 6. 与 TTL skill 的关系

两套 skill 共用环境约定（节点、版本目录、账号、3C3D 拓扑）与集群生命周期写法，
但 **harness 各自独立**：TTL skill 的判据是"日志计数 + TsFile 数"，本 skill 的判据是
"`SHOW`/`COUNT`/`information_schema` 的集合"。没有做 `ttl_`→`md_` 机械改名，
以免把 `ttl_check_interval` 这类**产品配置名**一起改坏。

用例创建的对象前缀：本 skill 用 `md`（`MD_PREFIX`），TTL skill 用 `ttl_`/`param_`/`regdup_` 等，互不冲突。
