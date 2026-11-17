#!/bin/bash
# V2.0.11.1 RN 冒烟验证（RC2 83183d0，3C5D）
# 覆盖主题：CFG(配置热加载) / CLI(客户端一致性) / QUERY(查询) / COPY(COPY TO TsFile) / MIGRATE(迁移取消)
# 输出：每条检查 PASS/FAIL/SKIP，最后汇总
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
mkdir -p "$OUT"
LOG=$OUT/run.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
t(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }

echo "===== V2.0.11.1 RN SMOKE $(date -Is) =====" | tee -a "$LOG"

########## CFG 配置热加载 ##########
echo "--- CFG ---" | tee -a "$LOG"
# CFG-1 非法值应被拒绝且不写入配置文件
r=$(t 'SET CONFIGURATION "wal_throttle_threshold_in_byte"="abc";')
if has "$r" 'error|exception|301|not.*valid|invalid'; then
  ok "CFG-1 非法 wal_throttle 值被拒绝"
else
  ng "CFG-1 非法 wal_throttle 值被拒绝" "未报错: $(echo "$r" | tail -n1)"
fi
# CFG-2 NaN 磁盘阈值应被拒绝，且不触发 ReadOnly
r=$(t 'SET CONFIGURATION "disk_space_warning_threshold"="NaN";')
ro=$(q "SHOW CLUSTER;" | grep -c 'ReadOnly')
if has "$r" 'error|exception|301|invalid' && [ "${ro:-0}" -eq 0 ]; then
  ok "CFG-2 disk_space_warning_threshold=NaN 被拒绝且无节点 ReadOnly"
else
  ng "CFG-2 disk_space_warning_threshold=NaN" "err=$(echo "$r" | tail -n1) readonly=$ro"
fi
# CFG-3 region_migration_concurrency_limit 0 -> 1
r0=$(t 'SET CONFIGURATION "region_migration_concurrency_limit"="0";')
r1=$(t 'SET CONFIGURATION "region_migration_concurrency_limit"="1";')
if has "$r1" 'successfully' && ! has "$r1" 'exception'; then
  ok "CFG-3 region_migration_concurrency_limit 0→1 设置成功"
else
  ng "CFG-3 region_migration_concurrency_limit 0→1" "$(echo "$r1" | tail -n1)"
fi
# CFG-4 data_region_per_data_node 设置并恢复
r=$(t 'SET CONFIGURATION "data_region_per_data_node"="3";')
r2=$(t 'SET CONFIGURATION "data_region_per_data_node"="2";')
if has "$r" 'successfully' && has "$r2" 'successfully'; then
  ok "CFG-4 data_region_per_data_node 3→2 设置成功"
else
  ng "CFG-4 data_region_per_data_node" "$(echo "$r" | tail -n1)"
fi
# CFG-5 partition_table_recover_worker_num=0 不应刷大量 ERROR
before=$(ssh -n -o BatchMode=yes root@172.16.2.16 "grep -c ERROR $NEW/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null); before=${before:-0}
r=$(t 'SET CONFIGURATION "partition_table_recover_worker_num"="0";')
sleep 20
after=$(ssh -n -o BatchMode=yes root@172.16.2.16 "grep -c ERROR $NEW/logs/log_confignode_all.log 2>/dev/null" 2>/dev/null); after=${after:-0}
if has "$r" 'successfully' && [ $((after-before)) -lt 50 ]; then
  ok "CFG-5 partition_table_recover_worker_num=0 无 ERROR 刷屏（增量 $((after-before))）"
else
  ng "CFG-5 partition_table_recover_worker_num=0" "err=$(echo "$r" | tail -n1) error_delta=$((after-before))"
fi

########## CLI 客户端 ##########
echo "--- CLI ---" | tee -a "$LOG"
q "CREATE DATABASE rn_cli;" >/dev/null 2>&1
q "CREATE TABLE rn_cli.t (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
q "INSERT INTO rn_cli.t(time,dev,v) VALUES (1796700000000,'d1',1);" >/dev/null 2>&1
q "INSERT INTO rn_cli.t(time,dev,v) VALUES (1796700000001,'d1',2);" >/dev/null 2>&1
q "FLUSH;" >/dev/null 2>&1
sleep 2
# CLI-1 不同 DN 结果一致
a=$(bash "$CLI" -h 172.16.2.19 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; SELECT count(*) FROM rn_cli.t;" 2>&1 | grep -E '^\|' | head -n1)
b=$(bash "$CLI" -h 172.16.2.21 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; SELECT count(*) FROM rn_cli.t;" 2>&1 | grep -E '^\|' | head -n1)
c=$(bash "$CLI" -h 172.16.2.22 -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; SELECT count(*) FROM rn_cli.t;" 2>&1 | grep -E '^\|' | head -n1)
if [ -n "$a" ] && [ "$a" = "$b" ] && [ "$a" = "$c" ]; then
  ok "CLI-1 三个 DN 查询结果一致（$a）"
else
  ng "CLI-1 三个 DN 查询结果一致" "a=$a b=$b c=$c"
fi
# CLI-2 SHOW TIMESERIES 排序
t "CREATE TIMESERIES root.rncli.d1.s2 WITH DATATYPE=INT32, ENCODING=PLAIN;" >/dev/null 2>&1
t "CREATE TIMESERIES root.rncli.d1.s1 WITH DATATYPE=INT32, ENCODING=PLAIN;" >/dev/null 2>&1
r=$(t "SHOW TIMESERIES ORDER BY timeseries;")
if has "$r" 'root.rncli' && ! has "$r" 'exception'; then
  ok "CLI-2 SHOW TIMESERIES ORDER BY timeseries 可用"
else
  ng "CLI-2 SHOW TIMESERIES ORDER BY timeseries" "$(echo "$r" | tail -n1)"
fi
# CLI-3 DATE 空值占位
q "CREATE TABLE rn_cli.dt (dev STRING TAG, d DATE FIELD);" >/dev/null 2>&1
r=$(q "INSERT INTO rn_cli.dt(time,dev,d) VALUES (1796700000000,'d1',NULL);")
r2=$(q "SELECT time,dev,d FROM rn_cli.dt;" | tail -n 4)
if ! has "$r" 'exception' && ! has "$r2" 'exception'; then
  ok "CLI-3 DATE 类型空值写入/查询无异常"
else
  ng "CLI-3 DATE 类型空值" "$(echo "$r" | tail -n1)"
fi

########## QUERY 查询 ##########
echo "--- QUERY ---" | tee -a "$LOG"
# QUERY-1 对齐序列 LAST + 时间过滤（防卡死）
t "CREATE ALIGNED TIMESERIES root.rnq.d1(s1 INT32, s2 INT64);" >/dev/null 2>&1
t "INSERT INTO root.rnq.d1(timestamp,s1,s2) ALIGNED VALUES (1796710000000,1,10),(1796710000100,2,20),(1796710000200,3,30);" >/dev/null 2>&1
t "FLUSH;" >/dev/null 2>&1
start=$(date +%s)
r=$(timeout 30 bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; SELECT LAST s1, s2 FROM root.rnq.d1 WHERE time >= 1796710000000;" 2>&1)
dur=$(( $(date +%s) - start ))
if [ "$dur" -lt 30 ] && ! has "$r" 'exception' && has "$r" '\|'; then
  ok "QUERY-1 对齐序列 LAST+时间过滤返回正常（${dur}s）"
else
  ng "QUERY-1 对齐序列 LAST+时间过滤" "dur=${dur}s out=$(echo "$r" | tail -n1)"
fi
# QUERY-2 DELETE 时间区间 min>max 的报错行为
q "CREATE TABLE rn_cli.bad (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
q "INSERT INTO rn_cli.bad(time,dev,v) VALUES (1796720000000,'d1',1);" >/dev/null 2>&1
r=$(q "DELETE FROM rn_cli.bad WHERE time > 1796720000100 AND time < 1796720000000;")
code=$(echo "$r" | grep -oE '[0-9]{3}:')
if ! has "$r" 'exception' || [ "${code:-}" != "305:" ]; then
  ok "QUERY-2 时间区间 min>max 未返回 305（当前: ${code:-无错误}）"
else
  ng "QUERY-2 时间区间 min>max" "仍返回 305"
fi
# QUERY-3 EXPLAIN ANALYZE
r=$(q "EXPLAIN ANALYZE SELECT count(*) FROM rn_cli.t;")
if has "$r" '\|' && ! has "$r" 'exception'; then
  ok "QUERY-3 EXPLAIN ANALYZE 可执行"
else
  ng "QUERY-3 EXPLAIN ANALYZE" "$(echo "$r" | tail -n1)"
fi

########## COPY TO TsFile ##########
echo "--- COPY ---" | tee -a "$LOG"
q "CREATE TABLE rn_cli.ct (dev STRING TAG, reg STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
q "INSERT INTO rn_cli.ct(time,dev,reg,v) VALUES (1796730000000,'d1','r1',1);" >/dev/null 2>&1
q "FLUSH;" >/dev/null 2>&1
sleep 2
# COPY-1 TAGS 中重复列应报错
r=$(q "COPY rn_cli.ct TO '/data2/iotdb/rn_2_0_11_1/c1.tsfile' WITH (TAGS(dev,dev));")
if has "$r" 'exception|error|duplicat|重复'; then
  ok "COPY-1 TAGS 重复列被拒绝"
else
  ng "COPY-1 TAGS 重复列被拒绝" "$(echo "$r" | tail -n1)"
fi
# COPY-2 查询形式 + 不指定 TABLE
r=$(q "COPY (SELECT time,dev,v FROM rn_cli.ct) TO '/data2/iotdb/rn_2_0_11_1/c2.tsfile';")
if ! has "$r" 'exception'; then
  ok "COPY-2 COPY (query) TO 不带 TABLE 成功"
else
  ng "COPY-2 COPY (query) TO" "$(echo "$r" | tail -n1)"
fi

########## MIGRATE 迁移取消 ##########
echo "--- MIGRATE ---" | tee -a "$LOG"
rid=$(q "SHOW REGIONS;" | grep -i rn_cli | grep DataRegion | awk -F'|' '{gsub(/ /,"",$2); print $2}' | head -n1)
if [ -n "${rid:-}" ]; then
  mk="RNMIG-$(date +%s)"; echo "$mk" > /tmp/rn_mig_mark
  for n in 19 21 22 23 24; do ssh -n -o BatchMode=yes root@172.16.2.$n "echo $mk >> $NEW/logs/log_datanode_all.log" 2>/dev/null; done
  q "EXTEND REGION $rid TO 6;" >/dev/null 2>&1
  sleep 3
  q "CANCEL ALL MIGRATIONS;" >/dev/null 2>&1
  sleep 10
  bad=0
  for n in 19 21 22 23 24; do
    c=$(ssh -n -o BatchMode=yes root@172.16.2.$n "awk -v m='$mk' 'index(\$0,m){f=1} f' $NEW/logs/log_datanode_all.log 2>/dev/null | grep -icE 'unexpected consensusGroupId|NullPointerException|TreeSet' " 2>/dev/null)
    bad=$((bad+${c:-0}))
  done
  q "CANCEL ALL MIGRATIONS;" >/dev/null 2>&1
  sleep 5
  if [ "$bad" -eq 0 ]; then
    ok "MIGRATE-1 EXTEND+CANCEL ALL MIGRATIONS 无 NPE/unexpected consensusGroupId"
  else
    ng "MIGRATE-1 EXTEND+CANCEL ALL MIGRATIONS" "异常行数=$bad"
  fi
else
  sk "MIGRATE-1" "未找到 rn_cli 的 DataRegion"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
q "DROP DATABASE rn_cli;" >/dev/null 2>&1
t "DELETE TIMESERIES root.rncli.**;" >/dev/null 2>&1
t "DELETE TIMESERIES root.rnq.**;" >/dev/null 2>&1
exit 0
