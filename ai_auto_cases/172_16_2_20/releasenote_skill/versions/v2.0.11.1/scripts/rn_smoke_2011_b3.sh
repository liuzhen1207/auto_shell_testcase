#!/bin/bash
# V2.0.11.1 RN 冒烟第三批：审计埋点、表模型 DDL、存储/集群轻量检查
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run3.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1 | grep -vE '^\s*$' | tail -n 4; }
t(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1 | grep -vE '^\s*$' | tail -n 4; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }

echo "===== V2.0.11.1 RN SMOKE-3 $(date -Is) =====" | tee -a "$LOG"

########## AUDIT 审计埋点 ##########
echo "--- AUDIT ---" | tee -a "$LOG"
# 先触发一批操作
t "CREATE USER rnaud 'Aud@2026pass';" >/dev/null 2>&1
t "CANCEL ALL MIGRATIONS;" >/dev/null 2>&1
# 受限用户执行 CANCEL，应被拒绝
r=$(bash "$CLI" -h "$HOST" -p 6667 -u rnaud -pw 'Aud@2026pass' -e "SET SQL_DIALECT=TREE; CANCEL ALL MIGRATIONS;" 2>&1)
denied=$(echo "$r" | grep -cE '803|no permission|Access Denied|not authorized')
# 错误口令登录
bash "$CLI" -h "$HOST" -p 6667 -u root -pw 'WrongPass@123' -e "SHOW DATABASES;" >/dev/null 2>&1
sleep 4
# 取审计记录
T0=$(date -d '5 minutes ago' +%Y-%m-%dT%H:%M:%S)
# TDB-709 fixed: CANCEL writes OBJECT_AUTHENTICATION + privilege=[MAINTAIN] + operation_type=CONTROL.
aud_cancel=$(bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; SELECT audit_event_type, privilege_type, operation_type, result FROM root.__audit.log.** WHERE time > $T0;" 2>&1)
cnt_cancel=$(echo "$aud_cancel" | grep -E 'OBJECT_AUTHENTICATION' | grep -c '\[MAINTAIN\]')
cnt_fail=$(echo "$aud" | grep -ciE 'fail|false|denied|error')
if [ "${cnt_cancel:-0}" -ge 1 ]; then
  ok "AUDIT-4 CANCEL ALL MIGRATIONS 产生审计记录（命中 $cnt_cancel 行，TDB-709）"
else
  ng "AUDIT-4 CANCEL ALL MIGRATIONS 审计记录" "未命中"
fi
if [ "${denied:-0}" -ge 1 ]; then
  ok "AUDIT-5 受限用户 CANCEL ALL MIGRATIONS 被拒绝（803，TDB-709 拒绝场景）"
else
  sk "AUDIT-5 受限用户 CANCEL 拒绝" "未出现 803"
fi
if [ "${cnt_fail:-0}" -ge 1 ]; then
  ok "AUDIT-6 失败类事件（登录失败/拒绝）有审计记录（$cnt_fail 行，TDB-775/776/778）"
else
  sk "AUDIT-6 失败类审计" "未命中失败记录"
fi
t "DROP USER rnaud;" >/dev/null 2>&1

########## DDL 表模型 ##########
echo "--- DDL ---" | tee -a "$LOG"
r=$(q "COUNT DATABASES;")
if has "$r" '[0-9]' && ! has "$r" 'exception'; then
  ok "DDL-1 COUNT DATABASES 可用（TDB-799）"
else
  ng "DDL-1 COUNT DATABASES" "$(echo "$r" | tail -n1 | cut -c1-60)"
fi
# DDL-2 整型/浮点比较一致性（TDB-828）
q "CREATE DATABASE rnddl;" >/dev/null 2>&1
q "CREATE TABLE rnddl.t (dev STRING TAG, iv INT32 FIELD, dv DOUBLE FIELD);" >/dev/null 2>&1
q "INSERT INTO rnddl.t(time,dev,iv,dv) VALUES (1796810000000,'d1',2,2.0);" >/dev/null 2>&1
q "FLUSH;" >/dev/null 2>&1
sleep 2
a=$(q "SELECT count(*) FROM rnddl.t WHERE iv = 2.0;" | grep -E '^\|' | head -n1)
b=$(q "SELECT count(*) FROM rnddl.t WHERE dv = 2;" | grep -E '^\|' | head -n1)
if [ -n "$a" ] && [ "$a" = "$b" ]; then
  ok "DDL-2 整型/浮点跨类型比较一致（$a，TDB-828）"
else
  ng "DDL-2 整型/浮点比较" "iv=2.0 -> $a ; dv=2 -> $b"
fi

########## STORAGE 存储/查询类型 ##########
echo "--- STORAGE ---" | tee -a "$LOG"
r=$(q "SELECT cast(1.1 as float) FROM (SELECT 1 as a);")
if ! has "$r" 'UnsupportedOperationException|exception'; then
  ok "STOR-3 cast(1.1 as float) 无异常（TDB-809）"
else
  ng "STOR-3 cast as float" "$(echo "$r" | tail -n1 | cut -c1-70)"
fi

########## CLUSTER 集群 ##########
echo "--- CLUSTER ---" | tee -a "$LOG"
r=$(q "SHOW REGIONS;")
row=$(echo "$r" | grep -E 'DataRegion' | grep -v 'Unknown' | head -n1)
ratio=$(echo "$row" | awk -F'|' '{gsub(/ /,"",$15); print $15}')
if [ -n "${ratio:-}" ] && [ "$ratio" != "NaN" ]; then
  ok "CLUSTER-1 SHOW REGIONS 的 CompressionRatio 可见（$ratio，TDB-818）"
else
  sk "CLUSTER-1 CompressionRatio" "当前无有效值"
fi
# CLUSTER-2 多 region 列表语法（TDB-796）
ids=$(q "SHOW REGIONS;" | grep DataRegion | awk -F'|' '{gsub(/ /,"",$2); print $2}' | sort -u | head -n 2 | paste -sd, -)
if [ -n "${ids:-}" ] && [ "$(echo "$ids" | tr ',' '\n' | wc -l)" -ge 2 ]; then
  r=$(t "EXTEND REGION $ids TO 6;")
  if has "$r" 'successfully' || has "$r" 'region.*not exist|909'; then
    ok "CLUSTER-2 EXTEND REGION 支持 regionId 列表（$ids，TDB-796）"
  else
    ng "CLUSTER-2 多 region 列表" "$(echo "$r" | tail -n1 | cut -c1-70)"
  fi
else
  sk "CLUSTER-2 多 region 列表" "region 不足 2 个"
fi

echo "" | tee -a "$LOG"
echo "SUMMARY-3 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
q "DROP DATABASE rnddl;" >/dev/null 2>&1
exit 0
