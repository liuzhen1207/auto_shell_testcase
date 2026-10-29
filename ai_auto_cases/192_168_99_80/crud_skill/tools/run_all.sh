#!/bin/bash
# ============================================================================
# 存储模块 CRUD 专项 skill —— 用例集合入口
#   bash tools/run_all.sh [--set smoke|write|delete|load|object|all]
#                         [--only CR-01,CR-03]
#   smoke  = 冒烟（写入 → 合并 → 读数一致，链路通畅）；write = 写入/更新路径；
#   delete = 删除（DELETE / DELETE TIMESERIES / DROP）路径；load = LOAD/导入导出路径；
#   object = 对象/复杂类型（OBJECT、对齐、空值等）；all = 全部。
#   ✅ 集合是**显式 ID 清单**（见下 case_in_set；不再用编号区间）：加用例时要显式决定归属哪个集合。
#   smoke=CR-00；write=CR-01..CR-03；delete=CR-04..CR-10；load=CR-13,CR-14；object=CR-11,CR-12。
#                         [--consensus IoTConsensus|IoTConsensusV2] [--ver <版本目录名>]
#   每条用例自己负责 清集群/写配置/启动，串行执行（并行会互相污染 TsFile 与日志计数）。
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
# 集合名白名单：写错 --set 绝不"默默跑全部"（继承来的 `*) return 0` 会让拼错的集合跑全量回归）
case "$SET" in
  smoke|write|delete|load|object|all) ;;
  *) echo "未知 --set: $SET（支持 smoke|write|delete|load|object|all）" >&2; exit 2 ;;
esac
. "$SKILL/conf/env.conf"
[ -n "$VER" ] && { V_TESTDB="$VER"; BUILD_TAG="$VER"; }
[ -n "$CONSENSUS" ] && DATA_CONSENSUS="$CONSENSUS"
export V_TESTDB BUILD_TAG DATA_CONSENSUS

RUN_ID=$(date +%Y%m%d_%H%M%S)
OUTDIR="$SKILL/results"; mkdir -p "$OUTDIR"

# 用例矩阵（含空矩阵保护：空数组在 bash 里会展开成"一个空行"，直接进循环会去执行空脚本名）
#   放在加锁/建 CSV 之前：空矩阵时直接退出，不留下锁文件与空 test_result.csv
mapfile -t LINES < <(grep -vE '^\s*#|^\s*$' "$SKILL/cases/cases.tsv")
[ "${#LINES[@]}" -gt 0 ] || { echo "!! cases/cases.tsv 里没有任何用例（只有注释行），本次无事可做。" >&2; exit 3; }

# ---------------------------------------------------------------------------
# 并发保护：两个 run_all 同时跑会互相 清 data/启停节点，必然产生假 FAIL
#（合并 skill 上实测过：一条用例被另一条的集群清理打成 "550: Table does not exist"）。
# 用 flock 非阻塞加锁，拿不到锁直接退出。
# ---------------------------------------------------------------------------
LOCK="$OUTDIR/.run_all.lock"
exec 9>"$LOCK" || exit 1
if ! flock -n 9; then
  echo "!! 已有另一个 run_all.sh 正在运行（锁 $LOCK，持有者：$(head -c 200 "$LOCK" 2>/dev/null)），本次退出。" >&2
  echo "   并发跑会互相清库/启停节点，产生假 FAIL；请等它结束或先 kill。" >&2
  exit 2
fi
printf 'pid=%s set=%s only=%s start=%s\n' "$$" "$SET" "$ONLY" "$(date '+%F %T')" >&9

SUITE="$OUTDIR/SUITE_${SET}_${RUN_ID}.out"
CSV="$OUTDIR/test_result.csv"
[ -f "$CSV" ] || echo 'Time,build,consensus,caseName,result,elapsedSeconds,failCount,artifact,message' >>"$CSV"

case_in_set(){ local id=$1 set_ids=""
  # 集合 = **显式 ID 清单**（不再用"编号区间"）。
  #   为什么改：区间会把编号相邻但语义无关的用例卷进来（CR-11/CR-12 是 object，却落在 CR-1x 区间的边界上），
  #   而且新增用例时"落在哪个区间"完全靠编号巧合 —— 清单化以后，加用例必须显式决定它属于哪个集合。
  # 各集合含义（与 cases/cases.tsv 的"粒度/说明"列一致）：
  #   smoke  = CR-00                     骨架冒烟：建库→写→flush→合并→读数一致→收尾三件套，保证 harness 端到端可用
  #   write  = CR-01,CR-02,CR-03         写入/更新路径的校验与配置：时间戳精度门禁、精度×时间分区、表模型"只有 Time 列"
  #   delete = CR-04..CR-10              删除路径：.mods2 形态 / Mod 分配阈值 / 删除×合并并发 / 删除中间态 /
  #                                      Pipe 传输带删除的 TsFile / Mod 生命周期与重启恢复 / DELETE 阻塞写入量化
  #   load   = CR-13,CR-14               LOAD 导入导出：Load 时 LastCache 四策略正确性、Load×Pipe+Last（restart-only
  #                                      语义 + 性能与内存预算）
  #   object = CR-11,CR-12               对象/复杂类型：OBJECT 手动删除后的物理清理、OBJECT 删除异常路径
  #   all    = 全部（矩阵里的每一条）
  case "$SET" in
    all)    return 0 ;;
    smoke)  set_ids="CR-00" ;;
    write)  set_ids="CR-01 CR-02 CR-03" ;;
    delete) set_ids="CR-04 CR-05 CR-06 CR-07 CR-08 CR-09 CR-10" ;;
    load)   set_ids="CR-13 CR-14" ;;
    object) set_ids="CR-11 CR-12" ;;
    *)      return 1 ;;   # 未知集合：不选中任何用例（正常入口已被上面的白名单拦住）
  esac
  case " $set_ids " in *" $id "*) return 0 ;; *) return 1 ;; esac
}
echo "=== CRUD 专项用例集 set=$SET build=$V_TESTDB consensus=$DATA_CONSENSUS $(date '+%F %T') ===" | tee "$SUITE"
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
