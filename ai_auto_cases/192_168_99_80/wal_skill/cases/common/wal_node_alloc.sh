#!/bin/bash
# ============================================================================
# W-10 WALNode 分配（`max_wal_nodes_num`；树模型；库名 root.walnode）
# ----------------------------------------------------------------------------
# 目标（cases/cases.tsv W-10）：`max_wal_nodes_num=0`（系统自定） vs 指定 N（默认 2）两相，
#   观察 `<dn_wal_dirs>` 下的 **WALNode 子目录数**与**多库（≥3 个库）写入时的分布**，
#   并用 `wal_node_num` 指标交叉验证；**数据面必须一致**。
#   ⚠ 关键纪律：**N 小于库数（DataRegion 数）时系统如何行为，三份文档都没写**
#     ⇒ 只"描述现象 + 逐副本证据"，**不判 FAIL**（本用例把 ≤N 写成 PASS/WARN 二选一）。
#
# 需求依据（docs/req_sources/design_extract.md）：
#   · §2.2「`max_wal_nodes_num`：WAL Node 的最大数量，默认为 0 表示根据 `wal_dirs` 中目录数量
#     由系统针对负载自行决定；」（**未标热加载**）
#   · §2.1「每个 WAL Node 代表一个 WAL 目录，每个目录下有多个 WAL 文件。」+ §1.4「WAL-Serialize /
#     WAL-Sync 线程数与 WAL Node 个数相等」⇒ WALNode 个数直接决定线程数与 buffer 个数。
#   · §1.3「在 IoTConsensus 中，每个 DataRegion 拥有一个 WAL Node」；§2.1 三种分配策略
#     （Elastic：每 node 固定数量（默认 4 个）unique id；RoundRobin：规定 node 数后轮转；
#      FirstCreate：每个 unique id 一个 WALNode，MultiLeader 只能用这个）——
#     **但"哪个配置项选哪个策略"文档未提及**，只在源码里能看到（见下）。
#   · §2.3「`wal_dirs`：保存 WAL 的目录，若配置多个目录则使用逗号分隔，默认为 data/wal」；
#     §2.3 末尾明确标注 **"目录命名规则文档未提及"** ⇒ 本用例只**记录**目录名形态，不硬断言命名。
#
# 源码印证（docs/req_sources/source_grounding.md §1.2 / §3.2，与上面的文档缺口互补）：
#   · `wal_dir`（单数）、`wal_dirs` 这两个键**不存在**；真实键是 `dn_wal_dirs`
#     （模板 `:293 dn_wal_dirs=data/datanode/wal`、`:287 # effectiveMode: restart`）。
#   · `max_wal_nodes_num`：模板 `:1939 =0`、`:1937 # effectiveMode: restart`（**restart-only**），
#     且模板 `:1933` 注释原文「This parameter is only valid in the standalone mode.
#     IoTConsensus uses one wal per data region and RatisConsensus doesn't use wal.」；
#     `IoTDBDescriptor.java:1836-1838` `if (maxWalNodesNum > 0) { … }` ⇒ **≤0（含负数）一律回落成 0**。
#   · `WALManager.java:76-85` 策略选择：
#       IoTConsensus / IoTConsensusV2 → `FirstCreateStrategy`（identifier = `<database>-<regionId>`，
#         `DataRegion.java:806-812`；`FILE_NAME_SEPARATOR="-"`）
#       否则 `max_wal_nodes_num==0` → `ElasticStrategy`（`ElasticStrategy.java:41,67-69`：
#         `APPLICATION_NODE_RATIO=4`，**每 4 个申请者开 1 个 WALNode**，目录名是**自增整数** `0/1/2…`）
#       否则 → `RoundRobinStrategy(N)`（目录名同样 `0..N-1`）
#   · WALNode 子目录 = `<walDir>/<identifier>`（`AbstractNodeAllocationStrategy.java:62-83`）；
#     WAL 文件名 = `_<versionId>-<startSearchIndex>-<statusCode>.wal`
#     （`IoTDBConstant.java:358-363`、`WALFileUtils.java:65-83`）。
#   ⇒ 因此本用例**同时兼容两种读法**：目录名可能是 `<db>-<regionId>`，也可能是纯数字 `0/1/…`；
#     两种都属实现定义，**都不判 FAIL**，只如实记录"实际数量 / 目录名形态 / 与申请者数的关系"。
#   · ⚠ **少量库（1~3 个 DataRegion）时只看到 1 个 WALNode 目录是正常的**（Elastic 分支
#     每 4 个申请者才开 1 个；FirstCreate 分支则是一 region 一个）⇒ **绝不能**把"目录数 < 库数"
#     当成场景失败。
#
# 判据（FAIL 只来自数据面 / 场景有效性）：
#   1) 场景有效性（硬）：两相 `max_wal_nodes_num` 的**配置文件值**正确（0 / N）、
#      写入行数达标、集群级 WAL 文件数 > 0、WALNode 子目录数 ≥ 1；
#   2) 数据面（硬）：两相都写**完全相同**的数据 ⇒ 三个库的 count/sum 指纹必须逐相相等；
#   3) `wal_node_dirs ≤ N`（指定 N 时）：成立 → PASS；不成立 → **WARN + 逐副本证据**
#      （文档未写 N < 库数时的行为，且 IoTConsensus 下策略可能是 FirstCreate）；
#   4) 收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / CN-DN 日志无 NPE·OOM·越界等异常；
#   5) 目录名形态、`wal_node_num` 指标、分布、WAL 文件名形态 ⇒ 证据（指标缺失只 WARN）。
#
# 用法： bash cases/common/wal_node_alloc.sh [--consensus IoTConsensus|IoTConsensusV2]
#
#   ⚠ **本条未实跑**（写就时 99.80 正在跑合并长回归，禁止任何集群动作；本用例会启停集群两次，
#     属"任何集群动作"）。仅保证 `bash -n` 与 tools/selftest.sh 静态检查通过。
#
# watch list（首跑前逐条确认，3~5 条）：
#   ① `max_wal_nodes_num` 是 **restart-only**（模板 `:1937`）⇒ 必须靠 `cmp_cluster_prepare` 写文件
#      + 重启生效；`SET CONFIGURATION` 只会回 "restart is required"。EXTRA_CONF 里**不能同名键两次**
#      （cluster_write_conf 逐键回读会判 false FAIL）⇒ 本用例用 w10_strip_keys() 先摘掉默认键。
#   ② 两相都用**同一份数据/同一时间戳基准**：否则指纹不可比、数据面判据失效。
#   ③ `wal_node_dirs` 是"`<dn_wal_dirs>` 下第一层子目录"计数 ⇒ 若本版本在 WAL 根目录下还放了
#      buffer/checkpoint 之外的目录（例如多 `dn_wal_dirs` 时的并列目录），计数会偏大；
#      首跑请把 `wal_ls`/目录清单一起看（本用例已打印目录名）。
#   ④ `wal_metric_node_num`（`wal_node_num{name="wal_nodes_num"}`）是跨 DN 求和的"已分配 WALNode 数"，
#      与目录计数**不一定相等**（目录含历史遗留、指标只算运行期）⇒ 只作交叉证据，不判 FAIL。
#   ⑤ 若 Phase B 看到目录数 > N：先确认共识协议（IoTConsensus 下 `max_wal_nodes_num` 按源码
#      `WALManager.java:76-85` 根本不参与策略选择），再按"只描述现象"处理，**不要**判 FAIL。
#
# ---------------------------------------------------------------------------
# 判据速查（读代码先看这里：FAIL 只可能来自 §A 场景有效性 与 §B 数据面）
#   §A 场景有效性（fail "场景无效：…"）：
#        · 两相配置文件里的 max_wal_nodes_num 没写成 0 / N
#        · 任一相三个库写入后某库 d1 行数 ≠ 每设备行数
#        · 任一相 WALNode 子目录数 = 0 或 WAL 文件数 = 0
#   §B 数据面（唯一的"产品问题"判据）：
#        · Phase B 三个库的 count/sum 指纹与 Phase A 不一致（两相写的是**同一份数据**）
#   §C PASS/WARN 二选一（不是数据面问题）：
#        · `wal_node_dirs ≤ N`：成立 → PASS；不成立 → WARN + 逐副本目录名/指标证据
#          （文档未写 N < 库数时的行为，见 §2.2 缺口；源码里 IoTConsensus 走 FirstCreateStrategy）
#   §D 只记录（绝不 FAIL）：
#        · 目录名形态（含库名 = FirstCreate 口径 / 纯数字 = Elastic·RoundRobin 口径）
#        · wal_node_num 指标、目录数与"申请者数/4"的关系、WAL 文件名形态
#   §E 与相邻用例的边界：
#        · W-08 测轮转阈值、W-09 测 buffer ⇒ 本条完全不改这两个键，只看 WALNode 数量与分布；
#        · W-10 不改 dn_wal_dirs（多目录场景属 TP-08/W-24 的范围）。
# ---------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_node_alloc_${DATA_CONSENSUS}"

DB=root.walnode               # 主库（矩阵约定的库名）
DBS="root.walnode root.walnode_b root.walnode_c"   # ≥3 个库：观察 WALNode 在多库下的分布
N=${WAL_NODE_N:-2}            # Phase B 指定的 max_wal_nodes_num
DEVS=${WAL_NODE_DEVS:-3}
ROWS=${WAL_NODE_ROWS:-300}
WIN=${WAL_WIN_SEC:-120}
DB_CNT=$(printf '%s\n' $DBS | grep -c .)
# 固定时间戳基准：两相写完全相同的数据 ⇒ 指纹必须逐相相等（跨相数据面判据）
BASE=$(( ($(date +%s) - 7200) * 1000 ))

# ---------------------------------------------------------------------------
# 本地辅助
# ---------------------------------------------------------------------------
w10_strip_keys(){ local out="$WAL_EXTRA_DEFAULT" k
  for k in "$@"; do
    out=$(printf '%s' "$out" | tr ',' '\n' | grep -v "^${k}=" | tr '\n' ',' | sed 's/,$//')
  done
  printf '%s' "$out"; }

w10_write(){ local db=$1 d k ts vals
  for ((d=1; d<=DEVS; d++)); do
    vals=""
    for ((k=0; k<ROWS; k++)); do
      ts=$(( BASE + k * 10 ))
      vals="$vals($ts,$(( k + 1 ))),"
    done
    sq "insert into $db.d$d(time,s1) values ${vals%,};" >/dev/null \
      || warn "  [$db] 设备$d 写入返回非空（行数断言会兜底）"
  done
  log "  [$db] 写入完成（$DEVS 设备 × $ROWS 点，时间戳基准 $BASE）"
}

# 某 DN 上 WAL 根目录的第一层子目录名（= WALNode 目录名；文档未给命名规则 ⇒ 只记录）
w10_dir_names(){ local out
  out=$(sshx "$1" "find $(wal_roots_arg "$1") -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort" 2>/dev/null | tr -d '\r')
  printf '%s' "$out" | tr '\n' ',' | sed 's/,$//'; }

# 某 DN 上"目录名含某库名"的 WALNode 目录数（FirstCreate 分支：identifier=<db>-<regionId>）
w10_dirs_of_db(){ local n
  n=$(sshx "$1" "find $(wal_roots_arg "$1") -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -c -F '$2'" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
# 某 DN 上"目录名是纯数字"的 WALNode 目录数（Elastic/RoundRobin 分支：identifier=0/1/2…）
w10_dirs_numeric(){ local n
  n=$(sshx "$1" "find $(wal_roots_arg "$1") -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | grep -cE '^[0-9]+$'" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
# 跨 DN 求和的"目录名含某库名"计数（wal_sum_over_dn 只支持单参数函数 ⇒ 这里单独包一层）
w10_dirs_of_db_sum(){ local db=$1 h s=0
  for h in "${DN[@]}"; do s=$(( s + $(w10_dirs_of_db "$h" "$db") )); done
  echo "$s"; }
# WAL 文件名形态命中（源码口径 `_<versionId>-<startSearchIndex>-<statusCode>.wal`）
w10_name_pat_src(){ local n
  n=$(sshx "$1" "find $(wal_roots_arg "$1") -name '*.wal' -printf '%f\n' 2>/dev/null | grep -cE '^_[0-9]+-[0-9]+-[01]\\.wal$'" 2>/dev/null | tr -dc '0-9')
  echo "${n:-0}"; }
# DataRegion 数（申请者数的近似；`show regions` 不可用时返回 -1，只记录不判 FAIL）
w10_data_region_cnt(){ local out
  out=$(sq 'show regions;' 2>&1)
  if printf '%s' "$out" | grep -qiE 'Exception'; then echo "-1"; return; fi
  printf '%s\n' "$out" | awk -F'|' '{gsub(/[[:space:]]/,"",$3)} $3=="DataRegion"{n++} END{print n+0}'; }

# 一相的 WALNode 观测（目录 + 指标 + 文件名形态 + 逐库分布）
w10_observe(){ local tag=$1 h tot
  tot=$(wal_sum_over_dn wal_node_dirs)
  log "  [$tag] WALNode 子目录数（wal_node_dirs 跨 DN 求和）=$tot"
  for h in "${DN[@]}"; do
    log "    [$tag] $h：dirs=$(wal_node_dirs "$h") 目录名=[$(w10_dir_names "$h")] 纯数字目录=$(w10_dirs_numeric "$h") 指标 wal_node_num=$(wal_metric_node_num "$h")"
  done
  log "  [$tag] WAL 目录证据：文件数=$(wal_sum_over_dn wal_file_cnt) 字节=$(wal_sum_over_dn wal_dir_bytes)B（0 字节说明该节点还没落过 WAL）"
  log "  [$tag] 指标口径 wal_node_num 跨 DN 合计=$(wal_metric_sum_over_dn wal_metric_node_num)（与目录计数交叉验证）"
  log "  [$tag] 逐库 WALNode 目录数（目录名含库名，FirstCreate 口径）：$(for d in $DBS; do printf '%s=%s ' "${d##*.}" "$(w10_dirs_of_db_sum "$d")"; done)"
  log "  [$tag] WAL 文件名形态（源码口径命中数，${DN[0]}）：$(w10_name_pat_src "${DN[0]}")；样例：$(wal_ls "${DN[0]}" | head -3 | tr '\n' ' ')"
  wal_metrics_dump "${DN[0]}"; }

# 一相的数据面：建 3 库 + 写同一份数据 + 指纹
w10_data_phase(){ local tag=$1 d
  for d in $DBS; do
    cmp_make_tree_db "$d" "$DEVS"
    w10_write "$d"
  done
  for d in $DBS; do
    wait_scalar_tree "select count(s1) from $d.d1;" "$ROWS" "$WIN" "[$tag] $d d1 行数"
  done
  for d in $DBS; do log "  [$tag] 指纹 $d：$(cmp_fp_tree "$d")"; done }

log "=== W-10 目标：max_wal_nodes_num=0（系统自定） vs =$N（指定上限）==="
log "  库=$DBS（共 $DB_CNT 个库）每库 $DEVS 设备 × $ROWS 点；consensus=${CONSENSUS_CLASS##*.}"
log "  策略源码：IoTConsensus/V2→FirstCreateStrategy；否则 0→Elastic(每 4 个申请者 1 个 WALNode)、>0→RoundRobin(N)"

# ===========================================================================
# Phase A：max_wal_nodes_num=0（系统按 wal_dirs 目录数/负载自定）
# ===========================================================================
log "--- Phase A：max_wal_nodes_num=0 ---"
EXTRA_CONF="$WAL_EXTRA_DEFAULT" cmp_cluster_prepare
A_PROPS=$(wal_props_get "${DN[0]}" max_wal_nodes_num)
A_EFF=$(wal_eff "${DN[0]}" max_wal_nodes_num)
log "  Phase A 配置值=[$A_PROPS] 实际生效值=[$A_EFF]（期望 0）"
assert_eq "Phase A 配置文件 max_wal_nodes_num" "$A_PROPS" "0"

w10_data_phase "Phase A"
FP_A1=$(cmp_fp_tree "$DB"); FP_A2=$(cmp_fp_tree "root.walnode_b"); FP_A3=$(cmp_fp_tree "root.walnode_c")
A_REGIONS=$(w10_data_region_cnt)
log "  Phase A DataRegion 数（show regions，近似申请者数）=$A_REGIONS（-1=接口不可用，只记录）"
w10_observe "Phase A"

A_DIRS=$(wal_sum_over_dn wal_node_dirs)
A_FILES=$(wal_sum_over_dn wal_file_cnt)
[ "${A_DIRS:-0}" -ge 1 ] && pass "Phase A 场景有效：WALNode 子目录数=$A_DIRS（少量库时只有 1 个也属正常：Elastic 每 4 个申请者才开 1 个）" \
  || fail "场景无效：WAL 目录下没有任何 WALNode 子目录（写路径或 dn_wal_dirs 识别有问题）"
[ "${A_FILES:-0}" -ge 1 ] && pass "Phase A 场景有效：WAL 文件数=$A_FILES" \
  || fail "场景无效：Phase A WAL 文件数为 0"
if [ "${A_REGIONS:-0}" -gt 0 ]; then
  log "  关系记录：申请者（DataRegion）≈$A_REGIONS ⇒ Elastic 口径预期 ≈ceil($A_REGIONS/4) 个 WALNode；FirstCreate 口径预期 ≈一个 DataRegion 一个；实测 $A_DIRS 个"
fi

# ===========================================================================
# Phase B：max_wal_nodes_num=N（restart-only ⇒ 写 conf + 重启）
# ===========================================================================
log "--- Phase B：max_wal_nodes_num=$N ---"
W10_B_CONF="$(w10_strip_keys max_wal_nodes_num),max_wal_nodes_num=${N}"
log "  EXTRA_CONF=$W10_B_CONF"
EXTRA_CONF="$W10_B_CONF" cmp_cluster_prepare
B_PROPS=$(wal_props_get "${DN[0]}" max_wal_nodes_num)
B_EFF=$(wal_eff "${DN[0]}" max_wal_nodes_num)
log "  Phase B 配置值=[$B_PROPS] 实际生效值=[$B_EFF]（期望 $N）"
assert_eq "Phase B 配置文件 max_wal_nodes_num（restart-only 已写入）" "$B_PROPS" "$N"
if [ -z "$B_EFF" ]; then
  warn "  cmp_eff 读不到 max_wal_nodes_num（show configuration 未暴露）⇒ 只以配置文件值为准，记录该缺口"
elif [ "$B_EFF" = "$N" ]; then
  pass "Phase B 实际生效值=$B_EFF"
else
  warn "Phase B 配置值=[$B_PROPS] 但实际生效值=[$B_EFF]（如实记录；≤0 会回落 0，见 IoTDBDescriptor.java:1836-1838）"
fi

w10_data_phase "Phase B"
cmp_assert_same "Phase B 与 Phase A 指纹 $DB（同一份数据）" "$FP_A1" "$(cmp_fp_tree "$DB")"
cmp_assert_same "Phase B 与 Phase A 指纹 root.walnode_b（同一份数据）" "$FP_A2" "$(cmp_fp_tree "root.walnode_b")"
cmp_assert_same "Phase B 与 Phase A 指纹 root.walnode_c（同一份数据）" "$FP_A3" "$(cmp_fp_tree "root.walnode_c")"
B_REGIONS=$(w10_data_region_cnt)
log "  Phase B DataRegion 数=$B_REGIONS（Phase A=$A_REGIONS）"
w10_observe "Phase B"

B_DIRS=$(wal_sum_over_dn wal_node_dirs)
B_FILES=$(wal_sum_over_dn wal_file_cnt)
[ "${B_DIRS:-0}" -ge 1 ] && pass "Phase B 场景有效：WALNode 子目录数=$B_DIRS" \
  || fail "场景无效：Phase B WAL 目录下没有任何 WALNode 子目录"
[ "${B_FILES:-0}" -ge 1 ] && pass "Phase B 场景有效：WAL 文件数=$B_FILES" \
  || fail "场景无效：Phase B WAL 文件数为 0"

# ---- N 上限判定：成立 → PASS；不成立 → 只描述现象（文档未写该边界）----
if [ "${B_DIRS:-0}" -le "$N" ]; then
  pass "max_wal_nodes_num=$N 时 WALNode 子目录数=$B_DIRS ≤ $N"
else
  warn "max_wal_nodes_num=$N 但 WALNode 子目录数=$B_DIRS > $N：**只描述现象、不判 FAIL** —— design_extract §2.2 只写'默认为 0 表示按 wal_dirs 目录数由系统自定'，**没有写 N 小于库数/DataRegion 数时的行为**；源码印证 WALManager.java:76-85 在 IoTConsensus/IoTConsensusV2 下强制 FirstCreateStrategy（一个 DataRegion 一个 WALNode，不读 max_wal_nodes_num），模板 :1933 亦注明该参数 only valid in the standalone mode。逐副本证据：$(wal_per_node)"
fi

# 分布/形态结论（全部记录，不判 FAIL）
log "--- 分布与形态记录（不判 FAIL）---"
log "  WALNode 子目录数：Phase A=${A_DIRS}（max_wal_nodes_num=0） vs Phase B=${B_DIRS}（N=$N）"
log "  逐副本目录名：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(w10_dir_names "$h")"; done)"
warn "WALNode 目录命名规则文档未提及（design_extract §2.3 明确标注该缺口）⇒ 本用例只记录形态：目录名含库名=FirstCreate 口径（IoTConsensus）、纯数字=Elastic/RoundRobin 口径；两者都是实现定义，均不判 FAIL。"
warn "N 小于库数时的系统行为文档未写 ⇒ 本用例只描述现象（见上）；WALNode 数量的权威指标 wal_node_num 与目录计数可能不等（目录含历史遗留、指标只算运行期），已并列打印作交叉证据。"

# ---------------------------------------------------------------------------
# 收尾三件套
# ---------------------------------------------------------------------------
log "--- 收尾三件套 ---"
export WAL_EVIDENCE_DB="$DB"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
# 不安装 WAL 建议异常正则（未实跑标定；且 lib/wal_ext.sh ⑪ 明确"删除过期 WAL 条数是 DEBUG 文案、
# 不要当判据"）⇒ WAL 侧只作证据，唯一 FAIL 判据是数据面（三库指纹）。
post_checks "select count(s1) from $DB.d1;" tree
cmp_case_finish "" tree ""
