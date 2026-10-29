#!/bin/bash
# ============================================================================
# 存储模块 WAL（写前日志）专项 skill —— 用例集合入口
#   bash tools/run_all.sh [--set smoke|mode|recover|file|compress|cleanup|mem|object|param|observe|ha|all]
#                         [--only W-01,W-04]
#   smoke   = 冒烟（写→flush→读一致 + WAL 目录确有文件，链路通畅）
#   mode    = wal_mode 语义：模式矩阵 / 集群下 DISABLE 被拒 / restart-only
#   recover = 故障恢复：kill -9 重放 / flush 边界 / DN 下线期写入 / 元数据恢复
#   file    = WAL 文件面：轮转阈值 / buffer 大小 / WALNode 分配
#   compress= WAL 压缩：开关对比 / 压缩态恢复 / 开关切换后的混合兼容
#   cleanup = 无效 WAL 清理：删除周期 / 最小有效信息比 / MemTable 快照
#   mem     = 内存与背压：阻写阈值 / 大压力下队列内存受控
#   object  = OBJECT 类型：写入恢复 / 导入后重启一致性
#   param   = 参数合法性（非法取值拒绝）与热加载语义
#   observe = 可观测性：监控指标 / WAL 目录配置
#   ha      = 高可用：WAL 盘 readonly / 双协议对照
#   all     = 全部（矩阵里的每一条）
#   ✅ 集合是**显式 ID 清单**（见下 case_in_set），不用编号区间：加用例必须显式决定归属。
#                         [--consensus IoTConsensus|IoTConsensusV2] [--ver <版本目录名>]
#   每条用例自己负责 清集群/写配置/启动，串行执行（并行会互相污染 WAL 文件与日志计数）。
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$(cd "$HERE/.." && pwd)"
SET=all; ONLY=""; CONSENSUS=""; VER=""
while [ $# -gt 0 ]; do
  case "$1" in
    --set) SET="$2"; shift 2 ;;
    --only) ONLY="$2"; shift 2 ;;
    --consensus) CONSENSUS="$2"; shift 2 ;;
    --ver) VER="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; shift ;;
  esac
done
# 集合名白名单：写错 --set 绝不"默默跑全部"
case "$SET" in
  smoke|mode|recover|file|compress|cleanup|mem|object|param|observe|ha|all) ;;
  *) echo "未知 --set: $SET（支持 smoke|mode|recover|file|compress|cleanup|mem|object|param|observe|ha|all）" >&2; exit 2 ;;
esac
. "$SKILL/conf/env.conf"
[ -n "$VER" ] && { V_TESTDB="$VER"; BUILD_TAG="$VER"; }
[ -n "$CONSENSUS" ] && DATA_CONSENSUS="$CONSENSUS"
export V_TESTDB BUILD_TAG DATA_CONSENSUS

RUN_ID=$(date +%Y%m%d_%H%M%S)
OUTDIR="$SKILL/results"; mkdir -p "$OUTDIR"

# 用例矩阵（含空矩阵保护）
mapfile -t LINES < <(grep -vE '^\s*#|^\s*$' "$SKILL/cases/cases.tsv")
[ "${#LINES[@]}" -gt 0 ] || { echo "!! cases/cases.tsv 里没有任何用例（只有注释行），本次无事可做。" >&2; exit 3; }

# ---------------------------------------------------------------------------
# 并发保护：两个 run_all 同时跑会互相 清 data/启停节点，必然产生假 FAIL。
# ---------------------------------------------------------------------------
LOCK="$OUTDIR/.run_all.lock"
exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
  echo "!! 已有另一个 run_all.sh 正在运行（锁 $LOCK，持有者：$(head -c 200 "$LOCK" 2>/dev/null)），本次退出。" >&2
  exit 2
fi
printf 'pid=%s set=%s only=%s start=%s\n' "$$" "$SET" "$ONLY" "$(date '+%F %T')" >&9

SUITE="$OUTDIR/SUITE_${SET}_${RUN_ID}.out"
CSV="$OUTDIR/test_result.csv"
[ -f "$CSV" ] || echo 'Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$CSV"

case_in_set(){ local id=$1 set_ids=""
  # 集合 = **显式 ID 清单**。各集合含义（与 cases/cases.tsv 的"说明"列一致）：
  #   smoke   = W-00                                    骨架冒烟
  #   mode    = W-01,W-02,W-03                          模式矩阵 / DISABLE 拒绝 / restart-only
  #   recover = W-04,W-05,W-06,W-07                     kill-9 重放 / flush 边界 / DN 下线 / 元数据
  #   file    = W-08,W-09,W-10                          轮转阈值 / buffer / WALNode 分配
  #   compress= W-11,W-12,W-13                          压缩开关 / 压缩态恢复 / 混合兼容
  #   cleanup = W-14,W-15,W-16                          删除周期 / 最小有效比 / MemTable 快照
  #   mem     = W-17,W-18                               阻写阈值 / 队列内存受控
  #   object  = W-19,W-20                               OBJECT 写入恢复 / 导入后重启
  #   param   = W-21,W-22                               非法取值 / 热加载
  #   observe = W-23,W-24                               监控指标 / WAL 目录配置
  #   ha      = W-25,W-26                               盘 readonly / 双协议对照
  case "$SET" in
    all)     return 0 ;;
    smoke)   set_ids="W-00" ;;
    mode)    set_ids="W-01 W-02 W-03" ;;
    recover) set_ids="W-04 W-05 W-06 W-07" ;;
    file)    set_ids="W-08 W-09 W-10" ;;
    compress) set_ids="W-11 W-12 W-13" ;;
    cleanup) set_ids="W-14 W-15 W-16" ;;
    mem)     set_ids="W-17 W-18" ;;
    object)  set_ids="W-19 W-20" ;;
    param)   set_ids="W-21 W-22" ;;
    observe) set_ids="W-23 W-24" ;;
    ha)      set_ids="W-25 W-26" ;;
    *)       return 1 ;;
  esac
  case " $set_ids " in *" $id "*) return 0 ;; *) return 1 ;; esac
}
echo "=== WAL 专项用例集 set=$SET build=$V_TESTDB consensus=$DATA_CONSENSUS $(date '+%F %T') ===" | tee "$SUITE"
PASS=0; FAIL=0; SKIP=0
for line in "${LINES[@]}"; do
  IFS=$'\t' read -r id script model gran restart params desc <<<"$line"
  case_in_set "$id" || { SKIP=$((SKIP+1)); continue; }
  if [ -n "$ONLY" ] && ! printf ',%s,' "$ONLY" | grep -q ",$id,"; then SKIP=$((SKIP+1)); continue; fi
  echo "" | tee -a "$SUITE"
  echo "########## [$id] $desc —— $(date '+%F %T') ##########" | tee -a "$SUITE"
  T0=$(date +%s)
  bash "$SKILL/$script" ${CONSENSUS:+--consensus "$CONSENSUS"} </dev/null >"$OUTDIR/${id}_${RUN_ID}.out" 2>&1
  rc=$?; T1=$(date +%s); EL=$((T1-T0))
  RES=$(grep -aE '^\[[^]]*\] RESULT ' "$OUTDIR/${id}_${RUN_ID}.out" | tail -1)
  STATUS=$(printf '%s' "$RES" | grep -oE 'RESULT (PASS|FAIL)' | awk '{print $2}')
  FF=$(printf '%s' "$RES" | grep -oE 'fail_flag=[0-9]+' | cut -d= -f2)
  MSG=$(grep -aE '^\[[^]]*\] v_warnMessage=' "$OUTDIR/${id}_${RUN_ID}.out" | tail -1 | sed 's/.*v_warnMessage=//' | tr '\n\r' '  ' | tr -s ' ' | tr ',' ';' | tr -d "'" | cut -c1-1200)
  [ -z "$STATUS" ] && STATUS="UNKNOWN"
  [ "$STATUS" = "PASS" ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
  echo "  -> rc=$rc [$STATUS] fail_flag=${FF:-?} elapsed=${EL}s 输出=$OUTDIR/${id}_${RUN_ID}.out" | tee -a "$SUITE"
  [ -n "$MSG" ] && echo "     message: ${MSG:0:220}" | tee -a "$SUITE"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,\047%s\047\n' "$(date --iso-8601=seconds)" "$BUILD_TAG" "${DATA_CONSENSUS}" "$id" "$STATUS" "$EL" "${FF:-}" "$OUTDIR/${id}_${RUN_ID}.out" "$MSG" >>"$CSV"
done
echo "" | tee -a "$SUITE"
echo "=== 汇总 $(date '+%F %T')：PASS=$PASS FAIL=$FAIL 跳过=$SKIP ===" | tee -a "$SUITE"
echo "明细 CSV：$CSV"
echo "套件输出：$SUITE"
