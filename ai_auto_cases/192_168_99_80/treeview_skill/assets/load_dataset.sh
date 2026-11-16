#!/bin/bash
# ============================================================================
# assets/load_dataset.sh —— 把真实树模型 TsFile 装进 3C3D
#   1) 解压 zip（幂等）到 $TV_DATA_DIR
#   2) 分发到三台 DN 的同一路径（load 读的是 DN 本地磁盘）
#   3) 每个 DN 各自 load 该目录（树方言）
#   4) flush + 等三节点 count 对齐
# 用法：bash assets/load_dataset.sh [--zip /data/iotdb/treeview_tsfile.zip]
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
tv_load_env
tv_parse_args "$@"

ZIP=${TV_DATA_ZIP:-/data/iotdb/treeview_tsfile.zip}
DEST=${TV_DATA_DIR:-/tmp/treeview/tsfile}
TREE_DB=${TV_DATA_DB:-root.reactor}

log "=== 1) 解压 $ZIP → /tmp/treeview ==="
if [ ! -d "$DEST" ] || [ -z "$(ls -A "$DEST" 2>/dev/null)" ]; then
  if [ ! -f "$ZIP" ]; then
    log "!! 找不到 $ZIP（先把 tsfile.zip 传到 99.80 的这个路径）"
    exit 2
  fi
  mkdir -p /tmp/treeview
  unzip -o -q "$ZIP" -d /tmp/treeview || { log "!! 解压失败"; exit 2; }
  # zip 内是 tsfile/ 子目录
  if [ -d /tmp/treeview/tsfile ] && [ "$DEST" != "/tmp/treeview/tsfile" ]; then
    mkdir -p "$DEST"; mv /tmp/treeview/tsfile/* "$DEST"/ 2>/dev/null || true
  fi
fi
CNT=$(ls -1 "$DEST"/*.tsfile 2>/dev/null | wc -l)
SZ=$(du -sm "$DEST" 2>/dev/null | awk '{print $1}')
log "  本地文件数=$CNT 体积=${SZ:-0}MB 目录=$DEST"
[ "${CNT:-0}" -ge 1 ] || { log "!! 目录里没有 .tsfile"; exit 2; }

log "=== 2) 分发到三台 DN（同路径）==="
for h in "${DN[@]}"; do
  sshx "$h" "mkdir -p $DEST"
  rsync -a -e "ssh $SSH_OPTS" "$DEST"/ root@"$h":"$DEST"/ 2>/dev/null || \
    for f in "$DEST"/*; do scp $SSH_OPTS "$f" root@"$h":"$DEST/" 2>/dev/null || true; done
  n=$(sshx "$h" "ls -1 $DEST/*.tsfile 2>/dev/null | wc -l" | tr -dc '0-9')
  log "  .$h 文件数=${n:-0}"
done

log "=== 3) 每个 DN 各自 load（树方言，本地文件）==="
for h in "${DN[@]}"; do
  out=$(printf "set sql_dialect=tree;\nload '%s';\n" "$DEST" | "$CLI" -h "$h" -u root -pw "$ROOT_PW" 2>&1)
  msg=$(printf '%s\n' "$out" | grep -aE '^(Msg|Error):' | tail -1)
  log "  .$h load → ${msg:0:160}"
done

log "=== 4) flush + 等三节点行数对齐 ==="
printf 'set sql_dialect=tree;\nflush;\n' | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" >/dev/null 2>&1
for i in $(seq 1 40); do
  a=$(printf 'set sql_dialect=tree;\nselect count(*) from %s.**;\n' "$TREE_DB" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 | table_rows | wc -l)
  b=$(printf 'set sql_dialect=tree;\nshow devices %s.**;\n' "$TREE_DB" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 | table_rows | wc -l)
  printf 'set sql_dialect=tree;\nselect count(*) from %s.**;\n' "$TREE_DB" >/dev/null
  d1=$(printf 'set sql_dialect=tree;\nselect count(*) from %s.**;\n' "$TREE_DB" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 | grep -ac '^|')
  d2=$(printf 'set sql_dialect=tree;\nselect count(*) from %s.**;\n' "$TREE_DB" | "$CLI" -h "${DN[1]}" -u root -pw "$ROOT_PW" 2>&1 | grep -ac '^|')
  d3=$(printf 'set sql_dialect=tree;\nselect count(*) from %s.**;\n' "$TREE_DB" | "$CLI" -h "${DN[2]}" -u root -pw "$ROOT_PW" 2>&1 | grep -ac '^|')
  devs=$b
  log "  轮 $i：devices=${devs:-0} 三节点结果行=$d1/$d2/$d3"
  [ "$d1" = "$d2" ] && [ "$d2" = "$d3" ] && [ "${devs:-0}" -gt 0 ] && { log "  ✔ 三节点一致"; break; }
  sleep 15
done

log "=== 5) 数据面概览（供用例使用）==="
printf 'set sql_dialect=tree;\nshow devices %s.**;\n' "$TREE_DB" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 | table_rows | head -5 | sed 's/^/    /'
printf 'set sql_dialect=tree;\nshow timeseries %s.** limit 5;\n' "$TREE_DB" | "$CLI" -h "${DN[0]}" -u root -pw "$ROOT_PW" 2>&1 | table_rows | head -5 | sed 's/^/    /'
log "=== 完成 ==="
