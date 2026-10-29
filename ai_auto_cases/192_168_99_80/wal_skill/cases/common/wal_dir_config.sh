#!/bin/bash
# ============================================================================
# W-24 WAL 目录配置（`dn_wal_dirs` 指向自定义目录；**restart-only**；树模型；库名 root.waldir）
# ----------------------------------------------------------------------------
# 目标（cases/cases.tsv W-24）：把 `dn_wal_dirs` 指到自定义目录（单目录 / 逗号分隔的多目录）→
#   重启后 WAL 文件**确实落到该目录**（且默认目录不再新增）→ 数据可跨重启恢复。
#
# 【覆盖需求】
#   · design_extract.md §8.1 TP-01（`wal_dirs` 下应有 WALNode 目录且其内有 `.wal`）、
#     TP-02（文件名 `^_\d+\.wal$`，源码口径更细）、TP-08（**多目录**：期望多目录均有 WAL；
#     **分配策略文档未提及 ⇒ 只作弱断言**，本用例：不满足只 WARN）；§7.2 参数表 `wal_dirs`
#     默认 `data/wal`（与源码默认 `data/datanode/wal` 不一致，见下）。
#   · source_grounding.md（**以此为准**）：
#       §1.2-18 `dn_wal_dirs`：默认 `data/datanode/wal`、String[]（逗号分隔）、**restart-only**
#              （模板 iotdb-system.properties.template:293 / :287，CommonDescriptor.java:124-128）
#       §3.1 `dn_wal_dirs` 相对 `<IOTDB_HOME>` 解析；启动检查里注册/创建（IoTDBStartCheck.java:222-224）
#       §3.2 WALNode 子目录 = `<walDir>/<identifier>`；IoTConsensus(V2) 下 identifier = `<database>-<regionId>`
#       §3.4 文件名 = `_<versionId>-<startSearchIndex>-<statusCode>.wal`（statusCode ∈ {0,1}）
#       §1.5 / §14 `wal_dir`（单数）、`wal_dirs` 键**不存在**（模板注释里的 wal_dirs 属注释口误）
#   · DECISIONS.md §1（目录面=过程证据、数据面=唯一 FAIL 判据）、§2（多目录分布类差异只 WARN）、
#     §4.2（目录命名/映射文档未给出 ⇒ 动态定位、不写死路径）。
#
# 【判据】（FAIL 只来自"场景有效性 + 数据面 + 配置真的落到了该目录"）
#   1) 配置面（硬）：`SET CONFIGURATION 'dn_wal_dirs'=…` 的返回文案必须含 `restart is required`
#      且点名 `dn_wal_dirs`（restart-only 的直接证据；源码与模板 `:287 # effectiveMode: restart` 一致）；
#      改配置后 properties 逐节点落到新值（若被框架启动脚本还原 ⇒ 用 cluster_write_conf 重写并 WARN 记录）。
#   2) 未重启不生效（硬）：SET 之后继续写入 ⇒ **当前生效目录**的 `.wal` 字节增长，而新目录**不存在**。
#      ⚠ 这里必须用"显式目录口径"的 helper：`wal_dir_roots`/`wal_file_cnt` 读的是**配置文件**，
#      此刻配置文件已是新值、运行期仍在旧目录 ⇒ 用它们会数到空目录（本文件自带 w24_dir_* 系列）。
#   3) 重启后落到自定义目录（硬）：`<自定义目录>/<db>-<regionId>/` 出现且 `_v-i-s.wal` 命名全部合规；
#      默认目录**不再新增**（字节数不增长）；数据（含切换前未 flush 的一批）由新目录的 WAL 恢复。
#   4) 多目录（硬 + 弱）：文件确实落在自定义目录组内（硬）；"每个目录都非空"按 TP-08 只作弱断言
#      —— 分配策略文档未提及（TP-08 原文），不满足时 WARN + 逐目录逐副本证据，**不判 FAIL**。
#   5) 数据面（硬，唯一能判 FAIL 的）：每次重启前后 count/sum/min/max 与 `$DB.d1` 全序列完全一致；
#      写入行数 == 设备数×点数×批数（离线可核算）。
#   6) 收尾三件套：sync lag 归零 / 逐个停 DN 副本一致 / CN-DN 日志无异常。
#
# 【为什么切换目录前必须 flush（与本 skill "恢复相不 flush"并不矛盾）】
#   切换 `dn_wal_dirs` 后重启，DN 只扫描**新目录**（§3.2/§4 恢复粒度 = WALNode 目录）⇒ 旧目录里
#   未刷盘的 WAL entry 不在恢复视野内。若让未 flush 数据跨越"目录切换"，丢数据是**构造方式导致**、
#   不是产品缺陷。故：切目录前 flush（数据落 TsFile）；只在**同一目录内**的重启相用未 flush 数据
#   验证"WAL 重放 + 数据可恢复"（第 3/5 相各一次）。
#
# 【注意】
#   ⚠ 本脚本**未在集群实跑**（写就时 99.80 正在跑合并长回归，禁止任何集群启停动作）。
#     只做了静态语法检查（见交付说明的 bash -n / 等价检查）。
#   ⚠ EXTRA_CONF 里**不能出现同名键两次**（cluster_write_conf 逐键回读会判假 FAIL）⇒ 用
#     w24_strip_keys 先把要自己定值的键从 WAL_EXTRA_DEFAULT 里摘掉（与 W-00 同一纪律）。
#   ⚠ harness 缺口：lib/common.sh 的 cluster_set_conf 引用了 wal_skill/conf/env.conf **未定义**的
#     TTL_CHECK_INTERVAL_MS / MAX_EXPIRED_TIME_MS / EXPIRED_DATA_RATIO；`set -u` 下会让"写配置"整条命令
#     终止 ⇒ 本文件在 cmp_cluster_prepare 之前给出安全默认值（与 W-00 一致，不改 lib/conf）。
#   ⚠ 默认路径口径：源码默认 `data/datanode/wal`，设计文档写 `data/wal`。本用例**不写死**：先读
#     `wal_dir_roots`，读不到再回落 `$DB_DIR/data/datanode/wal`，并把实际值打印出来（首轮标定用）。
#
#   首轮实跑 watch list（最关键 4 条）：
#     ① `SET CONFIGURATION 'dn_wal_dirs'='<路径>'` 是否真的被接受并落到各 DN 的 properties；
#        若返回 "not supported"/被丢弃 ⇒ 走 cluster_write_conf 兜底（脚本已实现），并据此判断是
#        "restart-only 提示缺失"（产品/文档问题）还是"该键不可 SET"（实现问题）。
#     ② `wal_dir_roots`（读配置）与"运行期真正在写的目录"在切目录后**首次**写入时是否一致：
#        本用例用显式目录计数交叉验证，首轮请把 `w24_per_node2 w24_dir_bytes <目录>` 的前后值都看一遍。
#     ③ 多目录（`one,two`）时文件分布：可能只落在第一个目录（IoTConsensus 用 FirstCreateStrategy，
#        `WALManager.java:76-85`；多目录分配策略文档未提及）⇒ 只 WARN；若一个目录都没文件 ⇒ 才 FAIL。
#     ④ 自定义目录基路径（默认 `/data/iotdb/walcase`）在三个 DN 上是否存在且可写；不可写时本用例
#        降级为"只做默认目录相 + WARN 不可构造"，**不判 FAIL**（`WAL_DIR_BASE` 可覆盖）。
#
# 用法： bash cases/common/wal_dir_config.sh [--consensus IoTConsensus|IoTConsensusV2]
#   可调：WAL_DIR_BASE=/path  W24_SKIP_C_PROBE=1（跳过多目录相里那次"未重启不生效"探针写入）
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
. "$HERE/../../lib/wal_ext.sh"

# ---- harness 侧防御（见头注释；不改 lib/conf）--------------------------------
: "${TTL_CHECK_INTERVAL_MS:=60000}"
: "${MAX_EXPIRED_TIME_MS:=9223372036854775807}"
: "${EXPIRED_DATA_RATIO:=0.000001}"
export TTL_CHECK_INTERVAL_MS MAX_EXPIRED_TIME_MS EXPIRED_DATA_RATIO

cmp_load_env
cmp_parse_args "$@"
cmp_case_init "wal_dir_config_${DATA_CONSENSUS}"

DB=root.waldir
DEVS=${WAL_DEVS:-4}
ROWS=${WAL_ROWS:-200}
WIN=${WAL_WIN_SEC:-120}
CLOSE_WIN=${WAL_CLOSE_WIN_SEC:-60}
DEF_WAL="$DB_DIR/data/datanode/wal"
WAL_BASE=${WAL_DIR_BASE:-/data/iotdb/walcase}
CUSTOM1="$WAL_BASE/one"
CUSTOM2="$WAL_BASE/two"
SKIP_C_PROBE=${W24_SKIP_C_PROBE:-0}
KEEP_DIRS=${W24_KEEP_DIRS:-1}
BATCH_NO=0
CUSTOM_OK=1
ACTIVE_A=""
BASE=$(( ($(date +%s) - 7200) * 1000 ))

# ---------------------------------------------------------------------------
# 局部 helper
# ---------------------------------------------------------------------------
# 从 WAL_EXTRA_DEFAULT 里摘掉指定键（本用例要自己给这些键定值；见头注释的"同名键两次"纪律）
w24_strip_keys(){ local out="$WAL_EXTRA_DEFAULT" k
  for k in "$@"; do
    out=$(printf '%s' "$out" | tr ',' '\n' | grep -v "^${k}=" | tr '\n' ',' | sed 's/,$//')
  done
  printf '%s' "$out"; }

# ⚠ 显式目录口径（**不看配置**）。conf 里的 dn_wal_dirs 被 SET 改成新值后，运行期仍写旧目录
#   （restart-only）⇒ wal_file_cnt / wal_dir_bytes（读 conf）会数到空目录；本组 helper 必须用。
w24_dir_files(){ local v
  v=$(sshx "$1" "find $2 -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w24_dir_bytes(){ local v
  v=$(sshx "$1" "find $2 -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
# 只数**本库** identifier 目录（`<目录>/<db>-<regionId>/`）下的 WAL
w24_dir_db_files(){ local v
  v=$(sshx "$1" "find $2 -path '*/$DB-*/*' -name '*.wal' 2>/dev/null | wc -l" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w24_dir_db_bytes(){ local v
  v=$(sshx "$1" "find $2 -path '*/$DB-*/*' -name '*.wal' -printf '%s\n' 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
w24_dir_exists(){ local v
  v=$(sshx "$1" "[ -d '$2' ] && echo 1 || echo 0" 2>/dev/null | tr -dc '0-9'); echo "${v:-0}"; }
# 跨 DN 求和 / 逐副本串（两参数的包装：wal_sum_over_dn 只支持单参数函数）
w24_sum2(){ local f=$1 a=$2 h s=0; for h in "${DN[@]}"; do s=$(( s + $($f "$h" "$a") )); done; echo "$s"; }
w24_per_node2(){ local f=$1 a=$2 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$($f "$h" "$a") "; done; echo "$out"; }
w24_exists_sum(){ local h s=0; for h in "${DN[@]}"; do s=$(( s + $(w24_dir_exists "$h" "$1") )); done; echo "$s"; }
# 命名合规性（源码口径 `_<versionId>-<startSearchIndex>-<statusCode>.wal`，允许 .enc 后缀）
w24_bad_names(){ local v
  v=$(sshx "$1" "find $2 -name '*.wal' -printf '%f\n' 2>/dev/null | grep -cvE '^_[0-9]+-[0-9]+-[01]\.wal(\.enc)?\$'" 2>/dev/null | tr -dc '0-9')
  echo "${v:-0}"; }
# `<db>-<regionId>` 形态的 WALNode 子目录（逐副本，证据用）
w24_ident_dirs(){ local v
  v=$(sshx "$1" "find $2 -mindepth 2 -maxdepth 2 -type d -name '$DB-*' -printf '%f\n' 2>/dev/null | sort -u | tr '\n' ' '" 2>/dev/null | tr -d '\r')
  echo "${v:-0}"; }
# 配置面
w24_props_all(){ local k=$1 h out=""; for h in "${DN[@]}"; do out="$out${h##*.}=$(wal_props_get "$h" "$k") "; done; echo "$out"; }
w24_props_match(){ local k=$1 want=$2 h n=0 v; for h in "${DN[@]}"; do v=$(wal_props_get "$h" "$k"); [ "$v" = "$want" ] && n=$(( n + 1 )); done; echo "$n"; }

# 写 1 批（**不 flush**）：设备 d 第 b 批第 k 行 ⇒ 值 = k+b，时间戳 = BASE + b*1000000 + k*10
w24_write_nf(){ local b=$1 d k vals ts start
  start=$(( BASE + b * 1000000 ))
  for ((d=1; d<=DEVS; d++)); do
    vals=""
    for ((k=0; k<ROWS; k++)); do
      ts=$(( start + k * 10 ))
      vals="$vals($ts,$(( k + b ))),"
      if [ $(( (k + 1) % 500 )) -eq 0 ]; then
        sq "insert into $DB.d$d(time,s1) values ${vals%,};" >/dev/null || return 1
        vals=""
      fi
    done
    [ -n "$vals" ] && { sq "insert into $DB.d$d(time,s1) values ${vals%,};" >/dev/null || return 1; }
  done
  BATCH_NO=$b
  return 0; }
w24_exp_rows(){ echo $(( DEVS * ROWS * BATCH_NO )); }
w24_rows_now(){ row_sum "$(sq "select count(s1) from $DB.**;")"; }
w24_assert_rows(){ local label=$1 want=$2 got
  got=$(w24_rows_now)
  assert_eq "$label（来源：CLI count($DB.**) 的 row_sum）" "${got:-0}" "$want"; }
w24_wait_rows(){ local want=$1 win=$2 dl got
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    got=$(w24_rows_now)
    [ "${got:-0}" = "$want" ] && return 0
    sleep 5
  done
  return 1; }
w24_fp(){ cmp_fp_tree "$DB"; }
w24_fpd(){ cmp_fingerprint tree "select s1 from $DB.d1 order by time"; }
# 等 WAL 文件出现在**指定目录**（WAL 是异步刷盘的；写完立刻数可能还是 0）
w24_wait_dir_files(){ local d=$1 want=$2 win=$3 dl n
  dl=$(( $(date +%s) + win ))
  while (( $(date +%s) < dl )); do
    n=$(w24_sum2 w24_dir_db_files "$d")
    [ "${n:-0}" -ge "$want" ] && { echo "$n"; return 0; }
    sleep 3
  done
  echo "${n:-0}"; return 1; }
# 无 clean 重启（数据 / WAL 目录必须跨重启保留）：stop → 核对 conf → start
#   框架启动脚本可能把 properties 还原成 conf_orig ⇒ 发现 dn_wal_dirs 不是 want 时用 cluster_write_conf 重写
# 逐步取证：记录每个 DN 的 properties 里 dn_wal_dirs 值 + 整个文件 md5（判断"哪一步被改回去"）
w24_props_probe(){ local step=$1 h v m
  for h in "${DN[@]}"; do
    v=$(wal_props_get "$h" dn_wal_dirs)
    m=$(sshx "$h" "md5sum $DB_DIR/conf/iotdb-system.properties 2>/dev/null | cut -c1-8" 2>/dev/null | tr -d '\r')
    log "    [props-$step] ${h##*.}: dn_wal_dirs='${v:-<空>}' file_md5=${m:-?}"
  done; }
w24_restart_noclean(){ local tag=$1 want=$2 n
  log "--- [$tag] 重启（cluster_stop → cluster_start；**不 clean**：数据与 WAL 目录要跨重启保留）---"
  w24_props_probe "before-stop"
  cluster_stop
  w24_props_probe "after-stop"
  n=$(w24_props_match dn_wal_dirs "$want")
  if [ "${n:-0}" -lt "${#DN[@]}" ]; then
    warn "[$tag] 停集群后 dn_wal_dirs ≠ $want（$n/${#DN[@]}）⇒ 用 cluster_write_conf 重写（不改变用例语义）"
    EXTRA_CONF="$(w24_strip_keys 'dn_wal_dirs'),dn_wal_dirs=$want,$CMP_EXTRA_WRITE" cluster_write_conf
    w24_props_probe "after-rewrite"
  fi
  cluster_start
  w24_props_probe "after-start"; }

# ===========================================================================
log "=== W-24 WAL 目录配置：库 $DB；${DEVS} 设备 × ${ROWS} 点/批；consensus=${CONSENSUS_CLASS##*.} ==="
log "  默认 WAL 根（源码口径 data/datanode/wal）：$DEF_WAL"
log "  自定义 WAL 根（本用例创建/清理）：$WAL_BASE ⇒ 单目录=[$CUSTOM1] 多目录=[$CUSTOM1,$CUSTOM2]"

# ---------------------------------------------------------------------------
# 相 0：只读探测（环境可行性 + 默认目录实际口径）
# ---------------------------------------------------------------------------
log "--- 相 0) 只读探测：默认 dn_wal_dirs / WAL 根实际路径 / 自定义基路径可写性 ---"
for h in "${DN[@]}"; do
  log "  [$h] properties dn_wal_dirs='$(wal_props_get "$h" dn_wal_dirs)'；配置解析出的 WAL 根=[$(wal_dir_roots "$h" | tr '\n' ' ')]"
  log "  [$h] 默认目录是否存在=$(w24_dir_exists "$h" "$DEF_WAL") 现有 .wal 数=$(w24_dir_files "$h" "$DEF_WAL")；wal_dir 键出现次数=$(sshx "$h" "grep -cE '^[[:space:]]*wal_dir[[:space:]]*=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null" 2>/dev/null | tr -dc '0-9')"
done
# 源码结论 §1.5/§14：只有 dn_wal_dirs，没有 wal_dir（单数）/ wal_dirs —— 静态核对（0 命中即合规）
N_WALDIR_KEY=0
for h in "${DN[@]}"; do
  N_WALDIR_KEY=$(( N_WALDIR_KEY + $(sshx "$h" "grep -hcE '^[[:space:]]*wal_dirs?[[:space:]]*=' $DB_DIR/conf/iotdb-system.properties 2>/dev/null | awk '{s+=\$1} END{print s+0}'" 2>/dev/null | tr -dc '0-9') ))
done
assert_eq "properties 里不存在 wal_dir/wal_dirs（单数/旧键）——只应有 dn_wal_dirs（source_grounding §1.5）" "${N_WALDIR_KEY:-0}" "0"
# 自定义基路径可写性（三副本都要能写；不可写则本用例降级为"只做默认目录相 + WARN"）
CUSTOM_OK=1
for h in "${DN[@]}"; do
  r=$(sshx "$h" "mkdir -p $WAL_BASE 2>/dev/null && touch $WAL_BASE/.w24_probe 2>/dev/null && rm -f $WAL_BASE/.w24_probe && echo OK" 2>/dev/null | tr -d '\r')
  if [ "$r" = "OK" ]; then
    log "  [$h] 自定义基路径可写：$WAL_BASE（$(sshx "$h" "df -P $WAL_BASE 2>/dev/null | tail -1" 2>/dev/null | tr -s ' ' | cut -c1-100)）"
  else
    CUSTOM_OK=0
    warn "  [$h] 自定义基路径不可写/不可创建：$WAL_BASE（返回 '$r'）"
  fi
done
if [ "$CUSTOM_OK" != "1" ]; then
  warn "本环境不可构造"自定义 WAL 目录"相（三副本中至少一个无法在 $WAL_BASE 下创建/写入）⇒ 只保留"默认目录相"的观测，跳过自定义目录与多目录相，**不判 FAIL**（环境构造问题，非产品行为）"
fi

# ---------------------------------------------------------------------------
# 相 A：默认目录（集群准备 + 造数据 + WAL 落到默认目录）
# ---------------------------------------------------------------------------
log "--- 相 A) 集群准备：EXTRA_CONF = (WAL_EXTRA_DEFAULT 去掉 dn_wal_dirs) + 关三类合并 ---"
EXTRA_CONF="$(w24_strip_keys 'dn_wal_dirs'),$CMP_EXTRA_WRITE" cmp_cluster_prepare
ACTIVE_A=$(wal_dir_roots "${DN[0]}" | head -1)
[ -n "$ACTIVE_A" ] || { ACTIVE_A="$DEF_WAL"; warn "相 A：wal_dir_roots 读不到（properties/目录探测都为空）⇒ 回落默认路径 $DEF_WAL"; }
log "  相 A 运行期默认 WAL 根（读 conf/探测）：$ACTIVE_A（期望 $DEF_WAL）"
[ "$ACTIVE_A" = "$DEF_WAL" ] && pass "相 A：默认 WAL 根 = $DEF_WAL（与源码默认 data/datanode/wal 一致）" \
  || warn "相 A：默认 WAL 根 = $ACTIVE_A ≠ $DEF_WAL（设计文档写 data/wal、源码写 data/datanode/wal；以实际为准，记录）"

cmp_make_tree_db "$DB" "$DEVS"
log "  写第 1 批（**不 flush**，数据只在 MemTable + WAL 上）"
w24_write_nf 1 || fail "相 A：第 1 批写入失败（场景无效）"
w24_wait_rows "$(w24_exp_rows)" 90 || warn "相 A：写入后行数未在 90s 内达到 $(w24_exp_rows)（后面只作证据）"
w24_assert_rows "相 A 第 1 批写入行数（场景有效性）" "$(w24_exp_rows)"
A_DBFILES=$(w24_wait_dir_files "$ACTIVE_A" 1 "$WIN")
A_BYTES=$(w24_sum2 w24_dir_bytes "$ACTIVE_A")
log "  相 A：默认目录 $(w24_sum2 w24_dir_files "$ACTIVE_A") 个 .wal / $(w24_sum2 w24_dir_db_files "$ACTIVE_A") 个属本库 / ${A_BYTES}B；逐副本=$(w24_per_node2 w24_dir_bytes "$ACTIVE_A")"
log "  相 A：本库 identifier 目录（逐副本）：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(w24_ident_dirs "$h" "$ACTIVE_A")"; done)"
[ "${A_DBFILES:-0}" -ge 1 ] && pass "相 A 场景有效：默认目录下本库 WAL 文件数=$A_DBFILES（>0）" \
  || fail "相 A 场景无效：默认目录 $ACTIVE_A 下没有本库的 .wal（观测口径或写入路径异常，先看上面打印的目录树/路径）"
BAD=$(w24_sum2 w24_bad_names "$ACTIVE_A")
assert_eq "相 A：WAL 文件名全部匹配 ^_[0-9]+-[0-9]+-[01]\\.wal$ (WALFileUtils.java:65-83)" "${BAD:-0}" "0"
for h in "${DN[@]}"; do
  [ -n "$(w24_ident_dirs "$h" "$ACTIVE_A")" ] && pass "相 A：$h 存在 <$DB-regionId> 形态的 WALNode 目录（$(w24_ident_dirs "$h" "$ACTIVE_A")）" \
    || warn "相 A：$h 未见到 <$DB-regionId> 形态的 WALNode 目录（identifier 命名与源码推断不符时需现场标定；只 WARN）"
done
wal_metrics_dump "${DN[0]}"

sq "flush;" >/dev/null
ensure_closed "$DB" 3 "$CLOSE_WIN" || warn "相 A：有副本的 TsFile 未在 ${CLOSE_WIN}s 内 Async close（只影响过程证据）"
FP_A=$(w24_fp); FPD_A=$(w24_fpd)
log "  相 A 基线指纹（已 flush，切换目录前必须落盘）：$FP_A"

# ---------------------------------------------------------------------------
# 相 B：单目录 —— ① SET 的 restart-only 文案 ② 未重启不生效 ③ 重启后落到自定义目录
# ---------------------------------------------------------------------------
if [ "$CUSTOM_OK" != "1" ]; then
  log "--- 相 B/C 跳过（自定义基路径不可写，见相 0 的 WARN）---"
else
  log "--- 相 B-1) SET CONFIGURATION 'dn_wal_dirs'='$CUSTOM1'（restart-only 文案判据）---"
  RESP=$(wal_set dn_wal_dirs "$CUSTOM1")
  log "  返回原文（来源：CLI 回显，helper wal_set）：$(printf '%s' "$RESP" | cut -c1-300)"
  assert_contains "相 B：SET 返回含 restart is required（模板 :287 # effectiveMode: restart）" "$RESP" "restart is required"
  assert_contains "相 B：SET 文案点名 dn_wal_dirs" "$RESP" "dn_wal_dirs"
  NPROP=$(w24_props_match dn_wal_dirs "$CUSTOM1")
  log "  落盘核对：dn_wal_dirs=$CUSTOM1 的 DN 数=$NPROP/${#DN[@]}（逐节点：$(w24_props_all dn_wal_dirs)）"
  if [ "${NPROP:-0}" -lt "${#DN[@]}" ]; then
    warn "相 B：SET 未让所有 DN 的 properties 落到 $CUSTOM1（$NPROP/${#DN[@]}）⇒ 改用 cluster_write_conf 兜底写入（restart-only 语义不变）"
    EXTRA_CONF="$(w24_strip_keys 'dn_wal_dirs'),dn_wal_dirs=$CUSTOM1,$CMP_EXTRA_WRITE" cluster_write_conf
    NPROP=$(w24_props_match dn_wal_dirs "$CUSTOM1")
    assert_eq "相 B：兜底写入后 properties 逐节点为 $CUSTOM1" "${NPROP:-0}" "${#DN[@]}"
  fi

  log "--- 相 B-2) 未重启不生效：继续写入 ⇒ 生效目录（$ACTIVE_A）增长、$CUSTOM1 不存在 ---"
  B_BEFORE=$(w24_sum2 w24_dir_bytes "$ACTIVE_A")
  C1_EXIST_BEFORE=$(w24_exists_sum "$CUSTOM1")
  w24_write_nf 2 || fail "相 B：第 2 批写入失败（场景无效）"
  B_AFTER=$(w24_sum2 w24_dir_bytes "$ACTIVE_A")
  C1_EXIST_AFTER=$(w24_exists_sum "$CUSTOM1")
  log "  生效目录 $ACTIVE_A 字节：$B_BEFORE → $B_AFTER（逐副本=$(w24_per_node2 w24_dir_bytes "$ACTIVE_A")）"
  log "  新目录 $CUSTOM1 存在的 DN 数：$C1_EXIST_BEFORE → $C1_EXIST_AFTER"
  [ "${B_AFTER:-0}" -gt "${B_BEFORE:-0}" ] && pass "相 B：未重启时 WAL 仍写入**旧**生效目录（字节 $B_BEFORE → $B_AFTER，restart-only 直接证据）" \
    || warn "相 B：未重启时旧目录字节未增长（$B_BEFORE → $B_AFTER）——记录：可能已轮转到旧目录的另一个文件/快照路径，需现场标定"
  assert_eq "相 B：未重启时新目录 $CUSTOM1 尚未被创建（目录创建发生在启动检查）" "${C1_EXIST_AFTER:-0}" "0"
  sq "flush;" >/dev/null
  ensure_closed "$DB" 3 "$CLOSE_WIN" || warn "相 B：TsFile 未全部 Async close（切目录前必须落盘，这里只记过程证据）"

  log "--- 相 B-3) 重启生效：WAL 必须落到 $CUSTOM1，且默认目录不再新增 ---"
  w24_restart_noclean "相 B" "$CUSTOM1"
  ROOTS_B=$(wal_dir_roots "${DN[0]}" | tr '\n' ' ')
  log "  重启后各 DN 的 WAL 根（读 conf）：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(wal_dir_roots "$h" | tr '\n' ' ')"; done)"
  case " $ROOTS_B " in *" $CUSTOM1 "*) pass "相 B：重启后生效 WAL 根含 $CUSTOM1（$ROOTS_B）";;
    *) fail "相 B：重启后生效 WAL 根不含 $CUSTOM1（实际 '$ROOTS_B'）——配置未生效或目录未注册";; esac
  assert_eq "相 B：重启后各 DN 都已创建 $CUSTOM1（IoTDBStartCheck.java:222-224）" "$(w24_exists_sum "$CUSTOM1")" "${#DN[@]}"

  DEF_BEFORE_B3=$(w24_sum2 w24_dir_bytes "$ACTIVE_A")
  log "  相 B：写第 3 批（**不 flush**，这批要靠 $CUSTOM1 里的 WAL 恢复）"
  w24_write_nf 3 || fail "相 B：第 3 批写入失败（场景无效）"
  C1_F=$(w24_wait_dir_files "$CUSTOM1" 1 "$WIN")
  C1_BYTES=$(w24_sum2 w24_dir_bytes "$CUSTOM1")
  DEF_AFTER_B3=$(w24_sum2 w24_dir_bytes "$ACTIVE_A")
  log "  $CUSTOM1：本库 WAL 文件=$C1_F 全目录字节=${C1_BYTES}B（逐副本=$(w24_per_node2 w24_dir_bytes "$CUSTOM1")）"
  log "  默认目录 $ACTIVE_A 字节：$DEF_BEFORE_B3 → $DEF_AFTER_B3（应**不再新增**）；默认目录属本库文件=$(w24_sum2 w24_dir_db_files "$ACTIVE_A")"
  [ "${C1_F:-0}" -ge 1 ] && pass "相 B 场景有效：自定义目录下本库 WAL 文件数=$C1_F（WAL 确实落到 dn_wal_dirs 指向的自定义目录）" \
    || fail "相 B 场景无效：自定义目录 $CUSTOM1 下没有本库的 .wal（配置未生效或路径口径不对）"
  BAD1=$(w24_sum2 w24_bad_names "$CUSTOM1")
  assert_eq "相 B：自定义目录下文件名全部合规（^_[0-9]+-[0-9]+-[01]\\.wal$）" "${BAD1:-0}" "0"
  [ "${DEF_AFTER_B3:-0}" -le "${DEF_BEFORE_B3:-0}" ] \
    && pass "相 B：默认目录不再新增（字节 $DEF_BEFORE_B3 → $DEF_AFTER_B3）" \
    || fail "相 B：默认目录仍在新增（字节 $DEF_BEFORE_B3 → $DEF_AFTER_B3）——切换后的 WAL 未完全落到自定义目录"
  FP_PRE=$(w24_fp); FPD_PRE=$(w24_fpd)
  log "  相 B：重启前指纹（第 3 批尚未 flush，只可能在 MemTable + WAL 上）：$FP_PRE"

  log "--- 相 B-4) 重启（不 flush）⇒ 第 3 批必须由 $CUSTOM1 的 WAL 重放恢复 ---"
  w24_restart_noclean "相 B-4" "$CUSTOM1"
  w24_wait_rows "$(w24_exp_rows)" "$WAL_REPLAY_WIN_SEC" || warn "相 B-4：重启后行数未在 ${WAL_REPLAY_WIN_SEC}s 内达到 $(w24_exp_rows)"
  w24_assert_rows "相 B-4 重启后总行数（数据面硬判据）" "$(w24_exp_rows)"
  cmp_assert_same "相 B-4 重启前后 count/sum/min/max（自定义目录 WAL 重放）" "$FP_PRE" "$(w24_fp)"
  cmp_assert_same "相 B-4 重启前后 $DB.d1 全序列" "$FPD_PRE" "$(w24_fpd)"
  cmp_assert_same "相 B-4 与相 A 基线指纹（前 2 批不得变化）" "$(printf '%s' "$FP_A" | sed 's/^/A/')" "$(printf '%s' "$(w24_fp)" | sed 's/^/A/')"
  sq "flush;" >/dev/null

  # -------------------------------------------------------------------------
  # 相 C：多目录（逗号分隔）—— 分布如实记录；"每个目录都非空"按 TP-08 只作弱断言
  # -------------------------------------------------------------------------
  log "--- 相 C-1) SET CONFIGURATION 'dn_wal_dirs'='$CUSTOM1,$CUSTOM2'（restart-only）---"
  RESP2=$(wal_set dn_wal_dirs "$CUSTOM1,$CUSTOM2")
  log "  返回原文：$(printf '%s' "$RESP2" | cut -c1-300)"
  assert_contains "相 C：SET 多目录返回含 restart is required" "$RESP2" "restart is required"
  NPROP2=$(w24_props_match dn_wal_dirs "$CUSTOM1,$CUSTOM2")
  log "  落盘核对：$NPROP2/${#DN[@]}（逐节点：$(w24_props_all dn_wal_dirs)）"
  if [ "${NPROP2:-0}" -lt "${#DN[@]}" ]; then
    warn "相 C：SET 未让所有 DN 落到多目录值（$NPROP2/${#DN[@]}）⇒ 用 cluster_write_conf 兜底"
    EXTRA_CONF="$(w24_strip_keys 'dn_wal_dirs'),dn_wal_dirs=$CUSTOM1,$CUSTOM2,$CMP_EXTRA_WRITE" cluster_write_conf
  fi
  if [ "$SKIP_C_PROBE" = "1" ]; then
    log "  相 C：W24_SKIP_C_PROBE=1 ⇒ 跳过"未重启不生效"探针写入（省一次写入）"
  else
    C1_BEFORE=$(w24_sum2 w24_dir_bytes "$CUSTOM1")
    w24_write_nf 4 || fail "相 C：第 4 批写入失败（场景无效）"
    C1_AFTER=$(w24_sum2 w24_dir_bytes "$CUSTOM1")
    log "  未重启：$CUSTOM1 字节 $C1_BEFORE → $C1_AFTER；$CUSTOM2 存在的 DN 数=$(w24_exists_sum "$CUSTOM2")"
    [ "${C1_AFTER:-0}" -ge "${C1_BEFORE:-0}" ] && pass "相 C：未重启时仍写旧目录组（$CUSTOM1 字节未下降）" \
      || warn "相 C：未重启时 $CUSTOM1 字节下降（$C1_BEFORE → $C1_AFTER，可能是清理线程删除旧 WAL；记录）"
    assert_eq "相 C：未重启时 $CUSTOM2 尚未创建" "$(w24_exists_sum "$CUSTOM2")" "0"
    sq "flush;" >/dev/null
  fi

  log "--- 相 C-2) 重启生效（多目录）⇒ 写第 5 批（不 flush），记录分布 ---"
  w24_restart_noclean "相 C" "$CUSTOM1,$CUSTOM2"
  ROOTS_C=$(wal_dir_roots "${DN[0]}" | tr '\n' ' ')
  NR=$(wal_dir_roots "${DN[0]}" | grep -c .)
  log "  重启后 WAL 根（逐节点）：$(for h in "${DN[@]}"; do printf '%s=[%s] ' "${h##*.}" "$(wal_dir_roots "$h" | tr '\n' ' ')"; done)"
  [ "${NR:-0}" -ge 2 ] && pass "相 C：重启后配置解析出 $NR 个 WAL 根（$ROOTS_C）" \
    || fail "相 C：重启后只解析出 ${NR:-0} 个 WAL 根（'$ROOTS_C'）——逗号分隔多目录未生效"
  assert_eq "相 C：$CUSTOM2 已在各 DN 创建" "$(w24_exists_sum "$CUSTOM2")" "${#DN[@]}"
  DEF_BEFORE_C=$(w24_sum2 w24_dir_bytes "$ACTIVE_A")
  w24_write_nf 5 || fail "相 C：第 5 批写入失败（场景无效）"
  C_TOTAL=$(w24_wait_dir_files "$CUSTOM1" 1 "$WIN")
  C1_DB=$(w24_sum2 w24_dir_db_files "$CUSTOM1"); C2_DB=$(w24_sum2 w24_dir_db_files "$CUSTOM2")
  C1_B=$(w24_sum2 w24_dir_bytes "$CUSTOM1"); C2_B=$(w24_sum2 w24_dir_bytes "$CUSTOM2")
  DEF_AFTER_C=$(w24_sum2 w24_dir_bytes "$ACTIVE_A")
  log "  多目录分布（本库文件数）：$CUSTOM1=$C1_DB  $CUSTOM2=$C2_DB；字节：$CUSTOM1=${C1_B}B  $CUSTOM2=${C2_B}B"
  log "  逐副本文件数：$CUSTOM1 → $(w24_per_node2 w24_dir_db_files "$CUSTOM1")；$CUSTOM2 → $(w24_per_node2 w24_dir_db_files "$CUSTOM2")"
  log "  默认目录 $ACTIVE_A 字节：$DEF_BEFORE_C → $DEF_AFTER_C（应仍不新增）；属本库文件=$(w24_sum2 w24_dir_db_files "$ACTIVE_A")"
  [ "$(( ${C1_DB:-0} + ${C2_DB:-0} ))" -ge 1 ] \
    && pass "相 C 场景有效：WAL 确实落在自定义多目录组内（$CUSTOM1+$CUSTOM2 本库文件 $(( ${C1_DB:-0} + ${C2_DB:-0} )) 个）" \
    || fail "相 C 场景无效：自定义多目录组内没有本库的 .wal"
  [ "${DEF_AFTER_C:-0}" -le "${DEF_BEFORE_C:-0}" ] \
    && pass "相 C：默认目录不再新增（字节 $DEF_BEFORE_C → $DEF_AFTER_C）" \
    || fail "相 C：默认目录仍在新增（字节 $DEF_BEFORE_C → $DEF_AFTER_C）"
  if [ "${C1_DB:-0}" -ge 1 ] && [ "${C2_DB:-0}" -ge 1 ]; then
    pass "相 C：多目录**均有** WAL（TP-08 期望成立）"
  else
    warn "相 C：多目录分布不均（$CUSTOM1=$C1_DB、$CUSTOM2=$C2_DB，某个目录为空）⇒ **只 WARN 不判 FAIL**：design_extract TP-08 原文即"分配策略文档未提及，只断言都非空"，且源码 WALManager.java:76-85 在 IoTConsensus(V2) 下用 FirstCreateStrategy（每 region 一 WALNode，不按目录轮转）。逐副本证据：$CUSTOM1=$(w24_per_node2 w24_dir_db_files "$CUSTOM1") $CUSTOM2=$(w24_per_node2 w24_dir_db_files "$CUSTOM2")"
  fi
  FP_PRE_C=$(w24_fp); FPD_PRE_C=$(w24_fpd)
  log "  相 C：重启前指纹（第 5 批未 flush）：$FP_PRE_C"

  log "--- 相 C-3) 重启（不 flush）⇒ 第 5 批必须由多目录里的 WAL 重放恢复 ---"
  w24_restart_noclean "相 C-3" "$CUSTOM1,$CUSTOM2"
  w24_wait_rows "$(w24_exp_rows)" "$WAL_REPLAY_WIN_SEC" || warn "相 C-3：重启后行数未在 ${WAL_REPLAY_WIN_SEC}s 内达到 $(w24_exp_rows)"
  w24_assert_rows "相 C-3 重启后总行数（数据面硬判据）" "$(w24_exp_rows)"
  cmp_assert_same "相 C-3 重启前后 count/sum/min/max（多目录 WAL 重放）" "$FP_PRE_C" "$(w24_fp)"
  cmp_assert_same "相 C-3 重启前后 $DB.d1 全序列" "$FPD_PRE_C" "$(w24_fpd)"
  log "  相 C-3 后：默认目录属本库文件=$(w24_sum2 w24_dir_db_files "$ACTIVE_A")，$CUSTOM1=$(w24_sum2 w24_dir_db_files "$CUSTOM1")，$CUSTOM2=$(w24_sum2 w24_dir_db_files "$CUSTOM2")"

  log "--- 相 C-4) 终态记录：配置值（逐节点）---"
  log "  dn_wal_dirs（properties）=$(w24_props_all dn_wal_dirs)"
  log "  自定义目录体积：$CUSTOM1=$(w24_sum2 w24_dir_bytes "$CUSTOM1")B $CUSTOM2=$(w24_sum2 w24_dir_bytes "$CUSTOM2")B（WAL_DIR_BASE=$WAL_BASE）"
  if [ "$KEEP_DIRS" = "1" ]; then
    warn "自定义 WAL 目录保留作证据：$CUSTOM1 / $CUSTOM2（清理：三节点 rm -rf $WAL_BASE；或用 W24_KEEP_DIRS=0 让后续轮次自行清理）"
  else
    for h in "${DN[@]}"; do sshx "$h" "rm -rf $WAL_BASE" >/dev/null 2>&1 || warn "  清理 $h:$WAL_BASE 失败"; done
    log "  已清理自定义 WAL 目录 $WAL_BASE（KEEP_DIRS=0）"
  fi
fi

# ---------------------------------------------------------------------------
# 收尾三件套
# ---------------------------------------------------------------------------
log "--- 收尾三件套（WAL 正证据 + 默认异常面；本用例不装 WAL 建议正则：SET/目录切换本身会打 WAL 相关行）---"
export CMP_POSITIVE_EVIDENCE_FN=wal_positive_evidence
export WAL_EVIDENCE_DB="$DB"
export CMP_LOG_BENIGN_EXTRA='Execute FragmentInstance[^|]*failed|Failed to CHANGE_REGION_LEADER|RatisRequestFailedException|transferLeader|Connection refused|Connection reset by peer'
post_checks "select count(s1) from $DB.d1 order by time;" tree
cmp_case_finish "" tree ""
