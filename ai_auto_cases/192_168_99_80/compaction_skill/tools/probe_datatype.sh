#!/bin/bash
# 探测：修改数据类型（树 ALTER TIMESERIES / 表 ALTER TABLE ALTER COLUMN / 视图 ALTER VIEW）
#   —— 语法、兼容性、错误码、改后数据可读性、以及"改类型 × 合并"的相互作用；另探环境（/data 挂载点）
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_datatype"
export EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000,inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0"
cmp_cluster_prepare
DB=root.dtprobe
BASE=$(( ($(date +%s) - 3600) * 1000 ))

log "=== 0) 环境：/data 是什么挂载点（readonly 场景要用）==="
for h in "${DN[@]}"; do
  echo "  --- $h ---"
  sshx "$h" "findmnt -T $DB_DIR 2>/dev/null | head -3; df -h $DB_DIR | tail -2; mount | grep -c ' /data '" 2>/dev/null | sed 's/^/    /'
done

log "=== 1) 树模型：建多类型序列（INT32/INT64/FLOAT/DOUBLE/BOOLEAN/TEXT/STRING/TIMESTAMP）==="
sq "create database $DB;" >/dev/null
mk(){ sq "create timeseries $1 with datatype=$2, encoding=PLAIN, compression=UNCOMPRESSED;" 2>&1 | tail -1 | cut -c1-80; }
for t in INT32 INT64 FLOAT DOUBLE BOOLEAN TEXT STRING TIMESTAMP; do
  echo "  建 INT32 序列 + $t 序列: $(mk "$DB.o32_$t.s1" INT32) / $(mk "$DB.t_$t.s1" "$t")"
done
log "=== 2) 树模型：写数据（改类型前 2 批）==="
w(){ local path=$1 v=$2
  sq "insert into $path(time,s1) values ($(( BASE + 100 )),$v),($(( BASE + 200 )),$v);" 2>&1 | tail -1 | cut -c1-70; }
echo "  INT32: $(w "$DB.o32_INT64.d1" 42)"
for t in INT64 FLOAT DOUBLE BOOLEAN TEXT STRING TIMESTAMP; do
  case "$t" in
    BOOLEAN) v=true ;;
    TEXT|STRING) v="'abc'" ;;
    *) v=7 ;;
  esac
  echo "  $t: $(w "$DB.t_$t.d1" "$v")"
done
sq "flush;" >/dev/null; sleep 6

log "=== 3) 树模型：正向兼容转换（改前/改后查询 + 响应）==="
try(){ local path=$1 to=$2
  local r; r=$(sq "alter timeseries $path set data type $to;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' ' | cut -c1-150)
  local ty; ty=$(sqt "show timeseries" 2>/dev/null | grep "$path" | awk -F'|' '{gsub(/ /,"",$4); print $4}')
  local q; q=$(sq "select s1 from $path order by time;" 2>&1 | grep -E '^\|' | tail -2 | tr '\n' ' ' | cut -c1-90)
  echo "  [$path → $to] resp=[$r] 新类型=[$ty] 数据=[$q]"; }
for to in INT64 FLOAT DOUBLE TIMESTAMP STRING TEXT; do try "$DB.o32_$to.d1.s1" "$to"; done
try "$DB.t_INT64.d1.s1" DOUBLE
try "$DB.t_FLOAT.d1.s1" DOUBLE
try "$DB.t_DOUBLE.d1.s1" STRING
try "$DB.t_BOOLEAN.d1.s1" STRING
try "$DB.t_TEXT.d1.s1" STRING
try "$DB.t_STRING.d1.s1" TEXT
try "$DB.t_TIMESTAMP.d1.s1" INT64

log "=== 4) 树模型：负向（不兼容 + 不存在 + 重复改）==="
neg(){ local path=$1 to=$2; local 
  r=$(sq "alter timeseries $path set data type $to;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' ' | cut -c1-160)
  echo "  [$path → $to] resp=[$r]"; }
neg "$DB.t_DOUBLE.d1.s1" FLOAT
neg "$DB.t_TEXT.d1.s1" INT32
neg "$DB.t_BOOLEAN.d1.s1" INT32
neg "$DB.no_such_dev.d1.s1" DOUBLE
neg "$DB.o32_DOUBLE.d1.s1" STRING

log "=== 5) 改类型 × 合并：改类型前有文件、改后写新数据 → 触发合并 ==="
DQ="$DB.o32_INT64.d1.s1"
log "  改后写新数据（第 2 批，新类型 INT64）"
sq "insert into $DB.o32_INT64.d1(time,s1) values ($(( BASE + 100000 )),99),($(( BASE + 100010 )),98);" 2>&1 | tail -1 | cut -c1-70
sq "flush;" >/dev/null; sleep 8
echo "  改类型后各副本布局=$(cmp_lay "$DB")"
FIN0=$(cmp_inner_finish "$DB"); FP0=$(cmp_fp_tree "$DB")
log "  开合并（等待 60s）"
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 60
echo "  合并后：布局=$(cmp_lay "$DB") finishes=$FIN0→$(cmp_inner_finish "$DB") 指纹=$FP0 → $(cmp_fp_tree "$DB")"
echo "  数据（改类型后 + 新写）："
sq "select s1 from $DB.o32_INT64.d1 order by time;" 2>&1 | grep -E '^\|' | tail -6 | sed 's/^/    /'
echo "  压缩日志（本库）："
for h in "${DN[@]}"; do sshx "$h" "grep -hE '($DB|dtprobe)-[0-9]+ \[Compaction\]' $(cmp_log_files) 2>/dev/null | tail -3 | cut -c1-165" 2>/dev/null; done
echo "  日志异常（Compaction/DataType 相关）："
for h in "${DN[@]}"; do sshx "$h" "grep -haE 'DataTypeInconsistent|CompactionTableSchemaNotMatch|type mismatch|Illegal.*[Tt]ype|ALREADY_EXISTS.*type' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -3 | cut -c1-180" 2>/dev/null; done

log "=== 6) 表模型：ALTER TABLE ... ALTER COLUMN ... SET DATA TYPE ==="
DBT=dtprobe
sqt "create database $DBT;" >/dev/null 2>&1
echo "  建表: $(sqt "create table $DBT.t1 (time TIMESTAMP TIME, dev STRING TAG, v INT32 FIELD, s STRING FIELD);" 2>&1 | tail -1 | cut -c1-80)"
echo "  写入: $(sqt "insert into $DBT.t1 (time, dev, v, s) values ($(( BASE + 100 )),'d1',11,'x'),($(( BASE + 200 )),'d1',22,'y');" 2>&1 | tail -1 | cut -c1-70)"
sqt "flush;" >/dev/null; sleep 5
tv(){ local r; r=$(sqt "$1" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' ' | cut -c1-150); echo "  [$1] → [$r]"; }
tv "alter table $DBT.t1 alter column v set data type DOUBLE;"
tv "alter table $DBT.t1 alter column dev set data type STRING;"
tv "alter table $DBT.t1 alter column time set data type INT64;"
tv "alter table $DBT.t1 alter column s set data type INT32;"
tv "alter table $DBT.t1 alter column v set data type BOOLEAN;"
echo "  改后查询: $(sqt "select v from $DBT.t1;" 2>&1 | grep -E '^\|' | tail -3 | tr '\n' ' ' | cut -c1-120)"
echo "  表结构: $(sqt "desc $DBT.t1;" 2>&1 | grep -E '^\|' | grep -E 'v|dev' | tr '\n' ' ' | cut -c1-160)"

log "=== 7) 视图：ALTER VIEW ... ALTER COLUMN ... SET DATA TYPE ==="
sq "create database ${DB}v;" >/dev/null
sq "create timeseries ${DB}v.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into ${DB}v.d1(time,s1) values ($(( BASE + 100 )),5);" >/dev/null
sq "flush;" >/dev/null; sleep 4
echo "  建视图: $(sqt "create view ${DB}v.v1 (time, s1 FIELD) as select s1 from ${DB}v.d1;" 2>&1 | tail -1 | cut -c1-100)"
echo "  改视图列类型: $(sqt "alter view ${DB}v.v1 alter column s1 set data type DOUBLE;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' ' | cut -c1-140)"
echo "  视图查询: $(sqt "select s1 from ${DB}v.v1;" 2>&1 | grep -E '^\|' | tail -3 | tr '\n' ' ' | cut -c1-100)"
echo "### 探测结束 $(date '+%F %T')"
