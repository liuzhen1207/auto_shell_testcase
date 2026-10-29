#!/bin/bash
# 探测 v2：用**正确路径**确认 修改数据类型 的语法/语义/错误码/与合并的相互作用
set -uo pipefail
S=/data/iotdb/autotest/compaction_skill
cd $S || exit 1
. $S/lib/common.sh; . $S/lib/cmp.sh
cmp_load_env; cmp_parse_args
cmp_case_init "probe_datatype2"
export EXTRA_CONF="enable_seq_space_compaction=false,enable_unseq_space_compaction=false,enable_cross_space_compaction=false,inner_compaction_candidate_file_num=2,compaction_schedule_interval_in_ms=1000,inner_seq_selector=size_tiered_multi_target,max_level_gap_in_inner_compaction=0,min_cross_compaction_unseq_file_level=0"
cmp_cluster_prepare
DB=root.dt2
DOB=dt2
BASE=$(( ($(date +%s) - 3600) * 1000 ))

# 树模型：序列路径 = root.dt2.<dev>.s1（设备 <dev>，测量 s1）——建/写/改都用**同一个路径**
tpath(){ echo "$DB.$1.s1"; }
# 从 `show timeseries` 表头定位 DataType 列，取该序列的类型
ttype(){ local p=$1 out idx
  out=$(sq "show timeseries $p;" 2>/dev/null)
  idx=$(printf '%s\n' "$out" | awk -F'|' '/Timeseries/{for(i=1;i<=NF;i++){gsub(/ /,"",$i); if($i=="DataType"){print i; exit}}}')
  [ -z "$idx" ] && { echo "?"; return; }
  printf '%s\n' "$out" | awk -F'|' -v i="$idx" -v p="$p" '{gsub(/^[ \t]+|[ \t]+$/,"",$2); if($2==p){v=$i; gsub(/[ \t]/,"",v); print v; exit}}'; }
# 数据渲染（前 2 行值）
tval(){ sq "select s1 from $1 order by time limit 3;" 2>&1 | grep -E '^\|' | tail -n +2 | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/,"",$3); printf "%s ", $3}'; echo; }
talt(){ local p=$1 to=$2 
  r=$(sq "alter timeseries $p set data type $to;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | tr '\n' ' ' | cut -c1-200)
  printf '  [%s → %-9s] %s\n' "${p##*.}" "$to" "$r"; }
twrite(){ sq "insert into $1(time,s1) values ($(( BASE + $2 )),$3);" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -1 | cut -c1-90; }

log "=== A) 树模型：正确路径下的正向转换 + 改后数据 ==="
mk(){ sq "create timeseries $(tpath "$1") with datatype=$2, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null; }
mk a32 INT32;      twrite "$DB.a32" 100 42;      twrite "$DB.a32" 110 43
mk a64 INT64;      twrite "$DB.a64" 100 42;      twrite "$DB.a64" 110 43
mk afl FLOAT;      twrite "$DB.afl" 100 1.5;     twrite "$DB.afl" 110 2.5
mk adb DOUBLE;     twrite "$DB.adb" 100 1.5;     twrite "$DB.adb" 110 2.5
mk abo BOOLEAN;    twrite "$DB.abo" 100 true;    twrite "$DB.abo" 110 false
mk atx TEXT;       twrite "$DB.atx" 100 "'abc'"; twrite "$DB.atx" 110 "'def'"
mk ast STRING;     twrite "$DB.ast" 100 "'abc'"; twrite "$DB.ast" 110 "'def'"
mk ats TIMESTAMP;  twrite "$DB.ats" 100 1000;    twrite "$DB.ats" 110 2000
sq "flush;" >/dev/null; sleep 6
for d in a32 a64 afl adb abo atx ast ats; do
  echo "  改前 $d: 类型=$(ttype "$(tpath $d)") 数据=$(tval "$(tpath $d)")"
done
talt "$(tpath a32)" INT64;    echo "    改后 a32: 类型=$(ttype "$(tpath a32)") 数据=$(tval "$(tpath a32)")"
talt "$(tpath a32)" DOUBLE;   echo "    再改 a32: 类型=$(ttype "$(tpath a32)") 数据=$(tval "$(tpath a32)")"
talt "$(tpath a32)" STRING;   echo "    三改 a32: 类型=$(ttype "$(tpath a32)") 数据=$(tval "$(tpath a32)")"
talt "$(tpath a64)" TIMESTAMP; echo "    改后 a64: 类型=$(ttype "$(tpath a64)") 数据=$(tval "$(tpath a64)")"
talt "$(tpath afl)" DOUBLE;    echo "    改后 afl: 类型=$(ttype "$(tpath afl)") 数据=$(tval "$(tpath afl)")"
talt "$(tpath adb)" STRING;    echo "    改后 adb: 类型=$(ttype "$(tpath adb)") 数据=$(tval "$(tpath adb)")"
talt "$(tpath abo)" STRING;    echo "    改后 abo: 类型=$(ttype "$(tpath abo)") 数据=$(tval "$(tpath abo)")"
talt "$(tpath atx)" STRING;    echo "    改后 atx: 类型=$(ttype "$(tpath atx)") 数据=$(tval "$(tpath atx)")"
talt "$(tpath ast)" TEXT;      echo "    改后 ast: 类型=$(ttype "$(tpath ast)") 数据=$(tval "$(tpath ast)")"
talt "$(tpath ats)" INT64;     echo "    改后 ats: 类型=$(ttype "$(tpath ats)") 数据=$(tval "$(tpath ats)")"

log "=== B) 树模型：负向（不兼容 / 不存在 / 改类型后继续写）==="
talt "$(tpath adb)" FLOAT
talt "$(tpath atx)" INT32
talt "$(tpath abo)" INT32
talt "$DB.no_such.d1.s1" DOUBLE
echo "  改类型后写新值（a32 现为 STRING）：$(twrite "$DB.a32" 200 "'xyz'") 数据=$(tval "$(tpath a32)")"
echo "  改类型后写数值（应报错或不兼容）：$(twrite "$DB.a32" 210 5) 数据=$(tval "$(tpath a32)")"

log "=== C) 改类型 × 合并（核心）：改前 2 批 + 改后 2 批 ⇒ 合并 ⇒ 数据/类型/异常 ==="
DBC="$DB.c1"
sq "create timeseries $DBC.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into $DBC(time,s1) values ($(( BASE + 100 )),11),($(( BASE + 110 )),12);" >/dev/null
sq "flush;" >/dev/null; sleep 5
echo "  改前：类型=$(ttype "$DBC.s1") 数据=$(tval "$DBC.s1") 布局=$(cmp_lay "$DB")"
talt "$DBC.s1" DOUBLE
sq "insert into $DBC(time,s1) values ($(( BASE + 200 )),1.25),($(( BASE + 210 )),2.5);" >/dev/null
sq "flush;" >/dev/null; sleep 6
echo "  改后写入：类型=$(ttype "$DBC.s1") 数据=$(tval "$DBC.s1") 布局=$(cmp_lay "$DB")"
FIN0=$(cmp_inner_finish "$DB"); FP0=$(cmp_fp_tree "$DB")
cmp_set_hot enable_seq_space_compaction true >/dev/null
sleep 45
echo "  合并后：布局=$(cmp_lay "$DB") finishes=$FIN0→$(cmp_inner_finish "$DB") 指纹=$FP0 → $(cmp_fp_tree "$DB")"
echo "  合并后数据=$(tval "$DBC.s1") 类型=$(ttype "$DBC.s1")"
echo "  本库压缩日志："
for h in "${DN[@]}"; do sshx "$h" "grep -hE '($DB|dt2)-[0-9]+ \[Compaction\]' $(cmp_log_files) 2>/dev/null | tail -3 | cut -c1-170" 2>/dev/null | sed 's/^/    /'; done
echo "  异常扫描（DataType/Schema/Type 相关）："
for h in "${DN[@]}"; do sshx "$h" "grep -haE 'DataTypeInconsistent|CompactionTableSchemaNotMatch|not compatible|is not compatible|Illegal.*[Tt]ype|data type' $DB_DIR/logs/log_datanode_all.log 2>/dev/null | tail -5 | cut -c1-200" 2>/dev/null | sed 's/^/    /'; done

log "=== D) 并发删除序列 × 改类型 ==="
DBD="$DB.d"
sq "create timeseries $DBD.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null
sq "insert into $DBD(time,s1) values ($(( BASE + 300 )),1);" >/dev/null
sq "flush;" >/dev/null; sleep 4
( sleep 0.2; sq "delete timeseries $DBD.**;" >/dev/null 2>&1 ) &
sq "alter timeseries $DBD.s1 set data type DOUBLE;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -2 | sed 's/^/    alter→ /'
wait
echo "    删除后查询：$(sq "select s1 from $DBD.s1;" 2>&1 | grep -vE '^\+|Total line|It costs' | tail -2 | tr '\n' ' ' | cut -c1-120)"

log "=== E) 表模型：改类型后继续写 + 合并 ==="
sqt "create database $DOB;" >/dev/null 2>&1
sqt "create table $DOB.t1 (time TIMESTAMP TIME, dev STRING TAG, v INT32 FIELD);" >/dev/null
sqt "insert into $DOB.t1 (time, dev, v) values ($(( BASE + 100 )),'d1',11);" >/dev/null
sqt "flush;" >/dev/null; sleep 4
echo "  改前: $(sqt "select v from $DOB.t1;" 2>&1 | grep -E '^\|' | tail -2 | tr '\n' ' ' | cut -c1-80)"
echo "  改列类型: $(sqt "alter table $DOB.t1 alter column v set data type DOUBLE;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -1 | cut -c1-90)"
echo "  改后写新值: $(sqt "insert into $DOB.t1 (time, dev, v) values ($(( BASE + 200 )),'d1',2.75);" 2>&1 | tail -1 | cut -c1-80)"
sqt "flush;" >/dev/null; sleep 5
echo "  改后查询: $(sqt "select v from $DOB.t1;" 2>&1 | grep -E '^\|' | tail -3 | tr '\n' ' ' | cut -c1-100)"
sqt "set configuration 'enable_seq_space_compaction'='true';" >/dev/null 2>&1
sleep 30
echo "  表模型合并后查询: $(sqt "select v from $DOB.t1;" 2>&1 | grep -E '^\|' | tail -3 | tr '\n' ' ' | cut -c1-110)"
echo "  表模型压缩日志："
for h in "${DN[@]}"; do sshx "$h" "grep -hE '($DOB)-[0-9]+ \[Compaction\]' $(cmp_log_files) 2>/dev/null | tail -3 | cut -c1-170" 2>/dev/null | sed 's/^/    /'; done

log "=== F) 视图：正确语法（表模型库）+ 改列类型 ==="
DBV=dt2v
sqt "create database $DBV;" >/dev/null 2>&1
sq "create timeseries ${DBV}_src.d1.s1 with datatype=INT32, encoding=PLAIN, compression=UNCOMPRESSED;" >/dev/null 2>&1
echo "  建视图: $(sqt "create view $DBV.v1 (s1 FIELD) as select s1 from ${DBV}_src.d1;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -1 | cut -c1-140)"
echo "  视图列表: $(sqt "show views from $DBV;" 2>&1 | grep -E '^\|' | tail -2 | tr '\n' ' ' | cut -c1-120)"
echo "  改视图列类型: $(sqt "alter view $DBV.v1 alter column s1 set data type DOUBLE;" 2>&1 | grep -vE '^\||^\+|Total line|It costs' | tail -1 | cut -c1-140)"
echo "### 探测 v2 结束 $(date '+%F %T')"
