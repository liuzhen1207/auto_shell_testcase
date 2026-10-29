#!/bin/bash
# 表模型探针：① SELECT 结果列构成；② 表模型 Compaction 日志里的库名前缀格式；
#              ③ cmp_inner_finish / cmp_all_sum / cmp_lay 对**表模型库名**是否可用
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../lib/common.sh"
. "$HERE/../lib/cmp.sh"
cmp_load_env
cmp_parse_args "$@"
cmp_case_init "probe_table_fmt_${DATA_CONSENSUS}"

DB=dtprobe
BASE=$(( ($(date +%s) - 3600) * 1000))
EXTRA_CONF="$CMP_EXTRA_WRITE" cmp_cluster_prepare

sqt "create database $DB;" >/dev/null 2>&1
sqt "create table $DB.t1 (time TIMESTAMP TIME, dev STRING TAG, v INT32 FIELD, s STRING FIELD);" >/dev/null
sqt "insert into $DB.t1 (time, dev, v, s) values ($(( BASE + 100 )),'d1',11,'a'),($(( BASE + 110 )),'d1',12,'b');" >/dev/null
sqt "flush;" >/dev/null; sleep 4
sqt "insert into $DB.t1 (time, dev, v, s) values ($(( BASE + 200 )),'d1',21,'c'),($(( BASE + 210 )),'d1',22,'d');" >/dev/null
sqt "flush;" >/dev/null
cmp_wait_lay "$DB" "2/0/0/0" 90 >/dev/null || true

echo "### ① 原始结果集（select v from $DB.t1 order by time）"
sqt "select v from $DB.t1 order by time;" 2>&1 | cat -A | sed -n '1,12p' | sed 's/\$$//' | cut -c1-200
echo "### ①' 原始结果集（select time, v ...）"
sqt "select time, v from $DB.t1 order by time;" 2>&1 | sed -n '1,10p' | cut -c1-200
echo "### ①'' 原始结果集（select v, s ...）"
sqt "select v, s from $DB.t1 order by time;" 2>&1 | sed -n '1,10p' | cut -c1-200

echo "### ② 观测接口"
echo "  cmp_lay      = $(cmp_lay "$DB")"
echo "  cmp_all_sum  = $(cmp_all_sum "$DB")"
echo "  cmp_unseq_sum= $(cmp_unseq_sum "$DB")"
echo "  cmp_inner_finish(前) = $(cmp_inner_finish "$DB")"
cmp_compaction_on true false false
sleep 20
echo "  cmp_inner_finish(后) = $(cmp_inner_finish "$DB")  TsFile=$(cmp_all_sum "$DB")"
echo "### ②' compaction 日志里含 $DB 的行（各节点 tail）"
for h in "${DN[@]}"; do
  echo "--- $h ---"
  sshx "$h" "grep -ha '$DB' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | tail -4" 2>/dev/null | cut -c1-230 | sed 's/^/  /'
done
echo "### ②'' 日志里 task finishes 行的原始前缀（不过滤库名）"
for h in "${DN[@]}"; do
  echo "--- $h ---"
  sshx "$h" "grep -ha 'finishes successfully' $DB_DIR/logs/log_datanode_compaction.log 2>/dev/null | tail -4" 2>/dev/null | cut -c1-230 | sed 's/^/  /'
done
