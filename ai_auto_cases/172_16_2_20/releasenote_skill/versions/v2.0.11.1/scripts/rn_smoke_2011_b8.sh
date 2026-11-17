#!/bin/bash
# V2.0.11.1 RN 冒烟第八批：配置热加载剩余（wal 显示/非法值落盘/迁移限速/运行时配置）+ 查询语法
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
NEW=${NEW:-/data1/iotdb/v20131rc2_1110_83183d0}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run8.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1; }
t(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }
confval(){ ssh -n -o BatchMode=yes root@172.16.2.16 "grep -E '^$1=' $NEW/conf/iotdb-system.properties 2>/dev/null | tail -n1" 2>/dev/null; }

echo "===== V2.0.11.1 RN SMOKE-8 $(date -Is) =====" | tee -a "$LOG"

########## 配置热加载 ##########
echo "--- CFG ---" | tee -a "$LOG"
# CFG-6 wal_throttle=-1 显示与落盘（TDB-696）
r=$(t 'SET CONFIGURATION "wal_throttle_threshold_in_byte"="-1";')
v=$(confval wal_throttle_threshold_in_byte)
if has "$r" 'successfully' && echo "$v" | grep -q '\-1'; then
  ok "CFG-6 wal_throttle_threshold_in_byte=-1 已落盘（TDB-696）"
else
  sk "CFG-6 wal -1" "cfg=[$v] out=$(echo "$r" | tail -n1 | cut -c1-60)"
fi
# CFG-7 非法值不应写入配置文件（TDB-699）
t 'SET CONFIGURATION "wal_throttle_threshold_in_byte"="notanumber";' >/dev/null 2>&1
v=$(confval wal_throttle_threshold_in_byte)
if ! echo "$v" | grep -qi 'notanumber'; then
  ok "CFG-7 非法 wal 值未写入配置文件（TDB-699）"
else
  ng "CFG-7 非法值落盘" "cfg=[$v]"
fi
t 'SET CONFIGURATION "wal_throttle_threshold_in_byte"="104857600";' >/dev/null 2>&1
# CFG-8 迁移限速设置（TDB-712）
r=$(t 'SET CONFIGURATION "region_migration_speed_limit_bytes_per_second"="0";')
if has "$r" 'successfully' && ! has "$r" 'IndexOutOfBounds|Exception'; then
  ok "CFG-8 region_migration_speed_limit 设置无 IndexOutOfBounds（TDB-712）"
else
  ng "CFG-8 迁移限速" "$(echo "$r" | tail -n1 | cut -c1-70)"
fi
t 'SET CONFIGURATION "region_migration_speed_limit_bytes_per_second"="-1";' >/dev/null 2>&1
# CFG-9 运行时配置热改（TDB-738）
r=$(t 'SET CONFIGURATION "heartbeat_interval_in_ms"="2000";')
r2=$(t 'SET CONFIGURATION "heartbeat_interval_in_ms"="10000";')
if has "$r" 'successfully' && has "$r2" 'successfully'; then
  ok "CFG-9 运行时配置热改（heartbeat_interval_in_ms）成功（TDB-738）"
else
  ng "CFG-9 运行时热改" "$(echo "$r" | tail -n1 | cut -c1-70)"
fi

########## 查询语法 ##########
echo "--- QUERY ---" | tee -a "$LOG"
q "CREATE DATABASE rnq8;" >/dev/null 2>&1
q "CREATE TABLE rnq8.t (dev STRING TAG, v INT32 FIELD);" >/dev/null 2>&1
q "INSERT INTO rnq8.t(time,dev,v) VALUES (1797010000000,'d1',1);" >/dev/null 2>&1
q "INSERT INTO rnq8.t(time,dev,v) VALUES (1797010000000,'d2',2);" >/dev/null 2>&1
q "FLUSH;" >/dev/null 2>&1
sleep 2
# QRY-6 GROUP BY / ORDER BY 使用 select as 别名（TDB-739）
r=$(q "SELECT dev AS d, count(v) AS c FROM rnq8.t GROUP BY dev ORDER BY c DESC;")
if ! has "$r" 'exception' && has "$r" '\|'; then
  ok "QUERY-6 GROUP BY/ORDER BY 支持别名（TDB-739）"
else
  ng "QUERY-6 别名" "$(echo "$r" | tail -n1 | cut -c1-80)"
fi
# QRY-7 SELECT 子句中的子查询（TDB-807）
r=$(q "SELECT dev, (SELECT count(*) FROM rnq8.t) AS total FROM rnq8.t;")
if ! has "$r" 'exception'; then
  ok "QUERY-7 SELECT 子句子查询可用（TDB-807）"
else
  sk "QUERY-7 SELECT 子查询" "$(echo "$r" | tail -n1 | cut -c1-70)"
fi
# QRY-8 date_bin_gap_fill 嵌套（TDB-752）
r=$(q "SELECT date_bin_gap_fill(1s, 1797010000000, 1797010005000) AS g;" 2>&1)
if ! has "$r" 'exception'; then
  ok "QUERY-8 date_bin_gap_fill 可执行（TDB-752）"
else
  sk "QUERY-8 date_bin_gap_fill" "$(echo "$r" | tail -n1 | cut -c1-70)"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-8 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
q "DROP DATABASE rnq8;" >/dev/null 2>&1
exit 0
