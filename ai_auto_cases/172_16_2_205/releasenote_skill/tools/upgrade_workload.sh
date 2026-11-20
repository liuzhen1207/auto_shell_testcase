#!/bin/bash
# 升级过程中的并发读写负载
#   usage: upgrade_workload.sh start <dir> | stop <dir> | report <dir>
#   依赖调用方已加载 lib_rn.sh（T/Q 可用）
set -u
BASE="${BASE:-$(cd "$(dirname "$0")/.." && pwd)}"
NEW="${WL_NEW:-$NEW}"
for _p in "$BASE/conf/env.conf"; do [ -f "$_p" ] && . "$_p" && break; done
for _p in "$BASE/lib/lib_rn.sh"; do [ -f "$_p" ] && . "$_p" && break; done

ACT="${1:-}"; WDIR="${2:-/tmp/upg_wl}"

case "$ACT" in
  start)
    mkdir -p "$WDIR"; rm -f "$WDIR/stop" "$WDIR/pid" "$WDIR"/*.log
    (
      n=0
      while [ ! -f "$WDIR/stop" ]; do
        n=$((n+1))
        ts=$(( $(date +%s) * 1000 + n ))
        out=$(T "insert into root.upg_wl.d1(time,s1) values($ts, 1.5)" 2>&1)
        if echo "$out" | grep -qi "success"; then echo "$ts" >> "$WDIR/tree_ok"; else echo "$ts|$out" >> "$WDIR/tree_err"; fi
        out=$(Q "insert into upg_wl.t1(time, dev, val, obj) values($ts, 'd1', 1.5, to_object(true, 0, X'0102'))" 2>&1)
        if echo "$out" | grep -qi "success"; then echo "$ts" >> "$WDIR/table_ok"; else echo "$ts|$out" >> "$WDIR/table_err"; fi
        # 读操作
        out=$(T "select count(s1) from root.upg_wl.d1" 2>&1)
        echo "$out" | grep -q "|" || echo "$out" >> "$WDIR/read_err"
        out=$(Q "select count(*) from upg_wl.t1" 2>&1)
        echo "$out" | grep -q "|" || echo "$out" >> "$WDIR/read_err"
        sleep 0.3
      done
    ) > "$WDIR/worker.log" 2>&1 &
    echo $! > "$WDIR/pid"
    echo "workload started pid=$(cat "$WDIR/pid") dir=$WDIR"
    ;;
  stop)
    touch "$WDIR/stop"
    [ -f "$WDIR/pid" ] && kill "$(cat "$WDIR/pid")" 2>/dev/null
    sleep 2
    pkill -f "upgrade_workload.sh" 2>/dev/null
    echo "workload stopped"
    ;;
  report)
    for f in tree_ok table_ok tree_err table_err read_err; do
      c=$(wc -l < "$WDIR/$f" 2>/dev/null || echo 0)
      echo "$f=$c"
    done
    echo "--- 错误样例（前 3 条）---"
    cat "$WDIR"/tree_err "$WDIR"/table_err "$WDIR"/read_err 2>/dev/null | head -3 | cut -c1-160
    ;;
  *)
    echo "usage: $0 start|stop|report <dir>"; exit 2 ;;
esac
