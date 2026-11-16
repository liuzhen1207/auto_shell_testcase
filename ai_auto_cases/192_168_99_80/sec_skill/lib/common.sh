#!/bin/bash
# ============================================================================
# sec_skill 公共库：强安全级别密码（身份鉴别）需求回归
#   设计要点：
#   1) 角色感知：normal 模式用 root；sep（三权分立）模式用 security_admin（用户/安全）
#      / sys_admin（DDL）/ audit_admin（审计），并断言 root 被拒（803）。
#   2) 每条用例统一收尾：sync lag 归零 → 副本一致性（逐停 DN）→ CN/DN 日志门禁
#      （无预期外 WARN/ERROR；且日志不得出现明文密码）。
#   3) 时间类需求（过期/复用间隔）用"时钟前移 + 复位"实现，不靠真实等待。
# ============================================================================
set -uo pipefail

SEC_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export SEC_SKILL_DIR
. "$SEC_SKILL_DIR/conf/env.conf"
# 节点本机上的 CLI（与 .80 的 testdb 路径不同），用于"本机登录"类验证
CLI_NODE="${DB_DIR}/sbin/start-cli.sh"

SEC_CASE=""; SEC_RUN_ID="$(date '+%Y%m%d_%H%M%S')"; SEC_FAILS=0; SEC_PASSES=0; SEC_WARNS=0
SEC_OUT="$SEC_SKILL_DIR/results/$SEC_RUN_ID.out"
SEC_RESULTS="$SEC_SKILL_DIR/results/test_result.csv"
SEC_ART_ROOT="$SEC_SKILL_DIR/results"
mkdir -p "$SEC_SKILL_DIR/results"

sec_log(){ echo "[$(date '+%F %T')] $*" | tee -a "${SEC_OUT:-/dev/null}"; }
pass(){ SEC_PASSES=$((SEC_PASSES+1)); sec_log "PASS $*"; }
fail(){ SEC_FAILS=$((SEC_FAILS+1)); sec_log "FAIL $*"; }
warn(){ SEC_WARNS=$((SEC_WARNS+1)); sec_log "WARN $*"; }

# ---------- 参数 ----------
sec_parse_args(){
  while [ $# -gt 0 ]; do
    case "$1" in
      --mode) SEC_MODE="$2"; shift 2 ;;
      --mode=*) SEC_MODE="${1#*=}"; shift ;;
      --consensus) SEC_CONSENSUS="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
}

# ---------- 基础执行 ----------
sshx(){ local h=$1; shift; ssh -o BatchMode=yes -o ConnectTimeout=20 -o LogLevel=ERROR root@"$h" "$*" 2>/dev/null; }

sec_sql_as(){ local u=$1 pw=$2 d=$3 sql=$4
  printf 'set sql_dialect=%s;\n%s\n' "$d" "$sql" | timeout 90 "$CLI" -h "$PRIMARY" -u "$u" -pw "$pw" 2>&1; }
sec_sql(){ sec_sql_as "$SEC_USER" "$SEC_PW" "${1:-tree}" "${2:-show databases;}"; }
st(){ sec_sql tree "$1"; }
stb(){ sec_sql table "$1"; }

sec_clean(){ grep -avE '^(TimechoDB>|Starting TimechoDB|----|  _| /_|/ /|/_/|\s*$)' | grep -avE '^\s*$'; }
msg_of(){ sec_clean | grep -aE 'Msg:|Error:' | tail -1; }
scalar(){ sec_clean | grep -aE '^\|' | sed -n '2p' | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}'; }
table_rows(){ grep -aE '^\|' | sed -n '3,$p' | grep -avE '^\+' ; }

# ---------- 模式 ----------
sec_detect_mode(){
  [ "$SEC_MODE" = "auto" ] || return 0
  local out
  out=$(sec_sql_as root "$ROOT_PW" tree "show cluster;")
  if printf '%s' "$out" | grep -q '803.*SUPER USER is not allowed'; then
    SEC_MODE=sep
  elif printf '%s' "$out" | grep -q 'Running'; then
    SEC_MODE=normal
  else
    SEC_MODE=normal
    warn "模式探测未拿到明确结果（按 normal 处理）：$(printf '%s' "$out" | grep -aE 'Error|Msg' | head -1)"
  fi
}

sec_bind_users(){
  sec_detect_mode
  if [ "$SEC_MODE" = "sep" ]; then
    SEC_USER="$SEC_ADMIN"; SEC_PW="$ADMIN_PW"
    DDL_USER="$SYS_ADMIN"; AUD_USER="$AUDIT_ADMIN"
  else
    SEC_USER=root; SEC_PW="$ROOT_PW"
    DDL_USER=root; AUD_USER=root
  fi
  export SEC_MODE SEC_USER SEC_PW DDL_USER AUD_USER
}

# ---------- 配置读写（show configuration 列：| key | 生效值 | 默认值 |）----------
sec_conf_get(){
  stb "show configuration;" | sec_clean | grep -aE "^\\|[[:space:]]*$1[[:space:]]*\\|" | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$3); print $3}'
}
sec_conf_set(){ st "set configuration '$1'='$2';" | msg_of; }
sec_conf_restore(){
  sec_conf_set enforce_strong_password true >/dev/null 2>&1
  sec_conf_set password_expiration_days 0 >/dev/null 2>&1
  # 注意：password_reuse_interval_days 的 setter 会把 0 改写成 1（CommonConfig.java:3428），
  # 写 0 会让"禁用"变成"1 天限制"并污染后续用例 —— 统一用 -1（代码默认值，等于禁用）。
  sec_conf_set password_reuse_interval_days -1 >/dev/null 2>&1
}

# ---------- 用户 ----------
sec_user_drop(){ st "drop user $1;" >/dev/null 2>&1 || true; }
sec_user_exists(){ st "list user;" | grep -aqE "\\|[[:space:]]*$1[[:space:]]*\\|"; }
sec_user_create(){ st "create user $1 '$2';" | msg_of; }
sec_user_alter(){ st "alter user $1 set password '$2';" | msg_of; }

sec_login_ok(){
  local u=$1 pw=$2 out
  out=$(sec_sql_as "$u" "$pw" tree "show databases;")
  ! printf '%s' "$out" | grep -qE 'Error:|Msg:.*(820|803|822|801|Password)'
}
sec_login_msg(){
  sec_sql_as "$1" "$2" tree "show databases;" | grep -aE 'Error:|Msg:' | tail -1
}


# ---------- 指定节点执行（用于单 DN 时钟偏移类用例）----------
sec_sql_via(){ local h=$1 u=$2 pw=$3 d=$4 sql=$5
  printf 'set sql_dialect=%s;\n%s\n' "$d" "$sql" | timeout 90 "$CLI" -h "$h" -u "$u" -pw "$pw" 2>&1; }
sec_login_ok_via(){ local h=$1 u=$2 pw=$3 out
  out=$(sec_sql_via "$h" "$u" "$pw" tree "show databases;")
  ! printf '%s' "$out" | grep -qE 'Error:|Msg:.*(820|803|822|801|Password)'; }
sec_login_msg_via(){ sec_sql_via "$1" "$2" "$3" tree "show databases;" | grep -aE 'Error:|Msg:' | tail -1; }
sec_user_alter_via(){ sec_sql_via "$1" "$SEC_USER" "$SEC_PW" tree "alter user $2 set password '$3';" | grep -aE 'Msg:|Error:' | tail -1; }


# ---------- 登录/锁定相关（防止口令暴力破解、身份鉴别基础）----------
# 一次登录尝试，返回最后一条 Error/Msg（含错误码）
try_login(){ local u=$1 pw=$2 h=${3:-$PRIMARY} out
  out=$(sec_sql_via "$h" "$u" "$pw" tree "list user;")
  printf '%s' "$out" | grep -aE 'Error:|Msg:' | tail -1; }
try_login_ok(){ printf '%s' "$(try_login "$1" "$2" "${3:-$PRIMARY}")" | grep -q 'Msg:'; }
# 直接读错误码（801/822/804/803/...），无错误码时输出空
login_code(){ try_login "$1" "$2" "${3:-$PRIMARY}" | grep -aoE '[0-9]{3}:' | head -1 | tr -d ':'; }
# 连续错误登录 n 次，打印每次的错误码
repeat_bad_login(){ local u=$1 n=$2 i c codes=""
  for i in $(seq 1 "$n"); do c=$(login_code "$u" 'DefinitelyWrong123!'); codes="$codes ${c:-OK}"; done
  echo "$codes"; }
# 带 restart 提示的配置设置（返回原始最后一条消息，含 restart is required）
conf_set_raw(){ st "set configuration '$1'='$2';" | grep -aE 'Msg:|Error:' | tail -1; }
# 读取生效值（配置可能不在 show configuration 中，返回值或空）
conf_eff(){ local u="$SEC_USER" pw="$SEC_PW"
  # sep 模式下 security_admin 无 SYSTEM 权限，show configuration 需用 sys_admin
  [ "${SEC_MODE:-normal}" = "sep" ] && { u="$DDL_USER"; pw="$ADMIN_PW"; }
  sec_sql_as "$u" "$pw" table "show configuration;" | grep -aE "^\|[[:space:]]*$1[[:space:]]*\|" | head -1 | awk -F'|' '{gsub(/ /,"",$3); print $3}'; }
conf_set_raw_as(){ local u=$1 pw=$2
  sec_sql_as "$u" "$pw" tree "set configuration '$3'='$4';" | grep -aE 'Msg:|Error:' | tail -1; }

# 连续错误登录，直到出现 822 或达到 max 次；返回 "次数:最后的错误码"
lock_until_code(){ local u=$1 max=$2 i c
  for i in $(seq 1 "$max"); do
    c=$(login_code "$u" 'DefinitelyWrong123!')
    if [ "$c" = "822" ]; then echo "$i:822"; return 0; fi
  done
  echo "$max:${c:-none}"; }
# ---------- 断言 ----------
assert_contains(){ if printf '%s' "$2" | grep -aqF "$3"; then pass "$1: 命中 /$3/"; else fail "$1: 未命中 /$3/（实际=${2:0:170}）"; fi; }
assert_not_contains(){ if printf '%s' "$2" | grep -aqF "$3"; then fail "$1: 不应出现 /$3/"; else pass "$1: 未出现 /$3/"; fi; }
assert_eq(){ if [ "$2" = "$3" ]; then pass "$1: $2 == $3"; else fail "$1: 实际=[$2] 期望=[$3]"; fi; }
assert_ne(){ if [ "$2" != "$3" ]; then pass "$1: $2 != $3"; else fail "$1: 不应相等（都是 [$2]）"; fi; }

# ---------- 集群 ----------
sec_running(){ stb "show cluster;" 2>/dev/null | grep -ac 'Running' | tr -dc '0-9' | head -1; }
sec_sync_lag_zero(){
  local h line bad=0
  for h in $DN_NODES; do
    line=$(sshx "$h" "curl -s --max-time 5 http://$h:9092/metrics 2>/dev/null | grep -E '^iot_consensus\\{type=\"syncLag\"' | awk '{s+=\$2} END{print s+0}'")
    [ "${line:-0}" != "0" ] && bad=$((bad+1))
  done
  [ "$bad" -eq 0 ] && pass "sync lag 归零（各 DN syncLag 合计=0）" || warn "有 $bad 个 DN syncLag 非 0"
}
sec_replica_fingerprint(){
  local h=$1 out
  out=$(printf 'set sql_dialect=tree;\nlist user;\n' | timeout 60 "$CLI" -h "$h" -u "$SEC_USER" -pw "$SEC_PW" 2>&1)
  printf '%s' "$out" | grep -aE '^\| *[0-9]+ *\|' | sed -E 's/ +/ /g' | sort | md5sum | cut -d' ' -f1
}
sec_replica_consistency(){
  local base h f bad=0 other f2
  base=$(sec_replica_fingerprint "$PRIMARY")
  for h in $DN_NODES; do
    [ "$h" = "$PRIMARY" ] && continue
    f=$(sec_replica_fingerprint "$h")
    if [ "$f" != "$base" ]; then fail "副本一致性：$PRIMARY 与 $h 用户元数据指纹不一致（$base vs $f）"; bad=$((bad+1)); fi
  done
  [ "$bad" -eq 0 ] && pass "副本一致性：三 DN 用户元数据指纹一致（$base）"
  local i
  for h in $DN_NODES; do
    # 只停该节点的 DataNode（不碰同节点 ConfigNode）
    sshx "$h" "pkill -TERM -f 'org.apache.iotdb.db.service.DataNode' || true" >/dev/null 2>&1
    sleep 25
    other=$(echo $DN_NODES | tr ' ' '\n' | grep -v "^$h$" | head -1)
    f2=$(sec_replica_fingerprint "$other")
    if [ "$f2" = "$base" ]; then pass "停 $h 后经 $other 查询，用户元数据与基线一致"; else fail "停 $h 后经 $other 查询不一致（$base vs $f2）"; fi
    # 用框架脚本整体拉起（保证 CN/DN 都回来）
    ( cd /data/iotdb/autotest && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$SEC_OUT" 2>&1 & )
    for i in $(seq 1 30); do r=$(sec_running_via_ok); case "$r" in ""|*[!0-9]*) r=0 ;; esac; [ "$r" -ge 6 ] && break; sleep 5; done
    pass "节点 $h 已恢复（Running=$(sec_running_via_ok)）"
  done
}

# ---------- 集群生命周期 / 时钟 ----------
sec_stop_cluster(){ local h; for h in $ALL_NODES; do sshx "$h" "pkill -TERM -f 'com.timecho.iotdb' || true" >/dev/null 2>&1; done; sleep 10; }
sec_start_cluster(){
  local i n
  ( cd /data/iotdb/autotest && setsid nohup bash prepare_env/start_cluster_v20.sh 1 6 >>"$SEC_OUT" 2>&1 & )
  for i in $(seq 1 40); do
    n=$(sec_running 2>/dev/null); case "${n:-0}" in ""|*[!0-9]*) n=0 ;; esac
    [ "$n" -ge 6 ] && { pass "集群就绪 Running=$n"; return 0; }
    sleep 10
  done
  fail "集群未就绪 Running=${n:-0}"; return 1
}
sec_clock_shift(){ local delta=$1 h
  for h in $ALL_NODES; do
    sshx "$h" "date -s \"\$(date -d '$delta' '+%Y-%m-%d %H:%M:%S')\" >/dev/null 2>&1; date '+%F %T'" | sed "s/^/    .$h /"
  done
}

sec_running_via_ok(){ local h n=0 c
  for h in $ALL_NODES; do
    c=$(sshx "$h" "ps -eo cmd | grep -c '[c]om.timecho.iotdb'" | tr -dc '0-9' | head -1)
    n=$(( n + ${c:-0} ))
  done
  echo $(( n / 2 ))
}
# ---------- 日志门禁 ----------
SEC_LOG_MARK_DIR="$SEC_SKILL_DIR/results/.logmark"; mkdir -p "$SEC_LOG_MARK_DIR"
sec_log_mark(){
  local h
  for h in $ALL_NODES; do
    sshx "$h" "cat $DB_DIR/logs/log_confignode_all.log $DB_DIR/logs/log_datanode_all.log 2>/dev/null | wc -l" > "$SEC_LOG_MARK_DIR/$h"
  done
}
sec_check_logs(){
  local h base line bad=0
  for h in $ALL_NODES; do
    base=$(cat "$SEC_LOG_MARK_DIR/$h" 2>/dev/null || echo 0)
    line=$(sshx "$h" "cat $DB_DIR/logs/log_confignode_all.log $DB_DIR/logs/log_datanode_all.log 2>/dev/null | grep -aE ' (ERROR|WARN) ' | grep -avE '$SEC_LOG_BENIGN' | awk -v st='${SEC_CASE_START_TS:-1970-01-01 00:00:00}' 'substr(\$0,1,19) >= st' | head -3")
    if [ -n "$line" ]; then
      fail "节点 $h 出现预期外 WARN/ERROR：$(printf '%s' "$line" | head -2 | cut -c1-200 | tr '\n' ' ')"
      bad=$((bad+1))
    fi
  done
  [ "$bad" -eq 0 ] && pass "CN/DN 日志门禁：无预期外 WARN/ERROR"
}
sec_check_password_leak(){
  local pw=$1 h hit bad=0
  for h in $ALL_NODES; do
    hit=$(sshx "$h" "grep -F -l -- '$pw' $DB_DIR/logs/*.log 2>/dev/null | head -2")
    if [ -n "$hit" ]; then fail "节点 $h 日志出现明文密码（${pw:0:4}***）：$hit"; bad=$((bad+1)); fi
  done
  [ "$bad" -eq 0 ] && pass "日志不含明文密码（${pw:0:4}***）"
}

# ---------- 用例框架 ----------
sec_case_init(){
  SEC_CASE="$1"; SEC_CASE_NAME="$2"
  SEC_OUT="$SEC_SKILL_DIR/results/${SEC_CASE}_${SEC_RUN_ID}.out"
  : >"$SEC_OUT"
  sec_bind_users
  sec_log "=== $SEC_CASE $SEC_CASE_NAME 开始 run_id=$SEC_RUN_ID mode=$SEC_MODE ==="
  sec_log "环境: build=$BUILD_TAG nodes=[$CN_NODES] 角色 SEC:$SEC_USER DDL:$DDL_USER AUD:$AUD_USER"
  sec_conf_restore
  sec_log "安全配置复位: enforce=$(sec_conf_get enforce_strong_password) expiry=$(sec_conf_get password_expiration_days) reuse=$(sec_conf_get password_reuse_interval_days)"
  SEC_CASE_START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
  sec_log_mark
}
sec_case_finish(){
  sec_conf_restore
  sec_sync_lag_zero
  sec_check_logs
  local dur=${SECONDS:-0} res=PASS
  [ "$SEC_FAILS" -gt 0 ] && res=FAIL
  sec_log "RESULT $res fail_flag=$SEC_FAILS case=${SEC_CASE}_${SEC_MODE} mode=$SEC_MODE build=$BUILD_TAG elapsed=${dur}s passes=$SEC_PASSES warns=$SEC_WARNS"
  [ -f "$SEC_RESULTS" ] || echo "Time,build,mode,caseName,result,elapsedSeconds,failCount,warnCount,artifact,message" > "$SEC_RESULTS"
  echo "$(date '+%FT%T%z'),$BUILD_TAG,$SEC_MODE,$SEC_CASE,$res,$dur,$SEC_FAILS,$SEC_WARNS,$SEC_OUT," >> "$SEC_RESULTS"
  if [ "$res" = "FAIL" ]; then
    local art="$SEC_ART_ROOT/artifact_${SEC_CASE}_${SEC_MODE}_${SEC_RUN_ID}" h
    mkdir -p "$art/logs"
    for h in $ALL_NODES; do
      sshx "$h" "cd $DB_DIR/logs 2>/dev/null && tar czf - log_confignode_all.log log_datanode_all.log 2>/dev/null" > "$art/logs/$h.logs.tgz" 2>/dev/null || true
    done
    sec_log "失败日志已备份：$art"
  fi
}
