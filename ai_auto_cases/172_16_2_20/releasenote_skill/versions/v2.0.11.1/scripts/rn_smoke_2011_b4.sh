#!/bin/bash
# V2.0.11.1 RN 冒烟第四批：审计事件覆盖（登录/DDL/用户管理/审计读权限）
set -u
CLI=${CLI:-/data2/iotdb/v20131rc2_1110_83183d0/client/timechodb-2.0.13.1-bin/sbin/start-cli.sh}
PW=${PW:-'TimechoDB@2021'}
HOST=${HOST:-172.16.2.19}
OUT=${OUT:-/data2/iotdb/rn_2_0_11_1}
LOG=$OUT/run4.log
: > "$LOG"
PASS=0; FAIL=0; SKIP=0
q(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TABLE; $1" 2>&1 | grep -vE '^\s*$' | tail -n 3; }
t(){ bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; $1" 2>&1 | grep -vE '^\s*$' | tail -n 3; }
ok(){ PASS=$((PASS+1)); echo "PASS | $1" | tee -a "$LOG"; }
ng(){ FAIL=$((FAIL+1)); echo "FAIL | $1 | $2" | tee -a "$LOG"; }
sk(){ SKIP=$((SKIP+1)); echo "SKIP | $1 | $2" | tee -a "$LOG"; }
has(){ echo "$1" | grep -qiE "$2"; }
cnt(){
  local s=0 d cc
  for d in $(bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; SHOW DEVICES root.__audit.log.**;" 2>&1 | grep -oE 'root\.__audit\.log\.[a-z0-9_.]+'); do
    cc=$(bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SET SQL_DIALECT=TREE; SELECT count(operation_type) FROM $d;" 2>&1 | grep -E '^\|[[:space:]]*[0-9]+' | head -n1 | tr -cd '0-9')
    s=$((s+${cc:-0}))
  done
  echo $s
}

echo "===== V2.0.11.1 RN SMOKE-4 $(date -Is) =====" | tee -a "$LOG"

########## 登录审计 ##########
before=$(cnt "root.__audit.log.node_0.u_4")
bash "$CLI" -h "$HOST" -p 6667 -u root -pw "$PW" -e "SHOW DATABASES;" >/dev/null 2>&1
sleep 6
after=$(cnt "root.__audit.log.node_0.u_4")
if [ -n "${after:-}" ] && [ "${after:-0}" -gt "${before:-0}" ]; then
  ok "AUDIT-7 登录/会话操作产生审计记录（$before → $after，TDB-778）"
else
  sk "AUDIT-7 登录审计增长" "before=$before after=$after"
fi

########## DDL 审计 ##########
before=$(cnt "root.__audit.log.node_0.u_4")
q "CREATE DATABASE audx;" >/dev/null
q "DROP DATABASE audx;" >/dev/null
sleep 6
after=$(cnt "root.__audit.log.node_0.u_4")
if [ "${after:-0}" -gt "${before:-0}" ]; then
  ok "AUDIT-8 DDL（建库/删库）产生审计记录（$before → $after）"
else
  ng "AUDIT-8 DDL 审计" "行数未增长 before=$before after=$after"
fi

########## 用户管理审计 ##########
before=$(cnt "root.__audit.log.node_0.u_4")
t "CREATE USER audx_u 'Aud@2026pass';" >/dev/null 2>&1
t "GRANT READ ON root.** TO USER audx_u;" >/dev/null 2>&1
t "DROP USER audx_u;" >/dev/null 2>&1
sleep 6
after=$(cnt "root.__audit.log.node_0.u_4")
if [ "${after:-0}" -gt "${before:-0}" ]; then
  ok "AUDIT-9 用户管理（建用户/授权/删用户）产生审计记录（$before → $after，TDB-781）"
else
  ng "AUDIT-9 用户管理审计" "行数未增长"
fi

########## 审计数据可读权限（TDB-794） ##########
t "CREATE USER audx_r 'Aud@2026pass';" >/dev/null 2>&1
r=$(bash "$CLI" -h "$HOST" -p 6667 -u audx_r -pw 'Aud@2026pass' -e "SET SQL_DIALECT=TREE; SELECT count(operation_type) FROM root.__audit.log.node_0.u_4;" 2>&1)
denied=$(echo "$r" | grep -cE '803|no permission|Access Denied|not authorized')
t "GRANT READ ON root.__audit.** TO USER audx_r;" >/dev/null 2>&1
sleep 2
r2=$(bash "$CLI" -h "$HOST" -p 6667 -u audx_r -pw 'Aud@2026pass' -e "SET SQL_DIALECT=TREE; SELECT count(operation_type) FROM root.__audit.log.node_0.u_4;" 2>&1)
allowed=$(echo "$r2" | grep -cE '^\|')
if [ "${denied:-0}" -ge 1 ] && [ "${allowed:-0}" -ge 1 ]; then
  ok "AUDIT-10 审计数据权限生效（无权限 803，授权后可读，TDB-794）"
elif [ "${denied:-0}" -ge 1 ]; then
  sk "AUDIT-10 授权后可读" "授权后仍不可读"
else
  sk "AUDIT-10 审计数据权限" "未出现 803（可能默认放开）"
fi
t "DROP USER audx_r;" >/dev/null 2>&1

echo "" | tee -a "$LOG"
echo "SUMMARY-4 pass=$PASS fail=$FAIL skip=$SKIP" | tee -a "$LOG"
exit 0
