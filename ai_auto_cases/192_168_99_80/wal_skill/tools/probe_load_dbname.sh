#!/bin/bash
# ============================================================================
# probe_load_dbname.sh —— 表模型 LOAD 的库名从哪来？
#   (a) load '<file>'                              —— 不带属性（用例 CR-03/CO-33 的写法）
#   (b) load '<file>' with ('database-name'='dst') —— 显式给库名
#   判读：(a)=0 行 & (b)=N 行 ⇒ 用例漏了必填属性；两者都 0 ⇒ 产品缺口
# 前置：集群可起（本脚本自己 clean 起一套）；跑完停集群。
# ============================================================================
set -uo pipefail
R=/data/iotdb/autotest
SK=$R/wal_skill
. "$SK/lib/common.sh"
. "$SK/lib/cmp.sh"
. "$SK/lib/wal_ext.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "probe_load_dbname_${DATA_CONSENSUS}"

SRC=probe_ld_src
DST=probe_ld_dst
DIR=/tmp/probe_load
TBL=t1

log "=== 0) 集群准备 ==="
cmp_cluster_prepare || { log "集群准备失败"; exit 2; }

log "=== 1) 造一个表模型 TsFile（写 3 行 + flush）==="
sqt "create database $SRC;" >/dev/null 2>&1
sqt "create table $SRC.$TBL (time TIMESTAMP TIME, dev STRING TAG, s1 INT32 FIELD);" >/dev/null 2>&1
sqt "insert into $SRC.$TBL (time,dev,s1) values (1,'d1',11),(2,'d1',22),(3,'d1',33);" >/dev/null 2>&1
sqt "flush;" >/dev/null 2>&1
sleep 3

log "=== 2) 在该表对应的 DN 上把 TsFile 拷到数据目录之外 ==="
H=${DN[0]}
found=""
for p in $(sshx "$H" "find $DB_DIR/data -path '*/$SRC/*' -name '*.tsfile' 2>/dev/null | head -3"); do
  found=$p; break
done
if [ -z "$found" ]; then log "!! 没找到 $SRC 的 TsFile ⇒ 终止"; exit 2; fi
sshx "$H" "mkdir -p $DIR && cp -f '$found' $DIR/x.tsfile" >/dev/null 2>&1
SZ=$(sshx "$H" "stat -c %s $DIR/x.tsfile 2>/dev/null" | tr -dc '0-9')
log "  源文件=$found → $DIR/x.tsfile（${SZ:-?}B）"

log "=== 3) 建目标库 + 空表 ==="
sqt "create database $DST;" >/dev/null 2>&1
sqt "create table $DST.$TBL (time TIMESTAMP TIME, dev STRING TAG, s1 INT32 FIELD);" >/dev/null 2>&1
sqt "insert into $DST.$TBL (time,dev,s1) values (100,'dz',0);" >/dev/null 2>&1
sqt "flush;" >/dev/null 2>&1
cnt(){ scalar "$(sqt "select count(s1) from $DST.$TBL;")"; }
c0=$(cnt); log "  目标表初始行数=$c0"

log "=== 4) (a) load 不带属性 ==="
a=$(sqt "load '$DIR/x.tsfile';" 2>&1)
sleep 3
ca=$(cnt)
log "  响应=$(printf '%s' "$a" | tr '\n' ' ' | cut -c1-160)"
log "  行数=$c0 → $ca"

log "=== 5) (b) load 带 database-name ==="
b=$(sqt "load '$DIR/x.tsfile' with ('database-name'='$DST');" 2>&1)
sleep 3
cb=$(cnt)
log "  响应=$(printf '%s' "$b" | tr '\n' ' ' | cut -c1-160)"
log "  行数=$ca → $cb"

log "=== 6) 判读 ==="
log "  (a) 不带属性：$c0 → $ca； (b) 带 database-name：$ca → $cb"
if [ "${ca:-0}" = "${c0:-0}" ] && [ "${cb:-0}" -gt "${ca:-0}" ]; then
  log "  ⇒ **用法问题**：表模型 load 必须显式给 database-name（CR-03/CO-33 漏了）"
elif [ "${cb:-0}" = "${ca:-0}" ]; then
  log "  ⇒ **与该属性无关/产品缺口**：(b) 也没导入，需继续查（CR-03/TDB-873 方向成立）"
else
  log "  ⇒ 两者都有变化，需人工核对"
fi
log "  DN 日志中 legal path 行数：$(sshx "$H" "grep -ac 'is not a legal path' $DB_DIR/logs/log_datanode_all.log 2>/dev/null" | tr -dc '0-9')"
cmp_case_finish "" tree ""
