#!/bin/bash
# ============================================================================
# 【纯桩 fake CLI】—— 模拟 sbin/start-cli.sh（只认 CR-14 用到的语句）
#   状态：$STUB_STATE/{rows.tsv,cache.tsv,pending.tsv,batches/,runtime.properties}
#   要点：
#     · 数据面：rows.tsv = 当前**可见**的 (dev,time,value)
#     · LastCache：cache.tsv 模拟缓存；`select last` 命中缓存则返回缓存值，否则填缓存后返回真值
#     · restart-only：`set configuration` 只改**配置层**（各节点 conf 文件）+ 返回 restart 提示；
#       运行期值（runtime.properties）只有 `cluster_write_conf`（= 重启）才更新，除非 STUB_MODE=hotapply
#     · load：把暂存 TsFile 对应的批次行重新写入可见数据，并按**运行期生效策略**维护 LastCache
#   **不连接任何集群、不执行任何真实 SQL。**
# ============================================================================
set -uo pipefail
STUB_ROOT="${STUB_ROOT:?STUB_ROOT 未设置}"
STUB_STATE="$STUB_ROOT/state"
STUB_NODES="$STUB_ROOT/nodes"
STUB_MODE="${STUB_MODE:-ok}"
STUB_STALE="${STUB_STALE:-0}"
NODE=""; USER_="root"; SQL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -h) NODE=$2; shift 2 ;;
    -u) USER_=$2; shift 2 ;;
    -pw) shift 2 ;;
    -sql_dialect) shift 2 ;;
    -timeout) shift 2 ;;
    -e) SQL=$2; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$NODE" ] || NODE="192.168.99.77"

ok_msg(){ printf 'Msg: The statement is executed successfully.\n'; }
row2(){ printf '|%s|%s|\n' "$1" "$2"; }
truth(){ awk -F'\t' -v d="$1" 'BEGIN{m=""} $1==d{ if(m=="" || ($2+0)>=(m+0)) {m=$2; v=$3} } END{if(m!="") print v}' "$STUB_STATE/rows.tsv"; }
cache_get(){ awk -F'\t' -v d="$1" '$1==d{print $2; exit}' "$STUB_STATE/cache.tsv"; }
cache_set(){ local d=$1 v=$2
  awk -F'\t' -v d="$d" '$1!=d' "$STUB_STATE/cache.tsv" > "$STUB_STATE/cache.tmp" 2>/dev/null || : > "$STUB_STATE/cache.tmp"
  mv "$STUB_STATE/cache.tmp" "$STUB_STATE/cache.tsv"
  printf '%s\t%s\n' "$d" "$v" >> "$STUB_STATE/cache.tsv"; }
cache_del(){ awk -F'\t' -v d="$1" '$1!=d' "$STUB_STATE/cache.tsv" > "$STUB_STATE/cache.tmp" 2>/dev/null || : > "$STUB_STATE/cache.tmp"; mv "$STUB_STATE/cache.tmp" "$STUB_STATE/cache.tsv"; }
cache_clear(){ : > "$STUB_STATE/cache.tsv"; }
runtime_get(){ awk -F= -v k="$1" '$1==k{print $2; exit}' "$STUB_STATE/runtime.properties"; }

# ---- 语句实现 --------------------------------------------------------------
do_insert(){ local sql=$1 dev vals out
  dev=$(printf '%s' "$sql" | sed -E 's/^insert into[[:space:]]+([^(]+)\(.*/\1/' | tr -d ' ')
  vals=$(printf '%s' "$sql" | sed -E 's/^[^(]*\([^)]*\)[[:space:]]*values[[:space:]]*//')
  out=$(printf '%s' "$vals" | sed -E 's/\),[[:space:]]*\(/\n/g' | sed -E 's/^\(//; s/\);?[[:space:]]*$//' \
    | awk -F, -v d="$dev" 'NF>=2{t=$1; v=$2; gsub(/[^0-9-]/,"",t); gsub(/[^0-9-]/,"",v); if(t!="") printf "%s\t%s\t%s\n", d, t, v}')
  printf '%s\n' "$out" | sed '/^$/d' >> "$STUB_STATE/rows.tsv"
  printf '%s\n' "$out" | sed '/^$/d' >> "$STUB_STATE/pending.tsv"
  ok_msg; }
do_flush(){ local cnt name n
  if [ -s "$STUB_STATE/pending.tsv" ]; then
    cnt=$(( $(cat "$STUB_STATE/flush_counter") + 1 )); echo "$cnt" > "$STUB_STATE/flush_counter"
    name="stub-${cnt}-1-0.tsfile"
    cp "$STUB_STATE/pending.tsv" "$STUB_STATE/batches/$name.tsv"
    : > "$STUB_STATE/pending.tsv"
    for n in $(ls "$STUB_NODES"); do
      mkdir -p "$STUB_NODES/$n/data/datanode/data/sequence/root.cr14/1/0"
      printf 'stub tsfile %s\n' "$name" > "$STUB_NODES/$n/data/datanode/data/sequence/root.cr14/1/0/$name"
    done
  fi
  ok_msg; }
do_last(){ local dev=$1 v c
  c=$(cache_get "$dev")
  if [ -n "$c" ]; then v="$c"; else v=$(truth "$dev"); [ -n "$v" ] && cache_set "$dev" "$v"; fi
  row2 "Time" "_col0"; row2 "2026-01-01T00:00:00.000+08:00" "${v:-NULL}"; }
do_select(){ local sql=$1 dev op num
  dev=$(printf '%s' "$sql" | sed -E 's/^select s1 from ([^ ]+).*$/\1/')
  op=""; num=""
  case "$sql" in
    *"where time >="*) op=">="; num=$(printf '%s' "$sql" | sed -E 's/.*where time >= ([0-9-]+).*/\1/') ;;
    *"where time <"*)  op="<";  num=$(printf '%s' "$sql" | sed -E 's/.*where time < ([0-9-]+).*/\1/') ;;
  esac
  row2 "Time" "_col0"
  awk -F'\t' -v d="$dev" -v op="$op" -v n="$num" '
    $1==d { t=$2+0
      if (op==">=" && t < n) next
      if (op=="<"  && t >= n) next
      print t"\t"$3 }' "$STUB_STATE/rows.tsv" | sort -n | awk -F'\t' '{printf "|2026-01-01T00:00:00.000+08:00|%s|\n", $2}' ; }
do_count(){ local dev=$1 c
  c=$(awk -F'\t' -v d="$dev" '$1==d{c++} END{print c+0}' "$STUB_STATE/rows.tsv")
  row2 "Time" "count(s1)"; row2 "0" "$c"; }
do_delete(){ local sql=$1 dev num
  dev=$(printf '%s' "$sql" | sed -E 's/^delete from (.*)\.\*\*.*$/\1/')
  num=$(printf '%s' "$sql" | sed -E 's/.*where time >= ([0-9-]+).*/\1/')
  awk -F'\t' -v d="$dev" -v n="$num" '!(($1==d) && (($2+0) >= n))' "$STUB_STATE/rows.tsv" > "$STUB_STATE/rows.tmp"
  mv "$STUB_STATE/rows.tmp" "$STUB_STATE/rows.tsv"
  ok_msg; }
do_load(){ local dir=$1 f base batch strat dev t v
  f=$(ls "$dir"/*.tsfile 2>/dev/null | head -1)
  if [ -z "${f:-}" ]; then
    printf 'Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 1100: Loading file failed. Detail: no tsfile under %s\n' "$dir"; return 0
  fi
  base=$(basename "$f"); batch="$STUB_STATE/batches/$base.tsv"
  if [ ! -f "$batch" ]; then
    printf 'Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 1100: Loading file %s failed. Detail: unknown batch\n' "$f"; return 0
  fi
  cat "$batch" >> "$STUB_STATE/rows.tsv"
  cat "$batch" >> "$STUB_STATE/pending.tsv"
  strat=$(runtime_get last_cache_operation_on_load)
  case "${strat:-UPDATE_NO_BLOB}" in
    UPDATE|UPDATE_NO_BLOB)
      if [ "$STUB_STALE" = 1 ]; then
        :                                       # 坏行为：缓存不更新（模拟陈旧）
      else
        while IFS=$'\t' read -r dev t v; do
          [ -n "${dev:-}" ] || continue
          [ -n "$(cache_get "$dev")" ] && cache_set "$dev" "$v"   # updateLastCacheIfExists 语义
        done < "$batch"
      fi ;;
    CLEAN_DEVICE) while IFS=$'\t' read -r dev t v; do [ -n "${dev:-}" ] && cache_del "$dev"; done < "$batch" ;;
    CLEAN_ALL) cache_clear ;;
  esac
  printf '%s\n' "$dir" >> "$STUB_STATE/loads.txt"
  ok_msg; }
do_set_conf(){ local k=$1 v=$2 n
  if [ "$USER_" != "root" ]; then
    printf 'Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 803: SET CONFIGURATION is not allowed for user %s: no permission\n' "$USER_"; return 0
  fi
  for n in $(ls "$STUB_NODES"); do
    sed -i -E "/^${k}=/d" "$STUB_NODES/$n/conf/iotdb-system.properties"
    printf '%s=%s\n' "$k" "$v" >> "$STUB_NODES/$n/conf/iotdb-system.properties"
  done
  if [ "$STUB_MODE" = hotapply ]; then
    if grep -q "^${k}=" "$STUB_STATE/runtime.properties"; then
      sed -i -E "s#^${k}=.*#${k}=${v}#" "$STUB_STATE/runtime.properties"
    else
      printf '%s=%s\n' "$k" "$v" >> "$STUB_STATE/runtime.properties"
    fi
  fi
  printf 'Msg: Configuration has been set successfully, but restart is required for the following parameters to take effect: %s.\n' "$k"; }
do_create_user(){ if [ "$USER_" != "root" ]; then printf 'Msg: org.apache.iotdb.jdbc.IoTDBSQLException: 803: no permission\n'; return 0; fi; ok_msg; }
dump_conf(){ local line k v
  printf '|%s|%s|%s|\n' "name" "value" "default_value"
  while IFS= read -r line; do
    k="${line%%=*}"; v="${line#*=}"
    printf '|%s|%s|%s|\n' "$k" "$v" "$v"
  done < "$STUB_STATE/runtime.properties"; }

run_stmt(){ local sql="$1"
  sql=$(printf '%s' "$sql" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
  [ -n "$sql" ] || return 0
  case "$sql" in
    "create database "*) ok_msg ;;
    "create timeseries "*) ok_msg ;;
    "insert into "*) do_insert "$sql" ;;
    "flush;"*) do_flush ;;
    "select last "*) do_last "$(printf '%s' "$sql" | sed -E 's/^select last s1 from ([^;]+);?$/\1/' | tr -d ' ')" ;;
    "select count("*) do_count "$(printf '%s' "$sql" | sed -E 's/^select count\(s1\) from (.*)\.\*\*.*$/\1/' | tr -d ' ')" ;;
    "select s1 from "*) do_select "$sql" ;;
    "delete from "*) do_delete "$sql" ;;
    "clear cache;"*) cache_clear; ok_msg ;;
    "load "*) do_load "$(printf '%s' "$sql" | sed -E "s/^load '([^']+)'.*$/\1/")" ;;
    "create user "*) do_create_user ;;
    "set configuration "*) do_set_conf \
        "$(printf '%s' "$sql" | sed -E "s/^set configuration '([^']+)'='([^']*)';?$/\1/")" \
        "$(printf '%s' "$sql" | sed -E "s/^set configuration '[^']+'='([^']*)';?$/\1/")" ;;
    "show pipes;"*) printf 'Empty set.\n' ;;
    "show timeseries "*) printf '|Timeseries|Alias|Database|DataType|\n|%s|NULL|root.cr14|INT64|\n' "$(printf '%s' "$sql" | sed -E 's/^show timeseries ([^;]+);?$/\1/')" ;;
    "show cluster;"*) printf '|NodeID|NodeType|Status|InternalAddress|\n|1|ConfigNode|Running|192.168.99.77|\n|2|DataNode|Running|192.168.99.77|\n' ;;
    "show configuration;"*) dump_conf ;;
    *) ok_msg ;;
  esac; }

if [ -n "$SQL" ]; then
  run_stmt "$SQL"
else
  while IFS= read -r line; do run_stmt "$line"; done
fi
exit 0
