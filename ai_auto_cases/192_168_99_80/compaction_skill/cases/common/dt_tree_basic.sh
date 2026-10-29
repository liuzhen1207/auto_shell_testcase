#!/bin/bash
# ============================================================================
# DT-01 修改数据类型（树模型）基础功能 + 兼容性矩阵（正向）
#
# 需求来源：《修改数据类型手册更新内容》树模型 2.3「修改时间序列数据类型」（V2.0.8+，企业版）
#   `ALTER TIMESERIES fullPath SET DATA TYPE newType`
#   兼容性表（原始 → 可变更为）：INT32→{INT64,FLOAT,DOUBLE,TIMESTAMP,STRING,TEXT}、INT64→{TIMESTAMP,DOUBLE,STRING,TEXT}、
#   FLOAT→{DOUBLE,STRING,TEXT}、DOUBLE→{STRING,TEXT}、BOOLEAN→{STRING,TEXT}、TEXT→{BLOB,STRING}、
#   STRING→{TEXT,BLOB}、BLOB→{STRING,TEXT}、DATE→{STRING,TEXT}、TIMESTAMP→{INT64,DOUBLE,STRING,TEXT}
#
# 场景：10 种原始类型各建 1 条序列 → 写 2 行 → 逐条按兼容表 ALTER → 断言：
#   ① 写进去的数据真的能查到（树方言 FROM 用**设备路径**：`select s1 from root.db.dev`）；
#   ② 每条转换都成功；③ `show timeseries` 的 DataType = 目标类型且三副本一致；④ 改后行数不减、值可读。
# 用法： bash dt_tree_basic.sh [--consensus ...]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../lib/common.sh"
. "$HERE/../../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "dt_tree_basic_${DATA_CONSENSUS}"

DB=root.dtb
BASE=$(( ($(date +%s) - 3600) * 1000 ))

dt01_mk(){ local p="$DB.$1.s1" t=$2 out
  out=$(sq "create timeseries $p with datatype=$t, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1)
  printf '%s' "$out" | grep -q successfully && { echo 1; return; }
  # 某些类型（实测 TIMESTAMP）不接受 PLAIN/UNCOMPRESSED ⇒ 用默认编码重试，并把首个错误打进日志
  log "      （$t 用 PLAIN/UNCOMPRESSED 建失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140)；改用默认编码重试）"
  out=$(sq "create timeseries $p with datatype=$t;" 2>&1)
  if printf '%s' "$out" | grep -q successfully; then echo 1; else log "      （$t 建序列仍失败：$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-140)）"; echo 0; fi; }
dt01_write(){ local p="$DB.$1" n
  n=$(sq "insert into $p(time,s1) values ($(( BASE + 100 )),$2),($(( BASE + 110 )),$3);" 2>&1 | grep -c successfully)
  [ "${n:-0}" -ge 1 ] && { echo "$n"; return; }
  # TIMESTAMP 列也接受不带引号的字面量，失败时回退一次
  n=$(sq "insert into $p(time,s1) values ($(( BASE + 100 )),${2//\'/}),($(( BASE + 110 )),${3//\'/});" 2>&1 | grep -c successfully)
  echo "${n:-0}"; }

log "--- 集群准备：三类合并先关（本用例只看类型变更本身）---"
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

log "--- 建库 + 10 种原始类型序列（各写 2 行）---"
sq "create database $DB;" >/dev/null
declare -A VAL1=( [INT32]=42 [INT64]=42 [FLOAT]=1.5 [DOUBLE]=1.5 [BOOLEAN]=true [TEXT]="'abc'" [STRING]="'abc'" [BLOB]="X'0A0B'" [DATE]="'2026-01-02'" [TIMESTAMP]=2026-01-01T00:00:00 )
declare -A VAL2=( [INT32]=43 [INT64]=43 [FLOAT]=2.5 [DOUBLE]=2.5 [BOOLEAN]=false [TEXT]="'def'" [STRING]="'def'" [BLOB]="X'0C0D'" [DATE]="'2026-01-03'" [TIMESTAMP]=2026-01-01T00:00:01 )
# 注意 1：设备名不能直接用类型关键字（`root.db.TIMESTAMP.s1` 会被解析器拒绝：700 解析失败）
# 注意 2：TIMESTAMP 测量列只接受**不带引号**的字面量（'2026-01-01T00:00:00' 会报 507 data type is not consistent）
for t in INT32 INT64 FLOAT DOUBLE BOOLEAN TEXT STRING BLOB DATE TIMESTAMP; do
  mk=$(dt01_mk "t_$t" "$t")
  n=$(dt01_write "t_$t" "${VAL1[$t]}" "${VAL2[$t]}")
  if [ "${mk:-0}" -ge 1 ] && [ "${n:-0}" -ge 1 ]; then
    pass "  建/写 $t 序列成功（dev=t_$t）"
  else
    fail "  建/写 $t 序列失败（dev=t_$t create=$mk insert=$n）"
  fi
done
sq "flush;" >/dev/null; sleep 6

log "--- 逐条按兼容表做正向转换 ---"
MATRIX="INT32:INT64,FLOAT,DOUBLE,TIMESTAMP,STRING,TEXT
INT64:TIMESTAMP,DOUBLE,STRING,TEXT
FLOAT:DOUBLE,STRING,TEXT
DOUBLE:STRING,TEXT
BOOLEAN:STRING,TEXT
TEXT:BLOB,STRING
STRING:TEXT,BLOB
BLOB:STRING,TEXT
DATE:STRING,TEXT
TIMESTAMP:INT64,DOUBLE,STRING,TEXT"
IDX=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  src=${line%%:*}; targets=${line#*:}
  first=1
  IFS=',' read -ra TG <<<"$targets"
  for to in "${TG[@]}"; do
    IDX=$(( IDX + 1 ))
    dev="m${IDX}"
    wresp=$(dt01_mk "$dev" "$src")
    wresp=$(dt01_write "$dev" "${VAL1[$src]}" "${VAL2[$src]}")
    sq "flush;" >/dev/null; sleep 4
    p="$DB.$dev.s1"
    rows0=$(cmp_rows_series "$p")
    resp=$(cmp_alter_ts "$p" "$to")
    ty=$(cmp_series_type "$p"); same=$(cmp_type_same_all "$p" "$to")
    rows1=$(cmp_rows_series "$p")
    vals=$(cmp_vals_series "$p" 2)
    if [ "$first" = 1 ]; then first=0; log "    （$src 写响应=$wresp；首个转换响应：$(printf '%s' "$resp" | cut -c1-120)）"; fi
    if [ "${rows0:-0}" -lt 2 ]; then
      fail "  [$src → $to] 写数据后只有 ${rows0:-0} 行（期望 2）—— 场景无效（写响应=$wresp）"
    elif printf '%s' "$resp" | grep -qi successfully; then
      if [ "$ty" = "$to" ] && [ "$same" = 1 ] && [ "${rows1:-0}" -ge "${rows0:-0}" ]; then
        pass "  [$src → $to] 成功：类型=$ty（三副本一致）行数 $rows0→$rows1 值=$vals"
      else
        fail "  [$src → $to] 响应成功但类型/副本/行数异常：类型=$ty same=$same 行数 $rows0→$rows1"
      fi
    else
      fail "  [$src → $to] 正向转换失败：$(printf '%s' "$resp" | cut -c1-160)"
    fi
  done
done <<<"$MATRIX"

log "--- 收尾三件套 ---"
post_checks "select s1 from $DB.m1 order by time;" tree
cmp_case_finish "" tree ""
