#!/bin/bash
# ============================================================================
# LBAC 测试套件公共库（表模型 LBAC）
# ============================================================================
set -u
BASE="${BASE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[ -f "$BASE/conf/env.conf" ] && . "$BASE/conf/env.conf"

NEW=${NEW:-v20131rc2_1110_83183d0}
CLI=${CLI:-/data2/iotdb/$NEW/sbin/start-cli.sh}
CN_LIST=${CN_LIST:-172.16.2.26 172.16.2.27 172.16.2.28}
DN_LIST=${DN_LIST:-172.16.2.2 172.16.2.3 172.16.2.4 172.16.2.5 172.16.2.6}
HOST=${HOST:-172.16.2.2}
PW=${PW:-TimechoDB@2021}
UPW=${UPW:-Lbac@1234567}
CN_DIR=${CN_DIR:-/data/iotdb/$NEW}
DN_DIR=${DN_DIR:-/data1/iotdb/$NEW}
DB=${DB:-lb_db}
TBL=${TBL:-t1}

# ---------- SQL ----------
QS() { timeout 60 $CLI -h "$HOST" -p 6667 -u "${SEC_ADMIN:-security_admin}" -pw "${ADMIN_PW:-$PW}" -sql_dialect table -e "$1" 2>&1; }
QD() { timeout 60 $CLI -h "$HOST" -p 6667 -u "${SYS_ADMIN:-sys_admin}"     -pw "${ADMIN_PW:-$PW}" -sql_dialect table -e "$1" 2>&1; }
QR() { timeout 60 $CLI -h "$HOST" -p 6667 -u root -pw "$PW" -sql_dialect table -e "$1" 2>&1; }

# 三权分立下的语句分发：
#   - 库/表/视图 DDL 与数据语句 -> sys_admin（含 ALTER TABLE ... ADD/DROP SECURITY POLICY，需要 ALTER）
#   - LBAC 元数据/授权/用户角色 -> security_admin
Q() {
  if [ "${SEP:-0}" != "1" ]; then QR "$1"; return; fi
  local s="$1"
  # security_* 系统表只有 SECURITY 主体能看到全部记录，统一用 security_admin 查询
  case "$s" in
    *information_schema.security_*) QS "$1"; return ;;
  esac
  case "$s" in
    CREATE\ TABLE*|CREATE\ DATABASE*|CREATE\ VIEW*|DROP\ TABLE*|DROP\ DATABASE*|DROP\ VIEW*|ALTER\ TABLE*|ALTER\ DATABASE*|INSERT*|SELECT*|UPDATE*|DELETE*|DESCRIBE*|SHOW\ *|show\ *)
      QD "$1" ;;
    CREATE\ SECURITY*|ALTER\ SECURITY*|DROP\ SECURITY*|COMMENT\ ON\ SECURITY*|GRANT*|REVOKE*|CREATE\ USER*|DROP\ USER*|CREATE\ ROLE*|DROP\ ROLE*|LIST\ USER*|LIST\ ROLE*)
      QS "$1" ;;
    *)
      QD "$1" ;;
  esac
}

T() { timeout 60 $CLI -h "$HOST" -p 6667 -u root -pw "$PW" -sql_dialect tree  -e "$1" 2>&1; }
L() { timeout 60 $CLI -h "$HOST" -p 6667 -u "$1" -pw "$2" -sql_dialect table -e "$3" 2>&1; }
u_sql() { L "$1" "$UPW" "$2"; }

# ---------- 断言 ----------
ok()   { echo "  [ok] $*"; }
fail() { FAILS=$((FAILS + 1)); echo "  [FAIL] $*"; }
note() { echo "  $*"; }

assert_ok() {
  local o="$1" d="$2"
  if echo "$o" | grep -qiE 'MSG: .*EXCEPTION|^Error:'; then
    fail "$d -> $(echo "$o" | head -1 | cut -c1-160)"
  else
    ok "$d"
  fi
}

assert_err() {
  local o="$1" pat="$2" d="$3"
  if ! echo "$o" | grep -qiE 'MSG: .*EXCEPTION|^Error:'; then
    fail "$d -> 期望报错但成功了：$(echo "$o" | head -1 | cut -c1-120)"
    return
  fi
  if [ -n "$pat" ] && ! echo "$o" | grep -qiE "$pat"; then
    fail "$d -> 报错信息不含 [$pat]：$(echo "$o" | head -1 | cut -c1-140)"
  else
    ok "$d"
  fi
}

assert_contains() {
  if echo "$1" | grep -qF "$2"; then ok "$3"; else fail "$3 -> 不含 [$2]（实际：$(echo "$1" | head -2 | tr '\n' ' ' | cut -c1-140)）"; fi
}

assert_no_rows() {
  local n
  n=$(echo "$1" | grep -cE '^\| *[0-9]')
  if [ "$n" = "0" ]; then ok "$2"; else fail "$2 -> 期望无数据行，实际 $n 行"; fi
}

# ---------- 元数据清理 ----------
lbac_reset() {
  # 顺序：删库（解绑表）→ 删测试用户/角色（解除授权）→ 撤 root 残留授权 → 标签 → 策略 → 组件
  Q "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
  Q "DROP DATABASE IF EXISTS ${DB}2" >/dev/null 2>&1

  local rows x
  rows=$(Q "LIST USER" 2>/dev/null | awk -F'|' 'NF>3 {gsub(/ /,"",$3); if ($3 ~ /^lbu_/) print $3}')
  for x in $rows; do Q "DROP USER $x" >/dev/null 2>&1; done
  rows=$(Q "LIST ROLE" 2>/dev/null | awk -F'|' 'NF>2 {gsub(/ /,"",$2); if ($2 ~ /^lbr_/) print $2}')
  for x in $rows; do Q "DROP ROLE $x" >/dev/null 2>&1; done

  sleep 2
  # 回收所有主体（root/sys_admin/security_admin/角色）对 lb_* 标签的授权与豁免，避免残留导致 2414/2413 级联
  local pn ln gname gtype
  while IFS='|' read -r _ pn ln gname gtype _; do
    pn=$(echo "$pn" | tr -d ' '); ln=$(echo "$ln" | tr -d ' ')
    gname=$(echo "$gname" | tr -d ' '); gtype=$(echo "$gtype" | tr -d ' ')
    case "$pn" in lb_*) ;; *) continue ;; esac
    [ -z "$gname" ] && continue
    if [ "$gtype" = "ROLE" ]; then
      Q "REVOKE SECURITY LABEL $pn.$ln FROM ROLE $gname" >/dev/null 2>&1
    else
      Q "REVOKE SECURITY LABEL $pn.$ln FROM USER $gname" >/dev/null 2>&1
    fi
  done < <(Q "SELECT policy_name, label_name, grantee, grantee_type FROM information_schema.security_label_access" 2>/dev/null)
  while IFS='|' read -r _ pn gname gtype _; do
    pn=$(echo "$pn" | tr -d ' '); gname=$(echo "$gname" | tr -d ' '); gtype=$(echo "$gtype" | tr -d ' ')
    case "$pn" in lb_*) ;; *) continue ;; esac
    [ -z "$gname" ] && continue
    if [ "$gtype" = "ROLE" ]; then
      Q "REVOKE EXEMPTION ON RULE ALL FOR $pn FROM ROLE $gname" >/dev/null 2>&1
    else
      Q "REVOKE EXEMPTION ON RULE ALL FOR $pn FROM USER $gname" >/dev/null 2>&1
    fi
  done < <(Q "SELECT policy_name, grantee, grantee_type FROM information_schema.security_policy_exemptions" 2>/dev/null)
  rows=$(Q "SELECT policy_name, label_name FROM information_schema.security_labels" 2>/dev/null | awk -F'|' 'NF>3 {gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2 ~ /^lb_/) print $2"."$3}')
  for x in $rows; do
    Q "REVOKE SECURITY LABEL $x FROM USER root" >/dev/null 2>&1
    Q "DROP SECURITY LABEL $x" >/dev/null 2>&1
  done
  rows=$(Q "SELECT policy_name FROM information_schema.security_policies" 2>/dev/null | awk -F'|' 'NF>2 {gsub(/ /,"",$2); if ($2 ~ /^lb_/) print $2}')
  for x in $rows; do Q "DROP SECURITY POLICY $x" >/dev/null 2>&1; done
  rows=$(Q "SELECT component_name FROM information_schema.security_label_components" 2>/dev/null | awk -F'|' 'NF>2 {gsub(/ /,"",$2); if ($2 ~ /^lb_/) print $2}')
  for x in $rows; do Q "DROP SECURITY LABEL COMPONENT $x" >/dev/null 2>&1; done

  # 校验数据库确实已删除，再重建（避免残留表绑定旧策略）
  local k=0
  while [ $k -lt 3 ]; do
    Q "DROP DATABASE IF EXISTS $DB" >/dev/null 2>&1
    n=$(Q "SHOW DATABASES" 2>/dev/null | grep -cE "\| *$DB *\|")
    [ "${n:-0}" = "0" ] && break
    sleep 1; k=$((k + 1))
  done
  Q "CREATE DATABASE IF NOT EXISTS $DB" >/dev/null 2>&1
}

# ---------- 元数据构造 ----------
mk_table() {  # $1=表名（默认 t1）
  local t=${1:-$TBL}
  Q "CREATE TABLE IF NOT EXISTS $DB.$t(time TIMESTAMP TIME, dev STRING TAG, s1 DOUBLE FIELD, s2 DOUBLE FIELD, s3 DOUBLE FIELD, attr STRING ATTRIBUTE)" >/dev/null 2>&1
}

arr_env() {  # $1=对象保护标签（top/sec/int/pub）
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('TOP','SEC','INT','PUB')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl" >/dev/null 2>&1
  local l
  for l in top sec int pub; do
    Q "CREATE SECURITY LABEL lb_p.$l COMPONENT lb_lvl '$(echo "$l" | tr a-z A-Z)'" >/dev/null 2>&1
  done
  mk_table
  bind_policy t1 lb_p
  protect t1 s1 "$1"
  with_label "$1" "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
}

mv_env() {  # 三组件：lvl(ARRAY) + dept(SET) + org(TREE)，不建表
  lbac_reset
  Q "CREATE SECURITY LABEL COMPONENT lb_lvl ARRAY ('TOP','SEC','INT','PUB')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_dept SET ('RD','QA','FIN')" >/dev/null 2>&1
  Q "CREATE SECURITY LABEL COMPONENT lb_org TREE ('COMPANY' ROOT, 'RND' UNDER 'COMPANY', 'STORAGE' UNDER 'RND')" >/dev/null 2>&1
  Q "CREATE SECURITY POLICY lb_p COMPONENTS lb_lvl, lb_dept, lb_org" >/dev/null 2>&1
}

mk_lbl() {  # $1=标签名 $2=组件取值子句
  if [ -z "${2:-}" ]; then
    Q "CREATE SECURITY LABEL lb_p.$1" >/dev/null 2>&1
  else
    Q "CREATE SECURITY LABEL lb_p.$1 $2" >/dev/null 2>&1
  fi
}

setup_col() {  # $1=列 $2=标签：建表 + 绑策略 + 保护 + 插一行
  mk_table
  bind_policy t1 lb_p
  protect t1 "$1" "$2"
  with_label "$2" "INSERT INTO $DB.t1(time,dev,s1) VALUES(1,'d1',1.5)" >/dev/null 2>&1
}

verify_table_policy() {  # $1=表 $2=policy
  Q "SELECT table_name, security_policy FROM information_schema.tables" 2>/dev/null | grep -E "\| *$1 *\|" | grep -qF "$2"
}

bind_policy() {  # $1=表 $2=policy（校验 + 重试 3 次）
  local t=$1 pol=$2 i=0
  while [ $i -lt 3 ]; do
    Q "ALTER TABLE $DB.$t ADD SECURITY POLICY $pol" >/dev/null 2>&1
    verify_table_policy "$t" "$pol" && return 0
    sleep 1; i=$((i + 1))
  done
  echo "  [warn] 策略绑定未生效：$t -> $pol" >&2
  return 1
}

with_label() {  # $1=label $2=SQL；用一个持有该 label ALL 的临时用户执行
  local lbl=$1 sql=$2 pol=${3:-lb_p}
  local u="lbu_lb_$RANDOM" i=0
  Q "CREATE USER $u '$UPW'" >/dev/null 2>&1
  while [ $i -lt 15 ]; do
    Q "LIST USER" 2>/dev/null | grep -q "$u" && break
    sleep 1; i=$((i + 1))
  done
  Q "GRANT SECURITY LABEL $pol.$lbl TO USER $u FOR ALL ACCESS" >/dev/null 2>&1
  Q "GRANT CREATE ON DATABASE $DB TO USER $u" >/dev/null 2>&1
  Q "GRANT ALTER ON DATABASE $DB TO USER $u" >/dev/null 2>&1
  Q "GRANT SELECT ON DATABASE $DB TO USER $u" >/dev/null 2>&1
  Q "GRANT INSERT ON DATABASE $DB TO USER $u" >/dev/null 2>&1
  Q "GRANT DELETE ON DATABASE $DB TO USER $u" >/dev/null 2>&1
  Q "GRANT UPDATE ON DATABASE $DB TO USER $u" >/dev/null 2>&1
  L "$u" "$UPW" "$sql"
}

verify_col_label() {  # $1=列 $2=标签（按字段精确匹配，避免 CLI 竖线格式差异）
  Q "SELECT column_name, security_label FROM information_schema.columns" 2>/dev/null \
    | awk -F'|' -v c="$1" -v l="$2" '{a=$2; b=$3; gsub(/^[ \t]+|[ \t]+$/,"",a); gsub(/^[ \t]+|[ \t]+$/,"",b); if (a==c && b==l) f=1} END{exit(f?0:1)}'
}

protect() {  # $1=表 $2=列 $3=label（必要时补绑定策略，最多 3 轮；失败时打印真实报错）
  local t=$1 c=$2 l=$3 i=0 out=""
  bind_policy "$t" "${4:-lb_p}" >/dev/null 2>&1
  while [ $i -lt 3 ]; do
    out=$(with_label "$l" "ALTER TABLE $DB.$t ALTER COLUMN $c SECURED WITH $l" 2>&1)
    verify_col_label "$c" "$l" && return 0
    bind_policy "$t" "${4:-lb_p}" >/dev/null 2>&1
    sleep 2; i=$((i + 1))
  done
  echo "  [warn] 列保护未生效：$t.$c -> $l；最后返回：$(echo "$out" | head -1 | cut -c1-140)" >&2
  return 1
}

mk_user() {  # $1=用户名后缀；默认给表上 SELECT/INSERT/UPDATE/DELETE
  local u="lbu_$1"; shift
  Q "CREATE USER $u '$UPW'" >/dev/null 2>&1
  local i=0; while [ $i -lt 15 ]; do Q "LIST USER" 2>/dev/null | grep -q "$u" && break; sleep 1; i=$((i + 1)); done
  if [ $# -eq 0 ]; then set -- SELECT INSERT UPDATE DELETE; fi
  local p
  for p in "$@"; do Q "GRANT $p ON TABLE $DB.$TBL TO USER $u" >/dev/null 2>&1; done
  echo "$u"
}

mk_role() {  # $1=角色名后缀
  local r="lbr_$1"
  Q "CREATE ROLE $r" >/dev/null 2>&1
  local i=0; while [ $i -lt 15 ]; do Q "LIST ROLE" 2>/dev/null | grep -q "$r" && break; sleep 1; i=$((i + 1)); done
  echo "$r"
}

# ---------- 集群操作 ----------
wait_running() {
  local want=${1:-8} t=${2:-600} i=0 n=0
  while [ $i -lt $((t / 6)) ]; do
    n=$(Q "show cluster" 2>/dev/null | grep -c Running)
    [ "$n" -ge "$want" ] && { echo "$n"; return 0; }
    sleep 6; i=$((i + 1))
  done
  echo "$n"; return 1
}

cn_restart() {
  local ip=$1
  ssh -n -o StrictHostKeyChecking=no root@$ip "bash $CN_DIR/sbin/stop-confignode.sh >/dev/null 2>&1; sleep 2; pkill -9 -f 'com.timecho.iotdb.ConfigNode' 2>/dev/null; true" 2>/dev/null
  sleep 5
  ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd $CN_DIR; nohup $CN_DIR/sbin/start-confignode.sh -H $CN_DIR/cn.hprof > $CN_DIR/start_cn.log 2>&1 &" 2>/dev/null
  wait_running 8 480 >/dev/null 2>&1 || true
}

dn_restart() {
  local ip=$1
  ssh -n -o StrictHostKeyChecking=no root@$ip "bash $DN_DIR/sbin/stop-datanode.sh >/dev/null 2>&1; sleep 2; pkill -9 -f 'com.timecho.iotdb.DataNode' 2>/dev/null; true" 2>/dev/null
  sleep 5
  ssh -n -o StrictHostKeyChecking=no root@$ip "source /etc/profile; cd $DN_DIR; nohup $DN_DIR/sbin/start-datanode.sh -H $DN_DIR/dn.hprof > $DN_DIR/start_dn.log 2>&1 &" 2>/dev/null
  wait_running 8 480 >/dev/null 2>&1 || true
}

# ---------- 日志 ----------
log_mark() {
  LOGMARK=$(mktemp)
  local ip
  for ip in $CN_LIST; do
    echo "CN $ip $(ssh -n -o StrictHostKeyChecking=no root@$ip "wc -l < $CN_DIR/logs/log_confignode_all.log" 2>/dev/null)" >> "$LOGMARK"
  done
  for ip in $DN_LIST; do
    echo "DN $ip $(ssh -n -o StrictHostKeyChecking=no root@$ip "wc -l < $DN_DIR/logs/log_datanode_all.log" 2>/dev/null)" >> "$LOGMARK"
  done
}

log_errors() {
  local kind ip n cnt=0
  while read -r kind ip n; do
    n=${n:-0}
    local f="$CN_DIR/logs/log_confignode_all.log"
    [ "$kind" = "DN" ] && f="$DN_DIR/logs/log_datanode_all.log"
    local out
    out=$(ssh -n -o StrictHostKeyChecking=no root@$ip "tail -n +$((n+1)) $f 2>/dev/null | grep ' ERROR '" 2>/dev/null)
    if [ -n "$out" ]; then
      echo "$out" | sed "s/^/    [$kind $ip] /" | head -6
      cnt=$((cnt + $(echo "$out" | wc -l)))
    fi
  done < "$LOGMARK"
  echo "$cnt"
}
