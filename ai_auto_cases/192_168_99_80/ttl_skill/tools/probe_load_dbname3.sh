#!/bin/bash
# ============================================================================
# probe_load_dbname3.sh —— 表模型 LOAD 的库名到底从哪来？
#   (a) load '<file>'                                —— 不带属性（CR-03/CO-33 的写法）
#   (b) load '<file>' with ('database-name'='dst')   —— 显式给库名
#   判读：(a) 0 行 & (b) >0 行 ⇒ 用例漏了必填属性（用法问题，TDB-873 可降级）
#         两者都 0 行         ⇒ 产品缺口（TDB-873 成立）
#         两者都导入           ⇒ 与该属性无关
#   前置：自己 clean 起一套集群，跑完停集群
# ============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
ttl_load_env
ttl_parse_args "$@"
ttl_case_init "probe_load_dbname_${DATA_CONSENSUS}"

SRC=probe_ld_src
DST=probe_ld_dst
DIR=/tmp/probe_load
TBL=t1
flat(){ printf '%s' "$1" | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-200; }
use_sql(){ sql_lines_table "use $1;" "$2"; }

log "=== 0) 集群准备（${DATA_CONSENSUS}）==="
ttl_cluster_prepare || { log "集群准备失败"; exit 2; }

log "=== 1) 造源表：3 行 + flush ==="
out=$(sql_lines_table "create database $SRC;")
log "  create db: $(flat "$out")"
out=$(use_sql "$SRC" "create table $TBL (time TIMESTAMP TIME, dev STRING TAG, s1 INT32 FIELD);")
log "  create table: $(flat "$out")"
out=$(use_sql "$SRC" "insert into $TBL (time,dev,s1) values (1,'d1',11),(2,'d1',22),(3,'d1',33);")
log "  insert: $(flat "$out")"
sql_lines_table "use $SRC;" "flush;" >/dev/null 2>&1
sleep 3
CSRC=$(scalar "$(use_sql "$SRC" "select count(s1) from $TBL;")")
log "  源表行数=$CSRC（期望 3）"

log "=== 2) 在 DN 上定位该库的 TsFile 并拷到数据目录之外 ==="
H=${DN[0]}
found=""
for i in $(seq 1 66); do
  found=$(sshx "$H" "find $DB_DIR/data -path '*${SRC}*' -name '*.tsfile' -size +0 2>/dev/null | head -1" | tr -d '\r')
  [ -n "$found" ] && break
  case "$i" in 10|25|40) sql_lines_table "use $SRC;" "flush;" >/dev/null 2>&1 ;; esac
  sleep 3
done
log "  源文件=$found"
[ -z "$found" ] && { log "  !! 仍未找到 TsFile ⇒ 终止"; ttl_case_finish "" tree ""; exit 2; }
sshx "$H" "mkdir -p $DIR && cp -f '$found' $DIR/x.tsfile && ls -l $DIR/x.tsfile" >/dev/null 2>&1
SZ=$(sshx "$H" "stat -c %s $DIR/x.tsfile 2>/dev/null" | tr -dc '0-9')
log "  拷贝后大小=${SZ:-?}B"

log "=== 3) 目标库 + 同名空表（先写 1 行作为对照组）==="
sql_lines_table "create database $DST;" >/dev/null 2>&1
use_sql "$DST" "create table $TBL (time TIMESTAMP TIME, dev STRING TAG, s1 INT32 FIELD);" >/dev/null 2>&1
use_sql "$DST" "insert into $TBL (time,dev,s1) values (100,'dz',0);" >/dev/null 2>&1
sql_lines_table "use $DST;" "flush;" >/dev/null 2>&1
cnt(){ scalar "$(use_sql "$DST" "select count(s1) from $TBL;")"; }
c0=$(cnt); log "  目标表现有行数=$c0"

log "=== 4) (a) load 不带任何属性 ==="
a=$(use_sql "$DST" "load '$DIR/x.tsfile';")
sleep 3
ca=$(cnt)
log "  响应: $(flat "$a")"
log "  行数: $c0 -> $ca"

log "=== 5) (b) load 带 database-name ==="
b=$(use_sql "$DST" "load '$DIR/x.tsfile' with ('database-name'='$DST');")
sleep 3
cb=$(cnt)
log "  响应: $(flat "$b")"
log "  行数: $ca -> $cb"

log "=== 6) 判读 ==="
log "  (a) 不带属性: $c0 -> $ca ；(b) 带 database-name: $ca -> $cb"
if [ "${ca:-0}" = "${c0:-0}" ] && [ "${cb:-0}" -gt "${ca:-0}" ]; then
  log "  ⇒ **用法问题**：表模型 load 必须显式给 database-name（CR-03/CO-33 漏了属性）"
elif [ "${cb:-0}" = "${ca:-0}" ]; then
  log "  ⇒ **产品缺口**：(b) 也没导入 ⇒ TDB-873 方向成立，继续查 load 路径"
else
  log "  ⇒ 两者都有变化，需人工核对"
fi
lp=$(sshx "$H" "grep -ac 'is not a legal path' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9')
log "  DN 日志 'is not a legal path' 次数=${lp:-0}"

log "=== 7) 打包三节点日志 ==="
TAR="$ART/probe_load_dbname_logs.tar.gz"
for h in "${HOSTS[@]}"; do
  sshx "$h" "cd $DB_DIR/logs && tar -czf /tmp/pl.${h##*.}.tgz log_*.log 2>/dev/null" >/dev/null 2>&1
  scp -q root@"$h":/tmp/pl."${h##*.}".tgz "$ART/" 2>/dev/null || true
done
tar -czf "$TAR" -C "$ART" . 2>/dev/null
log "  日志包：$TAR（$(stat -c %s "$TAR" 2>/dev/null)B）"
ttl_case_finish "" tree "$TAR"
