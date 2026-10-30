#!/bin/bash
# ============================================================================
# 身份鉴别一键回归（两种模式）
#   normal     : 不开启三权分立（root 全权）          27 条
#   separation : 开启三权分立（sys/security/audit）   33 条
#   合计 34 条；AUTH-026 只在 normal 跑，AUTH-030~036 只在 separation 跑
#
# 用法：
#   bash tools/run_regression.sh                  # 两种模式全跑，结束自动恢复 normal
#   bash tools/run_regression.sh --no-restore     # 不自动恢复（保持当前模式）
#   bash tools/run_regression.sh --only normal    # 只跑一种模式
#   bash tools/run_regression.sh AUTH-001 AUTH-017  # 指定用例（两种模式都跑）
#
# 退出码：0 全部通过；10 仅命中已知缺陷；3 存在新增失败；4 环境异常
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
for _p in "$BASE/conf/env.conf" "$BASE/scripts/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
for _p in "$BASE/lib/lib_auth.sh" "$BASE/scripts/lib_auth.sh"; do [ -f "$_p" ] && . "$_p" && break; done
if ! command -v L >/dev/null 2>&1; then echo "环境错误：未加载 lib_auth.sh（检查 lib/ 或 scripts/ 目录）"; exit 4; fi
KNOWN="${KNOWN:-$BASE/conf/known_failures.conf}"
[ -f "$KNOWN" ] || KNOWN="$BASE/scripts/known_failures.conf"

RESTORE=1
ONLY=all
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --no-restore) RESTORE=0 ;;
    --only) shift; ONLY="${1:-all}" ;;
    *) ARGS+=("$1") ;;
  esac
  shift
done
set -- ${ARGS[@]+"${ARGS[@]}"}

RESULT_ROOT="${RESULT_ROOT:-$BASE/results}"
OUT_DIR="$RESULT_ROOT/regression_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT_DIR"

is_known() {  # id mode -> 缺陷号
  local id=$1 mode=$2
  [ -f "$KNOWN" ] || return 1
  awk -F'|' -v id="$id" -v m="$mode" '
    /^[[:space:]]*#/ || NF<2 {next}
    { gsub(/[[:space:]]/,"",$1); gsub(/[[:space:]]/,"",$2);
      if ($1==id && ($2=="all" || $2==m)) { print $3; exit } }' "$KNOWN"
}

enable_separation() {
  L root "$PW" "set configuration 'enable_separation_of_powers'='true'" >/dev/null 2>&1
  sleep 4
}

disable_separation() {
  local ip
  for ip in $CN_LIST; do
    ssh -o StrictHostKeyChecking=no root@$ip \
      "f=$CN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_separation_of_powers=/d' \$f; echo 'enable_separation_of_powers=false' >> \$f" 2>/dev/null
  done
  for ip in $DN_LIST; do
    ssh -o StrictHostKeyChecking=no root@$ip \
      "f=$DN_DIR/conf/iotdb-system.properties; touch \$f; sed -i '/^enable_separation_of_powers=/d' \$f; echo 'enable_separation_of_powers=false' >> \$f" 2>/dev/null
  done
  ( cd "$BASE" && NEW="$NEW" bash tools/hard_reset.sh > "$OUT_DIR/restore.log" 2>&1 )
}

run_mode() {  # mode [case ids...]
  local mode=$1; shift
  local log="$OUT_DIR/mode_$mode.log"
  echo "[$(date +%T)] ===== 模式 $mode ====="
  local start_epoch; start_epoch=$(date +%s)
  local runner="$BASE/tools/suite_auth.sh"
  [ -f "$runner" ] || runner="$BASE/scripts/suite_auth.sh"
  MODE="$mode" bash "$runner" "$@" > "$log" 2>&1
  local rd
  rd=$(ls -td "$RESULT_ROOT"/run_* 2>/dev/null | while read -r d; do
         [ "$(stat -c %Y "$d")" -ge "$start_epoch" ] && { echo "$d"; break; }
       done)
  if [ -z "${rd:-}" ]; then
    echo "[$(date +%T)] $mode: 未生成本轮结果（见 $log）"; echo "" > "$OUT_DIR/$mode.rundir"; return 1
  fi
  echo "$rd" > "$OUT_DIR/$mode.rundir"
  echo "[$(date +%T)] $mode: $(grep -cE '\-> PASS' "$log") PASS / $(grep -cE '\-> FAIL' "$log") FAIL  ($rd)"
}

NEWFAIL=0
KNOWNHIT=0
summary() {  # mode
  local mode=$1 rd; rd=$(cat "$OUT_DIR/$mode.rundir" 2>/dev/null)
  [ -f "$rd/results.tsv" ] || { echo "  ! $mode 缺少 results.tsv"; NEWFAIL=$((NEWFAIL+1)); return; }
  local id feature ctype verdict fails errs dur msg tdb
  while IFS=$'\t' read -r id feature ctype verdict fails errs dur msg; do
    case "$id" in AUTH-*) ;; *) continue ;; esac
    [ "$verdict" = "PASS" ] && continue
    tdb=$(is_known "$id" "$mode")
    if [ -n "${tdb:-}" ]; then
      KNOWNHIT=$((KNOWNHIT+1))
      printf "  [已知缺陷] %-9s %-10s %s\n" "$id" "$mode" "$tdb"
    else
      NEWFAIL=$((NEWFAIL+1))
      printf "  [新失败]   %-9s %-10s fails=%s errs=%s\n" "$id" "$mode" "$fails" "$errs"
    fi
  done < <(tail -n +2 "$rd/results.tsv")
}

run_mode normal "$@"
if [ "$ONLY" = "all" ] || [ "$ONLY" = "separation" ]; then
  enable_separation
  run_mode separation "$@"
fi

echo
echo "================ 汇总 ================"
summary normal
[ -f "$OUT_DIR/separation.rundir" ] && summary separation
echo "--------------------------------------"
echo "已知缺陷失败: $KNOWNHIT    新增失败: $NEWFAIL"
echo "产物目录: $OUT_DIR"

if [ "$RESTORE" = "1" ] && [ -f "$OUT_DIR/separation.rundir" ]; then
  echo "[$(date +%T)] 恢复 normal 模式（改配置 + 重启，约 4 分钟）…"
  disable_separation
  echo "[$(date +%T)] 恢复完成"
fi

[ "$NEWFAIL" -gt 0 ] && exit 3
[ "$KNOWNHIT" -gt 0 ] && exit 10
exit 0
